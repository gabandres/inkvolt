import AppKit
import PdfCore
import UniformTypeIdentifiers

/// File › Save as PDF/A-2b…, and Save as PDF/A-2a (the accessible archive: the tags kept, Make Accessible first when there
/// are none) (the Windows app's `PdfAActions`): an archival copy of the document as it is now (edits
/// included), made by `PdfA.convert` in the background; the open document doesn't change. A document opened without its
/// permissions password asks for it (the copy can't be encrypted). When something can't be made conforming without
/// changing the look, nothing is saved and the reasons are listed; else the copy is saved where the user chooses (never
/// over the open document) and a sheet says what was changed, with Open the Copy. PDF/A-2b is free and PDF/A-2a asks the Pro
/// check, as on Windows.
extension DocumentWindowController {
    @objc func saveAsPdfA(_ sender: Any?) {
        startLongTask { await self.saveAsPdfA() }
    }

    @objc func saveAsPdfA2a(_ sender: Any?) {
        startLongTask { await self.saveAsPdfA2a() }
    }

    /// Save as PDF/A-2a: the Pro check, and Make Accessible first when the document has no tags.
    @discardableResult
    func saveAsPdfA2a() async -> Bool {
        guard pdf.session != nil, proAllows(.accessibleOutput), await settleForTags(), let session = pdf.session else { return false }
        let data = session.data, password = session.password
        if !(await Task.detached { AutoTag.isTagged(data, password) }.value) {
            guard await AccessibleState.askTagFirst(window), await makeAccessible() else { return false }
        }
        return await saveAsPdfA(conformance: .a)
    }

    /// The whole command; false when nothing was saved (refused, cancelled, failed).
    @discardableResult
    func saveAsPdfA(conformance: PdfAConformance = .b) async -> Bool {
        guard pdf.session != nil else { return false }
        form.commitEditor()
        await form.settle()
        await content.settle()
        guard let session = pdf.session else { return false }
        let data = session.data, displayName = session.displayName
        guard let result = await makePdfACopy(data, session.password, name: displayName, conformance: conformance) else { return false }
        guard let url = await pickPdfACopyLocation(PdfA.copyName(displayName, conformance: conformance), folder: session.filePath.map { ($0 as NSString).deletingLastPathComponent }, conformance) else {
            return false
        }
        return await writePdfACopy(result, to: url, conformance: conformance)
    }

    /// The PDF/A copy of `data`, with the progress sheet; asks for the permissions password while it is needed. Nil when
    /// refused (the reasons shown), cancelled or failed.
    func makePdfACopy(_ data: [UInt8], _ password: String?, name: String, conformance: PdfAConformance = .b) async -> PdfAResult? {
        let sheet = ProgressSheet(title: "Save as \(conformance.name)", text: "Making a PDF/A copy…")
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        var password = password
        var wrong = false
        while true {
            let pw = password
            let outcome = await Task.detached { () -> Result<PdfAResult, Error> in Result { try PdfA.convert(data, pw, conformance: conformance) } }.value
            if sheet.cancelled { return nil }
            switch outcome {
            case .success(let result):
                return result
            case .failure(let e) where e is OwnerPasswordRequired || e is PasswordRequired && wrong:
                // Opened for viewing only: the copy is unencrypted, so its permissions password is needed. (A wrong one
                // given for a file that also has an open password doesn't even open it: asked again too.)
                sheet.end()
                let wrongGiven = (e as? OwnerPasswordRequired)?.wrongPassword ?? true
                guard let owner = await PdfAState.askOwnerPassword(self, name, wrong: wrong || wrongGiven && password != nil) else { return nil }
                sheet.begin(on: window)
                password = owner
                wrong = true
            case .failure(let e as PdfAError):
                Report.progress("PDF/A refused: \(e.blockers.count) reasons")
                sheet.end()
                await PdfAState.show(self, "Can't save as \(conformance.name)", PdfA.refusalMessage(e.blockers, conformance: conformance))
                return nil
            case .failure(let error):
                Report.progress("PDF/A failed: \(type(of: error))")
                let message = (error as? PdfEditError)?.message ?? "\(error)"
                sheet.end()
                await PdfAState.show(self, "Can't save as \(conformance.name)", message, isError: true)
                return nil
            }
        }
    }

    /// Where the copy goes (the save panel, next to the document); the self-test's own file while it runs.
    private func pickPdfACopyLocation(_ name: String, folder: String?, _ conformance: PdfAConformance) async -> URL? {
        if Report.isRunning { return PdfAState.testTarget }
        guard let window else { return nil }
        let panel = NSSavePanel()
        panel.title = "Save as \(conformance.name)"
        panel.prompt = "Save Copy"
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.pdf]
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        return await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            panel.beginSheetModal(for: window) { response in done.resume(returning: response == .OK ? panel.url : nil) }
        }
    }

    /// Saves the copy at `url` (never over the open document) and says what was changed; true when saved.
    func writePdfACopy(_ result: PdfAResult, to url: URL, conformance: PdfAConformance = .b) async -> Bool {
        if let open = pdf.session?.filePath, URL(fileURLWithPath: open).standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
            await PdfAState.show(self, "Choose another name", "The PDF/A copy can't replace the open document. Choose another name or folder.")
            return false
        }
        let bytes = Data(result.data)
        let written = await Task.detached { () -> Result<Void, Error> in Result { try bytes.write(to: url, options: .atomic) } }.value
        if case .failure(let error) = written {
            await PdfAState.show(self, "Can't save the PDF/A copy",
                           "\(error.localizedDescription)\n\nIf the file is open in another program, close it there or choose another name.", isError: true)
            return false
        }
        Report.progress("PDF/A saved: \(result.changes.count) changes")
        let open = await PdfAState.show(self, "Saved as \(conformance.name)", PdfA.savedMessage(url.lastPathComponent, result.changes, conformance: conformance), openButton: true)
        if open { NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
        return true
    }
}

/// What the Save as PDF/A sheets said last (the self-test reads it, as the sheets aren't shown while it runs) and where
/// the self-test's copy goes.
@MainActor
enum PdfAState {
    static var testTarget: URL?
    /// The self-test's answers to the permissions password question, in turn (none left: cancelled), and the questions
    /// asked.
    static var testOwnerPasswords: [String] = []
    private(set) static var ownerPasswordQuestions: [String] = []
    private(set) static var lastTitle = ""
    private(set) static var lastMessage = ""

    /// A sheet on the window with `message` in a scrolling, selectable box (a refusal can list many fonts); true when
    /// Open the Copy was chosen.
    @discardableResult
    static func show(_ controller: DocumentWindowController, _ title: String, _ message: String, isError: Bool = false, openButton: Bool = false) async -> Bool {
        lastTitle = title
        lastMessage = message
        if Report.isRunning { return false }
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = isError ? .critical : .informational
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 10))
        text.string = message
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 100
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: min(max(used + 12, 40), 300)))
        scroll.documentView = text
        scroll.hasVerticalScroller = used + 12 > 300
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        text.frame.size.height = max(used + 8, scroll.frame.height)
        text.setAccessibilityLabel(title)
        alert.accessoryView = scroll
        if openButton {
            alert.addButton(withTitle: "Open the Copy")
            alert.addButton(withTitle: "Done")
        } else {
            alert.addButton(withTitle: "OK")
        }
        return await run(alert, on: controller.window) && openButton
    }

    /// The alert as a sheet on `window` (app-modal without one); true for its first button.
    private static func run(_ alert: NSAlert, on window: NSWindow?) async -> Bool {
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// The permissions password, asked for the copy (nil: cancelled).
    static func askOwnerPassword(_ controller: DocumentWindowController, _ name: String, wrong: Bool) async -> String? {
        let question = wrong ? "That password is incorrect. Try again." : "Permissions password required"
        if Report.isRunning {
            ownerPasswordQuestions.append(question)
            return testOwnerPasswords.isEmpty ? nil : testOwnerPasswords.removeFirst()
        }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "A PDF/A copy can't be password protected, so making one of “\(name)” needs its permissions (owner) password."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await run(alert, on: controller.window) ? field.stringValue : nil
    }
}
