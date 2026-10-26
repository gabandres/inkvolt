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
    private let log = Mutex<(requests: Int, received: [SnmpMessage])>((0, []))

    public init(_ objects: [SnmpVarBind], community: String = SnmpClient.defaultCommunity, v1Only: Bool = false) {
        self.objects = objects.sorted { $0.name < $1.name }
        self.community = community
        self.v1Only = v1Only
    }

    /// Requests received (answered or not): lets tests check what was, and wasn't, asked.
    public var requests: Int { log.withLock { $0.requests } }

    /// The requests received, decoded (tests).
    public var received: [SnmpMessage] { log.withLock { $0.received } }

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

    public func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
        try Task.checkCancellation()
        return respond(request)
    }

    /// The reply to one request datagram; nil where a real agent stays silent (garbage, wrong community or version).
    public func respond(_ request: [UInt8]) -> [UInt8]? {
        let message = try? SnmpMessage.decode(request)
        log.withLock { log in
            log.requests += 1
            if let message { log.received.append(message) }
        }
        guard let m = message, m.community == community, !(v1Only && m.version != .v1) else { return nil }
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

    private func perObject(_ m: SnmpMessage, _ v1: Bool, _ answer: (Oid) -> SnmpVarBind) -> [UInt8] {
        let bindings = m.varBinds.map { answer($0.name) }
        if v1, let bad = bindings.firstIndex(where: \.value.isException) {
            // RFC 1157 §4.1.2: the request comes back, with the index.
            return reply(m, status: SnmpMessage.noSuchName, index: bad + 1, m.varBinds)
        }
        return reply(m, status: 0, index: 0, bindings)
    }

    private func bulk(_ m: SnmpMessage) -> [UInt8] {
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

    private func reply(_ m: SnmpMessage, status: Int, index: Int, _ bindings: [SnmpVarBind]) -> [UInt8] {
        SnmpMessage(m.version, m.community, .response, requestId: m.requestId, errorStatus: status, errorIndex: index,
                    varBinds: bindings).encode()
    }
}
