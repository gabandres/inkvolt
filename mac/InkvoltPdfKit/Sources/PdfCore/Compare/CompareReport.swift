import Foundation
import PrintCore

/// What looks different on a page of the new document, besides its words: boxes in the page's points. `offPage`: areas
/// beyond the page's edge (the old page was larger), which only a note can mention.
public struct CompareVisualArea: Sendable, Equatable {
    public var newPage: Int
    public var boxes: [RectD]
    public var offPage = 0

    public init(_ newPage: Int, _ boxes: [RectD], offPage: Int = 0) {
        self.newPage = newPage
        self.boxes = boxes
        self.offPage = offPage
    }
}

/// A compare report (the Windows app's `CompareReport`): a copy of the new document with the changes as comments, so it
/// can be saved, shared and read in any viewer. Inserted words get a green highlight, changed words an amber one whose
/// comment quotes the old wording, moved words a violet one, reformatted words a blue one saying what changed, areas
/// that look different a light one; a note marks where words were removed (quoting them) or moved from, an inserted page
/// and the place of a removed page; a note on the first page sums it all up. Signed files get the comments appended
/// (signatures stay intact), protected files keep their protection.
public enum CompareReport {
    public static let author = "Inkvolt PDF Compare"

    public static let insertedColor = AnnotColor(0.45, 0.85, 0.4)
    public static let changedColor = AnnotColor(1, 0.72, 0.2)
    public static let removedColor = AnnotColor(0.9, 0.2, 0.2)
    public static let movedColor = AnnotColor(0.72, 0.58, 0.95)
    public static let formattedColor = AnnotColor(0.45, 0.78, 0.92)
    public static let visualColor = AnnotColor(0.72, 0.76, 1)

    private static let maxQuote = 400

    /// - Parameters:
    ///   - newPages: the new document's text, as compared (for where the changed words are).
    ///   - oldName: the old document's name, for the comments.
    ///   - summary: the first page's note.
    ///   - visual: what looks different besides the words.
    /// - Throws: `OwnerPasswordRequired` when the new document needs its permissions password to be edited.
    public static func annotate(_ newData: [UInt8], _ password: String?, _ result: CompareResult, _ newPages: [PageText], oldName: String,
                                summary: String, visual: [CompareVisualArea] = []) throws -> [UInt8] {
        try PageEditor.edit(newData, password) { doc in
            let pageCount = try doc.pageCount()
            // Notes without a place in the text (the summary, removed and inserted pages, removals with no anchor) are
            // gathered into one note per page, in its top-left corner, so any number of them stays on the page.
            var margin: [Int: [(text: String, color: AnnotColor)]] = [:]
            func marginNote(_ page: Int, _ text: String, _ color: AnnotColor) { margin[page, default: []].append((text, color)) }
            /// Highlights a change's words on the new document's pages.
            func highlight(_ c: CompareChange, _ color: AnnotColor, _ note: String) {
                for span in c.new where span.page < pageCount && span.page < newPages.count {
                    let rects = newPages[span.page].rects(span.start, span.end)
                    if !rects.isEmpty { Annotations.addTextMarkupIn(doc, span.page, .highlight, rects, color, note: note, author: author) }
                }
            }

            if pageCount > 0 { marginNote(0, summary, .yellow) }
            for c in result.changes {
                let misread = c.maybeMisread ? loc(" This may be a misreading of the scan.") : ""
                switch c.kind {
                case .inserted, .changed:
                    let note = c.kind == .inserted ? loc("Inserted (not in {0})", oldName) : loc("Changed. {0} has: “{1}”", oldName, quote(c.oldText))
                    highlight(c, c.kind == .inserted ? insertedColor : changedColor, note + misread)
                case .moved:
                    let movedHere = c.old.first.map { loc("Moved here from page {0} of {1}.", CoreLanguage.number($0.page + 1), oldName) } ?? loc("Moved here.")
                    highlight(c, movedColor, movedHere)
                    if let a = c.newAnchor, a.page < pageCount, a.page < newPages.count, let spot = spot(newPages[a.page], a.start), let to = c.new.first {
                        Annotations.addNoteIn(doc, a.page, spot.x, spot.y, loc("Moved to page {0}: “{1}”", CoreLanguage.number(to.page + 1), quote(c.oldText)),
                                              author: author, color: movedColor)
                    }
                case .formatted:
                    highlight(c, formattedColor, loc("Formatting: {0}", c.look?.describe() ?? ""))
                case .deleted:
                    let text = loc("Removed: “{0}”", quote(c.oldText)) + misread
                    if let a = c.newAnchor, a.page < pageCount, a.page < newPages.count, let spot = spot(newPages[a.page], a.start) {
                        Annotations.addNoteIn(doc, a.page, spot.x, spot.y, text, author: author, color: removedColor)
                    } else if let p = nearestNewPage(result, c.row, pageCount) {
                        marginNote(p, text, removedColor)
                    }
                case .pageInserted:
                    if let span = c.new.first, span.page < pageCount { marginNote(span.page, loc("Inserted page: {0} doesn't have it.", oldName), insertedColor) }
                case .pageRemoved:
                    guard let span = c.old.first else { continue }
                    // On the next page the new document has, else its last one.
                    let next = result.rows.dropFirst(c.row + 1).first { $0.newPage != nil }?.newPage ?? pageCount - 1
                    if next >= 0 {
                        let note = c.oldText.isEmpty ? loc("Removed page: page {0} of {1} was here (it has no text).", CoreLanguage.number(span.page + 1), oldName)
                            : loc("Removed page: page {0} of {1} was here: “{2}”", CoreLanguage.number(span.page + 1), oldName, quote(c.oldText))
                        marginNote(next, note, removedColor)
                    }
                }
            }
            for area in visual where area.newPage >= 0 && area.newPage < pageCount {
                for box in area.boxes where !box.isEmpty {
                    Annotations.addTextMarkupIn(doc, area.newPage, .highlight, [box], visualColor, note: loc("Looks different in {0}.", oldName), author: author)
                }
                if area.offPage > 0 {
                    let note = area.offPage == 1 ? loc("{1}'s page is larger: {0} area beyond this page's edge looks different.", 1, oldName)
                        : loc("{1}'s page is larger: {0} areas beyond this page's edge look different.", CoreLanguage.number(area.offPage), oldName)
                    marginNote(area.newPage, note, visualColor)
                }
            }
            for page in margin.keys.sorted() {
                guard let notes = margin[page] else { continue }
                Annotations.addNoteIn(doc, page, 6, 6, notes.map(\.text).joined(separator: "\n\n"), author: author, color: notes[0].color)
            }
        }
    }

    /// The new document's page for a change on a row: the row's, else the next one's, else the last before it (a page
    /// only the old document has has none).
    private static func nearestNewPage(_ result: CompareResult, _ row: Int, _ pageCount: Int) -> Int? {
        for r in row..<result.rows.count { if let p = result.rows[r].newPage, p < pageCount { return p } }
        for r in stride(from: row - 1, through: 0, by: -1) { if let p = result.rows[r].newPage, p < pageCount { return p } }
        return nil
    }

    /// Where a note for a position in the text goes: just above the character before it (or after it).
    private static func spot(_ text: PageText, _ caret: Int) -> (x: Double, y: Double)? {
        let rects = caret > 0 ? text.rects(caret - 1, caret) : text.rects(caret, min(text.length, caret + 1))
        guard let r = rects.first else { return nil }
        return (max(0, (caret > 0 ? r.right : r.x) - 10), max(0, r.y - 20))
    }

    private static func quote(_ s: String) -> String {
        let units = Array(s.utf16)
        return units.count <= maxQuote ? s : String(decoding: units[..<maxQuote], as: UTF16.self) + "…"
    }
}
