using System.Text.Json;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Recording;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Record a printer (print/ROADMAP.md 1.2): the demo printers recorded through the fixture transport and served again from the
/// recording read the same; identifiers planted in a printer's replies don't survive the recording. No test records a real printer.
/// </summary>
public sealed class RecordingTests : IDisposable
{
    private static readonly Diagnostics.Identity Me = new("jdoe", "JDOE-LAPTOP");
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "inkvolt-record-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private static string FixtureDir(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", name);

    /// <summary>A printer's web server answering from a folder, as the demo and the tests serve fixtures.</summary>
    private static FixtureHandler Serve(string folder, Func<string, string, string>? edit = null) => new(name =>
    {
        var path = Path.Combine(folder, name);
        if (!File.Exists(path)) return null;
        return edit is null ? File.ReadAllBytes(path) : System.Text.Encoding.UTF8.GetBytes(edit(name, File.ReadAllText(path)));
    });

    private static HttpMessageHandler At(string host, HttpMessageHandler printer) =>
        new HostRouter(new Dictionary<string, HttpMessageHandler> { [host] = printer });

    private static SnmpAgent Agent(string text) => new(SnmpAgent.ParseWalk(text));

    /// <summary>What the app shows of a printer: interfaces, model, firmware, scanner, and one reading. Identifiers left out.</summary>
    private static async Task<string> Seen(string host, HttpMessageHandler transport, ISnmpTransport? snmp = null)
    {
        using var c = await PrinterConnection.OpenAsync(host, transport: transport, snmp: snmp);
        var reading = await c.ReadAsync();
        var p = c.Probe;
        return JsonSerializer.Serialize(new
        {
            Interfaces = p.Interfaces.ToList(), p.Model, p.Brand, p.Firmware, p.HasHpInterfaces,
            Scanner = p.Scanner is { } s ? new { s.MakeAndModel, s.Platen, s.Adf, Sources = s.Sources.ToList() } : null,
            // Less what identifies the printer (stand-ins now) and what a person types (printer-info, printer-location: words now).
            Ipp = p.Ipp?.Attributes.Where(a => a.Key is not ("printer-uuid" or "printer-uri-supported" or "printer-more-info" or "printer-supply-info-uri"
                    or "printer-name" or "printer-info" or "printer-location" or "printer-dns-sd-name" or "printer-device-id"))
                .OrderBy(a => a.Key, StringComparer.Ordinal).ToDictionary(),
            Snmp = p.Snmp is { } id ? new { id.Version, id.DeviceIndex, id.Model } : null,
            reading,
        });
    }

    [Fact]
    public async Task Recording_the_M234dw_reads_back_as_its_fixtures()
    {
        const string host = FixtureHandler.DemoHost;
        var result = await PrinterRecorder.RecordAsync(host, _dir, new RecordOptions { Transport = At(host, Serve(FixtureDir("m234dw"))), Who = Me });

        Assert.Equal(["LEDM", "CDM", "eSCL"], result.Interfaces); // its DiscoveryTree lists CDM
        Assert.Equal("HP LaserJet MFP M234dw", result.Model);
        // Every document the app read is kept under the fixture's own name.
        var original = Directory.GetFiles(FixtureDir("m234dw")).Select(Path.GetFileName).ToHashSet();
        var recorded = result.Files.Where(f => f != PrinterRecorder.NotesFile).ToList();
        Assert.All(recorded, f => Assert.Contains(f, original));
        Assert.Contains("DevMgmt_ProductStatusDyn.xml", recorded);
        Assert.Contains("DevMgmt_ConsumableConfigDyn.xml", recorded);
        Assert.Contains("FirmwareUpdate_FirmwareUpdateDyn.xml", recorded);
        Assert.Contains("eSCL_ScannerStatus.xml", recorded);

        var before = await Seen(host, At(host, Serve(FixtureDir("m234dw"))));
        var after = await Seen(host, At(host, Serve(_dir)));
        Assert.Equal(before, after);

        // One printer still: LEDM's and eSCL's UUID agree, and it is a stand-in, as is the serial.
        using var c = await PrinterConnection.OpenAsync(host, transport: At(host, Serve(_dir)));
        Assert.Single(c.Probe.ReportedUuids.OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase));
        Assert.Equal("00000000-0000-4000-8000-000000000001", c.Probe.Uuid);
        Assert.StartsWith("SN", c.Probe.SerialNumber);
    }

    [Fact]
    public async Task Recording_the_demo_inkjet_keeps_its_IPP_attributes_and_scanner()
    {
        const string host = "192.0.2.11";
        var result = await PrinterRecorder.RecordAsync(host, _dir,
            new RecordOptions { Transport = At(host, Serve(FixtureDir("inkjet-demo"))), PlaceholderHost = host, Who = Me });

        Assert.Equal(["eSCL", "IPP"], result.Interfaces);
        Assert.Contains("ipp_print.ipp.txt", result.Files);
        Assert.Contains("eSCL_ScannerCapabilities.xml", result.Files);
        Assert.Equal(await Seen(host, At(host, Serve(FixtureDir("inkjet-demo")))), await Seen(host, At(host, Serve(_dir))));
        // The printer's own pages still point back at it, so the app still offers them.
        using var c = await PrinterConnection.OpenAsync(host, transport: At(host, Serve(_dir)));
        Assert.NotNull(c.Probe.WebPage);
    }

    [Fact]
    public async Task Recording_the_demo_CDM_laser_keeps_its_JSON()
    {
        const string host = "192.0.2.13";
        var result = await PrinterRecorder.RecordAsync(host, _dir, new RecordOptions { Transport = At(host, Serve(FixtureDir("cdm-laser"))), PlaceholderHost = host, Who = Me });

        Assert.Equal(["CDM"], result.Interfaces);
        Assert.Equal(Directory.GetFiles(FixtureDir("cdm-laser")).Select(Path.GetFileName).Order(),
            result.Files.Where(f => f != PrinterRecorder.NotesFile).Order());
        Assert.Equal(await Seen(host, At(host, Serve(FixtureDir("cdm-laser")))), await Seen(host, At(host, Serve(_dir))));
    }

    [Fact]
    public async Task Recording_an_SNMP_only_printer_writes_a_walk_the_made_up_agent_serves()
    {
        const string host = "192.0.2.14";
        var walk = File.ReadAllText(Path.Combine(FixtureDir("snmp-demo"), "workgroup-laser.txt"));
        var nothingOverHttp = new HostRouter(new Dictionary<string, HttpMessageHandler>());
        var result = await PrinterRecorder.RecordAsync(host, _dir, new RecordOptions { Transport = nothingOverHttp, Snmp = Agent(walk), PlaceholderHost = host, Who = Me });

        Assert.Equal(["SNMP"], result.Interfaces);
        Assert.Contains(PrinterRecorder.SnmpFile, result.Files);
        var replay = Agent(File.ReadAllText(Path.Combine(_dir, PrinterRecorder.SnmpFile)));
        Assert.Equal(await Seen(host, new HostRouter(new Dictionary<string, HttpMessageHandler>()), Agent(walk)),
            await Seen(host, new HostRouter(new Dictionary<string, HttpMessageHandler>()), replay));
        // Every object the reader walks is there, so the agent answers each GetNext as the printer did.
        var objects = SnmpAgent.ParseWalk(walk).Where(o => PrinterRecorder.SnmpSubtrees.Any(o.Name.IsUnder)).Select(o => o.Name.ToString());
        var kept = SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(_dir, PrinterRecorder.SnmpFile))).Select(o => o.Name.ToString()).ToHashSet();
        Assert.All(objects, o => Assert.Contains(o, kept));
    }

    [Fact]
    public async Task A_recording_only_reads()
    {
        const string host = FixtureHandler.DemoHost;
        var sent = new List<string>();
        var spy = new Spy(Serve(FixtureDir("m234dw")), r => { lock (sent) sent.Add($"{r.Method} {r.Content?.Headers.ContentType?.MediaType}"); });
        await PrinterRecorder.RecordAsync(host, _dir, new RecordOptions { Transport = At(host, spy), Who = Me });

        Assert.NotEmpty(sent);
        Assert.All(sent, s => Assert.True(s.StartsWith("GET", StringComparison.Ordinal) || s == "POST application/ipp", s));
    }

    // ------------------------------------------------------------------------------------------------ scrubbing

    private const string PlantedHost = "10.20.30.40";
    private const string Serial = "CNB7K2M9QZ", Uuid = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f", Mac = "a0:b1:c2:d3:e4:f5";

    /// <summary>What a real printer's replies carry about it, its network and its people: none may survive a recording.</summary>
    internal static readonly string[] Planted =
    [
        Serial, Uuid, Mac, "A0B1C2D3E4F5", "A0-B1-C2-D3-E4-F5", PlantedHost, "10.20.30.41", "fe80::1c2b:3a4d:5e6f:7a8b", "2a02:810d:4b3f:1200",
        "NPI7A1B2C", "jdoe-printer", "corp.lan", "HPF0A1B2", "A1B2C3", "jane", "contoso", "jdoe", "JDOE-LAPTOP", "Tax return",
        "Second floor", "Garcia family", "12345678-1234-4abc-8def-123456789abc", "CNB0A00000", "VNB3R12345",
    ];

    internal static string Plant(string name, string text) => name switch
    {
        "DevMgmt_ProductConfigDyn.xml" => text.Replace("12345678-1234-4abc-8def-123456789abc", Uuid).Replace("CNB0A00000", Serial)
            .Replace("<dd:DeviceLocation ></dd:DeviceLocation>", "<dd:DeviceLocation>Jane's office, second floor</dd:DeviceLocation>"),
        "eSCL_ScannerCapabilities.xml" => text.Replace("12345678-1234-4abc-8def-123456789abc", Uuid).Replace("CNB0A00000", Serial)
            .Replace("</scan:ScannerCapabilities>",
                $"<scan:AdminURI>http://NPI7A1B2C.local/#hId-pgDevInfo</scan:AdminURI><scan:IconURI>http://{PlantedHost}/ipp/images/printer.png</scan:IconURI></scan:ScannerCapabilities>"),
        "eSCL_ScannerStatus.xml" => text.Replace("</scan:ScannerStatus>",
            $"<scan:Jobs><scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/{Uuid}</pwg:JobUri><pwg:JobUuid>{Uuid}</pwg:JobUuid><scan:Age>20</scan:Age>" +
            "<pwg:JobState>Completed</pwg:JobState><pwg:JobName>Tax return 2025.pdf</pwg:JobName><pwg:JobOriginatingUserName>jdoe</pwg:JobOriginatingUserName>" +
            "</scan:JobInfo></scan:Jobs></scan:ScannerStatus>"),
        "DevMgmt_ProductStatusDyn.xml" => text.Replace("</psdyn:ProductStatusDyn>",
            $"<!-- seen from 10.20.30.41 at {Mac} --></psdyn:ProductStatusDyn>"),
        _ => text,
    };

    internal const string PlantedIpp = $"""
        printer-uri-supported uri ipp://{PlantedHost}:631/ipp/print
        printer-uri-supported uri ipps://[fe80::1c2b:3a4d:5e6f:7a8b]:631/ipp/print
        printer-uri-supported uri ipps://jdoe-printer.corp.lan:631/ipp/print
        printer-name name Jane Doe's LaserJet
        printer-info text Garcia family printer
        printer-location text Jane's office, second floor
        printer-dns-sd-name name HP LaserJet MFP M234dw [A1B2C3]
        printer-make-and-model text HP LaserJet MFP M234dw
        printer-device-id text MFG:HP;MDL:LaserJet MFP M234dw;CMD:PCL,PWG,URF;SN:{Serial};
        printer-uuid uri urn:uuid:{Uuid}
        printer-more-info uri http://HPF0A1B2.local/#hId-pgDevInfo
        printer-state enum 3
        printer-state-reasons keyword none
        printer-state-message text Ready. Last job from JDOE-LAPTOP (2a02:810d:4b3f:1200::12), contact jane.doe@contoso.com, MAC A0-B1-C2-D3-E4-F5
        job-originating-user-name name jdoe
        operations-supported enum 11
        """;

    internal static string PlantedWalk()
    {
        var walk = File.ReadAllText(Path.Combine(FixtureDir("snmp-demo"), "workgroup-laser.txt"));
        var keep = SnmpAgent.ParseWalk(walk).Where(o => !o.Name.ToString().StartsWith("1.3.6.1.2.1.1.", StringComparison.Ordinal)
                                                          && !o.Name.ToString().StartsWith("1.3.6.1.2.1.43.5.1.1.17.", StringComparison.Ordinal));
        return SnmpAgent.FormatWalk(keep) + $"""
            .1.3.6.1.2.1.1.1.0 = STRING: "HP LaserJet MFP M234dw, SN:{Serial}, at 10.20.30.41"
            .1.3.6.1.2.1.1.4.0 = STRING: "Jane Doe <jane.doe@contoso.com>"
            .1.3.6.1.2.1.1.5.0 = STRING: "NPI7A1B2C"
            .1.3.6.1.2.1.1.6.0 = STRING: "Jane's office, second floor"
            .1.3.6.1.2.1.43.5.1.1.17.1 = STRING: "{Serial}"
            .1.3.6.1.2.1.43.5.1.1.20.1 = STRING: "Jane Doe"
            .1.3.6.1.2.1.43.5.1.1.21.1 = STRING: "jane.doe@contoso.com"
            .1.3.6.1.2.1.25.3.2.1.6.1 = Hex-STRING: A0 B1 C2 D3 E4 F5
            """;
    }

    [Fact]
    public async Task Identifiers_planted_in_the_replies_dont_survive_a_recording()
    {
        var m234dw = FixtureDir("m234dw");
        FixtureHandler Printer() => new(name =>
            name == "ipp_print.ipp.txt" ? System.Text.Encoding.UTF8.GetBytes(PlantedIpp)
            : File.Exists(Path.Combine(m234dw, name)) ? System.Text.Encoding.UTF8.GetBytes(Plant(name, File.ReadAllText(Path.Combine(m234dw, name)))) : null);

        var result = await PrinterRecorder.RecordAsync(PlantedHost, _dir,
            new RecordOptions { Transport = At(PlantedHost, Printer()), Snmp = Agent(PlantedWalk()), Who = Me });

        Assert.Equal(["LEDM", "CDM", "eSCL", "IPP", "SNMP"], result.Interfaces);
        foreach (var file in Directory.GetFiles(_dir))
        {
            var text = File.ReadAllText(file);
            foreach (var planted in Planted)
                Assert.False(text.Contains(planted, StringComparison.OrdinalIgnoreCase), $"{planted} left in {Path.GetFileName(file)}");
        }

        // Still one printer, read as before: every interface's UUID is the one stand-in, LEDM's serial is SNMP's.
        const string host = FixtureScrubber.DefaultPlaceholderHost;
        using var c = await PrinterConnection.OpenAsync(host, transport: At(host, Serve(_dir)));
        Assert.Equal(["LEDM", "CDM", "eSCL", "IPP"], c.Probe.Interfaces);
        Assert.Single(c.Probe.ReportedUuids.OfType<string>().Select(u => u.Replace("urn:uuid:", "")).Distinct(StringComparer.OrdinalIgnoreCase));
        var snmp = await SnmpPrinterClient.ProbeAsync(Agent(File.ReadAllText(Path.Combine(_dir, PrinterRecorder.SnmpFile))), host);
        Assert.Equal(c.Probe.SerialNumber, snmp!.Identity.SerialNumber);
        using var original = await PrinterConnection.OpenAsync(PlantedHost, transport: At(PlantedHost, Printer()));
        Assert.Equal(JsonSerializer.Serialize(await original.ReadAsync()), JsonSerializer.Serialize(await c.ReadAsync()));
        // What a person typed says what it was.
        var ipp = File.ReadAllText(Path.Combine(_dir, "ipp_print.ipp.txt"));
        Assert.Contains("printer-location text Location", ipp);
        Assert.Contains("printer-name name Printer", ipp);
        Assert.Contains("job-originating-user-name name user", ipp);
        Assert.Contains($"printer-uri-supported uri ipp://{host}:631/ipp/print", ipp);
    }

    [Fact]
    public void The_scrubber_keeps_documentation_addresses_versions_and_models()
    {
        var s = new FixtureScrubber("192.0.2.10", who: Me);
        const string text = "Firmware 20230913 version 1.2.3.4, mask 255.255.255.0, at 192.0.2.10 and 198.51.100.7, HP LaserJet MFP M234dw, W1340A";
        Assert.Equal(text, s.Scrub("x.txt", text));
    }

    [Fact]
    public void IppText_reads_back_what_it_writes()
    {
        var values = IppText.Parse(File.ReadAllText(Path.Combine(FixtureDir("inkjet-demo"), "ipp_print.ipp.txt")));
        var again = IppText.Parse(IppText.FromResponse(IppCodec.EncodeResponse(0, 7, values)));
        Assert.Equal(values, again);
    }

    [Fact]
    public void A_walk_reads_back_what_it_writes()
    {
        var objects = SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(FixtureDir("snmp-demo"), "color-mfp.txt")));
        Assert.Equal(objects.OrderBy(o => o.Name), SnmpAgent.ParseWalk(SnmpAgent.FormatWalk(objects)));
    }

    private sealed class Spy(HttpMessageHandler inner, Action<HttpRequestMessage> seen) : DelegatingHandler(inner)
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            seen(request);
            return base.SendAsync(request, ct);
        }
    }
}
