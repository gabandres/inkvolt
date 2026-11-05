import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// What a printer can't make the app do over HTTP: ask another computer. Ported from RobustnessTests.cs'
/// DeviceHttpLimitsTests with the same names, its host tests (found missing on the Mac by ReportRecordingTests'
/// A_printer_cant_point_the_recorder_at_another_computer, 2026-11-05). Left out: the reply limits (32 MB, a scanned page's
/// 1 GB), which sit in the transport on the Mac (PrintMac's URLSession transport bounds a recording's replies) and aren't
/// ported for the app's own reads yet (mac/docs/PLAN.md, P12 1.2).
struct DeviceHttpLimitsTests {
    private static let host = "192.0.2.10", other = "192.0.2.200"

    /// Answers every request with `body` and keeps what was asked.
    final class Serving: HttpTransport {
        private let body: [UInt8]
        private let status: Int
        private let log = Mutex<[URL]>([])
        var asked: [URL] { log.withLock { $0 } }

        init(_ body: [UInt8], status: Int = 200) {
            self.body = body
            self.status = status
        }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            log.withLock { $0.append(request.url) }
            return HttpResponse(status: status, body: status == 200 ? body : [])
        }
    }

    private static func m234dw(_ name: String) -> [UInt8]? {
        FileManager.default.contents(atPath: Fixtures.root.appendingPathComponent("m234dw").appendingPathComponent(name).path).map { Array($0) }
    }

    @Test(arguments: ["http://192.0.2.200/secret.xml", "https://192.0.2.200/secret.xml", "http://192.0.2.10.evil.example/secret.xml",
                      "http://user@192.0.2.200/secret.xml"])
    func A_request_to_another_computer_isnt_sent(_ url: String) async throws {
        let serving = Serving([1])
        let http = DeviceHttp(host: Self.host, transport: serving)
        await #expect(throws: DeviceNetworkError.self) { try await http.getBytesOrNil(URL(string: url)!) }
        await #expect(throws: DeviceNetworkError.self) { try await http.sendOnce(HttpRequest("POST", URL(string: url)!)) }
        #expect(serving.asked.isEmpty)
    }

    @Test(arguments: [
        ("192.0.2.10", "http://192.0.2.10/a"),
        ("192.0.2.10", "http://192.0.2.10:631/ipp/print"),
        ("192.0.2.10", "https://192.0.2.10/a"),
        ("192.0.2.10", "https://192.0.2.10:8443/eSCL/"),
        ("HP-Printer.local", "http://hp-printer.LOCAL:8080/a"),
        ("HP-Printer.local", "https://HP-PRINTER.local/a"),
        ("2001:db8::5", "http://[2001:db8::5]:631/ipp/print"),
        ("[2001:db8::5]", "https://[2001:db8::5]/a"),
    ])
    func The_printers_own_host_on_any_port_or_scheme_is_asked(_ host: String, _ url: String) async throws {
        let serving = Serving([1, 2, 3])
        let http = DeviceHttp(host: host, transport: serving)
        #expect(try await http.getBytesOrNil(URL(string: url)!) == [1, 2, 3])
        #expect(serving.asked == [URL(string: url)!])
    }

    @Test(arguments: ["ftp://192.0.2.10/a", "file:///C:/Windows/win.ini"])
    func Only_web_addresses_are_asked_on_the_printer_too(_ url: String) async throws {
        let serving = Serving([1])
        let http = DeviceHttp(host: Self.host, transport: serving)
        await #expect(throws: DeviceNetworkError.self) { try await http.getBytesOrNil(URL(string: url)!) }
        #expect(serving.asked.isEmpty)
    }

    @Test(arguments: [
        "http://192.0.2.200/DevMgmt/ProductStatusDyn.xml",
        "//192.0.2.200/DevMgmt/ProductStatusDyn.xml",
        "http://NPI1A2B3C.local/DevMgmt/ProductStatusDyn.xml", // its own .local name: the same document, on the address in use
    ])
    func A_link_in_a_printers_documents_stays_on_it_and_still_reads(_ link: String) async throws {
        let tree = String(decoding: Self.m234dw("DevMgmt_DiscoveryTree.xml") ?? [], as: UTF8.self)
            .replacingOccurrences(of: "/DevMgmt/ProductStatusDyn.xml", with: link)
        #expect(tree.contains(link))
        let printer = FixtureTransport(document: { name in name == "DevMgmt_DiscoveryTree.xml" ? Array(tree.utf8) : Self.m234dw(name) })
        let elsewhere = Serving([1])
        let http = DeviceHttp(host: Self.host, transport: HostRouter([Self.host: printer, Self.other: elsewhere]))
        let ledm = LedmClient(http)

        #expect(try await ledm.status() != nil)
        #expect(elsewhere.asked.isEmpty)
    }

    @Test func A_settings_link_with_the_password_stays_on_the_printer_keeping_its_scheme_and_port() {
        let http = DeviceHttp(host: Self.host, transport: Serving([1]))
        #expect(http.https("https://192.0.2.200/DevMgmt/Settings.xml") == URL(string: "https://192.0.2.10/DevMgmt/Settings.xml"))
        #expect(http.https("https://user:pw@192.0.2.200:8443/x") == URL(string: "https://192.0.2.10:8443/x"))
        #expect(http.http("http://192.0.2.200:8080/x?a=1") == URL(string: "http://192.0.2.10:8080/x?a=1"))
        #expect(http.https("https://192.0.2.10:8443/x") == URL(string: "https://192.0.2.10:8443/x"))
        #expect(http.http("/DevMgmt/x.xml") == URL(string: "http://192.0.2.10/DevMgmt/x.xml"))
    }

    @Test func An_escl_address_kept_from_before_is_asked_on_the_printers_address_at_its_own_port() async throws {
        let here = Serving([], status: 404), there = Serving([], status: 404)
        let http = DeviceHttp(host: Self.host, transport: HostRouter([Self.host: here, Self.other: there]))
        let scanner = EsclClient(http, root: URL(string: "http://\(Self.other):8080/eSCL/")!)
        #expect(scanner.root == URL(string: "http://\(Self.host):8080/eSCL/"))
        _ = try? await PrinterConnection.probe(http, esclHint: URL(string: "http://\(Self.other):8080/eSCL/"))
        #expect(there.asked.isEmpty)
        #expect(here.asked.contains { $0.port == 8080 && $0.path == "/eSCL/ScannerCapabilities" })
    }
}
