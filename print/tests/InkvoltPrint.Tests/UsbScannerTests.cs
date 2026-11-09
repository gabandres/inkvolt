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
    [InlineData("04A9", "Canon EOS R6", @"USB\Class_06")] // a camera that doesn't say so
    [InlineData("04A9", "Canon PowerShot G7 X Mark III", @"USB\Class_06")]
    [InlineData("04B0", "Nikon Z 6II", @"USB\Class_06")]
    [InlineData("05AC", "Apple iPhone", @"USB\Class_06")]
    [InlineData("2717", "Redmi Note 13", @"USB\Class_06")] // a phone in PTP mode, named by its model only
    [InlineData("04E8", "SM-S921B", @"USB\Class_06")]
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
    public void An_all_in_ones_scanner_part_is_listed_when_its_printer_part_prints()
    {
        // The usual case: an Epson ET prints through its queue (Windows' class driver), its scanner part has no driver.
        var printer = new UsbPrinterNode(UsbNodeKind.UsbPrint, true)
        {
            FriendlyName = "EPSON ET-2800 Series", DeviceIdName = "EPSONET-2800_SERIES", DriverInf = "oem12.inf", Port = "USB003", ContainerId = Container,
        };
        var scannerPart = V19 with { BusReportedName = "EPSON ET-2800 Series MFP", HardwareIds = [@"USB\VID_04B8&PID_1186&MI_01"] };
        var queue = new SpoolerQueue("EPSON ET-2800 Series", "USB003", "Microsoft IPP Class Driver", 0, SpoolerFlags.AttributeLocal, 0);
        var s = Assert.Single(NeedsDriver.Find([printer, scannerPart], [queue], []));
        Assert.True(s.IsScanner);
        Assert.Equal("Epson ET-2800 Series MFP", s.Name);
    }

    [Fact]
    public void A_still_image_device_from_a_scanner_maker_that_says_nothing_of_cameras_is_a_scanner()
    {
        var node = new UsbPrinterNode(UsbNodeKind.UsbDevice, true) { BusReportedName = "Canon DR-C225", HardwareIds = [@"USB\VID_04A9&PID_1234"], CompatibleIds = [@"USB\Class_06"], ProblemCode = 28 };
        Assert.Single(Find(node));
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
    public async Task A_huge_name_from_a_scanners_driver_is_compared_at_once()
    {
        // A driver's WIA name can be anything: a long run of " 1" ending in another word made the trailing-number rule quadratic.
        var hostile = "Epson Perfection V19" + string.Concat(Enumerable.Repeat(" 1", 60_000)) + "x";
        var same = await Task.Run(() => UsbScanners.SameModel("Epson Perfection V19", hostile)).WaitAsync(Inkvolt.Testing.Timing.Limit(TimeSpan.FromSeconds(2)));
        Assert.False(same);
    }

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

    // ---------------------------------------------------------------- after its driver's installer: is it there and working?

    private static readonly NeedsDriverPrinter V19Listed = Assert.Single(Find(V19));

    private static readonly NeedsDriverPrinter Laser =
        new("usb-needs-driver:usb001", "HP LaserJet P1006", "HP", "USB001", DriverStage.NoDriver);

    private static readonly UsbPrinterNode LaserNode = new(UsbNodeKind.UsbPrint, true)
    {
        FriendlyName = "Hewlett-Packard HP LaserJet P1006", CompatibleIds = ["CID_MS_GENERICPRINT"], DriverInf = "prnms013.inf",
        DriverSection = "MS_GENERICPRINT", Port = "USB001",
    };

    [Fact]
    public void A_scanner_unplugged_while_waiting_is_absent_not_found()
    {
        Assert.Equal(DeviceNow.Absent, DeviceState.Of(V19Listed, [], []));
        Assert.Equal(DeviceNow.Absent, DeviceState.Of(V19Listed, [V19 with { Present = false, ProblemCode = 0, DriverInf = "oem196.inf" }], []));
        Assert.False(DeviceState.Found(V19Listed, DeviceNow.Absent, wiaLists: true));
    }

    [Fact]
    public void A_scanner_is_found_only_plugged_in_with_a_working_driver_and_listed_by_WIA()
    {
        Assert.Equal(DeviceNow.NeedsDriver, DeviceState.Of(V19Listed, [V19], []));
        var working = V19 with { ProblemCode = 0, DriverInf = "oem196.inf", DriverSection = "ES010C" };
        Assert.Equal(DeviceNow.Working, DeviceState.Of(V19Listed, [working], []));
        Assert.True(DeviceState.Found(V19Listed, DeviceNow.Working, wiaLists: true));
        Assert.False(DeviceState.Found(V19Listed, DeviceNow.Working, wiaLists: false));
        Assert.False(DeviceState.Found(V19Listed, DeviceNow.NeedsDriver, wiaLists: true));
    }

    [Fact]
    public void An_all_in_ones_composite_parent_with_its_driver_doesnt_make_its_scanner_part_working()
    {
        var parent = new UsbPrinterNode(UsbNodeKind.UsbDevice, true)
            { HardwareIds = [@"USB\VID_04B8&PID_1186"], CompatibleIds = [@"USB\COMPOSITE", @"USB\Class_00"], DriverInf = "usb.inf" };
        var printerPart = parent with { HardwareIds = [@"USB\VID_04B8&PID_1186&MI_00"], CompatibleIds = [@"USB\Class_07&SubClass_01"], DriverInf = "usbprint.inf" };
        var scannerPart = V19 with { BusReportedName = "EPSON ET-2800 Series MFP", HardwareIds = [@"USB\VID_04B8&PID_1186&MI_01"] };
        var device = Assert.Single(Find(scannerPart));
        Assert.Equal(DeviceNow.NeedsDriver, DeviceState.Of(device, [parent, printerPart, scannerPart], []));
    }

    [Fact]
    public void A_printer_unplugged_while_waiting_is_absent_and_one_with_a_queue_or_a_real_driver_is_working()
    {
        Assert.Equal(DeviceNow.Absent, DeviceState.Of(Laser, [], []));
        Assert.Equal(DeviceNow.Absent, DeviceState.Of(Laser, [LaserNode with { Present = false }], []));
        Assert.Equal(DeviceNow.NeedsDriver, DeviceState.Of(Laser, [LaserNode], []));
        Assert.Equal(DeviceNow.Working, DeviceState.Of(Laser, [LaserNode with { DriverInf = "oem55.inf", DriverSection = "HPLJP1006" }], []));
        var queue = new SpoolerQueue("HP LaserJet P1006", "USB001", "HP LaserJet P1006", 0, SpoolerFlags.AttributeLocal, 0);
        Assert.Equal(DeviceNow.Working, DeviceState.Of(Laser, [LaserNode], [queue]));
        Assert.True(DeviceState.Found(Laser, DeviceNow.Working, wiaLists: false));
        Assert.False(DeviceState.Found(Laser, DeviceNow.Absent, wiaLists: false));
    }

    [Fact]
    public void A_printer_whose_driver_the_installer_put_in_the_spooler_is_working_though_its_node_keeps_the_placeholder()
    {
        // The list's own rule (Find's NotSetUp): a matching spooler driver means "set it up", not "needs its driver".
        Assert.Equal(DeviceNow.Working, DeviceState.Of(Laser, [LaserNode], [], [new SpoolerDriver("HP LaserJet P1006")]));
        Assert.Equal(DeviceNow.NeedsDriver, DeviceState.Of(Laser, [LaserNode], [], [new SpoolerDriver("Microsoft IPP Class Driver")]));
        Assert.Equal(DeviceNow.Absent, DeviceState.Of(Laser, [LaserNode with { Present = false }], [], [new SpoolerDriver("HP LaserJet P1006")]));
    }
}
