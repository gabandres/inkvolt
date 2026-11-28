import Foundation

// Straightened lines (roadmap 2.2, Recognize Text's cleaning): the Windows Core's `LineCurve` and `CurvedLines`
// (shared/InkvoltPrint.Core/Imaging/PageWarp.cs), ported as is so a book's page is flattened alike on both platforms.

/// Lines of text bent on the page (a book's pages curving towards its spine, photographed or scanned open), and how to
/// flatten them. Each line is shifted across its run by an amount that changes along it: at a place u along the lines, a
/// point v across them came from v + `shiftAt(u)` + `stretchAt(u)` × (v − `acrossCenter`), so lines can bow, sag towards
/// the spine and fan out (closer together at one end) at once. Past the stretch it was measured on, the map goes on with
/// the page's tilt there (`shiftSlope`, `stretchSlope`: a page flattened in place of being straightened keeps no tilt at
/// its lines' ends). Letters aren't narrowed or widened along the line: the squeeze near a spine stays, as the bend of a
/// line says how the page curves up out of the picture's plane only together with the camera's distance, which a photo
/// doesn't give.
///
/// `vertical`: the lines run down the image (a page lying sideways): u is y and v is x. `shift`: a polynomial in
/// t = (u − `alongMid`) / `alongHalf`, pixels; `stretch`: the same, pixels per pixel.
public struct LineCurve: Sendable, Equatable {
    public let vertical: Bool
    public let alongMid, alongHalf, alongFrom, alongTo: Double
    public let acrossCenter, acrossFrom, acrossTo: Double
    public let shift: [Double]
    public let stretch: [Double]
    public let shiftSlope: Double
    public let stretchSlope: Double

    public init(vertical: Bool, alongMid: Double, alongHalf: Double, alongFrom: Double, alongTo: Double, acrossCenter: Double,
                acrossFrom: Double, acrossTo: Double, shift: [Double], stretch: [Double], shiftSlope: Double = 0, stretchSlope: Double = 0) {
        self.vertical = vertical
        self.alongMid = alongMid
        self.alongHalf = alongHalf
        self.alongFrom = alongFrom
        self.alongTo = alongTo
        self.acrossCenter = acrossCenter
        self.acrossFrom = acrossFrom
        self.acrossTo = acrossTo
        self.shift = shift
        self.stretch = stretch
        self.shiftSlope = shiftSlope
        self.stretchSlope = stretchSlope
    }

    private func t(_ u: Double) -> Double { (min(max(u, alongFrom), alongTo) - alongMid) / alongHalf }

    /// How far past the measured stretch `u` is (in t), 0 inside it.
    private func beyond(_ u: Double) -> Double { (u - min(max(u, alongFrom), alongTo)) / alongHalf }

    public func shiftAt(_ u: Double) -> Double { PageWarp.eval(shift, t(u)) + shiftSlope * beyond(u) }

    public func stretchAt(_ u: Double) -> Double { PageWarp.eval(stretch, t(u)) + stretchSlope * beyond(u) }

    /// Where a point across the lines at `u` along them came from, across.
    public func sourceAcross(_ u: Double, _ v: Double) -> Double {
        v + shiftAt(u) + stretchAt(u) * (min(max(v, acrossFrom), acrossTo) - acrossCenter)
    }

    /// Where a point of the flattened image (continuous pixels) was in the bent one.
    public func source(_ x: Double, _ y: Double) -> WarpPoint {
        vertical ? WarpPoint(sourceAcross(y, x), y) : WarpPoint(x, sourceAcross(x, y))
    }

    /// The bent image's pixels flattened (same size; white where nothing comes from). Throws `CancellationError` when
    /// `stop` fires.
    public func apply(_ pixels: [UInt8], _ width: Int, _ height: Int, _ channels: Int, stop: BatchStop? = nil) throws -> [UInt8] {
        var result = [UInt8](repeating: 255, count: pixels.count)
        let along = vertical ? height : width
        let shifts = (0..<along).map { shiftAt(Double($0) + 0.5) }
        let stretches = (0..<along).map { stretchAt(Double($0) + 0.5) }
        let (vertical, from, to, centre) = (vertical, acrossFrom, acrossTo, acrossCenter)
        try pixels.withUnsafeBufferPointer { src in
            try result.withUnsafeMutableBufferPointer { dst in
                let out = dst
                try cleanupRows(height, stop) { y in
                    for x in 0..<width {
                        let (u, v) = vertical ? (y, x) : (x, y)
                        let cv = Double(v) + 0.5
                        let sv = cv + shifts[u] + stretches[u] * (min(max(cv, from), to) - centre) - 0.5
                        let (sx, sy) = vertical ? (sv, Double(y)) : (Double(x), sv)
                        PageWarp.sample(src, width, height, channels, sx, sy, out, (y * width + x) * channels)
                    }
                }
            }
        }
        return result
    }
}

/// Finds how a page's lines of text are bent (`LineCurve`), on a straightened, whitened page at about 100 dpi. The page is
/// cut into strips across its lines, a third of an inch apart; each strip's ink per row is a profile of its lines. Going
/// out from the strip with most ink near the middle, each strip's profile is matched to its neighbour's (shifted and
/// stretched by at most under half a line step, so a line is never matched to the next), and the matches, chained, say
/// where each line is in each strip; smooth curves through them (polynomials of degree 4 at most) are the map. Only when
/// sure: lines in rows (a clear line step), every match close (correlation 0.5 or more), the curves through the matches
/// within a third of a line step, the matched strips spanning most of the text, and the lines bent by `minBend` of a line
/// step or more once one tilt of the whole page is taken out (less is left as it is). A page of pictures, tables or few
/// lines is left as it is.
public enum CurvedLines {
    private static let ink: UInt8 = 128

    /// Lines bent less than this share of a line step from straight are left as they are.
    public static let minBend = 0.15

    /// The bend of `img`'s lines (full size; `vertical`: they run down it), or nil. Throws `CancellationError` when `stop`
    /// fires.
    public static func find(_ img: GrayImage, _ dpi: Int, vertical: Bool = false, stop: BatchStop? = nil) throws -> LineCurve? {
        if img.width < 64 || img.height < 64 || img.width * img.height > PageWarp.maxPixels { return nil }
        let f = max(1, Int((Double(dpi) / 100).rounded(.toNearestOrEven))) // bounded: dpi is an Int
        let small = ScanCleanup.downscale(img, f)
        let smallDpi = max(30, Double(dpi) / Double(f))
        let (along, across) = vertical ? (small.height, small.width) : (small.width, small.height)
        let sw = small.width
        let px = small.pixels
        func isInk(_ u: Int, _ v: Int) -> Bool { (vertical ? px[u * sw + v] : px[v * sw + u]) < ink }

        // Where the text is, along and across.
        var alongInk = [Int](repeating: 0, count: along)
        var acrossInk = [Int](repeating: 0, count: across)
        for u in 0..<along {
            for v in 0..<across where isInk(u, v) {
                alongInk[u] += 1
                acrossInk[v] += 1
            }
        }
        var (uFrom, uTo) = extent(alongInk, 2)
        let (vFrom, vTo) = extent(acrossInk, 2)
        if uTo - uFrom < 60 || vTo - vFrom < 30 { return nil }
        // Columns: a gap of a quarter of an inch or more with no ink all the way across the lines. Two columns' lines
        // needn't be level with each other, so only the column with most ink is measured (the others follow its map).
        (uFrom, uTo) = widestColumn(alongInk, uFrom, uTo, Int((smallDpi / 4).rounded(.up))) // bounded: smallDpi ≤ dpi
        if uTo - uFrom < 60 { return nil }
        try stop?.check()

        // Strips across the lines, about a third of an inch apart, each half again as wide.
        let stripCount = Int(Double(uTo - uFrom + 1) / (smallDpi / 3)) // bounded: under the image's size
        if stripCount < 6 { return nil }
        let spacing = Double(uTo - uFrom + 1) / Double(stripCount)
        let half = max(3, Int((spacing * 0.75).rounded(.toNearestOrEven))) // bounded: under the image's size
        var centres = [Double](repeating: 0, count: stripCount)
        var profiles = [[Double]](repeating: [], count: stripCount)
        var inkIn = [Double](repeating: 0, count: stripCount)
        for k in 0..<stripCount {
            centres[k] = Double(uFrom) + (Double(k) + 0.5) * spacing
            let (a, b) = (max(0, Int(centres[k] - Double(half))), min(along, Int(centres[k] + Double(half)))) // bounded: inside the image
            var raw = [Double](repeating: 0, count: across)
            if a < b {
                for u in a..<b {
                    for v in vFrom...vTo where isInk(u, v) { raw[v] += 1 }
                }
            }
            var smooth = [Double](repeating: 0, count: across)
            for v in vFrom...vTo { smooth[v] = (raw[max(vFrom, v - 1)] + 2 * raw[v] + raw[min(vTo, v + 1)]) / 4 }
            profiles[k] = smooth
            inkIn[k] = raw.reduce(0, +)
        }
        let minInk = 0.01 * 2 * Double(half) * Double(vTo - vFrom + 1)

        // The reference: the strip with most ink in the middle half.
        var reference = -1
        for k in (stripCount / 4)..<(stripCount - stripCount / 4) where inkIn[k] >= minInk && (reference < 0 || inkIn[k] > inkIn[reference]) {
            reference = k
        }
        if reference < 0 { return nil }
        guard let step = lineStep(profiles[reference], vFrom, vTo, smallDpi) else { return nil }
        let limit = 0.45 * step
        let vc = Double(vFrom + vTo + 1) / 2
        let halfAcross = max(vc - Double(vFrom), Double(vTo + 1) - vc)

        // Chained out from the reference: each strip against the last one matched.
        var shift = [Double?](repeating: nil, count: stripCount)
        var stretch = [Double](repeating: 0, count: stripCount)
        shift[reference] = 0
        for direction in [-1, 1] {
            var (lastK, a, b) = (reference, 0.0, 0.0)
            var k = reference + direction
            while k >= 0 && k < stripCount {
                try stop?.check()
                defer { k += direction }
                if inkIn[k] < minInk { continue }
                let m = match(profiles[lastK], profiles[k], vFrom, vTo, vc, halfAcross, limit)
                if m.corr < 0.5 { break }
                // This strip's map after the last one's: v ↦ vc + da + (1 + db)(a + (1 + b)(v − vc)).
                (a, b) = (m.a + (1 + m.b) * a, (1 + m.b) * (1 + b) - 1)
                shift[k] = a
                stretch[k] = b
                lastK = k
            }
        }
        let matched = (0..<stripCount).filter { shift[$0] != nil }
        if matched.count < 5 { return nil }
        let (first, last) = (centres[matched[0]], centres[matched[matched.count - 1]])
        if last - first < 0.6 * Double(uTo - uFrom) { return nil }

        // Smooth curves through the matches.
        let mid = (first + last) / 2
        let halfAlong = max(1, (last - first) / 2)
        let ts = matched.map { (centres[$0] - mid) / halfAlong }
        let shifts = matched.map { shift[$0] ?? 0 }
        let stretches = matched.map { stretch[$0] }
        let degree = min(4, matched.count / 2)
        guard let shiftCurve = PageWarp.fit(ts, shifts, degree), let stretchCurve = PageWarp.fit(ts, stretches, degree) else { return nil }
        for i in matched.indices {
            let miss = abs(shifts[i] - PageWarp.eval(shiftCurve, ts[i])) + abs(stretches[i] - PageWarp.eval(stretchCurve, ts[i])) * halfAcross
            if miss > step / 3 { return nil }
        }

        // Bent enough to be worth it: how far the top, middle and bottom lines are from straight once one tilt of the whole
        // page (the middle line's, Deskew's to straighten) and a shift of each line as a whole are taken out.
        let samples = (0..<41).map { -1 + Double($0) / 20 }
        func line(_ v: Double) -> [Double] { samples.map { PageWarp.eval(shiftCurve, $0) + PageWarp.eval(stretchCurve, $0) * (v - vc) } }
        guard let tilt = PageWarp.fit(samples, line(vc), 1) else { return nil }
        var bend = 0.0
        for v in [Double(vFrom), Double(vTo) + 1, vc] {
            let off = line(v).enumerated().map { $0.element - PageWarp.eval(tilt, samples[$0.offset]) }
            let mean = off.reduce(0, +) / Double(off.count)
            bend = max(bend, off.map { abs($0 - mean) }.max() ?? 0)
        }
        if bend < max(1.5, minBend * step) { return nil }

        // The same map at full size, its tilt going on past the measured stretch.
        let shiftTilt = PageWarp.fit(ts, shifts, 1)?[1] ?? 0
        let stretchTilt = PageWarp.fit(ts, stretches, 1)?[1] ?? 0
        let ff = Double(f)
        return LineCurve(vertical: vertical, alongMid: mid * ff, alongHalf: halfAlong * ff, alongFrom: first * ff, alongTo: last * ff,
                         acrossCenter: vc * ff, acrossFrom: Double(vFrom) * ff, acrossTo: (Double(vTo) + 1) * ff,
                         shift: shiftCurve.map { $0 * ff }, stretch: stretchCurve, shiftSlope: shiftTilt * ff, stretchSlope: stretchTilt)
    }

    /// Of the text from `from` to `to`, the column with most ink: the stretches between gaps of `gap` or more with no ink.
    public static func widestColumn(_ ink: [Int], _ from: Int, _ to: Int, _ gap: Int) -> (from: Int, to: Int) {
        var (best, bestInk) = ((from: from, to: to), -1)
        var start = from
        var u = from
        while u <= to + 1 {
            var empty = 0
            while u + empty <= to && ink[u + empty] < 2 { empty += 1 }
            if u <= to && (empty < gap || empty == 0) {
                u += empty + 1
                continue
            }
            let end = u - 1
            var sum = 0
            if end >= start { for k in start...end { sum += ink[k] } }
            if end >= start && sum > bestInk { (best, bestInk) = ((start, end), sum) }
            start = u + empty
            u += empty + 1
        }
        return best
    }

    /// The first and last index with at least `min` (−1, −1 when none).
    private static func extent(_ counts: [Int], _ min: Int) -> (from: Int, to: Int) {
        guard let from = counts.firstIndex(where: { $0 >= min }), let to = counts.lastIndex(where: { $0 >= min }) else { return (-1, -1) }
        return (from, to)
    }

    /// The distance from one line to the next in a profile (its autocorrelation's first clear peak, a twentieth to two
    /// thirds of an inch), or nil for no rows of lines.
    static func lineStep(_ profile: [Double], _ from: Int, _ to: Int, _ dpi: Double) -> Double? {
        let n = to - from + 1
        var mean = 0.0
        for v in from...to { mean += profile[v] }
        mean /= Double(n)
        func r(_ lag: Int) -> Double {
            var s = 0.0
            var v = from
            while v + lag <= to {
                s += (profile[v] - mean) * (profile[v + lag] - mean)
                v += 1
            }
            return s / Double(max(1, n - lag))
        }
        let r0 = r(0)
        if r0 <= 0 { return nil }
        let (minLag, maxLag) = (max(3, Int(dpi / 20)), min(n / 3, Int(dpi * 2 / 3))) // bounded: dpi is a page's
        if maxLag <= minLag + 1 { return nil }
        var rs = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) { rs[lag] = r(lag) }
        var best: Int?
        for lag in minLag...maxLag where rs[lag] >= rs[lag - 1] && rs[lag] >= rs[lag + 1] && rs[lag] >= 0.25 * r0 && (best == nil || rs[lag] > rs[best!]) {
            best = lag
        }
        return best.map(Double.init)
    }

    /// The shift and stretch that best lay `next` over `prev`: next at vc + a + (1 + b)(v − vc) matches prev at v. Searched
    /// within `limit` pixels of movement anywhere across, then refined; with the correlation it reaches.
    private static func match(_ prev: [Double], _ next: [Double], _ from: Int, _ to: Int, _ vc: Double, _ halfAcross: Double,
                              _ limit: Double) -> (a: Double, b: Double, corr: Double) {
        func corr(_ a: Double, _ b: Double) -> Double {
            var (sx, sy, sxx, syy, sxy) = (0.0, 0.0, 0.0, 0.0, 0.0)
            var n = 0
            for v in from...to {
                let at = vc + a + (1 + b) * (Double(v) + 0.5 - vc) - 0.5
                if at < Double(from) || at > Double(to) { continue }
                let i = Int(at) // bounded: between from and to (above)
                let fr = at - Double(i)
                let y = i + 1 <= to ? next[i] * (1 - fr) + next[i + 1] * fr : next[i]
                let x = prev[v]
                sx += x
                sy += y
                sxx += x * x
                syy += y * y
                sxy += x * y
                n += 1
            }
            if n < 10 { return -1 }
            let cov = sxy - sx * sy / Double(n)
            let vx = sxx - sx * sx / Double(n)
            let vy = syy - sy * sy / Double(n)
            return vx <= 0 || vy <= 0 ? -1 : cov / (vx * vy).squareRoot()
        }
        var (bestA, bestB, best) = (0.0, 0.0, corr(0, 0))
        let bLimit = limit / halfAcross
        var a = -limit
        while a <= limit {
            var b = -bLimit
            while b <= bLimit {
                if abs(a) + abs(b) * halfAcross <= limit {
                    let c = corr(a, b)
                    if c > best { (bestA, bestB, best) = (a, b, c) }
                }
                b += 0.5 / halfAcross
            }
            a += 0.5
        }
        let (a0, b0) = (bestA, bestB)
        a = a0 - 0.5
        while a <= a0 + 0.5 {
            var b = b0 - 0.5 / halfAcross
            while b <= b0 + 0.5 / halfAcross {
                if abs(a) + abs(b) * halfAcross <= limit {
                    let c = corr(a, b)
                    if c > best { (bestA, bestB, best) = (a, b, c) }
                }
                b += 0.1 / halfAcross
            }
            a += 0.1
        }
        return (bestA, bestB, best)
    }
}
