import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import PrintCore
import Testing
@testable import PrintMac

/// PrintMac's page and photo drawing: scanned pages turned, cropped and straightened, searchable PDFs, photo sheets. One at
/// a time, the work on `offPool`: it's seconds of CPU, and on a small CI runner it starved the IPP timing tests beside it.
@Suite(.serialized)
struct MacImagingTests {
    private static func cgImage(_ jpeg: [UInt8]) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(Data(jpeg) as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func aTurnedPageSwapsItsSidesAndACropKeepsItsShare() async throws {
        let (page, turned, cropped, same) = try await offPool { () -> Result<([UInt8], (Int, Int), (Int, Int), Bool), any Error> in
            Result {
                let page = DemoScanPage.jpeg(0, width: 2550, height: 3300) // 1275 × 1650 px
                let turned = try ScanImaging.render(page, PageEdits(quarterTurns: 1))
                let cropped = try ScanImaging.render(page, PageEdits(crop: CropBox(0, 0, 0.5, 0.5)))
                return (page, (turned.width, turned.height), (cropped.width, cropped.height), try ScanImaging.jpeg(page, .none) == page)
            }
        }.get()
        #expect(!page.isEmpty)
        #expect(turned == (1650, 1275))
        #expect(abs(cropped.0 - 638) <= 1 && abs(cropped.1 - 825) <= 1)
        #expect(same) // unedited: the scanner's own bytes
    }

    @Test func aCrookedPageIsStraightenedToWithinHalfADegree() async throws {
        let (skew, after, blank) = try await offPool { () -> Result<(Double, Double, Bool), any Error> in
            Result {
                let crooked = DemoScanPage.jpeg(1, width: 2550, height: 3300)
                let skew = Deskew.angle(try ScanImaging.analysis(crooked))
                let after = Deskew.angle(try ScanImaging.analysis(ScanImaging.jpeg(crooked, PageEdits(deskew: skew))))
                return (skew, after, BlankPage.isBlank(try ScanImaging.analysis(DemoScanPage.jpeg(2, width: 2550, height: 3300))))
            }
        }.get()
        #expect(abs(skew) > 1.5)
        #expect(abs(after) < 0.5)
        #expect(blank)
    }

    /// The words are given, not Vision's: what this checks is ScanPdf's page and its invisible text, and Vision compiling its
    /// model first (below) made it fail.
    @Test func aSearchablePdfHasEachPageAtItsSizeWithItsWords() async throws {
        let words = [OcrWord(text: "demo", box: CGRect(x: 0.40, y: 0.80, width: 0.06, height: 0.012)),
                     OcrWord(text: "scanner", box: CGRect(x: 0.47, y: 0.80, width: 0.09, height: 0.012))]
        let data = try await offPool { () -> Result<Data, any Error> in
            Result {
                let page = DemoScanPage.jpeg(0, width: 2550, height: 3300)
                return try ScanPdf.write([ScanPdf.Page(jpeg: page, dpi: 150, words: words), ScanPdf.Page(jpeg: page, dpi: 150)])
            }
        }.get()
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 612) < 1 && abs(box.height - 792) < 1) // 8.5 × 11 in
        let first: String = pdf.page(at: 0)?.string ?? "", second: String = pdf.page(at: 1)?.string ?? ""
        #expect(first.contains("demo scanner"), "\(first)")
        #expect(second.isEmpty)
        // Where it was put: the words' box on the page, in points from the bottom left.
        let page = try #require(pdf.page(at: 0))
        let found = try #require(page.selection(for: NSRange(location: 0, length: 4))).bounds(for: page)
        #expect(abs(found.minX - 0.40 * 612) < 6 && abs(found.minY - 0.80 * 792) < 6, "\(found)")
    }

    /// Vision reads the demo page's words. Why it failed on ignia-mac (2026-11-05, five runs, alone and in the full run, on
    /// master too): when the system has no compiled copy of Vision's text model for this process (the log's "Attempting to
    /// compile E5 model", "E5BundleCache Lookup … exists=0"), aned has ANECompilerService compile it for the Neural Engine
    /// first, 50 to 57 s here, and Vision then gave no words (three times) or the right ones (once). With the compiled copy
    /// it takes under 1 s, also with a load average of 26. So no words after that long is the system compiling, a known
    /// intermittent issue; no words after a short wait, or the wrong words, still fail.
    @Test func visionReadsTheDemoPagesWords() async throws {
        let page = DemoScanPage.jpeg(0, width: 2550, height: 3300)
        let clock = ContinuousClock()
        let started = clock.now
        let words = await offPool { ScanPdf.recognize(page) }
        let took = clock.now - started
        let text = (words ?? []).map(\.text).joined(separator: " ")
        if text.isEmpty, took > .seconds(20) {
            withKnownIssue("Vision gave \(words == nil ? "an error" : "no words") after \(took): the system's recogniser stalled", isIntermittent: true) {
                Issue.record("No words after \(took)")
            }
            return
        }
        #expect(text.contains("demo scanner"), "after \(took): \(text)")
    }

    /// Scanners that only give PDF (roadmap 1.3): a page that isn't one JPEG picture (here a turned one) is drawn by PDFKit at
    /// the scan's resolution, as it shows, and remembered as rendered; the scanner's text-layer pages too.
    @Test func aScannersPdfPageThatIsntOneJpegIsDrawnAtTheScansResolution() async throws {
        let page = DemoScanPage.jpeg(0, width: 2550, height: 3300) // 1275 × 1650 px, letter at 150 dpi
        let flat = ScannerPdf.write([(page, 150, nil)])
        let text = try #require(String(data: Data(flat), encoding: .isoLatin1)) // one character per byte, the JPEG kept
        let turned = [UInt8](try #require(text.replacingOccurrences(of: "/Type /Page /Parent", with: "/Type /Page /Rotate 90 /Parent")
            .data(using: .isoLatin1)))
        #expect(turned.count == flat.count + 11 && ScannerPdf.jpegPages(turned) == nil)

        let drawn = try await ScannedPdfPages().render(turned, dpi: 100)
        try #require(drawn.count == 1)
        let size = try #require(ScanImaging.size(drawn[0]))
        #expect(size.width == 1100 && size.height == 850) // 11 × 8.5 in at 100 dpi: turned

        ScannerPdf.renderer = ScannedPdfPages()
        defer { ScannerPdf.renderer = nil }
        let pages = try await ScannerPdf.pages(turned, dpi: 100)
        #expect(pages.count == 1 && ScannerPdf.origin(of: pages[0])?.rendered == true)
        await #expect(throws: ScanError.self) { try await ScannedPdfPages().render(Array("%PDF-1.4 not really".utf8), dpi: 100) }
    }

    @Test func photoSheetsArePagesAtThePapersSize() async throws {
        let photo = try Self.cgImage(DemoScanPage.jpeg(0, width: 1800, height: 1200))
        let inputs = [PhotoInput(Double(photo.width), Double(photo.height), 3, .none)]
        let paper = SheetPaper(8.5, 11, 0.25, 0.25, 0.25, 0.25)
        let sheets = PhotoLayout.sheets(inputs, PhotoLayoutOptions(kind: .printSize, size: PhotoSizes.in4x6), paper)
        #expect(!sheets.isEmpty)
        let data = try await offPool { Result { try PhotoSheets.pdf(sheets, photos: [photo], names: ["photo.jpg"], paper: paper) } }.get()
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == sheets.count)
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(box.width - 612) < 1 && abs(box.height - 792) < 1)
        #expect(PhotoSheets.preview(sheets[0], photos: [photo], names: ["photo.jpg"], paper: paper, width: 200)?.width == 200)
    }

    // MARK: Clean up (roadmap 2.3): ScanImaging decodes, PrintCore's PageCleanup cleans, ScanImaging encodes

    /// A page drawn for the clean up: `paper` grey (0 to 1) with dark lines of "text", on a lid of `lid` grey around it
    /// (`margin` inches; 0: none), at 150 dpi, letter. `grey`: a one-channel JPEG, as a grey scan comes.
    static func cleanupPage(paper: CGFloat, lid: CGFloat = 0, margin: CGFloat = 0, grey: Bool = false) throws -> [UInt8] {
        let (w, h) = (1275, 1650)
        let space = grey ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info))
        context.setFillColor(CGColor(gray: lid, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let sheet = CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: margin * 150, dy: margin * 150)
        context.setFillColor(CGColor(gray: paper, alpha: 1))
        context.fill(sheet)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for i in 0..<20 { context.fill(CGRect(x: sheet.minX + 150, y: sheet.maxY - 200 - CGFloat(i) * 50, width: sheet.width - 300, height: 12)) }
        return try ScanImaging.jpeg(try #require(context.makeImage()))
    }

    /// The level of the pixel at (x, y) from the top left of a decoded page, as grey.
    static func level(_ jpeg: [UInt8], x: Int, y: Int) throws -> Int {
        let gray = try ScanImaging.analysis(jpeg) // at most 1100 px: positions as fractions of the full page
        let full = try #require(ScanImaging.size(jpeg))
        let gx = min(gray.width - 1, x * gray.width / full.width), gy = min(gray.height - 1, y * gray.height / full.height)
        return Int(gray.pixels[gy * gray.width + gx])
    }

    @Test func aWhitenedPageIsDecodedCleanedAndEncodedOnce() async throws {
        let (before, after, same, done) = try await offPool { () -> Result<(Int, Int, Bool, Bool), any Error> in
            Result {
                let page = try Self.cleanupPage(paper: 0.86)
                let cleaned = try ScanImaging.jpeg(page, PageEdits(filters: [.whiten]), dpi: 150)
                return (try Self.level(page, x: 60, y: 60), try Self.level(cleaned, x: 60, y: 60), cleaned == page,
                        try ScanImaging.jpeg(page, PageEdits(filters: [.cropToPaper]), dpi: 150) == page)
            }
        }.get()
        #expect(before < 230, "\(before)")
        #expect(after >= 250, "grey paper evened out to white: \(after)")
        #expect(!same)
        #expect(done) // the crop to the paper's flag alone changes no pixel: the scanner's own JPEG
    }

    @Test func aGreyScanIsCleanedAndSavedAsGrey() async throws {
        let (components, after) = try await offPool { () -> Result<(Int, Int), any Error> in
            Result {
                let page = try Self.cleanupPage(paper: 0.86, grey: true)
                let cleaned = try ScanImaging.jpeg(page, PageEdits(filters: [.whiten, .restoreColors]), dpi: 150)
                return (try PdfWriter.jpegInfo(cleaned).components, try Self.level(cleaned, x: 60, y: 60))
            }
        }.get()
        #expect(components == 1)
        #expect(after >= 250, "\(after)")
    }

    @Test func thePapersEdgeIsFoundOnTheAnalysisCopy() async throws {
        let (onLid, whole) = await offPool { () -> (CropBox?, CropBox?) in
            let onLid = (try? Self.cleanupPage(paper: 0.98, lid: 0.55, margin: 0.6)).flatMap { ScanImaging.paperEdge($0, dpi: 150) }
            let whole = (try? Self.cleanupPage(paper: 0.98)).flatMap { ScanImaging.paperEdge($0, dpi: 150) }
            return (onLid, whole)
        }
        let crop = try #require(onLid)
        // The sheet is 0.6 in in from each side of 8.5 × 11 in.
        #expect(abs(crop.x - 0.6 / 8.5) < 0.02 && abs(crop.y - 0.6 / 11) < 0.02, "\(crop)")
        #expect(abs(crop.width - 7.3 / 8.5) < 0.03 && abs(crop.height - 9.8 / 11) < 0.03, "\(crop)")
        #expect(whole == nil) // a page with no lid around it: no edge to be sure of
    }

    @Test func aStoppedCleanUpStopsAndAPageOfPhotosGetsWhatSuitsAPrint() async throws {
        let (stopped, photoDone) = try await offPool { () -> Result<(Bool, Bool), any Error> in
            Result {
                let page = try Self.cleanupPage(paper: 0.86)
                let stop = BatchStop()
                stop.stop()
                var stopped = false
                do { _ = try ScanImaging.render(page, PageEdits(filters: [.whiten]), dpi: 150, stop: stop) } catch is CancellationError { stopped = true }
                // Whiten isn't for a photo: asked for on one, the photo is cut out as it is, byte for byte.
                let box = PhotoBox(centerX: 0.5, centerY: 0.5, width: 0.4, height: 0.3, angle: 0, quarterTurns: 0)
                let plain = try ScanImaging.photo(page, box)
                return (stopped, try ScanImaging.photo(page, box, filters: [.whiten, .cropToPaper], dpi: 150) == plain)
            }
        }.get()
        #expect(stopped)
        #expect(photoDone)
    }

    @Test func visionsBoxesBecomeThePagesPixelsFromTheTop() throws {
        // Vision: fractions of the image from its bottom left. PdfWriter: pixels from the top left.
        let words = ScanPdf.pixelWords([OcrWord(text: "Καλημέρα", box: CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.05))], width: 1000, height: 2000)
        let w = try #require(words.first)
        #expect(words.count == 1 && w.text == "Καλημέρα")
        #expect(abs(w.x - 250) < 1e-9 && abs(w.y - 400) < 1e-9 && abs(w.width - 500) < 1e-9 && abs(w.height - 100) < 1e-9, "\(w)")
        #expect(ScanPdf.pixelWords([OcrWord(text: "x", box: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1))], width: 10, height: 10).isEmpty)
    }

    /// A line Vision reads is cut into words at its spaces, keeping what's between them whole (as Windows' recognizer gives
    /// words: "демо-сканера:" with its hyphen and colon), so a hyphenated word is found as typed; a line with no spaces
    /// (Japanese) is one word.
    @Test func aRecognisedLineIsCutIntoWordsAtItsSpacesOnly() {
        func words(_ line: String) -> [String] { ScanPdf.wordRanges(line).map { (r: Range<String.Index>) -> String in String(line[r]) } }
        let expected: [String] = ["Привет", "из", "демо-сканера:", "тест.", "ok"]
        #expect(words("Привет из демо-сканера:  тест.\tok") == expected)
        #expect(words("東京都庁です") == ["東京都庁です"])
        #expect(words("   ").isEmpty)
    }

    @Test func theTextLanguagesAreVisionsOwn() {
        let languages = ScanPdf.textLanguages()
        #expect(languages.contains { $0.tag == "en-US" })
        #expect(languages.allSatisfy { !$0.name.isEmpty })
    }

    /// Windows' presets name a Text language by its language alone ("ru", "en"); Vision lists "ru-RU", "en-US".
    @Test func aTextLanguageIsMatchedToVisionsTagByItsLanguage() {
        let vision = ["en-US", "fr-FR", "zh-Hans", "zh-Hant", "pt-BR", "ru-RU"]
        #expect(ScanPdf.visionTag("ru", among: vision) == "ru-RU")
        #expect(ScanPdf.visionTag("en", among: vision) == "en-US")
        #expect(ScanPdf.visionTag("EN-gb", among: vision) == "en-US")
        #expect(ScanPdf.visionTag("zh-Hant", among: vision) == "zh-Hant")
        #expect(ScanPdf.visionTag("zh", among: vision) == "zh-Hans")
        #expect(ScanPdf.visionTag("pt_PT", among: vision) == "pt-BR")
        #expect(ScanPdf.visionTag("fr-FR", among: vision) == "fr-FR")
        #expect(ScanPdf.visionTag("de", among: vision) == nil)
        #expect(ScanPdf.visionTag("", among: vision) == nil)
        #expect(ScanPdf.visionTag("ru", among: ScanPdf.textLanguages().map(\.tag)) == "ru-RU")
    }

    /// A grey page of `width` × `height` pixels, one level all over, as a baseline JPEG written by hand: a page past
    /// `PageCleanup.maxPixels` is about a megabyte this way, where an encoder would need its pixels in memory first. One
    /// channel, quantisation 1, Huffman tables with only the codes it uses (DC: no change "0", the first block's level
    /// "10"; AC: end of block "0"), so every block after the first is two zero bits.
    static func uniformGreyJpeg(width: Int, height: Int, level: Int) -> [UInt8] {
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var out: [UInt8] = [0xFF, 0xD8]
        // One append each: CI's older Xcode gives up type-checking a long chain of array literals and `+`.
        func put(_ parts: [UInt8]...) { for part in parts { out.append(contentsOf: part) } }
        put([0xFF, 0xDB], be16(67), [0x00], [UInt8](repeating: 1, count: 64))
        put([0xFF, 0xC0], be16(11), [8], be16(height), be16(width), [1, 1, 0x11, 0])
        let dcCounts: [UInt8] = [1, 1] + [UInt8](repeating: 0, count: 14)
        let acCounts: [UInt8] = [1] + [UInt8](repeating: 0, count: 15)
        let tablesLength: Int = 2 + 1 + 16 + 2 + 1 + 16 + 1
        put([0xFF, 0xC4], be16(tablesLength), [0x00], dcCounts, [0, 10], [0x10], acCounts, [0x00])
        put([0xFF, 0xDA], be16(8), [1, 1, 0x00, 0, 63, 0])
        // The first block: DC category 10 ("10"), its 10 bits (8 × the level less 128), end of block ("0").
        let dc = 8 * (level - 128)
        precondition(dc >= 512 && dc < 1024, "a level the category 10 code holds")
        let bits = [true, false] + (0..<10).map { dc >> (9 - $0) & 1 == 1 } + [false]
        let blocks = ((width + 7) / 8) * ((height + 7) / 8)
        let total = bits.count + 2 * (blocks - 1)
        var data = [UInt8](repeating: 0, count: (total + 7) / 8)
        for (i, bit) in bits.enumerated() where bit { data[i / 8] |= 0x80 >> (i % 8) }
        let pad = data.count * 8 - total
        if pad > 0 { data[data.count - 1] |= UInt8((1 << pad) - 1) } // padded with ones, as the standard says
        out += data // no 0xFF byte can come out of these bits but a padded last one
        if data.last == 0xFF { out.append(0x00) }
        out += [0xFF, 0xD9]
        return out
    }

    /// One rule for a page too large to clean up: drawn (thumbnails, the crop view, the Clean up view) without its filters,
    /// as it is saved. (A photo cut out of it goes by the photo's own size, saved and shown alike, as on Windows.)
    @Test func aPageTooLargeToCleanIsShownAsItIsSaved() async throws {
        let (saved, shown, small) = try await offPool { () -> Result<(Bool, Int, Int), any Error> in
            Result {
                let huge = Self.uniformGreyJpeg(width: 17_400, height: 17_400, level: 200)
                let size = try #require(ScanImaging.size(huge))
                #expect(PageCleanup.tooLarge(size.width, size.height))
                let whiten = PageEdits(filters: [.whiten, .restoreColors])
                let saved = try ScanImaging.jpeg(huge, whiten) == huge // saved as scanned
                let shown = try Self.level(ScanImaging.jpeg(ScanImaging.render(huge, whiten, maxPixels: 400)), x: 200, y: 200)
                let page = Self.uniformGreyJpeg(width: 800, height: 800, level: 200)
                let small = try Self.level(ScanImaging.jpeg(ScanImaging.render(page, whiten, maxPixels: 400)), x: 200, y: 200)
                return (saved, shown, small)
            }
        }.get()
        #expect(saved)
        #expect(abs(shown - 200) <= 3, "\(shown)")
        #expect(small > 240, "\(small)") // a page that can be cleaned is shown cleaned
    }

    @Test func aPhotoSheetPreviewOfAPaperNoIntCanMeasureIsNone() {
        // The paper comes from the printer's queue: a size that isn't a number (or a width of 0) draws no preview.
        for paper in [SheetPaper(8.5, 1e300, 0, 0, 0, 0), SheetPaper(0, 11, 0, 0, 0, 0), SheetPaper(8.5, .nan, 0, 0, 0, 0)] {
            #expect(PhotoSheets.preview(PhotoSheet([]), photos: [], names: [], paper: paper, width: 200) == nil)
        }
        #expect(PhotoSheets.preview(PhotoSheet([]), photos: [], names: [], paper: SheetPaper(8.5, 11, 0, 0, 0, 0), width: 200)?.height == 259)
    }
}
