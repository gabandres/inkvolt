import Foundation

// Cleaning a scanned page before text recognition (roadmap 2.2, E14): the Windows app's shared
// `InkvoltPrint.Core/Imaging/ScanCleanup.cs` and `Deskew.Measure` in `PageImage.cs`, ported as is (plain loops over grey
// bytes) so the decisions (skew, sideways, upside down, specks) are the same on both platforms. PdfCore doesn't depend
// on PrintCore, so these live here; Inkvolt Print's own `Deskew` (PrintCore) is the older ±10° one without the line
// strength. Colour pixels are RGB on the Mac (Windows renders BGR).

/// An 8-bit greyscale image, row by row with no padding (0 black, 255 white).
public struct GrayImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(_ width: Int, _ height: Int, _ pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// The level most of the area has (the median): the paper on a document.
    static func median(_ img: GrayImage, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        img.pixels.withUnsafeBufferPointer { p in
            for y in y0..<y1 {
                for x in x0..<x1 { histogram[Int(p[y * img.width + x])] += 1 }
            }
        }
        let half = (x1 - x0) * (y1 - y0) / 2
        var seen = 0
        for level in 0..<256 {
            seen += histogram[level]
            if seen > half { return level }
        }
        return 255
    }
}

/// Rows `0..<count` split over the cores, as .NET's `Parallel.For`. Each row writes only its own pixels, so handing the
/// body to the other threads is safe though Swift can't prove it.
private func eachRow(_ count: Int, _ body: (Int) -> Void) {
    if count <= 0 { return }
    let chunks = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
    withoutActuallyEscaping(body) { body in
        let shared = RowBody(run: body)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let start = count * c / chunks, end = count * (c + 1) / chunks
            for y in start..<end { shared.run(y) }
        }
    }
}

private struct RowBody: @unchecked Sendable {
    let run: (Int) -> Void
}

/// Skew detection by projection profile (the Windows app's `Deskew.Measure`): the ink is projected onto lines at each
/// candidate angle, and text lines line up into sharp peaks only at the page's true angle.
public enum Deskew {
    /// Smaller skews aren't worth re-encoding the page for.
    public static let minAngle = 0.4

    private static let inkContrast = 60
    private static let minInkPixels = 200
    private static let maxInkPixels = 40_000

    /// How far the page's content is turned, in degrees, clockwise positive as seen on screen (0 when straight enough or
    /// unclear), and how sharply the ink lines up into lines at it: the best angle's profile score over the average
    /// angle's (1 for no lines at all; 1.25 or more is a page of lines).
    public static func measure(_ img: GrayImage, maxAngle: Double) -> (angle: Double, strength: Double) {
        let (x0, y0) = (Int(Double(img.width) * 0.03), Int(Double(img.height) * 0.03))
        let (x1, y1) = (img.width - x0, img.height - y0)
        if x1 - x0 < 16 || y1 - y0 < 16 { return (0, 1) }
        let paper = GrayImage.median(img, x0, y0, x1, y1)
        if paper < 128 { return (0, 1) }
        let ink = UInt8(paper - inkContrast)

        // Ink pixels, relative to the centre; evenly thinned out on busy pages.
        var total = 0
        img.pixels.withUnsafeBufferPointer { p in
            for y in y0..<y1 {
                for x in x0..<x1 where p[y * img.width + x] < ink { total += 1 }
            }
        }
        if total < minInkPixels { return (0, 1) }
        let step = max(1, total / maxInkPixels)
        let (cx, cy) = (Double(img.width) / 2, Double(img.height) / 2)
        var xs: [Float] = [], ys: [Float] = []
        xs.reserveCapacity(total / step + 1)
        ys.reserveCapacity(total / step + 1)
        img.pixels.withUnsafeBufferPointer { p in
            var i = 0
            for y in y0..<y1 {
                for x in x0..<x1 where p[y * img.width + x] < ink {
                    if i % step == 0 {
                        xs.append(Float(Double(x) - cx))
                        ys.append(Float(Double(y) - cy))
                    }
                    i += 1
                }
            }
        }
        let diagonal = (Double(img.width) * Double(img.width) + Double(img.height) * Double(img.height)).squareRoot()
        var bins = [Int](repeating: 0, count: Int(diagonal.rounded(.up)) + 2)

        func score(_ degrees: Double) -> Double {
            let (s, c) = (sin(degrees * .pi / 180), cos(degrees * .pi / 180))
            let offset = bins.count / 2
            return bins.withUnsafeMutableBufferPointer { b in
                for k in 0..<b.count { b[k] = 0 }
                xs.withUnsafeBufferPointer { px in
                    ys.withUnsafeBufferPointer { py in
                        for k in 0..<px.count {
                            let projected = Double(py[k]) * c - Double(px[k]) * s
                            let bin = Int(projected.rounded(.toNearestOrEven)) + offset
                            if bin >= 0 && bin < b.count { b[bin] += 1 }
                        }
                    }
                }
                var sum = 0.0
                for v in b { sum += Double(v) * Double(v) }
                return sum
            }
        }

        // Coarse, then fine around the best.
        let coarse = 0.5, fine = 0.05
        let steps = Int(maxAngle / coarse)
        var scores = [Double](repeating: 0, count: 2 * steps + 1)
        var best = 0
        for k in scores.indices {
            scores[k] = score(Double(k - steps) * coarse)
            if scores[k] > scores[best] { best = k }
        }
        let mean = scores.reduce(0, +) / Double(scores.count)
        let strength = mean > 0 ? scores[best] / mean : 1
        if best == 0 || best == scores.count - 1 { return (0, strength) } // at the edge of the range: not a small skew
        if strength < 1.25 { return (0, strength) } // a flat profile: no lines to go by

        var angle = Double(best - steps) * coarse
        var bestScore = scores[best]
        var a = angle - coarse + fine
        let end = angle + coarse - fine / 2
        while a < end {
            let s = score(a)
            if s > bestScore { (bestScore, angle) = (s, a) }
            a += fine
        }
        angle = (angle / fine).rounded(.toNearestOrEven) * fine
        return (abs(angle) < minAngle ? 0 : angle, mean > 0 ? bestScore / mean : strength)
    }
}

/// Arbitrary-angle rotation of raw pixels (straightening a page), bilinear, same size, uncovered corners white.
public enum PageRotate {
    /// `pixels` turned `degrees` clockwise (as seen on screen) about the centre. `channels`: 1 for grey, 3 for RGB; rows
    /// are `stride` bytes apart.
    public static func rotate(_ pixels: [UInt8], _ width: Int, _ height: Int, _ stride: Int, _ channels: Int, _ degrees: Double,
                              fill: UInt8 = 255) -> [UInt8] {
        var result = [UInt8](repeating: fill, count: pixels.count)
        let (s, c) = (sin(degrees * .pi / 180), cos(degrees * .pi / 180))
        let (cx, cy) = (Double(width - 1) / 2, Double(height - 1) / 2)
        let fillD = Double(fill)
        pixels.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                let out = dst
                eachRow(height) { y in
                    let dy = Double(y) - cy
                    for x in 0..<width {
                        // Where this output pixel comes from in the original.
                        let dx = Double(x) - cx
                        let sx = c * dx + s * dy + cx
                        let sy = -s * dx + c * dy + cy
                        if sx <= -1 || sy <= -1 || sx >= Double(width) || sy >= Double(height) { continue }
                        let (x0, y0) = (Int(sx.rounded(.down)), Int(sy.rounded(.down)))
                        let (fx, fy) = (sx - Double(x0), sy - Double(y0))
                        for ch in 0..<channels {
                            func at(_ px: Int, _ py: Int) -> Double {
                                px < 0 || py < 0 || px >= width || py >= height ? fillD : Double(src[py * stride + px * channels + ch])
                            }
                            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
                            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
                            let value = (top * (1 - fy) + bottom * fy).rounded(.toNearestOrEven)
                            out[y * stride + x * channels + ch] = UInt8(min(max(value, 0), 255))
                        }
                    }
                }
            }
        }
        return result
    }
}

/// A scanned page made ready for text recognition: straightened (`skew` degrees undone), turned upright (`quarterTurns`
/// quarters clockwise after straightening), noise smoothed, the paper evened out to white and lone specks removed. `gray`
/// is what a recognizer reads; `rgb` (when asked for) is the same page in colour, to keep in the document. `uprightSure`
/// is false when the page's lines didn't say which way up it is (the caller may try the other way with its recognizer).
public struct CleanedScan: Sendable {
    public let gray: GrayImage
    public let skew: Double
    public let quarterTurns: Int
    public let uprightSure: Bool
    public let rgb: [UInt8]?
    public let specksRemoved: Int
}

/// Cleans a scanned page before text recognition (Recognize Text, roadmap 2.2): `Deskew` (up to ±15° here),
/// `PageRotate`, `Upright`, `Smooth`, `PaperLevel`, `Despeckle`, each its own type as on Windows.
public enum ScanCleanup {
    /// The largest skew straightened (a sheet laid on the glass by hand, a feeder that grabbed it crooked).
    public static let maxSkew = 15.0

    /// `pixels` (rows of `width` × `channels` bytes, 1 = grey, 3 = RGB) at `dpi`. `keepColor` also returns the cleaned
    /// page in colour (RGB input only).
    /// - Throws: `CancellationError` when `cancel` fires.
    public static func clean(_ pixels: [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ dpi: Int, keepColor: Bool = false,
                             cancel: CancelToken? = nil) throws -> CleanedScan {
        var gray = channels == 1 ? pixels : toGray(pixels, width, height)
        let factor = max(1, Int((Double(dpi) / 100).rounded(.toNearestOrEven)))
        let (skew, sideways, axisSure) = lines(downscale(GrayImage(width, height, gray), factor))
        try cancel.check()

        if skew != 0 { gray = PageRotate.rotate(gray, width, height, width, 1, -skew) }
        var smooth = Smooth.median3(gray, width, height)
        try cancel.check()
        let paper = PaperLevel.estimate(smooth, width, height, dpi)
        PaperLevel.whiten(&smooth, paper)
        let specks = try Despeckle.remove(&smooth, width, height, dpi, cancel: cancel)
        try cancel.check()

        // Lines that run down the page are turned a quarter to run across; then which way up is told by the letters.
        var small = downscale(GrayImage(width, height, smooth), factor)
        if sideways { small = GrayImage(small.height, small.width, turn(small.pixels, small.width, small.height, 1, 1)) }
        let (flipped, waySure) = Upright.upsideDown(small)
        let turns = (sideways ? 1 : 0) + (flipped ? 2 : 0)

        var rgb: [UInt8]?
        if keepColor && channels == 3 {
            var color = skew != 0 ? PageRotate.rotate(pixels, width, height, width * 3, 3, -skew) : pixels
            PaperLevel.whitenColor(&color, smooth, paper)
            rgb = turn(color, width, height, 3, turns)
        }
        let (w, h) = turns % 2 == 0 ? (width, height) : (height, width)
        return CleanedScan(gray: GrayImage(w, h, turn(smooth, width, height, 1, turns)), skew: skew, quarterTurns: turns,
                           uprightSure: axisSure && waySure, rgb: rgb, specksRemoved: specks)
    }

    /// How far a page's lines are turned (clockwise positive), up to ±`maxSkew`, measured on a copy at about 100 dpi; 0
    /// when straight or unclear. Lines that run down the page are measured on it turned a quarter.
    public static func skewOf(_ gray: GrayImage, _ dpi: Int) -> Double {
        lines(downscale(gray, max(1, Int((Double(dpi) / 100).rounded(.toNearestOrEven))))).skew
    }

    /// The skew, whether the lines run down the page (it lies sideways), and whether that was clear. Lines are looked for
    /// across the page and down it (on the page turned a quarter): the way they line up more sharply is theirs. The search
    /// goes a degree past `maxSkew` so a page at the limit isn't at the edge of it. Turning about the centre and
    /// straightening about the centre commute, so the skew found on the turned copy straightens the page itself.
    private static func lines(_ small: GrayImage) -> (skew: Double, sideways: Bool, sure: Bool) {
        let across = Deskew.measure(small, maxAngle: maxSkew + 1)
        let down = Deskew.measure(GrayImage(small.height, small.width, turn(small.pixels, small.width, small.height, 1, 1)), maxAngle: maxSkew + 1)
        let sideways = down.strength > across.strength * 1.15
        let sure = sideways || across.strength > down.strength * 1.15
        let skew = sideways ? down.angle : across.angle
        return (abs(skew) > maxSkew + 0.25 ? 0 : skew, sideways, sure)
    }

    /// Luma of RGB pixels (the weights Rec. 601 uses, in integers).
    public static func toGray(_ rgb: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        var g = [UInt8](repeating: 0, count: width * height)
        rgb.withUnsafeBufferPointer { src in
            g.withUnsafeMutableBufferPointer { dst in
                let out = dst
                eachRow(height) { y in
                    var j = y * width * 3
                    for i in (y * width)..<(y * width + width) {
                        out[i] = UInt8((Int(src[j]) * 77 + Int(src[j + 1]) * 150 + Int(src[j + 2]) * 29) >> 8)
                        j += 3
                    }
                }
            }
        }
        return g
    }

    /// Averages `factor` × `factor` blocks (a smaller copy for measuring).
    public static func downscale(_ img: GrayImage, _ factor: Int) -> GrayImage {
        if factor <= 1 { return img }
        let (w, h) = (img.width / factor, img.height / factor)
        var px = [UInt8](repeating: 0, count: w * h)
        let area = factor * factor, stride = img.width
        img.pixels.withUnsafeBufferPointer { src in
            px.withUnsafeMutableBufferPointer { dst in
                let out = dst
                eachRow(h) { y in
                    var sums = [Int](repeating: 0, count: w)
                    for dy in 0..<factor {
                        let rowStart = (y * factor + dy) * stride
                        for x in 0..<w {
                            var s = 0
                            let at = rowStart + x * factor
                            for dx in 0..<factor { s += Int(src[at + dx]) }
                            sums[x] += s
                        }
                    }
                    for x in 0..<w { out[y * w + x] = UInt8(sums[x] / area) }
                }
            }
        }
        return GrayImage(w, h, px)
    }

    /// `pixels` turned `quarters` quarter turns clockwise: a pixel at (x, y) of a W × H image goes to (H − 1 − y, x) for
    /// one turn. The same array when there's nothing to turn.
    public static func turn(_ pixels: [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ quarters: Int) -> [UInt8] {
        let q = ((quarters % 4) + 4) % 4
        if q == 0 { return pixels }
        var result = [UInt8](repeating: 0, count: pixels.count)
        let w2 = q % 2 == 0 ? width : height
        pixels.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                let out = dst
                eachRow(height) { y in
                    for x in 0..<width {
                        let (tx, ty): (Int, Int) = switch q {
                        case 1: (height - 1 - y, x)
                        case 2: (width - 1 - x, height - 1 - y)
                        default: (y, width - 1 - x)
                        }
                        let from = (y * width + x) * channels, to = (ty * w2 + tx) * channels
                        for c in 0..<channels { out[to + c] = src[from + c] }
                    }
                }
            }
        }
        return result
    }
}

/// A 3 × 3 median: takes out the paper's grain and single-pixel noise, keeps the edges of letters.
public enum Smooth {
    public static func median3(_ gray: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: gray.count)
        gray.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                let out = dst
                eachRow(height) { y in
                    let ys = (max(0, y - 1), y, min(height - 1, y + 1))
                    for x in 0..<width {
                        let xa = max(0, x - 1), xb = min(width - 1, x + 1)
                        var p = (src[ys.0 * width + xa], src[ys.0 * width + x], src[ys.0 * width + xb],
                                 src[ys.1 * width + xa], src[ys.1 * width + x], src[ys.1 * width + xb],
                                 src[ys.2 * width + xa], src[ys.2 * width + x], src[ys.2 * width + xb])
                        out[y * width + x] = median9(&p)
                    }
                }
            }
        }
        return result
    }

    /// The median of nine values by a sorting network (19 compare-exchanges).
    private static func median9(_ p: inout (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> UInt8 {
        withUnsafeMutableBytes(of: &p) { raw in
            let a = raw.bindMemory(to: UInt8.self)
            func s(_ i: Int, _ j: Int) {
                if a[i] > a[j] { a.swapAt(i, j) }
            }
            s(1, 2); s(4, 5); s(7, 8); s(0, 1); s(3, 4); s(6, 7); s(1, 2); s(4, 5); s(7, 8)
            s(0, 3); s(5, 8); s(4, 7); s(3, 6); s(1, 4); s(2, 5); s(4, 7); s(4, 2); s(6, 4); s(4, 2)
            return a[4]
        }
    }
}

/// The paper's own level across the page (grey recycled paper, a lid's shadow, yellowed edges), so it can be evened out:
/// each pixel is divided by the paper behind it, and what is then nearly white becomes white. The paper is the bright end
/// (90th percentile) of each block about a sixth of an inch square; a dark block (a photo, a black bar) takes its
/// neighbours' paper instead, so it stays dark.
public enum PaperLevel {
    /// After evening out, levels at or above this share of white become white.
    public static let white = 0.92

    public struct Map: Sendable {
        public let width: Int, height: Int, block: Int, columns: Int, rows: Int
        public let levels: [Float]

        /// The paper level at a pixel, bilinear between block centres.
        public func at(_ x: Int, _ y: Int) -> Float {
            let fx = min(max((Float(x) + 0.5) / Float(block) - 0.5, 0), Float(columns - 1))
            let fy = min(max((Float(y) + 0.5) / Float(block) - 0.5, 0), Float(rows - 1))
            let (x0, y0) = (Int(fx), Int(fy))
            let (x1, y1) = (min(x0 + 1, columns - 1), min(y0 + 1, rows - 1))
            let (ax, ay) = (fx - Float(x0), fy - Float(y0))
            let top = levels[y0 * columns + x0] * (1 - ax) + levels[y0 * columns + x1] * ax
            let bottom = levels[y1 * columns + x0] * (1 - ax) + levels[y1 * columns + x1] * ax
            return top * (1 - ay) + bottom * ay
        }
    }

    public static func estimate(_ gray: [UInt8], _ width: Int, _ height: Int, _ dpi: Int) -> Map {
        let block = max(8, dpi / 6)
        let (cols, rows) = ((width + block - 1) / block, (height + block - 1) / block)
        var levels = [Float](repeating: 0, count: cols * rows)
        gray.withUnsafeBufferPointer { src in
            levels.withUnsafeMutableBufferPointer { dst in
                let out = dst
                eachRow(rows) { by in
                    var histogram = [Int](repeating: 0, count: 256)
                    for bx in 0..<cols {
                        for k in 0..<256 { histogram[k] = 0 }
                        let (x0, y0) = (bx * block, by * block)
                        let (x1, y1) = (min(width, x0 + block), min(height, y0 + block))
                        for y in y0..<y1 {
                            for x in x0..<x1 { histogram[Int(src[y * width + x])] += 1 }
                        }
                        let target = (x1 - x0) * (y1 - y0) * 9 / 10
                        var level = 255, seen = 0
                        for v in 0..<256 {
                            seen += histogram[v]
                            if seen > target {
                                level = v
                                break
                            }
                        }
                        out[by * cols + bx] = Float(level)
                    }
                }
            }
        }

        // A block much darker than the brightest of its neighbours is content, not paper: it takes theirs.
        var grown = [Float](repeating: 0, count: levels.count)
        for by in 0..<rows {
            for bx in 0..<cols {
                var top: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let (nx, ny) = (bx + dx, by + dy)
                        if nx >= 0 && ny >= 0 && nx < cols && ny < rows { top = max(top, levels[ny * cols + nx]) }
                    }
                }
                let own = levels[by * cols + bx]
                grown[by * cols + bx] = own < top * 0.8 ? top : own
            }
        }
        // Never below mid-grey: a page that dark is a photo or a dark form, not paper to even out.
        for i in grown.indices { grown[i] = max(128, grown[i]) }
        return Map(width: width, height: height, block: block, columns: cols, rows: rows, levels: grown)
    }

    /// The paper level across one row, bilinear between block centres (what `Map.at` gives for each pixel of row `y`),
    /// worked out a row at a time so the per-pixel loop is plain arithmetic.
    fileprivate static func row(_ paper: Map, _ y: Int, _ xs: XWeights, into out: UnsafeMutableBufferPointer<Float>) {
        let fy = min(max((Float(y) + 0.5) / Float(paper.block) - 0.5, 0), Float(paper.rows - 1))
        let y0 = Int(fy)
        let y1 = min(y0 + 1, paper.rows - 1)
        let ay = fy - Float(y0)
        let c = paper.columns
        paper.levels.withUnsafeBufferPointer { l in
            for x in 0..<paper.width {
                let (x0, x1, ax) = (xs.x0[x], xs.x1[x], xs.ax[x])
                let top = l[y0 * c + x0] * (1 - ax) + l[y0 * c + x1] * ax
                let bottom = l[y1 * c + x0] * (1 - ax) + l[y1 * c + x1] * ax
                out[x] = top * (1 - ay) + bottom * ay
            }
        }
    }

    /// Each column's two block columns and its weight between them.
    fileprivate struct XWeights: @unchecked Sendable {
        var x0: [Int] = [], x1: [Int] = [], ax: [Float] = []

        init(_ paper: Map) {
            for x in 0..<paper.width {
                let fx = min(max((Float(x) + 0.5) / Float(paper.block) - 0.5, 0), Float(paper.columns - 1))
                let a = Int(fx)
                x0.append(a)
                x1.append(min(a + 1, paper.columns - 1))
                ax.append(fx - Float(a))
            }
        }
    }

    /// Divides each pixel by the paper behind it and turns the nearly white to white (in place).
    public static func whiten(_ gray: inout [UInt8], _ paper: Map, white: Double = PaperLevel.white) {
        let (width, height) = (paper.width, paper.height)
        let whiteF = Float(white), limit = 255 * Float(white)
        let xs = XWeights(paper)
        gray.withUnsafeMutableBufferPointer { buf in
            let g = buf
            eachRow(height) { y in
                let levels = UnsafeMutableBufferPointer<Float>.allocate(capacity: width)
                defer { levels.deallocate() }
                row(paper, y, xs, into: levels)
                let base = y * width
                for x in 0..<width {
                    let even = Float(g[base + x]) * 255 / levels[x]
                    g[base + x] = even >= limit ? 255 : UInt8(min(max(even / whiteF, 0), 255))
                }
            }
        }
    }

    /// The colour page evened out the same way; white wherever the cleaned grey page is white.
    public static func whitenColor(_ rgb: inout [UInt8], _ cleanedGray: [UInt8], _ paper: Map) {
        let (width, height) = (paper.width, paper.height)
        let whiteF = Float(white)
        let xs = XWeights(paper)
        cleanedGray.withUnsafeBufferPointer { cg in
            rgb.withUnsafeMutableBufferPointer { buf in
                let c = buf
                eachRow(height) { y in
                    let levels = UnsafeMutableBufferPointer<Float>.allocate(capacity: width)
                    defer { levels.deallocate() }
                    row(paper, y, xs, into: levels)
                    for x in 0..<width {
                        let i = y * width + x
                        if cg[i] == 255 {
                            c[i * 3] = 255
                            c[i * 3 + 1] = 255
                            c[i * 3 + 2] = 255
                            continue
                        }
                        let scale = 255 / levels[x] / whiteF
                        for k in 0..<3 { c[i * 3 + k] = UInt8(min(max(Float(c[i * 3 + k]) * scale, 0), 255)) }
                    }
                }
            }
        }
    }
}

/// Removes specks: small dark spots (dust, toner, a hole's shadow) with no other ink near them. Small means at most
/// `maxArea` pixels at 300 dpi (a 9 × 9 dot, scaled with the resolution); near means within `isolation` of an inch. A full
/// stop, a comma, the dot of an i or an accent is always near its letters, so it stays.
public enum Despeckle {
    public static let maxArea = 80
    public static let isolation = 1 / 20.0
    private static let ink: UInt8 = 160

    /// Turns lone specks white (in place); returns how many went.
    /// - Throws: `CancellationError` when `cancel` fires.
    public static func remove(_ gray: inout [UInt8], _ width: Int, _ height: Int, _ dpi: Int, cancel: CancelToken? = nil) throws -> Int {
        let scale = Double(dpi) / 300
        let maxArea = max(2, Int(Double(self.maxArea) * scale * scale))
        let reach = max(2, Int((Double(dpi) * isolation).rounded(.toNearestOrEven)))
        let stride = width + 1

        // Ink counts summed over the rectangle above and left of each pixel, to count the ink around a speck at once.
        var sums = [Int32](repeating: 0, count: (width + 1) * (height + 1))
        try gray.withUnsafeBufferPointer { g in
            for y in 0..<height {
                if y & 255 == 0 { try cancel.check() }
                var row: Int32 = 0
                for x in 0..<width {
                    row += g[y * width + x] < ink ? 1 : 0
                    sums[(y + 1) * stride + x + 1] = sums[y * stride + x + 1] + row
                }
            }
        }

        var seen = [Bool](repeating: false, count: gray.count)
        var stack: [Int] = []
        var pixels: [Int] = []
        var removed = 0
        try seen.withUnsafeMutableBufferPointer { seenBuf in
            let seen = seenBuf
            try sums.withUnsafeBufferPointer { sumBuf in
                let sums = sumBuf
                func inkIn(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
                    let (x0, y0, x1, y1) = (max(0, ax), max(0, ay), min(width, bx), min(height, by))
                    return Int(sums[y1 * stride + x1] - sums[y0 * stride + x1] - sums[y1 * stride + x0] + sums[y0 * stride + x0])
                }
                try gray.withUnsafeMutableBufferPointer { g in
                    for start in 0..<g.count {
                        if start % width == 0 && (start / width) & 255 == 0 { try cancel.check() }
                        if seen[start] || g[start] >= ink { continue }
                        // One spot of ink (8-connected), given up on as soon as it is too big to be a speck.
                        pixels.removeAll(keepingCapacity: true)
                        stack.append(start)
                        seen[start] = true
                        var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
                        var big = false
                        while let p = stack.popLast() {
                            let (px, py) = (p % width, p / width)
                            if !big {
                                pixels.append(p)
                                (minX, minY, maxX, maxY) = (min(minX, px), min(minY, py), max(maxX, px), max(maxY, py))
                                big = pixels.count > maxArea
                            }
                            for ny in max(0, py - 1)...min(height - 1, py + 1) {
                                for nx in max(0, px - 1)...min(width - 1, px + 1) {
                                    let n = ny * width + nx
                                    if seen[n] || g[n] >= ink { continue }
                                    seen[n] = true
                                    stack.append(n)
                                }
                            }
                        }
                        if big { continue }
                        let own = inkIn(minX, minY, maxX + 1, maxY + 1)
                        if inkIn(minX - reach, minY - reach, maxX + 1 + reach, maxY + 1 + reach) > own { continue }
                        for p in pixels { g[p] = 255 }
                        // Its soft edge (lighter than ink) goes too.
                        for y in max(0, minY - 1)...min(height - 1, maxY + 1) {
                            for x in max(0, minX - 1)...min(width - 1, maxX + 1) { g[y * width + x] = 255 }
                        }
                        removed += 1
                    }
                }
            }
        }
        return removed
    }
}

/// Whether a straightened page of horizontal text lines is upside down. In Latin script far more ink rises above the
/// middle of a line (capitals, b d f h k l t, accents, the dots of i and j) than hangs below it (g j p q y), so the side of
/// each line's middle band with more ink is the top. Which way the lines run is `Deskew.measure`'s to say.
public enum Upright {
    private static let inkContrast = 60

    /// Clear when one side has at least this much more ink than the other.
    public static let clearRatio = 1.4

    /// Whether the page is upside down, and whether its lines said so clearly (not for a page with almost no text).
    public static func upsideDown(_ horizontal: GrayImage) -> (upsideDown: Bool, sure: Bool) {
        let (above, below) = aboveBelow(horizontal)
        let ratio = (above + 1) / (below + 1)
        return (ratio < 1, above + below > 100 && (ratio >= clearRatio || ratio <= 1 / clearRatio))
    }

    /// Ink above and below the middle band of each text line, summed over the page. A line is a run of rows with ink, its
    /// middle band the rows at least half as inked as its fullest.
    public static func aboveBelow(_ img: GrayImage) -> (above: Double, below: Double) {
        let paper = GrayImage.median(img, 0, 0, img.width, img.height)
        if paper < 128 { return (0, 0) }
        let ink = UInt8(paper - inkContrast)
        var profile = [Int](repeating: 0, count: img.height)
        img.pixels.withUnsafeBufferPointer { p in
            for y in 0..<img.height {
                for x in 0..<img.width where p[y * img.width + x] < ink { profile[y] += 1 }
            }
        }
        let top = profile.max() ?? 0
        let floor = max(1, Double(top) * 0.03)
        var above = 0.0, below = 0.0
        var i = 0
        while i < profile.count {
            if Double(profile[i]) < floor {
                i += 1
                continue
            }
            let start = i
            while i < profile.count && Double(profile[i]) >= floor { i += 1 }
            let end = i // exclusive
            if end - start < 4 { continue }
            var peak = 0
            for j in start..<end { peak = max(peak, profile[j]) }
            var bandTop = start
            while Double(profile[bandTop]) < Double(peak) * 0.5 { bandTop += 1 }
            var bandBottom = end - 1
            while Double(profile[bandBottom]) < Double(peak) * 0.5 { bandBottom -= 1 }
            for j in start..<bandTop { above += Double(profile[j]) }
            for j in (bandBottom + 1)..<end { below += Double(profile[j]) }
        }
        return (above, below)
    }
}
