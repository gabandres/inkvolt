import Foundation
import Testing
@testable import PdfCore

/// Ported from EditTransactionTests.cs: the edit transaction (`DocumentSession.edit`) through its interface, the
/// questions it asks (answered by a script) and the session afterwards. Adapted: AnAes256Edit… asks nothing on the Mac (MuPDF keeps the open password
/// without knowing it), so it checks that the protection and the open password stay; ASignedFileAsksBeforeAnEditBreaksItsSignature
/// uses IncrSignatureTests' really signed two-page form (SignedEditTests' fixture is only signed-looking on the Mac). Left out:
/// AnEncryptedSignedFileWarnsOnceBeforeItsFirstEdit (MuPDF appends to an encrypted signed file, so there is no rewrite to warn about).
struct EditTransactionTests {
    /// Answers the transaction's questions from fixed answers and records what it was asked.
    final class ScriptedPrompts: EditPrompts, @unchecked Sendable {
        var ownerPasswords: [String?] = []
        var rewrite = true
        var breaking = true
        var asked: [String] = []

        init(ownerPasswords: [String?] = [], rewrite: Bool = true, breaking: Bool = true) {
            self.ownerPasswords = ownerPasswords
            self.rewrite = rewrite
            self.breaking = breaking
        }

        func confirmBreakingEdit(label: String, broken: [SignatureInfo]) -> Bool {
            asked.append("breaks " + broken.map(\.fieldName).joined(separator: ", "))
            return breaking
        }

        func askOwnerPassword(wrong: Bool) -> String? {
            asked.append(wrong ? "owner (wrong)" : "owner")
            return ownerPasswords.removeFirst()
        }

        func confirmSignatureRewrite(label: String, signatures: Int, reason: String) -> Bool {
            asked.append("rewrite \(signatures)")
            return rewrite
        }
    }

    /// Records what a session reports.
    final class Events: @unchecked Sendable {
        var changes: [ContentChange] = []
    }

    /// Lets a test hold an edit midway.
    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var started_ = false, released_ = false
        var started: Bool { lock.withLock { started_ } }
        func start() { lock.withLock { started_ = true } }
        func release() { lock.withLock { released_ = true } }
        func wait() { while !lock.withLock({ released_ }) { Thread.sleep(forTimeInterval: 0.005) } }
    }

    private func rotate(_ label: String = "Rotate") -> EditRequest {
        EditRequest(label) { d, pw in try PageEditor.rotate(d, pw, [0], 90) }
    }

    private func landscape(_ s: DocumentSession) -> Bool { s.engine.page(0).width > s.engine.page(0).height }

    @Test func anEditIsOneUndoStepThatKeepsItsIdThroughUndoAndRedo() async throws {
        let session = try DocumentSession.fromBytes(TestPdf.make(2), "t.pdf")
        defer { session.close() }
        let prompts = ScriptedPrompts()
        let events = Events()
        session.contentChanged = { events.changes.append($0) }
        var working = 0

        let first = await session.edit(rotate("Rotate"), prompts: prompts) { working += 1 }
        let second = await session.edit(EditRequest("Delete page") { d, pw in try PageEditor.delete(d, pw, [1]) }, prompts: prompts)

        #expect(first.outcome == .done)
        #expect(working == 1)
        #expect(first.stepId != second.stepId)
        #expect(session.undoStepId == second.stepId)
        #expect(session.undoLabel == "Delete page")
        #expect(session.engine.pageCount == 1)
        #expect(landscape(session))
        #expect(session.isDirty)

        try session.undo()
        #expect(session.undoStepId == first.stepId)
        #expect(session.redoLabel == "Delete page")
        #expect(session.engine.pageCount == 2)
        try session.undo()
        #expect(session.undoStepId == nil)
        #expect(!landscape(session))
        try session.redo()
        try session.redo()
        #expect(session.undoStepId == second.stepId) // the same edit again, not a new one
        #expect(session.engine.pageCount == 1)

        #expect(events.changes == [.edit, .edit, .undo, .undo, .redo, .redo])
        #expect(prompts.asked.isEmpty)
    }

    @Test func contentOnlyEditsSaySoAndUnchangedBytesMakeNoStep() async throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>"])
        let session = try DocumentSession.fromBytes(form, "f.pdf")
        defer { session.close() }
        let events = Events()
        session.contentChanged = { events.changes.append($0) }
        let prompts = ScriptedPrompts()

        var fill = EditRequest("Fill form field") { d, pw in try FormEditor.fill(d, pw, ["name": "Ada"]).data }
        fill.contentOnly = true
        #expect(await session.edit(fill, prompts: prompts).outcome == .done)
        #expect(events.changes.count == 1 && events.changes[0].contentOnly)
        try session.undo()
        #expect(!events.changes[1].contentOnly) // undo replaces the pages
        #expect(events.changes[1].steppedHistory)

        let before = session.undoStepId
        let same = await session.edit(EditRequest("Nothing") { d, _ in d }, prompts: prompts)
        #expect(same.outcome == .noChange)
        #expect(session.undoStepId == before)
        #expect(events.changes.count == 2)
    }

    @Test func failuresAndCancellationsCommitNothing() async throws {
        let session = try DocumentSession.fromBytes(TestPdf.make(1), "t.pdf")
        defer { session.close() }
        let prompts = ScriptedPrompts()
        let failed = await session.edit(EditRequest("Break") { _, _ in throw PdfEditError("nope") }, prompts: prompts)
        #expect(failed.outcome == .failed)
        #expect((failed.error as? PdfEditError)?.message == "nope")
        let cancelled = await session.edit(EditRequest("Recognize") { _, _ in throw CancellationError() }, prompts: prompts)
        #expect(cancelled.outcome == .declined)
        #expect(cancelled.error == nil)
        #expect(!session.canUndo)
        #expect(!session.isEditing)
    }

    @Test func oneEditAtATime() async throws {
        let session = try DocumentSession.fromBytes(TestPdf.make(1), "t.pdf")
        defer { session.close() }
        let prompts = ScriptedPrompts()
        let hold = Hold()
        async let slow = session.edit(EditRequest("Slow") { d, pw in
            hold.start()
            hold.wait()
            return try PageEditor.rotate(d, pw, [0], 90)
        }, prompts: prompts)
        while !hold.started { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.isEditing)
        #expect(await session.edit(rotate(), prompts: prompts).outcome == .busy)
        hold.release()
        #expect(await slow.outcome == .done)
        #expect(session.undoLabel == "Slow")
    }

    @Test func asksForTheOwnerPasswordUntilItWorksAndKeepsIt() async throws {
        let restricted = OwnerPasswordTests.ownerOnly("own")
        let session = try DocumentSession.fromBytes(restricted, "r.pdf")
        defer { session.close() }
        let prompts = ScriptedPrompts(ownerPasswords: ["wrong", "own"])

        let result = await session.edit(rotate(), prompts: prompts)

        #expect(result.outcome == .done)
        #expect(prompts.asked == ["owner", "owner (wrong)"])
        #expect(session.password == "own")
        #expect(try PdfSecurity.readSecurity(session.data, "own").isEncrypted) // still protected
        #expect(await session.edit(rotate("Again"), prompts: prompts).outcome == .done)
        #expect(prompts.asked.count == 2) // not asked again

        let other = try DocumentSession.fromBytes(restricted, "r.pdf")
        defer { other.close() }
        #expect(await other.edit(rotate(), prompts: ScriptedPrompts(ownerPasswords: [nil])).outcome == .declined)
        #expect(!other.canUndo)
    }

    @Test func anAes256EditKeepsTheProtectionAndTheOpenPassword() async throws {
        let pdf = KeptProtectionTests.encrypted("aes-256", "secret")
        let session = try DocumentSession.fromBytes(pdf, "a.pdf", password: KeptProtectionTests.owner)
        defer { session.close() }
        let prompts = ScriptedPrompts()

        #expect(await session.edit(rotate(), prompts: prompts).outcome == .done)
        #expect(prompts.asked.isEmpty)
        let info = try PdfSecurity.readSecurity(session.data, "secret")
        #expect(info.method == .aes256)
        #expect(info.requiresOpenPassword)
        #expect(await session.edit(rotate("Again"), prompts: prompts).outcome == .done)
        #expect(try PdfSecurity.readSecurity(session.data, "secret").requiresOpenPassword)
    }

    @Test func protectionChangesCommitTheirPasswordsAndUndoRestoresThem() async throws {
        let session = try DocumentSession.fromBytes(TestPdf.make(1), "p.pdf")
        defer { session.close() }
        var protect = EditRequest("Protect") { d, pw in try PdfSecurity.protect(d, pw, userPassword: "open", ownerPassword: "own") }
        protect.newPasswords = ("own", "open")
        #expect(await session.edit(protect, prompts: ScriptedPrompts()).outcome == .done)
        #expect(session.password == "own" && session.openPassword == "open")
        #expect(try PdfSecurity.readSecurity(session.data, "open").requiresOpenPassword)
        // A later edit keeps it protected.
        #expect(await session.edit(rotate(), prompts: ScriptedPrompts()).outcome == .done)
        #expect(try PdfSecurity.readSecurity(session.data, "open").requiresOpenPassword)
        try session.undo()
        try session.undo()
        #expect(session.password == nil && session.openPassword == nil)
        #expect(!session.engine.isEncrypted)
    }

    @Test func aSignedFileAsksBeforeAnEditBreaksItsSignature() async throws {
        let session = try DocumentSession.fromBytes(try IncrSignatureTests.signedForm(twoPages: true), "s.pdf")
        defer { session.close() }
        session.signedOnOpen = true
        let no = ScriptedPrompts(breaking: false)

        // A comment is appended: the signature stays valid, nothing to ask.
        let note = EditRequest("Add note") { d, pw in try Annotations.addNote(d, pw, 0, 100, 100, "Hi", author: "Me") }
        let noted = await session.edit(note, prompts: no)
        #expect(noted.outcome == .done)
        #expect(!noted.removedItemKept)
        #expect(no.asked.isEmpty)

        // Deleting a page alters what was signed.
        let before = session.data
        let delete = EditRequest("Delete pages") { d, pw in try PageEditor.delete(d, pw, [1]) }
        #expect(await session.edit(delete, prompts: no).outcome == .declined)
        #expect(no.asked == ["breaks Approval"])
        #expect(session.data == before)

        let yes = ScriptedPrompts()
        let deleted = await session.edit(delete, prompts: yes)
        #expect(deleted.outcome == .done)
        #expect(deleted.removedItemKept) // appended: the page is still in the signed revision
        #expect(session.engine.pageCount == 1)

        // Already warned (redaction): no question.
        try session.undo()
        let warned = ScriptedPrompts()
        var quiet = delete
        quiet.signaturesWarned = true
        #expect(await session.edit(quiet, prompts: warned).outcome == .done)
        #expect(warned.asked.isEmpty)
    }

    @Test func anEditThatRewritesASignedFileAsksFirst() async throws {
        let session = try DocumentSession.fromBytes(SignedEditTests.signed(), "s.pdf")
        defer { session.close() }
        var protect = EditRequest("Protect") { d, pw in try PdfSecurity.protect(d, pw, userPassword: "open", ownerPassword: "own") }
        protect.newPasswords = ("own", "open")

        let no = ScriptedPrompts(rewrite: false)
        #expect(await session.edit(protect, prompts: no).outcome == .declined)
        #expect(no.asked == ["rewrite 1"])
        #expect(!session.canUndo)

        let yes = ScriptedPrompts()
        #expect(await session.edit(protect, prompts: yes).outcome == .done)
        #expect(yes.asked == ["rewrite 1"])
        #expect(session.engine.isEncrypted)
    }

    @Test func onlyOpenSessionsAreEdited() async throws {
        let session = try DocumentSession.fromBytes(TestPdf.make(1), "t.pdf")
        session.close()
        #expect(await session.edit(rotate(), prompts: ScriptedPrompts()).outcome == .failed)
    }
}
