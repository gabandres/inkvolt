import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for D7 part d (`--edit`, after `FeatureTest`): links clicked on the page (a page, a web
/// address, an address that asks first); a text selection dragged across two pages and highlighted as one step; the
/// organizer and the page commands (rotate, duplicate, reverse, insert blank, from a PDF and from a picture, move by the grid's
/// drop, crop, the thumbnails' context menu, delete, undo); bookmarks (add, rename, move, nest, delete); password
/// protection through its sheet, then removed; Extract Pages' file per page and new document, Split Document… by a
/// page count and at the bookmarks; File › Document Properties… (its rows, the title and subject changed as
/// one undo step, undone); printing to PDF files in a temporary folder with four layouts (never a
/// printer); and the close question answered Cancel, then Save. Every result saved into a temporary folder and read
/// back. Only counts and kinds are written, never a document's text or its name.
@MainActor
struct PagesTest {
    /// A document this test opens itself (Extract Pages' new document): not tested as a document of its own.
    private(set) static var opensDocument = false
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0
    private let shots: Bool
    private let folder: String

    init(controller: DocumentWindowController, name: String, openedFrom path: String?) {
        self.controller = controller
        self.name = name
        shots = Report.snapshots != nil && path != nil && path == Report.syntheticPath
        folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-pages-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private var pages: PagesView { controller.pages }
    private var editor: DocumentEditor { controller.editor }
    private var session: DocumentSession? { controller.pdf.session }
    private var count: Int { controller.engine.pageCount }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private mutating func skip(_ what: String) { lines.append("SKIP \(what)") }

    private func path(_ file: String) -> URL { URL(fileURLWithPath: (folder as NSString).appendingPathComponent(file)) }

    // MARK: Driving the app

    private func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: pages.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// A press through points on (possibly different) pages, as the mouse makes it; waits for what it started.
    private func press(_ points: [(page: Int, p: PointD)]) async {
        let view = points.map { pages.viewPoint($0.p, pages.pageRects[$0.page]) }
        pages.mouseDown(with: event(.leftMouseDown, view[0]))
        for p in view.dropFirst() { pages.mouseDragged(with: event(.leftMouseDragged, p)) }
        pages.mouseUp(with: event(.leftMouseUp, view[view.count - 1]))
        await pages.pendingEdit?.value
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// Waits (up to 30 s) for the next edit to end (menu commands start theirs in a task): true when it made the undo step
    /// named `label`.
    private func waitEdit(_ label: String, since step: (id: Int?, edits: Int)) async -> Bool {
        trace("waiting for " + label)
        for _ in 0..<600 where editor.finishedEdits == step.edits {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(20))
        return session?.undoLabel == label && session?.undoStepId != step.id
    }

    /// Where the edits stand now (for `waitEdit`).
    private var mark: (id: Int?, edits: Int) { (session?.undoStepId, editor.finishedEdits) }

    /// Sends a menu command to the window (as choosing it in the menu bar does for the key window) and waits for its edit.
    private func menu(_ action: Selector, expect label: String) async -> Bool {
        let before = mark
        NSApp.sendAction(action, to: controller, from: nil)
        return await waitEdit(label, since: before)
    }

    private func texts() -> [String] { (0..<count).map { (try? controller.engine.text($0))?.text ?? "" } }

    private mutating func snapshot(_ file: String) {
        guard shots, let dir = Report.snapshots, let view = controller.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return check(false, "snapshot \(file): no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        let ok = (try? png?.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(file)))) != nil
        check(ok, "snapshot \(file): \(rep.pixelsWide) x \(rep.pixelsHigh) px")
    }

    // MARK: The scenario

    mutating func run() async {
        guard session != nil else {
            Report.write("== \(name): pages, bookmarks, passwords, print, links\nRESULT: FAIL (no session)")
            return
        }
        let started = Date()
        lines.append("== \(name): pages, bookmarks, passwords, print, links (\(count) pages)")
        controller.closePopovers()
        controller.setZoom(1)
        controller.go(0)
        trace("links")
        await links()
        trace("selection")
        await selectionAcrossPages()
        trace("comment tools")
        await commentTools()
        trace("organize")
        if await organize() {
            trace("bookmarks")
            await bookmarks()
            trace("passwords")
            await passwords()
        }
        trace("extract and split")
        await extractAndSplit()
        trace("document properties")
        await documentProperties()
        trace("print")
        await printing()
        trace("printer status")
        await printerStatus()
        trace("close question")
        await closeQuestion()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
        Report.note("pages took \(Int(Date().timeIntervalSince(started))) s")
    }

    /// Printing alone (`--only-print`): to PDF files, as vectors and as pictures, and the panel's printer status.
    mutating func runPrinting() async {
        guard session != nil else { return Report.write("== \(name): print\nRESULT: FAIL (no session)") }
        lines.append("== \(name): print (\(count) pages)")
        await printing()
        await printerStatus()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    // MARK: Links

    private mutating func links() async {
        let g = controller.engine.page(0)
        let last = count - 1
        func box(_ fy: Double) -> RectD { RectD(g.width * 0.01, g.height * fy, max(g.width * 0.05, 8), max(g.height * 0.02, 8)) }
        let a = await editor.addLink(page: 0, rect: box(0.30), uri: nil, target: last)
        let b = await editor.addLink(page: 0, rect: box(0.40), uri: "https://example.com/inkvolt-d7d", target: -1)
        let c = await editor.addLink(page: 0, rect: box(0.50), uri: "ftp://example.com/inkvolt-d7d.txt", target: -1)
        guard a && b && c else {
            if editor.lastOutcome == .declined { return skip("links: the document refuses changes without its permissions password") }
            return check(false, "links added for clicking (\(a)/\(b)/\(c))")
        }
        controller.testOpenedLinks = []
        controller.testLinkAnswer = false
        pages.tool = .text
        let asked0 = controller.linkQuestions
        func center(_ r: RectD) -> PointD { PointD(r.centerX, r.centerY) }
        controller.go(0)
        await press([(0, center(box(0.30)))])
        let jumped = count == 1 || pages.currentPage == last
        controller.go(0)
        await press([(0, center(box(0.40)))])
        let web = controller.testOpenedLinks ?? []
        let askedWeb = controller.linkQuestions - asked0
        await press([(0, center(box(0.50)))])
        let declined = controller.testOpenedLinks ?? []
        controller.testLinkAnswer = true
        await press([(0, center(box(0.50)))])
        let opened = controller.testOpenedLinks ?? []
        let asked = controller.linkQuestions - asked0
        // A press that starts on a link and moves away selects text instead of following it.
        let r = box(0.40)
        await press([(0, center(r)), (0, PointD(r.right + 30, r.centerY + 4)), (0, PointD(r.right + 60, r.centerY + 8))])
        let notFollowed = (controller.testOpenedLinks ?? []).count == opened.count
        controller.testOpenedLinks = nil
        check(jumped && web == ["https://example.com/inkvolt-d7d"] && askedWeb == 0 && declined.count == 1 && opened.count == 2 && asked == 2
              && notFollowed,
              "links clicked: to page \(last + 1) (went: \(jumped)), a web address opened without asking, another address asked first "
              + "(declined, then opened), a drag from a link didn't follow it")
        pages.clearSelection()
    }

    // MARK: Selection across pages

    private mutating func selectionAcrossPages() async {
        var spot: (page: Int, a: RectD, b: RectD)?
        for p in 0..<max(min(count - 1, 20), 0) {
            guard let t0 = try? controller.engine.text(p), let t1 = try? controller.engine.text(p + 1) else { continue }
            let w0 = EditTest.words(t0), w1 = EditTest.words(t1)
            if w0.count >= 5 && w1.count >= 5 {
                spot = (p, t0.boxAt(w0[4].start), t1.boxAt(w1[4].start))
                break
            }
        }
        guard let spot else { return skip("selection across pages: no two pages in a row with text") }
        controller.setZoom(1)
        controller.go(spot.page)
        pages.tool = .text
        let p0 = spot.page, p1 = spot.page + 1
        let start = PointD(spot.a.x + 0.5, spot.a.centerY), end = PointD(spot.b.right - 0.5, spot.b.centerY)
        let middle = PointD(start.x, controller.engine.page(p0).height - 2)
        await press([(p0, start), (p0, middle), (p1, PointD(end.x, 2)), (p1, end)])
        let spans = pages.selectedSpans
        let text = pages.selectedText ?? ""
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.bermudezsystems.InkvoltPdf.selftest"))
        let copied = pages.copySelection(to: pasteboard) && pasteboard.string(forType: .string) == text
        pasteboard.releaseGlobally()
        let before = editor.comments.count
        let stepBefore = session?.undoStepId
        controller.highlightText(nil)
        await pages.pendingEdit?.value
        let added = editor.comments.count - before
        let oneStep = session?.undoLabel == loc("Highlight") && session?.undoStepId != stepBefore
        controller.pdf.undo()
        let undone = editor.comments.count == before
        controller.pdf.redo()
        check(spans.count == 2 && spans[0].page == p0 && spans[1].page == p1 && text.contains("\n") && copied && added == 2 && oneStep && undone
              && editor.comments.count == before + 2,
              "text selected from page \(p0 + 1) to page \(p1 + 1) by dragging (\(text.utf16.count) characters, copied), highlighted as one "
              + "undo step (\(added) highlights), undone and redone")
    }

    // MARK: Callout, polygon, polyline; moving and recoloring notes and text marks

    private func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private mutating func commentTools() async {
        let g = controller.engine.page(0)
        func at(_ fx: Double, _ fy: Double) -> PointD { PointD(g.width * fx, g.height * fy) }
        func mine(_ subtype: String) -> [AnnotationInfo] { editor.comments.filter { $0.subtype == subtype && $0.author == editor.author } }
        controller.setZoom(1)
        controller.go(0)
        controller.closePopovers()
        let polygons0 = mine("Polygon").count, polylines0 = mine("PolyLine").count
        let callouts0 = mine("FreeText").filter { $0.geometry?.callout.isEmpty == false }.count

        // Callout: pressed at the tip, released where the text goes.
        controller.testText = "Self-test callout"
        pages.tool = .callout
        await press([(0, at(0.62, 0.22)), (0, at(0.64, 0.24)), (0, at(0.66, 0.25))])
        controller.testText = nil
        let callouts = mine("FreeText").filter { $0.geometry?.callout.isEmpty == false }
        let callout = callouts.last
        let tipOk = callout.map { c in abs((c.geometry?.callout.first?.x ?? 0) - g.width * 0.62) < 0.6 } ?? false
        // Polygon: three clicks, then a click on the first corner; polyline: three clicks, then Return.
        pages.tool = .polygon
        for p in [at(0.05, 0.47), at(0.2, 0.47), at(0.12, 0.5), at(0.05, 0.47)] { await press([(0, p)]) }
        pages.tool = .polyline
        for p in [at(0.55, 0.47), at(0.65, 0.5), at(0.75, 0.47)] { await press([(0, p)]) }
        controller.window?.makeFirstResponder(pages)
        pages.keyDown(with: key("\r", code: 36))
        await pages.pendingEdit?.value
        let polygon = mine("Polygon").last, polyline = mine("PolyLine").last
        check(callouts.count == callouts0 + 1 && tipOk && callout.map(DocumentEditor.kindName) == loc("Callout")
              && mine("Polygon").count == polygons0 + 1 && polygon?.geometry?.paths.first?.count == 3
              && mine("PolyLine").count == polylines0 + 1 && polyline?.geometry?.paths.first?.count == 3,
              "callout (tip where pressed, box where released), polygon (closed on its first corner), polyline (ended with Return)")

        // A note and a highlight moved with the hand tool, then recolored (the strip's color, the inspector's).
        let highlightsBefore = Set(mine("Highlight").map(\.id))
        let noted = await editor.addNote(page: 0, at: at(0.5, 0.13), text: "Move me", color: nil)
        // Where no form field is (a press on a field fills it instead).
        let spots: [Double] = [0.18, 0.06, 0.94, 0.3, 0.7]
        let fy = spots.first { y in controller.form.widget(page: 0, PointD(g.width * 0.45 + 50, g.height * y + 6)) == nil } ?? 0.18
        let marked = await editor.markText(.highlight, page: 0, rects: [RectD(g.width * 0.45, g.height * fy, 100, 12)], color: .yellow)
        guard noted && marked, let note = mine("Text").last(where: { $0.contents == "Move me" }),
              let marker = mine("Highlight").first(where: { !highlightsBefore.contains($0.id) }) else {
            return check(false, "a note and a highlight to move")
        }
        pages.tool = .hand
        // Each selected first (a press picks the selected comment before others in the same place).
        pages.select(note.id)
        let n0 = PointD(note.rect.centerX, note.rect.centerY)
        await press([(0, n0), (0, PointD(n0.x + 20, n0.y + 10)), (0, PointD(n0.x + 40, n0.y + 20))])
        let movedNote = editor.comment(note.id)?.rect ?? .zero
        let noteTitle = controller.window?.undoManager?.undoMenuItemTitle ?? ""
        pages.select(marker.id)
        let m0 = PointD(marker.quadRects[0].centerX, marker.quadRects[0].centerY)
        await press([(0, m0), (0, PointD(m0.x, m0.y + 15)), (0, PointD(m0.x, m0.y + 30))])
        let movedMark = editor.comment(marker.id)?.quadRects.first ?? .zero
        let markPicked = pages.selectedId == marker.id
        check(abs(movedNote.x - note.rect.x - 40) < 0.6 && abs(movedNote.y - note.rect.y - 20) < 0.6 && noteTitle == Shown.undo(loc("Move"))
              && abs(movedMark.y - marker.quadRects[0].y - 30) < 0.6 && abs(movedMark.x - marker.quadRects[0].x) < 0.6,
              "hand tool moved a note by (\(Int((movedNote.x - note.rect.x).rounded())), \(Int((movedNote.y - note.rect.y).rounded()))) "
              + "(“\(noteTitle)”) and a highlight by (\(Int((movedMark.x - marker.quadRects[0].x).rounded())), "
              + "\(Int((movedMark.y - marker.quadRects[0].y).rounded())))\(markPicked ? "" : " (another comment was picked)")")
        let blue = Palette.colors[4].color, green = Palette.colors[3].color
        pages.select(note.id)
        let step = mark
        controller.applyColor(blue)
        _ = await waitEdit(loc("Change Color"), since: step)
        var inspected = false
        pages.select(marker.id)
        controller.showInspector(marker.id)
        if let inspector = controller.inspector { inspected = await inspector.apply(color: green) }
        controller.closePopovers()
        check(editor.comment(note.id)?.color == blue && inspected && editor.comment(marker.id)?.color == green,
              "note recolored from the tool strip, highlight from the inspector")

        let saved = path("comments.pdf")
        let error = await saveAs(saved)
        let back = (try? Data(contentsOf: saved)).flatMap { try? Annotations.read([UInt8]($0), session?.password) } ?? []
        let backNote = back.first { $0.id == note.id }, backMark = back.first { $0.id == marker.id }
        check(error == nil && back.contains { $0.subtype == "Polygon" } && back.contains { $0.subtype == "PolyLine" }
              && back.contains { $0.geometry?.callout.isEmpty == false } && backNote?.color == blue && backMark?.color == green
              && abs((backNote?.rect.x ?? 0) - movedNote.x) < 0.6 && abs((backMark?.quadRects.first?.y ?? 0) - movedMark.y) < 0.6,
              "saved and read back: the callout, polygon and polyline, the moved and recolored note and highlight")
        pages.tool = .text
    }

    // MARK: Organize pages

    private mutating func organize() async -> Bool {
        let n0 = count
        let original = texts()
        let g0 = controller.engine.page(0)
        controller.showOrganizer(true)
        guard let grid = controller.organizer else {
            check(false, "organizer shown")
            return false
        }
        let cards = grid.pageCount
        check(controller.organizerShown && cards == n0 && controller.scrollView.isHidden, "Organize Pages: \(cards) cards for \(n0) pages")

        // Rotate right and left (menu commands on the card chosen).
        grid.select([0])
        let right = await menu(#selector(DocumentWindowController.rotatePagesRight(_:)), expect: loc("Rotate 1 page"))
        if !right && editor.lastOutcome == .declined {
            controller.showOrganizer(false)
            skip("organize, bookmarks, passwords: the document refuses changes without its permissions password")
            return false
        }
        let turned = controller.engine.page(0)
        let left = await menu(#selector(DocumentWindowController.rotatePagesLeft(_:)), expect: loc("Rotate 1 page"))
        let back = controller.engine.page(0)
        check(right && left && abs(turned.width - g0.height) < 0.5 && abs(back.width - g0.width) < 0.5,
              "rotate right, then left (Pages menu on the chosen card): \(Int(g0.width))×\(Int(g0.height)) → \(Int(turned.width))×\(Int(turned.height)) → back")

        // Duplicate, insert blank, insert from a PDF (an extracted page) and from a picture.
        grid.select([0])
        let dup = await menu(#selector(DocumentWindowController.duplicatePages(_:)), expect: loc("Duplicate 1 page"))
        grid.select([0])
        let blank = await menu(#selector(DocumentWindowController.insertBlankPage(_:)), expect: loc("Insert 1 page"))
        let blankEmpty = ((try? controller.engine.text(1))?.isEmpty ?? false) && abs(controller.engine.page(1).width - g0.width) < 0.5
        let extracted = path("extracted.pdf")
        let wrote = controller.extract([0], to: extracted)
        let extractedPages = (try? PdfEngine.open([UInt8](Data(contentsOf: extracted))))?.pageCount ?? -1
        var step = mark
        controller.insertFiles([extracted], at: count)
        let fromFile = await waitEdit(loc("Insert 1 page from {0}", "extracted.pdf"), since: step)
        let picture = path("picture.png")
        let pictureWritten = Self.writePicture(picture)
        step = mark
        controller.insertFiles([picture], at: count)
        let fromPicture = await waitEdit(loc("Insert 1 page from {0}", "picture.png"), since: step)
        let pictureSize = controller.engine.page(count - 1)
        check(dup && blank && blankEmpty && wrote && extractedPages == 1 && fromFile && pictureWritten && fromPicture && count == n0 + 4,
              "duplicate, insert blank (same size, no text), extract (\(extractedPages) page), insert from that PDF and from a picture: "
              + "\(n0) → \(count) pages")

        // Move the picture's page to the front by the grid's drop.
        grid.select([count - 1])
        step = mark
        grid.drop(grid.selectedPages, before: 0)
        let moved = await waitEdit(loc("Move 1 page"), since: step)
        let front = controller.engine.page(0)
        check(moved && abs(front.width - pictureSize.width) < 0.5 && abs(front.height - pictureSize.height) < 0.5 && grid.selectedPages == [0],
              "dragged the last card to the front: the picture's page is page 1, still chosen")
        snapshot("7-organizer.png")

        // Crop page 2 (the original first page) by half an inch, then remove the crop.
        let cropped = await controller.cropPages([1], margins: Margins(36, 36, 36, 36))
        let small = controller.engine.page(1)
        let uncropped = await controller.cropPages([1], margins: nil)
        let whole = controller.engine.page(1)
        check(cropped && uncropped && abs(small.width - (g0.width - 72)) < 0.6 && abs(small.height - (g0.height - 72)) < 0.6
              && abs(whole.width - g0.width) < 0.5,
              "crop by ½ inch: \(Int(g0.width))×\(Int(g0.height)) → \(Int(small.width.rounded()))×\(Int(small.height.rounded())), crop removed")

        // The sidebar's thumbnails: their context menu's Rotate Right on the thumbnail chosen.
        controller.showOrganizer(false)
        controller.sidebar.show(.pages)
        controller.sidebar.selectPages([1])
        var viaSidebar = false
        if let item = controller.sidebar.thumbMenu(row: 1)?.items.first(where: { $0.title == loc("Rotate Right") }), let action = item.action {
            step = mark
            NSApp.sendAction(action, to: item.target, from: item)
            viaSidebar = await waitEdit(loc("Rotate 1 page"), since: step)
        }
        let sideTurned = controller.engine.page(1)
        controller.pdf.undo()
        check(viaSidebar && abs(sideTurned.width - g0.height) < 0.5 && abs(controller.engine.page(1).width - g0.width) < 0.5,
              "thumbnail context menu: Rotate Right on page 2, then undone")

        // Reverse Page Order: the pages in the opposite order, the chosen page chosen at its mirrored place; undone.
        controller.showOrganizer(true)
        let order = texts()
        grid.select([1])
        let reversed = await menu(#selector(DocumentWindowController.reversePageOrder(_:)), expect: loc("Reverse page order"))
        let mirrored = texts() == Array(order.reversed()) && grid.selectedPages == [count - 2]
        controller.pdf.undo()
        check(reversed && mirrored && texts() == order, "Reverse Page Order (Pages menu): \(count) pages reversed, page 2 chosen at page \(count - 1), undone")

        // Delete the four added pages (picture, copy, blank, inserted copy) with the Delete key in the grid.
        controller.showOrganizer(true)
        let added = [0, 2, 3, count - 1]
        grid.select(added)
        step = mark
        controller.window?.makeFirstResponder(grid.grid)
        grid.grid.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "\u{7f}",
                                                 charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!)
        let deleted = await waitEdit(loc("Delete {0} pages", 4), since: step)
        let same = texts() == original
        let undo = controller.window?.undoManager
        let title = undo?.undoMenuItemTitle ?? ""
        undo?.undo()
        let restored = count
        undo?.redo()
        check(deleted && count == n0 && same && title == Shown.undo(loc("Delete {0} pages", 4)) && restored == n0 + 4,
              "Delete key on four chosen cards: \(n0 + 4) → \(count) pages, the original pages left in order; “\(title)” brings them back")

        // Save As, read back.
        let saved = path("organized.pdf")
        let error = await saveAs(saved)
        let reread = (try? DocumentSession.open(saved.path, password: session?.password))
        let backTexts = reread.map { s in (0..<s.engine.pageCount).map { (try? s.engine.text($0))?.text ?? "" } } ?? []
        reread?.close()
        check(error == nil && backTexts == original, "saved and read back: \(backTexts.count) pages, as they were")
        controller.showOrganizer(false)
        return true
    }

    // MARK: Bookmarks

    private func countAll(_ list: [Bookmark]) -> Int { list.reduce(0) { $0 + 1 + countAll($1.children) } }

    private mutating func bookmarks() async {
        let start = controller.readBookmarks()
        let b0 = start.count
        let last = count - 1
        controller.go(0)
        controller.testText = "Self-test bookmark A"
        let added = await menu(#selector(DocumentWindowController.addBookmark(_:)), expect: loc("Add bookmark “{0}”", "Self-test bookmark A"))
        controller.go(last)
        controller.testText = "Self-test bookmark B"
        let second = await menu(#selector(DocumentWindowController.addBookmark(_:)), expect: loc("Add bookmark “{0}”", "Self-test bookmark B"))
        var tree = controller.readBookmarks()
        let placed = tree.count == b0 + 2 && tree[b0].title == "Self-test bookmark A" && tree[b0].pageIndex == 0
            && tree[b0 + 1].title == "Self-test bookmark B" && tree[b0 + 1].pageIndex == last
        check(added && second && placed && controller.sidebar.outlineCount == countAll(tree),
              "Add Bookmark (⌘D) twice: for page 1 and page \(last + 1), the second after the first (\(countAll(tree)) in the sidebar)")

        controller.testText = "Self-test bookmark C"
        var step = mark
        controller.sidebar.onRenameBookmark?([b0 + 1])
        let renamed = await waitEdit(loc("Rename bookmark to “{0}”", "Self-test bookmark C"), since: step)
        controller.testText = nil
        step = mark
        controller.sidebar.dropBookmark([b0 + 1], parent: [], index: b0)
        let reordered = await waitEdit(loc("Move bookmark “{0}”", "Self-test bookmark C"), since: step)
        tree = controller.readBookmarks()
        let order = tree.count == b0 + 2 && tree[b0].title == "Self-test bookmark C" && tree[b0 + 1].title == "Self-test bookmark A"
        step = mark
        controller.sidebar.dropBookmark([b0 + 1], parent: [b0], index: 0)
        let nested = await waitEdit(loc("Move bookmark “{0}”", "Self-test bookmark A"), since: step)
        tree = controller.readBookmarks()
        let under = tree.count == b0 + 1 && tree[b0].children.count == 1 && tree[b0].children[0].title == "Self-test bookmark A"
        check(renamed && reordered && order && nested && under,
              "bookmarks renamed, dragged before another, and dragged under it")

        let saved = path("bookmarks.pdf")
        let error = await saveAs(saved)
        var readBack: [Bookmark] = []
        if let bytes = try? [UInt8](Data(contentsOf: saved)) { readBack = (try? Bookmarks.read(bytes, session?.password)) ?? [] }
        let kept = readBack.count == b0 + 1 && readBack[b0].title == "Self-test bookmark C" && readBack[b0].pageIndex == last
            && readBack[b0].children.first?.pageIndex == 0
        step = mark
        controller.sidebar.onDeleteBookmark?([b0])
        let deleted = await waitEdit(loc("Delete bookmark “{0}” and {1} inside it", "Self-test bookmark C", 1), since: step)
        let after = controller.readBookmarks()
        check(error == nil && kept && deleted && after.count == b0 && countAll(after) == countAll(start) && controller.sidebar.outlineCount == countAll(after),
              "saved and read back (\(countAll(readBack)) bookmarks), then deleted with the one inside it (\(countAll(after)) left)")
    }

    // MARK: Passwords

    /// Pages › Extract Pages…' file per page and new document, and Split Document… by a page count (twice: the names
    /// taken get numbers, nothing is replaced) and at the bookmarks, into a temporary folder; each file read back.
    private mutating func extractAndSplit() async {
        let n = count
        guard n >= 2, let s = session else { return lines.append("SKIP extract and split: needs two pages") }
        let dir = path("split").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func pageCounts(_ paths: [String]) -> [Int] {
            paths.map { p in (try? PdfEngine.open([UInt8]((try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data())))?.pageCount ?? -1 }
        }
        let perPage = await controller.extractPerPage([0, 1], to: dir) ?? []
        let perPageOk = pageCounts(perPage) == [1, 1] && perPage.first?.hasSuffix(Shown.tail(loc("{0} (page {1}).pdf", Shown.gap, 1))) == true
        Self.opensDocument = true
        let made = controller.extractToNewDocument([0, 1])
        let newOk = made?.engine?.pageCount == 2 && made?.fileURL == nil
        made?.close()
        Self.opensDocument = false

        let name = (s.displayName as NSString).deletingPathExtension
        let byCount = SplitFiles.parts(.pageCount, pageCount: n, pagesPerFile: "2", ranges: "", outline: [])
        let first = SplitFiles.targets(byCount.parts, mode: .pageCount, folder: dir, pattern: "{name} (part {n})", name: name).paths
        let splitOk = await controller.split(byCount.parts, to: first)
        let second = SplitFiles.targets(byCount.parts, mode: .pageCount, folder: dir, pattern: "{name} (part {n})", name: name).paths
        let againOk = await controller.split(byCount.parts, to: second)
        let sizes: [Int] = byCount.parts.map(\.pages.count)
        let firstCounts = pageCounts(first), secondCounts = pageCounts(second)
        let numbered = Set(first).isDisjoint(with: second) && second.first?.hasSuffix("(part 1) (2).pdf") == true
        let counted = firstCounts == sizes && secondCounts == sizes && numbered

        let outline = (try? controller.engine.outline()) ?? []
        var marks = "no bookmarks to split at"
        var marksOk = true
        if !outline.isEmpty {
            let byMarks = SplitFiles.parts(.bookmarks, pageCount: n, pagesPerFile: "", ranges: "", outline: outline)
            let paths = SplitFiles.targets(byMarks.parts, mode: .bookmarks, folder: dir, pattern: "{name} (part {n})", name: name).paths
            marksOk = await controller.split(byMarks.parts, to: paths) && pageCounts(paths).reduce(0, +) == n
            marks = "\(byMarks.parts.count) files at the bookmarks"
        }
        check(perPageOk && newOk && splitOk && againOk && counted && marksOk,
              "Extract Pages: a file per page (2) and a new document (2 pages); Split Document: \(byCount.parts.count) files of up to 2 pages, "
              + "again with numbered names (none replaced), \(marks)")
    }

    /// File › Document Properties…: the rows Windows shows (file, location, size, pages, page size, PDF version,
    /// security), then Title and Subject changed through it as one undo step, read back and undone.
    private mutating func documentProperties() async {
        guard let s = session, let before = try? PageEditor.readMetadata(s.data, s.password) else {
            return check(false, "Document Properties: the metadata read")
        }
        let item = NSApp.mainMenu?.items.first { $0.title == loc("File") }?.submenu?.items.first { $0.title == loc("Document Properties…") }
        let enabled = item.map { controller.validateMenuItem($0) } == true && item?.keyEquivalent == "i"
        DocumentPropertiesState.testAnswer = nil
        await controller.askDocumentProperties()
        let labels = DocumentPropertiesState.lastRows.map(\.label)
        let security = DocumentPropertiesState.lastRows.first { $0.label == loc("Security") }?.value ?? ""
        let rows = labels.starts(with: [loc("File"), loc("Location"), loc("File size"), loc("Pages"), loc("Page size"), loc("PDF version"), loc("Security")])
            && (s.hasEncryption || security == loc("Not protected"))
        let signed = s.data.firstRange(of: Array("/ByteRange".utf8)) != nil
        DocumentPropertiesState.testAnswer = ("Self-test title", before.author, "Self-test subject", before.keywords)
        let edited = await menu(#selector(DocumentWindowController.showDocumentProperties(_:)), expect: loc("Edit document properties"))
        DocumentPropertiesState.testAnswer = nil
        if !edited && signed && editor.lastOutcome == .declined {
            return check(enabled && rows, "Document Properties: \(labels.count) rows; a signed file's rewrite asked first and declined")
        }
        let after = session.flatMap { try? PageEditor.readMetadata($0.data, $0.password) }
        controller.pdf.undo()
        let undone = session.flatMap { try? PageEditor.readMetadata($0.data, $0.password) }
        check(enabled && rows && edited && after?.title == "Self-test title" && after?.subject == "Self-test subject" && undone?.title == before.title,
              "File › Document Properties… (⇧⌘I): \(labels.count) rows (file to security, “\(security)”), title and subject changed as one "
              + "undo step, undone")
    }

    private mutating func passwords() async {
        let signed = (session?.data ?? []).firstRange(of: Array("/ByteRange".utf8)) != nil
        let wasEncrypted = session?.hasEncryption == true
        controller.protectDocument(nil)
        guard let sheet = controller.protectSheet else { return check(false, "Protect with Password sheet shown") }
        sheet.needOpen.state = .on
        sheet.restrict.state = .on
        sheet.openField.stringValue = "selftest-open"
        sheet.openConfirm.stringValue = "selftest-typo"
        sheet.ownerField.stringValue = "selftest-owner"
        sheet.ownerConfirm.stringValue = "selftest-owner"
        sheet.copy.state = .off
        sheet.printing.selectItem(at: 1)
        sheet.protectClicked()
        let refused = !sheet.problem.stringValue.isEmpty && controller.protectSheet != nil
        sheet.openConfirm.stringValue = "selftest-o,pen"
        sheet.openField.stringValue = "selftest-o,pen"
        sheet.protectClicked()
        let comma = sheet.problem.stringValue.contains(loc("Inkvolt PDF for Mac can't use a comma in a password. Choose one without a comma.")) && controller.protectSheet != nil
        sheet.openField.stringValue = "selftest-open"
        sheet.openConfirm.stringValue = "selftest-open"
        let step = mark
        sheet.protectClicked()
        let label = wasEncrypted ? loc("Change password protection") : loc("Protect with password")
        let protected = await waitEdit(label, since: step)
        if !protected && signed && editor.lastOutcome == .declined {
            check(refused && comma, "protect: a signed file's rewrite asked first and declined (it would break the signatures); "
                  + "mismatched and comma passwords refused in the sheet")
            return
        }
        let saved = path("protected.pdf")
        let error = await saveAs(saved)
        var asksPassword = false
        do { _ = try DocumentSession.open(saved.path).close() } catch is PasswordRequired { asksPassword = true } catch {}
        let reopened = try? DocumentSession.open(saved.path, password: "selftest-open")
        let opens = reopened != nil
        reopened?.close()
        let info = (try? Data(contentsOf: saved)).flatMap { try? PdfSecurity.readSecurity([UInt8]($0), "selftest-open") }
        let rightInfo = info?.method == .aes256 && info?.requiresOpenPassword == true && info?.permissions.copy == false
            && info?.permissions.print == .lowResolution && info?.permissions.modify == true
        check(refused && comma && protected && error == nil && asksPassword && opens && rightInfo,
              "Protect with Password (its sheet; a mismatch and a comma refused first): saved file asks for its password, opens with it, "
              + "AES-256, copying off, low-resolution printing")

        // An edit afterwards keeps it protected; then Remove Protection.
        let noted = await editor.addNote(page: 0, at: PointD(12, 12), text: "Protected", color: nil)
        let stillLocked = session.map { PdfSecurity.needsOpenPassword($0.data) } ?? false
        let removeStep = session?.undoStepId
        let removed = await controller.removeProtectionNow()
        let removedLabel = session?.undoLabel == loc("Remove password protection") && session?.undoStepId != removeStep
        let plain = path("unprotected.pdf")
        let error2 = await saveAs(plain)
        let free = (try? DocumentSession.open(plain.path)).map { s in
            let ok = !s.hasEncryption
            s.close()
            return ok
        } ?? false
        check(noted && stillLocked && removed && removedLabel && error2 == nil && free,
              "a comment added while protected keeps the protection; Remove Password Protection: the saved file opens without a password")
    }

    // MARK: Print

    private mutating func printing() async {
        let n = count
        let range = n <= 8 ? "" : "1-8"
        let chosen = min(n, 8)
        let paper = controller.pdf.printInfo.paperSize
        var four = PrintSetup(handling: .pagesPerSheet, pagesPerSheet: 4)
        four.borders = true
        let layouts: [(String, PrintSetup, String, Int?)] = [
            ("one page per sheet", PrintSetup(), range, chosen),
            ("4 pages per sheet", four, range, (chosen + 3) / 4),
            ("booklet", PrintSetup(handling: .booklet), range, 2 * ((chosen + 3) / 4)),
            ("poster at 200 %", PrintSetup(handling: .poster, posterScale: 2, overlap: 18, cutMarks: true), "1", nil),
        ]
        var results: [String] = []
        var allOk = true
        var pictured: [String] = []
        var unexplained = false
        for (i, (label, setup, pagesTyped, expected)) in layouts.enumerated() {
            let url = path("print-\(i).pdf")
            let printed = await controller.printToFile(url, setup: setup, range: pagesTyped)
            let sheets = printed.sheets
            var ok = false
            if let data = try? Data(contentsOf: url), let e = try? PdfEngine.open([UInt8](data)) {
                let g = e.pageCount > 0 ? e.page(0) : PageGeometry(0, 0, 0, 0)
                let sized = abs(g.width - Double(paper.width)) < 1.5 && abs(g.height - Double(paper.height)) < 1.5
                let inked = (try? e.render(0, scale: 0.25))?.pixels.contains { $0 < 160 } ?? false
                ok = e.pageCount == sheets && sheets > 0 && sized && inked && (expected.map { $0 == sheets } ?? (sheets >= 4))
                e.close()
            }
            results.append("\(label): \(sheets) sheets, \(printed.vectors) pages as vectors, \(printed.pictures) as pictures")
            if printed.pictures > 0 {
                let why = Set(printed.reasons.values).sorted()
                pictured.append("\(label): \(why.joined(separator: "; "))")
                if why.isEmpty || why.contains(PrintSheetView.noCopy) { unexplained = true }
            }
            if !ok { allOk = false }
        }
        let operation = controller.printOperation(controller.pdf.printInfo.copy() as! NSPrintInfo)
        let accessory = operation.printPanel.accessoryControllers.contains { $0 is PrintAccessory }
        check(allOk && accessory, "printed to PDF files (no printer) on \(Int(paper.width))×\(Int(paper.height)) pt paper: "
              + results.joined(separator: "; ") + "; the print panel carries the Inkvolt options")
        check(!unexplained, pictured.isEmpty ? "every page printed as vectors"
              : "pages printed as vectors but where the print copy says why not (\(pictured.joined(separator: ", ")))")
        // The copy is made before the panel (off the main thread), taken once by the operation that follows; an
        // operation made without one (the panel's preview drawing) never makes it.
        let unprepared = (operation.view as? PrintSheetView)?.hasCopy == false
        let printed = controller.layerEngine ?? controller.engine
        let prepared = await controller.preparePrint(progress: false)
        let taken = controller.takePreparedPrint(printed)
        let once = controller.takePreparedPrint(printed) == nil
        check(unprepared && prepared && taken?.document != nil && once,
              "the print copy is made before the print panel opens and taken once; an operation without it draws pictures")
        await vectorsAgainstPictures(range: range)
    }

    /// The same pages printed as vectors (one per sheet, `print-0.pdf`) and as pictures, as before: the words of the
    /// first page are text on paper only in the vector job, and it is much smaller.
    private mutating func vectorsAgainstPictures(range: String) async {
        let pictures = path("print-pictures.pdf")
        let asPictures = await controller.printToFile(pictures, setup: PrintSetup(), range: range, pictures: true)
        let size = { (url: URL) -> Int in ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0 }
        let vectorBytes = size(path("print-0.pdf")), pictureBytes = size(pictures)
        let source = (try? controller.engine.text(0))?.text ?? ""
        let words = Array(Set(source.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 4 }).sorted().prefix(6))
        func text(_ url: URL) -> String {
            guard let data = try? Data(contentsOf: url), let e = try? PdfEngine.open([UInt8](data)) else { return "" }
            defer { e.close() }
            return (try? e.text(0))?.text ?? ""
        }
        let vectorText = text(path("print-0.pdf")), pictureText = text(pictures)
        let found = words.filter { vectorText.contains($0) }
        let wordsOk = words.isEmpty || (found.count == words.count && !words.contains { pictureText.contains($0) })
        let smaller = vectorBytes > 0 && pictureBytes > 0 && vectorBytes * 3 <= pictureBytes
        let look = Self.difference(path("print-0.pdf"), pictures)
        check(asPictures.sheets > 0 && asPictures.vectors == 0 && wordsOk && smaller && look < 0.005,
              "vector printing: \(vectorBytes / 1024) KB on paper against \(pictureBytes / 1024) KB as 300 dpi pictures; words of page 1 "
              + (words.isEmpty ? "(none: it has no text)" : "found as text: \(found.count) of \(words.count) (\(words.joined(separator: ", ")))")
              + String(format: "; sheet 1 inked where the pictures are (off by %.2f %% of the sheet)", look * 100))
        // A poster tile and a page turned by Rotate (then undone) land where the pictures do.
        let poster = PrintSetup(handling: .poster, posterScale: 2, overlap: 18, cutMarks: true)
        let tile = await comparePictures(poster, "1", "poster")
        var turned = -1.0
        if await controller.rotatePages([0], degrees: 90) {
            turned = await comparePictures(PrintSetup(), "1", "turned")
            controller.pdf.undo()
        }
        check(tile >= 0 && tile < 0.005 && turned >= 0 && turned < 0.005,
              String(format: "as vectors where the pictures are: a poster's first tile (off by %.2f %%), a page turned a quarter (off by %.2f %%)",
                     tile * 100, turned * 100))
    }

    /// Prints `range` with `setup` as vectors (a page the print copy keeps a picture as one) and as pictures; how far their first sheets' ink lies apart (`difference`; -1: a job failed
    /// or had pictures in the vector run).
    private func comparePictures(_ setup: PrintSetup, _ range: String, _ name: String) async -> Double {
        let vectors = path("print-\(name).pdf"), pictures = path("print-\(name)-pictures.pdf")
        let a = await controller.printToFile(vectors, setup: setup, range: range)
        let b = await controller.printToFile(pictures, setup: setup, range: range, pictures: true)
        guard a.sheets > 0, a.vectors + a.pictures > 0, !a.reasons.values.contains(PrintSheetView.noCopy), b.sheets == a.sheets else { return -1 }
        return Self.difference(vectors, pictures)
    }

    /// How far the ink of two printed files' first sheets lies apart (at twice their size): the shift of its centre, as
    /// a fraction of the sheet's size (1 when one has less than 40 % of the other's ink, or a file can't be read).
    /// Glyphs drawn by two renderers differ in weight, and a light gray line is dark enough in one only, so the ink's
    /// amount and bounds differ; a page put in the wrong place, size or turn moves its centre.
    private static func difference(_ a: URL, _ b: URL) -> Double {
        func image(_ url: URL) -> RenderedImage? {
            guard let data = try? Data(contentsOf: url), let e = try? PdfEngine.open([UInt8](data)) else { return nil }
            defer { e.close() }
            return e.pageCount > 0 ? try? e.render(0, scale: 2) : nil
        }
        struct Ink {
            var count = 0, sumX = 0.0, sumY = 0.0
        }
        func ink(_ img: RenderedImage) -> Ink {
            var found = Ink()
            for y in 0..<img.height {
                for x in 0..<img.width {
                    let i = (y * img.width + x) * 3
                    let sum = Int(img.pixels[i]) + Int(img.pixels[i + 1]) + Int(img.pixels[i + 2])
                    guard sum < 384 else { continue }
                    found.count += 1
                    found.sumX += Double(x)
                    found.sumY += Double(y)
                }
            }
            return found
        }
        guard let x = image(a), let y = image(b), x.width == y.width, x.height == y.height, x.width > 0 else { return 1 }
        let p = ink(x), q = ink(y)
        guard p.count > 0, q.count > 0 else { return p.count == q.count ? 0 : 1 }
        let ratio = Double(p.count) / Double(q.count)
        if ratio < 0.4 || ratio > 2.5 { return 1 }
        let w = Double(x.width), h = Double(x.height)
        let dx: Double = abs(p.sumX / Double(p.count) - q.sumX / Double(q.count)) / w
        let dy: Double = abs(p.sumY / Double(p.count) - q.sumY / Double(q.count)) / h
        return max(dx, dy)
    }

    /// The print panel's printer status: a hand-off from Inkvolt Print in a folder of the test's own (never the app group),
    /// a made-up queue whose name macOS shows differently, a printer at a documentation address that doesn't answer: the
    /// accessory warns; a printer Inkvolt Print doesn't know shows nothing. No network printer is asked.
    private mutating func printerStatus() async {
        let root = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("suite"))
        let id = "0e1f2a3b-0000-4000-8000-0000000000a1"
        let handed = SuitePrinters([SuitePrinter(id: id, name: "Office laser", host: "192.0.2.77", queue: "Office_Laser")])
        guard handed.save(root: root.path) else { return skip("printer status: the hand-off couldn't be written") }
        let lookup = PrinterStatusLookup()
        lookup.root = { root.path }
        lookup.transport = { _, _ in HostRouter([:]) }
        lookup.queues = FixedQueues([CupsDestination(name: "Office_Laser", options: ["device-uri": "ipp://192.0.2.77/ipp/print",
                                                                                     "printer-info": "Front Office"])])
        let accessory = PrintAccessory(options: PrintOptions(pageCount: 1, preset: ""))
        accessory.lookup = lookup
        _ = accessory.view
        accessory.testPrinterName = "Front Office"
        await accessory.checkPrinter("Front Office")
        let warned = accessory.printerStatus.stringValue.hasPrefix("⚠︎ " + loc("{0} isn't responding", "Office laser"))
        accessory.testPrinterName = "Someone else's"
        await accessory.checkPrinter("Someone else's")
        let quiet = accessory.printerStatus.stringValue.isEmpty
        let menu = DocumentCommands.command(action: "openInkvoltPrint:") != nil
        check(warned && quiet && menu, "the print panel warns about Inkvolt Print's printer that doesn't answer, shows nothing for one it "
              + "doesn't know; File › Printer Settings (Inkvolt Print) is there")
        // The panel closed before its check answered, then shown again with the same printer: it is checked again.
        accessory.testPrinterName = "Front Office"
        accessory.viewDidAppear()
        accessory.viewDidDisappear()
        accessory.viewDidAppear()
        for _ in 0..<40 where accessory.printerStatus.stringValue.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        accessory.viewDidDisappear()
        check(accessory.printerStatus.stringValue.hasPrefix("⚠︎ Office laser"),
              "the print panel shown again checks its printer again (a check cut short by closing it isn't the last word)")
    }

    // MARK: Closing with unsaved changes

    private mutating func closeQuestion() async {
        let noted = await editor.addNote(page: 0, at: PointD(14, 30), text: "Before closing", color: nil)
        guard noted, controller.pdf.isDocumentEdited else { return skip("close question: no unsaved change could be made") }
        let probe = CloseProbe()
        controller.pdf.testCloseAnswer = .cancel
        controller.pdf.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        let cancelled = probe.shouldClose == false && controller.pdf.isDocumentEdited
        probe.shouldClose = nil
        controller.pdf.testCloseAnswer = .save
        controller.pdf.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        for _ in 0..<100 where probe.shouldClose == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let saved = probe.shouldClose == true && !controller.pdf.isDocumentEdited
        controller.pdf.testCloseAnswer = nil
        check(cancelled && saved && controller.pdf.closeQuestions >= 2,
              "closing with unsaved changes: Cancel keeps it open and edited; Save saves it, then it may close")
    }

    // MARK: Helpers

    private func trace(_ step: String) { Report.progress("[\(controller.pdf.recoveryId.prefix(4))] step: \(step)") }

    private func saveAs(_ url: URL) async -> String? {
        trace("save as " + url.lastPathComponent)
        defer { trace("saved") }
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            controller.pdf.save(to: url, ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
                done.resume(returning: error.map { "\($0.localizedDescription)" })
            }
        }
    }

    /// A PNG made from the editing test's picture.
    static func writePicture(_ url: URL) -> Bool {
        let p = EditTest.picture()
        var rgba = [UInt8](repeating: 0, count: p.width * p.height * 4)
        for i in 0..<(p.width * p.height) {
            for c in 0..<3 { rgba[i * 4 + c] = p.rgb[i * 3 + c] }
            rgba[i * 4 + 3] = 255
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: p.width, pixelsHigh: p.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: p.width * 4, bitsPerPixel: 32) else { return false }
        rgba.withUnsafeBufferPointer { src in rep.bitmapData?.update(from: src.baseAddress!, count: src.count) }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

/// Receives AppKit's answers about closing: one document's (from `canClose`) and all of them (`closeAllDocuments`).
final class CloseProbe: NSObject {
    var shouldClose: Bool?
    var closedAll: Bool?

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { self.shouldClose = shouldClose }

    @objc func documentController(_ controller: NSDocumentController, didCloseAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        closedAll = didCloseAll
    }
}
