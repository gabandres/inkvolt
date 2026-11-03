import AppKit
import PdfCore

/// The self-test's scenario for the reading view (`--edit`, on the synthetic text document; `--only-view` runs it alone):
/// View › Rotate View Clockwise and Counterclockwise through the menu's own items (the pages laid out turned, page points
/// mapped there and back, text selected with the mouse on the turned view giving the same text, a note put down where
/// it was clicked, an arrow key moving a comment the way it points on the screen, the file unchanged, the split pane's
/// own turn, the turn remembered for the file); View › Dark Pages (Night Reading) (the page's paper drawn dark grey, in
/// the split pane too, kept as a setting, back to white). Only counts and states are written.
@MainActor
struct ViewTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var pages: PagesView { controller.pages }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func menuItem(_ title: String) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == title { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// Chooses a menu item as a person does: validated, then its action sent along the responder chain.
    @discardableResult
    private func choose(_ title: String) -> Bool {
        guard let item = menuItem(title), let action = item.action else { return false }
        let enabled = controller.validateMenuItem(item)
        if enabled { NSApp.sendAction(action, to: controller, from: item) }
        return enabled
    }

    private func settle(_ ms: Int = 150) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private func event(_ type: NSEvent.EventType, _ view: PagesView, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// A press through `points` (page space) on `page`, as the mouse makes it on the view as it is turned.
    private func press(_ view: PagesView, page: Int, _ points: [PointD]) async {
        guard let first = points.first else { return }
        let r = view.pageRects[page]
        view.mouseDown(with: event(.leftMouseDown, view, view.viewPoint(first, r)))
        for p in points.dropFirst() { view.mouseDragged(with: event(.leftMouseDragged, view, view.viewPoint(p, r))) }
        view.mouseUp(with: event(.leftMouseUp, view, view.viewPoint(points.last ?? first, r)))
        await view.pendingEdit?.value
        await settle(50)
    }

    private func key(_ code: UInt16, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    mutating func run() async {
        lines.append("== \(name): reading view (\(controller.engine.pageCount) pages)")
        await rotateView()
        await darkPages()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    /// A page with three words in a row on one line: from the first word's start to the third's end.
    private func textSpot() -> (page: Int, start: PointD, end: PointD)? {
        for p in 0..<controller.engine.pageCount {
            guard let text = try? controller.engine.text(p) else { continue }
            let words = EditTest.words(text)
            guard words.count >= 3 else { continue }
            for i in 0..<(words.count - 2) {
                let a = text.boxAt(words[i].start), b = text.boxAt(words[i + 2].end - 1)
                if abs(a.centerY - b.centerY) < 2 && b.right > a.x { return (p, PointD(a.x + 0.5, a.centerY), PointD(b.right - 0.5, b.centerY)) }
            }
        }
        return nil
    }

    /// One pixel of a picture (red, green, blue).
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let drawn = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        return drawn ? Array(px.prefix(3)) : []
    }

    /// The paper's color at page 1's top-left corner once its picture is drawn again (nil: not drawn in 10 s).
    private func cornerOnceDrawn(_ view: PagesView) async -> [UInt8]? {
        for _ in 0..<100 {
            view.requestVisible()
            if let image = view.renderer.image(0), image.scale > 0 { return pixel(image.image, 1, 1) }
            await settle(100)
        }
        return nil
    }

    private mutating func darkPages() async {
        guard controller.engine.pageCount > 0, let session = controller.pdf.session else { return }
        let before = session.data
        controller.go(0)
        controller.splitTopAndBottom(nil)
        await settle()
        let darkOn = choose("Dark Pages (Night Reading)")
        let state = menuItem("Dark Pages (Night Reading)").map { item -> Bool in
            _ = controller.validateMenuItem(item)
            return item.state == .on
        } ?? false
        let corner = await cornerOnceDrawn(pages)
        let second = controller.secondPages != nil
        var secondCorner: [UInt8]?
        if let pane = controller.secondPages { secondCorner = await cornerOnceDrawn(pane) }
        check(darkOn && state && AppSettings.darkPages && corner.map { $0.allSatisfy { abs(Int($0) - Int(NightColors.paper)) <= 2 } } == true
              && second && secondCorner == corner,
              "Dark Pages (Night Reading) draws the paper dark grey in both panes (\(corner.map { "\($0)" } ?? "not drawn")), ticked and kept as a setting")
        controller.removeSplit(nil)
        choose("Dark Pages (Night Reading)")
        let back = await cornerOnceDrawn(pages)
        check(!AppSettings.darkPages && back.map { $0.allSatisfy { $0 >= 250 } } == true && controller.pdf.session?.data == before,
              "turned off: the paper white again (\(back.map { "\($0)" } ?? "not drawn")), the file unchanged")
    }

    private mutating func rotateView() async {
        guard controller.engine.pageCount > 0, let session = controller.pdf.session else { return }
        let before = session.data
        controller.setZoom(1)
        controller.go(0)
        let g = controller.engine.page(0)

        // The text selected on the upright view, for the turned view to match.
        pages.tool = .text
        let spot = textSpot()
        var upright = ""
        if let spot {
            controller.go(spot.page)
            await press(pages, page: spot.page, [spot.start, PointD((spot.start.x + spot.end.x) / 2, spot.start.y), spot.end])
            upright = pages.selectedText ?? ""
            pages.clearSelection()
        }

        let turned = choose("Rotate View Clockwise")
        let r0 = pages.pageRects[0]
        check(turned && pages.viewRotation == 90 && abs(r0.width - g.height) < 0.5 && abs(r0.height - g.width) < 0.5,
              "Rotate View Clockwise turns the view 90° (page 1 shown \(Int(r0.width)) x \(Int(r0.height)))")
        var roundTrips = true
        for rotation in [90, 180, 270] {
            pages.setViewRotation(rotation)
            let r = pages.pageRects[0]
            for p in [PointD(10, 20), PointD(g.width - 30, 40), PointD(g.width / 2, g.height - 5)] {
                let v = pages.viewPoint(p, r)
                guard let back = pages.page(at: v) else { roundTrips = false; continue }
                if back.page != 0 || abs(back.x - p.x) > 0.01 || abs(back.y - p.y) > 0.01 { roundTrips = false }
                if !r.insetBy(dx: -0.5, dy: -0.5).contains(v) { roundTrips = false }
            }
        }
        pages.setViewRotation(90)
        check(roundTrips, "page points map onto the turned pages and back at 90°, 180° and 270°")

        if let spot {
            controller.go(spot.page)
            await press(pages, page: spot.page, [spot.start, PointD((spot.start.x + spot.end.x) / 2, spot.start.y), spot.end])
            let text = pages.selectedText ?? ""
            check(!upright.isEmpty && text == upright, "text selected with the mouse on the turned view: “\(text)” (upright: “\(upright)”)")
            pages.clearSelection()
        } else {
            lines.append("SKIP selection: no line of text")
        }

        // A note where the turned page was clicked, then moved by the right arrow: on the screen to the right, which on
        // a page turned 90° clockwise is up the page.
        let editor = controller.editor
        let notesBefore = editor.comments.filter { $0.subtype == "Text" }.count
        controller.testText = "Turned note"
        pages.tool = .note
        let spotOnPage = PointD(g.width * 0.3, g.height * 0.4)
        await press(pages, page: 0, [spotOnPage])
        controller.testText = nil
        let note = editor.comments.last { $0.subtype == "Text" && $0.contents == "Turned note" }
        check(editor.comments.filter { $0.subtype == "Text" }.count == notesBefore + 1
              && note.map { abs($0.rect.x - spotOnPage.x) < 2 && abs($0.rect.y - spotOnPage.y) < 22 } == true,
              "a note put down where the turned page was clicked (\(note.map { "\(Int($0.rect.x)), \(Int($0.rect.y))" } ?? "none"))")
        if let note {
            pages.tool = .hand
            pages.select(note.id)
            controller.window?.makeFirstResponder(pages)
            pages.keyDown(with: key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
            await pages.pendingEdit?.value
            await settle()
            let moved = editor.comment(note.id)
            check(moved.map { abs($0.rect.x - note.rect.x) < 0.01 && abs($0.rect.y - (note.rect.y - 1)) < 0.01 } == true,
                  "→ on the turned view moves the note up its page by 1 pt")
            pages.select(nil)
            controller.window?.undoManager?.undo()
            await settle()
            controller.window?.undoManager?.undo()
            await settle()
        }
        pages.tool = .text

        // The second pane keeps its own turn.
        controller.splitTopAndBottom(nil)
        await settle()
        if let second = controller.secondPages {
            let main = pages.viewRotation
            if controller.activePages !== second { controller.switchPane(nil) }
            choose("Rotate View Counterclockwise")
            check(second.viewRotation == RotatedView.normalize(main - 90) && pages.viewRotation == main,
                  "the split pane turns on its own (\(second.viewRotation)°, main pane \(main)°)")
            controller.removeSplit(nil)
            await settle()
        } else {
            check(false, "the split pane opens")
        }

        let start = pages.viewRotation
        for _ in 0..<3 { choose("Rotate View Counterclockwise") }
        check(pages.viewRotation == RotatedView.normalize(start + 90), "three turns counterclockwise (⇧⌘L) are one clockwise: \(start)° to \(pages.viewRotation)°")
        pages.setViewRotation(180)
        let path = controller.pdf.fileURL?.path ?? "/tmp/selftest.pdf"
        controller.rememberPosition()
        check(AppSettings.lastRotation(path) == 180 || !AppSettings.restorePosition,
              "the turn remembered for the file (\(AppSettings.lastRotation(path).map(String.init) ?? "none"))")
        pages.setViewRotation(0)
        check(controller.pdf.session?.data == before, "the file is unchanged by turning the view")
    }
}
