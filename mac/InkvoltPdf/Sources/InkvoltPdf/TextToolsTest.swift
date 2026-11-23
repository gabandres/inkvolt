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
        await linksFromAddresses()
        lines.append("RESULT:\(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
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

    // MARK: Links from Addresses (4.15)

    private mutating func linksFromAddresses() async {
        // The document has no address: the command says so and changes nothing.
        let before = session?.data
        check(choose(loc("Links from Addresses…")), "Tools › Annotate › Links from Addresses… is enabled")
        await waitIdle()
        check(session?.data == before && controller.noticeBar.message.hasPrefix(loc("No web or email address in the text needs a link")),
              "a document without addresses: said, nothing changed")

        // A line rewritten to hold two addresses (Edit Text & Images' run edit), then linked in one step.
        guard let data = session?.data, let content = try? ContentEditor.read(data, session?.password, 0),
              let run = content.runs.first(where: { $0.text.hasPrefix("Highlight these words") }) else {
            lines.append("SKIP Links from Addresses: the line to rewrite wasn't found")
            return
        }
        let links = editor.links.count
        _ = await editor.replaceText(run, "Visit www.example.org or write to help@example.com today.")
        choose(loc("Links from Addresses…"))
        await waitIdle()
        let added = editor.links.filter { $0.uri == "https://www.example.org/" || $0.uri == "mailto:help@example.com" }.count
        check(added == 2 && editor.links.count == links + 2 && session?.undoLabel == loc("Add {0} links", CoreLanguage.number(2)),
              "both addresses linked as one undo step: \(added) links, step \(session?.undoLabel ?? "none")")
        choose(loc("Links from Addresses…"))
        await waitIdle()
        check(editor.links.count == links + 2, "run again, an address already linked isn't linked twice")
        controller.window?.undoManager?.undo()
        controller.window?.undoManager?.undo()
        await settle(300)
        check(session?.data == data && editor.links.count == links, "Undo takes the links and the rewrite away")
    }
}
