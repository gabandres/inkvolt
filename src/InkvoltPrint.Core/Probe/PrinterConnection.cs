using System.Runtime.CompilerServices;
using InkvoltPrint.Core.Cdm;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;

namespace InkvoltPrint.Core.Probe;

/// <summary>Which interfaces a printer answered on. Probed once, in parallel, with short timeouts.</summary>
public sealed record ProbeResult(
    string Host,
    DiscoveryTree? Ledm,
    ProductInfo? Product,
    ScannerCapabilities? Scanner,
    Uri? EsclRoot,
    IppResponse? Ipp)
{
    /// <summary>The URL IPP answered on (null when it didn't).</summary>
    public Uri? IppEndpoint { get; init; }

    /// <summary>HP's newer interface (CDM) answered: a newer HP printer without LEDM. Only asked when LEDM isn't there.</summary>
    public CdmProbe? Cdm { get; init; }

    public bool Reachable => Ledm is not null || Scanner is not null || Ipp is not null || Cdm is not null;

    public string? Uuid =>
        Product?.Uuid ?? Scanner?.Uuid ?? Ipp?.Str("printer-uuid")?.Replace("urn:uuid:", "", StringComparison.OrdinalIgnoreCase);

    /// <summary>Every UUID the printer reports, one per interface (they normally agree; a scanner may have its own).</summary>
    public IReadOnlyList<string?> ReportedUuids => [Product?.Uuid, Cdm?.Identity.Uuid, Scanner?.Uuid, Ipp?.Str("printer-uuid")];

    public string? Model => Product?.MakeAndModel ?? Scanner?.MakeAndModel ?? Ipp?.Str("printer-make-and-model");

    public FirmwareInfo? Firmware => FirmwareInfo.From(Product, Ipp);

    /// <summary>HP's own interfaces answered (LEDM): settings, firmware updates and usage counters work. Other printers get IPP and eSCL only.</summary>
    public bool HasHpInterfaces => Ledm is not null;

    /// <summary>Who made it: HP when LEDM or CDM answers, else from the make-and-model the printer reports.</summary>
    public PrinterBrand Brand => HasHpInterfaces || Cdm is not null ? PrinterBrand.Hp
        : PrinterBrands.Detect(Ipp?.Str("printer-make-and-model"), Scanner?.MakeAndModel, Scanner?.Manufacturer);

    /// <summary>IPP <c>printer-location</c>, when someone set it on the printer.</summary>
    public string? Location => Ipp?.Str("printer-location") is { } l && l.Trim().Length > 0 ? l.Trim() : null;

    /// <summary>
    /// The printer's own web page: IPP <c>printer-more-info</c> when it is an http(s) page on this printer (the address
    /// comes from the network, so never another host), else null (callers fall back to <c>https://host/</c>).
    /// </summary>
    public Uri? WebPage => Ipp?.Str("printer-more-info") is { } s ? OnThisPrinter(s) : null;

    /// <summary>
    /// IPP <c>printer-icons</c> (PWG 5100.13: 48, 128 and 512 px PNGs, in that order) on this printer, the 128 px one first
    /// (the app shows it at up to 256 px), then the larger, then the smaller.
    /// </summary>
    public IReadOnlyList<Uri> Icons
    {
        get
        {
            var icons = Ipp?.Strs("printer-icons").Select(OnThisPrinter).OfType<Uri>().ToList() ?? [];
            return icons.Count < 2 ? icons : [.. icons.Skip(1), icons[0]];
        }
    }

    /// <summary>An http(s) URL from the printer's replies, only when it points back at this printer (never another host).</summary>
    private Uri? OnThisPrinter(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) && (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps)
        && string.Equals(u.IdnHost, Host, StringComparison.OrdinalIgnoreCase) && u.UserInfo.Length == 0
            ? u : null;

    public IEnumerable<string> Interfaces
    {
        get
        {
            if (Ledm is not null) yield return "LEDM";
            if (Ledm?.HasCdm == true || Cdm is not null) yield return "CDM";
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
        Ipp = probe.Ipp is not null ? new IppClient(http, probe.IppEndpoint ?? DefaultIpp(http)) : null;
        Cdm = probe.Cdm is { } cdm ? new CdmClient(http, cdm.Root) : null;
    }

    public DeviceHttp Http { get; }
    public ProbeResult Probe { get; }
    public LedmClient? Ledm { get; }
    public EsclClient? Scanner { get; }
    public IppClient? Ipp { get; }

    /// <summary>HP CDM, read only, for newer HP printers without LEDM: status, supplies and identity.</summary>
    public CdmClient? Cdm { get; }

    /// <param name="esclHint">eSCL base from DNS-SD (<c>rs</c> TXT + port), tried if <c>http://host/eSCL/</c> fails.</param>
    /// <param name="transport">Replaces the network (e.g. <see cref="FixtureHandler"/> for demo mode); null: real HTTP.</param>
    /// <param name="ippHint">IPP printer URL from DNS-SD (<c>rp</c> TXT + port, https for <c>_ipps</c>), tried first.</param>
    public static async Task<PrinterConnection> OpenAsync(string host, Uri? esclHint = null, CancellationToken ct = default,
        ICertificatePin? pin = null, HttpMessageHandler? transport = null, Uri? ippHint = null)
    {
        var http = new DeviceHttp(host, transport, pin);
        try
        {
            return new PrinterConnection(http, await ProbeAsync(http, esclHint, ct, ippHint).ConfigureAwait(false));
        }
        catch
        {
            http.Dispose();
            throw;
        }
    }

    public static async Task<ProbeResult> ProbeAsync(DeviceHttp http, Uri? esclHint = null, CancellationToken ct = default, Uri? ippHint = null)
    {
        var ledm = ProbeLedmAsync(http, ct);
        // CDM only when the printer clearly has no LEDM (see ProbeLedmAsync): an offline or waking printer costs nothing more,
        // and a printer with LEDM (all the HP printers LEDM covers) never gets a CDM request.
        var cdm = Try(async () => (await ledm.ConfigureAwait(false)).TryCdm ? await CdmClient.ProbeAsync(http, ct).ConfigureAwait(false) : null);
        var escl = Try<(ScannerCapabilities?, Uri?)>(async () =>
        {
            foreach (var root in new[] { http.Http("/eSCL/"), esclHint }.OfType<Uri>().Distinct())
            {
                var caps = await Try(() => new EsclClient(http, root).GetCapabilitiesAsync(ct)).ConfigureAwait(false);
                if (caps is not null) return (caps, root);
            }
            return (null, null);
        });
        var ipp = ProbeIppAsync(http, ippHint, ct);
        await Task.WhenAll(ledm, escl, ipp, cdm).ConfigureAwait(false);

        var (tree, product, _) = ledm.Result;
        var (scanner, esclRoot) = escl.Result;
        var (attrs, endpoint) = ipp.Result;
        return new ProbeResult(http.Host, tree, product ?? cdm.Result?.Identity, scanner, esclRoot, attrs) { IppEndpoint = endpoint, Cdm = cdm.Result };
    }

    /// <summary>
    /// The DiscoveryTree and product info. <c>TryCdm</c> only when the printer clearly has no LEDM: the DiscoveryTree is 404,
    /// plain HTTP is refused, or the tree's address redirects somewhere that isn't LEDM (<c>/DevMgmt/</c>). A 5xx, 401 or
    /// any other error page, or a timeout, is an LEDM printer waking up or busy: no CDM, the connection tries again later.
    /// </summary>
    internal static async Task<(DiscoveryTree?, ProductInfo?, bool TryCdm)> ProbeLedmAsync(DeviceHttp http, CancellationToken ct)
    {
        try
        {
            var c = new LedmClient(http);
            var tree = await c.GetTreeAsync(ct).ConfigureAwait(false);
            return tree is null ? (null, null, true) : (tree, await c.GetProductInfoAsync(ct).ConfigureAwait(false), false);
        }
        catch (HttpRequestException ex) when (Refused(ex))
        {
            return (null, null, true);
        }
        catch (DeviceHttpException ex) when ((int)ex.Status is >= 300 and < 400)
        {
            var to = ex.Location is null ? null : ex.Location.IsAbsoluteUri ? ex.Location : new Uri(http.HttpBase, ex.Location);
            return (null, null, to is not null && !to.AbsolutePath.StartsWith("/DevMgmt/", StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception ex) when (IsOffline(ex) || IsTransient(ex))
        {
            return (null, null, false);
        }
    }

    private static Uri DefaultIpp(DeviceHttp http) => new UriBuilder(Uri.UriSchemeHttp, http.Host, 631, "ipp/print").Uri;

    /// <summary>The whole IPP probe gets what one request used to: an offline printer costs no more than before.</summary>
    internal static readonly TimeSpan IppProbeDeadline = DeviceHttp.DefaultTimeout;

    /// <summary>
    /// The DNS-SD hint (only on this host) and <c>http://host:631/ipp/print</c> (IPP Everywhere's path) at the same time;
    /// the first that answers wins. When plain HTTP is refused outright, the same path over TLS: some printers only take
    /// IPPS once their HTTP is switched off. All of it within <see cref="IppProbeDeadline"/>.
    /// </summary>
    private static async Task<(IppResponse?, Uri?)> ProbeIppAsync(DeviceHttp http, Uri? hint, CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(IppProbeDeadline);
        var plain = DefaultIpp(http);
        var candidates = new List<Uri> { plain };
        if (hint is not null && hint != plain && string.Equals(hint.Host, http.Host, StringComparison.OrdinalIgnoreCase)
                             && (hint.Scheme == Uri.UriSchemeHttp || hint.Scheme == Uri.UriSchemeHttps))
            candidates.Insert(0, hint);
        var attempts = candidates.Select(Attempt).ToList();
        var pending = attempts.ToList();
        try
        {
            while (pending.Count > 0)
            {
                var done = await Task.WhenAny(pending).ConfigureAwait(false);
                pending.Remove(done);
                if (await done.ConfigureAwait(false) is ({ } r, { } uri)) return (r, uri);
            }
            return (null, null);
        }
        finally
        {
            await deadline.CancelAsync().ConfigureAwait(false); // the slower attempt stops; wait so nothing outlives the token
            await Task.WhenAll(attempts).ConfigureAwait(false);
        }

        async Task<(IppResponse?, Uri?)> Attempt(Uri uri)
        {
            try
            {
                return await Read(uri).ConfigureAwait(false);
            }
            catch (HttpRequestException ex) when (uri == plain && Refused(ex))
            {
                var tls = new UriBuilder(plain) { Scheme = Uri.UriSchemeHttps }.Uri;
                try { return await Read(tls).ConfigureAwait(false); }
                catch (Exception e) when (Missed(e)) { return (null, null); }
            }
            catch (Exception ex) when (Missed(ex))
            {
                return (null, null);
            }
        }

        async Task<(IppResponse?, Uri?)> Read(Uri uri) =>
            await new IppClient(http, uri).GetPrinterAttributesAsync(ct: deadline.Token).ConfigureAwait(false) is { Ok: true } r ? (r, uri) : (null, null);

        // Offline, garbage, the deadline, or the other attempt won; the caller's own cancellation still propagates.
        bool Missed(Exception ex) => IsOffline(ex) || IsTransient(ex) || (ex is OperationCanceledException && !ct.IsCancellationRequested);
    }

    private static bool Refused(HttpRequestException ex) =>
        ex.HttpRequestError == HttpRequestError.ConnectionError
        && ex.InnerException is System.Net.Sockets.SocketException { SocketErrorCode: System.Net.Sockets.SocketError.ConnectionRefused };

    /// <summary>
    /// LEDM first, then CDM (newer HP printers), IPP as fallback. Network failures mean offline; a printer that answers with an error or
    /// garbage (common while it wakes up) is reported as <see cref="PrinterStatus.Unavailable"/>, not offline.
    /// </summary>
    public async Task<PrinterStatus> GetStatusAsync(CancellationToken ct = default)
    {
        Exception? transient = null;
        if (Ledm is not null)
        {
            try
            {
                if (await Ledm.GetStatusAsync(ct).ConfigureAwait(false) is { } s) return s;
            }
            catch (Exception ex) when (IsOffline(ex)) { return PrinterStatus.Offline("Printer is not responding"); }
            catch (Exception ex) when (IsTransient(ex)) { transient = ex; }
        }
        if (Cdm is not null)
        {
            try
            {
                if (await Cdm.GetStatusAsync(ct).ConfigureAwait(false) is { } s) return s;
            }
            catch (Exception ex) when (IsOffline(ex)) { return PrinterStatus.Offline("Printer is not responding"); }
            catch (Exception ex) when (IsTransient(ex)) { transient ??= ex; }
        }
        if (Ipp is not null)
        {
            try
            {
                return IppClient.ToStatus(await Ipp.GetPrinterAttributesAsync(ct: ct).ConfigureAwait(false));
            }
            catch (Exception ex) when (IsOffline(ex)) { return PrinterStatus.Offline("Printer is not responding"); }
            catch (Exception ex) when (IsTransient(ex)) { transient ??= ex; }
        }
        return transient is not null
            ? PrinterStatus.Unavailable("The printer is busy; status will update shortly")
            : new PrinterStatus("unknown", "Status not available", Severity.Info, []);
    }

    public async Task<IReadOnlyList<Consumable>> GetSuppliesAsync(CancellationToken ct = default)
    {
        if (Ledm is not null && await Ledm.GetConsumablesAsync(ct).ConfigureAwait(false) is { } c) return c;
        if (Cdm is not null && await Cdm.GetSuppliesAsync(ct).ConfigureAwait(false) is { Count: > 0 } cdm) return cdm;
        if (Ipp is not null) return IppClient.ToConsumables(await Ipp.GetPrinterAttributesAsync(ct: ct).ConfigureAwait(false));
        return [];
    }

    /// <summary>
    /// Yields whenever status may have changed: on LEDM device events (long poll) or, for printers
    /// without events, once right away and then every <paramref name="fallbackInterval"/>.
    /// </summary>
    public async IAsyncEnumerable<string> WatchAsync(TimeSpan fallbackInterval, [EnumeratorCancellation] CancellationToken ct = default)
    {
        if (Ledm is not null && Probe.Ledm?.HasEvents == true)
        {
            await foreach (var events in Ledm.WatchEventsAsync(ct).ConfigureAwait(false))
                yield return events.Count > 0 ? events[^1].Category : "changed";
            yield break;
        }
        yield return "start"; // read once right away; IPP-only printers (Canon, Epson, Brother…) have no event feed
        using var timer = new PeriodicTimer(fallbackInterval);
        while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            yield return "tick";
    }

    public static bool IsOffline(Exception ex) => ex is HttpRequestException or TimeoutException;

    /// <summary>The printer answered, but with an error status or an unreadable body.</summary>
    public static bool IsTransient(Exception ex) => ex is DeviceHttpException or System.Xml.XmlException or FormatException;

    private static async Task<T?> Try<T>(Func<Task<T>> f)
    {
        try { return await f().ConfigureAwait(false); }
        catch (Exception ex) when (IsOffline(ex) || IsTransient(ex))
        {
            return default;
        }
    }

    public void Dispose() => Http.Dispose();
}
