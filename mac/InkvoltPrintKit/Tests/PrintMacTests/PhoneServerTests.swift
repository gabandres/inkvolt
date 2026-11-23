import Darwin
import Foundation
import PrintCore
@testable import PrintMac
import Security
import Testing

/// Ported from PhoneScanTests.cs' "over HTTPS on loopback" (roadmap 4.6): a phone pairs, sends and finishes through
/// Network framework's TLS server, and the port closes after. The certificate lives in a keychain file the test makes in
/// a folder of its own (`KeychainFile`), never the login keychain and never on the search list, deleted after: nothing of
/// the account's user is read or changed.
@Suite(.serialized) struct PhoneServerTests {
    private static let now = Date()

    @Test func theCertificateIsMadeOnceInItsKeychainAndKeptForTheNextScan() throws {
        let kc = try KeychainFile()
        defer { kc.delete() }
        let certificates = PhoneCertificateKeychain(keychain: kc.keychain)
        let made = try #require(try certificates.get(hostName: "office-mac.local", now: Self.now) as? KeychainPhoneCertificate)
        #expect(made.fingerprint.count == 95) // 32 bytes as hex pairs and colons
        let again = try #require(try certificates.get(hostName: "office-mac.local", now: Self.now.addingTimeInterval(3600)) as? KeychainPhoneCertificate)
        #expect(again.fingerprint == made.fingerprint)
        let certificate = try #require(SecCertificateCreateWithData(nil, Data(made.der) as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == PhoneCertificateDer.subject)
        // Close to its end: made anew.
        let later = Self.now.addingTimeInterval(PhoneCertificateDer.life - 10 * 86_400)
        let renewed = try #require(try certificates.get(hostName: "office-mac.local", now: later) as? KeychainPhoneCertificate)
        #expect(renewed.fingerprint != made.fingerprint)
        #expect(PhoneQrCode.image("https://192.0.2.30:9781/p/" + String(repeating: "A", count: 43)).map { $0.width >= 21 } == true)
    }

    @Test func aPhonePairsSendsAndFinishesOverHttpsAndThePortClosesAfter() async throws {
        let kc = try KeychainFile()
        defer { kc.delete() }
        let env = PhoneEnvironment.thisMacOnly(NetworkPhoneHost(), certificates: PhoneCertificateKeychain(keychain: kc.keychain))
        let opening = await PhoneScan.open(env, macName: "OFFICE-MAC")
        let link = try #require(opening.link, "\(opening.problem ?? "")")
        let url = try #require(URL(string: link.url))
        #expect(url.scheme == "https" && url.host == "127.0.0.1")
        let phone = LoopbackPhone(fingerprint: link.fingerprint)
        defer { phone.finish() }

        let page = try await phone.get(link.url)
        #expect(page.status == 200)
        #expect(page.header("Content-Type")?.hasPrefix("text/html") == true)
        #expect(page.header("Content-Security-Policy")?.contains("default-src 'none'") == true)
        #expect(page.header("X-Content-Type-Options") == "nosniff")
        #expect(page.header("Referrer-Policy") == "no-referrer")
        #expect(try await phone.get("https://127.0.0.1:\(link.port)/").status == 404)

        #expect(try await phone.post(link.url + "/pair").status == 200)
        #expect(link.session.state == .paired)
        let photo = PhoneScanTestsShared.jpegHeader(1600, 1200)
        #expect(try await phone.post(link.url + "/photo", body: photo).status == 200)
        #expect(try await phone.post(link.url + "/photo", body: [UInt8](repeating: 0, count: 5000)).status == 415)
        #expect(link.session.received == 1)

        // Without the session cookie (another browser on this Mac): refused.
        #expect(try await phone.post(link.url + "/photo", body: photo, withCookie: false).status == 403)
        // A client that doesn't trust this certificate gets nothing.
        let stranger = LoopbackPhone(fingerprint: "00")
        defer { stranger.finish() }
        await #expect(throws: (any Error).self) { try await stranger.get(link.url) }

        #expect(try await phone.post(link.url + "/done").status == 200)
        #expect(link.session.photos.tryRead()?.data == photo)
        await link.close()
        #expect(!Self.connects(link.port))
    }

    @Test func aPortInUseIsSaidAsSuch() async throws {
        let kc = try KeychainFile()
        defer { kc.delete() }
        let certificates = PhoneCertificateKeychain(keychain: kc.keychain)
        let first = try #require(await PhoneScan.open(.thisMacOnly(NetworkPhoneHost(), certificates: certificates), macName: "Mac").link)
        var taken = PhoneEnvironment.thisMacOnly(NetworkPhoneHost(), certificates: certificates)
        taken.port = first.port
        let second = await PhoneScan.open(taken, macName: "Mac")
        #expect(second.link == nil)
        #expect(second.problem == "Another app uses port \(first.port), which scanning with your phone needs. Quit it and try again.")
        await first.close()
    }

    /// Whether a TCP connection to 127.0.0.1:`port` is taken.
    private static func connects(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}

/// The JPEG header PrintCore's PhoneScanTests make (that target isn't reachable from here).
enum PhoneScanTestsShared {
    static func jpegHeader(_ width: Int, _ height: Int) -> [UInt8] {
        var b: [UInt8] = [0xFF, 0xD8]
        b += [0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(height >> 8 & 0xFF), UInt8(height & 0xFF), UInt8(width >> 8 & 0xFF), UInt8(width & 0xFF), 0x03,
              0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
        b += [0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00, 0xFF, 0xD9]
        return b
    }
}
