using System.Net;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Tests;

/// <summary>
/// The printer status module (<see cref="PrinterConnection.ReadAsync"/>): one read, one fallback order (LEDM, CDM, IPP, SNMP)
/// and one error rule, over fixture printers whose requests can be made to fail.
/// </summary>
public class PrinterReadingTests
{
    private static byte[]? Fixture(string folder, string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", folder, name);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    /// <summary>An HP laser with LEDM (m234dw's documents) that answers IPP as well (the demo inkjet's attributes).</summary>
    private static FixtureHandler LedmAndIpp() => new(name => Fixture("m234dw", name) ?? (name == "ipp_print.ipp.txt" ? Fixture("inkjet-demo", name) : null));

    private static FixtureHandler IppOnly() => new(name => name == "ipp_print.ipp.txt" ? Fixture("inkjet-demo", name) : null);

    private static bool IsIpp(HttpRequestMessage r) => r.Method == HttpMethod.Post && r.RequestUri!.AbsolutePath == "/ipp/print";

    private static bool Is(HttpRequestMessage r, string document) => r.RequestUri!.AbsolutePath.EndsWith(document, StringComparison.Ordinal);

    [Fact]
    public async Task An_IPP_printer_is_read_with_one_request()
    {
        var network = new Network(IppOnly());
        using var conn = await PrinterConnection.OpenAsync("192.0.2.11", transport: network);
        network.Fail = true;
        network.Seen.Clear();

        var reading = await conn.ReadAsync();

        Assert.Equal("Yellow ink is low.", Assert.Single(reading.Status.Alerts).Message);
        Assert.Equal(5, reading.Supplies!.Count);
        Assert.Null(reading.Usage); // page counts are LEDM's
        Assert.Single(network.Seen, IsIpp);
    }

    [Fact]
    public async Task An_LEDM_printer_gives_status_supplies_and_usage_without_asking_IPP()
    {
        var network = new Network(LedmAndIpp());
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: network);
        network.Fail = true;
        Assert.Contains("IPP", conn.Probe.Interfaces);
        network.Seen.Clear();

        var reading = await conn.ReadAsync();

        Assert.Equal("Ready", reading.Status.Message);
        Assert.Single(reading.Supplies!); // the laser's one toner, not the inkjet's five inks
        Assert.NotNull(reading.Usage?.TotalImpressions);
        Assert.DoesNotContain(network.Seen, IsIpp);
        Assert.Single(network.Seen, r => Is(r, "/ProductUsageDyn.xml")); // counters and page estimates: one read
    }

    [Fact]
    public async Task Supplies_that_LEDM_answers_with_an_error_come_from_IPP()
    {
        // Before, an LEDM error reading consumables gave no supplies at all, though IPP had them.
        var network = new Network(LedmAndIpp(), r => Is(r, "/ConsumableConfigDyn.xml") ? Network.Status(HttpStatusCode.InternalServerError) : null);
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: network);
        network.Fail = true;
        network.Seen.Clear();

        var reading = await conn.ReadAsync();

        Assert.Equal("Ready", reading.Status.Message); // still LEDM's
        Assert.Equal(5, reading.Supplies!.Count);
        Assert.Single(network.Seen, IsIpp);
        Assert.Equal(5, (await conn.GetSuppliesAsync()).Count);
    }

    [Fact]
    public async Task Status_and_supplies_both_falling_back_to_IPP_take_one_request()
    {
        var network = new Network(LedmAndIpp(), r => Is(r, "/ProductStatusDyn.xml") || Is(r, "/ConsumableConfigDyn.xml")
            ? Network.Status(HttpStatusCode.ServiceUnavailable) : null);
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: network);
        network.Fail = true;
        network.Seen.Clear();

        var reading = await conn.ReadAsync();

        Assert.Equal("Yellow ink is low.", Assert.Single(reading.Status.Alerts).Message);
        Assert.Equal(5, reading.Supplies!.Count);
        Assert.Single(network.Seen, IsIpp);
    }

    [Fact]
    public async Task A_printer_that_answers_only_with_errors_is_unavailable_and_its_supplies_unknown()
    {
        var network = new Network(LedmAndIpp(), r => Is(r, "/ProductStatusDyn.xml") || Is(r, "/ConsumableConfigDyn.xml") || IsIpp(r)
            ? Network.Status(HttpStatusCode.ServiceUnavailable) : null);
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: network);
        Assert.Contains("IPP", conn.Probe.Interfaces); // answered while it was probed
        network.Fail = true;

        var reading = await conn.ReadAsync();

        Assert.True(reading.Status.IsUnavailable);
        Assert.False(reading.IsOffline);
        Assert.Null(reading.Supplies); // not "none": the last known levels stay on screen
        Assert.Empty(await conn.GetSuppliesAsync());
    }

    [Fact]
    public async Task A_network_failure_is_offline_and_nothing_more_is_asked()
    {
        var network = new Network(LedmAndIpp(), r => Is(r, "/ProductStatusDyn.xml") ? Network.Refuse() : null);
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: network);
        network.Fail = true;
        network.Seen.Clear();

        var reading = await conn.ReadAsync();

        Assert.True(reading.IsOffline);
        Assert.Null(reading.Supplies);
        Assert.DoesNotContain(network.Seen, IsIpp); // the same host: no second timeout
        Assert.Equal("offline", (await conn.GetStatusAsync()).Code);
    }

    [Fact]
    public async Task Supplies_that_time_out_after_the_status_answered_keep_the_status()
    {
        var network = new Network(LedmAndIpp(), r => Is(r, "/ConsumableConfigDyn.xml") ? Network.Refuse() : null);
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: network);
        network.Fail = true;
        network.Seen.Clear();

        var reading = await conn.ReadAsync();

        Assert.Equal("Ready", reading.Status.Message);
        Assert.Null(reading.Supplies);
        Assert.DoesNotContain(network.Seen, IsIpp);
    }

    [Fact]
    public async Task Usage_counters_that_fail_are_just_missing()
    {
        var network = new Network(LedmAndIpp(), r => Is(r, "/ProductUsageDyn.xml") ? Network.Refuse() : null);
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: network);
        network.Fail = true;

        var reading = await conn.ReadAsync();

        Assert.Equal("Ready", reading.Status.Message);
        Assert.Single(reading.Supplies!);
        Assert.Null(reading.Usage);
    }

    [Fact]
    public async Task The_UUID_comes_from_the_next_interface_when_one_errs_and_from_none_when_the_printer_is_gone()
    {
        var network = new Network(LedmAndIpp(), r => Is(r, "/ProductConfigDyn.xml") ? Network.Status(HttpStatusCode.InternalServerError) : null);
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: network);
        network.Fail = true;

        Assert.Equal(["2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"], (await conn.ReadUuidsAsync()).Select(u => u?.Replace("urn:uuid:", "")));

        network.Fault = r => Is(r, "/ProductConfigDyn.xml") ? Network.Refuse() : null;
        network.Seen.Clear();
        Assert.Empty(await conn.ReadUuidsAsync());
        Assert.DoesNotContain(network.Seen, IsIpp);
    }

    /// <summary>The fixtures behind a network that records each request and, once <see cref="Fail"/> is set, fails the chosen ones.</summary>
    private sealed class Network(HttpMessageHandler inner, Func<HttpRequestMessage, Func<HttpRequestMessage, Task<HttpResponseMessage>>?>? fault = null)
        : DelegatingHandler(inner)
    {
        public List<HttpRequestMessage> Seen { get; } = [];

        /// <summary>Faults apply from now on (set once the connection is open, so the probe sees a healthy printer).</summary>
        public bool Fail { get; set; }

        public Func<HttpRequestMessage, Func<HttpRequestMessage, Task<HttpResponseMessage>>?>? Fault { get; set; } = fault;

        public static Func<HttpRequestMessage, Task<HttpResponseMessage>> Status(HttpStatusCode code) =>
            r => Task.FromResult(new HttpResponseMessage(code) { RequestMessage = r });

        public static Func<HttpRequestMessage, Task<HttpResponseMessage>> Refuse() => _ => Task.FromException<HttpResponseMessage>(
            new HttpRequestException(HttpRequestError.ConnectionError, "refused",
                new System.Net.Sockets.SocketException((int)System.Net.Sockets.SocketError.ConnectionRefused)));

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            lock (Seen) Seen.Add(request);
            return Fail && Fault?.Invoke(request) is { } f ? f(request) : base.SendAsync(request, ct);
        }
    }
}
