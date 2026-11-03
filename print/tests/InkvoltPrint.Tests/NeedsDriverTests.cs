using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>"Plugged in, needs its driver" (<see cref="NeedsDriver"/>): USB printers Windows sees that nothing can print to.</summary>
public class NeedsDriverTests
{
    private const string Serial = "AC2LSAA";
    private const string Container = "{A1E366FB-312A-50FF-9A67-1ACAD73B5934}";

    /// <summary>The HP LaserJet P1006 as this PC's Windows has it: bound only to the "Generic printer device" placeholder.</summary>
    private static readonly UsbPrinterNode P1006 = new(UsbNodeKind.UsbPrint, Present: true)
    {
        FriendlyName = "Hewlett-Packard HP LaserJet P1006",
        DeviceIdName = "HEWLETT-PACKARDHP_LASERJET_P1006",
        HardwareIds = [@"USBPRINT\Hewlett-PackardHP_LaBB7B", "Hewlett-PackardHP_LaBB7B"],
        CompatibleIds = ["CID_MS_GENERICPRINT"],
        DriverInf = "prnms013.inf",
        DriverSection = "MS_GENERICPRINT",
        DriverDescription = "Generic printer device",
        Port = "USB001",
        ContainerId = Container,
    };

    private static readonly SpoolerQueue Epson = new("EPSON L1110 Series", "USB002", "EPSON L1110 Series", 0, SpoolerFlags.AttributeLocal, 0);

    private static IReadOnlyList<NeedsDriverPrinter> Find(UsbPrinterNode node, IReadOnlyList<SpoolerQueue>? queues = null, IReadOnlyList<SpoolerDriver>? drivers = null) =>
        NeedsDriver.Find([node], queues ?? [Epson], drivers ?? []);

    [Fact]
    public void A_usb_printer_with_only_the_generic_placeholder_and_no_queue_needs_its_driver()
    {
        var found = Assert.Single(Find(P1006));
        Assert.Equal("HP LaserJet P1006", found.Name);
        Assert.Equal("HP", found.Maker);
        Assert.Equal("USB001", found.Port);
        Assert.Equal(DriverStage.NoDriver, found.Stage);
        Assert.True(NeedsDriver.IsNeedsDriverId(found.Id));
        Assert.Equal(NeedsDriverText.ListStatusNoDriver, NeedsDriverText.ListStatus(found));
    }

    [Fact]
    public void A_driver_problem_code_counts_as_no_driver()
    {
        var node = P1006 with { DriverInf = "hpc1006.inf", DriverSection = "HP1006", ProblemCode = 28 };
        Assert.Equal(DriverStage.NoDriver, Assert.Single(Find(node)).Stage);
    }

    [Fact]
    public void A_printer_with_its_real_driver_and_a_queue_is_not_listed()
    {
        var bound = P1006 with { DriverInf = "oem42.inf", DriverSection = "HP_LJ_P1006", DriverDescription = "HP LaserJet P1006" };
        var queue = new SpoolerQueue("HP LaserJet P1006", "USB001", "HP LaserJet P1006", 0, SpoolerFlags.AttributeLocal, 0);
        Assert.Empty(Find(bound, [Epson, queue]));
    }

    [Fact]
    public void A_queue_on_its_port_or_in_its_container_makes_it_a_queue_printer()
    {
        Assert.Empty(Find(P1006, [new SpoolerQueue("Whatever it's called", "USB001", "Some driver", 0, 0, 0)]));
        Assert.Empty(Find(P1006 with { Port = null }, [new SpoolerQueue("Laser", "USB009", "Some driver", 0, 0, 0) { ContainerId = Container.Trim('{', '}') }]));
        // A virtual printer on the same port name counts for nothing, nor does the PC's own container.
        Assert.Single(Find(P1006 with { ContainerId = "{" + QueueKinds.ThisPcContainer + "}" },
            [new SpoolerQueue("Laser", "USB009", "Some driver", 0, 0, 0) { ContainerId = QueueKinds.ThisPcContainer }]));
    }

    [Fact]
    public void Unplugged_it_is_gone()
    {
        Assert.Empty(Find(P1006 with { Present = false }));
    }

    [Fact]
    public void A_real_driver_bound_but_no_queue_needs_setting_up()
    {
        var bound = P1006 with { DriverInf = "oem42.inf", DriverSection = "HP_LJ_P1006", DriverDescription = "HP LaserJet P1006" };
        var found = Assert.Single(Find(bound, drivers: [new SpoolerDriver("HP LaserJet P1006")]));
        Assert.Equal(DriverStage.NotSetUp, found.Stage);
        Assert.Equal("HP LaserJet P1006", found.Driver);
    }

    [Fact]
    public void An_installed_driver_matching_its_hardware_id_or_model_offers_set_up()
    {
        var byId = Assert.Single(Find(P1006, drivers: [new SpoolerDriver("Microsoft IPP Class Driver"), new SpoolerDriver("HP LJ P1000 series", "Hewlett-PackardHP_LaBB7B")]));
        Assert.Equal((DriverStage.NotSetUp, "HP LJ P1000 series"), (byId.Stage, byId.Driver));
        var byName = Assert.Single(Find(P1006, drivers: [new SpoolerDriver("HP LaserJet P1006 PCL")]));
        Assert.Equal("HP LaserJet P1006 PCL", byName.Driver);
        // Another model, a class driver, a generic one: no match.
        Assert.Equal(DriverStage.NoDriver, Assert.Single(Find(P1006, drivers: [new SpoolerDriver("HP LaserJet P10065"), new SpoolerDriver("Microsoft PCL6 Class Driver"),
            new SpoolerDriver("Generic / Text Only")])).Stage);
    }

    [Fact]
    public void A_printer_class_usb_device_with_no_driver_at_all_is_listed_once()
    {
        var usb = new UsbPrinterNode(UsbNodeKind.UsbDevice, true)
        {
            FriendlyName = "HP LaserJet P1006", CompatibleIds = [@"USB\Class_07&SubClass_01&Prot_02", @"USB\Class_07"], ProblemCode = 28, ContainerId = Container,
        };
        Assert.Equal(DriverStage.NoDriver, Assert.Single(NeedsDriver.Find([usb], [], [])).Stage);
        Assert.Single(NeedsDriver.Find([usb, P1006], [], [])); // with its USBPRINT node, that one stands for it
        Assert.Empty(NeedsDriver.Find([usb with { CompatibleIds = [@"USB\Class_08"] }], [], [])); // not a printer
        Assert.Empty(NeedsDriver.Find([usb with { ProblemCode = 0, DriverInf = "usbprint.inf" }], [], [])); // usbprint has it: its USBPRINT node says
    }

    [Theory]
    [InlineData("Hewlett-Packard HP LaserJet P1006", null, "HP LaserJet P1006")]
    [InlineData(null, @"USBPRINT\Hewlett-PackardHP_LaserJet_P1006", "HP LaserJet P1006")]
    [InlineData(null, "HEWLETT-PACKARDHP_LASERJET_P1006", "HP Laserjet P1006")]
    [InlineData("EPSON EPSON L1110 Series", null, "Epson L1110 Series")]
    [InlineData("EPSON L1110 Series", null, "Epson L1110 Series")]
    [InlineData("Brother HL-L2350DW series", null, "Brother HL-L2350DW series")]
    [InlineData("Generic printer device", "CANONMG2500_SERIES", "Canon MG2500 Series")]
    [InlineData("Acme Label Writer 9", null, "Acme Label Writer 9")]
    [InlineData(null, null, "USB printer")]
    public void Its_name_comes_from_the_friendly_name_or_the_1284_ids(string? friendly, string? deviceId, string expected)
    {
        Assert.Equal(expected, PrinterNames.ForDevice(friendly, deviceId, []));
    }

    [Fact]
    public void A_shortened_hardware_id_is_passed_over_for_the_instance_ids_name()
    {
        Assert.Equal("HP Laserjet P1006", PrinterNames.ForDevice(null, "HEWLETT-PACKARDHP_LASERJET_P1006", [@"USBPRINT\Hewlett-PackardHP_LaBB7B"]));
        Assert.Equal("HP LaserJet P1006", PrinterNames.ForDevice(null, null, [@"USBPRINT\Hewlett-PackardHP_LaserJet_P1006"]));
        // An instance id handed in whole keeps only its device part: no serial.
        Assert.Equal("HP LaserJet P1006", PrinterNames.ForDevice(null, $@"USBPRINT\Hewlett-PackardHP_LaserJet_P1006\{Serial}", []));
    }

    [Fact]
    public void Its_maker_picks_the_driver_page_and_others_get_a_web_search()
    {
        var hp = Assert.Single(Find(P1006));
        Assert.Equal("https://support.hp.com/drivers", DriverHelp.PageFor(hp).AbsoluteUri);
        Assert.Equal("Open HP's driver page", NeedsDriverText.MakerButton(hp));
        var acme = hp with { Name = "Acme Label Writer 9", Maker = null };
        Assert.Equal("Search the web for its driver", NeedsDriverText.MakerButton(acme));
        Assert.Contains(Uri.EscapeDataString("Acme Label Writer 9 driver"), DriverHelp.PageFor(acme).AbsoluteUri);
    }

    [Fact]
    public void Windows_protected_print_mode_is_mentioned_only_when_on()
    {
        Assert.Null(NeedsDriverText.ProtectedPrint(false));
        var on = NeedsDriverText.ProtectedPrint(true);
        Assert.NotNull(on);
        Assert.Contains("Printers & scanners", on);
        Assert.Contains("maker's driver", on);
        Assert.EndsWith("off", NeedsDriverText.ReportLine([], false));
    }

    [Fact]
    public void No_serial_or_container_in_anything_it_says()
    {
        var node = P1006 with { DeviceIdName = $@"HEWLETT-PACKARDHP_LASERJET_P1006\{Serial}" };
        var usb = new UsbPrinterNode(UsbNodeKind.UsbDevice, true) { DeviceIdName = $@"USB\VID_03F0&PID_3E17\{Serial}", CompatibleIds = [@"USB\Class_07"], ProblemCode = 28 };
        var all = NeedsDriver.Find([node, usb], [], [new SpoolerDriver("HP LaserJet P1006")]);
        Assert.Equal(2, all.Count);
        foreach (var p in all)
        {
            string[] said =
            [
                p.Id, p.Name, NeedsDriverText.QueuesLine(p), NeedsDriverText.StatusNote(p), NeedsDriverText.Headline(p), NeedsDriverText.SetUpNote(p),
                NeedsDriverText.SetUpNeedsAdmin(p), NeedsDriverText.StepGetDriver(p), DriverHelp.PageFor(p).AbsoluteUri, p.ToString(),
            ];
            foreach (var text in said)
            {
                Assert.DoesNotContain(Serial, text, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain(Container.Trim('{', '}'), text, StringComparison.OrdinalIgnoreCase);
            }
        }
        Assert.DoesNotContain(Serial, NeedsDriverText.ReportLine(all, true), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void The_cli_says_needs_its_driver()
    {
        Assert.Equal("HP LaserJet P1006 | USB (USB001) | needs its driver", NeedsDriverText.QueuesLine(Assert.Single(Find(P1006))));
    }
}
