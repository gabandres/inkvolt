import Foundation

enum CKind: Sendable { case number, name, string, array, dict, bool, null }

/// An operand of a content-stream operator, with where it sits in the stream (byte offsets, end exclusive).
struct CObj: Sendable {
    var kind: CKind
    var num = 0.0
    var isInt = false
    /// A name (without the slash, #xx decoded, each byte as one Latin-1 character) or a bool/null keyword.
    var name = ""
    /// A string's bytes (escapes and hex decoded).
    var bytes: [UInt8] = []
    var hex = false
    var items: [CObj] = []
    var entries: [(key: String, value: CObj)] = []
    var start = 0, end = 0

    init(_ kind: CKind, start: Int = 0) {
        self.kind = kind
        self.start = start
    }

    subscript(key: String) -> CObj? { entries.first { $0.key == key }?.value }
}

/// An operator with its operands. An inline image is one "BI" op spanning BI…EI (its dictionary in `operands`).
final class COp {
    var name = ""
    var operands: [CObj] = []
    /// Where the op starts (its first operand, else the operator) and ends (after the operator; after EI for an inline image).
    var start = 0, end = 0
    /// Inline image data (between ID and EI).
    var dataStart = 0, dataEnd = 0
    /// An inline image whose end couldn't be found for sure: never edited, and nothing after it is read.
    var broken = false

    func n(_ i: Int) -> Double { i < operands.count && operands[i].kind == .number ? operands[i].num : 0 }
}

/// Bytes as text, one Latin-1 character per byte (.NET's `Encoding.Latin1`).
func latin1String<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    var s = String()
    s.unicodeScalars.reserveCapacity(bytes.count)
    for b in bytes { s.unicodeScalars.append(Unicode.Scalar(b)) }
    return s
}

/// Text as Latin-1 bytes (characters past U+00FF become '?').
func latin1Bytes(_ s: String) -> [UInt8] { s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : 63 } }

/// Reads a PDF content stream into operators, keeping byte offsets so a single operator can be replaced without
/// rewriting (or misreading) the rest: strings with escapes, hex strings, names with #xx, arrays, dictionaries
/// (marked-content properties), comments, and inline images (BI … ID data EI), whose binary data is skipped by its
/// computed length when unfiltered, else by finding an EI that is followed by ordinary content (the Windows app's
/// `ContentLexer`). Malformed input never throws: a stray delimiter is skipped and an unterminated object ends at the end
/// of the data.
struct ContentLexer {
    private let b: [UInt8]
    private var p = 0

    private init(_ data: [UInt8]) { b = data }

    /// - Throws: `CancellationError` when `cancel` fires.
    static func parse(_ data: [UInt8], cancel: CancelToken?) throws -> [COp] {
        var lx = ContentLexer(data)
        var ops: [COp] = []
        var operands: [CObj] = []
        var n = 0
        while true {
            n += 1
            if n & 4095 == 0 { try cancel?.check() }
            lx.skipSpace()
            if lx.p >= data.count { break }
            let start = lx.p
            if let obj = lx.readObject() {
                operands.append(obj)
                if operands.count > 4096 { operands.removeFirst() } // junk: don't grow without bound
                continue
            }
            if lx.p == start {
                lx.p += 1 // a stray delimiter: skip it
                continue
            }
            let op = COp()
            op.name = latin1String(data[start..<lx.p])
            op.operands = operands
            op.start = operands.first?.start ?? start
            op.end = lx.p
            operands = []
            if op.name == "BI" { lx.inlineImage(op) }
            ops.append(op)
            if op.broken { break } // where the content goes on is unknown: stop rather than misread it
        }
        return ops
    }

    /// `parse` for content that is never cancelled.
    static func parse(_ data: [UInt8]) -> [COp] { (try? parse(data, cancel: nil)) ?? [] }

    static func isSpace(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    static func isDelim(_ c: UInt8) -> Bool {
        c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37
    }
    static func isRegular(_ c: UInt8) -> Bool { !isSpace(c) && !isDelim(c) }

    private mutating func skipSpace() {
        while p < b.count {
            let c = b[p]
            if Self.isSpace(c) {
                p += 1
            } else if c == 37 { // %
                while p < b.count && b[p] != 10 && b[p] != 13 { p += 1 }
            } else {
                break
            }
        }
    }

    /// An operand at the position, or nil with the position past an operator keyword (or unchanged at a stray delimiter).
    private mutating func readObject(_ depth: Int = 0) -> CObj? {
        let start = p
        let c = b[p]
        switch c {
        case 47: // /
            p += 1
            var name: [UInt8] = []
            while p < b.count && Self.isRegular(b[p]) {
                if b[p] == 35 && p + 2 < b.count && Self.isHex(b[p + 1]) && Self.isHex(b[p + 2]) { // #xx
                    name.append(UInt8(Self.hexVal(b[p + 1]) * 16 + Self.hexVal(b[p + 2])))
                    p += 3
                } else {
                    name.append(b[p])
                    p += 1
                }
            }
            var o = CObj(.name, start: start)
            o.name = latin1String(name)
            o.end = p
            return o
        case 40: // (
            return literalString(start)
        case 60 where p + 1 < b.count && b[p + 1] == 60: // <<
            p += 2
            var d = CObj(.dict, start: start)
            while true {
                skipSpace()
                if p >= b.count { break }
                if b[p] == 62 && p + 1 < b.count && b[p + 1] == 62 {
                    p += 2
                    break
                }
                let at = p
                let key = depth < 32 ? readObject(depth + 1) : nil
                guard let key else {
                    if p == at { p += 1 }
                    continue
                }
                skipSpace()
                if p >= b.count { break }
                let at2 = p
                let value = readObject(depth + 1)
                if value == nil && p == at2 { p += 1 }
                if key.kind == .name, let value { d.entries.append((key.name, value)) }
            }
            d.end = p
            return d
        case 60: // <hex>
            p += 1
            var bytes: [UInt8] = []
            var hi: Int?
            while p < b.count && b[p] != 62 {
                let h = b[p]
                p += 1
                if !Self.isHex(h) { continue }
                if let high = hi {
                    bytes.append(UInt8(high * 16 + Self.hexVal(h)))
                    hi = nil
                } else {
                    hi = Self.hexVal(h)
                }
            }
            if let high = hi { bytes.append(UInt8(high * 16)) }
            if p < b.count { p += 1 }
            var o = CObj(.string, start: start)
            o.bytes = bytes
            o.hex = true
            o.end = p
            return o
        case 91: // [
            p += 1
            var a = CObj(.array, start: start)
            while true {
                skipSpace()
                if p >= b.count { break }
                if b[p] == 93 {
                    p += 1
                    break
                }
                let at = p
                let item = depth < 32 ? readObject(depth + 1) : nil
                if let item {
                    a.items.append(item)
                } else if p == at {
                    p += 1 // a stray delimiter inside an array
                }
                // An operator keyword inside an array: malformed; ignore it.
            }
            a.end = p
            return a
        case 43, 45, 46, 48...57: // + - . digits
            var end = p
            while end < b.count && Self.isRegular(b[end]) { end += 1 }
            var text = Array(b[p..<end])
            p = end
            // "--5" and "5-" turn up in the wild: read what parses as a number.
            while text.first == 43 { text.removeFirst() }
            while text.count >= 2 && text[0] == 45 && text[1] == 45 { text.removeFirst() }
            if let cut = text.indices.dropFirst().first(where: { text[$0] == 45 || text[$0] == 43 }) { text = Array(text[..<cut]) }
            var o = CObj(.number, start: start)
            o.num = Self.number(text) ?? 0
            o.isInt = !text.contains(46)
            o.end = p
            return o
        case 41, 62, 93, 123, 125:
            return nil // stray: the caller skips it
        default:
            break
        }
        // A keyword: true/false/null are operands, anything else is an operator.
        var e = p
        while e < b.count && Self.isRegular(b[e]) { e += 1 }
        let word = latin1String(b[p..<e])
        p = e
        switch word {
        case "true", "false":
            var o = CObj(.bool, start: start)
            o.name = word
            o.end = p
            return o
        case "null":
            var o = CObj(.null, start: start)
            o.name = word
            o.end = p
            return o
        default:
            return nil
        }
    }

    /// A number as .NET's `double.TryParse` with a leading sign and a decimal point reads it: digits with at most one
    /// point, nothing else.
    private static func number(_ t: [UInt8]) -> Double? {
        var digits = 0, points = 0
        for (i, c) in t.enumerated() {
            if c >= 48 && c <= 57 {
                digits += 1
            } else if c == 46 {
                points += 1
            } else if !(i == 0 && (c == 45 || c == 43)) {
                return nil
            }
        }
        guard digits > 0, points <= 1, let v = Double(latin1String(t)), v.isFinite else { return nil }
        return v
    }

    private mutating func literalString(_ start: Int) -> CObj {
        p += 1
        var bytes: [UInt8] = []
        var depth = 1
        while p < b.count {
            let c = b[p]
            p += 1
            if c == 92 { // backslash
                if p >= b.count { break }
                let e = b[p]
                p += 1
                switch e {
                case 110: bytes.append(10)
                case 114: bytes.append(13)
                case 116: bytes.append(9)
                case 98: bytes.append(8)
                case 102: bytes.append(12)
                case 13:
                    if p < b.count && b[p] == 10 { p += 1 }
                case 10:
                    break
                case 48...55:
                    var v = Int(e) - 48
                    var k = 0
                    while k < 2 && p < b.count && b[p] >= 48 && b[p] <= 55 {
                        v = v * 8 + Int(b[p]) - 48
                        p += 1
                        k += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: v))
                default:
                    bytes.append(e)
                }
                continue
            }
            if c == 40 {
                depth += 1
            } else if c == 41 {
                depth -= 1
                if depth == 0 { break }
            }
            bytes.append(c)
        }
        var o = CObj(.string, start: start)
        o.bytes = bytes
        o.end = p
        return o
    }

    /// BI was just read: its dictionary up to ID, then the data up to EI.
    private mutating func inlineImage(_ op: COp) {
        var dict = CObj(.dict, start: p)
        while true {
            skipSpace()
            if p >= b.count { break }
            let at = p
            guard let key = readObject() else {
                if p == at {
                    p += 1
                    continue
                }
                if latin1String(b[at..<p]) == "ID" { break }
                continue
            }
            skipSpace()
            if p >= b.count { break }
            let at2 = p
            let value = readObject()
            if value == nil && p == at2 { p += 1 }
            if key.kind == .name, let value { dict.entries.append((key.name, value)) }
        }
        dict.end = p
        op.operands = [dict]
        if p < b.count && Self.isSpace(b[p]) { p += 1 } // the single white-space byte after ID
        op.dataStart = p
        // Where the data ends, surest first: its stated length (PDF 2.0 /L), the end marker of an ASCIIHex or ASCII85
        // filter, the size of unfiltered samples; else the first EI after white space that ordinary content follows.
        let start = p
        var end: Int?
        let filter = Self.firstFilter(dict)
        if let l = dict["L"] ?? dict["Length"], l.kind == .number, l.num >= 0, Double(start) + l.num <= Double(b.count),
           accept(start + Int(l.num)) {
            end = start + Int(l.num)
        } else if filter == "AHx" || filter == "ASCIIHexDecode", let gt = b[start...].firstIndex(of: 62), accept(gt + 1) {
            end = gt + 1
        } else if filter == "A85" || filter == "ASCII85Decode", let tilde = b[start...].firstRange(of: [126, 62])?.lowerBound,
                  accept(tilde + 2) {
            end = tilde + 2
        } else if filter == nil, let len = Self.expectedLength(dict), start + len <= b.count, accept(start + len) {
            end = start + len
        }
        if end == nil { end = findEi(start) }
        guard let e = end, e >= 0 else {
            op.broken = true
            op.dataEnd = start
            op.end = start
            p = b.count
            return
        }
        op.dataEnd = e
        var q = e
        while q < b.count && Self.isSpace(b[q]) { q += 1 }
        q += 2 // EI (accept checked it)
        p = q
        op.end = q
    }

    /// The image's first filter, abbreviated or not (nil: unfiltered).
    private static func firstFilter(_ d: CObj) -> String? {
        guard let f = d["F"] ?? d["Filter"] else { return nil }
        if f.kind == .name { return f.name }
        if f.kind == .array, let first = f.items.first, first.kind == .name { return first.name }
        return nil
    }

    /// Data ending at `dataEnd`: optional white space, EI, then content that reads as content.
    private func accept(_ dataEnd: Int) -> Bool { eiAt(dataEnd) && plausible(eiEnd(dataEnd)) }

    private func eiEnd(_ dataEnd: Int) -> Int {
        var q = dataEnd
        while q < b.count && Self.isSpace(b[q]) { q += 1 }
        return q + 2
    }

    /// The data length of an unfiltered inline image (nil when filtered or unknown).
    private static func expectedLength(_ d: CObj) -> Int? {
        if let f = d["F"] ?? d["Filter"], !(f.kind == .array && f.items.isEmpty) { return nil }
        let w = (d["W"] ?? d["Width"])?.num ?? 0
        let h = (d["H"] ?? d["Height"])?.num ?? 0
        let mask = (d["IM"] ?? d["ImageMask"])?.name == "true"
        let bpc = mask ? 1 : (d["BPC"] ?? d["BitsPerComponent"])?.num ?? 0
        let cs = (d["CS"] ?? d["ColorSpace"]).flatMap { $0.kind == .name ? $0.name : nil }
        var comps = 0.0
        if mask {
            comps = 1
        } else {
            switch cs {
            case "G", "DeviceGray", "CalGray", "I", "Indexed": comps = 1
            case "RGB", "DeviceRGB", "CalRGB": comps = 3
            case "CMYK", "DeviceCMYK": comps = 4
            default: comps = 0
            }
        }
        if w <= 0 || h <= 0 || bpc <= 0 || comps == 0 || w * h > 1e8 { return nil }
        let row: Double = (w * comps * bpc / 8).rounded(.up)
        return Int(row * h)
    }

    /// Whether optional white space, then "EI" and a delimiter or the end follow.
    private func eiAt(_ at: Int) -> Bool {
        var q = at
        while q < b.count && Self.isSpace(b[q]) { q += 1 }
        if q + 1 >= b.count || b[q] != 69 || b[q + 1] != 73 { return false }
        return q + 2 >= b.count || !Self.isRegular(b[q + 2])
    }

    /// The end of filtered inline-image data: the first "EI" after white space, followed by a delimiter or the end, where
    /// what comes next lexes as content (see `plausible`); -1 when there is none.
    private func findEi(_ from: Int) -> Int {
        var q = from + 1
        while q + 1 < b.count {
            defer { q += 1 }
            if b[q] != 69 || b[q + 1] != 73 || !Self.isSpace(b[q - 1]) { continue }
            if q + 2 < b.count && Self.isRegular(b[q + 2]) { continue }
            if plausible(q + 2) { return q - 1 }
        }
        return -1
    }

    private static let operators: Set<String> = [
        "b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP", "EMC", "ET", "EX",
        "f", "F", "f*", "G", "g", "gs", "h", "i", "j", "J", "K", "k", "l", "m", "M", "MP", "n", "q", "Q", "re", "RG", "rg", "ri",
        "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td", "TD", "Tf", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz",
        "v", "w", "W", "W*", "y", "'", "\"",
    ]

    /// Whether the content from `at` reads as content: the next few tokens are operands or known operators, with no
    /// binary bytes outside strings (strings may hold anything).
    private func plausible(_ at: Int) -> Bool {
        var lx = ContentLexer(b)
        lx.p = at
        var operators = 0
        var tokens = 0
        while tokens < 40 && operators < 4 {
            tokens += 1
            lx.skipSpace()
            if lx.p >= b.count { return true }
            let c = b[lx.p]
            if c >= 0x80 || (c < 32 && !Self.isSpace(c)) { return false }
            let start = lx.p
            if let obj = lx.readObject() {
                if obj.kind == .name && obj.name.unicodeScalars.contains(where: { $0.value >= 0x80 || $0.value < 32 }) { return false }
                continue
            }
            if lx.p == start { return false } // a stray delimiter
            if !Self.operators.contains(latin1String(b[start..<lx.p])) { return false }
            operators += 1
        }
        return true
    }

    private static func isHex(_ c: UInt8) -> Bool { (48...57).contains(c) || (97...102).contains(c) || (65...70).contains(c) }
    private static func hexVal(_ c: UInt8) -> Int { c <= 57 ? Int(c) - 48 : Int(c | 0x20) - 97 + 10 }

    // ---- Writing ----

    /// A literal string with the bytes escaped as needed (non-printing bytes as octal).
    static func literal(_ bytes: [UInt8]) -> String {
        var s = "("
        for c in bytes {
            if c == 40 || c == 41 || c == 92 {
                s += "\\" + String(Unicode.Scalar(c))
            } else if c >= 32 && c < 127 {
                s.unicodeScalars.append(Unicode.Scalar(c))
            } else {
                let octal = String(c, radix: 8)
                s += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            }
        }
        return s + ")"
    }

    static func hexString(_ bytes: [UInt8]) -> String { "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">" }

    /// A number as content streams write it: up to four decimals, no trailing zeros (.NET's "0.####").
    static func number(_ v: Double) -> String {
        let r = (v * 10000).rounded(.toNearestOrEven) / 10000
        if abs(r) < 1e-9 || !r.isFinite { return "0" }
        var s = String(format: "%.4f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
