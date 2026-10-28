import AppKit
import CoreText
import PdfCore

/// The self-test's scenario for D7 part c (`--edit`, after `EditTest`): forms filled through the page view's own
/// clicks, editor, keystroke checks and Tab; Reset, Export and Import Form Data; Fill & Sign's text, marks, date,
/// drawn and typed signatures; Edit Text & Images; Recognize Text (cancelled, then done) and export to Word, Excel and
/// text (cancelled, then done) through the window's own functions, with their progress sheets; every result saved into a
/// temporary folder and read back by a fresh session. Only counts and kinds are written, never a document's text.
@MainActor
struct FeatureTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0
    private let shots: Bool
    /// The synthetic documents (by the path they were opened from: `EditTest`'s Save As moves them): the form, and the
    /// text pages with a scan.
    private let formDoc: Bool
    private let synthetic: Bool
    private let folder: String

    init(controller: DocumentWindowController, name: String, openedFrom path: String?) {
        self.controller = controller
        self.name = name
        formDoc = path != nil && path == Report.syntheticFormPath
        synthetic = path != nil && path == Report.syntheticPath
        shots = Report.snapshots != nil && (formDoc || synthetic)
        folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-features-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private var pages: PagesView { controller.pages }
    private var editor: DocumentEditor { controller.editor }
    private var form: FormFiller { controller.form }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private mutating func skip(_ what: String) { lines.append("SKIP \(what)") }

    // MARK: Driving the view

    private func event(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent {
        let location = pages.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
                                  pressure: 1)!
    }

    /// A press through `points` (page space), as the mouse makes it; waits for what it started.
    private func press(_ page: Int, _ points: [PointD]) async {
        let r = pages.pageRects[page]
        let view = points.map { pages.viewPoint($0, r) }
        pages.mouseDown(with: event(.leftMouseDown, view[0]))
        for p in view.dropFirst() { pages.mouseDragged(with: event(.leftMouseDragged, p)) }
        pages.mouseUp(with: event(.leftMouseUp, view[view.count - 1]))
        await settle()
    }

    private func key(_ characters: String, code: UInt16, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func settle() async {
        for _ in 0..<3 {
            await pages.pendingEdit?.value
            await form.settle()
            await controller.content.settle()
        }
        try? await Task.sleep(for: .milliseconds(40))
    }

    private func waitDrawn() async {
        for _ in 0..<60 {
            pages.requestVisible()
            if let image = pages.renderer.image(pages.currentPage), image.scale > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    private mutating func snapshot(_ view: NSView?, _ file: String) {
        guard shots, let view, let dir = Report.snapshots else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return check(false, "snapshot \(file): no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let flat = NSImage(size: view.bounds.size, flipped: false) { rect in
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            }
            rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return true
        }
        let png = flat.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
        let ok = (try? png?.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(file)))) != nil
        check(ok, "snapshot \(file): \(rep.pixelsWide) x \(rep.pixelsHigh) px")
    }

    /// Saves through NSDocument (Save As) into this test's folder; the error, if any.
    private func saveAs(_ file: String) async -> (url: URL, error: String?) {
        let url = URL(fileURLWithPath: (folder as NSString).appendingPathComponent(file))
        let error = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            controller.pdf.save(to: url, ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
                done.resume(returning: error.map { "\($0.localizedDescription)" })
            }
        }
        return (url, error)
    }

    private func readBack(_ url: URL) -> [UInt8]? { (try? Data(contentsOf: url)).map { [UInt8]($0) } }

    // MARK: The scenario

    mutating func run() async {
        guard let session = controller.pdf.session else {
            Report.write("== \(name): forms, Fill & Sign, edit text, OCR, export\nRESULT: FAIL (no session)")
            return
        }
        let started = Date()
        lines.append("== \(name): forms, Fill & Sign, edit text, OCR, export (\(session.engine.pageCount) pages)")
        controller.closePopovers()
        controller.setZoom(1)
        controller.go(0)
        await waitDrawn()
        if form.hasFields { await forms() } else { skip("forms: no fields") }
        if !formDoc {
            await fillAndSign()
            await editContent()
            await export()
            await recognize()
        }
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
        Report.note("features took \(Int(Date().timeIntervalSince(started))) s")
    }

    // MARK: Forms

    private func widget(_ name: String, _ onState: String? = nil) -> FormWidget? {
        form.widgets.first { $0.fieldName == name && (onState == nil || $0.onState == onState) }
    }

    private func center(_ w: FormWidget) -> PointD { PointD(w.rect.centerX, w.rect.centerY) }

    /// Types `text` into the open editor one character at a time, as the keyboard would (each one through the
    /// keystroke check).
    private func type(_ text: String) {
        guard let field = form.editorView else { return }
        for ch in text {
            field.stringValue += String(ch)
            form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
    }

    private mutating func forms() async {
        let fillable = form.fillable
        let page = fillable.first?.pageIndex ?? 0
        controller.go(page)
        check(fillable.count >= 1, "form: \(form.widgets.count) widgets, \(fillable.count) to fill, in tab order")
        guard form.widget(page: page, center(fillable[0])) != nil else { return check(false, "form: field under its own center") }

        // Tab from the pages focuses the first field in tab order and opens its editor; Tab again the next.
        controller.window?.makeFirstResponder(pages)
        pages.keyDown(with: key("\t", code: 48))
        let first = form.focused?.fieldName
        let editorOpen = form.editorView != nil
        form.focusNext(1)
        let second = form.focused?.fieldName
        form.cancelEditor()
        check(first == fillable[0].fieldName && second == fillable[1 % fillable.count].fieldName && (fillable[0].kind != .text || editorOpen),
              "Tab: first field focused (editor open: \(editorOpen)), Tab again: the next in tab order")
        guard formDoc, let name = widget("name"), let amount = widget("amount"), let extra = widget("extra"),
              let agree = widget("agree"), let blue = widget("color", "Blue"), let size = widget("size"), let fruit = widget("fruit") else {
            skip("form filling: not the synthetic form")
            return
        }

        // A text field: click, type, Return (one undo step).
        await press(page, [center(name)])
        let opened = form.editing?.fieldName == "name"
        type("Ada Lovelace")
        form.commitEditor()
        await settle()
        let undoTitle = controller.window?.undoManager?.undoMenuItemTitle ?? ""
        check(opened && form.value("name") == "Ada Lovelace" && undoTitle == "Undo Fill form field",
              "text field: clicked (editor opened: \(opened)), typed, written as “\(undoTitle)”")

        // The keystroke script refuses a letter in a number field; the calculation and format run on commit.
        await press(page, [center(amount)])
        await form.keystrokesReady()
        type("12a")
        let afterLetter = form.editorView?.stringValue ?? "-"
        type(".5")
        form.commitEditor()
        await settle()
        await press(page, [center(extra)])
        type("30")
        form.commitEditor()
        await settle()
        let total = widget("total")
        check(afterLetter == "12" && form.value("amount") == "12.5" && total?.value == "42.5" && total?.displayValue == "$42.50",
              "keystroke script refused a letter (\(afterLetter.count) characters kept); total calculated and formatted: \(total?.displayValue ?? "-")")

        // Check box, radio button, combo box, list.
        await press(page, [center(agree)])
        await press(page, [center(blue)])
        form.choose(size, 2)
        await settle()
        form.choose(fruit, 1)
        await settle()
        check(form.value("agree") == "Yes" && form.value("color") == "Blue" && form.value("size") == "L" && form.value("fruit") == "Banana",
              "check box, radio button, combo and list box set by click and choice")
        await waitDrawn()
        snapshot(controller.window?.contentView, "7-form-filled.png")

        // Undo and redo, one field at a time.
        let undo = controller.window?.undoManager
        undo?.undo()
        let undone = form.value("fruit")
        undo?.redo()
        check(undone == "" && form.value("fruit") == "Banana", "undo and redo of a field: list emptied, then chosen again")

        // Export the data, reset the form, import it back.
        let xfdf = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("form.xfdf"))
        let exported = form.exportData(to: xfdf, .xfdf)
        form.resetForm(nil)
        await settle()
        let reset = form.value("name") == "" && form.value("size") == "M" && form.value("agree") == "Off"
        let imported = await form.importData(readBack(xfdf) ?? [])
        let back = form.value("name") == "Ada Lovelace" && form.value("color") == "Blue" && widget("total")?.value == "42.5"
        check(exported && reset && imported && back, "Export Form Data (XFDF), Reset Form (defaults back), Import Form Data (values and total back)")

        // Saved and read back by a fresh session.
        let saved = await saveAs("form.pdf")
        var values: [String: String] = [:]
        if let s = try? DocumentSession.open(saved.url.path) {
            for w in (try? FormEditor.read(s.data, s.password)) ?? [] { values[w.fieldName] = w.value }
            s.close()
        }
        check(saved.error == nil && values["name"] == "Ada Lovelace" && values["total"] == "42.5" && values["fruit"] == "Banana",
              "form saved (Save As) and read back: \(values.count) fields with their values")
        let alerts = form.host.testLog.count
        lines.append("INFO form host: \(alerts) requests from scripts")
    }

    // MARK: Fill & Sign

    private func stamps(_ kind: StampKind) -> [TextStamp] { editor.stamps.filter { $0.kind == kind } }

    private mutating func fillAndSign() async {
        let page = pages.currentPage
        controller.go(page)
        let g = controller.engine.page(page)
        func at(_ fx: Double, _ fy: Double) -> PointD { PointD(g.width * fx, g.height * fy) }
        let texts0 = stamps(.text).count, sigs0 = stamps(.signature).count

        controller.testText = "Fill & Sign text"
        pages.tool = .fillText
        await press(page, [at(0.1, 0.44)])
        let added = stamps(.text).count == texts0 + 1
        controller.testText = "Changed text"
        if let s = stamps(.text).last { await press(page, [PointD(s.rect.centerX, s.rect.centerY)]) }
        let changed = stamps(.text).count == texts0 + 1 && stamps(.text).contains { $0.text == "Changed text" }
        controller.testText = nil
        check(added && changed, "Fill & Sign text: added with a click, changed with another (one stamp)")

        pages.tool = .fillCheck
        await press(page, [at(0.32, 0.44)])
        pages.tool = .fillCross
        await press(page, [at(0.38, 0.44)])
        pages.tool = .fillDate
        await press(page, [at(0.44, 0.44)])
        let marks = stamps(.check).count == 1 && stamps(.cross).count == 1 && stamps(.text).count == texts0 + 2
        pages.tool = .fillCheck
        if let c = stamps(.check).first { await press(page, [PointD(c.rect.centerX, c.rect.centerY)]) }
        check(marks && stamps(.check).isEmpty, "check mark, cross and date placed; clicking the check mark removed it")

        // A drawn signature and typed initials, through the sheet that makes them, then a click.
        let sheet = controller.showSignatureSheet(initials: false, typing: false)
        let wave = (0...30).map { i -> CGPoint in CGPoint(x: 30 + Double(i) * 10, y: 80 + 25 * sin(Double(i) / 3)) }
        sheet?.pad.add(wave)
        try? await Task.sleep(for: .milliseconds(200))
        snapshot(sheet?.window?.contentView, "8-signature-sheet.png")
        sheet?.useClicked()
        await press(page, [at(0.7, 0.44)])
        let initialsSheet = controller.showSignatureSheet(initials: true, typing: true)
        initialsSheet?.typed.stringValue = "AL"
        initialsSheet?.useClicked()
        await press(page, [at(0.85, 0.44)])
        let sigs = stamps(.signature)
        check(sheet != nil && initialsSheet != nil && sigs.count == sigs0 + 2 && pages.tool == .signature,
              "signature drawn and initials typed in the sheet, each put down with a click: \(sigs.count - sigs0) placed")

        // The hand tool moves a signature (redrawn in its new place, one undo step).
        if let s = stamps(.signature).last {
            pages.tool = .hand
            let c = PointD(s.rect.centerX, s.rect.centerY)
            await press(page, [c, PointD(c.x + 10, c.y + 5), PointD(c.x + 20, c.y + 10)])
            let moved = stamps(.signature).first { abs($0.rect.x - s.rect.x - 20) < 1 && abs($0.rect.y - s.rect.y - 10) < 1 }
            let title = controller.window?.undoManager?.undoMenuItemTitle ?? ""
            check(moved != nil && title == "Undo Move", "hand tool moved the initials by (20, 10): “\(title)”")
        }
        await waitDrawn()
        snapshot(controller.window?.contentView, "9-fill-and-sign.png")

        let saved = await saveAs("fill-and-sign.pdf")
        var readTexts = -1, readSigs = -1
        if let bytes = readBack(saved.url) {
            readTexts = ((try? TextStamps.read(bytes, controller.pdf.session?.password)) ?? []).filter { $0.kind == .text }.count
            readSigs = ((try? SignatureStamps.read(bytes, controller.pdf.session?.password)) ?? []).filter { $0.kind == .signature }.count
        }
        check(saved.error == nil && readTexts == stamps(.text).count && readSigs == stamps(.signature).count,
              "Fill & Sign saved and read back: \(readTexts) texts, \(readSigs) signatures")
        pages.tool = .text
    }

    // MARK: Edit Text & Images

    private mutating func editContent() async {
        let content = controller.content!
        pages.tool = .editContent
        let count = min(controller.engine.pageCount, 10)
        // Text: the first editable run with a word in it, rewritten with its own letters reversed.
        var edited = false
        for page in 0..<count {
            let c = await content.ensure(page)
            guard let run = c.runs.first(where: { r in r.blocked == nil && r.text.filter(\.isLetter).count >= 4 }) else { continue }
            var replacement = String(run.text.reversed())
            if replacement == run.text { replacement = run.text + String(run.text.prefix(1)) }
            guard run.check(replacement).missing.isEmpty else { continue }
            controller.go(page)
            controller.testText = replacement
            await press(page, [PointD(run.box.centerX, run.box.centerY)])
            controller.testText = nil
            let after = await content.ensure(page)
            let found = after.runs.contains { $0.text == replacement }
            let title = controller.window?.undoManager?.undoMenuItemTitle ?? ""
            check(found && title == "Undo Edit text", "Edit Text & Images: a \(run.text.count)-character run on page \(page + 1) rewritten (“\(title)”)")
            edited = true
            break
        }
        if !edited { skip("edit text: no editable run in the first \(count) pages") }

        // Pictures: dragged to move, Delete removes, undo brings it back.
        var moved = false
        for page in 0..<count {
            let c = await content.ensure(page)
            // A picture with room to move (a scan filling its page has none).
            let g = controller.engine.page(page)
            func room(_ i: PageImage) -> (dx: Double, dy: Double) {
                let dx: Double = i.box.right + 15 <= g.width ? 15 : i.box.x >= 15 ? -15 : 0
                let dy: Double = i.box.bottom + 10 <= g.height ? 10 : i.box.y >= 10 ? -10 : 0
                return (dx, dy)
            }
            guard let image = c.images.first(where: { i in i.blocked == nil && room(i).dx != 0 && room(i).dy != 0 }) else { continue }
            controller.go(page)
            await waitDrawn()
            let (dx, dy) = room(image)
            let ctr = PointD(image.box.centerX, image.box.centerY)
            await press(page, [ctr, PointD(ctr.x + dx / 2, ctr.y + dy / 2), PointD(ctr.x + dx, ctr.y + dy)])
            let after = await content.ensure(page)
            let shifted = after.images.contains { abs($0.box.x - image.box.x - dx) < 1 && abs($0.box.y - image.box.y - dy) < 1 }
            check(shifted, "picture on page \(page + 1) dragged by (\(Int(dx)), \(Int(dy))) (\(c.images.count) pictures on the page)")
            await settle()
            let before = after.images.count
            if content.selectedImage == nil, let m = after.images.first(where: { abs($0.box.x - image.box.x - dx) < 1 }) { content.select(m) }
            controller.window?.makeFirstResponder(pages)
            pages.keyDown(with: key("\u{7f}", code: 51))
            await settle()
            let deleted = await content.ensure(page).images.count
            controller.window?.undoManager?.undo()
            let restored = await content.ensure(page).images.count
            check(content.selectedImage == nil && deleted == before - 1 && restored == before,
                  "Delete removed the selected picture (\(before) → \(deleted)), undo brought it back (\(restored))")
            await waitDrawn()
            snapshot(controller.window?.contentView, "10-edit-content.png")
            moved = true
            break
        }
        if !moved { skip("edit pictures: no picture with room to move in the first \(count) pages") }
        pages.tool = .text
    }

    // MARK: Export

    private mutating func export() async {
        let count = controller.engine.pageCount
        let chosen = Array(0..<min(count, synthetic ? count : 5))
        // Cancelled at once: nothing written.
        let cancelURL = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("cancelled.docx"))
        let c = controller
        let cancelled = Task { @MainActor in await c.runExport(.word, to: cancelURL, pages: chosen, recognize: true) }
        for _ in 0..<100 where controller.progressSheet == nil { await Task.yield() }
        let shown = controller.progressSheet?.isShown ?? false
        controller.progressSheet?.cancelButton.performClick(nil)
        let cancelReport = await cancelled.value
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let temporary = files.contains { $0.hasPrefix("~inkvoltpdf") }
        // A few pages with text can be written before the click arrives: then the file is whole.
        let early = cancelReport != nil && files.contains("cancelled.docx")
        check(shown && (cancelReport == nil && !files.contains("cancelled.docx") || early) && !temporary && controller.progressSheet == nil,
              early ? "export finished before its Cancel was clicked: file whole, no temporary file left"
                    : "export cancelled from its progress sheet: nothing saved, no temporary file left")

        for format in ExportFormat.allCases {
            let url = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("export" + DocumentExport.fileExtension(format)))
            let started = Date()
            let report = await controller.runExport(format, to: url, pages: chosen, recognize: true)
            let bytes = readBack(url) ?? []
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            guard let report else {
                check(false, "export \(format): failed")
                continue
            }
            var ok = report.saved == !bytes.isEmpty
            switch format {
            case .word, .excel: ok = ok && (!report.saved || bytes.starts(with: [0x50, 0x4B]))
            case .text: ok = ok && (!report.saved || bytes.starts(with: [0xEF, 0xBB, 0xBF]))
            }
            if synthetic {
                // The synthetic document: text on two pages, a scan on the third (recognized), no table.
                ok = ok && (format == .excel ? !report.saved : report.saved && report.recognized == 1)
            }
            check(ok, "export \(format) of \(chosen.count) pages: saved \(report.saved), \(bytes.count) bytes, \(report.recognized) recognized, "
                  + "\(report.noText) without text, \(report.tables) tables, \(seconds) s; notice shown: \(!controller.noticeBar.isHidden)")
        }
    }

    // MARK: Recognize Text

    private mutating func recognize() async {
        let count = controller.engine.pageCount
        let chosen = Array(0..<min(count, synthetic ? count : 3))
        let undoBefore = controller.pdf.session?.undoLabel

        // Cancelled at once (before Vision has even loaded): nothing changes. The sheet is up before the first page.
        let c = controller
        let first = Task { @MainActor in await c.runRecognize(pages: chosen) }
        for _ in 0..<100 where controller.progressSheet == nil { await Task.yield() }
        let shown = controller.progressSheet?.isShown ?? false
        snapshot(controller.progressSheet?.window?.contentView, "11-ocr-progress.png")
        controller.progressSheet?.cancelButton.performClick(nil)
        let cancelled = await first.value
        // Pages that all have text may be done (nothing to change) before the click arrives.
        let stopped = cancelled.outcome == .declined || cancelled.outcome == .noChange
        check(shown && stopped && controller.pdf.session?.undoLabel == undoBefore,
              "Recognize Text cancelled from its progress sheet (shown at once): nothing changed")

        let started = Date()
        let result = await controller.runRecognize(pages: chosen)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        let r = result.report
        let summary = "\(r?.words ?? 0) words on \(r?.pagesWithWords ?? 0) pages, \(r?.hadText ?? 0) already had text, \(seconds) s"
        if synthetic {
            let text = (try? controller.engine.text(2))?.text ?? ""
            let title = controller.window?.undoManager?.undoMenuItemTitle ?? ""
            check(result.outcome == .done && r?.pagesWithWords == 1 && r?.hadText == 2 && text.contains("Inkvolt") && title == "Undo Recognize text",
                  "Recognize Text: \(summary); the scan's words found on its page; “\(title)”")
        } else {
            let fine = result.outcome == .done || result.outcome == .noChange
            check(fine && (r?.hadText ?? 0) + (r?.pagesWithWords ?? 0) <= chosen.count, "Recognize Text on \(chosen.count) pages: \(summary)")
        }
        // Again: every page has text now, so nothing to do and no undo step.
        if result.outcome == .done {
            let label = controller.pdf.session?.undoLabel
            let again = await controller.runRecognize(pages: chosen)
            check(again.outcome == .noChange && controller.pdf.session?.undoLabel == label,
                  "Recognize Text again: pages with text skipped (\(again.report?.hadText ?? 0)), no undo step")
        }
    }
}

// MARK: Synthetic documents

extension SyntheticPdf {
    /// A one-page form made here: text fields (one with a keystroke script and a format), a calculated total, a check
    /// box, two radio buttons, a combo box and a list box.
    static func form() -> [UInt8] {
        let w = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R"
        let number = #"/AA << /K << /S /JavaScript /JS (AFNumber_Keystroke\(2, 0, 0, 0, "", true\);) >> /F << /S /JavaScript /JS (AFNumber_Format\(2, 0, 0, 0, "$", true\);) >> >>"#
        let sum = #"/AA << /C << /S /JavaScript /JS (AFSimple_Calculate\("SUM", new Array\("amount", "extra"\)\);) >> /F << /S /JavaScript /JS (AFNumber_Format\(2, 0, 0, 0, "$", true\);) >> >>"#
        let content = """
        BT /F1 20 Tf 72 740 Td (Synthetic form) Tj ET
        BT /F1 12 Tf 72 696 Td (Name) Tj 0 -40 Td (Amount) Tj 0 -40 Td (Extra) Tj 0 -40 Td (Total) Tj 0 -40 Td (I agree) Tj 0 -40 Td (Color) Tj 0 -40 Td (Size) Tj 0 -60 Td (Fruit) Tj ET
        """
        let on = "q 0 g 3 3 12 12 re f Q\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 10 0 R 11 0 R 12 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> /CO [8 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 13 0 R 14 0 R 11 0 R 12 0 R] /Contents 15 0 R /Resources << /Font << /F1 4 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< \(w) /FT /Tx /T (name) /Rect [150 690 400 712] /DA (/Helv 12 Tf 0 g) >>",
            "<< \(w) /FT /Tx /T (amount) /Rect [150 650 300 672] /DA (/Helv 12 Tf 0 g) \(number) >>",
            "<< \(w) /FT /Tx /T (extra) /Rect [150 610 300 632] /DA (/Helv 12 Tf 0 g) \(number) >>",
            "<< \(w) /FT /Tx /Ff 1 /T (total) /Rect [150 570 300 592] /DA (/Helv 12 Tf 0 g) \(sum) >>",
            "<< \(w) /FT /Btn /T (agree) /V /Off /AS /Off /Rect [150 530 168 548] /AP << /N << /Yes 16 0 R /Off 17 0 R >> >> >>",
            "<< /FT /Btn /Ff 49152 /T (color) /Kids [13 0 R 14 0 R] /V /Off >>",
            "<< \(w) /FT /Ch /Ff 131072 /T (size) /Opt [(S) (M) (L)] /V (M) /DV (M) /Rect [150 450 260 472] /DA (/Helv 12 Tf 0 g) >>",
            "<< \(w) /FT /Ch /T (fruit) /Opt [(Apple) (Banana) (Cherry)] /Rect [150 370 260 430] /DA (/Helv 12 Tf 0 g) >>",
            "<< \(w) /Parent 10 0 R /Rect [150 490 168 508] /AS /Off /AP << /N << /Red 16 0 R /Off 17 0 R >> >> >>",
            "<< \(w) /Parent 10 0 R /Rect [200 490 218 508] /AS /Off /AP << /N << /Blue 16 0 R /Off 17 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Length \(on.utf8.count) >>\nstream\n\(on)endstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 18 18] /Length 0 >>\nstream\nendstream",
        ]
        return build(objects)
    }

    /// Objects to a PDF: numbered from 1, the catalog first.
    static func build(_ objects: [String]) -> [UInt8] {
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(out.utf8)
    }

    /// A "scanned" line of words: a gray picture of text (no text layer), as an image XObject in ASCII hex.
    static func scanImage() -> (width: Int, height: Int, hex: String) {
        let w = 800, h = 200
        var pixels = [UInt8](repeating: 255, count: w * h)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Inkvolt scan test", attributes: attributes))
            ctx.textPosition = CGPoint(x: 30, y: 75)
            CTLineDraw(line, ctx)
        }
        let digits = Array("0123456789ABCDEF".utf8)
        var hex = [UInt8]()
        hex.reserveCapacity(w * h * 2 + 1)
        for p in pixels {
            hex.append(digits[Int(p >> 4)])
            hex.append(digits[Int(p & 15)])
        }
        hex.append(UInt8(ascii: ">"))
        return (w, h, String(decoding: hex, as: UTF8.self))
    }
}
