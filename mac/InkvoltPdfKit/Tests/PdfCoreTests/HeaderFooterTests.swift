import Foundation
import Testing
@testable import PdfCore

/// Ported from HeaderFooterTests.cs (same names). Adapted: TokensExpand uses `HeaderFooter.invariant` for .NET's
/// invariant culture (MM/dd/yyyy, HH:mm); OtherScriptsEmbedOneFontForAllPages counts the Type 3 fonts `TextPainter`
/// embeds here (Windows embeds a Type 0 font); SignedFilesGetItAsAnUpdateThatBreaksTheSignature checks the update is
/// appended (signature verification is E2's).
struct HeaderFooterTests {
    private static let when: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 3, 9, 14, 5)
        return Calendar.current.date(from: c)!
    }()

    private static func expand(_ t: String, page: Int = 3, pages: Int = 12, bates: String? = "ABC000042") -> String {
        HeaderFooter.expand(t, page, pages, bates, "report.pdf", when, locale: HeaderFooter.invariant)
    }

    @Test func tokensExpand() {
        #expect(Self.expand("Page <<page>> of <<pages>>") == "Page 3 of 12")
        #expect(Self.expand("<<date>> <<time>>") == "03/09/2026 14:05")
        #expect(Self.expand("<<date:yyyy-MM-dd>>") == "2026-03-09")
        #expect(Self.expand("<<FILE>> · << bates >>") == "report.pdf · ABC000042")
        // Unknown tokens and stray brackets stay as typed; no Bates format means an empty number.
        #expect(Self.expand("<<chapter>> <<page") == "<<chapter>> <<page")
        #expect(Self.expand("[<<bates>>]", bates: nil) == "[]")
        // A bad date format falls back to the short date instead of failing.
        #expect(Self.expand("<<date:%>>") == "03/09/2026")
    }

    @Test func batesNumbersArePadded() {
        let b = BatesFormat("SMITH-", 41, 6, "-X")
        #expect(b.format(0) == "SMITH-000041-X")
        #expect(b.format(9) == "SMITH-000050-X")
        #expect(BatesFormat("", 1234567, 3).format(0) == "1234567") // more digits than the padding: kept whole
        #expect(BatesFormat("", 7, 0).format(0) == "7") // at least one digit
    }

    @Test func slotsArePlacedInsideTheMargins() {
        var o = HeaderFooterOptions()
        (o.marginTop, o.marginBottom, o.marginLeft, o.marginRight) = (36, 30, 72, 50)
        #expect(HeaderFooter.position(.headerLeft, 100, 612, 792, 9, -2, o) == (72.0, 792 - 36 - 9.0))
        #expect(HeaderFooter.position(.footerCenter, 100, 612, 792, 9, -2, o) == (256.0, 32.0))
        #expect(HeaderFooter.position(.footerRight, 100, 612, 792, 9, -2, o) == (612 - 50 - 100.0, 32.0))
    }

    @Test func writtenAsPageTextWhereItBelongs() throws {
        let pdf = TestPdf.make(3)
        var options = HeaderFooterOptions()
        options.headerCenter = "Quarterly report"
        options.footerRight = "Page <<page>> of <<pages>>"
        options.footerLeft = "<<bates>>"
        options.bates = BatesFormat("ACME", 100, 5)
        let result = try HeaderFooter.apply(pdf, nil, [0, 2], options)

        // Page content, not annotations: the text is there with annotations left out.
        let first = try Core2Pdf.lines(result, page: 0, annotations: false)
        let footer = try #require(first.first { $0.text == "Page 1 of 3" })
        #expect(footer.box.bottom >= 792 - 40 && footer.box.bottom <= 792 - 30) // near the bottom (36 pt margin), page space y down
        #expect(footer.box.right >= 612 - 75 && footer.box.right <= 612 - 70)
        let header = try #require(first.first { $0.text == "Quarterly report" })
        #expect(header.box.y >= 34 && header.box.y <= 40)
        #expect(header.box.centerX >= 300 && header.box.centerX <= 312)
        #expect(first.contains { $0.text == "ACME00100" })

        // Page 2 wasn't in the range; page 3 gets the next Bates number.
        #expect(!(try Core2Pdf.allText(result, page: 1)).contains("Quarterly"))
        let third = try Core2Pdf.allText(result, page: 2, annotations: false)
        #expect(third.contains("Page 3 of 3"))
        #expect(third.contains("ACME00101"))
        // The page's own text is still there.
        #expect(TestPdf.pageNumbers(result) == [1, 2, 3])
        #expect(try HeaderFooter.has(result, nil))
        #expect(!(try HeaderFooter.has(pdf, nil)))
    }

    @Test func followsTheTurnedPage() throws {
        let turned = try PageEditor.rotate(TestPdf.make(1), nil, [0], 90)
        var options = HeaderFooterOptions()
        options.footerCenter = "bottom line"
        let result = try HeaderFooter.apply(turned, nil, [0], options)
        // Shown landscape (792 x 612): the footer sits at the bottom of the page as shown, read left to right.
        let line = try #require(try Core2Pdf.lines(result, page: 0).first { $0.text == "bottom line" })
        #expect(line.box.bottom >= 612 - 40 && line.box.bottom <= 612 - 30)
        #expect(line.box.centerX >= 380 && line.box.centerX <= 412)
        #expect(line.box.width > line.box.height)
    }

    @Test func applyingAgainReplaces() throws {
        var first = HeaderFooterOptions()
        first.headerLeft = "first version"
        var second = HeaderFooterOptions()
        second.headerLeft = "second version"
        let once = try HeaderFooter.apply(TestPdf.make(1), nil, [0], first)
        let twice = try HeaderFooter.apply(once, nil, [0], second)
        let text = try Core2Pdf.allText(twice)
        #expect(!text.contains("first version"))
        #expect(text.contains("second version"))
    }

    @Test func removeTakesOutOnlyWhatWasAdded() throws {
        let pdf = TestPdf.make(2)
        var options = HeaderFooterOptions()
        options.footerCenter = "<<page>>/<<pages>>"
        options.headerRight = "Draft"
        let added = try HeaderFooter.apply(pdf, nil, [0, 1], options)
        let removed = try HeaderFooter.remove(added, nil)
        #expect(!(try Core2Pdf.allText(removed)).contains("Draft"))
        #expect(TestPdf.pageNumbers(removed) == [1, 2])
        #expect(!(try HeaderFooter.has(removed, nil)))
        let doc = try Core2Pdf.open(removed)
        for page in try doc.pages() {
            #expect(!(page.array("Contents")?.elements.contains { $0.isDict && $0.has(PageMarks.key) } ?? false))
            let xobjects = page.dict("Resources")?.dict("XObject")
            #expect(xobjects == nil || xobjects!.keys.allSatisfy { !$0.hasPrefix("Iv") })
        }
        // Nothing to remove: the same bytes back (no undo step).
        #expect(try HeaderFooter.remove(pdf, nil) == pdf)
    }

    @Test func otherScriptsGetAnEmbeddedFont() throws {
        var options = HeaderFooterOptions()
        options.headerCenter = "Отчёт Ω"
        let result = try HeaderFooter.apply(TestPdf.make(1), nil, [0], options)
        #expect(try Core2Pdf.allText(result).contains("Отчёт Ω"))
    }

    @Test func otherScriptsEmbedOneFontForAllPages() throws {
        func type3Fonts(_ pdf: [UInt8]) throws -> Int {
            try Core2Pdf.open(pdf).allObjects().filter { $0.isDict && $0.name("Subtype") == "Type3" }.count
        }
        let pdf = TestPdf.make(50)
        var options = HeaderFooterOptions()
        options.headerCenter = "Отчёт <<page>>"
        options.footerRight = "Ωμέγα <<page>>/<<pages>>"
        let result = try HeaderFooter.apply(pdf, nil, Array(0..<50), options)
        // One set of fonts for every page (the painter builds them once, after the last page), never one per page.
        let fonts = try type3Fonts(result) - type3Fonts(pdf)
        #expect(fonts >= 1 && fonts <= 4)
        // The glyphs of every page: the last page's digits are there too.
        #expect(try Core2Pdf.allText(result, page: 49).contains("Отчёт 50"))
        #expect(try Core2Pdf.allText(result, page: 36).contains("Ωμέγα 37/50"))
    }

    /// A Letter page whose content moves the origin and leaves it so (an unclosed q), or restores more than it saved.
    private static func unbalanced(_ content: String, pageExtra: String = "") -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R \(pageExtra) >>",
            Core2Pdf.stream(content),
        ])
    }

    static let unbalancedContents = [
        "q 1 0 0 1 250 -300 cm 0 0 1 rg 0 0 10 10 re f",
        "q q 0.5 0 0 0.5 0 0 cm (Q) Tj % Q\n0 0 1 rg 0 0 10 10 re f",
        "Q 1 0 0 1 250 -300 cm 0 0 1 rg 0 0 10 10 re f",
        "BI /W 2 /H 1 /CS /G /BPC 8 ID QQ EI q 2 0 0 2 0 0 cm 0 0 1 rg 0 0 10 10 re f",
    ]

    @Test(arguments: unbalancedContents)
    func unbalancedPageContentDoesntMoveTheFooter(_ content: String) throws {
        var options = HeaderFooterOptions()
        options.footerRight = "Page <<page>>"
        options.fontSize = 10
        let result = try HeaderFooter.apply(Self.unbalanced(content), nil, [0], options)
        let footer = try #require(try Core2Pdf.lines(result, page: 0, annotations: false).first { $0.text == "Page 1" })
        #expect(footer.box.bottom >= 792 - 40 && footer.box.bottom <= 792 - 30)
        #expect(footer.box.right >= 612 - 75 && footer.box.right <= 612 - 70)
        #expect(footer.box.height >= 6 && footer.box.height <= 14)
        // Removed again, the page is as it was.
        let doc = try Core2Pdf.open(try HeaderFooter.remove(result, nil))
        let left = try #require(doc.page(0).array("Contents"))
        #expect(left.count == 1)
        #expect(latin1(left[0]?.streamData ?? []) == content)
    }

    @Test func saveDepthSkipsStringsCommentsAndImages() {
        func depth(_ s: String) -> (Int, Int) { PageMarks.saveDepth([Array(s.utf8)]) }
        #expect(depth("q 1 0 0 1 5 5 cm Q") == (0, 0))
        #expect(depth("q (Q\\) Q) Tj <51> Tj % Q Q\n") == (1, 0))
        #expect(depth("Q Q q") == (-1, -2))
        #expect(depth("q BI /W 1 /H 1 ID QQ EI q /Q Do") == (2, 0))
        #expect(PageMarks.saveDepth([[81], [113]]) == (0, -1)) // streams in a row
    }

    @Test func userUnitPagesGetPointSizes() throws {
        // One unit is 2 points: the 612 x 792 unit page is 1224 x 1584 points on paper.
        var options = HeaderFooterOptions()
        options.footerRight = "Page <<page>>"
        options.fontSize = 10
        options.marginBottom = 36
        options.marginRight = 72
        let result = try HeaderFooter.apply(Self.unbalanced("0 0 1 rg 0 0 10 10 re f", pageExtra: "/UserUnit 2"), nil, [0], options)
        let doc = try Core2Pdf.open(result)
        let xobjects = try #require(doc.page(0).dict("Resources")?.dict("XObject"))
        #expect(xobjects.count == 1)
        let form = try #require(xobjects.values.first)
        let bbox = try #require(form.array("BBox"))
        let matrix = try #require(form.array("Matrix"))
        // Drawn in points and scaled by 1/2 into the page's units: a 10 pt footer is 10 pt on paper.
        #expect(abs(bbox.num(2) - 1224) < 1)
        #expect(abs(bbox.num(3) - 1584) < 1)
        #expect(abs(matrix.num(0) - 0.5) < 0.001)
        #expect(abs(matrix.num(3) - 0.5) < 0.001)
    }

    @Test func keepsThePasswordProtection() throws {
        let pdf = TestPdf.encrypted(1, "secret")
        var options = HeaderFooterOptions()
        options.footerCenter = "<<page>>"
        let result = try HeaderFooter.apply(pdf, "secret-owner", [0], options)
        let engine = try PdfEngine.open(result, password: "secret")
        defer { engine.close() }
        #expect(engine.isEncrypted)
        #expect(throws: PdfEditError.self) { try HeaderFooter.apply(TestPdf.make(1), nil, [0], HeaderFooterOptions()) }
    }

    @Test func signedFilesGetItAsAnUpdateThatBreaksTheSignature() throws {
        let signed = SignedEditTests.signed()
        var options = HeaderFooterOptions()
        options.footerCenter = "<<page>>"
        let result = try HeaderFooter.apply(signed, nil, [0], options)
        // Appended after the signed bytes, but a page content change, which no signature allows: the UI warns first.
        #expect(result.count > signed.count && Array(result[0..<signed.count]) == signed)
        #expect(try Core2Pdf.allText(result, page: 0, annotations: false).contains("1"))
    }
}
