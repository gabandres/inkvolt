import Foundation

/// Form data exchange formats (the Windows app's `FormData`): FDF and XFDF (written for submits and mailForm, read for
/// ImportData) and HTML form encoding (written for submits). Field names are full names; hierarchy (a.b.c) becomes nested
/// FDF /Kids and XFDF field elements.
enum FormData {
    /// `values`: the value (several for a multi-select list); nil = the field has no value. `isName`: a check box or
    /// radio state, written as a PDF name in FDF.
    struct Entry: Equatable {
        var name: String
        var values: [String]?
        var isName: Bool
    }

    private final class Node {
        let part: String
        var entry: Entry?
        var kids: [Node] = []
        init(_ part: String) { self.part = part }
    }

    private static func tree(_ entries: [Entry]) -> [Node] {
        let root = Node("")
        for e in entries {
            var level = root
            for part in e.name.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
                if let n = level.kids.first(where: { $0.part == part }) {
                    level = n
                } else {
                    let n = Node(part)
                    level.kids.append(n)
                    level = n
                }
            }
            level.entry = e
        }
        return root.kids
    }

    // ---------------- FDF ----------------

    static func fdf(_ entries: [Entry], _ file: String?) -> [UInt8] {
        var sb = "%FDF-1.2\n%âãÏÓ\n1 0 obj\n<< /FDF << /Fields ["
        for n in tree(entries) { writeNode(&sb, n) }
        sb += "]"
        if let file { sb += " /F " + pdfString(file) }
        sb += " >> >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n"
        return FieldAppearance.latin1Bytes(sb)
    }

    private static func writeNode(_ sb: inout String, _ n: Node) {
        sb += "\n<< /T " + pdfString(n.part)
        if let entry = n.entry, let values = entry.values {
            sb += " /V "
            if values.count == 1 {
                sb += entry.isName ? pdfName(values[0]) : pdfString(values[0])
            } else {
                sb += "[" + values.map { pdfString($0) + " " }.joined() + "]"
            }
        }
        if !n.kids.isEmpty {
            sb += " /Kids ["
            for k in n.kids { writeNode(&sb, k) }
            sb += "]"
        }
        sb += " >>"
    }

    /// A PDF string: literal for printable ASCII, else UTF-16BE hex with a byte order mark.
    private static func pdfString(_ s: String) -> String {
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

    private static func pdfName(_ s: String) -> String {
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

    // ---------------- XFDF ----------------

    static func xfdf(_ entries: [Entry], _ file: String?) -> [UInt8] {
        func escape(_ s: String, attribute: Bool) -> String {
            var out = ""
            for c in s.unicodeScalars {
                switch c {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"" where attribute: out += "&quot;"
                case "\r": out += "&#xD;"
                case "\n" where attribute: out += "&#xA;"
                case "\t" where attribute: out += "&#x9;"
                default: out.unicodeScalars.append(c)
                }
            }
            return out
        }
        func element(_ n: Node) -> String {
            var e = "<field name=\"\(escape(n.part, attribute: true))\">"
            for k in n.kids { e += element(k) }
            for v in n.entry?.values ?? [] { e += "<value>\(escape(v, attribute: false))</value>" }
            return e + "</field>"
        }
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><xfdf xml:space=\"preserve\" xmlns=\"http://ns.adobe.com/xfdf/\"><fields>"
        xml += tree(entries).map(element).joined()
        xml += "</fields>"
        if let file { xml += "<f href=\"\(escape(file, attribute: true))\" />" }
        return Array((xml + "</xfdf>").utf8)
    }

    // ---------------- HTML form encoding ----------------

    static func html(_ entries: [Entry], _ encoding: String.Encoding) -> String {
        var parts: [String] = []
        for e in entries {
            for v in e.values ?? [""] { parts.append(escape(e.name, encoding) + "=" + escape(v, encoding)) }
        }
        return parts.joined(separator: "&")
    }

    private static func escape(_ s: String, _ encoding: String.Encoding) -> String {
        let bytes = s.data(using: encoding, allowLossyConversion: true).map(Array.init) ?? Array(s.utf8)
        var sb = ""
        for b in bytes {
            let c = Unicode.Scalar(b)
            if (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || "-_.~*".unicodeScalars.contains(c) {
                sb.unicodeScalars.append(c)
            } else if b == 32 {
                sb += "+"
            } else {
                sb += String(format: "%%%02X", b)
            }
        }
        return sb
    }

    // ---------------- Reading FDF and XFDF ----------------

    private static let maxImportBytes = 16 * 1024 * 1024

    /// Field values (full name → values) from FDF or XFDF data, or nil if it is neither.
    static func parse(_ data: [UInt8]) -> [String: [String]]? {
        if data.isEmpty || data.count > maxImportBytes { return nil }
        var start = data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0
        while start < data.count && [32, 9, 13, 10].contains(data[start]) { start += 1 }
        if start < data.count && data[start] == UInt8(ascii: "<") { return parseXfdf(data) }
        guard data[start...].starts(with: Array("%FDF".utf8)) else { return nil }
        return FdfParser(data).fields()
    }

    private static func parseXfdf(_ data: [UInt8]) -> [String: [String]]? {
        // No DTDs at all: an XFDF file never needs one, and entities could reach outside the file.
        let text = String(decoding: data, as: UTF8.self)
        if text.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil || text.range(of: "<!ENTITY", options: .caseInsensitive) != nil { return nil }
        guard let doc = try? XMLDocument(data: Data(data), options: []), let root = doc.rootElement() else { return nil }
        var result: [String: [String]] = [:]
        func walk(_ e: XMLElement, _ parent: String?, _ depth: Int) {
            if depth > 64 { return }
            for f in e.children?.compactMap({ $0 as? XMLElement }) ?? [] where f.localName == "field" {
                let part = f.attribute(forName: "name")?.stringValue ?? ""
                let name = parent.map { "\($0).\(part)" } ?? part
                let values = f.children?.compactMap { $0 as? XMLElement }.filter { $0.localName == "value" || $0.localName == "value-richtext" }
                    .map { $0.stringValue ?? "" } ?? []
                if !values.isEmpty { result[name] = values }
                walk(f, name, depth + 1)
            }
        }
        func find(_ e: XMLElement, _ depth: Int) {
            if depth > 64 { return }
            if e.localName == "fields" { walk(e, nil, 0) }
            for c in e.children?.compactMap({ $0 as? XMLElement }) ?? [] { find(c, depth + 1) }
        }
        find(root, 0)
        return result
    }

    /// Just enough of the PDF object syntax to read an FDF file's /Fields.
    private final class FdfParser {
        private indirect enum Value {
            case dict([String: Value]), array([Value]), string(String), name(String), number(Double), bool(Bool), null, ref(Int)
        }

        private enum Token {
            case open, close, arrOpen, arrClose, number(Double), string(String), name(String), keyword(String)
        }

        private let s: [UInt8]
        private var p = 0
        private var tokens: [Token] = []
        private var objects: [Int: Value] = [:]

        init(_ s: [UInt8]) { self.s = s }

        func fields() -> [String: [String]] {
            lex()
            var root: Value?
            var i = 0
            while i < tokens.count {
                if i + 2 < tokens.count, case .number(let id) = tokens[i], case .number = tokens[i + 1], case .keyword("obj") = tokens[i + 2] {
                    i += 3
                    objects[Int(id)] = value(&i)
                } else if case .keyword("trailer") = tokens[i] {
                    i += 1
                    if case .dict(let t)? = value(&i) { root = t["Root"] }
                } else {
                    i += 1
                }
            }
            var catalog: [String: Value]?
            if case .dict(let d)? = resolve(root) { catalog = d }
            if catalog == nil {
                for case .dict(let d) in objects.sorted(by: { $0.key < $1.key }).map(\.value) where d["FDF"] != nil {
                    catalog = d
                    break
                }
            }
            var result: [String: [String]] = [:]
            if case .dict(let fdf)? = resolve(catalog?["FDF"]), case .array(let list)? = resolve(fdf["Fields"]) {
                for f in list { walk(f, nil, &result, 0) }
            }
            return result
        }

        private func resolve(_ v: Value?) -> Value? {
            var o = v
            var guardCount = 0
            while case .ref(let id)? = o, guardCount < 32 {
                o = objects[id]
                guardCount += 1
            }
            if case .ref? = o { return nil }
            return o
        }

        private func walk(_ item: Value, _ parent: String?, _ into: inout [String: [String]], _ depth: Int) {
            guard depth <= 64, case .dict(let d)? = resolve(item) else { return }
            var part: String?
            if case .string(let t)? = resolve(d["T"]) { part = t }
            let name = part.map { p in parent.map { "\($0).\(p)" } ?? p } ?? parent
            if let name, let v = d["V"] {
                var values: [String] = []
                switch resolve(v) {
                case .string(let str)?: values = [str]
                case .name(let n)?: values = [n]
                case .array(let list)?:
                    for x in list {
                        switch resolve(x) {
                        case .string(let str)?: values.append(str)
                        case .name(let n)?: values.append(n)
                        default: break
                        }
                    }
                default: break
                }
                if !values.isEmpty { into[name] = values }
            }
            if case .array(let kids)? = resolve(d["Kids"]) {
                for k in kids { walk(k, name, &into, depth + 1) }
            }
        }

        private func value(_ i: inout Int) -> Value? {
            guard i < tokens.count else { return nil }
            let t = tokens[i]
            i += 1
            switch t {
            case .number(let n):
                if i + 1 < tokens.count, case .number = tokens[i], case .keyword("R") = tokens[i + 1] {
                    i += 2
                    return .ref(Int(n))
                }
                return .number(n)
            case .open:
                var d: [String: Value] = [:]
                while i < tokens.count {
                    if case .close = tokens[i] { break }
                    guard case .name(let key) = tokens[i] else {
                        i += 1
                        continue
                    }
                    i += 1
                    d[key] = value(&i) ?? .null
                }
                i += 1
                return .dict(d)
            case .arrOpen:
                var list: [Value] = []
                while i < tokens.count {
                    if case .arrClose = tokens[i] { break }
                    list.append(value(&i) ?? .null)
                }
                i += 1
                return .array(list)
            case .keyword("true"): return .bool(true)
            case .keyword("false"): return .bool(false)
            case .keyword("null"): return .null
            case .keyword(let k): return .name(k) // (a bare keyword: kept, never read as a value)
            case .string(let str): return .string(str)
            case .name(let n): return .name(n)
            case .close, .arrClose: return nil
            }
        }

        private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 0 }
        private static let delimiters = Array("()<>[]{}/%".utf8)

        private func at(_ ahead: Int) -> UInt8 { p + ahead < s.count ? s[p + ahead] : 0 }

        private func lex() {
            while p < s.count && tokens.count < 1_000_000 {
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
                        if let r = s[p...].firstRange(of: Array("endstream".utf8)) { p = r.upperBound } else { p = s.count }
                    } else {
                        tokens.append(.keyword(word))
                    }
                }
            }
        }

        private func number() -> Double {
            let start = p
            p += 1
            while p < s.count && ((s[p] >= 48 && s[p] <= 57) || s[p] == UInt8(ascii: ".")) { p += 1 }
            return Double(String(decoding: s[start..<p], as: UTF8.self)) ?? 0
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
            var digits: [UInt8] = []
            while p < s.count && s[p] != UInt8(ascii: ">") {
                let c = s[p]
                if (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) { digits.append(c) }
                p += 1
            }
            p += 1
            if digits.count % 2 == 1 { digits.append(48) }
            return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16) ?? 0 }
        }

        /// PDF text string bytes: UTF-16BE or UTF-8 with a byte order mark, else PDFDocEncoding (read as Latin-1).
        private static func decode(_ b: [UInt8]) -> String {
            if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { return String(decoding: FormEditor.utf16BE(Array(b[2...])), as: UTF16.self) }
            if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return String(decoding: b[3...], as: UTF8.self) }
            return String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
        }
    }
}
