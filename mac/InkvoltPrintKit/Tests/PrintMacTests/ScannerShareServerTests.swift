import Darwin
import Foundation
import PrintCore
@testable import PrintMac
import Security
import Testing
import TestTiming

/// Ported from ScannerSharingTests.cs' "over HTTPS on loopback, with our own eSCL client" (roadmap 3.1): the shared scanner
/// through Network framework's TLS server (`NetworkShareHost`) and our eSCL client over URLSession, page for page the
/// same as the direct scan; the certificate the card's fingerprint names; a device that may not connect gets no TLS; the
/// port closes at once; a device's connections are bounded; the switch with the real server. The certificate lives in a
/// keychain file of the test's own (`KeychainFile`), never the login keychain. The scanner is a fake ImageCaptureCore one.
@Suite(.serialized) struct ScannerShareServerTests {
    static let identity = ShareIdentity("Example Scan 300", "Example", UUID(uuidString: "0f6b3d2a-7c1e-4c55-9a51-2b8e44d1c0aa")!)
    static let usb = SystemScanner(id: "0x00110000046d0a00", name: "Example Scan 300", usb: true)

    static var caps: ScannerCapabilities {
        let glass = InputCaps(minWidth: 300, maxWidth: 2550, minHeight: 300, maxHeight: 3507, colorModes: ["RGB24", "Grayscale8"],
                              resolutions: [75, 100, 150, 200, 300, 400, 600, 1200])
        var feeder = glass
        feeder.maxHeight = 4200
        return ScannerCapabilities(makeAndModel: "Example Scan 300", platen: glass, adf: feeder, adfDuplex: true)
    }

    /// The glass gives one page, the feeder three; each a JPEG header and what was asked of the driver.
    final class FakeScanner: ScanDevice, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var transfers: [String] {
            get { lock.withLock { asked } }
            set { lock.withLock { asked = newValue } }
        }

        func capabilities() async throws -> ScannerCapabilities? { ScannerShareServerTests.caps }

        func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
            AsyncThrowingStream { continuation in
                let side = ScannerShareServerTests.caps.input(for: request.source)
                let dpi = side.map { EsclXml.resolution(request, $0) } ?? request.resolution
                let area = ScanArea.of(request, sourceWidth: Double(side?.maxWidth ?? 0) / 300, sourceHeight: Double(side?.maxHeight ?? 0) / 300)
                for n in 0..<(request.source == .platen ? 1 : 3) {
                    let line = "\(request.source) \(request.color) \(dpi) \(area.width) \(area.height)|\(n)"
                    lock.withLock { asked.append(line) }
                    continuation.yield([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]
                                       + Array(line.utf8) + [0xFF, 0xD9])
                }
                continuation.finish()
            }
        }
    }

    /// What our client's TLS saw: the leaf certificate's SHA-256, as a pin is told it.
    final class SeenPin: CertificatePin, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: String?
        var thumb: String? { lock.withLock { seen } }
        func get(_ port: Int) -> String? { nil }
        func setIfAbsent(_ port: Int, _ sha256Hex: String) -> String {
            lock.withLock {
                if seen == nil { seen = sha256Hex }
                return seen!
            }
        }
    }

    static func serve(_ scanner: ConnectedScanner, _ kc: KeychainFile, allow: (@Sendable (String, String?) -> Bool)? = nil) async throws
        -> (any PhoneListener, SharedScanner, any PhoneCertificate) {
        let certificate = try PhoneCertificateKeychain(keychain: kc.keychain).get(hostName: "localhost", now: Date())
        let server = SharedScanner(scanner, caps, identity, busyElsewhere: { scanner.isBusy })
        let listen = ShareListen(loopbackOnly: true, port: 0, certificate: certificate,
                                 allowPeer: allow ?? { peer, local in SharePeers.isLoopback(peer) && (local.map(SharePeers.isLoopback) ?? true) }, scanner: server)
        let listener = try await NetworkShareHost().start(listen)
        return (listener, server, certificate)
    }

    static func client(_ port: Int, pin: SeenPin? = nil) -> EsclClient {
        EsclClient(DeviceHttp(host: "127.0.0.1", transport: URLSessionTransport.factory(localNetwork: nil), pin: pin),
                   root: URL(string: "https://127.0.0.1:\(port)/eSCL/")!)
    }

    static func all(_ pages: AsyncThrowingStream<[UInt8], any Error>) async throws -> [[UInt8]] {
        var list: [[UInt8]] = []
        for try await p in pages { list.append(p) }
        return list
    }

    @Test func ourClientScansThroughTheSharedEndpointIdenticalToTheDirectScan() async throws {
        let kc = try KeychainFile()
        defer { kc.delete() }
        let fake = FakeScanner()
        let scanner = ConnectedScanner(Self.usb, device: fake)
        let (listener, server, certificate) = try await Self.serve(scanner, kc)
        defer { server.close() }
        let pin = SeenPin()
        let client = Self.client(try #require(listener.port), pin: pin)
        let caps = try #require(try await client.capabilities())
        #expect(caps.sources == Self.caps.sources)
        #expect(caps.platen?.resolutions == Self.caps.platen?.resolutions)
        #expect(caps.adf?.colorModes == Self.caps.adf?.colorModes)
        // The certificate the card's fingerprint names.
        #expect(pin.thumb?.uppercased() == certificate.fingerprint.replacingOccurrences(of: ":", with: ""))
        for request in [ScanRequest(source: .platen, color: .color, resolution: 300), ScanRequest(source: .adf, color: .grayscale, resolution: 200),
                        ScanRequest(source: .adfDuplex, color: .grayscale, resolution: 600),
                        ScanRequest(source: .platen, color: .color, resolution: 150, width: 1275, height: 1650)] {
            fake.transfers = []
            let mine = try await Self.all(scanner.scan(request))
            let asDriver = fake.transfers
            fake.transfers = []
            let theirs = try await Self.all(client.scan(request))
            #expect(mine.count >= 1)
            #expect(mine == theirs)
            #expect(asDriver == fake.transfers) // the driver was asked the same, page for page
        }
        await listener.close()
    }

    @Test func aDeviceThatMayNotConnectGetsNothingNotEvenTls() async throws {
        let kc = try KeychainFile()
        defer { kc.delete() }
        let (listener, server, _) = try await Self.serve(ConnectedScanner(Self.usb, device: FakeScanner()), kc, allow: { _, _ in false })
        defer { server.close() }
        let pin = SeenPin()
        await #expect(throws: (any Error).self) { _ = try await Self.client(try #require(listener.port), pin: pin).capabilities() }
        #expect(pin.thumb == nil) // no handshake at all
        await listener.close()
    }

    @Test func closedThePortRefusesConnectionsAtOnce() async throws {
        let kc = try KeychainFile()
        defer { kc.delete() }
        let (listener, server, _) = try await Self.serve(ConnectedScanner(Self.usb, device: FakeScanner()), kc)
        let port = try #require(listener.port)
        _ = try await Self.client(port).status()
        server.close()
        let clock = ContinuousClock(), began = clock.now
        await listener.close()
        #expect(clock.now - began < Timing.limit(.seconds(3)))
        #expect(!Self.connects(port))
    }

    @Test func tooManyConnectionsFromOneDeviceAreClosed() async throws {
        let kc = try KeychainFile()
        defer { kc.delete() }
        let (listener, server, _) = try await Self.serve(ConnectedScanner(Self.usb, device: FakeScanner()), kc)
        defer { server.close() }
        let port = try #require(listener.port)
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<NetworkShareHost.maxConnectionsPerPeer {
            let fd = Self.open(port)
            #expect(fd >= 0)
            held.append(fd)
        }
        try await Task.sleep(for: .milliseconds(300))
        let extra = Self.open(port)
        #expect(extra >= 0)
        defer { close(extra) }
        // Closed by the server without a byte (no TLS answer to our hello either).
        let hello: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0x05, 1, 0, 0, 1, 0]
        _ = hello.withUnsafeBytes { write(extra, $0.baseAddress, $0.count) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(extra, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = buffer.withUnsafeMutableBytes { read(extra, $0.baseAddress, $0.count) }
        #expect(n <= 0) // closed (0) or reset (-1)
        await listener.close()
    }

    @Test func theSwitchWithTheRealServerOnLoopbackScansAndCloses() async throws {
        let kc = try KeychainFile()
        defer { kc.delete() }
        let fake = FakeScanner()
        let scanner = ConnectedScanner(Self.usb, device: fake)
        let share = ScannerShare(.thisMacOnly(NetworkShareHost(), certificates: PhoneCertificateKeychain(keychain: kc.keychain)), computerName: "OFFICE-MAC",
                                 choice: nil, save: { _ in })
        await share.share(scanner)
        #expect(share.state == .on)
        let port = try #require(share.port)
        let request = ScanRequest(source: .adf, color: .color, resolution: 300)
        let mine = try await Self.all(scanner.scan(request))
        #expect(try await Self.all(Self.client(port).scan(request)) == mine)
        #expect(share.text(Self.usb.id) == "Demo: shared as \"Example Scan 300\" on port \(port), for this Mac only.")
        await share.stop()
        #expect(!Self.connects(port))
        await share.close()
    }

    @Test func theAnnouncementsTxtRecordIsEachKeyAfterItsLength() {
        let record = BonjourShareAdvertiser.txtRecord([("rs", "eSCL"), ("ty", String(repeating: "x", count: 300))])
        #expect(Array(record.prefix(8)) == [7] + Array("rs=eSCL".utf8))
        #expect(record[8] == 255 && record.count == 8 + 1 + 255)
        #expect(BonjourShareAdvertiser.txtRecord([]) == [0])
    }

    /// A TCP connection to 127.0.0.1:`port`, or -1.
    static func open(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    static func connects(_ port: Int) -> Bool {
        let fd = open(port)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }
}
