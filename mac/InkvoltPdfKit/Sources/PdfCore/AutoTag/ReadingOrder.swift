import Foundation
import PrintCore

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
        case .heading: what = loc("Heading {0}", CoreLanguage.number(b.level))
        case .list:
            let n = b.items.count
            if b.items.contains(where: { $0.level > 0 }) {
                what = n == 1 ? loc("List ({0} item, nested)", CoreLanguage.number(n)) : loc("List ({0} items, nested)", CoreLanguage.number(n))
            } else {
                what = n == 1 ? loc("List ({0} item)", CoreLanguage.number(n)) : loc("List ({0} items)", CoreLanguage.number(n))
            }
        case .table:
            let headers = switch (b.headerRow, b.headerColumn) {
            case (true, true): loc(", column headers, row headers")
            case (true, false): loc(", column headers")
            case (false, true): loc(", row headers")
            case (false, false): ""
            }
            what = b.rows.count == 1 ? loc("Table ({0} row{1})", CoreLanguage.number(b.rows.count), headers) : loc("Table ({0} rows{1})", CoreLanguage.number(b.rows.count), headers)
        case .caption: what = loc("Caption")
        case .note: what = loc("Footnote")
        case .contents: what = b.items.count == 1 ? loc("Table of contents ({0} entry)", CoreLanguage.number(b.items.count)) : loc("Table of contents ({0} entries)", CoreLanguage.number(b.items.count))
        case .formula: what = loc("Formula")
        case .figure: what = b.decorative ? loc("Picture (decorative)") : needsAlt ? loc("Picture: needs alternate text") : loc("Picture")
        case .paragraph: what = b.lang.map { loc("Paragraph ({0})", $0) } ?? loc("Paragraph")
        }
        return what + (b.readWith == nil ? "" : loc(" · from page {0}", CoreLanguage.number(b.page + 1)))
    }

    public var preview: String {
        block.kind == .figure || block.kind == .formula ? block.alt ?? block.text : block.text.replacingOccurrences(of: "\n", with: " ")
    }

    /// What a screen reader says for the item.
    public var spoken: String { "\(number). \(kind). \(preview.prefix(120))" }
}

/// A kind the selected piece can be made, as the reading order pane's Kind list shows it (Windows' `PieceKind`).
public struct PieceKind: Equatable, Sendable {
    public let kind: TagBlockKind
    /// A heading's level (1-6); 0 for the other kinds.
    public let level: Int
    public let label: String
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
            s.summary = loc("The document changed since this reading order was made. Choose Make Accessible again to read it anew.")
        } else {
            let n = s.items.count
            var parts = [n == 1 ? loc("{0} piece on page {1}, in the order a screen reader reads them.", CoreLanguage.number(n), CoreLanguage.number(page + 1))
                : loc("{0} pieces on page {1}, in the order a screen reader reads them.", CoreLanguage.number(n), CoreLanguage.number(page + 1))]
            if readElsewhere > 0 {
                parts.append(readElsewhere == 1 ? loc("{0} piece here is read with another page.", CoreLanguage.number(readElsewhere))
                    : loc("{0} pieces here are read with another page.", CoreLanguage.number(readElsewhere)))
            }
            if missing == 0 {
                parts.append(loc("Every picture has alternate text or is decorative."))
            } else {
                parts.append(missing == 1 ? loc("{0} picture needs alternate text.", CoreLanguage.number(missing)) : loc("{0} pictures need alternate text.", CoreLanguage.number(missing)))
            }
            parts.append(written ? loc("The document is tagged this way.") : loc("Apply changes to tag the document this way."))
            s.summary = parts.joined(separator: " ")
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

    // ---- a piece's kind ----

    /// The kinds a piece can be made (`AutoTag.kindsFor`), a heading at each level, as the Kind list shows them.
    public static func kinds(_ b: TagBlock) -> [PieceKind] {
        var list: [PieceKind] = []
        for k in AutoTag.kindsFor(b) {
            if k == .heading {
                for level in 1...6 { list.append(PieceKind(kind: k, level: level, label: loc("Heading {0}", CoreLanguage.number(level)))) }
                continue
            }
            let label = switch k {
            case .list: loc("List")
            case .contents: loc("Table of contents", context: "piece kind")
            case .table: loc("Table")
            case .caption: loc("Caption")
            case .note: loc("Footnote")
            case .formula: loc("Formula")
            case .figure: loc("Picture")
            default: loc("Paragraph")
            }
            list.append(PieceKind(kind: k, level: 0, label: label))
        }
        return list
    }

    /// The entry of `kinds` that says what the piece is now.
    public static func currentKind(_ b: TagBlock, _ kinds: [PieceKind]) -> Int? {
        kinds.firstIndex { $0.kind == b.kind && ($0.kind != .heading || $0.level == min(max(b.level, 1), 6)) }
    }

    /// What is announced once a piece was made another kind.
    public static func kindChanged(_ number: Int, _ label: String) -> String { loc("Piece {0} is now: {1}", CoreLanguage.number(number), label) }

    public static var kindHelp: String { loc("What a screen reader announces this piece as: a heading, a paragraph, a picture… Apply Changes to tag it so.") }

    // ---- Make Accessible's window ----

    /// What the title and language are missing, or nil when they will do.
    public static func problem(title: String, language: String) -> String? {
        if title.isBlank { return loc("Type a title: PDF/UA asks for one.") }
        return AccessibilityCheck.isLanguage(language.trimmedWS) ? nil : loc("Choose or type a language code, such as en, en-US or es.")
    }

    public static var introduction: String {
        loc("Tags the document on this Mac, from its layout: headings, paragraphs, lists, tables and pictures in reading order; running headers, footers and page numbers are marked as decoration. Screen readers and Reflow use the tags. You can undo this until you save.")
    }

    public static var replaces: String {
        loc("This document already has tags. They are replaced with new ones (pictures in the same place keep their alternate text).")
    }

    public static func titleNote(_ plan: TagPlan) -> String {
        switch plan.titleFrom {
        case .metadata: loc("From the document's properties. Screen readers say it first, and the window shows it.")
        case .heading: loc("From the first heading: check that it says what the document is.")
        case .none: loc("No title was found: type one that says what the document is.")
        }
    }

    public static func languageNote(_ plan: TagPlan) -> String {
        if plan.language == nil { return loc("The language couldn't be told from the text: choose or type its code (such as en or es).") }
        return plan.languageGuessed ? loc("Read from the text: check it. A code such as en, en-US or es-PR.") : loc("From the document. A code such as en, en-US or es-PR.")
    }

    public static func found(_ plan: TagPlan) -> String {
        let h = plan.blocks.count { $0.kind == .heading }, t = plan.blocks.count { $0.kind == .table }
        let f = plan.blocks.count { $0.kind == .figure }, missing = plan.figuresWithoutAlt
        let headings = h == 1 ? loc("{0} heading", CoreLanguage.number(h)) : loc("{0} headings", CoreLanguage.number(h))
        let tables = t == 1 ? loc("{0} table", CoreLanguage.number(t)) : loc("{0} tables", CoreLanguage.number(t))
        let figures = f == 1 ? loc("{0} picture", CoreLanguage.number(f)) : loc("{0} pictures", CoreLanguage.number(f))
        if missing == 0 { return loc("Found: {0}, {1}, {2}.", headings, tables, figures) }
        return missing == 1
            ? loc("Found: {1}, {2}, {3}; {0} picture still needs alternate text, which you add in the Reading Order pane that opens next.", CoreLanguage.number(missing), headings, tables, figures)
            : loc("Found: {1}, {2}, {3}; {0} pictures still need alternate text, which you add in the Reading Order pane that opens next.", CoreLanguage.number(missing), headings, tables, figures)
    }

    /// What the status bar says once the tags are written.
    public static func written(_ plan: TagPlan) -> String {
        let missing = plan.figuresWithoutAlt
        if missing == 0 { return loc("Tagged. Check the reading order. Save to keep it.") }
        return missing == 1 ? loc("Tagged. {0} picture needs alternate text: select each in the Reading Order pane.", CoreLanguage.number(missing))
            : loc("Tagged. {0} pictures need alternate text: select each in the Reading Order pane.", CoreLanguage.number(missing))
    }
}
