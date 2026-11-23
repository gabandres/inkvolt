import CoreGraphics
import Foundation
import ImageIO
import PrintCore
import Testing
@testable import PdfCore

/// Ported from OneBitImagesTests.cs (same names): smaller black-and-white scans (roadmap 4.8), Recognize Text's cleaned
/// page of a black-and-white scan kept at 1 bit (`ScanPage`), and Reduce File Size's lossless recoding of 1-bit pictures
/// and, when asked, grey scans of text made black and white (`OneBitImages`). Adapted: the JPEGs are ImageIO's (Windows:
/// its own encoder); a fixed generator in place of .NET's `Random`. Not ported: ScannedInBlackAndWhiteAPageIsSavedAtOneBit…
/// (the Mac's File › Scan has no black-and-white mode to save at 1 bit: PLAN, Wave 4 Batch B).
/// The tests on the corpus's 300 dpi page run on a Mac, not in CI (`ScanCorpus.runs`).
struct OneBitImagesTests {
    /// The corpus's light scan, made once.
    private static let page: (gray: [UInt8], width: Int, height: Int)? = {
        guard let file = ScanCorpus.files.first(where: { $0.name == "en-skew3-light" }),
              let made = try? ScanCorpus.makePage(file, 0) else { return nil }
        return (made.pixels, made.width, made.height)
    }()

    private static func full() throws -> (gray: [UInt8], width: Int, height: Int) { try #require(page) }

    /// The page's grey pixels, every `step`th row and column: a smaller page for quicker tests.
    private static func smaller(_ step: Int) throws -> (gray: [UInt8], width: Int, height: Int) {
        let (gray, w, h) = try full()
        let (sw, sh) = (w / step, h / step)
        var small = [UInt8](repeating: 0, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw { small[y * sw + x] = gray[y * step * w + x * step] } }
        return (small, sw, sh)
    }

    /// Objects 1…n with a classic xref table, from bytes (binary samples kept as they are).
    private static func build(_ objects: [[UInt8]]) -> [UInt8] {
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += Array("\(i + 1) 0 obj\n".utf8) + o + Array("\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    private static func stream(_ data: [UInt8], _ dict: String = "") -> [UInt8] {
        Array("<< \(dict) /Length \(data.count) >>\nstream\n".utf8) + data + Array("\nendstream".utf8)
    }

    /// A Letter page drawing one picture over all of it (`content` before it: a colour for a stencil).
    private static func onePicturePage(_ imageDict: String, _ data: [UInt8], content: String = "") -> [UInt8] {
        build([
            Array("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Array("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Array("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Im 5 0 R >> >> >>".utf8),
            stream(Array("\(content)q 612 0 0 792 0 0 cm /Im Do Q".utf8)),
            stream(data, imageDict),
        ])
    }

    private static func picture(_ doc: MuDoc, _ name: String = "Im") throws -> PObj {
        try #require(doc.page(0).dict("Resources")?.dict("XObject")?.dict(name))
    }

    private static func pixels(_ pdf: [UInt8], _ scale: Double = 0.5) throws -> [UInt8] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try engine.render(0, scale: scale).pixels
    }

    /// A 1-bit picture's rows as /DeviceGray reads them (0 black): a set bit of `bits` cleared.
    private static func samples(_ bits: BitImage) -> [UInt8] {
        let tail = UInt8(truncatingIfNeeded: 0xFF << (8 * bits.stride - bits.width))
        return bits.bits.indices.map { i in i % bits.stride == bits.stride - 1 ? ~bits.bits[i] & tail : ~bits.bits[i] }
    }

    private static func grayJpeg(_ gray: [UInt8], _ w: Int, _ h: Int, quality: Double = 0.85) throws -> [UInt8] {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw PdfEngineError(message: "JPEG") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PdfEngineError(message: "JPEG") }
        return [UInt8](data as Data)
    }

    private static let keepPictures = OptimizeOptions(maxImageDpi: nil)

    @Test(.enabled(if: ScanCorpus.runs)) func aScanOfTextLooksBlackAndWhiteAndAPhotoDoesnt() throws {
        let (gray, w, h) = try Self.full()
        #expect(OneBitImages.looksBlackAndWhite(gray, w, h))
        let noisyFile = try #require(ScanCorpus.files.first { $0.name == "en-skew6-noisy" })
        let (noisy, nw, nh, _) = try ScanCorpus.makePage(noisyFile, 0)
        #expect(OneBitImages.looksBlackAndWhite(noisy, nw, nh))
        #expect(OneBitImages.looksBlackAndWhite([UInt8](repeating: 250, count: 1000), 40, 25)) // blank paper

        // A photo: shades all through.
        var rng = SplitMix(seed: 4)
        var photo = [UInt8](repeating: 0, count: 400 * 300)
        for y in 0..<300 { for x in 0..<400 { photo[y * 400 + x] = UInt8(min(max(x * 255 / 400 + rng.next(40) - 20, 0), 255)) } }
        #expect(!OneBitImages.looksBlackAndWhite(photo, 400, 300))
        // Text on dark paper: ink and paper too close.
        #expect(!OneBitImages.looksBlackAndWhite(gray.map { 60 + $0 / 3 }, w, h))
        #expect(!OneBitImages.looksBlackAndWhite([], 0, 0))
    }

    @Test(.enabled(if: ScanCorpus.runs)) func reduceFileSizeCodesABlackAndWhitePictureAgainWithoutLosingAPixel() throws {
        let (gray, w, h) = try Self.smaller(2)
        let bits = try Bilevel.fromScan(gray, w, h, dpi: 150)
        let flate = Deflate.zlib(Self.samples(bits))
        let pdf = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode", flate)
        let result = try Optimizer.optimize(pdf, nil, Self.keepPictures)
        #expect(result.imagesBlackAndWhite == 1)
        let doc = try Core2Pdf.open(result.data)
        let image = try Self.picture(doc)
        #expect(image.name("Filter") == "JBIG2Decode")
        #expect(image.int("BitsPerComponent") == 1)
        let stored = try #require(image.rawStreamData).count
        #expect(stored * 4 < flate.count * 3, "\(stored) vs Flate \(flate.count)")
        #expect(try Self.pixels(pdf, 1) == Self.pixels(result.data, 1))

        // Again: nothing smaller to be had, so it stays as it is.
        #expect(try Optimizer.optimize(result.data, nil, Self.keepPictures).imagesBlackAndWhite == 0)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func onlyOneComponentPicturesAreCodedAgain() throws {
        let (gray, w, h) = try Self.smaller(2)
        let raw = Self.samples(try Bilevel.fromScan(gray, w, h, dpi: 150))
        let stride = (w + 7) / 8

        // 1-bit RGB: three samples a pixel, rows of the page's bits laid side by side. Coding them as grey would garble it.
        let rgbStride = (3 * w + 7) / 8
        var rgb = [UInt8](repeating: 0, count: rgbStride * h)
        for y in 0..<h { for i in 0..<rgbStride { rgb[y * rgbStride + i] = raw[y * stride + i % stride] } }
        for space in ["/DeviceRGB", "/DeviceCMYK", "[/ICCBased << /N 3 >>]"] {
            let data = space == "/DeviceCMYK" ? rgb + rgb[0..<((w * 4 + 7) / 8 * h - rgb.count)] : rgb
            let pdf = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace \(space) /BitsPerComponent 1 /Filter /FlateDecode",
                                          Deflate.zlib(data))
            let result = try Optimizer.optimize(pdf, nil, Self.keepPictures)
            #expect(result.imagesBlackAndWhite == 0)
            #expect(try Self.picture(Core2Pdf.open(result.data)).name("Filter") == "FlateDecode")
        }

        // Indexed with two colours (one sample a pixel): coded again, drawn the same.
        let indexed = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace [/Indexed /DeviceRGB 1 <000080FFFFFF>] /BitsPerComponent 1 /Filter /FlateDecode",
                                          Deflate.zlib(raw))
        let recoded = try Optimizer.optimize(indexed, nil, Self.keepPictures)
        #expect(recoded.imagesBlackAndWhite == 1)
        #expect(try Self.pixels(indexed, 1) == Self.pixels(recoded.data, 1))

        let doc = try Core2Pdf.open(indexed)
        #expect(OneBitImages.oneComponent(doc.name("DeviceGray")))
        #expect(!OneBitImages.oneComponent(doc.name("DeviceRGB")))
        #expect(!OneBitImages.oneComponent(nil))
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aStencilsDecodeArrayAndAGreyPictureAreLeftAsTheyDraw() throws {
        // A stencil painting its 1 samples in red (Decode [1 0]), as CCITT G4: coded again, drawn the same.
        let (gray, w, h) = try Self.smaller(3)
        let bits = try Bilevel.fromScan(gray, w, h, dpi: 100)
        let g4 = try CcittG4.encode(bits)
        let stencil = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ImageMask true /Decode [1 0] /Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns \(w) /Rows \(h) >>",
                                          g4, content: "1 0 0 rg ")
        let result = try Optimizer.optimize(stencil, nil, Self.keepPictures)
        #expect(result.imagesBlackAndWhite == 1)
        do {
            let image = try Self.picture(Core2Pdf.open(result.data))
            #expect(image.name("Filter") == "JBIG2Decode")
            #expect(image["DecodeParms"] == nil)
            #expect(OneBitImages.isStencil(image))
            #expect(image.array("Decode") != nil)
        }
        // Drawn the same, to MuPDF's smoothing of the edges (one filter or the other takes another path to the screen).
        let (a, b) = (try Self.pixels(stencil), try Self.pixels(result.data))
        #expect(a.count == b.count)
        #expect(zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 <= 4)

        // A grey scan isn't made black and white unless asked.
        let (g, gw, gh) = try Self.smaller(2)
        let grey = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(gw) /Height \(gh) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
                                       try Self.grayJpeg(g, gw, gh))
        let kept = try Optimizer.optimize(grey, nil, Self.keepPictures)
        #expect(kept.imagesBlackAndWhite == 0)
        #expect(try Self.picture(Core2Pdf.open(kept.data)).name("Filter") == "DCTDecode")
    }

    @Test(.enabled(if: ScanCorpus.runs)) func askedForBlackAndWhiteAGreyScanOfTextBecomesOneBitAndAPhotoDoesnt() throws {
        let (g, gw, gh) = try Self.smaller(2)
        let grey = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(gw) /Height \(gh) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
                                       try Self.grayJpeg(g, gw, gh))
        let options = OptimizeOptions(maxImageDpi: nil, blackAndWhiteScans: true)
        let result = try Optimizer.optimize(grey, nil, options)
        #expect(result.imagesBlackAndWhite == 1)
        #expect(result.sizeAfter * 5 < result.sizeBefore, "\(result.sizeBefore) -> \(result.sizeAfter)")
        do {
            let image = try Self.picture(Core2Pdf.open(result.data))
            #expect(image.int("BitsPerComponent") == 1)
            #expect(image.name("ColorSpace") == "DeviceGray")
        }
        // The text is where it was: ink where the scan had ink.
        let before = try Self.pixels(grey, 0.25), after = try Self.pixels(result.data, 0.25)
        #expect(before.count == after.count)
        var (inkBefore, inkAfter, both) = (0, 0, 0)
        for i in Swift.stride(from: 0, to: min(before.count, after.count), by: 3) {
            let (a, b) = (before[i] < 160, after[i] < 128)
            inkBefore += a ? 1 : 0
            inkAfter += b ? 1 : 0
            both += a && b ? 1 : 0
        }
        #expect(inkAfter > 0 && Double(both) > Double(inkAfter) * 0.6, "ink \(inkBefore) before, \(inkAfter) after, \(both) both")

        // A photo stays a photo.
        var rng = SplitMix(seed: 9)
        var photo = [UInt8](repeating: 0, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw { photo[y * gw + x] = UInt8(min(max((x + y) * 255 / (gw + gh) + rng.next(20) - 10, 0), 255)) } }
        let photoPdf = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(gw) /Height \(gh) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
                                           try Self.grayJpeg(photo, gw, gh))
        #expect(try Optimizer.optimize(photoPdf, nil, options).imagesBlackAndWhite == 0)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aCleanedPageOfABlackAndWhiteScanStaysBlackAndWhite() throws {
        let (gray, w, h) = try Self.smaller(2)
        let bits = try Bilevel.fromScan(gray, w, h, dpi: 150)
        let oneBit = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode",
                                         Deflate.zlib(Self.samples(bits)))
        let greyScan = Self.onePicturePage("/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
                                           try Self.grayJpeg(gray, w, h))
        let cleaned = CleanedPageImage.from(w, h, 1, gray, 0)

        let written = try ScanPage.writeBack(oneBit, nil, [0: cleaned])
        do {
            let image = try Self.picture(Core2Pdf.open(written), "PdScan")
            #expect(image.int("BitsPerComponent") == 1)
            #expect(image.name("Filter") == "JBIG2Decode")
            let stored = try #require(image.rawStreamData).count
            #expect(stored * 10 < cleaned.deflated.count, "\(stored) vs \(cleaned.deflated.count)")
        }
        #expect(try Core2Pdf.ink(written, 0, RectD(0, 0, 612, 792)) > 0.01)

        // A grey scan's cleaned page stays grey.
        let grey = try ScanPage.writeBack(greyScan, nil, [0: cleaned])
        #expect(try Self.picture(Core2Pdf.open(grey), "PdScan").int("BitsPerComponent") == 8)
    }

    @Test func blackAndWhiteScansIsOffUnlessAskedAndKeptInABatchPreset() throws {
        #expect(!OptimizeOptions().blackAndWhiteScans)
        let json = BatchPresets.write(BatchPreset(name: "bw", steps: [.optimize(OptimizeOptions(blackAndWhiteScans: true))]))
        #expect(json.contains("blackAndWhiteScans"))
        let without = json.replacingOccurrences(of: "\"blackAndWhiteScans\": true,", with: "")
        guard case .optimize(let off) = try #require(BatchPresets.read(without).steps.first) else { Issue.record("not an optimize step"); return }
        #expect(!off.blackAndWhiteScans)
        guard case .optimize(let on) = try #require(BatchPresets.read(json).steps.first) else { Issue.record("not an optimize step"); return }
        #expect(on.blackAndWhiteScans)
    }
}
