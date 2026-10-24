using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Tests;

/// <summary>Demo mode (<c>InkvoltPrint.exe --demo</c>): the fixture transport stands in for a whole printer.</summary>
public class DemoTests
{
    private static readonly byte[] Page = [0xFF, 0xD8, 0xFF, 0xD9];

    private static FixtureHandler Transport() => new(name =>
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }, () => Page);

    [Theory]
    [InlineData("/DevMgmt/ProductStatusDyn.xml", "DevMgmt_ProductStatusDyn.xml")]
    [InlineData("/EventMgmt/EventTable.xml", "EventMgmt_EventTable.xml")]
    [InlineData("/eSCL/ScannerCapabilities", "eSCL_ScannerCapabilities.xml")]
    public void PathsMapToFixtureNames(string path, string name) => Assert.Equal(name, FixtureHandler.DocumentName(path));

    [Fact]
    public async Task DemoPrinterConnectsFromFixturesAt192_0_2_10()
    {
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: Transport());
        Assert.Equal("192.0.2.10", conn.Http.Host);
        Assert.Contains("LEDM", conn.Probe.Interfaces);
        Assert.Contains("eSCL", conn.Probe.Interfaces);
        Assert.DoesNotContain("IPP", conn.Probe.Interfaces); // no IPP fixture: 404, not a network attempt
        Assert.Equal("HP LaserJet MFP M234dw", conn.Probe.Model);
        Assert.Equal("CNB0A00000", conn.Probe.Product!.SerialNumber);
        Assert.Equal("Ready", (await conn.GetStatusAsync()).Message);
        Assert.Single(await conn.GetSuppliesAsync());
        Assert.NotNull(await conn.Ledm!.GetAsync(InkvoltPrint.Core.Ledm.LedmResource.PrintConfigDyn));

        var pages = new List<byte[]>();
        await foreach (var p in conn.Scanner!.ScanAsync(new ScanRequest())) pages.Add(p);
        Assert.Equal([Page], pages);
    }

    [Fact]
    public async Task EventLongPollIsHeldNotSpun()
    {
        using var http = new DeviceHttp(FixtureHandler.DemoHost, Transport());
        using var req = new HttpRequestMessage(HttpMethod.Get, http.Http("/EventMgmt/EventTable.xml?timeout=600"));
        req.Headers.TryAddWithoutValidation("If-None-Match", "1-1");
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => http.SendAsync(req, TimeSpan.FromSeconds(10), cts.Token));
    }
}
