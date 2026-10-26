/// A JSON value as a device sent it, read without Foundation's JSONSerialization: numbers keep their text (as .NET's
/// `GetRawText`), booleans stay booleans on every platform, and nesting deeper than `maxDepth` is refused.
public enum Json: Equatable, Sendable {
    case object([String: Json])
    case array([Json])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static let maxDepth = 64

    /// Nil for anything that isn't one JSON value (garbage, an HTML page, trailing text).
    public static func parse(_ text: String?) -> Json? {
        guard let text else { return nil }
        var reader = Reader(Array(text.utf8))
        guard let value = reader.value(depth: 0) else { return nil }
        reader.skipSpace()
        return reader.atEnd ? value : nil
    }

    public subscript(key: String) -> Json? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var objectValue: [String: Json]? { if case .object(let o) = self { o } else { nil } }
    public var arrayValue: [Json]? { if case .array(let a) = self { a } else { nil } }

    private struct Reader {
        let b: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { b = bytes }

        var atEnd: Bool { i >= b.count }

        mutating func skipSpace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func value(depth: Int) -> Json? {
            guard depth <= Json.maxDepth else { return nil }
            skipSpace()
            guard i < b.count else { return nil }
            switch b[i] {
            case UInt8(ascii: "{"): return object(depth)
            case UInt8(ascii: "["): return array(depth)
            case UInt8(ascii: "\""): return string().map(Json.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        private mutating func literal(_ word: String, _ value: Json) -> Json? {
            let w = Array(word.utf8)
            guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { return nil }
            i += w.count
            return value
        }

        private mutating func object(_ depth: Int) -> Json? {
            i += 1
            var members: [String: Json] = [:]
            skipSpace()
            if i < b.count, b[i] == UInt8(ascii: "}") {
                i += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let v = value(depth: depth + 1) else { return nil }
                if members[key] == nil { members[key] = v } // a repeated name keeps its first value
                skipSpace()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                return nil
            }
        }

        private mutating func array(_ depth: Int) -> Json? {
            i += 1
            var items: [Json] = []
            skipSpace()
            if i < b.count, b[i] == UInt8(ascii: "]") {
                i += 1
                return .array(items)
            }
            while true {
                guard let v = value(depth: depth + 1) else { return nil }
                items.append(v)
                skipSpace()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                return nil
            }
        }

        private mutating func string() -> String? {
            i += 1
            var out: [UInt8] = []
            while i < b.count {
                let c = b[i]
                i += 1
                switch c {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard i < b.count else { return nil }
                    let e = b[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let unit = hex4() else { return nil }
                        var scalar: UInt32 = UInt32(unit)
                        if (0xD800...0xDBFF).contains(unit), i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            guard let low = hex4() else { return nil }
                            scalar = (0xDC00...0xDFFF).contains(low) ? 0x10000 + (UInt32(unit) - 0xD800) << 10 + (UInt32(low) - 0xDC00) : 0xFFFD
                        }
                        out += Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8)
                    default:
                        return nil
                    }
                default:
                    if c < 0x20 { return nil }
                    out.append(c)
                }
            }
            return nil
        }

        private mutating func hex4() -> UInt16? {
            guard i + 4 <= b.count, let v = UInt16(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else { return nil }
            i += 4
            return v
        }

        private mutating func number() -> Json? {
            let start = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() else { return nil }
            if i < b.count, b[i] == UInt8(ascii: ".") {
                i += 1
                guard digits() else { return nil }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() else { return nil }
            }
            return .number(String(decoding: b[start..<i], as: UTF8.self))
        }

        private mutating func digits() -> Bool {
            let start = i
            while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
            return i > start
        }
    }
}
