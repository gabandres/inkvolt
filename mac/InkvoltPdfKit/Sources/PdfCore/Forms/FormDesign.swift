import Foundation

/// The kinds of form field the form designer places.
public enum DesignFieldKind: String, CaseIterable, Sendable { case text, checkBox, radio, comboBox, listBox, signature, button }

/// What a push button does: reset the form, print, nothing, or an action Inkvolt PDF keeps as it is.
public enum FieldButtonAction: Sendable { case none, resetForm, print, other }

/// One widget of a form field as the form designer shows and edits it (page space: points, top-left origin, rotation
/// applied). Field-wide properties (name, tooltip, flags, default, options, format) are the same on every widget of a
/// field; a radio button's `name` is its group's.
public struct DesignField: Equatable, Sendable {
    /// The widget's /NM, else its position ("p<page>:<index>", valid for the bytes it was read from).
    public var id = ""
    /// The fully qualified field name ("address.city" puts the field under a parent "address").
    public var name = ""
    public var kind = DesignFieldKind.text
    public var pageIndex = 0
    public var rect = RectD.zero
    public var tooltip = ""
    public var required = false
    public var readOnly = false
    /// Text and choice fields: the value a reset restores (and the field starts with). Check box: its export value when
    /// checked by default, else empty. Radio: the export value of the group's default button, or empty.
    public var defaultValue = ""
    /// Text size in points; 0 = fit the box (auto).
    public var fontSize = 0.0
    public var textColor = AnnotColor(0, 0, 0)
    /// Border color; nil = no border.
    public var borderColor: AnnotColor?
    /// Background color; nil = transparent.
    public var fillColor: AnnotColor?
    /// Text alignment: 0 = left, 1 = centered, 2 = right.
    public var alignment = 0
    public var multiline = false
    /// Text fields: the most characters it takes; 0 = no limit.
    public var maxLength = 0
    /// Text fields: an Acrobat number, percent, date or special format (AFNumber_Format …), or nil.
    public var format: FieldFormat?
    /// The field has a format script that isn't one of the Acrobat built-ins: `format` can't change it.
    public var customFormat = false
    /// Combo and list boxes: the choices (export values).
    public var options: [String] = []
    /// Combo and list boxes: the text shown for each choice, parallel to `options` (empty: the export values themselves).
    /// Written as [export display] pairs where they differ.
    public var optionLabels: [String] = []
    /// Combo box: the user may type a value of their own.
    public var editable = false
    /// List box: several choices may be selected.
    public var multiSelect = false
    /// Check box or radio button: the value it stands for when on (its "on" appearance state).
    public var exportValue = "Yes"
    /// Push buttons: what clicking does.
    public var action = FieldButtonAction.none
    /// Push buttons: the label on the button.
    public var caption = ""
    /// A signature field that has been signed: it can't be moved, changed or deleted.
    public var signed = false
    /// Position in the page's fill (Tab) order, 0-based, as `FormEditor.read` orders it.
    public var tabIndex = 0

    public init() {}

    /// The text shown for each choice (`optionLabels`, else the export values).
    public var shownOptions: [String] { optionLabels.count == options.count ? optionLabels : options }

    /// A copy with `change` applied (.NET's `with`).
    public func with(_ change: (inout DesignField) -> Void) -> DesignField {
        var copy = self
        change(&copy)
        return copy
    }

    /// A name for lists and screen readers: "Text field Name", "Radio button Gender (Female)".
    public func describe() -> String { "\(Self.kindName(kind)) \(name)\(kind == .radio ? " (\(exportValue))" : "")" }

    public static func kindName(_ kind: DesignFieldKind) -> String {
        switch kind {
        case .text: "Text field"
        case .checkBox: "Check box"
        case .radio: "Radio button"
        case .comboBox: "Dropdown"
        case .listBox: "List box"
        case .signature: "Signature field"
        case .button: "Button"
        }
    }
}

/// Form authoring (the Windows app's `FormDesign`): adds, changes, moves, deletes and orders AcroForm fields. Every field
/// gets real appearance streams (text, choice and button faces drawn the way `FormEditor` draws filled values, check boxes
/// and radio buttons with their on and off states), a /DA and the form's /DR fonts, so it shows and fills in viewers that
/// ignore NeedAppearances. Names are fully qualified: "a.b" sits under a parent field "a"; radio buttons with the same name
/// are the kids of one group. Edits go through `PageEditor.edit`, so signed files are appended to and encrypted files keep
/// their protection.
public enum FormDesign {
    private static let maxNameLength = 120

    // MARK: Reading

    /// Every widget of every form field, page by page in each page's /Annots order.
    public static func read(_ data: [UInt8], _ password: String?) throws -> [DesignField] {
        try readIn(PdfEdit.openToRead(data, password))
    }

    private static func readIn(_ doc: MuDoc) throws -> [DesignField] {
        let acro = doc.catalog.dict("AcroForm")
        var fieldOf: [UInt: FormField] = [:]
        for f in try FormEditor.collect(doc, acro) {
            for w in f.widgets where fieldOf[w.identity] == nil { fieldOf[w.identity] = f }
        }
        var list: [DesignField] = []
        for p in 0..<(try doc.pageCount()) {
            let page = doc.page(p)
            guard let annots = page.array("Annots") else { continue }
            var onPage: [DesignField] = []
            for (i, a) in annots.elements.enumerated() where a.isDict {
                if let f = fieldOf[a.identity], let d = describe(doc, page, acro, f, a, p, i) { onPage.append(d) }
            }
            list += withTabOrder(onPage, page.name("Tabs"))
        }
        return list
    }

    /// The fill order the way `FormEditor` follows it: annotation order for /Tabs /A, /W and /S (structure order is
    /// approximated by the annotation order), columns for /C, rows otherwise.
    private static func withTabOrder(_ onPage: [DesignField], _ tabs: String?) -> [DesignField] {
        func key(_ f: DesignField, _ i: Int) -> [Double] {
            switch tabs {
            case "A", "W", "S": return [Double(i)]
            case "C": return [(f.rect.x / 6).rounded(.toNearestOrEven), f.rect.y, Double(i)]
            default: return [(f.rect.y / 6).rounded(.toNearestOrEven), f.rect.x, Double(i)]
            }
        }
        let ordered = onPage.indices.sorted { key(onPage[$0], $0).lexicographicallyPrecedes(key(onPage[$1], $1)) }
        var result = onPage
        for (rank, i) in ordered.enumerated() { result[i].tabIndex = rank }
        return result
    }

    private static func kindOf(_ f: FormField) -> DesignFieldKind? {
        switch f.type {
        case "Tx": return .text
        case "Ch": return f.flags & FormEditor.ffCombo != 0 ? .comboBox : .listBox
        case "Sig": return .signature
        case "Btn": return f.flags & FormEditor.ffPushButton != 0 ? .button : f.flags & FormEditor.ffRadio != 0 ? .radio : .checkBox
        default: return nil
        }
    }

    private static func describe(_ doc: MuDoc, _ page: PObj, _ acro: PObj?, _ f: FormField, _ w: PObj, _ pageIndex: Int, _ index: Int) -> DesignField? {
        guard let kind = kindOf(f), let r = w.array("Rect"), r.count >= 4 else { return nil }
        let rect = PageBoxes.rectToPage(page, r)
        if rect.isEmpty { return nil }
        let da = DefaultAppearance.parse(daOf(acro, f, w))
        let mk = w.dict("MK")
        let formatScript = script(f, w, "F")
        let format = kind == .text ? FormScripts.parseFormat(formatScript) : nil
        let (exports, labels) = FormEditor.readOptions(FormEditor.inherited(f.dict, "Opt"))
        let toggle = kind == .checkBox || kind == .radio
        let choice = kind == .comboBox || kind == .listBox
        var dv = defaultText(FormEditor.inherited(f.dict, "DV"))
        if toggle && dv == "Off" { dv = "" }

        var d = DesignField()
        d.id = Annotations.idOf(doc, w, pageIndex, index)
        d.name = f.name
        d.kind = kind
        d.pageIndex = pageIndex
        d.rect = rect
        d.tooltip = FormEditor.inherited(f.dict, "TU")?.text ?? ""
        d.required = f.flags & FormEditor.ffRequired != 0
        d.readOnly = f.flags & FormEditor.ffReadOnly != 0
        d.defaultValue = dv
        d.fontSize = da.size
        d.textColor = toRgb(da.color.c)
        d.borderColor = Annotations.colorOf(mk?.array("BC"))
        d.fillColor = Annotations.colorOf(mk?.array("BG"))
        let q = w.int("Q") ?? FormEditor.inherited(f.dict, "Q")?.int ?? acro?.int("Q") ?? 0
        d.alignment = min(max(q, 0), 2)
        d.multiline = kind == .text && f.flags & FormEditor.ffMultiline != 0
        d.maxLength = kind == .text ? max(0, FormEditor.inherited(f.dict, "MaxLen")?.int ?? 0) : 0
        d.format = format
        d.customFormat = format == nil && !(formatScript ?? "").allSatisfy(\.isWhitespace)
        d.options = choice ? exports : []
        d.optionLabels = choice && labels != exports ? labels : []
        d.editable = kind == .comboBox && f.flags & FormEditor.ffEdit != 0
        d.multiSelect = kind == .listBox && f.flags & FormEditor.ffMultiSelect != 0
        d.exportValue = toggle ? FormEditor.onStateOf(w) ?? "Yes" : ""
        d.action = kind == .button ? actionOf(w) : .none
        d.caption = kind == .button ? mk?.text("CA") ?? "" : ""
        d.signed = kind == .signature && FormEditor.inherited(f.dict, "V")?.isDict == true
        return d
    }

    /// A /DV as text: a string, a name, or several strings joined by "\n".
    private static func defaultText(_ o: PObj?) -> String {
        guard let o else { return "" }
        switch o.kind {
        case .string: return o.text ?? ""
        case .name: return o.name ?? ""
        case .array: return o.elements.compactMap { $0.kind == .string ? $0.text : nil }.joined(separator: "\n")
        default: return ""
        }
    }

    private static func daOf(_ acro: PObj?, _ f: FormField, _ w: PObj) -> String {
        w.text("DA") ?? FormEditor.inherited(f.dict, "DA")?.text ?? acro?.text("DA") ?? "/Helv 0 Tf 0 g"
    }

    /// The JavaScript of a widget's or its field's additional action (/AA /F, /K), if any.
    private static func script(_ f: FormField, _ w: PObj, _ key: String) -> String? {
        for holder in [w, f.dict] {
            if let action = holder.dict("AA")?.dict(key), action.name("S") == "JavaScript" { return FormEditor.scriptText(action["JS"]) }
        }
        return nil
    }

    private static func actionOf(_ w: PObj) -> FieldButtonAction {
        guard let a = w.dict("A") else { return w.has("AA") ? .other : .none }
        switch a.name("S") {
        case "ResetForm" where !a.has("Fields") && !a.has("Next"): return .resetForm
        case "Named" where a.name("N") == "Print" && !a.has("Next"): return .print
        default: return .other
        }
    }

    private static func toRgb(_ c: [Double]) -> AnnotColor {
        switch c.count {
        case 1: return AnnotColor(c[0], c[0], c[0])
        case 3: return AnnotColor(c[0], c[1], c[2])
        case 4: return AnnotColor((1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3]))
        default: return AnnotColor(0, 0, 0)
        }
    }

    // MARK: Names

    /// Why `name` can't be a field name, or nil when it can.
    public static func nameProblem(_ name: String) -> String? {
        if name.allSatisfy(\.isWhitespace) { return "Type a name for the field." }
        if name.utf16.count > maxNameLength { return "Use at most \(maxNameLength) characters." }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "A field name can't contain tabs or line breaks." }
        let badPart = name.components(separatedBy: ".").contains { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed != part
        }
        if badPart { return "Dots separate the parts of a name (\"address.city\"): a name can't start or end with one, have two in a row, or spaces around one." }
        return nil
    }

    /// Why a check box or radio button can't have `value` as its export value, or nil.
    public static func exportValueProblem(_ value: String) -> String? {
        if value.isEmpty { return "Type the value the button stands for when it's on." }
        if value == "Off" { return "\"Off\" means not selected; choose another value." }
        let allowed = value.unicodeScalars.allSatisfy { s in
            (48...57).contains(s.value) || (65...90).contains(s.value) || (97...122).contains(s.value) || s == "-" || s == "_" || s == "."
        }
        if value.utf16.count > 60 || !allowed { return "Use letters, digits, '-', '_' and '.' only (at most 60)." }
        return nil
    }

    /// Why a field of `kind` can't be named `name` among `existing` (name and kind of every other field), or nil. A radio
    /// button may take the name of a radio group: it joins it.
    public static func nameClash(_ existing: [(name: String, kind: DesignFieldKind)], _ name: String, _ kind: DesignFieldKind) -> String? {
        if let problem = nameProblem(name) { return problem }
        for (other, otherKind) in existing {
            if other == name {
                if kind == .radio && otherKind == .radio { continue }
                return "Another field is already named \"\(name)\"."
            }
            if other.hasPrefix(name + ".") { return "\"\(name)\" already groups other fields (such as \"\(other)\")." }
            if name.hasPrefix(other + ".") { return "\"\(other)\" is a field, so it can't hold \"\(name)\"." }
        }
        return nil
    }

    /// `baseName` if no field has it yet, else "baseName_2", "baseName_3", …
    public static func uniqueName(_ existing: [String], _ baseName: String) -> String {
        var names = NameBook(existing)
        return names.unique(baseName)
    }

    /// The next numbered name for a new field of `kind`: "Text1", "Check Box2", "Group1" …
    public static func nextName(_ existing: [String], _ kind: DesignFieldKind) -> String {
        var names = NameBook(existing)
        return names.next(kind)
    }

    /// The names in use, for picking several in a row (`uniqueName` and `nextName` start over each time): a name is free
    /// when it isn't taken, isn't a group of taken names ("a" when "a.b" is), and isn't under a taken field ("a.b" when "a"
    /// is). Each check costs the name's length, not the field count.
    struct NameBook {
        private var taken = Set<String>()
        private var groups = Set<String>()
        /// Where the numbering of a base name goes on: lower numbers were taken when it last looked.
        private var numbered: [String: Int] = [:]

        init(_ names: [String] = []) {
            for n in names { add(n) }
        }

        mutating func add(_ name: String) {
            if taken.insert(name).inserted { groups.formUnion(FormDesign.groupsOf(name)) }
        }

        func isFree(_ name: String) -> Bool {
            if taken.contains(name) || groups.contains(name) { return false }
            return !FormDesign.groupsOf(name).contains { taken.contains($0) }
        }

        /// `baseName`, or its next free numbered form ("baseName_2" …).
        mutating func unique(_ baseName: String) -> String {
            if isFree(baseName) { return baseName }
            var i = numbered[baseName] ?? 2
            while !isFree("\(baseName)_\(i)") { i += 1 }
            numbered[baseName] = i
            return "\(baseName)_\(i)"
        }

        mutating func next(_ kind: DesignFieldKind) -> String {
            let prefix = FormDesign.namePrefix(kind)
            var i = numbered[prefix] ?? 1
            while !isFree("\(prefix)\(i)") { i += 1 }
            numbered[prefix] = i
            return "\(prefix)\(i)"
        }
    }

    private static func namePrefix(_ kind: DesignFieldKind) -> String {
        switch kind {
        case .text: "Text"
        case .checkBox: "Check Box"
        case .radio: "Group"
        case .comboBox: "Dropdown"
        case .listBox: "List Box"
        case .signature: "Signature"
        case .button: "Button"
        }
    }

    /// The parts of a name before each of its dots ("a.b.c": "a", "a.b"); none when it starts with a dot.
    private static func groupsOf(_ name: String) -> [String] {
        guard name.utf8.contains(46), name.first != "." else { return [] }
        return name.indices.filter { name[$0] == "." }.map { String(name[..<$0]) }
    }

    /// A new field of `kind` over `rect` with the designer's defaults (thin gray border, automatic text size; check boxes
    /// and radio buttons black, push buttons gray with a caption) and a fresh id. `name` nil: the next numbered name.
    public static func newField(_ kind: DesignFieldKind, _ pageIndex: Int, _ rect: RectD, _ existingNames: [String], _ name: String? = nil) -> DesignField {
        var f = DesignField()
        f.id = Annotations.newId()
        f.name = name.map { uniqueName(existingNames, $0) } ?? nextName(existingNames, kind)
        f.kind = kind
        f.pageIndex = pageIndex
        f.rect = rect
        f.borderColor = kind == .checkBox || kind == .radio ? AnnotColor(0, 0, 0) : AnnotColor(0.45, 0.45, 0.45)
        f.fillColor = kind == .button ? AnnotColor(0.85, 0.85, 0.85) : nil
        f.alignment = kind == .button ? 1 : 0
        f.options = kind == .comboBox || kind == .listBox ? ["Option 1", "Option 2", "Option 3"] : []
        f.exportValue = kind == .radio ? "Choice1" : "Yes"
        f.action = kind == .button ? .resetForm : .none
        f.caption = kind == .button ? "Reset" : ""
        return f
    }

    /// A copy of `field` moved by (`dx`, `dy`) with a new id: a radio button stays in its group with the next free export
    /// value ("Choice2"), any other field gets a new name.
    public static func duplicate(_ field: DesignField, _ existing: [DesignField], _ dx: Double, _ dy: Double) -> DesignField {
        var copy = field
        copy.id = Annotations.newId()
        copy.rect.x += dx
        copy.rect.y += dy
        copy.signed = false
        if field.kind == .radio {
            let values = Set(existing.filter { $0.kind == .radio && $0.name == field.name }.map(\.exportValue))
            var stem = field.exportValue
            while let last = stem.last, last.isASCII, last.isNumber { stem.removeLast() }
            if stem.isEmpty { stem = "Choice" }
            var n = 2
            while values.contains("\(stem)\(n)") { n += 1 }
            copy.exportValue = "\(stem)\(n)"
            return copy
        }
        copy.name = uniqueName(existing.map(\.name), field.name)
        return copy
    }

    // MARK: Editing

    /// Adds fields (one undo step for the lot). Each gets `id` as its /NM (a new one when empty). Throws `PdfEditError` for
    /// a name or value that can't be used.
    public static func add(_ data: [UInt8], _ password: String?, _ fields: [DesignField]) throws -> [UInt8] {
        if fields.isEmpty { return data }
        return try PageEditor.edit(data, password) { doc in
            let acro = ensureAcroForm(doc)
            for spec in fields {
                try validate(doc, spec)
                let all = try FormEditor.collect(doc, acro)
                if let clash = nameClash(all.compactMap { f in kindOf(f).map { (f.name, $0) } }, spec.name, spec.kind) { throw PdfEditError(clash) }
                let page = doc.page(spec.pageIndex)
                let rot = PageBoxes.rotate(page)
                // Upright on the turned page, as Acrobat does.
                let mk = rot != 0 ? doc.dict([("R", doc.int(rot))]) : doc.dict()
                let w = doc.add(doc.dict([
                    ("Type", doc.name("Annot")), ("Subtype", doc.name("Widget")), ("NM", doc.text(spec.id.isEmpty ? Annotations.newId() : spec.id)),
                    ("F", doc.int(4)), ("P", page), ("MK", mk), ("BS", doc.dict([("W", doc.int(1)), ("S", doc.name("S"))])),
                ]))
                doc.annots(page).append(w)

                let field: PObj
                if spec.kind == .radio {
                    field = radioGroup(doc, acro, all, spec.name)
                    w.set("Parent", field)
                    kidsOf(doc, field).append(w)
                } else {
                    field = w
                    let type = spec.kind == .text ? "Tx" : spec.kind == .comboBox || spec.kind == .listBox ? "Ch" : spec.kind == .signature ? "Sig" : "Btn"
                    w.set("FT", doc.name(type))
                    let flags = spec.kind == .button ? FormEditor.ffPushButton : spec.kind == .comboBox ? FormEditor.ffCombo : 0
                    if flags != 0 { w.set("Ff", doc.int(flags)) }
                    attach(doc, acro, w, spec.name)
                }
                try apply(doc, acro, field, w, spec, isNew: true)
            }
        }
    }

    /// `update` without the new ids.
    public static func update(_ data: [UInt8], _ password: String?, _ changes: [DesignField]) throws -> [UInt8] {
        var ignored: [String: String] = [:]
        return try update(data, password, changes, newIds: &ignored)
    }

    /// Changes fields to match `changes` (matched by `id`): placement, name (a radio button renamed moves to that group),
    /// and properties. Widgets without an /NM get one, reported through `newIds` (old id → new id). Signed signature
    /// fields can't be changed.
    public static func update(_ data: [UInt8], _ password: String?, _ changes: [DesignField], newIds: inout [String: String]) throws -> [UInt8] {
        if changes.isEmpty { return data }
        var made: [String: String] = [:]
        let result = try PageEditor.edit(data, password) { doc in
            let acro = ensureAcroForm(doc)
            // Find every widget first: positional ids ("p0:3") refer to the document as it was read.
            let targets = try changes.map { change -> (spec: DesignField, page: Int, w: PObj) in
                guard let found = try Annotations.find(doc, change.id) else { throw PdfEditError("That field is no longer in the document.") }
                return (change, found.page, found.annot)
            }
            for (change, page, w) in targets {
                var spec = change
                spec.pageIndex = page
                let all = try FormEditor.collect(doc, acro)
                guard let f = all.first(where: { $0.widgets.contains { $0.identity == w.identity } }) else { throw PdfEditError("That isn't a form field.") }
                guard let kind = kindOf(f) else { throw PdfEditError("That kind of field can't be edited.") }
                if kind == .signature && FormEditor.inherited(f.dict, "V")?.isDict == true { throw PdfEditError("A signed signature field can't be changed.") }
                let choices: [DesignFieldKind] = [.comboBox, .listBox]
                if kind != spec.kind && !(choices.contains(kind) && choices.contains(spec.kind)) { throw PdfEditError("A field can't change its kind.") }
                let pageObj = doc.page(page)
                let index = pageObj.array("Annots")?.elements.firstIndex { $0.identity == w.identity } ?? -1
                try validate(doc, spec, old: describe(doc, pageObj, acro, f, w, page, index))
                if (w.text("NM") ?? "").isEmpty {
                    let id = Annotations.newId()
                    w.set("NM", doc.text(id))
                    made[spec.id] = id
                }

                var field = f.dict
                if spec.name != f.name {
                    let others = all.filter { $0 != f }.compactMap { x in kindOf(x).map { (x.name, $0) } }
                    if let clash = nameClash(others, spec.name, spec.kind) { throw PdfEditError(clash) }
                    if kind == .radio && f.widgets.count > 1 {
                        // This button leaves its group for the named one (created if needed); the group keeps the others.
                        removeKid(doc, acro, f.dict, w)
                        field = radioGroup(doc, acro, all.filter { $0 != f }, spec.name, like: f.dict)
                        w.set("Parent", field)
                        kidsOf(doc, field).append(w)
                    } else if kind == .radio, let target = all.first(where: { $0 != f && $0.name == spec.name && kindOf($0) == .radio }) {
                        // The group's only button joins another group: the old group goes.
                        removeKid(doc, acro, f.dict, w)
                        field = target.dict
                        w.set("Parent", field)
                        kidsOf(doc, field).append(w)
                    } else {
                        detach(doc, acro, f.dict)
                        attach(doc, acro, f.dict, spec.name)
                    }
                }
                let joined = field.identity != f.dict.identity
                if joined {
                    // A button that changes groups doesn't bring its old group's default: the new group keeps its own, and
                    // a new group starts with this button as default only when it was the old one's.
                    if let dv = field.name("DV"), dv != "Off" {
                        spec.defaultValue = dv
                    } else {
                        spec.defaultValue = spec.defaultValue == spec.exportValue && !field.has("DV") && kidsOf(doc, field).count == 1 ? spec.exportValue : ""
                    }
                }
                try apply(doc, acro, field, w, spec, isNew: false, joined: joined)
            }
        }
        newIds.merge(made) { _, new in new }
        return result
    }

    /// Deletes the widgets `ids`, and each field left without widgets (and parents left empty).
    public static func delete(_ data: [UInt8], _ password: String?, _ ids: [String]) throws -> [UInt8] {
        if ids.isEmpty { return data }
        return try PageEditor.edit(data, password) { doc in
            let acro = ensureAcroForm(doc)
            let targets = try ids.map { id -> (page: Int, annot: PObj) in
                guard let found = try Annotations.find(doc, id) else { throw PdfEditError("That field is no longer in the document.") }
                return found
            }
            for (page, w) in targets {
                let f = try FormEditor.collect(doc, acro).first { $0.widgets.contains { $0.identity == w.identity } }
                if let f, f.type == "Sig", FormEditor.inherited(f.dict, "V")?.isDict == true { throw PdfEditError("A signed signature field can't be deleted.") }
                let annots = doc.annots(doc.page(page))
                for i in stride(from: annots.count - 1, through: 0, by: -1) where annots[i]?.identity == w.identity { annots.remove(at: i) }
                guard let f else { continue }
                if f.dict.identity == w.identity {
                    detach(doc, acro, w)
                    removeFromCalculationOrder(acro, w)
                } else {
                    removeKid(doc, acro, f.dict, w) // the field goes (from /CO too) with its last widget
                }
            }
            SignedEdits.noteRemoval()
        }
    }

    /// `setTabOrder` without the new ids.
    public static func setTabOrder(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ ids: [String]) throws -> [UInt8] {
        var ignored: [String: String] = [:]
        return try setTabOrder(data, password, pageIndex, ids, newIds: &ignored)
    }

    /// Sets the fill (Tab) order of page `pageIndex`'s fields: the widgets `ids` in that order (others keep their places),
    /// with the page's /Tabs set to widget order (/W), which Acrobat and `FormEditor` follow. Widgets without an /NM get
    /// one (their positional id would change), reported through `newIds`.
    public static func setTabOrder(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ ids: [String], newIds: inout [String: String]) throws -> [UInt8] {
        let check = try PdfEdit.open(data, password)
        try Annotations.checkPage(check, pageIndex)
        if check.page(pageIndex).array("Annots") == nil { return data }
        var made: [String: String] = [:]
        let result = try PageEditor.edit(data, password) { doc in
            let page = doc.page(pageIndex)
            let annots = doc.annots(page)
            var slots: [Int] = []
            var byId: [String: PObj] = [:]
            for i in 0..<annots.count {
                guard let a = annots[i], a.isDict else { continue }
                let id = Annotations.idOf(doc, a, pageIndex, i)
                guard ids.contains(id), byId[id] == nil else { continue } // another with the same /NM stays where it is
                slots.append(i)
                byId[id] = a
                if (a.text("NM") ?? "").isEmpty {
                    let nm = Annotations.newId()
                    a.set("NM", doc.text(nm))
                    made[id] = nm
                }
            }
            var seen = Set<String>()
            let ordered = ids.filter { byId[$0] != nil && seen.insert($0).inserted }.compactMap { byId[$0] }
            for (slot, item) in zip(slots, ordered) { annots.replace(at: slot, with: item) }
            page.set("Tabs", doc.name("W"))
        }
        newIds.merge(made) { _, new in new }
        return result
    }

    // MARK: Internals

    /// Checks what a new field sets, or what an edit changes (`old`: the field as it is): a field the form came with may
    /// keep a name, value or size Inkvolt PDF wouldn't make, and still be moved.
    private static func validate(_ doc: MuDoc, _ spec: DesignField, old: DesignField? = nil) throws {
        let pageCount = try doc.pageCount()
        if spec.pageIndex < 0 || spec.pageIndex >= pageCount { throw PdfEditError("That page isn't in the document.") }
        let resized = old.map { abs($0.rect.width - spec.rect.width) > 0.01 || abs($0.rect.height - spec.rect.height) > 0.01 } ?? true
        if resized && (spec.rect.width < 4 || spec.rect.height < 4) { throw PdfEditError("A field needs to be at least 4 points wide and high.") }
        if old == nil, let problem = nameProblem(spec.name) { throw PdfEditError(problem) }
        if spec.kind == .checkBox || spec.kind == .radio, spec.exportValue != old?.exportValue, let bad = exportValueProblem(spec.exportValue) { throw PdfEditError(bad) }
        if spec.kind == .comboBox || spec.kind == .listBox, spec.options != old?.options ?? [], spec.options.contains("") { throw PdfEditError("A choice can't be empty.") }
        if !spec.optionLabels.isEmpty && spec.optionLabels.count != spec.options.count { throw PdfEditError("Each choice needs its own text.") }
    }

    /// The catalog's /AcroForm (made if missing) with /Fields, /DR fonts and /DA; a hybrid form's XFA goes, since XFA
    /// viewers would show the old form without the new fields.
    private static func ensureAcroForm(_ doc: MuDoc) -> PObj {
        let catalog = doc.catalog
        let acro: PObj
        if let existing = catalog.dict("AcroForm") {
            acro = existing
        } else {
            acro = doc.add(doc.dict())
            catalog.set("AcroForm", acro)
        }
        if acro.array("Fields") == nil { acro.set("Fields", doc.array()) }
        FormEditor.ensureDefaultFonts(doc, acro)
        acro.remove("XFA")
        catalog.remove("NeedsRendering")
        return acro
    }

    private static func kidsOf(_ doc: MuDoc, _ node: PObj) -> PObj {
        if let kids = node.array("Kids") { return kids }
        let made = doc.array()
        node.set("Kids", made)
        return made
    }

    /// The radio group named `name`, or a new one (copying `like`'s flags and tooltip).
    private static func radioGroup(_ doc: MuDoc, _ acro: PObj, _ all: [FormField], _ name: String, like: PObj? = nil) -> PObj {
        if let existing = all.first(where: { $0.name == name && kindOf($0) == .radio }) { return existing.dict }
        let fresh = FormEditor.ffRadio | FormEditor.ffNoToggleToOff
        let flags = like.flatMap { FormEditor.inherited($0, "Ff")?.int } ?? fresh
        let g = doc.add(doc.dict([("FT", doc.name("Btn")), ("Ff", doc.int(flags)), ("Kids", doc.array()), ("V", doc.name("Off"))]))
        if let like, let tu = FormEditor.inherited(like, "TU")?.text { g.set("TU", doc.text(tu)) }
        attach(doc, acro, g, name)
        return g
    }

    /// Puts a terminal field under the parent fields its name's leading parts name (made when missing).
    private static func attach(_ doc: MuDoc, _ acro: PObj, _ node: PObj, _ fullName: String) {
        let parts = fullName.components(separatedBy: ".")
        guard var siblings = acro.array("Fields") else { return }
        var parent: PObj?
        for part in parts.dropLast() {
            var next = siblings.elements.first { $0.isDict && $0.text("T") == part && isGroupNode($0) }
            if next == nil {
                let made = doc.add(doc.dict([("T", doc.text(part)), ("Kids", doc.array())]))
                if let parent { made.set("Parent", parent) }
                siblings.append(made)
                next = made
            }
            parent = next
            siblings = kidsOf(doc, next!)
        }
        node.set("T", doc.text(parts[parts.count - 1]))
        if let parent { node.set("Parent", parent) } else { node.remove("Parent") }
        siblings.append(node)
    }

    /// A non-terminal field: its kids are fields (named), not widgets.
    private static func isGroupNode(_ d: PObj) -> Bool {
        guard let kids = d.array("Kids"), !d.has("FT"), !d.has("Rect") else { return false }
        return kids.count == 0 || kids.elements.contains { $0.isDict && $0.has("T") }
    }

    /// Takes a field out of its parent's /Kids (or /Fields), then removes parents left empty.
    private static func detach(_ doc: MuDoc, _ acro: PObj, _ start: PObj) {
        var node = start
        for _ in 0..<64 {
            let parent = node.dict("Parent")
            let holder = parent == nil ? acro.array("Fields") : parent?.array("Kids")
            if let holder {
                for i in stride(from: holder.count - 1, through: 0, by: -1) where holder[i]?.identity == node.identity { holder.remove(at: i) }
            }
            node.remove("Parent")
            guard let parent, let holder, holder.count == 0, !parent.has("Rect") else { return }
            node = parent // an empty parent goes too
        }
    }

    /// Removes widget `w` from field `field`'s kids; a field left with none goes.
    private static func removeKid(_ doc: MuDoc, _ acro: PObj, _ field: PObj, _ w: PObj) {
        if let kids = field.array("Kids") {
            for i in stride(from: kids.count - 1, through: 0, by: -1) where kids[i]?.identity == w.identity { kids.remove(at: i) }
        }
        w.remove("Parent")
        guard let kids = field.array("Kids"), kids.count > 0 else {
            detach(doc, acro, field)
            removeFromCalculationOrder(acro, field)
            return
        }
        // The value and default may have been the button that left: then they name no button of the group.
        let states = Set(kids.elements.filter(\.isDict).compactMap(FormEditor.onStateOf))
        if let dv = field.name("DV"), dv != "Off", !states.contains(dv) { field.remove("DV") }
        if let v = field.name("V"), v != "Off", !states.contains(v) { field.set("V", doc.name("Off")) }
    }

    /// Refuses a radio button value another button of its group already stands for (they'd turn on together).
    private static func requireFreeValue(_ group: PObj, _ w: PObj, _ spec: DesignField) throws {
        guard group.identity != w.identity, let kids = group.array("Kids") else { return }
        if kids.elements.contains(where: { $0.isDict && $0.identity != w.identity && FormEditor.onStateOf($0) == spec.exportValue }) {
            throw PdfEditError("Another button of \"\(spec.name)\" already stands for \"\(spec.exportValue)\": give this one a value of its own.")
        }
    }

    /// Whether two /DA strings mean the same: font, size and color (gray, RGB or CMYK compared as RGB). For check boxes and
    /// radio buttons only the color counts (their symbol's font and size are the face's business).
    static func sameAppearance(_ a: String, _ b: String, colorOnly: Bool = false) -> Bool {
        let x = DefaultAppearance.parse(a), y = DefaultAppearance.parse(b)
        let cx = toRgb(x.color.c), cy = toRgb(y.color.c)
        let sameColor = abs(cx.r - cy.r) < 0.005 && abs(cx.g - cy.g) < 0.005 && abs(cx.b - cy.b) < 0.005
        return colorOnly ? sameColor : sameColor && x.fontName == y.fontName && abs(x.size - y.size) < 0.01
    }

    private static func removeFromCalculationOrder(_ acro: PObj, _ field: PObj) {
        guard let co = acro.array("CO") else { return }
        for i in stride(from: co.count - 1, through: 0, by: -1) where co[i]?.identity == field.identity { co.remove(at: i) }
    }

    /// Writes `spec`'s properties into the field and the widget, then redraws what they change. `joined`: the widget (a
    /// radio button) just moved into `field` from another group.
    private static func apply(_ doc: MuDoc, _ acro: PObj, _ field: PObj, _ w: PObj, _ spec: DesignField, isNew: Bool, joined: Bool = false) throws {
        let page = doc.page(spec.pageIndex)
        let oldRect = PageBoxes.rectToPage(page, w.array("Rect"))
        let r = PageBoxes.fromPageSpace(page, spec.rect)
        w.set("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2]))
        let resized = isNew || abs(oldRect.width - spec.rect.width) > 0.01 || abs(oldRect.height - spec.rect.height) > 0.01
        let toggle = spec.kind == .checkBox || spec.kind == .radio
        let choice = spec.kind == .comboBox || spec.kind == .listBox

        // Field-wide: tooltip, flags, length, alignment, options, default.
        if spec.tooltip.isEmpty { field.remove("TU") } else { field.set("TU", doc.text(spec.tooltip)) }
        var flags = FormEditor.inherited(field, "Ff")?.int ?? 0
        flags = set(flags, FormEditor.ffReadOnly, spec.readOnly)
        flags = set(flags, FormEditor.ffRequired, spec.required)
        if spec.kind == .text {
            flags = set(flags, FormEditor.ffMultiline, spec.multiline)
        } else if choice {
            flags = set(flags, FormEditor.ffCombo, spec.kind == .comboBox)
            flags = set(flags, FormEditor.ffEdit, spec.kind == .comboBox && spec.editable)
            flags = set(flags, FormEditor.ffMultiSelect, spec.kind == .listBox && spec.multiSelect)
        }
        if flags != 0 || field.has("Ff") { field.set("Ff", doc.int(flags)) }
        if spec.kind == .text && spec.maxLength > 0 { field.set("MaxLen", doc.int(spec.maxLength)) } else { field.remove("MaxLen") }
        if spec.kind == .text || choice || spec.kind == .button {
            field.set("Q", doc.int(min(max(spec.alignment, 0), 2)))
            if field.identity != w.identity { w.remove("Q") }
        }

        let colorsChanged = !isNew && (Annotations.colorOf(w.dict("MK")?.array("BC")) != spec.borderColor
            || Annotations.colorOf(w.dict("MK")?.array("BG")) != spec.fillColor)
        if w.dict("MK") == nil { w.set("MK", doc.dict()) }
        guard let mk = w.dict("MK") else { return }
        setColor(doc, mk, "BC", spec.borderColor)
        setColor(doc, mk, "BG", spec.fillColor)
        if spec.borderColor != nil && w.dict("BS") == nil && !w.has("Border") {
            w.set("BS", doc.dict([("W", doc.int(1)), ("S", doc.name("S"))]))
        }

        // /DA: keep the font the field names, set its size and color.
        let oldDa = w.text("DA") ?? FormEditor.inherited(field, "DA")?.text ?? acro.text("DA")
        var font = oldDa.map { DefaultAppearance.parse($0).fontName } ?? "/Helv"
        if acro.dict("DR")?.dict("Font")?.dict(PdfNames.bare(font)) == nil { font = "/Helv" }
        let rgb = rgbText(spec.textColor)
        let da = toggle ? "/ZaDb 0 Tf \(rgb) rg" : "\(font) \(PdfNum.f(min(max(spec.fontSize, 0), 200))) Tf \(rgb) rg"
        // Compared parsed: "0 g" and "0 0 0 rg" are the same black, and a field's own DA stays as written when it means the same.
        let daChanged = oldDa.map { !sameAppearance($0, da, colorOnly: toggle) } ?? true
        if daChanged || isNew {
            field.set("DA", doc.text(da))
            if field.identity != w.identity && w.has("DA") { w.set("DA", doc.text(da)) }
        }

        var captionChanged = false
        if spec.kind == .text {
            setFormat(doc, field, w, spec)
            setDefault(doc, field, spec.defaultValue.isEmpty ? nil : spec.defaultValue, isNew: isNew)
        } else if choice {
            let (exports, labels) = FormEditor.readOptions(FormEditor.inherited(field, "Opt"))
            let shown = spec.shownOptions
            let optionsChanged = isNew || exports != spec.options || labels != shown
            if optionsChanged {
                field.set("Opt", doc.array(spec.options.enumerated().map { i, o in
                    shown[i].isEmpty || shown[i] == o ? doc.text(o) : doc.array([doc.text(o), doc.text(shown[i])])
                }))
            }
            // Several defaults (a list box's array, which `read` joins with line breaks) stay as they are unless changed;
            // on Windows any edit clears them along with the value.
            let keepsSeveral = !isNew && !optionsChanged && field["DV"]?.isArray == true && defaultText(field["DV"]) == spec.defaultValue
            if !keepsSeveral {
                let dv = !spec.defaultValue.isEmpty && spec.options.contains(spec.defaultValue) ? spec.defaultValue : nil
                let changed = setDefault(doc, field, dv, isNew: isNew)
                if changed || optionsChanged {
                    if let dv, let at = spec.options.firstIndex(of: dv) { field.set("I", doc.array([doc.int(at)])) } else { field.remove("I") }
                }
            }
        } else if spec.kind == .button {
            captionChanged = (mk.text("CA") ?? "") != spec.caption
            if spec.caption.isEmpty { mk.remove("CA") } else { mk.set("CA", doc.text(spec.caption)) }
            setAction(doc, w, spec.action)
        }

        // Appearances.
        if toggle {
            let oldState = FormEditor.onStateOf(w)
            if spec.kind == .radio && (isNew || joined || oldState != spec.exportValue) { try requireFreeValue(field, w, spec) }
            if isNew || resized || colorsChanged || daChanged || oldState != spec.exportValue {
                ButtonFaces.build(doc, w, radio: spec.kind == .radio, state: spec.exportValue, mark: spec.textColor)
            }
            setButtonDefault(doc, field, w, spec, oldState, isNew: isNew)
        } else {
            let f = try FormEditor.collect(doc, acro).first { $0.dict.identity == field.identity }
            if spec.kind == .text || choice, let f {
                FormEditor.writeAppearances(doc, acro, f)
            } else if (isNew || resized || colorsChanged || daChanged || captionChanged) && mk.dict("I") == nil {
                // A button with an icon (/MK /I) keeps its faces (normal, down, rollover): only its rect moves.
                staticFace(doc, w, spec)
            }
        }
    }

    private static func set(_ flags: Int, _ bit: Int, _ on: Bool) -> Int { on ? flags | bit : flags & ~bit }

    private static func rgbText(_ c: AnnotColor) -> String { "\(PdfNum.f(c.r)) \(PdfNum.f(c.g)) \(PdfNum.f(c.b))" }

    private static func setColor(_ doc: MuDoc, _ mk: PObj, _ key: String, _ c: AnnotColor?) {
        if let c { mk.set(key, doc.realArray([c.r, c.g, c.b])) } else { mk.remove(key) }
    }

    /// Sets a text /DV, and /V along with it (a designer's default is what the form starts with). True if it changed.
    @discardableResult
    private static func setDefault(_ doc: MuDoc, _ field: PObj, _ value: String?, isNew: Bool) -> Bool {
        let old = field["DV"]
        let same = value == nil ? old == nil : old?.kind == .string && old?.text == value
        if same && !isNew { return false }
        if let value {
            field.set("DV", doc.text(value))
            field.set("V", doc.text(value))
        } else {
            field.remove("DV")
            field.remove("V")
        }
        field.remove("RV")
        return true
    }

    /// Check box: on by default when the default is its export value. Radio: the group's default button.
    private static func setButtonDefault(_ doc: MuDoc, _ field: PObj, _ w: PObj, _ spec: DesignField, _ oldState: String?, isNew: Bool) {
        let state = spec.exportValue
        // A renamed state carries the value along.
        if let oldState, oldState != state {
            for key in ["V", "DV"] where field.name(key) == oldState { field.set(key, doc.name(state)) }
        }
        let hasDefault = !spec.defaultValue.isEmpty && spec.defaultValue != "Off"
        var dvName: String? = hasDefault ? (spec.kind == .checkBox ? state : spec.defaultValue) : nil
        // A radio default must be the value of a button in the group (this one's new value included).
        if let dv = dvName, spec.kind == .radio, dv != state, field.identity != w.identity {
            let inGroup = field.array("Kids")?.elements.contains { $0.isDict && $0.identity != w.identity && FormEditor.onStateOf($0) == dv } ?? false
            if !inGroup { dvName = nil }
        }
        if isNew || field.name("DV") != dvName {
            if let dvName { field.set("DV", doc.name(dvName)) } else { field.remove("DV") }
            field.set("V", doc.name(dvName ?? "Off"))
        }
        // Each widget shows the field's value.
        let value = field.name("V") ?? "Off"
        let widgets = field.identity != w.identity ? field.array("Kids")?.elements.filter(\.isDict) ?? [w] : [w]
        for k in widgets { k.set("AS", doc.name(FormEditor.onStateOf(k) == value ? value : "Off")) }
    }

    private static func setFormat(_ doc: MuDoc, _ field: PObj, _ w: PObj, _ spec: DesignField) {
        let aa = field.dict("AA")
        let current = FormScripts.parseFormat(FormEditor.scriptText(aa?.dict("F")?["JS"]))
        let custom = current == nil && aa?.dict("F") != nil
        if custom || current == spec.format { return } // a script of the form's own, or nothing to change
        if w.dict("AA")?.dict("F") != nil && field.identity != w.identity { return }
        guard let fmt = spec.format else {
            aa?.remove("F")
            aa?.remove("K")
            if aa?.count == 0 { field.remove("AA") }
            return
        }
        if aa == nil { field.set("AA", doc.dict()) }
        guard let target = field.dict("AA") else { return }
        let scripts = formatScripts(fmt)
        target.set("F", javaScript(doc, scripts.format))
        target.set("K", javaScript(doc, scripts.keystroke))
    }

    private static func javaScript(_ doc: MuDoc, _ js: String) -> PObj {
        doc.dict([("S", doc.name("JavaScript")), ("JS", doc.text(js))])
    }

    /// The Acrobat format and keystroke scripts for `f` (AFNumber_Format and its keystroke …).
    public static func formatScripts(_ f: FieldFormat) -> (format: String, keystroke: String) {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        switch f.kind {
        case .number:
            let args = "\(f.decimals), \(f.separatorStyle), \(f.negativeStyle), 0, \(q(f.currency)), \(f.currencyPrepend ? "true" : "false")"
            return ("AFNumber_Format(\(args));", "AFNumber_Keystroke(\(args));")
        case .percent:
            return ("AFPercent_Format(\(f.decimals), \(f.separatorStyle));", "AFPercent_Keystroke(\(f.decimals), \(f.separatorStyle));")
        case .date:
            return ("AFDate_FormatEx(\(q(f.datePattern)));", "AFDate_KeystrokeEx(\(q(f.datePattern)));")
        case .special:
            return ("AFSpecial_Format(\(f.special));", "AFSpecial_Keystroke(\(f.special));")
        }
    }

    private static func setAction(_ doc: MuDoc, _ w: PObj, _ action: FieldButtonAction) {
        switch action {
        case .other:
            return // the form's own action stays
        case .none:
            w.remove("A")
            return
        case .resetForm:
            w.set("A", doc.dict([("Type", doc.name("Action")), ("S", doc.name("ResetForm"))]))
        case .print:
            w.set("A", doc.dict([("Type", doc.name("Action")), ("S", doc.name("Named")), ("N", doc.name("Print"))]))
        }
        // A push button highlights by pushing in (as Acrobat's default).
        w.set("H", doc.name("P"))
    }

    /// Push buttons and unsigned signature fields: background, border and caption, through the text field painter.
    private static func staticFace(_ doc: MuDoc, _ w: PObj, _ spec: DesignField) {
        // Auto size: a caption sized like a label (at most 12 pt), not as tall as the button.
        let size = spec.fontSize > 0 ? spec.fontSize : min(max((min(spec.rect.width, spec.rect.height) - 6) * 0.7, 4), 12)
        let look = FieldLook(da: "/Helv \(PdfNum.f(size)) Tf \(rgbText(spec.textColor)) rg", quadding: 1, text: spec.kind == .button ? spec.caption : "")
        guard let face = FieldAppearance.build(doc, w, look) else { return }
        w.set("AP", doc.dict([("N", face)]))
    }
}
