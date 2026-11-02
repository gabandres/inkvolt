import AppKit
import PdfCore

/// The self-test's scenario for E13 (`--edit`, on the synthetic text document; `--only-split` runs it alone): View ›
/// Split View through the menu's own items, the second pane opening where the main one is, page and zoom commands acting
/// on the active pane only, a click on a pane and ⌘' (the menu's key equivalent) switching panes, text selected in the
/// second pane with its own mouse handling and copied, a tool that changes the document going to the main pane, an edit
/// in the main pane (Rotate Right) and its undo showing in the second, Find's matches in both, Side by Side, the
/// organizer closing the split, and the second pane's × closing it. Only counts and states are written.
@MainActor
struct SplitTest {
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
        if enabled { NSApp.sendAction(action, to: controller, from: item) } // the window may not be key over SSH
        return enabled
    }

    private func settle(_ ms: Int = 150) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private func event(_ type: NSEvent.EventType, _ view: PagesView, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// A press from `from` to `to` (page space) on `page` of `view`, as the mouse makes it.
    private func press(_ view: PagesView, page: Int, from: PointD, to: PointD) async {
        let a = view.viewPoint(from, view.pageRects[page]), b = view.viewPoint(to, view.pageRects[page])
        view.mouseDown(with: event(.leftMouseDown, view, a))
        view.mouseDragged(with: event(.leftMouseDragged, view, NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
        view.mouseDragged(with: event(.leftMouseDragged, view, b))
        view.mouseUp(with: event(.leftMouseUp, view, b))
        await view.pendingEdit?.value
        await settle(50)
    }

    /// A pane's frame: drawn at all (the view is split), and in the accent color (the active pane).
    private func border(_ scroll: NSScrollView?) -> (width: CGFloat, accent: Bool) {
        guard let scroll, let frame = scroll.subviews.first(where: { $0 is PaneFrameView }) as? PaneFrameView else { return (0, false) }
        return (frame.state == .none ? 0 : 2, frame.state == .active)
    }

    mutating func run() async {
        lines.append("== \(name): split view (\(controller.engine.pageCount) pages)")
        let count = controller.engine.pageCount
        guard count >= 2 else {
            lines.append("SKIP split view: needs two pages")
            Report.write(lines.joined(separator: "\n"))
            return
        }
        controller.setSplit(.none)
        pages.tool = .text
        controller.setZoom(1)
        controller.go(0)
        await settle()

        // The menu.
        let switchItem = menuItem("Switch Pane"), remove = menuItem("Remove Split")
        check(menuItem("Split Top and Bottom") != nil && menuItem("Split Side by Side") != nil && remove != nil
              && switchItem?.keyEquivalent == "'" && switchItem?.keyEquivalentModifierMask == .command
              && remove.map { controller.validateMenuItem($0) } == false && switchItem.map { controller.validateMenuItem($0) } == false,
              "View › Split View has Top and Bottom, Side by Side, Remove Split and Switch Pane (⌘'); the last two off while not split")

        // Top and bottom: the second pane opens where the main one is, and is the active one.
        check(choose("Split Top and Bottom"), "Split Top and Bottom is enabled")
        await settle(300)
        guard let second = controller.secondPages, let secondScroll = controller.secondScroll else {
            check(false, "the second pane opened")
            Report.write(lines.joined(separator: "\n"))
            return
        }
        check(controller.paneSplit.panes.count == 2 && !controller.paneSplit.isVertical && controller.splitMode == .topAndBottom
              && controller.secondActive && controller.window?.firstResponder === second && second.currentPage == pages.currentPage
              && second.readingOnly && second.engine === pages.engine,
              "two panes, top and bottom; the second shows the same page of the same document and has the keyboard: \(controller.splitState)")
        let frames = (border(controller.scrollView), border(secondScroll))
        check(frames.1.width == 2 && frames.1.accent && frames.0.width == 2 && !frames.0.accent,
              "the active pane has the accent frame (main \(frames.0), second \(frames.1))")
        let topItem = menuItem("Split Top and Bottom")
        if let topItem { _ = controller.validateMenuItem(topItem) }
        check(topItem?.state == .on && remove.map { controller.validateMenuItem($0) } == true,
              "the menu shows Top and Bottom checked and Remove Split enabled")

        // Page and zoom commands act on the active pane only.
        let mainPage = pages.currentPage, mainZoom = controller.scrollView.magnification
        choose("Next Page")
        await settle()
        check(second.currentPage == mainPage + 1 && pages.currentPage == mainPage, "Next Page moves the active (second) pane only: \(controller.splitState)")
        let secondZoom = secondScroll.magnification
        choose("Zoom In")
        await settle()
        check(secondScroll.magnification > secondZoom + 0.01 && abs(controller.scrollView.magnification - mainZoom) < 0.001,
              "Zoom In zooms the active pane only: \(controller.splitState)")
        controller.setZoom(1)

        // A click on the main pane makes it active; ⌘' goes back.
        let mainVisible = pages.visibleRect
        let spot = NSPoint(x: mainVisible.midX, y: mainVisible.midY)
        pages.mouseDown(with: event(.leftMouseDown, pages, spot))
        pages.mouseUp(with: event(.leftMouseUp, pages, spot))
        await settle(50)
        check(!controller.secondActive && controller.window?.firstResponder === pages && border(controller.scrollView).accent && !border(secondScroll).accent,
              "a click on the main pane makes it the active one")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "'", charactersIgnoringModifiers: "'",
                                   isARepeat: false, keyCode: 39)!
        // The menu takes ⌘' only in the key window (over SSH the window may not be); else the item's own action.
        let viaKey = controller.window?.isKeyWindow == true
        let handled = viaKey ? NSApp.mainMenu?.performKeyEquivalent(with: key) ?? false : choose("Switch Pane")
        await settle(50)
        check(handled && controller.secondActive && controller.window?.firstResponder === second,
              "\(viaKey ? "⌘'" : "Switch Pane (the window isn't key: its menu item)") switches to the second pane")

        // Text selected in the second pane with its own mouse handling, and copied; the main pane's selection untouched.
        let textPage = second.currentPage
        if let t = try? controller.engine.text(textPage) {
            let words = EditTest.words(t)
            if words.count >= 3 {
                let a = t.boxAt(words[0].start), b = t.boxAt(words[2].end - 1)
                second.scrollTo(y: second.pageRects[textPage].minY + a.y - 40)
                await settle(50)
                await press(second, page: textPage, from: PointD(a.x + 0.5, a.centerY), to: PointD(b.right - 0.5, b.centerY))
                let selected = second.selectedText ?? ""
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.bermudezsystems.InkvoltPdf.selftest.split"))
                let copied = second.copySelection(to: pasteboard) && pasteboard.string(forType: .string) == selected
                pasteboard.releaseGlobally()
                check(selected.split(separator: " ").count >= 2 && copied && pages.selectedText == nil,
                      "text selected in the second pane by its own mouse handling and copied (\(selected.count) characters); the main pane has none")
            } else {
                lines.append("SKIP text selection in the second pane: page \(textPage + 1) has fewer than 3 words")
            }
        }

        // A tool that changes the document goes to the main pane, which becomes the active one.
        second.tool = .highlight
        await settle(50)
        check(second.tool == .text && pages.tool == .highlight && !controller.secondActive,
              "Highlight picked in the second pane goes to the main pane, which becomes active; the second stays on text selection")
        pages.tool = .text

        // An edit in the main pane shows in the second at once; and its undo.
        controller.go(0)
        await settle()
        let before = (main: pages.pageRects[0].size, second: second.pageRects[0].size)
        let edits = controller.editor.finishedEdits
        choose("Rotate Right")
        for _ in 0..<400 where controller.editor.finishedEdits == edits { try? await Task.sleep(for: .milliseconds(50)) }
        await settle(200)
        let rotated = second.pageRects[0].size
        check(controller.editor.finishedEdits > edits && second.engine === pages.engine && abs(rotated.width - before.second.height) < 0.5
              && abs(rotated.height - before.second.width) < 0.5 && pages.pageRects[0].size == rotated,
              "Rotate Right in the main pane shows in the second at once (page 1 \(Int(before.second.width))×\(Int(before.second.height)) → \(Int(rotated.width))×\(Int(rotated.height)))")
        controller.pdf.undo()
        await settle(300)
        check(second.engine === pages.engine && second.pageRects[0].size == before.second, "Undo shows in the second pane too")

        // Find: the matches in both panes; Find's next match moves the active pane.
        if let t = try? controller.engine.text(0), let word = EditTest.words(t).map({ String(decoding: Array(t.text.utf16)[$0.start..<$0.end], as: UTF16.self) })
            .first(where: { $0.count >= 4 }) {
            var done = false
            controller.onFindFinished = { done = true }
            controller.find(word)
            for _ in 0..<200 where !done { try? await Task.sleep(for: .milliseconds(50)) }
            controller.onFindFinished = nil
            let mainMatches = pages.matches.values.reduce(0) { $0 + $1.count }
            let secondMatches = second.matches.values.reduce(0) { $0 + $1.count }
            check(done && mainMatches > 0 && mainMatches == secondMatches && second.currentMatch != nil,
                  "Find shows its \(mainMatches) matches in both panes")
            controller.find("")
            check(pages.matches.isEmpty && second.matches.isEmpty, "clearing Find clears both panes")
        }

        // Side by side: the same panes, side by side; the second keeps its place.
        choose("Switch Pane")
        await settle(50)
        let secondPage = second.currentPage
        choose("Split Side by Side")
        await settle(300)
        let sideItem = menuItem("Split Side by Side")
        if let sideItem { _ = controller.validateMenuItem(sideItem) }
        check(controller.paneSplit.isVertical && controller.paneSplit.panes.count == 2 && controller.secondPages === second
              && second.currentPage == secondPage && sideItem?.state == .on,
              "Split Side by Side lays the same panes side by side, the second at its page: \(controller.splitState)")

        // The organizer takes the panes' place and closes the split.
        controller.showOrganizer(true)
        await settle()
        check(controller.secondPages == nil && controller.splitMode == .none, "Organize Pages closes the split")
        controller.showOrganizer(false)
        await settle()

        // The second pane's × closes it.
        choose("Split Top and Bottom")
        await settle(300)
        let close = controller.secondBox?.subviews.compactMap { $0 as? NSButton }.first
        close?.performClick(nil)
        await settle(200)
        check(close != nil && controller.secondPages == nil && controller.paneSplit.panes.count == 1 && !controller.secondActive
              && controller.window?.firstResponder === pages && border(controller.scrollView).width == 0,
              "the second pane's × closes the split; the main pane gets the keyboard and loses its frame")

        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
