import Foundation

/// What `Sanitizer` finds and removes.
public enum SanitizeItem: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// Document properties (the Info dictionary), XMP metadata packets (of the document, pages, images, fonts, ...) and
    /// other apps' private data (/PieceInfo, /LastModified).
    case metadata
    /// Layers (optional content groups) hidden by default, with everything they draw.
    case hiddenLayers
    /// Annotations and form fields flagged as hidden or not to be shown (/F Hidden or NoView).
    case hiddenAnnotations
    /// Comments, markup, stamps and drawings (every annotation but links, form fields and the kinds below).
    case comments
    /// Values filled into form fields (and an XFA form's copy of them).
    case formValues
    case bookmarks
    /// Embedded page thumbnails.
    case thumbnails
    /// JavaScript (document scripts, open actions, additional actions of the document, pages, annotations and fields,
    /// script actions of links, fields and bookmarks), Launch, SubmitForm, ImportData and multimedia actions; RichMedia,
    /// 3D, Sound, Movie and Screen annotations; XFA forms (they carry scripts).
    case activeContent
    /// Links and actions leading out of the document: web addresses (URI), other files (GoToR, GoToE, articles in other
    /// files).
    case externalLinks
    /// Attached files: the EmbeddedFiles name tree, file attachment annotations, associated files (/AF), portfolios.
    case embeddedFiles
    /// Digital signatures (signature values, their certification permissions and validation data); the fields stay, empty.
    case signatures

    public static func < (a: SanitizeItem, b: SanitizeItem) -> Bool { a.rawValue < b.rawValue }
}

/// Counts per `SanitizeItem`: what a document holds (`Sanitizer.scan`) or what was removed.
public struct SanitizeReport: Equatable, Sendable {
    public var counts: [SanitizeItem: Int]
    /// Earlier versions kept in the file by incremental saves (a rewrite drops them).
    public var earlierRevisions: Int
    /// Objects nothing refers to any more (a rewrite drops them).
    public var unusedObjects: Int
    /// What couldn't be removed, and why.
    public var notes: [String]

    public subscript(item: SanitizeItem) -> Int { counts[item] ?? 0 }

    /// Nothing of any kind found.
    public var isClean: Bool { counts.values.allSatisfy { $0 == 0 } }
}

public struct SanitizeResult: Sendable {
    public var data: [UInt8]
    public var removed: SanitizeReport
    /// The output scanned again (nil if it couldn't be read back with the same password).
    public var remaining: SanitizeReport?
}

/// Sanitize Document (the Windows app's `Sanitizer`): removes what a document carries besides its visible pages. Always a
/// full rewrite, so earlier revisions of an incrementally saved file and objects nothing uses are gone too. Hidden layers
/// lose their content, not just the layer: marked content of a layer that is off is cut out of every content stream
/// (pages, form XObjects, appearances, patterns), keeping the graphics-state operators it holds (as viewers apply them to
/// hidden content too), and XObjects and annotations that belong to it go. A part that can't be cut out safely (a content
/// stream that can't be decoded, hidden text whose width the visible text after it relies on) is kept, with its layer,
/// and noted. Text drawn in white or off the page is not looked for (it can't be told reliably from text that shows).
/// Signed documents need the caller's consent (`SignedEdits.run` with the rewrite allowed): the rewrite invalidates
/// their signatures. An encrypted document keeps its protection.
public enum Sanitizer {
    /// What the document holds of each kind (every kind counted, nothing changed).
    /// - Throws: `PasswordRequired`; `PdfEditError` when it can't be read.
    public static func scan(_ data: [UInt8], _ password: String?) throws -> SanitizeReport { try scan(data, password, originalIds: nil) }

    /// `originalIds`: the file identifiers (/ID) of the document this one was sanitized from: one still in the file links
    /// it to the original, and counts as metadata.
    static func scan(_ data: [UInt8], _ password: String?, originalIds: [[UInt8]]?) throws -> SanitizeReport {
        let doc = try PdfEdit.openToRead(data, password)
        let pass = Pass(doc, nil)
        pass.originalIds = originalIds
        return pass.run(earlierRevisions(data))
    }

    /// What an open document holds of each kind (its earlier versions not counted).
    static func scan(_ doc: MuDoc) -> SanitizeReport { Pass(doc, nil).run(0) }

    /// Removes the chosen kinds of content; the report counts what went.
    /// - Throws: `SignaturesWouldBreak` when the document is signed and the rewrite wasn't allowed;
    ///   `OwnerPasswordRequired`; `PdfEditError`.
    public static func sanitize(_ data: [UInt8], _ password: String?, _ items: Set<SanitizeItem>) throws -> SanitizeResult {
        let doc = try PdfEdit.open(data, password)
        try SignedEdits.requireRewrite(data, reason: "sanitizing rewrites the whole file")
        let pages = try doc.pageCount()
        let originalIds = (doc.trailer.array("ID")?.elements ?? []).compactMap(\.bytes).filter { !$0.isEmpty }
        let xmp = Xmp.read(doc)
        let removed = Pass(doc, items).run(earlierRevisions(data))
        var notes = removed.notes
        var reencrypt: String?
        var ownId = false
        if items.contains(.metadata) {
            // Properties and the packet go (Windows keeps a bare packet naming the program that wrote the file).
            // (The trailer read again: an edit puts a copy of it in the update MuPDF writes from.)
            doc.trailer.remove("Info")
            doc.catalog.remove("Metadata")
            // The file identifier links copies of a document (its first entry never changes): new ones for both.
            switch try newFileIdentifier(doc, password) {
            case .done: ownId = true
            case .reencrypt(let options): reencrypt = options
            case .kept: notes.append("The file identifier was kept: the document's encryption is made from it, and its open password isn't known here.")
            }
        } else {
            InfoDict.setDate(doc, "ModDate", Date())
            if doc.catalog.dict("Metadata")?.isStream == true { Xmp.write(doc, original: xmp) }
        }
        try doc.checkFailure()
        let saved: [UInt8]
        if let reencrypt {
            // Encrypted again with the new identifier; MuPDF then puts the old one's second half back (as it does on any
            // encrypted write that regenerates the identifier), so that half is set once more without touching the key.
            let first = try doc.write(reencrypt)
            let again = try PdfEdit.open(first, password)
            let id0 = again.trailer.array("ID")?[0]?.bytes ?? []
            again.trailer.set("ID", again.array([again.string(id0), again.string(randomId())]))
            try again.checkFailure()
            saved = try again.write("encrypt=keep,regenerate-id=no")
        } else if ownId && !KeptProtection.dropOpenPassword {
            // MuPDF regenerates the identifier's second half from the original one: keep the new one as it was set.
            saved = try doc.write("garbage=compact,encrypt=keep,regenerate-id=no")
        } else {
            saved = try PdfEdit.writeWhole(doc, password: password)
        }

        // The result must open as before: never hand back a file MuPDF can't read.
        do {
            let check = try PdfEngine.open(saved, password: password)
            defer { check.close() }
            if check.pageCount != pages {
                throw PdfEditError("The sanitized file couldn't be read back, so nothing was changed: it has \(check.pageCount) pages instead of \(pages).")
            }
        } catch is PasswordRequired {
            // Saved without the password it was opened with: nothing to check with.
        } catch let e as PdfEngineError {
            throw PdfEditError("The sanitized file couldn't be read back, so nothing was changed: " + e.message)
        }

        let remaining = try? scan(saved, password, originalIds: items.contains(.metadata) ? originalIds : nil)
        var report = removed
        report.notes = notes
        return SanitizeResult(data: saved, removed: report, remaining: remaining)
    }

    private enum NewIdentifier {
        /// Set; the encryption (none, or AES-256's, which doesn't depend on it) is kept as it is.
        case done
        /// Set; the file must be encrypted again with these write options.
        case reencrypt(String)
        /// Not set.
        case kept
    }

    /// Gives the document a new file identifier. An encrypted file's key comes from it (but for AES-256), so a new one
    /// means encrypting again with both passwords, and the open password is known only when it is empty or given
    /// (`KeptProtection.run`): without it the identifier stays.
    private static func newFileIdentifier(_ doc: MuDoc, _ password: String?) throws -> NewIdentifier {
        func fresh() -> PObj { doc.array([doc.string(randomId()), doc.string(randomId())]) }
        guard let info = try doc.encryptInfo() else {
            doc.trailer.set("ID", fresh())
            return .done
        }
        let method = PdfSecurity.method(info)
        if method == .aes256 {
            doc.trailer.set("ID", fresh())
            return .done
        }
        let user: String?
        if !doc.needsPassword {
            user = ""
        } else if let given = KeptProtection.current?.openPassword, doc.authBits(given) & 2 != 0 {
            user = given
        } else {
            user = nil
        }
        guard let user, [.aes128, .rc4With128Bits, .rc4With40Bits].contains(method) else { return .kept }
        doc.trailer.set("ID", fresh())
        let open = KeptProtection.dropOpenPassword ? "" : user
        return .reencrypt("garbage=compact," + PdfSecurity.encryptOptions(method, user: open, owner: password ?? "", p: info.p))
    }

    /// A random 16-byte file identifier half.
    private static func randomId() -> [UInt8] { (0..<16).map { _ in UInt8.random(in: 0...255) } }

    /// Incremental updates after the first version (a linearized file's first-page section isn't one).
    static func earlierRevisions(_ data: [UInt8]) -> Int {
        let key = Array("startxref".utf8)
        var count = 0
        var from = data.startIndex
        while let r = data[from...].firstRange(of: key) {
            count += 1
            from = r.upperBound
        }
        if data.prefix(2048).firstRange(of: Array("/Linearized".utf8)) != nil { count -= 1 }
        return max(0, count - 1)
    }

    /// One walk over the document: counts every kind (a scan, `apply` nil), or removes the chosen kinds and counts what it
    /// removed. Something that falls under several kinds (a hidden comment) counts once, under the first that applies in
    /// `SanitizeItem` order.
    final class Pass {
        private static let annotHidden = 2, annotNoView = 32, ffPushButton = 1 << 16

        let doc: MuDoc
        let apply: Set<SanitizeItem>?
        private var counts: [SanitizeItem: Int] = Dictionary(uniqueKeysWithValues: SanitizeItem.allCases.map { ($0, 0) })
        private var notes: [String] = []
        private var aaDone = Set<UInt>()
        private var actionDone = Set<UInt>()
        /// Layers that are off in the default configuration (nil: none).
        private var hiddenOcgs: Set<UInt>?
        private var stripLayers = false
        /// Some hidden-layer content couldn't be cut out: its layers stay (hidden) so it stays hidden.
        private var layerContentKept = false
        /// Scanning a sanitized copy: the original's file identifiers.
        var originalIds: [[UInt8]]?

        private lazy var catalog: PObj = doc.catalog

        init(_ doc: MuDoc, _ apply: Set<SanitizeItem>?) {
            self.doc = doc
            self.apply = apply
        }

        func run(_ earlierRevisions: Int) -> SanitizeReport {
            var unused = 0
            if apply == nil {
                var used = Set(objects().map(\.identity))
                if let info = doc.info {
                    used.insert(info.identity)
                    for o in doc.closure([info]) { used.insert(o.identity) }
                }
                // Not content: cross-reference and object streams, the encryption dictionary.
                unused = doc.allObjects().filter { o in
                    o.isDict && !used.contains(o.identity) && o.name("Type") != "XRef" && o.name("Type") != "ObjStm"
                        && !(o.name("Filter") == "Standard" && o.has("O"))
                }.count
            }

            prepareLayers()
            let count = (try? doc.pageCount()) ?? 0
            for i in 0..<count { page(doc.page(i)) }
            documentLevel()
            fields()
            if stripLayers { stripHiddenLayers() }
            otherObjects()
            info()
            return SanitizeReport(counts: counts, earlierRevisions: earlierRevisions, unusedObjects: unused, notes: notes)
        }

        /// Something of kind `item` was found: counted when scanning (false: nothing is removed), or when that kind is
        /// being removed (true: remove it).
        @discardableResult
        private func hit(_ item: SanitizeItem, _ n: Int = 1) -> Bool {
            if n <= 0 { return false }
            guard let apply else {
                counts[item, default: 0] += n
                return false
            }
            if !apply.contains(item) { return false }
            counts[item, default: 0] += n
            return true
        }

        private func removing(_ item: SanitizeItem) -> Bool { apply?.contains(item) == true }

        /// The indirect dictionaries the document uses (what a rewrite keeps), the catalog first.
        private func objects() -> [PObj] {
            var list = [catalog]
            var seen: Set<UInt> = [catalog.identity]
            for o in doc.closure([doc.trailer["Root"]]) where o.isDict && seen.insert(o.identity).inserted { list.append(o) }
            return list
        }

        /// Every dictionary the document uses: the indirect ones (`objects`) and the direct ones inside them (an
        /// annotation written straight into /Annots, a field in /Kids, a dictionary in a dictionary).
        private func allDictionaries() -> [PObj] {
            var list: [PObj] = []
            var seen = Set<UInt>()
            var stack: [(PObj, Int)] = objects().map { ($0, 0) }
            while let (item, depth) = stack.popLast() {
                if depth > 64 || !seen.insert(item.identity).inserted { continue }
                if item.isDict {
                    list.append(item)
                    for key in item.keys {
                        if let v = item[key], !v.isRef, v.isDict || v.isArray { stack.append((v, depth + 1)) } // references: listed already
                    }
                } else if item.isArray {
                    for v in item.elements where !v.isRef && (v.isDict || v.isArray) { stack.append((v, depth + 1)) }
                }
            }
            return list
        }

        // ---- Pages and annotations ----

        private func page(_ page: PObj) {
            if page.has("Thumb") && hit(.thumbnails) { page.remove("Thumb") }
            cleanAA(page)
            annotations(page)
        }

        private func annotations(_ page: PObj) {
            guard let annots = page.array("Annots") else { return }
            var remove: [UInt: PObj] = [:]
            for a in annots.elements where a.isDict {
                let subtype = a.name("Subtype") ?? ""
                if subtype == "Popup" || remove[a.identity] != nil { continue }
                if classify(a, subtype) != nil {
                    remove[a.identity] = a
                    continue
                }
                let hadAction = a.has("A")
                cleanActionEntry(a, "A")
                cleanAA(a)
                // A link whose only action went leads nowhere: it goes too.
                if subtype == "Link" && hadAction && !a.has("A") && !a.has("Dest") { remove[a.identity] = a }
            }
            if remove.isEmpty { return }

            // Pop-up notes go with their annotation.
            for r in Array(remove.values) {
                if let popup = r.dict("Popup") { remove[popup.identity] = popup }
            }
            for a in annots.elements where a.isDict && a.name("Subtype") == "Popup" {
                if let parent = a.dict("Parent"), remove[parent.identity] != nil { remove[a.identity] = a }
            }

            // The page's own list (a shared one is copied first).
            let kept = annots.elements.filter { !($0.isDict && remove[$0.identity] != nil) }
            if kept.isEmpty {
                page.remove("Annots")
            } else {
                page.set("Annots", doc.array(kept))
            }
            for w in remove.values where w.name("Subtype") == "Widget" { detachWidget(w) }
        }

        /// The kind an annotation is removed as (counted), or nil when it stays.
        private func classify(_ a: PObj, _ subtype: String) -> SanitizeItem? {
            var kinds: [SanitizeItem] = []
            if hiddenOcgs != nil && isHiddenOc(a["OC"]) { kinds.append(.hiddenLayers) }
            if (a.int("F") ?? 0) & (Self.annotHidden | Self.annotNoView) != 0 { kinds.append(.hiddenAnnotations) }
            switch subtype {
            case "FileAttachment": kinds.append(.embeddedFiles)
            case "RichMedia", "3D", "Sound", "Movie", "Screen": kinds.append(.activeContent)
            case "Link", "Widget", "PrinterMark", "TrapNet", "Watermark", "": break
            default: kinds.append(.comments)
            }
            guard let first = kinds.first else { return nil }
            // Annotations of a hidden layer go with it: the layer is what's counted.
            if first == .hiddenLayers && removing(.hiddenLayers) { return .hiddenLayers }
            if apply == nil {
                if first != .hiddenLayers { hit(first) }
                return nil
            }
            for k in kinds where k != .hiddenLayers && hit(k) { return k }
            return nil
        }

        /// Takes a removed widget out of its field; a field left without widgets (and so on up) goes too.
        private func detachWidget(_ widget: PObj) {
            let acro = catalog.dict("AcroForm")
            var node = widget
            for _ in 0..<64 {
                let parent = node.dict("Parent")
                guard let list = parent.map({ $0.array("Kids") }) ?? acro?.array("Fields") else { return }
                for k in stride(from: list.count - 1, through: 0, by: -1) where list[k]?.identity == node.identity { list.remove(at: k) }
                if let co = acro?.array("CO") {
                    for k in stride(from: co.count - 1, through: 0, by: -1) where co[k]?.identity == node.identity { co.remove(at: k) }
                }
                guard let parent, list.count == 0 else { return }
                node = parent
            }
        }

        // ---- Actions ----

        /// The kind of content an action is (nil: one that stays, such as going to a page).
        private static func actionKind(_ a: PObj) -> SanitizeItem? {
            let s = a.name("S") ?? ""
            if ["JavaScript", "Launch", "SubmitForm", "ImportData", "Rendition", "Movie", "Sound", "RichMediaExecute", "GoTo3DView"].contains(s)
                || a.has("JS") { return .activeContent }
            if ["URI", "GoToR", "GoToE"].contains(s) || (s == "Thread" && a.has("F")) { return .externalLinks }
            return nil
        }

        private enum Cleaned {
            case same, gone
            case replaced(PObj)
        }

        /// Cleans the action chain in owner[key] (each owner's /A once).
        private func cleanActionEntry(_ owner: PObj, _ key: String) {
            if key == "A" && !actionDone.insert(owner.identity).inserted { return }
            guard let item = owner[key], item.isDict else { return }
            switch cleanChain(item) {
            case .same: break
            case .gone: owner.remove(key)
            case .replaced(let first): owner.set(key, first)
            }
        }

        /// An action with the ones after it (/Next) minus those being removed, in the order they run.
        private func cleanChain(_ item: PObj) -> Cleaned {
            var chain: [PObj] = []
            var seen = Set<UInt>()
            flatten(item, &chain, &seen, 0)
            var keep: [PObj] = []
            var removed = false
            for a in chain {
                if let kind = Self.actionKind(a), hit(kind) {
                    removed = true
                } else {
                    keep.append(a)
                }
            }
            if !removed { return .same }
            for k in keep { k.remove("Next") }
            guard let first = keep.first else { return .gone }
            if keep.count > 1 { first.set("Next", doc.array(Array(keep.dropFirst()))) }
            return .replaced(first)
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

        /// Cleans the additional actions (/AA) of a document, page, annotation or field.
        private func cleanAA(_ owner: PObj) {
            guard aaDone.insert(owner.identity).inserted, let aa = owner.dict("AA") else { return }
            for key in aa.keys { cleanActionEntry(aa, key) }
            if apply != nil && aa.count == 0 { owner.remove("AA") }
        }

        // ---- Document level ----

        private func documentLevel() {
            if catalog.dict("OpenAction") != nil { cleanActionEntry(catalog, "OpenAction") }
            cleanAA(catalog)

            let names = catalog.dict("Names")
            if let js = names?.dict("JavaScript"), hit(.activeContent, max(1, PdfStructure.nameTree(js).count)) { names?.remove("JavaScript") }
            if let files = names?.dict("EmbeddedFiles") {
                let n = PdfStructure.nameTree(files).count
                if n > 0 && hit(.embeddedFiles, n) { names?.remove("EmbeddedFiles") }
            }
            if removing(.embeddedFiles) { catalog.remove("Collection") } // a portfolio's layout: its files are gone
            if removing(.externalLinks) { catalog.remove("URI") } // the base of relative web addresses

            if let outlines = catalog.dict("Outlines") {
                let items = Self.outlineItems(outlines)
                if !items.isEmpty && hit(.bookmarks, items.count) {
                    catalog.remove("Outlines")
                    if catalog.name("PageMode") == "UseOutlines" { catalog.remove("PageMode") }
                } else {
                    // A bookmark keeps going where it went; only a removed action is taken off it.
                    for item in items { cleanActionEntry(item, "A") }
                }
            }
        }

        private static func outlineItems(_ outlines: PObj) -> [PObj] {
            var list: [PObj] = []
            var seen: Set<UInt> = [outlines.identity]
            var stack: [PObj] = []
            if let first = outlines.dict("First") { stack.append(first) }
            while let top = stack.popLast(), list.count < 200_000 {
                var item: PObj? = top
                while let cur = item, seen.insert(cur.identity).inserted {
                    list.append(cur)
                    if let child = cur.dict("First") { stack.append(child) }
                    item = cur.dict("Next")
                }
            }
            return list
        }

        // ---- Form fields ----

        private func fields() {
            guard let acro = catalog.dict("AcroForm") else { return }
            // Every node of the field tree: a field or widget that no page lists in /Annots still runs its actions.
            for node in Self.fieldNodes(acro) {
                cleanActionEntry(node, "A")
                cleanAA(node)
            }

            let fields = (try? FormEditor.collect(doc, acro)) ?? []

            if acro.has("XFA") {
                if fields.isEmpty {
                    // XFA-only: the pages are a placeholder, the form is all there is.
                    if apply == nil || removing(.activeContent) {
                        notes.append("The XFA form (with its scripts and data) was kept: the document has no other form, so removing it would leave only a placeholder page.")
                    }
                } else if hit(.activeContent) {
                    acro.remove("XFA")
                }
            }

            let valued = fields.filter(Self.hasValue)
            if !valued.isEmpty && hit(.formValues, valued.count) {
                _ = try? FormEditor.clearFields(doc, Set(valued.flatMap(\.widgets).map(\.identity)))
                for f in valued {
                    // Fields without widgets, and default values (what Reset Form would bring back).
                    if f.widgets.isEmpty { for key in ["V", "RV", "I"] { f.dict.remove(key) } }
                    if f.type == "Tx" || f.type == "Ch" { f.dict.remove("DV") }
                }
            }

            let signed = fields.filter { $0.type == "Sig" && FormEditor.inherited($0.dict, "V")?.isDict == true }
            if !signed.isEmpty && hit(.signatures, signed.count) {
                for f in signed {
                    var d: PObj? = f.dict
                    var guardCount = 0
                    while let cur = d, guardCount < 64 {
                        cur.remove("V")
                        d = cur.dict("Parent")
                        guardCount += 1
                    }
                    for w in f.widgets { w.remove("AP") } // the visible signature (the signer's name, a picture)
                }
                catalog.remove("Perms") // certification (DocMDP) refers to a signature that is gone
                catalog.remove("DSS") // validation data: certificates, revocation answers
                acro.remove("SigFlags")
            }
        }

        private static func hasValue(_ f: FormField) -> Bool {
            func filled(_ v: PObj?) -> Bool {
                guard let v else { return false }
                if v.kind == .string { return !(v.bytes ?? []).isEmpty }
                if v.isArray { return v.count > 0 }
                if v.isStream { return !(v.rawStreamData ?? []).isEmpty }
                return false
            }
            switch f.type {
            case "Tx", "Ch":
                return filled(FormEditor.inherited(f.dict, "V")) || filled(f.dict["DV"])
            case "Btn" where f.flags & ffPushButton == 0:
                if let on = FormEditor.inherited(f.dict, "V")?.name, on != "Off" { return true }
                return f.widgets.contains { w in w.name("AS").map { $0 != "Off" } ?? false }
            default:
                return false
            }
        }

        /// Every node of the field tree (each once).
        private static func fieldNodes(_ acro: PObj) -> [PObj] {
            var list: [PObj] = []
            var seen = Set<UInt>()
            var stack: [(PObj, Int)] = (acro.array("Fields")?.elements ?? []).filter(\.isDict).map { ($0, 0) }
            while let (node, depth) = stack.popLast() {
                if depth > 64 || !seen.insert(node.identity).inserted { continue }
                list.append(node)
                for k in node.array("Kids")?.elements ?? [] where k.isDict { stack.append((k, depth + 1)) }
            }
            return list
        }

        // ---- Metadata and the rest of the objects ----

        private func otherObjects() {
            for d in allDictionaries() {
                // Who made a comment and when (a widget's /T is its field name, not an author).
                if d.has("Rect"), let subtype = d.name("Subtype"), !subtype.isEmpty, !d.has("BBox") {
                    let keys = subtype == "Widget" ? ["M"] : ["T", "M", "CreationDate", "NM"]
                    if keys.contains(where: d.has) && hit(.metadata) { for k in keys { d.remove(k) } }
                }
                if d.has("PieceInfo") && hit(.metadata) {
                    d.remove("PieceInfo")
                    d.remove("LastModified") // when the private data was last changed
                }
                if let xmp = d.dict("Metadata"), xmp.isStream, d.identity != catalog.identity || Self.xmpHasData(xmp), hit(.metadata) {
                    d.remove("Metadata")
                }
                if let af = d.array("AF"), af.count > 0, hit(.embeddedFiles, af.count) { d.remove("AF") }
            }
        }

        private func info() {
            if let info = doc.info {
                // Not counted when applying: a modification date written just now.
                let keys = info.keys.filter { k in
                    !(k == "ModDate" && apply != nil && PdfDates.parse(info.text(k)).map { abs($0.timeIntervalSinceNow) < 300 } == true)
                }
                if !keys.isEmpty && hit(.metadata, keys.count) { for k in info.keys { info.remove(k) } }
            }

            // Articles (threads) carry an information dictionary of their own: title, author, subject, dates.
            for t in catalog.array("Threads")?.elements ?? [] where t.isDict {
                if let ti = t.dict("I"), ti.count > 0, hit(.metadata, ti.count) { t.remove("I") }
            }

            if let ids = originalIds, !ids.isEmpty {
                let current = (doc.trailer.array("ID")?.elements ?? []).compactMap(\.bytes)
                if current.contains(where: ids.contains) { hit(.metadata) } // the file identifier still links this copy to the original
            }
        }

        private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

        /// Whether an XMP packet says anything beyond what a save writes anyway (producer, tool). Document IDs, history
        /// and derivation link a copy to its original, so they count. An unreadable packet counts as data.
        static func xmpHasData(_ stream: PObj) -> Bool { xmpData(stream).map { !$0.isEmpty } ?? true }

        /// The properties of an XMP packet that say something, as (name, value) in packet order; nil when the packet
        /// can't be read (it counts as data).
        static func xmpData(_ stream: PObj) -> [(name: String, value: String)]? {
            guard let bytes = stream.streamData,
                  let xml = try? XMLDocument(data: Data(bytes), options: [.nodeLoadExternalEntitiesNever]),
                  let root = xml.rootElement() else { return nil }
            var all: [XMLElement] = []
            func walk(_ e: XMLElement) {
                all.append(e)
                for c in e.children ?? [] { if let ce = c as? XMLElement { walk(ce) } }
            }
            walk(root)
            // The packet PDFsharp writes itself on every save (Windows): its document IDs are new each time.
            let fresh = (root.attributes ?? []).contains { $0.localName == "xmptk" && $0.stringValue == "3.1-701" }
                && all.contains { $0.localName == "Producer" && ($0.stringValue ?? "").hasPrefix("PDFsharp") }
                && !all.contains { ["OriginalDocumentID", "History", "DerivedFrom"].contains($0.localName ?? "") }
            func meaningful(_ name: String, _ value: String) -> Bool {
                let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if v.isEmpty || name == "Producer" || name == "CreatorTool" || (fresh && (name == "DocumentID" || name == "InstanceID")) { return false }
                return !(["CreateDate", "ModifyDate", "MetadataDate"].contains(name) && v.hasPrefix("0001-"))
            }
            var list: [(String, String)] = []
            for desc in all where desc.localName == "Description" && desc.uri == rdf {
                for attr in desc.attributes ?? [] {
                    let local = attr.localName ?? attr.name ?? ""
                    if local == "about" && attr.uri == rdf { continue }
                    if meaningful(local, attr.stringValue ?? "") { list.append((local, (attr.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines))) }
                }
                for case let el as XMLElement in desc.children ?? [] {
                    // A list (rdf:Seq, Bag, Alt) reads as its items joined.
                    var items: [String] = []
                    func lis(_ e: XMLElement) {
                        for case let c as XMLElement in e.children ?? [] {
                            if c.localName == "li" && c.uri == rdf {
                                let v = (c.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                if !v.isEmpty { items.append(v) }
                            }
                            lis(c)
                        }
                    }
                    lis(el)
                    let value = items.isEmpty ? el.stringValue ?? "" : items.joined(separator: "; ")
                    let name = el.localName ?? ""
                    if meaningful(name, value) { list.append((name, value.trimmingCharacters(in: .whitespacesAndNewlines))) }
                }
            }
            return list
        }

        // ---- Hidden layers ----

        private func prepareLayers() {
            guard let props = catalog.dict("OCProperties"), let list = props.array("OCGs") else { return }
            var ocgs: [PObj] = []
            var ids = Set<UInt>()
            for o in list.elements where o.isDict && ids.insert(o.identity).inserted { ocgs.append(o) }
            let d = props.dict("D")
            let on = Set(Self.members(d?["ON"]).map(\.identity))
            let off = Set(Self.members(d?["OFF"]).map(\.identity))
            let baseOff = d?.name("BaseState") == "OFF"
            let hidden = Set(ocgs.filter { off.contains($0.identity) || (baseOff && !on.contains($0.identity)) }.map(\.identity))
            if hidden.isEmpty { return }
            hiddenOcgs = hidden
            stripLayers = hit(.hiddenLayers, hidden.count)
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

        /// Whether an /OC entry (a layer or a membership dictionary) hides what it marks in the default configuration.
        private func isHiddenOc(_ oc: PObj?) -> Bool {
            guard let hidden = hiddenOcgs, let d = oc, d.isDict else { return false }
            return d.name("Type") == "OCMD" ? !ocmdVisible(d) : hidden.contains(d.identity)
        }

        private func ocmdVisible(_ ocmd: PObj) -> Bool {
            var done: [UInt: Bool?] = [:]
            if let ve = ocmd.array("VE"), let result = evaluate(ve, &done, 0) { return result }
            let members = Self.members(ocmd["OCGs"])
            if members.isEmpty { return true }
            let hidden = hiddenOcgs ?? []
            func on(_ m: PObj) -> Bool { !hidden.contains(m.identity) }
            switch ocmd.name("P") {
            case "AllOn": return members.allSatisfy(on)
            case "AnyOff": return members.contains { !on($0) }
            case "AllOff": return members.allSatisfy { !on($0) }
            default: return members.contains(where: on)
            }
        }

        /// A visibility expression ([/And ...], [/Or ...], [/Not x]); nil when it can't be read. Each array is evaluated
        /// once (`done`): an expression can use one many times.
        private func evaluate(_ ve: PObj, _ done: inout [UInt: Bool?], _ depth: Int) -> Bool? {
            if let known = done[ve.identity] { return known }
            let result = read(ve, &done, depth)
            done[ve.identity] = .some(result)
            return result
        }

        private func read(_ ve: PObj, _ done: inout [UInt: Bool?], _ depth: Int) -> Bool? {
            if depth > 16 || ve.count < 2 { return nil }
            var operands: [Bool] = []
            for e in ve.elements.dropFirst() {
                let v: Bool?
                if e.isArray {
                    v = evaluate(e, &done, depth + 1)
                } else if e.isDict {
                    v = !(hiddenOcgs ?? []).contains(e.identity)
                } else {
                    v = nil
                }
                guard let v else { return nil }
                operands.append(v)
            }
            switch ve[0]?.name {
            case "And": return operands.allSatisfy { $0 }
            case "Or": return operands.contains(true)
            case "Not": return !operands[0]
            default: return nil
            }
        }

        private func stripHiddenLayers() {
            var resources: [UInt: PObj] = [:]
            let count = (try? doc.pageCount()) ?? 0
            for i in 0..<count {
                let page = doc.page(i)
                let res = PageBoxes.inherited(page, "Resources").flatMap { $0.isDict ? $0 : nil }
                if let res { resources[res.identity] = res }
                stripPage(page, res, i)
            }
            for d in objects() {
                guard d.isStream else { continue }
                let isForm = d.name("Subtype") == "Form"
                let isPattern = d.int("PatternType") == 1
                if !isForm && !isPattern { continue }
                if isForm && isHiddenOc(d["OC"]) {
                    // A form XObject of a hidden layer draws nothing: empty it (it may be used in places not rewritten).
                    d.setStream([], deflate: true)
                    d.remove("Resources")
                    continue
                }
                let res = d.dict("Resources")
                if let res { resources[res.identity] = res }
                let bytes = d.streamData ?? []
                if bytes.isEmpty && !(d.rawStreamData ?? []).isEmpty {
                    if mentionsHidden(res) { keepLayerContent("A drawing that uses a hidden layer couldn't be decoded") }
                    continue
                }
                let (stripped, why) = strip(bytes, res)
                if let stripped { d.setStream(stripped, deflate: true) }
                if let why { keepLayerContent(why) }
            }

            if !layerContentKept {
                // Resource entries of hidden layers and their XObjects: nothing draws them now.
                for res in resources.values {
                    if let props = res.dict("Properties") {
                        for key in props.keys where isHiddenOc(props[key]) { props.remove(key) }
                    }
                    if let xobjects = res.dict("XObject") {
                        for key in xobjects.keys {
                            if let x = xobjects.dict(key), isHiddenOc(x["OC"]) { xobjects.remove(key) }
                        }
                    }
                }
            }
            removeHiddenLayers(Array(resources.values))
        }

        private func keepLayerContent(_ why: String) {
            let note = why + ": hidden layers were kept (still hidden) so it stays hidden."
            if !notes.contains(note) { notes.append(note) }
            layerContentKept = true
        }

        private func mentionsHidden(_ res: PObj?) -> Bool {
            if let props = res?.dict("Properties"), props.keys.contains(where: { isHiddenOc(props[$0]) }) { return true }
            if let xs = res?.dict("XObject"), xs.keys.contains(where: { xs.dict($0).map { isHiddenOc($0["OC"]) } ?? false }) { return true }
            return false
        }

        /// The page's content streams read as one, hidden-layer content cut out, written back as one stream.
        private func stripPage(_ page: PObj, _ res: PObj?, _ index: Int) {
            guard let contents = page["Contents"] else { return }
            let parts = contents.isStream ? [contents] : contents.elements.filter(\.isStream)
            if parts.isEmpty { return }
            var all: [UInt8] = []
            for s in parts {
                let bytes = s.streamData ?? []
                if bytes.isEmpty && !(s.rawStreamData ?? []).isEmpty {
                    if mentionsHidden(res) { keepLayerContent("Page \(index + 1) has content that couldn't be decoded") }
                    return
                }
                all += bytes
                all.append(10)
            }
            let (stripped, why) = strip(all, res)
            if let why { keepLayerContent("Page \(index + 1): \(why)") }
            guard let stripped else { return }
            page.set("Contents", doc.addStream(stripped, deflate: true))
        }

        private func strip(_ content: [UInt8], _ res: PObj?) -> (content: [UInt8]?, kept: String?) {
            let props = res?.dict("Properties")
            let xobjects = res?.dict("XObject")
            return HiddenContent.strip(content,
                                       hiddenTag: { isHiddenOc(props?[$0]) },
                                       hiddenXObject: { name in xobjects?.dict(name).map { isHiddenOc($0["OC"]) } ?? false })
        }

        /// Takes the hidden layers out of the layer configuration (unless some of their content had to stay).
        private func removeHiddenLayers(_ resources: [PObj]) {
            guard let props = catalog.dict("OCProperties"), let hidden = hiddenOcgs, !layerContentKept else { return }
            var gone = hidden

            // Membership dictionaries: an expression that names a hidden layer keeps it; plain lists are rewritten so
            // what they show doesn't change (the hidden layers are off for good). They are often direct objects: in
            // /Properties of resources, or an /OC entry.
            var ocmds: [UInt: PObj] = [:]
            var order: [UInt] = []
            func consider(_ item: PObj?) {
                guard let m = item, m.isDict, m.name("Type") == "OCMD" else { return }
                if ocmds[m.identity] == nil { order.append(m.identity) }
                ocmds[m.identity] = m
            }
            for o in objects() {
                consider(o)
                consider(o["OC"])
            }
            for res in resources {
                if let list = res.dict("Properties") { for key in list.keys { consider(list[key]) } }
            }
            let all = order.compactMap { ocmds[$0] }
            for m in all where m.has("VE") {
                var used = Set<UInt>()
                var seen = Set<UInt>()
                Self.collectVe(m.array("VE"), &used, &seen, 0)
                if !used.isDisjoint(with: gone) {
                    notes.append("A layer visibility expression uses a hidden layer, so that layer was kept (still hidden; its content was removed).")
                }
                gone.subtract(used)
            }
            for m in all where !m.has("VE") {
                let members = Self.members(m["OCGs"])
                if !members.contains(where: { gone.contains($0.identity) }) { continue }
                let visible = ocmdVisible(m)
                let rest = members.filter { !gone.contains($0.identity) }
                if (visible && m.name("P") == "AnyOff") || rest.isEmpty {
                    m.remove("OCGs") // satisfied for good (or marks only removed content): no effect
                    m.remove("P")
                } else {
                    // The members as they were written (references, as the file had them).
                    let written = (m["OCGs"]?.isArray == true ? m["OCGs"]!.elements : [m["OCGs"]!]).filter { $0.isDict && !gone.contains($0.identity) }
                    m.set("OCGs", doc.array(written))
                }
            }
            if gone.isEmpty { return }

            var filtered = Set<UInt>()
            Self.filter(props.array("OCGs"), gone, &filtered)
            var configs: [PObj] = []
            if let d = props.dict("D") { configs.append(d) }
            configs += (props.array("Configs")?.elements ?? []).filter(\.isDict)
            for c in configs {
                for key in ["ON", "OFF", "Locked", "Order"] { Self.filter(c.array(key), gone, &filtered) }
                for g in c.array("RBGroups")?.elements ?? [] { Self.filter(g.isArray ? g : nil, gone, &filtered) }
                for a in c.array("AS")?.elements ?? [] where a.isDict { Self.filter(a.array("OCGs"), gone, &filtered) }
            }
            if (props.array("OCGs")?.count ?? 0) == 0 { catalog.remove("OCProperties") }
        }

        /// The layers an expression names (each of its arrays read once: `seen`).
        private static func collectVe(_ ve: PObj?, _ into: inout Set<UInt>, _ seen: inout Set<UInt>, _ depth: Int) {
            guard let ve, ve.isArray, depth <= 16, seen.insert(ve.identity).inserted else { return }
            for e in ve.elements.dropFirst() {
                if e.isArray {
                    collectVe(e, &into, &seen, depth + 1)
                } else if e.isDict {
                    into.insert(e.identity)
                }
            }
        }

        /// Removes the layers from an array, and from arrays inside it (/Order nests them). Arrays in `done` were
        /// filtered already (arrays can be shared).
        private static func filter(_ a: PObj?, _ gone: Set<UInt>, _ done: inout Set<UInt>, _ depth: Int = 0) {
            guard let a, a.isArray, depth <= 32, done.insert(a.identity).inserted else { return }
            for k in stride(from: a.count - 1, through: 0, by: -1) {
                guard let e = a[k] else { continue }
                if e.isDict && gone.contains(e.identity) {
                    a.remove(at: k)
                } else if e.isArray {
                    filter(e, gone, &done, depth + 1)
                }
            }
        }
    }
}
