using System.Net;
using System.Text;
using System.Xml.Linq;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Maintenance;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Tests;

/// <summary>
/// Printer maintenance: what a printer offers (HP LEDM internal pages and alignment, IPP Identify-Printer, the supply page)
/// and the exact requests sent. Every request goes to a recording fake; nothing reaches a network. The HP documents below
/// are written by hand from public sources (HPLIP's base/maint.py, published LEDM dumps), never captured from a device.
/// </summary>
public class MaintenanceTests
{
    private const string Host = "192.0.2.10", InkjetHost = "192.0.2.11";

    // ------------------------------------------------------------------ request bodies

    [Fact]
    public void Internal_print_body_is_the_ledm_InternalPrintDyn_document() =>
        Assert.Equal(
            """<?xml version="1.0" encoding="UTF-8"?><ipdyn:InternalPrintDyn xmlns:ipdyn="http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21"><ipdyn:JobType>configurationPage</ipdyn:JobType></ipdyn:InternalPrintDyn>""",
            MaintenanceRequests.InternalPrint("configurationPage"));

    [Fact]
    public void Internal_print_refuses_job_types_outside_the_catalog() =>
        Assert.Throws<ArgumentException>(() => MaintenanceRequests.InternalPrint("demoPage</ipdyn:JobType><x>"));

    [Fact]
    public void Alignment_body_asks_the_calibration_session_to_print() =>
        Assert.Equal(
            """<?xml version="1.0" encoding="UTF-8"?><cal:CalibrationState xmlns:cal="http://www.hp.com/schemas/imaging/con/cnx/markingagentcalibration/2009/04/08">Printing</cal:CalibrationState>""",
            MaintenanceRequests.StartAlignment());

    [Fact]
    public void Identify_printer_request_is_encoded_byte_for_byte()
    {
        var expected = new List<byte> { 2, 0, 0x00, 0x3C, 0, 0, 0, 3, 0x01 };
        expected.AddRange(Attr(0x47, "attributes-charset", "utf-8"));
        expected.AddRange(Attr(0x48, "attributes-natural-language", "en"));
        expected.AddRange(Attr(0x45, "printer-uri", "ipp://192.0.2.11:631/ipp/print"));
        expected.AddRange(Attr(0x42, "requesting-user-name", "alex"));
        expected.AddRange(Attr(0x44, "identify-actions", "flash"));
        expected.AddRange(Attr(0x44, "", "sound"));
        expected.Add(0x03);

        var body = IppCodec.EncodeIdentifyPrinter("ipp://192.0.2.11:631/ipp/print", "alex", ["flash", "sound"], requestId: 3);

        Assert.Equal(expected.ToArray(), body);
        Assert.Equal((IppCodec.IdentifyPrinter, 3), IppCodec.ReadRequestHeader(body));
    }

    [Fact]
    public void Identify_printer_without_actions_or_user_leaves_them_out()
    {
        var expected = new List<byte> { 2, 0, 0x00, 0x3C, 0, 0, 0, 1, 0x01 };
        expected.AddRange(Attr(0x47, "attributes-charset", "utf-8"));
        expected.AddRange(Attr(0x48, "attributes-natural-language", "en"));
        expected.AddRange(Attr(0x45, "printer-uri", "ipp://192.0.2.11:631/ipp/print"));
        expected.Add(0x03);
        Assert.Equal(expected.ToArray(), IppCodec.EncodeIdentifyPrinter("ipp://192.0.2.11:631/ipp/print", null, []));
    }

    private static byte[] Attr(byte tag, string name, string value)
    {
        var n = Encoding.UTF8.GetBytes(name);
        var v = Encoding.UTF8.GetBytes(value);
        return [tag, (byte)(n.Length >> 8), (byte)n.Length, .. n, (byte)(v.Length >> 8), (byte)v.Length, .. v];
    }

    // ------------------------------------------------------------------ parsing what the printer advertises

    private const string InkjetCap = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ipcap:InternalPrintCap xmlns:ipcap="http://www.hp.com/schemas/imaging/con/ledm/internalprintcap/2008/03/21"
                                xmlns:ipdyn="http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21">
          <ipdyn:JobType>cleaningPage</ipdyn:JobType>
          <ipdyn:JobType>cleaningPageLevel1</ipdyn:JobType>
          <ipdyn:JobType>cleaningPageLevel2</ipdyn:JobType>
          <ipdyn:JobType>cleaningVerificationPage</ipdyn:JobType>
          <ipdyn:JobType>pqDiagnosticsPage</ipdyn:JobType>
          <ipdyn:JobType>configurationPage</ipdyn:JobType>
          <ipdyn:JobType>demoPage</ipdyn:JobType>
          <ipdyn:JobType>  configurationPage </ipdyn:JobType>
        </ipcap:InternalPrintCap>
        """;

    [Fact]
    public void Job_types_are_read_from_InternalPrintCap_in_any_spelling()
    {
        Assert.Equal(["cleaningPage", "cleaningPageLevel1", "cleaningPageLevel2", "cleaningVerificationPage", "pqDiagnosticsPage", "configurationPage", "demoPage"],
            MaintenanceRequests.ParseJobTypes(XDocument.Parse(InkjetCap)));
        Assert.Equal(["cleaningPage", "networkSummary"], MaintenanceRequests.ParseJobTypes(XDocument.Parse(
            "<InternalPrintCap><jobType>cleaningPage</jobType><x:InternalPrintJobType xmlns:x=\"urn:x\">networkSummary</x:InternalPrintJobType><Other>configurationPage</Other></InternalPrintCap>")));
    }

    private const string InkjetConsumables = """
        <ccdyn:ConsumableConfigDyn xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:ccdyn="http://www.hp.com/schemas/imaging/con/ledm/consumableconfigdyn/2007/11/19">
          <ccdyn:ProductConsumableInfo><dd:AlignmentMode>semiAutomatic</dd:AlignmentMode></ccdyn:ProductConsumableInfo>
          <ccdyn:ConsumableInfo><dd:ConsumableTypeEnum>ink</dd:ConsumableTypeEnum></ccdyn:ConsumableInfo>
        </ccdyn:ConsumableConfigDyn>
        """;

    [Fact]
    public void Alignment_mode_and_marking_come_from_ConsumableConfigDyn()
    {
        Assert.Equal("semiAutomatic", MaintenanceRequests.ParseAlignmentMode(XDocument.Parse(InkjetConsumables)));
        Assert.Equal(Marking.Ink, MaintenanceRequests.ParseMarking(XDocument.Parse(InkjetConsumables)));
        // The M234dw (a laser) reports toner and no alignment mode.
        Assert.Null(MaintenanceRequests.ParseAlignmentMode(Fixture.Xml("DevMgmt_ConsumableConfigDyn.xml")));
        Assert.Equal(Marking.Toner, MaintenanceRequests.ParseMarking(Fixture.Xml("DevMgmt_ConsumableConfigDyn.xml")));
    }

    [Theory]
    [InlineData("<cal:CalibrationState xmlns:cal=\"urn:cal\">Printing</cal:CalibrationState>", CalibrationStatus.Running)]
    [InlineData("<State><CalibrationState>Scanning</CalibrationState></State>", CalibrationStatus.Running)]
    [InlineData("<cal:CalibrationState xmlns:cal=\"urn:cal\">ParmsRequested</cal:CalibrationState>", CalibrationStatus.AwaitingParameters)]
    [InlineData("<State><ParmsRequested/></State>", CalibrationStatus.AwaitingParameters)]
    [InlineData("<cal:CalibrationState xmlns:cal=\"urn:cal\">CalibrationValid</cal:CalibrationState>", CalibrationStatus.Idle)]
    [InlineData("<cal:CalibrationState xmlns:cal=\"urn:cal\">CalibrationRequired</cal:CalibrationState>", CalibrationStatus.Idle)]
    public void The_calibration_state_says_whether_an_alignment_can_start(string xml, CalibrationStatus expected) =>
        Assert.Equal(expected, MaintenanceRequests.ReadCalibration(XDocument.Parse(xml)));

    // ------------------------------------------------------------------ the catalog: only what the printer advertises

    private static MaintenanceSources Hp(IReadOnlyList<string>? jobs, string? alignment = null, Marking marking = Marking.Ink) => new()
    {
        Host = Host,
        HasLedm = true,
        LedmJobTypes = jobs,
        LedmDynPath = "/DevMgmt/InternalPrintDyn.xml",
        AlignmentMode = alignment,
        Marking = marking,
    };

    [Fact]
    public void Hp_actions_follow_the_advertised_job_types_in_a_fixed_order()
    {
        var options = MaintenanceCatalog.Detect(Hp(MaintenanceRequests.ParseJobTypes(XDocument.Parse(InkjetCap))));

        Assert.Equal(
            ["ledm:configurationPage", "ledm:pqDiagnosticsPage", "ledm:cleaningPage", "ledm:cleaningPageLevel1", "ledm:cleaningPageLevel2", "ledm:cleaningVerificationPage"],
            options.Actions.Select(a => a.Id));
        Assert.All(options.Actions, a => Assert.Equal("HP", a.Brand));
        Assert.All(options.Actions, a => Assert.Equal("/DevMgmt/InternalPrintDyn.xml", a.Target));
        Assert.DoesNotContain(options.Actions, a => a.JobType == "demoPage"); // not maintenance: never offered
        var cleaning = options.Actions.Where(a => a.Kind == MaintenanceKind.Cleaning).ToList();
        Assert.Equal([1, 2, 3], cleaning.Select(a => a.Level));
        Assert.Equal("Clean printhead (HP)", cleaning[0].Label);
        Assert.Equal("Clean printhead, level 2 (HP)", cleaning[1].Label);
        Assert.Contains("more ink", cleaning[1].Uses);
        Assert.All(options.Actions, a => Assert.True(a.PrintsPage));
        Assert.Contains("plain paper", options.Actions[0].Uses);
    }

    [Fact]
    public void Cleaning_levels_are_ranked_whatever_the_firmware_calls_them()
    {
        var options = MaintenanceCatalog.Detect(Hp(["cleaningPageLevel3", "cleaningPage", "cleaningPageLevel2"]));
        Assert.Equal(["cleaningPage", "cleaningPageLevel2", "cleaningPageLevel3"], options.Actions.Select(a => a.JobType));
        Assert.Equal([1, 2, 3], options.Actions.Select(a => a.Level));
    }

    [Fact]
    public void A_toner_printer_gets_toner_wording_and_no_ink_only_actions()
    {
        var options = MaintenanceCatalog.Detect(Hp(["configurationPage", "cleaningPage", "ribSmearCleaningPage"], marking: Marking.Toner));
        Assert.Equal(["ledm:configurationPage", "ledm:cleaningPage"], options.Actions.Select(a => a.Id));
        Assert.Equal("Print cleaning page (HP)", options.Actions[1].Label);
        Assert.Contains("toner", options.Actions[1].Uses);
        Assert.DoesNotContain("ink", options.Actions[1].Uses);
    }

    [Theory]
    [InlineData("automatic", null)]
    [InlineData("semiAutomatic", null)]
    [InlineData("manual", "control panel")]
    public void Alignment_is_offered_when_the_calibration_interface_and_a_mode_are_there(string mode, string? reason)
    {
        var align = Assert.Single(MaintenanceCatalog.Detect(Hp(null, mode)).Actions);
        Assert.Equal(MaintenanceKind.Alignment, align.Kind);
        Assert.Equal("Align printhead (HP)", align.Label);
        Assert.Equal(MaintenanceRequests.CalibrationSessionPath, align.Target);
        if (reason is null) Assert.Null(align.Unavailable);
        else Assert.Contains(reason, align.Unavailable);
        if (mode == "semiAutomatic") Assert.Contains("scanner glass", align.Uses);
    }

    [Fact]
    public void An_hp_printer_without_maintenance_interfaces_gets_no_actions_and_says_why()
    {
        var options = MaintenanceCatalog.Detect(Hp(null) with { LedmDynPath = null });
        Assert.Empty(options.Actions);
        Assert.Contains("web page", options.Note);
    }

    private static IppResponse Ipp(string text) => IppCodec.Decode(IppCodec.EncodeResponse(0, 1, IppText.Parse(text)));

    [Fact]
    public void Identify_is_offered_only_when_operations_supported_lists_it()
    {
        var with = MaintenanceCatalog.Detect(new MaintenanceSources
        {
            Host = InkjetHost,
            Ipp = Ipp("""
                operations-supported enum 11
                operations-supported enum 60
                identify-actions-supported keyword flash
                identify-actions-supported keyword speak
                identify-actions-supported keyword sound
                printer-supply-info-uri uri http://192.0.2.11/supplies
                """),
        });
        var identify = Assert.Single(with.Actions);
        Assert.Equal(MaintenanceKind.Identify, identify.Kind);
        Assert.Null(identify.Brand); // standard IPP, not one maker's
        Assert.Equal(["flash", "sound"], identify.IdentifyActions); // what Inkvolt Print asks for, in its order
        Assert.False(identify.PrintsPage);
        Assert.Contains("flashes its lights and makes a sound", identify.Uses);
        Assert.Equal("Lights and sound · no paper or ink", identify.Summary);
        Assert.Equal(new Uri("http://192.0.2.11/supplies"), with.SupplyPage);
        Assert.Contains("aren't part of the IPP printing standard", with.Note);

        var without = MaintenanceCatalog.Detect(new MaintenanceSources { Host = InkjetHost, Ipp = Ipp("operations-supported enum 11") });
        Assert.Empty(without.Actions);
    }

    [Fact]
    public void Identify_with_no_known_action_lets_the_printer_choose()
    {
        var identify = Assert.Single(MaintenanceCatalog.Detect(new MaintenanceSources
        {
            Host = InkjetHost,
            Ipp = Ipp("operations-supported enum 60\nidentify-actions-supported keyword speak"),
        }).Actions);
        Assert.Empty(identify.IdentifyActions);
    }

    [Theory]
    [InlineData("http://192.0.2.99/supplies")] // another host: never followed
    [InlineData("ftp://192.0.2.11/supplies")]
    [InlineData("http://user@192.0.2.11/supplies")]
    public void The_supply_page_must_be_on_the_printer_itself(string uri) =>
        Assert.Null(MaintenanceCatalog.Detect(new MaintenanceSources { Host = InkjetHost, Ipp = Ipp($"printer-supply-info-uri uri {uri}") }).SupplyPage);

    // ------------------------------------------------------------------ when an action can run

    private static readonly MaintenanceAction Config = MaintenanceCatalog.Detect(Hp(["configurationPage"])).Actions[0];
    private static readonly MaintenanceAction Identify =
        MaintenanceCatalog.Detect(new MaintenanceSources { Host = InkjetHost, Ipp = Ipp("operations-supported enum 60") }).Actions[0];

    private static PrinterStatus Status(string code, Severity severity, string message = "Ready") => new(code, message, severity, []);

    [Fact]
    public void Actions_wait_for_an_online_idle_printer_with_reasons()
    {
        Assert.Null(MaintenanceAvailability.WhyNot(Config, online: true, Status("ready", Severity.Info), busy: false));
        Assert.Null(MaintenanceAvailability.WhyNot(Config, online: true, Status("lowToner", Severity.Warning), busy: false));
        Assert.Contains("isn't answering", MaintenanceAvailability.WhyNot(Config, online: false, null, busy: false));
        Assert.Contains("Waiting", MaintenanceAvailability.WhyNot(Config, online: true, Status("ready", Severity.Info), busy: true));
        Assert.Contains("Paper jam", MaintenanceAvailability.WhyNot(Config, online: true, Status("jam", Severity.Error, "Paper jam"), busy: false));
        Assert.Contains("printing", MaintenanceAvailability.WhyNot(Config, online: true, Status("processing", Severity.Info, "Printing"), busy: false));
        Assert.Contains("Updating firmware", MaintenanceAvailability.WhyNot(Config, online: true, Status("upgrading", Severity.Info, "Updating firmware"), busy: false));
        // Identify prints nothing: a jam or a job doesn't stop it.
        Assert.Null(MaintenanceAvailability.WhyNot(Identify, online: true, Status("jam", Severity.Error, "Paper jam"), busy: false));
        Assert.Null(MaintenanceAvailability.WhyNot(Identify, online: true, Status("processing", Severity.Info), busy: false));
        var manual = MaintenanceCatalog.Detect(Hp(null, "manual")).Actions[0];
        Assert.Equal(manual.Unavailable, MaintenanceAvailability.WhyNot(manual, online: true, Status("ready", Severity.Info), busy: false));
    }

    [Fact]
    public void Each_action_asks_first_and_says_what_it_uses()
    {
        foreach (var a in MaintenanceCatalog.Detect(Hp(["configurationPage", "pqDiagnosticsPage", "cleaningPage", "networkSummary"], "automatic")).Actions.Append(Identify))
        {
            Assert.Contains(a.Uses, a.ConfirmText);
            Assert.False(string.IsNullOrWhiteSpace(a.ConfirmButton));
            Assert.False(string.IsNullOrWhiteSpace(a.Summary));
            Assert.False(string.IsNullOrWhiteSpace(a.Sent));
        }
    }

    // ------------------------------------------------------------------ the client against recording fakes

    private sealed record Sent(HttpMethod Method, Uri Uri, string? ContentType, byte[] Body, HttpRequestMessage Request);

    /// <summary>Answers from <paramref name="respond"/> and records every request; never opens a socket.</summary>
    private sealed class Recorder(Func<Sent, HttpResponseMessage?> respond, HttpMessageHandler? inner = null) : DelegatingHandler(inner ?? new NotFound())
    {
        public List<Sent> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct);
            var sent = new Sent(request.Method, request.RequestUri!, request.Content?.Headers.ContentType?.MediaType, body, request);
            Requests.Add(sent);
            if (respond(sent) is { } r) { r.RequestMessage = request; return r; }
            if (request.Content is not null) request.Content = new ByteArrayContent(body) { Headers = { ContentType = request.Content.Headers.ContentType } };
            return await base.SendAsync(request, ct);
        }

        private sealed class NotFound : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
                Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound) { RequestMessage = request });
        }
    }

    private static HttpResponseMessage Xml(string xml) => new(HttpStatusCode.OK) { Content = new StringContent(xml, Encoding.UTF8, "text/xml") };

    private static string M234dw(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name);
    private static string Inkjet(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo", name);

    private static FixtureHandler M234dwPrinter() => new(n => File.Exists(M234dw(n)) ? File.ReadAllBytes(M234dw(n)) : null);
    private static FixtureHandler InkjetPrinter() => new(n => File.Exists(Inkjet(n)) ? File.ReadAllBytes(Inkjet(n)) : null);

    private static bool IsGetPrinterAttributes(Sent s) =>
        s.ContentType == "application/ipp" && IppCodec.ReadRequestHeader(s.Body).Operation == IppCodec.GetPrinterAttributes;

    [Fact]
    public async Task Detecting_on_the_M234dw_only_reads_and_finds_nothing_to_offer()
    {
        var recorder = new Recorder(_ => null, M234dwPrinter());
        using var conn = await PrinterConnection.OpenAsync(Host, transport: recorder);
        var before = recorder.Requests.Count;

        var options = await new MaintenanceClient(conn).DetectAsync();

        Assert.Empty(options.Actions); // the real M234dw answers 404 for InternalPrintCap and lists no calibration interface
        Assert.Contains("web page", options.Note);
        var detection = recorder.Requests.Skip(before).ToList();
        Assert.NotEmpty(detection);
        Assert.All(detection, s => Assert.True(s.Method == HttpMethod.Get || IsGetPrinterAttributes(s), $"{s.Method} {s.Uri}"));
        Assert.Contains(detection, s => s.Uri.AbsolutePath == MaintenanceRequests.InternalPrintCapPath);
    }

    [Fact]
    public async Task Detecting_on_the_demo_inkjet_finds_identify_and_the_supply_page_by_reading_only()
    {
        var recorder = new Recorder(_ => null, InkjetPrinter());
        using var conn = await PrinterConnection.OpenAsync(InkjetHost, transport: recorder);
        var before = recorder.Requests.Count;

        var options = await new MaintenanceClient(conn).DetectAsync();

        Assert.Equal([MaintenanceKind.Identify], options.Actions.Select(a => a.Kind));
        Assert.NotNull(options.SupplyPage);
        Assert.All(recorder.Requests.Skip(before), s => Assert.True(s.Method == HttpMethod.Get || IsGetPrinterAttributes(s), $"{s.Method} {s.Uri}"));
    }

    private const string TreeWithMaintenance = """
        <ledm:DiscoveryTree xmlns:ledm="http://www.hp.com/schemas/imaging/con/ledm/2007/09/21" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
          <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ProductStatusDyn.xml</dd:ResourceURI><dd:ResourceType>ledm:hpLedmProductStatusDyn</dd:ResourceType></ledm:SupportedTree>
          <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ConsumableConfigDyn.xml</dd:ResourceURI><dd:ResourceType>ledm:hpLedmConsumableConfigDyn</dd:ResourceType></ledm:SupportedTree>
          <ledm:SupportedIfc><ledm:ManifestURI>/DevMgmt/InternalPrintManifest.xml</ledm:ManifestURI><dd:ResourceType>ledm:hpLedmInternalPrintManifest</dd:ResourceType></ledm:SupportedIfc>
          <ledm:SupportedIfc><ledm:ManifestURI>/Calibration/CalibrationManifest.xml</ledm:ManifestURI><dd:ResourceType>ledm:hpCnxCalibrationManifest</dd:ResourceType></ledm:SupportedIfc>
        </ledm:DiscoveryTree>
        """;

    private const string InternalPrintManifest = """
        <man:Manifest xmlns:man="http://www.hp.com/schemas/imaging/con/ledm/manifest/2009/03/24" xmlns:map="http://www.hp.com/schemas/imaging/con/ledm/resourcemap/2009/01/27" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:ip="urn:example:internalprint">
          <map:ResourceMap>
            <map:ResourceLink><dd:ResourceURI>/Maint</dd:ResourceURI></map:ResourceLink>
            <map:ResourceNode><map:ResourceLink><dd:ResourceURI>/PrintCap.xml</dd:ResourceURI></map:ResourceLink><map:ResourceType><ip:ResourceType>InternalPrintCap</ip:ResourceType></map:ResourceType></map:ResourceNode>
            <map:ResourceNode><map:ResourceLink><dd:ResourceURI>/PrintDyn.xml</dd:ResourceURI></map:ResourceLink><map:ResourceType><ip:ResourceType>InternalPrintDyn</ip:ResourceType></map:ResourceType></map:ResourceNode>
          </map:ResourceMap>
        </man:Manifest>
        """;

    /// <summary>A made-up HP inkjet: the tree lists both interfaces; its manifest moves the internal-print documents.</summary>
    private static Recorder HpInkjet(Func<Sent, HttpResponseMessage?>? post = null, string? calibrationState = null) => new(s =>
    {
        if (s.Method == HttpMethod.Post && s.ContentType != "application/ipp") return post?.Invoke(s) ?? new HttpResponseMessage(HttpStatusCode.Created);
        return s.Uri.AbsolutePath switch
        {
            DiscoveryTree.Path => Xml(TreeWithMaintenance),
            "/DevMgmt/InternalPrintManifest.xml" => Xml(InternalPrintManifest),
            "/Maint/PrintCap.xml" => Xml(InkjetCap),
            "/DevMgmt/ConsumableConfigDyn.xml" => Xml(InkjetConsumables),
            "/DevMgmt/ProductStatusDyn.xml" => Xml(File.ReadAllText(M234dw("DevMgmt_ProductStatusDyn.xml"))),
            "/Calibration/State" when calibrationState is not null => Xml(calibrationState),
            _ => null,
        };
    });

    /// <summary>Requests that would change something on the printer (the IPP probe's Get-Printer-Attributes is a read).</summary>
    private static List<Sent> LedmPosts(Recorder printer) => printer.Requests.Where(s => s.Method == HttpMethod.Post && !IsGetPrinterAttributes(s)).ToList();

    [Fact]
    public async Task The_manifest_decides_where_internal_pages_are_read_and_sent()
    {
        var printer = HpInkjet();
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        var options = await client.DetectAsync();

        Assert.Equal("/Maint/PrintDyn.xml", options.Actions.First(a => a.JobType == "configurationPage").Target);
        Assert.DoesNotContain(printer.Requests, s => s.Uri.AbsolutePath == MaintenanceRequests.InternalPrintCapPath);
        Assert.Contains(options.Actions, a => a.Kind == MaintenanceKind.Alignment && a.Unavailable is null);
        Assert.DoesNotContain(printer.Requests, s => s.Method != HttpMethod.Get && !IsGetPrinterAttributes(s));

        var before = printer.Requests.Count;
        var result = await client.RunAsync(options.Actions.First(a => a.JobType == "configurationPage"));

        Assert.True(result.Ok, result.Message);
        var post = Assert.Single(printer.Requests.Skip(before));
        Assert.Equal(HttpMethod.Post, post.Method);
        Assert.Equal(new Uri($"https://{Host}/Maint/PrintDyn.xml"), post.Uri); // HTTPS: an admin password never crosses in clear text
        Assert.Equal("text/xml", post.ContentType);
        Assert.Equal(MaintenanceRequests.InternalPrint("configurationPage"), Encoding.UTF8.GetString(post.Body));
        Assert.Equal($"https://{Host}", post.Request.Headers.GetValues("Origin").Single());
        Assert.Equal("XMLHttpRequest", post.Request.Headers.GetValues("X-Requested-With").Single());
    }

    [Fact]
    public async Task Alignment_checks_the_calibration_state_then_starts_one_session()
    {
        var printer = HpInkjet(calibrationState: "<cal:CalibrationState xmlns:cal=\"urn:cal\">CalibrationValid</cal:CalibrationState>");
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        var align = (await client.DetectAsync()).Actions.Single(a => a.Kind == MaintenanceKind.Alignment);
        var before = printer.Requests.Count;

        Assert.True((await client.RunAsync(align)).Ok);

        var sent = printer.Requests.Skip(before).ToList();
        Assert.Equal([(HttpMethod.Get, $"http://{Host}/Calibration/State"), (HttpMethod.Post, $"https://{Host}/Calibration/Session")],
            sent.Select(s => (s.Method, s.Uri.AbsoluteUri)));
        Assert.Equal(MaintenanceRequests.StartAlignment(), Encoding.UTF8.GetString(sent[1].Body));
    }

    [Fact]
    public async Task An_alignment_already_running_is_not_started_again()
    {
        var printer = HpInkjet(calibrationState: "<cal:CalibrationState xmlns:cal=\"urn:cal\">Printing</cal:CalibrationState>");
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        var align = (await client.DetectAsync()).Actions.Single(a => a.Kind == MaintenanceKind.Alignment);

        var result = await client.RunAsync(align);

        Assert.False(result.Ok);
        Assert.Contains("already", result.Message);
        Assert.Empty(LedmPosts(printer));
    }

    [Fact]
    public async Task A_pending_alignment_session_is_not_started_over()
    {
        var printer = HpInkjet(calibrationState: "<cal:CalibrationState xmlns:cal=\"urn:cal\">ParmsRequested</cal:CalibrationState>");
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        var align = (await client.DetectAsync()).Actions.Single(a => a.Kind == MaintenanceKind.Alignment);

        var result = await client.RunAsync(align);

        Assert.False(result.Ok);
        Assert.Contains("turn the printer off and on", result.Message);
        Assert.Empty(LedmPosts(printer));
    }

    [Fact]
    public async Task Maintenance_writes_ask_for_a_connection_of_their_own()
    {
        var printer = HpInkjet();
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        await client.RunAsync((await client.DetectAsync()).Actions.First(a => a.Kind == MaintenanceKind.Cleaning));
        Assert.True(Assert.Single(LedmPosts(printer)).Request.Headers.ConnectionClose);

        var recorder = new Recorder(_ => null, InkjetPrinter());
        using var inkjet = await PrinterConnection.OpenAsync(InkjetHost, transport: recorder);
        var identifying = new MaintenanceClient(inkjet);
        await identifying.RunAsync((await identifying.DetectAsync()).Actions.Single());
        Assert.True(Assert.Single(LedmPosts(recorder)).Request.Headers.ConnectionClose);
    }

    [Theory]
    [InlineData("tls", "Not sent")]
    [InlineData("refused", "Not sent")]
    [InlineData("reset", "may have started")]
    public async Task Whether_a_failed_request_was_sent_comes_from_its_own_error(string failure, string says)
    {
        Exception error = failure switch
        {
            "tls" => new HttpRequestException("The SSL connection could not be established",
                new System.Security.Authentication.AuthenticationException("remote certificate rejected")),
            "refused" => new HttpRequestException(HttpRequestError.ConnectionError, "refused",
                new System.Net.Sockets.SocketException((int)System.Net.Sockets.SocketError.ConnectionRefused)),
            _ => new HttpRequestException(HttpRequestError.ResponseEnded, "connection reset", new IOException("reset")),
        };
        var printer = HpInkjet(post: _ => throw error);
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        var clean = (await client.DetectAsync()).Actions.First(a => a.Kind == MaintenanceKind.Cleaning);

        var result = await client.RunAsync(clean);

        Assert.False(result.Ok);
        Assert.Contains(says, result.Message);
    }

    [Fact]
    public async Task A_changed_certificate_on_another_port_doesnt_make_a_lost_answer_look_unsent()
    {
        var printer = HpInkjet(post: _ => throw new HttpRequestException(HttpRequestError.ResponseEnded, "connection reset"));
        var pins = new Pins();
        pins.SetIfAbsent(631, "00"); // IPPS pinned to another certificate earlier
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer, pin: pins);
        using var rsa = System.Security.Cryptography.RSA.Create(2048);
        using var cert = new System.Security.Cryptography.X509Certificates.CertificateRequest("CN=printer", rsa,
                System.Security.Cryptography.HashAlgorithmName.SHA256, System.Security.Cryptography.RSASignaturePadding.Pkcs1)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        Assert.False(conn.Http.ValidateCertificate(cert, System.Net.Security.SslPolicyErrors.None, 631));
        Assert.True(conn.Http.CertificateChanged); // sticky, and set by port 631

        var client = new MaintenanceClient(conn);
        var result = await client.RunAsync((await client.DetectAsync()).Actions.First(a => a.Kind == MaintenanceKind.Cleaning));

        Assert.Contains("may have started", result.Message); // the cleaning POST on 443 may have arrived: never invite a second one
    }

    private sealed class Pins : ICertificatePin
    {
        private readonly Dictionary<int, string> _pins = [];
        public string? Get(int port) => _pins.GetValueOrDefault(port);
        public string SetIfAbsent(int port, string sha256Hex) => _pins.TryAdd(port, sha256Hex) ? sha256Hex : _pins[port];
    }

    /// <summary>
    /// A real HTTP server on this PC's loopback address: answers GETs with keep-alive, and drops the connection without a
    /// word when a POST or a GET of <c>/drop</c> arrives (a printer resetting mid-request). Counts the requests it dropped.
    /// </summary>
    private sealed class DroppingServer : IDisposable
    {
        private readonly System.Net.Sockets.TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _stop = new();
        private int _dropped;

        public DroppingServer()
        {
            _listener.Start();
            _ = AcceptAsync();
        }

        public int Dropped => Volatile.Read(ref _dropped);
        public Uri Url(string path) => new($"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}{path}");

        private async Task AcceptAsync()
        {
            try
            {
                while (!_stop.IsCancellationRequested) _ = ServeAsync(await _listener.AcceptTcpClientAsync(_stop.Token));
            }
            catch (Exception) { } // stopped
        }

        private async Task ServeAsync(System.Net.Sockets.TcpClient client)
        {
            using (client)
            {
                var stream = client.GetStream();
                try
                {
                    while (await ReadRequestAsync(stream) is { } requestLine)
                    {
                        if (requestLine.StartsWith("POST", StringComparison.Ordinal) || requestLine.StartsWith("GET /drop", StringComparison.Ordinal))
                        {
                            Interlocked.Increment(ref _dropped);
                            client.Client.Close(); // no response at all
                            return;
                        }
                        await stream.WriteAsync("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok"u8.ToArray(), _stop.Token);
                    }
                }
                catch (Exception) { } // client gone
            }
        }

        /// <summary>One request (headers, then Content-Length bytes); its request line, or null at the end of the stream.</summary>
        private async Task<string?> ReadRequestAsync(Stream stream)
        {
            var head = new List<byte>();
            var one = new byte[1];
            while (head.Count < 4 || head[^4] != '\r' || head[^3] != '\n' || head[^2] != '\r' || head[^1] != '\n')
            {
                if (await stream.ReadAsync(one, _stop.Token) == 0) return null;
                head.Add(one[0]);
            }
            var lines = Encoding.ASCII.GetString(head.ToArray()).Split("\r\n");
            var length = lines.Where(l => l.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)).Select(l => int.Parse(l[15..].Trim())).FirstOrDefault();
            if (length > 0) await stream.ReadExactlyAsync(new byte[length], _stop.Token);
            return lines[0];
        }

        public void Dispose()
        {
            _stop.Cancel();
            _listener.Stop();
        }
    }

    private static HttpRequestMessage Post(Uri url) => new(HttpMethod.Post, url) { Content = new StringContent("<x/>", Encoding.UTF8, "text/xml") };

    [Fact]
    public async Task A_dropped_connection_never_makes_a_maintenance_write_arrive_twice()
    {
        using var server = new DroppingServer();
        using var http = new DeviceHttp("127.0.0.1");
        (await http.GetAsync(server.Url("/DevMgmt/ProductStatusDyn.xml"))).Dispose(); // a kept-alive connection in the pool

        using var post = Post(server.Url("/DevMgmt/InternalPrintDyn.xml"));
        await Assert.ThrowsAsync<HttpRequestException>(() => http.SendOnceAsync(post, TimeSpan.FromSeconds(5)));
        await Task.Delay(200); // a resend, if any, would have arrived by now

        Assert.Equal(1, server.Dropped);
    }

    [Fact]
    public async Task The_one_use_connection_also_stops_the_resend_dotnet_does_on_a_reused_connection()
    {
        // .NET resends a request whose reused keep-alive connection closes before any answer, as long as it hasn't started
        // sending a body (so today's POSTs are spared): shown here with a GET. SendOnceAsync never reuses a connection,
        // so nothing it sends is ever resent, whatever .NET's rules become.
        using var server = new DroppingServer();
        using var http = new DeviceHttp("127.0.0.1");
        (await http.GetAsync(server.Url("/DevMgmt/ProductStatusDyn.xml"))).Dispose();
        await Assert.ThrowsAsync<HttpRequestException>(() => http.GetAsync(server.Url("/drop"), TimeSpan.FromSeconds(5)));
        var pooled = server.Dropped;
        Assert.True(pooled >= 2, $"sent {pooled} times"); // pooled: sent again

        (await http.GetAsync(server.Url("/DevMgmt/ProductStatusDyn.xml"))).Dispose();
        using var once = new HttpRequestMessage(HttpMethod.Get, server.Url("/drop"));
        await Assert.ThrowsAsync<HttpRequestException>(() => http.SendOnceAsync(once, TimeSpan.FromSeconds(5)));
        await Task.Delay(200);
        Assert.Equal(pooled + 1, server.Dropped); // one use: sent once
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound, "doesn't offer")]
    [InlineData(HttpStatusCode.MethodNotAllowed, "doesn't offer")]
    [InlineData(HttpStatusCode.Conflict, "busy")]
    [InlineData(HttpStatusCode.ServiceUnavailable, "busy")]
    [InlineData(HttpStatusCode.InternalServerError, "HTTP 500")]
    public async Task A_refusal_is_reported_and_never_retried(HttpStatusCode status, string says)
    {
        var printer = HpInkjet(post: _ => new HttpResponseMessage(status));
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        var clean = (await client.DetectAsync()).Actions.First(a => a.Kind == MaintenanceKind.Cleaning);

        var result = await client.RunAsync(clean);

        Assert.False(result.Ok);
        Assert.Contains(says, result.Message);
        Assert.Single(LedmPosts(printer));
    }

    [Fact]
    public async Task A_password_protected_printer_asks_for_the_admin_password()
    {
        var printer = HpInkjet(post: _ => new HttpResponseMessage(HttpStatusCode.Unauthorized));
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        var clean = (await client.DetectAsync()).Actions.First(a => a.Kind == MaintenanceKind.Cleaning);

        var ex = await Assert.ThrowsAsync<LedmAuthRequiredException>(() => client.RunAsync(clean));
        Assert.False(ex.CredentialsWereSent);
    }

    [Fact]
    public async Task A_request_lost_on_the_way_back_says_it_may_have_started()
    {
        var printer = HpInkjet(post: _ => throw new HttpRequestException("connection reset"));
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);
        var client = new MaintenanceClient(conn);
        var clean = (await client.DetectAsync()).Actions.First(a => a.Kind == MaintenanceKind.Cleaning);

        var result = await client.RunAsync(clean);

        Assert.False(result.Ok);
        Assert.Contains("may have started", result.Message);
        Assert.Single(LedmPosts(printer));
    }

    [Fact]
    public async Task Identify_sends_one_Identify_Printer_request_to_the_printers_IPP_address()
    {
        var recorder = new Recorder(_ => null, InkjetPrinter());
        using var conn = await PrinterConnection.OpenAsync(InkjetHost, transport: recorder);
        var client = new MaintenanceClient(conn, userName: "alex");
        var identify = (await client.DetectAsync()).Actions.Single();
        var before = recorder.Requests.Count;

        var result = await client.RunAsync(identify);

        Assert.True(result.Ok, result.Message);
        var sent = Assert.Single(recorder.Requests.Skip(before));
        Assert.Equal(new Uri($"http://{InkjetHost}:631/ipp/print"), sent.Uri);
        Assert.Equal(IppCodec.EncodeIdentifyPrinter($"ipp://{InkjetHost}:631/ipp/print", "alex", identify.IdentifyActions, requestId: 1), sent.Body);
    }

    [Theory]
    [InlineData(0x0401, "signed-in")]
    [InlineData(0x0402, "signed-in")]
    [InlineData(0x0403, "signed-in")]
    [InlineData(0x0501, "doesn't offer")]
    [InlineData(0x0500, "0x0500")]
    public async Task Identify_refusals_are_explained(int status, string says)
    {
        var recorder = new Recorder(s => s.ContentType == "application/ipp" && IppCodec.ReadRequestHeader(s.Body).Operation == IppCodec.IdentifyPrinter
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(IppCodec.EncodeResponse((ushort)status, 1, [])) }
            : null, InkjetPrinter());
        using var conn = await PrinterConnection.OpenAsync(InkjetHost, transport: recorder);
        var client = new MaintenanceClient(conn);
        var identify = (await client.DetectAsync()).Actions.Single();

        var result = await client.RunAsync(identify);

        Assert.False(result.Ok);
        Assert.Contains(says, result.Message);
    }

    [Fact]
    public async Task Detection_survives_a_printer_that_answers_garbage()
    {
        var printer = new Recorder(s => s.Uri.AbsolutePath switch
        {
            DiscoveryTree.Path => Xml(TreeWithMaintenance),
            "/DevMgmt/InternalPrintManifest.xml" => Xml("<not xml"),
            MaintenanceRequests.InternalPrintCapPath => new HttpResponseMessage(HttpStatusCode.InternalServerError),
            "/DevMgmt/ConsumableConfigDyn.xml" => Xml("<also not xml"),
            "/DevMgmt/ProductStatusDyn.xml" => Xml(File.ReadAllText(M234dw("DevMgmt_ProductStatusDyn.xml"))),
            _ => null,
        });
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer);

        var options = await new MaintenanceClient(conn).DetectAsync();

        Assert.Empty(options.Actions);
    }

    // ------------------------------------------------------------------ demo printers (FixtureHandler)

    [Fact]
    public async Task The_fixture_server_answers_Identify_Printer_only_for_printers_that_list_it()
    {
        using var inkjet = new HttpMessageInvoker(InkjetPrinter());
        using var laser = new HttpMessageInvoker(new FixtureHandler(n => n == "ipp_print.ipp.txt" ? "printer-state enum 3"u8.ToArray() : null));
        foreach (var (invoker, expected) in new[] { (inkjet, (ushort)0), (laser, (ushort)0x0501) })
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, $"http://{InkjetHost}:631/ipp/print")
            {
                Content = new ByteArrayContent(IppCodec.EncodeIdentifyPrinter($"ipp://{InkjetHost}:631/ipp/print", null, ["flash"]))
                {
                    Headers = { ContentType = new("application/ipp") },
                },
            };
            using var resp = await invoker.SendAsync(req, default);
            Assert.Equal(expected, IppCodec.Decode(await resp.Content.ReadAsByteArrayAsync()).StatusCode);
        }
    }

    [Fact]
    public async Task The_fixture_server_accepts_an_ledm_maintenance_post()
    {
        using var invoker = new HttpMessageInvoker(M234dwPrinter());
        using var req = new HttpRequestMessage(HttpMethod.Post, $"https://{Host}/DevMgmt/InternalPrintDyn.xml")
        {
            Content = new StringContent(MaintenanceRequests.InternalPrint("configurationPage"), Encoding.UTF8, "text/xml"),
        };
        using var resp = await invoker.SendAsync(req, default);
        Assert.Equal(HttpStatusCode.Created, resp.StatusCode);
    }
}
