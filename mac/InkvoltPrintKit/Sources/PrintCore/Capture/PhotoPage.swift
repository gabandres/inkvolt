import Foundation

/// Pixels row by row with no padding (the Windows Core's `Picture`): `channels` 3 (red, green, blue: the Mac's order, where
/// Windows' is blue, green, red) or 1 (grey).
public struct Picture: Equatable, Sendable {
    public var pixels: [UInt8]
    public var width: Int
    public var height: Int
    public var channels: Int

    public init(_ pixels: [UInt8], _ width: Int, _ height: Int, _ channels: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.channels = channels
    }

    public var isGray: Bool { channels == 1 }
}

/// Decodes a photo whose header was checked (`CapturedPhotoInput.inspect`) and writes a page as JPEG: PrintMac's (Image I/O), a
/// fake in tests.
public protocol PhotoCodec: Sendable {
    /// The photo's pixels as stored (not turned by its EXIF orientation), RGB or grey; throws when it doesn't decode.
    func decode(_ data: [UInt8], _ header: PhotoHeader) throws -> Picture

    /// The page as a JPEG at `dpi`.
    func encodeJpeg(_ page: Picture, dpi: Int) throws -> [UInt8]
}

/// A paper size a photographed page is taken to be, by its proportions.
public struct PaperGuess: Equatable, Sendable {
    public var name: String
    public var longInches: Double

    public init(_ name: String, _ longInches: Double) {
        self.name = name
        self.longInches = longInches
    }
}

/// A photo made into a scanned page: its pixels at `dpi`, whether a page was found and straightened, and the paper it was
/// taken for.
public struct CapturedPage: Sendable {
    public var image: Picture
    public var dpi: Int
    public var straightened: Bool
    public var paper: PaperGuess
}

/// A photo of a page made into a scan (roadmap 4.6, 4.12; the Windows Core's `PhotoPage`): turned the way the camera held it
/// (EXIF orientation), the page found on a darker desk and warped back to a rectangle (`Trapezoid`, only when sure; otherwise
/// the whole photo), sized as the paper its proportions say (`paper`) at the resolution asked for, in grey when asked. A
/// photo has no resolution of its own, so its size on paper comes from the paper it's taken for; what's left of the cleanup
/// (straightening a few degrees, crop to the paper, whitening, OCR) is the scan review's, as for a scanner's page.
public enum PhotoPage {
    /// Resolutions a capture source offers (a phone's photo of a Letter page is about 350 dpi; finer would only be made up).
    public static let resolutions = [150, 200, 300]

    /// The resolution a capture scans at when `dpi` is asked: the finest of `resolutions` not above it, else the coarsest
    /// (Windows' `CaptureJob`).
    public static func captureResolution(_ dpi: Int) -> Int { resolutions.filter { $0 <= dpi }.max() ?? resolutions[0] }

    private static let papers: [(name: String, long: Double, short: Double)] = [("Letter", 11, 8.5), ("A4", 297 / 25.4, 210 / 25.4), ("Legal", 14, 8.5)]

    /// The paper a page of `longSide` × `shortSide` (any unit) is taken for: Letter, A4 or Legal when its proportions are
    /// within 4% of one; longer and narrower, a page 8.5 inches wide, or a till receipt 80 mm wide past 2.2 times as long as
    /// wide; squarer, a page 11 inches the long way. `foundPage` false (the whole frame, no page found in it): the frame's
    /// proportions are the camera's, so only a paper's own proportions count, and anything else is 11 inches the long way.
    public static func paper(_ longSide: Double, _ shortSide: Double, foundPage: Bool = true) -> PaperGuess {
        guard longSide > 0 && shortSide > 0 && longSide.isFinite && shortSide.isFinite else { return PaperGuess("Letter", 11) }
        let (long, short) = shortSide > longSide ? (shortSide, longSide) : (longSide, shortSide)
        let ratio = min(long / short, 8)
        func off(_ p: (name: String, long: Double, short: Double)) -> Double { abs(log(ratio / (p.long / p.short))) }
        var best = papers[0]
        for p in papers.dropFirst() where off(p) < off(best) { best = p }
        if off(best) <= log(1.04) { return PaperGuess(best.name, best.long) }
        if !foundPage { return PaperGuess("Photo", 11) }
        if ratio > 2.2 { return PaperGuess("Receipt", 80 / 25.4 * ratio) }
        if ratio > papers.map({ $0.long / $0.short }).max()! { return PaperGuess("Narrow", 8.5 * ratio) }
        return PaperGuess("Photo", 11)
    }

    public struct NotAPicture: Error {}

    /// The page in `photo` (as stored, `orientation` its EXIF orientation) at `dpi` (75 to 600), in grey when `gray`.
    /// `straighten`: look for the page on a desk and warp it flat. Throws `CancellationError` when `stop` fires.
    public static func make(_ photo: Picture, orientation: Int, dpi: Int, gray: Bool, straighten: Bool = true, stop: BatchStop? = nil) throws -> CapturedPage {
        guard photo.channels == 1 || photo.channels == 3, photo.width >= 1, photo.height >= 1,
              photo.width * photo.height * photo.channels == photo.pixels.count else { throw NotAPicture() }
        let dpi = min(max(dpi, 75), 600)
        var image = try orient(photo, orientation, stop: stop)
        if gray && !image.isGray { image = Picture(ScanCleanup.toGray(image.pixels, image.width, image.height), image.width, image.height, 1) }
        try stop?.check()

        let perspective = straighten
            ? try Trapezoid.find(GrayImage(image.width, image.height, image.isGray ? image.pixels : ScanCleanup.toGray(image.pixels, image.width, image.height)), stop: stop)
            : nil
        try stop?.check()

        // The page's size in the photo: the found page's sides (the mean of each opposite pair), or the whole photo.
        var across = Double(image.width), down = Double(image.height)
        if let c = perspective?.corners {
            across = (c[0].distance(to: c[1]) + c[3].distance(to: c[2])) / 2
            down = (c[0].distance(to: c[3]) + c[1].distance(to: c[2])) / 2
        }
        let paper = paper(max(across, down), min(across, down), foundPage: perspective != nil)
        let scale = paper.longInches * Double(dpi) / max(across, down) // photo pixels to page pixels
        let outW = min(max(Int((across * scale).rounded(.toNearestOrEven)), 1), CapturedPhotoInput.maxSide * 2) // bounded: across and scale finite (sides of at least a pixel, a paper of at most 8 × 3.2 inches at 600 dpi)
        let outH = min(max(Int((down * scale).rounded(.toNearestOrEven)), 1), CapturedPhotoInput.maxSide * 2) // bounded: as outW

        // Much smaller than the photo: averaged down first, so the page doesn't sparkle with the detail sampling would skip.
        let factor = max(1, Int((1 / scale).rounded(.down))) // bounded: scale is positive and finite, at least a paper's 6.9 inches at 75 dpi over the photo's side
        let source = factor > 1 ? try reduce(image, factor, stop: stop) : image
        let ch = source.channels
        var result = [UInt8](repeating: 0, count: outW * outH * ch)
        let (iw, ih) = (Double(image.width), Double(image.height))
        try source.pixels.withUnsafeBufferPointer { src in
            try result.withUnsafeMutableBufferPointer { out in
                let into = out
                try cleanupRows(outH, stop) { y in
                    for x in 0..<outW {
                        let s: WarpPoint
                        if let p = perspective {
                            let px = p.left + (Double(x) + 0.5) / Double(outW) * (p.right - p.left)
                            let py = p.top + (Double(y) + 0.5) / Double(outH) * (p.bottom - p.top)
                            s = p.source(px, py)
                        } else {
                            s = WarpPoint((Double(x) + 0.5) / Double(outW) * iw, (Double(y) + 0.5) / Double(outH) * ih)
                        }
                        PageWarp.sample(src, source.width, source.height, ch, s.x / Double(factor) - 0.5, s.y / Double(factor) - 0.5, into, (y * outW + x) * ch)
                    }
                }
            }
        }
        return CapturedPage(image: Picture(result, outW, outH, ch), dpi: dpi, straightened: perspective != nil, paper: paper)
    }

    /// The picture turned (and mirrored) the way an EXIF orientation of 1 to 8 says it is shown; any other value leaves it as
    /// it is.
    public static func orient(_ p: Picture, _ orientation: Int, stop: BatchStop? = nil) throws -> Picture {
        guard (2...8).contains(orientation) else { return p }
        let (w, h, ch) = (p.width, p.height, p.channels)
        let (ow, oh) = orientation >= 5 ? (h, w) : (w, h)
        var result = [UInt8](repeating: 0, count: p.pixels.count)
        try p.pixels.withUnsafeBufferPointer { src in
            try result.withUnsafeMutableBufferPointer { out in
                let into = out
                try cleanupRows(oh, stop) { y in
                    for x in 0..<ow {
                        let (sx, sy): (Int, Int) = switch orientation {
                        case 2: (w - 1 - x, y)
                        case 3: (w - 1 - x, h - 1 - y)
                        case 4: (x, h - 1 - y)
                        case 5: (y, x)
                        case 6: (y, h - 1 - x)
                        case 7: (w - 1 - y, h - 1 - x)
                        default: (w - 1 - y, x) // 8
                        }
                        let (from, to) = ((sy * w + sx) * ch, (y * ow + x) * ch)
                        for c in 0..<ch { into[to + c] = src[from + c] }
                    }
                }
            }
        }
        return Picture(result, ow, oh, ch)
    }

    /// Each `factor` × `factor` block averaged into one pixel.
    private static func reduce(_ p: Picture, _ factor: Int, stop: BatchStop?) throws -> Picture {
        let (w, h, ch) = (max(1, p.width / factor), max(1, p.height / factor), p.channels)
        var result = [UInt8](repeating: 0, count: w * h * ch)
        try p.pixels.withUnsafeBufferPointer { src in
            try result.withUnsafeMutableBufferPointer { out in
                let into = out
                try cleanupRows(h, stop) { y in
                    var sum = (0, 0, 0)
                    for x in 0..<w {
                        sum = (0, 0, 0)
                        var n = 0
                        var dy = 0
                        while dy < factor && y * factor + dy < p.height {
                            var dx = 0
                            while dx < factor && x * factor + dx < p.width {
                                let i = ((y * factor + dy) * p.width + x * factor + dx) * ch
                                sum.0 += Int(src[i])
                                if ch == 3 {
                                    sum.1 += Int(src[i + 1])
                                    sum.2 += Int(src[i + 2])
                                }
                                dx += 1
                                n += 1
                            }
                            dy += 1
                        }
                        let o = (y * w + x) * ch, d = max(1, n)
                        into[o] = UInt8(sum.0 / d)
                        if ch == 3 {
                            into[o + 1] = UInt8(sum.1 / d)
                            into[o + 2] = UInt8(sum.2 / d)
                        }
                    }
                }
            }
        }
        return Picture(result, w, h, ch)
    }
}
