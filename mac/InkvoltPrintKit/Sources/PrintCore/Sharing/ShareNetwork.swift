import Foundation

/// Who may reach the shared scanner (roadmap 3.1: private networks only; the Windows Core's `SharePeers`): the phone scan's
/// rules, which came to the Mac first (`PhonePeers`: this Mac's Ethernet and Wi-Fi IPv4 networks with a private address,
/// devices on their subnets that came in on that address, and this Mac over loopback). **Mac difference:** macOS has no
/// Private/Public setting, and the share serves IPv4 only (no link-local or other IPv6 peers).
public typealias SharePeers = PhonePeers

/// The share's TLS certificate is the phone scan's (Windows keeps one for both too): made once, kept in the app's keychain
/// (PrintMac's `PhoneCertificateKeychain`), shown by its fingerprint.
public typealias ShareCertificates = PhoneCertificates

/// What a share announces over DNS-SD (Bonjour): its service (`_uscans._tcp`), name, port and TXT keys (the Windows Core's
/// `ShareAdvert`). `instance`: the name clients list (at most 63 bytes, no dots); `host`: this Mac's `.local` name.
public struct ShareAdvert: Equatable, Sendable {
    /// A shared scanner's service type (eSCL over TLS).
    public static let service = "_uscans._tcp"

    public var instance: String
    public var host: String
    public var port: Int
    public var txt: [(key: String, value: String)]

    public init(instance: String, host: String, port: Int, txt: [(key: String, value: String)]) {
        self.instance = instance
        self.host = host
        self.port = port
        self.txt = txt
    }

    public static func == (a: ShareAdvert, b: ShareAdvert) -> Bool {
        a.instance == b.instance && a.host == b.host && a.port == b.port && a.txt.map(\.key) == b.txt.map(\.key) && a.txt.map(\.value) == b.txt.map(\.value)
    }

    public func value(_ key: String) -> String? { txt.first { $0.key == key }?.value }
}

/// The DNS-SD record for a shared scanner, as Mopria's eSCL and Apple's AirScan clients read it (the Windows Core's
/// `ShareDnssd`).
public enum ShareDnssd {
    /// The advert for `id` on `port`: rs=eSCL, its UUID, color modes, sources, duplex and formats.
    public static func advert(_ id: ShareIdentity, _ caps: ScannerCapabilities, computerName: String, port: Int) -> ShareAdvert {
        let inputs = [caps.platen, caps.adf].compactMap { $0 }
        var modes: [String] = []
        for m in inputs.flatMap(\.colorModes) where !modes.contains(m) { modes.append(m) }
        var cs: [String] = []
        if modes.contains("BlackAndWhite1") { cs.append("binary") }
        if modes.contains("Grayscale8") { cs.append("grayscale") }
        if modes.contains("RGB24") || modes.isEmpty { cs.append("color") }
        var sources: [String] = []
        if caps.platen != nil { sources.append("platen") }
        if caps.adf != nil { sources.append("adf") }
        let txt: [(key: String, value: String)] = [
            ("txtvers", "1"), ("vers", ShareXml.version), ("rs", "eSCL"), ("ty", cut(id.name, 200)), ("UUID", id.uuidText),
            ("pdl", ShareXml.formats.joined(separator: ",")), ("cs", cs.joined(separator: ",")), ("is", sources.joined(separator: ",")),
            ("duplex", caps.adfDuplex ? "T" : "F"),
        ]
        return ShareAdvert(instance: instanceName(id.name, computerName), host: hostName(computerName), port: port, txt: txt)
    }

    /// "Scanner on Mac" in the app's language: no dots or control characters, cut to DNS-SD's 63 bytes.
    public static func instanceName(_ scannerName: String, _ computerName: String) -> String {
        let name = loc("{0} on {1}", context: "shared scanner", scannerName.trimmingCharacters(in: .whitespacesAndNewlines),
                       computerName.trimmingCharacters(in: .whitespacesAndNewlines))
        let spaced = String(name.map { c -> Character in
            c.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } || c == "." || c == "\\" ? " " : c
        })
        let clean = spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return cut(clean.isEmpty ? "Inkvolt Print scanner" : clean, 63)
    }

    /// This Mac's name as a `.local` host name: letters, digits and dashes (others become dashes).
    public static func hostName(_ computerName: String) -> String {
        let trimmed = computerName.trimmingCharacters(in: .whitespacesAndNewlines)
        var label = String(trimmed.map { c -> Character in c.isASCII && (c.isLetter || c.isNumber) ? c : "-" })
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if label.count > 63 {
            label = String(label.prefix(63))
            while label.hasSuffix("-") { label.removeLast() }
        }
        return (label.isEmpty ? "inkvolt-print" : label) + ".local"
    }

    /// The longest start of `text` that is at most `max` UTF-8 bytes, cut between characters.
    static func cut(_ text: String, _ max: Int) -> String {
        if text.utf8.count <= max { return text }
        var out = ""
        var bytes = 0
        for c in text {
            let n = String(c).utf8.count
            if bytes + n > max { break }
            out.append(c)
            bytes += n
        }
        while out.last?.isWhitespace == true { out.removeLast() }
        return out
    }
}

/// This Mac's networks for a share (`PhoneNetworks`), and a word when they change: `watch` starts telling `changed` (from
/// any thread) until the watch it returns is stopped (PrintMac: Network framework's path monitor; nothing is watched
/// while no scanner is shared).
public protocol ShareNetworks: PhoneNetworks {
    func watch(_ changed: @escaping @Sendable () -> Void) -> any ShareWatch
}

/// A watch of the networks, or an announcement: `stop` ends it (again is nothing).
public protocol ShareWatch: Sendable {
    func stop() async
}

/// Announces the share over DNS-SD on the networks given, until the announcement it returns is stopped (PrintMac:
/// `DNSServiceRegister`). Cancelling the calling task gives up an announcement under way.
public protocol ShareAdvertiser: Sendable {
    func advertise(_ advert: ShareAdvert, on: [LocalNetwork]) async throws -> any ShareWatch
}
