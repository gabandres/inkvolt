/// Carries SNMP datagrams to a printer's agent: UDP port 161 (in PrintMac), or a made-up agent (`SnmpAgent`).
public protocol SnmpTransport: Sendable {
    /// Sends one request to `host`'s agent; the first reply, or nil when none came within `timeout`. Throws only
    /// `CancellationError`.
    func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]?
}

/// Several made-up agents behind one transport (demo mode): each request goes to its host's; other hosts never answer.
public struct SnmpRouter: SnmpTransport {
    private let hosts: [String: any SnmpTransport]

    public init(_ hosts: [String: any SnmpTransport]) {
        self.hosts = Dictionary(hosts.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    public func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
        try await hosts[host.lowercased()]?.send(request, to: host, timeout: timeout)
    }
}
