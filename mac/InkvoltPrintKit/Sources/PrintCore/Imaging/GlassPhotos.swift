import Foundation

/// A point on the glass, in the units of the `PhotoBox` it came from.
public struct PhotoPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A photo on the scanner glass: a rectangle that may be turned. All lengths are in units of the scan's width (so the box
/// keeps its shape on any copy of the scan: multiply by that copy's pixel width, as `inPixels` does), x to the right, y
/// down. `angle` is how far the photo is turned clockwise as seen on screen, in degrees, within ±45°; `quarterTurns` turns
/// the saved photo a further quarter clockwise each (a portrait print laid on its side).
///
/// Cutting it out with Core Image (y up): turn the scan anticlockwise as seen by `angle` about the box's centre
/// (`CGAffineTransform(rotationAngle: +angle in radians)` in Core Image's space), then crop the upright `width` × `height`
/// around the centre (y flipped: `scanHeight − centerY`), then apply `quarterTurns`.
public struct PhotoBox: Equatable, Sendable, Codable {
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double
    public var angle: Double
    public var quarterTurns: Int

    public init(centerX: Double, centerY: Double, width: Double, height: Double, angle: Double, quarterTurns: Int = 0) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.angle = angle
        self.quarterTurns = quarterTurns
    }

    private var sinCos: (sin: Double, cos: Double) {
        let radians: Double = angle * .pi / 180
        return (sin(radians), cos(radians))
    }

    /// The corners, clockwise from the photo's own top-left.
    public func corners() -> [PhotoPoint] {
        let (s, c) = sinCos
        let (hw, hh) = (width / 2, height / 2)
        let local: [(Double, Double)] = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        return local.map { (u, v) in
            let x: Double = centerX + u * c - v * s
            let y: Double = centerY + u * s + v * c
            return PhotoPoint(x, y)
        }
    }

    /// A point in the box's own frame: along its width and its height, from its centre.
    public func toLocal(_ x: Double, _ y: Double) -> (u: Double, v: Double) {
        let (s, c) = sinCos
        let (dx, dy) = (x - centerX, y - centerY)
        let u: Double = c * dx + s * dy
        let v: Double = -s * dx + c * dy
        return (u, v)
    }

    public func contains(_ x: Double, _ y: Double) -> Bool {
        let (u, v) = toLocal(x, y)
        return abs(u) <= width / 2 && abs(v) <= height / 2
    }

    /// Corner `corner` (as `corners()` numbers them) dragged to (x, y), the opposite corner staying put.
    public func withCorner(_ corner: Int, _ x: Double, _ y: Double, min minSide: Double = 0.02) -> PhotoBox {
        let opposite = corners()[(corner + 2) % 4]
        let (ou, ov) = toLocal(opposite.x, opposite.y)
        var (pu, pv) = toLocal(x, y)
        // Keep the dragged corner on its own side of the opposite one, at least min away.
        let su: Double = corner == 1 || corner == 2 ? 1 : -1
        let sv: Double = corner == 2 || corner == 3 ? 1 : -1
        pu = ou + su * max(minSide, su * (pu - ou))
        pv = ov + sv * max(minSide, sv * (pv - ov))
        let (mu, mv) = ((pu + ou) / 2, (pv + ov) / 2)
        let (s, c) = sinCos
        var box = self
        box.centerX = centerX + mu * c - mv * s
        box.centerY = centerY + mu * s + mv * c
        box.width = abs(pu - ou)
        box.height = abs(pv - ov)
        return box
    }

    /// The same box turned `degrees` more, kept within ±45° by swapping its sides.
    public func turned(_ degrees: Double) -> PhotoBox {
        var box = self
        box.angle = angle + degrees
        return Self.normalized(box)
    }

    static func normalized(_ box: PhotoBox) -> PhotoBox {
        var angle = box.angle.truncatingRemainder(dividingBy: 180)
        if angle > 90 { angle -= 180 }
        if angle <= -90 { angle += 180 }
        var result = box
        if angle > 45 || angle <= -45 {
            result.angle = angle > 45 ? angle - 90 : angle + 90
            result.width = box.height
            result.height = box.width
        } else {
            result.angle = angle
        }
        return result
    }

    /// The box on a copy of the scan `scanWidth` pixels wide: centre, size and corners in that copy's pixels (y down),
    /// for cutting it out of the full-size scan.
    public func inPixels(scanWidth: Int) -> PhotoPixels {
        let scale = Double(scanWidth)
        let points = corners().map { PhotoPoint($0.x * scale, $0.y * scale) }
        return PhotoPixels(centerX: centerX * scale, centerY: centerY * scale, width: width * scale, height: height * scale,
                           angle: angle, quarterTurns: quarterTurns, corners: points)
    }
}

/// A `PhotoBox` in one copy of the scan's pixels (`PhotoBox.inPixels`): y down, `angle` clockwise as seen, degrees.
public struct PhotoPixels: Equatable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double
    public var angle: Double
    public var quarterTurns: Int

    /// Clockwise from the photo's own top-left.
    public var corners: [PhotoPoint]
}

/// Finds the photos laid on the glass in a flatbed scan of the whole glass: the lid's level is the most common light level;
/// whatever differs from it is a print. On a coarse grid (about 50 cells per inch) the mask loses specks, hairs and thin lid
/// shadows (opening), closes small gaps and light patches inside prints (closing, then holes filled), and each remaining
/// connected component that's at least an inch on a side, mostly filling its box, becomes the smallest rectangle around it
/// (rotating calipers over its convex hull), trimmed a little at the edges. Prints laid closer than about 0.2 in can come out
/// as one; prints with white borders lose the border (it looks like the lid). Returned in reading order.
/// Seconds of CPU on a full glass: call it through `offPool`.
public enum PhotoFinder {
    /// How far from the lid's level a pixel must be to be part of a print.
    private static let contrast = 16

    /// Smallest print side, in inches.
    public static let minSide = 0.9

    /// Trimmed off each edge, in inches: the print's edge, its shadow and the grid's coarseness.
    public static let trim = 0.02

    /// The photos on `img` (a copy of the glass scan, any size), `pixelsPerInch` being that copy's resolution.
    public static func find(_ img: GrayImage, pixelsPerInch: Double) -> [PhotoBox] {
        if img.width < 32 || img.height < 32 || pixelsPerInch < 20 { return [] }
        let lid = lidLevel(img)
        if lid < 0 { return [] }

        // The grid: each cell is a print cell when most of its pixels differ from the lid.
        let cell = max(1, Int((pixelsPerInch / 50).rounded(.toNearestOrEven)))
        let (gw, gh) = ((img.width + cell - 1) / cell, (img.height + cell - 1) / cell)
        var mask = [Bool](repeating: false, count: gw * gh)
        img.pixels.withUnsafeBufferPointer { px in
            for gy in 0..<gh {
                let (yStart, yEnd) = (gy * cell, min(img.height, (gy + 1) * cell))
                for gx in 0..<gw {
                    let (xStart, xEnd) = (gx * cell, min(img.width, (gx + 1) * cell))
                    var on = 0
                    for y in yStart..<yEnd {
                        let row = y * img.width
                        for x in xStart..<xEnd where abs(Int(px[row + x]) - lid) > contrast { on += 1 }
                    }
                    mask[gy * gw + gx] = 2 * on > (yEnd - yStart) * (xEnd - xStart)
                }
            }
        }
        let cellsPerInch = pixelsPerInch / Double(cell)
        let open = max(1, Int((0.04 * cellsPerInch).rounded(.toNearestOrEven)))
        let close = max(1, Int((0.08 * cellsPerInch).rounded(.toNearestOrEven)))
        mask = dilate(erode(mask, gw, gh, open), gw, gh, open)
        mask = closing(mask, gw, gh, close)
        fillHoles(&mask, gw, gh)

        var boxes: [PhotoBox] = []
        var seen = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        var cells: [Int] = []
        for start in 0..<mask.count where mask[start] && !seen[start] {
            cells.removeAll(keepingCapacity: true)
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                cells.append(i)
                let (x, y) = (i % gw, i / gw)
                var next: [Int] = []
                if x > 0 { next.append(i - 1) }
                if x < gw - 1 { next.append(i + 1) }
                if y > 0 { next.append(i - gw) }
                if y < gh - 1 { next.append(i + gw) }
                for j in next where mask[j] && !seen[j] {
                    seen[j] = true
                    stack.append(j)
                }
            }
            if var found = box(cells, mask, gw, gh, cellsPerInch) {
                // Grid cells → units of the scan's width, trimmed.
                let scale = Double(cell) / Double(img.width)
                let trimmed: Double = 2 * trim * pixelsPerInch / Double(img.width)
                found.centerX *= scale
                found.centerY *= scale
                found.width = found.width * scale - trimmed
                found.height = found.height * scale - trimmed
                boxes.append(found)
            }
        }
        return readingOrder(boxes)
    }

    /// The lid's level: the most common light level (smoothed histogram peak at 128 or above); -1 for a dark lid.
    private static func lidLevel(_ img: GrayImage) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for p in img.pixels { histogram[Int(p)] += 1 }
        var best = -1
        var bestCount = 0
        for level in 128..<256 {
            var sum = 0
            for k in max(0, level - 3)...min(255, level + 3) { sum += histogram[k] }
            if sum > bestCount { (best, bestCount) = (level, sum) }
        }
        return bestCount * 10 < img.pixels.count ? -1 : best // under a tenth of the glass: no lid to go by
    }

    /// The smallest rectangle around a component, in grid cells; nil when it isn't print-shaped.
    private static func box(_ cells: [Int], _ mask: [Bool], _ gw: Int, _ gh: Int, _ cellsPerInch: Double) -> PhotoBox? {
        let minCells: Double = minSide * cellsPerInch
        if Double(cells.count) < minCells * minCells { return nil }

        // The corners of the component's edge cells.
        var points: [PhotoPoint] = []
        for i in cells {
            let (x, y) = (i % gw, i / gw)
            let edge = x == 0 || y == 0 || x == gw - 1 || y == gh - 1 || !mask[i - 1] || !mask[i + 1] || !mask[i - gw] || !mask[i + gw]
            if !edge { continue }
            let (px, py) = (Double(x), Double(y))
            points.append(PhotoPoint(px, py))
            points.append(PhotoPoint(px + 1, py))
            points.append(PhotoPoint(px, py + 1))
            points.append(PhotoPoint(px + 1, py + 1))
        }
        let hull = convexHull(points)
        if hull.count < 3 { return nil }

        var best: PhotoBox?
        var bestArea = Double.greatestFiniteMagnitude
        for e in hull.indices {
            let (a, b) = (hull[e], hull[(e + 1) % hull.count])
            let angle = atan2(b.y - a.y, b.x - a.x)
            let (s, c) = (sin(angle), cos(angle))
            var (minU, maxU) = (Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
            var (minV, maxV) = (Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
            for p in hull {
                let u: Double = c * p.x + s * p.y
                let v: Double = -s * p.x + c * p.y
                minU = min(minU, u)
                maxU = max(maxU, u)
                minV = min(minV, v)
                maxV = max(maxV, v)
            }
            let area: Double = (maxU - minU) * (maxV - minV)
            if area >= bestArea { continue }
            bestArea = area
            let (mu, mv) = ((minU + maxU) / 2, (minV + maxV) / 2)
            let cx: Double = c * mu - s * mv
            let cy: Double = s * mu + c * mv
            best = PhotoBox.normalized(PhotoBox(centerX: cx, centerY: cy, width: maxU - minU, height: maxV - minV,
                                                angle: angle * 180 / .pi))
        }
        guard var found = best, found.width >= minCells, found.height >= minCells, Double(cells.count) >= 0.5 * bestArea else {
            return nil
        }
        found.angle = abs(found.angle) < 0.25 ? 0 : (found.angle * 100).rounded(.toNearestOrEven) / 100
        return found
    }

    /// Andrew's monotone chain; counter-clockwise in a y-up frame.
    private static func convexHull(_ points: [PhotoPoint]) -> [PhotoPoint] {
        var sorted: [PhotoPoint] = []
        for p in points.sorted(by: { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }) where sorted.last != p { sorted.append(p) }
        if sorted.count < 3 { return sorted }

        func cross(_ o: PhotoPoint, _ a: PhotoPoint, _ b: PhotoPoint) -> Double {
            let first: Double = (a.x - o.x) * (b.y - o.y)
            let second: Double = (a.y - o.y) * (b.x - o.x)
            return first - second
        }

        var hull: [PhotoPoint] = []
        hull.reserveCapacity(2 * sorted.count)
        for pass in [sorted, sorted.reversed()] {
            let start = hull.count
            for p in pass {
                while hull.count >= start + 2 && cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 { hull.removeLast() }
                hull.append(p)
            }
            hull.removeLast()
        }
        return hull
    }

    /// Rows top to bottom (a box joins a row when its centre is above the middle of the row's first box's lower half),
    /// each left to right.
    private static func readingOrder(_ boxes: [PhotoBox]) -> [PhotoBox] {
        var ordered: [PhotoBox] = []
        // Stable, as .NET's OrderBy is.
        var rest = boxes.enumerated().sorted { $0.element.centerY != $1.element.centerY ? $0.element.centerY < $1.element.centerY : $0.offset < $1.offset }
            .map(\.element)
        while let first = rest.first {
            let limit = first.centerY + first.height / 2
            let count = rest.prefix { $0.centerY < limit }.count
            let row = rest[0..<count].enumerated()
                .sorted { $0.element.centerX != $1.element.centerX ? $0.element.centerX < $1.element.centerX : $0.offset < $1.offset }
            ordered += row.map(\.element)
            rest.removeFirst(count)
        }
        return ordered
    }

    // ---- Binary morphology on the grid (square window of radius r; the window is clipped at the edges, so prints
    //      against the edge of the glass keep their edge) ----

    private static func sums(_ mask: [Bool], _ w: Int, _ h: Int) -> [Int] {
        var sums = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                row += mask[y * w + x] ? 1 : 0
                sums[(y + 1) * (w + 1) + x + 1] = sums[y * (w + 1) + x + 1] + row
            }
        }
        return sums
    }

    private static func window(_ mask: [Bool], _ w: Int, _ h: Int, _ r: Int, dilate: Bool) -> [Bool] {
        let sums = sums(mask, w, h)
        var result = [Bool](repeating: false, count: mask.count)
        for y in 0..<h {
            let (y0, y1) = (max(0, y - r), min(h, y + r + 1))
            for x in 0..<w {
                let (x0, x1) = (max(0, x - r), min(w, x + r + 1))
                let count = sums[y1 * (w + 1) + x1] - sums[y0 * (w + 1) + x1] - sums[y1 * (w + 1) + x0] + sums[y0 * (w + 1) + x0]
                result[y * w + x] = dilate ? count > 0 : count == (x1 - x0) * (y1 - y0)
            }
        }
        return result
    }

    private static func dilate(_ mask: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] { window(mask, w, h, r, dilate: true) }
    private static func erode(_ mask: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] { window(mask, w, h, r, dilate: false) }

    /// Closing on a grid padded with lid all round, so a gap between a print and the edge of the glass stays open (the
    /// clipped window alone would fill it), while a print against the edge keeps its edge.
    private static func closing(_ mask: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
        let (pw, ph) = (w + 2 * r, h + 2 * r)
        var padded = [Bool](repeating: false, count: pw * ph)
        for y in 0..<h { padded.replaceSubrange(((y + r) * pw + r)..<((y + r) * pw + r + w), with: mask[(y * w)..<(y * w + w)]) }
        padded = erode(dilate(padded, pw, ph, r), pw, ph, r)
        var result = [Bool](repeating: false, count: mask.count)
        for y in 0..<h { result.replaceSubrange((y * w)..<(y * w + w), with: padded[((y + r) * pw + r)..<((y + r) * pw + r + w)]) }
        return result
    }

    /// Lid cells the lid around the edges can't reach (light patches inside a print) become print.
    private static func fillHoles(_ mask: inout [Bool], _ w: Int, _ h: Int) {
        var outside = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        func seed(_ i: Int) {
            if mask[i] || outside[i] { return }
            outside[i] = true
            stack.append(i)
        }
        for x in 0..<w {
            seed(x)
            seed((h - 1) * w + x)
        }
        for y in 0..<h {
            seed(y * w)
            seed(y * w + w - 1)
        }
        while let i = stack.popLast() {
            let (x, y) = (i % w, i / w)
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        for i in mask.indices where !outside[i] { mask[i] = true }
    }
}

/// Cuts a found photo out of the full-size scan, straight: only the pixels around it are read and turned (`PageRotate`).
/// The pure-pixel way; the app may use Core Image instead (`PhotoBox`'s notes).
public enum GlassPhotoCrop {
    /// The pixels to read for `box` from a `width` × `height` scan: its corners, a little around, inside the scan.
    public static func bounds(_ box: PhotoBox, width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let corners = box.corners()
        let scale = Double(width)
        let minX: Double = corners.map(\.x).min()! * scale
        let minY: Double = corners.map(\.y).min()! * scale
        let maxX: Double = corners.map(\.x).max()! * scale
        let maxY: Double = corners.map(\.y).max()! * scale
        let x0 = clamp(Int(minX.rounded(.down)) - 2, 0, width - 1)
        let y0 = clamp(Int(minY.rounded(.down)) - 2, 0, height - 1)
        let x1 = clamp(Int(maxX.rounded(.up)) + 2, x0 + 1, width)
        let y1 = clamp(Int(maxY.rounded(.up)) + 2, y0 + 1, height)
        return (x0, y0, x1 - x0, y1 - y0)
    }

    /// The photo, turned straight: `region` is the part of the scan `bounds` gave (at `regionX`, `regionY`, rows `stride`
    /// bytes apart, 1 or 3 channels), the scan `scanWidth` pixels wide. Rows of the result are padded to 4 bytes.
    public static func straighten(_ region: [UInt8], regionWidth: Int, regionHeight: Int, stride: Int, channels: Int,
                                  box: PhotoBox, scanWidth: Int, regionX: Int, regionY: Int)
        -> (pixels: [UInt8], width: Int, height: Int, stride: Int) {
        let turned = box.angle == 0
            ? region
            : PageRotate.rotate(region, width: regionWidth, height: regionHeight, stride: stride, channels: channels, degrees: -box.angle)
        // Where the box's centre is in the turned region (turned about the region's centre, as PageRotate does).
        let (rcx, rcy) = (Double(regionWidth - 1) / 2, Double(regionHeight - 1) / 2)
        let scale = Double(scanWidth)
        let dx: Double = box.centerX * scale - Double(regionX) - rcx
        let dy: Double = box.centerY * scale - Double(regionY) - rcy
        let radians: Double = box.angle * .pi / 180
        let (s, c) = (sin(radians), cos(radians))
        let cx: Double = c * dx + s * dy + rcx
        let cy: Double = -s * dx + c * dy + rcy

        var w = max(1, Int((box.width * scale).rounded(.toNearestOrEven)))
        var h = max(1, Int((box.height * scale).rounded(.toNearestOrEven)))
        let x0 = clamp(Int((cx - Double(w) / 2).rounded(.toNearestOrEven)), 0, regionWidth - 1)
        let y0 = clamp(Int((cy - Double(h) / 2).rounded(.toNearestOrEven)), 0, regionHeight - 1)
        w = min(w, regionWidth - x0)
        h = min(h, regionHeight - y0)
        let outStride = (w * channels + 3) & ~3
        var pixels = [UInt8](repeating: 0, count: outStride * h)
        let rowBytes = w * channels
        for row in 0..<h {
            let from = (y0 + row) * stride + x0 * channels
            pixels.replaceSubrange((row * outStride)..<(row * outStride + rowBytes), with: turned[from..<(from + rowBytes)])
        }
        return (pixels, w, h, outStride)
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }
}
