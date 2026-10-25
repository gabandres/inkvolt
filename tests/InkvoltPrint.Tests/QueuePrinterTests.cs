using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>Printers Windows has a queue for (USB, WSD, older network): which ones show up, and their status in plain words.</summary>
public class QueuePrinterTests
{
    private static SpoolerQueue Queue(string name, string port, string? driver = "Example Laser 2100 PCL6", uint status = 0, uint attributes = SpoolerFlags.AttributeLocal,
        int jobs = 0, string? monitor = null, string? container = null) =>
        new(name, port, driver, status, attributes, jobs) { PortMonitor = monitor, ContainerId = container };

    [Fact]
    public void Flag_values_match_winspool()
    {
        // PRINTER_STATUS_* as System.Printing.PrintQueueStatus lists them; PRINTER_ATTRIBUTE_* from winspool.h.
        Assert.Equal(0x1u, SpoolerFlags.StatusPaused);
        Assert.Equal(0x8u, SpoolerFlags.StatusPaperJam);
        Assert.Equal(0x10u, SpoolerFlags.StatusPaperOut);
        Assert.Equal(0x80u, SpoolerFlags.StatusOffline);
        Assert.Equal(0x400u, SpoolerFlags.StatusPrinting);
        Assert.Equal(0x20000u, SpoolerFlags.StatusTonerLow);
        Assert.Equal(0x40000u, SpoolerFlags.StatusNoToner);
        Assert.Equal(0x400000u, SpoolerFlags.StatusDoorOpen);
        Assert.Equal(0x1000000u, SpoolerFlags.StatusPowerSave);
        Assert.Equal(0x10u, SpoolerFlags.AttributeNetwork);
        Assert.Equal(0x400u, SpoolerFlags.AttributeWorkOffline);
        Assert.Equal(0x4000u, SpoolerFlags.AttributeFax);
        Assert.Equal(0x8000u, SpoolerFlags.AttributeTerminalServer);
    }

    [Theory]
    [InlineData("Microsoft Print to PDF", "PORTPROMPT:", "Microsoft Print To PDF", null)]
    [InlineData("Microsoft XPS Document Writer", "PORTPROMPT:", "Microsoft XPS Document Writer v4", null)]
    [InlineData("OneNote (Desktop)", "example_onenote-psa:print-to-onenote", "Microsoft Virtual Print Class Driver", "Virtual Monitor")]
    [InlineData("Send To OneNote 2016", "nul:", "Send to Microsoft OneNote 16 Driver", null)]
    [InlineData("Fax", "SHRFAX:", "Microsoft Shared Fax Driver", null)]
    [InlineData("Adobe PDF", "Documents\\*.pdf (Adobe PDF)", "Adobe PDF Converter", null)]
    [InlineData("CutePDF Writer", "CPW2:", "CutePDF Writer", null)]
    [InlineData("PDF24", "PDF24:", "PDF24", null)]
    [InlineData("Print to file", "FILE:", "Generic / Text Only", null)]
    [InlineData("Snagit 2024", "Snagit Port", "Snagit 24 Printer", null)]
    [InlineData("Example Laser (redirected 2)", "TS001", "Remote Desktop Easy Print", null)]
    public void Virtual_printers_are_left_out(string name, string port, string driver, string? monitor) =>
        Assert.True(QueueKinds.IsVirtual(Queue(name, port, driver, monitor: monitor)));

    [Fact]
    public void Fax_and_remote_desktop_attributes_mark_a_queue_virtual()
    {
        Assert.True(QueueKinds.IsVirtual(Queue("Office line", "COM3:", "Modem", attributes: SpoolerFlags.AttributeLocal | SpoolerFlags.AttributeFax)));
        Assert.True(QueueKinds.IsVirtual(Queue("Example Laser", "TS003", "Example Laser", attributes: SpoolerFlags.AttributeTerminalServer)));
    }

    [Theory]
    [InlineData("Example Inkjet 3700", "USB001", "Example Inkjet 3700 Series")]
    [InlineData("Example MFP", "DOT4_001", "Example MFP PCL 6")]
    [InlineData("Example Laser (WSD)", "WSD-0e1f2a3b-0000-4000-8000-000000000001", "Microsoft IPP Class Driver")]
    [InlineData("Office laser", "IP_192.0.2.40", "Example Universal PCL6")]
    [InlineData("Label printer", "LPT1:", "Example Label Printer")]
    [InlineData("\\\\print-server\\Floor 2", "\\\\print-server\\Floor 2", "Example Universal PS")]
    public void Real_printers_are_kept(string name, string port, string driver) =>
        Assert.False(QueueKinds.IsVirtual(Queue(name, port, driver)));

    [Theory]
    [InlineData("USB001", null, 0x40u, QueueConnection.Usb)]
    [InlineData("DOT4_001", "Dynamic Print Monitor", 0x40u, QueueConnection.Usb)]
    [InlineData("WSD-0e1f2a3b-0000-4000-8000-000000000001", "WSD Port Monitor", 0x40u, QueueConnection.Network)]
    [InlineData("IP_192.0.2.40", "Standard TCP/IP Port", 0x40u, QueueConnection.Network)]
    [InlineData("192.0.2.40_1", null, 0x40u, QueueConnection.Network)]
    [InlineData("http://192.0.2.40:631/ipp/print", null, 0x40u, QueueConnection.Network)]
    [InlineData("LPT1:", null, 0x40u, QueueConnection.Parallel)]
    [InlineData("COM1:", null, 0x40u, QueueConnection.Serial)]
    [InlineData("\\\\print-server\\Floor 2", null, 0x10u, QueueConnection.Shared)]
    [InlineData("SOMEPORT:", "Vendor Monitor", 0x40u, QueueConnection.Other)]
    public void Connection_comes_from_the_port(string port, string? monitor, uint attributes, QueueConnection expected) =>
        Assert.Equal(expected, QueueKinds.Connection(Queue("Example", port, attributes: attributes, monitor: monitor)));

    [Fact]
    public void Connection_text_names_the_server_of_a_shared_printer()
    {
        Assert.Equal("USB", QueueKinds.ConnectionText(Queue("Example", "USB001")));
        Assert.Equal("Network", QueueKinds.ConnectionText(Queue("Example", "IP_192.0.2.40")));
        Assert.Equal("Shared from print-server", QueueKinds.ConnectionText(
            Queue("\\\\print-server\\Floor 2", "\\\\print-server\\Floor 2", attributes: SpoolerFlags.AttributeNetwork)));
    }

    [Fact]
    public void Shared_printer_reads_as_windows_names_it()
    {
        Assert.Equal("Floor 2 on print-server", QueueKinds.DisplayName(Queue(@"\\print-server\Floor 2", @"\\print-server\Floor 2")));
        Assert.Equal("Example Inkjet 3700", QueueKinds.DisplayName(Queue("Example Inkjet 3700", "USB001")));
    }

    [Theory]
    [InlineData("USB001", "USB (USB001)")]
    [InlineData("WSD-0e1f2a3b-0000-4000-8000-000000000001", "Network (WSD)")]
    [InlineData("IP_192.0.2.40", "Network (192.0.2.40)")]
    [InlineData("http://192.0.2.40:631/ipp/print", "Network (IPP, 192.0.2.40)")]
    [InlineData("LPT1:", "Parallel port (LPT1)")]
    public void Connection_detail_names_the_port(string port, string expected) =>
        Assert.Equal(expected, QueueKinds.ConnectionDetail(Queue("Example", port)));

    [Fact]
    public void Queue_ids_are_stable_and_never_look_like_a_uuid()
    {
        var id = QueueKinds.IdFor("Example Inkjet 3700");
        Assert.Equal(id, QueueKinds.IdFor("example inkjet 3700"));
        Assert.True(QueueKinds.IsQueueId(id));
        Assert.False(PrinterId.IsValid(id));
        Assert.False(QueueKinds.IsQueueId("12345678-1234-4abc-8def-123456789abc"));
    }

    // ------------------------------------------------------------------ status

    [Fact]
    public void Idle_queue_is_ready_and_says_where_the_status_comes_from()
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001"));
        Assert.Equal("ready", s.Status.Code);
        Assert.Equal("Ready", s.Status.Message);
        Assert.Equal(Severity.Info, s.Status.Severity);
        Assert.Empty(s.Status.Alerts);
        Assert.False(s.Offline);
    }

    [Theory]
    [InlineData(SpoolerFlags.StatusPaperJam, "Paper jam", "media-jam")]
    [InlineData(SpoolerFlags.StatusPaperOut, "Out of paper", "media-empty")]
    [InlineData(SpoolerFlags.StatusDoorOpen, "A door or cover is open", "door-open")]
    [InlineData(SpoolerFlags.StatusNoToner, "Out of toner or ink", "no-toner")]
    [InlineData(SpoolerFlags.StatusOutputBinFull, "Output tray is full", "output-bin-full")]
    [InlineData(SpoolerFlags.StatusUserIntervention, "The printer needs attention", "user-intervention")]
    public void Problems_are_errors(uint status, string message, string id)
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001", status: status | SpoolerFlags.StatusError));
        Assert.Equal(message, s.Status.Message);
        Assert.Equal(Severity.Error, s.Status.Severity);
        Assert.Equal(id, Assert.Single(s.Status.Alerts).Id); // the generic error bit adds nothing when a specific one is set
        Assert.False(s.Offline);
    }

    [Fact]
    public void Generic_error_alone_still_shows()
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001", status: SpoolerFlags.StatusError));
        Assert.Equal("Printer error", s.Status.Message);
        Assert.Equal(Severity.Error, s.Status.Severity);
    }

    [Fact]
    public void Toner_low_is_a_warning_beside_ready()
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001", status: SpoolerFlags.StatusTonerLow));
        Assert.Equal("Ready", s.Status.Message);
        Assert.Equal(Severity.Warning, s.Status.Severity);
        var alert = Assert.Single(s.Status.Alerts);
        Assert.Equal("toner-low", alert.Id);
        Assert.Equal(Severity.Warning, alert.Severity);
        Assert.Contains("driver", alert.Message);
    }

    [Fact]
    public void Several_problems_lead_with_the_worst()
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001", status: SpoolerFlags.StatusTonerLow | SpoolerFlags.StatusPaperJam | SpoolerFlags.StatusPrinting));
        Assert.Equal("Paper jam", s.Status.Message);
        Assert.Equal(["media-jam", "toner-low"], s.Status.Alerts.Select(a => a.Id));
    }

    [Theory]
    [InlineData(SpoolerFlags.StatusPrinting, "Printing")]
    [InlineData(SpoolerFlags.StatusProcessing, "Printing")]
    [InlineData(SpoolerFlags.StatusWarmingUp, "Warming up")]
    [InlineData(SpoolerFlags.StatusInitializing, "Starting up")]
    [InlineData(SpoolerFlags.StatusPowerSave, "Sleeping")]
    [InlineData(SpoolerFlags.StatusIoActive, "Ready")]
    public void Activity_is_info(uint status, string message)
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001", status: status));
        Assert.Equal(message, s.Status.Message);
        Assert.Equal(Severity.Info, s.Status.Severity);
    }

    [Fact]
    public void Paused_queue_holds_jobs()
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001", status: SpoolerFlags.StatusPaused, jobs: 2));
        Assert.Equal("paused", s.Status.Code);
        Assert.Equal("Paused in Windows", s.Status.Message);
        Assert.Equal(Severity.Warning, s.Status.Severity);
        Assert.Contains("2 jobs", s.Status.Detail);
        Assert.False(s.Offline);
    }

    [Theory]
    [InlineData(SpoolerFlags.StatusOffline, 0u)]
    [InlineData(SpoolerFlags.StatusNotAvailable, 0u)]
    [InlineData(SpoolerFlags.StatusServerOffline, 0u)]
    [InlineData(0u, SpoolerFlags.AttributeWorkOffline)]
    public void Offline_in_any_form_is_offline(uint status, uint attributes)
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001", status: status, attributes: SpoolerFlags.AttributeLocal | attributes));
        Assert.True(s.Offline);
        Assert.Equal("offline", s.Status.Code);
        Assert.Equal(Severity.Error, s.Status.Severity);
    }

    [Fact]
    public void Use_printer_offline_is_named_as_such()
    {
        var s = SpoolerStatus.Describe(Queue("Example", "USB001", attributes: SpoolerFlags.AttributeLocal | SpoolerFlags.AttributeWorkOffline, jobs: 1));
        Assert.Equal("Use Printer Offline is on", s.Status.Message);
        Assert.Contains("1 job", s.Status.Detail);
    }

    [Fact]
    public void Offline_usb_printer_says_to_check_the_cable_and_network_printer_the_network()
    {
        Assert.Contains("USB cable", SpoolerStatus.Describe(Queue("Example", "USB001", status: SpoolerFlags.StatusOffline)).Status.Detail);
        Assert.Contains("network", SpoolerStatus.Describe(Queue("Example", "IP_192.0.2.40", status: SpoolerFlags.StatusOffline)).Status.Detail);
    }

    [Fact]
    public void Device_windows_no_longer_sees_is_not_connected_even_when_the_spooler_says_ready()
    {
        // A WSD queue of a printer that left the network keeps status 0 ("ready"); its WSD device node is no longer present.
        var gone = Queue("Example", "WSD-0000", status: 0) with { DevicePresent = false };
        var s = SpoolerStatus.Describe(gone);
        Assert.True(s.Offline);
        Assert.Equal("Not connected", s.Status.Message);
        Assert.Contains("network", s.Status.Detail);
        Assert.Contains("USB cable", SpoolerStatus.Describe(Queue("Example", "USB001") with { DevicePresent = false }).Status.Detail);
        Assert.False(SpoolerStatus.Describe(Queue("Example", "USB001") with { DevicePresent = true }).Offline);
        Assert.False(SpoolerStatus.Describe(Queue("Example", "USB001") with { DevicePresent = null }).Offline);
    }

    [Theory]
    [InlineData(new[] { @"USBPRINT\Example\7&0001", @"SWD\PRINTENUM\{0001}" }, new[] { true, true }, true)]
    [InlineData(new[] { @"USBPRINT\Example\7&0001", @"SWD\PRINTENUM\{0001}" }, new[] { false, true }, false)]
    [InlineData(new[] { @"SWD\DAFWSDProvider\urn:uuid:0001", @"SWD\DAFWSDProvider\urn:uuid:0001/scanner", @"SWD\IPP\0001" }, new[] { false, false, true }, false)]
    [InlineData(new[] { @"SWD\DAFWSDProvider\urn:uuid:0001", @"SWD\DAFWSDProvider\urn:uuid:0001/scanner" }, new[] { true, false }, true)]
    [InlineData(new[] { @"SWD\IPP\0001", @"SWD\PRINTENUM\{0001}" }, new[] { false, true }, null)] // IPP nodes stay present: can't tell
    [InlineData(new string[0], new bool[0], null)]
    public void Presence_comes_from_the_usb_or_wsd_device_nodes(string[] ids, bool[] present, bool? expected) =>
        Assert.Equal(expected, QueueKinds.DevicePresence(ids.Zip(present)));

    // ------------------------------------------------------------------ duplicates

    private static InkvoltPrinters Network(params InkvoltPrinter[] printers) => new(printers, new Dictionary<string, string>());

    [Fact]
    public void Queues_a_network_printer_already_has_are_not_listed_again()
    {
        const string uuid = "0e1f2a3b-0000-4000-8000-000000000001";
        var known = Network(new InkvoltPrinter(uuid, "Example Laser 2100", "Example Laser 2100", "192.0.2.10", null));
        var queues = new[]
        {
            Queue("Example Laser 2100 (WSD)", "WSD-0000", container: uuid),                       // same device container
            Queue("Office copy", "IP_192.0.2.10"),                                                  // its address in the port
            Queue("Example Inkjet 3700", "USB001", "Example Inkjet 3700 Series"),                   // a USB printer: kept
            Queue("Microsoft Print to PDF", "PORTPROMPT:", "Microsoft Print To PDF"),               // virtual: left out
        };
        Assert.Equal(["Example Inkjet 3700"], QueueKinds.Unclaimed(queues, known).Select(q => q.Name));
    }

    [Fact]
    public void Queue_created_for_a_printer_added_by_address_is_its_own()
    {
        const string uuid = "0e1f2a3b-0000-4000-8000-000000000002";
        var known = new InkvoltPrinters([new InkvoltPrinter(uuid, "Example", null, "printer.example", null)],
            new Dictionary<string, string> { [uuid] = "Front desk" });
        Assert.Empty(QueueKinds.Unclaimed([Queue("Front desk", "http://printer.example:631/ipp/print")], known));
    }

    [Fact]
    public void Without_network_printers_every_real_queue_shows()
    {
        var queues = new[] { Queue("Example Inkjet 3700", "USB001"), Queue("Office laser", "IP_192.0.2.40") };
        Assert.Equal(2, QueueKinds.Unclaimed(queues, InkvoltPrinters.Empty).Count);
    }
}
