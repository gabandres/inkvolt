import CoreGraphics
import Foundation
import ImageIO
import PrintCore
import Testing
@testable import PdfCore

/// Ported from CcittG4RenderTests.cs: PrintCore's black-and-white pages (Inkvolt Print's roadmap 4.4, for Inkvolt PDF's 4.8
/// to reuse): `CcittG4` written by `PdfWriter` and read back by another program, MuPDF, pixel for pixel; and what it saves
/// on a scanned page of text from the OCR corpus. Adapted: a fixed generator in place of .NET's `Random`; the JPEG is
/// ImageIO's at quality 0.85 (Windows: its own encoder at 85); no "as typeset" case (the Mac's corpus has no clean page). Mac
/// only: muPdfReadsTheFlatePageBitForBit (PrintCore's own Deflate, where Windows uses .NET's).
struct CcittG4RenderTests {
    /// The page drawn by MuPDF at one pixel a point (the PDF written at 72 dpi), as black and white bits.
    private static func rendered(_ pdf: [UInt8], _ width: Int, _ height: Int) throws -> BitImage {
        let engine = try PdfEngine.open(pdf)
        let img = try engine.render(0, scale: 1)
        #expect(img.width == width && img.height == height)
        var gray = [UInt8](repeating: 0, count: width * height)
        for i in gray.indices { gray[i] = img.pixels[i * 3 + 1] }
        return try BitImage.fromGray(gray, width, height, threshold: 128)
    }

    private static func pdf(_ image: BitImage) throws -> [UInt8] { try PdfWriter.write([.blackAndWhite(image, dpi: 72)], title: "G4") }

    private static func random(_ width: Int, _ height: Int, _ density: Double) throws -> BitImage {
        var state = UInt64(width + 7 * height) &* 0x9E37_79B9_7F4A_7C15 | 1
        func unit() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }
        let stride = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            var black = unit() < density
            for x in 0..<width {
                if unit() < 0.05 { black = unit() < density }
                if black { bits[y * stride + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
            }
        }
        return try BitImage(width, height, bits)
    }

    @Test(arguments: [(1, 1, 0.5), (13, 9, 0.5), (300, 200, 0.03), (301, 77, 0.5), (1728, 40, 0.1),
                      (3000, 30, 0.01), (2900, 12, 0.99)]) // white, then black runs past 2560
    func muPdfReadsTheG4PageBitForBit(_ width: Int, _ height: Int, _ density: Double) throws {
        let image = try Self.random(width, height, density)
        #expect(try Self.rendered(Self.pdf(image), width, height).bits == image.bits)
    }

    @Test func muPdfReadsTheFlatePageBitForBit() throws {
        // A checkerboard of single pixels goes as Flate (`PdfWriter.oneBit`): MuPDF's inflate reads PrintCore's deflate.
        let (w, h) = (512, 64)
        var bits = [UInt8](repeating: 0, count: w / 8 * h)
        for y in 0..<h { for i in 0..<(w / 8) { bits[y * (w / 8) + i] = y % 2 == 0 ? 0xAA : 0x55 } }
        let image = try BitImage(w, h, bits)
        let pdf = try Self.pdf(image)
        #expect(String(decoding: pdf, as: UTF8.self).contains("/Filter /FlateDecode"))
        #expect(try Self.rendered(pdf, w, h).bits == image.bits)
    }

    @Test(.enabled(if: ScanCorpus.runs))
    func muPdfReadsAScannedTextPageBitForBit() throws {
        let file = try #require(ScanCorpus.files.first { $0.name == "en-skew6-noisy" })
        let (pixels, w, h, _) = try ScanCorpus.makePage(file, 0)
        let image = try Bilevel.fromScan(pixels, w, h, dpi: ScanCorpus.dpi)
        let pdf = try Self.pdf(image)
        #expect(String(decoding: pdf, as: UTF8.self).contains("/CCITTFaxDecode"))
        #expect(try Self.rendered(pdf, w, h).bits == image.bits)
    }

    /// The size gain on a scanned letter page of text at 300 dpi (the corpus's light and noisy scans): the page as a grey JPEG
    /// at quality 0.85, a scanner's usual, against the same page in black and white as G4, each as a whole PDF.
    @Test(.enabled(if: ScanCorpus.runs), arguments: ["en-skew3-light", "es-skew4-noisy"])
    func aTextPageInBlackAndWhiteIsAFractionOfItsJpeg(_ name: String) throws {
        let file = try #require(ScanCorpus.files.first { $0.name == name })
        let (pixels, w, h, _) = try ScanCorpus.makePage(file, 0)
        let jpeg = try Self.grayJpeg(pixels, w, h, quality: 0.85)
        let bits = try Bilevel.fromScan(pixels, w, h, dpi: ScanCorpus.dpi)
        let asJpeg = try PdfWriter.write([PdfWriter.Page(jpeg, dpi: ScanCorpus.dpi)], title: name).count
        let asBits = try PdfWriter.write([.blackAndWhite(bits, dpi: ScanCorpus.dpi)], title: name).count
        print("\(name): \(w) × \(h), JPEG 0.85 PDF \(asJpeg) bytes, black-and-white PDF \(asBits) bytes (\(try PdfWriter.oneBit(bits).filter)), "
            + String(format: "%.1f times smaller", Double(asJpeg) / Double(asBits)))
        #expect(asBits * 5 < asJpeg, "\(asBits) vs \(asJpeg)")
    }

    private static func grayJpeg(_ gray: [UInt8], _ w: Int, _ h: Int, quality: Double) throws -> [UInt8] {
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
}
