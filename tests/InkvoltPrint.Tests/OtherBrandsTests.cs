using System.Xml.Linq;
using InkvoltPrint.Core.Discovery;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Tests;

/// <summary>
/// Canon, Epson, Brother and other IPP Everywhere / eSCL printers: status and supplies from IPP, scanning over eSCL.
/// The fixtures are written from the public specs (Fixtures/inkjet-demo), never captured from a device.
/// </summary>
public class OtherBrandsTests
{
    private static string InkjetFile(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo", name);

    private static IppResponse InkjetIpp() => IppCodec.Decode(IppCodec.EncodeResponse(0, 1, IppText.Parse(File.ReadAllText(InkjetFile("ipp_print.ipp.txt")))));

    private static IppResponse Ipp(string text) => IppCodec.Decode(IppCodec.EncodeResponse(0, 1, IppText.Parse(text)));

    // ------------------------------------------------------------------ IPP fixtures (text form)

    [Fact]
    public void IppText_round_trips_through_the_codec()
    {
        var r = Ipp("""
            # comment
            printer-state enum 4
            printer-is-accepting-jobs boolean true
            printer-state-reasons keyword media-low-report
            printer-state-reasons keyword toner-low-warning
            printer-make-and-model text Brother Example 0000
            """);

        Assert.True(r.Ok);
        Assert.Equal(4, r.Int("printer-state"));
        Assert.Equal([true], r.Attributes["printer-is-accepting-jobs"]);
        Assert.Equal(["media-low-report", "toner-low-warning"], r.Strs("printer-state-reasons"));
        Assert.Equal("Brother Example 0000", r.Str("printer-make-and-model"));
    }

    [Theory]
    [InlineData("printer-state enum three")]
    [InlineData("printer-state")]
    [InlineData("printer-state colour 3")]
    public void IppText_rejects_malformed_lines(string line) => Assert.Throws<FormatException>(() => IppText.Parse(line));

    [Fact]
    public void Ipp_request_header_is_read_for_the_fixture_server()
    {
        var req = IppCodec.EncodeGetPrinterAttributes("ipp://192.0.2.11:631/ipp/print", ["printer-state"], requestId: 7);
        Assert.Equal((IppCodec.GetPrinterAttributes, 7), IppCodec.ReadRequestHeader(req));
        Assert.Throws<FormatException>(() => IppCodec.ReadRequestHeader([1, 1]));
    }

    [Fact]
    public void OctetString_printer_alert_decodes_as_text() =>
        Assert.StartsWith("code=markerInkAlmostEmpty;", InkjetIpp().Strs("printer-alert").First());

    // ------------------------------------------------------------------ status

    [Fact]
    public void Inkjet_status_humanizes_reasons_and_uses_the_alert_description()
    {
        var s = IppClient.ToStatus(InkjetIpp());

        Assert.Equal("ready", s.Code);
        Assert.Equal("Ready", s.Message);
        var alert = Assert.Single(s.Alerts); // the low-ink reason and its printer-alert are one problem; a settings change isn't one
        Assert.Equal(("marker-supply-low", Severity.Warning, "Yellow ink is low."), (alert.Id, alert.Severity, alert.Message));
        Assert.Equal(Severity.Warning, s.Severity);
    }

    [Theory]
    [InlineData("media-empty-error", "media-empty", Severity.Error, "Out of paper")]
    [InlineData("media-jam-error", "media-jam", Severity.Error, "Paper jam")]
    [InlineData("toner-low", "toner-low", Severity.Warning, "Toner low")]        // no suffix: RFC says error, but "low" is a warning
    [InlineData("cover-open", "cover-open", Severity.Error, "A cover is open")]  // no suffix: error
    [InlineData("opc-near-eol-warning", "opc-near-eol", Severity.Warning, "Drum nearly worn out")]
    [InlineData("marker-waste-almost-full-warning", "marker-waste-almost-full", Severity.Warning, "Waste ink or toner box almost full")]
    [InlineData("com.example-vendor-thing-report", "com.example-vendor-thing", Severity.Info, "Com.example vendor thing")]
    public void Ipp_reasons(string reason, string id, Severity sev, string text)
    {
        var s = IppClient.ToStatus(Ipp($"printer-state enum 3\nprinter-state-reasons keyword {reason}"));
        var a = Assert.Single(s.Alerts);
        Assert.Equal((id, sev, text), (a.Id, a.Severity, a.Message));
    }

    [Fact]
    public void Placeholder_reasons_are_not_problems()
    {
        var s = IppClient.ToStatus(Ipp("printer-state enum 3\nprinter-state-reasons keyword none\nprinter-state-reasons keyword other-report"));
        Assert.Empty(s.Alerts);
        Assert.Equal(Severity.Info, s.Severity);
    }

    [Fact]
    public void Printer_alert_without_a_matching_reason_is_shown()
    {
        var s = IppClient.ToStatus(Ipp("""
            printer-state enum 5
            printer-state-reasons keyword none
            printer-alert octetString code=jam;index=1;severity=critical;group=mediaPath
            printer-alert octetString code=subunitLifeAlmostOver;severity=warning
            printer-alert octetString code=other;severity=other
            """));

        Assert.Equal("stopped", s.Code);
        Assert.Equal(["media-jam", "subunitLifeAlmostOver"], s.Alerts.Select(a => a.Id));
        Assert.Equal(["Paper jam", "Subunit life almost over"], s.Alerts.Select(a => a.Message));
        Assert.Equal([Severity.Error, Severity.Warning], s.Alerts.Select(a => a.Severity));
    }

    [Theory]
    [InlineData("code=coverOpen;severity=critical", "coverOpen", "critical")]
    [InlineData("severity=warning;code=markerTonerAlmostEmpty;index=2", "markerTonerAlmostEmpty", "warning")]
    [InlineData("index=2", null, null)]
    [InlineData("", null, null)]
    public void Printer_alert_values_parse(string value, string? code, string? severity)
    {
        var a = IppAlert.Parse(value);
        Assert.Equal((code, severity), (a?.Code, a?.Severity));
    }

    // ------------------------------------------------------------------ supplies

    [Fact]
    public void Inkjet_supplies_have_colors_kinds_and_a_maintenance_box()
    {
        var supplies = IppClient.ToConsumables(InkjetIpp());

        Assert.Equal(["Black ink", "Cyan ink", "Magenta ink", "Yellow ink", "Maintenance box"], supplies.Select(s => s.Name));
        Assert.Equal(["K", "C", "M", "Y", null], supplies.Select(s => s.ColorCode));
        Assert.Equal(["ink", "ink", "ink", "ink", "waste-ink"], supplies.Select(s => s.Kind));
        Assert.Equal([72, 55, 63, 12], supplies.Take(4).Select(s => s.PercentRemaining));
        Assert.Equal("low", supplies[3].State);
        Assert.True(supplies[3].IsLow);
        // A waste box's level runs the other way on some printers (how full vs. room left), so no percentage is shown.
        var box = supplies[4];
        Assert.Null(box.PercentRemaining);
        Assert.Equal("ok", box.State);
        Assert.True(box.IsWaste);
    }

    [Fact]
    public void Waste_box_state_comes_from_the_printer_state_reasons()
    {
        string Box(string reason) => IppClient.ToConsumables(Ipp($"""
            printer-state-reasons keyword {reason}
            marker-names name Waste toner
            marker-types keyword waste-toner
            marker-levels integer 40
            """))[0].State;

        Assert.Equal("almostFull", Box("marker-waste-almost-full-warning"));
        Assert.Equal("full", Box("marker-waste-full-error"));
        Assert.Equal("ok", Box("none"));
    }

    [Theory]
    [InlineData("#000000", "K")]
    [InlineData("#00ffff", "C")]
    [InlineData("#FF00FF", "M")]
    [InlineData("#FFFF00", "Y")]
    [InlineData("#808080", "#808080")]
    [InlineData("#00FFFF#FF00FF#FFFF00", "#00FFFF")] // a tri-color cartridge: its first color
    [InlineData("none", null)]
    [InlineData("#12", null)]
    [InlineData("red", null)]
    public void Marker_colors(string ipp, string? code) => Assert.Equal(code, IppClient.ColorCode(ipp));

    [Fact]
    public void Special_levels_mean_unknown_or_some_left()
    {
        var s = IppClient.ToConsumables(Ipp("""
            marker-names name Unknown
            marker-names name Some left
            marker-names name Empty
            marker-levels integer -2
            marker-levels integer -3
            marker-levels integer 0
            marker-types keyword toner
            """));

        Assert.Equal([("unknown", (int?)null), ("ok", null), ("out", 0)], s.Select(x => (x.State, x.PercentRemaining)));
        Assert.Equal(["toner", "supply", "supply"], s.Select(x => x.Kind)); // marker-types shorter than marker-names
    }

    // ------------------------------------------------------------------ brands and device info

    [Theory]
    [InlineData(PrinterBrand.Epson, "EPSON ET-0000 Series")]
    [InlineData(PrinterBrand.Epson, "Seiko Epson Example")]
    [InlineData(PrinterBrand.Canon, "Canon Example MF000")]
    [InlineData(PrinterBrand.Brother, "Brother Example-0000")]
    [InlineData(PrinterBrand.Hp, "HP LaserJet MFP M234dw")]
    [InlineData(PrinterBrand.Hp, "Hewlett-Packard Example")]
    [InlineData(PrinterBrand.Other, "Example Printer 9000")]
    [InlineData(PrinterBrand.Other, null)]
    [InlineData(PrinterBrand.Other, "SHPX 100")] // "HP" inside a word is not HP
    public void Brand_from_make_and_model(PrinterBrand brand, string? text) => Assert.Equal(brand, PrinterBrands.Detect(text));

    [Fact]
    public async Task Demo_inkjet_connects_over_IPP_and_eSCL()
    {
        using var conn = await PrinterConnection.OpenAsync("192.0.2.11", transport: InkjetTransport());
        var p = conn.Probe;

        Assert.Equal(["eSCL", "IPP"], p.Interfaces);
        Assert.Equal(PrinterBrand.Epson, p.Brand);
        Assert.False(p.HasHpInterfaces);
        Assert.Equal("EPSON ET-0000 Series", p.Model);
        Assert.Equal("2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b", p.Uuid);
        Assert.Equal("05.12.XA01", p.Firmware!.Display);
        Assert.Equal("Office, second floor", p.Location);
        Assert.Equal(new Uri("http://192.0.2.11/PRESENTATION/BONJOUR"), p.WebPage);
        Assert.Equal("Yellow ink is low.", Assert.Single((await conn.GetStatusAsync()).Alerts).Message);
        Assert.Equal(5, (await conn.GetSuppliesAsync()).Count);
        Assert.Equal([ScanSource.Platen, ScanSource.Adf, ScanSource.AdfDuplex], p.Scanner!.Sources);
    }

    [Fact]
    public async Task Printer_without_an_event_feed_is_read_right_away_not_after_the_first_interval()
    {
        using var conn = await PrinterConnection.OpenAsync("192.0.2.11", transport: InkjetTransport());
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await using var e = conn.WatchAsync(TimeSpan.FromMinutes(10), cts.Token).GetAsyncEnumerator(cts.Token);
        Assert.True(await e.MoveNextAsync());
    }

    [Theory]
    [InlineData("http://192.0.2.11/PRESENTATION/BONJOUR", "http://192.0.2.11/PRESENTATION/BONJOUR")]
    [InlineData("https://192.0.2.11:443/", "https://192.0.2.11/")]
    [InlineData("http://example.com/phish", null)]   // another host: not the printer's page
    [InlineData("file:///C:/Windows", null)]
    [InlineData("javascript:alert(1)", null)]
    public void Web_page_must_be_on_the_printer(string moreInfo, string? expected)
    {
        var p = new ProbeResult("192.0.2.11", null, null, null, null, Ipp($"printer-more-info uri {moreInfo}"));
        Assert.Equal(expected, p.WebPage?.AbsoluteUri);
    }

    [Fact]
    public void Printer_icons_on_the_printer_only_128_px_first()
    {
        var p = new ProbeResult("192.0.2.11", null, null, null, null, Ipp("""
            printer-icons uri https://192.0.2.11/icon-48.png
            printer-icons uri https://192.0.2.11/icon-128.png
            printer-icons uri http://example.com/icon-512.png
            printer-icons uri https://192.0.2.11/icon-512.png
            """));
        Assert.Equal(["/icon-128.png", "/icon-512.png", "/icon-48.png"], p.Icons.Select(u => u.AbsolutePath));
    }

    [Fact]
    public async Task Ipp_endpoint_hint_from_DNS_SD_is_tried_first()
    {
        var seen = new List<string>();
        var handler = new FixtureHandler(name =>
        {
            if (name.EndsWith(".ipp.txt", StringComparison.Ordinal)) seen.Add(name);
            return name == "ipp_printer.ipp.txt" ? File.ReadAllBytes(InkjetFile("ipp_print.ipp.txt")) : null;
        });
        using var conn = await PrinterConnection.OpenAsync("192.0.2.11", transport: handler, ippHint: new Uri("http://192.0.2.11:631/ipp/printer"));

        Assert.NotNull(conn.Ipp);
        Assert.Equal("/ipp/printer", conn.Ipp!.Endpoint.AbsolutePath);
        Assert.Equal("ipp_printer.ipp.txt", seen[0]);
    }

    // ------------------------------------------------------------------ eSCL

    private static ScannerCapabilities InkjetCaps() => ScannerCapabilities.Parse(XDocument.Load(InkjetFile("eSCL_ScannerCapabilities.xml")));

    [Fact]
    public void Feeder_profile_reference_and_resolution_range_are_resolved()
    {
        var c = InkjetCaps();

        Assert.Equal("EPSON", c.Manufacturer);
        Assert.Equal([100, 200, 300, 600, 1200], c.Platen!.Resolutions);
        Assert.Equal([75, 100, 150, 200, 300, 400, 600], c.Adf!.Resolutions);       // 75-600 step 25: the usual values in it
        Assert.Equal(["BlackAndWhite1", "Grayscale8", "RGB24"], c.Adf.ColorModes);   // from the named profile
        Assert.Contains("image/jpeg", c.Adf.DocumentFormats);
        Assert.True(c.AdfDuplex);
        Assert.True(c.Adf.HasDocumentFormatExt);
    }

    [Theory]
    [InlineData(100, 300, 0, 300, new[] { 100, 150, 200, 300 })]
    [InlineData(75, 1200, 1, 300, new[] { 75, 100, 150, 200, 300, 400, 600, 1200 })]
    [InlineData(150, 600, 150, 300, new[] { 150, 300, 600 })]         // only usual values the step reaches
    [InlineData(110, 130, 7, 117, new[] { 110, 117, 124 })]           // nothing usual fits: the step values
    [InlineData(101, 999, 1, 333, new[] { 150, 200, 300, 400, 600 })]
    [InlineData(101, 199, 3, 150, new[] { 101, 104, 107, 110, 113, 116, 119, 122 })] // many step values: the first eight
    public void Resolution_ranges(int min, int max, int step, int normal, int[] expected) =>
        Assert.Equal(expected, ScannerCapabilities.RangeResolutions(min, max, step, normal));

    [Fact]
    public void Discrete_resolutions_with_unequal_x_and_y_are_left_out()
    {
        var c = Caps("""
            <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile>
              <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
              <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></scan:DocumentFormats>
              <scan:SupportedResolutions><scan:DiscreteResolutions>
                <scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
                <scan:DiscreteResolution><scan:XResolution>600</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
              </scan:DiscreteResolutions></scan:SupportedResolutions>
            </scan:SettingProfile></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
            """);

        Assert.Equal([300], c.Platen!.Resolutions);
        Assert.False(c.Platen.HasDocumentFormatExt); // only pwg:DocumentFormat listed
    }

    [Fact]
    public void Unknown_profile_reference_is_ignored_not_fatal()
    {
        var c = Caps("""
            <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile ref="missing" /></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
            """);
        Assert.Empty(c.Platen!.Resolutions);
    }

    [Fact]
    public void ScanSettings_leave_out_DocumentFormatExt_when_the_scanner_never_lists_it()
    {
        var c = Caps("""
            <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile>
              <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></scan:DocumentFormats>
            </scan:SettingProfile></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
            """);
        var s = EsclXml.BuildScanSettings(new ScanRequest(), c).Root!;
        Assert.NotNull(s.Element(EsclXml.Pwg + "DocumentFormat"));
        Assert.Null(s.Element(EsclXml.Scan + "DocumentFormatExt"));
    }

    [Fact]
    public void ScanSettings_for_the_two_sided_feeder_with_an_intent_the_feeder_lacks()
    {
        var s = EsclXml.BuildScanSettings(new ScanRequest(ScanSource.AdfDuplex, Resolution: 300), InkjetCaps()).Root!;

        Assert.Equal("Feeder", s.Element(EsclXml.Pwg + "InputSource")!.Value);
        Assert.Equal("true", s.Element(EsclXml.Scan + "Duplex")!.Value);
        Assert.Equal("TextAndGraphic", s.Element(EsclXml.Scan + "Intent")!.Value); // "Document" isn't offered by this feeder
        Assert.Equal("300", s.Element(EsclXml.Scan + "XResolution")!.Value);
        Assert.Equal("4200", s.Element(EsclXml.Pwg + "ScanRegions")!.Elements().First().Element(EsclXml.Pwg + "Height")!.Value);
    }

    [Fact]
    public void Jpeg_is_required()
    {
        var c = Caps("""
            <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile>
              <scan:DocumentFormats><pwg:DocumentFormat>application/pdf</pwg:DocumentFormat></scan:DocumentFormats>
            </scan:SettingProfile></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
            """);
        Assert.False(c.Platen!.OffersJpeg);
        Assert.True(InkjetCaps().Platen!.OffersJpeg);
    }

    [Theory]
    [InlineData("EPSON ET-0000 Series", null, true, false)]
    [InlineData("Example", "EPSON", true, false)]
    [InlineData("Brother Example-0000", null, false, true)]
    [InlineData("Canon Example", "Canon", false, false)]
    [InlineData("HP LaserJet MFP M234dw", "HP", false, false)]
    public void Scanner_quirks(string model, string? manufacturer, bool portInHost, bool nextLoadDelay)
    {
        var q = EsclQuirks.For(new ScannerCapabilities("2.6", model, null, null, null, false) { Manufacturer = manufacturer });
        Assert.Equal((portInHost, nextLoadDelay), (q.PortInHost, q.NextLoadDelay));
    }

    [Theory]
    [InlineData(500, 250)]
    [InlineData(5000, 1000)]
    [InlineData(0, 0)]
    public void Brother_feeder_waits_before_the_next_page(int lastLoadMs, int waitMs) =>
        Assert.Equal(TimeSpan.FromMilliseconds(waitMs), EsclQuirks.NextLoadWait(TimeSpan.FromMilliseconds(lastLoadMs)));

    [Theory]
    [InlineData("Idle", "ScannerAdfLoaded", true, null)]
    [InlineData("Idle", "ScannerAdfEmpty", true, "Load the pages into the document feeder first.")]
    [InlineData("Idle", "ScannerAdfJam", true, "The document feeder is jammed. Clear the paper and try again.")]
    [InlineData("Idle", "ScannerAdfDoorOpen", true, "The document feeder's cover is open. Close it and try again.")]
    [InlineData("Idle", "ScannerAdfHatchOpen", true, "The document feeder's cover is open. Close it and try again.")]
    [InlineData("Idle", "ScannerAdfMispick", true, "The document feeder couldn't pick up a page. Straighten the stack and try again.")]
    [InlineData("Idle", "ScannerAdfJam", false, null)]          // glass scans ignore the feeder
    [InlineData("Idle", null, true, null)]                      // no feeder state reported: just try
    [InlineData("Testing", null, false, null)]                  // warming up: the job request waits for it
    [InlineData("Processing", null, false, null)]
    [InlineData("Stopped", null, false, "Scanner is stopped.")]
    [InlineData("Down", null, false, "Scanner is down.")]
    public void Scanner_status_problems(string state, string? adf, bool feeder, string? problem)
    {
        var xml = $"""
            <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:State>{state}</pwg:State>{(adf is null ? "" : $"<scan:AdfState>{adf}</scan:AdfState>")}
            </scan:ScannerStatus>
            """;
        Assert.Equal(problem, ScannerStatus.Parse(XDocument.Parse(xml)).Problem(feeder));
    }

    [Fact]
    public async Task Epson_scanner_gets_the_port_in_the_Host_header()
    {
        var hosts = new List<string?>();
        var inner = new FixtureHandler(name => File.Exists(InkjetFile(name)) ? File.ReadAllBytes(InkjetFile(name)) : null, () => [0xFF, 0xD8, 0xFF, 0xD9]);
        using var http = new DeviceHttp("192.0.2.11", new Spy(inner, r => hosts.Add(r.Headers.Host)));
        var client = new EsclClient(http, http.Http("/eSCL/"));

        await foreach (var _ in client.ScanAsync(new ScanRequest())) { }

        Assert.Null(hosts[0]); // ScannerCapabilities: the scanner isn't known to be an Epson yet
        Assert.True(hosts.Count > 3);
        Assert.All(hosts.Skip(1), h => Assert.Equal("192.0.2.11:80", h));
    }

    // ------------------------------------------------------------------ DNS-SD join

    private static DnssdService Svc(string service, string? uuid, string? hostName, string? ip, int? port = null, params (string, string)[] txt) =>
        new(service, uuid, hostName, ip, port, txt.ToDictionary(t => t.Item1, t => t.Item2, StringComparer.OrdinalIgnoreCase));

    [Fact]
    public void Services_join_on_uuid_and_a_service_without_one_joins_its_host()
    {
        var ipp = Svc("_ipp._tcp", "{2F1E6C3A-5B7D-4E8F-9A0B-1C2D3E4F5A6B}", "Example-0000.local", "192.0.2.11");
        var scan = Svc("_uscan._tcp", null, "Example-0000.local", "192.0.2.11");
        var lone = Svc("_ipp._tcp", null, "Other.local", "192.0.2.12");
        var none = Svc("_ipp._tcp", "not-a-uuid", null, null);
        var all = new[] { ipp, scan, lone, none };

        Assert.Equal("2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b", DnssdJoin.Key(ipp, all));
        Assert.Equal("2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b", DnssdJoin.Key(scan, all));
        Assert.Null(DnssdJoin.Key(lone, all)); // no UUID anywhere on its host: not joined (add it by address)
        Assert.Null(DnssdJoin.Key(none, all));
    }

    [Theory]
    [InlineData("_ipp._tcp", 631, "ipp/print", "http://192.0.2.11:631/ipp/print")]
    [InlineData("_ipps._tcp", 631, "ipp/print", "https://192.0.2.11:631/ipp/print")]
    [InlineData("_ipp._tcp", 8631, "/ipp/printer/", "http://192.0.2.11:8631/ipp/printer")]
    [InlineData("_ipp._tcp", null, null, "http://192.0.2.11:631/ipp/print")]
    [InlineData("_ipp._tcp", 631, "", "http://192.0.2.11:631/")]
    [InlineData("_ipp._tcp", 631, "../../x?y#z", null)]
    public void Ipp_endpoint_from_TXT_rp(string service, int? port, string? rp, string? expected)
    {
        var s = rp is null ? Svc(service, null, null, "192.0.2.11", port) : Svc(service, null, null, "192.0.2.11", port, ("rp", rp));
        Assert.Equal(expected, DnssdJoin.IppUri(s, "192.0.2.11")?.AbsoluteUri);
    }

    [Theory]
    [InlineData("_uscan._tcp", 80, "eSCL", "http://192.0.2.11/eSCL/")]
    [InlineData("_uscans._tcp", 443, "/eSCL", "https://192.0.2.11/eSCL/")]
    [InlineData("_uscan._tcp", 8080, null, "http://192.0.2.11:8080/eSCL/")]
    [InlineData("_uscan._tcp", 80, "", "http://192.0.2.11/")]
    public void Escl_root_from_TXT_rs(string service, int? port, string? rs, string expected)
    {
        var s = rs is null ? Svc(service, null, null, "192.0.2.11", port) : Svc(service, null, null, "192.0.2.11", port, ("rs", rs));
        Assert.Equal(expected, DnssdJoin.EsclRoot(s, "192.0.2.11")?.AbsoluteUri);
    }

    // ------------------------------------------------------------------ demo transport

    private static HttpMessageHandler InkjetTransport() =>
        new FixtureHandler(name => File.Exists(InkjetFile(name)) ? File.ReadAllBytes(InkjetFile(name)) : null, () => [0xFF, 0xD8, 0xFF, 0xD9]);

    [Fact]
    public async Task Host_router_sends_each_demo_printer_to_its_own_fixtures()
    {
        static HostRouter Router() => new(new Dictionary<string, HttpMessageHandler>
        {
            [FixtureHandler.DemoHost] = new FixtureHandler(name =>
            {
                var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name);
                return File.Exists(path) ? File.ReadAllBytes(path) : null;
            }),
            ["192.0.2.11"] = InkjetTransport(),
        });

        using (var a = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: Router()))
            Assert.Equal(PrinterBrand.Hp, a.Probe.Brand);
        using (var b = await PrinterConnection.OpenAsync("192.0.2.11", transport: Router()))
            Assert.Equal(PrinterBrand.Epson, b.Probe.Brand);
        using var c = await PrinterConnection.OpenAsync("192.0.2.99", transport: Router());
        Assert.False(c.Probe.Reachable);
    }

    private static ScannerCapabilities Caps(string inner) => ScannerCapabilities.Parse(XDocument.Parse($"""
        <scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.6</pwg:Version>{inner}
        </scan:ScannerCapabilities>
        """));

    private sealed class Spy(HttpMessageHandler inner, Action<HttpRequestMessage> seen) : DelegatingHandler(inner)
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            seen(request);
            return base.SendAsync(request, ct);
        }
    }
}
