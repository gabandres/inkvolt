import Foundation
import Synchronization

/// The agent's engine as discovered: its ID, boots and time (and when that was), and the user's keys localized to it.
struct V3Engine: Sendable {
    let id: [UInt8]
    let keys: Usm.Keys
    private(set) var boots: Int
    private var time: Int
    /// RFC 3414 §2.3's latestReceivedEngineTime.
    private var latest: Int
    private var at: ContinuousClock.Instant

    init(id: [UInt8], boots: Int, time: Int, keys: Usm.Keys) {
        self.id = id
        self.keys = keys
        self.boots = boots
        self.time = time
        latest = time
        at = .now
    }

    /// The engine's time now, as this manager reckons it (RFC 3414 §2.3).
    var timeNow: Int {
        let passed = (ContinuousClock.now - at).components.seconds
        return Int(min(Int64(Int32.max), Int64(time) + max(0, passed)))
    }

    /// RFC 3414 §3.2 step 7b: an authenticated message is outside the engine's time window when the engine's boots reached
    /// their end, its boots are behind, or with the same boots its time is more than 150 s behind the time reckoned (an old
    /// message sent again). Such a message is no answer, and moves nothing.
    func inWindow(boots: Int, time: Int) -> Bool {
        if self.boots >= Int(Int32.max) || boots < self.boots { return false }
        return boots > self.boots || time >= timeNow - Usm.timeWindow
    }

    /// An authenticated message's boots and time, once in the window: taken when later than the latest received (RFC 3414
    /// §3.2 step 7b).
    mutating func saw(boots: Int, time: Int) {
        guard boots > self.boots || (boots == self.boots && time > latest) else { return }
        reset(boots: boots, time: time)
    }

    /// The engine's own values (an authenticated notInTimeWindow report).
    mutating func reset(boots: Int, time: Int) {
        self.boots = boots
        self.time = time
        latest = time
        at = .now
    }
}

/// What an SNMPv3 client keeps between requests: the engine, and the salt's counter (RFC 3826 §3.1.2.1: a different salt
/// for every message, from a random start).
struct V3State: Sendable {
    var engine: V3Engine?
    var salt = UInt64.random(in: 0...UInt64(Int64.max))
}

/// One SNMPv3 user's dealings with one agent: the engine as discovered (its keys localized to it) and the salt's counter,
/// shared by the clients of a printer: the probe's discovery serves the reader and every identity check after it
/// (`SnmpIdentity.session`). Nothing in it is shown: its description and mirror name no key.
public final class SnmpV3Session: Sendable, CustomStringConvertible, CustomReflectable {
    /// The user it was made for: a client with another user (a login changed) starts a session of its own.
    let user: SnmpV3User?
    private let state = Mutex(V3State())

    init(user: SnmpV3User?) { self.user = user }

    func withLock<R: Sendable>(_ body: (inout V3State) -> R) -> R { state.withLock { body(&$0) } }

    public var description: String { "SNMPv3 session" }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A transport that wants each answer a client reads (a recording): SNMPv3 replies are encrypted on the wire, so the client
/// hands over the PDU once checked and decrypted. Windows' `ISnmpObserver`.
public protocol SnmpObserver: Sendable {
    func observe(_ reply: SnmpMessage)
}

/// SNMPv3 for `SnmpClient` (RFC 3412, RFC 3414, RFC 3826, RFC 7860): authPriv only, read only. The Windows Core's
/// `SnmpClient.V3.cs`.
extension SnmpClient {
    /// One request over SNMPv3: the engine discovered first (once per session), the scoped PDU encrypted with AES-128 and the
    /// message signed with HMAC-SHA-256-192. A signed notInTimeWindow report sets the clock and sends again (once); a refusal
    /// from the engine is an `SnmpAccessError` saying which part; reports RFC 3414 doesn't let a manager act on are no
    /// answer (`actedOn`).
    func sendV3(_ request: SnmpMessage) async throws -> SnmpMessage {
        guard let user, let crypto else { throw SnmpFormatError("SNMPv3: no cryptography to sign and encrypt with.") }
        var pdu = request
        pdu.community = ""
        var resynchronized = false
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
                v3.withLock { $0.engine?.saw(boots: reply.engineBoots, time: reply.engineTime) } // in its window (read)
                return answer
            }
            let said = answer.varBinds.first?.name
            guard said == Usm.notInTimeWindows else { throw SnmpAccessError(Self.refusal(said)) }
            // Signed (read lets no other through): the engine's own clock, taken once a request; again, it's no answer.
            if resynchronized { break }
            resynchronized = true
            v3.withLock { $0.engine?.reset(boots: reply.engineBoots, time: reply.engineTime) }
        }
        throw SnmpTimeoutError(host: host) // its engine's clock couldn't be agreed on
    }

    /// The usmStats counters an agent reports for a request it refuses (RFC 3414 §3.2), and what each says is wrong.
    private static let refusals: [(counter: Oid, reason: SnmpRefusal)] = [
        (Usm.unknownUserNames, .unknownUser), (Usm.wrongDigests, .wrongAuthKey), (Usm.decryptionErrors, .wrongPrivKey),
        (Usm.unsupportedSecLevels, .securityLevel),
    ]

    private static func refusal(_ counter: Oid?) -> SnmpRefusal {
        refusals.first { $0.counter == counter }?.reason ?? .securityLevel
    }

    /// A report this manager acts on (RFC 3414 §3.2, §4): before the engine is known, only discovery's unknownEngineID
    /// (unsigned: there are no keys yet); after, a notInTimeWindow only signed (the clock is set from it), or a refusal from
    /// the engine discovered, signed or not (an agent can't sign for a user or key it refuses). Any other report could come
    /// from anyone on the network: no answer.
    private static func actedOn(_ reply: SnmpV3Message, _ counter: Oid?, _ engine: V3Engine?) -> Bool {
        guard let engine else { return counter == Usm.unknownEngineIds && !reply.authenticated }
        if counter == Usm.notInTimeWindows { return reply.authenticated }
        return reply.engineId == engine.id && refusals.contains { $0.counter == counter }
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
    /// right digest, in the engine's time window, and decrypted with the user's key; an unsigned one only as a report that
    /// RFC 3414 lets a manager act on (agents report errors unsigned). Anything else is no answer.
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
        // An answer must be signed and private; a report may come in clear, if it's one RFC 3414 lets a manager act on.
        if pdu.type == .response && (!reply.authenticated || !reply.isPrivate || engine == nil) { return nil }
        let counter = pdu.varBinds.first?.name
        if pdu.type == .report && !actedOn(reply, counter, engine) { return nil }
        guard pdu.type == .response || pdu.type == .report else { return nil }
        // Signed but outside the engine's time window (an old message sent again): no answer. A notInTimeWindow report is
        // the engine telling its own clock.
        let resync = pdu.type == .report && counter == Usm.notInTimeWindows
        if reply.authenticated && !resync, let engine, !engine.inWindow(boots: reply.engineBoots, time: reply.engineTime) { return nil }
        return (reply, pdu)
    }
}
