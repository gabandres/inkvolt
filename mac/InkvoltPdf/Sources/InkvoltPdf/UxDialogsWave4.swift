import AppKit
import PdfCore
import PrintCore

/// Wave 4's sheets and windows in the UX walk (`--ux-shots`, and `--ax-audit`, which audits each for VoiceOver): the paper
/// commands (Replace Pages, Remove and Split at Blank Pages with their pictures to tick, Bookmarks from Headings, Grid
/// Spacing), Scan the Backs, Ask Across Folders, Search by Meaning's settings, Edit by Asking's request
/// and Steps Proposed, Summary to Audio before the assistant is set up, and the document window with its rulers. A
/// choice made first in a system panel (Replace Pages' other PDF) or a search (the blank pages) is given by the step, so
/// the sheet itself shows; each is cancelled as the walk's other dialogs are. Popovers (Insert Text, Turn to Angle) aren't
/// windows the walk finds: a person checks those.
extension UxShots {
    typealias Send = (Selector) -> @MainActor () -> Void

    mutating func wave4Paper(_ look: String, audits: Bool, _ send: Send) async {
        let c = controller
        await dialog([Step("replace-pages-\(look)")], audits: audits) { [weak c] in
            DocumentWindowController.testReplaceSource = Report.syntheticPath.map { (path: String) -> URL in URL(fileURLWithPath: path) }
            c?.window?.makeKeyAndOrderFront(nil)
            NSApp.sendAction(NSSelectorFromString("replacePages:"), to: c, from: nil)
        }
        let blanks: [(String, String)] = [("remove-blank", "removeBlankPages:"), ("split-blank", "splitAtBlankPages:")]
        for (name, action) in blanks {
            await dialog([Step("\(name)-\(look)")], audits: audits) { [weak c] in
                DocumentWindowController.testBlankPages = [1]
                c?.window?.makeKeyAndOrderFront(nil)
                NSApp.sendAction(NSSelectorFromString(action), to: c, from: nil)
            }
        }
        await dialog([Step("headings-\(look)")], audits: audits, wait: 900, skipProgress: true, send(NSSelectorFromString("bookmarksFromHeadings:")))
        await dialog([Step("grid-spacing-\(look)")], audits: audits, send(NSSelectorFromString("chooseGridSpacing:")))
        // Calculation Order… needs a form with two calculated fields (the synthetic text document has none): its sheet is
        // left to `PrepareFormTest` and a person.
    }

    mutating func wave4More(_ look: String, audits: Bool, _ send: Send) async {
        let c = controller
        await dialog([Step("scan-backs-\(look)")], audits: audits, wait: 1500, send(NSSelectorFromString("scanBacks:")))
        await dialog([Step("ask-folders-\(look)")], audits: audits, wait: 900) { FolderAskWindowController.show() }
        await dialog([Step("meaning-settings-\(look)")], audits: audits) { [weak c] in
            guard let window = c?.window else { return }
            Task { @MainActor in _ = await FolderMeaning.showSettings(on: window) }
        }
        await dialog([Step("ask-edit-\(look)")], audits: audits) { [weak c] in
            guard let window = c?.window else { return }
            Task { @MainActor in _ = await AskEditRequestSheet.ask(on: window) }
        }
        await dialog([Step("ask-edit-steps-\(look)")], audits: audits) { [weak c] in
            guard let window = c?.window else { return }
            let steps: [AskEditStep] = [AskEditStep(.goToPage, pages: [1]), AskEditStep(.rotatePages, pages: [0], degrees: 90),
                                        AskEditStep(.highlightText, text: "Inkvolt")]
            let plan = AskEditPlan(steps: steps, refused: [], said: nil)
            Task { @MainActor in _ = await AskEditStepsSheet.choose(on: window, plan) }
        }
        await dialog([Step("ai-summary-audio-not-set-up-\(look)")], audits: audits, send(NSSelectorFromString("aiSummaryToAudio:")))

        // The document window with View › Rulers on (4.19): the rulers' views among its controls.
        guard let window = c.window else { return }
        window.makeKeyAndOrderFront(nil)
        let rulers = NSSelectorFromString("toggleRulers:")
        let was = AppSettings.showRulers
        if !was { NSApp.sendAction(rulers, to: c, from: nil) }
        await settle()
        shoot(window, "doc-rulers-\(look)")
        if audits { audit(window, "document window with rulers") }
        if !was { NSApp.sendAction(rulers, to: c, from: nil) }
        await settle(200)
    }
}
