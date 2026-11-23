import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for Wave 4's paper commands (roadmap Batch A; `--edit`, on the synthetic text document;
/// `--only-paper` runs it alone): each through the menu bar's item (enabled, its sheet's edit run as the sheet runs it)
/// and the edit the sheet makes, checked on the document, then undone so the next starts from the document as opened.
/// Page Labels (4.14), Interleave Pages (4.3; Scan the Backs in `AppTest`, with the demo scanner), Remove Blank Pages and
/// Split at Blank Pages (4.4), Bookmarks from Headings (4.5), Resize Pages (4.7), Replace Pages (4.13). Only counts, labels
/// and states are written.
@MainActor
struct PaperTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var session: DocumentSession? { controller.pdf.session }
    private var count: Int { controller.engine.pageCount }

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

    /// The menu bar has the command, enabled for this document, sending `action`.
    private func offered(_ title: String, _ action: String) -> Bool {
        guard let item = menuItem(loc(title)) else { return false }
        return item.action == NSSelectorFromString(action) && controller.validateMenuItem(item)
    }

    private func labels() -> [String]? { session.flatMap { try? DocumentFeatures.pageLabels($0.data, $0.password) } }

    /// Undoes the last edit and waits until the document is back to `pages` pages and the undo step named `label` is gone.
    private func undo(_ pages: Int) async -> Bool {
        let before = session?.undoStepId
        controller.window?.undoManager?.undo()
        for _ in 0..<100 where session?.undoStepId == before || count != pages {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return count == pages
    }

    mutating func run() async {
        let started = Date()
        lines.append("== \(name): paper commands (\(count) pages)")
        guard count >= 2, session != nil else {
            lines.append("SKIP paper commands: needs two pages")
            Report.write(lines.joined(separator: "\n"))
            return
        }
        await pageLabels()
        await interleave()
        await blankPages()
        await headings()
        await resize()
        await replace()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
        Report.note("paper commands took \(Int(Date().timeIntervalSince(started))) s")
    }

    /// Page Labels…: page 1 in Roman numerals, the pages after it from 1; undone; then Use Plain Numbers on them.
    private mutating func pageLabels() async {
        let n = count
        let original = labels()
        let menu = offered("Page Labels…", "editPageLabels:")
        let set = await controller.setPageLabels([0], PageLabelStyle(.lowerRoman, "", 1), restartAfter: true)
        let shown = labels() ?? []
        let expected = ["i"] + (1..<n).map(String.init)
        let named = session?.undoLabel == loc("Set page labels")
        let removed = await controller.removePageLabels()
        let plain = labels() == nil
        let undone = await undo(n)
        let back = labels() == expected
        let undoneAgain = await undo(n)
        check(menu && set && shown == expected && named && removed && plain && undone && back && undoneAgain && labels() == original,
              "Page Labels… (Pages menu): page 1 as i, the rest from 1 (\(shown.prefix(3).joined(separator: ", "))…), Use Plain Numbers, both undone")
    }

    /// Each page's text, to tell the pages apart after a reorder.
    private func texts() -> [String] { (0..<count).map { (try? controller.engine.text($0))?.text ?? "" } }

    /// Interleave Pages…: the first half as fronts, the second as backs in reverse order; then this document's pages as the
    /// fronts of a copy of itself (the backs from another PDF). Each undone.
    private mutating func interleave() async {
        let n = count
        let before = texts()
        let menu = offered("Interleave Pages…", "interleavePages:") && offered("Scan the Backs…", "scanBacks:")
        let half = (n + 1) / 2
        let fronts = Array(0..<half), backs = Array(half..<n)
        let order = (try? PageEditor.interleaveOrder(n, fronts, backs, reverseBacks: true)) ?? []
        let done = await controller.interleave(fronts: fronts, backs: backs, reversed: true)
        let after = texts()
        let named = session?.undoLabel == loc("Interleave pages")
        let undone = await undo(n)
        check(menu && done && named && order.count == n && after == order.map { before[$0] } && undone && texts() == before,
              "Interleave Pages… (Pages menu, Scan the Backs… in File): \(fronts.count) fronts and \(backs.count) backs reversed, in the order \(order), undone")

        guard let s = session else { return }
        let copy = PdfSource(s.data, s.password, "backs.pdf")
        let with = await controller.interleaveWith(copy, reversed: false, label: loc("Interleave pages"))
        let doubled = texts()
        let pairs = doubled.count == 2 * n && (0..<n).allSatisfy { doubled[2 * $0] == before[$0] && doubled[2 * $0 + 1] == before[$0] }
        let undoneWith = await undo(n)
        check(with && pairs && undoneWith && texts() == before,
              "Interleave Pages… with another PDF: \(n) fronts and \(n) backs, each back after its front (\(doubled.count) pages), undone")
    }

    /// Remove Blank Pages… and Split at Blank Pages…: a blank page inserted after page 1 is found (with the progress sheet),
    /// removed as one step and undone, then the document split at it into a temporary folder; the insert undone.
    private mutating func blankPages() async {
        let n = count
        let menu = offered("Remove Blank Pages…", "removeBlankPages:") && offered("Split at Blank Pages…", "splitAtBlankPages:")
        let g = controller.engine.page(0)
        guard await controller.insertBlank(at: 1, count: 1, size: (g.width, g.height)) else { return check(false, "a blank page inserted to find") }
        let found = await controller.findBlankPages()
        let pictured = found?.pictures.first ?? nil
        let removed = await controller.removeBlank([1])
        let named = session?.undoLabel == loc("Remove 1 blank page")
        let afterRemove = count
        let undone = await undo(n + 1)
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-paper-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let parts = await controller.splitAtBlanks([1], to: folder) ?? []
        let partPages = parts.map { path in
            (try? PdfEngine.open(Array((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()))).map { e in
                defer { e.close() }
                return e.pageCount
            } ?? 0
        }
        let undoneInsert = await undo(n)
        check(menu && found?.pages.contains(1) == true && pictured != nil && removed && named && afterRemove == n && undone && partPages == [1, n - 1]
              && undoneInsert,
              "Remove Blank Pages… and Split at Blank Pages… (Pages menu): the blank page found (\(found?.pages ?? [])) and shown, removed as one step "
              + "and undone; split into \(parts.count) files of \(partPages) pages")
    }

    private func bookmarkCount() -> Int {
        func count(_ tree: [Bookmark]) -> Int { tree.reduce(0) { $0 + 1 + count($1.children) } }
        return count(session.flatMap { try? Bookmarks.read($0.data, $0.password) } ?? [])
    }

    /// Bookmarks from Headings…: the document's headings found (with the progress sheet) and made its bookmarks in place of
    /// those it has, as one step, then undone; a document without headings is said to have none.
    private mutating func headings() async {
        let n = count
        let menu = offered("Bookmarks from Headings…", "bookmarksFromHeadings:")
        let before = bookmarkCount()
        guard let found = await controller.findHeadings() else { return check(false, "Bookmarks from Headings…: the headings read") }
        if found.headings.isEmpty {
            return check(menu && found.existing == before, "Bookmarks from Headings… (Pages menu): this document has no headings, so none is offered")
        }
        let made = await controller.makeHeadingBookmarks(found.headings, replace: true, deepest: 6)
        let after = bookmarkCount()
        let named = session?.undoLabel == (found.headings.count == 1 ? loc("Bookmark 1 heading") : loc("Bookmark {0} headings", CoreLanguage.number(found.headings.count)))
        let undone = await undo(n)
        check(menu && made && named && after == found.headings.count && undone && bookmarkCount() == before,
              "Bookmarks from Headings… (Pages menu): \(found.headings.count) headings made the bookmarks (\(before) before), undone")
    }

    /// Resize Pages…: every page on A4, the content scaled; each page A4 (sideways when it shows landscape), its text kept;
    /// undone.
    private mutating func resize() async {
        let n = count
        let menu = offered("Resize Pages…", "resizePages:")
        let before = texts()
        let a4 = Self.paperSizesA4
        let done = await controller.resize(Array(0..<n), width: a4.width, height: a4.height, fit: .scale)
        let sizes = (0..<n).map { (controller.engine.page($0).width.rounded(), controller.engine.page($0).height.rounded()) }
        let onA4 = sizes.allSatisfy { ($0 == (a4.width, a4.height)) || ($0 == (a4.height, a4.width)) }
        let named = session?.undoLabel == (n == 1 ? loc("Resize 1 page") : loc("Resize {0} pages", CoreLanguage.number(n)))
        let sameText = texts().map { $0.filter { !$0.isWhitespace } } == before.map { $0.filter { !$0.isWhitespace } }
        let undone = await undo(n)
        check(menu && done && onA4 && named && sameText && undone && texts() == before,
              "Resize Pages… (Pages menu): \(n) pages on A4, the content scaled (\(sizes.map { "\(Int($0.0))×\(Int($0.1))" }.joined(separator: ", "))), text kept, undone")
    }

    /// Replace Pages…: page 1 swapped for a copy of the last page (from another PDF), page 1's label kept, then undone.
    private mutating func replace() async {
        let n = count
        let menu = offered("Replace Pages…", "replacePages:")
        let before = texts()
        guard let s = session, let last = try? PageEditor.extract(s.data, s.password, [n - 1]) else { return check(false, "Replace Pages…: a page to put in") }
        let done = await controller.replace([0], with: PdfSource(last, nil, "new.pdf"), [0])
        let after = texts()
        let named = session?.undoLabel == loc("Replace 1 page with {1}", CoreLanguage.number(1), "new.pdf")
        let undone = await undo(n)
        check(menu && done && named && after.count == n && after[0] == before[n - 1] && Array(after.dropFirst()) == Array(before.dropFirst())
              && undone && texts() == before,
              "Replace Pages… (Pages menu): page 1 swapped for the last page's copy, the others as they were (\(after.count) pages), undone")
    }

    /// A4 from Resize Pages' list.
    private static var paperSizesA4: (width: Double, height: Double) {
        let a4 = DocumentWindowController.paperSizes.first { $0.name.hasPrefix("A4") }
        return (a4?.width ?? 595, a4?.height ?? 842)
    }
}
