import Foundation

/// One ASN.1 value read from BER or DER bytes (what .NET's `AsnReader` gives the Windows app): its tag, the whole
/// encoding and its contents. Indefinite lengths (BER, as some older signers write CMS) are read too; their contents are
/// the encodings of the values inside.
struct Der: Sendable {
    let tag: UInt8
    /// The whole encoding: tag, length and contents.
    let raw: [UInt8]
    let content: [UInt8]

    struct Malformed: Error {}

    var constructed: Bool { tag & 0x20 != 0 }
    /// The tag number of a context-specific tag ([n]), else nil.
    var context: Int? { tag & 0xC0 == 0x80 ? Int(tag & 0x1F) : nil }

    /// The first value in `bytes`, and where the next one starts.
    static func read(_ bytes: [UInt8], at start: Int = 0, depth: Int = 0) throws -> (Der, next: Int) {
        guard depth < 64, start + 2 <= bytes.count else { throw Malformed() }
        let tag = bytes[start]
        if tag & 0x1F == 0x1F { throw Malformed() } // high tag numbers aren't used by CMS or X.509
        var i = start + 1
        let first = bytes[i]
        i += 1
        if first == 0x80 {
            guard tag & 0x20 != 0 else { throw Malformed() }
            let from = i
            while true {
                guard i + 2 <= bytes.count else { throw Malformed() }
                if bytes[i] == 0 && bytes[i + 1] == 0 { break }
                i = try read(bytes, at: i, depth: depth + 1).next
            }
            return (Der(tag: tag, raw: Array(bytes[start..<i + 2]), content: Array(bytes[from..<i])), i + 2)
        }
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let n = Int(first & 0x7F)
            guard n <= 4, i + n <= bytes.count else { throw Malformed() }
            for _ in 0..<n {
                length = (length << 8) | Int(bytes[i])
                i += 1
            }
        }
        guard length <= bytes.count - i else { throw Malformed() }
        return (Der(tag: tag, raw: Array(bytes[start..<i + length]), content: Array(bytes[i..<i + length])), i + length)
    }

    /// The value `bytes` start with (bytes after it ignored: the zero padding after a signature).
    static func parse(_ bytes: [UInt8]) throws -> Der { try read(bytes).0 }

    /// The values inside a constructed one.
    func children() throws -> [Der] {
        var list: [Der] = []
        var i = 0
        while i < content.count {
            let (d, next) = try Der.read(content, at: i)
            list.append(d)
            i = next
        }
        return list
    }

    func child(_ index: Int) throws -> Der {
        let all = try children()
        guard index < all.count else { throw Malformed() }
        return all[index]
    }

    /// An OCTET STRING's bytes (a constructed BER one joined).
    func octets() throws -> [UInt8] {
        if !constructed { return content }
        return try children().flatMap { try $0.octets() }
    }

    /// An OBJECT IDENTIFIER in dotted form.
    func oid() throws -> String {
        guard tag == 0x06, !content.isEmpty else { throw Malformed() }
        var parts: [UInt64] = []
        var v: UInt64 = 0
        for b in content {
            guard v < (1 << 56) else { throw Malformed() }
            v = (v << 7) | UInt64(b & 0x7F)
            if b & 0x80 == 0 {
                parts.append(v)
                v = 0
            }
        }
        guard let first = parts.first else { throw Malformed() }
        let head = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80]
        return (head + parts.dropFirst()).map(String.init).joined(separator: ".")
    }

    /// A small INTEGER.
    func int() throws -> Int {
        guard tag == 0x02, !content.isEmpty, content.count <= 8 else { throw Malformed() }
        var v = Int(Int8(bitPattern: content[0]))
        for b in content.dropFirst() { v = (v << 8) | Int(b) }
        return v
    }

    /// A UTCTime or GeneralizedTime.
    func time() throws -> Date {
        guard let s = String(bytes: content, encoding: .ascii) else { throw Malformed() }
        var c = DateComponents()
        c.timeZone = TimeZone(identifier: "UTC")
        let digits = Array(s.prefix { $0.isNumber })
        func n(_ from: Int, _ count: Int) throws -> Int {
            guard from + count <= digits.count, let v = Int(String(digits[from..<from + count])) else { throw Malformed() }
            return v
        }
        var at: Int
        if tag == 0x17 {
            let yy = try n(0, 2)
            c.year = yy < 50 ? 2000 + yy : 1900 + yy
            at = 2
        } else if tag == 0x18 {
            c.year = try n(0, 4)
            at = 4
        } else { throw Malformed() }
        c.month = try n(at, 2)
        c.day = try n(at + 2, 2)
        c.hour = try n(at + 4, 2)
        c.minute = try n(at + 6, 2)
        c.second = digits.count >= at + 10 ? try n(at + 8, 2) : 0
        guard var date = Calendar(identifier: .gregorian).date(from: c) else { throw Malformed() }
        // A fraction of a second, and a "+hhmm" offset (rare in signatures).
        if let dot = s.firstIndex(of: "."), let frac = Double("0" + s[dot...].prefix { $0 == "." || $0.isNumber }) { date += frac }
        if let sign = s.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let off = s[s.index(after: sign)...].filter(\.isNumber)
            if off.count == 4, let h = Int(off.prefix(2)), let m = Int(off.suffix(2)) {
                date -= Double((h * 60 + m) * 60) * (s[sign] == "+" ? 1 : -1)
            }
        }
        return date
    }

    /// A string value (UTF8String, PrintableString, IA5String, BMPString, T61String).
    func string() -> String? {
        switch tag {
        case 0x0C, 0x13, 0x16, 0x14, 0x12, 0x1A: return String(bytes: content, encoding: .utf8) ?? String(bytes: content, encoding: .isoLatin1)
        case 0x1E:
            var units: [UInt16] = []
            var i = 0
            while i + 1 < content.count {
                units.append(UInt16(content[i]) << 8 | UInt16(content[i + 1]))
                i += 2
            }
            return String(utf16CodeUnits: units, count: units.count)
        default: return nil
        }
    }
}

/// DER encodings (what .NET's `AsnWriter` writes for the Windows app).
enum DerWriter {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func seq(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    /// A SET OF, its elements sorted as DER requires.
    static func setOf(_ items: [[UInt8]]) -> [UInt8] {
        tlv(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 })
    }
    /// [n] around `content` (constructed, or a primitive implicit tag).
    static func context(_ n: Int, _ content: [UInt8], constructed: Bool = true) -> [UInt8] {
        tlv(UInt8(0x80 | (constructed ? 0x20 : 0) | n), content)
    }

    static func int(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat {
            bytes.insert(UInt8(truncatingIfNeeded: x), at: 0)
            x >>= 8
        } while x != 0 && x != -1
        if v >= 0 && bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        if v < 0 && bytes[0] & 0x80 == 0 { bytes.insert(0xFF, at: 0) }
        return tlv(0x02, bytes)
    }

    /// A positive INTEGER from big-endian bytes (a serial number or a nonce).
    static func unsigned(_ bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.drop { $0 == 0 })
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return tlv(0x06, []) }
        var out: [UInt8] = []
        for v in [parts[0] * 40 + parts[1]] + parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(v & 0x7F)]
            var x = v >> 7
            while x > 0 {
                chunk.insert(UInt8(x & 0x7F) | 0x80, at: 0)
                x >>= 7
            }
            out += chunk
        }
        return tlv(0x06, out)
    }

    static func octets(_ b: [UInt8]) -> [UInt8] { tlv(0x04, b) }
    static func bits(_ b: [UInt8], unused: UInt8 = 0) -> [UInt8] { tlv(0x03, [unused] + b) }
    static let null: [UInt8] = [0x05, 0x00]
    static func bool(_ v: Bool) -> [UInt8] { [0x01, 0x01, v ? 0xFF : 0x00] }
    static func utf8(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    static func ia5(_ s: String) -> [UInt8] { tlv(0x16, Array(s.utf8)) }

    /// UTCTime until 2049, GeneralizedTime after (RFC 5280's rule).
    static func time(_ d: Date) -> [UInt8] {
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d).year ?? 2000
        return year >= 1950 && year < 2050 ? tlv(0x17, Array(stamp(d, "yyMMddHHmmss").utf8)) : generalized(d)
    }

    static func generalized(_ d: Date) -> [UInt8] { tlv(0x18, Array(stamp(d, "yyyyMMddHHmmss").utf8)) }

    private static func stamp(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: d) + "Z"
    }
}

/// The object identifiers signatures use.
enum Oids {
    static let data = "1.2.840.113549.1.7.1"
    static let signedData = "1.2.840.113549.1.7.2"
    static let tstInfo = "1.2.840.113549.1.9.16.1.4"
    static let contentType = "1.2.840.113549.1.9.3"
    static let messageDigest = "1.2.840.113549.1.9.4"
    static let signingTime = "1.2.840.113549.1.9.5"
    static let timestampToken = "1.2.840.113549.1.9.16.2.14"
    static let signingCertificateV2 = "1.2.840.113549.1.9.16.2.47"
    static let rsa = "1.2.840.113549.1.1.1"
    static let rsaPss = "1.2.840.113549.1.1.10"
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let p256 = "1.2.840.10045.3.1.7"
    static let p384 = "1.3.132.0.34"
    static let p521 = "1.3.132.0.35"
    static let commonName = "2.5.4.3"
    static let organization = "2.5.4.10"
    static let email = "1.2.840.113549.1.9.1"
    static let keyUsage = "2.5.29.15"
    static let extendedKeyUsage = "2.5.29.37"
    static let basicConstraints = "2.5.29.19"
    static let subjectKeyId = "2.5.29.14"
    static let subjectAltName = "2.5.29.17"
}
