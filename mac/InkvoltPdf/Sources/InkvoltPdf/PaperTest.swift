import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for Wave 4's paper commands (roadmap Batch A; `--edit`, on the synthetic text document;
/// `--only-paper` runs it alone): each through the menu bar's item (enabled, its sheet's edit run as the sheet runs it)
/// and the edit the sheet makes, checked on the document, then undone so the next starts from the document as opened.
/// Page Labels (4.14). Only counts, labels and states are written.
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
}
