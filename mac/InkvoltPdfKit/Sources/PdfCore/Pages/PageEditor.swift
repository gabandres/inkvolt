import Foundation

/// Margins as the user sees the page (after its /Rotate), in points.
public struct Margins: Equatable, Sendable {
    public var left: Double, top: Double, right: Double, bottom: Double

    public init(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

/// A source document for merge and insert.
public struct PdfSource: Sendable {
    public var data: [UInt8]
    public var password: String?
    public var name: String

    public init(_ data: [UInt8], _ password: String?, _ name: String) {
        self.data = data
        self.password = password
        self.name = name
    }
}

/// Page-level edits (the Windows app's `PageEditor`). Every operation takes the current PDF bytes and returns new bytes
/// (undo keeps snapshots); edits happen in place, so bookmarks, forms and metadata survive wherever the pages they belong
/// to survive. Removing pages drops the bookmarks, links, actions, named destinations, article beads and form widgets
/// that pointed at them; imported pages bring their bookmarks, links and form fields along (never hidden copies of pages
/// they lead to). Page labels follow their pages. An encrypted document needs its permissions password and stays
/// encrypted; a signed one gets the edit appended.
public enum PageEditor {
    public static func delete(_ data: [UInt8], _ password: String?, _ pages: [Int]) throws -> [UInt8] {
        try edit(data, password) { doc in
            if Set(pages).count >= (try doc.pageCount()) { throw PdfEditError("A document must keep at least one page.") }
            try PdfStructure.removePages(doc, pages)
            SignedEdits.noteRemoval()
        }
    }

    /// Puts the pages in `order` (a permutation of 0..n-1).
    public static func reorder(_ data: [UInt8], _ password: String?, _ order: [Int]) throws -> [UInt8] {
        try edit(data, password) { doc in
            let count = try doc.pageCount()
            if order.count != count || Set(order).count != order.count || order.contains(where: { $0 < 0 || $0 >= count }) {
                throw PdfEditError("Order must be a permutation of the document's pages.")
            }
            if order == Array(0..<count) { return }
            let pages = try doc.pages()
            try doc.deletePages(Array(0..<count))
            for (k, i) in order.enumerated() { doc.insertPage(pages[i], at: k) }
        }
    }

    /// The page order after moving `pages` so they sit before original page `before` (the count: the end).
    public static func moveOrder(_ pageCount: Int, _ pages: [Int], _ before: Int) -> [Int] {
        let moving = Set(pages).sorted()
        var rest = (0..<pageCount).filter { !moving.contains($0) }
        let at = rest.filter { $0 < before }.count
        rest.insert(contentsOf: moving, at: at)
        return rest
    }

    public static func move(_ data: [UInt8], _ password: String?, _ pageCount: Int, _ pages: [Int], _ before: Int) throws -> [UInt8] {
        try reorder(data, password, moveOrder(pageCount, pages, before))
    }

    public static func reverse(_ data: [UInt8], _ password: String?, _ pageCount: Int) throws -> [UInt8] {
        try reorder(data, password, Array((0..<pageCount).reversed()))
    }

    /// Turns pages by `degrees` (a multiple of 90) clockwise, on top of how they are turned already.
    public static func rotate(_ data: [UInt8], _ password: String?, _ pages: [Int], _ degrees: Int) throws -> [UInt8] {
        if degrees % 90 != 0 { throw PdfEditError("Rotation must be a multiple of 90°.") }
        return try edit(data, password) { doc in try doc.rotate(Array(Set(pages)).sorted(), degrees) }
    }

    /// Inserts pages of `source` (all when nil) before page `at` (the count appends).
    public static func insert(_ data: [UInt8], _ password: String?, _ source: PdfSource, _ sourcePages: [Int]?, _ at: Int) throws -> [UInt8] {
        try edit(data, password) { doc in
            let src = try openSource(source, in: doc)
            let srcCount = try src.pageCount()
            let take = sourcePages ?? Array(0..<srcCount)
            let at = min(max(at, 0), try doc.pageCount())
            let graft = try Graft(into: doc)
            var imported: [(source: Int, page: PObj)] = []
            for (k, s) in take.enumerated() {
                try graft.page(src, s, to: at + k)
                imported.append((s, doc.page(at + k)))
            }
            let importer = try PdfStructure.Import(doc, src, graft, imported)
            try importer.copyAnnotations()
            importer.fixLinks()
            try PdfStructure.writeOutline(doc, PdfStructure.readOutline(doc) + importer.outline())
            try importer.registerFields()
            try PdfStructure.dropStrayReferences(doc)
        }
    }

    public static func insertBlank(_ data: [UInt8], _ password: String?, _ at: Int, _ count: Int, _ widthPt: Double, _ heightPt: Double) throws -> [UInt8] {
        try edit(data, password) { doc in
            let at = min(max(at, 0), try doc.pageCount())
            for k in 0..<count {
                let page = doc.add(doc.dict([("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, widthPt, heightPt)),
                                             ("Resources", doc.dict())]))
                doc.insertPage(page, at: at + k)
            }
        }
    }

    /// Inserts a copy of each page right after it.
    public static func duplicate(_ data: [UInt8], _ password: String?, _ pages: [Int]) throws -> [UInt8] {
        try edit(data, password) { doc in
            let copy = try openSource(PdfSource(data, password, ""), in: doc)
            let originals = try doc.pages()
            let graft = try Graft(into: doc)
            var copies: [(source: Int, page: PObj)] = []
            for i in Set(pages).sorted(by: >) {
                try graft.page(copy, i, to: i + 1)
                copies.append((i, doc.page(i + 1)))
            }
            // Links on a copy lead where the original's do; its form fields become separate fields.
            let importer = try PdfStructure.Import(doc, copy, graft, copies) { originals[$0] }
            try importer.copyAnnotations()
            importer.fixLinks()
            try importer.registerFields()
            try PdfStructure.dropStrayReferences(doc)
        }
    }

    /// A new document with just these pages (in document order), saved without the original's password protection.
    public static func extract(_ data: [UInt8], _ password: String?, _ pages: [Int]) throws -> [UInt8] {
        let keep = Set(pages)
        let doc = try PdfEdit.open(data, password)
        let count = try doc.pageCount()
        if !keep.contains(where: { $0 >= 0 && $0 < count }) { throw PdfEditError("No pages selected.") }
        let xmp = Xmp.read(doc)
        let labels = try PdfStructure.readLabels(doc)
        try PdfStructure.removePages(doc, (0..<count).filter { !keep.contains($0) })
        if let labels { try PdfStructure.writeLabels(doc, labels) }
        InfoDict.setDate(doc, "ModDate", Date())
        Xmp.write(doc, original: xmp)
        try doc.checkFailure()
        return try doc.write("garbage=compact,decrypt=yes,encrypt=no")
    }

    /// Consecutive chunks of `pagesPerFile` pages.
    public static func chunksOf(_ pageCount: Int, _ pagesPerFile: Int) -> [[Int]] {
        let size = max(1, pagesPerFile)
        return stride(from: 0, to: pageCount, by: size).map { Array($0..<min($0 + size, pageCount)) }
    }

    /// Combines documents into a new one, keeping each file's bookmarks (nested under a bookmark per source file when
    /// `bookmarkPerFile`), links and form fields (renamed on a name clash, e.g. "name_2").
    public static func merge(_ sources: [PdfSource], _ bookmarkPerFile: Bool) throws -> [UInt8] {
        if sources.isEmpty { throw PdfEditError("Nothing to combine.") }
        let doc = try MuDoc.create()
        var outline: [PdfStructure.OutlineItem] = []
        for source in sources {
            let src = try openSource(source, in: doc)
            let graft = try Graft(into: doc)
            let start = try doc.pageCount()
            var imported: [(source: Int, page: PObj)] = []
            for i in 0..<(try src.pageCount()) {
                try graft.page(src, i, to: start + i)
                imported.append((i, doc.page(start + i)))
            }
            if imported.isEmpty { continue }
            let importer = try PdfStructure.Import(doc, src, graft, imported)
            try importer.copyAnnotations()
            importer.fixLinks()
            let items = importer.outline()
            if bookmarkPerFile {
                let file = PdfStructure.newOutlineItem(doc, ((source.name as NSString).lastPathComponent as NSString).deletingPathExtension,
                                                       imported[0].page)
                file.children = items
                outline.append(file)
            } else {
                outline += items
            }
            try importer.registerFields()
        }
        try PdfStructure.writeOutline(doc, outline)
        try PdfStructure.dropStrayReferences(doc)
        InfoDict.setDate(doc, "CreationDate", Date())
        InfoDict.setDate(doc, "ModDate", Date())
        Xmp.write(doc, original: nil)
        try doc.checkFailure()
        return try doc.write("garbage=compact")
    }

    /// Shrinks the visible area (CropBox) of pages by the given margins.
    public static func crop(_ data: [UInt8], _ password: String?, _ pages: [Int], _ m: Margins) throws -> [UInt8] {
        try edit(data, password) { doc in
            for i in Set(pages).sorted() {
                let page = doc.page(i)
                let b = PageBoxes.visibleBox(page)
                let (l, bottom, r, t) = toPdfSpace(m, PageBoxes.rotate(page))
                let x1 = b.x1 + l, y1 = b.y1 + bottom, x2 = b.x2 - r, y2 = b.y2 - t
                if x2 - x1 < 1 || y2 - y1 < 1 { throw PdfEditError("The margins are larger than page \(i + 1).") }
                page.set("CropBox", doc.reals(x1, y1, x2, y2))
            }
        }
    }

    /// Removes any crop (the CropBox), showing each page's full media box again; the print production boxes (TrimBox,
    /// BleedBox, ArtBox) stay, clipped to the media box.
    public static func uncrop(_ data: [UInt8], _ password: String?, _ pages: [Int]) throws -> [UInt8] {
        try edit(data, password) { doc in
            for i in Set(pages).sorted() {
                let page = doc.page(i)
                page.remove("CropBox")
                let m = PageBoxes.visibleBox(page)
                for key in ["TrimBox", "BleedBox", "ArtBox"] {
                    guard let box = PageBoxes.rect(page[key]) else { continue }
                    let x1 = max(m.x1, box.x1), y1 = max(m.y1, box.y1), x2 = min(m.x2, box.x2), y2 = min(m.y2, box.y2)
                    if x2 <= x1 || y2 <= y1 {
                        page.remove(key)
                    } else if x1 != box.x1 || y1 != box.y1 || x2 != box.x2 || y2 != box.y2 {
                        page.set(key, doc.reals(x1, y1, x2, y2))
                    }
                }
            }
        }
    }

    /// User-facing margins (left, top, right, bottom) as unrotated PDF edge insets (x1, y1, x2, y2).
    static func toPdfSpace(_ m: Margins, _ rotate: Int) -> (left: Double, bottom: Double, right: Double, top: Double) {
        switch ((rotate % 360) + 360) % 360 {
        case 90: (m.top, m.left, m.bottom, m.right)
        case 180: (m.right, m.top, m.left, m.bottom)
        case 270: (m.bottom, m.right, m.top, m.left)
        default: (m.left, m.bottom, m.right, m.top)
        }
    }

    public static func readMetadata(_ data: [UInt8], _ password: String?) throws -> PdfMetadata {
        let doc = try PdfEdit.openToRead(data, password)
        let info = InfoDict.get(doc, create: false)
        return PdfMetadata(title: InfoDict.text(doc, "Title"), author: InfoDict.text(doc, "Author"), subject: InfoDict.text(doc, "Subject"),
                           keywords: InfoDict.text(doc, "Keywords"), creator: InfoDict.text(doc, "Creator"),
                           producer: InfoDict.text(doc, "Producer"), created: PdfDates.parse(info?.text("CreationDate")),
                           modified: PdfDates.parse(info?.text("ModDate")), version: version(data))
    }

    public static func writeMetadata(_ data: [UInt8], _ password: String?, _ title: String, _ author: String, _ subject: String,
                                     _ keywords: String) throws -> [UInt8] {
        try edit(data, password) { doc in
            InfoDict.set(doc, "Title", title)
            InfoDict.set(doc, "Author", author)
            InfoDict.set(doc, "Subject", subject)
            InfoDict.set(doc, "Keywords", keywords)
        }
    }

    /// The version in the file's header ("1.7").
    private static func version(_ data: [UInt8]) -> String {
        let head = String(decoding: data.prefix(16), as: UTF8.self)
        guard let r = head.range(of: #"%PDF-(\d\.\d)"#, options: .regularExpression) else { return "" }
        return String(head[r].dropFirst(5))
    }

    /// Opens the document for an edit, runs `body`, keeps the page labels, the modification date and the XMP packet in
    /// step, and saves it (`rewrite`: always written whole, never appended).
    static func edit(_ data: [UInt8], _ password: String?, rewrite: Bool = false, _ body: (MuDoc) throws -> Void) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        let xmp = Xmp.read(doc)
        let labels = try PdfStructure.readLabels(doc)
        try body(doc)
        if let labels { try PdfStructure.writeLabels(doc, labels) }
        InfoDict.setDate(doc, "ModDate", Date())
        Xmp.write(doc, original: xmp)
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password, rewrite: rewrite)
    }

    /// A source document opened in `doc`'s context (so its pages can be grafted), with its password.
    static func openSource(_ source: PdfSource, in doc: MuDoc) throws -> MuDoc {
        let src: MuDoc
        do {
            src = try MuDoc.open(source.data, in: doc)
        } catch let e as PdfEngineError {
            throw PdfEditError("\"\(source.name)\" can't be read: \(e.message)")
        }
        if src.needsPassword && src.authBits(source.password) == 0 { throw PasswordRequired(wrongPassword: !(source.password ?? "").isEmpty) }
        return src
    }
}
