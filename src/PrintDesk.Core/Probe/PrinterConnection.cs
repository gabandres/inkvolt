using System.Runtime.CompilerServices;
using PrintDesk.Core.Escl;
using PrintDesk.Core.Ipp;
using PrintDesk.Core.Ledm;
using PrintDesk.Core.Model;
using PrintDesk.Core.Net;

namespace PrintDesk.Core.Probe;

/// <summary>Which interfaces a printer answered on. Probed once, in parallel, with short timeouts.</summary>
public sealed record ProbeResult(
    string Host,
    DiscoveryTree? Ledm,
    ProductInfo? Product,
    ScannerCapabilities? Scanner,
    Uri? EsclRoot,
    IppResponse? Ipp)
{
    public bool Reachable => Ledm is not null || Scanner is not null || Ipp is not null;

    public string? Uuid =>
        Product?.Uuid ?? Scanner?.Uuid ?? Ipp?.Str("printer-uuid")?.Replace("urn:uuid:", "", StringComparison.OrdinalIgnoreCase);

    public string? Model => Product?.MakeAndModel ?? Scanner?.MakeAndModel ?? Ipp?.Str("printer-make-and-model");

    public IEnumerable<string> Interfaces
    {
        get
        {
            if (Ledm is not null) yield return "LEDM";
            if (Ledm?.HasCdm == true) yield return "CDM";
            if (Scanner is not null) yield return "eSCL";
            if (Ipp is not null) yield return "IPP";
        }
    }
}

/// <summary>
/// Live connection to one printer: picks LEDM for status/supplies/settings when present, IPP otherwise,
/// and eSCL for scanning. Owns the printer's single <see cref="DeviceHttp"/>.
/// </summary>
public sealed class PrinterConnection : IDisposable
{
    private PrinterConnection(DeviceHttp http, ProbeResult probe)
    {
        Http = http;
        Probe = probe;
        Ledm = probe.Ledm is not null ? new LedmClient(http) : null;
        Scanner = probe.EsclRoot is not null ? new EsclClient(http, probe.EsclRoot) : null;
        Ipp = probe.Ipp is not null ? new IppClient(http) : null;
    }

    public DeviceHttp Http { get; }
    public ProbeResult Probe { get; }
    public LedmClient? Ledm { get; }
    public EsclClient? Scanner { get; }
    public IppClient? Ipp { get; }

    /// <param name="esclHint">eSCL base from DNS-SD (<c>rs</c> TXT + port), tried if <c>http://host/eSCL/</c> fails.</param>
    public static async Task<PrinterConnection> OpenAsync(string host, Uri? esclHint = null, CancellationToken ct = default)
    {
        var http = new DeviceHttp(host);
        try
        {
            return new PrinterConnection(http, await ProbeAsync(http, esclHint, ct).ConfigureAwait(false));
        }
        catch
        {
            http.Dispose();
            throw;
        }
    }

    public static async Task<ProbeResult> ProbeAsync(DeviceHttp http, Uri? esclHint = null, CancellationToken ct = default)
    {
        var ledm = Try<(DiscoveryTree?, ProductInfo?)>(async () =>
        {
            var c = new LedmClient(http);
            var tree = await c.GetTreeAsync(ct).ConfigureAwait(false);
            return tree is null ? (null, null) : (tree, await c.GetProductInfoAsync(ct).ConfigureAwait(false));
        });
        var escl = Try<(ScannerCapabilities?, Uri?)>(async () =>
        {
            foreach (var root in new[] { http.Http("/eSCL/"), esclHint }.OfType<Uri>().Distinct())
            {
                var caps = await Try(() => new EsclClient(http, root).GetCapabilitiesAsync(ct)).ConfigureAwait(false);
                if (caps is not null) return (caps, root);
            }
            return (null, null);
        });
        var ipp = Try(() => new IppClient(http).GetPrinterAttributesAsync(ct: ct));
        await Task.WhenAll(ledm, escl, ipp).ConfigureAwait(false);

        var (tree, product) = ledm.Result;
        var (scanner, esclRoot) = escl.Result;
        return new ProbeResult(http.Host, tree, product, scanner, esclRoot, ipp.Result is { Ok: true } r ? r : null);
    }

    public async Task<PrinterStatus> GetStatusAsync(CancellationToken ct = default)
    {
        try
        {
            if (Ledm is not null && await Ledm.GetStatusAsync(ct).ConfigureAwait(false) is { } s) return s;
            if (Ipp is not null) return IppClient.ToStatus(await Ipp.GetPrinterAttributesAsync(ct: ct).ConfigureAwait(false));
            return new PrinterStatus("unknown", "Status not available", Severity.Info, []);
        }
        catch (Exception ex) when (IsOffline(ex))
        {
            return PrinterStatus.Offline("Printer is not responding");
        }
    }

    public async Task<IReadOnlyList<Consumable>> GetSuppliesAsync(CancellationToken ct = default)
    {
        if (Ledm is not null && await Ledm.GetConsumablesAsync(ct).ConfigureAwait(false) is { } c) return c;
        if (Ipp is not null) return IppClient.ToConsumables(await Ipp.GetPrinterAttributesAsync(ct: ct).ConfigureAwait(false));
        return [];
    }

    /// <summary>
    /// Yields whenever status may have changed: on LEDM device events (long poll) or, for printers
    /// without events, every <paramref name="fallbackInterval"/>.
    /// </summary>
    public async IAsyncEnumerable<string> WatchAsync(TimeSpan fallbackInterval, [EnumeratorCancellation] CancellationToken ct = default)
    {
        if (Ledm is not null && Probe.Ledm?.HasEvents == true)
        {
            await foreach (var events in Ledm.WatchEventsAsync(ct).ConfigureAwait(false))
                yield return events.Count > 0 ? events[^1].Category : "changed";
            yield break;
        }
        using var timer = new PeriodicTimer(fallbackInterval);
        while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            yield return "tick";
    }

    public static bool IsOffline(Exception ex) => ex is HttpRequestException or TimeoutException;

    private static async Task<T?> Try<T>(Func<Task<T>> f)
    {
        try { return await f().ConfigureAwait(false); }
        catch (Exception ex) when (ex is HttpRequestException or TimeoutException or DeviceHttpException or System.Xml.XmlException or FormatException)
        {
            return default;
        }
    }

    public void Dispose() => Http.Dispose();
}
