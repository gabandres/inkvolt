import Foundation

// Cleaning a scanned page for text recognition (Inkvolt PDF's Recognize Text, roadmap 2.2) and reading which way it lies
// (Inkvolt Print's pages turned upright, roadmap 4.3): the Windows app's shared `InkvoltPrint.Core/Imaging/ScanCleanup.cs`,
// ported as is (plain loops over grey bytes) so the decisions (skew, sideways, upside down) are the same on both platforms.
// In PrintCore, as on Windows in the shared core; Inkvolt PDF's PdfCore adds its cancel token (Ocr/ScanCleanup.swift).
// Colour pixels are RGB on the Mac (Windows renders BGR).

/// Rows `0..<count` split over the cores, as .NET's `Parallel.For`. Each row writes only its own pixels, so handing the
/// body to the other threads is safe though Swift can't prove it.
func eachRow(_ count: Int, _ body: (Int) -> Void) {
    try? cleanupRows(count, nil, body) // throws only when a stop fires, and there is none
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

/// Cleans a scanned page before text recognition: `Deskew` (up to ±15° here), `PageRotate`, `Upright`, `CleanupSmooth`,
/// `PaperLevel`, `CleanupDespeckle`, each its own type as on Windows.
public enum ScanCleanup {
    /// The largest skew straightened (a sheet laid on the glass by hand, a feeder that grabbed it crooked).
    public static let maxSkew = 15.0

    /// `pixels` (rows of `width` × `channels` bytes, 1 = grey, 3 = RGB) at `dpi`. `keepColor` also returns the cleaned page
    /// in colour (RGB input only).
    /// - Throws: `CancellationError` when `stop` fires.
    public static func clean(_ pixels: [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ dpi: Int, keepColor: Bool,
                             stop: BatchStop?) throws -> CleanedScan {
        var gray = channels == 1 ? pixels : try CleanupGray.of(pixels, width, height, stop)
        let factor = max(1, Int((Double(dpi) / 100).rounded(.toNearestOrEven))) // bounded: dpi is an Int
        let (skew, sideways, axisSure) = linesOf(downscale(GrayImage(width, height, gray), factor))
        try stop?.check()

        if skew != 0 { gray = PageRotate.rotate(gray, width, height, width, 1, -skew) }
        var smooth = try CleanupSmooth.median3(gray, width, height, stop)
        try stop?.check()
        let paper = PaperLevel.estimate(smooth, width, height, dpi)
        PaperLevel.whiten(&smooth, paper)
        let specks = try CleanupDespeckle.remove(&smooth, width, height, dpi, stop)
        try stop?.check()

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
        linesOf(downscale(gray, max(1, Int((Double(dpi) / 100).rounded(.toNearestOrEven))))).skew // bounded: dpi is an Int
    }

    /// The skew, whether the lines run down the page (it lies sideways), and whether that was clear. Lines are looked for
    /// across the page and down it (on the page turned a quarter): the way they line up more sharply is theirs. The search
    /// goes a degree past `maxSkew` so a page at the limit isn't at the edge of it. Turning about the centre and
    /// straightening about the centre commute, so the skew found on the turned copy straightens the page itself.
    public static func linesOf(_ small: GrayImage) -> (skew: Double, sideways: Bool, sure: Bool) {
        let across = Deskew.measure(small, maxAngle: maxSkew + 1)
        let down = Deskew.measure(GrayImage(small.height, small.width, turn(small.pixels, small.width, small.height, 1, 1)), maxAngle: maxSkew + 1)
        let sideways = down.strength > across.strength * 1.15
        let sure = sideways || across.strength > down.strength * 1.15
        let skew = sideways ? down.angle : across.angle
        return (abs(skew) > maxSkew + 0.25 ? 0 : skew, sideways, sure)
    }

    /// Luma of RGB pixels (the weights Rec. 601 uses, in integers).
    public static func toGray(_ rgb: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        (try? CleanupGray.of(rgb, width, height, nil)) ?? [] // throws only when a stop fires, and there is none
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

/// The paper's own level across the page (grey recycled paper, a lid's shadow, yellowed edges), so it can be evened out:
/// each pixel is divided by the paper behind it, and what is then nearly white becomes white. The paper is the bright end
/// (90th percentile) of each block about a sixth of an inch square; a dark block (a photo, a black bar) takes its
/// neighbours' paper instead, so it stays dark.
public enum PaperLevel {
    /// After evening out, levels at or above this share of white become white.
    public static let white = 0.92

    /// One level per block, read bilinearly between block centres (`PageCleanup` reads the same map).
    public typealias Map = PaperMap

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

    /// Divides each pixel by the paper behind it and turns the nearly white to white (in place).
    public static func whiten(_ gray: inout [UInt8], _ paper: Map, white: Double = PaperLevel.white) {
        let (width, height) = (paper.width, paper.height)
        let whiteF = Float(white), limit = 255 * Float(white)
        gray.withUnsafeMutableBufferPointer { buf in
            let g = buf
            eachRow(height) { y in
                let levels = UnsafeMutableBufferPointer<Float>.allocate(capacity: width)
                defer { levels.deallocate() }
                paper.row(y, into: levels)
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
        cleanedGray.withUnsafeBufferPointer { cg in
            rgb.withUnsafeMutableBufferPointer { buf in
                let c = buf
                eachRow(height) { y in
                    let levels = UnsafeMutableBufferPointer<Float>.allocate(capacity: width)
                    defer { levels.deallocate() }
                    paper.row(y, into: levels)
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

/// Whether a straightened page of horizontal text lines is upside down. In Latin script far more ink rises above the
/// middle of a line (capitals, b d f h k l t, accents, the dots of i and j) than hangs below it (g j p q y), so the side of
/// each line's middle band with more ink is the top. Which way the lines run is `Deskew.measure`'s to say.
public enum Upright {
    private static let inkContrast = 60

    /// Clear when one side has at least this much more ink than the other.
    public static let clearRatio = 1.4

    /// A run of inked rows taller than this many times the page's lines is left out (a picture, a shaded box; a heading
    /// twice the body's size stays).
    public static let maxLineRatio = 3.0

    /// Fewer rows than this aren't a line of text: a rule, an underline, a speck (about 100 dpi: 4 pt).
    public static let minLineRows = 6

    /// Whether the page is upside down, and whether its lines said so clearly (not for a page with almost no text).
    public static func upsideDown(_ horizontal: GrayImage) -> (upsideDown: Bool, sure: Bool) {
        let (above, below) = aboveBelow(horizontal)
        let ratio = (above + 1) / (below + 1)
        return (ratio < 1, above + below > 100 && (ratio >= clearRatio || ratio <= 1 / clearRatio))
    }

    /// Ink above and below the middle band of each text line, summed over the page. A line is a run of rows with ink, its
    /// middle band the rows at least half as inked as its fullest. A run of lines set tight (no white between) is cut at
    /// the troughs between their bands; a run shorter than `minLineRows` isn't a line, nor one more than `maxLineRatio`
    /// times as tall as the page's lines (a picture, a shaded box), which are then left out and the lines read again
    /// without them (a wide picture's rows mustn't set how faint a narrow line's ink may be).
    public static func aboveBelow(_ img: GrayImage) -> (above: Double, below: Double) {
        if img.width <= 0 || img.height <= 0 { return (0, 0) }
        let paper = GrayImage.median(img, 0, 0, img.width, img.height)
        if paper < 128 { return (0, 0) }
        let ink = UInt8(paper - inkContrast)
        var profile = [Int](repeating: 0, count: img.height)
        img.pixels.withUnsafeBufferPointer { p in
            for y in 0..<img.height {
                for x in 0..<img.width where p[y * img.width + x] < ink { profile[y] += 1 }
            }
        }
        let first = Self.lines(profile)
        var found = first.lines
        if !first.tall.isEmpty {
            // Without the pictures' rows: what is faint beside them is ink again.
            for (start, end) in first.tall { for j in start..<end { profile[j] = 0 } }
            found = Self.lines(profile).lines
        }
        var above = 0.0, below = 0.0
        for (start, end) in found {
            let fullest = Double(peak(profile, start, end))
            var bandTop = start
            while Double(profile[bandTop]) < fullest * 0.5 { bandTop += 1 }
            var bandBottom = end - 1
            while Double(profile[bandBottom]) < fullest * 0.5 { bandBottom -= 1 }
            for j in start..<bandTop { above += Double(profile[j]) }
            for j in (bandBottom + 1)..<end { below += Double(profile[j]) }
        }
        return (above, below)
    }

    /// The profile's lines of text, and its runs far taller than them (pictures). A run is rows at least 3% as inked as the
    /// fullest; one holding several bands (rows at least half its fullest) is cut where they meet, a line each. The lines'
    /// height is the lower middle of the pieces' heights: on a page of a picture and its caption, the caption's.
    private static func lines(_ profile: [Int]) -> (lines: [(Int, Int)], tall: [(Int, Int)]) {
        let top = profile.max() ?? 0
        let floor = max(1, Double(top) * 0.03)
        var pieces: [(Int, Int)] = []
        var i = 0
        while i < profile.count {
            if Double(profile[i]) < floor {
                i += 1
                continue
            }
            let start = i
            while i < profile.count && Double(profile[i]) >= floor { i += 1 }
            if i - start < minLineRows { continue } // a rule, an underline, a speck
            pieces += split(profile, start, i)
        }
        let heights = pieces.map { $0.1 - $0.0 }.filter { $0 >= minLineRows }.sorted()
        if heights.isEmpty { return ([], []) }
        let limit = maxLineRatio * Double(heights[(heights.count - 1) / 2])
        var text: [(Int, Int)] = [], tall: [(Int, Int)] = []
        for p in pieces where p.1 - p.0 >= minLineRows {
            if Double(p.1 - p.0) > limit { tall.append(p) } else { text.append(p) }
        }
        return (text, tall)
    }

    /// A run cut between its bands (rows at least half its fullest) at the faintest row, one piece a band.
    private static func split(_ profile: [Int], _ start: Int, _ end: Int) -> [(Int, Int)] {
        let half = Double(peak(profile, start, end)) * 0.5
        var bands: [(Int, Int)] = []
        var j = start
        while j < end {
            if Double(profile[j]) < half {
                j += 1
                continue
            }
            let b = j
            while j < end && Double(profile[j]) >= half { j += 1 }
            bands.append((b, j))
        }
        var pieces: [(Int, Int)] = []
        var from = start
        for k in 0..<max(0, bands.count - 1) {
            // Where the lines meet: after the faintest row between their bands (the last, if several are as faint).
            var cut = bands[k].1
            for j in bands[k].1..<bands[k + 1].0 where profile[j] <= profile[cut] { cut = j }
            pieces.append((from, cut + 1))
            from = cut + 1
        }
        pieces.append((from, end))
        return pieces
    }

    private static func peak(_ profile: [Int], _ start: Int, _ end: Int) -> Int {
        var peak = 0
        for j in start..<end { peak = max(peak, profile[j]) }
        return peak
    }
}
