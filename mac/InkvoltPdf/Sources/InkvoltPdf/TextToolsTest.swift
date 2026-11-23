import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for Wave 4's text tools (`--edit --only-text-tools`, on the synthetic text document): Edit ›
/// Find's Highlight All Matches (roadmap 4.18) chosen from the menu bar after a search, as one undo step, then again with
/// nothing left to mark. Only counts and states are written.
@MainActor
struct TextToolsTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var pages: PagesView { controller.pages }
    private var editor: DocumentEditor { controller.editor }
    private var session: DocumentSession? { controller.pdf.session }

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

    /// Waits for the window's long task (and the edit it runs) to end, at most `seconds`.
    private func waitIdle(_ seconds: Double = 20) async {
        let end = Date().addingTimeInterval(seconds)
        await settle(50)
        while controller.longTask != nil && Date() < end { await settle(50) }
    }

    private func find(_ query: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controller.onFindFinished = { done.resume() }
            controller.find(query)
        }
        controller.onFindFinished = nil
    }

    /// The first word of four letters or more on page 1.
    private func firstWord() -> String? {
        guard let text = try? controller.engine.text(0) else { return nil }
        return text.text.split { !$0.isLetter }.first { $0.count >= 4 }.map(String.init)
    }

    mutating func run() async {
        lines.append("== \(name): text tools (\(controller.engine.pageCount) pages)")
        await markAllMatches()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    // MARK: Mark All Matches (4.18)

    private mutating func markAllMatches() async {
        guard let word = firstWord() else {
            lines.append("SKIP Mark All Matches: no word on page 1")
            return
        }
        let off = menuItem(loc("Highlight All Matches")).map { controller.validateMenuItem($0) }
        await find(word)
        let hits = controller.found.count
        let before = editor.comments.filter { $0.subtype == "Highlight" }.count
        check(off == false && hits > 0 && choose(loc("Highlight All Matches")),
              "Edit › Find › Highlight All Matches is off before a search, on after it (\(hits) matches)")
        await waitIdle()
        let marks = editor.comments.filter { $0.subtype == "Highlight" }.count - before
        let step = hits == 1 ? loc("Highlight 1 match") : loc("Highlight {0} matches", CoreLanguage.number(hits))
        check(marks == hits && session?.undoLabel == step,
              "every match highlighted as one undo step: \(marks) marks for \(hits) matches, step \(session?.undoLabel ?? "none")")
        await settle(300)
        check(controller.found.count == hits, "the search runs again on the marked document: \(controller.found.count) matches")
        let edits = editor.finishedEdits
        choose(loc("Highlight All Matches"))
        await waitIdle()
        check(editor.finishedEdits == edits && editor.comments.filter { $0.subtype == "Highlight" }.count - before == marks,
              "chosen again, nothing is marked twice")
        controller.window?.undoManager?.undo()
        await settle(300)
        check(editor.comments.filter { $0.subtype == "Highlight" }.count == before, "one Undo takes every mark away")
        controller.find("")
    }
}
