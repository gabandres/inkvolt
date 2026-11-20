using System.Net.Http.Headers;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;

namespace InkvoltPrint.Core.Ipp;

public sealed class IppClient
{
    public static readonly string[] StatusAttributes =
    [
        "printer-state", "printer-state-reasons", "printer-state-message", "printer-make-and-model", "printer-uuid",
        "printer-info", "marker-names", "marker-levels", "marker-low-levels", "marker-high-levels", "marker-types", "marker-colors",
        "document-format-supported", "printer-firmware-name", "printer-firmware-string-version",
        "printer-alert", "printer-alert-description", "printer-location", "printer-more-info", "printer-icons",
        "printer-supply", "printer-impressions-completed",
    ];

    private readonly DeviceHttp _http;

    public IppClient(DeviceHttp http, string resourcePath = "ipp/print", int port = 631)
        : this(http, new UriBuilder(Uri.UriSchemeHttp, http.Host, port, resourcePath).Uri)
    {
    }

    /// <param name="endpoint">http(s) URL of the printer object, e.g. <c>http://host:631/ipp/print</c> (IPPS: https).</param>
    public IppClient(DeviceHttp http, Uri endpoint)
    {
        _http = http;
        Endpoint = endpoint;
    }

    public Uri Endpoint { get; }

    /// <summary>The <c>printer-uri</c> operation attribute: <c>ipp://</c> (or <c>ipps://</c>) for the endpoint's host, port and path.</summary>
    public string PrinterUri =>
        new UriBuilder(Endpoint.Scheme == Uri.UriSchemeHttps ? "ipps" : "ipp", Endpoint.Host, Endpoint.Port, Endpoint.AbsolutePath).Uri.AbsoluteUri;

    public Task<IppResponse> GetPrinterAttributesAsync(IEnumerable<string>? requested = null, CancellationToken ct = default) =>
        PostAsync(IppCodec.EncodeGetPrinterAttributes(PrinterUri, requested ?? StatusAttributes), TimeSpan.FromSeconds(5), ct);

    /// <summary>
    /// PWG 5100.13 Identify-Printer: the printer flashes, beeps or shows a message so it can be found. Sent once, never
    /// retried (on a connection of its own: <see cref="DeviceHttp.SendOnceAsync"/>); the caller reads the IPP status (a
    /// printer may want a signed-in user for it, §4.1).
    /// </summary>
    public Task<IppResponse> IdentifyPrinterAsync(IReadOnlyList<string> actions, string? userName, CancellationToken ct = default) =>
        PostAsync(IppCodec.EncodeIdentifyPrinter(PrinterUri, userName, actions), TimeSpan.FromSeconds(10), ct, once: true);

    /// <summary>
    /// Print-Job (RFC 8011 §4.2.1): <paramref name="request"/> (an <see cref="IppRequest"/>'s bytes) followed by the document,
    /// sent once and never again by the connection pool (a resend would print the job twice), with a time limit for a slow
    /// printer taking a large raster. Returns the job group of the answer.
    /// </summary>
    public async Task<IppResponse> PrintJobAsync(byte[] request, Stream document, TimeSpan timeout, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, Endpoint) { Content = new DocumentContent(request, document) };
        using var resp = await _http.SendOnceAsync(req, timeout, ct).ConfigureAwait(false);
        await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
        return IppCodec.Decode(await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false), IppCodec.JobTag);
    }

    /// <summary>Get-Job-Attributes (RFC 8011 §4.3.4): the job group.</summary>
    public Task<IppResponse> GetJobAttributesAsync(byte[] request, CancellationToken ct = default) =>
        PostAsync(request, TimeSpan.FromSeconds(5), ct, group: IppCodec.JobTag);

    /// <summary>Cancel-Job (RFC 8011 §4.3.3), sent once.</summary>
    public Task<IppResponse> CancelJobAsync(byte[] request, CancellationToken ct = default) =>
        PostAsync(request, TimeSpan.FromSeconds(10), ct, once: true, group: IppCodec.JobTag);

    /// <summary>Get-Jobs (RFC 8011 §4.2.6): the reply's bytes, one job group per job (<see cref="IppCodec.DecodeGroups"/>).</summary>
    public async Task<byte[]> GetJobsAsync(byte[] request, CancellationToken ct = default)
    {
        using var req = IppPost(request);
        using var resp = await _http.SendAsync(req, TimeSpan.FromSeconds(5), ct).ConfigureAwait(false);
        await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
        return await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
    }

    private HttpRequestMessage IppPost(byte[] body) => new(HttpMethod.Post, Endpoint)
    {
        Content = new ByteArrayContent(body) { Headers = { ContentType = new MediaTypeHeaderValue("application/ipp") } },
    };

    private async Task<IppResponse> PostAsync(byte[] body, TimeSpan timeout, CancellationToken ct, bool once = false, byte group = IppCodec.PrinterTag)
    {
        using var req = IppPost(body);
        using var resp = once ? await _http.SendOnceAsync(req, timeout, ct).ConfigureAwait(false)
            : await _http.SendAsync(req, timeout, ct).ConfigureAwait(false);
        await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
        return IppCodec.Decode(await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false), group);
    }

    /// <summary>An IPP request with a document after it, written straight from the document's stream (a raster can be hundreds of MB).</summary>
    private sealed class DocumentContent : HttpContent
    {
        private readonly byte[] _head;
        private readonly Stream _document;

        public DocumentContent(byte[] head, Stream document)
        {
            (_head, _document) = (head, document);
            Headers.ContentType = new MediaTypeHeaderValue("application/ipp");
        }

        protected override async Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context) =>
            await SerializeToStreamAsync(stream, context, CancellationToken.None).ConfigureAwait(false);

        protected override async Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context, CancellationToken ct)
        {
            await stream.WriteAsync(_head, ct).ConfigureAwait(false);
            await _document.CopyToAsync(stream, 1 << 16, ct).ConfigureAwait(false);
        }

        protected override bool TryComputeLength(out long length)
        {
            length = _document.CanSeek ? _head.Length + _document.Length - _document.Position : 0;
            return _document.CanSeek;
        }
    }

    /// <summary>Most supplies taken from a printer (a real one has a handful): a reply's bytes hold thousands, one card and history line each.</summary>
    public const int MaxSupplies = 64;

    /// <summary>Most problems read from each of <c>printer-state-reasons</c> and <c>printer-alert</c> (a real printer has a few).</summary>
    public const int MaxAlerts = 64;

    /// <summary>
    /// Status from <c>printer-state</c> and <c>printer-state-reasons</c>, plus <c>printer-alert</c> entries (PWG 5100.9) that
    /// no reason covers. Alerts matching a reason lend it their <c>printer-alert-description</c>s (the printer's own words,
    /// e.g. which colors are low), joined when several map to the same reason, and their severity when it is higher.
    /// Placeholder reasons ("none", "other") and change events are not problems.
    /// </summary>
    public static PrinterStatus ToStatus(IppResponse r)
    {
        var alerts = new List<PrinterAlert>();
        foreach (var x in r.Strs("printer-state-reasons").Take(MaxAlerts))
        {
            var (id, sev) = SplitReason(x);
            if (id is "none" or "other" || alerts.Any(a => a.Id == id)) continue;
            alerts.Add(new PrinterAlert(id, sev, IppStatusText.Describe(id)));
        }
        var descriptions = r.Strs("printer-alert-description").ToList();
        var texts = new Dictionary<string, List<string>>(StringComparer.Ordinal); // reason id → the printer's descriptions
        var i = -1;
        foreach (var value in r.Strs("printer-alert").Take(MaxAlerts))
        {
            i++;
            if (IppAlert.Parse(value) is not { } alert) continue;
            Severity? sev = alert.Severity switch { "critical" => Severity.Error, "warning" => Severity.Warning, _ => null };
            if (sev is null || alert.Code == "other") continue; // "other", "warningBinaryChangeEvent": nothing to fix
            var id = IppStatusText.ReasonForAlert(alert.Code) ?? alert.Code;
            var existing = alerts.FindIndex(a => a.Id == id);
            if (existing < 0) alerts.Add(new PrinterAlert(id, sev.Value, IppStatusText.Describe(id)));
            else if (sev.Value > alerts[existing].Severity) alerts[existing] = alerts[existing] with { Severity = sev.Value };
            if (i < descriptions.Count && descriptions[i].Trim() is { Length: > 0 } d)
            {
                if (!texts.TryGetValue(id, out var list)) texts[id] = list = [];
                if (!list.Contains(d, StringComparer.OrdinalIgnoreCase)) list.Add(d);
            }
        }
        for (var a = 0; a < alerts.Count; a++)
            if (texts.TryGetValue(alerts[a].Id, out var list))
                alerts[a] = alerts[a] with { Message = string.Join(" ", list.Select(t => t.EndsWith('.') || t.EndsWith('!') ? t : t + ".")) };
        var (code, label) = r.Int("printer-state") switch
        {
            3 => ("ready", CoreStrings.Status_Ready),
            4 => ("processing", CoreStrings.Status_Printing),
            5 => ("stopped", CoreStrings.Status_Stopped),
            _ => ("unknown", CoreStrings.Status_Unknown),
        };
        var severity = alerts.Count > 0 ? alerts.Max(a => a.Severity) : code == "stopped" ? Severity.Error : Severity.Info;
        var detail = alerts.Where(a => a.Severity == severity).Select(a => IppStatusText.Explain(a.Id)).FirstOrDefault(e => e is not null);
        var message = r.Str("printer-state-message");
        return new PrinterStatus(code, Headline(message, label), severity, alerts, detail) { PanelText = message };
    }

    /// <summary>
    /// The status line: the printer's <c>printer-state-message</c> when it says something, else the state in the app's
    /// words. A message that only restates the state ("Idle.", "Ready", "Printing") reads as the app's label, so every
    /// brand says "Ready" as HP does; a one-sentence message loses its final period, like the app's other headlines.
    /// </summary>
    public static string Headline(string? message, string label)
    {
        var m = message?.Trim() ?? "";
        if (m.EndsWith('.') && m.IndexOf('.') == m.Length - 1) m = m[..^1].TrimEnd();
        return m.Length == 0 || GenericStates.Contains(m) ? label : m;
    }

    private static readonly HashSet<string> GenericStates = new(StringComparer.OrdinalIgnoreCase)
    {
        "idle", "ready", "ready to print", "online", "printer is idle", "printing", "processing", "stopped", "none",
    };

    private static readonly (string Suffix, Severity Severity)[] Suffixes =
        [("-error", Severity.Error), ("-warning", Severity.Warning), ("-report", Severity.Info)];

    private static (string Id, Severity Severity) SplitReason(string x)
    {
        foreach (var (suffix, sev) in Suffixes)
            if (x.Length > suffix.Length && x.EndsWith(suffix, StringComparison.Ordinal)) return (x[..^suffix.Length], sev);
        return (x, IppStatusText.DefaultSeverity(x)); // RFC 8011 §5.4.12: no suffix is an error (but "low" is a warning)
    }

    /// <summary>
    /// Supplies from PWG 5100.13's parallel <c>marker-*</c> lists. Levels: 0-100 percent, -1 unavailable, -2 unknown,
    /// -3 "some left". Waste boxes (<c>waste-ink</c>, <c>waste-toner</c>…) report how full they are on some printers and
    /// how much room is left on others (CUPS turns one into the other), so they get no percentage: their state comes from
    /// the <c>marker-waste-*</c> reasons.
    /// </summary>
    public static IReadOnlyList<Consumable> ToConsumables(IppResponse r)
    {
        var names = r.Strs("marker-names").Take(MaxSupplies).ToList();
        var levels = r.Ints("marker-levels").ToList();
        var lows = r.Ints("marker-low-levels").ToList();
        var types = r.Strs("marker-types").ToList();
        var colors = r.Strs("marker-colors").ToList();
        var waste = r.Strs("printer-state-reasons").Select(x => SplitReason(x).Id)
            .Where(x => x.StartsWith("marker-waste", StringComparison.Ordinal)).ToList();
        var wasteState = waste.Any(x => !x.EndsWith("almost-full", StringComparison.Ordinal) && x.EndsWith("-full", StringComparison.Ordinal)) ? "full"
            : waste.Any(x => x.EndsWith("almost-full", StringComparison.Ordinal)) ? "almostFull"
            : "ok";
        // printer-supply describes the same supplies in the same order (CUPS makes the marker-* lists from it): only a list as
        // long as the markers is taken, so a page count never lands on another supply.
        var supplies = r.Strs("printer-supply").Take(MaxSupplies + 1).Select(IppSupply.Parse).ToList();
        if (supplies.Count != names.Count) supplies = [];
        return names.Select((n, i) =>
        {
            var kind = i < types.Count ? types[i] : "supply";
            var color = i < colors.Count ? ColorCode(colors[i]) : null;
            if (Consumable.IsWasteKind(kind)) return new Consumable(n, kind, color, null, wasteState, null, null, null, null, null);
            var raw = i < levels.Count ? levels[i] : -2;
            int? level = raw >= 0 ? Math.Min(raw, 100) : null;
            int? low = i < lows.Count && lows[i] >= 0 ? lows[i] : null;
            var state = raw == -3 ? "ok" : level is null ? "unknown" : level == 0 ? "out" : low is { } l && level <= l ? "low" : "ok";
            var pages = i < supplies.Count ? supplies[i] : null;
            return new Consumable(n, kind, color, level, state, null, null, low, pages?.PagesLeft, null) { PageYield = pages?.PageYield };
        }).ToList();
    }

    /// <summary>
    /// The lifetime page count: <c>printer-impressions-completed</c> (PWG 5100.22), what the supply history counts pages per
    /// cartridge with. Null when the printer doesn't say.
    /// </summary>
    public static UsageCounters? ToUsage(IppResponse r) =>
        r.Int("printer-impressions-completed") is >= 0 and var pages ? new UsageCounters(pages, null, null, null, null) : null;

    /// <summary>
    /// <c>marker-colors</c> value (<c>#RRGGBB</c>, several for a multi-color cartridge, or <c>none</c>) → K/C/M/Y for the
    /// process colors, <c>#RRGGBB</c> for others (the first color of a multi-color cartridge), null when there is no color.
    /// </summary>
    public static string? ColorCode(string value)
    {
        if (value.Length < 7 || value[0] != '#' || !Uri.IsHexDigit(value[1])) return null;
        for (var i = 1; i < 7; i++)
            if (!Uri.IsHexDigit(value[i])) return null;
        var hex = value[..7].ToUpperInvariant();
        if (value.Length > 7) return hex; // a multi-color cartridge: not one of the process colors
        return hex switch
        {
            "#000000" => "K",
            "#00FFFF" => "C",
            "#FF00FF" => "M",
            "#FFFF00" => "Y",
            _ => hex,
        };
    }
}
