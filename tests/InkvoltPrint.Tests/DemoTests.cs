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
    public async Task DemoScannerSeesTheRequestedRegion()
    {
        var regions = new List<(int, int)>();
        var handler = new FixtureHandler(name =>
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name);
            return File.Exists(path) ? File.ReadAllBytes(path) : null;
        }, scanArea: (w, h) => { regions.Add((w, h)); return Page; });
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: handler);

        await foreach (var _ in conn.Scanner!.ScanAsync(InkvoltPrint.Core.Printing.CopyLayout.IdCardRequest(ScanColor.Grayscale, 300))) { }
        await foreach (var _ in conn.Scanner!.ScanAsync(new ScanRequest(Width: 2550, Height: 3300))) { }

        Assert.Equal([(1350, 900), (2550, 3300)], regions);
    }

    [Fact]
    public async Task DemoLaserOffersItsMadeUpMaintenancePagesWithTonerWording()
    {
        var handler = new FixtureHandler(name => new[] { "m234dw", "hp-demo" }
            .Select(folder => Path.Combine(AppContext.BaseDirectory, "Fixtures", folder, name)).Where(File.Exists).Select(File.ReadAllBytes).FirstOrDefault());
        using var conn = await PrinterConnection.OpenAsync(FixtureHandler.DemoHost, transport: handler);

        var options = await new InkvoltPrint.Core.Maintenance.MaintenanceClient(conn).DetectAsync();

        Assert.Equal(["configurationPage", "pqDiagnosticsPage", "networkSummary", "cleaningPage"], options.Actions.Select(a => a.JobType));
        Assert.Equal("Print cleaning page (HP)", options.Actions[^1].Label);
        Assert.True((await new InkvoltPrint.Core.Maintenance.MaintenanceClient(conn).RunAsync(options.Actions[0])).Ok);
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
