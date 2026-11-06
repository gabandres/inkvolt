import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for E10 (`--edit`, on the synthetic text document; `--only-read-aloud` runs it alone): View ›
/// Read Aloud through the window's own command, with a silent speaker that keeps what it was asked to say (nothing is
/// played over SSH): reading from the top of the view, a word's callback highlighting that word on the page, paragraphs
/// following one another across pages to the end, the bar's pause, next, previous, speed and stop, a selection read alone,
/// ⇧⌘Y twice, and an edit stopping it (then undone). Only counts and short texts are written.
@MainActor
struct ReadAloudTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var pages: PagesView { controller.pages }
    private var reader: ReadAloud { controller.readAloud }

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

    private func toggle() { NSApp.sendAction(#selector(DocumentWindowController.toggleReadAloud(_:)), to: controller, from: nil) }

    private func text(_ page: Int) -> String { (try? controller.engine.text(page))?.text ?? "" }

    private static func short(_ s: String?) -> String {
        guard let s else { return "none" }
        return s.count > 40 ? String(s.prefix(40)) + "…" : s
    }

    /// The page text under the highlighted word.
    private func highlightedWord() -> String? {
        guard let s = pages.speech else { return nil }
        let u = Array(text(s.page).utf16)
        guard s.word.start < s.word.end, s.word.end <= u.count else { return nil }
        return String(decoding: u[s.word.start..<s.word.end], as: UTF16.self)
    }

    mutating func run() async {
        lines.append("== \(name): read aloud (\(controller.engine.pageCount) pages)")
        let item = menuItem(loc("Read Aloud"))
        check(item?.action == #selector(DocumentWindowController.toggleReadAloud(_:)) && item?.keyEquivalent == "y"
              && item?.keyEquivalentModifierMask == [.command, .shift] && item.map { controller.validateMenuItem($0) } == true,
              "View has Read Aloud (⇧⌘Y), enabled on a document")
        let speaker = RecordingSpeaker()
        reader.use(speaker)
        controller.go(0)
        pages.clearSelection()
        pages.scrollTo(y: 0)
        try? await Task.sleep(for: .milliseconds(100))
        let expected0 = ReadAloudText.chunks(0, text(0))

        // From the top of the view.
        toggle()
        check(reader.isActive && !reader.bar.isHidden && speaker.spoken.count == 1 && speaker.spoken.first?.text == expected0.first?.text,
              "Read Aloud starts at the top of the first page: \"\(Self.short(speaker.spoken.first?.text))\", the bar shown")
        check(item.map { controller.validateMenuItem($0) && $0.state == .on } == true, "the menu item is checked while reading")

        // A word's callback highlights that word on the page.
        if let first = expected0.first {
            let u = Array(first.text.utf16)
            let s = (u.firstIndex(of: 32) ?? 0) + 1
            let e = u[s...].firstIndex(of: 32) ?? u.count
            let word = String(decoding: u[s..<e], as: UTF16.self)
            speaker.word(s, e)
            check(highlightedWord() == word && pages.speech?.page == 0, "the word being read is highlighted on its page: \"\(highlightedWord() ?? "none")\"")
        }

        // Paragraphs follow one another; pause, next, previous, speed.
        speaker.finish()
        check(expected0.count < 2 || speaker.spoken.last?.text == expected0[1].text, "the next paragraph follows when one ends: \(reader.state)")
        reader.bar.pauseButton.performClick(nil)
        check(reader.isPaused && speaker.paused && reader.state.hasPrefix("paused"), "Pause pauses the voice")
        reader.bar.pauseButton.performClick(nil)
        check(!reader.isPaused && !speaker.paused, "Resume goes on")
        let atNext = speaker.spoken.count
        reader.bar.nextButton.performClick(nil)
        let afterNext = speaker.spoken.last?.text
        reader.bar.previousButton.performClick(nil)
        check(speaker.spoken.count == atNext + 2 && afterNext != speaker.spoken.last?.text && speaker.spoken.last?.text == speaker.spoken[atNext - 1].text,
              "Next and Previous Paragraph move by a paragraph")
        let speed = ReadAloud.speeds.firstIndex(of: 1.5) ?? 3
        reader.bar.speedPopup.selectItem(at: speed)
        reader.bar.speedPopup.sendAction(reader.bar.speedPopup.action, to: reader.bar.speedPopup.target)
        check(speaker.spoken.last?.speed == 1.5 && reader.speed == 1.5, "a new speed reads the paragraph again at 1.5×")
        reader.bar.speedPopup.selectItem(at: 1)
        reader.bar.speedPopup.sendAction(reader.bar.speedPopup.action, to: reader.bar.speedPopup.target)

        // To the end of the document, across pages.
        var pagesRead = Set<Int>()
        for _ in 0..<500 where reader.isActive {
            if let p = reader.speaking?.page { pagesRead.insert(p) }
            speaker.finish()
        }
        let withText = (0..<controller.engine.pageCount).filter { !ReadAloudText.chunks($0, text($0)).isEmpty }
        check(!reader.isActive && reader.bar.isHidden && pages.speech == nil && Set(withText).isSubset(of: pagesRead),
              "reading goes on across pages \(pagesRead.sorted().map { $0 + 1 }) and stops at the end, the bar hidden")

        // A selection is read alone.
        if let first = expected0.first {
            let from = first.sourceStart, to = min(from + 40, first.source.last.map { $0 + 1 } ?? from)
            pages.select(0, (from, to))
            let before = speaker.spoken.count
            toggle()
            let want = ReadAloudText.chunks(0, text(0), from: from, to: to)
            for _ in 0..<50 where reader.isActive { speaker.finish() }
            let got = speaker.spoken[before...].map(\.text)
            check(!want.isEmpty && got == want.map(\.text), "a selection is read alone: \(got.count) paragraph(s), \"\(Self.short(got.first))\"")
            pages.clearSelection()
        }

        // ⇧⌘Y again stops; Stop on the bar too.
        toggle()
        toggle()
        check(!reader.isActive, "Read Aloud chosen again stops reading")
        toggle()
        reader.bar.stopButton.performClick(nil)
        check(!reader.isActive && reader.bar.isHidden, "Stop on the bar stops reading")

        // An edit stops reading (as on Windows), then it is undone.
        toggle()
        let edits = controller.editor.finishedEdits
        NSApp.sendAction(#selector(DocumentWindowController.rotatePagesRight(_:)), to: controller, from: nil)
        for _ in 0..<400 where controller.editor.finishedEdits == edits { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(100))
        check(controller.editor.finishedEdits > edits && !reader.isActive, "an edit to the document stops reading")
        controller.pdf.undo()
        try? await Task.sleep(for: .milliseconds(200))
        reader.use(SystemSpeaker())

        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
