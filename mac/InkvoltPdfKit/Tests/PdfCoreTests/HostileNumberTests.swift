import Foundation
import Testing
@testable import PdfCore

/// Numbers from outside (a PDF's content and fonts, comment colors, a preset's values, a zoom) that are NaN, infinite or
/// too big for an Int, where the Mac turned them into an Int: Swift's `Int(x)` traps on those, .NET's cast doesn't, so
/// these have no Windows twin. Each must neither stop the app nor change what an ordinary number does
/// (`mac/tools/check-int.sh` keeps new conversions of a rounded value to the checked form).
struct HostileNumberTests {
    /// 400 nines: more than a Double holds, so the content lexer reads infinity and MuPDF its largest float.
    private static let huge = String(repeating: "9", count: 400)

    @Test func commentColorsThatArentNumbersAreWrittenWithinTheirRange() {
        #expect(CommentFiles.hex([.nan, .infinity, 1e300]) == "#00FFFF")
        #expect(CommentFiles.hex([-.infinity]) == "#000000")
        #expect(CommentFiles.hex([.nan, 0, 0, .infinity]) == "#000000") // CMYK: (1 - NaN) and (1 - infinity)
        #expect(CommentFiles.hex([1, 0.5, 0]) == "#FF8000")
    }

    @Test func aTypewriterCommentWhoseColorIsntANumberIsStillWritten() throws {
        let style = AnnotStyle.typewriter(fontSize: 14, textColor: AnnotColor(.nan, .infinity, 1e300))
        let pdf = try Annotations.addFreeText(TestPdf.make(1), nil, 0, RectD(72, 72, 200, 40), "Typed", style, author: "Ana")
        #expect(try PdfText.everything(pdf).contains("color:#00FFFF"))
    }

    @Test func aWatermarkColorThatIsntANumberIsSavedInAPreset() throws {
        let mark = WatermarkOptions(text: "DRAFT", fontSize: 60, color: AnnotColor(.nan, .infinity, 1e300), opacity: 0.25, rotation: 0,
                                    layout: .tiled, behind: false)
        let json = BatchPresets.write(BatchPreset(name: "Marked", steps: [.watermark(mark)]))
        #expect(json.contains("#00FFFF"))
    }

    @Test func editTextReadsAPageWhoseNumbersOverflow() throws {
        // A render mode no Int holds, and a CMYK fill of infinity with full black: (1 - infinity) × 0 isn't a number.
        let pdf = ContentEditPdf.make("BT /FA 12 Tf \(Self.huge) Tr \(Self.huge) 0 0 1 k 72 700 Td (Hello) Tj ET")
        _ = try ContentEditor.read(pdf, nil, 0)
    }

    @Test func editTextReadsAFontWhoseFirstCodeNoIntHolds() throws {
        let file = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (Hello) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar \(Self.huge) /LastChar 32 /Widths [500] /FontDescriptor << /Type /FontDescriptor /FontName /Helvetica /Flags \(Self.huge) >> >>",
        ])
        _ = try ContentEditor.read(file, nil, 0)
    }

    @Test func lexerSkipsAnInlineImageWhoseSizeNoIntHolds() {
        // /BPC of 1e40: the stated size is no use, so the EI that ordinary content follows ends the data.
        let bpc = "1" + String(repeating: "0", count: 40)
        let ops = ContentLexer.parse(latin1Bytes("BI /W 3 /H 1 /BPC \(bpc) /CS /RGB ID abc\nEI Q"))
        #expect(ops.map(\.name) == ["BI", "Q"])
    }

    @Test func exportJoinsLinesPlacedWhereNoIntReaches() {
        func line(_ text: String, _ y: Double) -> ExportLine {
            ExportLine([ExportSpan(text, "Helvetica", 12, false, false, 0, RectD(72, y, 40, 12))], RectD(72, y, 40, 12))
        }
        let merged = DocLayout.mergeRows([line("far", 1e300), line("lost", .nan), line("down", -.infinity), line("here", 700)], [])
        #expect(merged.contains { $0.text == "here" })
    }

    @Test func exportShapesReadAPointThatIsntANumber() {
        var rgba = [UInt8](repeating: 0, count: 2 * 2 * 4)
        rgba[12...15] = [9, 8, 7, 255] // the bottom-right pixel
        let raster = ExportShapes.Raster(rgba: rgba, width: 2, height: 2, scale: 1)
        _ = raster.at(.nan, .infinity)
        let far = raster.at(1e300, 1e300), before = raster.at(-1e300, -.infinity)
        let (farPixel, beforePixel): ([Int], [Int]) = ([far.r, far.g, far.b, far.a], [before.r, before.g, before.b, before.a])
        #expect(farPixel == [9, 8, 7, 255])
        #expect(beforePixel == [0, 0, 0, 0])
    }

    @Test func officeUnitsOfNumbersNoIntHoldsAreWritten() {
        #expect(OpenXmlParts.twips(.nan) == "0")
        #expect(OpenXmlParts.emu(.infinity) == "1000000000000000")
        #expect(OpenXmlParts.twips(-1e300) == "-1000000000000000")
        #expect(OpenXmlParts.twips(12.5) == "250")
        #expect(bankersInt(2.5) == 2)
    }

    @Test func renderingAtAZoomThatIsntANumberIsRefused() throws {
        let engine = try PdfEngine.open(TestPdf.make(1))
        defer { engine.close() }
        for scale in [Double.infinity, .nan, 1e300] {
            let refused = #expect(throws: PdfEngineError.self) { try engine.render(0, scale: scale) }
            #expect(refused?.message == "The image would be too large. Use a lower zoom or resolution.", "\(scale)")
        }
        let large = #expect(throws: PdfEngineError.self) { try engine.render(0, scale: 1e6) }
        #expect(large?.message.contains(" pixels)") == true) // a size an Int holds is shown
    }

    @Test func aPosterOfAPageThatIsntANumberIsOneSheetAndOfAHugeOneAtMostTheMost() {
        let letter = RectD(24, 24, 768, 1008)
        let t = PrintLayout.posterTiles(.nan, .infinity, 2, letter.width, letter.height, 18)
        #expect(t.cols == 1 && t.rows == PrintLayout.maxPosterTiles)
        let big = PrintLayout.posterTiles(1e300, 1e300, 2, letter.width, letter.height, 18)
        #expect(big.cols == PrintLayout.maxPosterTiles && big.rows == PrintLayout.maxPosterTiles)
    }

    @Test func redactingAnAreaThatIsntANumberBlacksOutToThePagesEdge() throws {
        let areas = [RectD(.nan, 0, 10, 10), RectD(0, 0, .infinity, 1e300), RectD(-1e300, 100, 2e300, 20)]
        let out = try Redaction.apply(TestPdf.make(1), nil, [0: areas], dpi: 72)
        let engine = try PdfEngine.open(out)
        defer { engine.close() }
        let img = try engine.render(0, scale: 1)
        #expect(img.pixels.allSatisfy { $0 == 0 }) // the second area covers the page
    }

    @Test func theRedactionCheckFindsNoPixelsUnderABoxThatIsntANumber() {
        let img = RenderedImage(4, 4, [UInt8](repeating: 0, count: 4 * 4 * 3))
        #expect(RedactionCheck.Check.uniformColor(img, RectD(.nan, 0, 1, 1), 1, RectD(0, 0, 0, 0), inner: false) == nil)
        #expect(RedactionCheck.Check.uniformColor(img, RectD(0, 0, .infinity, 1), 1, RectD(0, 0, 0, 0), inner: true) == nil)
        let all = RedactionCheck.Check.uniformColor(img, RectD(-1e300, -1e300, 2e300, 2e300), 1, RectD(0, 0, 0, 0), inner: false)
        let allPixel: [Int]? = all.map { [$0.0, $0.1, $0.2] }
        #expect(allPixel == [0, 0, 0])
    }

    @Test func aFieldFontSizeThatIsntANumberReadsAuto() {
        #expect(FormDesignRules.sizeText(.infinity) == "Auto")
        #expect(FormDesignRules.sizeText(.nan) == "Auto")
        #expect(FormDesignRules.sizeText(1e300) == "1e+300")
        #expect(FormDesignRules.sizeText(12) == "12")
        #expect(FormDesignRules.sizeText(10.5) == "10.5")
    }

    @Test func aScanTurnedByAnAngleThatIsntANumberComesBackBlank() {
        let gray = [UInt8](repeating: 0, count: 8 * 6)
        let turned = PageRotate.rotate(gray, 8, 6, 8, 1, .nan)
        #expect(turned.count == gray.count)
    }
}
