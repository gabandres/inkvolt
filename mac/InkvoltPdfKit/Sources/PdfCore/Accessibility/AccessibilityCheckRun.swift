import Foundation

extension AccessibilityCheck {
    /// Most findings listed per condition; the rest are counted in one more finding.
    static let maxPerCondition = 200

    /// Checks the document. Nothing is changed.
    /// - Parameter progress: (pages done, pages).
    /// - Throws: `PdfEditError` when the file can't be read as a PDF, `PasswordRequired` when the password is missing or
    ///   wrong, `CancellationError` when `cancel` fires.
    public static func run(_ data: [UInt8], _ password: String?, progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil) throws -> AccessibilityReport {
        let doc: MuDoc
        let pages: Int
        let data = HybridXref.normalize(data) // Word's files keep their tags where MuPDF alone doesn't look
        do {
            doc = try PdfEdit.openToRead(data, password)
            pages = try doc.pageCount()
        } catch let e as PdfEditError {
            throw PdfEditError(e.message.replacingOccurrences(of: "This PDF can't be read", with: "This PDF can't be checked"))
        } catch let e as PdfEngineError {
            throw PdfEditError("This PDF can't be checked: \(e.message)")
        }
        // MuPDF rebuilds what it can of a damaged file, so a file that isn't one opens as a document without pages.
        guard pages > 0 else { throw PdfEditError("This PDF can't be checked: it has no pages.") }
        return try AccessibilityChecker(data, doc, pages, progress, cancel).run()
    }

    /// An encrypted file's permissions (/P) against Matterhorn 26: "26-001" without them, "26-002" when they don't allow
    /// copying for accessibility (bit 10), else nil.
    static func permissionsCondition(_ p: Int?) -> String? {
        guard let p else { return "26-001" }
        return p & 512 == 0 ? "26-002" : nil
    }

    /// A language tag as RFC 3066 writes them ("en", "en-US", "zh-Hant-TW", "x-klingon"): what PDF/UA-1 asks of every Lang.
    static func isLanguage(_ s: String?) -> Bool {
        guard let s, !s.isEmpty, s.utf16.count <= 64 else { return false }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        func isLetter(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) }
        func isDigit(_ c: UInt8) -> Bool { (48...57).contains(c) }
        for (i, part) in parts.enumerated() {
            guard (1...8).contains(part.utf8.count) else { return false }
            guard part.utf8.allSatisfy({ isLetter($0) || (i > 0 && isDigit($0)) }) else { return false }
        }
        return true
    }
}

/// One run of the check (the Windows app's `AccessibilityCheck.Checker`). Its parts are in AccessibilityCheckRun (the
/// document), AccessibilityCheckStructure (the tags), AccessibilityCheckContent (pages, annotations) and
/// AccessibilityCheckFonts.
final class AccessibilityChecker {
    let data: [UInt8]
    let doc: MuDoc
    let pageCount: Int
    let progress: ((Int, Int) -> Void)?
    let cancel: CancelToken?
    let catalog: PObj
    var root: PObj?
    /// The catalog's /Lang is a language: every text's language can be told.
    var docLang = false
    var notes: [String] = []

    private var findings: [AccessibilityFinding] = []
    private var listed: [String: Int] = [:]
    private var dropped: [String: Int] = [:]
    private var droppedOrder: [String] = []

    // The tags (AccessibilityCheckStructure).
    var elems: [UInt: AccessibilityElem] = [:]
    var ordered: [AccessibilityElem] = []
    var parentTree: [Int: PObj?] = [:]
    var roleMap: [String: String] = [:]
    var classMap: PObj?
    var pageObjects: [PObj] = []
    var pageByNumber: [Int: Int] = [:]
    var pageByIdentity: [UInt: Int] = [:]

    // The content walk (AccessibilityCheckContent).
    var fonts: [UInt: AccessibilityFontUse] = [:]
    var fontOrder: [AccessibilityFontUse] = []
    var textFonts: [UInt: TextFont] = [:]
    var forms: [UInt: AccessibilityFormUse] = [:]
    var formOrder: [UInt] = []
    var refForms = Set<UInt>()
    var xobjects: [UInt: [String: AccessibilityXObject?]] = [:]
    var parsedOps = 0
    var totalOps = 0
    var walkedAppearances = Set<UInt>()

    init(_ data: [UInt8], _ doc: MuDoc, _ pageCount: Int, _ progress: ((Int, Int) -> Void)?, _ cancel: CancelToken?) {
        self.data = data
        self.doc = doc
        self.pageCount = pageCount
        self.progress = progress
        self.cancel = cancel
        catalog = doc.catalog
    }

    /// Whether another finding of this condition would only be counted (so working out where it is can be skipped).
    func full(_ condition: String) -> Bool { listed[condition, default: 0] >= AccessibilityCheck.maxPerCondition }

    func add(_ f: AccessibilityFinding) {
        if full(f.condition) {
            if dropped[f.condition] == nil { droppedOrder.append(f.condition) }
            dropped[f.condition, default: 0] += f.count
            return
        }
        listed[f.condition, default: 0] += 1
        findings.append(f)
    }

    func add(_ condition: String, _ problem: String, page: Int = -1, box: RectD = .zero, element: String = "Document", count: Int = 1, fix: String? = nil) {
        var f = AccessibilityFinding(condition: condition, problem: problem)
        f.page = page
        f.box = box
        f.element = element
        f.count = count
        f.fixOverride = fix
        add(f)
    }

    func run() throws -> AccessibilityReport {
        pageObjects = (0..<pageCount).map { doc.page($0) }
        for (i, page) in pageObjects.enumerated() {
            if page.isRef, pageByNumber[page.num] == nil { pageByNumber[page.num] = i }
            if pageByIdentity[page.identity] == nil { pageByIdentity[page.identity] = i }
        }

        root = catalog.dict("StructTreeRoot")
        let lang = Self.text(catalog["Lang"])
        docLang = lang != nil // present, even empty or malformed (that is reported on its own, as UA 7.2-Lang)
        if let lang, !AccessibilityCheck.isLanguage(lang) { add("UA 7.2-Lang", "The document's language is “\(Self.short(lang))”, which isn't a language code.") }

        header()
        if root == nil { add("UA 7.1", "The document has no tags (no structure tree), so screen readers can't tell its headings, lists, tables or reading order.") }
        let markInfo = catalog.dict("MarkInfo")
        if markInfo == nil || Self.bool(markInfo?["Marked"]) != true {
            add("UA 6.2", markInfo == nil ? "The document doesn't say it is tagged (no MarkInfo)." : "The document says it isn't tagged (Marked isn't true).")
        }
        if Self.bool(markInfo?["Suspects"]) == true { add("01-007", "The document says its tags may be wrong (Suspects is true).") }

        metadata()
        viewerPreferences()
        security()
        optionalContent()
        embeddedFiles()
        xfa()
        outlines()

        if root != nil { try readStructure() }
        try pages()
        if root != nil { try checkStructure() }
        try checkFonts()

        for condition in droppedOrder {
            let n = dropped[condition] ?? 0
            var more = AccessibilityFinding(condition: condition, problem: "… and \(n) more like these (only the first \(AccessibilityCheck.maxPerCondition) are listed).")
            more.count = n
            findings.append(more)
        }
        let order = AccessibilityCheck.conditionOrder
        let sorted = findings.enumerated().sorted { a, b in
            let ca = order[a.element.condition] ?? .max, cb = order[b.element.condition] ?? .max
            if ca != cb { return ca < cb }
            let pa = max(a.element.page, -1), pb = max(b.element.page, -1)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
        return AccessibilityReport(failures: sorted, notes: notes, pages: pageCount, tagged: root != nil)
    }

    // MARK: The document

    /// PDF/UA-1 is PDF 1.7: the file's header is "%PDF-1.n" with n from 0 to 7.
    private func header() {
        let start = data.prefix(1024)
        let mark = Array("%PDF-".utf8)
        var at: Int?
        if start.count >= mark.count {
            for i in 0...(start.count - mark.count) where start[i] == mark[0] && Array(start[i..<i + mark.count]) == mark {
                at = i
                break
            }
        }
        var head: [UInt8] = []
        if let at {
            head = Array(start[at...].prefix { $0 != 13 && $0 != 10 })
            while let last = head.last, [9, 11, 12, 32, 0x85, 0xA0].contains(last) { head.removeLast() }
        }
        if head.count == 8 && head.starts(with: Array("%PDF-1.".utf8)) && (48...55).contains(head[7]) { return }
        let text = latin1String(head)
        let problem: String
        if text.hasPrefix("%PDF-2") {
            problem = "The file is PDF 2.0; PDF/UA-1 is based on PDF 1.7 (PDF 2.0 files follow PDF/UA-2)."
        } else if at != nil {
            problem = "The file's header is “\(Self.short(text))”, not “%PDF-1.n” (n from 0 to 7)."
        } else {
            problem = "The file doesn't start with a PDF header."
        }
        add("UA 6.1", problem)
    }

    private static let pdfUaId = "http://www.aiim.org/pdfua/ns/id/"

    private func metadata() {
        guard let stream = catalog.dict("Metadata"), stream.isStream else {
            add("06-001", "The document has no XMP metadata, so it can't say it is PDF/UA or give its title there.")
            return
        }
        // Windows' reader refuses a document type definition (and with it any entity expansion).
        guard let xmp = Xmp.read(doc), xmp.dtd == nil else {
            add("06-001", "The document's XMP metadata can't be read (it isn't well-formed XML).")
            return
        }
        var all: [XMLElement] = []
        var stack: [XMLElement] = xmp.rootElement().map { [$0] } ?? []
        while let e = stack.popLast() {
            all.append(e)
            for child in (e.children ?? []).reversed() {
                if let c = child as? XMLElement { stack.append(c) }
            }
        }
        func isA(_ e: XMLElement, _ uri: String, _ name: String) -> Bool { e.localName == name && e.uri == uri }

        // pdfuaid:part, as an attribute of a description or an element inside it.
        let attribute = all.lazy.filter { isA($0, Xmp.rdf, "Description") }.compactMap { $0.attribute(forLocalName: "part", uri: Self.pdfUaId)?.stringValue }.first
        let part = attribute ?? all.first { isA($0, Self.pdfUaId, "part") }?.stringValue
        if let part {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if value != "1" {
                add("06-002", "The metadata says the document follows PDF/UA part \(Self.short(value)), not part 1.")
            } else if let prefix = Self.prefix(all, Self.pdfUaId), prefix != "pdfuaid" {
                add("06-002", "The PDF/UA identifier is written with the prefix “\(prefix)”; PDF/UA asks for “pdfuaid”.")
            }
        } else {
            add("06-002", "The metadata doesn't say the document is PDF/UA (it has no pdfuaid:part).")
        }

        if !all.contains(where: { isA($0, Xmp.dc, "title") }) { add("06-003", "The metadata has no title (dc:title).") }

        // Metadata text whose only language alternative is x-default: its language comes from the document's.
        if !docLang {
            for alt in all where isA(alt, Xmp.rdf, "Alt") {
                let items = (alt.children ?? []).compactMap { $0 as? XMLElement }.filter { isA($0, Xmp.rdf, "li") }
                guard items.count == 1 else { continue }
                let lang = items[0].attribute(forLocalName: "lang", uri: Xmp.xmlNs) ?? items[0].attribute(forName: "xml:lang")
                if lang?.stringValue == "x-default" {
                    add("11-006", "The metadata's \(alt.parent?.localName ?? "text") has no language of its own, and the document has none.")
                }
            }
        }
    }

    private static func prefix(_ all: [XMLElement], _ uri: String) -> String? {
        for e in all {
            for ns in e.namespaces ?? [] where ns.stringValue == uri { return (ns.name ?? "").isEmpty ? "xmlns" : ns.name }
        }
        return nil
    }

    private func viewerPreferences() {
        let display = Self.bool(catalog.dict("ViewerPreferences")?["DisplayDocTitle"])
        if display == nil {
            add("07-001", "The document doesn't ask viewers to show its title in the window (DisplayDocTitle is missing): they show the file name.")
        } else if display == false {
            add("07-002", "The document asks viewers to show the file name in the window instead of its title (DisplayDocTitle is false).")
        }
    }

    private func security() {
        guard let handler = doc.trailer.dict("Encrypt"), handler.has("Filter") else { return }
        switch AccessibilityCheck.permissionsCondition(handler.int("P")) {
        case "26-001": add("26-001", "The file is encrypted but doesn't say what readers may do (no P entry).")
        case "26-002": add("26-002", "The file's protection doesn't allow copying text for accessibility, so screen readers may refuse to read it.")
        default: break
        }
    }

    private func optionalContent() {
        guard let oc = catalog.dict("OCProperties") else { return }
        func config(_ c: PObj?, _ condition: String, _ which: String) {
            guard let c else { return }
            if (Self.text(c["Name"]) ?? "").isEmpty { add(condition, "The \(which) layer configuration has no name.") }
            if c.has("AS") { add("20-003", "The \(which) layer configuration switches layers automatically (it has an AS entry).") }
        }
        config(oc.dict("D"), "20-002", "default")
        for c in (oc.array("Configs")?.elements ?? []).filter(\.isDict).prefix(256) { config(c, "20-001", "other") }
    }

    private func embeddedFiles() {
        for (key, value) in PdfStructure.nameTree(catalog.dict("Names")?.dict("EmbeddedFiles")).prefix(10_000) {
            guard let spec = value, spec.isDict, spec.has("EF"), !Self.hasBothNames(spec) else { continue }
            add("21-001", "The attached file “\(Self.short(key))” lacks \(spec.has("UF") ? "its F name" : "its UF (Unicode) name").", element: "Attached file")
        }
    }

    static func hasBothNames(_ spec: PObj) -> Bool {
        !(text(spec["F"]) ?? "").isEmpty && !(text(spec["UF"]) ?? "").isEmpty
    }

    private func xfa() {
        guard let xfa = catalog.dict("AcroForm")?["XFA"] else { return }
        var bytes: [UInt8] = []
        if xfa.isStream {
            bytes = xfa.streamData ?? []
        } else if xfa.isArray {
            for i in stride(from: 1, to: xfa.count, by: 2) {
                if let part = xfa[i], part.isStream { bytes += part.streamData ?? [] }
            }
        } else {
            return
        }
        if Self.requiresDynamicRender(bytes) {
            add("25-001", "The file holds a dynamic XFA form (dynamicRender is required), which most readers and screen readers can't use.")
        }
    }

    /// `<dynamicRender[^>]*>\s*required\s*</dynamicRender\s*>`, ignoring case, in one pass over the bytes (Windows runs it
    /// as a regular expression with a time limit; a crafted form could spend all of it).
    static func requiresDynamicRender(_ b: [UInt8]) -> Bool {
        func isSpace(_ c: UInt8) -> Bool { c == 32 || (9...13).contains(c) }
        func matches(_ word: [UInt8], at i: Int) -> Bool {
            guard i + word.count <= b.count else { return false }
            for k in 0..<word.count where (b[i + k] | 0x20) != word[k] { return false }
            return true
        }
        let open = Array("<dynamicrender".utf8), close = Array("</dynamicrender".utf8), required = Array("required".utf8)
        var i = 0
        var nextEnd = -1 // the first '>' at or after i, once known
        while i < b.count {
            guard b[i] == 60, matches(open, at: i) else {
                i += 1
                continue
            }
            if nextEnd < i {
                guard let found = b[i...].firstIndex(of: 62) else { return false }
                nextEnd = found
            }
            var p = nextEnd + 1
            while p < b.count && isSpace(b[p]) { p += 1 }
            if matches(required, at: p) {
                p += required.count
                while p < b.count && isSpace(b[p]) { p += 1 }
                if b.indices.contains(p) && b[p] == 60 && matches(close, at: p) {
                    p += close.count
                    while p < b.count && isSpace(b[p]) { p += 1 }
                    if p < b.count && b[p] == 62 { return true }
                }
            }
            i += open.count
        }
        return false
    }

    private func outlines() {
        guard !docLang, let first = catalog.dict("Outlines")?.dict("First") else { return }
        var count = 0
        var seen = Set<UInt>()
        var stack = [first]
        while let item = stack.popLast(), count < 100_000 {
            guard seen.insert(item.identity).inserted else { continue }
            count += 1
            if let next = item.dict("Next") { stack.append(next) }
            if let kid = item.dict("First") { stack.append(kid) }
        }
        add("11-003", "The document has no language, so the language of its \(count) \(count == 1 ? "bookmark" : "bookmarks") can't be told.", element: "Bookmarks", count: count)
    }

    // MARK: Reading objects (Windows' `PdfObj`)

    static func bool(_ o: PObj?) -> Bool? {
        guard let o, o.kind == .bool else { return nil }
        return o.bool
    }

    /// Text held in a string or a stream.
    static func text(_ o: PObj?) -> String? {
        guard let o else { return nil }
        if let s = o.text { return s }
        guard o.isStream else { return nil }
        let b = o.streamData ?? []
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { return TextFont.utf16BE(Array(b[2...])) }
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return String(decoding: b[3...], as: UTF8.self) }
        return latin1String(b)
    }

    static func hasText(_ d: PObj, _ key: String) -> Bool { !(text(d[key]) ?? "").isEmpty }

    /// A dictionary's entry under a name read from a content stream (each byte one Latin-1 character there).
    static func entry(_ d: PObj?, _ name: String) -> PObj? {
        guard let d else { return nil }
        if name.utf8.allSatisfy({ $0 < 128 }) { return d[name] }
        return d[raw: latin1Bytes(name)]
    }

    static func short(_ s: String) -> String { s.count <= 60 ? s : String(s.prefix(57)) + "…" }

    static func count(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(one)s" }

    func step(_ done: Int) { progress?(done, pageCount) }
}
