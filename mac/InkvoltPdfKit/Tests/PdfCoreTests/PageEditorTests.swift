import Foundation
import Testing
@testable import PdfCore

/// Ported from PageEditorTests.cs: all 17 tests (with their cases), none left out; errors are `PdfEditError` where .NET
/// throws `InvalidOperationException`.
struct PageEditorTests {
    private static let five = TestPdf.make(5)

    @Test func deletesPages() throws {
        #expect(TestPdf.pageNumbers(try PageEditor.delete(Self.five, nil, [1, 3])) == [1, 3, 5])
    }

    @Test func refusesToDeleteEveryPage() {
        #expect(throws: PdfEditError.self) { try PageEditor.delete(Self.five, nil, [0, 1, 2, 3, 4]) }
    }

    @Test func reordersPages() throws {
        #expect(TestPdf.pageNumbers(try PageEditor.reorder(Self.five, nil, [4, 0, 3, 1, 2])) == [5, 1, 4, 2, 3])
    }

    @Test(arguments: [
        ([3, 4], 0, [4, 5, 1, 2, 3]),
        ([0], 5, [2, 3, 4, 5, 1]),
        ([0, 2], 4, [2, 4, 1, 3, 5]),
        ([1], 1, [1, 2, 3, 4, 5]),
    ])
    func movesPages(pages: [Int], before: Int, expected: [Int]) throws {
        #expect(TestPdf.pageNumbers(try PageEditor.move(Self.five, nil, 5, pages, before)) == expected)
    }

    @Test func reversesPages() throws {
        #expect(TestPdf.pageNumbers(try PageEditor.reverse(Self.five, nil, 5)) == [5, 4, 3, 2, 1])
    }

    @Test func rotatesPages() throws {
        let rotated = try PageEditor.rotate(Self.five, nil, [0], 90)
        let engine = try PdfEngine.open(rotated)
        defer { engine.close() }
        #expect(abs(engine.page(0).width - 792) <= 0.5)
        #expect(abs(engine.page(0).height - 612) <= 0.5)
        #expect(abs(engine.page(1).width - 612) <= 0.5)

        let back = try PageEditor.rotate(rotated, nil, [0], -90)
        let engine2 = try PdfEngine.open(back)
        defer { engine2.close() }
        #expect(abs(engine2.page(0).width - 612) <= 0.5)
    }

    @Test func insertsPagesFromAnotherFile() throws {
        let other = TestPdf.make(3, marker: "beta")
        let result = try PageEditor.insert(Self.five, nil, PdfSource(other, nil, "other.pdf"), [2, 0], 1)
        #expect(TestPdf.pageNumbers(result) == [1, 3, 1, 2, 3, 4, 5])
        let engine = try PdfEngine.open(result)
        defer { engine.close() }
        #expect(try engine.text(1).text.contains("beta"))
        #expect(try engine.text(3).text.contains("alpha"))
    }

    @Test func insertsBlankPages() throws {
        let result = try PageEditor.insertBlank(Self.five, nil, 5, 2, 595, 842)
        #expect(TestPdf.pageNumbers(result) == [1, 2, 3, 4, 5, 0, 0])
        let engine = try PdfEngine.open(result)
        defer { engine.close() }
        #expect(abs(engine.page(6).width - 595) <= 0.5)
        #expect(abs(engine.page(6).height - 842) <= 0.5)
    }

    @Test func duplicatesPages() throws {
        #expect(TestPdf.pageNumbers(try PageEditor.duplicate(Self.five, nil, [0, 2])) == [1, 1, 2, 3, 3, 4, 5])
    }

    @Test func extractsPages() throws {
        #expect(TestPdf.pageNumbers(try PageEditor.extract(Self.five, nil, [3, 1])) == [2, 4])
    }

    @Test func mergesWithBookmarks() throws {
        let merged = try PageEditor.merge([PdfSource(TestPdf.make(2), nil, "a.pdf"), PdfSource(TestPdf.make(3, marker: "beta"), nil, "b.pdf")], true)
        #expect(TestPdf.pageNumbers(merged) == [1, 2, 1, 2, 3])
        let engine = try PdfEngine.open(merged)
        defer { engine.close() }
        let outline = try engine.outline()
        #expect(outline.map(\.title) == ["a", "b"])
        #expect(outline.map(\.pageIndex) == [0, 2])
    }

    @Test func cropsAndUncrops() throws {
        let cropped = try PageEditor.crop(Self.five, nil, [0], Margins(72, 36, 0, 0))
        do {
            let engine = try PdfEngine.open(cropped)
            defer { engine.close() }
            #expect(abs(engine.page(0).width - 540) <= 0.5)
            #expect(abs(engine.page(0).height - 756) <= 0.5)
            // "Page 1" was drawn at x = 72pt; with 72pt cropped off the left it now starts near x = 0.
            let text = try engine.text(0)
            let hit = text.find("Page 1", matchCase: true, wholeWord: false)[0]
            #expect((-2...8).contains(text.rects(hit.start, hit.end)[0].x))
        }
        let restored = try PageEditor.uncrop(cropped, nil, [0])
        let engine2 = try PdfEngine.open(restored)
        defer { engine2.close() }
        #expect(abs(engine2.page(0).width - 612) <= 0.5)
    }

    @Test(arguments: [90, 180, 270])
    func cropMarginsFollowRotation(rotation: Int) throws {
        // Crop 100pt off the visible top of a rotated page: visible height shrinks by 100 and the text moves up 100.
        let rotated = try PageEditor.rotate(Self.five, nil, [0], rotation)
        let before = try PdfEngine.open(rotated)
        defer { before.close() }
        let cropped = try PageEditor.crop(rotated, nil, [0], Margins(0, 100, 0, 0))
        let after = try PdfEngine.open(cropped)
        defer { after.close() }
        #expect(abs(before.page(0).width - after.page(0).width) <= 0.5)
        #expect(abs(before.page(0).height - 100 - after.page(0).height) <= 0.5)

        func locate(_ e: PdfEngine) throws -> RectD {
            let t = try e.text(0)
            let h = t.find("Page 1", matchCase: true, wholeWord: false)[0]
            return t.rects(h.start, h.end)[0]
        }
        let a = try locate(before), b = try locate(after)
        #expect(abs(a.x - b.x) <= 1)
        #expect(abs(a.y - 100 - b.y) <= 1)
    }

    @Test func readsAndWritesMetadata() throws {
        let updated = try PageEditor.writeMetadata(Self.five, nil, "New title", "Me", "Subj", "k1, k2")
        let meta = try PageEditor.readMetadata(updated, nil)
        #expect(meta.title == "New title")
        #expect(meta.author == "Me")
        #expect(meta.keywords == "k1, k2")
    }

    @Test func editsEncryptedDocumentWithOwnerPassword() throws {
        let locked = TestPdf.encrypted(3, "secret")
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(locked) }
        #expect(throws: PasswordRequired(wrongPassword: true)) { try PdfEngine.open(locked, password: "nope") }

        // Editing needs the owner password; the open (user) password alone is refused with a clear message.
        let refused = #expect(throws: OwnerPasswordRequired.self) { try PageEditor.delete(locked, "secret", [0]) }
        #expect(refused?.description.contains("owner") == true)
        let edited = try PageEditor.delete(locked, "secret-owner", [0])
        // The edit keeps the protection: the same open password still opens it.
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(edited) }
        let engine = try PdfEngine.open(edited, password: "secret")
        defer { engine.close() }
        #expect(engine.isEncrypted)
        #expect(engine.pageCount == 2)
        #expect(try engine.text(0).text.contains("Page 2"))
    }

    private func withFile(_ body: (String) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("inkvoltpdf-\(UUID().uuidString).pdf").path
        try Data(Self.five).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    @Test func undoingEveryEditMakesTheSessionCleanAgain() throws {
        try withFile { path in
            let session = try DocumentSession.open(path)
            defer { session.close() }
            try session.commit(try PageEditor.rotate(session.data, nil, [1, 2], 90), "Rotate")
            try session.commit(try PageEditor.delete(session.data, nil, [3]), "Delete")
            try session.undo()
            #expect(session.isDirty)
            try session.undo()
            #expect(!session.isDirty)
            try session.redo()
            #expect(session.isDirty)
        }
    }

    @Test func sessionUndoRedoAndSave() throws {
        try withFile { path in
            let session = try DocumentSession.open(path)
            defer { session.close() }
            try session.commit(try PageEditor.delete(session.data, nil, [0]), "Delete")
            #expect(session.engine.pageCount == 4)
            #expect(session.isDirty)
            try session.undo()
            #expect(session.engine.pageCount == 5)
            #expect(!session.isDirty) // back at the saved state
            try session.redo()
            #expect(session.isDirty)
            #expect(session.engine.pageCount == 4)
            try session.saveAs(path)
            #expect(!session.isDirty)
            #expect(TestPdf.pageNumbers(Array(try Data(contentsOf: URL(fileURLWithPath: path)))) == [2, 3, 4, 5])
        }
    }
}
