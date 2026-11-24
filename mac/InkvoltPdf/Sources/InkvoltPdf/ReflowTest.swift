import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for roadmap 4.16, the Reflow view (`--edit`, on the synthetic text document; `--only-reflow`
/// runs it alone): View › Reflow through the menu bar's own item, the column shown at the page the reader was on, page
/// scripts off and no script in the page, the menu read-only but for Reflow's commands, the page box scrolling the column
/// and the column moving the page box, Zoom In and Actual Size on its text, Dark Pages, its links (a web address to the
/// browser, a file refused, a place in the document scrolled to), Organize leaving it, and leaving it at its page. Only
/// counts and states are written.
@MainActor
struct ReflowTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var reflow: ReflowView { controller.reflow }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[reflow] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func wait(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    private func settle(_ ms: Int = 1200) async { try? await Task.sleep(for: .milliseconds(ms)) }

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

    /// Chooses a menu item as a person does: validated, then its action sent to the window.
    @discardableResult
    private func choose(_ title: String) -> Bool {
        guard let item = menuItem(title), let action = item.action else { return false }
        let enabled = controller.validateMenuItem(item)
        if enabled { NSApp.sendAction(action, to: controller, from: item) }
        return enabled
    }

    private func enabled(_ title: String) -> Bool { menuItem(title).map(controller.validateMenuItem) ?? false }

    mutating func run() async {
        lines.append("== \(name): the Reflow view")
        let count = controller.engine.pageCount
        guard count >= 2 else {
            lines.append("SKIP the Reflow view: needs two pages")
            return Report.write(lines.joined(separator: "\n"))
        }
        let dark = AppSettings.darkPages
        // Zoomed in, so the page view has a page 2 to scroll to (the synthetic pages fit the window at its own zoom).
        controller.setZoom(4)
        await settle(300)
        controller.go(1)
        await settle(300)
        // View › Reflow: the column, at the page the reader was on. The synthetic pages are short: the text at its largest
        // and the window at its shortest, so the column has a page 2 to open at.
        let frame = controller.window?.frame
        if let window = controller.window { window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true) }
        reflow.zoom(20)
        let reflowTitle = loc("Reflow")
        check(choose(reflowTitle), "View › Reflow can be chosen")
        let shown = await wait(30) { reflow.state == "showing" }
        await settle()
        let openedAt = await reflow.topPage()
        check(shown && !reflow.host.isHidden && reflow.host.frame == controller.paneSplit.frame && reflow.page == 1 && openedAt == 1,
              "the column shows in place of the pages, at page \(openedAt.map { "\($0 + 1)" } ?? "none") (state \(reflow.state))")
        choose(loc("Actual Size"))
        if let frame { controller.window?.setFrame(frame, display: true) }
        await settle()
        let scripts = await reflow.evaluate("document.querySelectorAll('script').length")
        check(!reflow.runsPageScripts && scripts == "0", "page scripts are off and the page has none (\(scripts ?? "no answer"))")
        let tick = menuItem(reflowTitle).map { item in (controller.validateMenuItem(item), item.state) }
        check(tick?.0 == true && tick?.1 == .on, "View › Reflow is ticked")
        // The synthetic pages are short: each made a screen tall here, so there is a page to scroll to.
        _ = await reflow.evaluate("document.querySelectorAll('main > div').forEach(function(d){d.style.minHeight='3000px'});0")
        reflow.scrollAsReader(1)
        await settle()
        let top = await reflow.topPage()
        check(top == 1 && controller.pages.currentPage == 1, "the column's top is page \(top.map { "\($0 + 1)" } ?? "none"), the page box's \(controller.pages.currentPage + 1)")

        // Read-only: only Reflow's commands.
        let refused = [loc("Highlight Selected Text"), loc("Delete Pages"), loc("Find…"), loc("Split Side by Side"), loc("Zoom to Width")]
        let allowed = [loc("Zoom In"), loc("Next Page"), loc("Go to Page…"), loc("Save As…")]
        let offCount = refused.filter { !enabled($0) }.count, onCount = allowed.filter(enabled).count
        check(offCount == refused.count && onCount == allowed.count,
              "while it shows, \(offCount) of \(refused.count) editing commands are off and \(onCount) of \(allowed.count) of its own on")

        // The page box scrolls the column; the column moves the page box.
        controller.go(0)
        await settle()
        let followed = await reflow.topPage()
        check(followed == 0, "the page view sent to page 1: the column follows (page \(followed.map { "\($0 + 1)" } ?? "none"))")
        reflow.scrollAsReader(1)
        let moved = await wait(5) { controller.pages.currentPage == 1 }
        check(moved, "the column scrolled to page 2 by the reader: the page box follows (page \(controller.pages.currentPage + 1))")
        await settle()

        // Zoom In and Actual Size: the text's size (112.5% of 16 px, times the zoom).
        choose(loc("Zoom In"))
        await settle(500)
        let bigger = await reflow.evaluate("getComputedStyle(document.documentElement).fontSize")
        choose(loc("Actual Size"))
        await settle(500)
        let actual = await reflow.evaluate("getComputedStyle(document.documentElement).fontSize")
        let px = { (s: String?) in s.flatMap { Double($0.replacingOccurrences(of: "px", with: "")) } ?? 0 }
        check(abs(px(bigger) - 16 * 1.238) < 0.01 && px(actual) == 18 && controller.pages.currentPage == 1,
              "Zoom In makes the text \(bigger ?? "?"), Actual Size \(actual ?? "?"), the page kept")

        // Dark Pages: light text on dark, in place.
        if !dark { choose(loc("Dark Pages (Night Reading)")) }
        await settle(500)
        let paper = await reflow.evaluate("getComputedStyle(document.body).backgroundColor")
        if !dark { choose(loc("Dark Pages (Night Reading)")) }
        await settle(500)
        let back = await reflow.evaluate("getComputedStyle(document.body).backgroundColor")
        check(paper == "rgb(30, 30, 30)" && back == "rgb(255, 255, 255)", "Dark Pages: the paper \(paper ?? "?"), then \(back ?? "?")")

        // Links: a web address leaves for the browser, a file goes nowhere, a place in the document scrolls there.
        reflow.testOpened = []
        reflow.follow("https://example.com/a?b=1")
        reflow.follow("file:///etc/hosts")
        reflow.follow("javascript:alert(1)")
        reflow.follow(Reflow.address + "#page-1")
        await settle()
        let opened = reflow.testOpened ?? []
        let atFirst = await reflow.topPage()
        check(opened == ["https://example.com/a?b=1"] && atFirst == 0,
              "links: \(opened.count) web address opened, a file and a script refused, #page-1 scrolled to (page \(atFirst.map { "\($0 + 1)" } ?? "none"))")
        reflow.testOpened = nil
        reflow.scrollAsReader(1)
        _ = await wait(5) { controller.pages.currentPage == 1 }
        await settle()

        // Organize leaves Reflow; back to it, then leave at its page.
        check(choose(loc("Organize Pages")) && !reflow.isShown && controller.organizerShown, "Organize Pages leaves Reflow for the grid")
        choose(loc("Organize Pages"))
        choose(reflowTitle)
        _ = await wait(30) { reflow.state == "showing" }
        await settle()
        _ = await reflow.evaluate("document.querySelectorAll('main > div').forEach(function(d){d.style.minHeight='3000px'});0")
        reflow.scrollAsReader(1)
        _ = await wait(5) { controller.pages.currentPage == 1 }
        await settle()
        choose(reflowTitle)
        await settle(300)
        // Edit › Undo works on the document again (NSWindow kept an undo manager of its own once Reflow had none).
        let undoesDocument = controller.window?.undoManager === controller.pdf.undoBridge
        check(!reflow.isShown && reflow.host.isHidden && controller.pages.currentPage == 1 && reflow.web == nil && undoesDocument,
              "View › Reflow again: back to the pages at page \(controller.pages.currentPage + 1), the web view let go, Undo the document's (\(undoesDocument))")
        controller.applyOpeningZoom()
        controller.go(0)

        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
