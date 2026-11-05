import Foundation
import Network
import PrintCore
import Synchronization
import Testing
@testable import PrintMac

/// `record` over this Mac's own sockets (roadmap 1.2): PrintMac's URLSession transport and SNMP over UDP, against the
/// M234dw's fixtures served on a loopback port and a made-up SNMP agent. No printer. Also RecordingTests.cs'
/// A_printer_that_never_stops_answering_doesnt_fill_this_pcs_memory, which PrintCore's port left to the transport.
@Suite(.serialized)
struct RecordingTransportTests {
    private static let me = Diagnostics.Identity("jdoe", "JDOE-LAPTOP")

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-mac-record-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func recordingOverThisMacsSocketsKeepsWhatTheFixturesAnswerAndSendsOnlyReads() async throws {
        let m234dw = try Self.fixtures("m234dw")
        let server = try HttpServer { request in
            let path = String(request.path.split(separator: "?", maxSplits: 1).first ?? "")
            let file = m234dw.appendingPathComponent(FixtureTransport.documentName(path))
            guard request.method == "GET", let text = try? String(contentsOf: file, encoding: .utf8) else {
                return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            }
            return "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: \(text.utf8.count)\r\n\r\n" + text
        }
        defer { server.stop() }
        let walk = String(decoding: try TransportTests.fixture("snmp-demo/workgroup-laser.txt"), as: UTF8.self)
        let agent = SnmpAgent(try SnmpAgent.parseWalk(walk))
        let udp = try UdpServer { agent.respond($0) }
        defer { udp.stop() }

        let http = OnPort(URLSessionTransport(check: CertificateCheck(pin: nil), replyLimit: PrinterRecorder.maxReplyBytes), port: server.port)
        var options = RecordOptions(transport: http, snmp: PortSnmp(port: udp.port))
        options.who = Self.me
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await PrinterRecorder.record("127.0.0.1", to: dir, options)

        #expect(result.model == "HP LaserJet MFP M234dw")
        #expect(result.interfaces.contains("LEDM") && result.interfaces.contains("SNMP"))
        for name in ["DevMgmt_ProductStatusDyn.xml", "DevMgmt_ConsumableConfigDyn.xml", PrinterRecorder.snmpFile, PrinterRecorder.notesFile] {
            #expect(result.files.contains(name), "\(name)")
        }
        // Read only: nothing but GETs (and IPP's Get-Printer-Attributes, a POST no fixture answers here) reached the socket.
        #expect(server.requests.allSatisfy { $0.method == "GET" || ($0.method == "POST" && $0.path.hasPrefix("/ipp")) }, "\(server.requests.map(\.method))")
        // Served again from the folder, it is the same printer.
        let recorded = FixtureTransport(document: { FileManager.default.contents(atPath: dir.appendingPathComponent($0).path).map { Array($0) } })
        let replay = try await PrinterConnection.open(FixtureTransport.demoHost, transport: recorded)
        #expect(replay.probe.model == "HP LaserJet MFP M234dw")
        let fixtures = FixtureTransport(document: { FileManager.default.contents(atPath: m234dw.appendingPathComponent($0).path).map { Array($0) } })
        let original = try await PrinterConnection.open(FixtureTransport.demoHost, transport: fixtures)
        #expect(try await replay.read() == original.read())
    }

    @Test func aPrinterThatNeverStopsAnsweringDoesntFillThisPcsMemory() async throws {
        let server = try EndlessServer()
        defer { server.stop() }
        let limit = 2 << 20 // the bound is the transport's; a small one keeps the test quick
        let http = OnPort(URLSessionTransport(check: CertificateCheck(pin: nil), replyLimit: limit), port: server.port)
        var options = RecordOptions(transport: http)
        options.who = Self.me
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) { try await PrinterRecorder.record("127.0.0.1", to: dir, options) }
        // What was sent before the reply was given up on: the limit and what the sockets buffer, far from its 300 MB.
        #expect(server.mostSent > 0)
        #expect(server.mostSent <= limit + (24 << 20), "sent \(server.mostSent) bytes")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    static func fixtures(_ name: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("print").path) { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("print/tests/InkvoltPrint.Tests/Fixtures").appendingPathComponent(name, isDirectory: true)
    }
}

/// A printer's every port on one loopback port: the recorder asks the printer's usual ports (80, 631, 8080…) by its address.
struct OnPort: HttpTransport {
    let inner: any HttpTransport
    let port: UInt16

    init(_ inner: any HttpTransport, port: UInt16) {
        self.inner = inner
        self.port = port
    }

    func send(_ request: HttpRequest) async throws -> HttpResponse {
        guard request.url.scheme == "http", var c = URLComponents(url: request.url, resolvingAgainstBaseURL: true) else { throw DeviceNetworkError.refused }
        c.port = Int(port)
        var r = request
        r.url = c.url ?? request.url
        return try await inner.send(r)
    }
}

/// An HTTP server on a loopback port whose every reply is 200 with a body that never ends (zeros, up to 300 MB), counting
/// what it sent on each connection.
final class EndlessServer: Sendable {
    final class Counts: Sendable {
        private let list = Mutex<[Int]>([])
        func open() -> Int { list.withLock { $0.append(0); return $0.count - 1 } }
        func set(_ i: Int, _ n: Int) { list.withLock { $0[i] = n } }
        var most: Int { list.withLock { $0.max() ?? 0 } }
    }

    private let listener: NWListener
    private let counts: Counts
    let port: UInt16

    /// The most sent on one connection.
    var mostSent: Int { counts.most }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let counts = Counts()
        self.counts = counts
        let queue = UdpServer.ownQueue()
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            let index = counts.open()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let chunk = Data(count: 1 << 20)
                @Sendable func more(_ total: Int) {
                    guard total < 300 << 20 else { return connection.cancel() }
                    connection.send(content: chunk, completion: .contentProcessed { error in
                        guard error == nil else { return connection.cancel() }
                        counts.set(index, total + chunk.count)
                        more(total + chunk.count)
                    })
                }
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\n\r\n".utf8), completion: .contentProcessed { _ in more(0) })
            }
        }
        self.listener = listener
        port = try UdpServer.listen(listener, on: queue)
    }

    func stop() { listener.cancel() }
}
