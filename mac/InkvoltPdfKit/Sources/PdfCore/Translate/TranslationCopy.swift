import CryptoKit
import Foundation
import PrintCore

extension Translation {
    /// The most comments left in a copy: a crafted file can't fill the Comments pane with hundreds of thousands. The
    /// report still counts them all.
    private static let maxNotes = 2_000, maxNotesOnPage = 100

    /// A longer "paragraph" (a crafted page's single stretch of text) isn't sent or even cut into pieces.
    static let maxParagraphChars = 100_000

    private static let maxRunsToLayOut = 5_000

    /// Reads the pages' paragraphs. Pages that can't be read are noted; nothing is sent. `progress`: pages read so far.
    /// - Throws: `CancellationError` when `cancel` fired; `OwnerPasswordRequired` when the file was opened without its
    ///   permissions password, which a copy that changes its text needs. (Windows also refuses an AES-256 file opened
    ///   with its permissions password alone; MuPDF keeps the encryption as it was without the open password, see
    ///   `KeptProtection`.)
    public static func makePlan(_ data: [UInt8], _ password: String?, _ pages: [Int], progress: ((Int) -> Void)? = nil, cancel: CancelToken? = nil,
                                openPassword: String? = nil, dropOpenPassword: Bool = false) throws -> TranslationPlan {
        // Opened as for the edit: a file that needs a password for that says so now, before anything is sent, not after
        // hours of translating.
        let doc = try PdfEdit.open(data, password, failure: loc("This PDF can't be edited"))
        var openPassword = openPassword
        if (openPassword ?? "").isEmpty, !(password ?? "").isEmpty, PdfSecurity.isOpenPassword(data, password) { openPassword = password }
        // Without the engine no tables are found and pictures only from the content: paragraphs still are.
        let engine = try? PdfEngine.open(data, password: password)
        let count = try doc.pageCount()
        var plans: [TranslationPagePlan] = []
        var texts: [(text: String, page: Int)] = []
        var seen = Set<String>(), marked = Set<String>()
        var blocked: [(page: Int, why: String)] = []
        var scans: [Int] = [], turned: [Int] = [], crowded: [Int] = [], unreadable: [Int] = []
        var paragraphs = 0, noWords = 0
        for (done, p) in pages.enumerated() {
            try cancel?.check()
            progress?(done)
            if p < 0 || p >= count { continue }
            do {
                let page = doc.page(p)
                let content = try ContentEditor.readRaw(doc, page, p, cancel)
                if content.runs.count > ContentEditor.maxRunsToTranslate {
                    crowded.append(p)
                    continue
                }
                let (cells, obstacles, turnedCells) = surroundings(engine, page, p, content, cancel)
                let (width, height) = ContentEditor.displaySize(page)
                let parts = ContentEditor.turnedParts(content, width, height, turnedCells)
                let slots = try ContentEditor.translationSlots(content, cells, cancel, parts)
                var pageHasWords = false
                for slot in slots {
                    let t = slot.paragraph
                    if t.text.utf16.count > maxParagraphChars {
                        blocked.append((p, loc("it is far too long to be one paragraph")))
                        continue
                    }
                    if !TranslationText.hasWords(t.text) {
                        noWords += 1
                        continue
                    }
                    if let why = t.blocked {
                        if !ContentEditor.isInvisible(why) { blocked.append((p, why)) }
                        continue
                    }
                    pageHasWords = true
                    paragraphs += 1
                    let k = key(t)
                    if seen.insert(k).inserted { texts.append((k, p)) }
                    if k != t.text { marked.insert(k) } // mark gives back the text as it is when it doesn't mark it
                }
                if !pageHasWords && !content.images.isEmpty && (content.runs.isEmpty || content.runs.allSatisfy { ContentEditor.isInvisible($0.blocked) }) {
                    scans.append(p)
                }
                // Turned text no slot holds (at an angle other than a quarter turn, mirrored or slanted) stays as it is.
                let inSlots = Set(slots.flatMap { $0.paragraph.runs.map(\.key) })
                if content.runs.contains(where: { abs($0.angle) >= 0.5 && TranslationText.hasWords($0.text) && !inSlots.contains($0.key) }) { turned.append(p) }
                var plan = TranslationPagePlan(p, cells, obstacles)
                plan.turnedCells = turnedCells
                plans.append(plan)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unreadable.append(p)
            }
        }
        var plan = TranslationPlan(data: data, pages: plans, texts: texts)
        plan.password = password
        plan.openPassword = openPassword
        plan.dropOpenPassword = dropOpenPassword
        plan.marked = marked
        plan.paragraphCount = paragraphs
        plan.noWords = noWords
        plan.blocked = blocked
        plan.scanPages = scans
        plan.turnedTextPages = turned
        plan.crowdedPages = crowded
        plan.unreadablePages = unreadable
        return plan
    }

    /// A page's table cells (from Export to Word's analysis) and the pictures, vector figures, rules and form fields its
    /// text must keep clear of; the cells of tables set sideways, found the same way with the page turned so their text
    /// reads left to right, by quarter turn, in that frame.
    private static func surroundings(_ engine: PdfEngine?, _ page: PObj, _ pageIndex: Int, _ content: PageContent, _ cancel: CancelToken?)
        -> (cells: [RectD], obstacles: [RectD], turned: [Int: [RectD]]) {
        var turned: [Int: [RectD]] = [:]
        // The boxes a form's fields fill in: on the page though not in its content.
        var fields: [RectD] = []
        for a in page.array("Annots")?.elements ?? [] where fields.count < maxRunsToLayOut && a.isDict && a.name("Subtype") == "Widget" {
            if let rect = a.array("Rect"), rect.count >= 4 { fields.append(PageBoxes.rectToPage(page, rect)) }
        }
        guard let engine else { return ([], fields, turned) }
        // A page this crowded isn't worth laying out (its time grows much faster than its text): no tables found, as on a map.
        if content.runs.count > maxRunsToLayOut { return ([], fields, turned) }
        guard let export = try? engine.exportPage(pageIndex, images: true, cancel: cancel, boxesOnly: true) else { return ([], fields, turned) }
        let obstacles = export.rules + export.images.map(\.box) + fields
        let body = DocLayout.bodySize([export])
        func cellsOf(_ p: ExportPage) -> [RectD] {
            var cells: [RectD] = []
            for block in DocLayout.layOut(p, body).blocks {
                if case .table(let t) = block { cells += cellsOfTable(t) }
            }
            return cells.count > 4_000 ? [] : cells
        }
        var upright = export
        upright.lines = export.lines.filter { $0.reads == 0 }
        let cells = cellsOf(upright)
        // A table set sideways: its direction's lines with the page's rules and pictures, turned to read left to right.
        for turn in 1...3 {
            var sideways = export
            sideways.lines = export.lines.filter { $0.reads == turn }
            if sideways.lines.contains(where: { $0.text.unicodeScalars.contains(where: TranslationText.isLetter) }) {
                turned[turn] = cellsOf(sideways.turned(turn))
            }
        }
        return (cells, obstacles, turned)
    }

    /// Each cell with text in it, as a box: its columns from the table's widths, its row from the row heights when the
    /// rules give them, else down to the next row's text. A cell that is the only one with text on its row takes the empty
    /// cells after it too (a label heading the rows under it, as the census's "Income percentile ratios:"): a longer
    /// translation has that room rather than shrinking in its column. A rule between them still stops it (`room`).
    static func cellsOfTable(_ t: DocTable) -> [RectD] {
        var xs = [t.box.x]
        for w in t.columnWidths { xs.append(xs[xs.count - 1] + w) }
        var out: [RectD] = []
        var y = t.box.y
        for (r, row) in t.rows.enumerated() {
            let top: Double, bottom: Double
            if let heights = t.rowHeights, heights.count == t.rows.count {
                top = y
                y += heights[r]
                bottom = y
            } else {
                let boxes = row.flatMap(\.paragraphs).map(\.box)
                if boxes.isEmpty { continue }
                top = boxes.map(\.y).min()!
                let lowest = boxes.map(\.bottom).max()!
                let below = t.rows.dropFirst(r + 1).flatMap { $0 }.flatMap(\.paragraphs).map(\.box.y).min() ?? max(t.box.bottom, lowest)
                bottom = max(below, lowest)
            }
            var col = 0
            // A label alone on its row: the only cell with text there.
            var alone = -1
            for (c, cell) in row.enumerated() where !cell.paragraphs.isEmpty { alone = alone == -1 ? c : -2 }
            for (c, cell) in row.enumerated() {
                let span = max(cell.colSpan, 1)
                let end = c == alone ? xs.count - 1 : min(col + span, xs.count - 1)
                if !cell.paragraphs.isEmpty && end > col && bottom > top { out.append(.fromEdges(xs[col], top, xs[end], bottom)) }
                col = min(col + span, xs.count - 1)
            }
        }
        return out
    }

    /// A paragraph's text as it is sent, and its answer kept: with its looks as markup (`TranslationMarkup`).
    static func key(_ p: TextParagraph) -> String { TranslationMarkup.mark(p.text, p.spans) }

    /// Writes the translated copy from the plan's bytes (which stay as they are): each page's paragraphs in their boxes, a
    /// comment on each paragraph that doesn't fit or stays untranslated. A page that fails stays as it was and is
    /// reported. `progress`: pages written so far.
    public static func apply(_ plan: TranslationPlan, _ answers: TranslationAnswers, _ languageTag: String?, noteAuthor: String = "Inkvolt PDF translation",
                             progress: ((Int) -> Void)? = nil, cancel: CancelToken? = nil) throws -> TranslationResult {
        var report = TranslationReport()
        report.cancelled = answers.cancelled
        report.stoppedBecause = answers.stoppedBecause
        report.scanPages = plan.scanPages
        report.turnedTextPages = plan.turnedTextPages
        report.crowdedPages = plan.crowdedPages
        report.noWords = plan.noWords
        report.failedPages = plan.unreadablePages
        if answers.done.isEmpty {
            report.notTranslated = plan.paragraphCount + plan.blocked.count
            return TranslationResult(data: nil, report: report)
        }

        let doc = try PdfEdit.open(plan.data, plan.password, failure: loc("This PDF can't be edited"))
        let hash = SHA256.hash(data: Data(plan.data)).prefix(4).map { String(format: "%02X", $0) }.joined()
        let writer = ContentEditor.TranslationWriter(doc, hash)
        for (done, page) in plan.pages.enumerated() {
            try cancel?.check()
            progress?(done)
            var flagged: [TranslationFlag] = []
            var translated = 0, shrunk = 0, unfit = 0, unchanged = 0, untranslated = 0
            do {
                let (slots, written, refused) = try ContentEditor.translatePage(writer, page.page, page.cells, page.obstacles, { _, p in
                    if !TranslationText.hasWords(p.text) { return nil }
                    let k = key(p)
                    if p.blocked != nil { return answers.done[k] ?? p.text } // refused below, with its reason
                    guard let text = answers.done[k] else { return nil }
                    if TranslationMarkup.echoes(text, p.text, k) {
                        unchanged += 1
                        return nil
                    }
                    return text
                }, cancel, turnedCells: page.turnedCells)
                var wrote: [Int: TranslationWritten] = [:]
                for w in written { wrote[w.slot] = w }
                var no: [Int: TranslationRefused] = [:]
                for r in refused { no[r.slot] = r }
                for (i, slot) in slots.enumerated() {
                    let p = slot.paragraph
                    if !TranslationText.hasWords(p.text) { continue }
                    if let w = wrote[i] {
                        translated += 1
                        if w.fit < 0.999 { shrunk += 1 }
                        if !w.fits {
                            unfit += 1
                            flagged.append(TranslationFlag(kind: .doesNotFit, page: page.page, box: p.box,
                                                           message: loc("This translated paragraph doesn't fit its box even at the smallest size: it may run over what follows.")))
                        }
                        if !w.dropped.isEmpty {
                            let n = CoreLanguage.number(w.dropped.count)
                            let message = w.dropped.count == 1
                                ? loc("No font on this Mac has {0} character of this translation, so it was left out.", n)
                                : loc("No font on this Mac has {0} characters of this translation, so they were left out.", n)
                            flagged.append(TranslationFlag(kind: .charactersLeftOut, page: page.page, box: p.box, message: message))
                        }
                    } else if let r = no[i] {
                        if ContentEditor.isInvisible(r.why) { continue }
                        untranslated += 1
                        flagged.append(TranslationFlag(kind: .notTranslated, page: page.page, box: p.box, message: loc("This paragraph isn't translated: {0}.", r.why)))
                    } else {
                        let k = key(p)
                        if let same = answers.done[k], TranslationMarkup.echoes(same, p.text, k) { continue } // counted as unchanged
                        untranslated += 1
                        let tooLong = p.text.utf16.count > maxParagraphChars
                        let reached = answers.failed[k] != nil || tooLong
                        let why = answers.failed[k]
                            ?? (tooLong ? loc("it is far too long to be one paragraph")
                                : answers.cancelled ? loc("the translation was stopped first")
                                : answers.stoppedBecause != nil ? loc("the endpoint stopped answering first")
                                : loc("it got no answer"))
                        flagged.append(TranslationFlag(kind: .notTranslated, page: page.page, box: p.box, message: loc("This paragraph isn't translated: {0}.", why),
                                                       noted: reached))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Nothing on this page was written (see translatePage): it stays in the original language.
                report.failedPages.append(page.page)
                continue
            }
            report.translated += translated
            report.shrunk += shrunk
            report.doNotFit += unfit
            report.unchanged += unchanged
            report.notTranslated += untranslated
            report.flags += flagged
        }
        writer.finish()
        report.fonts += writer.fontNames

        if report.translated == 0 { return TranslationResult(data: nil, report: report) }

        var byPage: [Int: [TranslationFlag]] = [:]
        var pageOrder: [Int] = []
        for f in report.flags where f.noted {
            if byPage[f.page] == nil { pageOrder.append(f.page) }
            byPage[f.page, default: []].append(f)
        }
        for p in pageOrder {
            let (pageWidth, _) = ContentEditor.displaySize(doc.page(p))
            for flag in byPage[p]!.prefix(maxNotesOnPage) {
                if report.notes >= maxNotes { break }
                Annotations.addNoteIn(doc, p, min(flag.box.right + 2, max(0, pageWidth - 22)), flag.box.y, flag.message, author: noteAuthor)
                report.notes += 1
            }
        }
        if let tag = languageTag, !tag.isEmpty {
            doc.catalog.set("Lang", doc.text(tag))
        } else {
            doc.catalog.remove("Lang") // it isn't the original's language any more
        }
        try doc.checkFailure()

        // A copy: when a signed original can't be appended to (it is encrypted, say) the copy is rewritten and its
        // signature stops verifying, which is the truth about it. Refusing here would throw away a translation that may
        // have taken hours.
        let bytes = try KeptProtection.run(openPassword: plan.openPassword, dropOpenPassword: plan.dropOpenPassword) {
            try SignedEdits.run({ try PdfEdit.save(doc, original: plan.data, password: plan.password) }, allowRewrite: true).0
        }
        return TranslationResult(data: bytes, report: report)
    }
}
