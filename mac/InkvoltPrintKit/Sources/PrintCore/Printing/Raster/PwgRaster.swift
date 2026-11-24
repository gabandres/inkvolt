import Foundation

/// The page data compression PWG Raster (PWG 5102.4 §4.3.1.2) and Apple Raster share: each line starts with a line repeat
/// count (0-255: the line is used 1-256 times), then runs of pixels: 0-127 means the next pixel 1-128 times, 129-255 means
/// 257 minus it (2-128) pixels as they are. 128 is never written (Apple Raster reads it as "white to the end of the line", PWG
/// Raster doesn't define it). A page's transform (back sides) mirrors the lines and their order here.
enum RasterLines {
    static func write(_ out: inout [UInt8], _ page: RasterPage, _ transform: (crossFeed: Int, feed: Int)) {
        let bpp = page.bytesPerPixel
        let lineBytes = page.bytesPerLine
        var current = [UInt8](repeating: 0, count: lineBytes)
        var next = [UInt8](repeating: 0, count: lineBytes)
        var packed = [UInt8](repeating: 0, count: lineBytes + (page.width + 127) / 128 + page.width + 1) // every pixel its own run byte
        line(page, 0, transform, &current)
        var y = 0
        while y < page.height {
            var repeatCount = 1
            var haveNext = false
            while y + repeatCount < page.height {
                line(page, y + repeatCount, transform, &next)
                if repeatCount == 256 || next != current {
                    haveNext = true
                    break
                }
                repeatCount += 1
            }
            out.append(UInt8(repeatCount - 1))
            let n = pack(current, bpp, &packed)
            out += packed[0..<n]
            y += repeatCount
            if haveNext { swap(&current, &next) }
        }
    }

    /// Output line `y`: the page's line, from the bottom when the feed is mirrored, reversed when the cross-feed is.
    static func line(_ page: RasterPage, _ y: Int, _ transform: (crossFeed: Int, feed: Int), _ into: inout [UInt8]) {
        let source = transform.feed < 0 ? page.height - 1 - y : y
        let lineBytes = page.bytesPerLine
        let bpp = page.bytesPerPixel
        let w = page.width
        page.pixels.withUnsafeBufferPointer { src in
            into.withUnsafeMutableBufferPointer { dst in
                let row = src.baseAddress! + source * lineBytes
                if transform.crossFeed > 0 {
                    UnsafeMutableRawPointer(dst.baseAddress!).copyMemory(from: row, byteCount: lineBytes)
                    return
                }
                for x in 0..<w {
                    for c in 0..<bpp { dst[x * bpp + c] = row[(w - 1 - x) * bpp + c] }
                }
            }
        }
    }

    /// One line's runs into `into`; returns the bytes written.
    static func pack(_ line: [UInt8], _ bpp: Int, _ into: inout [UInt8]) -> Int {
        let n = line.count / bpp
        var o = 0
        line.withUnsafeBufferPointer { l in
            into.withUnsafeMutableBufferPointer { d in
                func same(_ a: Int, _ b: Int) -> Bool {
                    for c in 0..<bpp where l[a * bpp + c] != l[b * bpp + c] { return false }
                    return true
                }
                var i = 0
                while i < n {
                    if i + 1 < n && same(i, i + 1) {
                        var run = 2
                        while i + run < n && run < 128 && same(i, i + run) { run += 1 }
                        d[o] = UInt8(run - 1)
                        o += 1
                        for c in 0..<bpp { d[o + c] = l[i * bpp + c] }
                        o += bpp
                        i += run
                        continue
                    }
                    var count = 1 // pixels that differ from the one after them
                    while i + count < n && count < 128 && !(i + count + 1 < n && same(i + count, i + count + 1)) { count += 1 }
                    d[o] = count == 1 ? 0 : UInt8(257 - count)
                    o += 1
                    for k in 0..<count * bpp { d[o + k] = l[i * bpp + k] }
                    o += count * bpp
                    i += count
                }
            }
        }
        return o
    }
}

/// PWG Raster (PWG 5102.4-2012, `image/pwg-raster`): the sync word `RaS2`, then per page a 1796-byte header (big-endian, the
/// field offsets of §4.3.1.1 Table 1) and the compressed lines. Grey is `sgray_8` (ColorSpace 18), color `srgb_8`
/// (ColorSpace 19), chunky; reserved fields are zero.
public final class PwgRasterWriter: RasterWriter {
    public static let headerBytes = 1796
    public static let sgrayColorSpace = 18, srgbColorSpace = 19

    override init(_ job: RasterJob) throws {
        try super.init(job)
        put(Array("RaS2".utf8))
    }

    override func writePage(_ page: RasterPage, _ index: Int) {
        let transform = job.transform(index)
        put(Self.header(job, transform))
        var lines: [UInt8] = []
        RasterLines.write(&lines, page, transform)
        put(lines)
    }

    /// A page's header. Exposed for the byte tests.
    static func header(_ job: RasterJob, _ transform: (crossFeed: Int, feed: Int)) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: headerBytes)
        func u32(_ at: Int, _ v: Int) {
            let u = UInt32(truncatingIfNeeded: v)
            (h[at], h[at + 1], h[at + 2], h[at + 3]) = (UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF))
        }
        /// A 64-byte string field: US-ASCII, NUL-terminated and padded (at most 63 characters; others become '?').
        func text(_ at: Int, _ s: String) {
            for (k, scalar) in s.unicodeScalars.prefix(63).enumerated() { h[at + k] = scalar.isASCII ? UInt8(scalar.value) : UInt8(ascii: "?") }
        }
        let grey = job.color == .gray8
        let bitsPerPixel = grey ? 8 : 24
        text(0, "PwgRaster")                          // MediaClass: always "PwgRaster"
        text(128, job.mediaType ?? "")                // MediaType
        u32(272, job.duplex ? 1 : 0)                  // Duplex
        u32(276, job.dpi)                             // HWResolution: cross feed
        u32(280, job.dpi)                             //               feed
        u32(352, job.widthPoints.rounded(.toNearestOrEven).clampedInt) // PageSize, points
        u32(356, job.heightPoints.rounded(.toNearestOrEven).clampedInt)
        u32(368, job.tumble ? 1 : 0)                  // Tumble
        u32(372, job.widthPixels)                     // Width
        u32(376, job.heightPixels)                    // Height
        u32(384, 8)                                   // BitsPerColor
        u32(388, bitsPerPixel)                        // BitsPerPixel
        u32(392, job.widthPixels * bitsPerPixel / 8)  // BytesPerLine
        u32(396, 0)                                   // ColorOrder: chunky
        u32(400, grey ? sgrayColorSpace : srgbColorSpace) // ColorSpace
        u32(420, grey ? 1 : 3)                        // NumColors
        u32(452, job.pages)                           // TotalPageCount
        u32(456, transform.crossFeed)                 // CrossFeedTransform (signed)
        u32(460, transform.feed)                      // FeedTransform
        u32(472, job.widthPixels)                     // ImageBoxRight (Left and Top stay 0)
        u32(476, job.heightPixels)                    // ImageBoxBottom
        u32(480, 0x00FF_FFFF)                         // AlternatePrimary: white in sRGB
        u32(484, job.quality)                         // PrintQuality: 0 default, 3 draft, 4 normal, 5 high
        text(1732, job.mediaName)                     // PageSizeName: the PWG self-describing name
        return h
    }
}

/// Apple Raster (`image/urf`): `UNIRAST` and a NUL, the page count (big-endian), then per page a 32-byte header (bits per
/// pixel; color space 0 sGray, 1 sRGB; duplex 1 one-sided, 2 short edge, 3 long edge; quality; width, height and resolution as
/// big-endian 32-bit numbers at 12, 16 and 20) and the lines compressed as PWG Raster's. The layout CUPS reads and writes
/// (`cups/raster-stream.c`, `CUPS_RASTER_SYNCapple`).
public final class UrfWriter: RasterWriter {
    public static let headerBytes = 32

    override init(_ job: RasterJob) throws {
        try super.init(job)
        put(Array("UNIRAST".utf8) + [0] + Self.be32(job.pages))
    }

    override func writePage(_ page: RasterPage, _ index: Int) {
        put(Self.header(job))
        var lines: [UInt8] = []
        RasterLines.write(&lines, page, job.transform(index))
        put(lines)
    }

    static func header(_ job: RasterJob) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: headerBytes)
        let grey = job.color == .gray8
        h[0] = grey ? 8 : 24
        h[1] = grey ? 0 : 1
        h[2] = !job.duplex ? 1 : job.tumble ? 2 : 3
        h[3] = UInt8([3, 4, 5].contains(job.quality) ? job.quality : 4)
        h.replaceSubrange(12..<16, with: be32(job.widthPixels))
        h.replaceSubrange(16..<20, with: be32(job.heightPixels))
        h.replaceSubrange(20..<24, with: be32(job.dpi))
        return h
    }

    static func be32(_ v: Int) -> [UInt8] {
        let u = UInt32(truncatingIfNeeded: v)
        return [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }
}
