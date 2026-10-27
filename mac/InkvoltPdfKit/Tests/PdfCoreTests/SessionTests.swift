import Foundation
import Testing
@testable import PdfCore

/// A folder of the test's own, deleted afterwards.
final class TempFolder {
    let path: String

    init(_ prefix: String) {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        // Read-only files left by a test go too.
        if let names = FileManager.default.enumerator(atPath: path) {
            for case let name as String in names {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: (path as NSString).appendingPathComponent(name))
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    func write(_ data: [UInt8], _ name: String = "doc.pdf") -> String {
        let p = file(name)
        FileManager.default.createFile(atPath: p, contents: Data(data))
        return p
    }
}

private func read(_ path: String) -> [UInt8] { [UInt8](FileManager.default.contents(atPath: path) ?? Data()) }

/// Ported from SessionProtectionTests.cs: a session's protection as the commands see it, and reloading a file whose
/// protection the session changed or that another program protected.
struct SessionProtectionTests {
    private let dir = TempFolder("inkvoltpdf-protection")
    private static let noCopying = PdfPermissions(print: .highResolution, copy: false, modify: true, annotate: true, fillForms: true, assemble: true)

    @Test func aRestrictionOnlyPdfHasEncryptionThoughItOpensWithoutAPassword() throws {
        let pdf = try PdfSecurity.protect(TestPdf.make(1), nil, userPassword: nil, ownerPassword: "owner", permissions: Self.noCopying)
        let s = try DocumentSession.fromBytes(pdf, "restricted.pdf")
        defer { s.close() }
        #expect(!s.engine.isEncrypted) // MuPDF: no open password needed, so "not encrypted"
        #expect(s.hasEncryption)
    }

    @Test func openPasswordProtectedAndPlainPdfs() throws {
        let locked = try DocumentSession.fromBytes(PdfSecurity.protect(TestPdf.make(1), nil, userPassword: "open", ownerPassword: "owner"), "locked.pdf", password: "open")
        #expect(locked.hasEncryption)
        locked.close()
        let plain = try DocumentSession.fromBytes(TestPdf.make(1), "plain.pdf")
        #expect(!plain.hasEncryption)
        plain.close()
    }

    @Test func removingTheProtectionClearsItAndUndoBringsItBack() throws {
        let pdf = try PdfSecurity.protect(TestPdf.make(1), nil, userPassword: nil, ownerPassword: "owner", permissions: Self.noCopying)
        let s = try DocumentSession.fromBytes(pdf, "restricted.pdf", password: "owner")
        defer { s.close() }
        try s.commit(PdfSecurity.unprotect(s.data, s.password), "Remove password protection", password: nil, openPassword: nil)
        #expect(!s.hasEncryption)
        try s.undo()
        #expect(s.hasEncryption)
    }

    @Test func reloadAfterRemovingTheProtectionOpensTheProtectedFileWithItsPassword() async throws {
        let path = dir.write(try PdfSecurity.protect(TestPdf.make(2), nil, userPassword: "open", ownerPassword: "owner"))
        let s = try DocumentSession.open(path, password: "open")
        defer { s.close() }
        try s.commit(PdfSecurity.unprotect(s.data, "owner"), "Remove password protection", password: nil, openPassword: nil)
        #expect(s.password == nil)

        #expect(try await s.reloadFromDiskAsync())
        #expect(!s.isDirty)
        #expect(s.hasEncryption)
        #expect(s.password == "open")
        #expect(s.openPassword == "open")
        #expect(s.engine.pageCount == 2)
    }

    @Test func reloadAfterSavingWithoutProtectionNeedsNoPassword() async throws {
        let path = dir.write(try PdfSecurity.protect(TestPdf.make(1), nil, userPassword: "open", ownerPassword: "owner"))
        let s = try DocumentSession.open(path, password: "open")
        defer { s.close() }
        try s.commit(PdfSecurity.unprotect(s.data, "owner"), "Remove password protection", password: nil, openPassword: nil)
        try await s.saveAsAsync(path)

        #expect(try await s.reloadFromDiskAsync())
        #expect(s.password == nil)
        #expect(!s.hasEncryption)
    }

    @Test func aFileProtectedByAnotherProgramNeedsItsPasswordToReload() async throws {
        let path = dir.write(TestPdf.make(1))
        let s = try DocumentSession.open(path)
        defer { s.close() }
        FileManager.default.createFile(atPath: path, contents: Data(try PdfSecurity.protect(TestPdf.make(3), nil, userPassword: "theirs", ownerPassword: "owner")))

        await #expect(throws: PasswordRequired(wrongPassword: false)) { _ = try await s.reloadFromDiskAsync() }
        await #expect(throws: PasswordRequired.self) { _ = try await s.reloadFromDiskAsync(password: "wrong") }
        #expect(s.engine.pageCount == 1) // nothing changed

        #expect(try await s.reloadFromDiskAsync(password: "theirs"))
        #expect(s.engine.pageCount == 3)
        #expect(s.password == "theirs")
        #expect(s.openPassword == "theirs")
    }
}

/// Ported from RecoveryTests.cs: recovery copies of unsaved documents, each run's in a folder of its own, locked while
/// it runs; a clean exit removes the folder, and a run that ended without one leaves it for the next start.
struct RecoveryTests {
    private let root = TempFolder("inkvoltpdf-recovery")

    private func info(_ name: String, _ path: String? = nil) -> RecoveryInfo {
        RecoveryInfo(displayName: name, originalPath: path, originalLength: nil, originalWriteTime: nil,
                     saved: Date(timeIntervalSince1970: 1_793_016_000), page: 3)
    }

    private func folders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    @Test func aRunningCopysDocumentsAreNotOffered() throws {
        let store = try RecoveryStore.start(root.path)
        defer { store.close() }
        try store.write("a", [1, 2, 3], info("report.pdf"))
        #expect(RecoveryStore.findLeftOver(root.path).isEmpty)
    }

    @Test func aCleanExitLeavesNothing() throws {
        let store = try RecoveryStore.start(root.path)
        try store.write("a", [1, 2, 3], info("report.pdf"))
        store.close()
        #expect(RecoveryStore.findLeftOver(root.path).isEmpty)
        #expect(folders().isEmpty)
    }

    @Test func aRunThatEndedWithoutCleaningUpLeavesItsDocumentsWithWhereTheyCameFrom() throws {
        let store = try RecoveryStore.start(root.path)
        try store.write("a", [1, 2, 3], info("report.pdf", "/Users/me/Docs/report.pdf"))
        try store.write("b", [4, 5], info("Combined.pdf"))
        try store.write("a", [7, 8, 9, 10], info("report.pdf", "/Users/me/Docs/report.pdf")) // a later copy replaces the first
        store.abandon() // as a crash or a killed process would

        let left = RecoveryStore.findLeftOver(root.path).sorted { $0.info.displayName < $1.info.displayName }
        #expect(left.map(\.info.displayName) == ["Combined.pdf", "report.pdf"])
        #expect(left[1].info.originalPath == "/Users/me/Docs/report.pdf")
        #expect(left[1].info.page == 3)
        #expect(read(left[1].pdfPath) == [7, 8, 9, 10])
    }

    @Test func aRemovedDocumentIsNotLeftOver() throws {
        let store = try RecoveryStore.start(root.path)
        try store.write("a", [1], info("a.pdf"))
        try store.write("b", [2], info("b.pdf"))
        store.remove("a")
        store.abandon()
        #expect(RecoveryStore.findLeftOver(root.path).map(\.info.displayName) == ["b.pdf"])
    }

    @Test func halfWrittenOrDamagedCopiesAreSkipped() throws {
        let store = try RecoveryStore.start(root.path)
        try store.write("good", [1], info("good.pdf"))
        store.abandon()
        let folder = (root.path as NSString).appendingPathComponent(try #require(folders().first))
        func put(_ name: String, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: (folder as NSString).appendingPathComponent(name), contents: Data(bytes)) }
        put("nodesc.pdf", [1]) // a copy without its description
        put("nocopy.json", Array("{}".utf8)) // a description without its copy
        put("bad.pdf", [1])
        put("bad.json", Array("not json".utf8))
        #expect(RecoveryStore.findLeftOver(root.path).map(\.info.displayName) == ["good.pdf"])
    }

    @Test func discardingALeftOverRunDeletesItsFolder() throws {
        let store = try RecoveryStore.start(root.path)
        try store.write("a", [1], info("a.pdf"))
        store.abandon()
        RecoveryStore.discard(RecoveryStore.findLeftOver(root.path))
        #expect(RecoveryStore.findLeftOver(root.path).isEmpty)
        #expect(folders().isEmpty)
    }

    @Test func aRecoveredDocumentHasUnsavedChangesAndSavesBackToItsFile() throws {
        let path = root.write(TestPdf.make(1, marker: "old"), "report.pdf")
        let session = try DocumentSession.recover(TestPdf.make(2, marker: "edited"), originalPath: path, "report.pdf")
        defer { session.close() }
        #expect(session.isDirty)
        #expect(session.filePath == URL(fileURLWithPath: path).standardizedFileURL.path)
        #expect(session.engine.pageCount == 2)
        try session.saveAs(try #require(session.filePath))
        #expect(!session.isDirty)
        #expect(TestPdf.pageNumbers(read(path)).count == 2)
    }

    @Test func aProtectedDocumentStaysProtectedAndNeedsItsPassword() throws {
        let data = TestPdf.encrypted(1, "pw")
        #expect(throws: PasswordRequired.self) { try DocumentSession.recover(data, originalPath: nil, "secret.pdf") }
        let session = try DocumentSession.recover(data, originalPath: nil, "secret.pdf", password: "pw")
        defer { session.close() }
        #expect(session.isDirty)
        #expect(session.filePath == nil)
        #expect(session.data == data) // the copy is the protected bytes, as Save writes them
    }

    @Test func aRecoveredDocumentWhoseFileChangedSinceSaysSo() throws {
        let path = root.write(TestPdf.make(1, marker: "old"), "report.pdf")
        let stamp = try #require(DiskStamp.of(path))
        let same = try DocumentSession.recover(TestPdf.make(2), originalPath: path, "report.pdf", diskStamp: stamp)
        #expect(!same.hasChangedOnDisk())
        same.close()
        FileManager.default.createFile(atPath: path, contents: Data(TestPdf.make(3, marker: "someone else")))
        try FileManager.default.setAttributes([.modificationDate: stamp.writeTime.addingTimeInterval(300)], ofItemAtPath: path)
        let changed = try DocumentSession.recover(TestPdf.make(2), originalPath: path, "report.pdf", diskStamp: stamp)
        defer { changed.close() }
        #expect(changed.hasChangedOnDisk())
    }
}

/// Ported from Core1EngineTests.cs's Core1SessionTests: saving, and noticing the file change on disk.
struct Core1SessionTests {
    private let dir = TempFolder("inkvoltpdf-session")

    private func temps(_ path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".\(name).") && $0.hasSuffix(".tmp") }
    }

    @Test func saveReplacesTheFileKeepingItsCreationTime() throws {
        let path = dir.write(TestPdf.make(3))
        let created = Date(timeIntervalSince1970: 1_588_748_889) // 2020-05-06 07:08:09 UTC
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: path)
        let session = try DocumentSession.open(path)
        defer { session.close() }
        try session.commit(PageEditor.delete(session.data, nil, [0]), "Delete")
        try session.saveAs(path)
        let creation = try #require(try FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date)
        #expect(abs(creation.timeIntervalSince(created)) < 1)
        #expect(TestPdf.pageNumbers(read(path)) == [2, 3])
        #expect(!session.isDirty)
        #expect(!session.hasChangedOnDisk())
        #expect(temps(path).isEmpty)

        let other = dir.file("other.pdf")
        try session.saveAs(other)
        #expect(session.filePath == URL(fileURLWithPath: other).standardizedFileURL.path)
        #expect(TestPdf.pageNumbers(read(other)) == [2, 3])
    }

    @Test func savingOverAReadOnlyFileSaysSo() throws {
        let path = dir.write(TestPdf.make(3))
        let session = try DocumentSession.open(path)
        defer { session.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        let error = #expect(throws: PdfEditError.self) { try session.saveAs(path) }
        #expect(error?.message.contains("is read-only") == true)
        #expect(TestPdf.pageNumbers(read(path)).count == 3)
    }

    @Test func detectsAndReloadsExternalChanges() throws {
        let path = dir.write(TestPdf.make(3))
        let session = try DocumentSession.open(path)
        defer { session.close() }
        #expect(!session.hasChangedOnDisk())
        #expect(!session.isMissingOnDisk())
        try session.commit(PageEditor.rotate(session.data, nil, [0], 90), "Rotate")

        FileManager.default.createFile(atPath: path, contents: Data(TestPdf.make(5, marker: "beta")))
        #expect(session.hasChangedOnDisk())

        var events: [String] = []
        session.contentChanged = { _ in events.append("content:\(session.engine.pageCount)") }
        session.stateChanged = { events.append("state:\(session.isDirty)") }
        try session.reloadFromDisk()
        #expect(events == ["content:5", "state:false"])
        #expect(session.engine.pageCount == 5)
        #expect(!session.canUndo)
        #expect(!session.canRedo)
        #expect(!session.isDirty)
        #expect(!session.hasChangedOnDisk())
        #expect(try session.engine.text(0).text.contains("beta"))

        // Editing and undoing back to the reloaded state is clean again.
        try session.commit(PageEditor.delete(session.data, nil, [0]), "Delete")
        #expect(session.isDirty)
        try session.undo()
        #expect(!session.isDirty)
    }

    @Test func detectsAMissingFile() throws {
        let path = dir.write(TestPdf.make(3))
        let session = try DocumentSession.open(path)
        defer { session.close() }
        try FileManager.default.removeItem(atPath: path)
        #expect(session.isMissingOnDisk())
        #expect(session.hasChangedOnDisk())
        #expect(throws: (any Error).self) { try session.reloadFromDisk() }
        #expect(session.engine.pageCount == 3) // a failed reload changes nothing
    }

    @Test func unsavedDocumentsHaveNoDiskState() throws {
        let session = try DocumentSession.fromBytes(TestPdf.make(1), "New.pdf")
        defer { session.close() }
        #expect(!session.hasChangedOnDisk())
        #expect(!session.isMissingOnDisk())
        #expect(throws: PdfEditError.self) { try session.reloadFromDisk() }
    }
}
