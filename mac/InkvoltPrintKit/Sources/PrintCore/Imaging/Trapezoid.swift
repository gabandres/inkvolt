import Foundation

/// A point of a picture (continuous pixels: a pixel's centre at +0.5).
public struct WarpPoint: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to p: WarpPoint) -> Double { ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)).squareRoot() }
}

/// A projective map of the plane (a homography; the Windows Core's `Homography`): (x, y) goes to ((a x + b y + c) / w,
/// (d x + e y + f) / w) with w = g x + h y + 1. Maps the straightened page onto the photo it was taken from.
public struct Homography: Sendable, Equatable {
    private let h: [Double]

    public func apply(_ x: Double, _ y: Double) -> WarpPoint {
        let w = h[6] * x + h[7] * y + 1
        return WarpPoint((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// The map taking each of four points `from` to its partner in `to`; nil when three of them line up.
    public static func between(_ from: [WarpPoint], _ to: [WarpPoint]) -> Homography? {
        precondition(from.count == 4 && to.count == 4, "Four points each.")
        // Two equations a point: a x + b y + c − g x u − h y u = u, and the same for v.
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y, u, v) = (from[i].x, from[i].y, to[i].x, to[i].y)
            m[2 * i] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
            m[2 * i + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
        }
        // Gaussian elimination with partial pivoting.
        for col in 0..<8 {
            var pivot = col
            for r in (col + 1)..<8 where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            if abs(m[pivot][col]) < 1e-9 { return nil }
            if pivot != col { m.swapAt(col, pivot) }
            for r in 0..<8 where r != col {
                let k = m[r][col] / m[col][col]
                if k == 0 { continue }
                for j in col..<9 { m[r][j] -= k * m[col][j] }
            }
        }
        let h = (0..<8).map { m[$0][8] / m[$0][$0] }
        return h.allSatisfy(\.isFinite) ? Homography(h: h) : nil
    }
}

/// A page photographed at an angle, straightened (the Windows Core's `Perspective`): the page lies in the rectangle
/// `left`…`right` × `top`…`bottom` (its proportions as the photo shows them, centred), and `map` takes a point of it to where
/// it was in the photo. `corners`: the page's corners in the photo, clockwise from the top left.
public struct Perspective: Sendable, Equatable {
    public let map: Homography
    public let left, top, right, bottom: Double
    public let corners: [WarpPoint]

    /// Where a point of the straightened page (pixels, continuous) was in the photo.
    public func source(_ x: Double, _ y: Double) -> WarpPoint { map.apply(x, y) }

    /// The photo's pixels (rows of `width` × `channels` bytes) warped onto the straightened page: same size, white outside
    /// the page (Recognize Text's cleaning, roadmap 2.2). Throws `CancellationError` when `stop` fires.
    public func apply(_ pixels: [UInt8], _ width: Int, _ height: Int, _ channels: Int, stop: BatchStop? = nil) throws -> [UInt8] {
        var result = [UInt8](repeating: 255, count: pixels.count)
        let (l, t, r, b, map) = (left, top, right, bottom, map)
        try pixels.withUnsafeBufferPointer { src in
            try result.withUnsafeMutableBufferPointer { dst in
                let out = dst
                try cleanupRows(height, stop) { y in
                    let cy = Double(y) + 0.5
                    if cy < t || cy > b { return }
                    for x in 0..<width {
                        let cx = Double(x) + 0.5
                        if cx < l || cx > r { continue }
                        let s = map.apply(cx, cy)
                        PageWarp.sample(src, width, height, channels, s.x - 0.5, s.y - 0.5, out, (y * width + x) * channels)
                    }
                }
            }
        }
        return result
    }
}

/// Sampling shared by the warps (the Windows Core's `PageWarp`).
enum PageWarp {
    /// The largest image the warps take (pixels): a page at 300 dpi up to about 25 × 25 inches. Larger is left as it is.
    static let maxPixels = 80_000_000

    /// Bilinear sample at (`x`, `y`) (pixel indices, fractional) into `into[at…]`; white outside the image.
    @inline(__always)
    static func sample(_ pixels: UnsafeBufferPointer<UInt8>, _ width: Int, _ height: Int, _ channels: Int, _ x: Double, _ y: Double,
                       _ into: UnsafeMutableBufferPointer<UInt8>, _ at: Int) {
        guard x > -1 && y > -1 && x < Double(width) && y < Double(height) else {
            for c in 0..<channels { into[at + c] = 255 }
            return
        }
        let (x0, y0) = (Int(x.rounded(.down)), Int(y.rounded(.down))) // bounded: inside -1 < x < width, -1 < y < height (above)
        let (fx, fy) = (x - Double(x0), y - Double(y0))
        for c in 0..<channels {
            func value(_ px: Int, _ py: Int) -> Double {
                px < 0 || py < 0 || px >= width || py >= height ? 255 : Double(pixels[(py * width + px) * channels + c])
            }
            let top = value(x0, y0) * (1 - fx) + value(x0 + 1, y0) * fx
            let bottom = value(x0, y0 + 1) * (1 - fx) + value(x0 + 1, y0 + 1) * fx
            into[at + c] = UInt8(min(max((top * (1 - fy) + bottom * fy).rounded(.toNearestOrEven), 0), 255))
        }
    }

    /// A least-squares polynomial of `degree` through (t, value) points; nil when they can't fix one.
    static func fit(_ t: [Double], _ values: [Double], _ degree: Int) -> [Double]? {
        let n = degree + 1
        if t.count < n || values.count < t.count { return nil }
        var m = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for k in t.indices {
            var powers = [Double](repeating: 1, count: 2 * n)
            for i in 1..<powers.count { powers[i] = powers[i - 1] * t[k] }
            for i in 0..<n {
                for j in 0..<n { m[i][j] += powers[i + j] }
                m[i][n] += powers[i] * values[k]
            }
        }
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<max(col + 1, n) where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            if abs(m[pivot][col]) < 1e-12 { return nil }
            if pivot != col { m.swapAt(col, pivot) }
            for r in 0..<n where r != col {
                let k = m[r][col] / m[col][col]
                for j in col...n { m[r][j] -= k * m[col][j] }
            }
        }
        let coefficients = (0..<n).map { m[$0][n] / m[$0][$0] }
        return coefficients.allSatisfy(\.isFinite) ? coefficients : nil
    }

    static func eval(_ coefficients: [Double], _ t: Double) -> Double {
        var v = 0.0
        for c in coefficients.reversed() { v = v * t + c }
        return v
    }
}

/// Trapezoid correction (the Windows Core's `Trapezoid`; ABBYY's name for it): a page photographed at an angle shows as a
/// four-sided shape lighter than the desk around it. The page is the light region not reached from the photo's edges
/// through darker pixels; its outline's four sides are fitted as straight lines, and their corners give the map that
/// straightens it. Only when sure: the desk clearly darker than the paper, the page whole in the photo (no corner cut off by
/// its edge), four straight sides that the outline follows closely, corners between 50° and 130°, and the page filling its
/// four sides. A page lying square (a scan, or a photo taken straight on) isn't warped: straightening it is `Deskew`'s.
public enum Trapezoid {
    /// The page is looked for on a copy at most this many pixels across.
    public static let measureSize = 800

    /// A corner off square by less than this (degrees), with opposite sides within 1.5% of each other, is a page lying
    /// square.
    public static let squareWithin = 1.5

    /// The page's straightening, or nil when the photo shows no page on a darker desk clearly enough. Throws
    /// `CancellationError` when `stop` fires.
    public static func find(_ gray: GrayImage, stop: BatchStop? = nil) throws -> Perspective? {
        let (w, h) = (gray.width, gray.height)
        if w < 64 || h < 64 || w * h > PageWarp.maxPixels { return nil }
        let f = max(1, Int((Double(max(w, h)) / Double(measureSize)).rounded(.up))) // bounded: a picture's side over 800
        let small = ScanCleanup.downscale(gray, f)
        try stop?.check()
        guard let quad = findQuad(small) else { return nil }
        let corners = quad.map { WarpPoint($0.x * Double(f), $0.y * Double(f)) }

        // The page's proportions as the photo shows them (the mean of each pair of opposite sides), as large as fits, centred.
        let across = (corners[0].distance(to: corners[1]) + corners[3].distance(to: corners[2])) / 2
        let down = (corners[0].distance(to: corners[3]) + corners[1].distance(to: corners[2])) / 2
        if across < 1 || down < 1 { return nil }
        let scale = min(Double(w) / across, Double(h) / down)
        let (pw, ph) = (across * scale, down * scale)
        let (left, top) = ((Double(w) - pw) / 2, (Double(h) - ph) / 2)
        let rect = [WarpPoint(left, top), WarpPoint(left + pw, top), WarpPoint(left + pw, top + ph), WarpPoint(left, top + ph)]
        guard let map = Homography.between(rect, corners) else { return nil }
        return Perspective(map: map, left: left, top: top, right: left + pw, bottom: top + ph, corners: corners)
    }

    /// The page's corners on the measuring copy (continuous pixels, clockwise from the top left), or nil.
    static func findQuad(_ img: GrayImage) -> [WarpPoint]? {
        let (w, h, px) = (img.width, img.height, img.pixels)
        let n = w * h

        // Paper from desk: Otsu's threshold, and the two sides clearly apart.
        var hist = [Int](repeating: 0, count: 256)
        for p in px { hist[Int(p)] += 1 }
        var sumAll = 0.0
        for i in 0..<256 { sumAll += Double(i) * Double(hist[i]) }
        var sumDark = 0.0, bestVar = -1.0
        var dark = 0
        var threshold = 0
        for t in 0..<255 {
            dark += hist[t]
            sumDark += Double(t) * Double(hist[t])
            if dark == 0 || dark == n { continue }
            let (m0, m1) = (sumDark / Double(dark), (sumAll - sumDark) / Double(n - dark))
            let between = Double(dark) * Double(n - dark) * (m1 - m0) * (m1 - m0)
            if between > bestVar { (bestVar, threshold) = (between, t) }
        }
        var darkSum = 0.0
        var darkCount = 0
        for i in 0...threshold {
            darkSum += Double(i) * Double(hist[i])
            darkCount += hist[i]
        }
        let lightSum = sumAll - darkSum
        if darkCount == 0 || darkCount == n { return nil }
        if lightSum / Double(n - darkCount) - darkSum / Double(darkCount) < 50 { return nil }

        // The desk: dark pixels reached from the photo's edges.
        var desk = [Bool](repeating: false, count: n)
        var stack: [Int] = []
        func seed(_ i: Int) {
            if !desk[i] && Int(px[i]) <= threshold {
                desk[i] = true
                stack.append(i)
            }
        }
        for x in 0..<w {
            seed(x)
            seed((h - 1) * w + x)
        }
        for y in 0..<h {
            seed(y * w)
            seed(y * w + w - 1)
        }
        var deskCount = 0
        while let i = stack.popLast() {
            deskCount += 1
            let (x, y) = (i % w, i / w)
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        if Double(deskCount) < 0.02 * Double(n) { return nil }

        // The page: the largest region the desk doesn't reach (its print and pictures are inside it).
        var label = [Int32](repeating: 0, count: n)
        var best: Int32 = 0, bestCount = 0, next: Int32 = 0
        for start in 0..<n {
            if desk[start] || label[start] != 0 { continue }
            next += 1
            label[start] = next
            stack.append(start)
            var count = 0
            while let i = stack.popLast() {
                count += 1
                let (x, y) = (i % w, i / w)
                func visit(_ j: Int) {
                    if !desk[j] && label[j] == 0 {
                        label[j] = next
                        stack.append(j)
                    }
                }
                if x > 0 { visit(i - 1) }
                if x < w - 1 { visit(i + 1) }
                if y > 0 { visit(i - w) }
                if y < h - 1 { visit(i + w) }
            }
            if count > bestCount { (best, bestCount) = (next, count) }
        }
        if Double(bestCount) < 0.2 * Double(n) { return nil }

        // Its outline: pixels of it beside the desk. One on the photo's edge means a corner may be cut off: not sure.
        var outline: [WarpPoint] = []
        var onEdge = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if label[i] != best { continue }
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 {
                    onEdge += 1
                    continue
                }
                if label[i - 1] != best || label[i + 1] != best || label[i - w] != best || label[i + w] != best {
                    outline.append(WarpPoint(Double(x) + 0.5, Double(y) + 0.5))
                }
            }
        }
        if onEdge > 0 || outline.count < 40 { return nil }

        let four = reduce(hull(outline), 4)
        if four.count != 4 { return nil }

        // Each side fitted to the outline along its middle 80%, straight within a pixel and a half, followed nearly all along.
        var lines: [(px: Double, py: Double, dx: Double, dy: Double)] = []
        for s in 0..<4 {
            let (a, b) = (four[s], four[(s + 1) % 4])
            let len = a.distance(to: b)
            if len < 20 { return nil }
            let (dx, dy) = ((b.x - a.x) / len, (b.y - a.y) / len)
            let near = max(3, 0.03 * len)
            var bins = [Bool](repeating: false, count: 20)
            var points: [WarpPoint] = []
            for p in outline {
                let along = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len
                let off = -(p.x - a.x) * dy + (p.y - a.y) * dx
                if along < 0.1 || along > 0.9 || abs(off) > near { continue }
                points.append(p)
                bins[min(max(Int((along - 0.1) / 0.8 * 20), 0), 19)] = true
            }
            if bins.filter({ $0 }).count < 17 || points.count < 10 { return nil }
            let count = Double(points.count)
            let (mx, my) = (points.reduce(0) { $0 + $1.x } / count, points.reduce(0) { $0 + $1.y } / count)
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in points {
                sxx += (p.x - mx) * (p.x - mx)
                syy += (p.y - my) * (p.y - my)
                sxy += (p.x - mx) * (p.y - my)
            }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let (ux, uy) = (cos(angle), sin(angle))
            let rms = (points.reduce(0) { acc, p in
                let d = -(p.x - mx) * uy + (p.y - my) * ux
                return acc + d * d
            } / count).squareRoot()
            if rms > 1.5 { return nil }
            lines.append((mx, my, ux, uy))
        }

        // Corners where the sides meet: inside the photo, a convex shape, each corner 50° to 130°.
        var corners: [WarpPoint] = []
        for s in 0..<4 {
            let (p, q) = (lines[(s + 3) % 4], lines[s])
            let det = p.dx * q.dy - p.dy * q.dx
            if abs(det) < 1e-6 { return nil }
            let t = ((q.px - p.px) * q.dy - (q.py - p.py) * q.dx) / det
            let c = WarpPoint(p.px + t * p.dx, p.py + t * p.dy)
            if !(c.x >= 1 && c.y >= 1 && c.x <= Double(w - 1) && c.y <= Double(h - 1)) { return nil }
            corners.append(c)
        }
        corners = clockwise(corners)
        var angles = [Double](repeating: 0, count: 4)
        var turn: Double?
        for s in 0..<4 {
            let (prev, at, after) = (corners[(s + 3) % 4], corners[s], corners[(s + 1) % 4])
            let (ax, ay) = (prev.x - at.x, prev.y - at.y)
            let (bx, by) = (after.x - at.x, after.y - at.y)
            let cross = ax * by - ay * bx
            func signum(_ v: Double) -> Int { v > 0 ? 1 : v < 0 ? -1 : 0 }
            if let sign = turn, signum(sign) != signum(cross) { return nil }
            turn = cross
            angles[s] = abs(atan2(cross, ax * bx + ay * by)) * 180 / .pi
            if angles[s] < 50 || angles[s] > 130 { return nil }
        }

        // The page fills its four sides (not a torn sheet, nor two pages side by side).
        var area = 0.0
        for s in 0..<4 { area += corners[s].x * corners[(s + 1) % 4].y - corners[(s + 1) % 4].x * corners[s].y }
        area = abs(area) / 2
        let fill = Double(bestCount) / area
        if fill < 0.95 || fill > 1.04 { return nil }

        // Lying square: nothing to straighten here.
        let (top, right, bottom, left) = (corners[0].distance(to: corners[1]), corners[1].distance(to: corners[2]),
                                          corners[2].distance(to: corners[3]), corners[3].distance(to: corners[0]))
        if angles.allSatisfy({ abs($0 - 90) < squareWithin }) && abs(top - bottom) <= 0.015 * max(top, bottom)
            && abs(left - right) <= 0.015 * max(left, right) { return nil }
        return corners
    }

    /// Four points in clockwise order as seen (y down), the top left first.
    private static func clockwise(_ points: [WarpPoint]) -> [WarpPoint] {
        let (cx, cy) = (points.reduce(0) { $0 + $1.x } / 4, points.reduce(0) { $0 + $1.y } / 4)
        let sorted = points.enumerated().sorted { (atan2($0.element.y - cy, $0.element.x - cx), $0.offset) < (atan2($1.element.y - cy, $1.element.x - cx), $1.offset) }
            .map(\.element)
        var first = 0
        for (i, p) in sorted.enumerated() where p.x + p.y < sorted[first].x + sorted[first].y { first = i }
        return (0..<4).map { sorted[(first + $0) % 4] }
    }

    /// The convex hull (Andrew's monotone chain).
    private static func hull(_ points: [WarpPoint]) -> [WarpPoint] {
        var seen = Set<WarpPoint>()
        let p = points.filter { seen.insert($0).inserted }.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        if p.count < 3 { return p }
        func cross(_ o: WarpPoint, _ a: WarpPoint, _ b: WarpPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var hull: [WarpPoint] = []
        for q in p {
            while hull.count >= 2 && cross(hull[hull.count - 2], hull[hull.count - 1], q) <= 0 { hull.removeLast() }
            hull.append(q)
        }
        let lower = hull.count + 1
        for i in stride(from: p.count - 2, through: 0, by: -1) {
            while hull.count >= lower && cross(hull[hull.count - 2], hull[hull.count - 1], p[i]) <= 0 { hull.removeLast() }
            hull.append(p[i])
        }
        hull.removeLast()
        return hull
    }

    /// A polygon reduced to `count` corners, each time dropping the corner whose triangle with its neighbours is smallest
    /// (Visvalingam).
    private static func reduce(_ polygon: [WarpPoint], _ count: Int) -> [WarpPoint] {
        var p = polygon
        while p.count > count {
            var (smallest, at) = (Double.greatestFiniteMagnitude, -1)
            for i in 0..<p.count {
                let (a, b, c) = (p[(i + p.count - 1) % p.count], p[i], p[(i + 1) % p.count])
                let area = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
                if area < smallest { (smallest, at) = (area, i) }
            }
            p.remove(at: at)
        }
        return p
    }
}
