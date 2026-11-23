import Foundation
import Testing
@testable import PdfCore

/// Ported from HeadingBookmarksTests.cs (roadmap 4.5), all 7 tests, same names: DocLayout's headings, nested by level,
/// written through Bookmarks. Adapted: the report is written by hand in Helvetica (Windows draws it in Arial with
/// PDFsharp); the signed file is `IncrSignatureTests.signedForm(twoPages:)`, signed for real, so its status is verified as
/// on Windows; titles are measured in UTF-16 units, as .NET's `Length`; the progress is a closure.
struct HeadingBookmarksTests {
    private static let body = "This paragraph is ordinary body text set at eleven points, long enough to tell the body size."

    /// Three pages: "Chapter One" (24 pt) and "Background" (16 pt) with body text on page 1, "Method" (16 pt) on page 2,
    /// "Chapter Two" (24 pt) on page 3; each page also has a small running header that repeats.
    static func report() -> [UInt8] {
        let big = ("F2", 24.0), mid = ("F2", 16.0), small = ("F1", 11.0)
        let pages: [[(String, (String, Double))]] = [
            [("Chapter One", big), (body, small), (body, small), ("Background", mid), (body, small), (body, small)],
            [(body, small), ("Method", mid), (body, small), (body, small)],
            [("Chapter Two", big), (body, small), (body, small), (body, small)],
        ]
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\((0..<pages.count).map { "\(5 + $0 * 2) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
        ]
        for (i, lines) in pages.enumerated() {
            // The running header in grey at 40 pt from the top; then the lines, baselines from 100 pt down, as Windows draws them.
            var content = "BT 0.5 g /F1 9 Tf 72 752 Td (Annual report) Tj ET\n"
            var y = 100.0
            for (text, (font, size)) in lines {
                content += "BT 0 g /\(font) \(size) Tf 72 \(792 - y) Td (\(text)) Tj ET\n"
                y += size * 2.2
            }
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents \(6 + i * 2) 0 R >>")
            objects.append(Core2Pdf.stream(content))
        }
        return Core2Pdf.build(objects)
    }

    private static func find(_ pdf: [UInt8]) throws -> [FoundHeading] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try HeadingBookmarks.find(engine)
    }

    @Test func findsTheHeadingsByTheirSize_NotTheRunningHeader() throws {
        let found = try Self.find(Self.report())
        #expect(found.map { "\($0.title)|\($0.level)|\($0.pageIndex)" } == ["Chapter One|1|0", "Background|2|0", "Method|2|1", "Chapter Two|1|2"])
        #expect(found.count == 4 && found[0].top >= 70 && found[0].top <= 100) // the line's top, from the page's top
        #expect(found.count == 4 && found[1].top > found[0].top)
    }

    @Test func nestsByLevel_ASkippedLevelNestingOneStep() {
        func h(_ t: String, _ level: Int) -> FoundHeading { FoundHeading(t, level, 0, 0) }
        let tree = HeadingBookmarks.tree([h("A", 1), h("A.1.1", 3), h("A.2", 2), h("A.2.1", 3), h("B", 1), h("Lead-in", 2)])
        #expect(tree.map(\.title) == ["A", "B"])
        #expect(tree[0].children.map(\.title) == ["A.1.1", "A.2"])
        #expect(tree[0].children[1].children.map(\.title) == ["A.2.1"])
        #expect(tree[0].open)
        #expect(!tree[0].children[1].open)
        #expect(HeadingBookmarks.tree([h("A", 1), h("A.1.1", 3), h("B", 1)], deepest: 1).map(\.title) == ["A", "B"])
        #expect(HeadingBookmarks.tree([h("A.1", 2)], deepest: 1).isEmpty)
    }

    @Test func replacesTheBookmarks_OrAddsAfterThem() throws {
        let pdf = try Bookmarks.setOutline(Self.report(), nil, [Bookmark("Cover", 0)])
        let headings = try Self.find(pdf)

        let replaced = try Bookmarks.read(HeadingBookmarks.write(pdf, nil, headings, replace: true), nil)
        #expect(replaced.map(\.title) == ["Chapter One", "Chapter Two"])
        try #require(replaced.count == 2)
        #expect(replaced[0].children.map(\.title) == ["Background", "Method"])
        #expect(replaced[0].children.map(\.pageIndex) == [0, 1])
        #expect(replaced[1].pageIndex == 2)
        #expect(replaced[0].children.first?.top != nil)

        let added = try Bookmarks.read(HeadingBookmarks.write(pdf, nil, headings, replace: false, deepest: 1), nil)
        #expect(added.map(\.title) == ["Cover", "Chapter One", "Chapter Two"])
        #expect(added.allSatisfy { $0.children.isEmpty })
    }

    @Test func titlesAreOneLine_AndBounded() {
        #expect(HeadingBookmarks.title("  Part 2\n\tResults\u{7} ") == "Part 2 Results")
        let long = HeadingBookmarks.title(Array(repeating: "word", count: 100).joined(separator: " "))
        #expect(long.utf16.count == HeadingBookmarks.maxTitle)
        #expect(long.hasSuffix("…"))
    }

    @Test func aSignedFileGetsThemAsAnAppendedChange() throws {
        let signed = try IncrSignatureTests.signedForm(twoPages: true)
        let (edited, report) = try SignedEdits.run { try HeadingBookmarks.write(signed, nil, [FoundHeading("Contract", 1, 0, 72)], replace: true) }
        #expect(report.appended)
        #expect(Array(edited.prefix(signed.count)) == signed)
        #expect(Signatures.verify(edited).first { $0.fieldName == "Approval" }?.status == .modifiedAfterSigning)
        #expect(try Bookmarks.read(edited, nil).map(\.title) == ["Contract"])
    }

    @Test func aLongTitleIsNeverCutInsideACharacter() {
        // An emoji (a surrogate pair) and an e with a combining accent where the cut falls.
        for tail in ["😀😀😀", "e\u{301}e\u{301}e\u{301}"] {
            let title = HeadingBookmarks.title(String(repeating: "a", count: HeadingBookmarks.maxTitle - 2) + tail)
            #expect(title.hasSuffix("…"))
            #expect(title.utf16.count <= HeadingBookmarks.maxTitle)
            #expect(!title.unicodeScalars.contains("\u{FFFD}"))
            let units = Array(title.utf16)
            #expect(units[units.count - 2] != 0x301, "\(title)") // an accent never stands without its letter
            #expect(String(decoding: units, as: UTF16.self) == title) // whole scalars only (no lone surrogate)
        }
    }

    @Test func theSearchSaysHowFarItIs_AndStopsWhenAsked() throws {
        let engine = try PdfEngine.open(Self.report())
        defer { engine.close() }
        var seen: [[Int]] = []
        _ = try HeadingBookmarks.find(engine, progress: { seen.append([$0, $1]) })
        #expect(seen == [[0, 3], [1, 3], [2, 3]])
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try HeadingBookmarks.find(engine, cancel: cancel) }
    }
}
