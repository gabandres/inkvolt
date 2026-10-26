import Foundation

/// SNMP message versions Inkvolt Print speaks: v1 (RFC 1157) and community-based v2c (RFC 1901). Never v3.
public enum SnmpVersion: Int, Sendable {
    case v1 = 0
    case v2c = 1
}

/// PDU tags (RFC 1157 §4.1, RFC 3416 §3). Inkvolt Print sends only Get, GetNext and GetBulk: never Set.
public enum SnmpPduType: UInt8, Sendable {
    case getRequest = 0xA0
    case getNextRequest = 0xA1
    case response = 0xA2
    case setRequest = 0xA3
    case getBulkRequest = 0xA5
    case informRequest = 0xA6
    case trapV2 = 0xA7
    case report = 0xA8
}

/// One value in a variable binding: a number, octets, an OID, NULL or (SNMPv2) an exception.
public struct SnmpValue: Equatable, Sendable, CustomStringConvertible {
    /// The BER tag (INTEGER 0x02, OCTET STRING 0x04, Gauge32 0x42…).
    public let tag: UInt8

    /// INTEGER, Counter32, Gauge32, TimeTicks, Counter64 (a Counter64 above 2^63 wraps; nothing here reads one).
    public let number: Int64

    /// OCTET STRING, IpAddress, Opaque, and the content of a type Inkvolt Print doesn't know.
    public let bytes: [UInt8]?

    public let objectId: Oid?

    private init(tag: UInt8, number: Int64 = 0, bytes: [UInt8]? = nil, objectId: Oid? = nil) {
        self.tag = tag
        self.number = number
        self.bytes = bytes
        self.objectId = objectId
    }

    public var isNumber: Bool { [Ber.integer, Ber.counter32, Ber.gauge32, Ber.timeTicks, Ber.counter64].contains(tag) }

    /// noSuchObject, noSuchInstance or endOfMibView (SNMPv2), or the placeholder for a v1 noSuchName.
    public var isException: Bool { [Ber.noSuchObject, Ber.noSuchInstance, Ber.endOfMibView].contains(tag) }

    public static let null = SnmpValue(tag: Ber.null)
    public static let noSuchObject = SnmpValue(tag: Ber.noSuchObject)
    public static let noSuchInstance = SnmpValue(tag: Ber.noSuchInstance)
    public static let endOfMibView = SnmpValue(tag: Ber.endOfMibView)

    public static func integer(_ value: Int64) -> SnmpValue { SnmpValue(tag: Ber.integer, number: value) }
    public static func octets(_ value: [UInt8]) -> SnmpValue { SnmpValue(tag: Ber.octetString, bytes: value) }
    public static func string(_ value: String) -> SnmpValue { SnmpValue(tag: Ber.octetString, bytes: Array(value.utf8)) }
    public static func id(_ value: Oid) -> SnmpValue { SnmpValue(tag: Ber.objectIdentifier, objectId: value) }

    /// Counter32, Gauge32, TimeTicks or Counter64.
    public static func unsigned(_ tag: UInt8, _ value: UInt64) -> SnmpValue {
        precondition([Ber.counter32, Ber.gauge32, Ber.timeTicks, Ber.counter64].contains(tag), "Not an unsigned type.")
        return SnmpValue(tag: tag, number: Int64(bitPattern: value))
    }

    public static func address(_ ipv4: [UInt8]) -> SnmpValue {
        precondition(ipv4.count == 4, "IpAddress is 4 bytes.")
        return SnmpValue(tag: Ber.ipAddress, bytes: ipv4)
    }

    /// The number when it fits 32 bits; nil for other types.
    public var int: Int? { isNumber && number >= Int64(Int32.min) && number <= Int64(Int32.max) ? Int(number) : nil }

    /// An OCTET STRING as text: UTF-8 when it is valid UTF-8, else Latin-1 (older printers); NULs and surrounding spaces
    /// trimmed (some printers pad descriptions with NULs). Nil for other types and for empty text.
    public var text: String? {
        guard tag == Ber.octetString, let bytes else { return nil }
        let decoded = String(validating: bytes, as: UTF8.self) ?? String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        var scalars = String.UnicodeScalarView()
        for scalar in decoded.unicodeScalars {
            if scalar.value == 0 { break }
            if !SnmpValue.isControl(scalar) || scalar == "\n" { scalars.append(scalar) }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// As .NET's char.IsControl: C0, DEL and C1.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) }

    func encode() -> [UInt8] {
        switch tag {
        case Ber.integer: return Ber.tlv(tag, Ber.integerContent(number))
        case Ber.counter32, Ber.gauge32, Ber.timeTicks, Ber.counter64: return Ber.tlv(tag, Ber.unsignedContent(UInt64(bitPattern: number)))
        case Ber.objectIdentifier: return Ber.objectId(objectId!)
        default:
            // OCTET STRING, IpAddress, Opaque, and a type kept as it came (see decode). NULL and the SNMPv2 exceptions carry
            // no content.
            if let bytes { return Ber.tlv(tag, bytes) }
            return [tag, 0x00]
        }
    }

    static func decode(tag: UInt8, content: [UInt8]) throws -> SnmpValue {
        switch tag {
        case Ber.integer: return SnmpValue(tag: tag, number: try Ber.signedValue(content))
        case Ber.counter32, Ber.gauge32, Ber.timeTicks, Ber.counter64:
            return SnmpValue(tag: tag, number: Int64(bitPattern: try Ber.unsignedValue(content)))
        case Ber.octetString, Ber.ipAddress, Ber.opaque: return SnmpValue(tag: tag, bytes: content)
        case Ber.objectIdentifier: return SnmpValue(tag: tag, objectId: try Ber.objectIdValue(content))
        case Ber.noSuchObject where content.isEmpty: return .noSuchObject
        case Ber.noSuchInstance where content.isEmpty: return .noSuchInstance
        case Ber.endOfMibView where content.isEmpty: return .endOfMibView
        case Ber.null where content.isEmpty: return .null
        default:
            // Another type (NsapAddress 0x45, UInteger32 0x47 of RFC 1442's SMI, a vendor's): kept as opaque bytes, so one
            // odd value a GetBulk ran into doesn't lose the whole reply.
            return SnmpValue(tag: tag, bytes: content)
        }
    }

    /// As net-snmp prints values ("INTEGER: 3", "STRING: \"Ready\""), for logs.
    public var description: String {
        switch tag {
        case Ber.integer: return "INTEGER: \(number)"
        case Ber.counter32: return "Counter32: \(number)"
        case Ber.gauge32: return "Gauge32: \(number)"
        case Ber.timeTicks: return "Timeticks: (\(number))"
        case Ber.counter64: return "Counter64: \(number)"
        case Ber.octetString:
            if let t = text, !t.unicodeScalars.contains(where: SnmpValue.isControl) { return "STRING: \"\(t)\"" }
            return "Hex-STRING: \(SnmpValue.hexString(bytes ?? []))"
        case Ber.ipAddress: return "IpAddress: \((bytes ?? []).map(String.init).joined(separator: "."))"
        case Ber.objectIdentifier: return "OID: .\(objectId!)"
        case Ber.noSuchObject: return "No Such Object"
        case Ber.noSuchInstance: return "No Such Instance"
        case Ber.endOfMibView: return "End of MIB"
        case Ber.null: return "NULL"
        default: return "\(Ber.hex(tag)): \(SnmpValue.hexString(bytes ?? []))"
        }
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { let d = String($0, radix: 16, uppercase: true); return d.count == 1 ? "0" + d : d }.joined()
    }

    public static func == (lhs: SnmpValue, rhs: SnmpValue) -> Bool {
        lhs.tag == rhs.tag && lhs.number == rhs.number && lhs.objectId == rhs.objectId && (lhs.bytes ?? []) == (rhs.bytes ?? [])
    }
}

/// A variable binding: an object's name and its value (NULL in requests).
public struct SnmpVarBind: Equatable, Sendable, CustomStringConvertible {
    public var name: Oid
    public var value: SnmpValue

    public init(_ name: Oid, _ value: SnmpValue) {
        self.name = name
        self.value = value
    }

    public var description: String { ".\(name) = \(value)" }
}

/// An SNMPv1/v2c message (RFC 1157 §4, RFC 1901 §3): version, community, and one PDU. A GetBulk PDU (RFC 3416 §3) has the
/// same shape, with non-repeaters in place of error-status and max-repetitions in place of error-index.
public struct SnmpMessage: Equatable, Sendable {
    /// RFC 3416 §3 error-status values the client tells apart.
    public static let noError = 0, tooBig = 1, noSuchName = 2, genErr = 5

    public var version: SnmpVersion
    public var community: String
    public var type: SnmpPduType
    public var requestId: Int
    public var errorStatus: Int
    public var errorIndex: Int
    public var varBinds: [SnmpVarBind]

    public init(_ version: SnmpVersion, _ community: String, _ type: SnmpPduType, requestId: Int, errorStatus: Int, errorIndex: Int,
                varBinds: [SnmpVarBind]) {
        self.version = version
        self.community = community
        self.type = type
        self.requestId = requestId
        self.errorStatus = errorStatus
        self.errorIndex = errorIndex
        self.varBinds = varBinds
    }

    public var nonRepeaters: Int { errorStatus }
    public var maxRepetitions: Int { errorIndex }

    public func encode() -> [UInt8] {
        let bindings = varBinds.map { Ber.constructed(Ber.sequence, Ber.objectId($0.name), $0.value.encode()) }
        let pdu = Ber.constructed(type.rawValue, Ber.integer32(Int64(requestId)), Ber.integer32(Int64(errorStatus)),
                                  Ber.integer32(Int64(errorIndex)), Ber.constructed(Ber.sequence, parts: bindings))
        return Ber.constructed(Ber.sequence, Ber.integer32(Int64(version.rawValue)), Ber.octets(Array(community.utf8)), pdu)
    }

    /// A message from the network. `SnmpFormatError` for anything that isn't a v1/v2c message.
    public static func decode(_ data: [UInt8]) throws -> SnmpMessage {
        var outer = Ber.Reader(data)
        var message = try outer.enter(Ber.sequence)
        let versionNumber = try message.readInteger()
        guard let version = SnmpVersion(rawValue: Int(clamping: versionNumber)) else {
            throw SnmpFormatError("SNMP: version \(versionNumber) isn't v1 or v2c.")
        }
        let community = String(decoding: try message.readOctets(), as: UTF8.self)
        let (tag, start, length) = try message.next()
        guard let type = SnmpPduType(rawValue: tag) else { throw SnmpFormatError("SNMP: PDU type \(Ber.hex(tag)) isn't handled.") }
        var pdu = Ber.Reader(data, start: start, end: start + length)
        let requestId = try int32(pdu.readInteger())
        let errorStatus = try int32(pdu.readInteger())
        let errorIndex = try int32(pdu.readInteger())
        var list = try pdu.enter(Ber.sequence)
        var bindings: [SnmpVarBind] = []
        while list.hasMore {
            var binding = try list.enter(Ber.sequence)
            let name = try binding.readObjectId()
            let (valueTag, valueStart, valueLength) = try binding.next()
            bindings.append(SnmpVarBind(name, try SnmpValue.decode(tag: valueTag, content: binding.content(valueStart, valueLength))))
            if binding.hasMore { throw SnmpFormatError("SNMP: extra data in a variable binding.") }
        }
        return SnmpMessage(version, community, type, requestId: requestId, errorStatus: errorStatus, errorIndex: errorIndex, varBinds: bindings)
    }

    private static func int32(_ value: Int64) throws -> Int {
        guard value >= Int64(Int32.min) && value <= Int64(Int32.max) else { throw SnmpFormatError("SNMP: value out of range.") }
        return Int(value)
    }
}

/// The agent answered with an error-status (RFC 3416 §3) the client can't work around.
public struct SnmpErrorStatus: Error, CustomStringConvertible {
    public let status: Int

    /// The error-index: which object (from 1) the error is about; 0 when the agent didn't say.
    public let index: Int

    public var description: String { "SNMP error-status \(status) (index \(index))." }
}

/// No reply at all: the printer is off, or has no agent.
public struct SnmpTimeoutError: Error, CustomStringConvertible {
    public let host: String

    public var description: String { "No SNMP reply from \(host)." }
}
