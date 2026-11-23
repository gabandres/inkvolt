import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// Where Save AI Answer puts the answers (Windows' `AiSaveTarget` without its spoken recording, roadmap 4.24, not on the
/// Mac yet).
enum AiSaveTarget { case word, pdf, comment }

/// Save an AI answer (roadmap 4.20, the Windows `DocumentTab.AiSave`): an answer (its card's Save button, or the last one)
/// or the whole conversation (the pane's Save, or the menu) to a Word document or a PDF, or one answer into the document as
/// a comment on the page it cites (one undo step). PdfCore writes them (`AiAnswerExport`); the conversation is the
/// session's (`DocumentSession.aiConversation`), kept while the document is open.
extension DocumentWindowController {
    var hasAiAnswers: Bool { !(pdf.session?.aiConversation.exchanges.isEmpty ?? true) }

    /// The last answer, for Save AI Answer from the menu.
    var lastAiAnswer: AiExchange? { pdf.session?.aiConversation.exchanges.last }

    /// Tools › AI Assistant › Save AI Answer…: the last answer.
    @objc func saveAiAnswerCommand(_ sender: Any?) {
        guard let last = lastAiAnswer else { return notify(loc("No AI answer to save yet: ask, summarize or explain first.")) }
        saveAiAnswer(last)
    }

    /// Tools › AI Assistant › Save AI Conversation… and the pane's Save: every answer.
    @objc func saveAiConversation(_ sender: Any?) {
        ai.job = Task { @MainActor in _ = await saveAiAnswers(nil) }
    }

    /// One answer (its card's Save).
    func saveAiAnswer(_ exchange: AiExchange) {
        ai.job = Task { @MainActor in _ = await saveAiAnswers([exchange]) }
    }

    /// Saves `chosen` (nil: the whole conversation), asking where unless `target` (and, for a file, `url`) are given.
    /// Returns whether it was saved.
    @discardableResult
    func saveAiAnswers(_ chosen: [AiExchange]?, target given: AiSaveTarget? = nil, url given2: URL? = nil) async -> Bool {
        guard let window, let session = pdf.session else { return false }
        let list = chosen ?? session.aiConversation.exchanges
        if list.isEmpty {
            notify(loc("No AI answer to save yet: ask, summarize or explain first."))
            return false
        }
        let one = chosen != nil && list.count == 1 // named by what was asked: the conversation, even of one answer, is a conversation
        let pageCount = engine.pageCount
        let canComment = one && pageCount > 0
        let commentPage = canComment ? AiAnswerExport.commentPage(list[0], pageCount, current: pages.currentPage) : 0
        let title = one ? loc("Save AI answer") : loc("Save AI conversation")
        var target = given
        if target == nil {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = one ? loc("The answer to “{0}”.", AiProtocol.shorten(list[0].shown.replacingOccurrences(of: "\n", with: " "), 80))
                : list.count == 1 ? loc("{0} answer, with what was asked.", CoreLanguage.number(1))
                : loc("{0} answers, each with what was asked.", CoreLanguage.number(list.count))
            var choices: [(AiSaveTarget, String)] = [(.word, loc("A Word document (.docx)")), (.pdf, loc("A PDF"))]
            if canComment { choices.append((.comment, loc("A comment on page {0} of this document", CoreLanguage.number(commentPage + 1)))) }
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: choices.map(\.1))
            popup.setAccessibilityLabel(loc("Save as"))
            let form = SheetForm("SaveAiAnswer")
            form.row(loc("Save as"), popup)
            form.note(loc("It says it was written by an AI model, and which one; it may be wrong. A comment goes on the first page the answer cites."))
            form.install(in: alert)
            alert.addButton(withTitle: loc("Save"))
            alert.addButton(withTitle: loc("Cancel"))
            ai.saveAlert = (alert, popup)
            defer { ai.saveAlert = nil }
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return false }
            target = choices[max(popup.indexOfSelectedItem, 0)].0
        }

        if target == .comment {
            guard canComment else { return false }
            let e = list[0]
            // At the top right of the page, clear of most text; the note's icon is 20 pt.
            let x = max(0, engine.page(commentPage).width - 44), y = 16.0
            let author = editor.author, text = AiAnswerExport.commentText(e), page = commentPage
            let ok = await editor.run(loc("Add AI answer as comment"), contentOnly: true) { d, pw in
                try Annotations.addNote(d, pw, page, x, y, text, author: author, color: AnnotColor(0.55, 0.75, 1))
            }
            if ok {
                go(page)
                notify(loc("The answer is now a comment on page {0}.", CoreLanguage.number(page + 1)), canUndo: true)
            }
            return ok
        }

        let word = target == .word
        var url = given2
        if url == nil {
            let panel = NSSavePanel()
            panel.title = title
            panel.nameFieldStringValue = loc("{0} - AI answers", (session.displayName as NSString).deletingPathExtension) + (word ? ".docx" : ".pdf")
            panel.allowedContentTypes = [word ? (UTType(filenameExtension: "docx") ?? .data) : .pdf]
            if let path = session.filePath { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
            guard await panel.beginSheetModal(for: window) == .OK, let picked = panel.url else { return false }
            url = picked
        }
        guard let url else { return false }
        // Never over a PDF open in a window (this one included): its window reads that file.
        let file = url.standardizedFileURL
        if NSDocumentController.shared.documents.contains(where: { $0.fileURL?.standardizedFileURL == file }) {
            inform(title, loc("{0} is open in Inkvolt PDF. Close it first, or save under another name.", url.lastPathComponent))
            return false
        }
        let documentName = session.displayName
        let made = await Task.detached { () -> Result<Void, Error> in
            Result {
                let bytes = word ? try AiAnswerExport.toDocx(list, documentName) : try AiAnswerExport.toPdf(list, documentName)
                try Data(bytes).write(to: url, options: .atomic)
            }
        }.value
        if case .failure = made {
            inform(loc("Not saved"), loc("The file couldn't be written. Check that the folder exists and the file isn't open in another app, then try again."))
            return false
        }
        if word {
            notify(loc("Saved {0}.", url.lastPathComponent))
        } else if !Report.isRunning {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        return true
    }
}
