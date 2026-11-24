import AppKit
import PdfCore
import PrintCore

/// Pages › Replace Pages… (Windows' `Organize.Replace`, roadmap 4.13): pages of this document swapped one for one for pages
/// of another PDF (`PageEditor.replace`: what led to a replaced page leads to its replacement, which keeps its label), as
/// one undo step.
extension DocumentWindowController {
    @objc func replacePages(_ sender: Any?) {
        guard let window, pdf.session != nil else { return NSSound.beep() }
        let chosen = selectedPages
        guard !chosen.isEmpty else { return NSSound.beep() }
        Task { await askReplace(chosen, window) }
    }

    /// The accessibility audit's other PDF (`UxShots`), chosen without the open panel, which is the system's own.
    static var testReplaceSource: URL?

    private func askReplace(_ chosen: [Int], _ window: NSWindow) async {
        var picked = Self.testReplaceSource
        Self.testReplaceSource = nil
        if picked == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            panel.message = loc("Choose the PDF with the new pages")
            guard await panel.beginSheetModal(for: window) == .OK else { return }
            picked = panel.url
        }
        guard let url = picked, let source = loadSource([url]) else { return }
        guard let srcEngine = try? PdfEngine.open(source.data, password: source.password) else {
            return pdf.showError(loc("Those pages couldn't be read."), nil)
        }
        let srcCount = srcEngine.pageCount
        srcEngine.close()
        let count = engine.pageCount

        let note = NSTextField(wrappingLabelWithString: srcCount == 1 ? loc("{1} has 1 page.", CoreLanguage.number(1), url.lastPathComponent)
                               : loc("{1} has {0} pages.", CoreLanguage.number(srcCount), url.lastPathComponent))
        note.preferredMaxLayoutWidth = 380
        let range = NSTextField(string: PageRange.format(chosen))
        range.setAccessibilityLabel(loc("Replace these pages"))
        let srcRange = NSTextField(string: srcCount > 1 ? "1-\(min(srcCount, max(1, chosen.count)))" : "1")
        srcRange.setAccessibilityLabel(loc("With these pages of the other PDF"))
        for f in [range, srcRange] { f.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        let explain = NSTextField(wrappingLabelWithString: loc("Bookmarks and links that led to a replaced page lead to the page that takes its place."))
        explain.preferredMaxLayoutWidth = 380
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 380
        problem.isHidden = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: loc("Replace these pages:")), range],
            [NSTextField(labelWithString: loc("With these pages of the other PDF:")), srcRange],
        ])
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [note, grid, explain, problem])
        stack.orientation = .vertical
        stack.alignment = .leading

        var pages: [Int] = [], srcPages: [Int] = []
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Replace Pages")
            alert.addButton(withTitle: loc("Replace"))
            alert.addButton(withTitle: loc("Cancel"))
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            alert.window.initialFirstResponder = range
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            let r = PageRange.tryParse(range.stringValue, count), s = PageRange.tryParse(srcRange.stringValue, srcCount)
            let wrong = !r.ok ? r.error : !s.ok ? s.error : r.pages.count != s.pages.count
                ? loc("{0} pages to replace but {1} to put in: choose as many of each.", CoreLanguage.number(r.pages.count), CoreLanguage.number(s.pages.count)) : nil
            if let wrong {
                problem.stringValue = wrong
                problem.isHidden = false
                continue
            }
            (pages, srcPages) = (r.pages, s.pages)
            break
        }
        guard engine.pageCount == count else { return } // the document changed meanwhile
        await replace(pages, with: source, srcPages)
    }

    // MARK: The edit (the sheet and the self-test call it)

    @discardableResult
    func replace(_ chosen: [Int], with source: PdfSource, _ sourcePages: [Int]) async -> Bool {
        let label = chosen.count == 1 ? loc("Replace 1 page with {1}", CoreLanguage.number(1), source.name)
            : loc("Replace {0} pages with {1}", CoreLanguage.number(chosen.count), source.name)
        let ok = await editor.run(label) { d, pw in try PageEditor.replace(d, pw, chosen, source, sourcePages) }
        if ok { reselect(chosen) }
        return ok
    }
}
