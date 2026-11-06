import CryptoKit
import Foundation
import PrintCore
import Testing
@testable import PrintMac

/// Ported from SnmpV3Tests.cs (same names): the tests that need the system's hashes and ciphers, which PrintCore's tests on
/// the PC do with a stand-in. RFC 3414 A.3's MD5 and SHA-1 key vectors (PrintCore's algorithm with CryptoKit's Insecure
/// hashes), and `AppleSnmpCrypto` (CryptoKit, CommonCrypto) against RFC 4231, NIST SP 800-38A, the SHA-256 key vector, the
/// authPriv request written by hand, and the made-up agent read over v3 with it.
@Suite struct SnmpV3Tests {
    private static let crypto = AppleSnmpCrypto()
    private static let rfcEngine = bytes("000000000000000000000002")

    private static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.filter(\.isHexDigit))
        return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
    }

    @Test func passwordToKeyAndLocalizationMatchRFC3414A3ForMD5AndSHA1() {
        let md5: ([UInt8]) -> [UInt8] = { Array(Insecure.MD5.hash(data: $0)) }
        let ku = Usm.passwordToKey("maplesyrup", hash: md5)
        #expect(ku == Self.bytes("9f af 32 83 88 4e 92 83 4e bc 98 47 d8 ed d9 63")) // A.3.1
        #expect(Usm.localize(ku, engineId: Self.rfcEngine, hash: md5) == Self.bytes("52 6f 5e ed 9f cc e2 6f 89 64 c2 93 07 87 d8 2b"))
        let sha1: ([UInt8]) -> [UInt8] = { Array(Insecure.SHA1.hash(data: $0)) }
        let shaKu = Usm.passwordToKey("maplesyrup", hash: sha1)
        #expect(shaKu == Self.bytes("9f b5 cc 03 81 49 7b 37 93 52 89 39 ff 78 8d 5d 79 14 52 11")) // A.3.2
        let shaKul = Usm.localize(shaKu, engineId: Self.rfcEngine, hash: sha1)
        #expect(shaKul == Self.bytes("66 95 fe bc 92 88 e3 62 82 23 5f c7 15 1f 12 84 97 b3 8f 3f"))
    }

    @Test func theSameAlgorithmWithSHA256GivesTheKnownLocalizedKey() {
        let hash: ([UInt8]) -> [UInt8] = { Self.crypto.sha256($0) }
        let ku = Usm.passwordToKey("maplesyrup", hash: hash)
        #expect(ku == Self.bytes("ab51014d1e077f6017df2b12bee5f5aa72993177e9bb569c4dff5a4ca0b4afac"))
        #expect(Usm.localize(ku, engineId: Self.rfcEngine, hash: hash) == Self.bytes("8982e0e549e866db361a6b625d84cccc11162d453ee8ce3a6445c2d6776f0f8b"))
    }

    @Test func theDigestIsHMACSHA256CutTo192Bits() {
        let digest = Usm.authenticate(key: [UInt8](repeating: 0x0B, count: 20), Array("Hi There".utf8), Self.crypto)
        #expect(digest == Self.bytes("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da7")) // RFC 4231 test case 1
    }

    @Test func aesCfbMatchesNISTSP80038AAndTakesAnyLength() {
        let key = Self.bytes("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = Self.bytes("000102030405060708090a0b0c0d0e0f")
        let plain = Self.bytes("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51") // F.3.13, blocks 1-2
        let cipher = Self.bytes("3b3fd92eb72dad20333449f8e83cfb4ac8a64537a0b3a93fcde3cdad9f1ce58b")
        #expect(Usm.aesCfb(key: key, iv: iv, plain, encrypt: true, Self.crypto) == cipher)
        #expect(Usm.aesCfb(key: key, iv: iv, cipher, encrypt: false, Self.crypto) == plain)
        #expect(Usm.aesCfb(key: key, iv: iv, Array(plain.prefix(20)), encrypt: true, Self.crypto) == Array(cipher.prefix(20)))
    }

    @Test func anAuthPrivRequestIsByteForByteTheOneWrittenByHand() throws {
        // PrintCore's SnmpV3Tests' message (Python's hashlib, hmac and AES), signed and encrypted here with the system's crypto.
        let engine = Self.bytes("80001f8880e9630000d61ff449")
        let login = try SnmpLogin.forUser("inkvolt", "authpass-2026", "privpass-2026")
        let keys = Usm.Keys.of(try #require(login.user), engineId: engine, Self.crypto)
        #expect(keys.auth == Self.bytes("fc253677d1f53f3308d820c695259b271a4e65004cc6c46f2efe050abd363445"))
        let pdu = SnmpMessage(.v3, "", .getRequest, requestId: 0x1234, errorStatus: 0, errorIndex: 0,
                              varBinds: [SnmpVarBind(PrinterMib.sysDescr.appending(0), .null)])
        let salt = Self.bytes("0000000000000001")
        let iv = Usm.aesIv(boots: 3, time: 4321, salt: salt)
        let encrypted = Usm.aesCfb(key: keys.priv, iv: iv, SnmpV3Message.encodeScoped(engine, "", pdu), encrypt: true, Self.crypto)
        let flags = SnmpV3Message.flagAuth | SnmpV3Message.flagPriv | SnmpV3Message.flagReportable
        let signed = SnmpV3Message(messageId: 0x5678, flags: flags, engineId: engine, engineBoots: 3, engineTime: 4321, userName: "inkvolt",
                                   privParameters: salt, encrypted: encrypted).sign(keys.auth, Self.crypto)
        let header = "30818c 020103 300f 02025678 020300ffe3 040107 020103 0445 3043 040d80001f8880e9630000d61ff449 020103 020210e1"
        let rest = " 0407696e6b766f6c74 0418d64adc4fcc6e02902b608b478d48dab23ae4b6006a8f12ce 04080000000000000001 042f"
        let cipher = "fa556369817b47a255f05ca418f50a2f209c3ec43e1b9a0479fc35b9ea1f3d21b48ddc9c39f93d089e580931b3e57f"
        #expect(signed == Self.bytes(header + rest + cipher))
    }

    @Test func theAgentIsDiscoveredThenReadSignedAndEncrypted() async throws {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintMacTests/SnmpV3Tests.swift
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let walk = try String(contentsOf: url.appendingPathComponent("print/tests/InkvoltPrint.Tests/Fixtures/snmp-demo/workgroup-laser.txt"),
                              encoding: .utf8)
        let login = try SnmpLogin.forUser("inkvolt", "authpass-2026", "privpass-2026")
        let agent = SnmpAgent(try SnmpAgent.parseWalk(walk), user: try #require(login.user), engineId: Self.bytes("80001f8880e9630000d61ff449"),
                              crypto: Self.crypto)
        Usm.crypto = Self.crypto // the app's: the clients take it when made
        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14", login: login))
        #expect(printer.identity.version == .v3)
        #expect(try await printer.supplies().count == 3)
        #expect(agent.v3Log.filter { $0 == "discovery" }.count == 1) // the reader goes on with the probe's engine
        #expect(agent.v3Log.allSatisfy { $0 == "discovery" || $0 == "answered" })
    }
}
