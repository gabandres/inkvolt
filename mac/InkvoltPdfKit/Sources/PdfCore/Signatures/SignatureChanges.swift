import CryptoKit
import Foundation

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
/// - metadata (Info, XMP), validation data (/DSS), document timestamps: always.
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
    /// entries in the signed revision (nil when not found there).
    struct Analysis {
        var permitted: Bool
        var problem: String?
        var signed: Entries?
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
            let comparison = Comparison(before, after, level, locked, before.trailer.has("Info"), after.trailer.has("Info"))
            let problems = try comparison.run()
            if problems.isEmpty { return Analysis(permitted: true, problem: nil, signed: entries) }
            var distinct: [String] = []
            for p in problems where !distinct.contains(p) { distinct.append(p) }
            let what = distinct.prefix(3).joined(separator: "; ") + (distinct.count > 3 ? "; and more" : "")
            let problem = switch level {
            case 1: "The document is certified with no changes allowed, but it was changed after certification: \(what)."
            case 2, 3: "The document was changed after certification in ways the certification doesn't allow: \(what)."
            default: "The document was changed after signing in ways a signature doesn't allow: \(what)."
            }
            return Analysis(permitted: false, problem: problem, signed: entries)
        } catch {
            return Analysis(permitted: true, problem: "Inkvolt PDF couldn't work out what was changed after signing.", signed: nil)
        }
    }

    /// Which fields the signature locks: its FieldMDP reference, else the signature field's /Lock.
    private static func lockOf(_ v: PObj, _ field: PObj) -> (String) -> Bool {
        let fieldMdp = v.array("Reference")?.elements.first { $0.isDict && $0.name("TransformMethod") == "FieldMDP" }
        guard let lock = fieldMdp?.dict("TransformParams") ?? field.dict("Lock") else { return { _ in false } }
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

        private let a: MuDoc, b: MuDoc
        private let level: Int
        private let locked: (String) -> Bool
        private let infoA: Bool, infoB: Bool
        private var problems: [String] = []
        private var hashes: [ObjectIdentifier: [UInt: [UInt8]]] = [:]

        init(_ a: MuDoc, _ b: MuDoc, _ level: Int, _ locked: @escaping (String) -> Bool, _ infoA: Bool, _ infoB: Bool) {
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
            var arrays = Set<Int>()
            var fieldOf: [Int: FormField] = [:]
            var fieldNodes = Set<Int>()
            var sigValues = Set<Int>()
            var widgets = Set<Int>(), comments = Set<Int>(), meta = Set<Int>(), harmless = Set<Int>()
            var catalog = -1, acroForm = -1, names = -1, info = -1
        }

        func run() throws -> [String] {
            let ra = try roles(a, infoA)
            let rb = try roles(b, infoB)
            for (n, objB) in rb.objects.sorted(by: { $0.key < $1.key }) {
                guard let objA = ra.objects[n] else {
                    added(n, rb)
                    continue
                }
                if same(objA, objB) { continue }
                changed(n, objA, objB, ra, rb)
            }
            for (n, an) in ra.annots.sorted(by: { $0.key < $1.key }) where rb.annots[n] == nil {
                if an.widget { problem("form fields removed") } else if level < 3 { problem("comments removed") }
            }
            return problems
        }

        private func problem(_ what: String) { problems.append(what) }

        private func changed(_ n: Int, _ objA: PObj, _ objB: PObj, _ ra: Roles, _ rb: Roles) {
            if let page = ra.content[n] {
                problem("the content of page \(page + 1)")
            } else if n == ra.catalog {
                compareCatalog(objA, objB)
            } else if let page = ra.pages[n] {
                if !same(objA, objB, skip: ["Annots"]) { problem("page \(page + 1) (its size, rotation or resources)") }
            } else if ra.pageNodes.contains(n) {
                problem("pages added, removed or moved")
            } else if let an = ra.annots[n] {
                if rb.annots[n] == nil { return } // reported as removed
                if an.widget { changedField(ra.fieldOf[n], objA, objB, Comparison.widgetKeys) } else if level < 3 { problem("comments changed") }
            } else if ra.fieldNodes.contains(n) {
                changedField(ra.fieldOf[n], objA, objB, Comparison.fieldKeys)
            } else if n == ra.acroForm {
                compareAcroForm(objA, objB)
            } else if n == ra.names {
                compareNames(objA, objB)
            } else if ra.sigValues.contains(n) {
                problem("an earlier signature's details")
            } else if n == ra.info || ra.arrays.contains(n) || rb.arrays.contains(n) || ra.meta.contains(n) {
                // permitted
            } else if ra.widgets.contains(n) || rb.widgets.contains(n) {
                if level < 2 { problem("form field appearances") }
            } else if ra.comments.contains(n) || rb.comments.contains(n) {
                if level < 3 { problem("comments changed") }
            } else if level == SignatureChanges.approval && (ra.harmless.contains(n) || rb.harmless.contains(n)) {
                // permitted
            } else {
                problem("other document data")
            }
        }

        private func added(_ n: Int, _ rb: Roles) {
            if let an = rb.annots[n] {
                if an.widget { addedField(rb.fieldOf[n]) } else if level < 3 { problem("comments added") }
            } else if let f = rb.fieldOf[n] {
                addedField(f)
            }
        }

        private func addedField(_ f: FormField?) {
            if f?.type == "Sig" {
                // A document timestamp (PAdES-LTA) may follow any signature, even a no-changes certification.
                if let f, let v = FormEditor.inherited(f.dict, "V"), v.isDict, v.name("SubFilter") == "ETSI.RFC3161" { return }
                if level < 3 { problem("signature fields added") }
            } else if level < SignatureChanges.approval {
                problem("form fields added")
            }
        }

        private func changedField(_ f: FormField?, _ objA: PObj, _ objB: PObj, _ allowed: Set<String>) {
            var keys = diffKeys(objA, objB)
            // Signing locks fields by setting their read-only flag: that alone is fine.
            if keys.remove("Ff") != nil && (objB.int("Ff") ?? 0) != ((objA.int("Ff") ?? 0) | 1) { keys.insert("Ff") }
            let name = f?.name ?? "?"
            if keys.contains(where: { !allowed.contains($0) }) {
                problem("form field \"\(name)\" (its properties)")
            } else if keys.isEmpty {
                return
            } else if level < 2 {
                problem("form fields filled in")
            } else if keys.contains("V") || keys.contains("AS"), let f, f.type != "Sig", locked(f.name) {
                problem("locked field \"\(name)\"")
            }
        }

        private func compareCatalog(_ x: PObj, _ y: PObj) {
            for key in diffKeys(x, y).sorted() {
                if key == "AcroForm" {
                    if let dx = x.dict(key), let dy = y.dict(key) { compareAcroForm(dx, dy) }
                } else if key == "Names" && level == SignatureChanges.approval {
                    if let dx = x.dict(key), let dy = y.dict(key) { compareNames(dx, dy) }
                } else if Comparison.catalogKeys.contains(key) || (level == SignatureChanges.approval && Comparison.approvalCatalogKeys.contains(key)) {
                    continue
                } else {
                    let what = switch key {
                    case "OCProperties": "which layers are shown"
                    case "OpenAction", "AA": "what happens when the document opens"
                    case "Pages": "pages added, removed or moved"
                    default: "document settings (\(key))"
                    }
                    problem(what)
                }
            }
        }

        private func compareAcroForm(_ x: PObj, _ y: PObj) {
            guard x.isDict, y.isDict else { return }
            if diffKeys(x, y).contains(where: { !Comparison.acroFormKeys.contains($0) }) { problem("form settings (e.g. XFA data)") }
        }

        private func compareNames(_ x: PObj, _ y: PObj) {
            guard x.isDict, y.isDict else { return }
            if level < SignatureChanges.approval || diffKeys(x, y).contains(where: { !Comparison.namesKeys.contains($0) }) {
                problem("document scripts or named items")
            }
        }

        private func diffKeys(_ x: PObj, _ y: PObj) -> Set<String> {
            Set(x.keys).union(y.keys).filter { ser(x[$0], top: false) != ser(y[$0], top: false) }
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
            var nodes: [PObj] = catalog["Pages"].map { [$0] } ?? []
            while let node = nodes.popLast() {
                if node.isRef, node.isDict, node.name("Type") != "Page", r.pageNodes.insert(node.num).inserted {
                    nodes += node.array("Kids")?.elements ?? []
                }
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
                for item in page.array("Annots")?.elements ?? [] where item.isRef && item.isDict {
                    let widget = item.name("Subtype") == "Widget"
                    if r.annots[item.num] == nil { r.annots[item.num] = (item, widget) }
                    if widget { Comparison.walk([item], &r.widgets, stop) } else { Comparison.walk([item], &r.comments, stop) }
                }
            }

            let acroItem = catalog["AcroForm"]
            let acro = catalog.dict("AcroForm")
            if let acroItem, acroItem.isRef { r.acroForm = acroItem.num }
            if let fr = acro?["Fields"], fr.isRef { r.arrays.insert(fr.num) }
            for f in try FormEditor.collect(doc, acro) {
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

            Comparison.walk([catalog["DSS"], catalog["Metadata"], catalog["Extensions"], catalog["Perms"], info, acro?["DR"]], &r.meta, stop)
            if let names = catalog["Names"], names.isRef { r.names = names.num }
            let namesDict = catalog.dict("Names")
            let harmless = Comparison.approvalCatalogKeys.subtracting(["Names"]).sorted().map { catalog[$0] }
                + [namesDict?["EmbeddedFiles"], namesDict?["Dests"]]
            Comparison.walk(harmless, &r.harmless, stop)
            return r
        }

        private static func walk(_ roots: [PObj?], _ into: inout Set<Int>, _ stop: Set<Int>, record: Bool = false) {
            var none: [Int: PObj] = [:]
            walk(roots, &into, stop, record: record, objects: &none, keep: false)
        }

        /// Collects the indirect objects reachable from `roots`, not following references back up the structure
        /// (/Parent, /P, …) nor into `stop` (pages: their content is judged on its own). With `record` everything is
        /// followed, and each object is kept in `objects`.
        private static func walk(_ roots: [PObj?], _ into: inout Set<Int>, _ stop: Set<Int>, record: Bool, objects: inout [Int: PObj],
                                 keep: Bool = true) {
            var stack = roots.compactMap { $0 }
            var visitedDirect = 0
            while let item = stack.popLast() {
                if item.isRef {
                    let n = item.num
                    if stop.contains(n) || !into.insert(n).inserted { continue }
                    if keep { objects[n] = item }
                } else {
                    visitedDirect += 1
                    if visitedDirect > 1_000_000 { return }
                }
                if item.isDict {
                    for key in item.keys where record || !upward.contains(key) {
                        if let child = item[key], child.isRef || child.isDict || child.isArray { stack.append(child) }
                    }
                } else if item.isArray {
                    for child in item.elements where child.isRef || child.isDict || child.isArray { stack.append(child) }
                }
            }
        }
    }
}
