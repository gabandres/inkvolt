import Foundation
import Synchronization

/// A made-up SNMP agent over a fixed set of objects, answering Get, GetNext and GetBulk as RFC 1157 §4.1 and RFC 3416 §4.2
/// describe (v1: noSuchName errors; v2c: exception values; a Set is refused). Demo mode's SNMP-only printers and the tests
/// talk to it instead of the network. Requests with another community, or v2c to a v1-only agent, get no reply, like a
/// real agent.
public final class SnmpAgent: SnmpTransport {
    private let objects: [SnmpVarBind]
    public let community: String
    public let v1Only: Bool
    private let log = Mutex<(requests: Int, received: [SnmpMessage], v3: [String])>((0, [], []))

    /// The SNMPv3 user this agent knows (one; the agent answers nothing else); nil for a v1/v2c agent.
    public let v3User: SnmpV3User?
    /// The agent's snmpEngineID (RFC 3411).
    public let engineId: [UInt8]
    private let keys: Usm.Keys?
    private let crypto: (any SnmpCrypto)?
    private let engine: Mutex<(boots: Int, time: Int, salt: UInt64)>

    public init(_ objects: [SnmpVarBind], community: String = SnmpClient.defaultCommunity, v1Only: Bool = false) {
        self.objects = objects.sorted { $0.name < $1.name }
        self.community = community
        self.v1Only = v1Only
        v3User = nil
        engineId = []
        keys = nil
        crypto = nil
        engine = Mutex((0, 0, 0))
    }

    /// An SNMPv3-only agent (`respondV3`) for `user` at authPriv (SHA-256, AES-128), with engine `engineId`; v1 and v2c
    /// requests get no reply. Made without `crypto` (none passed, `Usm.crypto` unset) it answers nothing.
    public init(_ objects: [SnmpVarBind], user: SnmpV3User, engineId: [UInt8], engineBoots: Int = 1, engineTime: Int = 1000,
                crypto: (any SnmpCrypto)? = Usm.crypto) {
        self.objects = objects.sorted { $0.name < $1.name }
        community = SnmpClient.defaultCommunity
        v1Only = false
        v3User = user
        self.engineId = engineId
        self.crypto = crypto
        keys = crypto.map { Usm.Keys.of(user, engineId: engineId, $0) }
        engine = Mutex((engineBoots, engineTime, 0x5A17_0000_0000_0000))
    }

    /// Requests received (answered or not): lets tests check what was, and wasn't, asked.
    public var requests: Int { log.withLock { $0.requests } }

    /// The requests received, decoded (tests); an SNMPv3 request's PDU once decrypted.
    public var received: [SnmpMessage] { log.withLock { $0.received } }

    /// The v3 requests received and what each came to: "discovery", "answered" or the usmStats counter reported (tests).
    public var v3Log: [String] { log.withLock { $0.v3 } }

    /// snmpEngineBoots and snmpEngineTime (the tests move them, as a restarted or long-running agent would).
    public var engineBoots: Int {
        get { engine.withLock { $0.boots } }
        set { engine.withLock { $0.boots = newValue } }
    }

    public var engineTime: Int {
        get { engine.withLock { $0.time } }
        set { engine.withLock { $0.time = newValue } }
    }

    /// Objects written as net-snmp prints them (`snmpwalk -On`): `.1.3.6.1.2.1.1.1.0 = STRING: "Demo laser"`, with INTEGER,
    /// STRING, Hex-STRING, OID, Gauge32, Counter32, Timeticks and IpAddress. Blank lines and `#` comments are skipped.
    public static func parseWalk(_ text: String) throws -> [SnmpVarBind] {
        var list: [SnmpVarBind] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let bad = SnmpFormatError("Not an snmpwalk line: \(line)")
            guard let equals = line.firstIndex(of: "=") else { throw bad }
            let after = line[line.index(after: equals)...]
            guard let colon = after.firstIndex(of: ":"), let name = Oid(String(line[..<equals]).trimmingCharacters(in: .whitespaces)) else {
                throw bad
            }
            let type = after[..<colon].trimmingCharacters(in: .whitespaces)
            let value = after[after.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            list.append(SnmpVarBind(name, try parseValue(type, value, bad)))
        }
        return list
    }

    private static func parseValue(_ type: String, _ value: String, _ bad: SnmpFormatError) throws -> SnmpValue {
        switch type {
        case "INTEGER":
            guard let n = firstNumber(in: value, signed: true) else { throw bad }
            return .integer(n)
        case "STRING":
            if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
                return .string(String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\""))
            }
            return .string(value)
        case "Hex-STRING":
            let digits = Array(value.filter { $0 != " " })
            guard digits.count % 2 == 0 else { throw bad }
            var bytes: [UInt8] = []
            for i in stride(from: 0, to: digits.count, by: 2) {
                guard let b = UInt8(String(digits[i...i + 1]), radix: 16) else { throw bad }
                bytes.append(b)
            }
            return .octets(bytes)
        case "OID":
            guard let oid = Oid(value) else { throw bad }
            return .id(oid)
        case "Gauge32", "Counter32":
            guard let n = UInt64(value) else { throw bad }
            return .unsigned(type == "Gauge32" ? Ber.gauge32 : Ber.counter32, n)
        case "Timeticks":
            guard let n = firstNumber(in: value, signed: false) else { throw bad }
            return .unsigned(Ber.timeTicks, UInt64(n))
        case "IpAddress":
            let parts = value.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { throw bad }
            return .address(parts)
        default:
            throw SnmpFormatError("Unknown snmpwalk type \(type)")
        }
    }

    /// The first run of digits ("idle(3)" → 3, "(123456)" → 123456), with a minus sign right before it when `signed`.
    private static func firstNumber(in text: String, signed: Bool) -> Int64? {
        let chars = Array(text)
        guard let start = chars.firstIndex(where: \.isASCIIDigit) else { return nil }
        var end = start
        while end < chars.count && chars[end].isASCIIDigit { end += 1 }
        let negative = signed && start > 0 && chars[start - 1] == "-"
        return Int64((negative ? "-" : "") + String(chars[start..<end]))
    }

    /// The other way: objects as `parseWalk` reads them, one per line in OID order, each name once. A string that wouldn't
    /// read back byte for byte (invalid UTF-8, control characters, surrounding spaces, a trailing backslash) is written as
    /// Hex-STRING; a type the walk form has no word for is a comment line.
    public static func formatWalk(_ objects: [SnmpVarBind]) -> String {
        var seen = Set<Oid>()
        var lines = ""
        for o in objects.sorted(by: { $0.name < $1.name }) where seen.insert(o.name).inserted {
            let v = o.value
            let value: String?
            switch v.tag {
            case Ber.integer: value = "INTEGER: \(v.number)"
            case Ber.gauge32: value = "Gauge32: \(v.number)"
            case Ber.counter32: value = "Counter32: \(v.number)"
            case Ber.timeTicks: value = "Timeticks: (\(v.number))"
            case Ber.objectIdentifier: value = v.objectId.map { "OID: .\($0)" }
            case Ber.ipAddress: value = v.bytes?.count == 4 ? "IpAddress: \(v.bytes!.map(String.init).joined(separator: "."))" : nil
            case Ber.octetString:
                let bytes = v.bytes ?? []
                value = plainText(bytes).map { "STRING: \"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                    ?? "Hex-STRING: \(SnmpValue.hexString(bytes))"
            default: value = nil
            }
            lines += (value.map { ".\(o.name) = \($0)" } ?? "# .\(o.name) = \(v) (not kept)") + "\n"
        }
        return lines
    }

    /// Text that reads back byte for byte: valid UTF-8, printable, nothing `parseWalk`'s trimming or quoting would change.
    private static func plainText(_ bytes: [UInt8]) -> String? {
        guard let s = String(validating: bytes, as: UTF8.self), !s.isEmpty,
              !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              s.trimmingCharacters(in: .whitespaces) == s, !s.hasSuffix("\\") else { return nil }
        return s
    }

    public func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
        try Task.checkCancellation()
        return respond(request)
    }

    /// The reply to one request datagram; nil where a real agent stays silent (garbage, wrong community or version).
    public func respond(_ request: [UInt8]) -> [UInt8]? {
        if SnmpV3Message.isV3(request) {
            log.withLock { $0.requests += 1 }
            return respondV3(request)
        }
        let message = try? SnmpMessage.decode(request)
        log.withLock { log in
            log.requests += 1
            if let message { log.received.append(message) }
        }
        guard v3User == nil, let m = message, m.community == community, !(v1Only && m.version != .v1) else { return nil }
        return answer(m)?.encode()
    }

    /// The reply to one request PDU (any version: the v3 path hands its decrypted PDU here); nil where a real agent stays
    /// silent.
    private func answer(_ m: SnmpMessage) -> SnmpMessage? {
        let v1 = m.version == .v1
        switch m.type {
        case .getRequest:
            return perObject(m, v1) { name in
                if let found = objects.first(where: { $0.name == name }) { return found }
                let instanceMissing = objects.contains { $0.name.count == name.count && name.isUnder(parent($0.name)) }
                return SnmpVarBind(name, instanceMissing ? .noSuchInstance : .noSuchObject)
            }
        case .getNextRequest:
            return perObject(m, v1) { name in next(after: name) ?? SnmpVarBind(name, .endOfMibView) }
        case .getBulkRequest where !v1:
            return bulk(m)
        case .setRequest:
            // Read-only: RFC 3416 §4.2.5 notWritable for v2c, RFC 1157 §4.1.5 readOnly for v1 (never sent by Inkvolt Print).
            return reply(m, status: v1 ? 4 : 17, index: 1, m.varBinds)
        default:
            return nil
        }
    }

    private func parent(_ oid: Oid) -> Oid { Oid(arcs: Array(oid.arcs.dropLast())) ?? oid }

    /// The first object after `name` in lexicographic order (binary search).
    private func next(after name: Oid) -> SnmpVarBind? {
        var low = 0, high = objects.count
        while low < high {
            let mid = (low + high) / 2
            if objects[mid].name <= name { low = mid + 1 } else { high = mid }
        }
        return low < objects.count ? objects[low] : nil
    }

    private func perObject(_ m: SnmpMessage, _ v1: Bool, _ answer: (Oid) -> SnmpVarBind) -> SnmpMessage {
        let bindings = m.varBinds.map { answer($0.name) }
        if v1, let bad = bindings.firstIndex(where: \.value.isException) {
            // RFC 1157 §4.1.2: the request comes back, with the index.
            return reply(m, status: SnmpMessage.noSuchName, index: bad + 1, m.varBinds)
        }
        return reply(m, status: 0, index: 0, bindings)
    }

    private func bulk(_ m: SnmpMessage) -> SnmpMessage {
        let n = min(max(m.nonRepeaters, 0), m.varBinds.count)
        var bindings: [SnmpVarBind] = []
        for binding in m.varBinds.prefix(n) {
            bindings.append(next(after: binding.name) ?? SnmpVarBind(binding.name, .endOfMibView))
        }
        var at = m.varBinds.dropFirst(n).map(\.name)
        var repetition = 0
        while repetition < max(0, m.maxRepetitions) && !at.isEmpty {
            repetition += 1
            var allEnded = true
            for j in at.indices {
                guard let following = next(after: at[j]) else {
                    bindings.append(SnmpVarBind(at[j], .endOfMibView))
                    continue
                }
                bindings.append(following)
                at[j] = following.name
                allEnded = false
            }
            if allEnded { break } // RFC 3416 §4.2.3: the agent may stop once every variable reached the end of its MIB
        }
        return reply(m, status: 0, index: 0, bindings)
    }

    private func reply(_ m: SnmpMessage, status: Int, index: Int, _ bindings: [SnmpVarBind]) -> SnmpMessage {
        SnmpMessage(m.version, m.community, .response, requestId: m.requestId, errorStatus: status, errorIndex: index,
                    varBinds: bindings)
    }

    // MARK: SNMPv3 (RFC 3412 §7.2, RFC 3414 §3.2)

    /// A v3 request as an agent with one user at authPriv handles it: discovery (no engine ID) and an unknown engine get
    /// unknownEngineIDs with the engine's ID, boots and time; another user unknownUserNames; a lower security level
    /// unsupportedSecLevels; a wrong digest wrongDigests; a time outside 150 s of the engine's notInTimeWindows (signed); a
    /// scoped PDU that doesn't decrypt to one decryptionErrors. Reports other than notInTimeWindows go unsigned, as RFC 3414
    /// sends them. A request that reads is answered as v2c would be, signed and encrypted.
    private func respondV3(_ request: [UInt8]) -> [UInt8]? {
        guard let user = v3User, let keys, let crypto else { return nil } // a v1/v2c agent doesn't speak v3
        guard let m = try? SnmpV3Message.decode(request) else { return nil }
        let (boots, time) = engine.withLock { ($0.boots, $0.time) }
        if m.engineId.isEmpty || m.engineId != engineId {
            return report(m, Usm.unknownEngineIds, m.engineId.isEmpty ? "discovery" : "unknownEngineIDs", keys, crypto)
        }
        if m.userName != user.name { return report(m, Usm.unknownUserNames, "unknownUserNames", keys, crypto) }
        if !m.authenticated || !m.isPrivate { return report(m, Usm.unsupportedSecLevels, "unsupportedSecLevels", keys, crypto) }
        if !m.verify(request, keys.auth, crypto) { return report(m, Usm.wrongDigests, "wrongDigests", keys, crypto) }
        if m.engineBoots != boots || abs(m.engineTime - time) > Usm.timeWindow {
            return report(m, Usm.notInTimeWindows, "notInTimeWindows", keys, crypto, signed: true)
        }
        guard let encrypted = m.encrypted, m.privParameters.count == Usm.saltLength else {
            return report(m, Usm.decryptionErrors, "decryptionErrors", keys, crypto)
        }
        let iv = Usm.aesIv(boots: m.engineBoots, time: m.engineTime, salt: m.privParameters)
        guard let scoped = try? SnmpV3Message.decodeScoped(Usm.aesCfb(key: keys.priv, iv: iv, encrypted, encrypt: false, crypto)) else {
            return report(m, Usm.decryptionErrors, "decryptionErrors", keys, crypto)
        }
        log.withLock { $0.received.append(scoped.pdu) }
        guard let answer = answer(scoped.pdu) else { return nil }
        log.withLock { $0.v3.append("answered") }
        return wrap(m, answer, keys, crypto)
    }

    /// A report of `counter` (RFC 3414 §3.2), to a reportable request only.
    private func report(_ to: SnmpV3Message, _ counter: Oid, _ what: String, _ keys: Usm.Keys, _ crypto: any SnmpCrypto, signed: Bool = false)
        -> [UInt8]? {
        log.withLock { $0.v3.append(what) }
        guard to.reportable else { return nil }
        let (boots, time) = engine.withLock { ($0.boots, $0.time) }
        let pdu = SnmpMessage(.v3, "", .report, requestId: to.pdu?.requestId ?? 0, errorStatus: 0, errorIndex: 0,
                              varBinds: [SnmpVarBind(counter, .unsigned(Ber.counter32, 1))])
        let reply = SnmpV3Message(messageId: to.messageId, flags: signed ? SnmpV3Message.flagAuth : 0, engineId: engineId, engineBoots: boots,
                                  engineTime: time, userName: to.userName, contextEngineId: engineId, pdu: pdu)
        return signed ? reply.sign(keys.auth, crypto) : reply.encode()
    }

    /// A Response, encrypted with a fresh salt and signed.
    private func wrap(_ to: SnmpV3Message, _ answer: SnmpMessage, _ keys: Usm.Keys, _ crypto: any SnmpCrypto) -> [UInt8] {
        let (boots, time, salt) = engine.withLock { state -> (Int, Int, [UInt8]) in
            state.salt &+= 1
            return (state.boots, state.time, withUnsafeBytes(of: state.salt.bigEndian) { Array($0) })
        }
        let scoped = SnmpV3Message.encodeScoped(engineId, "", answer)
        let iv = Usm.aesIv(boots: boots, time: time, salt: salt)
        let reply = SnmpV3Message(messageId: to.messageId, flags: SnmpV3Message.flagAuth | SnmpV3Message.flagPriv, engineId: engineId,
                                  engineBoots: boots, engineTime: time, userName: to.userName, privParameters: salt,
                                  encrypted: Usm.aesCfb(key: keys.priv, iv: iv, scoped, encrypt: true, crypto))
        return reply.sign(keys.auth, crypto)
    }
}
