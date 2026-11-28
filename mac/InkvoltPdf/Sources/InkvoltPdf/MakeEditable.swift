import AppKit
import PdfCore
import PrintCore

/// Tools › Make Text Editable… and Scan & OCR on the bar (roadmap 2.2, for 2.1; Windows' `DocumentTab.MakeTextEditable`):
/// the recognized text of the chosen pages becomes real text in the installed font closest to the scan's, at its size and
/// place (`EditableText`), the scan covered behind it unless the person keeps it showing; one undo step. With no recognized
/// text, offers Recognize Text.
extension DocumentWindowController {
    @objc func makeTextEditable(_ sender: Any?) {
        guard pdf.session != nil, window != nil else { return NSSound.beep() }
        startLongTask { await self.runMakeEditable() }
    }

    /// Asks which pages and whether to keep the scan showing, then makes the text editable; what it did comes back (nil:
    /// not started).
    @discardableResult
    func runMakeEditable(answer: (pages: [Int], keepScan: Bool)? = nil) async -> EditableTextResult? {
        guard let session = pdf.session, let window else { return nil }
        let data = session.data, password = session.password
        let read: Result<[Int], Error> = await Task.detached { Result { try EditableText.pages(data, password) } }.value
        let recognized: [Int]
        switch read {
        case .success(let pages): recognized = pages
        case .failure(let error):
            // A layer that can't be read counts as none (Windows logs it the same way).
            Report.progress("Make Text Editable couldn't read the text layers: \(type(of: error))")
            recognized = []
        }
        if recognized.isEmpty {
            let alert = NSAlert()
            alert.messageText = loc("No recognized text")
            alert.informativeText = loc("These pages have no text from Recognize Text to make editable. Recognize their text first.")
            alert.addButton(withTitle: loc("Recognize Text"))
            alert.addButton(withTitle: loc("Cancel"))
            if answer == nil, await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.recognizeText(nil) } }
            }
            return nil
        }

        var chosen: [Int]
        var keepScan: Bool
        if let answer {
            (chosen, keepScan) = answer
        } else {
            let alert = NSAlert()
            alert.messageText = loc("Make Text Editable")
            alert.informativeText = loc("The words Recognize Text found become real text, in the installed font closest to the scan's, at their size and place, so Edit Text & Images can change them. Check the suspect words first: they can't be reviewed afterwards. Undo puts the pages back.")
            let choice = pageChoice(allTitle: loc("All pages with recognized text"))
            let keep = NSButton(checkboxWithTitle: loc("Keep the scan showing behind the text"), target: nil, action: nil)
            keep.state = AppSettings.editableKeepScan ? .on : .off
            keep.toolTip = loc("Off: the scan is covered behind each line, in the paper's colour, so only the new text shows there. On: the scan stays as it is and the text is drawn over it.")
            let form = SheetForm("MakeTextEditable")
            form.row(loc("Pages"), choice.view)
            form.row(nil, keep)
            form.install(in: alert)
            alert.addButton(withTitle: loc("Make Editable"))
            alert.addButton(withTitle: loc("Cancel"))
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
            let read = choice.read()
            guard let pages = read.pages, !pages.isEmpty else {
                pdf.showError(read.error ?? loc("No pages chosen."), nil)
                return nil
            }
            AppSettings.editableKeepScan = keep.state == .on
            (chosen, keepScan) = (pages, keep.state == .on)
            // "All pages": the ones with recognized text (the others would be left as they are anyway).
            if chosen.count == engine.pageCount { chosen = recognized }
        }

        let sheet = ProgressSheet(title: loc("Making text editable"), text: loc("Starting…"))
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let token = sheet.token
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain {
                guard done < total else { return }
                sheet.update(loc("{0}: page {1} of {2}…", loc("Making text editable"), CoreLanguage.number(done + 1), CoreLanguage.number(total)),
                             Double(done) / Double(max(total, 1)))
            }
        }
        let box = EditBox<EditableTextResult>()
        let pages = chosen, keep = keepScan
        await editor.run(loc("Make text editable")) { d, pw in
            let made = try EditableText.make(d, pw, pages: pages, keepScan: keep, cancel: token, progress: progress)
            box.value = made
            return made.data
        }
        switch editor.lastOutcome {
        case .done? where (box.value?.pages ?? 0) > 0:
            let made = box.value!
            let words = made.words == 1 ? loc("{0} word", CoreLanguage.number(made.words)) : loc("{0} words", CoreLanguage.number(made.words))
            let onPages = made.pages == 1 ? loc("{0} page", CoreLanguage.number(made.pages)) : loc("{0} pages", CoreLanguage.number(made.pages))
            notify(loc("Made {0} on {1} editable, in {2}. Click a paragraph with Edit Text & Images to change it.", words, onPages,
                       made.fonts.joined(separator: ", ")),
                   // Windows' Edit Text button: Edit Text & Images, to click a paragraph (unless it is on already).
                   links: [(loc("Edit Text"), { [weak self] in
                       guard let self, self.pages.tool != .editContent else { return }
                       self.choose(.editContent)
                   })])
        case .done?, .noChange?:
            let alert = NSAlert()
            alert.messageText = loc("No recognized text")
            alert.informativeText = loc("These pages have no text from Recognize Text to make editable. Recognize their text first.")
            if answer == nil { _ = await alert.beginSheetModal(for: window) }
        default:
            break
        }
        return box.value
    }
}
