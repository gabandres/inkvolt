using System.Xml.Linq;

namespace InkvoltPrint.Core.Ledm;

/// <summary>A computer on the printer's Scan to Computer list: its resource (a path on the printer) and the names it shows.</summary>
public sealed record WalkupDestination(string? Path, string? Name, string? Hostname);

/// <summary>
/// The element names <see cref="LedmWalkupScan"/> assumes, in one place. None of them has been seen on a printer: see its summary.
/// </summary>
/// <param name="Interface">The DiscoveryTree's <c>SupportedIfc</c> resource type whose manifest lists the interface.</param>
/// <param name="ListEntry">The manifest's element type of the destination list (unprefixed, as the captured FirmwareUpdate manifest names its own).</param>
/// <param name="EventEntry">The manifest's element type of the document that says what was pressed.</param>
/// <param name="ListRoot">The destination list's root element.</param>
/// <param name="Destination">One destination, in the list and as POSTed.</param>
/// <param name="Name">Its name (the dictionary namespace's <c>Name</c>); <paramref name="Hostname"/> and <paramref name="LinkType"/> as POSTed too.</param>
/// <param name="ResourceUri">Where a listed destination is (the captured documents' <c>dd:ResourceURI</c>).</param>
/// <param name="EventRoot">The event document's root, and <paramref name="EventType"/> its element that says what happened.</param>
/// <param name="ScanEventCategory">The EventTable category of a press (the captured table's categories are <c>PowerUpEvent</c>, <c>AlertTableChanged</c>).</param>
/// <param name="StartTypes">Event types that mean "scan now" (compared ignoring case). Choosing the computer alone doesn't count.</param>
/// <param name="HostnameNamespace">The namespace of <c>Hostname</c> when the printer's list shows none.</param>
internal sealed record WalkupNames(
    string Interface, string ListEntry, string EventEntry, string ListRoot, string Destination, string Name, string Hostname, string LinkType,
    string LinkTypeValue, string ResourceUri, string EventRoot, string EventType, string ScanEventCategory, IReadOnlyList<string> StartTypes,
    string HostnameNamespace);

/// <summary>
/// HP LEDM's walk-up scan destinations ("Scan to Computer" on the printer's panel): a computer adds itself to the printer's list
/// with one POST of a destination document and removes itself with a DELETE of the resource it got; when someone picks it on
/// the panel and presses Scan, the printer's EventTable gets a scan event naming that destination, and the event document says
/// what was pressed.
/// <para>
/// <b>Unconfirmed.</b> No printer that lists this interface has been recorded (the LaserJet MFP M234dw's DiscoveryTree
/// doesn't list it), so every name in <see cref="Names"/> is an assumption, laid out like the LEDM documents that were captured:
/// a <c>SupportedIfc</c> with a manifest (as FirmwareUpdate's), the dictionary namespace's <c>Name</c> and <c>ResourceURI</c>,
/// the EventTable's <c>Event</c> / <c>UnqualifiedEventCategory</c> / <c>AgingStamp</c> / <c>Payload</c>. A printer whose
/// documents don't match gets nothing (<see cref="Paths"/>, <see cref="Read"/> and <see cref="EventType"/> return null), so
/// nothing is POSTed on a guess; Record a printer saves the interface's documents, so one recording settles the names.
/// </para>
/// </summary>
public static class LedmWalkupScan
{
    /// <summary>The assumed names (see the class summary).</summary>
    internal static readonly WalkupNames Names = new(
        Interface: "wus:WalkupScanToCompManifest",
        ListEntry: "WalkupScanToCompDestinations",
        EventEntry: "WalkupScanToCompEvent",
        ListRoot: "WalkupScanToCompDestinations",
        Destination: "WalkupScanToCompDestination",
        Name: "Name",
        Hostname: "Hostname",
        LinkType: "LinkType",
        LinkTypeValue: "Network",
        ResourceUri: "ResourceURI",
        EventRoot: "WalkupScanToCompEvent",
        EventType: "WalkupScanToCompEventType",
        ScanEventCategory: "ScanEvent",
        StartTypes: ["ScanRequested"],
        HostnameNamespace: "http://www.hp.com/schemas/imaging/con/dictionaries/2009/04/06");

    /// <summary>The dictionary namespace every captured LEDM document uses (<c>dd:</c>).</summary>
    internal const string DictionaryNamespace = "http://www.hp.com/schemas/imaging/con/dictionaries/1.0/";

    /// <summary>The EventTable category of a printer that just started (captured: the M234dw's EventTable and EventCapabilities).</summary>
    internal const string PowerUpCategory = "PowerUpEvent";

    /// <summary>Bounds on the printer's replies: destinations read, a name's length, a path's length.</summary>
    internal const int MaxDestinations = 32, MaxNameLength = 64, MaxPathLength = 256;

    /// <summary>The longest name this PC is shown by (a panel has little room; the rest is cut).</summary>
    public const int MaxPanelName = 32;

    /// <summary>The manifest's path, when the tree lists the interface; else null.</summary>
    public static string? ManifestPath(DiscoveryTree tree) => tree.ManifestFor(Names.Interface) is { } path && IsLocalPath(path) ? path : null;

    /// <summary>The destination list's and the event document's paths from the manifest; null unless it lists both as plain paths.</summary>
    public static (string List, string Event)? Paths(XDocument manifest)
    {
        var map = LedmManifest.Parse(manifest);
        return map.TryGetValue(Names.ListEntry, out var list) && map.TryGetValue(Names.EventEntry, out var ev) && IsLocalPath(list) && IsLocalPath(ev)
            ? (list, ev)
            : null;
    }

    /// <summary>
    /// The computers on the list, or null when the document isn't the list this code knows (another root): then nothing is
    /// written to the printer. At most <see cref="MaxDestinations"/>; names shortened.
    /// </summary>
    public static IReadOnlyList<WalkupDestination>? Read(XDocument list)
    {
        if (list.Root is not { } root || root.Name.LocalName != Names.ListRoot) return null;
        return root.Kids(Names.Destination).Take(MaxDestinations).Select(d => new WalkupDestination(
            d.KidValue(Names.ResourceUri) is { } p && IsLocalPath(PathOf(p)) ? PathOf(p) : null,
            Short(d.KidValue(Names.Name)),
            Short(d.KidValue(Names.Hostname)))).ToList();
    }

    /// <summary>
    /// The POST body that adds this PC: a destination with its name, host name and link type. The destination's namespace is the
    /// list's own; each child's is the one a destination already on the list uses, else the dictionary's (<c>Name</c>), the
    /// assumed one (<c>Hostname</c>) or the list's (<c>LinkType</c>). A list in no namespace gets a destination in none.
    /// </summary>
    /// <param name="hostName">What marks the destination as this app's (<see cref="Marker"/>): how a later run knows it again.</param>
    public static XDocument Build(XDocument list, string panelName, string hostName)
    {
        var root = list.Root ?? throw new InvalidOperationException("The list has no root.");
        var wus = root.Name.Namespace;
        var sample = root.Kids(Names.Destination).FirstOrDefault();
        XNamespace Ns(string local, XNamespace fallback) => sample?.Kid(local)?.Name.Namespace ?? root.Descendants().FirstOrDefault(e => e.Name.LocalName == local)?.Name.Namespace ?? fallback;
        var dd = Ns(Names.Name, DictionaryNamespace);
        var dd3 = Ns(Names.Hostname, Names.HostnameNamespace);
        var link = Ns(Names.LinkType, wus);
        var destination = new XElement(wus + Names.Destination,
            new XElement(dd + Names.Name, panelName),
            new XElement(dd3 + Names.Hostname, hostName),
            new XElement(link + Names.LinkType, Names.LinkTypeValue));
        foreach (var (prefix, ns) in new[] { ("wus", wus), ("dd", dd), ("dd3", dd3) })
            if (ns != XNamespace.None && destination.Attributes().All(a => a.Value != ns.NamespaceName)) destination.Add(new XAttribute(XNamespace.Xmlns + prefix, ns.NamespaceName));
        return new XDocument(destination);
    }

    /// <summary>
    /// The host name this app gives its destination: the panel name and a tag kept with the choice (<c>PC-iv1a2b3c</c>), so a
    /// computer by this PC's name that another program added (HP's software) is never taken for this app's, and this app's own
    /// is known again whatever became of the POST's answer.
    /// </summary>
    public static string Marker(string panelName, string tag) => $"{panelName}-iv{tag}";

    /// <summary>A new tag for <see cref="Marker"/>: six hex digits.</summary>
    public static string NewTag() => Convert.ToHexStringLower(System.Security.Cryptography.RandomNumberGenerator.GetBytes(3));

    /// <summary>What the event document says was done on the panel, or null when it isn't the document this code knows.</summary>
    public static string? EventType(XDocument doc) =>
        doc.Root is { } root && root.Name.LocalName == Names.EventRoot && Short(root.KidValue(Names.EventType)) is { } type ? type : null;

    /// <summary>The event type means "scan now".</summary>
    public static bool IsStart(string? type) => type is not null && Names.StartTypes.Contains(type, StringComparer.OrdinalIgnoreCase);

    /// <summary>The table's event is a press for this destination: the scan category, naming <paramref name="destination"/>.</summary>
    public static bool IsPressFor(LedmEvent e, string destination) =>
        e.Category == Names.ScanEventCategory && e.Uris.Any(u => string.Equals(PathOf(u), destination, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// The new destination's path from the POST reply's <c>Location</c> (absolute or not): only a plain path below the list's
    /// (it's what a later DELETE goes to, so nothing else on the printer may be named), else null.
    /// </summary>
    public static string? OwnPath(string? location, string listPath)
    {
        if (location is null || location.Length > MaxPathLength * 2) return null;
        var path = PathOf(location);
        return IsLocalPath(path) && path.Length > listPath.Length + 1 && path.StartsWith(listPath.TrimEnd('/') + "/", StringComparison.OrdinalIgnoreCase) ? path : null;
    }

    /// <summary>
    /// The name this PC goes on the panel by: the computer's name, letters, digits and <c>-_.</c> kept, at most
    /// <see cref="MaxPanelName"/>; "PC" when nothing is left.
    /// </summary>
    public static string PanelName(string computerName)
    {
        var kept = new string([.. computerName.Where(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.' or ' ')]).Trim();
        return kept.Length == 0 ? "PC" : kept.Length > MaxPanelName ? kept[..MaxPanelName].TrimEnd() : kept;
    }

    /// <summary>A link's path: an absolute <c>http://…/x</c> becomes <c>/x</c>; a relative one stays.</summary>
    internal static string PathOf(string link) =>
        Uri.TryCreate(link, UriKind.Absolute, out var u) && u.Scheme is "http" or "https" ? u.AbsolutePath : link.Trim();

    /// <summary>A path on the printer that names nothing else: starts with one <c>/</c>, no <c>..</c>, no query, plain characters, bounded.</summary>
    internal static bool IsLocalPath(string path) =>
        path.Length is > 1 and <= MaxPathLength && path[0] == '/' && (path.Length == 1 || path[1] != '/') && !path.Contains("..", StringComparison.Ordinal)
        && path.All(c => char.IsAsciiLetterOrDigit(c) || c is '/' or '-' or '_' or '.' or '~');

    private static string? Short(string? text) => text is null ? null : text.Length > MaxNameLength ? text[..MaxNameLength] : text;
}
