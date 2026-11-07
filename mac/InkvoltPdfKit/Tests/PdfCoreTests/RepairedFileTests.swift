import Foundation
import PrintCore
import Testing
@testable import PdfCore

/// Ported from DamagedFileTests.cs: a damaged file opens as a repaired copy (`DocumentSession.repaired`), the person is told, and a
/// signature made before the repair is never shown valid. Plus what MuPDF's own repair asks of the Mac: a stale tail's old
/// objects reach no reader, whichever way the file is read. Adapted: Windows' rebuild tests are PDFsharp's, not ported.
struct RepairedFileTests {
    /// A stale tail holding an older copy of the field, with a whole object: repaired, not quietly cut.
    private static func shadowTail(after sound: [UInt8]) -> [UInt8] {
        Array("ndobj\n5 0 obj\n<< /Type /Annot /Subtype /Widget /F 4 /FT /Tx /T (name) /Rect [72 700 300 720] /V (Older) >>\nendobj\ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n\(sound.count - 30)\n%%EOF\n".utf8)
    }

    /// The same, with no object in it: rows of the old table, its trailer, a startxref into the new file.
    private static func plainTail(after sound: [UInt8]) -> [UInt8] {
        Array("0000000099 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n\(sound.count - 30)\n%%EOF\n".utf8)
    }

    private func signed() async throws -> [UInt8] {
        try await SigningTests.sign(DamagedFile.sound(), try SigningTests.rsaId())
    }

    private func name(_ data: [UInt8]) throws -> String? { try FormEditor.read(data, nil).first { $0.fieldName == "name" }?.value }

    // MARK: Signatures

    @Test func aSignatureMadeBeforeTheRepairIsNeverShownValid() async throws {
        let good = try await signed()
        let session = try DocumentSession.fromBytes(good + Self.shadowTail(after: good), "damaged.pdf", repair: true)
        defer { session.close() }
        #expect(session.repaired)
        let sigs = Signatures.verify(session.data, nil, repairedLength: session.repairedLength)
        #expect(sigs.count == 1)
        #expect(sigs.first?.status == .unsupported)
        #expect(sigs.first?.inRepairedFile == true)
        #expect(sigs.first?.detail != nil)
        // A file that wasn't repaired is checked as usual.
        #expect(Signatures.verify(good).first?.status == .valid)
        #expect(Signatures.verify(good, nil, repairedLength: 0).first?.inRepairedFile == false)
    }

    /// The bytes as they are, not through a session: nothing that reads a signature shows one valid over a hidden tail or a repair.
    @Test(arguments: ["tail", "offsets", "cut"])
    func aDamagedSignedFileReadDirectlyIsNeverShownValid(damage: String) async throws {
        let good = try await signed()
        let damaged: [UInt8]
        switch damage {
        case "tail": damaged = good + Self.shadowTail(after: good)
        case "offsets": damaged = DamagedFile.brokenOffsets(good)
        default: damaged = Array(good.dropLast(64))
        }
        for s in Signatures.verify(damaged) { #expect(s.status != .valid, "\(damage)") }
    }

    /// A tail with no object can hide nothing: it is cut quietly and the signature checks as usual.
    @Test func aTailWithNoObjectLeavesTheSignatureChecked() async throws {
        let good = try await signed()
        let normal = PdfRepair.normalize(good + Self.plainTail(after: good), nil)
        #expect(normal.data == good)
        #expect(!normal.repaired)
        #expect(Signatures.verify(normal.data).first?.status == .valid)
    }

    /// A tail its signature covers isn't a tail: the file is repaired, and the signature isn't shown valid.
    @Test func aTailASignatureCoversIsNotCut() async throws {
        let good = try await signed()
        let tail = Self.shadowTail(after: good)
        let covering = good + tail
        #expect(StaleTail.keepLength(covering) < covering.count)
        // A /ByteRange reaching past the cut, written where the file's own has room: the signature's dictionary is rewritten.
        let forged = Array("/ByteRange [0 10 20 \(covering.count + 500)]".utf8)
        #expect(StaleTail.keepLength(covering + forged) == (covering + forged).count)
    }

    @Test func aRepairedFileCanBeSignedAndItsSignatureChecks() async throws {
        let session = try DocumentSession.fromBytes(DamagedFile.truncated(), "damaged.pdf", repair: true)
        defer { session.close() }
        #expect(session.repaired)
        // Signing appends to the repaired bytes, never the file's.
        var request = SignRequest(id: try SigningTests.rsaId())
        request.repairedLength = session.repairedLength
        let out = try await Signing.sign(session.data, nil, request)
        #expect(Array(out[..<session.data.count]) == session.data)
        let sigs = Signatures.verify(out, nil, repairedLength: session.repairedLength)
        #expect(sigs.first?.status == .valid) // made on the repaired copy: checked as usual
        #expect(sigs.first?.inRepairedFile == false)
    }

    @Test func aRepairedFileIsNeverCertified() async throws {
        let session = try DocumentSession.fromBytes(DamagedFile.truncated(), "damaged.pdf", repair: true)
        defer { session.close() }
        var request = SignRequest(id: try SigningTests.rsaId())
        request.certify = .formFilling
        request.repairedLength = session.repairedLength
        await #expect(throws: SigningError.self) { _ = try await Signing.sign(session.data, nil, request) }
    }

    /// Signing a file with junk after its last %%EOF: the update goes right after the revision MuPDF read (its offsets count
    /// from there), and no later reader needs a repair.
    @Test func aSignatureOnAFileWithJunkAfterItsEndHasRightOffsets() async throws {
        let sound = DamagedFile.sound()
        let padded = sound + Array(String(repeating: "% padding added by a mail gateway\n", count: 300).utf8)
        let out = try await SigningTests.sign(padded, try SigningTests.rsaId())
        #expect(Array(out[..<sound.count]) == sound)
        #expect(try MuDoc.open(out).canAppend)
        #expect(Signatures.verify(out).first?.status == .valid)
    }

    // MARK: Sessions

    @Test func aDamagedFileOnDiskOpensRepaired() throws {
        let path = NSTemporaryDirectory() + "damaged-\(UUID().uuidString).pdf"
        try Data(DamagedFile.truncated()).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = try DocumentSession.open(path)
        defer { session.close() }
        #expect(session.repaired)
        #expect(session.repairedLength == session.data.count)
        #expect(try MuDoc.open(session.data).canAppend, "the repaired copy is sound")
        #expect(try name(session.data) == "Ana")
        // A reload of a sound file clears it.
        try Data(DamagedFile.sound()).write(to: URL(fileURLWithPath: path))
        try session.reloadFromDisk()
        #expect(!session.repaired)
    }

    @Test func aRecoveredRepairedDocumentStaysRepaired() async throws {
        let good = try await signed()
        let session = try DocumentSession.fromBytes(good + Self.shadowTail(after: good), "damaged.pdf", repair: true)
        defer { session.close() }
        #expect(session.repaired)
        let info = RecoveryInfo(displayName: "damaged.pdf", originalPath: nil, originalLength: nil, originalWriteTime: nil, saved: Date(), page: 1,
                                repairedLength: Int64(session.repairedLength))
        let decoded = try RecoveryStore.decoder().decode(RecoveryInfo.self, from: try RecoveryStore.encoder().encode(info))
        #expect(decoded.repairedLength == Int64(session.repairedLength))
        let recovered = try DocumentSession.recover(session.data, originalPath: nil, "damaged.pdf", repairedLength: Int(decoded.repairedLength ?? 0))
        defer { recovered.close() }
        #expect(recovered.repaired)
        #expect(Signatures.verify(recovered.data, nil, repairedLength: recovered.repairedLength).first?.inRepairedFile == true)
        // A description from before the field reads as not repaired; a length past the copy's end is cut to it.
        let older = RecoveryInfo(displayName: "a.pdf", originalPath: nil, originalLength: nil, originalWriteTime: nil, saved: Date(), page: 1)
        let old = try RecoveryStore.decoder().decode(RecoveryInfo.self, from: try RecoveryStore.encoder().encode(older))
        #expect(old.repairedLength == nil)
        let past = try DocumentSession.recover(session.data, originalPath: nil, "damaged.pdf", repairedLength: Int.max)
        defer { past.close() }
        #expect(past.repairedLength == session.data.count)
    }

    /// Combine, Extract, Scan and the rest open what the app just made: as it is.
    @Test func theAppsOwnBytesAreNotChecked() throws {
        let data = DamagedFile.truncated()
        let own = try DocumentSession.fromBytes(data, "made.pdf")
        defer { own.close() }
        #expect(!own.repaired)
        #expect(own.data == data)
        let outside = try DocumentSession.fromBytes(data, "attachment.pdf", repair: true)
        defer { outside.close() }
        #expect(outside.repaired)
    }

    // MARK: Every path reads the same bytes

    /// A stale tail's old objects reach no reader: not the form reader, an edit, the viewer's text, nor a merge.
    @Test func aStaleTailsOldObjectsReachNoReader() throws {
        let sound = DamagedFile.sound()
        let damaged = sound + Self.shadowTail(after: sound)
        #expect(try name(damaged) == "Ana")
        let filled = try FormEditor.fill(damaged, nil, ["name": "New"]).data
        #expect(try name(filled) == "New")
        let engine = try PdfEngine.open(damaged)
        defer { engine.close() }
        #expect(try engine.textLines(0, annotations: true).map(\.text).joined().contains("Older") == false)
        #expect(try Bookmarks.read(damaged, nil).first?.title == "Chapter one")
    }

    @Test func aBatchRunReadsARepairedFileAndSaysSo() async throws {
        let folder = NSTemporaryDirectory() + "batch-damaged-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = folder + "/damaged.pdf"
        let sound = DamagedFile.sound()
        try Data(sound + Self.shadowTail(after: sound)).write(to: URL(fileURLWithPath: path))
        let plan = BatchPlan(steps: [.rotate(90)], outputFolder: folder + "/out")
        let summary = try await BatchRunner.run([BatchFile(path)], plan, BatchHost())
        let item = try #require(summary.items.first)
        #expect(item.notes.contains { $0 == loc("Damaged: repaired to open it; the results are made from the repaired copy") })
        let output = [UInt8](try Data(contentsOf: URL(fileURLWithPath: try #require(item.outputs.first))))
        #expect(try name(output) == "Ana")
    }

    @Test func aMergeReadsARepairedFile() throws {
        let folder = NSTemporaryDirectory() + "merge-damaged-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let sound = DamagedFile.sound()
        let report = try FormMerge.run(DamagedFile.brokenOffsets(sound), nil, Array("name\nBea\n".utf8), formPath: folder + "/form.pdf",
                                       FormMergeOptions(outputFolder: folder, nameTemplate: FormMergeOptions.defaultTemplate))
        #expect(report.made.count == 1)
        let output = [UInt8](try Data(contentsOf: URL(fileURLWithPath: try #require(report.made.first?.file))))
        #expect(try name(output) == "Bea")
        #expect(try MuDoc.open(output).canAppend)
    }

    // MARK: Which tails are cut

    /// An update that starts with a comment, its startxref a little off, is an update: kept.
    @Test func anUpdateThatStartsWithACommentIsKept() throws {
        let sound = DamagedFile.sound()
        let update = "% added by a tool\n5 0 obj\n<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 0 Tf 0 g) /V (Newer) >>\nendobj\nstartxref\n\(sound.count - 30)\n%%EOF\n"
        let updated = sound + Array(update.utf8)
        #expect(StaleTail.keepLength(updated) == updated.count)
        let normal = PdfRepair.normalize(updated, nil)
        #expect(normal.repaired)
        #expect(try name(normal.data) == "Newer")
    }

    /// Objects dropped with a tail are never dropped silently: the file counts as repaired, and the person is told.
    @Test func aTailHoldingObjectsCountsAsARepair() {
        let sound = DamagedFile.sound()
        let normal = PdfRepair.normalize(sound + Self.shadowTail(after: sound), nil)
        #expect(normal.data == sound)
        #expect(normal.repaired)
    }

    /// A password the document needs and hasn't been given: read as it is, nothing is written.
    @Test func aDamagedFileThatNeedsAPasswordIsLeftUntilItIsGiven() {
        let locked = Encrypt.with(DamagedFile.sound(), "aes-256", user: "open", owner: "own", permissions: .all)
        let broken = DamagedFile.brokenOffsets(locked)
        #expect(PdfRepair.normalize(broken, nil).data == broken)
        let opened = PdfRepair.normalize(broken, "open")
        #expect(opened.repaired)
        #expect((try? FormEditor.read(opened.data, "open"))?.first?.value == "Ana")
    }

    @Test func aRepairedCopyKeepsItsEncryption() throws {
        let locked = Encrypt.with(DamagedFile.sound(), "aes-128", user: "", owner: "own", permissions: .all)
        let normal = PdfRepair.normalize(DamagedFile.brokenOffsets(locked), nil)
        #expect(normal.repaired)
        #expect(try PdfSecurity.readSecurity(normal.data, nil) == PdfSecurity.readSecurity(locked, nil))
        #expect(try name(normal.data) == "Ana")
    }
}
