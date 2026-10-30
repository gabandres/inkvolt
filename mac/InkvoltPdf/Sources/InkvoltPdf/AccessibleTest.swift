import AppKit
import PdfCore

/// The self-test's scenario for roadmap 2.4 (`--edit`, on the synthetic text document, after `MeasureTest`; `--only-accessible`
/// runs it alone): Make Accessible, the Reading Order pane and Save as PDF/A-2a through the app's own paths. The commands in
/// the menu bar; a title refused and the tags written as one undo step; the pane's list and the boxes; the keyboard (⌥↓, ⌥↑,
/// Page Down, ⌥Page Up, Return, Esc, as real key events on the list); a picture's alternate text typed and written by Apply
/// Changes, and marked decorative; the plan going stale on another edit; the Pro check on each feature; Save as PDF/A-2a
/// offering Make Accessible first, its copy checked by `PdfA.validate`. Everything is undone at the end. The sheets aren't
/// shown while the self-test runs. Only counts and short texts are written.
@MainActor
struct AccessibleTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var pane: ReadingOrderPane { controller.readingOrder }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private static func item(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for i in menu?.items ?? [] {
            if i.action == action { return i }
            if let hit = item(action, in: i.submenu) { return hit }
        }
        return nil
    }

    /// With `--snapshots`: a PNG of the window, as AppKit draws it.
    private func snapshot(_ file: String) {
        guard let dir = Report.snapshots, let view = controller.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        controller.pages.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(file)))
    }

    /// A key press as AppKit delivers it to the list.
    private func press(_ key: NSEvent.SpecialKey, _ flags: NSEvent.ModifierFlags = []) {
        let c = String(Character(key.unicodeScalar))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
                                     context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)
        if let event { pane.table.keyDown(with: event) }
    }

    mutating func run() async {
        lines.append("== \(name): Make Accessible, Reading Order, PDF/A-2a")
        if ProcessInfo.processInfo.environment["E24_TRY"] != nil { ProWindowController.show(feature: .autoTagging); try? await Task.sleep(for: .seconds(2)); ProWindowController.shared?.close(); Report.progress("E24 pro window survived"); try? await Task.sleep(for: .seconds(1)) }
        for (action, title, menu) in [(#selector(DocumentWindowController.makeAccessible(_:)), "Make Accessible (Tag)…", "Tools"),
                                      (#selector(DocumentWindowController.toggleReadingOrder(_:)), "Reading Order and Alt Text", "Tools"),
                                      (#selector(DocumentWindowController.saveAsPdfA2a(_:)), "Save as PDF/A-2a (Accessible Archive)…", "File")] {
            let found = Self.item(action, in: NSApp.mainMenu)
            check(found?.title == title && found?.menu?.title == menu && found.map { controller.validateMenuItem($0) } == true, "\(menu) › \(title) is in the menu bar and enabled")
        }
        check(BatchWindowController.offered.contains(.makeAccessible(language: nil)) && BatchWindowController.offered.contains(.saveAsPdfA2a), "Batch offers Make Accessible and Save as PDF/A-2a")
        guard let session = controller.pdf.session else {
            check(false, "the document is open")
            return finish()
        }
        let before = session.data, dirty = session.isDirty

        // A title the sheet refuses: nothing is written.
        AccessibleState.testTitle = "  "
        AccessibleState.testLanguage = "en"
        var ok = await controller.makeAccessible()
        check(!ok && AccessibleState.lastProblem?.contains("title") == true && controller.pdf.session?.data == before, "without a title nothing is written")

        // The tags, as one undo step.
        AccessibleState.testTitle = "Self-test document"
        AccessibleState.testLanguage = "en-US"
        AccessibleState.lastProblem = nil
        ok = await controller.makeAccessible()
        guard ok, let tagged = controller.pdf.session?.data else {
            check(false, "Make Accessible writes the tags")
            return finish()
        }
        check(AutoTag.isTagged(tagged, session.password), "Make Accessible writes the tags")
        let undoManager = controller.window?.undoManager
        check(undoManager?.undoMenuItemTitle.contains("Make accessible") == true, "as one undo step named Make accessible")
        check(pane.isShown && pane.written && pane.isCurrent, "the Reading Order pane opens on the plan written")
        check(pane.state.summary.contains("The document is tagged this way.") && !pane.applyButton.isEnabled, "the pane says the document is tagged this way, nothing to apply")
        let pieces = pane.state.items.count
        check(pieces > 0 && pane.table.numberOfRows == pieces, "the list shows the page's \(pieces) pieces")
        check(controller.pages.readingBoxes.count == pane.plan?.blocks.count, "the pages show a numbered box for each of the \(controller.pages.readingBoxes.count) pieces")
        snapshot("accessible-pane.png")

        // The keyboard path, with key events on the list.
        pane.focusList()
        check(controller.window?.firstResponder === pane.table, "the list can take the keyboard")
        pane.selectRow(0)
        let firstIndex = pane.selected
        press(.downArrow, .option)
        check(pane.selected == (firstIndex ?? 0) + 1 && !pane.written && pane.applyButton.isEnabled, "⌥↓ moves the piece down and Apply Changes wakes")
        press(.upArrow, .option)
        check(pane.selected == firstIndex && pane.table.selectedRow == 0, "⌥↑ moves it back")
        let pageCount = pane.plan?.pages ?? 0
        if pageCount > 1 {
            press(.pageDown)
            check(pane.page == 1 && pane.table.selectedRow == 0 && pane.selected != nil, "Page Down shows the next page's pieces, the first selected")
            let selected = pane.selected
            press(.pageUp, .option)
            check(pane.page == 0 && pane.selectedItemKind.hasSuffix(" · from page 2") && pane.selected != selected, "⌥Page Up reads the piece with the page before")
            press(.pageDown, .option)
            check(pane.page == 1 && !pane.selectedItemKind.contains("from page"), "⌥Page Down brings it back")
            press(.pageUp)
            check(pane.page == 0, "Page Up shows the page before")
        } else {
            lines.append("note: one page, the page keys aren't tried")
        }

        // A picture's alternate text, typed and written.
        if let row = pane.state.items.firstIndex(where: { $0.block.kind == .figure }) {
            pane.selectRow(row)
            check(!pane.figureGroup.isHidden && pane.altLabel.stringValue.hasPrefix("Alternate text for picture"), "a picture shows its alternate text")
            press(.carriageReturn)
            let editing = (controller.window?.firstResponder as? NSTextView)?.delegate as? NSTextField
            check(editing === pane.altField, "Return goes to the alternate text")
            if let t = controller.window?.firstResponder as? NSTextView {
                t.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                check(controller.window?.firstResponder === pane.table, "Esc goes back to the list")
            }
            pane.altField.stringValue = "A gradient of colors"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: pane.altField)
            check(pane.plan?.figuresWithoutAlt == 0 && !pane.written, "the text goes into the plan")
            snapshot("accessible-picture.png")
            let applied = await pane.apply()
            check(applied && pane.written && pane.isCurrent, "Apply Changes writes it")
            if let data = controller.pdf.session?.data, let engine = try? PdfEngine.open(data, password: session.password) {
                let read = try? AutoTag.plan(engine, data, session.password)
                engine.close()
                check(read?.wasTagged == true && read?.blocks.contains { $0.alt == "A gradient of colors" } == true, "the file read back has the alternate text")
            } else {
                check(false, "the file opens")
            }
            pane.selectRow(row)
            pane.setDecorative(true)
            check(pane.plan?.figuresWithoutAlt == 0 && !pane.altField.isEnabled && pane.selectedItemKind == "Picture (decorative)", "Decorative: no text needed, the field greys")
            pane.setDecorative(false)
        } else {
            lines.append("note: no picture on this page")
        }

        // The Pro check on each feature.
        Pro.enforced = true
        let locked = await controller.makeAccessible()
        check(!locked && !Pro.allows(.autoTagging), "Make Accessible asks the Pro check")
        pane.focusList()
        pane.selectRow(0)
        let unmoved = pane.plan
        press(.downArrow, .option)
        check(pane.plan == unmoved, "moving a piece asks the Pro check")
        let appliedLocked = await pane.apply()
        check(!appliedLocked, "Apply Changes asks the Pro check")
        let copyLocked = await controller.saveAsPdfA2a()
        check(!copyLocked, "Save as PDF/A-2a asks the Pro check")
        Pro.enforced = false
        ProWindowController.shared?.close()

        // Save as PDF/A-2a of the tagged document.
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-a11y-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let target = URL(fileURLWithPath: (folder as NSString).appendingPathComponent(PdfA.copyName(session.displayName, conformance: .a)))
        PdfAState.testTarget = target
        var saved = await controller.saveAsPdfA2a()
        check(saved && PdfAState.lastTitle == "Saved as PDF/A-2a" && PdfAState.lastMessage.contains("tagged for accessibility"), "Save as PDF/A-2a saves the copy")
        if !saved { lines.append("note: \(PdfAState.lastTitle): \(PdfAState.lastMessage.replacingOccurrences(of: "\n", with: " ").prefix(300))") }
        var copy = (try? Data(contentsOf: target)).map { [UInt8]($0) } ?? []
        let problems = PdfA.validate(copy, conformance: .a)
        check(!copy.isEmpty && problems.isEmpty, "the copy passes PdfA.validate at level A (\(problems.count) problems)")
        check(AutoTag.isTagged(copy, nil), "the copy keeps the tags")
        try? FileManager.default.removeItem(at: target)

        // Another edit makes the plan stale; undone, the document is as it was.
        undoManager?.undo()
        await Self.settle(controller)
        check(!pane.isCurrent && pane.state.summary.hasPrefix("The document changed") && !pane.applyButton.isEnabled, "another version of the document makes the plan stale")
        while controller.pdf.session?.data != before, undoManager?.canUndo == true {
            undoManager?.undo()
            await Self.settle(controller)
        }
        check(controller.pdf.session?.data == before, "undone, the document is as it was")

        // An untagged document: PDF/A-2a offers Make Accessible first.
        AccessibleState.testTagFirst = false
        saved = await controller.saveAsPdfA2a()
        check(!saved && AccessibleState.tagFirstAsked == 1 && controller.pdf.session?.data == before, "an untagged document is offered Make Accessible, and No leaves it")
        AccessibleState.testTagFirst = true
        saved = await controller.saveAsPdfA2a()
        copy = (try? Data(contentsOf: target)).map { [UInt8]($0) } ?? []
        check(saved && AccessibleState.tagFirstAsked == 2 && AutoTag.isTagged(copy, nil) && PdfA.validate(copy, conformance: .a).isEmpty, "Make Accessible first, then the copy")
        while controller.pdf.session?.data != before, undoManager?.canUndo == true {
            undoManager?.undo()
            await Self.settle(controller)
        }
        PdfAState.testTarget = nil
        check(controller.pdf.session?.data == before && controller.pdf.session?.isDirty == dirty, "the open document is back as it was")

        pane.hide()
        check(!pane.isShown && controller.pages.readingBoxes.isEmpty, "Done closes the pane and takes the boxes off")
        finish()
    }

    private static func settle(_ controller: DocumentWindowController) async {
        for _ in 0..<3 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
