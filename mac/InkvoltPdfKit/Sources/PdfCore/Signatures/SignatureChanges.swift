import CryptoKit
import Foundation
import PrintCore

/// What a signature's later incremental updates changed, and whether the signature permits it (the Windows app's
/// `SignatureChanges`). The signed revision (the file up to the end of the signature's byte range) is compared with the
/// current file object by object (an update redefines objects under the same numbers, and MuPDF keeps the file's
/// numbers). Each changed or added object is judged by its role:
/// - page content (content streams, resources, images and fonts a page draws with), the page tree, page properties, the
///   catalog's view-changing entries (layers, open actions, scripts): never permitted, since they change what the
///   signer saw (incremental "shadow attacks" hide, replace or overlay signed content this way);
/// - form values and their appearances: permitted unless certified with no changes (DocMDP P=1), and unless the field is
///   locked by the signature (FieldMDP);
/// - comments and new signature fields: permitted from P=3 and for approval (non-certifying) signatures;
/// - new form fields, bookmarks, page labels, attachments, tags: approval signatures only;
/// - metadata (Info, XMP), validation data (/DSS), document timestamps that draw nothing and verify: always. When nothing
///   else changed, the analysis says so (`Analysis.onlyValidationData`): such a signature still speaks for the whole document.
enum SignatureChanges {
    /// The permission level of an approval (non-certifying) signature: anything that leaves the signed content as it was.
    private static let approval = 4

    /// A signature dictionary's own entries, as signed.
    struct Entries {
        var subFilter: String?
        var name: String?
        var m: String?
        var reason: String?
        var location: String?
        var certificationLevel: Int?
    }

    /// `permitted`: every later change is one the signature permits (also true when the analysis failed). `problem`: what
    /// was changed that isn't permitted, or why the changes couldn't be checked. `signed`: the signature dictionary's
    /// entries in the signed revision (nil when not found there). `onlyValidationData`: everything added since is long-term
    /// validation data (/DSS) or document timestamps: the document itself is as it was signed.
    struct Analysis {
        var permitted: Bool
        var problem: String?
        var signed: Entries?
        var onlyValidationData = false
    }

    static func entries(of v: PObj) -> Entries {
        Entries(subFilter: v.name("SubFilter"), name: v.text("Name"), m: v.text("M"), reason: v.text("Reason"), location: v.text("Location"),
                certificationLevel: certificationLevel(v))
    }

    /// The DocMDP permission of a certifying signature dictionary (its /Reference), else nil.
    static func certificationLevel(_ v: PObj) -> Int? {
        for r in v.array("Reference")?.elements ?? [] where r.isDict && r.name("TransformMethod") == "DocMDP" {
            if let p = r.dict("TransformParams")?.int("P"), (1...3).contains(p) { return p }
            return 2
        }
        return nil
    }

    static func analyze(_ data: [UInt8], _ signedLength: Int, _ fieldName: String, _ password: String?) -> Analysis {
        do {
            let before = try PdfEdit.openToRead(Array(data[..<signedLength]), password)
            let after = try PdfEdit.openToRead(data, password)
            let fields = try FormEditor.collect(before, before.catalog.dict("AcroForm"))
            let field = fields.first { $0.name == fieldName && $0.type == "Sig" }
            let v = field.flatMap { FormEditor.inherited($0.dict, "V") }.flatMap { $0.isDict ? $0 : nil }
            let entries = v.map(entries(of:))
            let level = entries?.certificationLevel ?? approval
            var locked: (String) -> Bool = { _ in false }
            if let v, let field { locked = lockOf(v, field.dict) }
            let comparison = Comparison(data, before, after, level, locked, before.trailer.has("Info"), after.trailer.has("Info"))
            let problems = try comparison.run()
            if problems.isEmpty { return Analysis(permitted: true, problem: nil, signed: entries, onlyValidationData: comparison.onlyValidationData) }
            var distinct: [String] = []
            for p in problems where !distinct.contains(p) { distinct.append(p) }
            let what = distinct.prefix(3).joined(separator: "; ") + (distinct.count > 3 ? loc("; and more") : "")
            let problem = switch level {
            case 1: loc("The document is certified with no changes allowed, but it was changed after certification: {0}.", what)
            case 2, 3: loc("The document was changed after certification in ways the certification doesn't allow: {0}.", what)
            default: loc("The document was changed after signing in ways a signature doesn't allow: {0}.", what)
            }
            return Analysis(permitted: false, problem: problem, signed: entries)
        } catch {
            return Analysis(permitted: true, problem: loc("Inkvolt PDF couldn't work out what was changed after signing."), signed: nil)
        }
    }

    /// Which fields the signature locks: its FieldMDP references (all of them), else the signature field's /Lock.
    private static func lockOf(_ v: PObj, _ field: PObj) -> (String) -> Bool {
        var locks = (v.array("Reference")?.elements ?? []).filter { $0.isDict && $0.name("TransformMethod") == "FieldMDP" }
            .compactMap { $0.dict("TransformParams") }.prefix(16).map(lockOf)
        if locks.isEmpty, let own = field.dict("Lock") { locks.append(lockOf(own)) }
        return { name in locks.contains { $0(name) } }
    }

    private static func lockOf(_ lock: PObj) -> (String) -> Bool {
        let names = Set(lock.array("Fields")?.elements.compactMap(\.text) ?? [])
        let listed: (String) -> Bool = { name in names.contains { name == $0 || name.hasPrefix($0 + ".") } }
        switch lock.name("Action") {
        case "All": return { _ in true }
        case "Include": return listed
        case "Exclude": return { !listed($0) }
        default: return { _ in false }
        }
    }

    /// `infoA`, `infoB`: the revision's trailer names an Info dictionary.
    private final class Comparison {
        private static let upward: Set<String> = ["Parent", "P", "IRT", "Annots", "Pg", "Popup"]
        private static let widgetKeys: Set<String> = ["V", "AS", "AP", "MK", "DV", "P"]
        private static let fieldKeys: Set<String> = ["V", "DV", "Kids"]
        private static let acroFormKeys: Set<String> = ["Fields", "SigFlags", "DR", "DA", "NeedAppearances", "CO"]
        private static let catalogKeys: Set<String> = ["AcroForm", "DSS", "Metadata", "Extensions", "Perms"]
        private static let approvalCatalogKeys: Set<String> = ["Outlines", "PageLabels", "StructTreeRoot", "MarkInfo", "Lang", "ViewerPreferences",
                                                               "PageMode", "PageLayout", "Names", "Dests"]
        private static let namesKeys: Set<String> = ["EmbeddedFiles", "Dests"]

        private let data: [UInt8]
        private let a: MuDoc, b: MuDoc
        private let level: Int
        private let locked: (String) -> Bool
        private let infoA: Bool, infoB: Bool
        private var problems: [String] = []
        private var sawValidationData = false
        private var sawOther = false
        private var hashes: [ObjectIdentifier: [UInt: [UInt8]]] = [:]

        /// After `run`: every change was validation data or a document timestamp, and there was at least one.
        var onlyValidationData: Bool { sawValidationData && !sawOther && problems.isEmpty }

        init(_ data: [UInt8], _ a: MuDoc, _ b: MuDoc, _ level: Int, _ locked: @escaping (String) -> Bool, _ infoA: Bool, _ infoB: Bool) {
            self.data = data
            self.a = a
            self.b = b
            self.level = level
            self.locked = locked
            self.infoA = infoA
            self.infoB = infoB
        }

        final class Roles {
            var objects: [Int: PObj] = [:]
            var pages: [Int: Int] = [:]
            var pageNodes = Set<Int>()
            /// Objects page content draws with → the first page using them.
            var content: [Int: Int] = [:]
            var annots: [Int: (dict: PObj, widget: Bool)] = [:]
            /// Annotations written inside a page's list rather than referred to: no object number to know them by, so
            /// they go by what they say.
            var directAnnots: [(dict: PObj, widget: Bool)] = []
            var arrays = Set<Int>()
            var fieldOf: [Int: FormField] = [:]
            var fieldNodes = Set<Int>()
            var sigValues = Set<Int>()
            var widgets = Set<Int>(), comments = Set<Int>(), meta = Set<Int>(), harmless = Set<Int>(), validationData = Set<Int>()
            /// Objects a widget draws with (its appearance streams and their resources) → those widgets.
            var drawnBy: [Int: [Int]] = [:]
            var fieldNames = Set<String>()
            var catalog = -1, acroForm = -1, names = -1, info = -1
        }

        func run() throws -> [String] {
            let ra = try roles(a, infoA)
            let rb = try roles(b, infoB)
            for (n, objB) in rb.objects.sorted(by: { $0.key < $1.key }) {
                guard let objA = ra.objects[n] else {
                    added(n, ra, rb)
                    continue
                }
                if same(objA, objB) { continue }
                changed(n, objA, objB, ra, rb)
            }
            for (n, an) in ra.annots.sorted(by: { $0.key < $1.key }) where rb.annots[n] == nil {
                sawOther = true
                if an.widget { problem(loc("form fields removed")) } else if level < 3 { problem(loc("comments removed")) }
            }
            compareDirectAnnots(ra, rb)
            // A field dropped from the form while its widget stays on the page is no timestamp's doing.
            if !ra.fieldNames.subtracting(rb.fieldNames).isEmpty { sawOther = true }
            return problems
        }

        /// An annotation written inside a page's list draws on the page like any other, and is judged like any other.
        private func compareDirectAnnots(_ ra: Roles, _ rb: Roles) {
            var had = ra.directAnnots.map { ser($0.dict, top: true) }
            for annot in rb.directAnnots {
                if let i = had.firstIndex(of: ser(annot.dict, top: true)) {
                    had.remove(at: i)
                    continue
                }
                sawOther = true
                if annot.widget ? level < SignatureChanges.approval : level < 3 { problem(annot.widget ? loc("form fields added") : loc("comments added")) }
            }
            var has = rb.directAnnots.map { ser($0.dict, top: true) }
            for annot in ra.directAnnots {
                if let i = has.firstIndex(of: ser(annot.dict, top: true)) {
                    has.remove(at: i)
                    continue
                }
                sawOther = true
                if annot.widget { problem(loc("form fields removed")) } else if level < 3 { problem(loc("comments removed")) }
            }
        }

        private func problem(_ what: String) { problems.append(what) }

        private func changed(_ n: Int, _ objA: PObj, _ objB: PObj, _ ra: Roles, _ rb: Roles) {
            // What follows counts as a change to the document, apart from the few cases that clear this again.
            var other = true
            defer { if other { sawOther = true } }
            if let page = ra.content[n] {
                problem(loc("the content of page {0}", CoreLanguage.number(page + 1)))
            } else if n == ra.catalog {
                compareCatalog(objA, objB)
                other = false
            } else if let page = ra.pages[n] {
                if !same(objA, objB, skip: ["Annots"]) {
                    problem(loc("page {0} (its size, rotation or resources)", CoreLanguage.number(page + 1)))
                } else {
                    other = false // what was added to /Annots is judged on its own
                }
            } else if ra.pageNodes.contains(n) {
                problem(loc("pages added, removed or moved"))
            } else if let an = ra.annots[n] {
                if rb.annots[n] == nil { return } // reported as removed
                if an.widget { changedField(ra.fieldOf[n], objA, objB, Comparison.widgetKeys) } else if level < 3 { problem(loc("comments changed")) }
            } else if ra.fieldNodes.contains(n) {
                changedField(ra.fieldOf[n], objA, objB, Comparison.fieldKeys)
            } else if n == ra.acroForm {
                compareAcroForm(objA, objB)
                other = false
            } else if n == ra.names {
                compareNames(objA, objB)
            } else if ra.sigValues.contains(n) {
                problem(loc("an earlier signature's details"))
            } else if n == ra.info {
                other = diffKeys(objA, objB).contains { $0 != "ModDate" && $0 != "Producer" }
            } else if ra.arrays.contains(n) || rb.arrays.contains(n) {
                other = false // what went in or out is judged on its own
            } else if ra.validationData.contains(n) && !ra.widgets.contains(n) && !ra.comments.contains(n) {
                // After every other role, and not for what a widget or comment draws with: a store in the signed revision
                // can point at anything, and must not make that thing free to change.
                sawValidationData = true
                other = false
            } else if ra.meta.contains(n) {
                // permitted
            } else if ra.widgets.contains(n) || rb.widgets.contains(n) {
                if level < 2 {
                    problem(loc("form field appearances"))
                } else if let f = ra.drawnBy[n]?.lazy.compactMap({ ra.fieldOf[$0] }).first(where: { $0.type != "Sig" && self.locked($0.name) }) {
                    problem(loc("locked field \"{0}\" (its appearance)", f.name))
                }
            } else if ra.comments.contains(n) || rb.comments.contains(n) {
                if level < 3 { problem(loc("comments changed")) }
            } else if level == SignatureChanges.approval && (ra.harmless.contains(n) || rb.harmless.contains(n)) {
                // permitted
            } else {
                problem(loc("other document data"))
            }
        }

        private func added(_ n: Int, _ ra: Roles, _ rb: Roles) {
            if let an = rb.annots[n] {
                if an.widget {
                    addedField(rb.fieldOf[n], ra)
                } else {
                    sawOther = true
                    if level < 3 { problem(loc("comments added")) }
                }
            } else if let f = rb.fieldOf[n] {
                addedField(f, ra)
            }
        }

        private func addedField(_ f: FormField?, _ ra: Roles) {
            if f?.type == "Sig" {
                // A document timestamp (PAdES-LTA) may follow any signature, even a no-changes certification: one that draws
                // nothing and is one, not any field that says so, which could lay anything over the page.
                if let f, let v = FormEditor.inherited(f.dict, "V"), v.isDict, v.name("SubFilter") == "ETSI.RFC3161",
                   Comparison.drawsNothing(f), Signatures.holdsTimestamp(data, v) {
                    sawValidationData = true
                    return
                }
                sawOther = true
                if level < 3 { problem(loc("signature fields added")) }
            } else {
                sawOther = true
                if level < SignatureChanges.approval {
                    problem(loc("form fields added"))
                } else if let f, ra.fieldNames.contains(f.name), locked(f.name) {
                    // A new field under a locked field's name takes its place in a reader.
                    problem(loc("locked field \"{0}\" (a new field of the same name)", f.name))
                }
            }
        }

        /// Each of the field's widgets is hidden or has a box of no size, as an invisible signature's has.
        private static func drawsNothing(_ f: FormField) -> Bool {
            (f.widgets + [f.dict]).allSatisfy { w in
                let hidden = 2
                if (w.int("F") ?? 0) & hidden != 0 || w["Rect"] == nil { return true }
                guard let r = w.array("Rect"), r.count == 4 else { return false }
                return r.num(0) == r.num(2) || r.num(1) == r.num(3)
            }
        }

        private func changedField(_ f: FormField?, _ objA: PObj, _ objB: PObj, _ allowed: Set<String>) {
            var keys = diffKeys(objA, objB)
            // Signing locks fields by setting their read-only flag: that alone is fine.
            if keys.remove("Ff") != nil && (objB.int("Ff") ?? 0) != ((objA.int("Ff") ?? 0) | 1) { keys.insert("Ff") }
            let name = f?.name ?? "?"
            if keys.contains(where: { !allowed.contains($0) }) {
                problem(loc("form field \"{0}\" (its properties)", name))
            } else if keys.isEmpty {
                return
            } else if level < 2 {
                problem(loc("form fields filled in"))
            } else if let f, f.type != "Sig", locked(f.name) {
                problem(loc("locked field \"{0}\"", name))
            }
        }

        private func compareCatalog(_ x: PObj, _ y: PObj) {
            for key in diffKeys(x, y).sorted() {
                if key == "DSS" || key == "Extensions" {
                    sawValidationData = true
                    continue
                }
                if key == "AcroForm" {
                    compareAcroForm(x.dict(key), y.dict(key))
                    continue
                }
                sawOther = true
                if key == "Names" && level == SignatureChanges.approval {
                    if let dx = x.dict(key), let dy = y.dict(key) { compareNames(dx, dy) }
                } else if Comparison.catalogKeys.contains(key) || (level == SignatureChanges.approval && Comparison.approvalCatalogKeys.contains(key)) {
                    continue
                } else {
                    let what = switch key {
                    case "OCProperties": loc("which layers are shown")
                    case "OpenAction", "AA": loc("what happens when the document opens")
                    case "Pages": loc("pages added, removed or moved")
                    default: loc("document settings ({0})", key)
                    }
                    problem(what)
                }
            }
        }

        private func compareAcroForm(_ x: PObj?, _ y: PObj?) {
            guard let x, let y, x.isDict, y.isDict else {
                sawOther = true
                return
            }
            let keys = diffKeys(x, y)
            if keys.contains(where: { !Comparison.acroFormKeys.contains($0) }) { problem(loc("form settings (e.g. XFA data)")) }
            // A form's /SigFlags and /Fields change for a timestamp's field too; a new field in them is judged on its own.
            if keys.contains(where: { $0 != "Fields" && $0 != "SigFlags" }) { sawOther = true }
        }

        private func compareNames(_ x: PObj, _ y: PObj) {
            guard x.isDict, y.isDict else { return }
            if level < SignatureChanges.approval || diffKeys(x, y).contains(where: { !Comparison.namesKeys.contains($0) }) {
                problem(loc("document scripts or named items"))
            }
        }

        /// The keys whose values differ, or that one side has and the other hasn't (a /DSS of null still says it is there).
        private func diffKeys(_ x: PObj, _ y: PObj) -> Set<String> {
            let kx = Set(x.keys), ky = Set(y.keys)
            return kx.union(ky).filter { kx.contains($0) != ky.contains($0) || ser(x[$0], top: false) != ser(y[$0], top: false) }
        }

        private func same(_ x: PObj, _ y: PObj, skip: Set<String> = []) -> Bool { ser(x, top: true, skip: skip) == ser(y, top: true, skip: skip) }

        /// The object written out with references as numbers and streams as their data's hash (.NET's
        /// `Incremental.Serialize`), so objects of the two revisions compare by value.
        private func ser(_ o: PObj?, top: Bool, skip: Set<String> = []) -> [UInt8] {
            var out: [UInt8] = []
            write(o, top: top, skip: skip, depth: 0, into: &out)
            return out
        }

        private func write(_ o: PObj?, top: Bool, skip: Set<String>, depth: Int, into out: inout [UInt8]) {
            guard let o, depth < 64 else {
                out += Array("null ".utf8)
                return
            }
            if o.isRef && !top {
                out += Array("\(o.num) R ".utf8)
                return
            }
            switch o.kind {
            case .null: out += Array("null ".utf8)
            case .bool: out += Array((o.bool ? "true " : "false ").utf8)
            case .int, .real: out += Array("\(o.number ?? 0) ".utf8)
            case .name: out += Array("/\(o.name ?? "") ".utf8)
            case .string: out += [40] + (o.bytes ?? []) + [41, 32]
            case .array:
                out.append(91)
                for e in o.elements { write(e, top: false, skip: [], depth: depth + 1, into: &out) }
                out.append(93)
            case .dict:
                out += [60, 60]
                for key in o.keys.sorted() where !skip.contains(key) {
                    out += Array("/\(key) ".utf8)
                    write(o[key], top: false, skip: [], depth: depth + 1, into: &out)
                }
                out += [62, 62]
                if o.isStream { out += Array("stream ".utf8) + streamHash(o) }
            }
        }

        private func streamHash(_ o: PObj) -> [UInt8] {
            let docId = ObjectIdentifier(o.doc)
            if let h = hashes[docId]?[o.identity] { return h }
            let h = Array(SHA256.hash(data: o.rawStreamData ?? []))
            hashes[docId, default: [:]][o.identity] = h
            return h
        }

        private func roles(_ doc: MuDoc, _ hasInfo: Bool) throws -> Roles {
            let r = Roles()
            let catalog = doc.catalog
            let info = hasInfo ? doc.trailer["Info"] : nil
            r.catalog = catalog.isRef ? catalog.num : -1
            r.info = info.map { $0.isRef ? $0.num : -1 } ?? -1
            var all = Set<Int>()
            Comparison.walk([catalog, info], &all, [], record: true, objects: &r.objects)

            let count = try doc.pageCount()
            let pages = (0..<count).map { doc.page($0) }
            for (p, page) in pages.enumerated() where page.isRef && r.pages[page.num] == nil { r.pages[page.num] = p }
            // Every node of the page tree, a node written inside its parent (or the catalog) included: what it holds is the
            // page tree's, never validation data (below).
            var nodes: [PObj] = catalog["Pages"].map { [$0] } ?? []
            var treeNodes: [PObj] = []
            while let node = nodes.popLast() {
                guard node.isDict, node.name("Type") != "Page" else { continue }
                if node.isRef && !r.pageNodes.insert(node.num).inserted { continue }
                treeNodes.append(node)
                nodes += node.array("Kids")?.elements ?? []
            }
            let stop = Set(r.pages.keys).union(r.pageNodes)

            for (p, page) in pages.enumerated() {
                var seen = Set<Int>()
                Comparison.walk(page.keys.filter { $0 != "Parent" && $0 != "Annots" }.map { page[$0] }, &seen, stop)
                // Inherited resources live on the page tree nodes.
                var node = page.dict("Parent")
                var depth = 0
                while let n = node, depth < 64 {
                    Comparison.walk([n["Resources"]], &seen, stop)
                    node = n.dict("Parent")
                    depth += 1
                }
                for n in seen where r.content[n] == nil { r.content[n] = p }

                if let ar = page["Annots"], ar.isRef { r.arrays.insert(ar.num) }
                for item in page.array("Annots")?.elements ?? [] where item.isDict {
                    let widget = item.name("Subtype") == "Widget"
                    if !item.isRef {
                        r.directAnnots.append((item, widget))
                        continue
                    }
                    if r.annots[item.num] == nil { r.annots[item.num] = (item, widget) }
                    if widget {
                        Comparison.walk([item], &r.widgets, stop)
                        var drawn = Set<Int>()
                        Comparison.walk([item["AP"]], &drawn, stop)
                        for d in drawn { r.drawnBy[d, default: []].append(item.num) }
                    } else {
                        Comparison.walk([item], &r.comments, stop)
                    }
                }
            }

            let acroItem = catalog["AcroForm"]
            let acro = catalog.dict("AcroForm")
            if let acroItem, acroItem.isRef { r.acroForm = acroItem.num }
            if let fr = acro?["Fields"], fr.isRef { r.arrays.insert(fr.num) }
            for f in try FormEditor.collect(doc, acro) {
                r.fieldNames.insert(f.name)
                var node: PObj? = f.dict
                var guardCount = 0
                while let n = node, guardCount < 64 {
                    if n.isRef {
                        r.fieldNodes.insert(n.num)
                        if let kr = n["Kids"], kr.isRef { r.arrays.insert(kr.num) }
                    }
                    node = n.dict("Parent")
                    guardCount += 1
                }
                if f.dict.isRef && r.fieldOf[f.dict.num] == nil { r.fieldOf[f.dict.num] = f }
                for w in f.widgets where w.isRef && r.fieldOf[w.num] == nil { r.fieldOf[w.num] = f }
                if f.type == "Sig", let vr = FormEditor.inherited(f.dict, "V"), vr.isRef { r.sigValues.insert(vr.num) }
            }

            Comparison.walk([catalog["DSS"], catalog["Extensions"]], &r.validationData, stop)
            // Validation data is what only the store reaches: an object the document uses too (an attachment, a script, an
            // outline) a store names doesn't become free to change.
            // Pages are judged by their own roles before validation data is (content, widgets, comments), so the walk starts
            // from the rest, the form included (its XFA, scripts and values); it never goes back into the catalog (and through
            // it into /DSS). A walk cut short by its limit leaves no validation data at all: nothing it didn't reach may count
            // as free.
            var elsewhere = Set<Int>()
            let roots = catalog.keys.filter { !["DSS", "Extensions", "Pages"].contains($0) }.map { catalog[$0] } + [info]
            // An annotation written inside a page's list is compared by what it says (compareDirectAnnots), and what it
            // draws with has no role of its own: never validation data either. Nor what the page tree's nodes hold (an
            // inherited page size or turn, an indirect /Kids array), written inside the catalog or a parent too. Both walks
            // stop at pages and nodes, as Windows' do.
            var notBack = stop
            if r.catalog >= 0 { notBack.insert(r.catalog) }
            var onPages: [PObj?] = r.directAnnots.map { $0.dict }
            for node in treeNodes { onPages += node.keys.filter { $0 != "Parent" }.map { node[$0] } }
            if Comparison.walk(roots, &elsewhere, r.catalog >= 0 ? [r.catalog] : []),
               Comparison.walk(onPages, &elsewhere, notBack) {
                r.validationData.subtract(elsewhere)
            } else {
                r.validationData.removeAll()
            }
            Comparison.walk([catalog["Metadata"], catalog["Perms"], info, acro?["DR"]], &r.meta, stop)
            if let names = catalog["Names"], names.isRef { r.names = names.num }
            let namesDict = catalog.dict("Names")
            let harmless = Comparison.approvalCatalogKeys.subtracting(["Names"]).sorted().map { catalog[$0] }
                + [namesDict?["EmbeddedFiles"], namesDict?["Dests"]]
            Comparison.walk(harmless, &r.harmless, stop)
            return r
        }

        /// False when the walk stopped at its limit before reaching everything.
        @discardableResult
        private static func walk(_ roots: [PObj?], _ into: inout Set<Int>, _ stop: Set<Int>, record: Bool = false) -> Bool {
            var none: [Int: PObj] = [:]
            return walk(roots, &into, stop, record: record, objects: &none, keep: false)
        }

        /// Collects the indirect objects reachable from `roots`, not following references back up the structure
        /// (/Parent, /P, …) nor into `stop` (pages: their content is judged on its own). With `record` everything is
        /// followed, and each object is kept in `objects`.
        @discardableResult
        private static func walk(_ roots: [PObj?], _ into: inout Set<Int>, _ stop: Set<Int>, record: Bool, objects: inout [Int: PObj],
                                 keep: Bool = true) -> Bool {
            var stack = roots.compactMap { $0 }
            var visitedDirect = 0
            while let item = stack.popLast() {
                if item.isRef {
                    let n = item.num
                    if stop.contains(n) || !into.insert(n).inserted { continue }
                    if keep { objects[n] = item }
                } else {
                    visitedDirect += 1
                    if visitedDirect > 1_000_000 { return false }
                }
                if item.isDict {
                    for key in item.keys where record || !upward.contains(key) {
                        if let child = item[key], child.isRef || child.isDict || child.isArray { stack.append(child) }
                    }
                } else if item.isArray {
                    for child in item.elements where child.isRef || child.isDict || child.isArray { stack.append(child) }
                }
            }
            return true
        }
    }
}
