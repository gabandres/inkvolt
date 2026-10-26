import Foundation
import Synchronization
@testable import PrintCore

/// The fixture printers the .NET tests use, as transports.
enum Printers {
    /// One fixture folder.
    static func folder(_ name: String, scanPage: (@Sendable () -> [UInt8])? = nil) -> FixtureTransport {
        FixtureTransport(document: { try? Fixtures.data("\(name)/\($0)") }, scanPage: scanPage)
    }

    /// The demo inkjet (an Epson over IPP and eSCL) that scans a minimal JPEG.
    static func inkjet() -> FixtureTransport { folder("inkjet-demo", scanPage: { [0xFF, 0xD8, 0xFF, 0xD9] }) }

    /// An HP laser with LEDM (m234dw's documents) that answers IPP as well (the demo inkjet's attributes).
    static func ledmAndIpp() -> FixtureTransport {
        FixtureTransport(document: { name in
            (try? Fixtures.data("m234dw/\(name)")) ?? (name == "ipp_print.ipp.txt" ? try? Fixtures.data("inkjet-demo/\(name)") : nil)
        })
    }

    static func ippOnly() -> FixtureTransport {
        FixtureTransport(document: { $0 == "ipp_print.ipp.txt" ? try? Fixtures.data("inkjet-demo/\($0)") : nil })
    }

    /// Nothing answers over HTTP.
    static func none() -> HostRouter { HostRouter([:]) }
}

/// The fixtures behind a network that records each request and, once `fail` is set, answers the chosen ones itself
/// (an error status, a refusal, silence).
final class Network: HttpTransport {
    typealias Fault = @Sendable (HttpRequest) -> (@Sendable () async throws -> HttpResponse)?

    private let inner: any HttpTransport
    private let state: Mutex<(seen: [HttpRequest], fail: Bool, fault: Fault?)>

    init(_ inner: any HttpTransport, failNow: Bool = false, _ fault: Fault? = nil) {
        self.inner = inner
        state = Mutex(([], failNow, fault))
    }

    var seen: [HttpRequest] { state.withLock { $0.seen } }
    func clear() { state.withLock { $0.seen.removeAll() } }

    /// Faults apply from now on (set once the connection is open, so the probe sees a healthy printer).
    var fail: Bool {
        get { state.withLock { $0.fail } }
        set { state.withLock { $0.fail = newValue } }
    }

    var fault: Fault? {
        get { state.withLock { $0.fault } }
        set { state.withLock { $0.fault = newValue } }
    }

    static func status(_ code: Int) -> @Sendable () async throws -> HttpResponse { { HttpResponse(status: code) } }
    static func refuse() -> @Sendable () async throws -> HttpResponse { { throw DeviceNetworkError.refused } }
    static func hang() -> @Sendable () async throws -> HttpResponse {
        {
            try await Task.sleep(for: .seconds(3600))
            throw DeviceNetworkError.timedOut
        }
    }

    func send(_ request: HttpRequest) async throws -> HttpResponse {
        let (failing, fault) = state.withLock { s in
            s.seen.append(request)
            return (s.fail, s.fault)
        }
        if failing, let answer = fault?(request) { return try await answer() }
        return try await inner.send(request)
    }

    func count(_ predicate: (HttpRequest) -> Bool) -> Int { seen.filter(predicate).count }
}

extension HttpRequest {
    var isIpp: Bool { method == "POST" && url.path == "/ipp/print" }
    func `is`(_ document: String) -> Bool { url.path.hasSuffix(document) }
}

/// An SNMP agent that can be turned off (nil: no reply) or swapped for another.
final class SwitchableAgent: SnmpTransport {
    private let target: Mutex<(any SnmpTransport)?>

    init(_ to: (any SnmpTransport)?) { target = Mutex(to) }

    var to: (any SnmpTransport)? {
        get { target.withLock { $0 } }
        set { target.withLock { $0 = newValue } }
    }

    func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
        try await to?.send(request, to: host, timeout: timeout)
    }
}

func demoAgent(_ name: String, v1Only: Bool = false) throws -> SnmpAgent {
    SnmpAgent(try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/\(name)")), v1Only: v1Only)
}

/// A structurally valid JPEG skeleton (markers only, fake scan data).
enum TestJpeg {
    static func build(width: Int, height: Int, dnlHeight: Int?, components: UInt8 = 3) -> [UInt8] {
        var b: [UInt8] = [0xFF, 0xD8]
        b += [0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        let sofLength = 8 + 3 * Int(components)
        b += [0xFF, 0xC0, 0, UInt8(sofLength), 8, UInt8(height >> 8 & 0xFF), UInt8(height & 0xFF), UInt8(width >> 8 & 0xFF), UInt8(width & 0xFF), components]
        for c in 1...components { b += [c, 0x11, 0] }
        b += [0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 0x3F, 0]
        b += [0x12, 0x34, 0xFF, 0x00, 0x56] // entropy data with a stuffed FF
        if let d = dnlHeight { b += [0xFF, 0xDC, 0, 4, UInt8(d >> 8 & 0xFF), UInt8(d & 0xFF)] }
        b += [0xFF, 0xD9]
        return b
    }
}
