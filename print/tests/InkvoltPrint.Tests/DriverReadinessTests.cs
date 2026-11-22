using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>
/// Ready for Windows' new driver (roadmap 4.5): the kind of driver a queue uses, and whether each printer prints and scans under
/// Windows protected print mode (<see cref="DriverReadiness"/>).
/// </summary>
public class DriverReadinessTests
{
    /// <summary>As an HP LaserJet MFP M234dw answers (no identifiers): PCLm, PWG and Apple raster, Mopria 2.2 and Mopria Scan 1.4.</summary>
    private static readonly IppResponse M234dw = new(0, new Dictionary<string, List<object>>
    {
        ["document-format-supported"] = ["application/PCLm", "application/octet-stream", "image/pwg-raster", "image/urf"],
        ["mopria-certified"] = ["2.2"],
        ["mopria-certified-scan"] = ["1.4"],
        ["output-bin-default"] = ["face-down"],
        ["printer-output-tray"] = ["type=unRemovableBin;maxcapacity=125;remaining=-3;status=0;name=face-down;stackingorder=firstToLast;pagedelivery=faceDown"],
    });

    /// <summary>An older IPP printer that takes only PostScript or PCL: Windows' IPP class driver has nothing to send it.</summary>
    private static readonly IppResponse PostScriptOnly = new(0, new Dictionary<string, List<object>>
    {
        ["document-format-supported"] = ["application/postscript", "application/vnd.hp-PCL"],
    });

    [Theory]
    [InlineData("Microsoft IPP Class Driver", 4, "Microsoft", QueueDriver.WindowsIpp)]
    [InlineData("microsoft ipp class driver", null, null, QueueDriver.WindowsIpp)]
    [InlineData("Microsoft PCL6 Class Driver", 4, "Microsoft", QueueDriver.Microsoft)]
    [InlineData("Microsoft PS Class Driver", 3, "Microsoft", QueueDriver.Microsoft)]
    [InlineData("Generic / Text Only", 3, null, QueueDriver.Microsoft)]
    [InlineData("HP Universal Printing PCL 6", 3, "HP", QueueDriver.MakerV3)]
    [InlineData("Brother HL-L2350DW series", 4, "Brother", QueueDriver.MakerV4)]
    [InlineData("Canon Generic Plus UFR II", null, "Canon", QueueDriver.Maker)]
    [InlineData("Epson ET-2800", 3, "Microsoft", QueueDriver.MakerV3)] // a maker's driver Windows Update delivers: still the maker's
    public void Driver_kind(string name, int? version, string? provider, QueueDriver kind) =>
        Assert.Equal(kind, DriverReadiness.Kind(new QueueDriverInfo(name, version, provider)));

    [Fact]
    public void No_queue_is_none() => Assert.Equal(QueueDriver.None, DriverReadiness.Kind(null));

    [Fact]
    public void A_printers_status_read_asks_for_its_output_tray_and_Mopria()
    {
        foreach (var name in new[] { "output-bin-default", "printer-output-tray", "mopria-certified", "mopria-certified-scan", "document-format-supported" })
            Assert.Contains(name, IppClient.StatusAttributes);
    }

    [Fact]
    public void On_Windows_IPP_class_driver_it_is_ready()
    {
        var r = DriverReadiness.Assess(new(DriverReadiness.IppClassDriver, 4, "Microsoft"), M234dw, asked: true, answersEscl: true, windowsScanner: false);
        Assert.Equal(PrintReadiness.Ready, r.Print);
        Assert.Equal(ScanReadiness.Ready, r.Scan);
        Assert.True(r.AnswersIpp);
        Assert.True(r.Mopria);
        Assert.True(r.MopriaScan);
        Assert.False(r.OffersSetUp);
        Assert.Equal(OutputFace.Down, HandDuplex.FaceOf(M234dw)); // 4.2 reads the same answer
    }

    [Fact]
    public void On_the_makers_driver_a_printer_that_answers_IPP_can_move()
    {
        var r = DriverReadiness.Assess(new("HP Universal Printing PCL 6", 3, "HP"), M234dw, asked: true, answersEscl: true, windowsScanner: false);
        Assert.Equal(QueueDriver.MakerV3, r.Driver);
        Assert.Equal(PrintReadiness.CanMove, r.Print);
        Assert.True(r.OffersSetUp);
        // No queue at all: it can move, and the printer's own Set up in Windows does it (on Windows' IPP class driver too).
        var none = DriverReadiness.Assess(null, M234dw, asked: true, answersEscl: false, windowsScanner: false);
        Assert.Equal(PrintReadiness.CanMove, none.Print);
        Assert.False(none.OffersSetUp);
    }

    [Fact]
    public void A_printer_asked_that_doesnt_answer_IPP_isnt_ready_and_one_not_asked_isnt_known()
    {
        Assert.Equal(PrintReadiness.NotReady, DriverReadiness.Assess(new("Brother HL-2140", 3, "Brother"), null, asked: true, false, false).Print);
        Assert.Equal(PrintReadiness.NotReady, DriverReadiness.Assess(new("Old PS printer", 3, "X"), PostScriptOnly, asked: true, false, false).Print);
        Assert.Equal(PrintReadiness.NotKnown, DriverReadiness.Assess(new("Epson USB", 3, "Epson"), null, asked: false, false, false).Print);
    }

    [Fact]
    public void A_scanner_only_its_Windows_driver_reaches_is_warned_about()
    {
        Assert.Equal(ScanReadiness.DriverOnly, DriverReadiness.Assess(null, null, asked: false, answersEscl: false, windowsScanner: true).Scan);
        Assert.Equal(ScanReadiness.Ready, DriverReadiness.Assess(null, null, asked: false, answersEscl: true, windowsScanner: true).Scan);
        Assert.Equal(ScanReadiness.None, DriverReadiness.Assess(null, null, asked: false, answersEscl: false, windowsScanner: false).Scan);
    }

    [Fact]
    public void The_new_queue_is_named_beside_the_old_one() =>
        Assert.Equal("HP LaserJet MFP M234dw (Windows driver)", DriverReadiness.NewQueueName(" HP LaserJet MFP M234dw ", "Windows driver"));
}
