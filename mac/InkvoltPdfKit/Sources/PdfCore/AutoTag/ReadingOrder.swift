import Foundation

/// One piece of a page in the reading order pane: its number, what it is, the start of its text (the Windows app's
/// `ReadingOrderItem`).
public struct ReadingOrderItem: Equatable, Sendable {
    /// The block's index in the plan.
    public let index: Int
    /// Its place among the pieces read with its page.
    public let number: Int
    public let block: TagBlock

    public var needsAlt: Bool { block.kind == .figure && !block.decorative && (block.alt ?? "").isBlank }

    public var kind: String {
        let b = block
        let what: String
        switch b.kind {
        case .heading: what = "Heading \(b.level)"
        case .list:
            let nested = b.items.contains { $0.level > 0 } ? ", nested" : ""
            what = "List (\(b.items.count) \(b.items.count == 1 ? "item" : "items")\(nested))"
        case .table:
            let columns = b.headerRow ? ", column headers" : "", rows = b.headerColumn ? ", row headers" : ""
            what = "Table (\(b.rows.count) \(b.rows.count == 1 ? "row" : "rows")\(columns)\(rows))"
        case .caption: what = "Caption"
        case .note: what = "Footnote"
        case .contents: what = "Table of contents (\(b.items.count) \(b.items.count == 1 ? "entry" : "entries"))"
        case .formula: what = "Formula"
        case .figure: what = b.decorative ? "Picture (decorative)" : needsAlt ? "Picture: needs alternate text" : "Picture"
        case .paragraph: what = b.lang.map { "Paragraph (\($0))" } ?? "Paragraph"
        }
        return what + (b.readWith == nil ? "" : " · from page \(b.page + 1)")
    }

    public var preview: String {
        block.kind == .figure || block.kind == .formula ? block.alt ?? block.text : block.text.replacingOccurrences(of: "\n", with: " ")
    }

    /// What a screen reader says for the item.
    public var spoken: String { "\(number). \(kind). \(preview.prefix(120))" }
}

/// A numbered box of the reading order pane: where a piece is, its place in its page's order, and how it shows.
public struct ReadingOrderBox: Equatable, Sendable {
    public let page: Int
    public let box: RectD
    public let number: Int
    public let selected: Bool
    public let needsAlt: Bool
}

/// What the reading order pane shows for a plan on a page (Windows' `FillReadingOrder`).
public struct ReadingOrderState: Equatable, Sendable {
    /// The pieces read with this page, in order.
    public var items: [ReadingOrderItem] = []
    /// The boxes on every page (none when the document changed since the plan was made).
    public var boxes: [ReadingOrderBox] = []
    public var summary = ""
    public var editable = false
    public var canMoveToPageBefore = false
    public var canMoveToPageAfter = false
    public var canApply = false

    public init() {}
}

/// The reading order pane's rules and words (the Windows app's `DocumentTab.ReadingOrder` and `AccessibleActions`), so the
/// app's views only show them.
public enum ReadingOrder {
    /// Language codes offered (any other can be typed).
    public static let languages = ["en", "en-US", "en-GB", "es", "es-PR", "es-ES", "es-MX", "fr", "de", "it", "pt", "pt-BR", "nl"]

    /// The list for `page`, the boxes on every page, the summary and what can be done. `selected`: the block's index in the
    /// plan; `stale`: the document changed since the plan was made; `written`: the plan is in the document as it is now.
    public static func state(_ plan: TagPlan, page: Int, selected: Int?, stale: Bool, written: Bool) -> ReadingOrderState {
        var s = ReadingOrderState()
        let page = max(0, min(page, max(0, plan.pages - 1)))
        var numbers: [Int: Int] = [:]
        var readElsewhere = 0
        // Heading levels as they are written.
        for (i, b) in AutoTag.evenHeadings(plan.blocks).enumerated() {
            // Numbered among the pieces read with its page (a piece moved to another page is numbered there; its box stays
            // where its content is).
            let reading = AutoTag.readingPage(b)
            let n = numbers[reading, default: 0] + 1
            numbers[reading] = n
            let item = ReadingOrderItem(index: i, number: n, block: b)
            if reading == page {
                s.items.append(item)
            } else if b.page == page {
                readElsewhere += 1
            }
            if !stale { s.boxes.append(ReadingOrderBox(page: b.page, box: b.box, number: n, selected: i == selected, needsAlt: item.needsAlt)) }
        }
        let missing = plan.figuresWithoutAlt
        if stale {
            s.summary = "The document changed since this reading order was made. Choose Make Accessible again to read it anew."
        } else {
            let elsewhere = readElsewhere == 0 ? "" : "\(readElsewhere) \(readElsewhere == 1 ? "piece here is" : "pieces here are") read with another page. "
            let pictures = missing == 0 ? "Every picture has alternate text or is decorative." : "\(missing) \(missing == 1 ? "picture needs" : "pictures need") alternate text."
            s.summary = "\(s.items.count) \(s.items.count == 1 ? "piece" : "pieces") on page \(page + 1), in the order a screen reader reads them. "
                + elsewhere + pictures + (written ? " The document is tagged this way." : " Apply changes to tag the document this way.")
        }
        s.editable = !stale
        s.canMoveToPageBefore = !stale && page > 0
        s.canMoveToPageAfter = !stale && page < plan.pages - 1
        s.canApply = !stale && !written
        return s
    }

    /// The first piece read with `page`, or nil.
    public static func firstPiece(_ plan: TagPlan, page: Int) -> Int? {
        plan.blocks.firstIndex { AutoTag.readingPage($0) == page }
    }

    /// The plan with piece `index` read with the page before (-1) or after (1), the piece's new index and that page; nil when
    /// there is no such page.
    public static func movedToPage(_ plan: TagPlan, _ index: Int, _ by: Int) -> (plan: TagPlan, index: Int, page: Int)? {
        guard plan.blocks.indices.contains(index) else { return nil }
        let moved = AutoTag.moveToPage(plan, index, by)
        if moved == plan { return nil }
        let was = plan.blocks[index]
        guard let at = moved.blocks.firstIndex(where: { $0.box == was.box && $0.page == was.page && $0.kind == was.kind }) else { return nil }
        return (moved, at, AutoTag.readingPage(moved.blocks[at]))
    }

    /// The plan with the piece at `from` dropped on the piece at `onto` (a drag in the list, within a page).
    public static func dropped(_ plan: TagPlan, _ from: Int, onto: Int) -> TagPlan { AutoTag.move(plan, from, onto - from) }

    // ---- Make Accessible's window ----

    /// What the title and language are missing, or nil when they will do.
    public static func problem(title: String, language: String) -> String? {
        if title.isBlank { return "Type a title: PDF/UA asks for one." }
        return AccessibilityCheck.isLanguage(language.trimmedWS) ? nil : "Choose or type a language code, such as en, en-US or es."
    }

    public static let introduction = "Tags the document on this Mac, from its layout: headings, paragraphs, lists, tables and pictures in reading order; running headers, footers and page numbers are marked as decoration. Screen readers and Reflow use the tags. You can undo this until you save."

    public static let replaces = "This document already has tags. They are replaced with new ones (pictures in the same place keep their alternate text)."

    public static func titleNote(_ plan: TagPlan) -> String {
        switch plan.titleFrom {
        case .metadata: "From the document's properties. Screen readers say it first, and the window shows it."
        case .heading: "From the first heading: check that it says what the document is."
        case .none: "No title was found: type one that says what the document is."
        }
    }

    public static func languageNote(_ plan: TagPlan) -> String {
        if plan.language == nil { return "The language couldn't be told from the text: choose or type its code (such as en or es)." }
        return plan.languageGuessed ? "Read from the text: check it. A code such as en, en-US or es-PR." : "From the document. A code such as en, en-US or es-PR."
    }

    public static func found(_ plan: TagPlan) -> String {
        func count(_ n: Int, _ what: String) -> String { n == 1 ? "1 \(what)" : "\(n) \(what)s" }
        let headings = plan.blocks.count { $0.kind == .heading }, tables = plan.blocks.count { $0.kind == .table }
        let figures = plan.blocks.count { $0.kind == .figure }, missing = plan.figuresWithoutAlt
        let tail = missing > 0 ? "; \(count(missing, "picture")) still \(missing == 1 ? "needs" : "need") alternate text, which you add in the Reading Order pane that opens next." : "."
        return "Found: \(count(headings, "heading")), \(count(tables, "table")), \(count(figures, "picture"))" + tail
    }

    /// What the status bar says once the tags are written.
    public static func written(_ plan: TagPlan) -> String {
        let missing = plan.figuresWithoutAlt
        return missing == 0 ? "Tagged. Check the reading order. Save to keep it."
            : "Tagged. \(missing) \(missing == 1 ? "picture needs" : "pictures need") alternate text: select each in the Reading Order pane."
    }
}
