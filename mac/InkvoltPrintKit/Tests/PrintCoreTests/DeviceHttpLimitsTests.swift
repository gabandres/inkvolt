import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// What a printer can't make the app do over HTTP: ask another computer. Ported from RobustnessTests.cs'
/// DeviceHttpLimitsTests with the same names, its host tests (found missing on the Mac by ReportRecordingTests'
/// A_printer_cant_point_the_recorder_at_another_computer, 2026-11-05), and its reply limits (32 MB, a scanned page's 1 GB):
/// on the Mac each request carries its limit (`HttpRequest.replyLimit`) and the transport keeps no more of a reply, so here a
/// transport that keeps what PrintMac's URLSession transport keeps (`Bounded`); PrintMacTests' TransportTests check the real
/// one over this Mac's sockets.
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

    @Test func A_settings_link_with_the_password_stays_on_the_printer_keeping_its_scheme_and_port() throws {
        let http = DeviceHttp(host: Self.host, transport: Serving([1]))
        #expect(try http.https("https://192.0.2.200/DevMgmt/Settings.xml") == URL(string: "https://192.0.2.10/DevMgmt/Settings.xml"))
        #expect(try http.https("https://user:pw@192.0.2.200:8443/x") == URL(string: "https://192.0.2.10:8443/x"))
        #expect(try http.http("http://192.0.2.200:8080/x?a=1") == URL(string: "http://192.0.2.10:8080/x?a=1"))
        #expect(try http.https("https://192.0.2.10:8443/x") == URL(string: "https://192.0.2.10:8443/x"))
        #expect(try http.http("/DevMgmt/x.xml") == URL(string: "http://192.0.2.10/DevMgmt/x.xml"))
    }

    @Test func A_path_that_isnt_a_web_address_is_refused_not_sent_to_the_printers_root() async throws {
        let printer = Serving(Array("<x/>".utf8))
        let http = DeviceHttp(host: Self.host, transport: printer)
        #expect(throws: DeviceNetworkError.self) { try http.http("http://[oops/x") }
        #expect(throws: DeviceNetworkError.self) { try http.https("http://[oops/x") }
        await #expect(throws: DeviceNetworkError.self) { try await LedmClient(http).get(path: "http://[oops/x") }
        #expect(printer.asked.isEmpty)
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

    /// Keeps what PrintMac's transport keeps of a reply of `size` bytes: read in 64 KB pieces, given up on past the request's
    /// `replyLimit`. `read` is how much it read before it stopped.
    final class Bounded: HttpTransport {
        let size: Int
        private let counted = Mutex(0)
        var read: Int { counted.withLock { $0 } }

        init(_ size: Int) { self.size = size }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            try Self.keep(size, request, counted)
            return HttpResponse(status: 200, body: [UInt8](repeating: 0x30, count: size))
        }

        static func keep(_ size: Int, _ request: HttpRequest, _ counted: borrowing Mutex<Int>) throws {
            var kept = 0
            while kept < size {
                let piece = min(1 << 16, size - kept)
                if kept + piece > request.replyLimit {
                    counted.withLock { $0 = kept + piece }
                    throw DeviceNetworkError.failed("The reply was longer than \(request.replyLimit / (1 << 20)) MB")
                }
                kept += piece
            }
            counted.withLock { $0 = kept }
        }
    }

    @Test func A_reply_that_never_ends_is_given_up_on_at_the_limit() async throws {
        let reply = Bounded(300 << 20)
        let http = DeviceHttp(host: Self.host, transport: reply)
        await #expect(throws: DeviceNetworkError.self) { try await http.getBytesOrNil(try http.http("/x")) }
        #expect(reply.read >= 1 && reply.read <= DeviceHttp.maxReplyBytes + (1 << 20))
    }

    @Test func A_reply_at_the_limit_is_whole_and_a_scanned_page_may_be_longer() async throws {
        let http = DeviceHttp(host: Self.host, transport: Bounded(DeviceHttp.maxReplyBytes))
        #expect(try await http.getBytesOrNil(try http.http("/x"))?.count == DeviceHttp.maxReplyBytes)

        let page = DeviceHttp.maxReplyBytes + 1000
        let scanner = DeviceHttp(host: Self.host, transport: Bounded(page))
        var request = HttpRequest("GET", try scanner.http("/eSCL/ScanJobs/1/NextDocument"))
        request.allowLongReply()
        #expect(try await scanner.send(request).body.count == page)
        await #expect(throws: DeviceNetworkError.self) { try await scanner.send(HttpRequest("GET", try scanner.http("/eSCL/ScannerStatus"))) }
    }

    @Test func A_scanner_can_send_a_page_longer_than_a_document() async throws {
        let page = DeviceHttp.maxReplyBytes + 1000
        let m234dw = Printers.folder("m234dw", scanPage: { [UInt8](repeating: 0x30, count: page) })
        let scanner = CdmConnectionTests.Scripted { request in
            let reply = try await m234dw.send(request)
            try Bounded.keep(reply.body.count, request, Mutex(0))
            return reply
        }
        let http = DeviceHttp(host: Self.host, transport: scanner)
        var pages: [[UInt8]] = []
        for try await jpeg in EsclClient(http, root: try http.http("/eSCL/")).scan(ScanRequest(source: .platen)) { pages.append(jpeg) }
        #expect(pages.count == 1)
        #expect(pages.first?.count == page)
    }
}
