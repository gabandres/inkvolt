import Foundation

/// Where the old page's points are on the new page: turned `angle` degrees clockwise about (`centerX`, `centerY`), then
/// shifted by (`dx`, `dy`) points (the Windows app's `PageAlignment`).
public struct PageAlignment: Sendable, Equatable {
    public var dx: Double
    public var dy: Double
    public var angle: Double
    public var centerX: Double
    public var centerY: Double

    public init(_ dx: Double, _ dy: Double, _ angle: Double, _ centerX: Double, _ centerY: Double) {
        self.dx = dx
        self.dy = dy
        self.angle = angle
        self.centerX = centerX
        self.centerY = centerY
    }

    public static let none = PageAlignment(0, 0, 0, 0, 0)

    public var isNone: Bool { dx == 0 && dy == 0 && angle == 0 }

    /// A point of the old page, on the new page.
    public func toNew(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let r = angle * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        let rx = x - centerX, ry = y - centerY
        return (centerX + rx * cos - ry * sin + dx, centerY + rx * sin + ry * cos + dy)
    }

    /// A point of the new page, on the old page.
    public func toOld(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let r = angle * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        let rx = x - dx - centerX, ry = y - dy - centerY
        return (centerX + rx * cos + ry * sin, centerY - rx * sin + ry * cos)
    }

    /// The upright box around a box of the old page, on the new page.
    public func boxToNew(_ r: RectD) -> RectD { Self.around([toNew(r.x, r.y), toNew(r.right, r.y), toNew(r.x, r.bottom), toNew(r.right, r.bottom)]) }

    /// The upright box around a box of the new page, on the old page.
    public func boxToOld(_ r: RectD) -> RectD { Self.around([toOld(r.x, r.y), toOld(r.right, r.y), toOld(r.x, r.bottom), toOld(r.right, r.bottom)]) }

    private static func around(_ p: [(x: Double, y: Double)]) -> RectD {
        RectD.fromEdges(p.map(\.x).min() ?? 0, p.map(\.y).min() ?? 0, p.map(\.x).max() ?? 0, p.map(\.y).max() ?? 0)
    }
}

/// Lines up two scans of a page before they are overlaid (the Windows app's `CompareAlign`): a page fed a little crooked
/// or a few millimetres off shouldn't read as different all over. The turn comes from each page's own lines of text
/// (`ScanCleanup.skewOf`), the shift from where the ink of the two pages falls; an alignment that doesn't make the ink
/// agree better isn't used.
public enum CompareAlign {
    /// Resolution the ink is compared at (pixels per point: 100 dpi).
    static let workScale = 100.0 / 72

    /// The pages are rendered within this many pixels (a Letter page at 100 dpi is 0.94 million): a hostile page size
    /// costs no more memory or time than a large real one. The Mac's bound; Windows renders at 100 dpi whatever the size.
    static let maxWorkPixels = 4_000_000.0

    /// Largest shift looked for, as a share of the page's sides.
    private static let maxShiftShare = 0.08

    /// Largest turn believed (degrees): as far as the scan cleanup straightens.
    private static let maxAngle = 15.0

    private static let ink: UInt8 = 160

    /// The scale two pages are lined up at: 100 dpi, lower for very large pages.
    static func workScale(_ a: PageGeometry, _ b: PageGeometry) -> Double {
        let area = max(a.width * a.height, b.width * b.height, 1)
        return min(workScale, (maxWorkPixels / area).squareRoot())
    }

    /// Finds the alignment of two pages of open documents. `PageAlignment.none` when none helps.
    /// - Throws: `CancellationError`; the engine's errors (a page it refuses).
    public static func find(_ oldPdf: PdfEngine, _ oldPage: Int, _ newPdf: PdfEngine, _ newPage: Int, cancel: CancelToken? = nil) throws -> PageAlignment {
        let scale = workScale(oldPdf.page(oldPage), newPdf.page(newPage))
        return try find(try oldPdf.render(oldPage, scale: scale, cancel: cancel),
                        try newPdf.render(newPage, scale: scale, cancel: cancel), scale, cancel: cancel)
    }

    /// - Parameter scale: pixels per point of both images.
    public static func find(_ oldImage: RenderedImage, _ newImage: RenderedImage, _ scale: Double, cancel: CancelToken? = nil) throws -> PageAlignment {
        let w = max(oldImage.width, newImage.width), h = max(oldImage.height, newImage.height)
        if w < 16 || h < 16 || Double(w) * Double(h) > maxWorkPixels * 1.5 { return .none }
        let oldGray = gray(oldImage, w, h), newGray = gray(newImage, w, h)
        let dpi = Int(exactly: (scale * 72).rounded()) ?? 100
        var turn = ScanCleanup.skewOf(GrayImage(w, h, newGray), dpi) - ScanCleanup.skewOf(GrayImage(w, h, oldGray), dpi)
        if !turn.isFinite || abs(turn) > maxAngle { turn = 0 }
        try cancel?.check()

        let cx = Double(w) / 2, cy = Double(h) / 2
        let oldInk = mask(oldGray)
        let newInk = mask(newGray)
        let plain = try shiftFor(oldInk, newInk, w, h, cancel)
        var best = (angle: 0.0, dx: plain.dx, dy: plain.dy, agreement: plain.agreement)
        // The measured turn, and the turn a hair either side of it: the two estimates each carry a little error.
        for angle in [turn, turn - 0.15, turn + 0.15] where angle != 0 {
            try cancel?.check()
            let s = try shiftFor(oldInk, mask(turned(newGray, w, h, angle, cx, cy)), w, h, cancel)
            if s.agreement > best.agreement { best = (angle, s.dx, s.dy, s.agreement) }
        }

        // Closer still: at the far edge of a page a twentieth of a degree is a third of a point.
        if best.angle != 0 {
            for angle in [best.angle - 0.05, best.angle + 0.05] {
                try cancel?.check()
                let s = try shiftFor(oldInk, mask(turned(newGray, w, h, angle, cx, cy)), w, h, cancel)
                if s.agreement > best.agreement { best = (angle, s.dx, s.dy, s.agreement) }
            }
        }

        // Only if it helps: pages unlike each other have no "right" place, and a chance overlap mustn't move one.
        let asIs = agreement(oldInk, newInk, w, h, 0, 0)
        if best.agreement <= asIs + 0.02 { return .none }
        // The shift was found on the turned page, so on the new page it is turned too.
        let r = best.angle * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        let dx = Double(best.dx), dy = Double(best.dy)
        return PageAlignment((dx * cos - dy * sin) / scale, (dx * sin + dy * cos) / scale, best.angle, cx / scale, cy / scale)
    }

    /// The new page as seen through `a`: `width` × `height` pixels of the old page's space, starting at (`x0`, `y0`)
    /// points. White where the new page doesn't reach.
    /// - Parameters:
    ///   - source: the rendered part of the new page.
    ///   - sourceX: where `source` starts on the new page, in points (and `sourceY`).
    public static func resample(_ source: RenderedImage, _ sourceX: Double, _ sourceY: Double, _ scale: Double, _ a: PageAlignment, _ width: Int, _ height: Int,
                                x0: Double = 0, y0: Double = 0, cancel: CancelToken? = nil) throws -> RenderedImage {
        let width = max(0, width), height = max(0, height)
        var output = [UInt8](repeating: 255, count: width * height * 3)
        let sw = source.width, sh = source.height, stride = source.stride
        let px = source.pixels
        func sample(_ x: Int, _ y: Int, _ c: Int) -> Double { x < 0 || y < 0 || x >= sw || y >= sh ? 255 : Double(px[y * stride + x * 3 + c]) }
        for y in 0..<height {
            if y & 63 == 0 { try cancel?.check() }
            let row = y * width * 3
            for x in 0..<width {
                let n = a.toNew(x0 + (Double(x) + 0.5) / scale, y0 + (Double(y) + 0.5) / scale)
                let sx = (n.x - sourceX) * scale - 0.5, sy = (n.y - sourceY) * scale - 0.5
                guard sx.isFinite, sy.isFinite, sx >= -1, sy >= -1, sx < Double(sw), sy < Double(sh) else { continue } // white
                let ix = Int(sx.rounded(.down)), iy = Int(sy.rounded(.down)) // bounded: finite, within -1 and the source's size (the guard above)
                let fx = sx - Double(ix), fy = sy - Double(iy)
                let at = row + x * 3
                for c in 0..<3 {
                    let top = sample(ix, iy, c) * (1 - fx) + sample(ix + 1, iy, c) * fx
                    let bottom = sample(ix, iy + 1, c) * (1 - fx) + sample(ix + 1, iy + 1, c) * fx
                    let v = top * (1 - fy) + bottom * fy
                    output[at + c] = UInt8(min(255, max(0, v + 0.5)))
                }
            }
        }
        return RenderedImage(width, height, output)
    }

    /// Brightness, the image padded with white to the common size.
    private static func gray(_ img: RenderedImage, _ w: Int, _ h: Int) -> [UInt8] {
        var gray = [UInt8](repeating: 255, count: w * h)
        for y in 0..<img.height {
            for x in 0..<img.width {
                let i = y * img.stride + x * 3
                let luma = (Int(img.pixels[i]) * 299 + Int(img.pixels[i + 1]) * 587 + Int(img.pixels[i + 2]) * 114) / 1000
                gray[y * w + x] = UInt8(luma)
            }
        }
        return gray
    }

    private static func mask(_ gray: [UInt8]) -> [Bool] { gray.map { $0 < ink } }

    /// Gray as if the page were turned back by `angle` clockwise: each pixel taken from where it was.
    private static func turned(_ gray: [UInt8], _ w: Int, _ h: Int, _ angle: Double, _ cx: Double, _ cy: Double) -> [UInt8] {
        let r = angle * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let rx = Double(x) + 0.5 - cx, ry = Double(y) + 0.5 - cy
                let fx = (cx + rx * cos - ry * sin).rounded(.down), fy = (cy + rx * sin + ry * cos).rounded(.down)
                guard fx >= 0, fy >= 0, fx < Double(w), fy < Double(h) else { continue }
                out[y * w + x] = gray[Int(fy) * w + Int(fx)]
            }
        }
        return out
    }

    /// The shift of the new ink that best meets the old: first from the ink's profile along each side, then tried around
    /// that on the pixels themselves. In whole pixels: a new pixel (x, y) lands at (x - dx, y - dy).
    private static func shiftFor(_ oldInk: [Bool], _ newInk: [Bool], _ w: Int, _ h: Int, _ cancel: CancelToken?) throws -> (dx: Int, dy: Int, agreement: Double) {
        let maxX = Int(Double(w) * maxShiftShare), maxY = Int(Double(h) * maxShiftShare)
        let dx0 = bestProfileShift(profile(oldInk, w, h, alongX: true), profile(newInk, w, h, alongX: true), maxX)
        let dy0 = bestProfileShift(profile(oldInk, w, h, alongX: false), profile(newInk, w, h, alongX: false), maxY)
        var best = (dx: dx0, dy: dy0, agreement: agreement(oldInk, newInk, w, h, dx0, dy0))
        for dy in (dy0 - 3)...(dy0 + 3) {
            try cancel?.check()
            for dx in (dx0 - 3)...(dx0 + 3) where !(dx == dx0 && dy == dy0) {
                let score = agreement(oldInk, newInk, w, h, dx, dy)
                if score > best.agreement { best = (dx, dy, score) }
            }
        }
        return best
    }

    /// Ink counted per column (along x) or per row.
    private static func profile(_ ink: [Bool], _ w: Int, _ h: Int, alongX: Bool) -> [Int] {
        var profile = [Int](repeating: 0, count: alongX ? w : h)
        for y in 0..<h {
            for x in 0..<w where ink[y * w + x] { profile[alongX ? x : y] += 1 }
        }
        return profile
    }

    private static func bestProfileShift(_ oldProfile: [Int], _ newProfile: [Int], _ max: Int) -> Int {
        var best = 0, bestScore = Int.min
        for d in -max...max {
            var score = 0
            var i = Swift.max(0, -d)
            while i < oldProfile.count && i + d < newProfile.count {
                score &+= oldProfile[i] &* newProfile[i + d]
                i += 1
            }
            if score > bestScore || (score == bestScore && abs(d) < abs(best)) {
                best = d
                bestScore = score
            }
        }
        return best
    }

    /// The share of ink the two pages have in common at this shift (Jaccard, 0 to 1).
    private static func agreement(_ oldInk: [Bool], _ newInk: [Bool], _ w: Int, _ h: Int, _ dx: Int, _ dy: Int) -> Double {
        var both = 0, either = 0
        oldInk.withUnsafeBufferPointer { old in
            newInk.withUnsafeBufferPointer { new in
                for y in 0..<h {
                    let ny = y + dy
                    let rowInside = ny >= 0 && ny < h
                    for x in 0..<w {
                        let nx = x + dx
                        let n = rowInside && nx >= 0 && nx < w && new[ny * w + nx]
                        let o = old[y * w + x]
                        if o && n { both += 1 }
                        if o || n { either += 1 }
                    }
                }
            }
        }
        return either == 0 ? 0 : Double(both) / Double(either)
    }
}

/// What looks different on a row (the Windows app's `VisualAreas`): areas of the old page (points) that aren't explained
/// by the words on it.
public enum VisualAreas {
    /// How much of an area must lie off the text for it to count.
    private static let minOffText = 0.5

    /// A row's text sits in the same place on both pages, so what looks different there has changed in itself. Text that
    /// has reflowed moves everything below it: every picture and rule then "looks different" and says nothing.
    public static func sameLayout(_ oldText: PageText, _ newText: PageText) -> Bool {
        let oldLines = lines(oldText)
        if oldLines.isEmpty || newText.isEmpty { return true }
        let newLines = lines(newText)
        let same = oldLines.filter { newLines.contains($0) }.count
        return Double(same) >= Double(min(oldLines.count, newLines.count)) * 0.8
    }

    private struct Line: Hashable {
        var text: String
        var x: Int
        var y: Int
    }

    private static func lines(_ page: PageText) -> Set<Line> {
        var lines = Set<Line>()
        let units = Array(page.text.utf16)
        var start = 0
        while start < units.count {
            var end = start
            while end < units.count && units[end] != 10 { end += 1 }
            if end > start {
                let box = page.boxAt(start)
                lines.insert(Line(text: String(decoding: units[start..<end], as: UTF16.self), x: rounded(box.x), y: rounded(box.y)))
            }
            start = end + 1
        }
        return lines
    }

    private static func rounded(_ v: Double) -> Int { v.isFinite ? Int(max(-1e9, min(1e9, v.rounded()))) : 0 } // bounded: finite, clamped to 1e9

    /// The areas of `regions` (points of the old page) that are mostly not under text on either page: where the words
    /// differ the text compare has said so. The new page's text is brought over through `alignment`.
    public static func offText(_ regions: [RectD], _ oldText: PageText, _ newText: PageText, _ alignment: PageAlignment) -> [RectD] {
        if regions.isEmpty { return [] }
        var boxes = oldText.isEmpty ? [] : oldText.rects(0, oldText.length)
        if !newText.isEmpty { boxes += newText.rects(0, newText.length).map(alignment.boxToOld) }
        let grid = 12
        var kept: [RectD] = []
        for r in regions {
            var off = 0
            for j in 0..<grid {
                for i in 0..<grid {
                    let x = r.x + (Double(i) + 0.5) * r.width / Double(grid), y = r.y + (Double(j) + 0.5) * r.height / Double(grid)
                    if !boxes.contains(where: { x >= $0.x - 1 && x <= $0.right + 1 && y >= $0.y - 1 && y <= $0.bottom + 1 }) { off += 1 }
                }
            }
            if Double(off) >= Double(grid * grid) * minOffText { kept.append(r) }
        }
        return kept
    }
}
