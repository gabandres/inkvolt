import Foundation
import Synchronization

/// An IPv4 network this Mac is on: its own address there and the network's prefix length.
public struct LocalNetwork: Hashable, Sendable {
    public var address: String
    public var prefixLength: Int

    public init(_ address: String, _ prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }
}

/// How far a search is: addresses asked so far, of how many.
public struct SearchProgress: Equatable, Sendable {
    public var checked: Int
    public var total: Int
}

/// What `NetworkSearch` needs from the network (sockets in PrintMac, or a made-up one).
public protocol NetworkScanner: Sendable {
    /// The networks this Mac is on now.
    func localNetworks() -> [LocalNetwork]

    /// Whether `host` accepts a TCP connection on `port` within `timeout`.
    func isOpen(_ host: String, port: Int, timeout: Duration) async throws -> Bool

    /// Sends each request to UDP port 161 at each broadcast address; `answered` for each SNMP reply within `window`.
    func broadcastSnmp(_ broadcasts: [String], requests: [[UInt8]], window: Duration, answered: @escaping @Sendable (String) -> Void) async throws
}

/// Search my network (Add a printer), for printers that don't announce themselves over Bonjour: one SNMP question to the
/// whole network (an office printer's agent answers it), and every address of this Mac's own networks asked whether it
/// takes print jobs (IPP 631, raw 9100, LPD 515). Only private IPv4 networks are searched (RFC 1918: home and office LANs,
/// never a public, link-local or VPN carrier range), a large one only around this Mac (its /24). Finds addresses; whether
/// each is a printer, and which, the caller asks it (as for an address typed in).
public enum NetworkSearch {
    /// The ports a printer takes jobs on: IPP, raw (JetDirect), LPD. A web server alone (80, 443) is any device.
    public static let printerPorts = [631, 9100, 515]

    /// A printer on the LAN accepts a connection in a few milliseconds; nothing at an address takes this long to say so.
    public static let connectTimeout: Duration = .milliseconds(600)

    /// How long SNMP replies are collected.
    public static let snmpWindow: Duration = .seconds(2)

    // Networks this size or smaller are asked whole (a /22 is 1,022 addresses); a larger one only around this Mac.
    private static let wholeNetworkPrefix = 22
    private static let aroundThisMacPrefix = 24
    private static let parallel = 64

    /// The addresses to ask on `net`, in order, without this Mac's: none when it isn't worth searching.
    public static func addresses(_ net: LocalNetwork) -> [String] {
        guard let me = searchable(net) else { return [] }
        let prefix = net.prefixLength >= wholeNetworkPrefix ? net.prefixLength : aroundThisMacPrefix
        let m = mask(prefix)
        let first = (me & m) + 1
        let last = ((me & m) | ~m) - 1
        guard first <= last else { return [] }
        return (first...last).filter { $0 != me }.map(text)
    }

    /// The network's broadcast address (for SNMP), or nil when it isn't worth searching.
    public static func broadcast(_ net: LocalNetwork) -> String? {
        searchable(net).map { text(($0 & mask(net.prefixLength)) | ~mask(net.prefixLength)) }
    }

    /// Searches every network this Mac is on; `found` once for each address that takes print jobs or answered SNMP (from any
    /// task). Throws `CancellationError` when cancelled; the SNMP question stops with the search and is awaited.
    public static func search(_ scanner: any NetworkScanner, found: @escaping @Sendable (String) -> Void,
                              progress: (@Sendable (SearchProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let networks = unique(scanner.localNetworks())
        let hosts = unique(networks.flatMap(addresses))
        let own = Set(networks.map(\.address))
        let reported = Shared(Set<String>())
        let report: @Sendable (String) -> Void = { a in if reported.withLock({ $0.insert(a).inserted }) { found(a) } }
        let broadcasts = unique(networks.compactMap(broadcast))

        try await withThrowingTaskGroup(of: Void.self) { group in
            if !broadcasts.isEmpty {
                // A reply from outside these networks (or this Mac's own agent) isn't one of the printers looked for.
                group.addTask {
                    try await scanner.broadcastSnmp(broadcasts, requests: [question(.v2c), question(.v1)], window: snmpWindow) { a in
                        if !own.contains(a) && networks.contains(where: { within($0, a) }) { report(a) }
                    }
                }
            }
            group.addTask { try await sweep(scanner, hosts, report, progress) }
            try await group.waitForAll()
        }
    }

    /// Each address on each printer port, `parallel` addresses at a time.
    private static func sweep(_ scanner: any NetworkScanner, _ hosts: [String], _ report: @escaping @Sendable (String) -> Void,
                              _ progress: (@Sendable (SearchProgress) -> Void)?) async throws {
        let done = Shared(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            while next < hosts.count || !group.isEmpty {
                while next < hosts.count && next - done.withLock({ $0 }) < parallel {
                    let host = hosts[next]
                    next += 1
                    group.addTask {
                        async let ipp = scanner.isOpen(host, port: printerPorts[0], timeout: connectTimeout)
                        async let raw = scanner.isOpen(host, port: printerPorts[1], timeout: connectTimeout)
                        async let lpd = scanner.isOpen(host, port: printerPorts[2], timeout: connectTimeout)
                        let open = try await [ipp, raw, lpd]
                        if open.contains(true) { report(host) }
                        let checked = done.withLock { n in
                            n += 1
                            return n
                        }
                        progress?(SearchProgress(checked: checked, total: hosts.count))
                    }
                }
                try await group.next()
            }
        }
    }

    /// Whether an adapter is a home or office LAN worth searching: not a VPN's or a virtual switch's, told by name. (The Mac
    /// side also leaves out its utun, ipsec and bridge interfaces.)
    public static func isLan(_ name: String, _ description: String) -> Bool {
        !vpnWords.contains { name.range(of: $0, options: .caseInsensitive) != nil || description.range(of: $0, options: .caseInsensitive) != nil }
    }

    private static let vpnWords = [
        "VPN", "Virtual", "TAP-", "Tunnel", "AnyConnect", "PANGP", "GlobalProtect", "Fortinet", "FortiClient", "Juniper", "Pulse", "WireGuard",
        "Wintun", "Tailscale", "ZeroTier", "NordLynx", "Hamachi", "OpenVPN", "Data Channel Offload", "Hyper-V", "VMware", "VirtualBox", "WSL",
    ]

    /// GetNext of sysDescr and hrPrinterStatus: any agent answers the first, a printer's has the second.
    static func question(_ version: SnmpVersion) -> [UInt8] {
        SnmpMessage(version, SnmpClient.defaultCommunity, .getNextRequest, requestId: Int.random(in: 1..<Int(Int32.max)), errorStatus: 0, errorIndex: 0,
                    varBinds: [SnmpVarBind(PrinterMib.sysDescr, .null), SnmpVarBind(PrinterMib.hrPrinterStatus, .null)]).encode()
    }

    private static func searchable(_ net: LocalNetwork) -> UInt32? {
        guard (8...30).contains(net.prefixLength), let me = number(net.address), isPrivate(me) else { return nil }
        return me
    }

    /// 10/8, 172.16/12, 192.168/16 (RFC 1918).
    private static func isPrivate(_ a: UInt32) -> Bool { a >> 24 == 10 || a >> 20 == (172 << 4 | 1) || a >> 16 == (192 << 8 | 168) }

    private static func within(_ net: LocalNetwork, _ address: String) -> Bool {
        guard let a = number(address), let n = number(net.address) else { return false }
        return a & mask(net.prefixLength) == n & mask(net.prefixLength)
    }

    private static func mask(_ prefix: Int) -> UInt32 { prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix) }

    /// A dotted IPv4 address as a number; nil for anything else (an IPv6 address among them).
    static func number(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCIIDigit), let b = UInt8(p) else { return nil }
            value = value << 8 | UInt32(b)
        }
        return value
    }

    private static func text(_ a: UInt32) -> String { "\(a >> 24).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)" }

    private static func unique<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}
