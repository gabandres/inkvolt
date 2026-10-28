import AppKit
import PdfCore

/// The self-test's editing scenario for one open document (`--edit`): every comment tool driven through the page view's
/// own mouse and key handling (synthesized events), the menu commands, the inspector's functions, the comments list,
/// undo and redo through the window's undo manager, Save As and Save into a temporary folder (never over the file that
/// was opened), the file read back by a fresh session, the "changed on disk" bar and Reload, Revert, and a recovery copy.
/// Only counts and kinds are written, never a document's text. `--snapshots` adds PNGs of the window (synthetic document
/// only).
@MainActor
struct EditTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0
    /// Snapshots only of the synthetic document (decided once: Save As moves it elsewhere).
    private let shots: Bool

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
        shots = Report.snapshots != nil && controller.pdf.fileURL?.path == Report.syntheticPath
    }

    private var pages: PagesView { controller.pages }
    private var editor: DocumentEditor { controller.editor }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func count(_ subtype: String) -> Int { editor.comments.filter { $0.subtype == subtype }.count }

    // MARK: Driving the view

    private func event(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1, shift: Bool = false) -> NSEvent {
        let location = pages.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: shift ? .shift : [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// A press through `points` (page space of `page`), as the mouse would make it; waits for the edit it starts.
    private func press(_ page: Int, _ points: [PointD], shift: Bool = false, clicks: Int = 1) async {
        let r = pages.pageRects[page]
        let view = points.map { pages.viewPoint($0, r) }
        pages.mouseDown(with: event(.leftMouseDown, view[0], clicks: clicks, shift: shift))
        for p in view.dropFirst() { pages.mouseDragged(with: event(.leftMouseDragged, p, shift: shift)) }
        pages.mouseUp(with: event(.leftMouseUp, view[view.count - 1], clicks: clicks, shift: shift))
        await settle()
    }

    private func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// Waits for the edit a press or key started.
    private func settle() async {
        await pages.pendingEdit?.value
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// Waits until the page shown has its picture drawn after the last change (for snapshots).
    private func waitDrawn() async {
        for _ in 0..<60 {
            pages.requestVisible()
            let page = pages.currentPage
            if let image = pages.renderer.image(page), image.scale > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    private mutating func snapshot(_ view: NSView, _ file: String) {
        guard shots, let dir = Report.snapshots else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            check(false, "snapshot \(file): no bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Over the window's background, as the screen shows it (a popover's own background isn't in its view).
        let flat = NSImage(size: view.bounds.size, flipped: false) { rect in
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            }
            rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            return true
        }
        let path = (dir as NSString).appendingPathComponent(file)
        let png = flat.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
        let ok = (try? png?.write(to: URL(fileURLWithPath: path))) != nil
        check(ok, "snapshot \(file): \(rep.pixelsWide) x \(rep.pixelsHigh) px")
    }

    // MARK: The scenario

    mutating func run() async {
        guard let session = controller.pdf.session else {
            Report.write("== \(name): editing\nRESULT: FAIL (no session)")
            return
        }
        let started = Date()
        lines.append("== \(name): editing (\(session.data.count) bytes, \(session.engine.pageCount) pages)")
        defer { Report.note("editing took \(Int(Date().timeIntervalSince(started))) s") }
        let engine = controller.engine
        // A page with text (for the text marks), else the first.
        var page = 0
        var words: [(start: Int, end: Int)] = []
        for p in 0..<min(engine.pageCount, 20) {
            guard let t = try? engine.text(p), !t.isEmpty else { continue }
            words = Self.words(t)
            if words.count >= 3 {
                page = p
                break
            }
        }
        controller.setZoom(1)
        controller.go(page)
        await waitDrawn()
        let g = engine.page(page)
        let W = g.width, H = g.height
        func at(_ fx: Double, _ fy: Double) -> PointD { PointD(W * fx, H * fy) }
        let commentsBefore = editor.comments.count, linksBefore = editor.links.count
        func added(_ subtype: String) -> Int { editor.comments.filter { $0.subtype == subtype && $0.author == editor.author }.count }

        // Text marks: the menu command on a selected word, the tool dragged over another, the menu again.
        if words.count >= 3, let text = try? engine.text(page) {
            pages.tool = .text
            pages.select(page, words[0])
            controller.highlightText(nil)
            await settle()
            let w = words[1]
            let a = text.boxAt(w.start), b = text.boxAt(w.end - 1)
            pages.tool = .underline
            await press(page, [PointD(a.x + 0.5, a.centerY), PointD((a.x + b.right) / 2, b.centerY), PointD(b.right - 0.5, b.centerY)])
            pages.tool = .text
            pages.select(page, words[2])
            controller.strikeOutText(nil)
            await settle()
            check(added("Highlight") == 1 && added("Underline") == 1 && added("StrikeOut") == 1,
                  "text marks: highlight (menu), underline (tool drag), strike-out (menu): \(added("Highlight"))/\(added("Underline"))/\(added("StrikeOut"))")
        } else {
            lines.append("SKIP text marks: no page with three words")
        }

        // Note, typewriter line, text box.
        controller.testText = "Self-test note"
        pages.tool = .note
        await press(page, [at(0.85, 0.08)])
        controller.testText = "Typewriter line"
        pages.tool = .textBox
        await press(page, [at(0.1, 0.52)])
        controller.testText = "A text box that wraps its words inside the box"
        await press(page, [at(0.1, 0.6), at(0.3, 0.65), at(0.45, 0.68)])
        let freeTexts = editor.comments.filter { $0.subtype == "FreeText" && $0.author == editor.author }
        let typewriter = freeTexts.contains { $0.style?.color == nil }, boxed = freeTexts.contains { $0.style?.color != nil }
        check(added("Text") == 1 && freeTexts.count == 2 && typewriter && boxed,
              "note and text boxes (click: typewriter, drag: box): \(added("Text")) note, \(freeTexts.count) text boxes")

        // Pen, highlighter.
        pages.tool = .pen
        let wave = (0...40).map { i -> PointD in
            let t = Double(i) / 40
            return PointD(W * (0.55 + 0.35 * t), H * 0.56 + 10 * sin(t * 12))
        }
        await press(page, wave)
        pages.tool = .highlighter
        await press(page, (0...10).map { PointD(W * (0.55 + 0.03 * Double($0)), H * 0.62) })
        let inks = editor.comments.filter { $0.subtype == "Ink" && $0.author == editor.author }
        let thinned = inks.first { $0.style?.highlighter != true }?.geometry?.paths.first?.count ?? 0
        check(inks.count == 2 && inks.contains { $0.style?.highlighter == true } && thinned > 2 && thinned < wave.count,
              "pen and highlighter: \(inks.count) drawings, pen stroke thinned from \(wave.count) to \(thinned) points")

        // Shapes and lines (Shift: a circle, a 45° step).
        pages.tool = .rectangle
        await press(page, [at(0.1, 0.75), at(0.2, 0.8), at(0.3, 0.85)])
        pages.tool = .ellipse
        await press(page, [at(0.35, 0.75), at(0.42, 0.79), at(0.5, 0.8)], shift: true)
        pages.tool = .line
        await press(page, [at(0.55, 0.75), at(0.75, 0.78)])
        pages.tool = .arrow
        await press(page, [at(0.55, 0.82), at(0.75, 0.84)], shift: true)
        let circle = editor.comments.last { $0.subtype == "Circle" }?.geometry?.box ?? .zero
        let arrow = editor.comments.last { $0.subtype == "Line" && $0.style?.endEnding != LineEnding.none }?.geometry?.paths.first ?? []
        let flat = arrow.count == 2 && abs(arrow[0].y - arrow[1].y) < 0.5
        check(added("Square") == 1 && added("Circle") == 1 && added("Line") == 2 && abs(circle.width - circle.height) < 0.5 && flat,
              "rectangle, ellipse (Shift: circle \(Int(circle.width)) x \(Int(circle.height))), line, arrow (Shift: level: \(flat))")

        // Stamp, picture, links.
        pages.stamp = RubberStamps.builtIn[0]
        pages.tool = .stamp
        await press(page, [at(0.7, 0.33)])
        pages.pendingImage = Self.picture()
        pages.tool = .image
        await press(page, [at(0.25, 0.33)])
        let stamps = editor.comments.filter { $0.subtype == "Stamp" && $0.author == editor.author }
        check(stamps.count == 2 && stamps.contains { $0.subject == "Image" }, "stamp (Approved) and picture: \(stamps.count) stamps")
        controller.testLink = ("https://example.com/inkvolt", -1)
        pages.tool = .link
        await press(page, [at(0.1, 0.9), at(0.2, 0.92), at(0.3, 0.94)])
        controller.testLink = (nil, 0)
        await press(page, [at(0.6, 0.92)])
        let newLinks = editor.links.count - linksBefore
        check(newLinks == 2 && editor.links.contains { $0.uri == "https://example.com/inkvolt" } && editor.links.contains { $0.targetPage == 0 },
              "links (dragged to a web address, clicked to page 1): \(newLinks)")
        controller.testText = nil
        controller.testLink = nil
        let addedCount = editor.comments.count - commentsBefore
        check(session.isDirty && controller.pdf.isDocumentEdited && session.canUndo, "\(addedCount) comments added; document edited, undo offered")
        pages.tool = .pen
        await waitDrawn()
        snapshot(controller.window!.contentView!, "1-tools-pen.png")

        // Select the rectangle with the hand tool, move it, resize it with a handle.
        pages.tool = .hand
        guard let rect = editor.comments.last(where: { $0.subtype == "Square" }), let box0 = rect.geometry?.box else {
            check(false, "rectangle to select")
            return finish()
        }
        let edge = PointD(box0.x + 1, box0.centerY)
        await press(page, [edge, PointD(edge.x + 10, edge.y + 8), PointD(edge.x + 30, edge.y + 20)])
        let moved = editor.comment(rect.id)?.geometry?.box ?? .zero
        check(pages.selectedId == rect.id && abs(moved.x - box0.x - 30) < 0.6 && abs(moved.y - box0.y - 20) < 0.6,
              "hand tool: rectangle selected and moved by (\(Int((moved.x - box0.x).rounded())), \(Int((moved.y - box0.y).rounded())))")
        let corner = PointD(moved.right, moved.bottom) // within the handle drawn just outside the corner
        await press(page, [corner, PointD(corner.x + 10, corner.y + 5), PointD(corner.x + 20, corner.y + 10)])
        let resized = editor.comment(rect.id)?.geometry?.box ?? .zero
        check(abs(resized.width - moved.width - 20) < 1 && abs(resized.height - moved.height - 10) < 1 && pages.selectedId == rect.id,
              "bottom-right handle: \(Int(moved.width)) x \(Int(moved.height)) to \(Int(resized.width.rounded())) x \(Int(resized.height.rounded()))")
        pages.keyDown(with: key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124))
        await settle()
        let nudged = editor.comment(rect.id)?.geometry?.box.x ?? 0
        check(abs(nudged - resized.x - 1) < 0.3, "arrow key nudges the selected rectangle 1 pt")
        await waitDrawn()
        snapshot(controller.window!.contentView!, "2-selected-handles.png")

        // The inspector: color, width, opacity of the rectangle.
        controller.showInspector(rect.id)
        if let inspector = controller.inspector {
            await inspector.apply(color: Palette.colors[4].color)
            await inspector.apply(width: 5)
            await inspector.apply(opacity: 0.5)
            let style = editor.comment(rect.id)?.style
            check(style?.color == Palette.colors[4].color && style?.width == 5 && abs((style?.opacity ?? 0) - 0.5) < 0.01,
                  "inspector: color, width and opacity of the rectangle changed (three undo steps)")
            try? await Task.sleep(for: .milliseconds(300))
            snapshot(inspector.view, "3-inspector.png")
            await waitDrawn()
            snapshot(controller.window!.contentView!, "3-inspector-window.png")
        } else {
            check(false, "inspector shown")
        }

        // A note's text, a reply, a reply to the reply.
        if let note = editor.comments.first(where: { $0.subtype == "Text" && $0.author == editor.author }) {
            pages.select(note.id, reveal: true)
            controller.showInspector(note.id)
            if let inspector = controller.inspector {
                await inspector.apply(text: "Edited note")
                await inspector.reply("Self-test reply")
                let reply = editor.comments.first { $0.replyTo == note.id }
                if let reply { await editor.reply(to: reply.id, "Nested reply") }
                let nested = reply.map { r in editor.comments.contains { $0.replyTo == r.id } } ?? false
                check(editor.comment(note.id)?.contents == "Edited note" && reply?.contents == "Self-test reply" && nested,
                      "note text edited; a reply and a reply to it")
                try? await Task.sleep(for: .milliseconds(200))
                snapshot(inspector.view, "4-inspector-note.png")
            }
        }

        // The comments list: all of them, filtered by kind, selecting one selects it on the page.
        controller.showComments(nil)
        let list = controller.sidebar.comments
        let topLevel = editor.comments.filter { c in c.replyTo.map { id in !editor.comments.contains { $0.id == id } } ?? true }.count
        let allShown = list.topCount
        // A kind the document has (the filter menu lists only those).
        let kind = count("Highlight") > 0 ? "Highlight" : "Rectangle"
        list.filter(kind: kind, author: nil)
        let highlights = list.topCount
        list.filter(kind: nil, author: editor.author)
        let mine = list.topCount
        list.filter(kind: nil, author: nil)
        check(allShown == topLevel && highlights == count(kind == "Highlight" ? "Highlight" : "Square") && mine >= addedCount - 2,
              "comments list: \(allShown) comments (\(list.rowCount) rows with replies), \(highlights) of kind \(kind), \(mine) by the author")
        pages.select(rect.id, reveal: true)
        await waitDrawn()
        snapshot(controller.window!.contentView!, "5-comments-sidebar.png")

        // Delete with the keyboard, undo and redo through the window's undo manager.
        if let ellipse = editor.comments.last(where: { $0.subtype == "Circle" }) {
            controller.window?.makeFirstResponder(pages)
            pages.select(ellipse.id)
            let before = editor.comments.count
            pages.keyDown(with: key("\u{7f}", code: 51))
            await settle()
            let afterDelete = editor.comments.count
            let undo = controller.window?.undoManager
            let title = undo?.undoMenuItemTitle ?? ""
            undo?.undo()
            let afterUndo = editor.comments.count
            let redoTitle = undo?.redoMenuItemTitle ?? ""
            undo?.redo()
            let afterRedo = editor.comments.count
            undo?.undo()
            check(afterDelete == before - 1 && afterUndo == before && afterRedo == before - 1 && editor.comments.count == before
                  && title == "Undo Delete Comment" && redoTitle == "Redo Delete Comment",
                  "Delete key, then “\(title)” and “\(redoTitle)”: \(before) → \(afterDelete) → \(afterUndo) → \(afterRedo)")
        }

        // Single keys pick tools while the pages have the focus, never while typing in a field: the menu leaves keys
        // without modifiers to the focused view.
        controller.closePopovers()
        controller.window?.makeFirstResponder(pages)
        let menuTookP = NSApp.mainMenu?.performKeyEquivalent(with: key("p", code: 35)) ?? true
        pages.keyDown(with: key("p", code: 35))
        let after = pages.tool
        controller.showFind(nil)
        let inField = controller.window?.firstResponder is NSText
        let menuTookR = NSApp.mainMenu?.performKeyEquivalent(with: key("r", code: 15)) ?? true
        let afterTyping = pages.tool
        controller.findBar.onDone?()
        let menuTookCmd = NSApp.mainMenu?.items.first { $0.title == "Tools" }?.submenu?.items.contains { $0.keyEquivalent == "h" && $0.keyEquivalentModifierMask == [.command, .control] } ?? false
        check(!menuTookP && after == .pen && inField && !menuTookR && afterTyping == .pen && menuTookCmd,
              "single keys: P on the pages picks the pen (now \(after)); the menu leaves P and R (typed in the find field) "
              + "to the focused view (\(menuTookP)/\(menuTookR)); ⌃⌘H still a menu key")
        pages.tool = .text

        // VoiceOver sees the comments on the page.
        let reachable = pages.accessibilityChildren()?.count ?? 0
        check(reachable > 0, "VoiceOver: \(reachable) comments reachable on the pages in view")

        // Save As into a temporary folder; the file read back by a fresh session.
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-edit-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("edited.pdf"))
        let expected = editor.comments.map(\.subtype).sorted()
        let expectedLinks = editor.links.count
        let saveAsError = await save(target, .saveAsOperation)
        var readBack: [String] = [], readLinks = -1
        if let s = try? DocumentSession.open(target.path, password: session.password) {
            readBack = ((try? Annotations.read(s.data, s.password)) ?? []).filter { !$0.hidden }.map(\.subtype).sorted()
            readLinks = ((try? Links.read(s.data, s.password)) ?? []).count
            s.close()
        }
        check(saveAsError == nil && !controller.pdf.isDocumentEdited && !session.isDirty && controller.pdf.fileURL == target
              && readBack == expected && readLinks == expectedLinks,
              "Save As (a temporary copy): saved, not edited; read back \(readBack.count) of \(expected.count) comments and \(readLinks) of \(expectedLinks) links")

        // Save after another edit.
        await editor.addNote(page: page, at: at(0.05, 0.05), text: "After save", color: nil)
        let dirty = controller.pdf.isDocumentEdited
        let saveError = await save(target, .saveOperation)
        let onDisk = ((try? Annotations.read([UInt8](Data(contentsOf: target)), session.password)) ?? []).filter { !$0.hidden }.count
        check(dirty && saveError == nil && !controller.pdf.isDocumentEdited && onDisk == editor.comments.count,
              "Save: the new note is in the file (\(onDisk) comments), edited dot cleared")

        // Another program changes the file: the bar, then Reload.
        if let handle = try? FileHandle(forWritingTo: target) {
            handle.seekToEndOfFile()
            handle.write(Data("\n% changed by another program\n".utf8))
            try? handle.close()
        }
        controller.checkDisk()
        let barShown = !controller.diskBar.isHidden
        if barShown {
            await waitDrawn()
            snapshot(controller.window!.contentView!, "6-changed-on-disk.png")
        }
        let reloaded = await controller.reloadFromDiskNow()
        check(barShown && reloaded && controller.diskBar.isHidden && !session.canUndo && !session.isDirty,
              "changed on disk: bar shown, Reload read the file again (undo history dropped)")

        // Revert to Saved after an edit.
        let saved = editor.comments.count
        await editor.addNote(page: page, at: at(0.05, 0.2), text: "To revert", color: nil)
        let edited = editor.comments.count
        var reverted = false
        if let url = controller.pdf.fileURL {
            reverted = (try? controller.pdf.revert(toContentsOf: url, ofType: "com.adobe.pdf")) != nil
        }
        check(edited == saved + 1 && reverted && editor.comments.count == saved && !controller.pdf.isDocumentEdited,
              "Revert to Saved: \(edited) → \(editor.comments.count) comments, not edited")

        // A recovery copy of unsaved work.
        await editor.addNote(page: page, at: at(0.05, 0.3), text: "Unsaved", color: nil)
        for _ in 0..<50 where !RecoveryCopies.shared.hasCopy(controller.pdf) { try? await Task.sleep(for: .milliseconds(100)) }
        let copied = RecoveryCopies.shared.hasCopy(controller.pdf)
        check(copied, "recovery copy written \(Report.recoveryInterval) s after an unsaved change")
        finish()
        if Report.crashAfterRecovery && copied && shots {
            Report.write("CRASHING on purpose (recovery test)")
            kill(getpid(), SIGKILL)
        }
    }

    /// After `--restore-recovery`: the document came back from its copy, with its changes, unsaved.
    mutating func checkRecovered() async {
        guard let session = controller.pdf.session else { return }
        lines.append("== \(name): recovered")
        let unsaved = editor.comments.contains { $0.contents == "Unsaved" }
        check(session.isDirty && controller.pdf.isDocumentEdited && unsaved && editor.comments.count > 5,
              "restored from its recovery copy: \(editor.comments.count) comments, the last unsaved note there, edited")
        finish()
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    /// Saves through NSDocument (as File › Save and Save As do), waiting for it; the error, if any.
    private func save(_ url: URL, _ operation: NSDocument.SaveOperationType) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            controller.pdf.save(to: url, ofType: "com.adobe.pdf", for: operation) { error in
                done.resume(returning: error.map { "\($0.localizedDescription)" })
            }
        }
    }

    /// The words (runs of letters) of a page's text, as UTF-16 ranges.
    static func words(_ t: PageText) -> [(start: Int, end: Int)] {
        var found: [(start: Int, end: Int)] = []
        var start = -1
        let units = Array(t.text.utf16)
        for (i, u) in units.enumerated() {
            let letter = u < 128 ? (UInt8(u) >= 65 && UInt8(u) <= 90) || (UInt8(u) >= 97 && UInt8(u) <= 122) : false
            if letter && start < 0 { start = i }
            if !letter && start >= 0 {
                if i - start >= 4 { found.append((start, i)) }
                start = -1
            }
            if found.count >= 6 { break }
        }
        return found
    }

    /// A 64 x 48 picture with a gradient and a transparent corner.
    static func picture() -> StampImage {
        let w = 64, h = 48
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        var alpha = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                rgb[i * 3] = UInt8(x * 4)
                rgb[i * 3 + 1] = UInt8(y * 5)
                rgb[i * 3 + 2] = 200
                if x + y < 20 { alpha[i] = 0 }
            }
        }
        return StampImage(w, h, rgb, alpha)
    }
}

/// A three-page PDF made here, for the editing self-test and its snapshots (no real document's content): two pages of
/// plain text and a "scan" (a picture of a line of words, no text layer) for text recognition and picture editing.
enum SyntheticPdf {
    static func make() -> [UInt8] {
        let lines = [
            "Inkvolt PDF self-test document",
            "Highlight these words, underline others and strike some out.",
            "Notes, text boxes, drawings, stamps, pictures and links go here.",
            "The quick brown fox jumps over the lazy dog.",
            "Pack my box with five dozen liquor jugs.",
        ]
        func content(_ title: String) -> String {
            var s = "BT /F1 20 Tf 72 740 Td (\(title)) Tj ET\nBT /F1 12 Tf 72 700 Td 18 TL\n"
            for l in lines { s += "(\(l)) Tj T*\n" }
            s += "ET\n0.6 G 72 600 m 540 600 l S\n"
            return s
        }
        let c1 = content("Page one"), c2 = content("Page two")
        let scan = scanImage()
        let c3 = "q 400 0 0 100 72 600 cm /Im1 Do Q\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 8 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Length \(c1.utf8.count) >>\nstream\n\(c1)endstream",
            "<< /Length \(c2.utf8.count) >>\nstream\n\(c2)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 9 0 R /Resources << /XObject << /Im1 10 0 R >> >> >>",
            "<< /Length \(c3.utf8.count) >>\nstream\n\(c3)endstream",
            "<< /Type /XObject /Subtype /Image /Width \(scan.width) /Height \(scan.height) /ColorSpace /DeviceGray /BitsPerComponent 8 "
                + "/Filter /ASCIIHexDecode /Length \(scan.hex.utf8.count) >>\nstream\n\(scan.hex)\nendstream",
        ]
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
}
