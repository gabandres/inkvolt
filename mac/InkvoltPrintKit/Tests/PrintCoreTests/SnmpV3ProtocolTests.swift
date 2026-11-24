import Foundation
import Testing
import TestTiming
@testable import PrintCore

/// SNMPv3's other protocols beside SHA-256 and AES-128: HMAC-MD5-96 and HMAC-SHA-1-96 (RFC 3414 §6, §7), CBC-DES (RFC 3414
/// §8), AES-192 and AES-256 in CFB mode with a short key lengthened as Blumenthal's draft says (net-snmp) or, tried next, as
/// Reeder's (Cisco). The primitives against RFC 2202, NIST SP 800-38A and the textbook DES example; the key extensions and
/// RFC 3414's DES framing against values Python's hashlib and cryptography computed; then the made-up agent read with every
/// pair. Ported from SnmpV3ProtocolTests.cs, the crypto from `TestSnmpCrypto` (the PC has no CryptoKit; PrintMacTests runs
/// the primitives' vectors with `AppleSnmpCrypto`). Left out: A_protocol_that_isn_t_one_is_refused (Swift's enums hold no
/// other value).
@Suite(.offThePool)
struct SnmpV3ProtocolTests {
    private static let crypto: any SnmpCrypto = TestSnmpCrypto()
    private static let rfcEngine = hex("000000000000000000000002") // RFC 3414 A.3's engine ID

    init() { TestSnmpCrypto.install() }

    // MARK: primitives

    @Test func hmacMd596AndHmacSha196AreRfc2202sFirstCaseCutTo12Bytes() {
        let message = Array("Hi There".utf8)
        #expect(Usm.authenticate(.md5, key: [UInt8](repeating: 0x0b, count: 16), message, Self.crypto) == hex("9294727a3638bb1c13f48ef8"))
        #expect(Usm.authenticate(.sha1, key: [UInt8](repeating: 0x0b, count: 20), message, Self.crypto) == hex("b617318655057264e28bc0b6"))
        let lengths: [Int] = [Usm.digestLength(.md5), Usm.digestLength(.sha1), Usm.digestLength(.sha256)]
        #expect(lengths == [12, 12, 24])
    }

    @Test(arguments: [
        ("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b", "cdc80d6fddf18cab34c25909c99a417467ce7f7f81173621961a2b70171d3d7a"), // F.3.15
        ("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4", "dc7e84bfda79164b7ecd8486985d386039ffed143b28b1c832113c6331e5407b"), // F.3.17
    ])
    func aes192And256CfbMatchNistSp80038A(_ key: String, _ cipher: String) {
        let k = hex(key)
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        let plain = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        #expect(Usm.aesCfb(key: k, iv: iv, plain, encrypt: true, keyLength: k.count, Self.crypto) == hex(cipher))
        #expect(Usm.aesCfb(key: k, iv: iv, Array(hex(cipher).prefix(21)), encrypt: false, keyLength: k.count, Self.crypto) == Array(plain.prefix(21)))
    }

    @Test func desMatchesTheTextbookExample() throws {
        // Key 133457799BBCDFF1, block 0123456789ABCDEF (J. Orlin Grabbe's worked example); a zero IV makes CBC's first block ECB's.
        let key = hex("133457799BBCDFF1 0000000000000000")
        #expect(try Usm.desCbc(key, salt: [UInt8](repeating: 0, count: 8), hex("0123456789ABCDEF"), encrypt: true, Self.crypto) == hex("85e813540f0ab405"))
    }

    @Test func cbcDesTakesItsKeyAndPreIvFromThePrivacyKeyAndPadsToWholeBlocks() throws {
        // RFC 3414 §8.1.1: "maplesyrup" localized with MD5 at A.3's engine; key = its first 8 bytes, IV = its last 8 XOR the salt.
        let kul = hex("526f5eed9fcce26f8964c2930787d82b")
        let salt = Usm.salt(.des, boots: 3, counter: 1)
        #expect(salt == hex("0000000300000001")) // engine boots, then this sender's number
        let plain = (0..<20).map { UInt8($0) }
        let cipher = try Usm.desCbc(kul, salt: salt, plain, encrypt: true, Self.crypto)
        #expect(cipher == hex("009824bac70e3bdf7ab2bc947a02bd83c129148f14e64170")) // 20 bytes padded to 24
        #expect(Array(try Usm.desCbc(kul, salt: salt, cipher, encrypt: false, Self.crypto).prefix(20)) == plain)
        #expect(throws: SnmpFormatError.self) { try Usm.desCbc(kul, salt: salt, Array(cipher.prefix(23)), encrypt: false, Self.crypto) } // a decryption error
    }

    @Test func anAesSaltIsTheWholeCounterAndADesOneStartsWithTheBoots() {
        #expect(Usm.salt(.aes256, boots: 7, counter: 0x102) == hex("0000000000000102"))
        #expect(Usm.salt(.des, boots: 7, counter: 0x102) == hex("0000000700000102"))
    }

    // MARK: keys

    @Test(arguments: [
        (SnmpAuth.md5, SnmpPriv.aes192, Usm.KeyExtension.blumenthal, "526f5eed9fcce26f8964c2930787d82bfa24a92467426c2f"),
        (.md5, .aes256, .blumenthal, "526f5eed9fcce26f8964c2930787d82bfa24a92467426c2f4b09192be10dfaec"),
        (.sha1, .aes192, .blumenthal, "6695febc9288e36282235fc7151f128497b38f3f505e07eb"),
        (.sha1, .aes256, .blumenthal, "6695febc9288e36282235fc7151f128497b38f3f505e07eb9af25568fa1f5dbe"),
        (.md5, .aes256, .reeder, "526f5eed9fcce26f8964c2930787d82b79eff44a90650ee0a3a40abfac5acc12"),
        (.sha1, .aes192, .reeder, "6695febc9288e36282235fc7151f128497b38f3f9b8b6d78"),
        (.sha1, .aes256, .reeder, "6695febc9288e36282235fc7151f128497b38f3f9b8b6d78936ba6e7d19dfd9c"),
        (.md5, .des, .blumenthal, "526f5eed9fcce26f8964c2930787d82b"), // long enough already
        (.sha1, .aes128, .reeder, "6695febc9288e36282235fc7151f128497b38f3f"),
    ] as [(SnmpAuth, SnmpPriv, Usm.KeyExtension, String)])
    func aShortPrivacyKeyIsLengthenedAsTheDraftsSay(_ auth: SnmpAuth, _ priv: SnmpPriv, _ how: Usm.KeyExtension, _ key: String) {
        let user = SnmpV3User(name: "u", authPassphrase: "maplesyrup", privPassphrase: "maplesyrup", auth: auth, priv: priv)
        let keys = Usm.Keys.of(user, engineId: Self.rfcEngine, Self.crypto, extension: how)
        #expect(keys.priv == hex(key))
        let algorithm = Usm.hash(auth)
        let hashing: ([UInt8]) -> [UInt8] = { Self.crypto.hash(algorithm, $0) }
        let localized = Usm.localize(Usm.passwordToKey("maplesyrup", hash: hashing), engineId: Self.rfcEngine, hash: hashing)
        #expect(keys.priv.prefix(16) == localized.prefix(16)) // the localized key first
    }

    @Test func onlyAes192Or256AfterMd5OrSha1HasAnotherKeyToTry() {
        func u(_ a: SnmpAuth, _ p: SnmpPriv) -> SnmpV3User { SnmpV3User(name: "u", authPassphrase: "maplesyrup", privPassphrase: "maplesyrup", auth: a, priv: p) }
        #expect(Usm.Keys.otherwise(u(.sha1, .aes256), engineId: Self.rfcEngine, Self.crypto, .blumenthal) != nil)
        #expect(Usm.Keys.otherwise(u(.md5, .aes192), engineId: Self.rfcEngine, Self.crypto, .blumenthal) != nil)
        #expect(Usm.Keys.otherwise(u(.sha256, .aes256), engineId: Self.rfcEngine, Self.crypto, .blumenthal) == nil) // 32 bytes: no extension
        #expect(Usm.Keys.otherwise(u(.sha1, .aes128), engineId: Self.rfcEngine, Self.crypto, .blumenthal) == nil)
        #expect(Usm.Keys.otherwise(u(.md5, .des), engineId: Self.rfcEngine, Self.crypto, .blumenthal) == nil)
    }

    // MARK: the made-up agent

    private static let engine = hex("80001f8880e1b2c3d4e5f60718")

    private static func user(_ auth: SnmpAuth, _ priv: SnmpPriv) -> SnmpV3User {
        SnmpV3User(name: "reader", authPassphrase: "authpass-2026", privPassphrase: "privpass-2026", auth: auth, priv: priv)
    }

    private static func agent(_ user: SnmpV3User, _ how: Usm.KeyExtension = .blumenthal) throws -> SnmpAgent {
        SnmpAgent(try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/workgroup-laser.txt")), user: user, engineId: engine, engineBoots: 3,
                  engineTime: 4321, crypto: crypto, extension: how)
    }

    private static func login(_ u: SnmpV3User) throws -> SnmpLogin {
        try SnmpLogin.forUser(u.name, u.authPassphrase, u.privPassphrase, auth: u.auth, priv: u.priv)
    }

    private static let sysName0 = PrinterMib.sysName.appending(0)

    static let everyPair: [(SnmpAuth, SnmpPriv)] = SnmpAuth.allCases.flatMap { a in SnmpPriv.allCases.map { (a, $0) } }

    @Test(arguments: everyPair)
    func theAgentIsReadWithEveryPairOfProtocols(_ auth: SnmpAuth, _ priv: SnmpPriv) async throws {
        let agent = try Self.agent(Self.user(auth, priv))
        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14", login: try Self.login(Self.user(auth, priv))))
        #expect(printer.identity.serialNumber == "DEMO0005200")
        #expect(try await printer.supplies().count == 3) // GetBulk, encrypted both ways
        #expect(agent.v3Log.filter { $0 != "discovery" }.allSatisfy { $0 == "answered" })
    }

    @Test(arguments: [
        (SnmpAuth.sha256, SnmpPriv.aes128, SnmpAuth.sha1, SnmpPriv.aes128, SnmpRefusal.wrongAuthKey), // a 12-byte digest where 24 are due
        (.md5, .aes128, .sha1, .aes128, .wrongAuthKey),
        (.sha1, .des, .sha1, .aes128, .wrongPrivKey),
        (.sha1, .aes256, .sha1, .aes192, .wrongPrivKey),
    ] as [(SnmpAuth, SnmpPriv, SnmpAuth, SnmpPriv, SnmpRefusal)])
    func anotherProtocolThanTheAgentsIsRefusedAsThatPart(_ agentAuth: SnmpAuth, _ agentPriv: SnmpPriv, _ auth: SnmpAuth, _ priv: SnmpPriv,
                                                         _ reason: SnmpRefusal) async throws {
        let agent = try Self.agent(Self.user(agentAuth, agentPriv))
        let client = try SnmpClient(transport: agent, host: "192.0.2.14", version: .v3, login: try Self.login(Self.user(auth, priv)))
        await #expect(throws: SnmpAccessError(reason)) { try await client.get([Self.sysName0]) }
    }

    @Test(arguments: [(SnmpAuth.sha1, SnmpPriv.aes256), (.md5, .aes192)] as [(SnmpAuth, SnmpPriv)])
    func anAgentThatLengthensItsKeyAsReederDoesIsReadAfterOneDecryptionError(_ auth: SnmpAuth, _ priv: SnmpPriv) async throws {
        let agent = try Self.agent(Self.user(auth, priv), .reeder)
        let client = try SnmpClient(transport: agent, host: "192.0.2.14", version: .v3, login: try Self.login(Self.user(auth, priv)))
        #expect(try await client.get([Self.sysName0])[0].value.text == "demo-laser")
        #expect(agent.v3Log == ["discovery", "decryptionErrors", "answered"])
        _ = try await client.get([Self.sysName0]) // the key that worked is kept
        #expect(agent.v3Log.last == "answered")
        #expect(agent.v3Log.filter { $0 == "decryptionErrors" }.count == 1)
    }

    @Test func aWrongPrivacyPassphraseIsStillAWrongPrivacyKeyAfterBothExtensions() async throws {
        let agent = try Self.agent(Self.user(.sha1, .aes256))
        let wrong = SnmpV3User(name: "reader", authPassphrase: "authpass-2026", privPassphrase: "another-priv-pass", auth: .sha1, priv: .aes256)
        let client = try SnmpClient(transport: agent, host: "192.0.2.14", version: .v3, login: try Self.login(wrong))
        await #expect(throws: SnmpAccessError(.wrongPrivKey)) { try await client.get([Self.sysName0]) }
        #expect(agent.v3Log.filter { $0 == "decryptionErrors" }.count == 2)
    }

    @Test func aDesRequestWhoseBlocksArentWholeIsADecryptionError() throws {
        let user = Self.user(.md5, .des)
        let agent = try Self.agent(user)
        let keys = Usm.Keys.of(user, engineId: Self.engine, Self.crypto)
        let salt = keys.salt(boots: 3, counter: 1)
        let pdu = SnmpMessage(.v3, "", .getRequest, requestId: 9, errorStatus: 0, errorIndex: 0, varBinds: [SnmpVarBind(Self.sysName0, .null)])
        let scoped = SnmpV3Message.encodeScoped(Self.engine, "", pdu)
        let encrypted = try keys.encrypt(boots: 3, time: 4321, salt: salt, scoped, Self.crypto)
        let request = SnmpV3Message(messageId: 9, flags: SnmpV3Message.flagAuth | SnmpV3Message.flagPriv | SnmpV3Message.flagReportable,
                                    engineId: Self.engine, engineBoots: 3, engineTime: 4321, userName: user.name, privParameters: salt,
                                    encrypted: Array(encrypted.dropLast())).sign(keys, Self.crypto)
        #expect(agent.respond(request) != nil)
        #expect(agent.v3Log.last == "decryptionErrors")
    }

    // MARK: the login kept

    @Test func theProtocolsAreKeptWithTheLoginAndAnOlderEntryIsSha256AndAes128() throws {
        let login = try Self.login(Self.user(.md5, .des))
        #expect(login.toSecret().hasSuffix(":Md5:Des"))
        #expect(SnmpLogin.fromSecret(login.toSecret()) == login)

        let plain = try Self.login(Self.user(.sha256, .aes128))
        #expect(plain.toSecret().dropFirst("usm:".count).split(separator: ":", omittingEmptySubsequences: false).count == 3) // as kept before the other protocols came
        let read = try #require(SnmpLogin.fromSecret(plain.toSecret())?.user)
        #expect(read.auth == .sha256 && read.priv == .aes128)
        #expect(!login.description.contains("authpass"))
    }

    @Test(arguments: [":7:Des", ":sha1:Des", ": Sha1:Des", ":Sha512:Aes128", ":Sha1:Aes512", ":Sha1", ":Sha1:Des:More"])
    func aKeptLoginWithProtocolsThisVersionDidntWriteIsNoLogin(_ tail: String) throws {
        let secret = try Self.login(Self.user(.sha256, .aes128)).toSecret() + tail
        #expect(SnmpLogin.fromSecret(secret) == nil)
    }

    @Test func theDigestPlaceholderHasTheProtocolsLength() throws {
        let keys = Usm.Keys.of(Self.user(.sha1, .aes128), engineId: Self.engine, Self.crypto)
        let bytes = SnmpV3Message(messageId: 1, flags: SnmpV3Message.flagAuth, engineId: Self.engine, userName: "reader", contextEngineId: Self.engine,
                                  pdu: SnmpMessage(.v3, "", .getRequest, requestId: 1, errorStatus: 0, errorIndex: 0, varBinds: []))
            .sign(keys, Self.crypto)
        let read = try SnmpV3Message.decode(bytes)
        #expect(read.authParameters.count == 12)
        #expect(read.verify(bytes, keys, Self.crypto))
        #expect(!read.verify(bytes, Usm.Keys.of(Self.user(.sha256, .aes128), engineId: Self.engine, Self.crypto), Self.crypto)) // another length: no digest of it
        var zeroed = bytes
        zeroed.replaceSubrange(read.authOffset..<read.authOffset + 12, with: [UInt8](repeating: 0, count: 12))
        #expect(read.authParameters == keys.sign(zeroed, Self.crypto))
    }
}
