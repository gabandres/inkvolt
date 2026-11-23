import AppKit
import PdfCore
import PrintCore

/// Mark All Matches (roadmap 4.18; Windows' `DocumentTab.SearchMarks`): every match of the search the Find bar just made
/// highlighted, underlined or struck out as comments, one undo step (`SearchMarks`); then the same search runs again on
/// the marked document, so its matches stay listed for another kind of mark. Edit › Find › Highlight, Underline and
/// Strike Out All Matches, enabled while Find has matches.
extension DocumentWindowController {
    @objc func highlightAllMatches(_ sender: Any?) { markAllMatches(.highlight) }
    @objc func underlineAllMatches(_ sender: Any?) { markAllMatches(.underline) }
    @objc func strikeOutAllMatches(_ sender: Any?) { markAllMatches(.strikeOut) }

    func markAllMatches(_ kind: TextMarkupKind) {
        guard let session = pdf.session else { return }
        guard !found.isEmpty else {
            notify(foundQuery.isEmpty ? loc("Search for the words to mark, then choose it again.") : loc("The search found nothing to mark."))
            return
        }
        let engine = engine
        let hits: [HitToMark] = found.compactMap { f in
            guard let text = try? engine.text(f.page) else { return nil }
            return HitToMark(f.page, text.rects(f.start, f.end))
        }
        let (data, password) = (session.data, session.password)
        let tool: Tool = kind == .highlight ? .highlight : kind == .underline ? .underline : .strikeOut
        let color = pages.styles.style(tool).color ?? SearchMarks.colorOf(kind)
        let author = editor.author
        let query = foundQuery
        startLongTask {
            let planned: SearchMarksCount
            do {
                planned = try await Task.detached { try SearchMarks.count(data, password, hits, kind) }.value
            } catch {
                Report.progress("Mark All Matches couldn't read the document: \(error)")
                self.notify(loc("Couldn't mark the matches: the document couldn't be read."))
                return
            }
            guard self.pdf.session?.data == data else { return } // changed meanwhile: the matches are gone with it
            if planned.marked == 0 {
                self.notify(planned.alreadyMarked > 0 ? loc("Every match is marked already.") : loc("The search found nothing to mark."))
                return
            }
            // The undo step is named after the marks made, not the matches found.
            let n = planned.marked
            let label = switch kind {
            case .underline: n == 1 ? loc("Underline 1 match") : loc("Underline {0} matches", CoreLanguage.number(n))
            case .strikeOut: n == 1 ? loc("Strike out 1 match") : loc("Strike out {0} matches", CoreLanguage.number(n))
            default: n == 1 ? loc("Highlight 1 match") : loc("Highlight {0} matches", CoreLanguage.number(n))
            }
            let done = MarkCount()
            let made = await self.editor.run(label) { d, pw in
                let r = try SearchMarks.apply(d, pw, hits, kind, author: author, color: color)
                done.value = r.count
                return r.data
            }
            guard let count = done.value else { return }
            if self.editor.lastOutcome == .noChange { return self.notify(loc("Every match is marked already.")) }
            guard made else { return }
            // Matches past the limit, and pages with more marks than were read (a match under the rest is marked again): said.
            var notes: [String] = []
            if count.limited > 0 {
                notes.append(loc("Marked the first {0} of {1} matches; choose it again for the rest.",
                                 CoreLanguage.number(count.marked), CoreLanguage.number(count.marked + count.limited)))
            }
            if count.pagesNotAllRead > 0 {
                notes.append(count.pagesNotAllRead == 1
                    ? loc("1 page already had more marks than are read: a match under one of the others may be marked twice.")
                    : loc("{0} pages already had more marks than are read: a match under one of the others may be marked twice.",
                          CoreLanguage.number(count.pagesNotAllRead)))
            }
            if !notes.isEmpty { self.notify(notes.joined(separator: " "), canUndo: true) }
            // The edit cleared the matches: search again, staying where the view is.
            self.findAgain(query)
        }
    }
}

/// What the edit counted, handed from its worker back to the window.
private final class MarkCount: @unchecked Sendable {
    var value: SearchMarksCount?
}
