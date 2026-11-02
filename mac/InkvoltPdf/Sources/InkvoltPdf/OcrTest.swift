import AppKit
import PdfCore

/// The self-test's scenario for E14 (`--edit`, on the synthetic text document, before `FeatureTest` recognizes its scan page;
/// `--only-ocr` runs it alone): Recognize Text with roadmap 2.2's pipeline (what the dialog runs with its choices) on the
/// scan page, through a stand-in recognizer and dictionary so the words are known: the page cleaned before it is read,
/// one suspect word marked, the Suspect Words pane opened on it; the word corrected through the pane's own suggestion
/// button (search finds the correction), undone, kept as read through Keep as Read, a two-word correction refused; then
/// Replace the scans with the cleaned pages; every step undone at the end. Only counts and words are written.
@MainActor
struct OcrTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    /// Reads three words at fixed places of whatever page image it is given; notes whether that image was grey (the
    /// cleaned page is; the rendered one is RGB).
    final class StandInReader: TextRecognizer, @unchecked Sendable {
        private(set) var calls = 0
        private(set) var sawGray = false
        var language: String? { "en-US" }

        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
            calls += 1
            var gray = true
            var i = 0
            while i + 2 < image.pixels.count && gray {
                gray = image.pixels[i] == image.pixels[i + 1] && image.pixels[i + 1] == image.pixels[i + 2]
                i += 3 * 97
            }
            sawGray = gray
            let (w, h) = (Double(image.width), Double(image.height))
            return [OcrWord("Inkvolt", RectD(w * 0.12, h * 0.10, w * 0.14, h * 0.02)),
                    OcrWord("recognlzed", RectD(w * 0.28, h * 0.10, w * 0.18, h * 0.02)),
                    OcrWord("text", RectD(w * 0.48, h * 0.10, w * 0.07, h * 0.02))]
        }
    }

    struct StandInDictionary: Spelling {
        var language: String { "en-US" }
        func isKnown(_ word: String) -> Bool { ["inkvolt", "text", "recognized"].contains(word.lowercased()) }
        func suggest(_ word: String) -> [String] { ["recognized"] }
    }

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

    private func wait(_ seconds: Double = 20, _ done: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    private var pane: SuspectWordsPane { controller.sidebar.suspectWords }
    private var undoLabel: String? { controller.pdf.session?.undoLabel }

    private func layer(_ page: Int) -> OcrLayer? {
        guard let s = controller.pdf.session else { return nil }
        return (try? TextLayer.words(s.data, s.password))?[page]
    }

    private func found(_ page: Int, _ word: String) -> Int {
        guard let text = try? controller.engine.text(page) else { return 0 }
        return text.find(word, matchCase: true, wholeWord: true).count
    }

    /// Undoes until the undo label is `label` again (at most `steps` times).
    private func undo(to label: String?, steps: Int = 8) async {
        for _ in 0..<steps where undoLabel != label {
            let before = undoLabel
            controller.pdf.undo()
            _ = await wait(10) { undoLabel != before }
        }
    }

    mutating func run() async {
        lines.append("== \(name): Recognize Text with cleaning and suspect words (E14)")
        let recognize = menuItem("Recognize Text (OCR)…"), review = menuItem("Review Suspect Words")
        check(recognize?.action == #selector(DocumentWindowController.recognizeText(_:))
              && review?.action == #selector(DocumentWindowController.reviewSuspectWords(_:)),
              "Tools has Recognize Text (OCR)… and Review Suspect Words")
        guard let scanPage = (0..<controller.engine.pageCount).first(where: { !((try? TextLayer.hasText(controller.engine, $0)) ?? true) }) else {
            lines.append("SKIP: no page without text")
            return finish()
        }
        let start = undoLabel
        check(!controller.sidebar.showsSuspectWords, "the Suspect Words segment can't be chosen before any word is marked")

        // Recognize Text as the dialog runs it with Clean and Mark suspect words on.
        let reader = StandInReader()
        let result = await controller.runRecognize(pages: [scanPage], options: RecognizeOptions(clean: true, checkWords: true),
                                                   ocr: reader, spelling: StandInDictionary())
        let r = result.report
        check(result.outcome == .done && r?.words == 3 && r?.suspect == 1 && undoLabel == "Recognize text",
              "Recognize Text on page \(scanPage + 1): \(r?.words ?? 0) words, \(r?.suspect ?? 0) suspect, one undo step")
        check(reader.sawGray && reader.calls >= 2, "the recognizer was given the cleaned (grey) page, and the page as scanned to compare (\(reader.calls) readings)")
        let words = layer(scanPage)
        check(words?.words.map(\.text) == ["Inkvolt", "recognlzed", "text"] && words?.language == "en-US"
              && words?.words[1].suspect == .notInDictionary,
              "the text layer keeps the words, the language and the suspect reason: \(words?.words.map(\.text) ?? [])")
        _ = await wait(5) { controller.sidebar.shownPane == .suspectWords && pane.items.count == 1 }
        check(controller.sidebar.showsSuspectWords && controller.sidebar.shownPane == .suspectWords && pane.items.first?.word.text == "recognlzed"
              && pane.summaryText.hasPrefix("1 suspect word on 1 page"),
              "the Suspect Words pane opens on the suspect word: \(pane.summaryText)")

        // Corrected through the pane's own suggestion button.
        pane.suggest = { _ in StandInDictionary().suggest("") }
        pane.choose(0)
        check(pane.suggestionTitles == ["recognized"] && pane.field.stringValue == "recognlzed",
              "choosing it shows the dictionary's suggestion and the word to correct")
        if !pane.suggestionTitles.isEmpty { pane.press(suggestion: 0) }
        _ = await wait { undoLabel == "Correct recognized word" && pane.items.isEmpty }
        check(undoLabel == "Correct recognized word" && layer(scanPage)?.words.map(\.text) == ["Inkvolt", "recognized", "text"]
              && layer(scanPage)?.words.allSatisfy { $0.suspect.isEmpty } == true && found(scanPage, "recognized") == 1
              && found(scanPage, "recognlzed") == 0,
              "the suggestion corrects it as one undo step; search finds “recognized”, not “recognlzed”")
        check(pane.items.isEmpty && pane.summaryText.hasPrefix("No suspect words left"), "the list follows: \(pane.summaryText)")

        // Undone, then kept as read; a two-word correction refused.
        await undo(to: "Recognize text", steps: 1)
        _ = await wait { pane.items.count == 1 }
        check(undoLabel == "Recognize text" && pane.items.count == 1 && found(scanPage, "recognlzed") == 1, "Undo puts the suspect word back in the list")
        pane.choose(0)
        pane.field.stringValue = "recog nized"
        pane.correctButton.performClick(nil)
        try? await Task.sleep(for: .milliseconds(300))
        check(undoLabel == "Recognize text" && pane.items.count == 1, "a correction of two words is refused: one word replaces one word")
        pane.keepButton.performClick(nil)
        _ = await wait { undoLabel == "Keep recognized word" && pane.items.isEmpty }
        check(undoLabel == "Keep recognized word" && layer(scanPage)?.words[1].text == "recognlzed"
              && layer(scanPage)?.words[1].suspect.isEmpty == true && pane.items.isEmpty,
              "Keep as Read leaves the word as read and takes it off the list (one undo step)")

        // Replace the scans with the cleaned pages.
        await undo(to: start)
        check(undoLabel == start && layer(scanPage) == nil, "undone back to before Recognize Text")
        let replaced = await controller.runRecognize(pages: [scanPage], options: RecognizeOptions(clean: true, checkWords: false, keepCleanedImage: true),
                                                     ocr: StandInReader(), spelling: nil)
        // The page draws its cleaned image (the content stream "/PdScan Do" is written uncompressed).
        let scanName = controller.pdf.session.map { Data($0.data).range(of: Data("/PdScan Do".utf8)) != nil } ?? false
        check(replaced.outcome == .done && replaced.report?.replaced == 1 && scanName && found(scanPage, "Inkvolt") == 1,
              "Replace the scans: the page is its cleaned image (\(replaced.report?.replaced ?? 0) replaced), its words still found")
        await undo(to: start)
        check(undoLabel == start, "every step undone")
        // As found: the thumbnails in the sidebar and the pages taking the keys, for the scenarios that follow.
        controller.sidebar.show(.pages)
        controller.sidebar.showsSuspectWords = false
        controller.window?.makeFirstResponder(controller.pages)
        finish()
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
