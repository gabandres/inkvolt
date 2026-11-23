import Foundation
@testable import PrintCore
import PrintMac
import Testing

/// `ApplePdfCrypto` (CryptoKit, CommonCrypto), the system's cryptography for a scan preset's PDF password (roadmap 4.18),
/// against the vectors the PC's stand-in is checked with (ScanArchiveTests' TheTestCryptographyMatchesFips): FIPS 180-4's
/// "abc", FIPS 197's appendix C, and SP 800-38A's CBC example; then a password's /U made with it, which algorithm 2.A's check
/// of the password matches.
struct PdfCryptoTests {
    private static let crypto = ApplePdfCrypto()

    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    private static func bytes(_ hex: String) -> [UInt8] {
        let d = Array(hex.utf8)
        return stride(from: 0, to: d.count - 1, by: 2).map { UInt8(String(decoding: d[$0...$0 + 1], as: UTF8.self), radix: 16)! }
    }

    @Test func theHashesMatchFips180() {
        let abc = Array("abc".utf8)
        #expect(Self.hex(Self.crypto.sha256(abc)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Self.hex(Self.crypto.sha384(abc))
            == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
        #expect(Self.hex(Self.crypto.sha512(abc))
            == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    @Test func aesMatchesFips197AndSp80038a() {
        let plain = Self.bytes("00112233445566778899aabbccddeeff"), zero = [UInt8](repeating: 0, count: 16)
        #expect(Self.hex(Self.crypto.aesCbcEncrypt(key: (0..<16).map(UInt8.init), iv: zero, plain, pad: false)) == "69c4e0d86a7b0430d8cdb78070b4c55a")
        #expect(Self.hex(Self.crypto.aesCbcEncrypt(key: (0..<32).map(UInt8.init), iv: zero, plain, pad: false)) == "8ea2b7ca516745bfeafc49904b496089")
        // SP 800-38A F.2.5, CBC-AES256, the first two blocks.
        let key = Self.bytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = Self.bytes("000102030405060708090a0b0c0d0e0f")
        let text = Self.bytes("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        #expect(Self.hex(Self.crypto.aesCbcEncrypt(key: key, iv: iv, text, pad: false))
            == "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d")
        #expect(Self.crypto.aesCbcEncrypt(key: key, iv: iv, Array(text.prefix(20)), pad: true).count == 32) // PKCS#7 to whole blocks
    }

    @Test func aProtectedScanWrittenWithItChecksItsPassword() throws {
        let crypt = try PdfEncryption.create("pw", crypto: Self.crypto)
        let u = Self.bytes(String(crypt.dictionary().components(separatedBy: "/U <")[1].prefix(96)))
        #expect(u.count == 48)
        // Algorithm 2.A: the password's hash with the validation salt is the first 32 bytes of /U.
        let pw = PdfEncryption.passwordBytes("pw")
        #expect(Array(u[0..<32]) == PdfEncryption.hash(pw, Array(u[32..<40]), [], Self.crypto))
        #expect(Array(u[0..<32]) != PdfEncryption.hash(PdfEncryption.passwordBytes("wrong"), Array(u[32..<40]), [], Self.crypto))
    }
}
