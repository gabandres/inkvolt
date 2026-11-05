import Foundation

/// XFDF (ISO 19444-1) for `CommentFiles`: written by hand (attributes in Acrobat's order), read with Foundation's XML
/// parser after any DTD is refused.
extension CommentFiles {
    static let xfdfNamespace = "http://ns.adobe.com/xfdf/"

    /// The XFDF element of each annotation subtype that has one.
    static let xfdfElements: [String: String] = [
        "Text": "text", "FreeText": "freetext", "Line": "line", "Square": "square", "Circle": "circle",
        "Polygon": "polygon", "PolyLine": "polyline", "Highlight": "highlight", "Underline": "underline",
        "Squiggly": "squiggly", "StrikeOut": "strikeout", "Stamp": "stamp", "Caret": "caret", "Ink": "ink", "Redact": "redact",
    ]

    private static let subtypeOfElement: [String: String] = Dictionary(uniqueKeysWithValues: xfdfElements.map { ($0.value, $0.key) })

    /// Annotation flags (/F bits 1-10) by their XFDF names.
    private static let flagNames = ["invisible", "hidden", "print", "nozoom", "norotate", "noview", "readonly", "locked", "togglenoview", "lockedcontents"]

    /// Border styles (/BS /S) and their XFDF names.
    private static let styles: [(pdf: String, xfdf: String)] = [("S", "solid"), ("D", "dash"), ("B", "bevelled"), ("I", "inset"), ("U", "underline")]

    private static let markups: Set<String> = ["Highlight", "Underline", "Squiggly", "StrikeOut", "Redact"]

    // ---------------- Writing ----------------

    static func xml(_ s: String, attribute: Bool) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\r": out += "&#xD;"
            case "\n": out += "&#xA;"
            case "\t" where attribute: out += "&#x9;"
            default:
                // Characters XML can't carry (controls other than tab and line ends) are left out.
                if c.value < 0x20 && c != "\t" || c.value == 0xFFFE || c.value == 0xFFFF { continue }
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    static func writeXfdf(_ records: [Record], _ pdfFileName: String?, _ left: inout [String]) -> [UInt8] {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><xfdf xml:space=\"preserve\" xmlns=\"\(xfdfNamespace)\"><annots>"
        var notInXfdf: [String: Int] = [:]
        for r in records {
            if let name = xfdfElements[r.subtype] {
                out += element(r, name)
            } else {
                notInXfdf[r.subtype, default: 0] += 1
            }
        }
        for subtype in notInXfdf.keys.sorted() {
            left.append("\(plural(notInXfdf[subtype] ?? 0, kindName(subtype))): XFDF has no element for them (FDF keeps them)")
        }
        out += "</annots>"
        if let pdfFileName { out += "<f href=\"\(xml(pdfFileName, attribute: true))\"/>" }
        return Array((out + "</xfdf>").utf8)
    }

    private static func list(_ values: [Double]?) -> String? { values.map { $0.map(Fdf.number).joined(separator: ",") } }

    /// "x,y;x,y;…", the way XFDF writes vertices and ink gestures.
    private static func pairs(_ v: [Double]) -> String {
        (0..<v.count / 2).map { Fdf.number(v[2 * $0]) + "," + Fdf.number(v[2 * $0 + 1]) }.joined(separator: ";")
    }

    static func hex(_ c: [Double]?) -> String? {
        guard let c else { return nil }
        let rgb: [Double]
        switch c.count {
        case 1: rgb = [c[0], c[0], c[0]]
        case 3: rgb = c
        case 4: rgb = [(1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])]
        default: return nil
        }
        return "#" + rgb.map { String(format: "%02X", Int(exactly: (min(max($0, 0), 1) * 255).rounded()) ?? 0) }.joined()
    }

    // swiftlint:disable:next function_body_length
    private static func element(_ r: Record, _ name: String) -> String {
        let d = r.dict
        var attrs: [(String, String)] = []
        func attr(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            if let i = attrs.firstIndex(where: { $0.0 == key }) { attrs[i].1 = value } else { attrs.append((key, value)) }
        }
        func number(_ key: String) -> String? { d[key]?.numberValue.map(Fdf.number) }

        attr("page", String(r.page))
        attr("rect", list(d["Rect"]?.numbers))
        attr("name", r.key)
        attr("title", d["T"]?.stringValue)
        attr("subject", d["Subj"]?.stringValue)
        attr("date", d["M"]?.stringValue)
        attr("creationdate", d["CreationDate"]?.stringValue)
        attr("color", hex(d["C"]?.numbers))
        attr("interior-color", hex(d["IC"]?.numbers))
        if let flags = d["F"]?.numberValue, flags.isFinite, abs(flags) < 1e9 {
            let bits = Int(flags)
            attr("flags", flagNames.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element).joined(separator: ","))
        }
        if let ca = d["CA"]?.numberValue, ca < 1 { attr("opacity", Fdf.number(max(ca, 0))) }
        if let to = r.replyTo {
            attr("inreplyto", to)
            attr("replyType", d["RT"]?.nameValue == "Group" ? "group" : "reply")
        }
        attr("intent", d["IT"]?.nameValue)

        // Border: /BS (width, style, dashes), else /Border [h v width [dash]]; clouds from /BE.
        if let bs = d["BS"]?.dictValue {
            attr("width", bs["W"]?.numberValue.map(Fdf.number))
            if let s = bs["S"]?.nameValue, let style = styles.first(where: { $0.pdf == s }) { attr("style", style.xfdf) }
            if let dash = bs["D"]?.numbers, !dash.isEmpty { attr("dashes", list(dash)) }
        } else if let border = d["Border"]?.arrayValue, border.count >= 3, let w = border[2].numberValue {
            attr("width", Fdf.number(w))
        }
        if let be = d["BE"]?.dictValue, be["S"]?.nameValue == "C" {
            attr("style", "cloudy")
            attr("intensity", be["I"]?.numberValue.map(Fdf.number))
        }
        attr("fringe", list(d["RD"]?.numbers))
        attr("rotation", number("Rotate"))
        attr("icon", d["Name"]?.nameValue)
        attr("state", d["State"]?.stringValue)
        attr("statemodel", d["StateModel"]?.stringValue)
        if let q = d["Q"]?.numberValue { attr("justification", q == 1 ? "centered" : q == 2 ? "right" : "left") }

        func ends() {
            if let le = d["LE"]?.arrayValue, le.count == 2 {
                attr("head", le[0].nameValue)
                attr("tail", le[1].nameValue)
            }
        }
        switch r.subtype {
        case "Line":
            if let l = d["L"]?.numbers, l.count == 4 {
                attr("start", list(Array(l[0..<2])))
                attr("end", list(Array(l[2..<4])))
            }
            ends()
            attr("leaderLength", number("LL"))
            attr("leaderExtended", number("LLE"))
            attr("leader-offset", number("LLO"))
            if let cap = d["Cap"]?.boolValue { attr("caption", cap ? "yes" : "no") }
        case "PolyLine":
            ends()
        case "FreeText":
            attr("callout", list(d["CL"]?.numbers))
            attr("head", d["LE"]?.nameValue)
        case "Caret":
            attr("symbol", d["Sy"]?.nameValue == "P" ? "paragraph" : nil)
        case "Redact":
            attr("overlay-text", d["OverlayText"]?.stringValue)
        default:
            break
        }
        if markups.contains(r.subtype) { attr("coords", list(d["QuadPoints"]?.numbers)) }

        var e = "<" + name + attrs.map { " \($0.0)=\"\(xml($0.1, attribute: true))\"" }.joined() + ">"
        if let contents = d["Contents"]?.stringValue, !contents.isEmpty { e += "<contents>\(xml(contents, attribute: false))</contents>" }
        if let rc = d["RC"]?.stringValue, let body = richText(rc) { e += "<contents-richtext>\(body)</contents-richtext>" }
        if let da = d["DA"]?.stringValue { e += "<defaultappearance>\(xml(da, attribute: false))</defaultappearance>" }
        if let ds = d["DS"]?.stringValue { e += "<defaultstyle>\(xml(ds, attribute: false))</defaultstyle>" }
        switch r.subtype {
        case "Polygon", "PolyLine":
            if let v = d["Vertices"]?.numbers, v.count >= 2 { e += "<vertices>\(pairs(v))</vertices>" }
        case "Ink":
            if let strokes = d["InkList"]?.arrayValue {
                e += "<inklist>" + strokes.compactMap(\.numbers).map { "<gesture>\(pairs($0))</gesture>" }.joined() + "</inklist>"
            }
        case "Stamp":
            if let ap = d["AP"]?.dictValue, let xml = appearanceXml(ap) { e += "<appearance>\(Data(xml).base64EncodedString())</appearance>" }
        default:
            break
        }
        return e + "</\(name)>"
    }

    /// /RC rich text as its XHTML body element (nil when it isn't well-formed XML or has a DTD).
    private static func richText(_ rc: String) -> String? {
        if hasDtd(Array(rc.utf8)) { return nil }
        guard let root = try? XMLElement(xmlString: rc), root.localName == "body" else { return nil }
        return root.xmlString
    }

    /// An appearance dictionary the way Acrobat puts it in XFDF (base64 of an XML tree: DICT, STREAM, ARRAY, NAME, INT,
    /// FIXED, BOOL, STRING, and each stream's bytes in DATA as stored, hex, its /Filter kept).
    private static func appearanceXml(_ ap: [String: FdfValue]) -> [UInt8]? {
        var nodes = 0
        var failed = false
        func node(_ tag: String, _ key: String?, _ v: FdfValue, _ depth: Int) -> String {
            nodes += 1
            if nodes > 200_000 || depth > 32 {
                failed = true
                return ""
            }
            let keyAttr = key.map { " KEY=\"\(xml($0, attribute: true))\"" } ?? ""
            func entries(_ d: [String: FdfValue]) -> String { d.keys.sorted().map { node("X", $0, d[$0]!, depth + 1) }.joined() }
            switch v {
            case .stream(let s):
                let hex = s.data.map { String(format: "%02X", $0) }.joined()
                return "<STREAM\(keyAttr)>" + entries(s.dict) + "<DATA MODE=\"FILTERED\" ENCODING=\"HEX\">\(hex)</DATA></STREAM>"
            case .dict(let d):
                return "<DICT\(keyAttr)>" + entries(d) + "</DICT>"
            case .array(let list):
                return "<ARRAY\(keyAttr)>" + list.map { node("X", nil, $0, depth + 1) }.joined() + "</ARRAY>"
            case .name(let n):
                return "<NAME\(keyAttr) VAL=\"\(xml(n, attribute: true))\"/>"
            case .number(let d):
                let tag = abs(d - d.rounded()) < 1e-9 && abs(d) < Double(Int32.max) ? "INT" : "FIXED"
                return "<\(tag)\(keyAttr) VAL=\"\(Fdf.number(d))\"/>"
            case .bool(let b):
                return "<BOOL\(keyAttr) VAL=\"\(b ? "true" : "false")\"/>"
            case .string(let str) where str.unicodeScalars.allSatisfy(isXmlChar):
                return "<STRING\(keyAttr) VAL=\"\(xml(str, attribute: true))\"/>"
            default:
                return ""
            }
        }
        let root = node("DICT", "AP", .dict(ap), 0)
        if failed || root.isEmpty { return nil }
        return Array(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + root).utf8)
    }

    private static func isXmlChar(_ c: Unicode.Scalar) -> Bool {
        c == "\t" || c == "\n" || c == "\r" || (c.value >= 0x20 && c.value != 0xFFFE && c.value != 0xFFFF)
    }

    // ---------------- Reading ----------------

    /// True when the bytes hold a DTD or an entity declaration ("<!DOCTYPE", "<!ENTITY", any case): refused outright,
    /// before any parsing, since it could make the file read other files or grow without end.
    static func hasDtd(_ bytes: [UInt8]) -> Bool {
        let words = [Array("DOCTYPE".utf8), Array("ENTITY".utf8)]
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == UInt8(ascii: "<") && bytes[i + 1] == UInt8(ascii: "!") {
                for w in words where i + 2 + w.count <= bytes.count {
                    var same = true
                    for k in 0..<w.count where bytes[i + 2 + k] & 0xDF != w[k] {
                        same = false
                        break
                    }
                    if same { return true }
                }
            }
            i += 1
        }
        return false
    }

    static func readXfdf(_ file: [UInt8], _ skipped: inout [String]) throws -> [Record] {
        if hasDtd(file) {
            throw PdfEditError("The XFDF file has a DTD (<!DOCTYPE>), which Inkvolt PDF doesn't read: it could make the file read other files or grow without end.")
        }
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: Data(file), options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw PdfEditError("The file isn't valid XFDF: \(error.localizedDescription)")
        }
        guard let root = doc.rootElement(), root.localName == "xfdf" else {
            throw PdfEditError("The file isn't XFDF (its root element isn't <xfdf>).")
        }
        var elements: [XMLElement] = []
        for annots in children(root) where annots.localName == "annots" { elements += children(annots) }
        if elements.count > maxComments { throw tooMany() }
        let cleaner = Cleaner { $0 }
        var records: [Record] = []
        for (i, x) in elements.enumerated() {
            let local = x.localName ?? ""
            let page = Int(x.attribute(forName: "page")?.stringValue ?? "").flatMap { $0 >= 0 ? $0 : nil } ?? -1
            guard let subtype = subtypeOfElement[local] else {
                if local != "popup" { skipped.append("Page \(page + 1), <\(local)>: not a kind of comment Inkvolt PDF imports") }
                continue
            }
            guard let clean = try cleaner.annotation(fromXfdf(x, subtype)) else { continue }
            let nm = x.attribute(forName: "name")?.stringValue ?? ""
            let key = nm.isEmpty ? hashKey("xfdf", i, nil, clean) : nm
            let to = x.attribute(forName: "inreplyto")?.stringValue ?? ""
            records.append(Record(key: key, page: page, dict: clean, replyTo: to.isEmpty ? nil : to))
        }
        return records
    }

    private static func children(_ e: XMLElement) -> [XMLElement] { e.children?.compactMap { $0 as? XMLElement } ?? [] }

    // swiftlint:disable:next function_body_length
    private static func fromXfdf(_ x: XMLElement, _ subtype: String) -> [String: FdfValue] {
        var d: [String: FdfValue] = ["Subtype": .name(subtype)]
        func a(_ name: String) -> String? { x.attribute(forName: name)?.stringValue }
        func child(_ name: String) -> XMLElement? { children(x).first { $0.localName == name } }
        func put(_ key: String, _ value: FdfValue?) { if let value { d[key] = value } }
        func put(_ key: String, _ text: String?) { if let text { d[key] = .string(text) } }
        func putNumber(_ key: String, _ text: String?) { if let n = num(text) { d[key] = .number(n) } }

        if let rect = nums(a("rect")), rect.count == 4 { d["Rect"] = box(rect) }
        put("T", a("title"))
        put("Subj", a("subject"))
        put("M", a("date"))
        put("CreationDate", a("creationdate"))
        put("C", color(a("color")))
        put("IC", color(a("interior-color")))
        if let flags = a("flags") {
            var f = 0
            for part in flags.split(separator: ",") {
                if let bit = flagNames.firstIndex(of: part.trimmingCharacters(in: .whitespaces).lowercased()) { f |= 1 << bit }
            }
            d["F"] = .number(Double(f))
        }
        if let ca = num(a("opacity")) { d["CA"] = .number(min(max(ca, 0), 1)) }
        if let to = a("inreplyto"), !to.isEmpty { d["RT"] = .name(a("replyType")?.lowercased() == "group" ? "Group" : "R") }
        if let it = a("intent"), !it.isEmpty { d["IT"] = .name(it) }

        let style = a("style")?.lowercased()
        var bs: [String: FdfValue] = ["Type": .name("Border")]
        if let width = num(a("width")) { bs["W"] = .number(min(max(width, 0), 1000)) }
        if let pdfStyle = styles.first(where: { $0.xfdf == style })?.pdf { bs["S"] = .name(pdfStyle) }
        if let dashes = nums(a("dashes")), !dashes.isEmpty {
            bs["D"] = .numbers(Array(dashes.prefix(16)))
            if bs["S"] == nil { bs["S"] = .name("D") }
        }
        if bs.count > 1 { d["BS"] = .dict(bs) }
        if style == "cloudy" { d["BE"] = .dict(["S": .name("C"), "I": .number(min(max(num(a("intensity")) ?? 1, 0), 2))]) }
        if let fringe = nums(a("fringe")), fringe.count == 4 { d["RD"] = .numbers(fringe) }
        putNumber("Rotate", a("rotation"))
        if let icon = a("icon"), !icon.isEmpty { d["Name"] = .name(icon) }
        put("State", a("state"))
        put("StateModel", a("statemodel"))
        if let j = a("justification")?.lowercased() { d["Q"] = .number(j == "centered" || j == "center" ? 1 : j == "right" ? 2 : 0) }

        func ends() {
            let head = a("head"), tail = a("tail")
            if head != nil || tail != nil { d["LE"] = .array([.name(head ?? "None"), .name(tail ?? "None")]) }
        }
        switch subtype {
        case "Line":
            if let s = nums(a("start")), s.count == 2, let e = nums(a("end")), e.count == 2 { d["L"] = .numbers(s + e) }
            ends()
            putNumber("LL", a("leaderLength"))
            putNumber("LLE", a("leaderExtended"))
            putNumber("LLO", a("leader-offset"))
            if let cap = a("caption") { d["Cap"] = .bool(cap.lowercased() == "yes") }
        case "PolyLine":
            ends()
        case "FreeText":
            if let cl = nums(a("callout")), cl.count == 4 || cl.count == 6 { d["CL"] = .numbers(cl) }
            if let head = a("head"), !head.isEmpty { d["LE"] = .name(head) }
        case "Caret":
            d["Sy"] = .name(a("symbol")?.lowercased() == "paragraph" ? "P" : "None")
        case "Redact":
            put("OverlayText", a("overlay-text"))
        default:
            break
        }
        if markups.contains(subtype), let coords = nums(a("coords")), !coords.isEmpty, coords.count % 8 == 0 { d["QuadPoints"] = .numbers(coords) }

        let rich = child("contents-richtext").flatMap { children($0).first { $0.localName == "body" } }
        if let contents = child("contents") {
            d["Contents"] = .string(contents.stringValue ?? "")
        } else if let rich {
            d["Contents"] = .string(plainText(rich))
        }
        if let rich { d["RC"] = .string(rich.xmlString) }
        put("DA", child("defaultappearance")?.stringValue)
        put("DS", child("defaultstyle")?.stringValue)
        switch subtype {
        case "Polygon", "PolyLine":
            if let v = nums(child("vertices")?.stringValue), v.count >= 4, v.count % 2 == 0 { d["Vertices"] = .numbers(v) }
        case "Ink":
            if let ink = child("inklist") {
                let strokes = children(ink).filter { $0.localName == "gesture" }.compactMap { nums($0.stringValue) }
                    .filter { $0.count >= 2 && $0.count % 2 == 0 }.map { FdfValue.numbers($0) }
                if !strokes.isEmpty { d["InkList"] = .array(strokes) }
            }
        case "Stamp":
            if let b64 = child("appearance")?.stringValue, !b64.isEmpty, let ap = parseAppearance(b64) { d["AP"] = .dict(ap) }
        default:
            break
        }
        return d
    }

    static func box(_ r: [Double]) -> FdfValue { .numbers([min(r[0], r[2]), min(r[1], r[3]), max(r[0], r[2]), max(r[1], r[3])]) }

    /// Numbers separated by commas, semicolons or spaces; nil when any isn't a finite number.
    static func nums(_ text: String?) -> [Double]? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var out: [Double] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) {
            guard let v = Double(part), v.isFinite, !part.contains(where: { $0.isLetter && $0 != "e" && $0 != "E" }) else { return nil }
            out.append(v)
        }
        return out
    }

    static func num(_ text: String?) -> Double? {
        guard let n = nums(text), n.count == 1 else { return nil }
        return n[0]
    }

    /// "#RRGGBB" as a /C array (nil when it isn't one).
    static func color(_ hex: String?) -> FdfValue? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        func part(_ shift: Int) -> Double { (Double((v >> shift) & 255) / 255 * 10000).rounded() / 10000 }
        return .numbers([part(16), part(8), part(0)])
    }

    /// The text of an XHTML body: paragraphs and line breaks become new lines.
    private static func plainText(_ body: XMLElement) -> String {
        var sb = ""
        func walk(_ e: XMLNode, _ depth: Int) {
            if depth > 64 { return }
            for n in e.children ?? [] {
                if n.kind == .text {
                    sb += n.stringValue ?? ""
                } else if let c = n as? XMLElement {
                    if c.localName == "br" { sb += "\n" } else { walk(c, depth + 1) }
                    if c.localName == "p" || c.localName == "div" { sb += "\n" }
                }
            }
        }
        walk(body, 0)
        while sb.hasSuffix("\n") { sb.removeLast() }
        return sb
    }

    /// An XFDF stamp's `appearance`: base64 of an XML tree of DICT, STREAM, ARRAY and values (see `appearanceXml`). Nil
    /// when it can't be read.
    private static func parseAppearance(_ base64: String) -> [String: FdfValue]? {
        guard let bytes = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters),
              !hasDtd(Array(bytes)),
              let doc = try? XMLDocument(data: bytes, options: [.nodeLoadExternalEntitiesNever]), let root = doc.rootElement() else { return nil }
        var nodes = 0
        func value(_ e: XMLElement, _ depth: Int) -> FdfValue? {
            nodes += 1
            if nodes > 200_000 || depth > 32 { return nil }
            let val = e.attribute(forName: "VAL")?.stringValue
            switch (e.localName ?? "").uppercased() {
            case "DICT":
                return .dict(entries(e, depth))
            case "STREAM":
                var dict = entries(e, depth)
                guard let data = children(e).first(where: { $0.localName?.uppercased() == "DATA" }), let raw = streamData(data) else { return nil }
                // Unfiltered data ("RAW"): its /Filter no longer applies, unless the bytes still look Flate-encoded.
                if data.attribute(forName: "MODE")?.stringValue?.uppercased() == "RAW"
                    && !(dict["Filter"]?.nameValue == "FlateDecode" && raw.count > 1 && raw[0] == 0x78) {
                    dict["Filter"] = nil
                    dict["DecodeParms"] = nil
                }
                return .stream(FdfStream(dict, raw))
            case "ARRAY":
                return .array(children(e).map { value($0, depth + 1) ?? .null })
            case "NAME":
                return val.map { .name($0) }
            case "INT", "FIXED":
                guard let val, let n = Double(val), n.isFinite else { return nil }
                return .number(n)
            case "BOOL":
                return .bool(val?.lowercased() == "true")
            case "STRING":
                return .string(val ?? e.stringValue ?? "")
            default:
                return nil
            }
        }
        func entries(_ e: XMLElement, _ depth: Int) -> [String: FdfValue] {
            var dict: [String: FdfValue] = [:]
            for c in children(e) {
                if let key = c.attribute(forName: "KEY")?.stringValue, !key.isEmpty, key != "Length", let v = value(c, depth + 1) { dict[key] = v }
            }
            return dict
        }
        func streamData(_ data: XMLElement) -> [UInt8]? {
            let text = data.stringValue ?? ""
            switch data.attribute(forName: "ENCODING")?.stringValue?.uppercased() {
            case "HEX":
                let digits = text.unicodeScalars.compactMap { UInt8(String($0), radix: 16) }
                if digits.count % 2 == 1 { return nil }
                return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
            case "BASE64":
                return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters).map(Array.init)
            default:
                return text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
            }
        }
        guard root.localName?.uppercased() == "DICT" else { return nil }
        let ap = entries(root, 0)
        return ap["N"] != nil ? ap : nil
    }
}
