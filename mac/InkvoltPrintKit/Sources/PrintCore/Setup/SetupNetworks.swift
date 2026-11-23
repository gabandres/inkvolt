import Foundation

/// A Wi-Fi network this Mac can see (what CoreWLAN's scan says about it).
public struct WifiNetwork: Equatable, Hashable, Sendable {
    /// The network's name as it's sent (up to 32 bytes, not always text).
    public var ssid: [UInt8]
    /// Signal quality, 0-100 (Windows' scale; the Mac's RSSI turned into it by `quality(rssi:)`).
    public var signal: Int
    /// It asks for a password (or more).
    public var secured: Bool

    public init(ssid: [UInt8], signal: Int, secured: Bool) {
        self.ssid = ssid
        self.signal = signal
        self.secured = secured
    }

    /// The name as shown: one line of visible characters (a name is hostile input; bytes that aren't UTF-8 show as �).
    public var name: String { SetupNetworks.show(ssid) }

    public func same(_ other: WifiNetwork) -> Bool { ssid == other.ssid }

    /// An RSSI in dBm as a 0-100 quality: -100 dBm or weaker is 0, -50 or stronger 100 (as Windows reports its own).
    public static func quality(rssi: Int) -> Int { min(100, max(0, 2 * (rssi + 100))) }
}

/// Which kind of printer network a setup network seems to be.
public enum SetupNetworkKind: Int, Comparable, Sendable {
    /// A printer's own setup network, open while it waits to be told the home Wi-Fi (HP-Setup, Canon_ij_, Brother's SETUP-, Epson's).
    case setup
    /// A printer's Wi-Fi Direct network (DIRECT-xx- with a printer maker's name): also reaches its setup page.
    case direct

    public static func < (a: SetupNetworkKind, b: SetupNetworkKind) -> Bool { a.rawValue < b.rawValue }
}

/// A network nearby that looks like a printer's: the network, the maker it names and the kind.
public struct SetupCandidate: Equatable, Sendable {
    public var network: WifiNetwork
    public var maker: String
    public var kind: SetupNetworkKind
}

/// Spotting a new printer's setup network among the Wi-Fi networks nearby (roadmap 4.17, Windows' `SetupNetworks`), by the
/// names makers give them: HP's "HP-Setup>xx-Model" and "HP-Print-xx-Model", Canon's "Canon_ij_XXXX", Brother's "SETUP-XXXX"
/// and "DIRECT-xx-Brother…"/"…_BR…", Epson's "EPSON…" and "DIRECT-xx-EPSON-…", Xerox's, Lexmark's, Samsung's, Kyocera's,
/// Ricoh's and Pantum's "DIRECT-…" names. A plain "DIRECT-xx-…" with no printer maker's name (a phone's or a TV's Wi-Fi
/// Direct) isn't one. Read only: nothing here connects (on the Mac nothing in the app does: PLAN, "Mac differences").
public enum SetupNetworks {
    private static let directMakers: [(word: String, maker: String)] = [
        ("HP", "HP"), ("EPSON", "Epson"), ("Brother", "Brother"), ("Canon", "Canon"), ("Xerox", "Xerox"), ("Lexmark", "Lexmark"),
        ("Samsung", "Samsung"), ("KYOCERA", "Kyocera"), ("Ricoh", "Ricoh"), ("Pantum", "Pantum"), ("OKI", "OKI"),
    ]

    /// The printer's setup or Wi-Fi Direct network this is, or nil for any other.
    public static func classify(_ network: WifiNetwork) -> SetupCandidate? {
        let name = show(network.ssid)
        func found(_ maker: String, _ kind: SetupNetworkKind) -> SetupCandidate { SetupCandidate(network: network, maker: maker, kind: kind) }
        if starts(name, "HP-Setup") { return found("HP", .setup) }
        if starts(name, "HP-Print-") { return found("HP", .direct) }
        if starts(name, "Canon_ij_") { return found("Canon", .setup) }
        if starts(name, "SETUP-") || starts(name, "Brother_") { return found("Brother", .setup) }
        if starts(name, "EPSON") { return found("Epson", .setup) }
        let chars = Array(name)
        if starts(name, "DIRECT-") && chars.count > 10 {
            // Brother's: DIRECT-xxHL-L2350DW_BRa1b2 (the model, then _BR and four hex digits).
            if isBrotherDirect(chars) { return found("Brother", .direct) }
            // The others: DIRECT-xx- and the maker's name right after it ("DIRECT-7A-EPSON-ET-2850", "DIRECT-4F-HP M234 LaserJet").
            // A maker's name further on isn't one: "DIRECT-3f-[TV] Samsung 7 Series" is a television.
            if chars[9] == "-" {
                let rest = Array(String(chars[10...]).drop { $0.isWhitespace })
                for (word, maker) in directMakers {
                    let w = Array(word)
                    guard rest.count >= w.count, String(rest[..<w.count]).caseInsensitiveCompare(word) == .orderedSame else { continue }
                    if rest.count == w.count || !rest[w.count].isLetter { return found(maker, .direct) }
                }
            }
        }
        return nil
    }

    private static func isBrotherDirect(_ chars: [Character]) -> Bool {
        guard chars.count >= 7 else { return false }
        let tail = chars.suffix(7)
        return String(tail.prefix(3)) == "_BR" && tail.suffix(4).allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// The printers' networks among `nearby`, each once, setup networks first, strongest first.
    public static func find(_ nearby: [WifiNetwork]) -> [SetupCandidate] {
        var best: [[UInt8]: Int] = [:]
        var order: [SetupCandidate] = []
        for candidate in nearby.prefix(512).compactMap(classify) {
            if let i = best[candidate.network.ssid] {
                if candidate.network.signal > order[i].network.signal { order[i] = candidate }
            } else {
                best[candidate.network.ssid] = order.count
                order.append(candidate)
            }
        }
        let sorted = order.enumerated().sorted { a, b in
            if a.element.kind != b.element.kind { return a.element.kind < b.element.kind }
            if a.element.network.signal != b.element.network.signal { return a.element.network.signal > b.element.network.signal }
            return a.offset < b.offset
        }
        return sorted.prefix(16).map(\.element)
    }

    /// A network's name as shown: UTF-8 (anything else as �), one line of visible characters.
    public static func show(_ ssid: [UInt8]) -> String {
        AlertText.clean(String(decoding: ssid.prefix(32), as: UTF8.self), 64)
    }

    private static func starts(_ name: String, _ prefix: String) -> Bool {
        name.count >= prefix.count && String(name.prefix(prefix.count)).caseInsensitiveCompare(prefix) == .orderedSame
    }

    /// The printer's setup page on its own network: the Wi-Fi gateway it gave this Mac (the printer is the access point), as
    /// `http://address/`. Only a private or link-local IPv4 address counts (a setup network that hands out anything else
    /// isn't a printer's); nil otherwise.
    public static func setupPage(_ gateway: String?) -> URL? {
        guard let gateway else { return nil }
        let parts = gateway.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var b: [Int] = []
        for p in parts {
            guard (1...3).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p), n <= 255 else { return nil }
            b.append(n)
        }
        let isPrivate = b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        guard isPrivate, b[3] != 0, b[3] != 255 else { return nil }
        return URL(string: "http://\(b.map(String.init).joined(separator: "."))/")
    }
}
