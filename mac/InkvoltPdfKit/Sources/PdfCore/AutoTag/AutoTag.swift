import Foundation

/// What a tag block becomes: a paragraph (P), a heading (H1-H6), a list (L › LI › LBody, nested lists inside an item's
/// LBody), a table, a figure, a figure's or table's caption (Caption: inside the table it belongs to), a footnote (Note,
/// with an ID), a table of contents (TOC › TOCI) or display math (Formula, with alternate text).
public enum TagBlockKind: Equatable, Sendable { case paragraph, heading, list, table, figure, caption, note, contents, formula }

/// Where the title Make Accessible proposes came from.
public enum TitleSource: Equatable, Sendable { case metadata, heading, none }

/// A list item (or contents entry): where its text is on the page (as shown) and the text, for the reading order panel.
public struct TagListItem: Equatable, Sendable {
    public var sources: [RectD]
    public var text: String
    /// How deep it is nested: 0 for the list's own items, 1 for a list inside one of them, and so on.
    public var level = 0
}

/// A table cell: where its text and any pictures in it are on the page, its text, and how many columns it spans.
public struct TagCell: Equatable, Sendable {
    public var sources: [RectD]
    public var text: String
    public var colSpan = 1
    public var pictures: [RectD] = []
}

/// One piece of a page in reading order, as Make Accessible will tag it. Boxes are in page space as shown (points, top
/// left origin, the page's rotation applied), like `ExportPage`'s.
public struct TagBlock: Equatable, Sendable {
    public var page: Int
    public var kind: TagBlockKind
    public var box: RectD
    /// Heading level 1-6 (`.heading`); levels are evened out when written (no gaps, first is H1).
    public var level = 0
    /// Where its content is on the page: text runs, or a figure's area.
    public var sources: [RectD] = []
    /// Its text (a figure's is empty): what the reading order panel shows.
    public var text = ""
    public var items: [TagListItem] = []
    public var rows: [[TagCell]] = []
    /// How many rows at the top hold column headers (TH with Scope Column): two when a header spans columns over the headers under it.
    public var headerRows = 0
    /// Each row's first cell is its row header (TH with Scope Row).
    public var headerColumn = false
    /// The language of this passage when it isn't the document's (a code such as "es"); nil: the document's.
    public var lang: String?
    /// A figure's or formula's alternate text (a formula's is its text until someone writes another).
    public var alt: String?
    /// A figure that only decorates: marked as an artifact, no alternate text needed.
    public var decorative = false
    /// The page it is read with when that isn't its own (a sidebar continuing an article from the page before): its
    /// content stays on `page`, the structure reads it among that page's pieces. Nil: its own page.
    public var readWith: Int?

    public init(page: Int, kind: TagBlockKind, box: RectD) {
        self.page = page
        self.kind = kind
        self.box = box
    }

    /// The table has column headers (`headerRows` above 0).
    public var headerRow: Bool { headerRows > 0 }
}

/// What Make Accessible will write: the blocks in reading order, the running headers, footers and page numbers per page
/// (artifacts), and the title and language proposed. The reading order panel edits it before (or after) it is written.
public struct TagPlan: Equatable, Sendable {
    public var blocks: [TagBlock]
    public var running: [[RectD]]
    public var title: String?
    public var titleFrom = TitleSource.metadata
    public var language: String?
    /// The language was read from the text (none was set), so it is a guess to confirm.
    public var languageGuessed = false
    /// The document already had tags (writing replaces them).
    public var wasTagged = false

    public init(blocks: [TagBlock], running: [[RectD]]) {
        self.blocks = blocks
        self.running = running
    }

    public var pages: Int { running.count }

    /// Figures that still need alternate text (not decorative, no text).
    public var figuresWithoutAlt: Int { blocks.count { $0.kind == .figure && !$0.decorative && ($0.alt ?? "").isBlank } }
}

/// Title and language written with the tags (the plan's own when these are nil).
public struct AccessibleOptions: Equatable, Sendable {
    public var title: String?
    public var language: String?

    public init(title: String? = nil, language: String? = nil) {
        self.title = title
        self.language = language
    }
}

/// Make Accessible: tags an untagged PDF on the Mac (the Windows app's `AutoTag`). `plan` reads the pages as Export to Word
/// does (`DocLayout`: headings, paragraphs, lists, tables, pictures and charts, columns, running headers and footers) into
/// a `TagPlan`; `write` puts each piece of page content in marked content with an MCID (or marks it as an artifact), builds
/// the structure tree from the plan's order, and sets MarkInfo, the title (shown in the window's title bar), the language,
/// the tab order and the PDF/UA identifier.
public enum AutoTag {
    /// Reads the document into a plan. Pages that can't be read have no blocks (their content becomes artifacts).
    /// - Throws: `CancellationError` when `cancel` fired.
    public static func plan(_ engine: PdfEngine, _ data: [UInt8], _ password: String?,
                            progress: ((_ done: Int, _ total: Int) -> Void)? = nil, cancel: CancelToken? = nil) throws -> TagPlan {
        var pages: [ExportPage] = []
        pages.reserveCapacity(engine.pageCount)
        for p in 0..<engine.pageCount {
            try cancel?.check()
            progress?(p, engine.pageCount)
            do {
                pages.append(try engine.exportPage(p, images: true, cancel: cancel, boxesOnly: true))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let g = engine.page(p)
                pages.append(ExportPage(g.width, g.height, [], [], []))
            }
        }
        let (layout, running) = DocLayout.analyzeForTags(pages)
        let body = DocLayout.bodySize(pages)
        var blocks: [TagBlock] = []
        for p in layout.pages.indices { blocks += self.blocks(p, layout.pages[p], body, pages[p].height) }

        var title: String?, lang: String?
        var tagged = false
        if let doc = try? PdfEdit.openToRead(data, password) {
            title = InfoDict.get(doc, create: false)?.text("Title")?.trimmedWS
            lang = doc.catalog.text("Lang")?.trimmedWS
            tagged = doc.catalog.has("StructTreeRoot")
            // Tagged before (by Make Accessible or another program): figures in the same place keep their alternate text.
            if tagged {
                let alts = (try? figureAlts(doc)) ?? []
                for i in blocks.indices where blocks[i].kind == .figure {
                    let b = blocks[i]
                    let match = alts.first { a in
                        guard a.page == b.page, let box = a.box else { return false }
                        return area(box.intersect(b.box)) > 0.5 * min(area(box), area(b.box))
                    }
                    if let match { blocks[i].alt = match.alt }
                }
            }
        }
        var from = TitleSource.metadata
        if title == nil || title!.isBlank || looksLikeFileName(title!) {
            title = blocks.first { $0.kind == .heading }?.text.trimmedWS
            from = (title ?? "").isEmpty ? .none : .heading
        }
        var guessed = false
        if lang == nil || lang!.isBlank || !isLanguage(lang) {
            lang = Language.guess(blocks.map(\.text).joined(separator: " "))
            guessed = true
        }
        // Passages in another language than the document's, where the words say so clearly.
        if let lang {
            for i in blocks.indices where blocks[i].kind == .paragraph {
                if let own = Language.guess(blocks[i].text, strict: true), primary(own).lowercased() != primary(lang).lowercased() {
                    blocks[i].lang = own
                }
            }
        }

        var plan = TagPlan(blocks: blocks, running: running)
        plan.title = (title ?? "").isBlank ? nil : title
        plan.titleFrom = from
        plan.language = lang
        plan.languageGuessed = guessed
        plan.wasTagged = tagged
        return plan
    }

    /// The Figure tags with alternate text: page, box (page space as shown; nil when the tag gives none) and text. A page
    /// given on a tag holds for what's inside it, a role map's own names for figures count, and the attributes may be one
    /// dictionary or a list.
    static func figureAlts(_ doc: MuDoc) throws -> [(page: Int, box: RectD?, alt: String)] {
        var found: [(page: Int, box: RectD?, alt: String)] = []
        let pages = try doc.pages()
        // Arrays too: an array shared (or in itself) is walked once, not once per path to it.
        var seen = Set<UInt>()
        let root = doc.catalog.dict("StructTreeRoot")
        let roles = root?.dict("RoleMap")
        func isFigure(_ start: String?) -> Bool {
            var name = start
            for _ in 0..<8 {
                guard let n = name else { return false }
                if n == "Figure" { return true }
                name = roles?.name(n)
            }
            return false
        }
        func boxOf(_ d: PObj) -> PObj? {
            guard let attributes = d["A"] else { return nil }
            let list = attributes.isArray ? attributes.elements : [attributes]
            return list.lazy.compactMap { $0.isDict ? $0.array("BBox") : nil }.first { $0.count == 4 }
        }
        func visit(_ item: PObj?, _ depth: Int, _ inherited: Int) {
            guard let item, depth <= 64, found.count <= 10_000 else { return }
            if item.isArray {
                guard seen.insert(item.identity).inserted else { return }
                for x in item.elements { visit(x, depth + 1, inherited) }
            } else if item.isDict {
                guard seen.insert(item.identity).inserted else { return }
                let own = item.has("Pg") ? doc.pageIndex(of: item["Pg"]) ?? -1 : -1
                let p = own >= 0 ? own : inherited
                if isFigure(item.name("S")), let alt = item.text("Alt"), !alt.isEmpty, p >= 0, p < pages.count {
                    var box: RectD?
                    if let bb = boxOf(item) { box = PageBoxes.toPageSpace(pages[p], bb.num(0), bb.num(1), bb.num(2), bb.num(3)) }
                    found.append((p, box, alt))
                }
                visit(item["K"], depth + 1, p)
            }
        }
        visit(root?["K"], 0, -1)
        return found
    }

    /// The document has a structure tree (tags) and says it is tagged.
    public static func isTagged(_ data: [UInt8], _ password: String?) -> Bool {
        guard let doc = try? PdfEdit.openToRead(data, password) else { return false }
        let catalog = doc.catalog
        guard catalog.has("StructTreeRoot"), let marked = catalog.dict("MarkInfo")?["Marked"] else { return false }
        return marked.kind == .bool && marked.bool
    }

    /// A language tag as RFC 3066 writes them ("en", "en-US", "zh-Hant-TW", "x-klingon"): what PDF/UA-1 asks of every Lang
    /// (the Windows app's `AccessibilityCheck.IsLanguage`).
    public static func isLanguage(_ s: String?) -> Bool {
        guard let s, !s.isEmpty, s.utf16.count <= 64 else { return false }
        return languageTag.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }

    private static let languageTag = try! NSRegularExpression(pattern: "^[a-zA-Z]{1,8}(-[a-zA-Z0-9]{1,8})*$")

    private static func primary(_ lang: String) -> String { String(lang.split(separator: "-", omittingEmptySubsequences: false).first ?? "") }

    /// "Microsoft Word - report.docx", "untitled.pdf": a producer's placeholder, not a title.
    private static func looksLikeFileName(_ title: String) -> Bool {
        let t = title.lowercased()
        return [".doc", ".docx", ".pdf", ".tex", ".dvi"].contains { t.hasSuffix($0) } || t.hasPrefix("microsoft word - ") || t == "untitled"
    }

    private static let sectionPattern = try! NSRegularExpression(pattern: #"^(\d{1,3}|[A-Z])((\.\d{1,3})*)\.?\s+\p{L}"#)

    /// How deep a section number at the start goes ("3" 1, "3.1" 2, "A.2.1" 3), or nil when the text doesn't start with one.
    static func sectionDepth(_ text: String) -> Int? {
        let s = text.trimmedStartWS as NSString
        guard let m = sectionPattern.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)) else { return nil }
        return 1 + s.substring(with: m.range(at: 2)).filter { $0 == "." }.count
    }

    static func bounds(_ boxes: [RectD]) -> RectD { boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) } }

    /// Heading levels as written: the first is H1 and none skips a level (H1 then H3 becomes H1 then H2).
    public static func evenHeadings(_ blocks: [TagBlock]) -> [TagBlock] {
        var current = 0
        return blocks.map { b in
            guard b.kind == .heading else { return b }
            var b = b
            let level = max(1, min(6, min(b.level, current + 1)))
            current = level
            b.level = level
            return b
        }
    }

    /// A figure as a PNG on white, at most `maxSide` pixels on its longer side.
    public static func figurePng(_ engine: PdfEngine, _ page: Int, _ box: RectD, maxSide: Int = 768) throws -> [UInt8] {
        let scale = min(4, max(0.25, Double(maxSide) / max(1, max(box.width, box.height))))
        guard var r = try engine.renderRegionRgba(page, box, scale: scale, cancel: nil) else { throw PdfEditError("The picture couldn't be drawn.") }
        var i = 0
        while i + 3 < r.rgba.count {
            let a = Int(r.rgba[i + 3])
            for k in 0..<3 { r.rgba[i + k] = UInt8((Int(r.rgba[i + k]) * a + 255 * (255 - a)) / 255) }
            r.rgba[i + 3] = 255
            i += 4
        }
        return PngEncoder.encode(r.width, r.height, r.rgba, alpha: false)
    }

    /// The text of the blocks on a figure's page nearest it (a caption, the paragraph that mentions it), up to `max` characters.
    public static func nearbyText(_ plan: TagPlan, _ index: Int, max limit: Int = 1500) -> String {
        guard plan.blocks.indices.contains(index) else { return "" }
        let fig = plan.blocks[index]
        var near: [(i: Int, d: Double)] = []
        for (i, b) in plan.blocks.enumerated() where i != index && b.page == fig.page && !b.text.isEmpty {
            let above: Double = b.box.y - fig.box.bottom, below: Double = fig.box.y - b.box.bottom
            near.append((i, max(0, max(above, below))))
        }
        near.sort { $0.d != $1.d ? $0.d < $1.d : $0.i < $1.i }
        var out = ""
        for n in near {
            let t = plan.blocks[n.i].text
            if out.utf16.count + t.utf16.count > limit { break }
            out += t + "\n"
        }
        return out.trimmedWS
    }

    /// The page a block is read with: its own, or the one it was moved to (`TagBlock.readWith`).
    public static func readingPage(_ b: TagBlock) -> Int { b.readWith ?? b.page }

    /// The plan with one block read with the page before (`by` -1: after that page's last piece) or after (1: before its
    /// first piece); back on its own page it is its own page's piece again. The plan unchanged when there is no such page.
    public static func moveToPage(_ plan: TagPlan, _ index: Int, _ by: Int) -> TagPlan {
        guard plan.blocks.indices.contains(index), by == -1 || by == 1 else { return plan }
        let b = plan.blocks[index]
        let page = readingPage(b) + by
        guard page >= 0, page < plan.pages else { return plan }
        var blocks = plan.blocks
        blocks.remove(at: index)
        var moved = b
        moved.readWith = page == b.page ? nil : page
        // Pieces are kept in page order of their reading page: after the last one read with a page before or on it, or
        // before the first one read with a page after it.
        let at = by < 0 ? (blocks.lastIndex { readingPage($0) <= page }.map { $0 + 1 } ?? 0) : (blocks.firstIndex { readingPage($0) >= page } ?? blocks.count)
        blocks.insert(moved, at: at)
        var result = plan
        result.blocks = blocks
        return result
    }

    /// The plan's blocks with one moved among those read with its page, `by` places up (negative) or down.
    public static func move(_ plan: TagPlan, _ index: Int, _ by: Int) -> TagPlan {
        guard plan.blocks.indices.contains(index), by != 0 else { return plan }
        let page = readingPage(plan.blocks[index])
        var target = index
        for _ in 0..<min(abs(by), plan.blocks.count) {
            let next = target + (by < 0 ? -1 : 1)
            if !plan.blocks.indices.contains(next) || readingPage(plan.blocks[next]) != page { break }
            target = next
        }
        if target == index { return plan }
        var result = plan
        let b = result.blocks.remove(at: index)
        result.blocks.insert(b, at: target)
        return result
    }

    /// The plan with block `index` changed (alternate text, decorative, kind).
    public static func with(_ plan: TagPlan, _ index: Int, _ change: (inout TagBlock) -> Void) -> TagPlan {
        guard plan.blocks.indices.contains(index) else { return plan }
        var result = plan
        change(&result.blocks[index])
        return result
    }

    static func area(_ r: RectD) -> Double { r.isEmpty ? 0 : r.width * r.height }

    /// Tells a text's language from its most common short words (English, Spanish, French, German, Italian, Portuguese,
    /// Dutch). Only a proposal: the person confirms the document's language before it is written.
    enum Language {
        private static func list(_ code: String, _ words: String) -> (code: String, words: Set<String>) {
            (code, Set(words.split(separator: " ").map(String.init)))
        }

        private static let lists = [
            list("en", "the and of to in is that for it with as was on are be this by from or have which not at we an they you"),
            list("es", "el la de que y en los las del se por con una para es su al lo como más pero sus le ha este esta son"),
            list("fr", "le la les de des et est un une du en que qui dans pour pas sur au avec ce il sont par ne se nous vous"),
            list("de", "der die und in den von zu das mit sich des auf für ist im dem nicht ein eine als auch es an werden aus er sie"),
            list("it", "il di che e la per un in del della non una sono le si con dei gli da al è lo come anche nel alla ha"),
            list("pt", "de a o que e do da em um para com não uma os no se na por mais as dos como mas ao das à seu"),
            list("nl", "de het een en van in is dat op te zijn met voor niet aan er om ook als bij door naar worden wordt maar deze die"),
        ]

        private static let separators: Set<Character> = [" ", "\n", "\r", "\t", ",", ".", ";", ":", "(", ")", "\"", "“", "”", "¿", "?", "¡", "!"]

        /// The language code, or nil when there are too few words or no clear winner. `strict`: a passage: more words and a
        /// wider margin before saying it is in another language.
        static func guess(_ text: String, strict: Bool = false) -> String? {
            let words = text.lowercased().split { separators.contains($0) }.prefix(5000).map(String.init)
            if words.count < (strict ? 25 : 8) { return nil }
            let scores = lists.enumerated()
                .map { i, list in (order: i, code: list.code, hits: words.count(where: list.words.contains)) }
                .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.order < $1.order }
            let best = scores[0], second = scores[1]
            if Double(best.hits) < Double(words.count) * (strict ? 0.2 : 0.1) { return nil }
            if Double(best.hits) < Double(second.hits) * (strict ? 2.0 : 1.3) { return nil }
            return best.code
        }
    }
}
