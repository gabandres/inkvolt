import Foundation

/// A computer on the printer's Scan to Computer list: its resource (a path on the printer) and the names it shows.
public struct WalkupDestination: Equatable, Sendable {
    public var path: String?
    public var name: String?
    public var hostname: String?
}

/// The element names `LedmWalkupScan` assumes, in one place (Windows' `WalkupNames`). None of them has been seen on a printer:
/// see `LedmWalkupScan`.
struct WalkupNames: Sendable {
    /// The DiscoveryTree's `SupportedIfc` resource type whose manifest lists the interface.
    let interface: String
    /// The manifest's element types of the destination list and of the document that says what was pressed.
    let listEntry: String, eventEntry: String
    /// The destination list's root element, and one destination in it (and as POSTed).
    let listRoot: String, destination: String
    /// A destination's name (the dictionary namespace's `Name`), host name and link type, as POSTed too.
    let name: String, hostname: String, linkType: String, linkTypeValue: String
    /// Where a listed destination is (the captured documents' `dd:ResourceURI`).
    let resourceUri: String
    /// The event document's root, and its element that says what happened.
    let eventRoot: String, eventType: String
    /// The EventTable category of a press (the captured table's categories are `PowerUpEvent`, `AlertTableChanged`).
    let scanEventCategory: String
    /// Event types that mean "scan now" (compared ignoring case). Choosing the computer alone doesn't count.
    let startTypes: [String]
    /// The namespace of `Hostname` when the printer's list shows none.
    let hostnameNamespace: String
}

/// HP LEDM's walk-up scan destinations ("Scan to Computer" on the printer's panel; Windows' `LedmWalkupScan`): a computer adds
/// itself to the printer's list with one POST of a destination document and removes itself with a DELETE of the resource it
/// got; when someone picks it on the panel and presses Scan, the printer's EventTable gets a scan event naming that
/// destination, and the event document says what was pressed.
///
/// **Unconfirmed.** No printer that lists this interface has been recorded (the LaserJet MFP M234dw's DiscoveryTree doesn't
/// list it), so every name in `names` is Windows' assumption, ported as it is and laid out like the LEDM documents that were
/// captured: a `SupportedIfc` with a manifest (as FirmwareUpdate's), the dictionary namespace's `Name` and `ResourceURI`, the
/// EventTable's `Event` / `UnqualifiedEventCategory` / `AgingStamp` / `Payload`. A printer whose documents don't match gets
/// nothing (`paths`, `read` and `eventType` return nil), so nothing is POSTed on a guess; Record a printer saves the
/// interface's documents, so one recording settles the names.
public enum LedmWalkupScan {
    /// The assumed names (see above).
    static let names = WalkupNames(
        interface: "wus:WalkupScanToCompManifest",
        listEntry: "WalkupScanToCompDestinations",
        eventEntry: "WalkupScanToCompEvent",
        listRoot: "WalkupScanToCompDestinations",
        destination: "WalkupScanToCompDestination",
        name: "Name",
        hostname: "Hostname",
        linkType: "LinkType",
        linkTypeValue: "Network",
        resourceUri: "ResourceURI",
        eventRoot: "WalkupScanToCompEvent",
        eventType: "WalkupScanToCompEventType",
        scanEventCategory: "ScanEvent",
        startTypes: ["ScanRequested"],
        hostnameNamespace: "http://www.hp.com/schemas/imaging/con/dictionaries/2009/04/06")

    /// The dictionary namespace every captured LEDM document uses (`dd:`).
    static let dictionaryNamespace = "http://www.hp.com/schemas/imaging/con/dictionaries/1.0/"

    /// The EventTable category of a printer that just started (captured: the M234dw's EventTable and EventCapabilities).
    static let powerUpCategory = "PowerUpEvent"

    /// Bounds on the printer's replies: destinations read, a name's length, a path's length.
    static let maxDestinations = 32, maxNameLength = 64, maxPathLength = 256

    /// The longest name this Mac is shown by (a panel has little room; the rest is cut).
    public static let maxPanelName = 32

    /// The manifest's path, when the tree lists the interface; else nil.
    public static func manifestPath(_ tree: DiscoveryTree) -> String? {
        guard let path = tree.manifest(for: names.interface), isLocalPath(path) else { return nil }
        return path
    }

    /// The destination list's and the event document's paths from the manifest; nil unless it lists both as plain paths.
    public static func paths(_ manifest: XmlElement) -> (list: String, event: String)? {
        let map = LedmManifest.parse(manifest)
        guard let list = map[names.listEntry], let event = map[names.eventEntry], isLocalPath(list), isLocalPath(event) else { return nil }
        return (list, event)
    }

    /// The computers on the list, or nil when the document isn't the list this code knows (another root): then nothing is
    /// written to the printer. At most `maxDestinations`; names shortened.
    public static func read(_ list: XmlElement) -> [WalkupDestination]? {
        guard list.name == names.listRoot else { return nil }
        return list.kids(names.destination).prefix(maxDestinations).map { d in
            let path = d.kidValue(names.resourceUri).map(pathOf)
            return WalkupDestination(path: path.flatMap { isLocalPath($0) ? $0 : nil }, name: short(d.kidValue(names.name)),
                                     hostname: short(d.kidValue(names.hostname)))
        }
    }

    /// The POST body that adds this Mac: a destination with its name, host name and link type. The destination's namespace is
    /// the list's own; each child's is the one a destination already on the list uses, else the dictionary's (`Name`), the
    /// assumed one (`Hostname`) or the list's (`LinkType`). A list in no namespace gets a destination in none. The same bytes
    /// as Windows' (`LedmClient.Serialize(LedmWalkupScan.Build(…))`).
    /// - Parameter hostName: what marks the destination as this app's (`marker`): how a later run knows it again.
    public static func build(_ list: XmlElement, panelName: String, hostName: String) -> String {
        let wus = list.namespace
        let sample = list.kids(names.destination).first
        func ns(_ local: String, _ fallback: String) -> String {
            if let e = sample?.kid(local) { return e.namespace }
            if let e = list.all(local).first { return e.namespace }
            return fallback
        }
        let dd = ns(names.name, dictionaryNamespace)
        let dd3 = ns(names.hostname, names.hostnameNamespace)
        let link = ns(names.linkType, wus)
        // Prefixes as Windows writes them: wus, dd, dd3 for those three namespaces, each declared once on the destination.
        var declared: [(prefix: String, namespace: String)] = []
        for (prefix, namespace) in [("wus", wus), ("dd", dd), ("dd3", dd3)] where !namespace.isEmpty && !declared.contains(where: { $0.namespace == namespace }) {
            declared.append((prefix, namespace))
        }
        if !link.isEmpty && !declared.contains(where: { $0.namespace == link }) { declared.append(("p1", link)) }
        func q(_ namespace: String, _ local: String) -> String {
            guard let p = declared.first(where: { $0.namespace == namespace })?.prefix else { return local }
            return "\(p):\(local)"
        }
        func element(_ namespace: String, _ local: String, _ text: String) -> String {
            "<\(q(namespace, local))>\(LedmNode.escape(text))</\(q(namespace, local))>"
        }
        let root = q(wus, names.destination)
        let xmlns = declared.map { " xmlns:\($0.prefix)=\"\(LedmNode.escape($0.namespace))\"" }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><\(root)\(xmlns)>" + element(dd, names.name, panelName) + element(dd3, names.hostname, hostName)
            + element(link, names.linkType, names.linkTypeValue) + "</\(root)>"
    }

    /// The host name this app gives its destination: the panel name and a tag kept with the choice (`MAC-iv1a2b3c`), so a
    /// computer by this Mac's name that another program added (HP's software) is never taken for this app's, and this app's
    /// own is known again whatever became of the POST's answer.
    public static func marker(_ panelName: String, _ tag: String) -> String { "\(panelName)-iv\(tag)" }

    /// A new tag for `marker`: six hex digits.
    public static func newTag() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<3).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// What the event document says was done on the panel, or nil when it isn't the document this code knows.
    public static func eventType(_ doc: XmlElement) -> String? {
        guard doc.name == names.eventRoot else { return nil }
        return short(doc.kidValue(names.eventType))
    }

    /// The event type means "scan now".
    public static func isStart(_ type: String?) -> Bool {
        guard let type else { return false }
        return names.startTypes.contains { $0.caseInsensitiveCompare(type) == .orderedSame }
    }

    /// The table's event is a press for this destination: the scan category, naming `destination`.
    public static func isPressFor(_ e: LedmEvent, _ destination: String) -> Bool {
        e.category == names.scanEventCategory && e.uris.contains { pathOf($0).caseInsensitiveCompare(destination) == .orderedSame }
    }

    /// The new destination's path from the POST reply's `Location` (absolute or not): only a plain path below the list's
    /// (it's what a later DELETE goes to, so nothing else on the printer may be named), else nil.
    public static func ownPath(_ location: String?, _ listPath: String) -> String? {
        guard let location, location.count <= maxPathLength * 2 else { return nil }
        let path = pathOf(location)
        var base = listPath
        while base.hasSuffix("/") { base.removeLast() }
        guard isLocalPath(path), path.count > listPath.count + 1, path.lowercased().hasPrefix(base.lowercased() + "/") else { return nil }
        return path
    }

    /// The name this Mac goes on the panel by: the computer's name, letters, digits and `-_.` kept, at most `maxPanelName`;
    /// "PC" when nothing is left (as Windows).
    public static func panelName(_ computerName: String) -> String {
        let kept = String(computerName.filter { $0.isLetter || $0.isNumber || "-_. ".contains($0) }).trimmingCharacters(in: .whitespaces)
        if kept.isEmpty { return "PC" }
        return kept.count > maxPanelName ? String(kept.prefix(maxPanelName)).trimmingCharacters(in: .whitespaces) : kept
    }

    /// A link's path: an absolute `http://…/x` becomes `/x`; a relative one stays.
    static func pathOf(_ link: String) -> String {
        if let c = URLComponents(string: link), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https", c.host != nil {
            return c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        }
        return link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A path on the printer that names nothing else: starts with one `/`, no `..`, no query, plain characters, bounded.
    static func isLocalPath(_ path: String) -> Bool {
        let chars = Array(path.utf8)
        guard chars.count > 1, chars.count <= maxPathLength, chars[0] == UInt8(ascii: "/"), chars[1] != UInt8(ascii: "/"), !path.contains("..") else {
            return false
        }
        return chars.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || "/-_.~".utf8.contains(c)
        }
    }

    private static func short(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.count > maxNameLength ? String(text.prefix(maxNameLength)) : text
    }
}
