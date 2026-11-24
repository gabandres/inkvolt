import Foundation

/// The three raster formats IPP Everywhere printers take without a driver (roadmap 2.1; Windows' `Printing/Raster`).
public enum RasterFormat: Sendable, Equatable, CaseIterable {
    /// PWG 5102.4 PWG Raster (`image/pwg-raster`), the one IPP Everywhere requires.
    case pwgRaster
    /// Apple Raster (`image/urf`), AirPrint's.
    case urf
    /// PCLm (`application/PCLm`): Mopria's raster in a constrained PDF (Mopria Alliance, PCLm Technical Reference).
    case pclm
}

/// 8 bits a pixel, grey (sGray, 0 black, 255 white) or three per pixel (sRGB).
public enum RasterColor: Sendable, Equatable {
    case gray8
    case rgb8
}

/// How the printer wants the back of a two-sided sheet (`pwg-raster-document-sheet-back`, `urf-supported`'s DM1-DM4,
/// `pclm-raster-back-side`): as it is, flipped, rotated, or as a manual-tumble unit takes it.
public enum BackSide: Sendable, Equatable {
    case normal
    case flipped
    case rotated
    case manualTumble
}

/// Why a raster page or job can't be made or written (Windows' ArgumentException and InvalidOperationException).
public enum RasterError: Error, Equatable, CustomStringConvertible {
    /// A size, resolution or count out of range, or pixels that don't match the size.
    case outOfRange(String)
    /// A page that isn't the job's paper and color.
    case pageMismatch
    /// More pages than the job said, or `finish` before all of them.
    case pageCount(String)

    public var description: String {
        switch self {
        case .outOfRange(let why), .pageCount(let why): why
        case .pageMismatch: "page doesn't match the job's paper and color"
        }
    }
}

/// One page's pixels, top row first, left to right, with no padding: one byte a pixel (grey) or three (R, G, B).
public struct RasterPage: Sendable, Equatable {
    /// Most pixels on one page: 400 million (13 × 19 in at 1200 dpi is 356 million).
    public static let maxPixels = 400_000_000

    public let width: Int
    public let height: Int
    public let color: RasterColor
    public let pixels: [UInt8]

    public init(width: Int, height: Int, color: RasterColor, pixels: [UInt8]) throws {
        guard width > 0, height > 0, width.multipliedReportingOverflow(by: height).partialValue <= Self.maxPixels,
              width <= Self.maxPixels, height <= Self.maxPixels else { throw RasterError.outOfRange("page size out of range") }
        guard pixels.count == width * height * Self.channels(color) else { throw RasterError.outOfRange("pixel count doesn't match the size") }
        (self.width, self.height, self.color, self.pixels) = (width, height, color, pixels)
    }

    public var bytesPerPixel: Int { Self.channels(color) }
    public var bytesPerLine: Int { width * bytesPerPixel }

    public static func channels(_ color: RasterColor) -> Int { color == .gray8 ? 1 : 3 }

    /// A white page.
    public static func blank(width: Int, height: Int, color: RasterColor) throws -> RasterPage {
        guard width > 0, height > 0, width <= maxPixels, height <= maxPixels, width * height <= maxPixels else {
            throw RasterError.outOfRange("page size out of range")
        }
        return try RasterPage(width: width, height: height, color: color, pixels: [UInt8](repeating: 255, count: width * height * channels(color)))
    }

    /// From 32-bit BGRA rows with alpha already applied on a white page (Core Graphics' `byteOrder32Little` with
    /// `premultipliedFirst`, as WPF's Pbgra32), as grey (ITU-R BT.601 weights) or RGB. `stride`: bytes from one row to the next.
    /// `grey`: RGB with the three equal (the grey value), grey printing on a format that takes only color.
    public static func fromBgra(width: Int, height: Int, stride: Int, _ bgra: UnsafeBufferPointer<UInt8>, color: RasterColor,
                                grey: Bool = false) throws -> RasterPage {
        guard width > 0, height > 0, width * height <= maxPixels, stride >= width * 4, bgra.count >= stride * (height - 1) + width * 4 else {
            throw RasterError.outOfRange("pixel buffer too small for the size")
        }
        let channels = Self.channels(color)
        var pixels = [UInt8](repeating: 0, count: width * height * channels)
        pixels.withUnsafeMutableBufferPointer { out in
            var o = 0
            for y in 0..<height {
                let row = y * stride
                for x in 0..<width {
                    let b = Int(bgra[row + x * 4]), g = Int(bgra[row + x * 4 + 1]), r = Int(bgra[row + x * 4 + 2])
                    if channels == 1 {
                        out[o] = UInt8((77 * r + 150 * g + 29 * b + 128) >> 8)
                        o += 1
                    } else if grey {
                        let level = UInt8((77 * r + 150 * g + 29 * b + 128) >> 8)
                        (out[o], out[o + 1], out[o + 2]) = (level, level, level)
                        o += 3
                    } else {
                        (out[o], out[o + 1], out[o + 2]) = (UInt8(r), UInt8(g), UInt8(b))
                        o += 3
                    }
                }
            }
        }
        return try RasterPage(width: width, height: height, color: color, pixels: pixels)
    }

    public static func fromBgra(width: Int, height: Int, stride: Int, _ bgra: [UInt8], color: RasterColor, grey: Bool = false) throws -> RasterPage {
        try bgra.withUnsafeBufferPointer { try fromBgra(width: width, height: height, stride: stride, $0, color: color, grey: grey) }
    }

    /// This page cut or padded with white on the right and bottom to `width` × `height` (rounding between resolutions).
    public func fitted(width w: Int, height h: Int) throws -> RasterPage {
        if w == width && h == height { return self }
        var fitted = try RasterPage.blank(width: w, height: h, color: color).pixels
        let copy = min(w, width) * bytesPerPixel
        let line = w * bytesPerPixel
        pixels.withUnsafeBufferPointer { src in
            fitted.withUnsafeMutableBufferPointer { dst in
                for y in 0..<min(h, height) {
                    UnsafeMutableRawPointer(dst.baseAddress! + y * line).copyMemory(from: src.baseAddress! + y * bytesPerLine, byteCount: copy)
                }
            }
        }
        return try RasterPage(width: w, height: h, color: color, pixels: fitted)
    }

    /// Each pixel made a `factor` × `factor` block: a page drawn at 300 dpi for a 600 dpi printer.
    public func enlarged(_ factor: Int) throws -> RasterPage {
        if factor == 1 { return self }
        guard (1...8).contains(factor) else { throw RasterError.outOfRange("enlargement out of range") }
        let (w, h, bpp) = (width * factor, height * factor, bytesPerPixel)
        guard w * h <= Self.maxPixels else { throw RasterError.outOfRange("page size out of range") }
        var out = [UInt8](repeating: 0, count: w * h * bpp)
        let line = w * bpp
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let first = y * factor * line
                    var o = first
                    for x in 0..<width {
                        for _ in 0..<factor {
                            for c in 0..<bpp { dst[o + c] = src[(y * width + x) * bpp + c] }
                            o += bpp
                        }
                    }
                    for k in 1..<factor {
                        UnsafeMutableRawPointer(dst.baseAddress! + first + k * line).copyMemory(from: dst.baseAddress! + first, byteCount: line)
                    }
                }
            }
        }
        return try RasterPage(width: w, height: h, color: color, pixels: out)
    }
}

/// What every page of one raster job shares: format, resolution, color, the paper (its PWG self-describing name and its size
/// in hundredths of a millimetre, as `media-col` gives it), two-sided printing and how the back is turned.
public struct RasterJob: Sendable, Equatable {
    public var format: RasterFormat
    public var dpi: Int
    public var color: RasterColor
    public var mediaName: String
    public var widthHmm: Int
    public var heightHmm: Int
    public var pages: Int
    public var duplex = false
    /// Two-sided along the short edge (calendar style).
    public var tumble = false
    public var back: BackSide = .normal
    /// IPP `print-quality`: 3 draft, 4 normal, 5 high; 0 the printer's default.
    public var quality = 0
    /// The paper type keyword (`media-type`, e.g. `photographic-glossy`), written in a PWG raster header.
    public var mediaType: String?
    /// PCLm's strip height in pixels (`pclm-strip-height-preferred`).
    public var stripHeight = 16
    /// PCLm's strips with PDF's RunLengthDecode instead of FlateDecode (`pclm-compression-method-preferred`).
    public var runLength = false

    public init(_ format: RasterFormat, dpi: Int, color: RasterColor, mediaName: String, widthHmm: Int, heightHmm: Int, pages: Int) {
        (self.format, self.dpi, self.color, self.mediaName) = (format, dpi, color, mediaName)
        (self.widthHmm, self.heightHmm, self.pages) = (widthHmm, heightHmm, pages)
    }

    /// Pixels across the paper at `dpi`.
    public var widthPixels: Int { Self.pixels(widthHmm, dpi) }
    public var heightPixels: Int { Self.pixels(heightHmm, dpi) }

    /// The paper in points (1/72 in), as PWG raster's PageSize and PCLm's MediaBox give it.
    public var widthPoints: Double { Double(widthHmm) * 72 / 2540 }
    public var heightPoints: Double { Double(heightHmm) * 72 / 2540 }

    /// .NET's Math.Round: half to even.
    public static func pixels(_ hundredthsOfMm: Int, _ dpi: Int) -> Int {
        (Double(hundredthsOfMm) * Double(dpi) / 2540).rounded(.toNearestOrEven).clampedInt
    }

    /// The turn a page gets (cross-feed, feed: -1 mirrors that direction): fronts never; backs as the printer asks, as CUPS's
    /// `cupsRasterInitPWGHeader` and PWG 5102.4 set CrossFeedTransform and FeedTransform for each `BackSide`.
    public func transform(_ pageIndex: Int) -> (crossFeed: Int, feed: Int) {
        guard duplex, pageIndex % 2 == 1 else { return (1, 1) }
        switch back {
        case .flipped: return tumble ? (-1, 1) : (1, -1)
        case .manualTumble: return tumble ? (-1, -1) : (1, 1)
        case .rotated: return tumble ? (1, 1) : (-1, -1)
        case .normal: return (1, 1)
        }
    }

    /// Why this job can't be written, or nil: sizes and counts checked before anything is allocated.
    public func problem() -> String? {
        if !(72...2400).contains(dpi) { return "resolution out of range" }
        if !(500...200_000).contains(widthHmm) || !(500...500_000).contains(heightHmm) { return "paper size out of range" }
        if widthPixels * heightPixels > RasterPage.maxPixels { return "page too large" }
        if !(1...100_000).contains(pages) { return "page count out of range" }
        if !(1...4096).contains(stripHeight) { return "strip height out of range" }
        return nil
    }
}

extension Double {
    /// This number as an Int, NaN and values past Int's range clamped (a hostile size never traps).
    var clampedInt: Int {
        if isNaN { return 0 }
        if self >= 9.2e18 { return Int.max }
        if self <= -9.2e18 { return Int.min }
        return Int(self)
    }
}

/// Writes one raster job page by page into `bytes` (a page's pixels are let go once it is written); `drain` hands over what
/// was written so far, so a long job can go to a file as it is made.
public class RasterWriter {
    public let job: RasterJob
    public private(set) var written = 0
    /// What was written and not drained yet.
    var bytes: [UInt8] = []
    /// Bytes written since the start, drained ones included (PCLm's offsets).
    private(set) var at = 0

    init(_ job: RasterJob) throws {
        if let problem = job.problem() { throw RasterError.outOfRange(problem) }
        self.job = job
    }

    public static func forJob(_ job: RasterJob) throws -> RasterWriter {
        switch job.format {
        case .pwgRaster: try PwgRasterWriter(job)
        case .urf: try UrfWriter(job)
        case .pclm: try PclmWriter(job)
        }
    }

    /// The next page, the paper's size in pixels at the job's resolution and color.
    public func write(_ page: RasterPage) throws {
        guard written < job.pages else { throw RasterError.pageCount("more pages than the job said") }
        guard page.width == job.widthPixels, page.height == job.heightPixels, page.color == job.color else { throw RasterError.pageMismatch }
        writePage(page, written)
        written += 1
    }

    /// Ends the document (PCLm's page tree, cross-reference table and trailer). Every page must have been written.
    public func finish() throws {
        guard written == job.pages else { throw RasterError.pageCount("fewer pages than the job said") }
        writeEnd()
    }

    /// What was written since the last drain.
    public func drain() -> [UInt8] {
        defer { bytes = [] }
        return bytes
    }

    func writePage(_ page: RasterPage, _ index: Int) {}

    func writeEnd() {}

    func put(_ b: [UInt8]) {
        bytes += b
        at += b.count
    }

    func put(_ b: UInt8) {
        bytes.append(b)
        at += 1
    }

    func put(_ s: String) { put(Array(s.utf8)) }
}
