using System.Globalization;
using System.Net;
using System.Text;
using System.Web;
using System.Xml.Linq;
using InkvoltPrint.Core.Ledm;

namespace InkvoltPrint.Core.Net;

/// <summary>
/// A made-up HP printer panel's Scan to Computer list (demo mode and tests), in front of a printer's documents (a
/// <see cref="FixtureHandler"/>): its DiscoveryTree gains the walk-up interface (<see cref="LedmWalkupScan"/>'s assumed names), the
/// list holds the computers POSTed to it until they're DELETEd or the printer "restarts" (<see cref="PowerUp"/>), and
/// <see cref="Press"/> is someone choosing a computer on the panel and pressing Scan: a scan event in the EventTable (whose long
/// poll answers at once on a change) and the event document's type. The list, manifest and event documents themselves are the
/// fixtures' (<c>Fixtures/hp-demo</c>, written by hand). Never opens a socket.
/// </summary>
public sealed class FakeScanToComputer(HttpMessageHandler documents, bool inTree = true) : DelegatingHandler(documents)
{
    public const string ManifestPath = "/WalkupScanToComp/WalkupScanToCompManifest.xml", ListPath = "/WalkupScanToComp/WalkupScanToCompDestinations",
        EventPath = "/WalkupScanToComp/WalkupScanToCompEvent";

    private const string TreePath = "/DevMgmt/DiscoveryTree.xml", TablePath = "/EventMgmt/EventTable.xml";

    private readonly Lock _gate = new();
    private readonly List<(int Id, string Name, string Host)> _listed = [];
    private readonly Dictionary<string, (int Stamp, string[] Uris)> _events = new(StringComparer.Ordinal);
    private TaskCompletionSource _changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _next = 1, _version = 1, _stamp = 100;
    private string? _eventType;

    /// <summary>What a POST to the list gets instead of 201 (401 for an admin password, 400…); null: the PC is added.</summary>
    public HttpStatusCode? PostAnswer { get; set; }

    /// <summary>What a GET of the EventTable gets instead of the table (503: as if it weren't answering); null: the table.</summary>
    public HttpStatusCode? TableAnswer { get; set; }

    /// <summary>What a GET of the list gets instead of the list (503: busy for now); null: the list.</summary>
    public HttpStatusCode? ListAnswer { get; set; }

    /// <summary>A POST adds the computer and then gets this instead of 201 (its answer lost: 503, say); null: 201.</summary>
    public HttpStatusCode? AddedThenAnswer { get; set; }

    /// <summary>A 201 without a <c>Location</c> (the list then says where it went).</summary>
    public bool NoLocation { get; set; }

    /// <summary>Every POST and DELETE, in order: method and path.</summary>
    public List<string> Writes { get; } = [];

    /// <summary>The names on the list now.</summary>
    public IReadOnlyList<string> Names
    {
        get { lock (_gate) return [.. _listed.Select(l => l.Name)]; }
    }

    /// <summary>The destinations' paths on the list now.</summary>
    public IReadOnlyList<string> Paths
    {
        get { lock (_gate) return [.. _listed.Select(l => $"{ListPath}/{l.Id}")]; }
    }

    /// <summary>The host names on the list now (this app's carry its marker).</summary>
    public IReadOnlyList<string> Hosts
    {
        get { lock (_gate) return [.. _listed.Select(l => l.Host)]; }
    }

    /// <summary>A computer already on the list (another PC, HP's software for this one, or with <paramref name="host"/> an earlier run of this app's). Its path.</summary>
    public string Add(string name, string? host = null)
    {
        lock (_gate)
        {
            _listed.Add((_next, name, host ?? name));
            return $"{ListPath}/{_next++}";
        }
    }

    /// <summary>
    /// Someone picks <paramref name="destination"/> (default: the last computer added) on the panel and presses Scan: the event
    /// document says <paramref name="type"/> and the EventTable gets a new scan event naming the destination. False when the list
    /// is empty.
    /// </summary>
    public bool Press(string? destination = null, string type = "ScanRequested")
    {
        lock (_gate)
        {
            if (destination is null && _listed.Count == 0) return false;
            destination ??= $"{ListPath}/{_listed[^1].Id}";
            _eventType = type;
            Changed(LedmWalkupScan.Names.ScanEventCategory, [destination, EventPath]);
        }
        return true;
    }

    /// <summary>The printer restarts: its list is empty and its EventTable says it powered up.</summary>
    public void PowerUp()
    {
        lock (_gate)
        {
            _listed.Clear();
            Changed(LedmWalkupScan.PowerUpCategory, ["/DevMgmt/ProductStatusDyn.xml"]);
        }
    }

    private void Changed(string category, string[] uris)
    {
        _events[category] = (++_stamp, uris);
        _version++;
        var changed = _changed;
        _changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        changed.TrySetResult();
    }

    private string ETag
    {
        get { lock (_gate) return "fake-" + _version.ToString(CultureInfo.InvariantCulture); }
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var path = request.RequestUri!.AbsolutePath;
        var method = request.Method;
        if (method == HttpMethod.Get && path == TreePath && inTree) return await TreeAsync(request, ct).ConfigureAwait(false);
        if (method == HttpMethod.Get && path == TablePath)
            return TableAnswer is { } down ? Reply(request, down) : await TableAsync(request, ct).ConfigureAwait(false);
        if (!inTree) return await base.SendAsync(request, ct).ConfigureAwait(false);
        if (method == HttpMethod.Get && path == ListPath)
            return ListAnswer is { } failing ? Reply(request, failing) : await ListAsync(request, ct).ConfigureAwait(false);
        if (method == HttpMethod.Get && path == EventPath) return await EventAsync(request, ct).ConfigureAwait(false);
        if (method == HttpMethod.Post && path == ListPath)
        {
            lock (_gate) Writes.Add($"POST {path}");
            if (PostAnswer is { } refused) return Reply(request, refused);
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            var posted = XDocument.Parse(body).Root?.Elements().ToList() ?? [];
            var name = posted.FirstOrDefault(e => e.Name.LocalName == LedmWalkupScan.Names.Name)?.Value ?? "?";
            var host = posted.FirstOrDefault(e => e.Name.LocalName == LedmWalkupScan.Names.Hostname)?.Value ?? name;
            int id;
            lock (_gate)
            {
                id = _next++;
                _listed.Add((id, name, host));
            }
            if (AddedThenAnswer is { } lost) return Reply(request, lost);
            var created = Reply(request, HttpStatusCode.Created);
            if (!NoLocation) created.Headers.Location = new Uri(request.RequestUri, $"{ListPath}/{id}");
            return created;
        }
        if (method == HttpMethod.Delete && path.StartsWith(ListPath + "/", StringComparison.Ordinal))
        {
            bool removed;
            lock (_gate)
            {
                Writes.Add($"DELETE {path}");
                removed = int.TryParse(path[(ListPath.Length + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var id) && _listed.RemoveAll(l => l.Id == id) > 0;
            }
            return Reply(request, removed ? HttpStatusCode.OK : HttpStatusCode.NotFound);
        }
        return await base.SendAsync(request, ct).ConfigureAwait(false);
    }

    /// <summary>The printer's tree with the walk-up interface listed (a <c>SupportedIfc</c>, as the tree lists its other manifests).</summary>
    private async Task<HttpResponseMessage> TreeAsync(HttpRequestMessage request, CancellationToken ct)
    {
        using var inner = await base.SendAsync(request, ct).ConfigureAwait(false);
        if (!inner.IsSuccessStatusCode) return Reply(request, inner.StatusCode);
        var doc = DeviceXml.Load(await inner.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));
        var root = doc.Root!;
        XNamespace ledm = root.Name.Namespace, dd = LedmWalkupScan.DictionaryNamespace;
        root.Add(new XElement(ledm + "SupportedIfc",
            new XElement(ledm + "ManifestURI", ManifestPath),
            new XElement(dd + "ResourceType", LedmWalkupScan.Names.Interface),
            new XElement(dd + "Revision", "demo")));
        return Xml(request, doc);
    }

    /// <summary>The fixture's list with the computers on it now.</summary>
    private async Task<HttpResponseMessage> ListAsync(HttpRequestMessage request, CancellationToken ct)
    {
        using var inner = await base.SendAsync(request, ct).ConfigureAwait(false);
        if (!inner.IsSuccessStatusCode) return Reply(request, inner.StatusCode);
        var doc = DeviceXml.Load(await inner.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));
        var root = doc.Root!;
        XNamespace wus = root.Name.Namespace, dd = LedmWalkupScan.DictionaryNamespace, dd3 = LedmWalkupScan.Names.HostnameNamespace;
        var n = LedmWalkupScan.Names;
        lock (_gate)
            foreach (var (id, name, host) in _listed)
                root.Add(new XElement(wus + n.Destination,
                    new XElement(dd + n.ResourceUri, $"{ListPath}/{id}"),
                    new XElement(dd + n.Name, name),
                    new XElement(dd3 + n.Hostname, host),
                    new XElement(wus + n.LinkType, n.LinkTypeValue)));
        return Xml(request, doc);
    }

    /// <summary>The fixture's event document, saying what was last pressed.</summary>
    private async Task<HttpResponseMessage> EventAsync(HttpRequestMessage request, CancellationToken ct)
    {
        using var inner = await base.SendAsync(request, ct).ConfigureAwait(false);
        if (!inner.IsSuccessStatusCode) return Reply(request, inner.StatusCode);
        var doc = DeviceXml.Load(await inner.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));
        string? type;
        lock (_gate) type = _eventType;
        if (type is not null && doc.Root!.Elements().FirstOrDefault(e => e.Name.LocalName == LedmWalkupScan.Names.EventType) is { } element) element.Value = type;
        return Xml(request, doc);
    }

    /// <summary>
    /// The fixture's EventTable with this panel's events (one per category, the latest), under an ETag that changes with them. A
    /// long poll (<c>If-None-Match</c>) on the current one is held until something changes or its <c>timeout</c> runs out (304).
    /// </summary>
    private async Task<HttpResponseMessage> TableAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var asked = request.Headers.TryGetValues("If-None-Match", out var tags) ? tags.FirstOrDefault() : null;
        if (asked is null) return await TableNowAsync(request, ct).ConfigureAwait(false);
        var open = Interlocked.Increment(ref _polls);
        lock (_gate) MostPolls = Math.Max(MostPolls, open);
        try
        {
            return await LongPollAsync(request, asked, ct).ConfigureAwait(false);
        }
        finally
        {
            Interlocked.Decrement(ref _polls);
        }
    }

    private int _polls;

    /// <summary>The most EventTable long polls held open at once (one connection should hold one).</summary>
    public int MostPolls { get; private set; }

    private async Task<HttpResponseMessage> LongPollAsync(HttpRequestMessage request, string asked, CancellationToken ct)
    {
        if (asked == ETag)
        {
            Task changed;
            lock (_gate) changed = _changed.Task;
            var wait = int.TryParse(HttpUtility.ParseQueryString(request.RequestUri!.Query)["timeout"], out var ds) ? ds * 100 : 60_000;
            var timeout = Task.Delay(Math.Clamp(wait, 1_000, 600_000), ct);
            if (await Task.WhenAny(changed, timeout).ConfigureAwait(false) != changed)
            {
                ct.ThrowIfCancellationRequested();
                return Reply(request, HttpStatusCode.NotModified);
            }
        }
        return await TableNowAsync(request, ct).ConfigureAwait(false);
    }

    private async Task<HttpResponseMessage> TableNowAsync(HttpRequestMessage request, CancellationToken ct)
    {
        using var plain = new HttpRequestMessage(HttpMethod.Get, request.RequestUri!.GetLeftPart(UriPartial.Path));
        using var inner = await base.SendAsync(plain, ct).ConfigureAwait(false);
        if (!inner.IsSuccessStatusCode) return Reply(request, inner.StatusCode);
        var doc = DeviceXml.Load(await inner.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));
        var root = doc.Root!;
        XNamespace ev = root.Name.Namespace, dd = LedmWalkupScan.DictionaryNamespace;
        string etag;
        lock (_gate)
        {
            foreach (var (category, (stamp, uris)) in _events)
            {
                root.Elements().Where(e => e.Name.LocalName == "Event" && e.Elements().Any(c => c.Name.LocalName == "UnqualifiedEventCategory" && c.Value == category)).Remove();
                root.Add(new XElement(ev + "Event",
                    new XElement(dd + "UnqualifiedEventCategory", category),
                    new XElement(dd + "AgingStamp", $"{stamp}-1"),
                    uris.Select(u => new XElement(ev + "Payload", new XElement(dd + "ResourceURI", u)))));
            }
            etag = "fake-" + _version.ToString(CultureInfo.InvariantCulture);
        }
        var reply = Xml(request, doc);
        reply.Headers.TryAddWithoutValidation("ETag", etag);
        return reply;
    }

    private static HttpResponseMessage Xml(HttpRequestMessage request, XDocument doc) => new(HttpStatusCode.OK)
    {
        RequestMessage = request,
        Content = new ByteArrayContent(Encoding.UTF8.GetBytes(doc.ToString(SaveOptions.DisableFormatting))) { Headers = { ContentType = new("text/xml") } },
    };

    private static HttpResponseMessage Reply(HttpRequestMessage request, HttpStatusCode status) => new(status) { RequestMessage = request };
}
