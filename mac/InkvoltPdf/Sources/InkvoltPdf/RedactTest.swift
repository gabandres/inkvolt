import AppKit
import PdfCore

/// The self-test's scenario for E1 (`--edit`, after `PagesTest`, and after `FeatureTest` for the synthetic form): the
/// Redact tool from its menu item, an area dragged and clicked away through the page view's own mouse handling, the
/// redaction bar's buttons; a word's selection and its search matches marked; Redact by Pattern through its sheet (a bad
/// expression refused first); Apply from the bar (the pages become pictures, their text recognized again, the check
/// after it); on the synthetic document a dark box drawn over a word, found by Check Redaction and fixed from its report;
/// Sanitize Document through its sheet. Every result saved into a temporary folder and read back, then undone. Only
/// counts and kinds are written, never a document's text or its name.
@MainActor
struct RedactTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0
    private let synthetic: Bool
    private let shots: Bool
    private let folder: String

    init(controller: DocumentWindowController, name: String, openedFrom path: String?) {
        self.controller = controller
        self.name = name
        synthetic = path != nil && path == Report.syntheticPath
        shots = Report.snapshots != nil && synthetic
        folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-redact-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private var pages: PagesView { controller.pages }
    private var editor: DocumentEditor { controller.editor }
    private var session: DocumentSession? { controller.pdf.session }
    private var bar: RedactBar { controller.redactBar }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private mutating func skip(_ what: String) { lines.append("SKIP \(what)") }

    // MARK: Driving the app

    private func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: pages.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// A press through `points` on `page` (page space), as the mouse makes it.
    private func press(_ page: Int, _ points: [PointD]) async {
        let r = pages.pageRects[page]
        let view = points.map { pages.viewPoint($0, r) }
        pages.mouseDown(with: event(.leftMouseDown, view[0]))
        for p in view.dropFirst() { pages.mouseDragged(with: event(.leftMouseDragged, p)) }
        pages.mouseUp(with: event(.leftMouseUp, view[view.count - 1]))
        await settle()
    }

    private func settle() async {
        await pages.pendingEdit?.value
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// Waits for the long task a command started, then for the check or fix that may follow it.
    private func waitTasks() async {
        for _ in 0..<2400 where controller.longTask != nil || controller.redaction.task != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func send(_ action: Selector) { NSApp.sendAction(action, to: controller, from: nil) }

    private func path(_ file: String) -> URL { URL(fileURLWithPath: (folder as NSString).appendingPathComponent(file)) }

    /// Saves through NSDocument (Save As) into this test's folder; the bytes read back, or nil.
    private func saveAs(_ file: String) async -> [UInt8]? {
        let url = path(file)
        let error = await withCheckedContinuation { (done: CheckedContinuation<Error?, Never>) in
            controller.pdf.save(to: url, ofType: "com.adobe.pdf", for: .saveAsOperation) { done.resume(returning: $0) }
        }
        guard error == nil, let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }

    private func undo(_ label: String) -> Bool {
        guard session?.undoLabel == label else { return false }
        controller.pdf.undo()
        return true
    }

    private mutating func snapshot(_ view: NSView?, _ file: String) {
        guard shots, let view, let dir = Report.snapshots else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return check(false, "snapshot \(file): no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        let ok = (try? png?.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(file)))) != nil
        check(ok, "snapshot \(file): \(rep.pixelsWide) x \(rep.pixelsHigh) px")
    }

    private func wholeWordHits(_ word: String, _ page: Int) -> Int {
        (try? controller.engine.text(page))?.find(word, matchCase: false, wholeWord: true).count ?? 0
    }

    /// The matches of `word` in `text` whose middle lies in one of `marks` (what the redaction blacked out).
    private static func under(_ word: String, _ text: PageText?, _ marks: [RectD]) -> Int {
        guard let text else { return 0 }
        return text.find(word, matchCase: false, wholeWord: true).filter { hit in
            text.rects(hit.start, hit.end).contains { r in marks.contains { $0.inflate(1).contains(r.centerX, r.centerY) } }
        }.count
    }

    // MARK: The scenario

    mutating func run() async {
        guard session != nil else {
            Report.write("== \(name): redaction, check, sanitize\nRESULT: FAIL (no session)")
            return
        }
        let started = Date()
        lines.append("== \(name): redaction, check, sanitize (\(controller.engine.pageCount) pages)")
        controller.closePopovers()
        controller.setZoom(1)
        controller.go(0)
        // A word of the first page with text (whole word, at least four letters), for the selection, search and pattern.
        var target: (page: Int, word: String, start: Int, end: Int)?
        for p in 0..<min(controller.engine.pageCount, 10) {
            guard let t = try? controller.engine.text(p), let w = SelfTest.pickWord(t.text),
                  let hit = t.find(w, matchCase: true, wholeWord: true).first else { continue }
            target = (p, w, hit.start, hit.end)
            break
        }
        await marking(target)
        await patterns(target)
        await apply(target)
        if synthetic { await badRedaction() } else { skip("check and fix a dark box over text: synthetic document only") }
        await sanitize()
        pages.clearRedactions()
        if pages.tool == .redact { pages.tool = .hand }
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
        Report.note("redaction took \(Int(Date().timeIntervalSince(started))) s")
    }

    // MARK: Marking

    private mutating func marking(_ target: (page: Int, word: String, start: Int, end: Int)?) async {
        pages.clearRedactions()
        let item = NSMenuItem()
        item.tag = Tool.redact.rawValue
        controller.chooseTool(item)
        check(pages.tool == .redact && !bar.isHidden && bar.label.stringValue.hasPrefix("Drag over") && !bar.apply.isEnabled,
              "Redact tool from its menu item: the redaction bar shows, Apply disabled with nothing marked")

        let g = controller.engine.page(0)
        let a = PointD(g.width * 0.1, g.height * 0.1), b = PointD(g.width * 0.35, g.height * 0.16)
        let mid = PointD((a.x + b.x) / 2, (a.y + b.y) / 2)
        await press(0, [a, mid, b])
        let one = pages.redactions.count == 1 && bar.label.stringValue.hasPrefix("1 area on 1 page") && bar.apply.isEnabled
        await press(0, [mid])
        let none = pages.redactions.isEmpty
        await press(0, [a, mid, b])
        let again = pages.redactions.count == 1
        snapshot(controller.window?.contentView, "e1-01-mark.png")
        bar.clear.performClick(nil)
        check(one && none && again && pages.redactions.isEmpty,
              "an area dragged with the Redact tool is marked, a click on it unmarks it; Clear Marks from the bar")

        guard let t = target else { return skip("selection and search marked: no text") }
        guard let text = try? controller.engine.text(t.page) else { return }
        pages.select(t.page, (t.start, t.end))
        let expected = text.rects(t.start, t.end).count
        send(#selector(DocumentWindowController.redactSelectedText(_:)))
        check(pages.redactions.count == expected && pages.selectedText == nil,
              "Redact Selected Text: \(pages.redactions.count) mark for a \(t.word.count)-letter word, the selection cleared")
        pages.clearRedactions()

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controller.onFindFinished = { done.resume() }
            controller.find(t.word)
        }
        controller.onFindFinished = nil
        let hits = controller.found.count
        let shown = !bar.matches.isHidden
        bar.matches.performClick(nil)
        let marked = pages.redactions.count
        controller.find("")
        check(hits > 0 && shown && marked >= hits, "search matches marked from the bar: \(hits) matches, \(marked) marks")
        pages.clearRedactions()
    }

    // MARK: Redact by Pattern

    private mutating func patterns(_ target: (page: Int, word: String, start: Int, end: Int)?) async {
        send(#selector(DocumentWindowController.redactByPattern(_:)))
        guard let sheet = controller.redaction.patternSheet else { return check(false, "Redact by Pattern sheet shown") }
        snapshot(sheet.window?.contentView, "e1-02-patterns.png")
        for c in sheet.checks { c.box.state = .off }
        sheet.phrases.string = ""
        sheet.expression.stringValue = "CASE-("
        sheet.findClicked()
        let refused = !sheet.problem.isHidden && sheet.problem.stringValue.contains("near character") && controller.redaction.patternSheet != nil
        sheet.expression.stringValue = ""
        sheet.findClicked()
        let empty = sheet.problem.stringValue.hasPrefix("Choose something") && controller.redaction.patternSheet != nil
        guard let t = target else {
            sheet.cancelClicked()
            return check(refused && empty && controller.redaction.patternSheet == nil, "Redact by Pattern: a bad pattern and nothing chosen refused, Cancel")
        }
        sheet.phrases.string = t.word
        sheet.wholeWord.state = .on
        sheet.findClicked()
        await waitTasks()
        let expected = (try? RedactionPatterns.find(controller.engine, RedactionPatternOptions(patterns: [], phrases: [t.word])))?.reduce(0) { $0 + $1.rects.count } ?? -1
        let marked = pages.redactions.count
        let notice = controller.noticeBar.message.hasPrefix("Marked")
        if marked != expected || marked == 0 {
            let p = RedactionState.lastPatterns
            lines.append("  (patterns \(p.patterns.count), phrases \(p.phrases.map(\.count)), whole \(p.wholeWord), case \(p.matchCase), "
                + "expression \(p.expression?.count ?? -1); expected \(expected); word on page \(t.page + 1): \(wholeWordHits(t.word, t.page)))")
        }
        check(refused && empty && controller.redaction.patternSheet == nil && marked == expected && marked > 0 && pages.tool == .redact && notice,
              "Redact by Pattern (its sheet; a bad pattern and nothing chosen refused first): a word's \(marked) matches marked, the Redact tool on")
    }

    // MARK: Apply

    private mutating func apply(_ target: (page: Int, word: String, start: Int, end: Int)?) async {
        if pages.redactions.isEmpty {
            let g = controller.engine.page(0)
            await press(0, [PointD(g.width * 0.1, g.height * 0.1), PointD(g.width * 0.4, g.height * 0.2)])
        }
        let marks = pages.redactions
        guard !marks.isEmpty else { return check(false, "areas to apply") }
        let marked = Array(Set(marks.map(\.page))).sorted()
        let label = marks.count == 1 ? "Redact 1 area" : "Redact \(marks.count) areas"
        let before = controller.editor.finishedEdits
        bar.apply.performClick(nil)
        await waitTasks()
        let applied = session?.undoLabel == label && controller.editor.finishedEdits > before && pages.redactions.isEmpty && bar.isHidden
        // Nothing of the word under the marks is in the pages' text now (the recognized text included; the word may still
        // be where the page search didn't find it whole, as in a word run into the next one, and is read there again).
        var markRects: [Int: [RectD]] = [:]
        for m in marks { markRects[m.page, default: []].append(m.rect) }
        let gone = target.map { t in marked.allSatisfy { p in Self.under(t.word, try? controller.engine.text(p), markRects[p] ?? []) == 0 } } ?? true
        let report = controller.redaction.lastReport
        let reportShown = controller.redaction.reportSheet != nil
        let checked = report.map { $0.isClean ? controller.noticeBar.history.contains { $0.hasPrefix("Redaction checked") } : reportShown } ?? false
        let kinds = Set(report?.findings.map(\.kind) ?? []).map { RedactionCheck.name($0) }.sorted().joined(separator: ", ")
        if !(applied && gone && checked) {
            for f in report?.findings ?? [] { lines.append("  (found: \(RedactionCheck.name(f.kind)) · \(f.place), \(f.text.count) characters, fix \(f.fix))") }
        }
        check(applied && gone && checked, "Apply Redactions from the bar: “\(label)” on \(marked.count) page(s), the word gone from under the marks; "
              + "checked afterwards: \(report.map { $0.isClean ? "clean" : "\($0.findings.count) found (\(kinds))" } ?? "no report")")
        if let sheet = controller.redaction.reportSheet {
            snapshot(sheet.window?.contentView, "e1-03-report.png")
            sheet.closeClicked()
        }
        if synthetic {
            // The rest of the redacted page was recognized again: its words can still be found.
            let words = (try? controller.engine.text(marked[0]))?.text.split(whereSeparator: { $0.isWhitespace }).count ?? 0
            check(words > 3, "the redacted page's other text recognized again (\(words) words) and still searchable")
        }

        if let saved = await saveAs("redacted.pdf") {
            let password = session?.password
            let engine = try? PdfEngine.open(saved, password: password)
            let images = marked.allSatisfy { p in !((try? ContentEditor.read(saved, password, p))?.images.isEmpty ?? true) }
            var stillGone = true
            if let t = target, let engine {
                stillGone = marked.allSatisfy { p in Self.under(t.word, try? engine.text(p), markRects[p] ?? []) == 0 }
            }
            engine?.close()
            let after = target.flatMap { t in try? RedactionCheck.run(saved, password, RedactionCheckOptions(values: [t.word])) }
            let onPages = after?.findings.filter { f in
                f.kind == .pageText && (markRects[f.page] ?? []).contains { !$0.intersect(f.box).isEmpty }
            }.count ?? 0
            check(images && stillGone && onPages == 0,
                  "the redacted file saved and read back: the redacted pages are pictures, the word not under the marks, nor found there by the check")
        } else {
            check(false, "the redacted file saved")
        }
        check(undo(label) && target.map { wholeWordHits($0.word, $0.page) > 0 } ?? true, "undo brings the redacted text back")
    }

    // MARK: Check Redaction

    private mutating func badRedaction() async {
        guard let text = try? controller.engine.text(0), let hit = text.find("quick", matchCase: true, wholeWord: true).first else {
            return skip("check a box over text: the word isn't on page 1")
        }
        let box = text.rects(hit.start, hit.end).reduce(RectD.zero) { $0.union($1) }.inflate(1)
        let drawn = await editor.addShape(page: 0, kind: .rectangle, box: box, style: AnnotStyle(color: AnnotStyle.black, fill: AnnotStyle.black, width: 1))
        send(#selector(DocumentWindowController.checkRedaction(_:)))
        await waitTasks()
        let report = controller.redaction.lastReport
        let covered = report?.findings.contains { $0.kind == .coveredText && $0.text == "quick" && $0.fix == .redact } ?? false
        guard let sheet = controller.redaction.reportSheet else { return check(false, "Check Redaction's report shown for a box over a word") }
        let fixTitle = sheet.fixButton.title.hasPrefix("Fix")
        let copied = RedactionReportSheet.text(sheet.report).contains("Text under a cover")
        sheet.fixClicked()
        await waitTasks()
        let fixedNotice = controller.noticeBar.history.last?.hasPrefix("Fixed") ?? false
        let after = controller.redaction.lastReport
        let wordGone = wholeWordHits("quick", 0) == 0
        if !(drawn && covered && fixTitle && copied && wordGone && fixedNotice) {
            for f in report?.findings ?? [] { lines.append("  (first check: \(RedactionCheck.name(f.kind)) · \(f.place), fix \(f.fix))") }
            for f in after?.findings ?? [] { lines.append("  (after the fix: \(RedactionCheck.name(f.kind)) · \(f.place), fix \(f.fix))") }
            lines.append("  (drawn \(drawn), covered \(covered), fix title \(fixTitle), copied \(copied), word gone \(wordGone), notice \(fixedNotice))")
        }
        check(drawn && covered && fixTitle && copied && wordGone && (fixedNotice || after?.findings.allSatisfy { $0.fix == .none } == true),
              "Check Redaction: a dark box over a word found (text under a cover), Fix from its report redacts it and checks again: "
              + "\(after.map { $0.isClean ? "clean" : "\($0.findings.count) left without a fix" } ?? "no report")")
        if let open = controller.redaction.reportSheet { open.closeClicked() }
        // Back to before the box: the fix's steps, then the box.
        var undone = 0
        while undone < 4, let label = session?.undoLabel, label.hasPrefix("Redact") || label == "Remove redaction leftovers" || label == "Rectangle" {
            controller.pdf.undo()
            undone += 1
            if label == "Rectangle" { break }
        }
        check(wholeWordHits("quick", 0) > 0, "undo takes the fix and the box away (\(undone) steps)")
    }

    // MARK: Sanitize

    private mutating func sanitize() async {
        guard let s = session else { return }
        let expected = try? Sanitizer.scan(s.data, s.password)
        send(#selector(DocumentWindowController.sanitizeDocument(_:)))
        await waitTasks()
        guard let sheet = controller.redaction.sanitizeSheet, let expected else { return check(false, "Sanitize Document sheet shown") }
        let original = s.data
        snapshot(sheet.window?.contentView, "e1-04-sanitize.png")
        let boxes = sheet.checks.allSatisfy { c in (c.box.state == .on) == (expected[c.item] > 0) && c.box.isEnabled == (expected[c.item] > 0) }
        let chosen = sheet.chosen
        let before = s.undoStepId
        sheet.sanitizeClicked()
        if chosen.isEmpty && expected.earlierRevisions == 0 && expected.unusedObjects == 0 {
            let refused = !sheet.problem.isHidden && controller.redaction.sanitizeSheet != nil
            sheet.cancelClicked()
            return check(boxes && refused && controller.redaction.sanitizeSheet == nil && session?.undoStepId == before,
                         "Sanitize Document: nothing found, its sheet says so; Cancel changes nothing")
        }
        await waitTasks()
        let result = controller.redaction.lastSanitize
        let done = session?.undoLabel == "Sanitize document" && result != nil
        var clean = false
        if let saved = await saveAs("sanitized.pdf"), let rescan = try? Sanitizer.scan(saved, session?.password) {
            clean = chosen.allSatisfy { rescan[$0] == 0 } && rescan.earlierRevisions == 0
            if !clean {
                FileManager.default.createFile(atPath: path("before-sanitize.pdf").path, contents: Data(original))
                lines.append("  (kept for a look: \(path("before-sanitize.pdf").path))")
                let left = chosen.filter { rescan[$0] > 0 }.map { "\($0) \(rescan[$0])" }.joined(separator: ", ")
                lines.append("  (after saving: \(left); earlier versions \(rescan.earlierRevisions); in memory: "
                    + "\(chosen.filter { (result?.remaining?[$0] ?? 0) > 0 }.map { "\($0)" }.joined(separator: ", ")))")
            }
        }
        let removed = chosen.reduce(0) { $0 + (result?.removed[$1] ?? 0) }
        check(boxes && done && clean, "Sanitize Document (its sheet: \(chosen.count) kinds found and ticked, \(removed) items): removed, "
              + "the saved file scanned again holds none of them and no earlier version")
        check(undo("Sanitize document"), "undo Sanitize")
    }
}
