import Foundation

/// A stream on its way in or out of an FDF file: its dictionary and its bytes as stored (still encoded by its /Filter).
/// A class, so a stream shared by several objects is written (and imported) once.
final class FdfStream {
    var dict: [String: FdfValue]
    let data: [UInt8]

    init(_ dict: [String: FdfValue], _ data: [UInt8]) {
        self.dict = dict
        self.data = data
    }
}

/// One PDF value of an FDF file or of a comment on its way in or out (the Windows app's plain `Fdf` values): text strings
/// are decoded, names have no slash, references stay references until resolved.
indirect enum FdfValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case name(String)
    case ref(Int)
    case array([FdfValue])
    case dict([String: FdfValue])
    case stream(FdfStream)

    var dictValue: [String: FdfValue]? { if case .dict(let d) = self { d } else { nil } }
    var arrayValue: [FdfValue]? { if case .array(let a) = self { a } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var nameValue: String? { if case .name(let n) = self { n } else { nil } }
    var numberValue: Double? { if case .number(let n) = self { n } else { nil } }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }

    /// An array of numbers only, else nil (Windows' `CommentFiles.Numbers`).
    var numbers: [Double]? {
        guard case .array(let list) = self else { return nil }
        var out: [Double] = []
        out.reserveCapacity(list.count)
        for v in list {
            guard case .number(let n) = v else { return nil }
            out.append(n)
        }
        return out
    }

    static func numbers(_ values: [Double]) -> FdfValue { .array(values.map { .number($0) }) }
}

/// Just enough PDF object syntax to read and write FDF files (form data and comments), as the Windows app's `Fdf`.
enum Fdf {
    /// An FDF file's objects and its catalog.
    final class Document {
        var objects: [Int: FdfValue] = [:]
        var root: FdfValue?

        func resolve(_ v: FdfValue?) -> FdfValue? {
            var o = v
            var guardCount = 0
            while case .ref(let id)? = o, guardCount < 32 {
                o = objects[id]
                guardCount += 1
            }
            if case .ref? = o { return nil }
            return o
        }

        /// The catalog's /FDF dictionary (the trailer's /Root, else the first object holding one).
        func fdfDict() -> [String: FdfValue]? {
            var catalog = resolve(root)?.dictValue
            if catalog == nil {
                for key in objects.keys.sorted() {
                    if let d = objects[key]?.dictValue, d["FDF"] != nil {
                        catalog = d
                        break
                    }
                }
            }
            return resolve(catalog?["FDF"])?.dictValue
        }
    }

    /// Reads an FDF file's bytes.
    static func read(_ bytes: [UInt8]) -> Document { Parser(bytes).parse() }

    // ---------------- Reading ----------------

    private final class Parser {
        private enum Token {
            case open, close, arrOpen, arrClose, number(Double), string(String), name(String), keyword(String), streamData([UInt8])
        }

        private static let maxTokens = 2_000_000
        private static let maxDepth = 64
        private let s: [UInt8]
        private var p = 0
        private var tokens: [Token] = []

        init(_ s: [UInt8]) { self.s = s }

        func parse() -> Document {
            lex()
            let doc = Document()
            var i = 0
            while i < tokens.count {
                if i + 2 < tokens.count, case .number(let id) = tokens[i], case .number = tokens[i + 1], case .keyword("obj") = tokens[i + 2],
                   id >= 0, id < 100_000_000 {
                    i += 3
                    doc.objects[Int(id)] = value(&i, 0) ?? .null
                } else if case .keyword("trailer") = tokens[i] {
                    i += 1
                    if case .dict(let t)? = value(&i, 0) { doc.root = t["Root"] }
                } else {
                    i += 1
                }
            }
            return doc
        }

        /// Skips a dictionary or array nested too deep, without recursion.
        private func skip(_ i: inout Int) {
            var depth = 1
            while i < tokens.count && depth > 0 {
                switch tokens[i] {
                case .open, .arrOpen: depth += 1
                case .close, .arrClose: depth -= 1
                default: break
                }
                i += 1
            }
        }

        private func value(_ i: inout Int, _ depth: Int) -> FdfValue? {
            guard i < tokens.count else { return nil }
            let t = tokens[i]
            i += 1
            switch t {
            case .number(let n):
                if i + 1 < tokens.count, case .number = tokens[i], case .keyword("R") = tokens[i + 1] {
                    i += 2
                    return n >= 0 && n < 100_000_000 ? .ref(Int(n)) : .null
                }
                return .number(n)
            case .open:
                if depth > Self.maxDepth {
                    skip(&i)
                    return .null
                }
                var d: [String: FdfValue] = [:]
                while i < tokens.count {
                    if case .close = tokens[i] { break }
                    guard case .name(let key) = tokens[i] else {
                        i += 1
                        continue
                    }
                    i += 1
                    d[key] = value(&i, depth + 1) ?? .null
                }
                i += 1
                if i < tokens.count, case .streamData(let data) = tokens[i] {
                    i += 1
                    return .stream(FdfStream(d, data))
                }
                return .dict(d)
            case .arrOpen:
                if depth > Self.maxDepth {
                    skip(&i)
                    return .null
                }
                var list: [FdfValue] = []
                while i < tokens.count {
                    if case .arrClose = tokens[i] { break }
                    list.append(value(&i, depth + 1) ?? .null)
                }
                i += 1
                return .array(list)
            case .keyword("true"): return .bool(true)
            case .keyword("false"): return .bool(false)
            case .keyword, .streamData: return .null
            case .string(let str): return .string(str)
            case .name(let n): return .name(n)
            case .close, .arrClose: return nil
            }
        }

        private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 0 }
        private static let delimiters = Array("()<>[]{}/%".utf8)

        private func at(_ ahead: Int) -> UInt8 { p + ahead < s.count ? s[p + ahead] : 0 }

        private func lex() {
            while p < s.count && tokens.count < Self.maxTokens {
                let c = s[p]
                if Self.isSpace(c) {
                    p += 1
                } else if c == UInt8(ascii: "%") {
                    while p < s.count && s[p] != 13 && s[p] != 10 { p += 1 }
                } else if c == UInt8(ascii: "<") && at(1) == UInt8(ascii: "<") {
                    tokens.append(.open)
                    p += 2
                } else if c == UInt8(ascii: ">") && at(1) == UInt8(ascii: ">") {
                    tokens.append(.close)
                    p += 2
                } else if c == UInt8(ascii: "[") {
                    tokens.append(.arrOpen)
                    p += 1
                } else if c == UInt8(ascii: "]") {
                    tokens.append(.arrClose)
                    p += 1
                } else if c == UInt8(ascii: "(") {
                    tokens.append(.string(Self.decode(literal())))
                } else if c == UInt8(ascii: "<") {
                    tokens.append(.string(Self.decode(hex())))
                } else if c == UInt8(ascii: "/") {
                    tokens.append(.name(nameToken()))
                } else if (c >= 48 && c <= 57) || c == UInt8(ascii: "+") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") {
                    tokens.append(.number(number()))
                } else {
                    let start = p
                    while p < s.count && !Self.isSpace(s[p]) && !Self.delimiters.contains(s[p]) { p += 1 }
                    if p == start { p += 1 }
                    let word = String(decoding: s[start..<p], as: UTF8.self)
                    if word == "stream" {
                        tokens.append(.streamData(streamBytes()))
                    } else {
                        tokens.append(.keyword(word))
                    }
                }
            }
        }

        /// A stream's bytes: the /Length of the dictionary just read when it is a direct number that ends at "endstream",
        /// else up to "endstream".
        private func streamBytes() -> [UInt8] {
            if p < s.count && s[p] == 13 { p += 1 }
            if p < s.count && s[p] == 10 { p += 1 }
            let start = p
            var length: Int?
            var depth = 0
            var k = tokens.count - 1
            while k >= 0 && k >= tokens.count - 4096 {
                if case .close = tokens[k] {
                    depth += 1
                } else if case .open = tokens[k] {
                    depth -= 1
                    if depth <= 0 { break }
                } else if depth == 1, case .name("Length") = tokens[k], k + 1 < tokens.count, case .number(let len) = tokens[k + 1] {
                    var isRef = false
                    if k + 3 < tokens.count, case .keyword("R") = tokens[k + 3] { isRef = true }
                    if !isRef { length = len >= 0 && len <= Double(Int32.max) ? Int(len) : nil }
                }
                k -= 1
            }
            let end = Array("endstream".utf8)
            if let n = length, start + n <= s.count {
                var after = start + n
                while after < s.count && Self.isSpace(s[after]) { after += 1 }
                if after + end.count <= s.count && Array(s[after..<after + end.count]) == end {
                    p = after + end.count
                    return Array(s[start..<start + n])
                }
            }
            let stop0 = s[start...].firstRange(of: end)?.lowerBound ?? s.count
            p = min(s.count, stop0 + end.count)
            var stop = stop0
            if stop > start && s[stop - 1] == 10 { stop -= 1 }
            if stop > start && s[stop - 1] == 13 { stop -= 1 }
            return Array(s[start..<stop])
        }

        private func number() -> Double {
            let start = p
            p += 1
            while p < s.count && ((s[p] >= 48 && s[p] <= 57) || s[p] == UInt8(ascii: ".")) { p += 1 }
            let v = Double(String(decoding: s[start..<p], as: UTF8.self)) ?? 0
            return v.isFinite ? v : 0
        }

        private func nameToken() -> String {
            p += 1
            var bytes: [UInt8] = []
            while p < s.count && !Self.isSpace(s[p]) && !Self.delimiters.contains(s[p]) {
                if s[p] == UInt8(ascii: "#"), p + 2 < s.count, let b = UInt8(String(decoding: s[(p + 1)...(p + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(b)
                    p += 3
                } else {
                    bytes.append(s[p])
                    p += 1
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        private func literal() -> [UInt8] {
            p += 1
            var bytes: [UInt8] = []
            var depth = 1
            while p < s.count {
                let c = s[p]
                p += 1
                if c == UInt8(ascii: "\\") && p < s.count {
                    let e = s[p]
                    p += 1
                    switch e {
                    case UInt8(ascii: "n"): bytes.append(10)
                    case UInt8(ascii: "r"): bytes.append(13)
                    case UInt8(ascii: "t"): bytes.append(9)
                    case UInt8(ascii: "b"): bytes.append(8)
                    case UInt8(ascii: "f"): bytes.append(12)
                    case 13: if p < s.count && s[p] == 10 { p += 1 }
                    case 10: break
                    case 48...55:
                        var v = Int(e - 48)
                        var k = 0
                        while k < 2 && p < s.count && s[p] >= 48 && s[p] <= 55 {
                            v = v * 8 + Int(s[p] - 48)
                            p += 1
                            k += 1
                        }
                        bytes.append(UInt8(v & 255))
                    default: bytes.append(e)
                    }
                    continue
                }
                if c == UInt8(ascii: "(") {
                    depth += 1
                } else if c == UInt8(ascii: ")") {
                    depth -= 1
                    if depth == 0 { break }
                }
                bytes.append(c)
            }
            return bytes
        }

        private func hex() -> [UInt8] {
            p += 1
            var out: [UInt8] = []
            var high: UInt8?
            while p < s.count && s[p] != UInt8(ascii: ">") {
                let c = s[p]
                p += 1
                let v: UInt8
                switch c {
                case 48...57: v = c - 48
                case 65...70: v = c - 55
                case 97...102: v = c - 87
                default: continue
                }
                if let h = high {
                    out.append(h << 4 | v)
                    high = nil
                } else {
                    high = v
                }
            }
            p += 1
            if let h = high { out.append(h << 4) }
            return out
        }

        /// PDF text string bytes: UTF-16BE or UTF-8 with a byte order mark, else PDFDocEncoding (read as Latin-1).
        static func decode(_ b: [UInt8]) -> String {
            if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { return String(decoding: FormEditor.utf16BE(Array(b[2...])), as: UTF16.self) }
            if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return String(decoding: b[3...], as: UTF8.self) }
            return String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
        }
    }

    // ---------------- Writing ----------------

    /// Writes an FDF file: objects in order, streams always as indirect objects (each once).
    final class Writer {
        private(set) var out: [UInt8] = []
        private var ids: [ObjectIdentifier: Int] = [:]
        private var pending: [(Int, FdfStream)] = []
        private var next = 1

        init() { raw("%FDF-1.2\n%\u{E2}\u{E3}\u{CF}\u{D3}\n") }

        /// A number for an object written later (`set`).
        func reserve() -> Int {
            defer { next += 1 }
            return next
        }

        func set(_ id: Int, _ value: FdfValue) {
            raw("\(id) 0 obj\n")
            if case .stream(let st) = value { writeStream(st) } else { raw(serialize(value)) }
            raw("\nendobj\n")
            flush()
        }

        func finish(_ root: Int) -> [UInt8] {
            flush()
            raw("trailer\n<< /Root \(root) 0 R >>\n%%EOF\n")
            return out
        }

        private func indirect(_ st: FdfStream) -> Int {
            if let id = ids[ObjectIdentifier(st)] { return id }
            let id = next
            next += 1
            ids[ObjectIdentifier(st)] = id
            pending.append((id, st))
            return id
        }

        private func flush() {
            while !pending.isEmpty {
                let (id, st) = pending.removeFirst()
                raw("\(id) 0 obj\n")
                writeStream(st)
                raw("\nendobj\n")
            }
        }

        private func writeStream(_ st: FdfStream) {
            var dict = st.dict
            dict["Length"] = .number(Double(st.data.count))
            raw(serialize(.dict(dict)))
            raw("\nstream\n")
            out += st.data
            raw("\nendstream")
        }

        /// Latin-1 bytes of `text` (everything the writer makes is ASCII but the header's marker).
        private func raw(_ text: String) { out += text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

        func serialize(_ value: FdfValue?) -> String {
            var sb = ""
            write(&sb, value, 0)
            return sb
        }

        private func write(_ sb: inout String, _ value: FdfValue?, _ depth: Int) {
            guard let value, depth <= 64 else {
                sb += "null"
                return
            }
            switch value {
            case .null: sb += "null"
            case .bool(let b): sb += b ? "true" : "false"
            case .number(let d): sb += Fdf.number(d)
            case .string(let str): sb += Fdf.text(str)
            case .name(let n): sb += Fdf.nameText(n)
            case .ref(let r): sb += "\(r) 0 R"
            case .stream(let st): sb += "\(indirect(st)) 0 R"
            case .dict(let d):
                sb += "<<"
                for k in d.keys.sorted() {
                    sb += " " + Fdf.nameText(k) + " "
                    write(&sb, d[k], depth + 1)
                }
                sb += " >>"
            case .array(let list):
                sb += "["
                for (i, item) in list.enumerated() {
                    if i > 0 { sb += " " }
                    write(&sb, item, depth + 1)
                }
                sb += "]"
            }
        }
    }

    /// A number as FDF and XFDF write it: whole numbers without a point, else at most five decimals.
    static func number(_ d: Double) -> String {
        if !d.isFinite { return "0" }
        if abs(d - d.rounded()) < 1e-9 && abs(d) < 1e15 { return String(Int64(d.rounded())) }
        let r = (d * 100_000).rounded() / 100_000
        if r == r.rounded() { return String(Int64(r)) }
        var s = String(format: "%.5f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// A PDF string: literal for printable ASCII, else UTF-16BE hex with a byte order mark.
    static func text(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ ($0.value >= 32 && $0.value < 127) || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            var sb = "("
            for c in s.unicodeScalars {
                switch c {
                case "(": sb += "\\("
                case ")": sb += "\\)"
                case "\\": sb += "\\\\"
                case "\n": sb += "\\n"
                case "\r": sb += "\\r"
                case "\t": sb += "\\t"
                default: sb.unicodeScalars.append(c)
                }
            }
            return sb + ")"
        }
        return "<FEFF" + s.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }

    static func nameText(_ s: String) -> String {
        var sb = "/"
        for b in s.utf8 {
            if b > 0x20 && b < 0x7F && !"#()<>[]{}/%".utf8.contains(b) {
                sb.unicodeScalars.append(Unicode.Scalar(b))
            } else {
                sb += String(format: "#%02X", b)
            }
        }
        return sb
    }
}
