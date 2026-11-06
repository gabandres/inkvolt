import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// SNMPv3 (roadmap 3.2, Pro): the User-based Security Model's key localization with SHA-256 (RFC 3414 A.3's MD5 and SHA-1
/// vectors are in PrintMacTests, which has those hashes), HMAC-SHA-256 against RFC 4231, AES-CFB against NIST SP 800-38A, a
/// discovery request and an authPriv GetRequest written by hand byte for byte (RFC 3412 §6, RFC 3414 §2.4, RFC 3826 §3.1),
/// the made-up agent speaking v3: discovery, reads, and refusing a wrong user or either wrong key; and lengths from the
/// network bounded. Ported from print/tests/InkvoltPrint.Tests/SnmpV3Tests.cs, the crypto from `TestSnmpCrypto` (the PC
/// has no CryptoKit).
struct SnmpV3Tests {
    private static let crypto: any SnmpCrypto = TestSnmpCrypto()
    private static let rfcEngine = hex("000000000000000000000002") // RFC 3414 A.3's engine ID

    init() { TestSnmpCrypto.install() }

    // MARK: keys, digest, cipher

    @Test func theSameAlgorithmWithSHA256GivesTheKnownLocalizedKey() {
        // RFC 7860 §4.2.2 keeps A.2's algorithm; this is "maplesyrup" at A.3's engine, as other SNMP stacks print it.
        let hash: ([UInt8]) -> [UInt8] = { Self.crypto.sha256($0) }
        let ku = Usm.passwordToKey("maplesyrup", hash: hash)
        #expect(ku == hex("ab51014d1e077f6017df2b12bee5f5aa72993177e9bb569c4dff5a4ca0b4afac"))
        #expect(Usm.localize(ku, engineId: Self.rfcEngine, hash: hash) == hex("8982e0e549e866db361a6b625d84cccc11162d453ee8ce3a6445c2d6776f0f8b"))
    }

    @Test func theDigestIsHMACSHA256CutTo192Bits() {
        // RFC 4231 test case 1, its first 24 bytes (RFC 7860 §4.2.1's usmHMAC192SHA256AuthProtocol).
        let digest = Usm.authenticate(key: [UInt8](repeating: 0x0B, count: 20), Array("Hi There".utf8), Self.crypto)
        #expect(digest == hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da7"))
    }

    @Test func aesCfbMatchesNISTSP80038AAndTakesAnyLength() {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = hex("000102030405060708090a0b0c0d0e0f")
        let plain = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51") // F.3.13 CFB128-AES128.Encrypt, blocks 1-2
        let cipher = hex("3b3fd92eb72dad20333449f8e83cfb4ac8a64537a0b3a93fcde3cdad9f1ce58b")
        #expect(Usm.aesCfb(key: key, iv: iv, plain, encrypt: true, Self.crypto) == cipher)
        #expect(Usm.aesCfb(key: key, iv: iv, cipher, encrypt: false, Self.crypto) == plain)
        // No padding is sent: 20 bytes in, the same 20 bytes of the cipher stream out.
        #expect(Usm.aesCfb(key: key, iv: iv, Array(plain.prefix(20)), encrypt: true, Self.crypto) == Array(cipher.prefix(20)))
        #expect(Usm.aesCfb(key: key, iv: iv, Array(cipher.prefix(20)), encrypt: false, Self.crypto) == Array(plain.prefix(20)))
    }

    @Test func theAESIVIsBootsTimeAndSaltBigEndian() {
        #expect(Usm.aesIv(boots: 3, time: 4321, salt: hex("0102030405060708")) == hex("00000003 000010e1 0102030405060708")) // RFC 3826 §3.1.2.1
    }

    // MARK: messages written by hand

    @Test func aDiscoveryRequestIsWrittenAsRFC3414Section4HasIt() {
        let pdu = SnmpMessage(.v3, "", .getRequest, requestId: 0x1234, errorStatus: 0, errorIndex: 0, varBinds: [])
        let bytes = SnmpV3Message(messageId: 0x5678, flags: SnmpV3Message.flagReportable, contextEngineId: [], pdu: pdu).encode()
        let expected = hex(
            "30 3a"
                + "  02 01 03" // msgVersion 3
                + "  30 0f 02 02 5678 02 03 00ffe3 04 01 04 02 01 03" // msgID, msgMaxSize 65507, msgFlags reportable, USM
                + "  04 10 30 0e 04 00 02 01 00 02 01 00 04 00 04 00 04 00" // no engine, boots 0, time 0, no user, no digest, no salt
                + "  30 12 04 00 04 00" // scoped PDU in clear: no contextEngineID, no contextName
                + "    a0 0c 02 02 1234 02 01 00 02 01 00 30 00") // GetRequest, no variables
        #expect(bytes == expected)
    }

    // An authPriv GetRequest of sysDescr.0, written out by hand; the cipher text and digest come from the keys below
    // (Python's hashlib, hmac and an AES-CFB of its own, not this code).
    private static let engine = hex("80001f8880e9630000d61ff449")
    private static let authPass = "authpass-2026", privPass = "privpass-2026", user = "inkvolt"
    private static let authKul = "fc253677d1f53f3308d820c695259b271a4e65004cc6c46f2efe050abd363445", privKul16 = "677c849915cc5a33c1fb6bebd52d9811"
    private static let scoped = "302d 040d80001f8880e9630000d61ff449 0400 a01a 02021234 020100 020100 300e 300c 06082b06010201010100 0500"
    private static let encrypted = "fa556369817b47a255f05ca418f50a2f209c3ec43e1b9a0479fc35b9ea1f3d21b48ddc9c39f93d089e580931b3e57f"
    private static let digest = "d64adc4fcc6e02902b608b478d48dab23ae4b6006a8f12ce"
    private static let message: String = {
        let header = "30818c 020103 300f 02025678 020300ffe3 040107 020103"
        let usm = " 0445 3043 040d80001f8880e9630000d61ff449 020103 020210e1 0407696e6b766f6c74 0418" + digest + " 04080000000000000001"
        return header + usm + " 042f" + encrypted
    }()

    @Test func anAuthPrivRequestIsByteForByteTheOneWrittenByHand() {
        let keys = Usm.Keys.of(SnmpV3User(name: Self.user, authPassphrase: Self.authPass, privPassphrase: Self.privPass), engineId: Self.engine, Self.crypto)
        #expect(keys.auth == hex(Self.authKul))
        #expect(Array(keys.priv.prefix(16)) == hex(Self.privKul16)) // RFC 3826 §1.2: AES-128 takes the first 16 bytes

        let pdu = SnmpMessage(.v3, "", .getRequest, requestId: 0x1234, errorStatus: 0, errorIndex: 0,
                              varBinds: [SnmpVarBind(PrinterMib.sysDescr.appending(0), .null)])
        let scoped = SnmpV3Message.encodeScoped(Self.engine, "", pdu)
        #expect(scoped == hex(Self.scoped))
        let salt = hex("0000000000000001")
        let encrypted = Usm.aesCfb(key: keys.priv, iv: Usm.aesIv(boots: 3, time: 4321, salt: salt), scoped, encrypt: true, Self.crypto)
        #expect(encrypted == hex(Self.encrypted))

        let flags = SnmpV3Message.flagAuth | SnmpV3Message.flagPriv | SnmpV3Message.flagReportable
        let signed = SnmpV3Message(messageId: 0x5678, flags: flags, engineId: Self.engine, engineBoots: 3, engineTime: 4321, userName: Self.user,
                                   privParameters: salt, encrypted: encrypted).sign(keys.auth, Self.crypto)
        #expect(signed == hex(Self.message))
    }

    @Test func theHandWrittenMessageReadsBackChecksAndDecrypts() throws {
        let bytes = hex(Self.message)
        let m = try SnmpV3Message.decode(bytes)
        #expect(m.messageId == 0x5678 && m.flags == 7 && m.engineBoots == 3 && m.engineTime == 4321 && m.userName == Self.user)
        #expect(m.engineId == Self.engine)
        #expect(m.verify(bytes, hex(Self.authKul), Self.crypto))
        let iv = Usm.aesIv(boots: 3, time: 4321, salt: m.privParameters)
        let clear = Usm.aesCfb(key: hex(Self.privKul16), iv: iv, try #require(m.encrypted), encrypt: false, Self.crypto)
        let (contextEngine, contextName, pdu) = try SnmpV3Message.decodeScoped(clear)
        #expect(contextEngine == Self.engine)
        #expect(contextName == "" && pdu.type == .getRequest && pdu.requestId == 0x1234)
        #expect(pdu.varBinds.map(\.name) == [PrinterMib.sysDescr.appending(0)])

        // Any byte changed anywhere fails the digest; so does another key.
        for i in bytes.indices where !(m.authOffset..<m.authOffset + Usm.authLength).contains(i) {
            var changed = bytes
            changed[i] ^= 0x01
            guard let read = try? SnmpV3Message.decode(changed) else { continue } // no longer a message at all: nothing to check
            #expect(!read.verify(changed, hex(Self.authKul), Self.crypto), "byte \(i)")
        }
        let other = Usm.Keys.of(SnmpV3User(name: Self.user, authPassphrase: "another-pass", privPassphrase: Self.privPass), engineId: Self.engine, Self.crypto)
        #expect(!m.verify(bytes, other.auth, Self.crypto))
    }

    @Test func aV1OrV2cDecoderDoesntTakeAV3Message() {
        #expect(SnmpV3Message.isV3(hex(Self.message)))
        #expect(throws: SnmpFormatError.self) { try SnmpMessage.decode(hex(Self.message)) }
        let v2c = SnmpMessage(.v2c, "public", .getRequest, requestId: 1, errorStatus: 0, errorIndex: 0, varBinds: []).encode()
        #expect(!SnmpV3Message.isV3(v2c))
    }

    // MARK: lengths from the network (a Mac addition: the v1/v2c reader's rule, for v3's own fields)

    /// The hand-written message with its engine ID (13 bytes) replaced by `count` bytes, its lengths fixed up.
    private static func withEngineId(_ count: Int) -> [UInt8] {
        let flags = SnmpV3Message.flagAuth | SnmpV3Message.flagPriv | SnmpV3Message.flagReportable
        return SnmpV3Message(messageId: 0x5678, flags: flags, engineId: [UInt8](repeating: 0x80, count: count), engineBoots: 3, engineTime: 4321,
                             userName: user, authParameters: hex(digest), privParameters: hex("0000000000000001"), encrypted: hex(encrypted)).encode()
    }

    @Test func anEngineIdOrFieldLongerThanAllowedIsNoMessage() throws {
        _ = try SnmpV3Message.decode(Self.withEngineId(Usm.maxEngineId))
        #expect(throws: SnmpFormatError.self) { try SnmpV3Message.decode(Self.withEngineId(Usm.maxEngineId + 1)) }
        let long = SnmpV3Message(messageId: 1, flags: 0, engineId: Self.engine, userName: String(repeating: "u", count: 65), contextEngineId: Self.engine,
                                 pdu: SnmpMessage(.v3, "", .report, requestId: 1, errorStatus: 0, errorIndex: 0, varBinds: []))
        #expect(throws: SnmpFormatError.self) { try SnmpV3Message.decode(long.encode()) }
        // A msgID past 2³¹−1 and a negative boots are out of range, not wrapped.
        var bad = hex(Self.message)
        bad.replaceSubrange(10..<12, with: [0x80, 0x00]) // msgID -32768
        #expect(throws: SnmpFormatError.self) { try SnmpV3Message.decode(bad) }
        // A length running past its container, cut short anywhere: never read past the datagram.
        let whole = hex(Self.message)
        for cut in stride(from: 1, to: whole.count, by: 7) {
            #expect(throws: SnmpFormatError.self) { try SnmpV3Message.decode(Array(whole.prefix(cut))) }
        }
    }

    @Test func aDiscoveryReportWithAnUnusableEngineIdIsNoAnswer() async throws {
        // An agent reporting a 4-byte engine ID (RFC 3411: 5 to 32) is never used: no keys are made for it.
        let liar = Replier { request in
            guard let m = try? SnmpV3Message.decode(request) else { return nil }
            let report = SnmpMessage(.v3, "", .report, requestId: m.pdu?.requestId ?? 0, errorStatus: 0, errorIndex: 0,
                                     varBinds: [SnmpVarBind(Usm.unknownEngineIds, .unsigned(Ber.counter32, 1))])
            return SnmpV3Message(messageId: m.messageId, flags: 0, engineId: [1, 2, 3, 4], contextEngineId: [1, 2, 3, 4], pdu: report).encode()
        }
        let client = try SnmpClient(transport: liar, host: "192.0.2.14", version: .v3, login: Self.login(Self.right), retries: 0)
        await #expect(throws: SnmpFormatError.self) { try await client.get([PrinterMib.sysDescr.appending(0)]) }
    }

    // MARK: the made-up agent over v3

    private static let right = SnmpV3User(name: user, authPassphrase: authPass, privPassphrase: privPass)

    private static func agent() throws -> SnmpAgent {
        SnmpAgent(try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/workgroup-laser.txt")), user: right, engineId: engine, engineBoots: 3,
                  engineTime: 4321, crypto: crypto)
    }

    private static func login(_ u: SnmpV3User) throws -> SnmpLogin { try SnmpLogin.forUser(u.name, u.authPassphrase, u.privPassphrase) }

    @Test func theAgentIsDiscoveredThenReadSignedAndEncrypted() async throws {
        let agent = try Self.agent()
        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14", login: Self.login(Self.right)))
        #expect(printer.identity.version == .v3)
        #expect(printer.identity.serialNumber == "DEMO0005200")
        #expect(try await printer.supplies().count == 3)
        // The engine is discovered once: the reader and every identity check go on with the probe's.
        #expect(agent.v3Log.filter { $0 == "discovery" }.count == 1)
        #expect(agent.v3Log.first == "discovery")
        #expect(agent.v3Log.allSatisfy { $0 == "discovery" || $0 == "answered" })
        #expect(try await printer.readIdentity() != nil)
        #expect(agent.v3Log.filter { $0 == "discovery" }.count == 1)
    }

    @Test func aWalkUsesGetBulkOverV3() async throws {
        let agent = try Self.agent()
        let client = try SnmpClient(transport: agent, host: "192.0.2.14", version: .v3, login: Self.login(Self.right))
        let columns = try await client.walk([PrinterMib.suppliesDescription])
        #expect(columns[0].count == 3)
        #expect(agent.received.contains { $0.type == .getBulkRequest })
    }

    @Test(arguments: [
        ("someone", authPass, privPass, SnmpRefusal.unknownUser, "unknownUserNames"),
        (user, "wrong-auth-pass", privPass, .wrongAuthKey, "wrongDigests"),
        (user, authPass, "wrong-priv-pass", .wrongPrivKey, "decryptionErrors"),
    ] as [(String, String, String, SnmpRefusal, String)])
    func theAgentRefusesAWrongUserOrKeyAndTheClientSaysWhich(_ name: String, _ auth: String, _ priv: String, _ reason: SnmpRefusal,
                                                             _ counter: String) async throws {
        let agent = try Self.agent()
        let login = try SnmpLogin.forUser(name, auth, priv)
        let client = try SnmpClient(transport: agent, host: "192.0.2.14", version: .v3, login: login)
        do {
            _ = try await client.get([PrinterMib.sysDescr.appending(0)])
            Issue.record("read with a wrong user or key")
        } catch let error as SnmpAccessError {
            #expect(error.reason == reason)
            #expect(!"\(error)".contains(auth) && !"\(error)".contains(priv))
        }
        #expect(agent.v3Log.last == counter)
        #expect(!agent.received.contains { $0.type == .getRequest && !$0.varBinds.isEmpty }) // nothing was read

        let told = Told() // the probe finds nothing, and says why
        #expect(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14", login: login, refused: { told.set($0) }) == nil)
        #expect(told.reason == reason)
    }

    @Test func aV3AgentIgnoresV1AndV2cAndACommunityLoginNeverSpeaksV3() async throws {
        let agent = try Self.agent()
        #expect(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14") == nil)
        #expect(agent.v3Log.isEmpty)
        let v2 = SnmpAgent(try SnmpAgent.parseWalk(".1.3.6.1.2.1.1.5.0 = STRING: \"x\""))
        #expect(v2.respond(hex(Self.message)) == nil) // a v1/v2c agent doesn't speak v3
        #expect(throws: SnmpLoginError.self) { try SnmpClient(transport: agent, host: "h", version: .v3, login: .public) }
        #expect(throws: SnmpLoginError.self) { try SnmpClient(transport: agent, host: "h", version: .v2c, login: Self.login(Self.right)) }
    }

    @Test func aClockOutOfTheWindowIsSetFromTheAgentsSignedReport() async throws {
        let agent = try Self.agent()
        let client = try SnmpClient(transport: agent, host: "192.0.2.14", version: .v3, login: Self.login(Self.right))
        _ = try await client.get([PrinterMib.sysDescr.appending(0)])
        agent.engineBoots = 4 // the printer restarted
        agent.engineTime = 12
        let got = try await client.get([PrinterMib.sysName.appending(0)])
        #expect(got[0].value.text == "demo-laser")
        #expect(agent.v3Log == ["discovery", "answered", "notInTimeWindows", "answered"])
    }

    @Test func aReplyChangedOnTheWayIsNoAnswer() async throws {
        let tampered = Tamper(try Self.agent())
        let client = try SnmpClient(transport: tampered, host: "192.0.2.14", version: .v3, login: Self.login(Self.right), retries: 0)
        _ = try await client.get([PrinterMib.sysName.appending(0)]) // discovery and a first answer pass untouched
        tampered.on.store(true, ordering: .relaxed)
        await #expect(throws: SnmpTimeoutError.self) { try await client.get([PrinterMib.sysName.appending(0)]) }
    }

    private static let otherEngine = hex("80001f8880aaaaaaaaaaaaaaaa")

    @Test(arguments: [
        ("unknownUserNames", false), // from another engine: anyone's
        ("unknownEngineIDs", true), // after discovery: no reason to discover again
        ("notInTimeWindows", true), // unsigned: never sets the clock, never "doesn't take authPriv"
    ])
    func anUnsignedReportRfc3414DoesntAllowIsNoAnswer(_ counter: String, _ fromItsEngine: Bool) async throws {
        let spoofer = Spoofer(try Self.agent())
        let client = try SnmpClient(transport: spoofer, host: "192.0.2.14", version: .v3, login: Self.login(Self.right), retries: 0)
        _ = try await client.get([PrinterMib.sysName.appending(0)])
        let oid = counter == "unknownUserNames" ? Usm.unknownUserNames : counter == "unknownEngineIDs" ? Usm.unknownEngineIds : Usm.notInTimeWindows
        spoofer.spoof.withLock { $0 = (oid, fromItsEngine ? Self.engine : Self.otherEngine) }
        do {
            _ = try await client.get([PrinterMib.sysName.appending(0)])
            Issue.record("\(counter): answered")
        } catch {
            #expect(error is SnmpTimeoutError, "\(counter): \(error)")
        }
        #expect(spoofer.agent.v3Log.filter { $0 == "discovery" }.count == 1)
        #expect(client.v3.withLock { $0.engine?.boots } == 3)
    }

    @Test func anUnsignedRefusalFromTheAgentsOwnEngineStillSaysWhich() async throws {
        let spoofer = Spoofer(try Self.agent())
        let client = try SnmpClient(transport: spoofer, host: "192.0.2.14", version: .v3, login: Self.login(Self.right), retries: 0)
        _ = try await client.get([PrinterMib.sysName.appending(0)])
        spoofer.spoof.withLock { $0 = (Usm.wrongDigests, Self.engine) }
        await #expect(throws: SnmpAccessError(.wrongAuthKey)) { try await client.get([PrinterMib.sysName.appending(0)]) }
    }

    @Test(arguments: [(-1, 0, false), (0, -(Usm.timeWindow + 1), false), (0, -(Usm.timeWindow - 10), true)])
    func aSignedAnswerOutsideTheTimeWindowIsNoAnswerAndLeavesTheClock(_ boots: Int, _ time: Int, _ inWindow: Bool) async throws {
        let stale = Stale(try Self.agent(), keys: Usm.Keys.of(Self.right, engineId: Self.engine, Self.crypto))
        let client = try SnmpClient(transport: stale, host: "192.0.2.14", version: .v3, login: Self.login(Self.right), retries: 0)
        _ = try await client.get([PrinterMib.sysName.appending(0)])
        stale.shift.withLock { $0 = (boots, time) }
        let got = try? await client.get([PrinterMib.sysName.appending(0)])
        #expect((got != nil) == inWindow, "boots \(boots), time \(time)")
        #expect(client.v3.withLock { $0.engine?.boots } == 3)
        #expect(client.v3.withLock { $0.engine?.timeNow ?? 0 } >= 4321)
    }

    @Test func theClockIsSetFromASignedReportOncePerRequest() async throws {
        let agent = try Self.agent()
        let client = try SnmpClient(transport: Restarting(agent), host: "192.0.2.14", version: .v3, login: Self.login(Self.right), retries: 0)
        await #expect(throws: SnmpTimeoutError.self) { try await client.get([PrinterMib.sysName.appending(0)]) }
        #expect(agent.v3Log.filter { $0 == "notInTimeWindows" }.count == 2) // resynchronized once, then no answer
    }

    @Test func aUsersKeysAreWorkedOutOncePerPassphraseNotPerEngine() {
        let counting = Counting()
        let passphrase = "pass-\(UUID().uuidString)" // one never stretched before (both keys from it: a 1 MiB hash is slow here)
        let user = SnmpV3User(name: "cache", authPassphrase: passphrase, privPassphrase: passphrase)
        let a = Usm.Keys.of(user, engineId: Self.engine, counting)
        let b = Usm.Keys.of(SnmpV3User(name: "another", authPassphrase: passphrase, privPassphrase: passphrase), engineId: Self.rfcEngine, counting)
        #expect(counting.stretched == 1) // repeated to 1 MiB and hashed once, whatever the user or engine
        #expect(a.auth != b.auth)
        let fresh = Usm.Keys.of(user, engineId: Self.engine, Self.crypto)
        #expect(a.auth == fresh.auth && a.priv == fresh.priv)
    }

    @Test func aV2cIdentityWithAV3LoginIsAskedOverV3NeverWithAnEmptyCommunity() async throws {
        let agent = try Self.agent()
        let identity = SnmpIdentity(version: .v2c, deviceIndex: 1, deviceDescription: nil, systemDescription: nil, systemName: nil, location: nil,
                                    serialNumber: nil, login: try Self.login(Self.right))
        let printer = SnmpPrinterClient(transport: agent, host: "192.0.2.14", identity: identity)
        let supplies = try? await printer.supplies()
        #expect(supplies?.count == 3)
        #expect(!agent.received.contains { $0.version != .v3 })
    }

    /// Unsigned reports of `spoof`'s counter from its engine, once set, for every request but a discovery: anyone on the
    /// network can send one.
    final class Spoofer: SnmpTransport {
        let agent: SnmpAgent
        let spoof = Mutex<(counter: Oid, engineId: [UInt8])?>(nil)

        init(_ agent: SnmpAgent) { self.agent = agent }

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
            guard let spoofed = spoof.withLock({ $0 }), let m = try? SnmpV3Message.decode(request), !m.engineId.isEmpty else {
                return try await agent.send(request, to: host, timeout: timeout)
            }
            let report = SnmpMessage(.v3, "", .report, requestId: 0, errorStatus: 0, errorIndex: 0,
                                     varBinds: [SnmpVarBind(spoofed.counter, .unsigned(Ber.counter32, 1))])
            return SnmpV3Message(messageId: m.messageId, flags: 0, engineId: spoofed.engineId, engineBoots: 9, engineTime: 99_999,
                                 userName: m.userName, contextEngineId: spoofed.engineId, pdu: report).encode()
        }
    }

    /// The agent's answers with their boots and time moved by `shift` (encrypted and signed again with the user's keys), as an
    /// old answer replayed would carry.
    final class Stale: SnmpTransport {
        let agent: SnmpAgent
        let keys: Usm.Keys
        let shift = Mutex<(boots: Int, time: Int)?>(nil)

        init(_ agent: SnmpAgent, keys: Usm.Keys) {
            self.agent = agent
            self.keys = keys
        }

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
            guard let reply = try await agent.send(request, to: host, timeout: timeout) else { return nil }
            guard let by = shift.withLock({ $0 }), let m = try? SnmpV3Message.decode(reply), m.isPrivate, let encrypted = m.encrypted else {
                return reply
            }
            let crypto = SnmpV3Tests.crypto
            let clear = Usm.aesCfb(key: keys.priv, iv: Usm.aesIv(boots: m.engineBoots, time: m.engineTime, salt: m.privParameters), encrypted,
                                   encrypt: false, crypto)
            let (boots, time) = (m.engineBoots + by.boots, m.engineTime + by.time)
            let again = Usm.aesCfb(key: keys.priv, iv: Usm.aesIv(boots: boots, time: time, salt: m.privParameters), clear, encrypt: true, crypto)
            return SnmpV3Message(messageId: m.messageId, flags: m.flags, engineId: m.engineId, engineBoots: boots, engineTime: time,
                                 userName: m.userName, privParameters: m.privParameters, encrypted: again).sign(keys.auth, crypto)
        }
    }

    /// An agent that restarts before every request it's sent (but a discovery): each comes outside its time window.
    final class Restarting: SnmpTransport {
        let agent: SnmpAgent

        init(_ agent: SnmpAgent) { self.agent = agent }

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
            if let m = try? SnmpV3Message.decode(request), !m.engineId.isEmpty { agent.engineBoots += 1 }
            return try await agent.send(request, to: host, timeout: timeout)
        }
    }

    /// The tests' crypto, counting the passphrases stretched to 1 MiB.
    final class Counting: SnmpCrypto {
        private let count = Mutex(0)
        var stretched: Int { count.withLock { $0 } }

        func sha256(_ data: [UInt8]) -> [UInt8] {
            if data.count >= 1_048_576 { count.withLock { $0 += 1 } }
            return SnmpV3Tests.crypto.sha256(data)
        }

        func hmacSha256(key: [UInt8], _ data: [UInt8]) -> [UInt8] { SnmpV3Tests.crypto.hmacSha256(key: key, data) }

        func aes128(key: [UInt8], block: [UInt8]) -> [UInt8] { SnmpV3Tests.crypto.aes128(key: key, block: block) }
    }

    /// Flips a byte in the encrypted answer, as someone on the way could.
    final class Tamper: SnmpTransport {
        let agent: SnmpAgent
        let on = Atomic(false)

        init(_ agent: SnmpAgent) { self.agent = agent }

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
            guard var reply = try await agent.send(request, to: host, timeout: timeout) else { return nil }
            if on.load(ordering: .relaxed) { reply[reply.count - 1] ^= 0x01 }
            return reply
        }
    }

    /// What a probe's `refused` was told.
    final class Told: Sendable {
        private let seen = Mutex<SnmpRefusal?>(nil)
        var reason: SnmpRefusal? { seen.withLock { $0 } }
        func set(_ reason: SnmpRefusal) { seen.withLock { $0 = reason } }
    }

    /// An agent of the test's own making: each request's reply from `answer`.
    struct Replier: SnmpTransport {
        let answer: @Sendable ([UInt8]) -> [UInt8]?

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? { answer(request) }
    }

    // MARK: the login

    @Test func aV3LoginRoundTripsAsItsKeptSecretAndShowsNothing() throws {
        let login = try SnmpLogin.forUser("ops:reader", "auth pass:1", "priv:pass 2")
        #expect(SnmpLogin.fromSecret(login.toSecret()) == login)
        #expect(!login.isDefault)
        let user = try #require(login.user)
        var dumped = ""
        dump(login, to: &dumped)
        for shown in [login.description, String(reflecting: login), dumped, user.description.replacingOccurrences(of: "ops:reader", with: "")] {
            #expect(!shown.contains("auth pass:1"))
            #expect(!shown.contains("priv:pass 2"))
        }
        #expect(!login.description.contains("ops:reader"))
    }

    @Test(arguments: [
        ("", "authpass1", "privpass1", "user name"),
        ("u", "short", "privpass1", "authentication passphrase"),
        ("u", "authpass1", "short", "privacy passphrase"),
        ("a-user-name-longer-than-32-chars!", "authpass1", "privpass1", "1 to 32"),
    ])
    func aV3LoginThatCantBeUsedIsRefusedWithWhy(_ name: String, _ auth: String, _ priv: String, _ why: String) {
        #expect { try SnmpLogin.forUser(name, auth, priv) } throws: { "\($0)".contains(why) }
    }
}

extension ProGated {
    /// SNMPv3 is a Pro feature: the gate (`Pro.allows`) decides whether a kept v3 user is used; a community always is.
    @Suite struct SnmpV3ProTests {
        init() {
            Pro.store = MemoryProStore()
            Pro.enforced = false
        }

        @Test func aKeptV3UserIsUsedOnlyWhileProAllowsIt() throws {
            defer { Pro.enforced = false }
            let logins: any SnmpLogins = MemorySnmpLogins()
            logins.save(try SnmpLogin.forUser("reader", "authpass1", "privpass1"), for: "v3")
            logins.save(try SnmpLogin.forCommunity("office"), for: "community")
            #expect(logins.usable("v3") != nil) // the gate is off while the apps launch

            Pro.enforced = true // no licence
            #expect(!Pro.allows(.snmpV3))
            #expect(logins.usable("v3") == nil)
            #expect(logins.usable("community")?.community == "office") // free
            #expect(logins.get("v3") != nil) // kept, for when a licence comes
        }
    }
}
