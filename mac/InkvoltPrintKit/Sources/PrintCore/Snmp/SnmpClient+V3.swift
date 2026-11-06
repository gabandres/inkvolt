import Foundation

/// The agent's engine as discovered: its ID, boots and time (and when that was), and the user's keys localized to it.
struct V3Engine: Sendable {
    let id: [UInt8]
    let keys: Usm.Keys
    private(set) var boots: Int
    private var time: Int
    private var at: ContinuousClock.Instant

    init(id: [UInt8], boots: Int, time: Int, keys: Usm.Keys) {
        self.id = id
        self.keys = keys
        self.boots = boots
        self.time = time
        at = .now
    }

    /// The engine's time now, as this manager reckons it (RFC 3414 §2.3).
    var timeNow: Int {
        let passed = (ContinuousClock.now - at).components.seconds
        return Int(min(Int64(Int32.max), Int64(time) + max(0, passed)))
    }

    /// An authenticated reply's boots and time: taken when later than reckoned (RFC 3414 §3.2 step 7b).
    mutating func saw(boots: Int, time: Int) {
        if boots < self.boots || (boots == self.boots && time <= timeNow) { return }
        reset(boots: boots, time: time)
    }

    /// The engine's own values (an authenticated notInTimeWindow report).
    mutating func reset(boots: Int, time: Int) {
        self.boots = boots
        self.time = time
        at = .now
    }
}

/// What an SNMPv3 client keeps between requests: the engine, and the salt's counter (RFC 3826 §3.1.2.1: a different salt
/// for every message, from a random start).
struct V3State: Sendable {
    var engine: V3Engine?
    var salt = UInt64.random(in: 0...UInt64(Int64.max))
}

/// A transport that wants each answer a client reads (a recording): SNMPv3 replies are encrypted on the wire, so the client
/// hands over the PDU once checked and decrypted. Windows' `ISnmpObserver`.
public protocol SnmpObserver: Sendable {
    func observe(_ reply: SnmpMessage)
}

/// SNMPv3 for `SnmpClient` (RFC 3412, RFC 3414, RFC 3826, RFC 7860): authPriv only, read only. The Windows Core's
/// `SnmpClient.V3.cs`.
extension SnmpClient {
    /// One request over SNMPv3: the engine discovered first (once per client), the scoped PDU encrypted with AES-128 and the
    /// message signed with HMAC-SHA-256-192. An authenticated notInTimeWindow report sets the clock and sends again, an
    /// unknownEngineID report discovers again; any other report is the agent refusing the user or its keys.
    func sendV3(_ request: SnmpMessage) async throws -> SnmpMessage {
        guard let user, let crypto else { throw SnmpFormatError("SNMPv3: no cryptography to sign and encrypt with.") }
        var pdu = request
        pdu.community = ""
        for _ in 0..<3 {
            let engine: V3Engine
            if let known = v3.withLock({ $0.engine }) {
                engine = known
            } else {
                engine = try await discover(user, crypto)
                v3.withLock { $0.engine = engine }
            }
            let messageId = nextId()
            let salt = v3.withLock { state -> [UInt8] in
                state.salt &+= 1
                return withUnsafeBytes(of: state.salt.bigEndian) { Array($0) }
            }
            let (boots, time) = (engine.boots, engine.timeNow)
            let scoped = SnmpV3Message.encodeScoped(engine.id, "", pdu)
            let iv = Usm.aesIv(boots: boots, time: time, salt: salt)
            let flags = SnmpV3Message.flagAuth | SnmpV3Message.flagPriv | SnmpV3Message.flagReportable
            let message = SnmpV3Message(messageId: messageId, flags: flags, engineId: engine.id, engineBoots: boots, engineTime: time,
                                        userName: user.name, privParameters: salt,
                                        encrypted: Usm.aesCfb(key: engine.keys.priv, iv: iv, scoped, encrypt: true, crypto))
            let (reply, answer) = try await exchange(message.sign(engine.keys.auth, crypto), messageId: messageId, engine: engine, crypto)
            if answer.type == .response {
                if answer.requestId != pdu.requestId { continue } // signed, but not this request's answer: ask again
                v3.withLock { $0.engine?.saw(boots: reply.engineBoots, time: reply.engineTime) }
                return answer
            }
            let said = answer.varBinds.first?.name
            if said == Usm.notInTimeWindows && reply.authenticated {
                v3.withLock { $0.engine?.reset(boots: reply.engineBoots, time: reply.engineTime) }
            } else if said == Usm.unknownEngineIds {
                v3.withLock { $0.engine = nil }
            } else {
                throw SnmpAccessError(Self.refusal(said))
            }
        }
        throw SnmpTimeoutError(host: host) // its engine's clock couldn't be agreed on
    }

    private static func refusal(_ counter: Oid?) -> SnmpRefusal {
        if counter == Usm.unknownUserNames { return .unknownUser }
        if counter == Usm.wrongDigests { return .wrongAuthKey }
        if counter == Usm.decryptionErrors { return .wrongPrivKey }
        return .securityLevel
    }

    /// RFC 3414 §4: an empty request, neither signed nor encrypted; the agent reports its engine ID, boots and time.
    private func discover(_ user: SnmpV3User, _ crypto: any SnmpCrypto) async throws -> V3Engine {
        let messageId = nextId()
        let empty = SnmpMessage(.v3, "", .getRequest, requestId: nextId(), errorStatus: 0, errorIndex: 0, varBinds: [])
        let request = SnmpV3Message(messageId: messageId, flags: SnmpV3Message.flagReportable, contextEngineId: [], pdu: empty).encode()
        let (reply, _) = try await exchange(request, messageId: messageId, engine: nil, crypto)
        // RFC 3411's SnmpEngineID is 5 to 32 octets.
        guard (5...Usm.maxEngineId).contains(reply.engineId.count) else { throw SnmpFormatError("SNMPv3: the agent reported no usable engine ID.") }
        return V3Engine(id: reply.engineId, boots: reply.engineBoots, time: reply.engineTime,
                        keys: Usm.Keys.of(user, engineId: reply.engineId, crypto))
    }

    /// Sends a v3 request and waits for its reply (same msgID). A signed reply is read only with this engine's ID and the
    /// right digest, and decrypted with the user's key; an unsigned one only as a report (agents report errors unsigned).
    /// Anything else is no answer.
    private func exchange(_ request: [UInt8], messageId: Int, engine: V3Engine?, _ crypto: any SnmpCrypto) async throws
        -> (message: SnmpV3Message, pdu: SnmpMessage) {
        for _ in 0...retries {
            guard let bytes = try await transport.send(request, to: host, timeout: timeout) else { continue }
            guard let read = Self.read(bytes, messageId: messageId, engine: engine, crypto) else { continue }
            if read.pdu.type == .response, let observer = transport as? any SnmpObserver { observer.observe(read.pdu) }
            return read
        }
        throw SnmpTimeoutError(host: host)
    }

    /// One datagram as a reply to `messageId`, checked and decrypted; nil when it isn't one.
    private static func read(_ bytes: [UInt8], messageId: Int, engine: V3Engine?, _ crypto: any SnmpCrypto)
        -> (message: SnmpV3Message, pdu: SnmpMessage)? {
        guard let reply = try? SnmpV3Message.decode(bytes), reply.messageId == messageId else { return nil }
        if reply.authenticated {
            guard let engine, reply.engineId == engine.id, reply.verify(bytes, engine.keys.auth, crypto) else { return nil }
        }
        if reply.isPrivate && !reply.authenticated { return nil } // privacy without authentication isn't a USM level
        let pdu: SnmpMessage
        if reply.isPrivate {
            guard let engine, let encrypted = reply.encrypted, reply.privParameters.count == Usm.saltLength else { return nil }
            let iv = Usm.aesIv(boots: reply.engineBoots, time: reply.engineTime, salt: reply.privParameters)
            let clear = Usm.aesCfb(key: engine.keys.priv, iv: iv, encrypted, encrypt: false, crypto)
            guard let scoped = try? SnmpV3Message.decodeScoped(clear) else { return nil }
            pdu = scoped.pdu
        } else {
            guard let clear = reply.pdu else { return nil }
            pdu = clear
        }
        // An answer must be signed and private; a report may come in clear.
        if pdu.type == .response && (!reply.authenticated || !reply.isPrivate || engine == nil) { return nil }
        guard pdu.type == .response || pdu.type == .report else { return nil }
        return (reply, pdu)
    }
}
