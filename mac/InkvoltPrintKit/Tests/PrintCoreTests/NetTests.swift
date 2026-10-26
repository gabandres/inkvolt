import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Device HTTP rules that don't need a TLS handshake (pins per port, credentials only to the web server), printer ids and
/// the digests. Ported from CertificatePinTests.cs and RobustnessTests.cs; the loopback TLS tests belong to PrintMac.
struct NetTests {
    private final class MemoryPins: CertificatePin {
        private let pins = Mutex<[Int: String]>([:])
        func get(_ port: Int) -> String? { pins.withLock { $0[port] } }
        func setIfAbsent(_ port: Int, _ sha256Hex: String) -> String {
            pins.withLock { p in
                if let known = p[port] { return known }
                p[port] = sha256Hex
                return sha256Hex
            }
        }
    }

    @Test func certificateIsPinnedOnFirstUseAndADifferentOneIsRefused() {
        let pins = MemoryPins()
        let check = CertificateCheck(pin: pins)
        #expect(check.accept(sha256Hex: "AA11", port: 443))
        #expect(pins.get(443) == "AA11")
        #expect(check.accept(sha256Hex: "aa11", port: 443))
        #expect(!check.certificateChanged)
        #expect(!check.accept(sha256Hex: "BB22", port: 443))
        #expect(check.certificateChanged)
    }

    @Test func eachPortKeepsItsOwnPin() {
        let pins = MemoryPins()
        let check = CertificateCheck(pin: pins)
        #expect(check.accept(sha256Hex: "AA11", port: 443))
        #expect(check.accept(sha256Hex: "BB22", port: 631)) // a different certificate, another port: fine
        #expect(check.accept(sha256Hex: "AA11", port: 443))
        #expect(!check.certificateChanged)
        #expect(pins.get(631) == "BB22")
    }

    @Test func racingFirstHandshakesAreBothCheckedAgainstThePinThatWon() {
        let pins = MemoryPins()
        let check = CertificateCheck(pin: pins)
        _ = pins.setIfAbsent(443, "AA11") // the other handshake stored first
        #expect(!check.accept(sha256Hex: "BB22", port: 443))
        #expect(check.accept(sha256Hex: "AA11", port: 443))
    }

    @Test func pinsStoredBeforePortsWereToldApartStayTheWebServers() {
        let id = "12345678-1234-4abc-8def-123456789abc"
        #expect(CertificatePinKey.key(id, port: 443) == id)
        #expect(CertificatePinKey.key(id, port: 631) == id + ":631")
        #expect(CertificatePinKey.belongs(id, to: id))
        #expect(CertificatePinKey.belongs(id + ":631", to: id))
        #expect(!CertificatePinKey.belongs("12345678-1234-4abc-8def-123456789abd:631", to: id))
    }

    @Test func theAdminPasswordGoesOnlyToTheWebServerPort() async throws {
        let sent = Mutex<[String: Bool]>([:])
        let echo = CdmConnectionTests.Scripted { request in
            sent.withLock { $0[request.url.absoluteString] = request.header("Authorization") != nil }
            return HttpResponse(status: 200)
        }
        let http = DeviceHttp(host: "192.0.2.11", transport: echo)
        http.setCredentials(user: "admin", password: "secret")
        for url in ["https://192.0.2.11/DevMgmt/x.xml", "https://192.0.2.11:631/ipp/print", "http://192.0.2.11/DevMgmt/x.xml"] {
            _ = try await http.get(URL(string: url)!)
        }
        let result = sent.withLock { $0 }
        #expect(result["https://192.0.2.11/DevMgmt/x.xml"] == true)
        #expect(result["https://192.0.2.11:631/ipp/print"] == false)
        #expect(result["http://192.0.2.11/DevMgmt/x.xml"] == false)
    }

    @Test func aRequestThatTakesLongerThanItsTimeoutTimesOut() async throws {
        let http = DeviceHttp(host: "192.0.2.11", transport: Network(Printers.none(), failNow: true) { _ in Network.hang() })
        await #expect(throws: DeviceNetworkError.timedOut) {
            try await http.send(HttpRequest("GET", http.http("/"), timeout: .milliseconds(100)))
        }
    }

    // MARK: Printer ids

    @Test(arguments: ["12345678-1234-4abc-8def-123456789abc", "urn:uuid:12345678-1234-4ABC-8DEF-123456789ABC",
                      "{12345678-1234-4abc-8def-123456789abc}"])
    func printerIdsAreNormalisedGuids(_ raw: String) {
        #expect(PrinterId.normalize(raw, host: "10.0.0.5") == "12345678-1234-4abc-8def-123456789abc")
    }

    @Test(arguments: [#"..\..\evil"#, #"C:\Windows\x"#, nil] as [String?])
    func untrustedIdsBecomeAStableGuidFromTheHost(_ raw: String?) {
        let id = PrinterId.normalize(raw, host: "10.0.0.5")
        #expect(PrinterId.isValid(id))
        #expect(PrinterId.normalize(raw, host: "10.0.0.5") == id)
        #expect(!PrinterId.fileName(id).contains("\\"))
        #expect(!PrinterId.fileName(#"..\..\evil"#).contains("."))
    }

    @Test func theHostIdIsTheWindowsApps() {
        // MD5("printdesk-host:10.0.0.5") read as .NET's Guid: the first three fields little-endian.
        let hash = Digest.md5(Array("printdesk-host:10.0.0.5".utf8))
        let id = PrinterId.normalize(nil, host: " 10.0.0.5 ")
        #expect(id.replacingOccurrences(of: "-", with: "").hasSuffix(Digest.hex(Array(hash[8...]))))
        #expect(id.prefix(8) == Digest.hex(Array(hash[0..<4].reversed())))
    }

    private static let known = "12345678-1234-4abc-8def-123456789abc", other = "87654321-4321-4cba-8fed-cba987654321"

    @Test func sameDeviceWhenAnyInterfaceReportsItsUuid() {
        #expect(PrinterId.identify(Self.known, host: "192.0.2.10", reported: [nil, nil, Self.other, "urn:uuid:12345678-1234-4ABC-8DEF-123456789ABC"]) == .same)
    }

    @Test func differentDeviceWhenItReportsOnlyOtherUuids() {
        #expect(PrinterId.identify(Self.known, host: "192.0.2.10", reported: [Self.other, nil, "", Self.other]) == .different)
    }

    @Test func unknownWhenTheDeviceReportsNoUsableUuid() {
        #expect(PrinterId.identify(Self.known, host: "192.0.2.10", reported: [nil, " ", "not-a-uuid"]) == .unknown)
    }

    @Test func unknownForAPrinterRememberedByItsAddress() {
        let byAddress = PrinterId.normalize(nil, host: "192.0.2.10")
        #expect(PrinterId.identify(byAddress, host: "192.0.2.10", reported: [Self.other]) == .unknown)
    }

    @Test func aUuidTheUserAcceptedCountsAsThePrinter() {
        #expect(PrinterId.identify(Self.known, accepted: [Self.other], host: "192.0.2.10", reported: ["urn:uuid:" + Self.other.uppercased()]) == .same)
        #expect(PrinterId.identify(Self.known, accepted: [], host: "192.0.2.10", reported: [Self.other]) == .different)
    }

    @Test(arguments: [
        // The announced address answers with the printer's UUID: move; as another device: never.
        (DeviceIdentity.same, true, "HP LaserJet MFP M234dw", "HP LaserJet MFP M234dw", true),
        (.different, false, nil, "HP LaserJet MFP M234dw", false),
        // Can't tell there (no answer, or no UUID): a typed address still answering as this kind of printer is kept...
        (.unknown, true, "HP LaserJet MFP M234dw", "HP LaserJet MFP M234dw", false),
        (.unknown, true, "HP LaserJet MFP M234dw", nil, false),
        // ...otherwise the printer moves, as discovery always did.
        (.unknown, false, nil, "HP LaserJet MFP M234dw", true),
        (.unknown, true, "Example Inkjet 300", "HP LaserJet MFP M234dw", true),
    ] as [(DeviceIdentity, Bool, String?, String?, Bool)])
    func movingToAnAnnouncedAddress(_ atNew: DeviceIdentity, _ currentAnswers: Bool, _ currentModel: String?, _ announced: String?, _ move: Bool) {
        #expect(PrinterId.shouldMove(atNew, currentAnswers: currentAnswers, currentModel: currentModel, announcedModel: announced) == move)
    }

    @Test(arguments: [
        ("HP LaserJet MFP M234dw", "hp laserjet mfp m234dw", true),
        ("HP LaserJet MFP M234dw", "LaserJet MFP M234dw", true),
        ("Example Inkjet 300", "HP LaserJet MFP M234dw", false),
        (nil, "HP LaserJet MFP M234dw", false),
        ("Anything", "", true),
    ] as [(String?, String?, Bool)])
    func sameKindOfDevice(_ model: String?, _ announced: String?, _ expected: Bool) {
        #expect(PrinterId.sameKind(model, announced) == expected)
    }

    // MARK: Digests (RFC 1321 and FIPS 180-4 test vectors)

    @Test func digestsMatchTheirStandardsTestVectors() {
        #expect(Digest.hex(Digest.md5([])) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(Digest.hex(Digest.md5(Array("abc".utf8))) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(Digest.hex(Digest.md5(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8)))
            == "57edf4a22be3c955ac49da2e2107b67a")
        #expect(Digest.hex(Digest.sha256(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Digest.hex(Digest.sha256(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}
