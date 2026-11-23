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
        let found = found
        let (data, password) = (session.data, session.password)
        let tool: Tool = kind == .highlight ? .highlight : kind == .underline ? .underline : .strikeOut
        let color = pages.styles.style(tool).color ?? SearchMarks.colorOf(kind)
        let author = editor.author
        let query = foundQuery
        startLongTask {
            // The matches' boxes come from each page's text, read off the main thread (a page not read since the search
            // takes a moment), with progress and Cancel; then what marking them would do is counted.
            let sheet = ProgressSheet(title: loc("Marking the matches"), text: loc("Starting…"))
            if let window = self.window, window.attachedSheet == nil { sheet.begin(on: window) }
            defer { sheet.end() }
            let cancel = sheet.token
            let hits: [HitToMark], planned: SearchMarksCount
            do {
                (hits, planned) = try await Task.detached { () throws -> ([HitToMark], SearchMarksCount) in
                    var hits: [HitToMark] = []
                    var page = -1
                    var text: PageText?
                    for f in found {
                        try cancel.check()
                        if f.page != page {
                            page = f.page
                            text = try? engine.text(f.page, cancel: cancel)
                            let shown = f.page
                            Task { @MainActor in
                                sheet.update(loc("Page {0} of {1}", CoreLanguage.number(shown + 1), CoreLanguage.number(engine.pageCount)),
                                             Double(shown) / Double(max(engine.pageCount, 1)))
                            }
                        }
                        if let text { hits.append(HitToMark(f.page, text.rects(f.start, f.end))) }
                    }
                    try cancel.check()
                    return (hits, try SearchMarks.count(data, password, hits, kind))
                }.value
            } catch is CancellationError {
                return
            } catch {
                Report.progress("Mark All Matches couldn't read the document: \(error)")
                self.notify(loc("Couldn't mark the matches: the document couldn't be read."))
                return
            }
            sheet.end()
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
