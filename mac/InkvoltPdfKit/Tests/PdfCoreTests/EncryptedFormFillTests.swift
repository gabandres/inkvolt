import Foundation
import Testing
@testable import PdfCore

/// Ported from EncryptedFormFillTests.cs: encrypted forms whose permissions allow filling (USCIS, OPM) are filled with the
/// user password, as Acrobat, Nitro and Preview do, and saved as an incremental update that keeps the original encryption,
/// /Encrypt and /ID. The permissions (owner) password is never needed for what /P allows, and still is for the rest.
/// Adapted: MuPDF writes the protection (methods it can write: no RC4 in V4, no `AFileWhoseUpdatesDontRepeat...`, which was
/// PDFsharp's trouble, nor `AFormTheUserPasswordPathCantCopy...`, nor the copy's /Perms check, all Windows' own path).
struct EncryptedFormFillTests {
    private func plain() -> [UInt8] {
        Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /V (Alice) /F 4 /P 3 0 R >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /Rect [72 650 90 668] /V /Off /AS /Off /F 4 /P 3 0 R /MK << /CA (4) >> >>",
        ])
    }

    private func protect(_ method: String, fill: Bool, annotate: Bool, user: String = "") -> [UInt8] {
        let permissions = PdfPermissions(print: .highResolution, copy: true, modify: false, annotate: annotate, fillForms: fill, assemble: false)
        return Encrypt.with(plain(), method, user: user, owner: "own", permissions: permissions)
    }

    @Test(arguments: ["rc4-128", "aes-128", "aes-256"])
    func aFormThatAllowsFillingIsFilledWithoutTheOwnerPasswordAndStaysEncrypted(method: String) throws {
        let data = protect(method, fill: true, annotate: false)
        let before = try PdfSecurity.readSecurity(data, nil)

        let filled = try FormEditor.fill(data, nil, ["name": "Filled One", "agree": "On"]).data

        // An incremental update: the original bytes, untouched, then the new objects, encrypted with the file key.
        #expect(Array(filled[..<data.count]) == data)
        let update = Array(filled[data.count...])
        #expect(!latin1(update).contains("Filled One"))
        #expect(latin1(update).contains("/Encrypt"))

        // Same protection; MuPDF's own text of the page and the form reader show the value.
        #expect(try PdfSecurity.readSecurity(filled, nil) == before)
        #expect(try Core2Pdf.allText(filled).contains("Filled One"))
        let widgets = try FormEditor.read(filled, nil)
        #expect(widgets.first { $0.fieldName == "name" }?.value == "Filled One")
        #expect(widgets.first { $0.fieldName == "agree" }?.value != "Off")

        // A later fill appends again.
        let again = try FormEditor.fill(filled, nil, ["name": "Filled Two"]).data
        #expect(Array(again[..<filled.count]) == filled)
        #expect(try Core2Pdf.allText(again).contains("Filled Two"))
        #expect(try PdfSecurity.readSecurity(again, nil) == before)
    }

    /// Revision 2 has no separate fill bit: annotating allows filling.
    @Test func aRevision2FormIsFilledWithItsAnnotateBit() throws {
        let data = protect("rc4-40", fill: true, annotate: true)
        let filled = try FormEditor.fill(data, nil, ["name": "Old handler"]).data
        #expect(Array(filled[..<data.count]) == data)
        #expect(try FormEditor.read(filled, nil).first { $0.fieldName == "name" }?.value == "Old handler")
        #expect(try PdfSecurity.readSecurity(filled, nil) == PdfSecurity.readSecurity(data, nil))
    }

    @Test func theAnnotateBitAloneAllowsFilling() throws {
        let data = protect("aes-128", fill: false, annotate: true)
        let filled = try FormEditor.fill(data, nil, ["name": "By annotate"]).data
        #expect(try FormEditor.read(filled, nil).first { $0.fieldName == "name" }?.value == "By annotate")

        // ...and comments, which filling alone doesn't.
        let noted = try Annotations.addNote(filled, nil, 0, 300, 80, "A note", author: "Ana")
        #expect(Array(noted[..<filled.count]) == filled)
        #expect(try Annotations.read(noted, nil).contains { $0.contents == "A note" })
        #expect(throws: OwnerPasswordRequired.self) {
            try Annotations.addNote(protect("aes-128", fill: true, annotate: false), nil, 0, 300, 80, "A note", author: "Ana")
        }
    }

    @Test func aFormWithAnOpenPasswordIsFilledWithIt() throws {
        let data = protect("aes-256", fill: true, annotate: false, user: "open")
        let filled = try FormEditor.fill(data, "open", ["name": "With open"]).data
        #expect(Array(filled[..<data.count]) == data)
        #expect(try FormEditor.read(filled, "open").first { $0.fieldName == "name" }?.value == "With open")
        #expect(try PdfSecurity.readSecurity(filled, "open").requiresOpenPassword)
    }

    @Test(arguments: ["rc4-128", "aes-256"])
    func aDamagedEncryptedFormIsRepairedThenFilledWithTheUserPassword(method: String) throws {
        // Every xref row off by two bytes: MuPDF rebuilds the cross-reference, carrying /Encrypt and /ID, and the form is
        // filled through the user password, written whole (a repaired file can't be appended to).
        let data = protect(method, fill: true, annotate: false)
        let broken = DamagedFile.brokenOffsets(data)
        #expect(try FormEditor.read(broken, nil).first { $0.fieldName == "name" }?.value == "Alice")

        let filled = try FormEditor.fill(broken, nil, ["name": "Repaired"]).data
        #expect(!latin1(filled).contains("Repaired"))
        #expect(try FormEditor.read(filled, nil).first { $0.fieldName == "name" }?.value == "Repaired")
        #expect(try PdfSecurity.readSecurity(filled, nil) == PdfSecurity.readSecurity(data, nil))
        #expect(try Core2Pdf.allText(filled).contains("Repaired"))
    }

    @Test func whatThePermissionsDontAllowStillNeedsTheOwnerPassword() throws {
        let data = protect("aes-256", fill: false, annotate: false)
        // Filling isn't allowed: it asks for the owner password, and then works.
        #expect(throws: OwnerPasswordRequired.self) { try FormEditor.fill(data, nil, ["name": "No"]) }
        #expect(try FormEditor.read(FormEditor.fill(data, "own", ["name": "Yes"]).data, nil).first { $0.fieldName == "name" }?.value == "Yes")
        // Allowed to fill, but nothing else.
        let fillable = protect("aes-256", fill: true, annotate: false)
        #expect(throws: OwnerPasswordRequired.self) { try PageEditor.rotate(fillable, nil, [0], 90) }
    }

    /// Everything the app does to a form's values goes the same way: Reset and importing data.
    @Test func resettingAndImportingAreFillingToo() throws {
        let data = protect("aes-128", fill: true, annotate: false)
        let cleared = try FormEditor.resetForm(data, nil)
        #expect(try FormEditor.read(cleared, nil).first { $0.fieldName == "name" }?.value == "")
        let imported = try FormEditor.importData(data, nil, Array("{\"name\":\"Imported\"}".utf8))
        #expect(try FormEditor.read(imported.data, nil).first { $0.fieldName == "name" }?.value == "Imported")
    }
}

/// Damaged files (Windows' `DamagedFileTests`): MuPDF repairs them as it opens them. What matters here is the save path: a
/// filled copy keeps the field, the comment and the bookmark, and is a sound file.
enum DamagedFile {
    /// One page with a text field (name = Ana), a note ("Check this") and a bookmark ("Chapter one"); its content stream
    /// shows the text "12 0 obj", which a repair must not take for an object.
    static let objects = [
        "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R] /Contents 9 0 R /Resources << /Font << /Helv 4 0 R >> >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 0 Tf 0 g) /V (Ana) >>",
        "<< /Type /Annot /Subtype /Text /P 3 0 R /Rect [400 700 420 720] /Contents (Check this) >>",
        "<< /Type /Outlines /First 8 0 R /Last 8 0 R /Count 1 >>",
        "<< /Title (Chapter one) /Parent 7 0 R /Dest [3 0 R /Fit] >>",
        Core2Pdf.stream("BT /Helv 12 Tf 72 650 Td (12 0 obj) Tj ET\n"),
    ]

    static func sound() -> [UInt8] { Core2Pdf.build(objects) }

    /// Every row of the xref table off by two bytes, as a tool that changed the header without moving them leaves it.
    static func brokenOffsets(_ data: [UInt8]) -> [UInt8] {
        var out = data
        var from = out.startIndex
        let key = Array(" 00000 n".utf8)
        while let r = out[from...].firstRange(of: key) {
            let start = r.lowerBound - 10
            if let n = Int(String(decoding: out[start..<r.lowerBound], as: UTF8.self)) {
                out.replaceSubrange(start..<r.lowerBound, with: Array(String(format: "%010d", n + 2).utf8))
            }
            from = r.upperBound
        }
        return out
    }

    /// Saved over a longer older copy of itself: after the new %%EOF, the old file's last object (an older font), the end
    /// of its xref table, its trailer and a startxref into the middle of the new file.
    static func staleTail() -> [UInt8] {
        let data = sound()
        return data + Array("ndobj\n4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n0000000099 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n\(data.count - 30)\n%%EOF\n".utf8)
    }

    /// A stale tail that holds an older copy of the field: its old value must not come back.
    static func staleTailWithAnOlderField() -> [UInt8] {
        let data = sound()
        return data + Array("ndobj\n5 0 obj\n<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 0 Tf 0 g) /V (Older) >>\nendobj\n0000000099 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n\(data.count - 30)\n%%EOF\n".utf8)
    }

    /// A download cut off before the cross-reference table: every object is there, nothing says where.
    static func truncated() -> [UInt8] {
        let data = sound()
        guard let r = data.firstRange(of: Array("xref\n".utf8)) else { return data }
        return Array(data[..<r.lowerBound])
    }
}

struct DamagedFormTests {
    private static let damages: [(String, @Sendable () -> [UInt8])] = [
        ("brokenOffsets", { DamagedFile.brokenOffsets(DamagedFile.sound()) }),
        ("staleTail", { DamagedFile.staleTail() }),
        ("truncated", { DamagedFile.truncated() }),
    ]

    private func readable(_ data: [UInt8], value: String) throws {
        let w = try #require(try FormEditor.read(data, nil).first)
        #expect(w.fieldName == "name")
        #expect(w.value == value)
        #expect(try Annotations.read(data, nil).contains { $0.contents == "Check this" })
        #expect(try Bookmarks.read(data, nil).first?.title == "Chapter one")
    }

    @Test func aDamagedFormIsFilledAndKeepsItsFieldsCommentsAndBookmarks() throws {
        for (name, make) in Self.damages {
            let damaged = make()
            try readable(damaged, value: "Ana")
            let filled = try FormEditor.fill(damaged, nil, ["name": "Filled"]).data
            try readable(filled, value: "Filled")
            #expect(try Core2Pdf.allText(filled).contains("Filled"), "\(name)")
            // What is saved is sound: no repair needed the next time, and a second fill keeps everything too.
            let doc = try MuDoc.open(filled)
            #expect(doc.canAppend, "\(name) saved a sound file")
            try readable(try FormEditor.fill(filled, nil, ["name": "Again"]).data, value: "Again")
        }
    }

    /// The bytes of an older copy left after the last good %%EOF never come back as the form's values: a document opens
    /// without them, and what is saved is sound.
    @Test func aStaleTailsOlderValueDoesntComeBack() throws {
        let damaged = DamagedFile.staleTailWithAnOlderField()
        let path = NSTemporaryDirectory() + "stale-\(UUID().uuidString).pdf"
        try Data(damaged).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = try DocumentSession.open(path)
        defer { session.close() }
        try readable(session.data, value: "Ana")
        #expect(session.data == DamagedFile.sound())
        #expect(session.repaired) // the tail held an object: the person is told
        try readable(try FormEditor.fill(session.data, nil, ["name": "Ana2"]).data, value: "Ana2")
    }

    /// Fields, comments and bookmarks compressed in object streams, the file's end cut off: what the repair found is all
    /// in what is saved (MuPDF's writer doesn't read object streams of a repaired file by itself).
    @Test func whatARepairFoundInObjectStreamsIsSaved() throws {
        let compressed = try MuDoc.open(DamagedFile.sound()).write("objstms=yes,compress=yes")
        #expect(PdfBytes.first(Array("/ObjStm".utf8), in: compressed) != nil)
        let cut = Array(compressed.dropLast(64))
        try readable(cut, value: "Ana")
        let filled = try FormEditor.fill(cut, nil, ["name": "Filled"]).data
        try readable(filled, value: "Filled")
        #expect(try MuDoc.open(filled).canAppend)
    }

    /// A signed form whose last revision lost its end (a cut-off download): nothing is read from an older revision while
    /// the view shows the repaired one. Saving needs the rewrite (the signed revision can't be appended to), and keeps the value.
    @Test func aSignedFormCutOffAtTheEndIsFilledFromWhatTheViewShows() throws {
        let signed = SignedEditTests.signed()
        let updated = try FormEditor.fill(signed, nil, ["Name": "Second"]).data
        let cut = Array(updated.dropLast(64))
        #expect(try FormEditor.read(cut, nil).first { $0.fieldName == "Name" }?.value == "Second")
        #expect(throws: SignaturesWouldBreak.self) { try FormEditor.fill(cut, nil, ["Name": "Third"]) }
        let (saved, _) = try SignedEdits.run({ try FormEditor.fill(cut, nil, ["Name": "Third"]).data }, allowRewrite: true)
        #expect(try FormEditor.read(saved, nil).first { $0.fieldName == "Name" }?.value == "Third")
        #expect(try MuDoc.open(saved).canAppend)
    }

    /// Bytes after a signed file's %%EOF with no object in them (a mail gateway's padding, too much for MuPDF to look past):
    /// the update goes right after the file's last revision, its offsets right, the signed bytes as they were.
    @Test func aSignedFormWithPaddingAfterItsEndIsFilledAsAnUpdate() throws {
        let signed = SignedEditTests.signed()
        let padded = signed + [UInt8](repeating: 32, count: 4096)
        let saved = try FormEditor.fill(padded, nil, ["Name": "Padded"]).data
        #expect(Array(saved[..<signed.count]) == signed)
        #expect(try FormEditor.read(saved, nil).first { $0.fieldName == "Name" }?.value == "Padded")
        #expect(try MuDoc.open(saved).canAppend, "the update's offsets are right: no repair")
    }

    /// A stale tail after a signed form: cut as the document opens, when the signature doesn't cover it.
    @Test func aSignedFormsStaleTailIsCutWhenItsSignatureDoesntCoverIt() throws {
        let signed = SignedEditTests.signed()
        let tail = Array("ndobj\n4 0 obj\n<< /Length 0 >>\nendobj\n0000000099 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n\(signed.count - 30)\n%%EOF\n".utf8)
        #expect(PdfRepair.normalize(signed + tail, nil).data == signed)
        #expect(PdfRepair.normalize(signed + tail, nil).repaired) // it held an object
    }

    /// A broken update (it starts as one, its startxref is wrong) is real work: its object is kept, by MuPDF's repair.
    @Test func aBrokenUpdateIsNotCutAsATail() throws {
        let data = DamagedFile.sound()
        let update = "5 0 obj\n<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 0 Tf 0 g) /V (Newer) >>\nendobj\nstartxref\n\(data.count - 30)\n%%EOF\n"
        let updated = data + Array(update.utf8)
        #expect(StaleTail.keepLength(updated) == updated.count)
        try readable(updated, value: "Newer")
    }

    /// A sound file with several revisions, and one whose only startxref is wrong, stay as they are.
    @Test func aSoundFileIsLeftAsItIs() throws {
        let sound = DamagedFile.sound()
        #expect(StaleTail.find(sound) == nil)
        #expect(StaleTail.find(DamagedFile.truncated()) == nil)
        let edited = try FormEditor.fill(sound, nil, ["name": "Twice"]).data
        #expect(StaleTail.find(edited) == nil)
    }
}
