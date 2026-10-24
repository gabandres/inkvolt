using System.Net;
using InkvoltPrint.Core.Cdm;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Tests;

/// <summary>
/// HP CDM (newer HP printers without LEDM), read only: identity, supplies and status from fixtures written from the public
/// sources (MIT-licensed Home Assistant integrations' captures and parsers; HPLIP for the supply fields), at 192.0.2.x.
/// </summary>
public class CdmTests
{
    private static string Json(string printer, string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", printer, name));

    private static FixtureHandler Transport(string printer) => new(name =>
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", printer, name);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    });

    [Fact]
    public void Identity_gives_model_serial_firmware_and_uuid()
    {
        var p = CdmParsers.ParseIdentity(Json("cdm-laser", "cdm_system_v1_identity.json"))!;

        Assert.Equal("HP Color LaserJet Pro MFP 3302", p.MakeAndModel);
        Assert.Equal("HP Color LaserJet Pro MFP 3301-3304 3388", p.Family);
        Assert.Equal("CNC0X00000", p.SerialNumber);
        Assert.Equal("499Q7A", p.ProductNumber);
        Assert.Equal("4d1e2c3b-0a9f-4e8d-b7c6-5a4b3c2d1e0f", p.Uuid);
        Assert.Equal("6.28.3.30-202606111700", p.FirmwareRevision);
        Assert.Equal("2026-07-24", p.FirmwareDate);
        Assert.Null(p.AdminPasswordSet);
    }

    [Fact]
    public void Identity_tolerates_a_plain_model_string_and_missing_fields()
    {
        Assert.Equal("HP OfficeJet Pro 9130", CdmParsers.ParseIdentity("""{"makeAndModel":"HP OfficeJet Pro 9130"}""")!.MakeAndModel);
        Assert.Equal("2025-09-18", CdmParsers.ParseIdentity(Json("cdm-tank", "cdm_system_v1_identity.json"))!.FirmwareDate);
        Assert.Null(CdmParsers.ParseIdentity("""{"version":"1.0.0"}""")); // no model: not an identity
        Assert.Null(CdmParsers.ParseIdentity("<html>not json</html>"));
        Assert.Null(CdmParsers.ParseIdentity("[1,2]"));
    }

    [Fact]
    public void Toner_supplies_with_levels_parts_and_pages()
    {
        var s = CdmParsers.ParseSupplies(Json("cdm-laser", "cdm_supply_v1_suppliesPublic.json"));

        Assert.Equal(["Black toner", "Cyan toner", "Magenta toner", "Yellow toner"], s.Select(c => c.Name));
        Assert.All(s, c => Assert.Equal("toner", c.Kind));
        Assert.Equal(["K", "C", "M", "Y"], s.Select(c => c.ColorCode));
        Assert.Equal([72, 9, 55, 61], s.Select(c => c.PercentRemaining));
        Assert.Equal("W2121X", s[1].ProductNumber);
        Assert.Equal(200, s[1].EstimatedPagesRemaining);
        Assert.Equal("low", s[1].State);
        Assert.True(s[1].IsLow);
        Assert.False(s[0].IsLow);
    }

    [Fact]
    public void Ink_tanks_and_their_printheads()
    {
        var s = CdmParsers.ParseSupplies(Json("cdm-tank", "cdm_supply_v1_suppliesPublic.json"));

        // Tanks first (what runs out), then the printheads, which report no level on tank printers.
        Assert.Equal(["Cyan ink tank", "Magenta ink tank", "Yellow ink tank", "Black ink tank", "Tri-color printhead", "Black printhead"], s.Select(c => c.Name));
        Assert.Equal([80, 60, 10, 100, null, null], s.Select(c => c.PercentRemaining));
        Assert.Equal("low", s[2].State);
        Assert.Equal("ok", s[4].State);          // "inform" (a used printhead): nothing to do
        Assert.Equal("M0H50A", s[4].ProductNumber);
        Assert.Equal("CMY", s[4].ColorCode);
    }

    [Fact]
    public void Supply_states_and_odd_values()
    {
        var s = CdmParsers.ParseSupplies("""
            {"suppliesList":[
              {"supplyType":"inkCartridge","supplyColorCode":"K","supplyState":"out","percentLifeDisplay":"0"},
              {"supplyType":"inkCartridge","supplyColorCode":"CMY","supplyState":"ok","levelState":"veryLow","percentLifeDisplay":4},
              {"supplyType":"inkCartridge","supplyColorCode":"pK","supplyState":"missing"},
              {"supplyType":"imageDrum","supplyState":"ok","percentLifeDisplay":250},
              {"supplyType":"somethingNew","supplyState":"weird","percentLifeDisplay":-1},
              {"no":"type"}
            ]}
            """);

        Assert.Equal(["Black ink cartridge", "Tri-color ink cartridge", "Photo black ink cartridge", "Drum", "Something new", "Supply"], s.Select(c => c.Name));
        Assert.Equal(["out", "veryLow", "missing", "ok", "unknown", "unknown"], s.Select(c => c.State));
        Assert.Equal([0, 4, null, 100, null, null], s.Select(c => c.PercentRemaining));
        Assert.Equal("K", s[2].ColorCode); // photo black shows as black
        Assert.Empty(CdmParsers.ParseSupplies("{}"));
        Assert.Empty(CdmParsers.ParseSupplies("garbage"));
    }

    [Fact]
    public void Status_from_system_status_and_alerts()
    {
        var ready = CdmParsers.ParseStatus(Json("cdm-laser", "cdm_system_v1_status.json"), Json("cdm-laser", "cdm_print_v2_status.json"),
            Json("cdm-laser", "cdm_alert_v1_alerts.json"));

        Assert.Equal("ready", ready.Code);
        Assert.Equal("Ready", ready.Message);
        Assert.Equal(Severity.Warning, ready.Severity);
        var alert = Assert.Single(ready.Alerts); // the "genuine HP supply" information alert is left out
        Assert.Equal("cartridgeLow", alert.Id);
        Assert.Equal("Cartridge low (Cyan)", alert.Message);

        var tray = CdmParsers.ParseStatus(Json("cdm-tank", "cdm_system_v1_status.json"), Json("cdm-tank", "cdm_print_v2_status.json"),
            Json("cdm-tank", "cdm_alert_v1_alerts.json"));
        Assert.Equal(Severity.Error, tray.Severity);
        Assert.Equal("Load paper", Assert.Single(tray.Alerts).Message);
        Assert.Equal("Load paper", tray.Message); // an error says what's wrong rather than "Ready"
        Assert.NotNull(tray.Detail);
    }

    [Fact]
    public void Status_without_system_status_falls_back_to_the_print_state()
    {
        Assert.Equal("Printing", CdmParsers.ParseStatus(null, """{"printerState":"processing","printerStateReasons":["none"]}""", null).Message);
        Assert.Equal("Ready", CdmParsers.ParseStatus(null, """{"printerState":"idle"}""", null).Message);
        Assert.Equal("unknown", CdmParsers.ParseStatus(null, null, "garbage").Code);
        Assert.Equal("Door open", CdmParsers.ParseStatus("""{"status":"ready"}""", null,
            """{"alerts":[{"category":"doorOpen","severity":"error"},{"category":"jamInTray2","severity":"error"}]}""").Alerts[0].Message);
        Assert.Equal("Paper jam", CdmParsers.ParseStatus("""{"status":"ready"}""", null,
            """{"alerts":[{"category":"jamInTray2"}]}""").Alerts[0].Message);
    }

    [Fact]
    public async Task A_printer_without_ledm_connects_over_cdm()
    {
        using var conn = await PrinterConnection.OpenAsync("192.0.2.13", transport: Transport("cdm-laser"));

        Assert.NotNull(conn.Cdm);
        Assert.Null(conn.Ledm);
        Assert.Contains("CDM", conn.Probe.Interfaces);
        Assert.True(conn.Probe.Reachable);
        Assert.Equal(PrinterBrand.Hp, conn.Probe.Brand);
        Assert.False(conn.Probe.HasHpInterfaces); // settings, firmware updates and counters stay LEDM only
        Assert.Equal("HP Color LaserJet Pro MFP 3302", conn.Probe.Model);
        Assert.Equal("4d1e2c3b-0a9f-4e8d-b7c6-5a4b3c2d1e0f", conn.Probe.Uuid);
        Assert.Equal("6.28.3.30-202606111700 (2026-07-24)", conn.Probe.Firmware!.Display);
        Assert.Equal("Ready", (await conn.GetStatusAsync()).Message);
        Assert.Equal(4, (await conn.GetSuppliesAsync()).Count);
    }

    [Fact]
    public async Task Cdm_is_only_asked_when_ledm_is_missing_and_only_with_gets()
    {
        var seen = new List<(HttpMethod, string)>();
        var ledm = new Recording(seen, path => path.StartsWith("/DevMgmt/DiscoveryTree", StringComparison.Ordinal) || path.StartsWith("/cdm/", StringComparison.Ordinal)
            ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", path.StartsWith("/cdm/", StringComparison.Ordinal) ? "cdm-laser" : "m234dw",
                path.StartsWith("/cdm/", StringComparison.Ordinal) ? FixtureHandler.DocumentName(path) : "DevMgmt_DiscoveryTree.xml"))
            : null);
        using (await PrinterConnection.OpenAsync("192.0.2.10", transport: ledm)) { }
        Assert.DoesNotContain(seen, r => r.Item2.StartsWith("/cdm/", StringComparison.Ordinal)); // LEDM answered: CDM never asked

        seen.Clear();
        using var conn = await PrinterConnection.OpenAsync("192.0.2.13", transport: new Recording(seen, null, Transport("cdm-laser")));
        await conn.GetStatusAsync();
        await conn.GetSuppliesAsync();
        Assert.Contains(seen, r => r.Item2 == "/cdm/system/v1/identity");
        Assert.All(seen.Where(r => r.Item2.StartsWith("/cdm/", StringComparison.Ordinal)), r => Assert.Equal(HttpMethod.Get, r.Item1));
    }

    [Fact]
    public async Task Https_when_the_printer_redirects_there()
    {
        var seen = new List<(HttpMethod, string)>();
        var inner = Transport("cdm-laser");
        var redirecting = new Recording(seen, null, inner, redirectHttp: true);

        using var conn = await PrinterConnection.OpenAsync("192.0.2.13", transport: redirecting);

        Assert.Equal("HP Color LaserJet Pro MFP 3302", conn.Probe.Model);
        Assert.Equal(Uri.UriSchemeHttps, conn.Cdm!.Root.Scheme);
        Assert.Equal(4, (await conn.GetSuppliesAsync()).Count);
    }

    [Fact]
    public void Maintenance_says_cdm_printers_are_left_to_their_panel()
    {
        var options = Core.Maintenance.MaintenanceCatalog.Detect(new Core.Maintenance.MaintenanceSources { Host = "192.0.2.13", HasCdm = true });

        Assert.Empty(options.Actions);
        Assert.Contains("CDM", options.Note);
        Assert.DoesNotContain("IPP", options.Note);
    }

    /// <summary>The DiscoveryTree answers with <paramref name="status"/> (and a Location for redirects); CDM from the laser fixtures.</summary>
    private static async Task<(bool AskedCdm, ProbeResult Probe)> ProbeWithTree(HttpStatusCode status, string? location = null)
    {
        var seen = new List<(HttpMethod, string)>();
        var handler = new Scripted(seen, request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/DevMgmt/DiscoveryTree.xml")
            {
                var resp = new HttpResponseMessage(status) { RequestMessage = request, Content = new StringContent("") };
                if (location is not null) resp.Headers.Location = new Uri(location, UriKind.RelativeOrAbsolute);
                return resp;
            }
            var file = Path.Combine(AppContext.BaseDirectory, "Fixtures", "cdm-laser", FixtureHandler.DocumentName(path));
            return new HttpResponseMessage(path.StartsWith("/cdm/", StringComparison.Ordinal) && File.Exists(file) ? HttpStatusCode.OK : HttpStatusCode.NotFound)
            {
                RequestMessage = request,
                Content = new ByteArrayContent(path.StartsWith("/cdm/", StringComparison.Ordinal) && File.Exists(file) ? File.ReadAllBytes(file) : []),
            };
        });
        using var http = new DeviceHttp("192.0.2.13", handler);
        var probe = await PrinterConnection.ProbeAsync(http);
        return (seen.Any(r => r.Item2.StartsWith("/cdm/", StringComparison.Ordinal)), probe);
    }

    [Theory]
    [InlineData(HttpStatusCode.ServiceUnavailable)] // an LEDM printer waking up
    [InlineData(HttpStatusCode.InternalServerError)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.BadRequest)]
    public async Task An_ledm_error_page_is_ledm_busy_not_a_cdm_printer(HttpStatusCode status)
    {
        var (askedCdm, probe) = await ProbeWithTree(status);

        Assert.False(askedCdm);
        Assert.Null(probe.Cdm);
    }

    [Theory]
    [InlineData("/hp/device/webAccess/index.htm", true)]                       // the web page instead: no LEDM
    [InlineData("https://192.0.2.13/DevMgmt/DiscoveryTree.xml", false)]        // LEDM over HTTPS: LEDM, not CDM
    [InlineData("/DevMgmt/DiscoveryTree.xml?x=1", false)]
    public async Task A_redirect_counts_as_no_ledm_only_away_from_ledm(string location, bool cdm)
    {
        var (askedCdm, probe) = await ProbeWithTree(HttpStatusCode.MovedPermanently, location);

        Assert.Equal(cdm, askedCdm);
        Assert.Equal(cdm, probe.Cdm is not null);
    }

    [Fact]
    public async Task A_missing_discovery_tree_is_no_ledm()
    {
        var (askedCdm, probe) = await ProbeWithTree(HttpStatusCode.NotFound);

        Assert.True(askedCdm);
        Assert.Equal("HP Color LaserJet Pro MFP 3302", probe.Model);
    }

    private sealed class Scripted(List<(HttpMethod, string)> seen, Func<HttpRequestMessage, HttpResponseMessage> reply) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            lock (seen) seen.Add((request.Method, request.RequestUri!.AbsolutePath));
            return Task.FromResult(reply(request));
        }
    }

    [Fact]
    public void Cdm_paths_map_to_json_fixtures() =>
        Assert.Equal("cdm_supply_v1_suppliesPublic.json", FixtureHandler.DocumentName("/cdm/supply/v1/suppliesPublic"));

    /// <summary>Records each request's method and path; serves <paramref name="serve"/> or passes to <paramref name="inner"/>.</summary>
    private sealed class Recording(List<(HttpMethod, string)> seen, Func<string, byte[]?>? serve, HttpMessageHandler? inner = null, bool redirectHttp = false)
        : DelegatingHandler(inner ?? new HttpClientHandler())
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var uri = request.RequestUri!;
            lock (seen) seen.Add((request.Method, uri.AbsolutePath));
            if (redirectHttp && uri.Scheme == Uri.UriSchemeHttp && uri.AbsolutePath.StartsWith("/cdm/", StringComparison.Ordinal))
            {
                var moved = new HttpResponseMessage(HttpStatusCode.MovedPermanently) { RequestMessage = request };
                moved.Headers.Location = new UriBuilder(uri) { Scheme = Uri.UriSchemeHttps, Port = 443 }.Uri;
                return moved;
            }
            if (serve is null) return await base.SendAsync(request, ct);
            var body = serve(uri.AbsolutePath);
            return new HttpResponseMessage(body is null ? HttpStatusCode.NotFound : HttpStatusCode.OK)
            {
                RequestMessage = request,
                Content = new ByteArrayContent(body ?? []),
            };
        }
    }
}
