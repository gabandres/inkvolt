import Foundation

/// A network (eSCL) scanner in Inkvolt PDF's Scan dialog: one Inkvolt Print remembers, or one Bonjour found.
public struct EsclScanner: Equatable, Sendable {
    /// What the dialog remembers as the last scanner: "escl:" and the printer's UUID in lower case.
    public var key: String
    public var name: String
    public var host: String
    public var esclRoot: URL
    /// Inkvolt Print remembers it (its hand-off, `SuitePrinters`); else only found on the network now.
    public var remembered: Bool

    public init(key: String, name: String, host: String, esclRoot: URL, remembered: Bool) {
        self.key = key
        self.name = name
        self.host = host
        self.esclRoot = esclRoot
        self.remembered = remembered
    }
}

/// The Scan dialog's list of scanners (the Windows suite's `ScannerList`, its network part; the Mac's USB scanners come
/// through ImageCaptureCore): the scanners Inkvolt Print remembers first, so they're there at once, then the ones Bonjour
/// finds; their keys and labels.
public enum ScannerList {
    private static let prefix = "escl:"

    /// "escl:" and the UUID as `PrinterId.key` writes it, so a UUID written any way is the same scanner.
    public static func key(_ uuid: String) -> String { prefix + PrinterId.key(uuid) }

    /// "Name  (host)", with " · found on the network" for one Inkvolt Print doesn't remember; "Name  (USB)".
    public static func label(_ scanner: EsclScanner) -> String {
        "\(scanner.name)  (\(scanner.host))\(scanner.remembered ? "" : loc(" · found on the network"))"
    }

    /// Which of the listed scanners (`ids`) is chosen: the one chosen now when the user chose it, else the saved one (also when
    /// it turns up after another stood in for it: ImageCaptureCore reports USB scanners after the hand-off's are listed), else
    /// the one standing in while still listed, else the first. `fallback`: chosen only because the saved one isn't listed, so
    /// not to be saved over it. Nil for an empty list.
    public static func pick(_ ids: [String], current: String?, fallback: Bool, saved: String?) -> (index: Int, fallback: Bool)? {
        guard !ids.isEmpty else { return nil }
        if !fallback, let current, let i = ids.firstIndex(of: current) { return (i, false) }
        if let saved, let i = ids.firstIndex(of: saved) { return (i, false) }
        return (current.flatMap { ids.firstIndex(of: $0) } ?? 0, saved != nil)
    }

    public static func usbLabel(_ name: String) -> String { "\(name)  (USB)" }

    /// The network scanners: Inkvolt Print's remembered printers that scan over eSCL (hand-off order), then those Bonjour
    /// found that aren't among them. A remembered one Bonjour finds gets its address and eSCL root from discovery (DHCP may
    /// have moved it), keeping its key and the name Inkvolt Print knows it by. Found is the same printer as Inkvolt Print
    /// joins them: its UUID is the remembered id or one the user accepted for it ("This is my printer"); or, for a printer
    /// remembered by its address (no UUID of its own), it is at one of its hosts (address or Bonjour name).
    public static func network(remembered: SuitePrinters, found: [DiscoveredPrinter]) -> [EsclScanner] {
        var list: [EsclScanner] = []
        var known: [SuitePrinter] = [] // list[i] stands for known[i] while i < known.count
        for p in remembered.printers {
            guard let root = p.esclRoot.flatMap(URL.init(string:)) else { continue }
            let id = key(p.id)
            if !list.contains(where: { $0.key == id }) {
                list.append(EsclScanner(key: id, name: p.name, host: p.host, esclRoot: root, remembered: true))
                known.append(p)
            }
        }
        for d in found where d.hasScanner {
            guard let host = d.host, let root = d.esclRoot else { continue }
            let id = key(d.uuid)
            let mine = known.firstIndex { isSame($0, d) } ?? list.firstIndex { $0.key == id }
            if let i = mine {
                list[i].host = host
                list[i].esclRoot = root
            } else {
                list.append(EsclScanner(key: id, name: d.name, host: host, esclRoot: root, remembered: false))
            }
        }
        return list
    }

    /// The remembered printer `p` is the one found: by UUID (its id or an accepted one), or by host for one without a UUID.
    static func isSame(_ p: SuitePrinter, _ d: DiscoveredPrinter) -> Bool {
        if PrinterId.same(p.id, d.uuid) || p.acceptedUuids.contains(where: { PrinterId.same($0, d.uuid) }) { return true }
        let hosts = [p.host] + p.hosts
        guard PrinterId.isFromAddress(p.id, hosts: hosts) else { return false } // a UUID of its own: another is another device
        let bare = Set(hosts.map(bareHost))
        return [d.host, d.hostName].contains { $0.map { bare.contains(bareHost($0)) } ?? false }
    }

    /// A host as compared: lower case, without the DNS root's trailing dot.
    private static func bareHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}
