import Foundation
import PrintCore

/// Where the old page's points are on the new page: turned `angle` degrees clockwise about (`centerX`, `centerY`) and made
/// `scale` times as large there, then shifted by (`dx`, `dy`) points (the Windows app's `PageAlignment`). A page scanned a
/// quarter turn off has an angle near 90, 180 or 270; one scanned at another size, a scale other than 1.
public struct PageAlignment: Sendable, Equatable {
    public var dx: Double
    public var dy: Double
    public var angle: Double
    public var centerX: Double
    public var centerY: Double
    public var scale: Double

    public init(_ dx: Double, _ dy: Double, _ angle: Double, _ centerX: Double, _ centerY: Double, _ scale: Double = 1) {
        self.dx = dx
        self.dy = dy
        self.angle = angle
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
    }

    public static let none = PageAlignment(0, 0, 0, 0, 0)

    public var isNone: Bool { dx == 0 && dy == 0 && angle == 0 && s == 1 }

    /// The scale, 1 for one that isn't positive and finite (.NET's default value has 0).
    private var s: Double { scale > 0 && scale.isFinite ? scale : 1 }

    /// A point of the old page, on the new page.
    public func toNew(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let r = angle * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        let rx = x - centerX, ry = y - centerY
        return (centerX + s * (rx * cos - ry * sin) + dx, centerY + s * (rx * sin + ry * cos) + dy)
    }

    /// A point of the new page, on the old page.
    public func toOld(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let r = angle * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        let rx = (x - dx - centerX) / s, ry = (y - dy - centerY) / s
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
/// (`ScanCleanup.skewOf`), the shift from where the ink of the two pages falls; a page scanned at another size or a quarter
/// turn off is first brought to the other's size and way up, from where most of each page's ink lies. An alignment that
/// doesn't make the ink agree better isn't used.
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

    /// Finds the alignment of two pages rendered at `scale`: first as they lie (turned a little, shifted); then, for a page
    /// scanned at another size or a quarter turn off, the new page brought to the old one's frame (each quarter turn, at the
    /// size that makes the two pages' ink as large) and lined up the same way. The one whose ink agrees best is kept, if it
    /// agrees better than the pages as they lie.
    /// - Parameter scale: pixels per point of both images.
    public static func find(_ oldImage: RenderedImage, _ newImage: RenderedImage, _ scale: Double, cancel: CancelToken? = nil) throws -> PageAlignment {
        let w = max(oldImage.width, newImage.width), h = max(oldImage.height, newImage.height)
        if w < 16 || h < 16 || Double(w) * Double(h) > maxWorkPixels * 1.5 { return .none }
        let ow = oldImage.width, oh = oldImage.height, nw = newImage.width, nh = newImage.height
        if min(ow, oh) < 16 || min(nw, nh) < 16 { return .none }
        let asLaid = try lined(gray(oldImage, w, h), gray(newImage, w, h), w, h, scale, cancel)
        var best = asLaid

        // Another size or a quarter turn: the new page's ink framed like the old page's, tried coarsely for each turn.
        let oldOwn = gray(oldImage, ow, oh), newOwn = gray(newImage, nw, nh)
        if let oldBox = inkBox(oldOwn, ow, oh), let newBox = inkBox(newOwn, nw, nh) {
            let oldInk = mask(oldOwn)
            let oldCoarse = coarse(oldInk, ow, oh, coarseCell)
            func agrees(_ old: Coarse, _ f: Frame, _ cell: Int) throws -> Double {
                let framedInk = coarse(mask(framed(newOwn, nw, nh, ow, oh, f)), ow, oh, cell)
                return try shiftFor(old.ink, framedInk.ink, old.w, old.h, cancel).agreement
            }
            let plainInk = coarse(mask(gray(newImage, ow, oh)), ow, oh, coarseCell)
            let plainCoarse = try shiftFor(oldCoarse.ink, plainInk.ink, oldCoarse.w, oldCoarse.h, cancel).agreement
            var rough: (frame: Frame, agreement: Double)?
            for f in frames(oldBox, newBox) {
                try cancel?.check()
                let a = try agrees(oldCoarse, f, coarseCell)
                if a > plainCoarse + 0.02 && a > (rough?.agreement ?? -1) { rough = (f, a) }
            }
            if let rough {
                // The ink boxes give the size to a percent or so (a stamp in the margin moves one, a few lines measure
                // poorly), and at a page's edge a percent is several points: tried a little smaller and larger, at 2 pixels.
                let fine = coarse(oldInk, ow, oh, 2)
                var sized: (frame: Frame, agreement: Double) = (rough.frame, try agrees(fine, rough.frame, 2))
                let steps: [(step: Double, count: Int)] = [(0.01, 5), (0.003, 2)]
                for (step, count) in steps {
                    let around = sized.frame.scale
                    for k in -count...count where k != 0 {
                        try cancel?.check()
                        let size = around * (1 + Double(k) * step)
                        if size < minScale || size > maxScale { continue }
                        var f = sized.frame
                        f.scale = size
                        let a = try agrees(fine, f, 2)
                        if a > sized.agreement { sized = (f, a) }
                    }
                }
                let framedNew = framed(newOwn, nw, nh, ow, oh, sized.frame)
                let inFrame = try lined(oldOwn, framedNew, ow, oh, scale, cancel)
                if inFrame.agreement > best.agreement {
                    best = (then(inFrame.alignment, sized.frame, scale), inFrame.agreement, inFrame.asIs)
                }
            }
        }
        // Only if it helps: pages unlike each other have no "right" place, and a chance overlap mustn't move one.
        return best.agreement <= asLaid.asIs + 0.02 ? .none : best.alignment
    }

    /// How the new page is laid in the old page's frame (pixels): a point m of the frame is the new page's point
    /// `newCenter + scale · turn(m − oldCenter)`, turned `quarter` quarter turns clockwise.
    private struct Frame {
        var quarter: Int
        var scale: Double
        var oldX: Double
        var oldY: Double
        var newX: Double
        var newY: Double

        func toNew(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            let rx = x - oldX, ry = y - oldY
            let t: (x: Double, y: Double)
            switch quarter {
            case 1: t = (-ry, rx)
            case 2: t = (-rx, -ry)
            case 3: t = (ry, -rx)
            default: t = (rx, ry)
            }
            return (newX + scale * t.x, newY + scale * t.y)
        }
    }

    /// Smallest and largest size of one page's ink to the other's looked for.
    private static let minScale = 0.33, maxScale = 3.0

    /// The frames worth trying: each quarter turn whose ink box, turned, has the old box's proportions (within an eighth),
    /// at the size that makes them as large; not the page as it lies (`lined` has it).
    private static func frames(_ oldBox: RectD, _ newBox: RectD) -> [Frame] {
        var frames: [Frame] = []
        for q in 0..<4 {
            let bw = q % 2 == 0 ? newBox.width : newBox.height, bh = q % 2 == 0 ? newBox.height : newBox.width
            let sx = bw / oldBox.width, sy = bh / oldBox.height
            if max(sx, sy) / min(sx, sy) > 1.125 { continue }
            let s = (sx * sy).squareRoot()
            if s < minScale || s > maxScale || (q == 0 && abs(s - 1) < 0.02) { continue }
            frames.append(Frame(quarter: q, scale: s, oldX: oldBox.centerX, oldY: oldBox.centerY, newX: newBox.centerX, newY: newBox.centerY))
        }
        return frames
    }

    /// The new page's gray laid in the old page's frame (`w` × `h`), white beyond it.
    private static func framed(_ gray: [UInt8], _ gw: Int, _ gh: Int, _ w: Int, _ h: Int, _ f: Frame) -> [UInt8] {
        var framed = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let n = f.toNew(Double(x) + 0.5, Double(y) + 0.5)
                let fx = n.x.rounded(.down), fy = n.y.rounded(.down)
                guard fx >= 0, fy >= 0, fx < Double(gw), fy < Double(gh) else { continue } // white
                framed[y * w + x] = gray[Int(fy) * gw + Int(fx)] // bounded: within the source's size (the guard above)
            }
        }
        return framed
    }

    /// The alignment of the old page with the new one, from `a` (old page to the framed new page) and the frame (framed to
    /// new): `new = newCenter + s·Q·(C + R(old − C) + D − oldCenter)`, which is again a turn about C, a scale and a shift.
    private static func then(_ a: PageAlignment, _ f: Frame, _ scale: Double) -> PageAlignment {
        let cx = a.isNone ? 0 : a.centerX, cy = a.isNone ? 0 : a.centerY
        let m = f.toNew((cx + a.dx) * scale, (cy + a.dy) * scale)
        return PageAlignment(m.x / scale - cx, m.y / scale - cy, a.angle + 90 * Double(f.quarter), cx, cy, f.scale)
    }

    /// Where most of a page's ink is (pixels): the box between the 1st and 99th hundredth of it along each side, so a speck
    /// at the edge doesn't move it; nil for a page with too little ink or ink in too narrow a band to measure.
    private static func inkBox(_ gray: [UInt8], _ w: Int, _ h: Int) -> RectD? {
        let ink = mask(gray)
        let cols = profile(ink, w, h, alongX: true), rows = profile(ink, w, h, alongX: false)
        let total = cols.reduce(0, +)
        if total < 200 { return nil }
        func hundredth(_ profile: [Int], _ share: Double) -> Int {
            let want = Int((Double(total) * share).rounded(.up)) // bounded: a share under 1 of a pixel count
            var sum = 0
            for i in profile.indices {
                sum += profile[i]
                if sum >= want { return i }
            }
            return profile.count - 1
        }
        let x0 = hundredth(cols, 0.01), x1 = hundredth(cols, 0.99)
        let y0 = hundredth(rows, 0.01), y1 = hundredth(rows, 0.99)
        if x1 - x0 < w / 25 || y1 - y0 < h / 25 { return nil }
        return RectD.fromEdges(Double(x0), Double(y0), Double(x1 + 1), Double(y1 + 1))
    }

    /// Pixels a coarse ink cell is wide and high, to tell which way up the new page goes.
    private static let coarseCell = 4

    private struct Coarse {
        var ink: [Bool]
        var w: Int
        var h: Int
    }

    /// The ink in cells of `cell` pixels (a cell with any ink is ink): quicker to try a frame on.
    private static func coarse(_ ink: [Bool], _ w: Int, _ h: Int, _ cell: Int) -> Coarse {
        let cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell
        var coarse = [Bool](repeating: false, count: cw * ch)
        for y in 0..<h {
            let row = y / cell * cw
            for x in 0..<w where ink[y * w + x] { coarse[row + x / cell] = true }
        }
        return Coarse(ink: coarse, w: cw, h: ch)
    }

    /// The pages as they lie (both `w` × `h`): turned a little and shifted to make their ink agree best. agreement: of that
    /// alignment; asIs: of the pages unmoved. The alignment is `PageAlignment.none` when nothing beat unmoved.
    private static func lined(_ oldGray: [UInt8], _ newGray: [UInt8], _ w: Int, _ h: Int, _ scale: Double,
                              _ cancel: CancelToken?) throws -> (alignment: PageAlignment, agreement: Double, asIs: Double) {
        let dpi = Int(exactly: (scale * 72).rounded(.toNearestOrEven)) ?? 100 // half to even, as Windows' Math.Round
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

        let asIs = agreement(oldInk, newInk, w, h, 0, 0)
        if best.agreement <= asIs + 0.02 { return (.none, asIs, asIs) }
        // The shift was found on the turned page, so on the new page it is turned too.
        let r = best.angle * Double.pi / 180, sin = Foundation.sin(r), cos = Foundation.cos(r)
        let dx = Double(best.dx), dy = Double(best.dy)
        let found = PageAlignment((dx * cos - dy * sin) / scale, (dx * sin + dy * cos) / scale, best.angle, cx / scale, cy / scale)
        return (found, best.agreement, asIs)
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

    /// Brightness, the image padded with white (or cut) to `w` × `h`.
    private static func gray(_ img: RenderedImage, _ w: Int, _ h: Int) -> [UInt8] {
        var gray = [UInt8](repeating: 255, count: w * h)
        for y in 0..<min(img.height, h) {
            for x in 0..<min(img.width, w) {
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

    /// Half to even, as Windows' Math.Round.
    private static func rounded(_ v: Double) -> Int {
        v.isFinite ? Int(max(-1e9, min(1e9, v.rounded(.toNearestOrEven)))) : 0 // bounded: finite, clamped to 1e9
    }

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
