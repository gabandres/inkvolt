import CCups
import CoreGraphics
import Foundation
import PrintCore
import Synchronization
import Testing
@testable import PrintMac

/// Roadmap 2.1's encoders read by macOS's own readers, as Windows checked them against CUPS's (DirectPrintTests.cs' header):
/// libcups' raster reader (`cupsRasterReadHeader2`, `cupsRasterReadPixels`: the code CUPS's filters read PWG and Apple raster
/// with) takes our PWG raster and Apple raster with the header fields and pixels written; Core Graphics opens our PCLm as the
/// PDF it is and draws its strips back to the same pixels; and `/usr/bin/ippeveprinter` (CUPS's IPP Everywhere test printer,
/// which macOS ships) takes a Print-Job of each format and keeps the very bytes sent (IppEvePrinterTests). Not proved
/// here: that a real printer prints them (ippeveprinter stores a document, it doesn't read it; PLAN P12 2.1).
@Suite(.serialized)
struct RasterCupsTests {
    struct CupsPage {
        var header: cups_page_header2_t
        var pixels: [UInt8]
    }

    /// Every page of a raster document as libcups reads it.
    static func cupsRead(_ bytes: [UInt8]) throws -> [CupsPage] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-raster-\(UUID().uuidString)")
        try Data(bytes).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0, let raster = cupsRasterOpen(fd, CUPS_RASTER_READ) else { throw CocoaError(.fileReadUnknown) }
        defer {
            cupsRasterClose(raster)
            close(fd)
        }
        var pages: [CupsPage] = []
        var header = cups_page_header2_t()
        while cupsRasterReadHeader2(raster, &header) == 1 {
            let line = Int(header.cupsBytesPerLine)
            var pixels = [UInt8](repeating: 0, count: line * Int(header.cupsHeight))
            for y in 0..<Int(header.cupsHeight) {
                let read = pixels.withUnsafeMutableBufferPointer { cupsRasterReadPixels(raster, $0.baseAddress! + y * line, UInt32(line)) }
                if read != UInt32(line) { throw CocoaError(.fileReadCorruptFile) }
            }
            pages.append(CupsPage(header: header, pixels: pixels))
        }
        return pages
    }

    private static func name(_ header: cups_page_header2_t) -> String {
        withUnsafeBytes(of: header.cupsPageSizeName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func write(_ job: RasterJob, _ pages: [RasterPage]) throws -> [UInt8] {
        let w = try RasterWriter.forJob(job)
        for p in pages { try w.write(p) }
        try w.finish()
        return w.drain()
    }

    @Test(arguments: [RasterColor.gray8, .rgb8])
    func libcupsReadsOurPwgRasterHeaderAndPixels(_ color: RasterColor) throws {
        let front = try Self.noise(37, 23, color, seed: 11)
        let back = try Self.noise(37, 23, color, seed: 12)
        var job = Self.job(.pwgRaster, color, 940, 584, pages: 2)
        (job.duplex, job.tumble, job.back, job.quality, job.mediaType) = (true, true, .flipped, 5, "stationery")
        let pages = try Self.cupsRead(Self.write(job, [front, back]))
        #expect(pages.count == 2)
        for (i, page) in pages.enumerated() {
            let h = page.header
            #expect([h.cupsWidth, h.cupsHeight, h.cupsBitsPerColor] == [37, 23, 8] as [UInt32])
            #expect(h.cupsBitsPerPixel == (color == .gray8 ? 8 : 24))
            #expect(h.cupsColorSpace == (color == .gray8 ? CUPS_CSPACE_SW : CUPS_CSPACE_SRGB))
            #expect(h.cupsColorOrder == CUPS_ORDER_CHUNKED)
            #expect([h.HWResolution.0, h.HWResolution.1] == [100, 100] as [UInt32])
            #expect([h.PageSize.0, h.PageSize.1] == [27, 17] as [UInt32]) // 940 × 584 hundredths of a mm in points, rounded
            #expect(h.Duplex == CUPS_TRUE && h.Tumble == CUPS_TRUE)
            #expect(h.cupsInteger.0 == 2) // TotalPageCount
            #expect(Self.name(h) == "custom")
            // CrossFeedTransform and FeedTransform (cupsInteger[1] and [2]): flipped + short edge mirrors the back across.
            #expect([Int32(bitPattern: h.cupsInteger.1), Int32(bitPattern: h.cupsInteger.2)] == (i == 0 ? [1, 1] : [-1, 1] as [Int32]))
        }
        #expect(pages[0].pixels == front.pixels)
        #expect(pages[1].pixels == Self.mirror(back, across: true, down: false))
    }

    @Test(arguments: [RasterColor.gray8, .rgb8])
    func libcupsReadsOurAppleRasterHeaderAndPixels(_ color: RasterColor) throws {
        let pages = try (0..<3).map { try Self.noise(61, 20, color, seed: UInt64(20 + $0)) }
        var job = Self.job(.urf, color, 1549, 508, pages: 3)
        (job.duplex, job.quality) = (true, 3)
        let read = try Self.cupsRead(Self.write(job, pages))
        #expect(read.count == 3)
        for (i, page) in read.enumerated() {
            let h = page.header
            #expect([h.cupsWidth, h.cupsHeight] == [61, 20] as [UInt32])
            #expect(h.cupsBitsPerPixel == (color == .gray8 ? 8 : 24))
            #expect(h.cupsColorSpace == (color == .gray8 ? CUPS_CSPACE_SW : CUPS_CSPACE_SRGB))
            #expect([h.HWResolution.0, h.HWResolution.1] == [100, 100] as [UInt32])
            #expect(h.Duplex == CUPS_TRUE && h.Tumble == CUPS_FALSE) // long edge
            #expect(page.pixels == pages[i].pixels)
        }
    }

    /// A PCLm page drawn by Core Graphics at its own resolution, one device pixel a raster pixel, into a bitmap of the page's
    /// color (grey or RGB, no color management between Device spaces), without smoothing.
    private static func draw(_ pdf: [UInt8], page index: Int, dpi: Int, color: RasterColor) throws -> (pixels: [UInt8], box: CGRect) {
        let provider = try #require(CGDataProvider(data: Data(pdf) as CFData))
        let document = try #require(CGPDFDocument(provider))
        let page = try #require(document.page(at: index + 1))
        let box = page.getBoxRect(.mediaBox)
        let scale = CGFloat(dpi) / 72
        let (w, h) = (Int((box.width * scale).rounded()), Int((box.height * scale).rounded()))
        let channels = RasterPage.channels(color)
        let space = color == .gray8 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = color == .gray8 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let bpp = color == .gray8 ? 1 : 4
        var raw = [UInt8](repeating: 255, count: w * h * bpp)
        try raw.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * bpp,
                                                 space: space, bitmapInfo: info))
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
        }
        if channels == 1 { return (raw, box) }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<w * h { for c in 0..<3 { rgb[i * 3 + c] = raw[i * 4 + c] } }
        return (rgb, box)
    }

    @Test(arguments: [(RasterColor.gray8, true), (.rgb8, false)] as [(RasterColor, Bool)])
    func coreGraphicsOpensOurPclmAndDrawsItsStripsBack(_ color: RasterColor, _ runLength: Bool) throws {
        let pages = try (0..<2).map { try Self.noise(40, 37, color, seed: UInt64(30 + $0)) }
        var job = Self.job(.pclm, color, 1016, 940, pages: 2)
        (job.stripHeight, job.runLength) = (16, runLength)
        let pdf = try Self.write(job, pages)
        let provider = try #require(CGDataProvider(data: Data(pdf) as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == 2)
        for i in 0..<2 {
            let (pixels, box) = try Self.draw(pdf, page: i, dpi: 100, color: color)
            #expect(abs(box.width - 28.8) < 0.001 && abs(box.height - 26.6457) < 0.001)
            #expect(pixels.count == pages[i].pixels.count)
            let off = zip(pixels, pages[i].pixels).map { abs(Int($0) - Int($1)) }.max() ?? 999
            #expect(off == 0, "page \(i + 1): a pixel differs by \(off)")
        }
    }

    // ---- pages and jobs (PrintCoreTests' RasterEncoderTests has the same; test targets don't share code) ----

    static func job(_ format: RasterFormat, _ color: RasterColor, _ w: Int, _ h: Int, pages: Int = 1, dpi: Int = 100) -> RasterJob {
        RasterJob(format, dpi: dpi, color: color, mediaName: "custom", widthHmm: w, heightHmm: h, pages: pages)
    }

    /// Pixels with runs and literals (a quarter white, the rest 0-3), the first four lines alike for the line repeat.
    static func noise(_ w: Int, _ h: Int, _ color: RasterColor, seed: UInt64) throws -> RasterPage {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func next(_ n: UInt64) -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(state % n)
        }
        let channels = RasterPage.channels(color)
        var pixels = (0..<w * h * channels).map { _ in next(4) == 0 ? UInt8(255) : next(4) }
        let line = w * channels
        if h > 4 { for y in 1..<4 { pixels.replaceSubrange(y * line..<(y + 1) * line, with: pixels[0..<line]) } }
        return try RasterPage(width: w, height: h, color: color, pixels: pixels)
    }

    static func mirror(_ p: RasterPage, across: Bool, down: Bool) -> [UInt8] {
        let bpp = p.bytesPerPixel
        var o = [UInt8](repeating: 0, count: p.pixels.count)
        for y in 0..<p.height {
            for x in 0..<p.width {
                let (sx, sy) = (across ? p.width - 1 - x : x, down ? p.height - 1 - y : y)
                for c in 0..<bpp { o[(y * p.width + x) * bpp + c] = p.pixels[(sy * p.width + sx) * bpp + c] }
            }
        }
        return o
    }
}
