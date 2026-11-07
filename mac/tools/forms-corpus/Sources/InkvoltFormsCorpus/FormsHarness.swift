import Foundation
@testable import PdfCore

/// Fills one form the way the app does (`FormEditor.read` for the widgets the page view shows, `FormEditor.fill` for what a
/// typed or clicked value becomes, `FieldKeystrokes` for typing into a field with a keystroke script), saves it, reads it
/// back with FormEditor, checks every filled widget's appearance and what MuPDF draws, and leaves the pdf.js comparison to
/// `PdfJs.compare`. Windows' `FormsHarness`, with typing added (Windows has its UI pass for that) and the encryption, tab
/// order, comments and bookmarks compared before and after.
enum FormsHarness {
    static func fillOne(_ name: String, _ data: [UInt8], _ outDir: String, password: String? = nil) -> FormReport {
        var report = FormReport()
        report.name = name
        let start = Date()
        run(&report, data, outDir, password)
        report.ms = Int((Date().timeIntervalSince(start) * 1000).rounded()) // bounded: a run's seconds
        if report.skip != nil {
            report.status = "skip"
        } else {
            report.status = report.failures.isEmpty ? "pass" : "fail"
        }
        return report
    }

    private static func run(_ report: inout FormReport, _ data: [UInt8], _ outDir: String, _ password: String?) {
        report.features = features(data, password)
        let widgets: [FormWidget]
        let dataFields: [FormDataField]
        do {
            widgets = try FormEditor.read(data, password)
            report.widgets = widgets.count
            report.names = unique(widgets.map(\.fieldName))
            report.fields = report.names.count
            for w in widgets { report.widgetCounts[w.fieldName, default: 0] += 1 }
            if widgets.isEmpty {
                let xfa = (try? FormEditor.hasXfa(data, password)) ?? (false, false)
                report.skip = xfa.1 ? "XFA-only form" : xfa.0 ? "XFA, no widgets" : "no form fields"
                return
            }
            dataFields = try FormEditor.dataFields(data, password)
        } catch {
            report.fail("read-exception", "", signature(error))
            return
        }
        // Hidden widgets aren't on the page view, but their fields are still found (by data import, scripts).
        report.names = unique(report.names + dataFields.map(\.name))
        let scripts = fieldScripts(data, password)
        let hasScripts = scripts.values.contains { $0.format != nil || $0.keystroke != nil }
            || widgets.contains { $0.calculated || !$0.triggers.isEmpty }
        if hasScripts { report.features.append("JavaScript") }

        var values: [String: String] = [:]
        var ordinal = 0
        for f in dataFields {
            let ws = widgets.filter { $0.fieldName == f.name }
            if f.readOnly || ws.isEmpty || ws.allSatisfy(\.readOnly) || ws.contains(where: \.calculated) { continue }
            ordinal += 1
            let js = scripts[f.name]
            let format = FieldValues.formatOf(format: js?.format, keystroke: js?.keystroke)
            var state: String?
            let sent: String
            switch f.kind {
            case .text:
                let comb = (js?.flags ?? 0) & (1 << 24) != 0 && (js?.flags ?? 0) & ((1 << 12) | (1 << 13)) == 0
                sent = FieldValues.textValue(ordinal, format, maxLen: f.maxLength, multiline: ws.contains(where: \.multiline), comb: comb)
            case .checkBox:
                guard let on = ws.lazy.compactMap(\.onState).first else {
                    report.fail("checkbox-cannot-be-ticked", f.name, "no widget has an on appearance, so the page view refuses to tick it")
                    continue
                }
                state = on
                sent = on
            case .radio:
                guard let last = unique(ws.compactMap(\.onState)).last else {
                    report.fail("radio-cannot-be-chosen", f.name, "no button has an on appearance")
                    continue
                }
                state = last
                sent = last
            case .choice:
                if f.options.isEmpty {
                    if !f.editable {
                        report.notes.append("\(f.name): choice field without options")
                        continue
                    }
                    sent = "Ink\(ordinal)"
                } else if f.multiSelect && f.options.count > 2 {
                    sent = f.options[1] + "\n" + f.options[2]
                } else {
                    sent = f.options.count > 1 && !f.options[1].allSatisfy(\.isWhitespace) ? f.options[1] : f.options[0]
                }
            default:
                continue
            }
            values[f.name] = sent
            report.plan.append(Planned(name: f.name, kind: kindName(f.kind), sent: sent, state: state, password: ws.contains(where: \.password), format: format))
        }
        if values.isEmpty {
            report.notes.append("nothing to fill (every field read-only or calculated)")
            return
        }

        // Fill as the page view does (one batch of values); a value a script refuses is tried again as digits, then as a
        // date, as a person would.
        var saved: [UInt8]
        var rejected: [String: String] = [:]
        do {
            let first = try fill(data, password, values)
            saved = first.data
            for r in first.rejected { rejected[r.fieldName] = r.message }
            for alternate in ["1234", "1", "03/15/2024"] where !rejected.isEmpty {
                var retry: [String: String] = [:]
                for name in rejected.keys {
                    if let i = report.plan.firstIndex(where: { $0.name == name }), report.plan[i].kind == "Text" {
                        retry[name] = alternate
                        report.plan[i].sent = alternate
                    }
                }
                if retry.isEmpty { break }
                let again = try fill(saved, password, retry)
                saved = again.data
                rejected = [:]
                for r in again.rejected { rejected[r.fieldName] = r.message }
            }
        } catch {
            report.fail("fill-exception", "", signature(error))
            return
        }
        for (name, why) in rejected {
            report.fail("value-rejected-by-script", name, why.isEmpty ? "(refused in a dialog)" : why.replacingOccurrences(of: "\n", with: " "))
        }
        report.plan.removeAll { rejected[$0.name] != nil }
        report.filled = report.plan.count

        let filledPath = (outDir as NSString).appendingPathComponent(report.name + ".filled.pdf")
        FileManager.default.createFile(atPath: filledPath, contents: Data(saved))

        // Reopen and read back.
        let after: [FormDataField]
        let afterWidgets: [FormWidget]
        do {
            after = try FormEditor.dataFields(saved, password)
            afterWidgets = try FormEditor.read(saved, password)
        } catch {
            report.fail("reopen-exception", "", signature(error))
            return
        }
        var afterByName: [String: FormDataField] = [:]
        for f in after where afterByName[f.name] == nil { afterByName[f.name] = f }
        var aloneTries = 0
        for i in report.plan.indices {
            let p = report.plan[i]
            guard let got = afterByName[p.name] else {
                report.fail("field-gone-after-save", p.name, "")
                continue
            }
            // What the field shows: a text field's value through its format script, a choice's display text.
            var display = afterWidgets.first { $0.fieldName == p.name }?.displayValue ?? got.value
            if p.kind == "Choice", let li = got.options.firstIndex(of: got.value), li < got.labels.count { display = got.labels[li] }
            report.plan[i].stored = got.value
            report.plan[i].display = display
            let ok: Bool
            switch p.kind {
            case "Text":
                ok = got.value == p.sent || unifiedLines(got.value) == p.sent || (!digits(got.value).isEmpty && digits(got.value) == digits(p.sent))
            case "Choice":
                ok = got.value == p.sent || got.value.replacingOccurrences(of: "\r", with: "") == p.sent
            default:
                ok = got.value != "Off" && !got.value.isEmpty
            }
            if ok, let want = FieldValues.spanishAmount(p.format, p.sent), !normalize(display).contains(want) {
                report.fail("spanish-number-misread", p.name, "\(p.format): typed '\(p.sent)', stored '\(esc(got.value))', shows '\(esc(display))' (expected \(want))")
            }
            if ok { continue }
            // Filled alone, does it keep the value? Then another field's script changed it (the form's own doing). A few
            // are enough to tell; each opens and saves the form.
            aloneTries += 1
            if aloneTries <= 8, fillAlone(data, password, p.name, p.sent) == p.sent {
                report.notes.append("\(p.name): kept alone, changed to '\(esc(got.value))' when filled with the others (a script of the form)")
                continue
            }
            let kind = got.value.isEmpty || got.value == "Off" ? "value-not-kept" : "value-changed"
            report.fail(kind, p.name, "\(p.kind) \(p.format): sent '\(esc(p.sent))', read back '\(esc(got.value))'")
        }

        // Fields nobody filled keep their values, unless the form's scripts or calculations set them.
        let planned = Set(report.plan.map(\.name))
        let calculated = Set(widgets.filter(\.calculated).map(\.fieldName))
        for f in dataFields where !planned.contains(f.name) && !calculated.contains(f.name) {
            guard let now = afterByName[f.name], now.value != f.value else { continue }
            if hasScripts {
                report.notes.append("\(f.name): not filled, changed '\(esc(f.value))' → '\(esc(now.value))' (the form has scripts)")
            } else {
                report.fail("untouched-field-changed", f.name, "\(kindName(f.kind)): '\(esc(f.value))' became '\(esc(now.value))' though it wasn't filled")
            }
        }

        checkAppearances(&report, saved, password)
        checkMuPdf(&report, saved, afterWidgets, password)
        checkCalculations(&report, widgets, afterWidgets)
        checkTabOrder(&report, widgets, afterWidgets)
        checkEncryption(&report, data, saved, password)
        checkOtherContent(&report, data, saved, password)
        checkTyping(&report, data, password, scripts)
    }

    /// `FormEditor.fill`; a signed file it can't append to is saved whole, as the app does once the person agrees.
    private static func fill(_ data: [UInt8], _ password: String?, _ values: [String: String]) throws -> FormFillResult {
        do {
            return try FormEditor.fill(data, password, values)
        } catch is SignaturesWouldBreak {
            var result: FormFillResult?
            _ = try SignedEdits.run({
                let r = try FormEditor.fill(data, password, values)
                result = r
                return r.data
            }, allowRewrite: true)
            guard let result else { throw PdfEditError("no result") }
            return result
        }
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func kindName(_ k: FormFieldKind) -> String {
        switch k {
        case .text: return "Text"
        case .checkBox: return "CheckBox"
        case .radio: return "Radio"
        case .choice: return "Choice"
        case .pushButton: return "PushButton"
        case .signature: return "Signature"
        }
    }

    /// One field filled by itself on the original: the value it then holds, or nil when that fails.
    private static func fillAlone(_ data: [UInt8], _ password: String?, _ name: String, _ value: String) -> String? {
        guard let saved = try? fill(data, password, [name: value]).data else { return nil }
        return (try? FormEditor.dataFields(saved, password))?.first { $0.name == name }?.value
    }

    // MARK: Scripts and features, read from the objects

    struct FieldScripts {
        var format: String?
        var keystroke: String?
        var flags: Int
    }

    /// The AcroForm's field tree read top-down from /Fields, as Acrobat reads it: each widget's chain of field
    /// dictionaries (itself first). A widget missing its /Parent link is still named by the tree.
    struct FieldTree {
        private var chains: [UInt: [PObj]] = [:]

        init(_ doc: MuDoc) {
            for f in doc.catalog.dict("AcroForm")?.array("Fields")?.elements ?? [] where f.isDict { walk(f, []) }
        }

        private mutating func walk(_ d: PObj, _ above: [PObj]) {
            if above.count > 32 || chains[d.identity] != nil || above.contains(where: { $0.identity == d.identity }) { return }
            let chain = [d] + above
            chains[d.identity] = chain
            for k in d.array("Kids")?.elements ?? [] where k.isDict { walk(k, chain) }
        }

        func chain(_ widget: PObj) -> [PObj] {
            if let c = chains[widget.identity] { return c }
            var list: [PObj] = []
            var d: PObj? = widget
            while let cur = d, list.count < 64, !list.contains(where: { $0.identity == cur.identity }) {
                list.append(cur)
                d = cur.dict("Parent")
            }
            return list
        }

        func fullName(_ widget: PObj) -> String {
            chain(widget).reversed().compactMap { d in d["T"].flatMap { $0.kind == .string ? $0.text : nil } }.joined(separator: ".")
        }
    }

    static func widgets(on page: PObj) -> [PObj] {
        (page.array("Annots")?.elements ?? []).filter { $0.isDict && $0.name("Subtype") == "Widget" }
    }

    private static func fieldScripts(_ data: [UInt8], _ password: String?) -> [String: FieldScripts] {
        var result: [String: FieldScripts] = [:]
        guard let doc = try? PdfEdit.openToRead(data, password), let pages = try? doc.pages() else { return result }
        let tree = FieldTree(doc)
        func script(_ chain: [PObj], _ key: String) -> String? {
            for d in chain {
                if let action = d.dict("AA")?.dict(key), let text = FormEditor.scriptText(action["JS"]) { return text }
            }
            return nil
        }
        for page in pages {
            for w in widgets(on: page) {
                let chain = tree.chain(w)
                let name = tree.fullName(w)
                if name.isEmpty { continue }
                let f = script(chain, "F"), k = script(chain, "K")
                let flags = chain.lazy.compactMap { $0.int("Ff") }.first ?? 0
                if let had = result[name] {
                    result[name] = FieldScripts(format: had.format ?? f, keystroke: had.keystroke ?? k, flags: had.flags | flags)
                } else {
                    result[name] = FieldScripts(format: f, keystroke: k, flags: flags)
                }
            }
        }
        return result
    }

    /// Traits worth grouping failures by: producer, NeedAppearances, XFA, object streams, incremental updates, encryption.
    private static func features(_ data: [UInt8], _ password: String?) -> [String] {
        var features: [String] = []
        var eofs = 0
        var from = data.startIndex
        while let r = data[from...].firstRange(of: Array("%%EOF".utf8)) {
            eofs += 1
            from = r.upperBound
        }
        if eofs > 1 { features.append("incremental-updates:\(eofs - 1)") }
        if data.firstRange(of: Array("/ObjStm".utf8)) != nil { features.append("object-streams") }
        guard let doc = try? PdfEdit.openToRead(data, password) else {
            features.append("cannot-read")
            return features
        }
        if let info = try? doc.encryptInfo() { features.append("encrypted:v\(info.v)r\(info.r)") }
        if let acro = doc.catalog.dict("AcroForm") {
            if acro["NeedAppearances"]?.bool == true { features.append("NeedAppearances") }
            if acro.has("XFA") { features.append("XFA") }
            if acro.has("CO") { features.append("calculation-order") }
        }
        if !doc.canAppend { features.append("repaired") }
        if let producer = doc.trailer.dict("Info")?.text("Producer"), !producer.isEmpty { features.append("producer:" + producer) }
        return features
    }

    // MARK: Appearances

    /// Every widget of a filled field has a normal appearance; a check box or radio shows the state it was set to; a text
    /// or combo field's appearance stream draws the value (as the format script shows it).
    private static func checkAppearances(_ report: inout FormReport, _ saved: [UInt8], _ password: String?) {
        var plan: [String: Planned] = [:]
        for p in report.plan { plan[p.name] = p }
        guard let doc = try? PdfEdit.openToRead(saved, password), let pages = try? doc.pages() else { return }
        let needs = doc.catalog.dict("AcroForm")?["NeedAppearances"]?.bool == true
        if needs { report.notes.append("saved with /NeedAppearances true") }
        var seen = Set<String>()
        let tree = FieldTree(doc)
        for page in pages {
            for w in widgets(on: page) {
                let name = tree.fullName(w)
                guard let p = plan[name] else { continue }
                seen.insert(name)
                guard let n = w.dict("AP")?["N"] else {
                    report.fail("appearance-missing", name, "\(p.kind)\(needs ? " (NeedAppearances set)" : "")")
                    continue
                }
                if p.kind == "CheckBox" || p.kind == "Radio" {
                    let states = n.isDict && !n.isStream ? n.keys.filter { $0 != "Off" } : []
                    let shown = w.name("AS") ?? ""
                    if states.isEmpty {
                        report.fail("appearance-no-states", name, "\(p.kind): /AP /N has no on state, /AS=\(shown)")
                        continue
                    }
                    if let state = p.state, states.contains(state), shown != state {
                        report.fail("appearance-wrong-state", name, "\(p.kind): /AS=\(shown), set to \(state)")
                    }
                    if !shown.isEmpty && shown != "Off" {
                        if !states.contains(shown) {
                            report.fail("appearance-state-undrawn", name, "/AS=\(shown) has no face; faces: \(states.joined(separator: ","))")
                        } else if let face = n[shown], !face.isStream {
                            report.fail("appearance-state-undrawn", name, "/AS=\(shown): its face is not a stream")
                        }
                    }
                    continue
                }
                guard n.isStream else {
                    report.fail("appearance-missing", name, "\(p.kind): /AP /N is not a stream")
                    continue
                }
                if p.password || (p.kind == "Choice" && p.sent.contains("\n")) { continue }
                if usesTwoByteFont(n) {
                    report.notes.append("\(name): appearance in a two-byte font, text not compared")
                    continue
                }
                let drawn = normalize(winAnsi(strings(n.streamData ?? []).joined()))
                let expected = normalize(p.display.isEmpty ? p.stored : p.display)
                if expected.isEmpty { continue }
                // A comb field's cells show what was typed when the format's separators wouldn't fit them.
                if !drawn.contains(String(expected.prefix(24))) && !(p.format != "plain" && drawn == normalize(p.stored)) {
                    report.fail("appearance-text-mismatch", name, "\(p.kind) \(p.format): draws '\(esc(drawn, 60))', value shows '\(esc(expected))'")
                }
            }
        }
        for p in report.plan where !seen.contains(p.name) {
            report.notes.append("\(p.name): no widget found by its full name in the saved file (name read differently)")
        }
    }

    private static func usesTwoByteFont(_ form: PObj) -> Bool {
        guard let fonts = form.dict("Resources")?.dict("Font") else { return false }
        return fonts.keys.contains { fonts.dict($0)?.name("Subtype") == "Type0" }
    }

    /// Bytes 0x80–0x9F as WinAnsiEncoding reads them; the rest are Latin-1 already.
    private static func winAnsi(_ s: String) -> String {
        let high = Array("€\u{81}‚ƒ„…†‡ˆ‰Š‹Œ\u{8D}Ž\u{8F}\u{90}‘’“”•–—˜™š›œ\u{9D}žŸ")
        return String(s.map { c -> Character in
            if let u = c.unicodeScalars.first?.value, u >= 0x80, u <= 0x9F { return high[Int(u - 0x80)] }
            return c
        })
    }

    /// The string operands of a content stream, decoded byte for byte (simple fonts).
    private static func strings(_ content: [UInt8]) -> [String] {
        var out: [String] = []
        func text(_ bytes: [UInt8]) -> String { String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) })) }
        var i = 0
        while i < content.count {
            let c = content[i]
            if c == UInt8(ascii: "%") {
                while i < content.count && content[i] != 10 && content[i] != 13 { i += 1 }
            } else if c == UInt8(ascii: "(") {
                var bytes: [UInt8] = []
                var depth = 1
                i += 1
                while i < content.count && depth > 0 {
                    let b = content[i]
                    if b == UInt8(ascii: "\\") && i + 1 < content.count {
                        i += 1
                        let e = content[i]
                        if e >= 48 && e <= 55 {
                            var v = Int(e - 48), k = 0
                            while k < 2 && i + 1 < content.count && content[i + 1] >= 48 && content[i + 1] <= 55 {
                                i += 1
                                v = v * 8 + Int(content[i] - 48)
                                k += 1
                            }
                            bytes.append(UInt8(v & 255))
                        } else {
                            switch e {
                            case UInt8(ascii: "n"): bytes.append(10)
                            case UInt8(ascii: "r"): bytes.append(13)
                            case UInt8(ascii: "t"): bytes.append(9)
                            case UInt8(ascii: "b"): bytes.append(8)
                            case UInt8(ascii: "f"): bytes.append(12)
                            case 10, 13: break
                            default: bytes.append(e)
                            }
                        }
                    } else {
                        if b == UInt8(ascii: "(") { depth += 1 }
                        if b == UInt8(ascii: ")") { depth -= 1 }
                        if depth > 0 { bytes.append(b) }
                    }
                    i += 1
                }
                out.append(text(bytes))
                continue
            } else if c == UInt8(ascii: "<") && i + 1 < content.count && content[i + 1] != UInt8(ascii: "<") {
                var hex: [UInt8] = []
                i += 1
                while i < content.count && content[i] != UInt8(ascii: ">") {
                    if let d = Character(Unicode.Scalar(content[i])).hexDigitValue { hex.append(UInt8(d)) }
                    i += 1
                }
                if hex.count % 2 == 1 { hex.append(0) }
                out.append(text(stride(from: 0, to: hex.count, by: 2).map { hex[$0] * 16 + hex[$0 + 1] }))
            } else if c == UInt8(ascii: "<") {
                i += 1
            }
            i += 1
        }
        return out
    }

    /// What MuPDF draws on the saved file's pages (annotations included) holds each filled text and combo value as its
    /// format shows it.
    private static func checkMuPdf(_ report: inout FormReport, _ saved: [UInt8], _ afterWidgets: [FormWidget], _ password: String?) {
        var byPage: [Int: String] = [:]
        do {
            let engine = try PdfEngine.open(saved, password: password)
            for p in report.plan {
                if (p.kind != "Text" && p.kind != "Choice") || p.password || (p.sent.contains("\n") && p.kind == "Choice") { continue }
                let expected = normalize(p.display.isEmpty ? p.stored : p.display)
                if expected.isEmpty { continue }
                let pages = Set(afterWidgets.filter { $0.fieldName == p.name && $0.rect.width > 1 && $0.rect.height > 1 }.map(\.pageIndex)).sorted()
                if pages.isEmpty { continue }
                var found = false
                for page in pages {
                    if byPage[page] == nil {
                        byPage[page] = normalize(try engine.textLines(page, annotations: true).map(\.text).joined())
                    }
                    if byPage[page]?.contains(String(expected.prefix(24))) == true { found = true }
                }
                if !found { report.fail("mupdf-does-not-show-value", p.name, "\(p.kind) \(p.format): '\(esc(expected))' not in MuPDF's text of page \(pages[0] + 1)") }
            }
        } catch {
            report.fail("mupdf-cannot-read-saved", "", signature(error))
        }
    }

    /// Calculated fields that kept their value although their inputs were filled: noted, not failed.
    private static func checkCalculations(_ report: inout FormReport, _ before: [FormWidget], _ after: [FormWidget]) {
        let calc = Set(before.filter(\.calculated).map(\.fieldName))
        if calc.isEmpty { return }
        var was: [String: String] = [:], now: [String: String] = [:]
        for w in before where was[w.fieldName] == nil { was[w.fieldName] = w.value }
        for w in after where now[w.fieldName] == nil { now[w.fieldName] = w.value }
        let changed = calc.filter { now[$0] != nil && was[$0] != nil && now[$0] != was[$0] }.count
        report.notes.append("calculated fields: \(changed) of \(calc.count) changed after filling")
        if changed == 0 { report.notes.append("calc-not-updated: no calculated field changed") }
    }

    /// Tab goes through the fields in the same order after a fill: the same fields, on the same pages. Places may round
    /// differently once the file is rewritten; that must not reorder them.
    private static func checkTabOrder(_ report: inout FormReport, _ before: [FormWidget], _ after: [FormWidget]) {
        let a = before.map { "\($0.pageIndex):\($0.fieldName)" }, b = after.map { "\($0.pageIndex):\($0.fieldName)" }
        if a == b { return }
        if a.count != b.count {
            report.fail("widgets-changed-after-save", "", "\(a.count) widgets on the page view before the fill, \(b.count) after")
            return
        }
        let i = a.indices.first { a[$0] != b[$0] } ?? 0
        report.fail("tab-order-changed", a[i], "position \(i): was \(esc(a[i])), now \(esc(b[i]))")
    }

    /// The filled file is protected exactly as the original was: same handler, permissions, still opening the same way.
    private static func checkEncryption(_ report: inout FormReport, _ data: [UInt8], _ saved: [UInt8], _ password: String?) {
        guard let original = try? MuDoc.open(data), let filled = try? MuDoc.open(saved) else { return }
        let a = try? original.encryptInfo(), b = try? filled.encryptInfo()
        let was = a.flatMap { $0 }, now = b.flatMap { $0 }
        if was == nil && now == nil { return }
        guard let was, let now else {
            report.fail("encryption-lost", "", "was \(was == nil ? "not encrypted" : "encrypted"), now \(now == nil ? "not encrypted" : "encrypted")")
            return
        }
        if was.v != now.v || was.r != now.r || was.p != now.p || was.cfm != now.cfm || was.length != now.length {
            report.fail("encryption-changed", "", "V\(was.v) R\(was.r) P\(was.p) \(was.cfm) became V\(now.v) R\(now.r) P\(now.p) \(now.cfm)")
        }
        if original.needsPassword != filled.needsPassword { report.fail("encryption-changed", "", "opening needs a password: \(original.needsPassword) → \(filled.needsPassword)") }
    }

    /// Pages, comments and bookmarks are all still there.
    private static func checkOtherContent(_ report: inout FormReport, _ data: [UInt8], _ saved: [UInt8], _ password: String?) {
        guard let a = try? PdfEdit.openToRead(data, password), let b = try? PdfEdit.openToRead(saved, password) else { return }
        guard let pa = try? a.pages(), let pb = try? b.pages() else { return }
        if pa.count != pb.count {
            report.fail("pages-lost", "", "\(pa.count) pages became \(pb.count)")
            return
        }
        func comments(_ page: PObj) -> Int { (page.array("Annots")?.elements ?? []).filter { $0.isDict && $0.name("Subtype") != "Widget" }.count }
        let ca = pa.map(comments), cb = pb.map(comments)
        if ca != cb { report.fail("comments-lost", "", "\(ca.reduce(0, +)) other annotations became \(cb.reduce(0, +))") }
        let ba = (try? Bookmarks.read(data, password).count) ?? -1, bb = (try? Bookmarks.read(saved, password).count) ?? -1
        report.bookmarksBefore = ba
        report.bookmarksAfter = bb
        if ba != bb && !report.features.contains("repaired") { report.fail("bookmarks-lost", "", "\(ba) bookmarks became \(bb)") }
    }

    // MARK: Typing

    /// Typing a value character by character, as the app's editor does (its length limit and the keystroke script on each
    /// edit), ends with what was typed, and the commit takes it: at most `perFormat` fields of each format per form (each
    /// opens the document and its script engine).
    private static func checkTyping(_ report: inout FormReport, _ data: [UInt8], _ password: String?, _ scripts: [String: FieldScripts]) {
        let perFormat = 3
        var tried: [String: Int] = [:]
        guard let dataFields = try? FormEditor.dataFields(data, password) else { return }
        for p in report.plan where p.kind == "Text" && !p.password && !p.sent.contains("\n") {
            // A form's own script may refuse the harness's value ("Ink1" into a letters-only field): only the AF formats.
            if p.format == "custom" || scripts[p.name]?.keystroke == nil || tried[p.format, default: 0] >= perFormat { continue }
            tried[p.format, default: 0] += 1
            let maxLength = dataFields.first { $0.name == p.name }?.maxLength ?? 0
            let existing = dataFields.first { $0.name == p.name }?.value ?? ""
            guard let keys = FieldKeystrokes.open(data, password, p.name) else { continue }
            report.typed += 1
            var text = existing
            // The value already there is selected and typed over, as a person replaces it.
            for (i, c) in p.sent.enumerated() {
                let after = i == 0 ? String(c) : text + String(c)
                text = FieldKeystrokes.typed(before: text, after: after, maxLength: maxLength, keys).text
            }
            if digits(text) != digits(p.sent) || text.isEmpty {
                report.fail("typing-refused", p.name, "\(p.format) MaxLen \(maxLength): typing '\(esc(p.sent))' left '\(esc(text))'")
                continue
            }
            guard let filled = try? fill(data, password, [p.name: text]) else { continue }
            if let r = filled.rejected.first(where: { $0.fieldName == p.name }) {
                report.fail("typed-value-rejected", p.name, "\(p.format): typed '\(esc(text))': \(esc(r.message, 80))")
            }
        }
    }
}
