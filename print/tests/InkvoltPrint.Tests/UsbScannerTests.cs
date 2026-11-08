using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>USB scanners that need their driver (<see cref="UsbScanners"/>, listed by <see cref="NeedsDriver.Find"/>).</summary>
public class UsbScannerTests
{
    private const string Serial = "583256303031373834";
    private const string Container = "{6C1A4D2E-0B3F-5E8A-9C7D-2F1E0A9B8C7D}";

    /// <summary>The Epson Perfection V19 as this PC's Windows had it: no driver (28), vendor-specific class, named by the bus only.</summary>
    private static readonly UsbPrinterNode V19 = new(UsbNodeKind.UsbDevice, Present: true)
    {
        FriendlyName = "Epson Perfection V19",
        BusReportedName = "Epson Perfection V19",
        HardwareIds = [@"USB\VID_04B8&PID_013C&REV_0100", @"USB\VID_04B8&PID_013C"],
        CompatibleIds = [@"USB\Class_FF&SubClass_FF&Prot_FF", @"USB\Class_FF&SubClass_FF", @"USB\Class_FF"],
        ProblemCode = 28,
        ContainerId = Container,
    };

    private static IReadOnlyList<NeedsDriverPrinter> Find(params UsbPrinterNode[] nodes) => NeedsDriver.Find(nodes, [], []);

    [Fact]
    public void The_V19_with_no_driver_is_a_scanner_that_needs_its_driver_named_by_the_bus()
    {
        var s = Assert.Single(Find(V19));
        Assert.True(s.IsScanner);
        Assert.Equal("Epson Perfection V19", s.Name);
        Assert.Equal("Epson", s.Maker);
        Assert.Equal("04B8:013C", s.UsbId);
        Assert.Equal(DriverStage.NoDriver, s.Stage);
        Assert.Equal("plugged in, needs its driver", NeedsDriverText.EnglishStatus(s));
        Assert.Equal("Plugged in, needs its driver", NeedsDriverText.ListStatus(s));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(18)]
    [InlineData(28)]
    [InlineData(31)]
    public void Each_driver_problem_lists_it(int code) => Assert.Single(Find(V19 with { ProblemCode = code, DriverInf = "oem196.inf" }));

    [Fact]
    public void A_scanner_with_a_working_driver_or_unplugged_is_not_listed()
    {
        Assert.Empty(Find(V19 with { ProblemCode = 0, DriverInf = "oem196.inf", DriverSection = "ES010C" }));
        Assert.Empty(Find(V19 with { Present = false }));
    }

    [Fact]
    public void A_still_image_device_of_any_maker_is_a_scanner_with_a_name_of_its_own()
    {
        var other = new UsbPrinterNode(UsbNodeKind.UsbDevice, true)
        {
            BusReportedName = "DocuScan 300", HardwareIds = [@"USB\VID_1234&PID_5678"], CompatibleIds = [@"USB\Class_06&SubClass_01&Prot_01", @"USB\Class_06"],
            ProblemCode = 28,
        };
        var s = Assert.Single(Find(other));
        Assert.Equal("DocuScan 300", s.Name);
        Assert.Null(s.Maker);
    }

    [Theory]
    [InlineData("04E8", "Galaxy S24", @"USB\Class_06&SubClass_01&Prot_01")] // Samsung phone in PTP mode
    [InlineData("03F0", "HP Webcam HD 4310", @"USB\Class_FF")] // HP makes webcams
    [InlineData("03F0", "HP USB Optical Mouse", @"USB\Class_FF")]
    [InlineData("04B8", "EPSON USB Device", @"USB\Class_FF")] // an Epson that says nothing of scanning
    [InlineData("04A9", "Canon EOS R6 camera", @"USB\Class_06")] // a camera
    [InlineData("18D1", "Pixel 9", @"USB\Class_FF")] // not a scanner maker
    public void A_phone_a_camera_a_webcam_or_an_unnamed_device_is_not_a_scanner(string vid, string name, string compatible)
    {
        var node = new UsbPrinterNode(UsbNodeKind.UsbDevice, true) { BusReportedName = name, HardwareIds = [$@"USB\VID_{vid}&PID_0001"], CompatibleIds = [compatible], ProblemCode = 28 };
        Assert.Empty(Find(node));
    }

    [Theory]
    [InlineData("04A9", "CanoScan LiDE 300", "Canon")]
    [InlineData("04C5", "ScanSnap iX1600", "Fujitsu")]
    [InlineData("03F0", "HP ScanJet Pro 2600 f1", "HP")]
    [InlineData("04F9", "Brother ADS-1700W", "Brother")]
    [InlineData("07B3", "Plustek OpticFilm 8200i", "Plustek")]
    [InlineData("03F0", "HP LaserJet MFP M140we", "HP")]
    public void A_scanner_makers_scanner_or_all_in_one_is_listed_with_its_maker(string vid, string name, string maker)
    {
        var node = new UsbPrinterNode(UsbNodeKind.UsbDevice, true) { BusReportedName = name, HardwareIds = [$@"USB\VID_{vid}&PID_0001"], CompatibleIds = [@"USB\Class_FF"], ProblemCode = 28 };
        Assert.Equal(maker, Assert.Single(Find(node)).Maker);
    }

    [Fact]
    public void An_all_in_ones_scanner_part_is_not_listed_again_beside_its_printer()
    {
        var printer = new UsbPrinterNode(UsbNodeKind.UsbPrint, true)
        {
            FriendlyName = "EPSON ET-2800 Series", DeviceIdName = "EPSONET-2800_SERIES", CompatibleIds = ["CID_MS_GENERICPRINT"], DriverInf = "prnms013.inf",
            Port = "USB003", ContainerId = Container,
        };
        var scannerPart = V19 with { BusReportedName = "EPSON ET-2800 Series MFP", HardwareIds = [@"USB\VID_04B8&PID_1186&MI_01"] };
        var found = Find(printer, scannerPart);
        Assert.False(Assert.Single(found).IsScanner);
    }

    [Fact]
    public void Windows_placeholder_names_give_way_to_the_makers_and_long_names_are_shortened()
    {
        Assert.Equal("Epson scanner", UsbScanners.NameOf(V19 with { BusReportedName = null, FriendlyName = "Unknown USB Device (Device Descriptor Request Failed)" }));
        Assert.Equal("Epson Perfection V19", UsbScanners.NameOf(V19 with { BusReportedName = "EPSON Perfection V19" }));
        Assert.Equal("Epson Perfection V19", UsbScanners.NameOf(V19 with { BusReportedName = "Perfection V19" }));
        Assert.True(UsbScanners.NameOf(V19 with { BusReportedName = "Epson " + new string('x', 300) }).Length <= 81);
    }

    [Theory]
    [InlineData("Epson Perfection V19", "EPSON Perfection V19", true)]
    [InlineData("Epson Perfection V19", "EPSON Perfection V19 #2", true)]
    [InlineData("Epson Perfection V19", "Epson Perfection V19 Scanner", true)]
    [InlineData("Epson Perfection V19", "EPSON Perfection V19 II", false)]
    [InlineData("Epson Perfection V19", "EPSON Perfection V39", false)]
    [InlineData("Epson Perfection V19", "", false)]
    public void WIA_lists_it_by_its_model(string shown, string listed, bool same) => Assert.Equal(same, UsbScanners.SameModel(shown, listed));

    [Fact]
    public void Its_serial_and_container_are_never_in_what_is_kept_or_shown()
    {
        var withSerial = V19 with { DeviceIdName = $@"USB\VID_04B8&PID_013C\{Serial}" };
        var s = Assert.Single(Find(withSerial));
        foreach (var text in new[] { s.Id, s.Name, s.UsbId!, NeedsDriverText.ScannerLine(s), NeedsDriverText.LogLine(s), NeedsDriverText.StatusNote(s),
                     NeedsDriverText.ReportLine([s], false), NeedsDriverText.ScanTabLine(s), NeedsDriverText.Headline(s) })
        {
            Assert.DoesNotContain(Serial, text, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(Container.Trim('{', '}'), text, StringComparison.OrdinalIgnoreCase);
        }
        Assert.Contains("scanner", NeedsDriverText.LogLine(s));
    }
}
