import Foundation
import Testing
@testable import PdfCore

/// Ported from ScanTextTests.cs: Recognize Text's pipeline without Vision (roadmap 2.2): a stand-in recognizer "reads"
/// the first line of ink of the image it is given, so the tests see what the engine would be handed (straight, upright,
/// cleaned) and where its words land on the page. Adapted: colour is RGB on the Mac; the layer's font is
/// `GlyphlessFont`, so the content and font counts are read with MuPDF instead of PDFsharp.
struct ScanTextTests {
    /// Returns one word, "Heading", boxed around the topmost line of ink; keeps the image it was given.
    final class FirstLineReader: TextRecognizer, @unchecked Sendable {
        private(set) var seen: GrayImage?
        private(set) var calls = 0

        var language: String? { "en-US" }

        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
            calls += 1
            let (width, height) = (image.width, image.height)
            let gray = ScanCleanup.toGray(image.pixels, width, height)
            seen = GrayImage(width, height, gray)
            func ink(_ y: Int) -> Int { (0..<width).filter { gray[y * width + $0] < 128 }.count }
            guard let top = (0..<height).first(where: { ink($0) > 3 }) else { return [] }
            var bottom = top
            while bottom + 1 < height && ink(bottom + 1) > 0 { bottom += 1 }
            var minX = Int.max, maxX = -1
            for y in top...bottom {
                for x in 0..<width where gray[y * width + x] < 128 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
            return [OcrWord("Heading", RectD(Double(minX), Double(top), Double(maxX - minX + 1), Double(bottom - top + 1)))]
        }
    }

    private static func turnedScan() throws -> [UInt8] {
        var file = ScanCorpus.file("en-turned")
        file.pages = 1
        return try ScanCorpus.make(file).pdf
    }

    private static let blank = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
        Core2Pdf.stream("0.9 g 0 0 10 10 re f"),
    ]

    /// Where search finds `text` on page 0: the union of its boxes.
    private static func found(_ data: [UInt8], _ text: String) throws -> [RectD] {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let page = try engine.text(0)
        return page.find(text, matchCase: true, wholeWord: false).map { hit in page.rects(hit.start, hit.end).reduce(RectD.zero) { $0.isEmpty ? $1 : $0.union($1) } }
    }

    @Test(arguments: [(0.0, 0), (7.5, 0), (-12.0, 1), (3.0, 2), (-4.0, 3)])
    func aPointOfTheCleanedImageMapsBackToTheScan(_ skew: Double, _ turns: Int) {
        let (w, h) = (400, 300)
        var px = [UInt8](repeating: 255, count: w * h)
        for y in 70..<76 {
            for x in 120..<126 { px[y * w + x] = 0 } // a dot centred on (123, 73)
        }
        let straight = PageRotate.rotate(px, w, h, w, 1, -skew)
        let cleaned = ScanCleanup.turn(straight, w, h, 1, turns)
        let cw = turns % 2 == 0 ? w : h
        let dark = cleaned.indices.filter { cleaned[$0] < 128 }
        let dx = Double(dark.reduce(0) { $0 + $1 % cw }) / Double(dark.count) + 0.5
        let dy = Double(dark.reduce(0) { $0 + $1 / cw }) / Double(dark.count) + 0.5

        let (x0, y0) = ScanFrame(width: w, height: h, skew: skew, quarterTurns: turns).toRendered(dx, dy)
        #expect(abs(x0 - 123) <= 1.0 && abs(y0 - 73) <= 1.0, "\(x0), \(y0)")
    }

    @Test(.enabled(if: ScanCorpus.runs)) func anUpsideDownSkewedScanIsReadUprightAndItsWordsLandWhereTheyAre() throws {
        let pdf = try PdfEngine.open(Self.turnedScan())
        defer { pdf.close() }
        let reader = FirstLineReader()
        let page = try ScanText.recognize(pdf, 0, reader, RecognizeOptions(checkWords: false))

        #expect(page.quarterTurns == 2)
        #expect(abs(page.skew - 3.1) <= 0.3, "\(page.skew)")
        #expect(page.cleaned == nil)
        // What the engine was given: straight, upright, white paper.
        let seen = try #require(reader.seen)
        #expect(abs(ScanCleanup.skewOf(seen, 300)) <= 0.3)
        #expect(!Upright.upsideDown(ScanCleanup.downscale(seen, 3)).upsideDown)
        #expect(GrayImage.median(seen, 0, 0, seen.width, seen.height) == 255)

        // The heading is at the top left of the page as written, so at the bottom right of the upside-down scan, upside down.
        try #require(page.words.count == 1)
        let word = page.words[0]
        #expect(word.rect.centerX >= 306 && word.rect.centerX <= 612, "\(word.rect)")
        #expect(word.rect.centerY >= 600 && word.rect.centerY <= 792, "\(word.rect)")
        #expect(abs(word.angle - -176.9) <= 0.3, "\(word.angle)")
        #expect(word.rect.height >= 10 && word.rect.height <= 22) // 16 pt Helvetica-Bold
    }

    @Test(.enabled(if: ScanCorpus.runs)) func thePageAsScannedIsReadAsToday() throws {
        let pdf = try PdfEngine.open(Self.turnedScan())
        defer { pdf.close() }
        let reader = FirstLineReader()
        let page = try ScanText.recognize(pdf, 0, reader, .asScanned)
        #expect(reader.calls == 1)
        #expect(page.quarterTurns == 0 && page.skew == 0)
        try #require(page.words.count == 1)
        #expect(page.words[0].angle == 0)
        #expect(reader.seen?.width == 2550 && reader.seen?.height == 3300) // 300 dpi, as rendered
    }

    @Test(.enabled(if: ScanCorpus.runs)) func theCleanedPageCanReplaceTheScanAndTheWordsFitIt() throws {
        let scan = try Self.turnedScan()
        let pdf = try PdfEngine.open(scan)
        let page = try ScanText.recognize(pdf, 0, FirstLineReader(), RecognizeOptions(checkWords: false, keepCleanedImage: true))
        pdf.close()
        let cleaned = try #require(page.cleaned)
        #expect(cleaned.quarterTurns == 2 && cleaned.channels == 1) // a grey scan stays grey
        try #require(page.words.count == 1)
        let word = page.words[0]
        #expect(word.angle == 0)
        #expect(word.rect.centerY >= 40 && word.rect.centerY <= 100, "\(word.rect)") // on the page as it will be: upright, the heading at the top
        #expect(word.rect.x >= 60 && word.rect.x <= 85, "\(word.rect)")

        var data = try ScanPage.writeBack(scan, nil, [0: cleaned])
        data = try TextLayer.addInvisibleText(data, nil, [0: page.words])
        let after = try PdfEngine.open(data)
        #expect(abs(after.page(0).width - 612) <= 1.0)
        after.close()
        let box = try #require(try Self.found(data, "Heading").first)
        #expect(abs(box.centerX - word.rect.centerX) <= 3.0 && abs(box.centerY - word.rect.centerY) <= 3.0, "\(box) for \(word.rect)")
        // Upright now: the heading's ink is at the top left, and the paper is white.
        let heading = try FormTests.ink(data, word.rect)
        #expect(heading > 0.05)
        #expect(try FormTests.ink(data, RectD(72, 700, 200, 40)) < heading)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aCleanedPageIsHeldCompressedAsItWillBeWritten() throws {
        // Replace the scans holds every page until it writes them: raw, a 500-page Letter colour scan was about 12.6 GB.
        let pdf = try PdfEngine.open(Self.turnedScan())
        defer { pdf.close() }
        let page = try ScanText.recognize(pdf, 0, FirstLineReader(), RecognizeOptions(checkWords: false, keepCleanedImage: true))
        let cleaned = try #require(page.cleaned)
        let raw = cleaned.width * cleaned.height * cleaned.channels
        #expect(cleaned.deflated.count >= 1 && cleaned.deflated.count <= raw / 4)
    }

    @Test func aColourPageWrittenBackKeepsItsColours() throws {
        let scan = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 700 Td (Heading) Tj ET 0.85 0.1 0.1 rg 72 300 200 150 re f 0.1 0.2 0.85 rg 320 300 200 150 re f"),
        ])
        let pdf = try PdfEngine.open(scan)
        let page = try ScanText.recognize(pdf, 0, FirstLineReader(), RecognizeOptions(checkWords: false, keepCleanedImage: true))
        pdf.close()
        let cleaned = try #require(page.cleaned)
        #expect(cleaned.channels == 3)
        let data = try ScanPage.writeBack(scan, nil, [0: cleaned])
        let after = try PdfEngine.open(data)
        defer { after.close() }
        // So few lines may not say which way up: a page set upside down shows the boxes swapped round.
        let flipped = cleaned.quarterTurns == 2
        func at(_ x: Double, _ y: Double) throws -> (r: Int, g: Int, b: Int) {
            let px = try after.render(0, scale: 1, region: flipped ? RectD(612 - x - 4, 792 - y - 4, 4, 4) : RectD(x, y, 4, 4)).pixels // RGB
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
        let red = try at(170, 410)
        let blue = try at(420, 410)
        #expect(red.r > 150 && red.b < 100, "red came out \(red)")
        #expect(blue.b > 150 && blue.r < 100, "blue came out \(blue)")
    }

    @Test func turnedWordsAreFoundWhereTheyWereRead() throws {
        let scan = Core2Pdf.build(Self.blank)
        let words = [
            OcrWord("Straight", RectD(100, 100, 90, 20), angle: 6),
            OcrWord("ahead", RectD(200, 111, 60, 20), angle: 6),
            OcrWord("Upside", RectD(300, 400, 80, 20), angle: -174),
        ]
        let data = try TextLayer.addInvisibleText(scan, nil, [0: words])
        let engine = try PdfEngine.open(data)
        let text = try engine.text(0).text
        engine.close()
        #expect(text.contains("Straight ahead"), "\(text)") // the space between words on a skewed line
        for w in words {
            let hits = try Self.found(data, w.text)
            try #require(hits.count == 1, "\(w.text): \(hits)")
            #expect(abs(hits[0].centerX - w.rect.centerX) <= 3.0 && abs(hits[0].centerY - w.rect.centerY) <= 3.0, "\(w.text): \(hits[0])")
        }
    }

    @Test func aCorrectedWordIsFoundBySearchAndTheLayerIsReplacedInPlace() throws {
        let scan = Core2Pdf.build(Self.blank)
        let words = [
            OcrWord("The", RectD(72, 100, 30, 14), angle: 2.5),
            OcrWord("rlver", RectD(106, 101, 40, 14), angle: 2.5, suspect: [.notInDictionary, .readDifferently]),
            OcrWord("año", RectD(150, 102, 30, 14), angle: 2.5, suspect: .lettersAndDigits),
        ]
        let data = try TextLayer.addInvisibleText(scan, nil, [0: words], language: "es-MX")
        let read = try TextLayer.words(data, nil)
        #expect(read[0]?.words == words) // the words, boxes, angles and suspect reasons come back as written
        #expect(read[0]?.language == "es-MX")

        var corrected = try TextLayer.correct(data, nil, 0, 1, "river")
        corrected = try TextLayer.keep(corrected, nil, 0, 2)
        let after = try #require(try TextLayer.words(corrected, nil)[0])
        #expect(after.words.map(\.text) == ["The", "river", "año"])
        #expect(after.words.allSatisfy { $0.suspect.isEmpty })
        #expect(after.language == "es-MX")
        #expect(try Self.found(corrected, "river").count == 1)
        #expect(try Self.found(corrected, "rlver").isEmpty)
        let engine = try PdfEngine.open(corrected)
        let text = try engine.text(0).text
        engine.close()
        #expect(text.contains("The river año"), "\(text)")

        // One layer, not two: the page's content list and fonts don't grow with each correction.
        func counts(_ pdf: [UInt8]) throws -> (contents: Int, fonts: Int) {
            let doc = try Core2Pdf.open(pdf)
            let page = doc.page(0)
            let contents = page["Contents"].map { $0.isArray ? $0.count : 1 } ?? 0
            return (contents, page.dict("Resources")?.dict("Font")?.keys.count ?? 0)
        }
        let (before, now) = (try counts(data), try counts(corrected))
        #expect(before.contents == now.contents && before.fonts == now.fonts, "\(before) → \(now)")
    }

    @Test(arguments: [
        // what is done, then where "hello" (72,100 100x20 on Letter) is: its centre, size and angle
        ("nothing", 122.0, 110.0, 100.0, 20.0, 0.0),
        ("rotate 90", 682, 122, 100, 20, 90),
        ("rotate 270", 110, 490, 100, 20, -90),
        ("crop", 72, 60, 100, 20, 0),
        ("crop, rotate 180", 470, 662, 100, 20, 180),
    ])
    func wordsStayOnTheirTextWhenThePageIsTurnedOrCropped(_ change: String, _ cx: Double, _ cy: Double, _ w: Double, _ h: Double, _ angle: Double) throws {
        let scan = Core2Pdf.build(Self.blank)
        let words = [OcrWord("hello", RectD(72, 100, 100, 20)), OcrWord("wrld", RectD(176, 100, 60, 20), suspect: .notInDictionary)]
        var data = try TextLayer.addInvisibleText(scan, nil, [0: words], language: "en-US")
        if change.contains("crop") { data = try PageEditor.crop(data, nil, [0], Margins(50, 50, 20, 20)) }
        if change.contains("rotate") { data = try PageEditor.rotate(data, nil, [0], Int(change.suffix(3).trimmingCharacters(in: .whitespaces))!) }

        func assertHello(_ pdf: [UInt8]) throws {
            let hello = try #require(try TextLayer.words(pdf, nil)[0]?.words.first)
            #expect(abs(hello.rect.centerX - cx) <= 1 && abs(hello.rect.centerY - cy) <= 1, "\(change): \(hello.rect)")
            #expect(abs(hello.rect.width - w) <= 1 && abs(hello.rect.height - h) <= 1, "\(change): \(hello.rect)")
            #expect(abs(hello.angle - angle) <= 1, "\(change): \(hello.angle)")
            // Where search finds it: the invisible text written over the word.
            let hits = try Self.found(pdf, "hello")
            try #require(hits.count == 1, "\(change): \(hits)")
            #expect(abs(hits[0].centerX - cx) <= 1 && abs(hits[0].centerY - cy) <= 1, "\(change): found at \(hits[0])")
        }
        try assertHello(data)
        try assertHello(try TextLayer.keep(data, nil, 0, 1))
        try assertHello(try TextLayer.correct(data, nil, 0, 1, "world"))
    }

    @Test func aLayerWrittenWithoutItsFrameIsReadInThePagesFrameNow() throws {
        // As the first 2.2 builds wrote it: no "%f" line. A page not turned or cropped since reads as it always did.
        let scan = Core2Pdf.build(Self.blank)
        let words = [OcrWord("hello", RectD(72, 100, 100, 20), angle: 1.5), OcrWord("wrld", RectD(176, 100, 60, 20), angle: 1.5, suspect: .notInDictionary)]
        var data = try TextLayer.addInvisibleText(scan, nil, [0: words])
        data = try PageEditor.edit(data, nil) { doc in
            let contents = try #require(doc.page(0)["Contents"])
            let layer = try #require(contents.elements.first { $0.streamData?.starts(with: Array("%InkvoltOCR".utf8)) == true })
            let lines = String(decoding: layer.streamData ?? [], as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.filter { $0.hasPrefix("%f ") }.count == 1)
            layer.setStream(Array(lines.filter { !$0.hasPrefix("%f ") }.joined(separator: "\n").utf8), deflate: true)
        }
        #expect(try TextLayer.words(data, nil)[0]?.words == words)
        #expect(try TextLayer.words(try TextLayer.keep(data, nil, 0, 1), nil)[0]?.words.first == words[0])
    }

    @Test func wordsWithBoxesNoPageHasAreLeftOut() throws {
        // A crafted layer: what the suspect words' list and pictures are given is only boxes a page can have.
        let hostile = [
            "%w 1 NaN 100 50 20 0 414243", "%w 1 1e300 1e300 1e300 1e300 0 414243", "%w 1 72 100 50 20 Infinity 414243",
            "%w 99999999999 72 100 50 20 0 414243", "%w 1 72 -Infinity 50 20 0 414243", "%w 1 72 100 50 20 0 6F6B",
        ]
        let scan = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.stream(TextLayer.marker + "\n%f 0 0 0 612 792\n" + hostile.joined(separator: "\n") + "\n"),
        ])
        let read = try #require(try TextLayer.words(scan, nil)[0])
        #expect(read.words == [OcrWord("ok", RectD(72, 100, 50, 20), suspect: .notInDictionary)])
        #expect(try TextLayer.words(try TextLayer.correct(scan, nil, 0, 0, "fine"), nil)[0]?.words.map(\.text) == ["fine"])
    }

    @Test func aPageWithoutAnInkvoltLayerHasNoWordsToReview() throws {
        let data = TestPdf.make(1)
        #expect(try TextLayer.words(data, nil).isEmpty)
        #expect(throws: PdfEditError.self) { try TextLayer.correct(data, nil, 0, 0, "x") }
    }
}
