import Foundation

/// A black-and-white (1-bit) image (roadmap 4.4, the Windows app's `BitImage`): `height` rows of `stride` bytes, the leftmost
/// pixel in each byte's highest bit, a set bit black (ink). What `CcittG4` encodes and a black-and-white PDF page holds.
public struct BitImage: Equatable, Sendable {
    /// The most pixels an image may have (a 600 dpi A3 page is about 70 million): bounds what is allocated.
    public static let maxPixels = 200_000_000

    public enum SizeError: Error, Equatable {
        /// A side under 1 pixel, or more than `maxPixels` in all.
        case outOfRange
        /// Fewer bytes than the image's rows hold.
        case tooFewBytes
    }

    public let width: Int
    public let height: Int
    public let bits: [UInt8]

    /// - Throws: `SizeError` for a size out of range or too few bytes, before anything is allocated.
    public init(_ width: Int, _ height: Int, _ bits: [UInt8]) throws {
        guard Self.fits(width, height) else { throw SizeError.outOfRange }
        guard bits.count >= (width + 7) / 8 * height else { throw SizeError.tooFewBytes }
        self.width = width
        self.height = height
        self.bits = bits
    }

    /// A side of at least 1 and at most `maxPixels` in all (checked without overflowing).
    static func fits(_ width: Int, _ height: Int) -> Bool {
        width >= 1 && height >= 1 && width <= maxPixels && height <= maxPixels / width
    }

    /// Bytes per row: a row starts on a byte, its unused last bits are 0.
    public var stride: Int { (width + 7) / 8 }

    /// Whether the pixel at (`x`, `y`) is black.
    public subscript(x: Int, y: Int) -> Bool { bits[y * stride + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0 }

    /// All white.
    public static func white(_ width: Int, _ height: Int) throws -> BitImage {
        guard fits(width, height) else { throw SizeError.outOfRange }
        return try BitImage(width, height, [UInt8](repeating: 0, count: (width + 7) / 8 * height))
    }

    /// Grey pixels (rows of `width` bytes, 0 black) darker than `threshold` as black.
    public static func fromGray(_ gray: [UInt8], _ width: Int, _ height: Int, threshold: Int) throws -> BitImage {
        guard fits(width, height), gray.count >= width * height else { throw SizeError.outOfRange }
        let stride = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * height)
        gray.withUnsafeBufferPointer { src in
            bits.withUnsafeMutableBufferPointer { dst in
                let out = dst
                eachRow(height) { y in
                    let (row, line) = (y * width, y * stride)
                    for x in 0..<width where Int(src[row + x]) < threshold { out[line + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
                }
            }
        }
        return try BitImage(width, height, bits)
    }

    /// The rows with a set bit white instead (PDF's DeviceGray at 1 bit: 0 black, 1 white), the bits past each row's end 0.
    func inverted() -> [UInt8] {
        let stride = self.stride
        let tail = UInt8(truncatingIfNeeded: 0xFF << (8 * stride - width)) // the bits past the row's end stay 0
        var result = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for i in 0..<stride {
                let v = ~bits[y * stride + i]
                result[y * stride + i] = i == stride - 1 ? v & tail : v
            }
        }
        return result
    }
}

/// A scanned page made black and white for a small file (the Windows app's `Bilevel`): the JPEG's noise smoothed
/// (`CleanupSmooth`), the paper evened out to white (`PaperLevel`, so a lid's shadow or grey paper doesn't turn black), then
/// each pixel black or white at the level that best parts the page's ink from its paper (Otsu's), kept between
/// `minThreshold` and `maxThreshold` so a page of almost all paper or almost all ink isn't cut at an odd level.
public enum Bilevel {
    public static let minThreshold = 96, maxThreshold = 200

    /// - Parameter gray: rows of `width` bytes, 0 black, at `dpi`; not changed.
    /// - Throws: `BitImage.SizeError` for a size out of range; `CancellationError` when `stop` fires.
    public static func fromScan(_ gray: [UInt8], _ width: Int, _ height: Int, dpi: Int, stop: BatchStop? = nil) throws -> BitImage {
        guard BitImage.fits(width, height), gray.count >= width * height else { throw BitImage.SizeError.outOfRange }
        var smooth = try CleanupSmooth.median3(gray, width, height, stop)
        try stop?.check()
        PaperLevel.whiten(&smooth, PaperLevel.estimate(smooth, width, height, min(max(dpi, 50), 2400)))
        try stop?.check()
        return try BitImage.fromGray(smooth, width, height, threshold: threshold(smooth))
    }

    /// Otsu's level for the pixels (the one that best splits them into two groups), within the bounds above.
    public static func threshold(_ gray: [UInt8]) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for v in gray { histogram[Int(v)] += 1 }
        let total = gray.count
        var sumAll = 0
        for v in 0..<256 { sumAll += v * histogram[v] }
        var below = 0, sumBelow = 0
        var best = -1.0
        var level = 128
        for t in 0..<255 {
            below += histogram[t]
            sumBelow += t * histogram[t]
            let above = total - below
            if below == 0 || above == 0 { continue }
            let meanBelow = Double(sumBelow) / Double(below)
            let meanAbove = Double(sumAll - sumBelow) / Double(above)
            let between = Double(below) * Double(above) * (meanBelow - meanAbove) * (meanBelow - meanAbove)
            if between > best { (best, level) = (between, t + 1) } // pixels below t + 1 are the dark group
        }
        return min(max(level, minThreshold), maxThreshold)
    }
}
