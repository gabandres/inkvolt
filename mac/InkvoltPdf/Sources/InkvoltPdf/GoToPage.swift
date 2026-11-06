import AppKit
import PdfCore
import PrintCore

/// Go › Go to Page… (⌥⌘G; Windows: Go to Page…, Ctrl+G, which focuses the page box): a page number or the page's label
/// as the file names it ("iv", "A-3"), a matching label first, as Windows' `DocumentTab.FindPage`. Asked again, saying
/// the range, when nothing matches.
extension DocumentWindowController {
    @objc func goToPage(_ sender: Any?) {
        Task { await askGoToPage() }
    }

    /// The page `text` names in this document: a label first, then a number.
    func findPage(_ text: String) -> Int? {
        let labels = pdf.session.flatMap { try? DocumentFeatures.pageLabels($0.data, $0.password) }
        return DocumentFeatures.findPage(labels, text, pageCount: engine.pageCount)
    }

    func askGoToPage() async {
        guard let window, engine.pageCount > 0 else { return }
        if organizerShown { showOrganizer(false) }
        let range = loc("Enter a page from 1 to {0}.", CoreLanguage.number(engine.pageCount))
        if Report.skipsDialogs {
            guard let answer = GoToPageState.testAnswer else { return }
            if let page = findPage(answer) {
                GoToPageState.lastProblem = nil
                go(page)
            } else {
                GoToPageState.lastProblem = range
            }
            return
        }
        let field = NSTextField(string: "")
        field.placeholderString = "1–\(engine.pageCount)"
        field.setAccessibilityLabel(loc("Page number or label"))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Go to Page")
            alert.informativeText = problem ?? GoToPageWords.prompt
            alert.addButton(withTitle: loc("Go"))
            alert.addButton(withTitle: loc("Cancel"))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            if let page = findPage(field.stringValue) {
                go(page)
                window.makeFirstResponder(activePages)
                return
            }
            problem = GoToPageWords.problem(typed: field.stringValue, pageCount: engine.pageCount)
            field.selectText(nil)
        }
    }
}

/// What the self-test types into Go to Page (the sheet isn't shown while it runs), and the last problem it said.
@MainActor
enum GoToPageState {
    static var testAnswer: String?
    static var lastProblem: String?
}
