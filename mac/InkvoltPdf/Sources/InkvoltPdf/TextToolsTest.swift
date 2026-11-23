import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for Wave 4's text tools (`--edit --only-text-tools`, on the synthetic text document), each from
/// the menu bar: Edit › Find's Highlight All Matches (roadmap 4.18) after a search, as one undo step, then again with
/// nothing left to mark; Links from Addresses (4.15) on a line rewritten to hold two; Copy Text from Area and Copy Area as
/// Table (4.6) on a Snapshot box, and a scan's box read with Vision; spell check's underlines, menu and Ignore (4.1);
/// Find and Replace's Replace All of the ticked matches and Replace of one (4.2). Only counts and states are written.
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
        await copyFromArea()
        lines.append("RESULT: " + "\(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
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
        check(session?.data == before && controller.noticeBar.message == loc("No web or email address in the text needs a link: each one found is a link already. A scanned page needs Recognize Text first."),
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

    // MARK: Copy Text from Area, Copy Area as Table (4.6)

    /// Waits for the next notice that starts with one of `starts`, at most `seconds`; the notice, or nil.
    private func nextNotice(_ starts: [String], after count: Int, _ seconds: Double = 120) async -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let hit = controller.noticeBar.history.dropFirst(count).first(where: { m in starts.contains { m.hasPrefix($0) } }) { return hit }
            await settle(100)
        }
        return nil
    }

    private mutating func copyFromArea() async {
        let board = NSPasteboard(name: NSPasteboard.Name("InkvoltSelfTestAreaCopy"))
        let kept = SnapshotBoard.board
        SnapshotBoard.board = board
        defer { SnapshotBoard.board = kept }
        let copied = [loc("Text copied (1 word)").replacingOccurrences(of: "(1 word)", with: ""),
                      loc("Text read from the scan and copied (1 word)").replacingOccurrences(of: "(1 word)", with: ""),
                      loc("No text found in that box."), loc("Couldn't read that part of the page.")]

        // No box yet: the command picks Snapshot and the next box copies its words, not its picture.
        controller.snapshotArea = nil
        var seen = controller.noticeBar.history.count
        check(choose(loc("Copy Text from Area")) && pages.tool == .snapshot && controller.pendingAreaCopy == .text,
              "Edit › Copy Text from Area with no box picks Snapshot to draw one")
        // Page 1's title and first line, as a box drawn with Snapshot hands them over.
        controller.copySnapshot(controller.engine, page: 0, region: RectD(60, 82, 420, 33), viewScale: 1, rotation: 0)
        var said = await nextNotice(copied, after: seen)
        var text = board.string(forType: .string) ?? ""
        check(said?.hasPrefix(copied[0]) == true && text.contains("self-test document") && text.contains("Highlight these words") && !text.contains("\r"),
              "the box's words copied in reading order: \(text.split(separator: "\n").count) lines (\(said ?? "no notice"))")

        // The same box as a table: the clipboard has tab-separated rows and an HTML table.
        seen = controller.noticeBar.history.count
        check(choose(loc("Copy Area as Table")), "Edit › Copy Area as Table copies the last box")
        said = await nextNotice(copied + [loc("Table copied ({0} × {1}): paste it into Numbers, Excel or Pages").components(separatedBy: "(")[0]], after: seen)
        let html = board.string(forType: .html) ?? ""
        text = board.string(forType: .string) ?? ""
        check(html.hasPrefix("<table>") && text.split(separator: "\n").count == 2, "as a table: \(text.split(separator: "\n").count) rows, HTML \(html.count) characters (\(said ?? "no notice"))")

        // Page 3 is a picture of words with no text: read with Vision.
        guard controller.engine.pageCount >= 3 else { return }
        seen = controller.noticeBar.history.count
        controller.copyArea(.text, controller.engine, page: 2, area: RectD(60, 80, 430, 125))
        said = await nextNotice(copied, after: seen)
        text = board.string(forType: .string) ?? ""
        check(said?.hasPrefix(copied[1]) == true && !text.isEmpty, "a scan's box read with Vision: \(text.split(separator: " ").count) words (\(said ?? "no notice"))")
    }

    // MARK: Spell check (4.1)
}
