using System.Net;
using InkvoltPrint.Core.Discovery;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// A printer's web server on a port of its own (HP's EWS, LEDM and CDM at <c>http://host:8080/</c>): typed in Add a printer as a
/// web address with its port, or announced in its IPP service's <c>adminurl</c>; the connection asks LEDM and CDM there, and
/// still finds a scanner on port 80.
/// </summary>
public class PrinterWebPortTests
{
    private const string Host = "192.0.2.20";

    // ------------------------------------------------------------------------------------------------ where the web server is

    [Theory]
    [InlineData("http://192.0.2.20:8080", "http://192.0.2.20:8080/")]
    [InlineData("http://192.0.2.20:8080/hp/device/info", "http://192.0.2.20:8080/")]
    [InlineData("https://printer.local:8443/", "https://printer.local:8443/")]
    [InlineData("http://192.0.2.20", null)] // port 80: the default
    [InlineData("https://printer.local:443/", null)]
    [InlineData("192.0.2.20:8080", null)] // no scheme: an IPP server's port, as before
    [InlineData("ipp://192.0.2.20:8080/ipp/print", null)]
    [InlineData("http://192.0.2.20:631/ipp/print", null)] // IPP Everywhere's port and path: the IPP server, not the web server
    [InlineData("http://192.0.2.20:631/", null)]
    [InlineData("http://192.0.2.20:8631/ipp/print", null)]
    [InlineData("https://192.0.2.20:8443/ipp", null)]
    [InlineData("http://[fe80::1]:8080/", "http://[fe80::1]:8080/")]
    public void A_web_address_with_its_port_says_where_the_web_server_is(string typed, string? web)
    {
        var a = PrinterAddress.Parse(typed);
        Assert.Null(a.Error);
        Assert.Equal(web, a.Web?.AbsoluteUri);
        if (web is not null) Assert.NotNull(a.Ipp); // and an IPP server to try there, as before
    }

    [Theory]
    [InlineData("http://user:secret@other.example:8080/x?y#z", "http://192.0.2.20:8080/")] // only the scheme and port: on this printer
    [InlineData("ftp://192.0.2.20:2121/", null)]
    [InlineData("http://192.0.2.20:80/", null)]
    [InlineData("https://192.0.2.20/", null)]
    public void A_web_root_is_a_scheme_and_port_on_the_printer(string url, string? root) =>
        Assert.Equal(root, PrinterAddress.WebRoot(new Uri(url), Host)?.AbsoluteUri);

    private static DnssdService Ipp(string? adminurl, string? hostName = "NPI0A1B2C.local", string ipv4 = Host)
    {
        var txt = new Dictionary<string, string> { ["rp"] = "ipp/print" };
        if (adminurl is not null) txt["adminurl"] = adminurl;
        return new DnssdService("_ipp._tcp", "00000000-0000-4000-8000-000000000020", hostName, ipv4, 631, txt);
    }

    [Theory]
    [InlineData("http://NPI0A1B2C.local:8080/#hId-pgDevInfo", "http://192.0.2.20:8080/")] // its .local name: on the address in use
    [InlineData("https://192.0.2.20:8443/", "https://192.0.2.20:8443/")]
    [InlineData("http://NPI0A1B2C.local./", null)] // port 80
    [InlineData("http://another-printer.local:8080/", null)] // names another device
    [InlineData("http://198.51.100.7:8080/", null)]
    [InlineData("javascript:alert(1)", null)]
    [InlineData("not a url", null)]
    [InlineData(null, null)]
    public void An_IPP_service_s_adminurl_on_a_port_of_its_own_is_its_web_server(string? adminurl, string? root) =>
        Assert.Equal(root, DnssdJoin.WebRoot(Ipp(adminurl), Host)?.AbsoluteUri);

    [Fact]
    public void A_very_long_adminurl_is_left_alone() =>
        Assert.Null(DnssdJoin.WebRoot(Ipp("http://NPI0A1B2C.local:8080/" + new string('a', 5000)), Host));

    [Fact]
    public void The_device_s_http_or_https_base_moves_to_the_web_port()
    {
        using var plain = new DeviceHttp(Host, new FixtureHandler(_ => null), web: new Uri("http://elsewhere.example:8080/"));
        Assert.Equal(("http://192.0.2.20:8080/", "https://192.0.2.20/"), (plain.HttpBase.AbsoluteUri, plain.HttpsBase.AbsoluteUri));
        using var tls = new DeviceHttp(Host, new FixtureHandler(_ => null), web: new Uri("https://192.0.2.20:8443/"));
        Assert.Equal(("http://192.0.2.20/", "https://192.0.2.20:8443/"), (tls.HttpBase.AbsoluteUri, tls.HttpsBase.AbsoluteUri));
        Assert.Equal("http://192.0.2.20:8080/DevMgmt/DiscoveryTree.xml", plain.Http("/DevMgmt/DiscoveryTree.xml").AbsoluteUri);
    }

    // ------------------------------------------------------------------------------------------------ connecting

    /// <summary>The M234dw's documents, its web server (LEDM) on port 8080 only and its scanner on port 80; port 80 has nothing else.</summary>
    private sealed class OnPort8080 : DelegatingHandler
    {
        public List<string> Seen { get; } = [];

        public OnPort8080() : base(new FixtureHandler(name =>
            File.Exists(Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name)) ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name)) : null))
        {
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var uri = request.RequestUri!;
            lock (Seen) Seen.Add($"{uri.Port} {uri.AbsolutePath}");
            var scanner = uri.AbsolutePath.StartsWith("/eSCL/", StringComparison.Ordinal);
            if (uri.Port == 8080 && !scanner || uri.Port == 80 && scanner) return base.SendAsync(request, ct);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound) { RequestMessage = request });
        }
    }

    [Fact]
    public async Task Without_its_web_port_the_printer_s_LEDM_isn_t_found()
    {
        using var conn = await PrinterConnection.OpenAsync(Host, transport: new OnPort8080());
        Assert.DoesNotContain("LEDM", conn.Probe.Interfaces);
    }

    [Fact]
    public async Task With_its_web_port_LEDM_is_read_there_and_the_scanner_still_found_on_port_80()
    {
        var printer = new OnPort8080();
        using var conn = await PrinterConnection.OpenAsync(Host, transport: printer, webHint: new Uri("http://192.0.2.20:8080/"));
        Assert.Contains("LEDM", conn.Probe.Interfaces);
        Assert.Contains("eSCL", conn.Probe.Interfaces);
        Assert.Equal("http://192.0.2.20/eSCL/", conn.Probe.EsclRoot?.AbsoluteUri);
        var reading = await conn.ReadAsync();
        Assert.Equal("Ready", reading.Status.Message);
        Assert.Contains("8080 /DevMgmt/ProductStatusDyn.xml", printer.Seen);
        Assert.DoesNotContain("80 /DevMgmt/ProductStatusDyn.xml", printer.Seen);
    }

    [Fact]
    public async Task A_printer_s_session_connects_with_the_web_hint_it_was_given()
    {
        using var session = new PrinterSession(Core.Model.PrinterId.Normalize(null, Host),
            new PrinterRecipe(() => new OnPort8080(), new SnmpRouter(new Dictionary<string, ISnmpTransport>())), () => [], _ => { });
        var step = await session.ConnectAsync(new PrinterWhere(Host, WebHint: new Uri("http://192.0.2.20:8080/")), default);
        var connected = Assert.IsType<SessionStep.Connected>(step);
        Assert.Contains("LEDM", connected.Connection.Probe.Interfaces);
    }

    // ------------------------------------------------------------------------------------------------ kept, or let go

    [Fact]
    public async Task A_web_root_is_kept_only_where_LEDM_or_CDM_answered()
    {
        var web = new Uri("http://192.0.2.20:8080/");
        using (var http = new DeviceHttp(Host, new OnPort8080(), web: web))
            Assert.Equal(web, (await PrinterConnection.ProbeAsync(http)).WebRootKept(web));
        // The inkjet answers IPP only: a typed port that isn't its web server isn't kept.
        using (var http = new DeviceHttp(Host, Inkjet(), web: web))
        {
            var probe = await PrinterConnection.ProbeAsync(http);
            Assert.True(probe.Reachable);
            Assert.Null(probe.WebRootKept(web));
        }
    }

    private static FixtureHandler Inkjet() => new(name =>
        name == "ipp_print.ipp.txt" ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo", name)) : null);

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task The_monitor_lets_a_web_root_go_once_nothing_of_the_web_server_answers_there(bool ledmThere)
    {
        HttpMessageHandler Network() => ledmThere ? new OnPort8080() : Inkjet();
        using var m = new PrinterMonitor(ledmThere ? Core.Fleet.DemoFleet.LaserUuid : Core.Fleet.DemoFleet.InkjetUuid, () => "Printer",
            new PrinterWhere(Host, WebHint: new Uri("http://192.0.2.20:8080/")),
            new PrinterRecipe(Network, new SnmpRouter(new Dictionary<string, ISnmpTransport>())), () => [], _ => { }, _ => { },
            retryDelay: TimeSpan.FromMilliseconds(50), fallbackRefresh: TimeSpan.FromMilliseconds(200));
        using var cts = new CancellationTokenSource();
        var run = Task.Run(() => m.RunAsync(cts.Token));
        try
        {
            var limit = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(10));
            while (!m.View.IsOnline && DateTime.UtcNow < limit) await Task.Delay(10);
            Assert.True(m.View.IsOnline);
            Assert.Equal(ledmThere ? "http://192.0.2.20:8080/" : null, m.Target.WebHint?.AbsoluteUri);
        }
        finally
        {
            await cts.CancelAsync();
            await run;
        }
    }
}
