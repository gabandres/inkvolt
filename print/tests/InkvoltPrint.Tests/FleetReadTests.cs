using System.Text;
using System.Text.Json;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Offline;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Tests;

/// <summary>
/// Reading every printer at once (<see cref="FleetReader"/>), <c>status --all</c> and Fix all, on the demo PC's list (the same
/// printers, queues and scanners the app's <c>--demo</c> has, over the same fixtures) and on printers that misbehave.
/// </summary>
[Collection("Pro")]
public sealed class FleetReadTests : IDisposable
{
    private static readonly DateTimeOffset Now = new(2026, 10, 31, 12, 0, 0, TimeSpan.Zero);
    private static readonly Diagnostics.Identity Me = new("jdoe", "JDOE-LAPTOP");

    public FleetReadTests()
    {
        Pro.Store = new MemoryProStore();
        Pro.Enforced = false;
    }

    public void Dispose()
    {
        Pro.Store = new MemoryProStore();
        Pro.Enforced = false;
    }

    private static Func<string, byte[]?> Folder(params string[] names) => file =>
    {
        foreach (var name in names)
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", name, file);
            if (File.Exists(path)) return File.ReadAllBytes(path);
        }
        return null;
    };

    private static byte[]? OfficeDocument(string file)
    {
        var bytes = Folder("m234dw", "hp-demo")(file);
        return bytes is null || file is not ("DevMgmt_ProductConfigDyn.xml" or "eSCL_ScannerCapabilities.xml") ? bytes
            : Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace("HP LaserJet MFP M234dw", "Demo office laser").Replace(DemoFleet.LaserUuid, DemoFleet.OfficeUuid));
    }

    /// <summary>The demo network: the app's <c>Demo.CreateTransport</c> and <c>Demo.Snmp</c>, over the fixtures on disk.</summary>
    private static HttpMessageHandler DemoNetwork() => new HostRouter(new Dictionary<string, HttpMessageHandler>
    {
        [FixtureHandler.DemoHost] = new FixtureHandler(Folder("m234dw", "hp-demo")),
        [DemoFleet.InkjetHost] = new FixtureHandler(Folder("inkjet-demo")),
        [DemoFleet.OfficeNewHost] = new FixtureHandler(OfficeDocument),
        [DemoFleet.CdmHost] = new FixtureHandler(Folder("cdm-laser")),
    });

    private static SnmpAgent Agent(string name) =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", name))));

    private static ISnmpTransport DemoSnmp() => new SnmpRouter(new Dictionary<string, ISnmpTransport>
    {
        [DemoFleet.SnmpHost] = Agent("workgroup-laser.txt"),
        [DemoFleet.SnmpQueueHost] = Agent("color-mfp.txt"),
    });

    private static IFleetPc DemoPc() => new DemoFleetPc(DemoNetwork, DemoSnmp(), new FakeWiaSystem(DemoFleet.Scanners((_, _) => [])));

    // The demo PC's nine entries, as the Fleet page and status --all list them: the five that need attention (low ink, paper or
    // toner, a paused queue), by name; then the two that can't be reached (the office laser's old address, the PC sharing Front
    // desk); then the two that are fine. Connected printers go by the name they report, as on the sidebar.
    private static readonly string[] NineInOrder =
    [
        "Demo inkjet", "Demo Laser 5200 Series", "Demo USB laser", "HP Color LaserJet Pro MFP 3302", "Office color MFP",
        "Demo office laser", "Front desk on demo-pc",
        "Demo Photo Scanner 40", "HP LaserJet MFP M234dw",
    ];

    private static readonly FleetTrouble[] NineTroubles =
    [
        FleetTrouble.Warning, FleetTrouble.Warning, FleetTrouble.Warning, FleetTrouble.Warning, FleetTrouble.Warning,
        FleetTrouble.Offline, FleetTrouble.Offline,
        FleetTrouble.Ok, FleetTrouble.Ok,
    ];

    [Fact]
    public async Task The_demo_pcs_nine_entries_render_most_trouble_first()
    {
        var read = await FleetReader.ReadAllAsync(DemoPc(), Now);

        Assert.Empty(read.Notes);
        var rows = FleetPage.Rows(read.Printers, Now);
        Assert.Equal(NineInOrder, rows.Select(r => r.Printer.Name));
        Assert.Equal(NineTroubles, rows.Select(r => r.Printer.Trouble));
    }

    [Fact]
    public async Task The_demo_pcs_rows_say_what_each_printer_gave()
    {
        var rows = FleetPage.Rows((await FleetReader.ReadAllAsync(DemoPc(), Now)).Printers, Now).ToDictionary(r => r.Printer.Name);

        var laser = rows["HP LaserJet MFP M234dw"];
        Assert.Equal(FleetTrouble.Ok, laser.Printer.Trouble);
        Assert.Contains(laser.Supplies, s => s.Level is not null);
        Assert.Contains("pages printed", laser.PagesText); // LEDM gives a count
        Assert.StartsWith("Firmware 20", laser.FirmwareText);
        Assert.Equal("Read just now", laser.LastReadText);

        var office = rows["Demo office laser"];
        Assert.Equal(FleetTrouble.Offline, office.Printer.Trouble);
        Assert.Equal("Not read yet", office.LastReadText);

        var usb = rows["Demo USB laser"];
        Assert.Equal(FleetKind.Queue, usb.Printer.Kind);
        Assert.Equal("Paused in Windows", usb.Printer.Status);
        Assert.Equal("Pages not reported", usb.PagesText);

        var inkjet = rows["Demo inkjet"];
        Assert.Contains(inkjet.Supplies, s => s.Text.StartsWith("Yellow", StringComparison.OrdinalIgnoreCase) && s.IsLow);
        Assert.Contains("Firmware", inkjet.FirmwareText);

        var mfp = rows["Office color MFP"];
        Assert.Equal(5, mfp.Supplies.Count); // four toners and its waste box, over SNMP, through the queue's port
        Assert.Contains(mfp.Supplies, s => s.IsLow);

        var scanner = rows["Demo Photo Scanner 40"];
        Assert.Equal(FleetKind.Scanner, scanner.Printer.Kind);
        Assert.Equal("Ready to scan", scanner.Printer.Status);
    }

    [Fact]
    public async Task The_scanner_that_belongs_to_a_printer_and_the_queues_that_stand_for_none_stay_out()
    {
        var read = await FleetReader.ReadAllAsync(DemoPc(), Now);
        Assert.DoesNotContain(read.Printers, p => p.Name.Contains("Print to PDF", StringComparison.Ordinal));
        Assert.DoesNotContain(read.Printers, p => p.Name.Contains("(demo)", StringComparison.Ordinal)); // the HP laser's own queue
        Assert.DoesNotContain(read.Printers, p => p.Name == "Demo Laser 2100"); // the USB laser's scanner part
    }

    [Fact]
    public async Task A_hidden_entry_stays_hidden()
    {
        var pc = new DemoFleetPc(DemoNetwork, DemoSnmp(), new FakeWiaSystem(DemoFleet.Scanners((_, _) => [])))
        {
            Hidden = [QueueKinds.IdFor("Demo USB laser"), DemoFleet.CdmUuid],
        };
        var names = (await FleetReader.ReadAllAsync(pc, Now)).Printers.Select(p => p.Name).ToList();
        Assert.DoesNotContain("Demo USB laser", names);
        Assert.Contains("HP Color LaserJet Pro MFP 3302", names); // remembered: Hidden is only for what Windows lists
    }

    [Fact]
    public async Task The_demo_pcs_json_validates_against_the_schema_and_carries_no_identifiers()
    {
        var read = await FleetReader.ReadAllAsync(DemoPc(), Now);
        var json = FleetExport.Json(read.Printers, read.Notes, Now, Me);

        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        var schema = JsonDocument.Parse(File.ReadAllText(Path.Combine(dir!.FullName, "print", "schemas", "fleet-status.schema.json"))).RootElement;
        Assert.Empty(JsonSchemaCheck.Errors(schema, JsonDocument.Parse(json).RootElement));

        foreach (var secret in new[] { DemoFleet.LaserUuid, DemoFleet.InkjetUuid, DemoFleet.OfficeUuid, DemoFleet.CdmUuid, "CNB0A00000", "DEMO0005200",
                     "192.0.2.", "demo-laser" })
            Assert.DoesNotContain(secret, json, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// The scrubber's test (RecordingTests): a printer whose replies carry its serial number, UUID, MAC, addresses, host names and
    /// people's names, over LEDM and eSCL, IPP and SNMP. None of it may reach the JSON or the CSV.
    /// </summary>
    [Fact]
    public async Task What_the_scrubbers_test_plants_in_a_printers_replies_never_reaches_the_export()
    {
        const string host = "10.20.30.40";
        var m234dw = Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw");
        var ledm = new FixtureHandler(name => File.Exists(Path.Combine(m234dw, name))
            ? Encoding.UTF8.GetBytes(RecordingTests.Plant(name, File.ReadAllText(Path.Combine(m234dw, name)))) : null);
        var ipp = new FixtureHandler(name => name == "ipp_print.ipp.txt" ? Encoding.UTF8.GetBytes(RecordingTests.PlantedIpp) : null);
        var snmpOnly = new HostRouter(new Dictionary<string, HttpMessageHandler>());

        var printers = new List<FleetPrinter>();
        const string planted = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f"; // the UUID the replies report: the printer is known by it, and it stays out too
        foreach (var (id, name, transport, snmp, device) in new (string, string, HttpMessageHandler, ISnmpTransport, SnmpDevice?)[]
                 {
                     (planted, "LEDM printer", ledm, new SnmpRouter(new Dictionary<string, ISnmpTransport>()), null),
                     (planted, "IPP printer", ipp, new SnmpRouter(new Dictionary<string, ISnmpTransport>()), null),
                     (PrinterId.Normalize(null, host), "SNMP printer", snmpOnly,
                         new SnmpRouter(new Dictionary<string, ISnmpTransport> { [host] = new SnmpAgent(SnmpAgent.ParseWalk(RecordingTests.PlantedWalk())) }),
                         new SnmpDevice(null, null, null)),
                 })
        {
            var known = new InkvoltPrinter(id, name, null, host, null) { Snmp = device };
            var pc = new OnePrinterPc(known, () => transport, snmp);
            var read = await FleetReader.ReadAllAsync(pc, Now);
            var printer = Assert.Single(read.Printers);
            Assert.True(printer.Trouble is not FleetTrouble.Offline, $"{name} should have been read");
            printers.Add(printer);
        }

        foreach (var text in new[] { FleetExport.Json(printers, [], Now, Me), FleetExport.Csv(printers, Now, Me) })
            foreach (var word in RecordingTests.Planted)
                Assert.False(text.Contains(word, StringComparison.OrdinalIgnoreCase), $"{word} left in {text}");
    }

    private sealed class OnePrinterPc(InkvoltPrinter printer, Func<HttpMessageHandler> transport, ISnmpTransport snmp) : IFleetPc
    {
        public InkvoltPrinters Remembered { get; } = new([printer], new Dictionary<string, string>());
        public IReadOnlyCollection<string> Hidden => [];
        public PrinterRecipe Recipe(InkvoltPrinter p) => new(transport, snmp);
        public Task<IReadOnlyList<SpoolerQueue>> QueuesAsync(Func<SpoolerQueue, bool> needsPresence, CancellationToken ct) => Task.FromResult<IReadOnlyList<SpoolerQueue>>([]);
        public IQueueStatusSource QueueStatus(SpoolerQueue q) => throw new InvalidOperationException();
        public Task<IReadOnlyList<WiaDeviceInfo>> ScannersAsync(CancellationToken ct) => Task.FromResult<IReadOnlyList<WiaDeviceInfo>>([]);
        public IWiaSystem Wia => throw new InvalidOperationException();
        public SupplyHistoryStore? History => null;
    }

    // ------------------------------------------------------------------ printers that misbehave

    private sealed class Script : IFleetPc
    {
        public List<InkvoltPrinter> Printers = [];
        public Func<string, Func<HttpMessageHandler>> Transport = _ => () => new HostRouter(new Dictionary<string, HttpMessageHandler>());
        public List<SpoolerQueue> Queues = [];
        public Dictionary<string, IQueueStatusSource> Sources = [];
        public Exception? QueuesFail;
        public bool QueuesHang, ScannersHang;
        public SupplyHistoryStore? Store;
        public List<WiaDeviceInfo> Devices = [];
        public IWiaSystem System = new FakeWiaSystem([]);

        public InkvoltPrinters Remembered => new(Printers, new Dictionary<string, string>());
        public IReadOnlyCollection<string> Hidden { get; set; } = [];
        public PrinterRecipe Recipe(InkvoltPrinter p) => new(Transport(p.Host), new SnmpRouter(new Dictionary<string, ISnmpTransport>()));

        public async Task<IReadOnlyList<SpoolerQueue>> QueuesAsync(Func<SpoolerQueue, bool> needsPresence, CancellationToken ct)
        {
            if (QueuesHang) await new TaskCompletionSource().Task;
            if (QueuesFail is { } ex) throw ex;
            return Queues;
        }

        public IQueueStatusSource QueueStatus(SpoolerQueue q) => Sources[q.Name];

        public async Task<IReadOnlyList<WiaDeviceInfo>> ScannersAsync(CancellationToken ct)
        {
            if (ScannersHang) await new TaskCompletionSource().Task;
            return Devices;
        }

        public IWiaSystem Wia => System;
        public SupplyHistoryStore? History => Store;
    }

    private sealed class Source(Func<CancellationToken, Task<QueueStatusRead?>> read) : IQueueStatusSource
    {
        public string Origin => "test";
        public bool HasSupplyLevels => false;
        public Task<QueueStatusRead?> ReadAsync(CancellationToken ct) => read(ct);
    }

    private static SpoolerQueue UsbQueue(string name) => new(name, "USB001", "Driver", 0, SpoolerFlags.AttributeLocal, 0) { PortMonitor = "USB Monitor" };

    private static IQueueStatusSource Ready() => new Source(_ => Task.FromResult<QueueStatusRead?>(QueueStatusRead.From(SpoolerStatus.Describe(UsbQueue("x")))));

    /// <summary>A transport whose every request never answers, whatever the token says.</summary>
    private sealed class Hung : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            await new TaskCompletionSource().Task;
            throw new InvalidOperationException();
        }
    }

    [Fact]
    public async Task A_read_that_hangs_holds_up_only_its_own_row()
    {
        var pc = new Script
        {
            Queues = [UsbQueue("Hangs"), UsbQueue("Fine"), UsbQueue("Throws")],
            Sources =
            {
                ["Hangs"] = new Source(async _ => { await new TaskCompletionSource().Task; return null; }),
                ["Fine"] = Ready(),
                ["Throws"] = new Source(_ => throw new IOException("the wire came out")),
            },
        };

        var read = await FleetReader.ReadAllAsync(pc, Now, limit: TimeSpan.FromMilliseconds(200)).WaitAsync(TimeSpan.FromSeconds(20));

        var rows = read.Printers.ToDictionary(p => p.Name);
        Assert.Equal(FleetTrouble.Ok, rows["Fine"].Trouble);
        Assert.Equal(FleetTrouble.Offline, rows["Hangs"].Trouble);
        Assert.Contains("didn't answer", rows["Hangs"].Status);
        Assert.Equal(FleetTrouble.Offline, rows["Throws"].Trouble);
        Assert.DoesNotContain("wire", rows["Throws"].Status); // not the exception's words
    }

    [Fact]
    public async Task A_network_printer_that_hangs_mid_read_is_contained_too()
    {
        var pc = new Script
        {
            Printers = [new InkvoltPrinter(DemoFleet.LaserUuid, "Hung", null, "192.0.2.50", null), new InkvoltPrinter(DemoFleet.LaserUuid.Replace('1', '2'), "Other", null, "192.0.2.51", null)],
            Transport = host => host == "192.0.2.50" ? () => new Hung() : () => new HostRouter(new Dictionary<string, HttpMessageHandler>()),
        };

        var read = await FleetReader.ReadAllAsync(pc, Now, limit: TimeSpan.FromMilliseconds(400)).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.Equal(2, read.Printers.Count);
        Assert.All(read.Printers, p => Assert.Equal(FleetTrouble.Offline, p.Trouble));
    }

    [Fact]
    public async Task A_lot_of_printers_that_hang_dont_add_up()
    {
        var pc = new Script { Queues = [.. Enumerable.Range(0, 40).Select(i => UsbQueue($"Queue {i}"))] };
        foreach (var q in pc.Queues) pc.Sources[q.Name] = new Source(async _ => { await new TaskCompletionSource().Task; return null; });

        var sw = System.Diagnostics.Stopwatch.StartNew();
        var read = await FleetReader.ReadAllAsync(pc, Now, limit: TimeSpan.FromMilliseconds(200)).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.Equal(40, read.Printers.Count);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(15), $"took {sw.Elapsed}");
    }

    [Fact]
    public async Task A_spooler_that_hangs_or_fails_leaves_a_note_and_the_network_printers()
    {
        var hung = new Script { QueuesHang = true, Printers = [new InkvoltPrinter(DemoFleet.LaserUuid, "Net", null, "192.0.2.50", null)] };
        var read = await FleetReader.ReadAllAsync(hung, Now, limit: TimeSpan.FromMilliseconds(200)).WaitAsync(TimeSpan.FromSeconds(20));
        Assert.Single(read.Printers);
        Assert.Contains(read.Notes, n => n.Contains("Windows' printers", StringComparison.Ordinal));

        var failed = new Script { QueuesFail = new InvalidOperationException("RPC") };
        Assert.Contains((await FleetReader.ReadAllAsync(failed, Now)).Notes, n => n.Contains("Windows' printers", StringComparison.Ordinal));

        var scanners = new Script { ScannersHang = true };
        Assert.Contains((await FleetReader.ReadAllAsync(scanners, Now, limit: TimeSpan.FromMilliseconds(200))).Notes, n => n.Contains("scanners", StringComparison.Ordinal));
    }

    [Fact]
    public async Task A_queue_windows_lost_mid_read_says_so()
    {
        var pc = new Script { Queues = [UsbQueue("Gone")], Sources = { ["Gone"] = new Source(_ => Task.FromResult<QueueStatusRead?>(null)) } };
        var printer = Assert.Single((await FleetReader.ReadAllAsync(pc, Now)).Printers);
        Assert.Equal(FleetTrouble.Offline, printer.Trouble);
        Assert.Equal("Not found in Windows", printer.Status);
    }

    [Fact]
    public async Task Another_device_at_the_address_is_never_read_under_the_printers_name()
    {
        // The address answers as the demo laser, with its own UUID; this printer remembers another one.
        var pc = new Script
        {
            Printers = [new InkvoltPrinter("87654321-4321-4cba-8fed-cba987654321", "My printer", null, FixtureHandler.DemoHost, null)],
            Transport = _ => () => new FixtureHandler(Folder("m234dw", "hp-demo")),
        };

        var printer = Assert.Single((await FleetReader.ReadAllAsync(pc, Now)).Printers);

        Assert.Equal("My printer", printer.Name);
        Assert.Equal(FleetTrouble.Offline, printer.Trouble);
        Assert.Contains("different device", printer.Status);
        Assert.Empty(printer.Supplies);
        Assert.Null(printer.Firmware);
        Assert.Null(printer.Pages);
    }

    [Fact]
    public async Task A_printer_that_doesnt_answer_shows_what_the_supply_history_and_state_last_knew()
    {
        var store = new SupplyHistoryStore(null);
        store.Record("p", [new Consumable("Black", "toner", "K", 33, "ok", null, null, null, null, null)], 4242, new DateOnly(2026, 10, 29));
        var pc = new Script { Store = store, Printers = [new InkvoltPrinter("p", "Asleep", null, "192.0.2.50", null) { Firmware = "2024-08-13" }] };

        var printer = Assert.Single((await FleetReader.ReadAllAsync(pc, Now)).Printers);

        Assert.Equal(FleetTrouble.Offline, printer.Trouble);
        Assert.True(printer.LastKnown);
        Assert.Equal(new DateOnly(2026, 10, 29), printer.LastReadingDay);
        Assert.Null(printer.LastReading);
        Assert.Equal(4242, printer.Pages);
        Assert.Equal("2024-08-13", printer.Firmware);
        Assert.Equal(33, Assert.Single(printer.Supplies).Level);
    }

    [Fact]
    public async Task Reading_writes_nothing_to_the_supply_history()
    {
        var store = new SupplyHistoryStore(null);
        var pc = new DemoFleetPc(DemoNetwork, DemoSnmp(), new FakeWiaSystem(DemoFleet.Scanners((_, _) => []))) { History = store };
        await FleetReader.ReadAllAsync(pc, Now);
        foreach (var id in new[] { DemoFleet.LaserUuid, DemoFleet.InkjetUuid, DemoFleet.CdmUuid }) Assert.Empty(store.Rows(id));
    }

    // ------------------------------------------------------------------ status --all

    private static async Task<(int Code, string Out, string Error)> Status(params string[] args)
    {
        var (o, e) = (new StringWriter(), new StringWriter());
        var code = await FleetCommand.RunAsync(args, o, e, DemoPc(), () => Now, Me, default);
        return (code, o.ToString(), e.ToString());
    }

    [Fact]
    public async Task Status_all_json_writes_the_list_in_trouble_order_to_standard_output()
    {
        var (code, output, error) = await Status("status", "--all", "--json");

        Assert.Equal(FleetCommand.Done, code);
        Assert.Empty(error);
        var printers = JsonDocument.Parse(output).RootElement.GetProperty("printers");
        Assert.Equal(NineInOrder, printers.EnumerateArray().Select(p => p.GetProperty("name").GetString()));
    }

    [Fact]
    public async Task Status_all_without_json_writes_a_line_per_printer()
    {
        var (code, output, _) = await Status("status", "--all");

        Assert.Equal(FleetCommand.Done, code);
        var lines = output.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
        Assert.StartsWith("9 printers:", lines[0]);
        Assert.Contains("Demo inkjet", lines[1]);
        Assert.Contains("Demo Laser 5200 Series", lines[2]);
    }

    [Fact]
    public async Task Status_all_out_writes_the_file_whole()
    {
        var folder = Path.Combine(Path.GetTempPath(), $"inkvolt-fleet-{Guid.NewGuid():N}");
        Directory.CreateDirectory(folder);
        try
        {
            var file = Path.Combine(folder, "fleet.json");
            var (code, output, _) = await Status("status", "--all", "--json", "--out", file);
            Assert.Equal(FleetCommand.Done, code);
            Assert.Empty(output);
            Assert.Equal(9, JsonDocument.Parse(File.ReadAllText(file)).RootElement.GetProperty("printers").GetArrayLength());
            Assert.Equal(["fleet.json"], Directory.GetFiles(folder).Select(Path.GetFileName)); // no temporary file left

            var (failed, _, why) = await Status("status", "--all", "--json", "--out", Path.Combine(folder, "no", "such", "folder.json"));
            Assert.Equal(FleetCommand.SomeFailed, failed);
            Assert.Contains("Could not write", why);
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }

    [Theory]
    [InlineData("status")]
    [InlineData("status", "--json")]
    [InlineData("status", "--all", "--bad")]
    [InlineData("status", "--all", "--out")]
    public async Task Status_with_the_wrong_arguments_says_how_and_reads_nothing(params string[] args)
    {
        var pc = new Script { QueuesFail = new InvalidOperationException("must not be read") };
        var (o, e) = (new StringWriter(), new StringWriter());

        var code = await FleetCommand.RunAsync(args, o, e, pc, () => Now, Me, default);

        Assert.Equal(FleetCommand.Wrong, code);
        Assert.Empty(o.ToString());
        Assert.Contains("status --all", e.ToString());
    }

    [Theory]
    [InlineData(new[] { "status", "--all", "--json" }, true)]
    [InlineData(new[] { "--demo", "status", "--all" }, true)]
    [InlineData(new[] { "--demo", "--pro-enforce", "status", "--all" }, true)]
    [InlineData(new[] { "--demo", "--no-printers", "status", "--all" }, true)]
    [InlineData(new[] { "status" }, true)]
    [InlineData(new[] { "status.pdf" }, false)]
    [InlineData(new[] { "--snapshot", "status" }, false)]
    [InlineData(new string[0], false)]
    public void The_app_tells_the_command_from_a_file_to_open(string[] args, bool expected) => Assert.Equal(expected, FleetCommand.IsFor(args));

    [Fact]
    public async Task Without_a_licence_status_all_says_where_to_get_one_and_reads_nothing()
    {
        Pro.Enforced = true;
        var pc = new Script { QueuesFail = new InvalidOperationException("must not be read") };
        var (o, e) = (new StringWriter(), new StringWriter());

        var code = await FleetCommand.RunAsync(["status", "--all", "--json"], o, e, pc, () => Now, Me, default);

        Assert.Equal(FleetCommand.Wrong, code);
        Assert.Empty(o.ToString());
        Assert.Contains(Pro.Locked(ProFeature.FleetExport), e.ToString());
        Assert.Contains(Pro.BuyUrl, e.ToString());
    }

    [Fact]
    public async Task Stopped_partway_says_so()
    {
        using var stop = new CancellationTokenSource();
        var pc = new Script { Queues = [UsbQueue("Q")], Sources = { ["Q"] = new Source(async ct => { stop.Cancel(); await Task.Delay(Timeout.Infinite, ct); return null; }) } };
        var (o, e) = (new StringWriter(), new StringWriter());

        var code = await FleetCommand.RunAsync(["status", "--all"], o, e, pc, () => Now, Me, stop.Token);

        Assert.Equal(FleetCommand.Stopped, code);
        Assert.Empty(o.ToString());
    }

    [Fact]
    public void The_export_is_behind_the_same_gate()
    {
        Pro.Enforced = false;
        Assert.True(FleetExport.Allowed);
        Pro.Enforced = true;
        Assert.False(FleetExport.Allowed);
    }

    // ------------------------------------------------------------------ Fix all

    private sealed class FakeFixPc(params QueueFacts[] queues) : IOfflineProbes, IOfflineRepairs
    {
        public List<QueueFacts> Queues = [.. queues];
        public SpoolerState Spooler = SpoolerState.Running;
        public List<string> Done = [];
        public AttemptResult UserResult = AttemptResult.Done;
        public bool ReadHangs;
        public Exception? RepairThrows;

        public Task<SpoolerState> SpoolerAsync(CancellationToken ct) => Task.FromResult(Spooler);
        public Task<Rediscovery?> RediscoverAsync(string uuid, CancellationToken ct) => throw new InvalidOperationException("Fix all takes no network step");
        public Task<Reachability> ReachAsync(string host, CancellationToken ct) => throw new InvalidOperationException("Fix all takes no network step");

        public async Task<IReadOnlyList<QueueFacts>> QueuesAsync(CancellationToken ct)
        {
            if (ReadHangs) await new TaskCompletionSource().Task;
            return Queues.ToList();
        }

        public Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct)
        {
            if (RepairThrows is { } ex) throw ex;
            Done.Add($"user {repair.Kind} {repair.Queue}");
            if (UserResult == AttemptResult.Done)
            {
                var i = Queues.FindIndex(q => q.Name == repair.Queue);
                Queues[i] = repair.Kind == RepairKind.ResumeQueue ? Queues[i] with { Paused = false } : Queues[i] with { WorkOffline = false };
            }
            return Task.FromResult(new Attempt(UserResult));
        }

        public Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct)
        {
            Done.Add($"admin {repair.Kind} {repair.Queue}");
            return Task.FromResult(Attempt.Done);
        }
    }

    private static QueueFacts Facts(string name) => new(name, new QueuePort("USB001", PortKind.Other));

    private static Func<Repair, Task<bool>> Answer(bool yes, List<string>? asked = null) => r =>
    {
        asked?.Add(r.Question!);
        return Task.FromResult(yes);
    };

    private static readonly DateTime When = new(2026, 10, 31, 12, 0, 0);

    private static Task<FixAllReport> FixAll(FakeFixPc pc, Func<Repair, Task<bool>> confirm, bool canElevate = false, params string[] queues) =>
        FleetFixAll.RunAsync(queues.Select(q => OfflineDevice.ForQueue(q, q, null)).ToList(), pc, pc, canElevate, confirm, now: When);

    [Fact]
    public async Task Fix_all_asks_for_each_repair_and_does_only_what_was_confirmed()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true, WorkOffline = true }, Facts("B") with { Paused = true }, Facts("C"));
        var asked = new List<string>();

        var report = await FixAll(pc, r => { asked.Add(r.Question!); return Task.FromResult(r.Queue != "B"); }, queues: ["A", "B", "C"]);

        Assert.Equal(3, asked.Count);
        Assert.All(asked, q => Assert.Contains("?", q));
        Assert.Equal(["user ResumeQueue A", "user ClearWorkOffline A"], pc.Done);
        Assert.Equal([FixAllKind.Fixed, FixAllKind.Fixed, FixAllKind.Declined], report.Steps.Select(s => s.Kind));
        Assert.True(pc.Queues.Single(q => q.Name == "B").Paused);
    }

    [Fact]
    public async Task Saying_no_to_everything_changes_nothing()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true, WorkOffline = true });
        var report = await FixAll(pc, Answer(false), queues: ["A"]);
        Assert.Empty(pc.Done);
        Assert.All(report.Steps, s => Assert.Equal(FixAllKind.Declined, s.Kind));
    }

    [Fact]
    public async Task Stuck_jobs_are_never_touched_only_named_for_the_printers_own_fixer()
    {
        var job = new QueueJob(7, "Report.pdf", 2, 0, JobStatus.Error, When.AddMinutes(-10), "someone");
        var deleting = new QueueJob(8, "Old.pdf", 2, 0, JobStatus.Deleting, When.AddHours(-1), "someone");
        var pc = new FakeFixPc(Facts("A") with { Jobs = [job, deleting] });
        var asked = new List<string>();

        var report = await FixAll(pc, Answer(true, asked), queues: ["A"]);

        Assert.Empty(asked);
        Assert.Empty(pc.Done);
        Assert.Empty(report.Steps);
        Assert.Contains(report.Left, l => l.Contains("stuck job", StringComparison.Ordinal));
        Assert.Contains(report.Left, l => l.Contains("Spooler", StringComparison.Ordinal));
        Assert.DoesNotContain(report.Left, l => l.StartsWith("Or ", StringComparison.Ordinal)); // an alternative isn't one more thing to do
    }

    [Fact]
    public async Task A_queue_renamed_while_the_question_was_open_isnt_touched()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true });
        var report = await FixAll(pc, r => { pc.Queues.Clear(); pc.Queues.Add(Facts("A renamed") with { Paused = true }); return Task.FromResult(true); }, queues: ["A"]);
        Assert.Empty(pc.Done);
        Assert.Equal(FixAllKind.Gone, Assert.Single(report.Steps).Kind);
    }

    [Fact]
    public async Task A_queue_someone_resumed_while_the_question_was_open_is_left_alone()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true });
        var report = await FixAll(pc, r => { pc.Queues[0] = Facts("A"); return Task.FromResult(true); }, queues: ["A"]);
        Assert.Empty(pc.Done);
        Assert.Equal(FixAllKind.AlreadyFine, Assert.Single(report.Steps).Kind);
    }

    [Fact]
    public async Task One_refusal_doesnt_stop_the_rest_and_says_what_to_do()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true }, Facts("B") with { Paused = true }) { UserResult = AttemptResult.AccessDenied };

        var report = await FixAll(pc, Answer(true), queues: ["A", "B"]);

        Assert.Equal(2, report.Steps.Count);
        Assert.All(report.Steps, s =>
        {
            Assert.Equal(FixAllKind.Manual, s.Kind);
            Assert.NotEmpty(s.Steps);
        });
        Assert.DoesNotContain(pc.Done, d => d.StartsWith("admin", StringComparison.Ordinal)); // a Store copy never elevates
    }

    [Fact]
    public async Task A_copy_that_may_elevate_asks_windows_only_after_the_user_was_refused()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true }) { UserResult = AttemptResult.AccessDenied };
        var report = await FixAll(pc, Answer(true), canElevate: true, queues: ["A"]);
        Assert.Equal(["user ResumeQueue A", "admin ResumeQueue A"], pc.Done);
        Assert.Equal(FixAllKind.Fixed, Assert.Single(report.Steps).Kind);
    }

    [Fact]
    public async Task A_repair_that_throws_is_that_queues_failure_only()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true }, Facts("B") with { Paused = true }) { RepairThrows = new InvalidOperationException("spooler said no") };
        var report = await FixAll(pc, Answer(true), queues: ["A", "B"]);
        Assert.Equal([FixAllKind.Failed, FixAllKind.Failed], report.Steps.Select(s => s.Kind));
        Assert.Contains("spooler said no", report.Steps[0].Message);
    }

    [Fact]
    public async Task A_stopped_spooler_stops_it_before_any_question()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true }) { Spooler = SpoolerState.Stopped };
        var asked = new List<string>();
        var report = await FixAll(pc, Answer(true, asked), queues: ["A"]);
        Assert.Empty(asked);
        Assert.Contains("Print Spooler", report.Stopped);
    }

    [Fact]
    public async Task Windows_not_answering_ends_it_with_a_message_instead_of_holding_it()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true }) { ReadHangs = true };
        var report = await FleetFixAll.RunAsync([OfflineDevice.ForQueue("A", "A", null)], pc, pc, false, Answer(true), now: When, limit: TimeSpan.FromMilliseconds(100))
            .WaitAsync(TimeSpan.FromSeconds(20));
        Assert.Empty(pc.Done);
        Assert.Contains(report.Left, l => l.Contains("“A”", StringComparison.Ordinal));
    }

    [Fact]
    public async Task A_cancel_stops_before_the_next_queue()
    {
        using var stop = new CancellationTokenSource();
        var pc = new FakeFixPc(Facts("A") with { Paused = true }, Facts("B") with { Paused = true });
        var asked = new List<string>();

        await FleetFixAll.RunAsync([OfflineDevice.ForQueue("A", "A", null), OfflineDevice.ForQueue("B", "B", null)], pc, pc, false, r =>
        {
            asked.Add(r.Queue!);
            stop.Cancel();
            return Task.FromResult(true);
        }, now: When, ct: stop.Token);

        Assert.Equal(["A"], asked);
        Assert.Empty(pc.Done); // cancelled while the question was open: not run
    }

    [Fact]
    public async Task A_network_printer_counts_only_queues_known_to_be_its_own()
    {
        var pc = new FakeFixPc(
            new QueueFacts("Paired", new QueuePort("WSD-1", PortKind.DeviceId)) { ContainerId = DemoFleet.LaserUuid, Paused = true },
            new QueueFacts("By address", new QueuePort("IP_192.0.2.10", PortKind.TcpIp) { Host = "192.0.2.10" }) { WorkOffline = true },
            new QueueFacts("Example Laser copy", new QueuePort("IP_192.0.2.99", PortKind.TcpIp) { Host = "192.0.2.99" }) { Paused = true }, // only its name matches
            new QueueFacts("Unrelated", new QueuePort("USB001", PortKind.Other)) { Paused = true });
        var device = new OfflineDevice(DemoFleet.LaserUuid, "Example Laser", "Example Laser", "192.0.2.10");
        var asked = new List<string>();

        await FleetFixAll.RunAsync([device], pc, pc, false, r => { asked.Add(r.Queue!); return Task.FromResult(true); }, now: When);

        Assert.Equal(["Paired", "By address"], asked);
    }

    [Fact]
    public async Task A_queue_two_printers_share_is_asked_about_once()
    {
        var pc = new FakeFixPc(Facts("A") with { Paused = true });
        var asked = new List<string>();
        await FleetFixAll.RunAsync([OfflineDevice.ForQueue("A", "A", null), OfflineDevice.ForQueue("a", "a", null)], pc, pc, false, Answer(true, asked), now: When);
        Assert.Single(asked);
    }

    [Fact]
    public async Task Without_a_licence_fix_all_asks_nothing_and_changes_nothing()
    {
        Pro.Enforced = true;
        var pc = new FakeFixPc(Facts("A") with { Paused = true });
        var asked = new List<string>();

        var report = await FixAll(pc, Answer(true, asked), queues: ["A"]);

        Assert.True(report.Locked);
        Assert.Empty(asked);
        Assert.Empty(pc.Done);
    }
}
