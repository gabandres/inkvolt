import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Search my network (Add a printer): which addresses are asked, that each printer is reported once, what an address typed
/// in becomes, with a made-up network (no packets sent). Ported from NetworkSearchTests.cs.
struct NetworkSearchTests {
    private static func net(_ address: String, _ prefix: Int) -> LocalNetwork { LocalNetwork(address, prefix) }

    /// A made-up network: the hosts listening on each port, and those whose SNMP agent answers a broadcast.
    final class FakeNetwork: NetworkScanner {
        private let networks: [LocalNetwork]
        let open: [String: [Int]]
        let snmpAnswers: [String]
        /// The SNMP question waits for its window (until cancelled), as a real one does, and so does every connection.
        let snmpWaits: Bool
        private let log = Mutex<(asked: [String], broadcasts: [String], requests: [[UInt8]], snmpStopped: Bool)>(([], [], [], false))

        init(_ networks: [LocalNetwork], open: [String: [Int]] = [:], snmpAnswers: [String] = [], snmpWaits: Bool = false) {
            self.networks = networks
            self.open = open
            self.snmpAnswers = snmpAnswers
            self.snmpWaits = snmpWaits
        }

        var asked: [String] { log.withLock { $0.asked } }
        var broadcasts: [String] { log.withLock { $0.broadcasts } }
        var requests: [[UInt8]] { log.withLock { $0.requests } }
        var snmpStopped: Bool { log.withLock { $0.snmpStopped } }

        func localNetworks() -> [LocalNetwork] { networks }

        func isOpen(_ host: String, port: Int, timeout: Duration) async throws -> Bool {
            try Task.checkCancellation()
            if snmpWaits { // a slow network: the search is stopped mid-way
                try await Task.sleep(for: .seconds(3600))
                return false
            }
            log.withLock { $0.asked.append("\(host):\(port)") }
            return open[host]?.contains(port) ?? false
        }

        func broadcastSnmp(_ broadcasts: [String], requests: [[UInt8]], window: Duration, answered: @escaping @Sendable (String) -> Void) async throws {
            log.withLock { l in
                l.broadcasts += broadcasts
                l.requests += requests
            }
            for host in snmpAnswers { answered(host) }
            guard snmpWaits else { return }
            defer { log.withLock { $0.snmpStopped = true } }
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private static func search(_ network: FakeNetwork, progress: (@Sendable (SearchProgress) -> Void)? = nil) async throws -> [String] {
        let found = Mutex<[String]>([])
        try await NetworkSearch.search(network, found: { a in found.withLock { $0.append(a) } }, progress: progress)
        return found.withLock { $0 }
    }

    // MARK: Which addresses

    @Test func aHomeNetworkIsEveryOtherAddressInIt() {
        let hosts = NetworkSearch.addresses(Self.net("192.168.1.23", 24))
        #expect(hosts.count == 253) // .1 to .254, not this Mac
        #expect(hosts.first == "192.168.1.1")
        #expect(hosts.last == "192.168.1.254")
        #expect(!hosts.contains("192.168.1.23"))
        #expect(!hosts.contains("192.168.1.0"))
        #expect(!hosts.contains("192.168.1.255"))
    }

    @Test func aSmallNetworkIsAskedWhole() {
        let hosts = NetworkSearch.addresses(Self.net("10.0.0.5", 22))
        #expect(hosts.count == 1021) // 10.0.0.1 to 10.0.3.254, not this Mac
        #expect(hosts.contains("10.0.3.254"))
        #expect(NetworkSearch.broadcast(Self.net("10.0.0.5", 22)) == "10.0.3.255")
    }

    @Test func aLargeNetworkIsAskedOnlyAroundThisMac() {
        // A /16 would be 65,000 addresses: only the /24 this Mac is in.
        let hosts = NetworkSearch.addresses(Self.net("172.16.40.7", 16))
        #expect(hosts.count == 253)
        #expect(hosts.allSatisfy { $0.hasPrefix("172.16.40.") })
        #expect(NetworkSearch.broadcast(Self.net("172.16.40.7", 16)) == "172.16.255.255")
    }

    @Test(arguments: [
        ("8.8.4.4", 24), // a public address: never swept
        ("169.254.3.4", 16), // no DHCP answer (link-local): nothing there to find
        ("127.0.0.1", 8),
        ("192.168.1.1", 31), // a point-to-point link
        ("192.168.1.1", 32),
        ("100.64.1.2", 24), // carrier-grade NAT (a VPN like Tailscale): not this site's network
    ] as [(String, Int)])
    func networksNotWorthAskingAreSkipped(_ address: String, _ prefix: Int) {
        #expect(NetworkSearch.addresses(Self.net(address, prefix)).isEmpty)
        #expect(NetworkSearch.broadcast(Self.net(address, prefix)) == nil)
    }

    @Test(arguments: [
        ("Ethernet 3", "Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter for Windows x64"),
        ("Ethernet 2", "PANGP Virtual Ethernet Adapter Secure"), // GlobalProtect
        ("Local Area Connection", "TAP-Windows Adapter V9"), // OpenVPN
        ("OpenVPN Data Channel Offload", "OpenVPN Data Channel Offload"),
        ("Ethernet 4", "Fortinet SSL VPN Virtual Ethernet Adapter"),
        ("WireGuard Tunnel", "WireGuard Tunnel"),
        ("Tailscale", "Tailscale Tunnel"),
        ("vEthernet (WSL)", "Hyper-V Virtual Ethernet Adapter"),
        ("ZeroTier One", "ZeroTier Virtual Port"),
        ("Ethernet 5", "Juniper Networks Virtual Adapter"),
        ("NordLynx", "NordLynx Tunnel"),
    ] as [(String, String)])
    func vpnAndVirtualAdaptersAreNotSearched(_ name: String, _ description: String) {
        #expect(!NetworkSearch.isLan(name, description))
    }

    @Test(arguments: [
        ("Wi-Fi", "Intel(R) Wi-Fi 6E AX211 160MHz"),
        ("Ethernet", "Realtek USB GbE Family Controller"),
        ("Wi-Fi", "Qualcomm FastConnect 7800 Wi-Fi 7 High Band Simultaneous (HBS) Network Adapter"),
    ] as [(String, String)])
    func homeAndOfficeAdaptersAreSearched(_ name: String, _ description: String) {
        #expect(NetworkSearch.isLan(name, description))
    }

    @Test func aStoppedSearchStopsItsSnmpQuestionToo() async throws {
        let network = FakeNetwork([Self.net("192.168.1.23", 24)], snmpWaits: true)
        let search = Task { try await Self.search(network) }
        try await Task.sleep(for: .milliseconds(100))
        search.cancel()
        await #expect(throws: CancellationError.self) { try await search.value }
        #expect(network.snmpStopped) // awaited, not left running unobserved
    }

    @Test func ipv6IsNotSwept() {
        #expect(NetworkSearch.addresses(LocalNetwork("fe80::1", 64)).isEmpty)
    }

    // MARK: The search

    @Test func printerPortsAndSnmpFindPrinters() async throws {
        let network = FakeNetwork([Self.net("192.168.1.23", 24)],
                                  open: ["192.168.1.40": [631], // IPP
                                         "192.168.1.41": [9100], // raw printing only
                                         "192.168.1.42": [515], // LPD only
                                         "192.168.1.1": [80, 443]], // the router: a web server isn't a printer
                                  snmpAnswers: ["192.168.1.50"]) // an older office printer, SNMP only
        let found = try await Self.search(network)
        #expect(found.sorted() == ["192.168.1.40", "192.168.1.41", "192.168.1.42", "192.168.1.50"])
        #expect(network.broadcasts == ["192.168.1.255"])
    }

    @Test func eachHostIsReportedOnce() async throws {
        let network = FakeNetwork([Self.net("192.168.1.23", 24), Self.net("192.168.1.23", 24)], // the same network on two adapters
                                  open: ["192.168.1.40": [631, 9100, 515]],
                                  snmpAnswers: ["192.168.1.40", "192.168.1.40"]) // v1 and v2c agents both answer
        #expect(try await Self.search(network) == ["192.168.1.40"])
        #expect(network.asked.count == 253 * NetworkSearch.printerPorts.count) // each address and port once
    }

    @Test func snmpAnswersFromOtherNetworksAreIgnored() async throws {
        let network = FakeNetwork([Self.net("192.168.1.23", 24)], snmpAnswers: ["8.8.8.8", "192.168.1.23"]) // the second: this Mac's own agent
        #expect(try await Self.search(network).isEmpty)
    }

    @Test func theSnmpQuestionAsksForThePrinterTable() async throws {
        let network = FakeNetwork([Self.net("192.168.1.23", 24)])
        _ = try await Self.search(network)
        let requests = try network.requests.map(SnmpMessage.decode)
        #expect(requests.map(\.version) == [.v2c, .v1]) // agents that turned one off answer the other
        for r in requests {
            #expect(r.type == .getNextRequest)
            #expect(r.community == SnmpClient.defaultCommunity)
            #expect(r.varBinds.contains { $0.name == PrinterMib.hrPrinterStatus })
        }
    }

    @Test func progressCountsTheAddressesAsked() async throws {
        let network = FakeNetwork([Self.net("192.168.1.23", 24)])
        let reports = Mutex<[SearchProgress]>([])
        _ = try await Self.search(network) { p in reports.withLock { $0.append(p) } }
        let all = reports.withLock { $0 }
        #expect(all.allSatisfy { $0.total == 253 })
        #expect(all.map(\.checked).max() == 253)
    }

    @Test func noNetworkFindsNothing() async throws {
        let network = FakeNetwork([Self.net("8.8.4.4", 24)])
        #expect(try await Self.search(network).isEmpty)
        #expect(network.asked.isEmpty)
        #expect(network.broadcasts.isEmpty)
    }

    @Test func cancellingStops() async throws {
        let network = FakeNetwork([Self.net("192.168.1.23", 24)])
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Self.search(network)
        }
        await #expect(throws: CancellationError.self) { try await search.value }
    }

    // MARK: An address typed in

    @Test(arguments: [
        ("192.168.1.40", "192.168.1.40", nil),
        ("  192.168.1.40  ", "192.168.1.40", nil),
        ("printer.local", "printer.local", nil),
        ("NPI7A1B2C", "NPI7A1B2C", nil),
        ("http://192.168.1.40", "192.168.1.40", nil), // a web page address: the host
        ("http://192.168.1.40/hp/device/info", "192.168.1.40", nil),
        ("https://printer.local:443/", "printer.local", nil),
        ("ipp://printer.local/ipp/print", "printer.local", "http://printer.local:631/ipp/print"),
        ("ipps://printer.local/ipp/print", "printer.local", "https://printer.local:631/ipp/print"), // IPPS is port 631 too (RFC 7472)
        ("http://host:8631/ipp/print", "host", "http://host:8631/ipp/print"), // IPP on a port of its own
        ("ipp://host:8631/printers/office", "host", "http://host:8631/printers/office"),
        ("192.168.1.40:631", "192.168.1.40", "http://192.168.1.40:631/ipp/print"),
        ("host:8631", "host", "http://host:8631/ipp/print"),
        ("[fe80::1]", "[fe80::1]", nil),
    ] as [(String, String, String?)])
    func typedAddressesBecomeAHostAndIppUrl(_ typed: String, _ host: String, _ ipp: String?) {
        let a = PrinterAddress.parse(typed)
        #expect(a.error == nil)
        #expect(a.host == host)
        #expect(a.ipp?.absoluteString == ipp)
    }

    @Test(arguments: ["", "   ", "not an address", "ftp://printer.local/", "host:99999", "http://"])
    func nonsenseIsSaidToBeNoAddress(_ typed: String) {
        let a = PrinterAddress.parse(typed)
        #expect(a.error != nil)
        #expect(a.host == nil)
    }
}

/// How a printer's DNS-SD services join into one printer, and its endpoints. Ported from OtherBrandsTests.cs.
struct DnssdJoinTests {
    private static func svc(_ service: String, _ uuid: String?, _ hostName: String?, _ ip: String?, _ port: Int? = nil,
                            _ txt: [String: String] = [:]) -> DnssdService {
        DnssdService(service: service, uuid: uuid, hostName: hostName, ipv4: ip, port: port, txt: txt)
    }

    @Test func servicesJoinOnUuidAndAServiceWithoutOneJoinsItsHost() {
        let ipp = Self.svc("_ipp._tcp", "{2F1E6C3A-5B7D-4E8F-9A0B-1C2D3E4F5A6B}", "Example-0000.local", "192.0.2.11")
        let scan = Self.svc("_uscan._tcp", nil, "Example-0000.local", "192.0.2.11")
        let lone = Self.svc("_ipp._tcp", nil, "Other.local", "192.0.2.12")
        let none = Self.svc("_ipp._tcp", "not-a-uuid", nil, nil)
        let all = [ipp, scan, lone, none]
        #expect(DnssdJoin.key(ipp, all) == "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b")
        #expect(DnssdJoin.key(scan, all) == "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b")
        #expect(DnssdJoin.key(lone, all) == nil) // no UUID anywhere on its host: not joined (add it by address)
        #expect(DnssdJoin.key(none, all) == "not-a-uuid") // not a GUID: kept as published (the app's list skips it)
    }

    @Test func servicesSharingAUuidThatIsNotAGuidStillJoin() {
        let ipp = Self.svc("_ipp._tcp", "printer-0001", "Example-0000.local", "192.0.2.11")
        let scan = Self.svc("_uscan._tcp", "printer-0001", "Example-0000.local", "192.0.2.11")
        let bare = Self.svc("_uscan._tcp", nil, "Example-0000.local", "192.0.2.11")
        let all = [ipp, scan, bare]
        #expect(all.map { DnssdJoin.key($0, all) } == ["printer-0001", "printer-0001", "printer-0001"])
        // A GUID on the host still wins for a service without a UUID.
        let guid = Self.svc("_ipps._tcp", "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b", "Example-0000.local", "192.0.2.11")
        #expect(DnssdJoin.key(bare, all + [guid]) == "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b")
    }

    @Test(arguments: [
        ("_ipp._tcp", 631, "ipp/print", "http://192.0.2.11:631/ipp/print"),
        ("_ipps._tcp", 631, "ipp/print", "https://192.0.2.11:631/ipp/print"),
        ("_ipp._tcp", 8631, "/ipp/printer/", "http://192.0.2.11:8631/ipp/printer"),
        ("_ipp._tcp", nil, nil, "http://192.0.2.11:631/ipp/print"),
        ("_ipp._tcp", 631, "", "http://192.0.2.11:631/"),
        ("_ipp._tcp", 631, "../../x?y#z", nil),
    ] as [(String, Int?, String?, String?)])
    func ippEndpointFromTxtRp(_ service: String, _ port: Int?, _ rp: String?, _ expected: String?) {
        let s = Self.svc(service, nil, nil, "192.0.2.11", port, rp.map { ["rp": $0] } ?? [:])
        #expect(DnssdJoin.ippUri(s, host: "192.0.2.11")?.absoluteString == expected)
    }

    @Test(arguments: [
        ("_uscan._tcp", 80, "eSCL", "http://192.0.2.11/eSCL/"),
        ("_uscans._tcp", 443, "/eSCL", "https://192.0.2.11/eSCL/"),
        ("_uscan._tcp", 8080, nil, "http://192.0.2.11:8080/eSCL/"),
        ("_uscan._tcp", 80, "", "http://192.0.2.11/"),
    ] as [(String, Int?, String?, String)])
    func esclRootFromTxtRs(_ service: String, _ port: Int?, _ rs: String?, _ expected: String) {
        let s = Self.svc(service, nil, nil, "192.0.2.11", port, rs.map { ["rs": $0] } ?? [:])
        #expect(DnssdJoin.esclRoot(s, host: "192.0.2.11")?.absoluteString == expected)
    }
}
