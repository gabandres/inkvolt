using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Xml.Linq;
using PrintDesk.Core.Model;
using PrintDesk.Core.Net;

namespace PrintDesk.Core.Ledm;

/// <summary>
/// HP LEDM (XML over HTTP). Resource URIs come from the DiscoveryTree, not hard-coded paths.
/// Reads go over plain HTTP; writes go over HTTPS so admin credentials never cross the LAN in clear text.
/// </summary>
public sealed class LedmClient(DeviceHttp http)
{
    /// <summary>Long-poll window the printer holds an EventTable request open (deciseconds on the wire).</summary>
    public static readonly TimeSpan EventWait = TimeSpan.FromSeconds(60);

    private DiscoveryTree? _tree;
    private readonly Dictionary<string, XDocument> _capCache = new(StringComparer.Ordinal);

    public DeviceHttp Http => http;

    /// <summary>Null when the device does not speak LEDM.</summary>
    public async Task<DiscoveryTree?> GetTreeAsync(CancellationToken ct = default)
    {
        if (_tree is not null) return _tree;
        var bytes = await http.GetBytesOrNullAsync(http.Http(DiscoveryTree.Path), ct: ct).ConfigureAwait(false);
        if (bytes is null) return null;
        return _tree = DiscoveryTree.Parse(Load(bytes));
    }

    /// <summary>Fetch a resource by LEDM type. Returns null if the device does not expose it. *Cap resources are cached.</summary>
    public async Task<XDocument?> GetAsync(string resourceType, CancellationToken ct = default)
    {
        if (_capCache.TryGetValue(resourceType, out var cached)) return cached;
        var tree = await GetTreeAsync(ct).ConfigureAwait(false);
        if (tree?.UriFor(resourceType) is not { } path) return null;
        var bytes = await http.GetBytesOrNullAsync(http.Http(path), ct: ct).ConfigureAwait(false);
        if (bytes is null) return null;
        var doc = Load(bytes);
        if (resourceType.EndsWith("Cap", StringComparison.Ordinal)) _capCache[resourceType] = doc;
        return doc;
    }

    public async Task<PrinterStatus?> GetStatusAsync(CancellationToken ct = default) =>
        await GetAsync(LedmResource.ProductStatusDyn, ct).ConfigureAwait(false) is { } d ? LedmParsers.ParseStatus(d) : null;

    public async Task<ProductInfo?> GetProductInfoAsync(CancellationToken ct = default) =>
        await GetAsync(LedmResource.ProductConfigDyn, ct).ConfigureAwait(false) is { } d ? LedmParsers.ParseProductConfig(d) : null;

    public async Task<UsageCounters?> GetUsageAsync(CancellationToken ct = default) =>
        await GetAsync(LedmResource.ProductUsageDyn, ct).ConfigureAwait(false) is { } d ? LedmParsers.ParseUsage(d) : null;

    public async Task<IReadOnlyList<Consumable>?> GetConsumablesAsync(CancellationToken ct = default)
    {
        var supplies = GetAsync(LedmResource.ConsumableConfigDyn, ct);
        var usage = GetAsync(LedmResource.ProductUsageDyn, ct);
        await Task.WhenAll(supplies, usage).ConfigureAwait(false);
        return supplies.Result is { } s ? LedmParsers.ParseConsumables(s, usage.Result) : null;
    }

    /// <summary>
    /// Yields each time the printer's event table changes. Uses the device's delayed-reply long poll
    /// (<c>?timeout=</c> + <c>If-None-Match</c>), so an idle printer costs one request per minute, not a poll loop.
    /// The first table is yielded immediately; an empty list is yielded once when the printer stops answering.
    /// </summary>
    public async IAsyncEnumerable<IReadOnlyList<LedmEvent>> WatchEventsAsync([EnumeratorCancellation] CancellationToken ct = default)
    {
        var tree = await GetTreeAsync(ct).ConfigureAwait(false);
        if (tree?.UriFor(LedmResource.EventTable) is not { } path) yield break;

        string? etag = null;
        var backoff = TimeSpan.FromSeconds(2);
        var wait = (int)(EventWait.TotalMilliseconds / 100);
        var wasFailing = false;
        while (!ct.IsCancellationRequested)
        {
            IReadOnlyList<LedmEvent>? events = null;
            var failed = false;
            try
            {
                var uri = etag is null ? http.Http(path) : http.Http($"{path}?timeout={wait}");
                using var req = new HttpRequestMessage(HttpMethod.Get, uri);
                if (etag is not null) req.Headers.TryAddWithoutValidation("If-None-Match", etag);
                using var resp = await http.SendAsync(req, EventWait + TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
                if (resp.StatusCode != HttpStatusCode.NotModified)
                {
                    await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
                    // HP sends unquoted ETags ("34-2"), which the typed header parser rejects.
                    etag = resp.Headers.NonValidated.TryGetValues("ETag", out var v) ? v.FirstOrDefault() : null;
                    events = LedmParsers.ParseEventTable(Load(await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false)));
                }
                backoff = TimeSpan.FromSeconds(2);
                if (wasFailing) { wasFailing = false; etag = null; }
            }
            catch (Exception ex) when (ex is HttpRequestException or TimeoutException or DeviceHttpException)
            {
                failed = true;
            }

            if (events is not null) yield return events;
            if (failed)
            {
                // Tell the caller once per outage so it can re-read status (and show "offline").
                if (!wasFailing) yield return [];
                wasFailing = true;
                await Task.Delay(backoff, ct).ConfigureAwait(false);
                backoff = TimeSpan.FromTicks(Math.Min(backoff.Ticks * 2, TimeSpan.FromSeconds(30).Ticks));
            }
            else if (etag is null)
            {
                // Device gave no ETag: long poll impossible, fall back to a slow refresh.
                await Task.Delay(TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
            }
        }
    }

    /// <summary>PUT a partial LEDM document. Throws <see cref="LedmAuthRequiredException"/> on 401/403.</summary>
    public async Task PutAsync(string resourceType, XDocument body, CancellationToken ct = default)
    {
        var tree = await GetTreeAsync(ct).ConfigureAwait(false);
        var path = tree?.UriFor(resourceType) ?? throw new InvalidOperationException($"Printer does not expose {resourceType}");
        var xml = body.Declaration is null ? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + body.ToString(SaveOptions.DisableFormatting) : body.ToString(SaveOptions.DisableFormatting);
        using var req = new HttpRequestMessage(HttpMethod.Put, http.Https(path))
        {
            Content = new StringContent(xml, Encoding.UTF8, new MediaTypeHeaderValue("text/xml")),
        };
        using var resp = await http.SendAsync(req, TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
        if (resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new LedmAuthRequiredException(http.HasCredentials);
        await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
    }

    private static XDocument Load(byte[] bytes)
    {
        using var ms = new MemoryStream(bytes);
        return XDocument.Load(ms);
    }
}

public sealed class LedmAuthRequiredException(bool credentialsWereSent)
    : Exception(credentialsWereSent ? "The printer rejected the admin password." : "The printer requires its admin password.")
{
    public bool CredentialsWereSent { get; } = credentialsWereSent;
}
