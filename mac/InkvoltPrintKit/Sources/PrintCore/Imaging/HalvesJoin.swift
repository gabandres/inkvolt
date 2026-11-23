import Foundation

/// Where the second half goes, beside the first: to its right, below it, to its left or above it.
public enum JoinSide: Int, CaseIterable, Sendable { case right, below, left, above }

/// Where the second half lies on the first: `side`, turned half a turn (`turned`: the original was turned round on the glass
/// for its other half), and its top-left corner at (`x`, `y`) in the first half's pixels (negative: left of or above it).
public struct JoinPlacement: Equatable, Sendable {
    public var side: JoinSide
    public var turned: Bool
    public var x: Int, y: Int

    public init(_ side: JoinSide, _ turned: Bool, _ x: Int, _ y: Int) {
        self.side = side
        self.turned = turned
        self.x = x
        self.y = y
    }

    /// The same placement in pixels `factor` times as many (a smaller or larger copy of both halves).
    public func scaled(_ factor: Double) -> JoinPlacement {
        JoinPlacement(side, turned, HalvesJoin.rounded(Double(x) * factor), HalvesJoin.rounded(Double(y) * factor))
    }

    /// Moved by (`dx`, `dy`) pixels: the manual nudge.
    public func nudged(_ dx: Int, _ dy: Int) -> JoinPlacement {
        JoinPlacement(side, turned, x.addingReportingOverflow(dx).partialValue, y.addingReportingOverflow(dy).partialValue)
    }
}

/// What `HalvesJoin.find` found: the best placement, whether it is sure of it (else it's a guess to nudge), its match and the
/// next best placement's.
public struct JoinFound: Equatable, Sendable {
    public var placement: JoinPlacement
    public var sure: Bool
    public var score: Double
    public var next = -1.0

    public init(_ placement: JoinPlacement, _ sure: Bool, _ score: Double, next: Double = -1) {
        self.placement = placement
        self.sure = sure
        self.score = score
        self.next = next
    }
}

/// Joins two halves of an original too big for the glass, each scanned with an overlap (roadmap 4.8, the Windows app's
/// `HalvesJoin`, as Canon IJ Scan Utility's stitch): the overlap is found by matching the two scans (normalized
/// cross-correlation, coarse at about 12 pixels an inch over every side, either way up, then fine), and the halves are drawn
/// onto one page, the seam in the middle of the overlap. The halves come straightened (each page's own edits); only a shift
/// is looked for. When the match isn't clearly better than any other, the best guess is given as not sure, to be nudged by
/// hand. Pixels are grey or RGB (Windows: BGR), rows packed.
public enum HalvesJoin {
    /// The overlap looked for, inches: at least this much, at most `maxOverlapShare` of the half.
    public static let minOverlap = 0.3, maxOverlapShare = 0.8

    /// How far (inches) the halves may be offset along the seam.
    public static let maxShift = 1.5

    /// The match a sure overlap needs, and how far ahead of the next best placement it must be: the next leaves `lead` times
    /// as much unmatched (1 − its score) or more. A grid or ruled lines match almost as well a step away; what is drawn on
    /// them doesn't.
    public static let sureScore = 0.7, lead = 2.0

    /// The largest page a join makes (pixels): past it the halves aren't joined.
    public static let maxPixels = PageCleanup.maxPixels

    private static let coarsePpi = 12.0, minSpread = 6.0

    /// The longest side of the coarse copies every placement is tried on (a 33 inch half at 12 pixels an inch).
    public static let maxCoarseSide = 400

    /// How many of the coarse search's best placements are refined.
    private static let refinedCount = 6

    /// The longest side of a copy `find` reads (its sums are kept per row).
    public static let maxSide = 20_000

    /// .NET's `Math.Round` (to even) of a value that fits; 0 for one that doesn't (never a trap).
    static func rounded(_ v: Double) -> Int { Int(exactly: v.rounded(.toNearestOrEven)) ?? 0 }

    /// The overlap of `first` and `second` (grey copies at `ppi` pixels an inch, both the same), as a placement in those
    /// pixels.
    /// - Throws: `CancellationError` when `stop` fires.
    public static func find(_ first: GrayImage, _ second: GrayImage, ppi: Double, stop: BatchStop? = nil) throws -> JoinFound {
        let fallback = JoinFound(edgeToEdge(.right, false, first.width, first.height, second.width, second.height), false, 0)
        let longest = max(first.width, first.height, second.width, second.height)
        if !(ppi >= 4 && ppi <= 10_000) || first.width < 8 || first.height < 8 || second.width < 8 || second.height < 8 || longest > maxSide
            || first.pixels.count < first.width * first.height || second.pixels.count < second.width * second.height {
            return fallback // nothing to match, or not the analysis copies it is made for
        }
        // About 12 pixels an inch, and never more than maxCoarseSide pixels a side: a huge page's every-placement search stays seconds.
        let factor = max(max(1, rounded(ppi / coarsePpi)), (longest + maxCoarseSide - 1) / maxCoarseSide)
        let a = shrink(first, factor)
        let coarse = ppi / Double(factor)
        let turnedSecond = turned(second)
        var candidates: [(placement: JoinPlacement, score: Double)] = []
        for isTurned in [false, true] {
            let b = shrink(isTurned ? turnedSecond : second, factor)
            for side in JoinSide.allCases {
                try stop?.check()
                candidates += try search(a, b, side, isTurned, coarse, stop)
            }
        }
        if candidates.isEmpty { return fallback }
        // The best few placements, each at least half an inch from a better one (a grid or ruled lines repeat: the coarse
        // copies can take a step of them for the overlap), each refined on the copies given; the best of those, if well ahead
        // of the rest.
        let far = coarse / 2
        var tops: [(placement: JoinPlacement, score: Double)] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            if tops.contains(where: { t in t.placement.side == c.placement.side && t.placement.turned == c.placement.turned
                && Double(abs(t.placement.x - c.placement.x)) <= far && Double(abs(t.placement.y - c.placement.y)) <= far }) { continue }
            tops.append(c)
            if tops.count == refinedCount { break }
        }
        // Refined on copies at half the size given (when that still has 30 pixels an inch), then the best on the copies given.
        // Coarse copies made smaller than usual (a huge page) are refined on copies twice as large each time first, so no step
        // looks far.
        let half = ppi >= 60 ? 2 : 1
        var steps: [Int] = []
        if factor > rounded(ppi / coarsePpi) {
            var f = factor / 2
            while f >= half * 2 {
                steps.append(f)
                f /= 2
            }
        }
        steps.append(half)
        var refined = tops
        var from = factor
        for step in steps {
            let (stepFirst, stepSecond, stepTurned) = (shrink(first, step), shrink(second, step), shrink(turnedSecond, step))
            let scale = Double(from) / Double(step)
            for i in refined.indices {
                refined[i] = try refine(stepFirst, refined[i].placement.turned ? stepTurned : stepSecond, refined[i].placement.scaled(scale),
                                        Int((scale / 2).rounded(.up)) + 1, stop) // bounded: scale is a ratio of two small factors
            }
            from = step
        }
        let bestIndex = refined.indices.max { refined[$0].score < refined[$1].score }!
        let best = refined[bestIndex]
        let other = refined.indices.filter { $0 != bestIndex }.map { refined[$0].score }.max() ?? -1
        let (placement, score) = try half == 1 ? best
            : refine(first, best.placement.turned ? turnedSecond : second, best.placement.scaled(Double(half)), half + 1, stop)
        // Ahead of the next: what the next leaves unmatched at least twice what the best does (a near-perfect match needs little
        // lead, a fair one a lot).
        return JoinFound(placement, score >= sureScore && 1 - other >= lead * (1 - best.score), max(0, score), next: other)
    }

    /// The best placement within `reach` pixels of `near`, and its match.
    private static func refine(_ a: GrayImage, _ b: GrayImage, _ near: JoinPlacement, _ reach: Int, _ stop: BatchStop?) throws -> (placement: JoinPlacement, score: Double) {
        var (fx, fy, fine) = (near.x, near.y, -Double.infinity)
        for dy in -reach...reach {
            try stop?.check()
            for dx in -reach...reach {
                let score = ncc(a, b, near.x + dx, near.y + dy, minArea: 1)
                if score > fine { (fx, fy, fine) = (near.x + dx, near.y + dy, score) }
            }
        }
        return (JoinPlacement(near.side, near.turned, fx, fy), fine)
    }

    /// A placement found on copies `factor` times smaller (`gray`, `shrink`) in the full-size pixels. A copy leaves out the
    /// last (size mod factor) columns and rows of the half, which, turned, are its first: a turned second half (`secondWidth`
    /// × `secondHeight` at full size) moves back by them.
    public static func fromCopy(_ at: JoinPlacement, factor: Int, secondWidth: Int, secondHeight: Int) -> JoinPlacement {
        if factor <= 1 { return at }
        return at.turned ? JoinPlacement(at.side, true, at.x * factor - secondWidth % factor, at.y * factor - secondHeight % factor)
            : at.scaled(Double(factor))
    }

    /// A full-size placement on copies `factor` times smaller: `fromCopy` the other way.
    public static func toCopy(_ at: JoinPlacement, factor: Int, secondWidth: Int, secondHeight: Int) -> JoinPlacement {
        if factor <= 1 { return at }
        return at.turned
            ? JoinPlacement(at.side, true, rounded(Double(at.x + secondWidth % factor) / Double(factor)), rounded(Double(at.y + secondHeight % factor) / Double(factor)))
            : at.scaled(1 / Double(factor))
    }

    /// The second half edge to edge with the first on `side`, centred along the seam: where a hand nudge starts.
    public static func edgeToEdge(_ side: JoinSide, _ turned: Bool, _ w1: Int, _ h1: Int, _ w2: Int, _ h2: Int) -> JoinPlacement {
        switch side {
        case .right: JoinPlacement(side, turned, w1, (h1 - h2) / 2)
        case .left: JoinPlacement(side, turned, -w2, (h1 - h2) / 2)
        case .below: JoinPlacement(side, turned, (w1 - w2) / 2, h1)
        case .above: JoinPlacement(side, turned, (w1 - w2) / 2, -h2)
        }
    }

    /// The two halves on one page (rows of width × `channels` bytes, 1 grey or 3 RGB, both alike): the first, and the second
    /// turned as `at` says, each up to the middle of their overlap; what neither covers is white. Nil when the page would be
    /// larger than `maxPixels` or the pixels don't fit their sizes.
    public static func join(_ first: [UInt8], _ w1: Int, _ h1: Int, _ second: [UInt8], _ w2: Int, _ h2: Int, channels: Int,
                            _ at: JoinPlacement) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard channels == 1 || channels == 3, w1 >= 1, h1 >= 1, w2 >= 1, h2 >= 1,
              w1 <= first.count / h1 / channels, w2 <= second.count / h2 / channels, // all there (divided: no overflow)
              abs(at.x) <= 1 << 30, abs(at.y) <= 1 << 30 else { return nil }
        let (x0, y0) = (min(0, at.x), min(0, at.y))
        let (x1, y1) = (max(w1, at.x + w2), max(h1, at.y + h2))
        let (width, height) = (x1 - x0, y1 - y0)
        guard width <= maxPixels, height <= maxPixels / width else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * channels)
        // The seam: the middle of the overlap across the join (or where they meet when they don't overlap).
        let seam: Double = switch at.side {
        case .right: Double(at.x + w1) / 2
        case .left: Double(at.x + w2) / 2
        case .below: Double(at.y + h1) / 2
        case .above: Double(at.y + h2) / 2
        }
        first.withUnsafeBufferPointer { f in
            second.withUnsafeBufferPointer { s in
                pixels.withUnsafeMutableBufferPointer { buffer in
                    let out = buffer
                    eachRow(height) { y in
                        let py = y + y0
                        for x in 0..<width {
                            let px = x + x0
                            let inFirst = px >= 0 && py >= 0 && px < w1 && py < h1
                            var (sx, sy) = (px - at.x, py - at.y)
                            let inSecond = sx >= 0 && sy >= 0 && sx < w2 && sy < h2
                            if !inFirst && !inSecond { continue }
                            let secondSide: Bool = switch at.side {
                            case .right: Double(px) >= seam
                            case .left: Double(px) < seam
                            case .below: Double(py) >= seam
                            case .above: Double(py) < seam
                            }
                            let to = (y * width + x) * channels
                            if inSecond && (!inFirst || secondSide) {
                                if at.turned { (sx, sy) = (w2 - 1 - sx, h2 - 1 - sy) }
                                let from = (sy * w2 + sx) * channels
                                for c in 0..<channels { out[to + c] = s[from + c] }
                            } else {
                                let from = (py * w1 + px) * channels
                                for c in 0..<channels { out[to + c] = f[from + c] }
                            }
                        }
                    }
                }
            }
        }
        return (pixels, width, height)
    }

    /// A grey copy `factor` times smaller (each pixel the average of its square), from grey or RGB pixels.
    public static func gray(_ pixels: [UInt8], _ width: Int, _ height: Int, channels: Int, factor: Int) -> GrayImage {
        let factor = max(1, factor)
        let (w, h) = (max(1, width / factor), max(1, height / factor))
        var result = [UInt8](repeating: 255, count: w * h)
        pixels.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { buffer in
                let out = buffer
                eachRow(h) { y in
                    for x in 0..<w {
                        var sum = 0, n = 0
                        for yy in (y * factor)..<min(height, (y + 1) * factor) {
                            for xx in (x * factor)..<min(width, (x + 1) * factor) {
                                let i = (yy * width + xx) * channels
                                sum += channels == 1 ? Int(src[i]) : (Int(src[i + 2]) * 114 + Int(src[i + 1]) * 587 + Int(src[i]) * 299) / 1000
                                n += 1
                            }
                        }
                        out[y * w + x] = n == 0 ? 255 : UInt8(sum / n)
                    }
                }
            }
        }
        return GrayImage(w, h, result)
    }

    /// A copy `factor` times smaller in each direction, grey or RGB (for the join's preview).
    public static func shrink(_ pixels: [UInt8], _ width: Int, _ height: Int, channels: Int, factor: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let factor = max(1, factor)
        let (w, h) = (max(1, width / factor), max(1, height / factor))
        var result = [UInt8](repeating: 255, count: w * h * channels)
        pixels.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { buffer in
                let out = buffer
                eachRow(h) { y in
                    for x in 0..<w {
                        for c in 0..<channels {
                            var sum = 0, n = 0
                            for yy in (y * factor)..<min(height, (y + 1) * factor) {
                                for xx in (x * factor)..<min(width, (x + 1) * factor) {
                                    sum += Int(src[(yy * width + xx) * channels + c])
                                    n += 1
                                }
                            }
                            out[(y * w + x) * channels + c] = n == 0 ? 255 : UInt8(sum / n)
                        }
                    }
                }
            }
        }
        return (result, w, h)
    }

    private static func shrink(_ img: GrayImage, _ factor: Int) -> GrayImage {
        factor == 1 ? img : gray(img.pixels, img.width, img.height, channels: 1, factor: factor)
    }

    private static func turned(_ img: GrayImage) -> GrayImage { GrayImage(img.width, img.height, img.pixels.reversed()) }

    /// Every placement of `b` on `a`'s `side` with its match score, on the coarse copies.
    private static func search(_ a: GrayImage, _ b: GrayImage, _ side: JoinSide, _ isTurned: Bool, _ ppi: Double, _ stop: BatchStop?) throws
        -> [(placement: JoinPlacement, score: Double)] {
        let across = side == .right || side == .left
        let span = across ? min(a.width, b.width) : min(a.height, b.height)
        let minOverlapPx = max(2, Int((minOverlap * ppi).rounded(.up))) // bounded: ppi is checked by find
        let maxOverlapPx = Int(Double(span) * maxOverlapShare) // bounded: a side of at most maxSide
        let shift = Int((maxShift * ppi).rounded(.up)) // bounded: as above
        if maxOverlapPx < minOverlapPx { return [] }
        let found = Shared([(placement: JoinPlacement, score: Double)]())
        let overlaps = Array(minOverlapPx...maxOverlapPx)
        try cleanupRows(overlaps.count, stop) { k in
            let overlap = overlaps[k]
            var here: [(placement: JoinPlacement, score: Double)] = []
            for s in -shift...shift {
                let (x, y): (Int, Int) = switch side {
                case .right: (a.width - overlap, (a.height - b.height) / 2 + s)
                case .left: (overlap - b.width, (a.height - b.height) / 2 + s)
                case .below: ((a.width - b.width) / 2 + s, a.height - overlap)
                case .above: ((a.width - b.width) / 2 + s, overlap - b.height)
                }
                let score = ncc(a, b, x, y, minArea: 4 * minOverlapPx * minOverlapPx)
                if score > -Double.infinity { here.append((JoinPlacement(side, isTurned, x, y), score)) }
            }
            found.withLock { $0 += here }
        }
        // In a fixed order whatever order the rows ran in, so the same halves always give the same answer.
        return found.withLock { $0 }.sorted { ($0.placement.x, $0.placement.y) < ($1.placement.x, $1.placement.y) }
    }

    /// How alike the two are where `b`, its top-left at (`x`, `y`), lies over `a`: −1 to 1; −∞ when the overlap is smaller
    /// than `minArea` or either side of it is plain.
    private static func ncc(_ a: GrayImage, _ b: GrayImage, _ x: Int, _ y: Int, minArea: Int) -> Double {
        let (x0, y0) = (max(0, x), max(0, y))
        let (x1, y1) = (min(a.width, x + b.width), min(a.height, y + b.height))
        if x1 <= x0 || y1 <= y0 || (x1 - x0) * (y1 - y0) < minArea { return -Double.infinity }
        // A large overlap (the fine search) is read every other row, a huge one (a huge page's) on about a million pixels:
        // plenty to tell a match by, in a fraction of the time.
        let area = (x1 - x0) * (y1 - y0)
        let rowStep = area > 100_000 ? max(2, area / 1_000_000) : 1
        // The sums kept in the closure's own variables (captured ones are boxed, which a debug build pays for at every pixel).
        let (aw, bw, span) = (a.width, b.width, x1 - x0)
        let (sa, sb, saa, sbb, sab, count) = a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb -> (Int, Int, Int, Int, Int, Int) in
                var (sa, sb, saa, sbb, sab, count) = (0, 0, 0, 0, 0, 0)
                var py = y0
                while py < y1 {
                    var p = pa.baseAddress! + (py * aw + x0)
                    var q = pb.baseAddress! + ((py - y) * bw + x0 - x)
                    var (ra, rb, raa, rbb, rab) = (0, 0, 0, 0, 0)
                    for _ in 0..<span {
                        let va = Int(p.pointee), vb = Int(q.pointee)
                        ra &+= va
                        rb &+= vb
                        raa &+= va &* va
                        rbb &+= vb &* vb
                        rab &+= va &* vb
                        p += 1
                        q += 1
                    }
                    sa += ra
                    sb += rb
                    saa += raa
                    sbb += rbb
                    sab += rab
                    count += span
                    py += rowStep
                }
                return (sa, sb, saa, sbb, sab, count)
            }
        }
        let n = Double(count)
        let varA = Double(saa) - Double(sa) * Double(sa) / n
        let varB = Double(sbb) - Double(sb) * Double(sb) / n
        if varA < minSpread * minSpread * n || varB < minSpread * minSpread * n { return -Double.infinity } // plain paper: nothing to match
        return (Double(sab) - Double(sa) * Double(sb) / n) / (varA * varB).squareRoot()
    }
}
