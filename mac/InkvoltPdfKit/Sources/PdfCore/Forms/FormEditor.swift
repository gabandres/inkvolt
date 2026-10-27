import Foundation

/// A terminal form field: its dictionary, full name, type (Tx, Btn, Ch, Sig), flags and widgets.
final class FormField: Hashable {
    let dict: PObj
    let name: String
    let type: String
    let flags: Int
    let widgets: [PObj]

    init(_ dict: PObj, _ name: String, _ type: String, _ flags: Int, _ widgets: [PObj]) {
        self.dict = dict
        self.name = name
        self.type = type
        self.flags = flags
        self.widgets = widgets
    }

    static func == (a: FormField, b: FormField) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var isTextOrChoice: Bool { type == "Tx" || type == "Ch" }
    var isToggle: Bool { type == "Btn" && flags & FormEditor.ffPushButton == 0 }
}

/// Reads and fills AcroForm fields (text, check boxes, radio buttons, combo and list boxes), the Windows app's
/// `FormEditor`. Values are written in place, and every text or choice widget that changes gets a freshly generated
/// appearance stream (fonts from the form's /DR, or embedded fonts for other scripts), so viewers that ignore
/// NeedAppearances (Preview, iOS, print pipelines) still show the values. The form's JavaScript (keystroke, validate,
/// calculate and format actions, plus document-level scripts) runs in a sandbox (`JsFormHost`), with the parsed
/// `FormScripts` fast paths as fallback. Hybrid AcroForm+XFA forms lose their XFA when filled; XFA-only forms (no
/// AcroForm widgets) are not fillable: check `hasXfa`.
public enum FormEditor {
    static let ffReadOnly = 1, ffRequired = 2, ffNoExport = 4, ffMultiline = 1 << 12, ffPassword = 1 << 13, ffNoToggleToOff = 1 << 14
    static let ffRadio = 1 << 15, ffPushButton = 1 << 16, ffCombo = 1 << 17, ffEdit = 1 << 18, ffMultiSelect = 1 << 21
    static let ffComb = 1 << 24, ffRadiosInUnison = 1 << 25
    static let annotHidden = 2, annotPrint = 4, annotNoView = 32, annotReadOnly = 64

    public static func read(_ data: [UInt8], _ password: String?) throws -> [FormWidget] {
        let doc = try PdfEdit.openToRead(data, password)
        return try readWidgets(doc)
    }

    /// Whether the document carries an XFA form, and whether it is XFA-only (no AcroForm widgets to fill, or a dynamic
    /// form that needs an XFA renderer): such forms can't be filled here.
    public static func hasXfa(_ data: [UInt8], _ password: String?) throws -> (hasXfa: Bool, xfaOnly: Bool) {
        let doc = try PdfEdit.openToRead(data, password)
        guard let acro = doc.catalog.dict("AcroForm"), acro.has("XFA") else { return (false, false) }
        let dynamic = doc.catalog["NeedsRendering"].map { $0.kind == .bool && $0.bool } ?? false
        let hasWidgets = try collect(doc, acro).contains { !$0.widgets.isEmpty }
        return (true, dynamic || !hasWidgets)
    }

    /// Sets field values by full field name. Check boxes take "On"/"Off" (or their export value); radio groups take the
    /// chosen state; choice fields take an export value (or its display text); multi-select list boxes take the selected
    /// export values joined by "\n". Afterwards the form's calculations run (in /CO order) and their results are written.
    public static func setValues(_ data: [UInt8], _ password: String?, _ values: [String: String]) throws -> [UInt8] {
        try fill(data, password, values).data
    }

    /// `setValues` that runs the form's JavaScript and reports what it said: each text or choice value first goes
    /// through the field's keystroke (commit) and validate scripts, which may reject it (the field keeps its old value;
    /// see `rejected`) or adjust it; then the calculate scripts run in /CO order and format scripts produce the
    /// appearances. With a `host`, app.alert and app.response become its dialogs (rate-limited), and outward actions the
    /// scripts take go through it, which asks the user first. When every value was rejected and nothing else changed,
    /// `data` is the input itself.
    public static func fill(_ data: [UInt8], _ password: String?, _ values: [String: String], host: FormActionHost? = nil) throws -> FormFillResult {
        let doc = try PdfEdit.open(data, password, failure: "This PDF's form can't be read")
        let xmp = Xmp.read(doc)
        let acro = doc.catalog.dict("AcroForm")
        let fields = try collect(doc, acro)
        if fields.isEmpty { throw PdfEditError("This PDF has no fillable form.") }
        let runner = FormActionRunner(doc, acro, fields, host, data, password: password, xmp: xmp)
        let js: JsFormHost = runner.js
        var rejected: [FieldRejection] = []
        var alerts: [String] = []

        var dirty: [FormField] = []
        var changed = false
        for f in fields {
            guard var value = values[f.name], f.flags & ffReadOnly == 0 else { continue }
            if f.isTextOrChoice && value != valueOf(f), let verdict = commit(js, f, value, &alerts) {
                if let why = verdict.rejection {
                    rejected.append(FieldRejection(fieldName: f.name, message: why))
                    continue
                }
                value = verdict.value
            }
            changed = true
            switch f.type {
            case "Tx":
                f.dict.set("V", doc.text(value))
                f.dict.remove("RV") // rich text would override the plain value in Acrobat
                dirty.append(f)
            case "Ch":
                setChoice(doc, f, value)
                dirty.append(f)
            case "Btn" where f.flags & ffPushButton == 0:
                setButton(f, value)
                dirty.append(f)
            default:
                break
            }
        }
        if !changed && !rejected.isEmpty && js.touched.isEmpty && !runner.changed {
            runner.runDeferred(data)
            return FormFillResult(data: data, rejected: rejected, alerts: runner.notices + alerts, log: js.log, focusField: runner.focusField)
        }

        // A hybrid form's XFA would keep showing the old values in Acrobat; the AcroForm is now the truth.
        acro?.remove("XFA")

        for f in calculate(doc, acro, fields, js, &alerts) where !dirty.contains(f) { dirty.append(f) }
        for f in js.touchedInOrder where !dirty.contains(f) { dirty.append(f) }

        finishAppearances(doc, acro, fields, dirty, js)
        let saved = try save(doc, data, password, xmp)
        runner.runDeferred(saved)
        return FormFillResult(data: saved, rejected: rejected, alerts: runner.notices + alerts, log: js.log, focusField: runner.focusField)
    }

    /// The edited form's bytes: the modification date and the XMP packet updated as every edit does (`PageEditor.edit`).
    static func save(_ doc: MuDoc, _ original: [UInt8], _ password: String?, _ xmp: XMLDocument?) throws -> [UInt8] {
        InfoDict.setDate(doc, "ModDate", Date())
        Xmp.write(doc, original: xmp)
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: original, password: password)
    }

    /// The keystroke (commit) and validate scripts of a text or choice field for a new value: nil when the field has
    /// none (or they couldn't run), else the value to store (keystroke scripts may rewrite it) or why it was refused.
    private static func commit(_ js: JsFormHost, _ f: FormField, _ value: String, _ alerts: inout [String]) -> (value: String, rejection: String?)? {
        var value = value
        var ran = false
        for (key, name) in [("K", "Keystroke"), ("V", "Validate")] {
            guard let script = actionScript(f, key), let r = js.run(name, f, script, value, willCommit: true) else { continue }
            ran = true
            if !r.rc {
                // A message the user already saw in a dialog isn't repeated (empty reason).
                let why = !r.alerts.isEmpty ? r.alerts.joined(separator: "\n") : r.shown > 0 ? "" : "The value entered for \(f.name) isn't valid."
                return (value, why)
            }
            alerts += r.alerts
            if key == "K", let adjusted = r.value { value = adjusted }
        }
        return ran ? (value, nil) : nil
    }

    static func setChoice(_ doc: MuDoc, _ f: FormField, _ value: String) {
        let (exports, labels) = readOptions(inherited(f.dict, "Opt"))
        let multi = f.flags & ffMultiSelect != 0
        var parts: [String] = multi ? value.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map(String.init)
            : value.isEmpty ? [] : [value]
        // Display text is accepted too: mapped to its export value.
        for i in parts.indices where !exports.contains(parts[i]) {
            if let li = labels.firstIndex(of: parts[i]) { parts[i] = exports[li] }
        }
        if !multi && parts.count > 1 { parts = [parts[0]] }
        var unique: [String] = []
        for p in parts where !unique.contains(p) { unique.append(p) }
        // Option order (a stable sort: values that aren't options keep their order, last).
        parts = unique.enumerated().sorted { a, b in
            let ia = exports.firstIndex(of: a.element) ?? Int.max, ib = exports.firstIndex(of: b.element) ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)

        if parts.isEmpty {
            f.dict.remove("V")
        } else if parts.count == 1 {
            f.dict.set("V", doc.text(parts[0]))
        } else {
            f.dict.set("V", doc.array(parts.map { doc.text($0) }))
        }

        let indices = Array(Set(parts.compactMap { exports.firstIndex(of: $0) })).sorted()
        if !indices.isEmpty && indices.count == parts.count {
            f.dict.set("I", doc.array(indices.map { doc.int($0) }))
        } else {
            f.dict.remove("I") // selected indices would contradict a custom value
        }
    }

    /// A check box or radio field's /Opt: the export value of each widget, by its position among the field's widgets
    /// (Acrobat writes it, with states named "0", "1"…, when export values aren't plain ASCII or repeat); nil without.
    private static func buttonOptions(_ f: FormField) -> [String]? {
        guard f.type == "Btn", let arr = inherited(f.dict, "Opt"), arr.isArray, arr.count > 0 else { return nil }
        return arr.elements.map { $0.text ?? "" }
    }

    /// What a check box or radio value means outside the PDF (scripts, submits, exported data): its on state, or with
    /// /Opt the export value of the widget having that state. "Off" stays "Off".
    static func buttonExport(_ f: FormField, _ state: String) -> String {
        guard state != "Off", !state.isEmpty, let opt = buttonOptions(f) else { return state }
        for i in 0..<min(f.widgets.count, opt.count) where onStateOf(f.widgets[i]) == state { return opt[i] }
        if let k = Int(state), k >= 0, k < opt.count, state.allSatisfy(\.isNumber) { return opt[k] }
        return state
    }

    /// The on state a check box or radio value stands for: a state name as is, or an /Opt export value mapped to the
    /// state of the (first) widget carrying it.
    private static func buttonState(_ f: FormField, _ value: String) -> String {
        if value == "Off" || value.isEmpty { return value }
        let states = f.widgets.map(onStateOf)
        guard !states.contains(value), let opt = buttonOptions(f), let i = opt.firstIndex(of: value) else { return value }
        return i < states.count ? states[i] ?? String(i) : String(i)
    }

    /// A field's value as scripts and exported data see it (check boxes and radios through their /Opt).
    static func exportValueOf(_ f: FormField) -> String { f.type == "Btn" ? buttonExport(f, valueOf(f)) : valueOf(f) }

    static func setButton(_ f: FormField, _ value: String) {
        let value = buttonState(f, value)
        let radio = f.flags & ffRadio != 0
        let off = value == "Off" || value.isEmpty
        if off && radio && f.flags & ffNoToggleToOff != 0 { return } // the group must keep a selection
        let states = f.widgets.map(onStateOf)
        var on: String?
        if !off {
            if states.contains(where: { $0 == value }) {
                on = value
            } else if value == "On" {
                on = states.compactMap { $0 }.first
            }
        }
        let doc = f.dict.doc
        f.dict.set("V", doc.name(on ?? "Off"))
        // Radios sharing an on-state turn on together only with RadiosInUnison; otherwise just the first one.
        let unison = !radio || f.flags & ffRadiosInUnison != 0
        var turnedOn = false
        for w in f.widgets {
            let isOn = on != nil && onStateOf(w) == on && (unison || !turnedOn)
            turnedOn = turnedOn || isOn
            w.set("AS", doc.name(isOn ? on ?? "Off" : "Off"))
        }
    }

    /// Runs the form's calculate scripts (in /CO order) and returns the fields whose value changed. Each runs in the
    /// JavaScript sandbox; when it can't, the parsed fast path (`FormScripts.parseCalculation`) stands in.
    static func calculate(_ doc: MuDoc, _ acro: PObj?, _ fields: [FormField], _ js: JsFormHost, _ alerts: inout [String]) -> [FormField] {
        var changed: [FormField] = []
        var byDict: [UInt: FormField] = [:]
        for f in fields where byDict[f.dict.identity] == nil { byDict[f.dict.identity] = f }
        var order: [FormField] = []
        for item in acro?.array("CO")?.elements ?? [] where item.isDict {
            if let f = byDict[item.identity], !order.contains(f) { order.append(f) }
        }
        if order.isEmpty { order = fields }
        let calcs: [(FormField, String)] = order.compactMap { f in
            guard let s = actionScript(f, "C"), !s.allSatisfy(\.isWhitespace) else { return nil }
            return (f, s)
        }
        if calcs.isEmpty { return changed }

        func valuesOf(_ name: String) -> [String] {
            fields.filter { $0.name == name || $0.name.hasPrefix(name + ".") }.map(exportValueOf)
        }

        for (f, script) in calcs where f.isTextOrChoice {
            let current = valueOf(f)
            let text: String
            if let r = js.run("Calculate", f, script, current) {
                alerts += r.alerts
                guard r.rc, let v = r.value else { continue }
                text = v
            } else {
                guard let result = FormScripts.parseCalculation(script)?.evaluate(valuesOf), result.isFinite else { continue }
                text = FormScripts.numberToValue(result)
            }
            if valueOf(f) == text { continue }
            if f.type == "Ch" {
                setChoice(doc, f, text)
            } else {
                f.dict.set("V", doc.text(text))
                f.dict.remove("RV")
            }
            changed.append(f)
        }
        return changed
    }

    /// The JavaScript of a field's additional action (/AA /C calculate, /F format, ...), if any.
    static func actionScript(_ f: FormField, _ key: String) -> String? {
        for holder in [f.dict] + f.widgets {
            guard let action = holder.dict("AA")?.dict(key), action.name("S") == "JavaScript" else { continue }
            return scriptText(action["JS"])
        }
        return nil
    }

    /// Text held in a string or a stream (JavaScript actions use either).
    static func scriptText(_ o: PObj?) -> String? {
        guard let o else { return nil }
        if o.kind == .string { return o.text }
        guard o.isStream, let b = o.streamData else { return nil }
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { return String(decoding: utf16BE(Array(b[2...])), as: UTF16.self) }
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return String(decoding: b[3...], as: UTF8.self) }
        return String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
    }

    static func utf16BE(_ b: [UInt8]) -> [UInt16] {
        stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
    }

    static func valueOf(_ f: FormField) -> String {
        guard let v = inherited(f.dict, "V") else { return f.type == "Btn" ? "Off" : "" }
        switch v.kind {
        case .string: return v.text ?? ""
        case .name: return v.name ?? ""
        case .array: return v.elements.compactMap { $0.kind == .string ? $0.text : nil }.joined(separator: "\n")
        case .int: return String(v.int ?? 0)
        case .real: return FormScripts.numberToValue(v.number ?? 0)
        default: return f.type == "Btn" ? "Off" : ""
        }
    }

    /// The text a field's format script (/AA /F) shows for a raw value, and the text color it asked for (red
    /// negatives): through the JavaScript sandbox when there is one, else (or when the script fails) the parsed fast path.
    private static func display(_ f: FormField, _ raw: String, _ js: JsFormHost?) -> (text: String, color: [Double]?) {
        guard let script = actionScript(f, "F") else { return (raw, nil) }
        if let r = js?.run("Format", f, script, raw), let shown = r.value { return (shown, r.textColor) }
        if let fmt = FormScripts.parseFormat(script) {
            let (text, red) = FormScripts.format(fmt, raw)
            return (text, red ? [1, 0, 0] : nil)
        }
        return (raw, nil)
    }

    /// After values changed: every changed field gets appearance streams that show its value (text and choice faces
    /// drawn from it, through its format script; check boxes and radio buttons on and off faces, made when a widget has a
    /// single face or none). /NeedAppearances is set only when some appearance couldn't be built, since pdf.js, poppler
    /// and others then redraw every field themselves (losing formats and list or check box looks). A form whose producer
    /// asked for it gets all its fields' appearances built here once, so it keeps working without it.
    static func finishAppearances(_ doc: MuDoc, _ acro: PObj?, _ fields: [FormField], _ dirty: [FormField], _ js: JsFormHost?) {
        var complete = true
        for f in dirty where !buildAppearance(doc, acro, f, js) { complete = false }
        guard let acro else { return }
        let producerAsked = acro["NeedAppearances"].map { $0.kind == .bool && $0.bool } ?? false
        if producerAsked {
            for f in fields where !dirty.contains(f) && !buildAppearance(doc, acro, f, js) { complete = false }
        }
        if complete { acro.remove("NeedAppearances") } else { acro.set("NeedAppearances", doc.bool(true)) }
        if !dirty.isEmpty || producerAsked { ensureDefaultFonts(doc, acro) }
    }

    /// Builds what a field needs to show its value by itself; false when some widget still has no appearance.
    private static func buildAppearance(_ doc: MuDoc, _ acro: PObj?, _ f: FormField, _ js: JsFormHost?) -> Bool {
        if f.isTextOrChoice { return writeAppearances(doc, acro, f, js) }
        if f.isToggle {
            ensureStateFaces(doc, f)
            return f.widgets.allSatisfy(hasStateFace)
        }
        return f.widgets.allSatisfy { $0.dict("AP")?["N"] != nil }
    }

    /// A check box or radio widget whose normal appearance is a state dictionary holding the state it shows.
    private static func hasStateFace(_ w: PObj) -> Bool {
        guard let states = w.dict("AP")?.dict("N"), !states.isStream else { return false }
        guard let shown = w.name("AS"), shown != "Off" else { return true }
        return states.has(shown)
    }

    /// Gives each check box or radio widget whose normal appearance is a single stream (or missing) on and off faces:
    /// redrawn from its /MK (border, background, symbol) when it has one, else the single face as "on" and an empty
    /// "off". Without that, its /AS can't switch what it shows.
    private static func ensureStateFaces(_ doc: MuDoc, _ f: FormField) {
        let radio = f.flags & ffRadio != 0
        for w in f.widgets {
            let normal = w.dict("AP")?.dict("N")
            if let normal, !normal.isStream { continue }
            let state = onStateOf(w) ?? "Yes"
            let shown = w.name("AS")
            if let mk = w.dict("MK"), mk.has("BC") || mk.has("BG") || mk.has("CA") {
                let da = DefaultAppearance.parse(w.text("DA") ?? inherited(f.dict, "DA")?.text ?? "/ZaDb 0 Tf 0 g")
                let c = da.color.c
                let mark: AnnotColor
                switch c.count {
                case 3: mark = AnnotColor(c[0], c[1], c[2])
                case 4: mark = AnnotColor((1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3]))
                default: mark = AnnotColor(c[0], c[0], c[0])
                }
                ButtonFaces.build(doc, w, radio: radio, state: state, mark: mark)
            } else if let normal, let ap = w.dict("AP") {
                let bbox = normal.array("BBox")
                let off = doc.formXObject([], 0, 0, bbox?.num(2) ?? 1, bbox?.num(3) ?? 1, nil)
                let face = ap["N"] ?? normal
                ap.set("N", doc.dict([(state, face), ("Off", off)]))
            } else {
                continue // no face and nothing to draw one from: NeedAppearances covers it
            }
            w.set("AS", doc.name(shown == state ? state : "Off"))
        }
    }

    /// Generates the normal appearance of every widget of a text or choice field from its current value. False when a
    /// widget's couldn't be built (no usable /Rect).
    @discardableResult
    static func writeAppearances(_ doc: MuDoc, _ acro: PObj?, _ f: FormField, _ js: JsFormHost? = nil) -> Bool {
        guard f.isTextOrChoice else { return true }
        var complete = true
        let raw = valueOf(f)
        let (exports, labels) = readOptions(inherited(f.dict, "Opt"))
        let listBox = f.type == "Ch" && f.flags & ffCombo == 0
        var (text, color) = f.type == "Tx" ? display(f, raw, js) : (raw, nil)
        if f.type == "Ch" && !listBox, let ci = exports.firstIndex(of: raw) { text = labels[ci] }

        var selected = Set<Int>()
        if listBox {
            for part in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                if let i = exports.firstIndex(of: String(part)) { selected.insert(i) }
            }
        }
        var topIndex = inherited(f.dict, "TI")?.int ?? 0
        if listBox, let first = selected.min(), topIndex > first { topIndex = first }
        let drFonts = acro?.dict("DR")?.dict("Font")

        for w in f.widgets {
            let da = w.text("DA") ?? inherited(f.dict, "DA")?.text ?? acro?.text("DA") ?? "/Helv 0 Tf 0 g"
            let fontName = DefaultAppearance.parse(da).fontName
            let baseFont = drFonts?.dict(PdfNames.bare(fontName))?.name("BaseFont")
            let q = w.int("Q") ?? inherited(f.dict, "Q")?.int ?? acro?.int("Q") ?? 0
            let look = FieldLook(
                da: da, drBaseFont: (baseFont ?? "").isEmpty ? nil : baseFont, quadding: q,
                multiline: f.type == "Tx" && f.flags & ffMultiline != 0,
                comb: f.type == "Tx" && f.flags & ffComb != 0 && f.flags & (ffMultiline | ffPassword) == 0,
                password: f.type == "Tx" && f.flags & ffPassword != 0,
                maxLen: inherited(f.dict, "MaxLen")?.int ?? 0, text: text, listBox: listBox, items: labels, selected: selected,
                topIndex: topIndex, colorOverride: color.flatMap { $0.isEmpty ? nil : PdfColorValue(c: $0) })
            guard let ap = FieldAppearance.build(doc, w, look) else {
                complete = false
                continue
            }
            w.set("AP", doc.dict([("N", ap)]))
        }
        return complete
    }

    /// With NeedAppearances, viewers redraw every field (check boxes too) from the form's default resources: the fonts
    /// they look for (Helvetica for text, ZapfDingbats for check marks) must be there.
    static func ensureDefaultFonts(_ doc: MuDoc, _ acro: PObj) {
        var dr = acro.dict("DR")
        if dr == nil {
            acro.set("DR", doc.dict())
            dr = acro.dict("DR")
        }
        guard let dr else { return }
        var fonts = dr.dict("Font")
        if fonts == nil {
            dr.set("Font", doc.dict())
            fonts = dr.dict("Font")
        }
        guard let fonts else { return }
        for (key, name) in [("Helv", "Helvetica"), ("ZaDb", "ZapfDingbats")] where !fonts.has(key) {
            fonts.set(key, FontResources.standard(doc, name))
        }
        if !acro.has("DA") { acro.set("DA", doc.text("/Helv 0 Tf 0 g")) }
    }

    private static func readWidgets(_ doc: MuDoc) throws -> [FormWidget] {
        let acro = doc.catalog.dict("AcroForm")
        let fields = try collect(doc, acro)
        if fields.isEmpty { return [] }

        // Which page each widget sits on (via the pages' /Annots; /P is optional and often wrong).
        var pageOf: [UInt: Int] = [:]
        var annotOrder: [UInt: Int] = [:]
        let pageCount = try doc.pageCount()
        var tabs: [String?] = []
        var pages: [PObj] = []
        for i in 0..<pageCount {
            let page = doc.page(i)
            pages.append(page)
            tabs.append(page.name("Tabs"))
            for (k, a) in (page.array("Annots")?.elements ?? []).enumerated() where a.isDict && pageOf[a.identity] == nil {
                pageOf[a.identity] = i
                annotOrder[a.identity] = k
            }
        }
        let structOrder = tabs.contains("S") ? structureOrder(doc) : [:]
        let calculated = Set(fields.filter { !(actionScript($0, "C") ?? "").allSatisfy(\.isWhitespace) })
        var js: JsFormHost? // made on the first format script

        var result: [(widget: FormWidget, annot: UInt)] = []
        for f in fields {
            let kind: FormFieldKind
            switch f.type {
            case "Tx": kind = .text
            case "Ch": kind = .choice
            case "Sig": kind = .signature
            case "Btn": kind = f.flags & ffPushButton != 0 ? .pushButton : f.flags & ffRadio != 0 ? .radio : .checkBox
            default: continue
            }

            let (options, labels) = readOptions(inherited(f.dict, "Opt"))
            let multi = kind == .choice && f.flags & ffMultiSelect != 0
            let value = widgetValue(f, kind, multi, options)
            let maxLen = inherited(f.dict, "MaxLen")?.int ?? 0
            var display: String?
            if kind == .text && actionScript(f, "F") != nil {
                let host = js ?? JsFormHost(doc, fields, readOnly: true)
                js = host
                display = self.display(f, value, host).text
            }

            for w in f.widgets {
                guard let page = pageOf[w.identity], let r = w.array("Rect"), r.count >= 4 else { continue }
                let rect = PageBoxes.toPageSpace(pages[page], r.num(0), r.num(1), r.num(2), r.num(3))
                if rect.isEmpty { continue }
                let annotFlags = w.int("F") ?? 0
                if annotFlags & (annotHidden | annotNoView) != 0 { continue }
                let signed = kind == .signature && inherited(f.dict, "V")?.isDict == true
                result.append((FormWidget(
                    fieldName: f.name, kind: kind, pageIndex: page, rect: rect, onState: onStateOf(w),
                    multiline: f.flags & ffMultiline != 0, readOnly: f.flags & ffReadOnly != 0 || annotFlags & annotReadOnly != 0,
                    editable: kind == .choice && f.flags & ffCombo != 0 && f.flags & ffEdit != 0,
                    maxLength: maxLen, options: options, value: value, tabOrder: 0,
                    optionLabels: labels == options ? nil : labels, multiSelect: multi,
                    noToggleToOff: kind == .radio && f.flags & ffNoToggleToOff != 0,
                    password: kind == .text && f.flags & ffPassword != 0,
                    displayValue: display, calculated: calculated.contains(f), signed: signed, triggers: FormActions.triggersOf(f, w),
                    annotIndex: annotOrder[w.identity] ?? -1), w.identity))
            }
        }

        // Fill order, page by page: the page's /Tabs when it asks for structure (/S), annotation (/A, /W) or column (/C)
        // order; otherwise (and for /R) the natural reading order: top to bottom, then left to right, rows within a few
        // points counting as one line.
        var ordered: [FormWidget] = []
        for page in Set(result.map(\.widget.pageIndex)).sorted() {
            let group = result.enumerated().filter { $0.element.widget.pageIndex == page }
            func key(_ x: (widget: FormWidget, annot: UInt)) -> [Double] {
                let annot = Double(annotOrder[x.annot] ?? 0)
                switch tabs[page] {
                case "S": return [Double(structOrder[x.annot] ?? Int.max), annot]
                case "A", "W": return [annot]
                case "C": return [(x.widget.rect.x / 6).rounded(.toNearestOrEven), x.widget.rect.y]
                default: return [(x.widget.rect.y / 6).rounded(.toNearestOrEven), x.widget.rect.x]
                }
            }
            let sorted = group.sorted { a, b in
                let ka = key(a.element), kb = key(b.element)
                return ka != kb ? ka.lexicographicallyPrecedes(kb) : a.offset < b.offset
            }
            ordered += sorted.map(\.element.widget)
        }
        return ordered.enumerated().map { i, w in
            var w = w
            w.tabOrder = i
            return w
        }
    }

    /// A field's value as `read` reports it (a choice field without /V: its /I selection).
    private static func widgetValue(_ f: FormField, _ kind: FormFieldKind, _ multi: Bool, _ options: [String]) -> String {
        let toggle = kind == .checkBox || kind == .radio
        guard let v = inherited(f.dict, "V") else {
            if kind == .choice, let sel = inherited(f.dict, "I"), sel.isArray {
                let picked = sel.elements.map { $0.int ?? -1 }.filter { $0 >= 0 && $0 < options.count }.map { options[$0] }
                return (multi ? picked : Array(picked.prefix(1))).joined(separator: "\n")
            }
            return toggle ? "Off" : ""
        }
        switch v.kind {
        case .string: return v.text ?? ""
        case .name: return v.name ?? ""
        case .array where multi: return v.elements.compactMap { $0.kind == .string ? $0.text : nil }.joined(separator: "\n")
        case .array where v.count > 0 && v[0]?.kind == .string: return v[0]?.text ?? ""
        case .int: return String(v.int ?? 0)
        case .real: return FormScripts.numberToValue(v.number ?? 0)
        default: return toggle ? "Off" : ""
        }
    }

    /// The order in which annotations appear in the structure tree (OBJR references), for /Tabs /S.
    private static func structureOrder(_ doc: MuDoc) -> [UInt: Int] {
        var order: [UInt: Int] = [:]
        var seen = Set<UInt>()
        func visit(_ item: PObj?, _ depth: Int) {
            guard depth <= 64, let item else { return }
            if item.isArray {
                for e in item.elements { visit(e, depth + 1) }
            } else if item.isDict, seen.insert(item.identity).inserted {
                if item.name("Type") == "OBJR" {
                    if let target = item.dict("Obj"), order[target.identity] == nil { order[target.identity] = order.count }
                } else {
                    visit(item["K"], depth + 1)
                }
            }
        }
        visit(doc.catalog.dict("StructTreeRoot")?["K"], 0)
        return order
    }

    /// Every terminal field: from the AcroForm's /Fields, then any widget on a page not reached from there (some
    /// producers leave /Fields empty or incomplete; viewers still treat those as fields), from its top-most parent.
    static func collect(_ doc: MuDoc, _ acro: PObj?) throws -> [FormField] {
        var into: [FormField] = []
        var seen = Set<UInt>()
        for item in acro?.array("Fields")?.elements ?? [] where item.isDict { walk(item, nil, &into, &seen, 0) }

        var unnamed = 0
        for p in 0..<(try doc.pageCount()) {
            for a in doc.page(p).array("Annots")?.elements ?? [] where a.isDict {
                if seen.contains(a.identity) || a.name("Subtype") != "Widget" { continue }
                var root = a
                var guardCount = 0
                while let parent = root.dict("Parent"), !seen.contains(parent.identity), guardCount < 64 {
                    root = parent
                    guardCount += 1
                }
                if seen.contains(root.identity) { continue }
                var name: String?
                if !root.has("T") {
                    unnamed += 1
                    name = "field\(unnamed)_p\(p + 1)"
                }
                walk(root, name, &into, &seen, 0)
            }
        }
        return into
    }

    private static func walk(_ node: PObj, _ parentName: String?, _ into: inout [FormField], _ seen: inout Set<UInt>, _ depth: Int) {
        guard depth <= 64, seen.insert(node.identity).inserted else { return } // malformed files can contain cycles
        let partial = node["T"].flatMap { $0.kind == .string ? $0.text : nil }
        let name = partial.map { p in parentName.map { "\($0).\(p)" } ?? p } ?? parentName ?? ""

        let kids = node.array("Kids")?.elements.filter(\.isDict) ?? []
        let fieldKids = kids.filter { $0.has("T") }
        if !fieldKids.isEmpty {
            for k in fieldKids { walk(k, name, &into, &seen, depth + 1) }
            return
        }

        // A terminal field: its widgets are the kids without names, or the field dictionary itself.
        let widgets = !kids.isEmpty ? kids : node.has("Rect") ? [node] : []
        for w in widgets { seen.insert(w.identity) }
        let type = inherited(node, "FT")?.name ?? ""
        let flags = inherited(node, "Ff")?.int ?? 0
        if !name.isEmpty && !type.isEmpty { into.append(FormField(node, name, type, flags, widgets)) }
    }

    static func inherited(_ node: PObj, _ key: String) -> PObj? {
        var d: PObj? = node
        var guardCount = 0
        while let cur = d, guardCount < 64 {
            if let v = cur[key] { return v }
            d = cur.dict("Parent")
            guardCount += 1
        }
        return nil
    }

    /// The state a check box or radio widget shows when on: a name in its normal (else down) appearance dictionary, else
    /// its /AS. A single appearance stream is no state dictionary (its keys are /BBox, /Resources …): such a widget, or
    /// one without any appearance, gets its position as the name when the field has an /Opt (Acrobat's "0", "1" …), else
    /// "Yes". Nil for widgets of other fields.
    static func onStateOf(_ widget: PObj) -> String? {
        let ap = widget.dict("AP")
        for key in ["N", "D"] {
            if let states = ap?.dict(key), !states.isStream, let state = states.keys.first(where: { $0 != "Off" }) { return state }
        }
        if let shown = widget.name("AS"), shown != "Off" { return shown }
        let flags = inherited(widget, "Ff")?.int ?? 0
        guard inherited(widget, "FT")?.name == "Btn", flags & ffPushButton == 0 else { return nil }
        if let opt = inherited(widget, "Opt"), opt.isArray, opt.count > 0 {
            let kids = widget.dict("Parent")?.array("Kids")?.elements ?? []
            let index = kids.firstIndex { $0.identity == widget.identity } ?? -1
            return String(max(0, index))
        }
        return "Yes"
    }

    /// The export values and display labels of a choice field's /Opt (plain strings or [export display] pairs).
    static func readOptions(_ opt: PObj?) -> (exports: [String], labels: [String]) {
        var exports: [String] = [], labels: [String] = []
        guard let opt, opt.isArray else { return (exports, labels) }
        for e in opt.elements {
            if e.kind == .string {
                exports.append(e.text ?? "")
                labels.append(e.text ?? "")
            } else if e.isArray, e.count > 0, let first = e[0], first.kind == .string, let export = first.text {
                exports.append(export)
                labels.append(e.count > 1 ? e[1].flatMap { $0.kind == .string ? $0.text : nil } ?? export : export)
            }
        }
        return (exports, labels)
    }
}
