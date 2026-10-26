import Foundation
import Network
import PrintCore
import Synchronization
import Testing
@testable import PrintMac

/// PrintMac's transports against servers on this Mac's loopback: a made-up SNMP agent on a UDP port and a small HTTP
/// server. Loopback needs no Local Network permission (and tests aren't sandboxed).
@Suite(.serialized)
struct TransportTests {
    // MARK: SNMP

    @Test func snmpGetsTheAgentsReplyOverUdp() async throws {
        let agent = SnmpAgent(try SnmpAgent.parseWalk(String(decoding: try Self.fixture("snmp-demo/workgroup-laser.txt"), as: UTF8.self)))
        let server = try UdpServer { agent.respond($0) }
        defer { server.stop() }
        let transport = PortSnmp(port: server.port)
        let identity = try await SnmpPrinterClient.probe(transport: transport, host: "127.0.0.1")?.identity
        #expect(identity?.serialNumber == "DEMO0005200")
    }

    @Test func snmpWithNoAgentGivesNoReplyWithinItsTimeout() async throws {
        let started = ContinuousClock.now
        let reply = try await PortSnmp(port: 9).send([0x30, 0x00], to: "127.0.0.1", timeout: .milliseconds(300))
        #expect(reply == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func snmpStopsWaitingWhenCancelled() async throws {
        let server = try UdpServer { _ in nil } // never answers
        defer { server.stop() }
        let started = ContinuousClock.now
        let task = Task { try await PortSnmp(port: server.port).send([0x30, 0x00], to: "127.0.0.1", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    // MARK: HTTP

    @Test func httpSendsTheHeadersAsGivenAndReturnsRedirectsUnfollowed() async throws {
        let server = try HttpServer { request in
            request.path == "/old" ? "HTTP/1.1 302 Found\r\nLocation: /new\r\nContent-Length: 0\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: 5\r\n\r\nhello"
        }
        defer { server.stop() }
        let http = URLSessionTransport(check: CertificateCheck(pin: nil))
        let base = "http://127.0.0.1:\(server.port)"

        let ok = try await http.send(HttpRequest("GET", URL(string: "\(base)/DevMgmt/x.xml")!, headers: ["Authorization": "Basic YWRtaW46eA=="]))
        #expect(ok.status == 200)
        #expect(ok.text == "hello")
        #expect(ok.header("content-type") == "text/xml")
        // The EWS password goes out as a header (URLSession lists Authorization among the headers it may manage).
        #expect(server.requests.last?.headers["authorization"] == "Basic YWRtaW46eA==")

        let moved = try await http.send(HttpRequest("GET", URL(string: "\(base)/old")!))
        #expect(moved.status == 302)
        #expect(moved.header("Location") == "/new")
        #expect(server.requests.count == 2)

        let once = try await http.send(HttpRequest("POST", URL(string: "\(base)/once")!, body: Array("x".utf8), once: true))
        #expect(once.status == 200)
        #expect(server.requests.last?.body == "x")
    }

    @Test func aPortNothingListensOnIsRefused() async throws {
        let http = URLSessionTransport(check: CertificateCheck(pin: nil))
        await #expect(throws: DeviceNetworkError.refused) { try await http.send(HttpRequest("GET", URL(string: "http://127.0.0.1:9/")!)) }
    }

    @Test func aSilentServerTimesOutThroughDeviceHttp() async throws {
        let server = try HttpServer { _ in nil } // accepts, never answers
        defer { server.stop() }
        let device = DeviceHttp(host: "127.0.0.1:\(server.port)", transport: URLSessionTransport.factory(localNetwork: nil))
        await #expect(throws: DeviceNetworkError.timedOut) {
            try await device.send(HttpRequest("GET", URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: .milliseconds(300)))
        }
    }

    @Test func anAnswerFromTheNetworkCountsAsLocalNetworkAllowed() async throws {
        let server = try HttpServer { _ in "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" }
        defer { server.stop() }
        let signal = LocalNetworkSignal()
        let http = URLSessionTransport(check: CertificateCheck(pin: nil), localNetwork: signal)
        #expect(try await http.send(HttpRequest("GET", URL(string: "http://127.0.0.1:\(server.port)/")!)).status == 404)
        #expect(signal.access == .allowed)
    }

    // MARK: Helpers

    @Test func theHostHeaderNamesThePortAsEpsonScannersWantIt() async throws {
        // The Epson eSCL quirk sends "Host: host:port". URLSession lists Host among the headers it manages: this says what goes out.
        let server = try HttpServer { _ in "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" }
        defer { server.stop() }
        let http = URLSessionTransport(check: CertificateCheck(pin: nil))
        let url = URL(string: "http://127.0.0.1:\(server.port)/eSCL/ScannerStatus")!
        // A value of our own, not the URL's: it goes out as given, so the port can be named even when it's the default one.
        _ = try await http.send(HttpRequest("GET", url, headers: ["Host": "printer.test:80"]))
        #expect(server.requests.last?.headers["host"] == "printer.test:80")
    }

    // MARK: Search my network

    @Test func theScannerFindsAListeningPortAndNotAClosedOne() async throws {
        let server = try HttpServer { _ in "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" }
        defer { server.stop() }
        let scanner = SocketNetworkScanner()
        #expect(try await scanner.isOpen("127.0.0.1", port: Int(server.port), timeout: .seconds(2)))
        let started = ContinuousClock.now
        #expect(try await !scanner.isOpen("127.0.0.1", port: 9, timeout: .milliseconds(600)))
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func theScannerSearchesNoLoopbackOrTunnel() {
        for net in SocketNetworkScanner().localNetworks() {
            #expect(!net.address.hasPrefix("127."))
            #expect((1...32).contains(net.prefixLength))
        }
    }

    // MARK: CUPS

    @Test func libcupsListsThisMacsQueues() async throws {
        // Tests aren't sandboxed, so cupsd answers whether or not the Mac has a queue; each one comes with its options.
        let list = try #require(await LibCups().destinations())
        for d in list { #expect(!d.name.isEmpty) }
    }

    static func fixture(_ path: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintMacTests/TransportTests.swift
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent("print/tests/InkvoltPrint.Tests/Fixtures").appendingPathComponent(path))
    }
}

/// `UdpSnmpTransport`'s exchange on another port than 161 (a test agent can't bind a privileged port).
struct PortSnmp: SnmpTransport {
    let port: UInt16

    func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
        let stop = StopFlag()
        let port = port
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<UdpSnmpTransport.Exchange, Never>) in
                DispatchQueue.global().async { done.resume(returning: UdpSnmpTransport.exchange(request, host: host, port: port, timeout: timeout, stop: stop)) }
            }
        } onCancel: {
            stop.set()
        }
        try Task.checkCancellation()
        if case .reply(let bytes) = result { return bytes }
        return nil
    }
}

/// A UDP server on a loopback port: each datagram is answered with what `answer` returns (nil: silence).
final class UdpServer: Sendable {
    private let listener: NWListener
    let port: UInt16

    init(_ answer: @escaping @Sendable ([UInt8]) -> [UInt8]?) throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            @Sendable func next() {
                connection.receiveMessage { data, _, _, error in
                    guard error == nil else { return }
                    if let data, let reply = answer(Array(data)) { connection.send(content: Data(reply), completion: .idempotent) }
                    next()
                }
            }
            next()
        }
        self.listener = listener
        port = try Self.listen(listener)
    }

    func stop() { listener.cancel() }

    static func listen(_ listener: NWListener) throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue, port != 0 else { throw URLError(.cannotConnectToHost) }
        return port
    }
}

/// A minimal HTTP/1.1 server on a loopback port: one request per connection; `answer` gives the whole raw response (nil:
/// accept and never answer).
final class HttpServer: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Names in lower case.
        var headers: [String: String]
        var body: String
    }

    final class Log: Sendable {
        private let list = Mutex<[Request]>([])
        var all: [Request] { list.withLock { $0 } }
        func add(_ r: Request) { list.withLock { $0.append(r) } }
    }

    private let listener: NWListener
    private let log: Log
    let port: UInt16

    var requests: [Request] { log.all }

    init(_ answer: @escaping @Sendable (Request) -> String?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let log = Log()
        self.log = log
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.read(connection, Data()) { request in
                log.add(request)
                if let response = answer(request) {
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        self.listener = listener
        port = try UdpServer.listen(listener)
    }

    func stop() { listener.cancel() }

    private static func read(_ connection: NWConnection, _ buffer: Data, _ done: @escaping @Sendable (Request) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) {
                done(request)
            } else if !complete && error == nil {
                read(connection, buffer, done)
            }
        }
    }

    private static func parse(_ data: Data) -> Request? {
        let text = String(decoding: data, as: UTF8.self)
        guard let end = text.range(of: "\r\n\r\n") else { return nil }
        let lines = text[..<end.lowerBound].components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = String(text[end.upperBound...])
        if let length = headers["content-length"].flatMap(Int.init), body.utf8.count < length { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }
}
