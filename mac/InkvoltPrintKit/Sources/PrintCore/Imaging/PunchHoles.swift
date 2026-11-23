import Foundation

/// A punch hole found on a page: its centre and radius in the page's pixels.
public struct PunchHole: Equatable, Sendable {
    public var x: Double, y: Double, radius: Double

    public init(_ x: Double, _ y: Double, _ radius: Double) {
        self.x = x
        self.y = y
        self.radius = radius
    }
}

/// Removes punch holes (roadmap 4.7, the Windows app's `PunchHoles`, as Epson Scan 2's punch hole removal): the dark round
/// shadows a two- or three-hole punched sheet leaves near its edges (the feeder's backing or the lid's shadow seen through the
/// hole), each filled with the paper's color around it. Only what is surely a hole is touched: round (a disc, or a ring around
/// one), 0.14 to 0.5 inch across, its centre within `band` inch of an edge, whole on the page and on its own (nothing within a
/// sixteenth of an inch around it), so a letter "O" in a line of text, a bullet, a logo in the page's middle or a hole cut by
/// the page's edge stay. Grey or RGB pixels, rows packed.
public enum PunchHoles {
    /// How far from an edge (inches) a hole's centre may be: punches put them 0.3 to 0.6 inch in.
    public static let band = 1.0

    /// A hole's size across (inches): 4 to 10 mm holes, with their shadow.
    public static let minSide = 0.14, maxSide = 0.5

    private static let maxAspect = 1.35, minFill = 0.78, maxFill = 1.15, gap = 0.06, halo = 0.03, maxOthers = 0.04

    /// How much darker than the paper a hole's shadow is (on the grid's averaged cells).
    private static let contrast = 45

    /// At most this many holes on a page: more round marks along the edges are a pattern, not punching.
    public static let maxHoles = 12

    /// Fills each hole found with the paper's color around it, in place; returns how many.
    /// - Throws: `CancellationError` when `stop` fires.
    public static func remove(_ pixels: inout [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ dpi: Int, stop: BatchStop? = nil) throws -> Int {
        let holes = try find(pixels, width, height, channels, dpi, stop: stop)
        for hole in holes {
            try stop?.check()
            fill(&pixels, width, height, channels, hole, dpi)
        }
        return holes.count
    }

    /// The holes on the page, in the page's pixels; none when it is too small to hold one or not sure.
    public static func find(_ pixels: [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ dpi: Int, stop: BatchStop? = nil) throws -> [PunchHole] {
        guard width >= 1, height >= 1, dpi >= 30, dpi <= 9600, channels == 1 || channels == 3,
              width <= pixels.count / height / channels, // all of it there (no overflow: divided, not multiplied)
              Double(min(width, height)) >= 2 * maxSide * Double(dpi) else { return [] }

        // A grid of about 50 cells an inch, each its average lightness.
        let step = max(1, Int((Double(dpi) / 50).rounded(.toNearestOrEven))) // bounded: dpi is at most 9600
        let (gw, gh) = (width / step, height / step)
        let cpi = Double(dpi) / Double(step)
        var grid = [UInt8](repeating: 0, count: gw * gh)
        try pixels.withUnsafeBufferPointer { src in
            try grid.withUnsafeMutableBufferPointer { dst in
                let out = dst
                try cleanupRows(gh, stop) { gy in
                    for gx in 0..<gw {
                        var sum = 0
                        for y in (gy * step)..<((gy + 1) * step) {
                            for x in (gx * step)..<((gx + 1) * step) {
                                let i = (y * width + x) * channels
                                sum += channels == 1 ? Int(src[i]) : (Int(src[i + 2]) * 114 + Int(src[i + 1]) * 587 + Int(src[i]) * 299) / 1000
                            }
                        }
                        out[gy * gw + gx] = UInt8(sum / (step * step))
                    }
                }
            }
        }
        let paper = GrayImage.median(GrayImage(gw, gh, grid), 0, 0, gw, gh)
        if paper < 128 { return [] } // a dark page or a photo: no paper to tell a hole from
        let mask = grid.map { Int($0) < paper - contrast }

        let edgeBand = band * cpi
        var holes: [PunchHole] = []
        var seen = [Bool](repeating: false, count: mask.count)
        var queue: [Int] = []
        var cells: [Int] = []
        for start in mask.indices {
            if !mask[start] || seen[start] { continue }
            let (sx, sy) = (start % gw, start / gw)
            if Double(sx) > edgeBand && Double(sx) < Double(gw - 1) - edgeBand && Double(sy) > edgeBand && Double(sy) < Double(gh - 1) - edgeBand { continue } // never near an edge
            cells.removeAll(keepingCapacity: true)
            seen[start] = true
            queue = [start]
            var head = 0
            var (minX, maxX, minY, maxY) = (sx, sx, sy, sy)
            while head < queue.count {
                let i = queue[head]
                head += 1
                cells.append(i)
                let (x, y) = (i % gw, i / gw)
                (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
                for n in [x > 0 ? i - 1 : -1, x < gw - 1 ? i + 1 : -1, y > 0 ? i - gw : -1, y < gh - 1 ? i + gw : -1] where n >= 0 && mask[n] && !seen[n] {
                    seen[n] = true
                    queue.append(n)
                }
            }
            if let found = hole(mask, gw, gh, cells, minX, minY, maxX, maxY, cpi, edgeBand) {
                holes.append(PunchHole((found.x + 0.5) * Double(step), (found.y + 0.5) * Double(step), found.radius * Double(step) + halo * Double(dpi)))
                if holes.count > maxHoles { return [] }
            }
        }
        return holes
    }

    /// The component as a hole on the grid (centre and radius in cells), or nil when it isn't surely one.
    private static func hole(_ mask: [Bool], _ gw: Int, _ gh: Int, _ cells: [Int], _ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int,
                             _ cpi: Double, _ band: Double) -> PunchHole? {
        if minX == 0 || minY == 0 || maxX == gw - 1 || maxY == gh - 1 { return nil } // cut by the page's edge: not sure
        let (w, h) = (maxX - minX + 1, maxY - minY + 1)
        if Double(min(w, h)) < minSide * cpi || Double(max(w, h)) > maxSide * cpi || Double(max(w, h)) > maxAspect * Double(min(w, h)) { return nil }
        let (cx, cy) = (Double(minX) + Double(w - 1) / 2, Double(minY) + Double(h - 1) / 2)
        if min(min(cx, Double(gw - 1) - cx), min(cy, Double(gh - 1) - cy)) > band { return nil }

        // Its outline filled (a ring's middle is the hole too), then how round: a disc fills π/4 of its box.
        let (pw, ph) = (w + 2, h + 2)
        var own = [Bool](repeating: false, count: pw * ph)
        for i in cells { own[(i / gw - minY + 1) * pw + i % gw - minX + 1] = true }
        PhotoFinder.fillHoles(&own, pw, ph)
        let area = own.reduce(0) { $0 + ($1 ? 1 : 0) }
        let fill = Double(area) / (Double.pi / 4 * Double(w) * Double(h))
        if fill < minFill || fill > maxFill { return nil }

        // On its own: around it, within the gap, next to nothing else dark (a letter has neighbours in its line).
        let g = max(1, Int((gap * cpi).rounded(.up))) // bounded: cpi is at most 50-odd cells an inch
        let (x0, y0, x1, y1) = (max(0, minX - g), max(0, minY - g), min(gw - 1, maxX + g), min(gh - 1, maxY + g))
        var others = 0, ring = 0
        for y in y0...y1 {
            for x in x0...x1 {
                if x >= minX && x <= maxX && y >= minY && y <= maxY { continue }
                ring += 1
                if mask[y * gw + x] { others += 1 }
            }
        }
        if ring == 0 || Double(others) > maxOthers * Double(ring) { return nil }
        return PunchHole(cx, cy, Double(max(w, h)) / 2)
    }

    /// The hole's disc painted with the paper's color around it (each channel's median just outside), its rim blended.
    private static func fill(_ pixels: inout [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ hole: PunchHole, _ dpi: Int) {
        let r = hole.radius
        let outer = r + max(2, 0.06 * Double(dpi))
        var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: channels)
        var counted = 0
        // bounded: a hole's centre and radius are inside the page's own pixels
        let (x0, y0) = (max(0, Int((hole.x - outer).rounded(.down))), max(0, Int((hole.y - outer).rounded(.down))))
        let (x1, y1) = (min(width - 1, Int((hole.x + outer).rounded(.up))), min(height - 1, Int((hole.y + outer).rounded(.up))))
        if x0 > x1 || y0 > y1 { return }
        func distance(_ x: Int, _ y: Int) -> Double { ((Double(x) - hole.x) * (Double(x) - hole.x) + (Double(y) - hole.y) * (Double(y) - hole.y)).squareRoot() }
        for y in y0...y1 {
            for x in x0...x1 {
                let d = distance(x, y)
                if d <= r || d > outer { continue }
                let i = (y * width + x) * channels
                for c in 0..<channels { histograms[c][Int(pixels[i + c])] += 1 }
                counted += 1
            }
        }
        if counted == 0 { return }
        var paper = [Double](repeating: 255, count: channels)
        for c in 0..<channels {
            var seen = 0
            for level in 0..<256 {
                seen += histograms[c][level]
                if seen * 2 > counted {
                    paper[c] = Double(level)
                    break
                }
            }
        }

        let soft = 1.5 // pixels of rim blended into what's around
        for y in y0...y1 {
            for x in x0...x1 {
                let d = distance(x, y)
                if d > r + soft { continue }
                let weight = d <= r ? 1 : (r + soft - d) / soft
                let i = (y * width + x) * channels
                for c in 0..<channels {
                    let v = Double(pixels[i + c])
                    pixels[i + c] = UInt8(min(255, max(0, (v + (paper[c] - v) * weight).rounded(.toNearestOrEven))))
                }
            }
        }
    }
}
