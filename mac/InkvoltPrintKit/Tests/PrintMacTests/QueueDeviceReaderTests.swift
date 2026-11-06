import Foundation
import PrintCore
import Testing
import dnssd
@testable import PrintMac

/// Route 1's reader on this Mac (roadmap 3.6): an `ippusb://` queue names a Bonjour service, which is resolved (here a
/// local-only one, as a relay on this Mac would register) and its printer asked over loopback HTTP. Loopback needs no Local
/// Network permission; ignia-mac also proved the sandboxed app reaches such a relay (research file, 3.6).
@Suite(.serialized)
struct QueueDeviceReaderTests {
    /// A reply whose every byte is ASCII, so the test server's text body carries it unchanged.
    static let reply = """
        printer-state enum 3
        printer-state-reasons keyword toner-low
        marker-names name Black Toner
        marker-types keyword toner
        marker-colors name #000000
        marker-levels integer 9
        marker-low-levels integer 15
        marker-high-levels integer 100
        """

    @Test func anIppUsbQueuesServiceIsResolvedAndItsPrinterAsked() async throws {
        let bytes = IppCodec.encodeResponse(status: 0, requestId: 1, try IppText.parse(Self.reply))
        #expect(bytes.allSatisfy { $0 < 0x80 })
        let body = String(decoding: bytes, as: UTF8.self)
        let server = try HttpServer { _ in
            "HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n" + body
        }
        defer { server.stop() }
        let instance = "Inkvolt test relay \(UInt32.random(in: 0...UInt32.max))"
        let registration = try Self.register(instance, port: server.port, rp: "ipp/print")
        defer { DNSServiceRefDeallocate(registration) }
        let queue = CupsDestination(name: "Q", options: [
            "device-uri": "ippusb://\(instance.replacingOccurrences(of: " ", with: "%20"))._ipp._tcp.local./", "printer-type": "4", "printer-state": "3",
        ])

        let readers = QueueDeviceReaders.readers(for: queue, transport: URLSessionTransport.factory(localNetwork: nil))
        #expect(readers.count == 1)
        let reading = try #require(try await readers[0].read())

        #expect(reading.from == .printerOverUsb)
        #expect(reading.supplies.map(\.percentRemaining) == [9])
        #expect(server.requests.map(\.path) == ["/ipp/print"])
        #expect(server.requests.first?.method == "POST")
    }

    @Test func aServiceNobodyAnnouncesIsNothingWithinItsTimeout() async {
        let started = ContinuousClock.now
        let found = await ServiceResolve.once(instance: "Inkvolt nobody \(UInt32.random(in: 0...UInt32.max))", type: "_ipp._tcp", domain: "local.")
        #expect(found == nil)
        // CI's runner, busy with the whole run, took 3.4 s once against 3 s: there the bound gets the slack ConnectionTests gives.
        let slack: Duration = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil ? .seconds(5) : .seconds(1)
        #expect(ContinuousClock.now - started < IppQueueReading.resolveLimit + slack) // the request's time left in the call
    }

    @Test func aQueueWithNothingToAskHasNoReader() {
        for uri in ["usb://Demo/Laser?serial=1", "socket://192.0.2.15", "ippusb://Demo%20Laser/ipp/print"] {
            let d = CupsDestination(name: "Q", options: ["device-uri": uri, "printer-type": "4", "printer-state": "3"])
            #expect(QueueDeviceReaders.readers(for: d, transport: URLSessionTransport.factory(localNetwork: nil)).isEmpty)
        }
    }

    /// A local-only `_ipp._tcp` registration on this Mac, pointing at `port` on localhost.
    private static func register(_ instance: String, port: UInt16, rp: String) throws -> DNSServiceRef {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        _ = TXTRecordSetValue(&txt, "rp", UInt8(rp.utf8.count), rp)
        var ref: DNSServiceRef?
        let localOnly = UInt32.max // kDNSServiceInterfaceIndexLocalOnly, ((uint32_t)-1)
        let error = DNSServiceRegister(&ref, 0, localOnly, instance, "_ipp._tcp", "local.", "localhost.",
                                       port.bigEndian, TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), nil, nil)
        guard Int(error) == Int(kDNSServiceErr_NoError), let ref else { throw RegisterError(code: Int(error)) }
        return ref
    }

    struct RegisterError: Error { var code: Int }
}
