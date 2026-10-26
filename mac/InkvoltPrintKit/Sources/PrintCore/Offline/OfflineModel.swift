import Foundation

/// The printer the "printer offline" fixer looks at, as Inkvolt Print knows it (the Windows app's `OfflineDevice`, without
/// the stored Windows queue and pairing: Inkvolt Print sets up no queues on the Mac).
public struct OfflineDevice: Equatable, Sendable {
    /// The printer's UUID (its DNS-SD `UUID`, also in the `uuid=` of the device URI of the queues macOS set up from Bonjour).
    public var uuid: String
    public var name: String
    public var model: String?
    /// The address Inkvolt Print last used for it.
    public var host: String?
    /// Addresses it had before (DHCP moved it): a queue whose device URI still points at one of them is this printer's.
    public var previousHosts: [String]

    public init(uuid: String, name: String, model: String? = nil, host: String?, previousHosts: [String] = []) {
        self.uuid = uuid
        self.name = name
        self.model = model
        self.host = host
        self.previousHosts = previousHosts
    }
}

/// The printer as a fresh Bonjour look-up by its UUID found it.
public struct Rediscovery: Equatable, Sendable {
    /// The address it announced (an IPv4 address; see `accept`).
    public var address: String
    /// Its Bonjour host name ("NPI123456.local"), which follows the printer when its address changes.
    public var hostName: String?
    /// Every address that answered for this UUID, `address` first. The UUID is public (anyone on the network can announce
    /// it), so more than one means the fixer asks before using any of them.
    public var addresses: [String]

    public init(_ address: String, hostName: String? = nil, addresses: [String]? = nil) {
        self.address = address
        self.hostName = hostName
        self.addresses = addresses ?? [address]
    }

    /// More than one device announced this printer's UUID.
    public var isAmbiguous: Bool { Self.distinct(addresses).count > 1 }

    /// What Bonjour reported, cleaned: only IPv4 addresses in their usual form (the Mac's look-ups are IPv4, as discovery
    /// is), and a host name only when it's a plain `.local` name (it comes from the network and ends up on screen and in
    /// the steps the user follows). Nil when no usable address is left.
    public static func accept(_ addresses: [String?], hostName: String?) -> Rediscovery? {
        let ips = distinct(addresses.compactMap { $0 }.filter(IpText.isIPv4))
        guard let first = ips.first else { return nil }
        return Rediscovery(first, hostName: isLocalName(hostName) ? IpText.trimDots(hostName!) : nil, addresses: ips)
    }

    /// "name.local" (labels of letters, digits and hyphens), nothing else.
    public static func isLocalName(_ name: String?) -> Bool {
        guard let name else { return false }
        let n = IpText.trimDots(name)
        guard n.count <= 253, n.lowercased().hasSuffix(".local") else { return false }
        let labels = n.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { l in
            (1...63).contains(l.count) && l.first != "-" && l.last != "-" && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// The same look-up with anything unusable dropped (`accept`).
    public func cleaned() -> Rediscovery? { Self.accept([address] + addresses, hostName: hostName) }

    /// The look-up from what Bonjour browsing found (`DiscoveredPrinters.join`): every address announced for `uuid`.
    public static func from(_ printers: [DiscoveredPrinter], uuid: String) -> Rediscovery? {
        let want = CupsQueues.normalizedUuid(uuid) ?? uuid.lowercased()
        let mine = printers.filter { (CupsQueues.normalizedUuid($0.uuid) ?? $0.uuid.lowercased()) == want }
        let addresses = mine.flatMap { $0.addresses.isEmpty ? [$0.host].compactMap { $0 } : $0.addresses }
        return accept(addresses, hostName: mine.lazy.compactMap(\.hostName).first)
    }

    static func distinct(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Which of the printing and web ports accepted a connection at an address. No ping: the sandbox has no ICMP, and ping
/// alone was never enough (another device may hold the address).
public struct Reachability: Equatable, Sendable {
    public var host: String
    public var openPorts: [Int]

    public init(_ host: String, openPorts: [Int] = []) {
        self.host = host
        self.openPorts = openPorts
    }

    /// The ports tried: IPP, raw printing (JetDirect), the web page (HTTP, HTTPS).
    public static let ports = [631, 9100, 80, 443]

    public var answers: Bool { !openPorts.isEmpty }

    /// "IPP, raw printing (port 9100) and its web page".
    public var portsText: String {
        var parts: [String] = []
        for p in openPorts {
            let text = switch p {
            case 631: "IPP"
            case 9100: "raw printing (port 9100)"
            case 80, 443: "its web page"
            default: "port \(p)"
            }
            if !parts.contains(text) { parts.append(text) }
        }
        return Self.join(parts)
    }

    static func join(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// Asks each of `ports` at `host` at the same time, through the same TCP connect Add a printer's search uses. A port
    /// whose connect fails is closed; only cancellation ends the check early.
    public static func check(_ host: String, with scanner: any NetworkScanner, timeout: Duration = .milliseconds(1500)) async throws -> Reachability {
        let open = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            for port in ports {
                group.addTask {
                    do { return (port, try await scanner.isOpen(host, port: port, timeout: timeout)) } catch is CancellationError {
                        throw CancellationError()
                    } catch { return (port, false) }
                }
            }
            var open = Set<Int>()
            for try await (port, isOpen) in group where isOpen { open.insert(port) }
            return open
        }
        try Task.checkCancellation()
        return Reachability(host, openPorts: ports.filter(open.contains))
    }
}

/// What the fixer needs from the Mac and the network besides the print queues (`PrintQueues`). PrintMac implements it
/// (Bonjour, TCP); tests and demo mode use fakes. Each call may throw; the diagnosis reports a failed probe as "couldn't
/// check", except a cancellation, which ends it.
public protocol OfflineProbes: Sendable {
    /// Looks for the printer on the network by its UUID (a fresh Bonjour browse and resolve; `Rediscovery.from` joins what
    /// it finds); nil when it doesn't show up in time.
    func rediscover(_ uuid: String) async throws -> Rediscovery?

    /// Which of `Reachability.ports` accept a TCP connection at `host` (`Reachability.check`).
    func reach(_ host: String) async throws -> Reachability
}

public enum CheckKind: CaseIterable, Equatable, Sendable { case network, connection, queues, queueState }

public enum CheckState: Equatable, Sendable { case waiting, running, passed, warning, failed, skipped }

/// One line of the diagnosis as it runs: "Printer answers · Answers at 192.0.2.23: IPP".
public struct CheckResult: Equatable, Sendable {
    public var kind: CheckKind
    public var state: CheckState
    public var title: String
    public var detail: String

    public init(_ kind: CheckKind, _ state: CheckState, _ detail: String = "") {
        self.kind = kind
        self.state = state
        title = Self.titleOf(kind)
        self.detail = detail
    }

    public static func titleOf(_ kind: CheckKind) -> String {
        switch kind {
        case .network: "Printer on the network"
        case .connection: "Printer answers"
        case .queues: "macOS printers for this device"
        case .queueState: "Paused, not accepting jobs or stuck jobs"
        }
    }

    public static func waiting(_ kind: CheckKind) -> CheckResult { CheckResult(kind, .waiting) }
}

/// Why a queue was taken for this printer, most certain first: the UUID in its device URI, its address or host name
/// there, its Bonjour service name, or (fixed-address queues only) its name starting with the printer's model or name.
public enum MatchReason: Equatable, Sendable { case uuid, address, service, name }

/// A macOS print queue that prints to this printer, its jobs, why it was matched, and whether its device URI points
/// somewhere else.
public struct MatchedQueue: Equatable, Sendable {
    public var queue: CupsDestination
    /// The jobs in it that aren't finished (none when cupsd couldn't list them).
    public var jobs: [QueueJob]
    public var reason: MatchReason
    public var portIsStale: Bool

    public init(queue: CupsDestination, jobs: [QueueJob] = [], reason: MatchReason, portIsStale: Bool) {
        self.queue = queue
        self.jobs = jobs
        self.reason = reason
        self.portIsStale = portIsStale
    }

    /// "raw printing (HP Jetdirect - Socket) to 192.0.2.12", "Bonjour (macOS finds the printer by its name)".
    public var portText: String {
        let uri = queue.deviceUri ?? ""
        let host = CupsQueues.host(uri) ?? uri
        if CupsQueues.scheme(uri) == "dnssd" || CupsQueues.serviceInstance(uri) != nil { return "Bonjour (macOS finds the printer by its name)" }
        return switch CupsQueues.scheme(uri) {
        case "socket": "raw printing (HP Jetdirect - Socket) to \(host)"
        case "lpd": "LPD to \(host)"
        case "ipp", "ipps", "http", "https": "IPP to \(host)"
        default: CupsQueues.connectionText(queue)
        }
    }

    /// Stopped: printer-state 5 (paused by someone, or by macOS when a job failed).
    public var isPaused: Bool { queue.state == 5 }
}

/// Text checks for addresses, Foundation only.
enum IpText {
    /// A dotted IPv4 address in its usual form ("192.0.2.23", not "192.0.2.023").
    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            (1...3).contains(p.count) && p.allSatisfy { $0.isASCII && $0.isNumber } && (p.count == 1 || p.first != "0") && Int(p)! <= 255
        }
    }

    /// An IPv4 or IPv6 address rather than a name (device URIs give IPv6 hosts without their brackets).
    static func isAddress(_ host: String) -> Bool { isIPv4(host) || (host.contains(":") && host.allSatisfy { $0.isHexDigit || ":.%".contains($0) }) }

    static func trimDots(_ name: String) -> String {
        var n = name
        while n.hasSuffix(".") { n.removeLast() }
        return n
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return trimDots(a).caseInsensitiveCompare(trimDots(b)) == .orderedSame
    }
}
