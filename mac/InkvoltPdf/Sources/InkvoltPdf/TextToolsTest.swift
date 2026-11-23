import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for Wave 4's text tools (`--edit --only-text-tools`, on the synthetic text document), each from
/// the menu bar: Edit › Find's Highlight All Matches (roadmap 4.18) after a search, as one undo step, then again with
/// nothing left to mark; Links from Addresses (4.15) on a line rewritten to hold two; Copy Text from Area and Copy Area as
/// Table (4.6) on a Snapshot box, and a scan's box read with Vision; spell check's underlines, menu and Ignore (4.1);
/// Find and Replace's Replace All of the ticked matches and Replace of one (4.2); Insert Text and Replace Text (4.17), the
/// Comments list showing Replace Text as one row, and one Delete taking it whole. Only counts and states are written.
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
        spellCheck()
        await findAndReplace()
        await proofreading()
        lines.append("RESULT: " + "\(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    // MARK: Proofreading marks (4.17)

    private mutating func proofreading() async {
        guard let text = try? controller.engine.text(0), let word = firstWord(), let r = text.text.range(of: word) else {
            lines.append("SKIP proofreading marks: no word on page 1")
            return
        }
        let start = text.text.utf16.distance(from: text.text.utf16.startIndex, to: r.lowerBound), end = start + word.utf16.count
        let before = editor.comments.count, rowsBefore = controller.sidebar.comments.topCount
        func carets() -> [AnnotationInfo] { editor.comments.filter { $0.subtype == "Caret" } }
        pages.clearSelection()
        let off = menuItem(loc("Insert Text…")).map { controller.validateMenuItem($0) }
        pages.select(0, (start, end))
        controller.testText = "inserted words"
        check(off == false && choose(loc("Insert Text…")), "Insert Text… is off with no place in the text, on with a selection")
        await settle(400)
        let inserted = carets().first { $0.contents == "inserted words" }
        check(inserted != nil && inserted?.subject == "Inserted Text" && session?.undoLabel == loc("Insert text") && pages.selection == nil,
              "Insert Text puts a caret holding the words at the selection's end, one undo step: \(carets().count) carets")
        pages.select(0, (start, end))
        controller.testText = "swapped words"
        check(choose(loc("Replace Text…")), "Replace Text… is on with a selection")
        await settle(400)
        let replacing = carets().first { $0.contents == "swapped words" }
        let strike = editor.comments.first { $0.subtype == "StrikeOut" && $0.grouped && $0.replyTo == replacing?.id }
        let kinds = controller.sidebar.comments.topKinds
        check(replacing != nil && strike != nil && session?.undoLabel == loc("Replace text"),
              "Replace Text strikes the word out, grouped with a caret holding the new words")
        check(controller.sidebar.comments.topCount == rowsBefore + 2 && kinds.contains(loc("Replace text")) && kinds.contains(loc("Insert text")),
              "the Comments list shows each mark once, by what it asks: \(controller.sidebar.comments.topCount - rowsBefore) rows")
        controller.testText = nil
        if let strike {
            pages.select(strike.id)
            pages.deleteSelected()
            await settle(400)
        }
        check(carets().count == 1 && !editor.comments.contains { $0.id == strike?.id }, "deleting the strike-out takes its caret too")
        for _ in 0..<3 {
            controller.window?.undoManager?.undo()
            await settle(300)
        }
        check(editor.comments.count == before, "Undo takes both marks away: \(editor.comments.count - before) left")
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

    private mutating func spellCheck() {
        guard let checker = SpellCheck.checker("en-US") else {
            check(!AppSettings.spellCheck, "spell check: the Mac has an English dictionary")
            return
        }
        // An editor's text: a misspelling underlined; an address, a number and an acronym left alone.
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        view.string = "The quikc fox read www.exmaple.com on A4 paper for NASA."
        SpellCheck.underline(view, checker)
        func underlined(_ word: String) -> Bool {
            let r = (view.string as NSString).range(of: word)
            var effective = NSRange()
            return view.layoutManager?.temporaryAttribute(.spellingState, atCharacterIndex: r.location, effectiveRange: &effective) != nil
        }
        check(underlined("quikc") && !underlined("fox") && !underlined("exmaple") && !underlined("A4") && !underlined("NASA"),
              "a misspelling is underlined; a known word, an address, A4 and NASA aren't")

        // Its menu: suggestions first, then Ignore Spelling and Add to Dictionary; Ignore holds for the session.
        let at = (view.string as NSString).range(of: "quikc").location + 2
        let menu = SpellCheck.menu(NSMenu(), view, at: at, checker) { SpellCheck.underline(view, checker) }
        let titles = menu.items.map(\.title)
        check(titles.contains("quick") && titles.contains(loc("Ignore Spelling")) && titles.contains(loc("Add to Dictionary")),
              "the menu on it: \(titles.prefix(4).joined(separator: ", "))…")
        if let ignore = menu.items.first(where: { $0.title == loc("Ignore Spelling") }), let action = ignore.action {
            NSApp.sendAction(action, to: ignore.target, from: ignore)
        }
        check(!underlined("quikc") && checker.isIgnored("quikc") && SpellCheck.checker("en-US")?.check("quikc").isEmpty == true,
              "Ignore Spelling: not underlined again, here or in another editor")
        // A suggestion replaces the word where it is.
        view.string = "A wrng word"
        SpellCheck.underline(view, checker)
        let fix = SpellCheck.menu(NSMenu(), view, at: 3, checker) { SpellCheck.underline(view, checker) }
        if let first = fix.items.first, let action = first.action, first.title != loc("No Suggestions") {
            NSApp.sendAction(action, to: first.target, from: first)
        }
        check(view.string != "A wrng word" && view.string.hasPrefix("A ") && view.string.hasSuffix(" word"), "a suggestion replaces the word: “\(view.string)”")

        // Settings › Check spelling as I type, off: nothing is checked.
        let was = AppSettings.spellCheck
        AppSettings.spellCheck = false
        check(SpellCheck.checker("en-US") == nil, "turned off in Settings: no spell checker")
        AppSettings.spellCheck = was
    }

    // MARK: Find and Replace (4.2)

    /// Waits until the sheet's search is in, at most `seconds`.
    private func searched(_ sheet: ReplaceSheet, _ seconds: Double = 20) async {
        let end = Date().addingTimeInterval(seconds)
        await settle(400) // past the typing pause
        while sheet.busy && Date() < end { await settle(50) }
    }

    private mutating func findAndReplace() async {
        guard let before = session?.data, let text = try? ContentEditor.read(before, nil, 0).paragraphs.map(\.text).joined(separator: " "),
              text.contains("five dozen") else {
            lines.append("SKIP Find and Replace: the synthetic text wasn't found")
            return
        }
        check(choose(loc("Find and Replace…")) && controller.replaceSheet != nil, "Edit › Find › Find and Replace… opens its sheet")
        guard let sheet = controller.replaceSheet else { return }
        sheet.findField.stringValue = "five dozen"
        sheet.withField.stringValue = "six dozen"
        sheet.search()
        await searched(sheet)
        let found = sheet.matches.count
        check(found == 2 && sheet.matches.map(\.pageIndex) == [0, 1], "both pages' “five dozen” listed: \(found) matches")
        sheet.untick(1)
        let edits = editor.finishedEdits
        sheet.replaceAllClicked()
        let end0 = Date().addingTimeInterval(30)
        while editor.finishedEdits == edits && Date() < end0 { await settle(50) }
        await settle(300)
        let page1 = (try? ContentEditor.read(session?.data ?? [], nil, 0).paragraphs.map(\.text).joined(separator: " ")) ?? ""
        let page2 = (try? ContentEditor.read(session?.data ?? [], nil, 1).paragraphs.map(\.text).joined(separator: " ")) ?? ""
        check(page1.contains("six dozen") && page2.contains("five dozen") && session?.undoLabel == loc("Replace All")
              && controller.lastReplace?.replaced == 1 && controller.replaceSheet == nil,
              "Replace All changes the ticked match only, as one undo step: \(controller.lastReplace?.replaced ?? -1) replaced")
        controller.window?.undoManager?.undo()
        await settle(300)
        check(session?.data == before, "Undo puts it back")

        // Replace: the selected match now, then the list found again with the next one selected.
        choose(loc("Find and Replace…"))
        guard let again = controller.replaceSheet else { return check(false, "the sheet opens again") }
        check(again.findField.stringValue == "five dozen" && again.withField.stringValue == "six dozen", "it remembers what was looked for")
        again.search()
        await searched(again)
        again.replaceClicked()
        let end = Date().addingTimeInterval(20)
        while (again.busy || again.matches.count == 2) && Date() < end { await settle(100) }
        await searched(again)
        check(again.matches.count == 1 && again.matches.first?.pageIndex == 1 && session?.undoLabel == loc("Replace"),
              "Replace changes one and lists the rest: \(again.matches.count) left")
        again.closeClicked()
        controller.window?.undoManager?.undo()
        await settle(300)
        check(controller.replaceSheet == nil && session?.data == before, "Close, and Undo puts it back")
    }
}
