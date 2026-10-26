import Foundation
import Network

/// Research open items 5 to 7: Bonjour types, SNMP over UDP (broadcast and unicast), the TCP sweep, and how a Local
/// Network denial shows up in each.
enum NetworkChecks {
    static let listedTypes = ["_ipp._tcp", "_ipps._tcp", "_uscan._tcp", "_uscans._tcp", "_pdl-datastream._tcp", "_printer._tcp"]
    static let unlistedTypes = ["_http._tcp", "_airplay._tcp", "_companion-link._tcp"]

    /// SNMPv2c GetNext of sysDescr (1.3.6.1.2.1.1.1), community "public", request ID 1.
    static let snmpGetNext: [UInt8] = [
        0x30, 0x25,
        0x02, 0x01, 0x01,
        0x04, 0x06, 0x70, 0x75, 0x62, 0x6C, 0x69, 0x63,
        0xA1, 0x18,
        0x02, 0x01, 0x01,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x00,
        0x30, 0x0D, 0x30, 0x0B,
        0x06, 0x07, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01,
        0x05, 0x00,
    ]

    // MARK: Bonjour

    @MainActor static func bonjour(_ log: ProbeLog) async {
        for type in listedTypes + unlistedTypes {
            let result = await browse(type, seconds: 4)
            log.add("\(type) (\(listedTypes.contains(type) ? "listed" : "not listed")): \(result)")
        }
    }

    /// Counts only: service names can carry people's names.
    static func browse(_ type: String, seconds: Double) async -> String {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
            let once = Once()
            let seen = BrowseState()
            let finish: @Sendable (String) -> Void = { text in
                guard once.claim() else { return }
                browser.cancel()
                continuation.resume(returning: text)
            }
            browser.stateUpdateHandler = { update in
                switch update {
                case .ready: seen.state = "ready"
                case .waiting(let error): seen.state = "waiting \(error)"
                case .failed(let error): finish("failed \(error)")
                default: break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in seen.count = results.count }
            browser.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + seconds) { finish("\(seen.state), \(seen.count) found") }
        }
    }

    // MARK: SNMP

    @MainActor static func snmpBroadcast(_ log: ProbeLog) async {
        let networks = ipv4Interfaces().filter { $0.broadcast != nil }
        if networks.isEmpty { log.add("No IPv4 network with a broadcast address.") }
        for network in networks {
            let target = network.broadcast!
            let result = await offMain { udpSnmp(to: target, broadcast: true, wait: 2) }
            log.add("\(network.name) broadcast \(mask(target)): \(result)")
        }
    }

    @MainActor static func snmpUnicast(_ log: ProbeLog, address: String) async {
        guard isIPv4(address) else { log.add("Enter an IPv4 address."); return }
        let socketResult = await offMain { udpSnmp(to: address, broadcast: false, wait: 2) }
        log.add("BSD socket to \(mask(address)): \(socketResult)")
        log.add("Network framework to \(mask(address)): \(await networkFrameworkSnmp(address))")
    }

    static func udpSnmp(to target: String, broadcast: Bool, wait: Double) -> String {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return "socket failed: \(errnoText())" }
        defer { close(fd) }
        var on: Int32 = 1
        if broadcast, setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            return "SO_BROADCAST failed: \(errnoText())"
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(161).bigEndian
        guard inet_pton(AF_INET, target, &address.sin_addr) == 1 else { return "bad address" }
        let sent = snmpGetNext.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == snmpGetNext.count else { return "sendto failed: \(errnoText())" }

        var replies: [String] = []
        var receiveError = ""
        let capacity = 2048
        var buffer = [UInt8](repeating: 0, count: capacity)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let length = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, capacity, 0, $0, &fromLength)
                }
            }
            if length > 0 {
                replies.append("\(mask(ipString(from.sin_addr))) \(length) bytes\(buffer[0] == 0x30 ? "" : " (not SNMP)")")
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                receiveError = errnoText()
                break
            }
        }
        var text = "sent \(sent) bytes; \(replies.count) \(replies.count == 1 ? "reply" : "replies")"
        if !replies.isEmpty { text += ": " + replies.joined(separator: ", ") }
        if !receiveError.isEmpty { text += "; receive failed: \(receiveError)" }
        return text
    }

    static func networkFrameworkSnmp(_ address: String) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(address), port: 161, using: .udp)
            let once = Once()
            let finish: @Sendable (String) -> Void = { text in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: text)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(snmpGetNext), completion: .contentProcessed { error in
                        if let error { finish("send failed: \(error)") }
                    })
                    connection.receiveMessage { data, _, _, error in
                        finish(data.map { "reply \($0.count) bytes" } ?? "no reply: \(error.map { "\($0)" } ?? "-")")
                    }
                case .waiting(let error):
                    finish("waiting: \(error)\(denied(connection) ? " (localNetworkDenied)" : "")")
                case .failed(let error):
                    finish("failed: \(error)")
                default:
                    break
                }
            }
            connection.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + 3) { finish("timed out\(denied(connection) ? " (localNetworkDenied)" : "")") }
        }
    }

    // MARK: TCP sweep

    enum TcpResult { case open, closed, denied, timedOut }

    @MainActor static func sweep(_ log: ProbeLog) async {
        guard let network = ipv4Interfaces().first(where: { $0.isPrivate }) else { log.add("No private IPv4 network."); return }
        let prefix = network.address.split(separator: ".").prefix(3).joined(separator: ".")
        var targets: [(String, UInt16)] = []
        for host in 1...254 where "\(prefix).\(host)" != network.address {
            for port: UInt16 in [631, 9100, 515] { targets.append(("\(prefix).\(host)", port)) }
        }
        log.add("\(network.name): \(targets.count) connections, 96 at a time, 1.5 s timeout")
        let started = Date()
        var open: [String] = []
        var denied = 0, timedOut = 0
        for start in stride(from: 0, to: targets.count, by: 96) {
            let chunk = targets[start..<min(start + 96, targets.count)]
            let results = await withTaskGroup(of: (String, UInt16, TcpResult).self) { group in
                for (host, port) in chunk {
                    group.addTask { (host, port, await tcpProbe(host, port, timeout: 1.5)) }
                }
                var all: [(String, UInt16, TcpResult)] = []
                for await result in group { all.append(result) }
                return all
            }
            for (host, port, result) in results {
                switch result {
                case .open: open.append("\(mask(host)):\(port)")
                case .denied: denied += 1
                case .timedOut: timedOut += 1
                case .closed: break
                }
            }
        }
        log.add(String(format: "%.1f s: %d open, %d localNetworkDenied, %d timed out",
                       Date().timeIntervalSince(started), open.count, denied, timedOut))
        if !open.isEmpty { log.add("Open: " + open.sorted().joined(separator: ", ")) }
    }

    static func tcpProbe(_ host: String, _ port: UInt16, timeout: Double) async -> TcpResult {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish: @Sendable (TcpResult) -> Void = { result in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.open)
                case .waiting: finish(denied(connection) ? .denied : .closed)
                case .failed: finish(.closed)
                default: break
                }
            }
            connection.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + timeout) { finish(denied(connection) ? .denied : .timedOut) }
        }
    }

    private static func denied(_ connection: NWConnection) -> Bool {
        connection.currentPath?.unsatisfiedReason == .localNetworkDenied
    }
}

/// What a Bonjour browse has seen; touched only on `probeQueue`.
final class BrowseState: @unchecked Sendable {
    var state = "setup"
    var count = 0
}

// MARK: - IPv4 interfaces

struct IPv4Interface {
    let name: String
    let address: String
    let netmask: String?
    let broadcast: String?

    var isPrivate: Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
    }
}

func ipv4Interfaces() -> [IPv4Interface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var result: [IPv4Interface] = []
    var cursor = head
    while let entry = cursor?.pointee {
        cursor = entry.ifa_next
        let flags = Int32(bitPattern: entry.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = ipv4String(entry.ifa_addr) else { continue }
        result.append(IPv4Interface(
            name: String(cString: entry.ifa_name),
            address: address,
            netmask: ipv4String(entry.ifa_netmask),
            broadcast: flags & IFF_BROADCAST != 0 ? ipv4String(entry.ifa_dstaddr) : nil))
    }
    return result
}

func ipv4String(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
    guard let pointer, pointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
    return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipString($0.pointee.sin_addr) }
}

func ipString(_ address: in_addr) -> String {
    var address = address
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
