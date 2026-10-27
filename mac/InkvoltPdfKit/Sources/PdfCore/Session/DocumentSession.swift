import Foundation

/// Why the document's content changed.
public enum ContentChange: Equatable, Sendable {
    case edit
    /// An edit that leaves the pages as they were (form values, Fill & Sign): an open field editor can stay.
    case contentOnlyEdit
    case undo
    case redo
    case reload

    public var contentOnly: Bool { self == .contentOnlyEdit }
    /// Undo or redo: the same page positions may now hold different pages.
    public var steppedHistory: Bool { self == .undo || self == .redo }
}

/// A file's size and last-write time, to notice another program changing it.
public struct DiskStamp: Equatable, Sendable {
    public var length: Int64
    public var writeTime: Date

    public init(length: Int64, writeTime: Date) {
        self.length = length
        self.writeTime = writeTime
    }

    static func of(_ path: String) -> DiskStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (a[.size] as? NSNumber)?.int64Value, let time = a[.modificationDate] as? Date else { return nil }
        return DiskStamp(length: size, writeTime: time)
    }
}

/// An open document (the Windows app's `DocumentSession`): its bytes, the MuPDF view of them, and undo/redo snapshots of
/// edits. The file on disk is read once and never locked; it changes only on Save. Edits go through `edit` (the edit
/// transaction). Used from one place at a time (the app's main actor); `edit` runs the edit itself on a worker.
public final class DocumentSession: @unchecked Sendable {
    private static let maxUndoSteps = 50
    private static let maxUndoBytes = 768 << 20

    /// An undo/redo state: its bytes and the passwords that open them; `id` names the edit through undo and redo.
    private struct Step {
        var data: [UInt8]
        var label: String
        var version: Int
        var password: String?
        var openPassword: String?
        var id: Int
    }

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    private var version = 0
    private var savedVersion = 0
    private var nextVersion = 1
    private var lastStepId = 0
    private var closed = false
    private var onDisk: DiskStamp?
    private var diskPassword: String? // what opens the file on disk: the session's own may differ after a protection change
    private var encryptionScan: (version: Int, found: Bool)?
    private let editGate = NSLock()
    private var editing = false

    public private(set) var filePath: String?
    public private(set) var displayName: String
    public private(set) var data: [UInt8]
    /// The password the document was opened with; replaced by the permissions password once the user gives it for an edit.
    public private(set) var password: String?
    /// The document's open (user) password when known.
    public private(set) var openPassword: String?
    public private(set) var engine: PdfEngine
    /// True when the content differs from what is on disk (undoing back to the saved state clears it).
    public var isDirty: Bool { version != savedVersion }

    /// Called after the content changed (edit, undo, redo, reload); the engine has been replaced.
    public var contentChanged: ((ContentChange) -> Void)?
    /// Called when the name, path or dirty state changed.
    public var stateChanged: (() -> Void)?

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public var undoLabel: String? { undoSteps.last?.label }
    public var redoLabel: String? { redoSteps.last?.label }
    /// The edit `undo()` would take back (an `EditResult.stepId`), or nil.
    public var undoStepId: Int? { undoSteps.last?.id }
    /// The file's size and time when it was opened or last saved (nil for a document never saved).
    public var diskStampWhenRead: DiskStamp? { onDisk }

    /// True when the PDF has an encryption dictionary: it needs a password to open, or only restricts printing, copying
    /// or editing (`PdfEngine.isEncrypted` is true in both cases on the Mac). A byte scan, once per content.
    public var hasEncryption: Bool {
        if let scan = encryptionScan, scan.version == version { return scan.found }
        let found = data.firstRange(of: Array("/Encrypt".utf8)) != nil
        encryptionScan = (version, found)
        return found
    }

    private init(path: String?, displayName: String, data: [UInt8], password: String?, engine: PdfEngine) {
        filePath = path
        self.displayName = displayName
        self.data = data
        self.password = password
        self.engine = engine
    }

    /// - Throws: `PasswordRequired`.
    public static func open(_ path: String, password: String? = nil) throws -> DocumentSession {
        // Stamp before reading: a write that lands mid-read then shows up as a change rather than going unnoticed.
        let stamp = DiskStamp.of(path)
        let data = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        let engine = try PdfEngine.open(data, password: password)
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        let session = DocumentSession(path: full, displayName: (full as NSString).lastPathComponent, data: data, password: password, engine: engine)
        session.onDisk = stamp
        session.openPassword = PdfSecurity.isOpenPassword(data, password) ? password : nil
        session.diskPassword = password
        return session
    }

    /// A new, unsaved PDF (e.g. the result of Combine or Extract).
    public static func fromBytes(_ data: [UInt8], _ displayName: String, password: String? = nil) throws -> DocumentSession {
        let session = DocumentSession(path: nil, displayName: displayName, data: data, password: password,
                                      engine: try PdfEngine.open(data, password: password))
        session.savedVersion = -1 // never saved
        return session
    }

    /// A document offered back after Inkvolt PDF closed without saving it (`RecoveryStore`): its bytes as they were, under
    /// the file it came from (nil for one never saved), so Save writes it back there. `diskStamp`: that file's size and
    /// time when the copy was made, so a file changed since shows as changed on disk.
    public static func recover(_ data: [UInt8], originalPath: String?, _ displayName: String, diskStamp: DiskStamp? = nil,
                               password: String? = nil) throws -> DocumentSession {
        let engine = try PdfEngine.open(data, password: password)
        let path = originalPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let session = DocumentSession(path: path, displayName: displayName, data: data, password: password, engine: engine)
        session.openPassword = PdfSecurity.isOpenPassword(data, password) ? password : nil
        session.diskPassword = password
        session.onDisk = path.flatMap { diskStamp ?? DiskStamp.of($0) }
        session.savedVersion = -1 // unsaved changes
        return session
    }

    /// Uses the permissions (owner) password for edits from now on (after `OwnerPasswordRequired`). A different password
    /// that opened the document but couldn't edit it was its open (user) password.
    public func usePassword(_ newPassword: String) {
        if let current = password, !current.isEmpty, current != newPassword, openPassword == nil { openPassword = current }
        password = newPassword
    }

    /// Remembers the document's open password.
    public func useOpenPassword(_ newOpenPassword: String?) { openPassword = newOpenPassword }

    /// Replaces the content with edited bytes, recording an undo step.
    public func commit(_ newData: [UInt8], _ label: String) throws { try commit(newData, label, password: password, openPassword: openPassword) }

    /// Replaces the content with edited bytes that open with other passwords (the protection changed), recording an undo
    /// step: undoing it goes back to the old bytes and passwords.
    public func commit(_ newData: [UInt8], _ label: String, password newPassword: String?, openPassword newOpen: String?) throws {
        _ = try commit(newData, label, newPassword, newOpen, .edit)
    }

    /// The new undo step's id.
    func commit(_ newData: [UInt8], _ label: String, _ newPassword: String?, _ newOpen: String?, _ change: ContentChange) throws -> Int {
        let newEngine = try PdfEngine.open(newData, password: newPassword)
        lastStepId += 1
        undoSteps.append(Step(data: data, label: label, version: version, password: password, openPassword: openPassword, id: lastStepId))
        trimUndo()
        redoSteps.removeAll()
        (password, openPassword) = (newPassword, newOpen)
        swap(newData, newEngine, nextVersion, change)
        nextVersion += 1
        return lastStepId
    }

    public func undo() throws {
        guard let step = undoSteps.last else { return }
        let newEngine = try PdfEngine.open(step.data, password: step.password)
        undoSteps.removeLast()
        redoSteps.append(Step(data: data, label: step.label, version: version, password: password, openPassword: openPassword, id: step.id))
        (password, openPassword) = (step.password, step.openPassword)
        swap(step.data, newEngine, step.version, .undo)
    }

    public func redo() throws {
        guard let step = redoSteps.last else { return }
        let newEngine = try PdfEngine.open(step.data, password: step.password)
        redoSteps.removeLast()
        undoSteps.append(Step(data: data, label: step.label, version: version, password: password, openPassword: openPassword, id: step.id))
        (password, openPassword) = (step.password, step.openPassword)
        swap(step.data, newEngine, step.version, .redo)
    }

    /// Writes the current bytes to `path` atomically: a temporary file in the same folder, then swapped in (the target
    /// keeps its creation date and permissions).
    /// - Throws: `PdfEditError` saying the target "is read-only".
    public func saveAs(_ path: String) throws {
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        try Self.writeFile(full, data)
        markSaved(full, version, password)
    }

    /// `saveAs` with the writing on a worker: the bytes as they are now are written; an edit committed meanwhile leaves the
    /// document dirty.
    public func saveAsAsync(_ path: String) async throws {
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        let (bytes, savingVersion, savingPassword) = (data, version, password)
        try await Task.detached { try Self.writeFile(full, bytes) }.value
        markSaved(full, savingVersion, savingPassword)
    }

    private func markSaved(_ path: String, _ savedAt: Int, _ savedPassword: String?) {
        filePath = path
        diskPassword = savedPassword
        displayName = (path as NSString).lastPathComponent
        savedVersion = savedAt
        onDisk = DiskStamp.of(path)
        stateChanged?()
    }

    static func writeFile(_ path: String, _ bytes: [UInt8]) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: path)
        let name = target.lastPathComponent
        if fm.fileExists(atPath: path) && !fm.isWritableFile(atPath: path) {
            throw PdfEditError("\"\(name)\" is read-only. Save a copy under another name, or make it writable in its Get Info window.")
        }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw PdfEditError("\"\(name)\" can't be saved in that folder.")
        }
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if fm.fileExists(atPath: path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
    }

    /// True when the file is missing or its size or last-write time differ from when it was opened or last saved.
    public func hasChangedOnDisk() -> Bool {
        guard let filePath else { return false }
        guard let now = DiskStamp.of(filePath) else { return true }
        return onDisk.map { $0 != now } ?? false
    }

    /// True when the document came from a file that no longer exists (moved, renamed or deleted).
    public func isMissingOnDisk() -> Bool { filePath.map { !FileManager.default.fileExists(atPath: $0) } ?? false }

    /// Re-reads the file with the password that opened or saved it, discarding unsaved changes and undo history. On
    /// failure (I/O, password, corrupt file) nothing changes.
    /// - Throws: `PasswordRequired` when the file needs another password (another program protected it).
    public func reloadFromDisk() throws { apply(try Self.readDiskCopy(filePath, diskPassword)) }

    /// `reloadFromDisk` with the reading and parsing on a worker; false (nothing changed) when `stillWanted` says no once
    /// the file has been read. `password`: one the user gave after `PasswordRequired`.
    public func reloadFromDiskAsync(stillWanted: (() -> Bool)? = nil, password given: String? = nil) async throws -> Bool {
        let path = filePath
        let pw = given ?? diskPassword
        let copy = try await Task.detached { try Self.readDiskCopy(path, pw) }.value
        if stillWanted?() == false || path != filePath {
            copy.engine.close()
            return false
        }
        apply(copy)
        return true
    }

    private struct DiskCopy: @unchecked Sendable {
        var data: [UInt8]
        var engine: PdfEngine
        var stamp: DiskStamp?
        var password: String?
        var openPassword: String?
    }

    private static func readDiskCopy(_ path: String?, _ password: String?) throws -> DiskCopy {
        guard let path else { throw PdfEditError("This document has not been saved to a file.") }
        let stamp = DiskStamp.of(path)
        let data = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        let engine = try PdfEngine.open(data, password: password)
        return DiskCopy(data: data, engine: engine, stamp: stamp, password: password,
                        openPassword: PdfSecurity.isOpenPassword(data, password) ? password : nil)
    }

    private func apply(_ copy: DiskCopy) {
        // The file's passwords from now on; the same password keeps an open password learned since.
        if copy.password != password { (password, openPassword) = (copy.password, copy.openPassword) }
        diskPassword = copy.password
        undoSteps.removeAll()
        redoSteps.removeAll()
        onDisk = copy.stamp
        let v = nextVersion
        nextVersion += 1
        savedVersion = v
        swap(copy.data, copy.engine, v, .reload)
    }

    private func swap(_ newData: [UInt8], _ newEngine: PdfEngine, _ newVersion: Int, _ change: ContentChange) {
        let old = engine
        data = newData
        engine = newEngine
        version = newVersion
        contentChanged?(change)
        stateChanged?()
        old.close()
    }

    private func trimUndo() {
        var total = undoSteps.reduce(0) { $0 + $1.data.count }
        while undoSteps.count > 1 && (undoSteps.count > Self.maxUndoSteps || total > Self.maxUndoBytes) {
            total -= undoSteps[0].data.count
            undoSteps.removeFirst()
        }
    }

    /// Closes the document; later edits fail.
    public func close() {
        closed = true
        engine.close()
    }

    // MARK: The edit transaction

    /// An edit is running (its questions included): another one now returns `.busy`.
    public var isEditing: Bool { editGate.withLock { editing } }

    /// The edit transaction (the Windows app's `EditAsync`): runs the request's edit on a worker and commits it as one undo
    /// step, keeping an encrypted document's protection and a signed document's signatures where it can, asking `prompts`
    /// what only the user can answer: the permissions password an edit needs (then the same edit runs again with it), or
    /// whether to rewrite a signed file. A password that worked is used for later edits too. Never throws: a failed edit's
    /// error is in the result.
    /// - Parameter working: called once the edit starts (the app shows its progress from then on).
    public func edit(_ request: EditRequest, prompts: EditPrompts, working: (() -> Void)? = nil) async -> EditResult {
        if closed { return EditResult(.failed) }
        let started = editGate.withLock { () -> Bool in
            if editing { return false }
            editing = true
            return true
        }
        guard started else { return EditResult(.busy) }
        defer { editGate.withLock { editing = false } }
        working?()
        return await runEdit(request, prompts)
    }

    private func runEdit(_ request: EditRequest, _ prompts: EditPrompts) async -> EditResult {
        do {
            let original = data
            var pw = password
            var rewrite = false
            var result: [UInt8]
            var report: SignedEditReport
            while true {
                do {
                    let (allow, given, open) = (rewrite, pw, openPassword)
                    (result, report) = try await Task.detached {
                        try KeptProtection.run(openPassword: open, dropOpenPassword: false) {
                            try SignedEdits.run({ try request.edit(original, given) }, allowRewrite: allow)
                        }
                    }.value
                    break
                } catch let e as OwnerPasswordRequired where !closed {
                    // Opened for viewing without the permissions password: ask for it and try the same edit again.
                    guard let owner = prompts.askOwnerPassword(wrong: e.wrongPassword) else { return EditResult(.declined) }
                    pw = owner
                } catch let e as SignaturesWouldBreak where !closed && !rewrite {
                    // The edit can't be appended to the signed file: say so before anything is committed, then redo it as a rewrite.
                    if !prompts.confirmSignatureRewrite(label: request.label, signatures: e.signatureCount, reason: e.reason) {
                        return EditResult(.declined)
                    }
                    rewrite = true
                }
            }
            if closed { return EditResult(.failed) }
            if let pw, pw != password { usePassword(pw) } // only once it worked
            if result == original { return EditResult(.noChange) }
            let change: ContentChange = request.contentOnly ? .contentOnlyEdit : .edit
            let id = if let np = request.newPasswords {
                try commit(result, request.label, np.password, np.openPassword, change)
            } else {
                try commit(result, request.label, password, openPassword, change)
            }
            return EditResult(.done, stepId: id, removedItemKept: report.removedItemKept)
        } catch is CancellationError {
            return EditResult(.declined) // the user cancelled a long edit (e.g. text recognition): nothing changed
        } catch {
            return EditResult(.failed, error: error) // the caller reports it; never lose it
        }
    }
}

/// How an edit transaction ended.
public enum EditOutcome: Equatable, Sendable {
    /// Committed as one undo step.
    case done
    /// The edit returned the bytes it was given: nothing to commit, no undo step.
    case noChange
    /// Another edit (or its questions) holds the document: try again once it is done.
    case busy
    /// The user said no to a question (password, signatures), or cancelled a long edit: nothing changed.
    case declined
    /// The edit threw (see `EditResult.error`), or the document was closed meanwhile.
    case failed
}

/// What `DocumentSession.edit` did.
public struct EditResult: Sendable {
    public var outcome: EditOutcome
    /// The undo step a `.done` edit made (compare with `DocumentSession.undoStepId`).
    public var stepId: Int
    /// The edit removed something that can still be recovered from the signed revision (`SignedEditReport`).
    public var removedItemKept: Bool
    /// Why a `.failed` edit failed, when it threw.
    public var error: (any Error)?

    init(_ outcome: EditOutcome, stepId: Int = 0, removedItemKept: Bool = false, error: (any Error)? = nil) {
        self.outcome = outcome
        self.stepId = stepId
        self.removedItemKept = removedItemKept
        self.error = error
    }
}

/// One edit for `DocumentSession.edit`.
public struct EditRequest: Sendable {
    /// Names the undo step ("Rotate pages"), and the questions asked about it.
    public var label: String
    /// The edited bytes from the document's bytes and password; runs on a worker, and again after a question was answered
    /// (a password, a rewrite allowed). Returning the same bytes means nothing changed.
    public var edit: @Sendable ([UInt8], String?) throws -> [UInt8]
    /// A form value or Fill & Sign edit: the pages stay as they were (`ContentChange.contentOnlyEdit`).
    public var contentOnly = false
    /// The caller already told the user the edit breaks the signatures (redaction): don't ask again.
    public var signaturesWarned = false
    /// The edit changes the protection (protect, unprotect): the passwords that open the result.
    public var newPasswords: (password: String?, openPassword: String?)?

    public init(_ label: String, _ edit: @escaping @Sendable ([UInt8], String?) throws -> [UInt8]) {
        self.label = label
        self.edit = edit
    }
}

/// The questions an edit transaction asks the user, at most once per answer it needs; a "no" (false, nil) declines the
/// edit. The app's adapter shows dialogs; tests answer from a script.
public protocol EditPrompts: Sendable {
    /// The document opened for viewing without its permissions (owner) password: ask for it. `wrong`: the one tried was
    /// wrong. Nil declines.
    func askOwnerPassword(wrong: Bool) -> String?

    /// The edit can't be appended to the signed file: saving it rewrites the file and invalidates `signatures`
    /// signatures. `reason` says why, for the log.
    func confirmSignatureRewrite(label: String, signatures: Int, reason: String) -> Bool
}
