import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// A printer's web server on a port of its own (HP's EWS, LEDM and CDM at `http://host:8080/`): typed in Add a printer as a
/// web address with its port, or announced in its IPP service's `adminurl`; the connection asks LEDM and CDM there, and still
/// finds a scanner on port 80. The same names as the Windows app's PrinterWebPortTests.cs.
struct PrinterWebPortTests {
    private static let host = "192.0.2.20"

    // ------------------------------------------------------------------------------------------------ where the web server is

    @Test(arguments: [
        ("http://192.0.2.20:8080", "http://192.0.2.20:8080/"),
        ("http://192.0.2.20:8080/hp/device/info", "http://192.0.2.20:8080/"),
        ("https://printer.local:8443/", "https://printer.local:8443/"),
        ("http://192.0.2.20", nil), // port 80: the default
        ("https://printer.local:443/", nil),
        ("192.0.2.20:8080", nil), // no scheme: an IPP server's port, as before
        ("ipp://192.0.2.20:8080/ipp/print", nil),
        ("http://192.0.2.20:631/ipp/print", nil), // IPP Everywhere's port and path: the IPP server, not the web server
        ("http://192.0.2.20:631/", nil),
        ("http://192.0.2.20:8631/ipp/print", nil),
        ("https://192.0.2.20:8443/ipp", nil),
        ("http://[fe80::1]:8080/", "http://[fe80::1]:8080/"),
    ] as [(String, String?)])
    func aWebAddressWithItsPortSaysWhereTheWebServerIs(_ typed: String, _ web: String?) {
        let a = PrinterAddress.parse(typed)
        #expect(a.error == nil)
        #expect(a.web?.absoluteString == web)
        if web != nil { #expect(a.ipp != nil) } // and an IPP server to try there, as before
    }

    @Test(arguments: [
        ("http://user:secret@other.example:8080/x?y#z", "http://192.0.2.20:8080/"), // only the scheme and port: on this printer
        ("ftp://192.0.2.20:2121/", nil),
        ("http://192.0.2.20:80/", nil),
        ("https://192.0.2.20/", nil),
    ] as [(String, String?)])
    func aWebRootIsASchemeAndPortOnThePrinter(_ url: String, _ root: String?) {
        #expect(PrinterAddress.webRoot(URL(string: url), host: Self.host)?.absoluteString == root)
    }

    private static func ipp(_ adminurl: String?, hostName: String? = "NPI0A1B2C.local", ipv4: String = host) -> DnssdService {
        var txt: [String: String] = ["rp": "ipp/print"]
        if let adminurl { txt["adminurl"] = adminurl }
        return DnssdService(service: "_ipp._tcp", uuid: "00000000-0000-4000-8000-000000000020", hostName: hostName, ipv4: ipv4, port: 631,
                            txt: txt)
    }

    @Test(arguments: [
        ("http://NPI0A1B2C.local:8080/#hId-pgDevInfo", "http://192.0.2.20:8080/"), // its .local name: on the address in use
        ("https://192.0.2.20:8443/", "https://192.0.2.20:8443/"),
        ("http://NPI0A1B2C.local./", nil), // port 80
        ("http://another-printer.local:8080/", nil), // names another device
        ("http://198.51.100.7:8080/", nil),
        ("javascript:alert(1)", nil),
        ("not a url", nil),
        (nil, nil),
    ] as [(String?, String?)])
    func anIPPServiceSAdminurlOnAPortOfItsOwnIsItsWebServer(_ adminurl: String?, _ root: String?) {
        #expect(DnssdJoin.webRoot(Self.ipp(adminurl), host: Self.host)?.absoluteString == root)
    }

    @Test func aVeryLongAdminurlIsLeftAlone() {
        let long = "http://NPI0A1B2C.local:8080/" + String(repeating: "a", count: 5000)
        #expect(DnssdJoin.webRoot(Self.ipp(long), host: Self.host) == nil)
    }

    @Test func theDeviceSHttpOrHttpsBaseMovesToTheWebPort() throws {
        let none = HostRouter([:])
        let plain = DeviceHttp(host: Self.host, transport: none, web: URL(string: "http://elsewhere.example:8080/"))
        #expect(plain.httpBase.absoluteString == "http://192.0.2.20:8080/")
        #expect(plain.httpsBase.absoluteString == "https://192.0.2.20/")
        let tls = DeviceHttp(host: Self.host, transport: none, web: URL(string: "https://192.0.2.20:8443/"))
        #expect(tls.httpBase.absoluteString == "http://192.0.2.20/")
        #expect(tls.httpsBase.absoluteString == "https://192.0.2.20:8443/")
        #expect(try plain.http("/DevMgmt/DiscoveryTree.xml").absoluteString == "http://192.0.2.20:8080/DevMgmt/DiscoveryTree.xml")
    }

    // ------------------------------------------------------------------------------------------------ connecting

    /// The M234dw's documents, its web server (LEDM) on port 8080 only and its scanner on port 80; port 80 has nothing else.
    final class OnPort8080: HttpTransport {
        private let inner = Printers.folder("m234dw")
        private let seenList = Mutex<[String]>([])
        var seen: [String] { seenList.withLock { $0 } }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            let port = request.url.port ?? (request.url.scheme == "https" ? 443 : 80)
            let path = request.url.path
            seenList.withLock { $0.append("\(port) \(path)") }
            let scanner = path.hasPrefix("/eSCL/")
            if (port == 8080 && !scanner) || (port == 80 && scanner) { return try await inner.send(request) }
            return HttpResponse(status: 404)
        }
    }

    @Test func withoutItsWebPortThePrinterSLEDMIsnTFound() async throws {
        let conn = try await PrinterConnection.open(Self.host, transport: OnPort8080())
        #expect(!conn.probe.interfaces.contains("LEDM"))
    }

    @Test func withItsWebPortLEDMIsReadThereAndTheScannerStillFoundOnPort80() async throws {
        let printer = OnPort8080()
        let conn = try await PrinterConnection.open(Self.host, transport: printer, webHint: URL(string: "http://192.0.2.20:8080/"))
        #expect(conn.probe.interfaces.contains("LEDM"))
        #expect(conn.probe.interfaces.contains("eSCL"))
        #expect(conn.probe.esclRoot?.absoluteString == "http://192.0.2.20/eSCL/")
        let reading = try await conn.read()
        #expect(reading.status.message == "Ready")
        #expect(printer.seen.contains("8080 /DevMgmt/ProductStatusDyn.xml"))
        #expect(!printer.seen.contains("80 /DevMgmt/ProductStatusDyn.xml"))
    }

    @Test func aPrinterSSessionConnectsWithTheWebHintItWasGiven() async throws {
        let session = PrinterSession(id: PrinterId.normalize(nil, host: Self.host),
                                     recipe: PrinterRecipe(transport: { _, _ in OnPort8080() }, snmp: SnmpRouter([:])),
                                     accepted: { [] }, acceptUuids: { _ in })
        let step = try await session.connect(PrinterWhere(Self.host, webHint: URL(string: "http://192.0.2.20:8080/")))
        guard case .connected(let connection, _) = step else {
            Issue.record("Not connected: \(step)")
            return
        }
        #expect(connection.probe.interfaces.contains("LEDM"))
    }

    // ------------------------------------------------------------------------------------------------ kept, or let go

    @Test func aWebRootIsKeptOnlyWhereLEDMOrCDMAnswered() async throws {
        let web = URL(string: "http://192.0.2.20:8080/")!
        let laser = try await PrinterConnection.probe(DeviceHttp(host: Self.host, transport: OnPort8080(), web: web))
        #expect(laser.webRootKept(web) == web)
        // The inkjet answers IPP only: a typed port that isn't its web server isn't kept.
        let inkjet = try await PrinterConnection.probe(DeviceHttp(host: Self.host, transport: Printers.ippOnly(), web: web))
        #expect(inkjet.reachable)
        #expect(inkjet.webRootKept(web) == nil)
    }

    @Test(arguments: [true, false])
    func theMonitorLetsAWebRootGoOnceNothingOfTheWebServerAnswersThere(_ ledmThere: Bool) async throws {
        let network: @Sendable () -> any HttpTransport = { ledmThere ? OnPort8080() as any HttpTransport : Printers.ippOnly() }
        let recipe = PrinterRecipe(transport: { _, _ in network() }, snmp: SnmpRouter([:]))
        let m = PrinterMonitor(id: ledmThere ? Demo.uuid : Demo.inkjetUuid, name: "Printer",
                               target: PrinterWhere(Self.host, webHint: URL(string: "http://192.0.2.20:8080/")), recipe: recipe,
                               accepted: { [] }, acceptUuids: { _ in }, retryDelay: .milliseconds(50), fallbackRefresh: .milliseconds(200),
                               onEvent: { _ in })
        let run = Task { await m.run() }
        defer { run.cancel() }
        var online = false
        for _ in 0..<1000 {
            online = await m.view.isOnline
            if online { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(online)
        #expect(await m.target.webHint?.absoluteString == (ledmThere ? "http://192.0.2.20:8080/" : nil))
    }
}
