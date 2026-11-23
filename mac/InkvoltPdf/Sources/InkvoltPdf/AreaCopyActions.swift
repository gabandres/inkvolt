import AppKit
import PdfCore
import PrintCore

/// What Copy Text from Area and Copy Area as Table take from a Snapshot box.
enum AreaCopyKind { case text, table }

/// The last box drawn with Snapshot (pdf/GLOSSARY.md "Snapshot area"), for the document as it was then (its engine).
struct SnapshotArea {
    weak var engine: PdfEngine?
    let page: Int
    let region: RectD
}

/// Copy Text from Area and Copy Area as Table (roadmap 4.6; Windows' `DocumentTab.AreaCopy`): the words in the last
/// Snapshot box, or in the next one drawn, put on the clipboard: the page's text there, else the box read by Vision. As a
/// table, tab-separated text and an HTML table, so Numbers, Excel and Pages paste it as cells. Edit › Copy Text from Area,
/// Copy Area as Table; the snapshot's notice offers Copy text.
extension DocumentWindowController {
    @objc func copyTextFromArea(_ sender: Any?) { copyFromArea(.text) }
    @objc func copyAreaAsTable(_ sender: Any?) { copyFromArea(.table) }

    private func copyFromArea(_ kind: AreaCopyKind) {
        if let area = snapshotArea, let engine = area.engine, engine === self.engine {
            return copyArea(kind, engine, page: area.page, area: area.region)
        }
        // No box yet (or the document changed since): the next one drawn with Snapshot.
        pendingAreaCopy = kind
        pickTool(.snapshot)
        notify(kind == .table ? loc("Drag a box around the table to copy.") : loc("Drag a box around the text to copy."))
    }

    /// Copies the words in `area` of `page`, read off the main thread (recognized when the page has no text there).
    func copyArea(_ kind: AreaCopyKind, _ engine: PdfEngine, page: Int, area: RectD) {
        snapshotCancel?.cancel()
        let cancel = CancelToken()
        snapshotCancel = cancel
        let recognizer: any TextRecognizer = VisionRecognizer()
        Task { @MainActor [weak self] in
            let reading = Task { @MainActor [weak self] in
                // Said only when it takes a while (recognition the first time on a Mac loads its model).
                try await Task.sleep(for: .milliseconds(600))
                self?.notify(loc("Reading the text in the box…"))
            }
            let made = await Task.detached(priority: .userInitiated) { () -> Result<AreaCopied, any Error> in
                Result { try Self.read(kind, engine, page, area, recognizer, cancel) }
            }.value
            reading.cancel()
            guard let self, !cancel.isCancelled else { return } // a newer copy took its place
            snapshotCancel = nil
            switch made {
            case .success(let copied):
                notify(Self.put(copied, on: SnapshotBoard.board))
            case .failure(let error):
                Report.progress("Copy from area failed: \(error)")
                notify(loc("Couldn't read that part of the page."))
            }
        }
    }

    /// What an area gave: its text, its table (Copy Area as Table), whether it was read from the picture, its word count.
    struct AreaCopied: Sendable {
        let text: String
        let table: AreaTable?
        let fromScan: Bool
        let words: Int
    }

    nonisolated private static func read(_ kind: AreaCopyKind, _ engine: PdfEngine, _ page: Int, _ area: RectD,
                                         _ recognizer: any TextRecognizer, _ cancel: CancelToken) throws -> AreaCopied {
        let all = try engine.exportPage(page, images: false, cancel: cancel)
        var clipped = AreaCopy.clip(all, area)
        var fromScan = false
        if !clipped.hasText {
            let words = try AreaCopy.recognize(engine, page, area, recognizer, cancel: cancel)
            clipped = AreaCopy.fromWords(all, words)
            fromScan = true
        }
        try cancel.check()
        let table = kind == .table ? try AreaCopy.table(clipped, cancel: cancel) : nil
        let text = AreaCopy.text(clipped)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return AreaCopied(text: text, table: table, fromScan: fromScan, words: words)
    }

    /// Puts what was copied on `board` and says what: a table as tab-separated text and HTML, else the text.
    static func put(_ copied: AreaCopied, on board: NSPasteboard) -> String {
        if let table = copied.table, !table.tooLarge, !table.isEmpty {
            board.declareTypes([.string, .html], owner: nil)
            board.setString(table.tsv(), forType: .string)
            board.setString(table.html(), forType: .html)
            return loc("Table copied ({0} × {1}): paste it into Numbers, Excel or Pages",
                       CoreLanguage.number(table.rows.count), CoreLanguage.number(table.columnCount))
        }
        if copied.text.isEmpty { return loc("No text found in that box.") }
        board.declareTypes([.string], owner: nil)
        board.setString(copied.text, forType: .string)
        let n = copied.words
        var done = copied.fromScan
            ? (n == 1 ? loc("Text read from the scan and copied (1 word)") : loc("Text read from the scan and copied ({0} words)", CoreLanguage.number(n)))
            : (n == 1 ? loc("Text copied (1 word)") : loc("Text copied ({0} words)", CoreLanguage.number(n)))
        if copied.table?.tooLarge == true {
            done = loc("More than {0} cells for a table: copied as text.", CoreLanguage.number(AreaCopy.maxCells)) + " " + done
        }
        return done
    }
}
