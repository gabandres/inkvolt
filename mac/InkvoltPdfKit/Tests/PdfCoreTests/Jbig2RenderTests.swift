import Foundation
import PrintCore
import Testing
@testable import PdfCore

/// Ported from Jbig2RenderTests.cs: our lossless JBIG2 (PrintCore's `Jbig2Generic`, roadmap 4.8) read back by another
/// program, MuPDF (jbig2dec), pixel for pixel, and its size against `CcittG4` on 300 dpi pages of text. Adapted: a fixed
/// generator in place of .NET's `Random`; no "as typeset" case (the Mac's corpus has no clean page), so the size test
/// prints G4 and JBIG2 only.
struct Jbig2RenderTests {
    /// A one-page PDF at 72 dpi whose image is the 1-bit stream given.
    private static func pdf(_ image: BitImage, _ filter: String, _ data: [UInt8]) -> [UInt8] {
        Optimizer.oneImagePage("/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /ColorSpace /DeviceGray /BitsPerComponent 1 \(filter)",
                               data, image.width, image.height)
    }

    private static func rendered(_ pdf: [UInt8], _ width: Int, _ height: Int) throws -> BitImage {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let img = try engine.render(0, scale: 1)
        #expect(img.width == width && img.height == height)
        var gray = [UInt8](repeating: 0, count: width * height)
        for i in gray.indices { gray[i] = img.pixels[i * 3 + 1] }
        return try BitImage.fromGray(gray, width, height, threshold: 128)
    }

    private static func random(_ width: Int, _ height: Int, _ density: Double, _ change: Double) throws -> BitImage {
        var rng = SplitMix(seed: UInt64(width * 31 + height))
        func unit() -> Double { Double(rng.next(1 << 30)) / Double(1 << 30) }
        let stride = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            var black = unit() < density
            for x in 0..<width {
                if unit() < change { black = unit() < density }
                if black { bits[y * stride + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
            }
        }
        return try BitImage(width, height, bits)
    }

    @Test(arguments: [(1, 1, 0.5, 0.05), (13, 9, 0.5, 0.05), (300, 200, 0.03, 0.05), (301, 77, 0.5, 0.05),
                      (64, 64, 0.5, 1.0), // noise: every context, many carries in the coder
                      (500, 300, 0.5, 0.6), (2900, 12, 0.99, 0.05)])
    func muPdfReadsTheJbig2ImageBitForBit(_ width: Int, _ height: Int, _ density: Double, _ change: Double) throws {
        let image = try Self.random(width, height, density, change)
        #expect(try Self.rendered(Self.pdf(image, "/Filter /JBIG2Decode", Jbig2Generic.encode(image)), width, height).bits == image.bits)
    }

    @Test func rowsLikeTheOneAboveAndBlankPagesComeBackToo() throws {
        // Runs of rows equal to the one above (blank, and repeated ink), on and off.
        let (w, h) = (200, 120)
        let stride = (w + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * h)
        for y in 0..<h {
            if y / 10 % 3 == 1 {
                for x in Swift.stride(from: y % 7, to: w, by: 5) { bits[y * stride + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
            } else if y / 10 % 3 == 2 {
                for x in Swift.stride(from: 0, to: w, by: 3) { bits[y * stride + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
            }
        }
        let image = try BitImage(w, h, bits)
        #expect(try Self.rendered(Self.pdf(image, "/Filter /JBIG2Decode", Jbig2Generic.encode(image)), w, h).bits == image.bits)
        let white = try BitImage.white(w, h)
        #expect(try Self.rendered(Self.pdf(white, "/Filter /JBIG2Decode", Jbig2Generic.encode(white)), w, h).bits == white.bits)
    }

    @Test(.enabled(if: ScanCorpus.runs))
    func muPdfReadsAScannedTextPageBitForBit() throws {
        let file = try #require(ScanCorpus.files.first { $0.name == "en-skew6-noisy" })
        let (pixels, w, h, _) = try ScanCorpus.makePage(file, 0)
        let image = try Bilevel.fromScan(pixels, w, h, dpi: ScanCorpus.dpi)
        #expect(try Self.rendered(Self.pdf(image, "/Filter /JBIG2Decode", Jbig2Generic.encode(image)), w, h).bits == image.bits)
    }

    @Test func cancellingStopsTheEncoder() throws {
        let stop = BatchStop()
        stop.stop()
        #expect(throws: CancellationError.self) { try Jbig2Generic.encode(try BitImage.white(100, 100), stop: stop) }
    }

    /// The sizes on 300 dpi letter pages of text (the corpus's light, noisy and shaded scans), in black and white as CCITT
    /// G4 and as our JBIG2. JBIG2 is kept because it is clearly smaller than G4 on every one.
    @Test(.enabled(if: ScanCorpus.runs), arguments: ["en-skew3-light", "en-skew6-noisy", "es-skew8-shaded"])
    func jbig2IsClearlySmallerThanG4OnTextPages(_ name: String) throws {
        let file = try #require(ScanCorpus.files.first { $0.name == name })
        let (pixels, w, h, _) = try ScanCorpus.makePage(file, 0)
        let bits = try Bilevel.fromScan(pixels, w, h, dpi: ScanCorpus.dpi)
        let g4 = try CcittG4.encode(bits).count
        let started = Date()
        let jbig2 = try Jbig2Generic.encode(bits).count
        print("\(name): \(w) × \(h), G4 \(g4), JBIG2 \(jbig2) (\(100 * jbig2 / g4)% of G4, \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        #expect(jbig2 * 10 < g4 * 9, "JBIG2 \(jbig2) vs G4 \(g4)")
    }
}
