import Foundation

/// A compare report (the Windows app's `CompareReport`): a copy of the new document with the changes as comments, so it
/// can be saved, shared and read in any viewer. Inserted words get a green highlight, changed words an amber one whose
/// comment quotes the old wording; a note marks where words were removed (quoting them), an inserted page and the place
/// of a removed page; a note on the first page sums it all up. Signed files get the comments appended (signatures stay
/// intact), protected files keep their protection.
public enum CompareReport {
    public static let author = "Inkvolt PDF Compare"

    public static let insertedColor = AnnotColor(0.45, 0.85, 0.4)
    public static let changedColor = AnnotColor(1, 0.72, 0.2)
    public static let removedColor = AnnotColor(0.9, 0.2, 0.2)

    private static let maxQuote = 400

    /// - Parameters:
    ///   - newPages: the new document's text, as compared (for where the changed words are).
    ///   - oldName: the old document's name, for the comments.
    ///   - summary: the first page's note.
    /// - Throws: `OwnerPasswordRequired` when the new document needs its permissions password to be edited.
    public static func annotate(_ newData: [UInt8], _ password: String?, _ result: CompareResult, _ newPages: [PageText], oldName: String,
                                summary: String) throws -> [UInt8] {
        try PageEditor.edit(newData, password) { doc in
            let pageCount = try doc.pageCount()
            // Notes without a place in the text (the summary, removed and inserted pages, removals with no anchor) are
            // gathered into one note per page, in its top-left corner, so any number of them stays on the page.
            var margin: [Int: [(text: String, color: AnnotColor)]] = [:]
            func marginNote(_ page: Int, _ text: String, _ color: AnnotColor) { margin[page, default: []].append((text, color)) }

            if pageCount > 0 { marginNote(0, summary, .yellow) }
            for c in result.changes {
                switch c.kind {
                case .inserted, .changed:
                    for span in c.new where span.page < pageCount && span.page < newPages.count {
                        let rects = newPages[span.page].rects(span.start, span.end)
                        if rects.isEmpty { continue }
                        let note = c.kind == .inserted ? "Inserted (not in \(oldName))" : "Changed. \(oldName) has: “\(quote(c.oldText))”"
                        Annotations.addTextMarkupIn(doc, span.page, .highlight, rects, c.kind == .inserted ? insertedColor : changedColor,
                                                    note: note, author: author)
                    }
                case .deleted:
                    let text = "Removed: “\(quote(c.oldText))”"
                    if let a = c.newAnchor, a.page < pageCount, a.page < newPages.count, let spot = spot(newPages[a.page], a.start) {
                        Annotations.addNoteIn(doc, a.page, spot.x, spot.y, text, author: author, color: removedColor)
                    } else if let p = result.rows[c.row].newPage, p < pageCount {
                        marginNote(p, text, removedColor)
                    }
                case .pageInserted:
                    if let span = c.new.first, span.page < pageCount { marginNote(span.page, "Inserted page: \(oldName) doesn't have it.", insertedColor) }
                case .pageRemoved:
                    guard let span = c.old.first else { continue }
                    // On the next page the new document has, else its last one.
                    let next = result.rows.dropFirst(c.row + 1).first { $0.newPage != nil }?.newPage ?? pageCount - 1
                    if next >= 0 {
                        marginNote(next, "Removed page: page \(span.page + 1) of \(oldName) was here"
                            + (c.oldText.isEmpty ? " (it has no text)." : ": “\(quote(c.oldText))”"), removedColor)
                    }
                }
            }
            for page in margin.keys.sorted() {
                guard let notes = margin[page] else { continue }
                Annotations.addNoteIn(doc, page, 6, 6, notes.map(\.text).joined(separator: "\n\n"), author: author, color: notes[0].color)
            }
        }
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
