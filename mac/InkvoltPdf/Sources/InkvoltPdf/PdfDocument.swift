import AppKit
import PdfCore
import PrintCore

/// One open PDF: a `DocumentSession` (its bytes, the MuPDF engine over them, undo and redo of edits). Open, Open
/// Recent, Finder's Open With, window tabs, Save, Save As, Revert and the questions on close and quit come from
/// NSDocument; the bytes and their saving are the session's (an edit to a signed file is appended by the core, so Save
/// keeps its signatures). The session is opened when the window is made, after asking for the password if the file needs
/// one; a recovered document arrives with its session made.
@objc(PdfDocument)
final class PdfDocument: NSDocument {
    // Set by read(from:ofType:), which AppKit calls on the main thread (no concurrent reading) before any window.
    nonisolated(unsafe) private var openURL: URL?
    private(set) var session: DocumentSession?
    /// A recovered document's session, until its window is made.
    private var pending: DocumentSession?
    /// The page a recovered document shows first.
    var startPage = 0
    /// Names this document's recovery copy.
    let recoveryId = UUID().uuidString
    /// Edit › Undo and Redo: the session's steps, through the window's undo manager.
    private(set) lazy var undoBridge = SessionUndoManager(document: self)
    /// Called after the content changed (edit, undo, redo, reload): the session's engine is the new one.
    var onContentChanged: ((ContentChange) -> Void)?

    override init() {
        super.init()
        hasUndoManager = false
    }

    /// A document offered back after Inkvolt PDF closed without saving it: Save writes it to the file it came from.
    convenience init(recovered session: DocumentSession, page: Int, fileDate: Date?) {
        self.init()
        pending = session
        startPage = page
        fileType = "com.adobe.pdf"
        if let path = session.filePath, FileManager.default.fileExists(atPath: path) {
            fileURL = URL(fileURLWithPath: path)
            fileModificationDate = fileDate
        }
    }

    var engine: PdfEngine? { session?.engine }
    /// The document's bytes as they are now.
    var fileBytes: [UInt8] { session?.data ?? [] }

    override class var autosavesInPlace: Bool { false }

    /// The name shown for the document.
    var name: String { session?.displayName ?? displayName ?? loc("This document") }

    override var displayName: String! {
        get {
            if fileURL == nil, let s = session ?? pending { return s.displayName }
            return super.displayName
        }
        set { super.displayName = newValue }
    }

    override func read(from url: URL, ofType typeName: String) throws {
        openURL = url
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let session else { throw CocoaError(.fileWriteUnknown) }
        return Data(session.data)
    }

    override func makeWindowControllers() {
        guard let session = pending ?? openSession() else {
            // Cancelled or unreadable: the document goes away once AppKit has finished opening it.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.close() } }
            return
        }
        pending = nil
        if session.engine.pageCount == 0 {
            session.close()
            fail(NoPages())
            DispatchQueue.main.async { MainActor.assumeIsolated { self.close() } }
            return
        }
        attach(session)
        addWindowController(DocumentWindowController(document: self))
        if session.isDirty { stateChanged() }
    }

    private func attach(_ session: DocumentSession) {
        self.session = session
        // The session calls these from the worker an edit commits on, or from here for undo, redo and reload.
        session.contentChanged = { @Sendable [weak self] change in
            let document = self
            onMain { document?.onContentChanged?(change) }
        }
        session.stateChanged = { @Sendable [weak self] in
            let document = self
            onMain { document?.stateChanged() }
        }
    }

    /// The window's edited dot, the close and quit questions, and the recovery copy follow the session's dirty state.
    private func stateChanged() {
        guard let session else { return }
        updateChangeCount(session.isDirty ? .changeDone : .changeCleared)
        RecoveryCopies.shared.changed(self)
    }

    override func close() {
        RecoveryCopies.shared.closed(self)
        super.close()
        session?.close()
        StartWindowController.documentClosed()
    }

    // MARK: Closing with unsaved changes

    /// The self-test's answer to the "Save changes?" question (nil: AppKit asks the user, as it always does).
    enum CloseAnswer { case save, dontSave, cancel }
    var testCloseAnswer: CloseAnswer?
    /// How often the question was answered from `testCloseAnswer`.
    private(set) var closeQuestions = 0

    /// Closing a window (or tab) or quitting with unsaved changes: AppKit's question (Save, Don't Save, Cancel; quitting
    /// with several such documents first offers to review them, then asks this for each). The self-test answers it from
    /// `testCloseAnswer` through the same callback AppKit's sheet uses.
    /// An arrow-key move in Prepare Form or Edit Text & Images still waiting for the keys to rest is written first (⌘W
    /// within 0.45 s would lose it), so the question sees it and Save writes it.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let waiting = MainActor.assumeIsolated { () -> (PrepareForm?, ContentEditing?)? in
            let c = windowControllers.first as? DocumentWindowController
            let design = c?.madeDesign.flatMap { $0.hasPendingNudge ? $0 : nil }
            let content = c?.content.flatMap { $0.hasPendingNudge ? $0 : nil }
            if design == nil && content == nil { return nil }
            design?.flushNudge()
            content?.flushNudge()
            return (design, content)
        }
        guard let waiting else { return decideClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo) }
        nonisolated(unsafe) let target = delegate
        nonisolated(unsafe) let info = contextInfo
        Task { @MainActor in
            await waiting.0?.settle()
            await waiting.1?.settle()
            self.decideClose(withDelegate: target, shouldClose: shouldCloseSelector, contextInfo: info)
        }
    }

    private func decideClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let answer = testCloseAnswer, isDocumentEdited else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        closeQuestions += 1
        let reply: (Bool) -> Void = { ok in
            guard let selector = shouldCloseSelector, let target = delegate as? NSObject else { return }
            typealias Callback = @convention(c) (NSObject, Selector, NSDocument, ObjCBool, UnsafeMutableRawPointer?) -> Void
            let call = unsafeBitCast(target.method(for: selector), to: Callback.self)
            call(target, selector, self, ObjCBool(ok), contextInfo)
        }
        switch answer {
        case .cancel:
            reply(false)
        case .dontSave:
            reply(true)
        case .save:
            guard let url = fileURL else { return reply(false) }
            save(to: url, ofType: fileType ?? "com.adobe.pdf", for: .saveOperation) { error in reply(error == nil) }
        }
    }

    // MARK: Printing

    /// Every print request (File › Print…, a form's print action, Finder's Print): the print copy is made first, off the
    /// main thread (`preparePrint`, with a sheet and Cancel when it takes a while), then the panel opens as NSDocument
    /// does it; Cancel prints nothing.
    override func print(withSettings printSettings: [NSPrintInfo.AttributeKey: Any], showPrintPanel: Bool, delegate: Any?,
                        didPrint didPrintSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let controller = MainActor.assumeIsolated { windowControllers.first as? DocumentWindowController }
        guard let controller else {
            return super.print(withSettings: printSettings, showPrintPanel: showPrintPanel, delegate: delegate,
                               didPrint: didPrintSelector, contextInfo: contextInfo)
        }
        nonisolated(unsafe) let settings = printSettings
        nonisolated(unsafe) let target = delegate
        nonisolated(unsafe) let info = contextInfo
        Task { @MainActor in
            guard await controller.preparePrint() else { return }
            self.printPrepared(settings, showPrintPanel, target, didPrintSelector, info)
        }
    }

    private func printPrepared(_ settings: [NSPrintInfo.AttributeKey: Any], _ showPanel: Bool, _ delegate: Any?,
                               _ didPrint: Selector?, _ contextInfo: UnsafeMutableRawPointer?) {
        super.print(withSettings: settings, showPrintPanel: showPanel, delegate: delegate, didPrint: didPrint, contextInfo: contextInfo)
    }

    /// The window's print operation (its pages through the core's print layout), on paper from the copy `print` made.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        try MainActor.assumeIsolated {
            guard let controller = windowControllers.first as? DocumentWindowController else { throw CocoaError(.featureUnsupported) }
            let info = printInfo.copy() as! NSPrintInfo
            for (key, value) in printSettings { info.dictionary().setObject(value, forKey: key.rawValue as NSString) }
            return controller.printOperation(info, copy: controller.takePreparedPrint(controller.layerEngine ?? controller.engine))
        }
    }

    // MARK: Undo and redo

    func undo() {
        guard let session, session.canUndo, !session.isEditing else { return }
        do { try session.undo() } catch { showError(loc("That couldn't be undone."), error) }
    }

    func redo() {
        guard let session, session.canRedo, !session.isEditing else { return }
        do { try session.redo() } catch { showError(loc("That couldn't be redone."), error) }
    }

    // MARK: Saving

    /// Save, Save As and Save To write the session's bytes (atomically, keeping the file's creation date); NSDocument
    /// then records the new file and clears the edited dot.
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        try MainActor.assumeIsolated { try self.write(url, saveOperation) }
    }

    private func write(_ url: URL, _ operation: NSDocument.SaveOperationType) throws {
        guard let session else { throw CocoaError(.fileWriteUnknown) }
        do {
            if operation == .saveToOperation {
                try Data(session.data).write(to: url, options: .atomic) // a copy: the document stays as it is
            } else {
                try session.saveAs(url.path)
            }
        } catch let e as PdfEditError {
            throw NSError(domain: "InkvoltPdf", code: 1, userInfo: [NSLocalizedDescriptionKey: e.message]) // English: a domain name; the message is PdfCore's (loc)
        }
        if operation != .saveToOperation { RecoveryCopies.shared.changed(self) }
    }

    /// Revert to Saved: the file read again (the session's reload), undo history dropped.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            guard let session else { return }
            do {
                try session.reloadFromDisk()
            } catch is PasswordRequired {
                throw NSError(domain: "InkvoltPdf", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    loc("The file on disk now needs another password. Use the bar over the pages to reload it.")])
            }
            self.syncFileDate()
        }
    }

    /// After a reload or a save: NSDocument's idea of the file's date matches the file again.
    func syncFileDate() {
        guard let path = session?.filePath else { return }
        fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: Opening

    /// The session over the file: with the report's password, else the user's, asked again after a wrong one.
    private func openSession() -> DocumentSession? {
        guard let url = openURL else { return nil }
        do {
            return try DocumentSession.open(url.path, password: Report.password)
        } catch is PasswordRequired {
        } catch {
            fail(error)
            return nil
        }
        var wrong = false
        while let password = PasswordPrompt.ask(file: url.lastPathComponent, wrong: wrong) {
            do {
                return try DocumentSession.open(url.path, password: password)
            } catch is PasswordRequired {
                wrong = true
            } catch {
                fail(error)
                return nil
            }
        }
        return nil
    }

    private func fail(_ error: Error) {
        let shown = openURL?.lastPathComponent ?? name
        Report.failed(shown, error)
        let alert = NSAlert()
        alert.messageText = loc("{0} couldn't be opened.", shown)
        alert.informativeText = NSAlert.plainText(error)
        if !Report.skipsDialogs { alert.runModal() }
    }

    func showError(_ message: String, _ error: Error?) {
        Report.note("ERROR \(message) \(error.map { "\(type(of: $0)): \($0)" } ?? "")")
        if Report.skipsDialogs { return }
        let alert = NSAlert()
        alert.messageText = message
        if let error { alert.informativeText = NSAlert.plainText(error) }
        if let window = windowControllers.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Runs `f` on the main thread: now when already there, else as soon as it is free.
nonisolated func onMain(_ f: @escaping @Sendable @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { f() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
    }
}

/// Edit › Undo and Redo for a document window: AppKit asks the window's undo manager whether it can undo and what to call
/// the step ("Undo Highlight"); this one answers from the document's session, whose steps are byte snapshots.
final class SessionUndoManager: UndoManager {
    private weak var document: PdfDocument?

    init(document: PdfDocument) {
        self.document = document
        super.init()
        groupsByEvent = false
    }

    private func session() -> DocumentSession? {
        MainActor.assumeIsolated { document?.session }
    }

    override var canUndo: Bool { session().map { $0.canUndo && !$0.isEditing } ?? false }
    override var canRedo: Bool { session().map { $0.canRedo && !$0.isEditing } ?? false }
    override var undoActionName: String { session()?.undoLabel ?? "" }
    override var redoActionName: String { session()?.redoLabel ?? "" }
    override func undo() { MainActor.assumeIsolated { document?.undo() } }
    override func redo() { MainActor.assumeIsolated { document?.redo() } }
}

/// Asks for a document's open password.
@MainActor
enum PasswordPrompt {
    static func ask(file: String, wrong: Bool) -> String? {
        if Report.skipsDialogs { return nil }
        let alert = NSAlert()
        alert.messageText = wrong ? loc("That password doesn't open {0}.", file) : loc("{0} is protected with a password.", file)
        alert.informativeText = loc("Type its password to open it.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.setAccessibleName(loc("Password"))
        alert.accessoryView = field
        alert.addButton(withTitle: loc("Open"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// A file that opened (MuPDF repaired it) with no page to show.
struct NoPages: Error, CustomStringConvertible {
    var description: String { loc("The file is damaged: no page of it could be read.") }
}
