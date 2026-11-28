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
    /// What tells `network` from another with the same addresses (a café's Wi-Fi is often 192.168.1.0/24 too): its router's
    /// address and hardware address, and its Wi-Fi name when the app may already read it (PrintMac: SystemConfiguration, the
    /// routing table's neighbours, CoreWLAN only with location access already given; never asked for).
    func place(of network: LocalNetwork) -> NetworkPlace
}

/// A network sharing was turned on in, as this Mac knows it again (the pre-release review: any RFC 1918 network counted as
/// private, so a café's or hotel's Wi-Fi was shared to everyone there). **Mac difference:** Windows asks the person whether
/// each network is Private or Public and shares on Private ones; macOS has no such setting, so the share remembers where the
/// person turned it on and pauses everywhere else until they turn it on there too. Kept with the choice, on this Mac only.
public struct NetworkPlace: Codable, Hashable, Sendable {
    /// The subnet, "192.168.1.0/24".
    public var subnet: String
    /// The router's IPv4 address; nil when the network has none.
    public var router: String?
    /// The router's hardware (Ethernet) address, lowercased; nil when this Mac couldn't read it.
    public var routerHardware: String?
    /// The Wi-Fi network's name (its bytes in hex); nil on Ethernet or without location access.
    public var wifi: String?

    public init(_ network: LocalNetwork, router: String? = nil, routerHardware: String? = nil, wifi: String? = nil) {
        subnet = Self.subnet(network)
        self.router = router.flatMap { NetworkSearch.number($0) == nil ? nil : $0 }
        self.routerHardware = routerHardware.flatMap(Self.hardware)
        self.wifi = wifi.map { String($0.prefix(64)) }
    }

    /// The same network as `remembered`: the same subnet and router address, the router's hardware address when one was
    /// remembered (unread now: not the same, so a failed read pauses rather than shares), and the same Wi-Fi name when both
    /// are known.
    public func isSame(as remembered: NetworkPlace) -> Bool {
        guard subnet == remembered.subnet, router == remembered.router else { return false }
        if let hardware = remembered.routerHardware, hardware != routerHardware { return false }
        if let wifi, let was = remembered.wifi, wifi != was { return false }
        return true
    }

    /// How many places are kept: the most recent ones the person turned sharing on in.
    public static let kept = 8

    /// `remembered` with `here` added (the same place once, the newest last), at most `kept`.
    public static func adding(_ here: [NetworkPlace], to remembered: [NetworkPlace]) -> [NetworkPlace] {
        var all: [NetworkPlace] = []
        for place in remembered.suffix(kept) + here.prefix(64) {
            all.removeAll { $0.isSame(as: place) || place.isSame(as: $0) }
            all.append(place)
        }
        return Array(all.suffix(kept))
    }

    static func subnet(_ network: LocalNetwork) -> String {
        guard let a = NetworkSearch.number(network.address), (0...32).contains(network.prefixLength) else { return network.address }
        let mask: UInt32 = network.prefixLength == 0 ? 0 : ~UInt32(0) << UInt32(32 - network.prefixLength)
        let n = a & mask
        return "\(n >> 24).\(n >> 16 & 0xFF).\(n >> 8 & 0xFF).\(n & 0xFF)/\(network.prefixLength)"
    }

    /// "aa:bb:cc:dd:ee:ff" from six hex bytes however written ("A:B:C:D:E:F" too); nil for anything else or all zeros.
    static func hardware(_ text: String) -> String? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard (1...2).contains(p.count), let b = UInt8(p, radix: 16) else { return nil }
            bytes.append(b)
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { b in (b < 16 ? "0" : "") + String(b, radix: 16) }.joined(separator: ":")
    }
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
