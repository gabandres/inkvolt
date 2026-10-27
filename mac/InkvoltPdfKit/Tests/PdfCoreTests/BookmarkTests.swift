import Foundation
import Testing
@testable import PdfCore

/// Ported from BookmarkTests.cs: all 4 tests. The outline objects are read through MuPDF (`Core2Pdf.open`) where
/// Windows reads them with PDFsharp. Adapted: a bookmark leading to a missing page throws `PdfEditError` (.NET's
/// `ArgumentOutOfRangeException`). Left out of SignedFilesGetAnIncrementalUpdate: its signature verification
/// (`Signatures.Verify`, a later step); the signed bytes are checked to stay the file's first bytes instead.
struct BookmarkTests {
    private func muPdfOutline(_ pdf: [UInt8]) throws -> [OutlineNode] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try engine.outline()
    }

    private func tree() -> Bookmark {
        var a = Bookmark("Chapter A", 1, top: 200)
        a.italic = true
        var part = Bookmark("Part 1", 0, children: [a, Bookmark("Chapter B", 2, children: [Bookmark("Section B.1", 2, top: 400)])])
        part.open = true
        part.bold = true
        part.color = AnnotColor(1, 0, 0)
        return part
    }

    private func with(_ b: Bookmark, _ change: (inout Bookmark) -> Void) -> Bookmark {
        var b = b
        change(&b)
        return b
    }

    @Test func writesANestedTreeAndReadsItBack() throws {
        let pdf = try Bookmarks.setOutline(TestPdf.make(3), nil, [tree(), Bookmark("Heading only")])
        let read = try Bookmarks.read(pdf, nil)
        #expect(read.map(\.title) == ["Part 1", "Heading only"])
        let part = read[0]
        #expect(part.open && part.bold && !part.italic)
        #expect(part.color == AnnotColor(1, 0, 0))
        #expect(part.pageIndex == 0)
        #expect(part.children.map(\.title) == ["Chapter A", "Chapter B"])
        #expect(part.children[0].italic)
        #expect(part.children[0].pageIndex == 1)
        #expect(abs(try #require(part.children[0].top) - 200) <= 1)
        #expect(!part.children[1].open)
        #expect(abs(try #require(part.children[1].children[0].top) - 400) <= 1)
        #expect(read[1].pageIndex == -1)

        // /Count: the open Part 1 shows its 2 children (B is closed: its child counts negative); the root counts 4 visible.
        let doc = try Core2Pdf.open(pdf)
        let root = try #require(doc.catalog.dict("Outlines"))
        #expect(root.int("Count") == 4)
        let first = try #require(root.dict("First"))
        #expect(first.int("Count") == 2)
        #expect(first.dict("Last")?.int("Count") == -1)

        // MuPDF sees the same tree.
        let mu = try muPdfOutline(pdf)
        #expect(mu.map(\.title) == ["Part 1", "Heading only"])
        #expect(mu[0].children.map(\.title) == ["Chapter A", "Chapter B"])
        #expect(mu[0].children[0].pageIndex == 1)
        #expect(mu[0].children[1].children[0].title == "Section B.1")
        #expect(mu[0].children[1].children[0].pageIndex == 2)
    }

    @Test func renamesDeletesReordersAndNests() throws {
        let pdf = try Bookmarks.setOutline(TestPdf.make(3), nil, [tree()])
        let part = try Bookmarks.read(pdf, nil)[0]
        let a = part.children[0]
        let b = part.children[1]
        // B moves to the top level before Part 1 and is renamed; A moves under B; B.1 is deleted.
        let edited = try Bookmarks.setOutline(pdf, nil, [
            with(b) {
                $0.title = "Chapter Bee"
                $0.children = [a]
                $0.open = true
            },
            with(part) { $0.children = [] },
        ])
        let read = try Bookmarks.read(edited, nil)
        #expect(read.map(\.title) == ["Chapter Bee", "Part 1"])
        #expect(read[0].children.map(\.title) == ["Chapter A"])
        #expect(abs(try #require(read[0].children[0].top) - 200) <= 1)
        #expect(read[1].children.isEmpty)
        #expect(try muPdfOutline(edited).map(\.title) == ["Chapter Bee", "Part 1"])

        // Retargeting rewrites the destination.
        let moved = try Bookmarks.setOutline(edited, nil, [with(read[0]) {
            $0.pageIndex = 0
            $0.top = 100
        }, read[1]])
        #expect(try Bookmarks.read(moved, nil)[0].pageIndex == 0)
        #expect(abs(try #require(try Bookmarks.read(moved, nil)[0].top) - 100) <= 1)

        // An empty outline removes it.
        let none = try Bookmarks.setOutline(moved, nil, [])
        #expect(try Bookmarks.read(none, nil).isEmpty)
        #expect(throws: PdfEditError.self) { try Bookmarks.setOutline(none, nil, [Bookmark("x", 9)]) }
    }

    @Test func keepsOtherActionsWhenUnchanged() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Outlines /First 5 0 R /Last 6 0 R /Count 2 >>",
            "<< /Title (Web) /Parent 4 0 R /Next 6 0 R /A << /S /URI /URI (https://example.com/) >> >>",
            "<< /Title (Go) /Parent 4 0 R /Prev 5 0 R /A << /S /GoTo /D [3 0 R /FitH 700] >> >>",
        ])
        let read = try Bookmarks.read(pdf, nil)
        #expect(read[0].actionKind == "URI")
        #expect(read[0].uri == "https://example.com/")
        #expect(read[1].pageIndex == 0)

        let edited = try Bookmarks.setOutline(pdf, nil, [with(read[1]) { $0.title = "Go there" }, with(read[0]) { $0.bold = true }])
        let doc = try Core2Pdf.open(edited)
        let first = try #require(doc.catalog.dict("Outlines")?.dict("First"))
        #expect(first.text("Title") == "Go there")
        #expect(first.dict("A")?.array("D")?[1]?.name == "FitH")
        let second = try #require(first.dict("Next"))
        #expect(second.dict("A")?.text("URI") == "https://example.com/")
        #expect(second.int("F") == 2)
    }

    @Test func signedFilesGetAnIncrementalUpdate() throws {
        let signed = SignedEditTests.signed()
        let (edited, report) = try SignedEdits.run {
            try Bookmarks.setOutline(signed, nil, [Bookmark("Contract", 0, children: [Bookmark("Page two", 1)])])
        }
        #expect(report.appended)
        #expect(Array(edited.prefix(signed.count)) == signed)
        #expect(try muPdfOutline(edited).map(\.title) == ["Contract"])

        let renamed = try Bookmarks.setOutline(edited, nil, [with(try Bookmarks.read(edited, nil)[0]) { $0.title = "Agreement" }])
        #expect(Array(renamed.prefix(signed.count)) == signed)
        #expect(try Bookmarks.read(renamed, nil)[0].title == "Agreement")
        #expect(try Bookmarks.read(renamed, nil)[0].children[0].title == "Page two")
    }
}
