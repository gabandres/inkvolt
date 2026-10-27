import Foundation
import Testing
@testable import PdfCore

/// Ported from EngineTests.cs. Left out: RunningOutOfMemoryWhileOpeningLeavesTheDocumentUnusableNotTheProcess (it tests
/// a workaround for MuPDFCore's finalizers; here MuPDF's out-of-memory error comes back through the shim like any
/// other). Adapted: AFileMuPdfCantOpenDoesntCrashTheProcessLater keeps its engine part (`PdfSecurity` comes with D2,
/// `ImageImport` with D3); DisposedEnginesLeaveNothingForTheFinalizer closes its engines instead of disposing them.
struct EngineTests {
    @Test func aFileMuPdfCantOpenDoesntCrashTheProcessLater() {
        let junk = Array("%PDF-1.7\nthis is not a pdf at all".utf8)
        #expect(throws: (any Error).self) { try PdfEngine.open(junk).close() }
    }

    @Test func rendersPageAtScale() throws {
        let engine = try PdfEngine.open(TestPdf.make(2))
        defer { engine.close() }
        #expect(engine.pageCount == 2)
        let g = engine.page(0)
        #expect(abs(g.width - 612) <= 0.5)
        #expect(abs(g.height - 792) <= 0.5)

        let img = try engine.render(0, scale: 0.5)
        #expect(abs(img.width - 306) <= 1)
        #expect(abs(img.height - 396) <= 1)
        #expect(img.pixels.count == img.width * img.height * 3)
        #expect(img.pixels[0] == 255) // white background at the corner
        #expect(img.pixels.contains { $0 < 64 }) // some dark text pixels
    }

    @Test func rendersRegion() throws {
        let engine = try PdfEngine.open(TestPdf.make(1))
        defer { engine.close() }
        let img = try engine.render(0, scale: 2, region: RectD(100, 100, 50, 25))
        #expect(abs(img.width - 100) <= 1)
        #expect(abs(img.height - 50) <= 1)
    }

    @Test func extractsTextWithBoxesAndFinds() throws {
        let engine = try PdfEngine.open(TestPdf.make(3))
        defer { engine.close() }
        let text = try engine.text(1)
        #expect(text.text.contains("Page 2 alpha"))

        let hits = text.find("QUICK brown", matchCase: false, wholeWord: true)
        try #require(hits.count == 1)
        let rects = text.rects(hits[0].start, hits[0].end)
        try #require(rects.count == 1)
        #expect((100...125).contains(rects[0].x)) // "The " starts at x = 72pt, so "quick" sits near 112pt
        #expect((110...145).contains(rects[0].y)) // baseline at y = 140pt, top-down

        // Whitespace in the query spans line breaks.
        #expect(text.find("fox jumps", matchCase: false, wholeWord: false).count == 1)
        #expect(text.find("QUICK", matchCase: true, wholeWord: false).isEmpty)
        #expect(text.find("qui", matchCase: false, wholeWord: true).isEmpty)

        let caret = text.hitTest(rects[0].x + 1, rects[0].centerY)
        #expect(caret == hits[0].start)
        let word = text.wordAt(caret + 1)
        #expect(text.string(word.start, word.end) == "quick")
    }

    @Test func closedEnginesAndWrongPasswords() throws {
        for _ in 0..<3 {
            let engine = try PdfEngine.open(TestPdf.make(4))
            _ = try engine.render(1, scale: 0.3)
            _ = try engine.text(2)
            _ = try engine.links(3)
            _ = try engine.outline()
            engine.close()
        }
        #expect(throws: PasswordRequired(wrongPassword: false)) { try PdfEngine.open(TestPdf.encrypted(2, "pw")) }
        #expect(throws: PasswordRequired(wrongPassword: true)) { try PdfEngine.open(TestPdf.encrypted(2, "pw"), password: "wrong") }
    }

    @Test func unencryptedDocumentIgnoresPassword() throws {
        let engine = try PdfEngine.open(TestPdf.make(1), password: "whatever")
        defer { engine.close() }
        #expect(!engine.isEncrypted)
    }
}
