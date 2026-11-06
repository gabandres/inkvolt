import Foundation
import PrintCore

/// The parts of `DocumentInventory`'s report, in the order it shows them.
public enum InventorySection: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// JavaScript: document scripts and script actions, with what each one calls.
    case scripts
    /// Actions that run by themselves: when the document opens, closes, is saved or printed, a page opens or closes, a
    /// field is shown.
    case actions
    /// Web addresses, mail addresses, other files and programs the document can reach, and how.
    case addresses
    /// Attached files.
    case attachments
    /// Document properties, XMP metadata, other apps' private data, comment authors.
    case metadata
    /// Digital signatures: who signed, when, why, where.
    case signatures
    /// Earlier versions kept by incremental saves, and the text they show that the current one doesn't.
    case earlierVersions
    /// Hidden layers, hidden comments and fields, text that doesn't show (white, off the page, clipped).
    case hidden
    /// Values filled into form fields.
    case formValues
    /// Covers that hide nothing for good: text or pictures under boxes, redaction marks never applied.
    case redaction

    public static func < (a: InventorySection, b: InventorySection) -> Bool { a.rawValue < b.rawValue }

    /// Its name in the JSON report and the web page's anchors ("earlierVersions").
    public var id: String {
        switch self {
        case .scripts: "scripts"
        case .actions: "actions"
        case .addresses: "addresses"
        case .attachments: "attachments"
        case .metadata: "metadata"
        case .signatures: "signatures"
        case .earlierVersions: "earlierVersions"
        case .hidden: "hidden"
        case .formValues: "formValues"
        case .redaction: "redaction"
        }
    }
}

/// What sets an action off.
public enum InventoryTrigger: Sendable {
    /// Not an action (an attachment, a metadata entry).
    case none
    /// Runs by itself: the document opens, closes, is saved or printed, a page opens or closes, a field is shown.
    case automatic
    /// The pointer passing over a link, comment or field: no click needed.
    case pointer
    /// A click, a key typed, a field chosen or left.
    case use
}

/// One thing the document carries.
public struct InventoryItem: Equatable, Sendable {
    public var section: InventorySection
    /// What it is, in words ("Script", "Web address", "Author").
    public var what: String
    /// Where it is, or what sets it off ("When the document opens", "Page 2, a link", "Document properties"); Windows'
    /// `Where`.
    public var place: String
    /// The thing itself: the address, the value, the script's first lines.
    public var detail: String
    /// Its page (index), or -1.
    public var page = -1
    public var trigger = InventoryTrigger.none
    /// For a script: what it does that reaches outside the document or the reader ("opens a web page").
    public var calls: [String] = []
    /// The kind of content Sanitize Document removes it with; nil when a rewrite (earlier versions) or a redaction (text
    /// that doesn't show, covers) removes it.
    public var removedBy: SanitizeItem?

    public init(_ section: InventorySection, _ what: String, _ place: String, _ detail: String, page: Int = -1,
                trigger: InventoryTrigger = .none, calls: [String] = [], removedBy: SanitizeItem? = nil) {
        self.section = section
        self.what = what
        self.place = place
        self.detail = detail
        self.page = page
        self.trigger = trigger
        self.calls = calls
        self.removedBy = removedBy
    }

    /// Reached or run without a click: by itself, or by the pointer passing over.
    public var withoutClick: Bool { trigger == .automatic || trigger == .pointer }
}

/// What's in this PDF, item by item, with what Sanitize Document finds of each kind (`counts`) and what couldn't be
/// looked at, and why (`notes`).
public struct InventoryReport: Sendable {
    public var items: [InventoryItem]
    public var counts: SanitizeReport
    public var pages: Int
    public var notes: [String]

    /// The document carries nothing but its pages.
    public var isEmpty: Bool { items.isEmpty }

    /// The items of one section (Windows' `In`).
    public func items(in section: InventorySection) -> [InventoryItem] { items.filter { $0.section == section } }

    /// "Scripts (2), web addresses (3), …", or that the document carries nothing but its pages.
    public var summary: String {
        if isEmpty {
            return loc("Nothing but its pages: no scripts, actions, addresses, attachments, metadata, earlier versions, hidden content or form values.")
        }
        var perSection: [InventorySection: Int] = [:]
        for i in items { perSection[i.section, default: 0] += 1 }
        let parts = perSection.keys.sorted().map { loc("{0} ({1})", DocumentInventory.lower(DocumentInventory.title($0)), DocumentInventory.n0(perSection[$0] ?? 0)) }
        let outward = items.filter { $0.section == .addresses && $0.withoutClick }.count
        let text = parts.joined(separator: ", ")
        var s = text.prefix(1).uppercased() + text.dropFirst() + "."
        if outward > 0 {
            s += outward == 1 ? loc(" {0} address is reached without a click.", DocumentInventory.n0(outward))
                : loc(" {0} addresses are reached without a click.", DocumentInventory.n0(outward))
        }
        return s
    }
}

/// What's in This PDF (the Windows app's `DocumentInventory`): one readable report of everything a file carries
/// besides what its pages show, and what it does when opened. Scripts (and what they call), actions that run by
/// themselves, every web address, file and program it can reach (and whether that happens without a click),
/// attachments, metadata and comment authors, signatures, earlier versions (and the text they show that the current
/// one doesn't), hidden layers, comments, fields and text, form values, and covers that hide nothing (the
/// `RedactionCheck`'s own findings). Nothing is changed. What Sanitize Document removes is said per item
/// (`InventoryItem.removedBy`), so after sanitizing everything the report is empty.
public enum DocumentInventory {
    /// The longest detail kept (a script's first part, a long value).
    static let maxDetail = 400
    /// Most items per section (a file with 100,000 comments by one author stays readable).
    static let maxPerSection = 2000

    public static func title(_ s: InventorySection) -> String {
        switch s {
        case .scripts: loc("Scripts")
        case .actions: loc("Actions that run by themselves")
        case .addresses: loc("Web addresses, files and programs")
        case .attachments: loc("Attached files")
        case .metadata: loc("Metadata and authors")
        case .signatures: loc("Digital signatures")
        case .earlierVersions: loc("Earlier versions")
        case .hidden: loc("Hidden content")
        case .formValues: loc("Form values")
        case .redaction: loc("Text and pictures under covers")
        }
    }

    public static func name(_ t: InventoryTrigger) -> String {
        switch t {
        case .automatic: loc("By itself")
        case .pointer: loc("When the pointer passes over")
        case .use: loc("On a click or other use")
        case .none: ""
        }
    }

    /// Looks at the whole document. Nothing is changed.
    /// - Parameter progress: (steps done, steps): the redaction check's pages and earlier versions.
    /// - Throws: `PasswordRequired` when the password is missing or wrong; `CancellationError`; `PdfEditError` and
    ///   `PdfEngineError` for a file that can't be read.
    public static func run(_ data: [UInt8], _ password: String?, progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil) throws -> InventoryReport {
        let counts = try Sanitizer.scan(data, password)
        var notes = counts.notes
        let doc = try PdfEdit.openToRead(data, password)
        let pages = try doc.pageCount()
        let walk = Walk(doc)
        try walk.run(pages, cancel)
        var items = walk.items

        for a in attachments(doc, pages) {
            let place = a.page >= 0 ? loc("Page {0}, an attachment comment", CoreLanguage.number(a.page + 1)) : loc("The document's attachments")
            let description = (a.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ", " + (a.description ?? "")
            items.append(InventoryItem(.attachments, loc("Attached file"), place, "\(a.name) (\(size(a.size))\(description))", page: a.page, removedBy: .embeddedFiles))
        }

        if counts.earlierRevisions > 0 {
            let versions = counts.earlierRevisions == 1
                ? loc("{0} earlier version of the file can be opened from it, with everything they held.", n0(1))
                : loc("{0} earlier versions of the file can be opened from it, with everything they held.", n0(counts.earlierRevisions))
            items.append(InventoryItem(.earlierVersions, loc("Earlier versions"), loc("Kept by incremental saves"), versions))
        }

        // The redaction check's own findings: what the pages hold that doesn't show, covers, earlier versions' text. (Its
        // echoes of that text elsewhere in the file are left out: those places are listed here in their own right.)
        let check = try RedactionCheck.run(data, password, RedactionCheckOptions(), progress: progress, cancel: cancel)
        for f in check.findings {
            let section: InventorySection?
            switch f.kind {
            case .hiddenText: section = .hidden
            case .earlierRevision: section = .earlierVersions
            case .coveredText, .coveredContent, .unappliedMark, .glyphSpacing, .areaNotRemoved: section = .redaction
            default: section = nil
            }
            if let section {
                items.append(InventoryItem(section, RedactionCheck.name(f.kind), f.place, clip(f.text), page: f.page, removedBy: f.sanitize))
            }
        }
        notes += check.notes

        var kept: [InventoryItem] = []
        for s in InventorySection.allCases {
            let list = items.filter { $0.section == s }
            kept += list.prefix(maxPerSection)
            if list.count > maxPerSection { notes.append(loc("{0}: only the first {1} of {2} are listed.", title(s), n0(maxPerSection), n0(list.count))) }
        }
        var distinct: [String] = []
        for n in notes where !distinct.contains(n) { distinct.append(n) }
        return InventoryReport(items: kept, counts: counts, pages: pages, notes: distinct)
    }

    // MARK: The walk

    private final class Walk {
        private static let annotHidden = 2, annotNoView = 32, ffPushButton = 1 << 16

        let doc: MuDoc
        var items: [InventoryItem] = []
        private var actions = Set<UInt>()
        private var addresses = Set<String>()
        private var pageCount = 0

        init(_ doc: MuDoc) { self.doc = doc }

        func run(_ pages: Int, _ cancel: CancelToken?) throws {
            pageCount = pages
            let catalog = doc.catalog
            document(catalog)
            for p in 0..<pages {
                try cancel.check()
                page(doc.page(p), p)
            }
            outline(catalog)
            form(catalog)
            layers(catalog)
            metadata(catalog)
            externalStreams()
        }

        // ---- Actions ----

        /// An action (with the ones after it) at `place`, set off by `trigger`.
        private func action(_ item: PObj?, _ place: String, _ trigger: InventoryTrigger, _ page: Int) {
            var chain: [PObj] = []
            var seen = Set<UInt>()
            flatten(item, &chain, &seen, 0)
            for a in chain {
                if !actions.insert(a.identity).inserted { continue }
                let s = a.name("S") ?? ""
                if s == "JavaScript" || a.has("JS") {
                    script(FormEditor.scriptText(a["JS"]) ?? "", place, trigger, page)
                    continue
                }
                let (what, target, removedBy) = describe(a, s)
                // Going to a page of this document by itself is ordinary navigation: not listed.
                if trigger == .automatic && s != "GoTo" {
                    items.append(InventoryItem(.actions, what, place, target ?? Self.words(s), page: page, trigger: trigger, removedBy: removedBy))
                }
                if let target, ["URI", "SubmitForm", "GoToR", "GoToE", "Launch", "ImportData", "Thread"].contains(s) {
                    address(target, what, place, trigger, page, removedBy ?? .externalLinks)
                } else if trigger != .automatic && removedBy == .activeContent {
                    items.append(InventoryItem(.scripts, what, place, target ?? Self.words(s), page: page, trigger: trigger, removedBy: removedBy))
                }
            }
        }

        private func flatten(_ item: PObj?, _ chain: inout [PObj], _ seen: inout Set<UInt>, _ depth: Int) {
            guard depth <= 32, let a = item, a.isDict, seen.insert(a.identity).inserted else { return }
            chain.append(a)
            guard let next = a["Next"] else { return }
            if next.isDict {
                flatten(next, &chain, &seen, depth + 1)
            } else if next.isArray {
                for n in next.elements { flatten(n, &chain, &seen, depth + 1) }
            }
        }

        /// An action in words, its target (an address, a file, a page) and what Sanitize removes it as.
        private func describe(_ a: PObj, _ s: String) -> (what: String, target: String?, removedBy: SanitizeItem?) {
            switch s {
            case "URI": return (loc("Opens a web address"), Self.clean(a.text("URI")), .externalLinks)
            case "SubmitForm": return (loc("Sends the form's data"), Self.fileName(a["F"]), .activeContent)
            case "ImportData": return (loc("Reads form data from a file"), Self.fileName(a["F"]), .activeContent)
            case "Launch": return (loc("Starts a program or opens a file"), Self.fileName(a["F"]) ?? Self.fileName(a.dict("Win")?["F"]), .activeContent)
            case "GoToR": return (loc("Opens another PDF"), Self.fileName(a["F"]), .externalLinks)
            case "GoToE": return (loc("Opens an embedded or other PDF"), Self.fileName(a["F"]) ?? loc("an attached PDF"), .externalLinks)
            case "Thread" where a.has("F"): return (loc("Opens an article in another file"), Self.fileName(a["F"]), .externalLinks)
            case "Rendition", "Movie", "Sound", "RichMediaExecute", "GoTo3DView": return (loc("Plays media"), nil, .activeContent)
            case "GoTo": return (loc("Goes to a page"), DocumentFeatures.resolveDestination(doc, a["D"]).map { loc("page {0}", CoreLanguage.number($0.pageIndex + 1)) }, nil)
            case "Named": return (loc("Runs a viewer command"), a.name("N"), nil)
            case "Hide": return (loc("Shows or hides fields"), nil, nil)
            case "ResetForm": return (loc("Clears the form"), nil, nil)
            case "SetOCGState": return (loc("Shows or hides layers"), nil, nil)
            default: return (loc("Action"), s, nil)
            }
        }

        private static func words(_ s: String) -> String { s.isEmpty ? loc("(no type)") : s }

        static func fileName(_ f: PObj?) -> String? {
            guard let f else { return nil }
            if f.kind == .string { return clean(f.text) }
            guard f.isDict else { return nil }
            return clean(f.text("UF") ?? f.text("F") ?? f.text("DOS") ?? f.text("Unix"))
        }

        private static func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : clip(t)
        }

        private func address(_ target: String, _ what: String, _ place: String, _ trigger: InventoryTrigger, _ page: Int, _ removedBy: SanitizeItem?) {
            guard addresses.insert("\(target)\n\(place)\n\(trigger)").inserted else { return }
            items.append(InventoryItem(.addresses, what, place, target, page: page, trigger: trigger, removedBy: removedBy))
        }

        private func script(_ source: String, _ place: String, _ trigger: InventoryTrigger, _ page: Int) {
            items.append(InventoryItem(.scripts, loc("Script"), place, clip(source.trimmingCharacters(in: .whitespacesAndNewlines)), page: page,
                                       trigger: trigger, calls: scriptCalls(source), removedBy: .activeContent))
            let ns = source as NSString
            for m in urlPattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                var url = ns.substring(with: m.range)
                while let last = url.last, ".,;".contains(last) { url.removeLast() }
                address(url, loc("Web address in a script"), place, trigger, page, .activeContent)
            }
        }

        /// The additional actions (/AA) of a document, page, comment or field.
        private func additionalActions(_ owner: PObj, _ page: Int, _ name: (String) -> (place: String, trigger: InventoryTrigger)?) {
            guard let aa = owner.dict("AA") else { return }
            for key in aa.keys {
                if let n = name(key) { action(aa[key], n.place, n.trigger, page) }
            }
        }

        // ---- Document, pages ----

        private func document(_ catalog: PObj) {
            if catalog.dict("OpenAction") != nil { action(catalog["OpenAction"], loc("When the document opens"), .automatic, -1) }
            additionalActions(catalog, -1) { key in
                switch key {
                case "WC": (loc("Before the document closes"), .automatic)
                case "WS": (loc("Before the document is saved"), .automatic)
                case "DS": (loc("After the document is saved"), .automatic)
                case "WP": (loc("Before the document is printed"), .automatic)
                case "DP": (loc("After the document is printed"), .automatic)
                default: (loc("Document event {0}", key), .automatic)
                }
            }
            for (key, value) in PdfStructure.nameTree(catalog.dict("Names")?.dict("JavaScript")) {
                action(value, loc("When the document opens (document script \u{201C}{0}\u{201D})", key), .automatic, -1)
            }
            if let base = catalog.dict("URI")?.text("Base"), !base.isEmpty {
                address(base, loc("Base of relative web addresses"), loc("The document"), .none, -1, .externalLinks)
            }
        }

        private func page(_ page: PObj, _ p: Int) {
            additionalActions(page, p) { key in
                switch key {
                case "O": (loc("When page {0} opens", CoreLanguage.number(p + 1)), .automatic)
                case "C": (loc("When page {0} closes", CoreLanguage.number(p + 1)), .automatic)
                default: nil
                }
            }
            guard let annots = page.array("Annots") else { return }
            for a in annots.elements where a.isDict {
                let subtype = a.name("Subtype") ?? ""
                if subtype == "Popup" { continue }
                let kind: String
                switch subtype {
                case "Link": kind = loc("a link")
                case "Widget": kind = Self.fieldName(of: a).map { loc("field \u{201C}{0}\u{201D}", $0) } ?? loc("a form field")
                default: kind = loc("a comment")
                }
                let at = loc("Page {0}, {1}", CoreLanguage.number(p + 1), kind)
                if subtype != "Widget" { // a widget's actions go with its field (form)
                    action(a["A"], loc("When {0} on page {1} is clicked", kind, CoreLanguage.number(p + 1)), .use, p)
                    additionalActions(a, p) { Self.event($0, at, p, nil) }
                }
                if ["RichMedia", "3D", "Sound", "Movie", "Screen"].contains(subtype) {
                    items.append(InventoryItem(.scripts, loc("Multimedia or 3D"), at, subtype, page: p, trigger: .use, removedBy: .activeContent))
                }
                let flags = a.int("F") ?? 0
                if flags & (Self.annotHidden | Self.annotNoView) != 0 {
                    let detail = FormEditor.scriptText(a["Contents"]) ?? FormEditor.inherited(a, "V")?.text ?? subtype
                    items.append(InventoryItem(.hidden, subtype == "Widget" ? loc("Hidden form field") : loc("Hidden comment"), at, clip(detail),
                                               page: p, removedBy: .hiddenAnnotations))
                }
            }
        }

        /// An annotation or field event (/AA key) in words.
        private static func event(_ key: String, _ at: String, _ p: Int, _ field: String?) -> (place: String, trigger: InventoryTrigger)? {
            switch key {
            case "E": return (loc("{0}: when the pointer enters it", at), .pointer)
            case "X": return (loc("{0}: when the pointer leaves it", at), .pointer)
            case "D": return (loc("{0}: when the mouse button is pressed on it", at), .use)
            case "U": return (loc("{0}: when it is clicked", at), .use)
            case "Fo": return (loc("{0}: when it gets the focus", at), .use)
            case "Bl": return (loc("{0}: when it loses the focus", at), .use)
            case "PO": return (loc("{0}: when page {1} opens", at, CoreLanguage.number(p + 1)), .automatic)
            case "PC": return (loc("{0}: when page {1} closes", at, CoreLanguage.number(p + 1)), .automatic)
            case "PV": return (loc("{0}: when page {1} comes into view", at, CoreLanguage.number(p + 1)), .automatic)
            case "PI": return (loc("{0}: when page {1} goes out of view", at, CoreLanguage.number(p + 1)), .automatic)
            default: break
            }
            guard let field else { return nil }
            switch key {
            case "K": return (loc("Field \u{201C}{0}\u{201D}: as it is typed in", field), .use)
            case "V": return (loc("Field \u{201C}{0}\u{201D}: when its value changes", field), .use)
            case "C": return (loc("Field \u{201C}{0}\u{201D}: when the form recalculates", field), .use)
            case "F": return (loc("Field \u{201C}{0}\u{201D}: whenever it is shown", field), .automatic)
            default: return nil
            }
        }

        private static func fieldName(of widget: PObj) -> String? {
            var parts: [String] = []
            var node: PObj? = widget
            var guardCount = 0
            while let d = node, guardCount < 64 {
                if let t = d.text("T") { parts.insert(t, at: 0) }
                node = d.dict("Parent")
                guardCount += 1
            }
            return parts.isEmpty ? nil : parts.joined(separator: ".")
        }

        private func pageOf(_ widget: PObj) -> Int {
            if let p = doc.pageIndex(of: widget["P"]) { return p }
            for i in 0..<pageCount where doc.page(i).array("Annots")?.elements.contains(where: { $0.identity == widget.identity }) == true { return i }
            return -1
        }

        // ---- Bookmarks, form, layers ----

        private func outline(_ catalog: PObj) {
            guard let outlines = catalog.dict("Outlines") else { return }
            var seen: Set<UInt> = [outlines.identity]
            var stack: [PObj] = []
            if let first = outlines.dict("First") { stack.append(first) }
            var n = 0
            while let top = stack.popLast(), n < 200_000 {
                var item: PObj? = top
                while let cur = item, seen.insert(cur.identity).inserted, n < 200_000 {
                    n += 1
                    let title = clip(cur.text("Title") ?? "", 80)
                    action(cur["A"], loc("When the bookmark \u{201C}{0}\u{201D} is chosen", title), .use, -1)
                    if let child = cur.dict("First") { stack.append(child) }
                    item = cur.dict("Next")
                }
            }
        }

        private func form(_ catalog: PObj) {
            guard let acro = catalog.dict("AcroForm") else { return }
            let fields = (try? FormEditor.collect(doc, acro)) ?? []
            for f in fields {
                let widgets = f.widgets.isEmpty ? [f.dict] : f.widgets
                let page = widgets.lazy.map(pageOf).first { $0 >= 0 } ?? -1
                let at = page >= 0 ? loc("Field \u{201C}{0}\u{201D}, page {1}", f.name, CoreLanguage.number(page + 1)) : loc("Field \u{201C}{0}\u{201D}", f.name)
                // The field's own actions and each widget's (a widget may be the field itself).
                var nodes: [PObj] = []
                for n in [f.dict] + widgets where !nodes.contains(where: { $0.identity == n.identity }) { nodes.append(n) }
                for node in nodes {
                    action(node["A"], loc("When field \u{201C}{0}\u{201D} is clicked", f.name), .use, page)
                    additionalActions(node, page) { Self.event($0, at, max(page, 0), f.name) }
                }
                if f.type == "Sig" {
                    if let sig = FormEditor.inherited(f.dict, "V"), sig.isDict { signature(sig, at, page) }
                    continue
                }
                if let value = Self.value(f) {
                    items.append(InventoryItem(.formValues, loc("Value"), at, clip(value), page: page, removedBy: .formValues))
                }
            }
            if acro.has("XFA") {
                items.append(InventoryItem(.scripts, loc("XFA form"), loc("The document's form"), loc("An XFA form: it can hold scripts and its own copy of the form's data."),
                                           removedBy: fields.isEmpty ? nil : .activeContent))
            }
        }

        private func signature(_ sig: PObj, _ at: String, _ page: Int) {
            var parts: [String] = []
            if let name = sig.text("Name"), !name.isEmpty { parts.append(name) }
            if let m = sig.text("M"), let when = PdfDates.parse(m) { parts.append(DocumentInventory.date(when, written: m)) }
            if let reason = sig.text("Reason"), !reason.isEmpty { parts.append(loc("reason: {0}", reason)) }
            if let location = sig.text("Location"), !location.isEmpty { parts.append(loc("at {0}", location)) }
            if let contact = sig.text("ContactInfo"), !contact.isEmpty { parts.append(loc("contact: {0}", contact)) }
            if parts.isEmpty { parts.append(loc("a signature (with the signer's certificate)")) }
            items.append(InventoryItem(.signatures, loc("Signed"), at, clip(parts.joined(separator: ", ")), page: page, removedBy: .signatures))
        }

        /// A field's value in words (as Sanitize counts values: text, choices, a box that is on, a default).
        private static func value(_ f: FormField) -> String? {
            func text(_ item: PObj?) -> String? {
                guard let item else { return nil }
                if item.isArray { return item.elements.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "; ") }
                if item.isStream { return FormEditor.scriptText(item) }
                return item.text
            }
            switch f.type {
            case "Tx", "Ch":
                if let v = text(FormEditor.inherited(f.dict, "V")), !v.isEmpty { return v }
                if let dv = text(f.dict["DV"]), !dv.isEmpty { return loc("{0} (its default)", dv) }
                return nil
            case "Btn" where f.flags & ffPushButton == 0:
                var on: String?
                if let n = FormEditor.inherited(f.dict, "V")?.name, n != "Off" {
                    on = n
                } else {
                    on = f.widgets.lazy.compactMap { $0.name("AS") }.first { $0 != "Off" }
                }
                return on.map { loc("on ({0})", $0) }
            default:
                return nil
            }
        }

        private func layers(_ catalog: PObj) {
            guard let props = catalog.dict("OCProperties"), let list = props.array("OCGs") else { return }
            let d = props.dict("D")
            let on = Set(Self.members(d?["ON"]).map(\.identity))
            let off = Set(Self.members(d?["OFF"]).map(\.identity))
            let baseOff = d?.name("BaseState") == "OFF"
            for ocg in Self.members(list) where off.contains(ocg.identity) || (baseOff && !on.contains(ocg.identity)) {
                items.append(InventoryItem(.hidden, loc("Hidden layer"), loc("The document's layers"),
                                           loc("\u{201C}{0}\u{201D}, off when the document opens, with what it draws", clip(ocg.text("Name") ?? loc("(no name)"), 120)),
                                           removedBy: .hiddenLayers))
            }
        }

        /// The dictionaries in an array (or a single one), each once.
        private static func members(_ item: PObj?) -> [PObj] {
            guard let item else { return [] }
            if item.isDict { return [item] }
            var out: [PObj] = []
            var seen = Set<UInt>()
            for d in item.elements where d.isDict && seen.insert(d.identity).inserted { out.append(d) }
            return out
        }

        // ---- Metadata ----

        private func metadata(_ catalog: PObj) {
            if let info = doc.info {
                for key in info.keys {
                    guard let v = info[key] else { continue }
                    var value = v.text ?? v.name.map { "/" + $0 } ?? v.number.map { PdfNum.f2($0) } ?? ""
                    if (key == "Producer" || key == "Creator") && value.hasPrefix("PDFsharp") { continue } // what a save writes itself
                    if key == "CreationDate" || key == "ModDate", let t = PdfDates.parse(value) { value = DocumentInventory.date(t, written: value, zone: true) }
                    items.append(InventoryItem(.metadata, Self.infoName(key), loc("Document properties"), clip(value), removedBy: .metadata))
                }
            }

            var authors: [String: (count: Int, pages: Set<Int>)] = [:]
            var authorOrder: [String] = []
            var objects = Set<UInt>()
            // Pages are pushed last so they are walked first: what they hold is listed with its page.
            var stack: [(item: PObj, depth: Int, page: Int)] = [(catalog, 0, -1)]
            for p in stride(from: pageCount - 1, through: 0, by: -1) { stack.append((doc.page(p), 0, p)) }
            while let (item, depth, page) = stack.popLast() {
                let place = page >= 0 ? loc("Page {0}", CoreLanguage.number(page + 1)) : loc("The document")
                if depth > 64 { continue }
                if item.isArray {
                    for e in item.elements where e.isDict || e.isArray { stack.append((e, depth + 1, page)) }
                    continue
                }
                guard item.isDict else { continue }
                let type = item.name("Type")
                if !objects.insert(item.identity).inserted || type == "Pages" || (depth > 0 && type == "Page") { continue }

                let subtype = item.name("Subtype") ?? ""
                let isCatalog = item.identity == catalog.identity
                let owner = Self.owner(item, subtype, place, isCatalog: isCatalog, isPage: depth == 0 && page >= 0)
                if item.has("Rect") && !subtype.isEmpty && !["Widget", "Link", "Popup"].contains(subtype) && !item.has("BBox"),
                   let author = item.text("T"), !author.isEmpty {
                    if authors[author] == nil { authorOrder.append(author) }
                    var entry = authors[author] ?? (0, [])
                    entry.count += 1
                    if page >= 0 { entry.pages.insert(page + 1) }
                    authors[author] = entry
                }
                if let piece = item.dict("PieceInfo") {
                    items.append(InventoryItem(.metadata, loc("Private data of other apps"), owner, piece.keys.joined(separator: ", "), removedBy: .metadata))
                }
                if let xmp = item.dict("Metadata"), xmp.isStream {
                    if let props = Sanitizer.xmpProperties(xmp) {
                        if !props.isEmpty {
                            for (name, value) in props {
                                items.append(InventoryItem(.metadata, Self.xmpName(name), loc("{0}, XMP metadata", owner), clip(value), removedBy: .metadata))
                            }
                        } else if !isCatalog {
                            items.append(InventoryItem(.metadata, loc("XMP metadata"), owner, loc("a packet (empty)"), removedBy: .metadata))
                        }
                    } else {
                        items.append(InventoryItem(.metadata, loc("XMP metadata"), owner, loc("a packet that can't be read"), removedBy: .metadata))
                    }
                }
                if let af = item.array("AF"), af.count > 0 {
                    items.append(InventoryItem(.attachments, loc("Associated file"), owner,
                                               af.elements.map { Self.fileName($0) ?? loc("(no name)") }.joined(separator: ", "), removedBy: .embeddedFiles))
                }

                for key in item.keys where !["Parent", "P", "Metadata", "Prev", "Last", "Dest", "D"].contains(key) {
                    if let v = item[key], v.isDict || v.isArray { stack.append((v, depth + 1, page)) }
                }
            }
            // Most comments first (a stable order for the same count: first met first).
            let ranked = authorOrder.enumerated().sorted { a, b in
                let ca = authors[a.element]?.count ?? 0, cb = authors[b.element]?.count ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }.map(\.element)
            for author in ranked {
                guard let (count, pageSet) = authors[author] else { continue }
                let pages = pageSet.sorted()
                var detail = author
                if !pages.isEmpty {
                    let list = pages.prefix(20).map(String.init).joined(separator: ", ") + (pages.count > 20 ? ", …" : "")
                    detail = pages.count == 1 ? loc("{0} (page {1})", author, list) : loc("{0} (pages {1})", author, list)
                }
                items.append(InventoryItem(.metadata, loc("Comment author"), count == 1 ? loc("{0} comment", n0(1)) : loc("{0} comments", n0(count)), detail, removedBy: .metadata))
            }

            for t in catalog.array("Threads")?.elements ?? [] where t.isDict {
                guard let ti = t.dict("I"), ti.count > 0 else { continue }
                for key in ti.keys {
                    let v = ti[key]
                    let value = v?.text ?? v?.name.map { "/" + $0 } ?? v?.number.map { PdfNum.f2($0) } ?? ""
                    items.append(InventoryItem(.metadata, Self.infoName(key), loc("An article's properties"), clip(value), removedBy: .metadata))
                }
            }
        }

        private static func owner(_ d: PObj, _ subtype: String, _ place: String, isCatalog: Bool, isPage: Bool) -> String {
            if isCatalog { return loc("The document") }
            if isPage { return place }
            switch subtype {
            case "Image": return loc("{0}, a picture", place)
            case "Form": return loc("{0}, a drawing", place)
            case "Widget": return loc("{0}, a form field", place)
            case "Type1", "TrueType", "Type0", "Type3", "CIDFontType0", "CIDFontType2": return loc("{0}, a font", place)
            default:
                if d.has("Rect") { return loc("{0}, a comment", place) }
                if d.name("Type") == "FontDescriptor" { return loc("{0}, a font", place) }
                return loc("{0}, an object", place)
            }
        }

        private static func infoName(_ key: String) -> String {
            switch key {
            case "Title": loc("Title")
            case "Author": loc("Author")
            case "Subject": loc("Subject")
            case "Keywords": loc("Keywords")
            case "Creator": loc("Made with")
            case "Producer": loc("Written by")
            case "CreationDate": loc("Created")
            case "ModDate": loc("Modified")
            case "Trapped": loc("Trapped")
            default: key
            }
        }

        private static func xmpName(_ name: String) -> String {
            switch name {
            case "creator": loc("Author (XMP)")
            case "title": loc("Title (XMP)")
            case "description": loc("Subject (XMP)")
            case "subject": loc("Keywords (XMP)")
            case "rights": loc("Rights (XMP)")
            case "CreateDate": loc("Created (XMP)")
            case "ModifyDate": loc("Modified (XMP)")
            case "MetadataDate": loc("Metadata changed (XMP)")
            case "DocumentID": loc("Document ID (XMP)")
            case "InstanceID": loc("Version ID (XMP)")
            case "OriginalDocumentID": loc("Original document ID (XMP)")
            case "History": loc("Editing history (XMP)")
            case "DerivedFrom": loc("Made from (XMP)")
            default: "\(name) (XMP)"
            }
        }

        /// Streams whose data is in another file or on the web (/F): read when the page is drawn.
        private func externalStreams() {
            for o in doc.allObjects() where o.isStream && o.has("F") {
                if let target = Self.fileName(o["F"]) {
                    address(target, loc("Data read from outside the file"), loc("When the page using it is drawn"), .automatic, -1, nil)
                }
            }
        }
    }

    // MARK: Attachments

    /// The document's attached files (Windows: `Attachments.List`, which the Mac gets with E9): the EmbeddedFiles name
    /// tree, then the attachment comments of each page.
    private static func attachments(_ doc: MuDoc, _ pages: Int) -> [(name: String, description: String?, size: Int, page: Int)] {
        func describe(_ fs: PObj, _ fallback: String, _ page: Int) -> (name: String, description: String?, size: Int, page: Int) {
            var name = (fs.text("UF") ?? fs.text("F") ?? fallback).replacingOccurrences(of: "\\", with: "/")
            if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
            if name.isEmpty { name = fallback }
            let ef = fs.dict("EF")
            let stream = ef?.dict("UF") ?? ef?.dict("F")
            var size = stream?.dict("Params")?.int("Size") ?? -1
            if size < 0 { size = stream?.streamData?.count ?? 0 }
            return (name, fs.text("Desc"), size, page)
        }
        var list: [(name: String, description: String?, size: Int, page: Int)] = []
        for (key, value) in PdfStructure.nameTree(doc.catalog.dict("Names")?.dict("EmbeddedFiles")) {
            if let fs = value, fs.isDict { list.append(describe(fs, key, -1)) }
        }
        for p in 0..<pages {
            for a in doc.page(p).array("Annots")?.elements ?? [] where a.isDict && a.name("Subtype") == "FileAttachment" {
                if let fs = a.dict("FS") { list.append(describe(fs, "attachment", p)) }
            }
        }
        return list
    }

    // MARK: Scripts

    /// What a script calls that reaches outside the document or acts on the reader, in words, each once.
    static func scriptCalls(_ source: String) -> [String] {
        var out: [String] = []
        let range = NSRange(location: 0, length: (source as NSString).length)
        for (pattern, key) in calls where pattern.firstMatch(in: source, range: range) != nil && !out.contains(key.text) { out.append(key.text) }
        return out
    }

    /// The patterns are constants, checked by the tests.
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let calls: [(NSRegularExpression, LocKey)] = [
        (regex(#"\b(launchURL|getURL)\s*\("#), LocKey("opens a web address")),
        (regex(#"\bsubmitForm\s*\("#), LocKey("sends the form's data")),
        (regex(#"\b(mailDoc|mailForm|mailMsg|mailGetAddrs)\s*\("#), LocKey("sends email")),
        (regex(#"\b(Net\.HTTP|SOAP\.|Net\.SOAP|Net\.Discovery|Collab\.)"#), LocKey("connects to the internet")),
        (regex(#"\bopenDoc\s*\("#), LocKey("opens another file")),
        (regex(#"\b(exportDataObject|exportAsFDF|exportAsXFDF|exportAsText|exportXFAData|saveAs|extractPages)\s*\("#), LocKey("writes a file")),
        (regex(#"\b(importDataObject|importAnFDF|importAnXFDF|importTextData|importXFAData|importIcon|importSound|readFileIntoStream|browseForDoc)\s*\("#), LocKey("reads a file")),
        (regex(#"\b(launch|openDataObject)\s*\("#), LocKey("opens an attached file")),
        (regex(#"\b(print|printWithParams)\s*\("#), LocKey("prints")),
        (regex(#"\bexecMenuItem\s*\("#), LocKey("runs a menu command")),
        (regex(#"\b(setTimeOut|setInterval)\s*\("#), LocKey("runs on a timer")),
        (regex(#"\b(eval|Function)\s*\("#), LocKey("runs code it builds as it goes")),
        (regex(#"\b(addScript|setAction|setPageAction)\s*\("#), LocKey("adds scripts")),
        (regex(#"\b(alert|response)\s*\("#), LocKey("shows a message or asks a question")),
        (regex(#"\b(identity|app\.platform|app\.viewerVersion)\b"#), LocKey("reads who you are or what your computer runs")),
    ]

    private static let urlPattern =
        regex(#"(?:https?|ftp)://[^\s'"\\()<>\[\]{}]+|mailto:[^\s'"\\()<>\[\]{}]+"#, [.caseInsensitive])

    // MARK: Words

    static func clip(_ text: String, _ max: Int = maxDetail) -> String {
        let s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard s.count > max else { return s }
        var cut = String(s.prefix(max))
        while let last = cut.last, last.isWhitespace { cut.removeLast() }
        return cut + "…"
    }

    static func lower(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).lowercased() + s.dropFirst() }

    /// A count with thousands separators, as .NET's N0 in the interface's language ("12,345" in English).
    static func n0(_ n: Int) -> String { CoreLanguage.number(n) }

    private static func size(_ bytes: Int) -> String {
        func one(_ v: Double) -> String {
            let r = (v * 10).rounded() / 10
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        }
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return "\(one(Double(bytes) / 1024)) KB" }
        return "\(one(Double(bytes) / (1024 * 1024))) MB"
    }

    /// A PDF date in words, at the clock time it was written with ("1 March 2026, 12:00"; with `zone`, its offset too).
    static func date(_ date: Date, written: String, zone: Bool = false) -> String {
        let f = DateFormatter()
        // The interface's month names (Windows' PdfLanguage.Culture); English keeps POSIX so a 12-hour Mac can't change HH.
        f.locale = CoreLanguage.language == "en" ? Locale(identifier: "en_US_POSIX") : CoreLanguage.locale
        f.timeZone = writtenZone(written)
        f.dateFormat = zone ? loc("d MMMM yyyy, HH:mm xxx") : loc("d MMMM yyyy, HH:mm")
        return f.string(from: date)
    }

    /// The time zone a PDF date names (Z, +hh'mm', -hh'mm'), else the one `PdfDates.parse` read it in (this Mac's).
    private static func writtenZone(_ s: String) -> TimeZone {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("D:") { t.removeFirst(2) }
        let rest = t.drop { $0.isASCII && $0.isNumber }
        guard let first = rest.first else { return .current }
        if first == "Z" { return TimeZone(secondsFromGMT: 0) ?? .current }
        guard first == "+" || first == "-" else { return .current }
        let nums = rest.dropFirst().split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let minutes = (nums.first ?? 0) * 60 + (nums.count > 1 ? nums[1] : 0)
        return TimeZone(secondsFromGMT: (first == "-" ? -1 : 1) * minutes * 60) ?? .current
    }
}
