import Foundation
@testable import PdfCore

/// Small hand-written forms for the cases the real corpus has too few of, each as plain PDF syntax so it shows exactly one
/// trait. Windows' `SyntheticForms`, the same forms, plus encrypted ones (with and without fill permission), masked
/// AFSpecial fields and damaged files. Generated, never downloaded.
enum SyntheticForms {
    static let all: [(name: String, what: String)] = [
        ("synth-comb", "comb text field, MaxLen 9"),
        ("synth-hex-names", "field names as hex strings, UTF-16 with BOM and accented"),
        ("synth-inherited", "/FT, /DA, /Ff and /MaxLen inherited from parents; widgets without /T"),
        ("synth-hierarchy", "a.b.c names: a terminal field three levels down, a check box beside it"),
        ("synth-needappearances", "NeedAppearances true, text fields with no appearance"),
        ("synth-no-appearance", "no NeedAppearances, a text field and a check box (with /MK /CA) with no appearance"),
        ("synth-richtext", "rich text field (/RV, /DS)"),
        ("synth-choice", "combo with [export display] pairs, editable combo, multi-select list"),
        ("synth-radio-kids", "radio group of three kids, NoToggleToOff; a RadiosInUnison group"),
        ("synth-checkbox-opt", "check boxes sharing a name, export values in /Opt"),
        ("synth-js-es", "Spanish number format AFNumber_Format(2, 2, ...), 1.234,56; SUM calculation; dd/mm/yyyy date"),
        ("synth-js-es3", "AFNumber sepStyle 3 (1234,56) with a currency suffix; AFPercent; product calculation"),
        ("synth-da-acroform", "text fields with no /DA of their own: the AcroForm's /DA and /Q"),
        ("synth-incremental", "an incremental update that changes a value and adds a field"),
        ("synth-objstm", "fields and widgets inside an object stream, cross-reference stream"),
        ("synth-rotated", "page /Rotate 90 with fields, widget /MK /R 90"),
        ("synth-multiline", "multiline centered text, a password field, a field with no font size (auto)"),
        // The Mac's additions: what Windows' corpus found, in small forms.
        ("synth-special", "AFSpecial SSN (comb, MaxLen 9), phone (MaxLen 10), ZIP+4 (MaxLen 9), ZIP; a mask with its dashes"),
        ("synth-enc-aes256", "empty user password, an owner password, AES-256, filling allowed; a choice, a check box, an AFNumber field"),
        ("synth-enc-aes128", "the same, AES-128"),
        ("synth-enc-rc4128", "the same, RC4 128-bit"),
        ("synth-enc-rc440", "the same, RC4 40-bit (revision 2: annotating allows filling)"),
        ("synth-enc-annots", "AES-256, comments allowed (and with them filling), the fill bit itself clear"),
        ("synth-kids-missing", "a radio button with /Parent that its parent's /Kids leaves out, a nameless widget listed in /Fields"),
        ("synth-stale-widget-i", "a list box whose widget has its own stale /I and /V"),
        ("synth-box-no-face", "a check box with no appearance and no /MK, one whose on face is an empty dictionary"),
        ("synth-shared-widget", "the same widget on two pages' /Annots; a kid widget without /Parent"),
        ("synth-damaged-offsets", "every xref row off by two bytes"),
        ("synth-damaged-tail", "saved over a longer older copy of itself: a stale tail with an old object, trailer and startxref"),
        ("synth-damaged-truncated", "cut off before the cross-reference table"),
        ("synth-damaged-objstm", "the fields in an object stream, its cross-reference row wrong"),
        ("synth-damaged-enc", "encrypted with an empty user password, a stale tail after %%EOF"),
    ]

    static func build(_ name: String) -> [UInt8] {
        switch name {
        case "synth-comb": return simple([tx("Comb", 72, 700, 200, 20, ff: 1 << 24, extra: "/MaxLen 9")])
        case "synth-hex-names":
            return simple([txRaw("<FEFF004E006F006D006200720065>", 72, 700), txRaw("<4369747920>", 72, 660),
                           txRaw("<FEFF0041006E0303006F>", 72, 620), txRaw("(Pa\\355s)", 72, 580)])
        case "synth-inherited": return inherited()
        case "synth-hierarchy": return hierarchy()
        case "synth-needappearances":
            return simple([tx("First", 72, 700), tx("Second", 72, 660), check("Agree", 72, 620, ap: true)], acroExtra: "/NeedAppearances true")
        case "synth-no-appearance":
            return simple([tx("Plain", 72, 700), check("Bare", 72, 660, ap: false, extra: "/MK << /CA (8) /BC [0 0 0] >>")])
        case "synth-richtext":
            let rich = "/RV (<?xml version=\"1.0\"?><body xmlns=\"http://www.w3.org/1999/xhtml\"><p>Old <b>rich</b> text</p></body>) /DS (font: Helvetica 10pt) /V (Old rich text)"
            return simple([tx("Rich", 72, 700, 300, 40, ff: 1 << 25 | 1 << 12, extra: rich)])
        case "synth-choice":
            return simple([
                field("Pais", "/FT /Ch /Ff 131072 /Opt [[(PR) (Puerto Rico)] [(US) (Estados Unidos)] [(ES) (Espa\\361a)]] /V (PR) /DA (/Helv 10 Tf 0 g)", 72, 700, 200, 20),
                field("Ciudad", "/FT /Ch /Ff 393216 /Opt [(San Juan) (Ponce) (Mayag\\374ez)] /DA (/Helv 10 Tf 0 g)", 72, 660, 200, 20),
                field("Colores", "/FT /Ch /Ff 2097152 /Opt [(Rojo) (Verde) (Azul) (Negro)] /DA (/Helv 10 Tf 0 g)", 72, 560, 200, 80),
            ])
        case "synth-radio-kids": return radioKids()
        case "synth-checkbox-opt": return checkOpt()
        case "synth-js-es": return spanish(sep: 2)
        case "synth-js-es3": return spanish(sep: 3)
        case "synth-da-acroform": return simple([txNoDa("Uno", 72, 700), txNoDa("Dos", 72, 660)], acroExtra: "/Q 2")
        case "synth-incremental": return incremental()
        case "synth-objstm": return objStm()
        case "synth-rotated":
            return simple([tx("Turned", 100, 500, 20, 200, extra: "/MK << /R 90 >>"), check("TurnedBox", 140, 500, ap: true)], rotate: 90)
        case "synth-multiline":
            return simple([tx("Notes", 72, 600, 300, 100, ff: 1 << 12, extra: "/Q 1"), tx("Secret", 72, 560, 200, 20, ff: 1 << 13),
                           field("Auto", "/FT /Tx /DA (/Helv 0 Tf 0 g)", 72, 520, 200, 14)])
        case "synth-special": return special()
        case "synth-enc-aes256": return encrypted("aes-256", fill: true, annotate: false)
        case "synth-enc-aes128": return encrypted("aes-128", fill: true, annotate: false)
        case "synth-enc-rc4128": return encrypted("rc4-128", fill: true, annotate: false)
        case "synth-enc-rc440": return encrypted("rc4-40", fill: true, annotate: true)
        case "synth-enc-annots": return encrypted("aes-256", fill: false, annotate: true)
        case "synth-kids-missing": return kidsMissing()
        case "synth-stale-widget-i": return staleWidgetIndex()
        case "synth-box-no-face": return boxNoFace()
        case "synth-shared-widget": return sharedWidget()
        case "synth-damaged-offsets": return Damage.brokenOffsets(damageable())
        case "synth-damaged-tail": return Damage.staleTail(damageable())
        case "synth-damaged-truncated": return Damage.truncated(damageable())
        case "synth-damaged-objstm": return Damage.brokenObjStm(objStm())
        case "synth-damaged-enc": return Damage.staleTail(encrypted("aes-128", fill: true, annotate: false))
        default: return []
        }
    }

    // MARK: Fields

    /// A field written as the objects it needs; "{P}" stands for the page, "{SELF}" for its own object.
    struct Spec {
        var dict: String
        var ap: String?
        var apOff: String?
    }

    private static func n(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(v) } // bounded: small constants of this file

    private static func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String { "[\(n(x)) \(n(y)) \(n(x + w)) \(n(y + h))]" }

    static func field(_ t: String, _ body: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Spec {
        Spec(dict: "/Type /Annot /Subtype /Widget /T (\(t)) \(body) /Rect \(r(x, y, w, h)) /P {P} /F 4")
    }

    static func tx(_ t: String, _ x: Double, _ y: Double, _ w: Double = 200, _ h: Double = 20, ff: Int = 0, extra: String = "") -> Spec {
        Spec(dict: "/Type /Annot /Subtype /Widget /FT /Tx /T (\(t)) /Ff \(ff) /DA (/Helv 10 Tf 0 g) \(extra) /Rect \(r(x, y, w, h)) /P {P} /F 4")
    }

    static func txRaw(_ tRaw: String, _ x: Double, _ y: Double) -> Spec {
        Spec(dict: "/Type /Annot /Subtype /Widget /FT /Tx /T \(tRaw) /DA (/Helv 10 Tf 0 g) /Rect \(r(x, y, 200, 20)) /P {P} /F 4")
    }

    static func txNoDa(_ t: String, _ x: Double, _ y: Double) -> Spec {
        Spec(dict: "/Type /Annot /Subtype /Widget /FT /Tx /T (\(t)) /Rect \(r(x, y, 200, 20)) /P {P} /F 4")
    }

    static func check(_ t: String, _ x: Double, _ y: Double, ap: Bool, extra: String = "") -> Spec {
        Spec(dict: "/Type /Annot /Subtype /Widget /FT /Btn /T (\(t)) /V /Off /AS /Off /DA (/ZaDb 0 Tf 0 g) \(extra) /Rect \(r(x, y, 14, 14)) /P {P} /F 4",
             ap: ap ? checkFace : nil, apOff: ap ? "" : nil)
    }

    private static let checkFace = "q 0 g BT /ZaDb 10 Tf 2 3 Td (4) Tj ET Q"

    // MARK: Documents

    final class Writer {
        private var objs: [String?] = [nil] // 1-based
        func reserve() -> Int {
            objs.append(nil)
            return objs.count - 1
        }
        func add(_ body: String) -> Int {
            objs.append(body)
            return objs.count - 1
        }
        func set(_ id: Int, _ body: String) { objs[id] = body }
        func stream(_ dict: String, _ content: String) -> Int { add("<< \(dict) /Length \(latin1(content).count) >>\nstream\n\(content)\nendstream") }
        var count: Int { objs.count - 1 }

        func build(_ root: Int, header: String = "%PDF-1.7") -> [UInt8] {
            var sb = header + "\n%\u{E2}\u{E3}\u{CF}\u{D3}\n"
            var offsets = [Int](repeating: 0, count: objs.count)
            var length = latin1(sb).count
            for i in 1..<objs.count {
                offsets[i] = length
                let piece = "\(i) 0 obj\n\(objs[i] ?? "null")\nendobj\n"
                sb += piece
                length += latin1(piece).count
            }
            sb += "xref\n0 \(objs.count)\n0000000000 65535 f \n"
            for i in 1..<objs.count { sb += String(format: "%010d 00000 n \n", offsets[i]) }
            sb += "trailer\n<< /Size \(objs.count) /Root \(root) 0 R >>\nstartxref\n\(length)\n%%EOF\n"
            return latin1(sb)
        }
    }

    static func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") } }

    private static let fonts = "/Font << /Helv << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> /ZaDb << /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >> >>"
    private static let pageFonts = "/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>"

    private static func refs(_ ids: [Int]) -> String { ids.map { "\($0) 0 R" }.joined(separator: " ") }

    /// One page, each spec a merged field/widget at the top of /Fields.
    static func simple(_ specs: [Spec], acroExtra: String = "", rotate: Int = 0) -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let ids = specs.map { addWidget(w, $0, page) }
        let labels = w.stream("", "BT /F1 12 Tf 72 740 Td (Synthetic form for Inkvolt's forms corpus) Tj ET")
        w.set(page, "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 612 792] \(rotate != 0 ? "/Rotate \(rotate)" : "") \(pageFonts) /Contents \(labels) 0 R /Annots [\(refs(ids))] >>")
        w.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        w.set(catalog, "<< /Type /Catalog /Pages \(pages) 0 R /AcroForm << /Fields [\(refs(ids))] /DR << \(fonts) >> /DA (/Helv 0 Tf 0 g) \(acroExtra) >> >>")
        return w.build(catalog)
    }

    private static func addWidget(_ w: Writer, _ s: Spec, _ page: Int, parent: String = "") -> Int {
        let id = w.reserve()
        var ap = ""
        if let face = s.ap {
            let rect = (match(#"/Rect \[([\d. -]+)\]"#, s.dict)?[1] ?? "0 0 1 1").split(separator: " ").map { Double($0) ?? 0 }
            let bbox = "[0 0 \(n(rect[2] - rect[0])) \(n(rect[3] - rect[1]))]"
            let on = w.stream("/Type /XObject /Subtype /Form /BBox \(bbox) /Resources << \(fonts) >>", face)
            if let offFace = s.apOff {
                let off = w.stream("/Type /XObject /Subtype /Form /BBox \(bbox)", offFace)
                let state = match(#"/OnState /(\w+)"#, s.dict)?[1] ?? "Yes"
                ap = "/AP << /N << /\(state) \(on) 0 R /Off \(off) 0 R >> >>"
            } else {
                ap = "/AP << /N \(on) 0 R >>"
            }
        }
        let dict = s.dict.replacingOccurrences(of: #"/OnState /\w+"#, with: "", options: .regularExpression)
        w.set(id, "<< \(dict.replacingOccurrences(of: "{P}", with: "\(page) 0 R").replacingOccurrences(of: "{SELF}", with: "\(id) 0 R")) \(ap) \(parent) >>")
        return id
    }

    private static func finish(_ w: Writer, _ catalog: Int, _ pages: Int, _ page: Int, annots: [Int], fields: [Int], label: String, acro: String = "") -> [UInt8] {
        let labels = w.stream("", "BT /F1 12 Tf 72 740 Td (\(label)) Tj ET")
        w.set(page, "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 612 792] \(pageFonts) /Contents \(labels) 0 R /Annots [\(refs(annots))] >>")
        w.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        w.set(catalog, "<< /Type /Catalog /Pages \(pages) 0 R /AcroForm << /Fields [\(refs(fields))] /DR << \(fonts) >> \(acro) >> >>")
        return w.build(catalog)
    }

    private static func inherited() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        // A text field whose /FT, /DA, /Ff and /MaxLen are on the parent; two widgets without /T.
        let parent = w.reserve()
        let k1 = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /Rect \(r(72, 700, 200, 20)) /P {P} /F 4"), page, parent: "/Parent \(parent) 0 R")
        let k2 = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /Rect \(r(72, 660, 200, 20)) /P {P} /F 4"), page, parent: "/Parent \(parent) 0 R")
        w.set(parent, "<< /FT /Tx /T (Shared) /DA (/Helv 9 Tf 0 0 1 rg) /MaxLen 12 /Kids [\(k1) 0 R \(k2) 0 R] >>")
        // A grandparent holding /FT /Tx and /DA; the terminal field has /T only.
        let grand = w.reserve()
        let leaf = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /T (Leaf) /Rect \(r(72, 620, 200, 20)) /P {P} /F 4"), page, parent: "/Parent \(grand) 0 R")
        w.set(grand, "<< /FT /Tx /T (Group) /DA (/Helv 11 Tf 0 g) /Kids [\(leaf) 0 R] >>")
        // A check box whose /FT is on the parent.
        let cbParent = w.reserve()
        let cb = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /AS /Off /Rect \(r(72, 580, 14, 14)) /P {P} /F 4 /OnState /Si", ap: checkFace, apOff: ""), page, parent: "/Parent \(cbParent) 0 R")
        w.set(cbParent, "<< /FT /Btn /T (Acepto) /V /Off /DA (/ZaDb 0 Tf 0 g) /Kids [\(cb) 0 R] >>")
        return finish(w, catalog, pages, page, annots: [k1, k2, leaf, cb], fields: [parent, grand, cbParent], label: "Inherited attributes")
    }

    private static func hierarchy() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let a = w.reserve(), b = w.reserve()
        let c = addWidget(w, tx("c", 72, 700), page, parent: "/Parent \(b) 0 R")
        let d = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Btn /T (d) /V /Off /AS /Off /Rect \(r(72, 660, 14, 14)) /P {P} /F 4", ap: checkFace, apOff: ""), page, parent: "/Parent \(b) 0 R")
        let e = addWidget(w, tx("e", 72, 620), page, parent: "/Parent \(a) 0 R")
        w.set(b, "<< /T (b) /Parent \(a) 0 R /Kids [\(c) 0 R \(d) 0 R] >>")
        w.set(a, "<< /T (a) /Kids [\(b) 0 R \(e) 0 R] >>")
        return finish(w, catalog, pages, page, annots: [c, d, e], fields: [a], label: "a.b.c", acro: "/DA (/Helv 0 Tf 0 g)")
    }

    private static func radioKids() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let dot = "q 0 g 7 7 m 7 9.2 5.2 11 3 11 c 0.8 11 -1 9.2 -1 7 c -1 4.8 0.8 3 3 3 c 5.2 3 7 4.8 7 7 c f Q"
        let group = w.reserve()
        var kids: [Int] = []
        for (i, state) in ["Uno", "Dos", "Tres"].enumerated() {
            let x = 72 + Double(i) * 40
            kids.append(addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /AS /\(i == 0 ? state : "Off") /Rect \(r(x, 700, 14, 14)) /P {P} /F 4 /MK << /CA (l) >> /OnState /\(state)", ap: dot, apOff: ""), page, parent: "/Parent \(group) 0 R"))
        }
        w.set(group, "<< /FT /Btn /Ff \((1 << 15) | (1 << 14)) /T (Opcion) /V /Uno /DA (/ZaDb 0 Tf 0 g) /Kids [\(refs(kids))] >>")
        let unison = w.reserve()
        var ukids: [Int] = []
        for (i, state) in ["A", "A", "B"].enumerated() {
            let x = 72 + Double(i) * 40
            ukids.append(addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /AS /Off /Rect \(r(x, 650, 14, 14)) /P {P} /F 4 /OnState /\(state)", ap: dot, apOff: ""), page, parent: "/Parent \(unison) 0 R"))
        }
        w.set(unison, "<< /FT /Btn /Ff \((1 << 15) | (1 << 25)) /T (Unison) /V /Off /DA (/ZaDb 0 Tf 0 g) /Kids [\(refs(ukids))] >>")
        return finish(w, catalog, pages, page, annots: kids + ukids, fields: [group, unison], label: "Radio groups")
    }

    private static func checkOpt() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let parent = w.reserve()
        var kids: [Int] = []
        for i in 0..<3 {
            let x = 72 + Double(i) * 40
            kids.append(addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /AS /Off /Rect \(r(x, 700, 14, 14)) /P {P} /F 4 /OnState /\(i)", ap: checkFace, apOff: ""), page, parent: "/Parent \(parent) 0 R"))
        }
        w.set(parent, "<< /FT /Btn /T (Estado) /V /Off /Opt [(Soltero) (Casado) (Viudo)] /DA (/ZaDb 0 Tf 0 g) /Kids [\(refs(kids))] >>")
        return finish(w, catalog, pages, page, annots: kids, fields: [parent], label: "Check boxes with /Opt")
    }

    /// The owner's case in miniature: amounts in a Spanish number format, a total calculated from them.
    private static func spanish(sep: Int) -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        func js(_ s: String) -> Int { w.add("<< /S /JavaScript /JS (\(s.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)"))) >>") }
        let cur = sep == 3 ? "\" \\\\u20AC\", false" : "\"\", true" // \\ in the PDF string: JavaScript gets €
        let fmt = "AFNumber_Format(2, \(sep), 0, 0, \(cur));", key = "AFNumber_Keystroke(2, \(sep), 0, 0, \(cur));"
        var ids: [Int] = []
        func amount(_ t: String, _ y: Double, calc: String? = nil) -> Int {
            let aa = "/AA << /F \(js(fmt)) 0 R /K \(js(key)) 0 R \(calc.map { "/C \(js($0)) 0 R" } ?? "") >>"
            let id = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Tx /T (\(t)) /DA (/Helv 10 Tf 0 g) /Q 2 \(aa) /Rect \(r(300, y, 150, 20)) /P {P} /F 4"), page)
            ids.append(id)
            return id
        }
        _ = amount("Importe1", 700)
        _ = amount("Importe2", 660)
        let op = sep == 2 ? "SUM" : "PRD"
        let total = amount("Total", 620, calc: "AFSimple_Calculate(\"\(op)\", new Array(\"Importe1\", \"Importe2\"));")
        ids.append(addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Tx /T (Fecha) /DA (/Helv 10 Tf 0 g) /AA << /F \(js("AFDate_FormatEx(\"dd/mm/yyyy\");")) 0 R /K \(js("AFDate_KeystrokeEx(\"dd/mm/yyyy\");")) 0 R >> /Rect \(r(300, 580, 150, 20)) /P {P} /F 4"), page))
        if sep == 3 {
            ids.append(addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Tx /T (Porcentaje) /DA (/Helv 10 Tf 0 g) /AA << /F \(js("AFPercent_Format(1, 3);")) 0 R /K \(js("AFPercent_Keystroke(1, 3);")) 0 R >> /Rect \(r(300, 540, 150, 20)) /P {P} /F 4"), page))
        }
        return finish(w, catalog, pages, page, annots: ids, fields: ids, label: "Importes", acro: "/CO [\(total) 0 R] /DA (/Helv 0 Tf 0 g)")
    }

    /// A form saved, then updated incrementally: the update changes a value and adds a field.
    private static func incremental() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let name = addWidget(w, tx("Nombre", 72, 700, extra: "/V (Viejo)"), page)
        let labels = w.stream("", "BT /F1 12 Tf 72 740 Td (Incremental update) Tj ET")
        func pageBody(_ annots: String) -> String { "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 612 792] \(pageFonts) /Contents \(labels) 0 R /Annots [\(annots)] >>" }
        func catalogBody(_ fields: String) -> String { "<< /Type /Catalog /Pages \(pages) 0 R /AcroForm << /Fields [\(fields)] /DR << \(fonts) >> /DA (/Helv 0 Tf 0 g) >> >>" }
        w.set(page, pageBody("\(name) 0 R"))
        w.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        w.set(catalog, catalogBody("\(name) 0 R"))
        let first = w.build(catalog)
        let prevXref = Int(match(#"startxref\n(\d+)"#, String(String.UnicodeScalarView(first.map { Unicode.Scalar($0) })))?[1] ?? "") ?? 0
        // The update: the field's new value, a new field, the page and catalog that list it.
        let added = w.count + 1
        let updates: [(Int, String)] = [
            (name, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Nombre) /Ff 0 /DA (/Helv 10 Tf 0 g) /V (Nuevo) /Rect \(r(72, 700, 200, 20)) /P \(page) 0 R /F 4 >>"),
            (added, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Agregado) /DA (/Helv 10 Tf 0 g) /Rect \(r(72, 660, 200, 20)) /P \(page) 0 R /F 4 >>"),
            (page, pageBody("\(name) 0 R \(added) 0 R")),
            (catalog, catalogBody("\(name) 0 R \(added) 0 R")),
        ]
        var sb = ""
        var offsets: [Int: Int] = [:]
        for (id, body) in updates {
            offsets[id] = first.count + latin1(sb).count
            sb += "\(id) 0 obj\n\(body)\nendobj\n"
        }
        let xref = first.count + latin1(sb).count
        sb += "xref\n0 1\n0000000000 65535 f \n"
        for id in offsets.keys.sorted() { sb += "\(id) 1\n" + String(format: "%010d 00000 n \n", offsets[id] ?? 0) }
        sb += "trailer\n<< /Size \(added + 1) /Root \(catalog) 0 R /Prev \(prevXref) >>\nstartxref\n\(xref)\n%%EOF\n"
        return first + latin1(sb)
    }

    /// Fields and widgets stored in an object stream, found through a cross-reference stream.
    private static func objStm() -> [UInt8] {
        // Objects: 1 catalog, 2 pages, 3 page, 4 contents, 5 object stream, 6 xref stream; 7..9 fields inside 5.
        let inside = [
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Comprimido) /DA (/Helv 10 Tf 0 g) /Rect \(r(72, 700, 200, 20)) /P 3 0 R /F 4 >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Otro) /DA (/Helv 10 Tf 0 g) /MaxLen 20 /Rect \(r(72, 660, 200, 20)) /P 3 0 R /F 4 >>",
            "<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (Lista) /Opt [(Si) (No)] /DA (/Helv 10 Tf 0 g) /Rect \(r(72, 620, 200, 20)) /P 3 0 R /F 4 >>",
        ]
        var header = "", body = ""
        for (i, s) in inside.enumerated() {
            header += "\(7 + i) \(body.utf8.count) "
            body += s + "\n"
        }
        let objstm = header + body
        let content = "BT /F1 12 Tf 72 740 Td (Object stream) Tj ET"
        let objs = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [7 0 R 8 0 R 9 0 R] /DR << \(fonts) >> /DA (/Helv 0 Tf 0 g) >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \(pageFonts) /Contents 4 0 R /Annots [7 0 R 8 0 R 9 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /ObjStm /N \(inside.count) /First \(header.utf8.count) /Length \(objstm.utf8.count) >>\nstream\n\(objstm)\nendstream",
        ]
        var sb = "%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n"
        var offsets: [Int] = []
        for (i, o) in objs.enumerated() {
            offsets.append(latin1(sb).count)
            sb += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xrefOffset = latin1(sb).count
        func row(_ type: Int, _ a: Int, _ b: Int) -> [UInt8] {
            [UInt8(type), UInt8(a >> 24 & 255), UInt8(a >> 16 & 255), UInt8(a >> 8 & 255), UInt8(a & 255), UInt8(b >> 8 & 255), UInt8(b & 255)]
        }
        var rows = [row(0, 0, 65535)]
        rows += offsets.map { row(1, $0, 0) }
        rows.append(row(1, xrefOffset, 0)) // 6: this stream
        for i in inside.indices { rows.append(row(2, 5, i)) }
        let data = rows.flatMap { $0 }
        let head = latin1(sb + "6 0 obj\n<< /Type /XRef /Size \(rows.count) /W [1 4 2] /Root 1 0 R /Length \(data.count) >>\nstream\n")
        return head + data + latin1("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n")
    }

    // MARK: The Mac's additions

    /// ca-ftb-540's SSN box and the like: AFSpecial with a MaxLen of just the digits, and a mask holding its own dashes.
    private static func special() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        func js(_ s: String) -> Int { w.add("<< /S /JavaScript /JS (\(s.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)"))) >>") }
        var ids: [Int] = []
        func add(_ t: String, _ y: Double, _ format: String, _ keystroke: String, _ extra: String) {
            let aa = "/AA << /F \(js(format)) 0 R /K \(js(keystroke)) 0 R >>"
            ids.append(addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Tx /T (\(t)) /DA (/Helv 10 Tf 0 g) \(extra) \(aa) /Rect \(r(72, y, 200, 20)) /P {P} /F 4"), page))
        }
        add("SSN", 700, "AFSpecial_Format(3);", "AFSpecial_Keystroke(3);", "/Ff \(1 << 24) /MaxLen 9")
        add("Phone", 660, "AFSpecial_Format(2);", "AFSpecial_Keystroke(2);", "/MaxLen 10")
        add("ZipPlus4", 620, "AFSpecial_Format(1);", "AFSpecial_Keystroke(1);", "/MaxLen 9")
        add("Zip", 580, "AFSpecial_Format(0);", "AFSpecial_Keystroke(0);", "/MaxLen 5")
        add("SSNWide", 540, "AFSpecial_Format(3);", "AFSpecial_Keystroke(3);", "")
        add("Masked", 500, "AFSpecial_KeystrokeEx(\"999-99-9999\");", "AFSpecial_KeystrokeEx(\"999-99-9999\");", "/MaxLen 11")
        return finish(w, catalog, pages, page, annots: ids, fields: ids, label: "Masked fields", acro: "/DA (/Helv 0 Tf 0 g)")
    }

    /// A small form encrypted the way USCIS's are: it opens without a password, an owner password guards the rest.
    private static func encrypted(_ method: String, fill: Bool, annotate: Bool) -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        func js(_ s: String) -> Int { w.add("<< /S /JavaScript /JS (\(s.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)"))) >>") }
        let name = addWidget(w, tx("Nombre", 72, 700, extra: "/V (Viejo)"), page)
        let amount = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Tx /T (Monto) /DA (/Helv 10 Tf 0 g) /AA << /F \(js("AFNumber_Format(2, 0, 0, 0, \"\", true);")) 0 R /K \(js("AFNumber_Keystroke(2, 0, 0, 0, \"\", true);")) 0 R >> /Rect \(r(72, 660, 200, 20)) /P {P} /F 4"), page)
        let box = addWidget(w, check("Acepto", 72, 620, ap: true), page)
        let list = addWidget(w, field("Pais", "/FT /Ch /Ff 131072 /Opt [(PR) (US)] /V (PR) /DA (/Helv 10 Tf 0 g)", 72, 580, 200, 20), page)
        let ids = [name, amount, box, list]
        let plain = finish(w, catalog, pages, page, annots: ids, fields: ids, label: "Encrypted form", acro: "/DA (/Helv 0 Tf 0 g)")
        var permissions = PdfPermissions(print: .highResolution, copy: false, modify: false, annotate: annotate, fillForms: fill, assemble: false)
        if method == "rc4-40" { permissions.fillForms = true }
        let p = PdfSecurity.pValue(permissions)
        guard let doc = try? MuDoc.open(plain),
              let bytes = try? doc.write("garbage=compact,encrypt=\(method),user-password=,owner-password=owner-secret,permissions=\(p)") else { return plain }
        return bytes
    }

    /// pdfjs-opt_demo and qpdf-form-errors in small: a radio button its parent's /Kids leaves out; a nameless widget in /Fields.
    private static func kidsMissing() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let dot = "q 0 g 7 7 m 7 9.2 5.2 11 3 11 c 0.8 11 -1 9.2 -1 7 c -1 4.8 0.8 3 3 3 c 5.2 3 7 4.8 7 7 c f Q"
        let group = w.reserve()
        var kids: [Int] = []
        for (i, state) in ["A", "B"].enumerated() {
            let x = 72 + Double(i) * 40
            kids.append(addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /AS /Off /Rect \(r(x, 700, 14, 14)) /P {P} /F 4 /OnState /\(state)", ap: dot, apOff: ""), page, parent: "/Parent \(group) 0 R"))
        }
        w.set(group, "<< /FT /Btn /Ff \(1 << 15) /T (veg) /V /Off /DA (/ZaDb 0 Tf 0 g) >>") // no /Kids at all
        let text = w.reserve()
        let kid = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /Rect \(r(72, 650, 200, 20)) /P {P} /F 4"), page, parent: "/Parent \(text) 0 R")
        let named = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /T (beside) /FT /Tx /DA (/Helv 10 Tf 0 g) /Rect \(r(72, 620, 200, 20)) /P {P} /F 4"), page, parent: "/Parent \(text) 0 R")
        w.set(text, "<< /FT /Tx /T (parent) /DA (/Helv 10 Tf 0 g) /Kids [\(kid) 0 R \(named) 0 R] >>")
        return finish(w, catalog, pages, page, annots: kids + [kid, named], fields: [group, text], label: "Widgets left out of /Kids")
    }

    /// pdflib-fancy_fields in small: the widget of a combo holds its own /I and /V, stale after the field is set.
    private static func staleWidgetIndex() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let parent = w.reserve()
        let kid = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /Opt [(One) (Two) (Three)] /I [0] /V (One) /DA (/Helv 10 Tf 0 g) /Rect \(r(72, 700, 200, 20)) /P {P} /F 4"), page, parent: "/Parent \(parent) 0 R")
        w.set(parent, "<< /T (Pick) /FT /Ch /Ff 131072 /Opt [(One) (Two) (Three)] /I [0] /V (One) /DA (/Helv 10 Tf 0 g) /Kids [\(kid) 0 R] >>")
        return finish(w, catalog, pages, page, annots: [kid], fields: [parent], label: "Stale index")
    }

    /// pdfjs-checkbox_no_appearance and pypdf-pdflatex-forms in small.
    private static func boxNoFace() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let bare = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Btn /T (cbOn) /V /Off /AS /Off /Rect \(r(72, 700, 14, 14)) /P {P} /F 4"), page)
        let empty = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /FT /Btn /T (Check) /V /Off /AS /Off /MK << /CA (4) >> /DA (/ZaDb 0 Tf 0 g) /AP << /N << /Yes << >> >> >> /Rect \(r(72, 660, 14, 14)) /P {P} /F 4"), page)
        return finish(w, catalog, pages, page, annots: [bare, empty], fields: [bare, empty], label: "Boxes without faces")
    }

    /// qpdf-form-fields-and-annotations-shared and qpdf-form-document-defaults in small.
    private static func sharedWidget() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page1 = w.reserve(), page2 = w.reserve()
        let shared = addWidget(w, tx("Both", 72, 700), page1)
        let parent = w.reserve()
        let orphan = addWidget(w, Spec(dict: "/Type /Annot /Subtype /Widget /Rect \(r(72, 660, 200, 20)) /P {P} /F 4"), page1)
        w.set(parent, "<< /T (Orphan) /FT /Tx /DA (/Helv 10 Tf 0 g) /Kids [\(orphan) 0 R] >>")
        let labels = w.stream("", "BT /F1 12 Tf 72 740 Td (Shared widget) Tj ET")
        for p in [page1, page2] {
            let annots = p == page1 ? "\(shared) 0 R \(orphan) 0 R" : "\(shared) 0 R"
            w.set(p, "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 612 792] \(pageFonts) /Contents \(labels) 0 R /Annots [\(annots)] >>")
        }
        w.set(pages, "<< /Type /Pages /Kids [\(page1) 0 R \(page2) 0 R] /Count 2 >>")
        w.set(catalog, "<< /Type /Catalog /Pages \(pages) 0 R /AcroForm << /Fields [\(shared) 0 R \(parent) 0 R] /DR << \(fonts) >> /DA (/Helv 0 Tf 0 g) >> >>")
        return w.build(catalog)
    }

    /// One page with a text field (name = Ana), a note and a bookmark, for the damaged files (Windows' `DamagedFileTests`).
    private static func damageable() -> [UInt8] {
        let w = Writer()
        let catalog = w.reserve(), pages = w.reserve(), page = w.reserve()
        let name = addWidget(w, tx("name", 72, 700, extra: "/V (Ana)"), page)
        let note = w.add("<< /Type /Annot /Subtype /Text /P \(page) 0 R /Rect [400 700 420 720] /Contents (Check this) >>")
        let outlines = w.reserve(), mark = w.reserve()
        w.set(outlines, "<< /Type /Outlines /First \(mark) 0 R /Last \(mark) 0 R /Count 1 >>")
        w.set(mark, "<< /Title (Chapter one) /Parent \(outlines) 0 R /Dest [\(page) 0 R /Fit] >>")
        let labels = w.stream("", "BT /F1 12 Tf 72 650 Td (12 0 obj) Tj ET\n")
        w.set(page, "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 612 792] \(pageFonts) /Contents \(labels) 0 R /Annots [\(name) 0 R \(note) 0 R] >>")
        w.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        w.set(catalog, "<< /Type /Catalog /Pages \(pages) 0 R /Outlines \(outlines) 0 R /AcroForm << /Fields [\(name) 0 R] /DR << \(fonts) >> /DA (/Helv 0 Tf 0 g) >> >>")
        return w.build(catalog)
    }

    enum Damage {
        private static func text(_ b: [UInt8]) -> String { String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) })) }

        /// Every row of the xref table off by two bytes.
        static func brokenOffsets(_ sound: [UInt8]) -> [UInt8] {
            let s = text(sound)
            guard let re = try? NSRegularExpression(pattern: #"(\d{10}) 00000 n"#) else { return sound }
            var out = s
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let whole = Range(m.range, in: out), let v = Range(m.range(at: 1), in: out), let n = Int(out[v]) else { continue }
                out.replaceSubrange(whole, with: String(format: "%010d 00000 n", n + 2))
            }
            return latin1(out)
        }

        /// Saved over a longer older copy of itself: after the new %%EOF, the old file's last object, the end of its xref
        /// table, its trailer and a startxref into the middle of the new file.
        static func staleTail(_ sound: [UInt8]) -> [UInt8] {
            let tail = "ndobj\n4 0 obj\n<< /Length 0 >>\nendobj\n0000000099 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n\(sound.count - 30)\n%%EOF\n"
            return sound + latin1(tail)
        }

        /// A download cut off before the cross-reference table.
        static func truncated(_ sound: [UInt8]) -> [UInt8] {
            guard let r = sound.firstRange(of: Array("xref\n".utf8)) else { return sound }
            return Array(sound[..<r.lowerBound])
        }

        /// The object stream's row in the cross-reference stream points seven bytes off.
        static func brokenObjStm(_ sound: [UInt8]) -> [UInt8] {
            guard let start = sound.firstRange(of: Array("/W [1 4 2]".utf8)), let stream = sound[start.upperBound...].firstRange(of: Array("stream\n".utf8)) else { return sound }
            var out = sound
            let row = stream.upperBound + 7 * 5 // object 5
            out[row + 4] = out[row + 4] &+ 7
            return out
        }
    }
}
