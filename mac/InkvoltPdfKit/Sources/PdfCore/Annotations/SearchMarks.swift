import Foundation
import PrintCore

/// One search hit to mark: its page and its box on each line it runs over (page space).
public struct HitToMark: Sendable {
    public var page: Int
    public var rects: [RectD]

    public init(_ page: Int, _ rects: [RectD]) {
        self.page = page
        self.rects = rects
    }
}

/// What marking the hits does: `marked` hits marked, `alreadyMarked` under a mark of that kind already, `limited` left for
/// another run past `SearchMarks.maxMarks`, `skipped` on no page of the document or without a box. `pagesNotAllRead`: pages
/// whose marks of that kind cover more lines than are read (`SearchMarks.maxMarkedLines`): a hit there under one of the
/// rest is marked again, and that is said.
public struct SearchMarksCount: Equatable, Sendable {
    public var marked: Int
    public var alreadyMarked: Int
    public var limited: Int
    public var skipped: Int
    public var pagesNotAllRead: Int

    public init(_ marked: Int, _ alreadyMarked: Int, _ limited: Int, _ skipped: Int, pagesNotAllRead: Int = 0) {
        self.marked = marked
        self.alreadyMarked = alreadyMarked
        self.limited = limited
        self.skipped = skipped
        self.pagesNotAllRead = pagesNotAllRead
    }
}

/// What `SearchMarks.apply` did: the document (the same bytes when nothing was marked) and its counts.
public struct SearchMarksResult: Sendable {
    public var data: [UInt8]
    public var count: SearchMarksCount
}

/// Mark All Matches (roadmap 4.18; the Windows app's `SearchMarks`): every hit of a search highlighted, underlined or
/// struck out as a comment of its own, as Highlight Text marks a selection (`Annotations.addTextMarkupIn`), all in one
/// change of the document. A hit already under a mark of the same kind is left alone, so running it twice adds nothing.
public enum SearchMarks {
    /// The most hits marked at once (a search for "e" finds tens of thousands; the reader would crawl).
    public static let maxMarks = 5000

    /// The most lines of a page's existing marks read to tell what is marked already (a hostile page can list one mark
    /// of 20,000 lines thousands of times: hundreds of millions of boxes).
    public static let maxMarkedLines = 50_000

    /// The most entries of a page's /Annots looked at.
    static let maxAnnots = 10_000

    /// The usual colour of each kind (Windows' Highlight, Underline and Strike Out Text colours).
    public static func colorOf(_ kind: TextMarkupKind) -> AnnotColor {
        switch kind {
        case .underline: AnnotColor(0.1, 0.55, 0.2)
        case .strikeOut: .red
        case .squiggly: AnnotColor(0.1, 0.45, 0.85)
        case .highlight: .yellow
        }
    }

    /// The hits marked (at most `maxMarks`; a hit on a page the document doesn't have, or without a box, is passed over)
    /// as `kind` in `color` (nil: `colorOf(kind)`), each a comment by `author`.
    public static func apply(_ data: [UInt8], _ password: String?, _ hits: [HitToMark], _ kind: TextMarkupKind, author: String,
                             color: AnnotColor? = nil) throws -> SearchMarksResult {
        struct NothingToMark: Error {}
        var count = SearchMarksCount(0, 0, 0, 0)
        do {
            let out = try PageEditor.edit(data, password, userEdit: .annotate) { doc in
                let (toMark, planned) = try plan(doc, hits, kind)
                count = planned
                if toMark.isEmpty { throw NothingToMark() }
                for m in toMark { Annotations.addTextMarkupIn(doc, m.page, kind, m.rects, color ?? colorOf(kind), note: nil, author: author) }
            }
            return SearchMarksResult(data: out, count: count)
        } catch is NothingToMark {
            return SearchMarksResult(data: data, count: count)
        }
    }

    /// What `apply` would do, nothing written: for the undo step's name, and to say when there is nothing to mark.
    public static func count(_ data: [UInt8], _ password: String?, _ hits: [HitToMark], _ kind: TextMarkupKind) throws -> SearchMarksCount {
        try plan(try PdfEdit.openToRead(data, password), hits, kind).count
    }

    /// The hits to mark, in order, and the counts.
    private static func plan(_ doc: MuDoc, _ hits: [HitToMark], _ kind: TextMarkupKind) throws -> (toMark: [HitToMark], count: SearchMarksCount) {
        let pageCount = try doc.pageCount()
        var existing: [Int: [RectD]] = [:]
        var toMark: [HitToMark] = []
        var already = 0, limited = 0, skipped = 0, notAllRead = 0
        for hit in hits {
            let rects = hit.rects.filter { !$0.isEmpty && $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite }
            if hit.page < 0 || hit.page >= pageCount || rects.isEmpty {
                skipped += 1
                continue
            }
            if existing[hit.page] == nil {
                let (lines, cut) = markedLines(doc.page(hit.page), kind.rawValue)
                existing[hit.page] = lines
                if cut { notAllRead += 1 }
            }
            let quads = existing[hit.page]!
            if rects.allSatisfy({ r in quads.contains { covers($0, r) } }) {
                already += 1
                continue
            }
            if toMark.count >= maxMarks {
                limited += 1
                continue
            }
            toMark.append(HitToMark(hit.page, rects))
            existing[hit.page]! += rects // the same place twice in the list is marked once
        }
        return (toMark, SearchMarksCount(toMark.count, already, limited, skipped, pagesNotAllRead: notAllRead))
    }

    /// The lines the page's marks of this kind already cover: each mark once however often /Annots lists it, at most
    /// `maxMarkedLines` (`cut` when there were more).
    private static func markedLines(_ page: PObj, _ subtype: String) -> (lines: [RectD], cut: Bool) {
        var lines: [RectD] = []
        guard let annots = page.array("Annots") else { return (lines, false) }
        var seen = Set<ObjId>()
        for i in 0..<min(annots.count, maxAnnots) {
            guard let a = annots[i], a.isDict, seen.insert(a.id).inserted, a.name("Subtype") == subtype else { continue }
            let quads = Annotations.quadRectsOf(page, a, max: min(Annotations.maxQuads, maxMarkedLines - lines.count))
            if lines.count + quads.count > maxMarkedLines {
                lines += quads.prefix(maxMarkedLines - lines.count)
                return (lines, true)
            }
            lines += quads
        }
        return (lines, false)
    }

    /// Most of `hit` lies under `mark`.
    private static func covers(_ mark: RectD, _ hit: RectD) -> Bool {
        let w = min(mark.right, hit.right) - max(mark.x, hit.x)
        let h = min(mark.bottom, hit.bottom) - max(mark.y, hit.y)
        return w > 0 && h > 0 && w * h >= 0.8 * hit.width * hit.height
    }
}
