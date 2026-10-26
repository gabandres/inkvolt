/// A reply that isn't the SNMP it should be: malformed BER, another version or PDU, a value out of range.
public struct SnmpFormatError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// The part of BER (ITU-T X.690) that SNMP uses (RFC 1157 §4, RFC 3417 §8): one-byte tags, definite lengths, INTEGER,
/// OCTET STRING, NULL, OBJECT IDENTIFIER, SEQUENCE and the SNMP application types. Encoding is the shortest form (as DER,
/// which every agent accepts); decoding takes any definite length and rejects everything else (indefinite lengths,
/// multi-byte tags, values running past their container) with an `SnmpFormatError`: replies come from the network.
enum Ber {
    static let integer: UInt8 = 0x02, octetString: UInt8 = 0x04, null: UInt8 = 0x05, objectIdentifier: UInt8 = 0x06, sequence: UInt8 = 0x30

    /// RFC 2578 §7.1 application types (RFC 3416 §3): IpAddress, Counter32, Gauge32/Unsigned32, TimeTicks, Opaque, Counter64.
    static let ipAddress: UInt8 = 0x40, counter32: UInt8 = 0x41, gauge32: UInt8 = 0x42, timeTicks: UInt8 = 0x43, opaque: UInt8 = 0x44,
        counter64: UInt8 = 0x46

    /// RFC 3416 §3 VarBind exceptions in SNMPv2 responses: context-specific, primitive, empty.
    static let noSuchObject: UInt8 = 0x80, noSuchInstance: UInt8 = 0x81, endOfMibView: UInt8 = 0x82

    // MARK: Encode

    /// Tag, length, content (X.690 §8.1).
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }

    /// A constructed value: its parts one after the other.
    static func constructed(_ tag: UInt8, _ parts: [UInt8]...) -> [UInt8] { constructed(tag, parts: parts) }

    static func constructed(_ tag: UInt8, parts: [[UInt8]]) -> [UInt8] { tlv(tag, parts.flatMap { $0 }) }

    /// X.690 §8.1.3: short form below 128, else 0x80 + the number of length bytes, then the length big-endian.
    static func length(_ length: Int) -> [UInt8] {
        precondition(length >= 0)
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var rest = length
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// X.690 §8.3: two's complement, big-endian, in as few bytes as keep the sign.
    static func integerContent(_ value: Int64) -> [UInt8] {
        let b = withUnsafeBytes(of: value.bigEndian) { Array($0) }
        var i = 0
        while i < 7 && ((b[i] == 0x00 && b[i + 1] & 0x80 == 0) || (b[i] == 0xFF && b[i + 1] & 0x80 != 0)) { i += 1 }
        return Array(b[i...])
    }

    /// An unsigned value (Counter32, Gauge32, TimeTicks, Counter64) is a non-negative INTEGER: a leading zero when the top
    /// bit is set.
    static func unsignedContent(_ value: UInt64) -> [UInt8] {
        let b = [0] + withUnsafeBytes(of: value.bigEndian) { Array($0) }
        var i = 0
        while i < 8 && b[i] == 0 && b[i + 1] & 0x80 == 0 { i += 1 }
        return Array(b[i...])
    }

    static func integer32(_ value: Int64) -> [UInt8] { tlv(integer, integerContent(value)) }

    static func octets(_ value: [UInt8]) -> [UInt8] { tlv(octetString, value) }

    /// X.690 §8.19: the first two arcs as one subidentifier (40 × first + second), each subidentifier in base 128, high bit
    /// on all but its last byte.
    static func objectId(_ oid: Oid) -> [UInt8] {
        var content: [UInt8] = []
        addSubidentifier(&content, 40 * UInt64(oid.arcs[0]) + UInt64(oid.arcs[1]))
        for arc in oid.arcs.dropFirst(2) { addSubidentifier(&content, UInt64(arc)) }
        return tlv(objectIdentifier, content)
    }

    private static func addSubidentifier(_ content: inout [UInt8], _ value: UInt64) {
        var groups: [UInt8] = []
        var rest = value
        repeat {
            groups.append(UInt8(rest & 0x7F))
            rest >>= 7
        } while rest != 0
        for i in stride(from: groups.count - 1, through: 0, by: -1) { content.append(groups[i] | (i > 0 ? 0x80 : 0)) }
    }

    // MARK: Decode

    /// Reads TLVs one after the other from part of a buffer.
    struct Reader {
        let data: [UInt8]
        private var position: Int
        private let end: Int

        init(_ data: [UInt8], start: Int = 0, end: Int? = nil) {
            self.data = data
            position = start
            self.end = end ?? data.count
        }

        var hasMore: Bool { position < end }

        /// The next TLV: its tag and where its content is. Moves past it.
        mutating func next() throws -> (tag: UInt8, start: Int, length: Int) {
            guard position < end else { throw SnmpFormatError("BER: value expected, end of data.") }
            let tag = data[position]
            position += 1
            if tag & 0x1F == 0x1F { throw SnmpFormatError("BER: multi-byte tags aren't used by SNMP.") }
            guard position < end else { throw SnmpFormatError("BER: length missing.") }
            var length = Int(data[position])
            position += 1
            if length == 0x80 { throw SnmpFormatError("BER: indefinite lengths aren't allowed in SNMP.") }
            if length > 0x80 {
                let count = length & 0x7F
                if count > 4 || position + count > end { throw SnmpFormatError("BER: length too long.") }
                var long: Int64 = 0
                for _ in 0..<count {
                    long = (long << 8) | Int64(data[position])
                    position += 1
                }
                if long > Int64(Int32.max) { throw SnmpFormatError("BER: length too long.") }
                length = Int(long)
            }
            if length > end - position { throw SnmpFormatError("BER: value runs past its container.") }
            let start = position
            position += length
            return (tag, start, length)
        }

        /// The next TLV, which must have `tag`: its content as a reader.
        mutating func enter(_ tag: UInt8) throws -> Reader {
            let (t, s, l) = try next()
            if t != tag { throw SnmpFormatError("BER: tag \(hex(tag)) expected, \(hex(t)) found.") }
            return Reader(data, start: s, end: s + l)
        }

        mutating func readInteger() throws -> Int64 {
            let (t, s, l) = try next()
            if t != Ber.integer { throw SnmpFormatError("BER: INTEGER expected, tag \(hex(t)) found.") }
            return try Ber.signedValue(content(s, l))
        }

        mutating func readOctets() throws -> [UInt8] {
            let (t, s, l) = try next()
            if t != Ber.octetString { throw SnmpFormatError("BER: OCTET STRING expected, tag \(hex(t)) found.") }
            return content(s, l)
        }

        mutating func readObjectId() throws -> Oid {
            let (t, s, l) = try next()
            if t != Ber.objectIdentifier { throw SnmpFormatError("BER: OBJECT IDENTIFIER expected, tag \(hex(t)) found.") }
            return try Ber.objectIdValue(content(s, l))
        }

        func content(_ start: Int, _ length: Int) -> [UInt8] { Array(data[start..<start + length]) }
    }

    /// An INTEGER's content: 1 to 8 bytes, two's complement.
    static func signedValue(_ content: [UInt8]) throws -> Int64 {
        guard (1...8).contains(content.count) else { throw SnmpFormatError("BER: INTEGER of 1 to 8 bytes expected.") }
        var value = Int64(Int8(bitPattern: content[0]))
        for b in content.dropFirst() { value = (value << 8) | Int64(b) }
        return value
    }

    /// An unsigned type's content: up to 8 value bytes, plus a leading zero byte when the top bit is set.
    static func unsignedValue(_ content: [UInt8]) throws -> UInt64 {
        var bytes = content[...]
        if bytes.count == 9 && bytes.first == 0 { bytes = bytes.dropFirst() }
        guard (1...8).contains(bytes.count) else { throw SnmpFormatError("BER: unsigned value of 1 to 8 bytes expected.") }
        // A top bit set without the leading zero is a negative INTEGER in strict BER, but some agents send a Counter32 that
        // way: read as unsigned, as other managers do.
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func objectIdValue(_ content: [UInt8]) throws -> Oid {
        if content.isEmpty { throw SnmpFormatError("BER: empty OBJECT IDENTIFIER.") }
        var subidentifiers: [UInt64] = []
        var value: UInt64 = 0
        var bytes = 0
        for b in content {
            if bytes == 0 && b == 0x80 { throw SnmpFormatError("BER: OBJECT IDENTIFIER subidentifier with a leading 0x80.") }
            value = (value << 7) | UInt64(b & 0x7F)
            bytes += 1
            if bytes > 5 { throw SnmpFormatError("BER: OBJECT IDENTIFIER arc too large.") }
            if b & 0x80 != 0 { continue }
            subidentifiers.append(value)
            value = 0
            bytes = 0
        }
        if bytes != 0 { throw SnmpFormatError("BER: OBJECT IDENTIFIER ends inside a subidentifier.") }
        let tooLarge = SnmpFormatError("BER: OBJECT IDENTIFIER arc too large.")
        let first = subidentifiers[0]
        var arcs: [UInt32]
        if first < 40 {
            arcs = [0, UInt32(first)]
        } else if first < 80 {
            arcs = [1, UInt32(first - 40)]
        } else {
            guard first - 80 <= UInt64(UInt32.max) else { throw tooLarge }
            arcs = [2, UInt32(first - 80)]
        }
        for s in subidentifiers.dropFirst() {
            guard s <= UInt64(UInt32.max) else { throw tooLarge }
            arcs.append(UInt32(s))
        }
        guard let oid = Oid(arcs: arcs) else { throw SnmpFormatError("BER: not an object identifier.") }
        return oid
    }

    static func hex(_ byte: UInt8) -> String {
        let digits = String(byte, radix: 16, uppercase: true)
        return "0x" + (digits.count == 1 ? "0" + digits : digits)
    }
}
