import Foundation

/// Geometry for the drawing tools and for editing drawing annotations: constraining a drag (Shift), hit-testing strokes
/// and shapes, the eight resize handles, moving inside the page, and thinning freehand strokes. Page space (points,
/// top-left origin) unless a function says otherwise; the rectangle helpers work in any axis-aligned space.
public enum DrawingGeometry {
    /// The handles of a selection frame, clockwise from the top-left corner.
    public static let topLeft = 0, top = 1, topRight = 2, right = 3, bottomRight = 4, bottom = 5, bottomLeft = 6, left = 7

    /// The end of a line from `from` towards `to`, turned to the nearest multiple of `stepDegrees` (45: horizontal,
    /// vertical or diagonal), keeping its length.
    public static func snapAngle(_ from: PointD, _ to: PointD, stepDegrees: Double = 45) -> PointD {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        if length == 0 || stepDegrees <= 0 { return to }
        let step = stepDegrees * .pi / 180
        // .NET's Math.Round rounds halves to even; so does this.
        let angle = (atan2(dy, dx) / step).rounded(.toNearestOrEven) * step
        var c = cos(angle), s = sin(angle)
        if abs(c) < 1e-12 { c = 0 }
        if abs(s) < 1e-12 { s = 0 }
        return PointD(from.x + length * c, from.y + length * s)
    }

    /// The box dragged from `from` to `to`; with `square`, a square (the larger side) growing towards the pointer.
    public static func dragBox(_ from: PointD, _ to: PointD, square: Bool) -> RectD {
        if !square { return .fromEdges(from.x, from.y, to.x, to.y) }
        let side = max(abs(to.x - from.x), abs(to.y - from.y))
        let x = to.x >= from.x ? from.x : from.x - side
        let y = to.y >= from.y ? from.y : from.y - side
        return RectD(x, y, side, side)
    }

    /// Where handle `handle` (`topLeft`…`left`) of a frame is.
    public static func handlePoint(_ r: RectD, _ handle: Int) -> PointD {
        switch handle {
        case topLeft: PointD(r.x, r.y)
        case top: PointD(r.centerX, r.y)
        case topRight: PointD(r.right, r.y)
        case right: PointD(r.right, r.centerY)
        case bottomRight: PointD(r.right, r.bottom)
        case bottom: PointD(r.centerX, r.bottom)
        case bottomLeft: PointD(r.x, r.bottom)
        case left: PointD(r.x, r.centerY)
        default: preconditionFailure("No handle \(handle).")
        }
    }

    /// The frame `r` with handle `handle` dragged to `p`: the opposite side (or corner) stays put; no side gets shorter
    /// than `minSize` (the handle stops instead of flipping). `keepAspect`: a corner handle keeps the frame's proportions.
    public static func resize(_ r: RectD, _ handle: Int, _ p: PointD, minSize: Double = 1, keepAspect: Bool = false) -> RectD {
        precondition((topLeft...left).contains(handle), "No handle \(handle).")
        var l = r.x, t = r.y, rt = r.right, b = r.bottom
        if [topLeft, bottomLeft, left].contains(handle) { l = min(p.x, rt - minSize) }
        if [topRight, right, bottomRight].contains(handle) { rt = max(p.x, l + minSize) }
        if [topLeft, top, topRight].contains(handle) { t = min(p.y, b - minSize) }
        if [bottomRight, bottom, bottomLeft].contains(handle) { b = max(p.y, t + minSize) }
        if keepAspect && [topLeft, topRight, bottomRight, bottomLeft].contains(handle) && r.width > 0 && r.height > 0 {
            let k = max((rt - l) / r.width, (b - t) / r.height)
            let w = r.width * k, h = r.height * k
            if handle == topLeft || handle == bottomLeft { l = rt - w } else { rt = l + w }
            if handle == topLeft || handle == topRight { t = b - h } else { b = t + h }
        }
        return RectD(l, t, rt - l, b - t)
    }

    /// A move by (`dx`, `dy`) cut short so that `bounds` stays on a `pageWidth` × `pageHeight` page (something already
    /// sticking out may move back in, never further out).
    public static func clampMove(_ bounds: RectD, _ dx: Double, _ dy: Double, _ pageWidth: Double, _ pageHeight: Double) -> (dx: Double, dy: Double) {
        func clamp(_ d: Double, _ start: Double, _ end: Double, _ size: Double) -> Double {
            let lo = min(0, -start) // as far back as the page's start
            let hi = max(0, size - end) // as far on as the page's end
            return min(max(d, lo), hi)
        }
        return (clamp(dx, bounds.x, bounds.right, pageWidth), clamp(dy, bounds.y, bounds.bottom, pageHeight))
    }

    /// The geometry moved by (`dx`, `dy`).
    public static func translate(_ g: AnnotGeometry, _ dx: Double, _ dy: Double) -> AnnotGeometry {
        func m(_ p: PointD) -> PointD { PointD(p.x + dx, p.y + dy) }
        let box = g.box.isEmpty ? g.box : RectD(g.box.x + dx, g.box.y + dy, g.box.width, g.box.height)
        return AnnotGeometry(box: box, paths: g.paths.map { $0.map(m) }, callout: g.callout.map(m))
    }

    /// The frame a selection shows (and resizes): a FreeText's text box (its callout has its own handle), else
    /// everything the geometry covers.
    public static func frame(_ subtype: String, _ g: AnnotGeometry) -> RectD {
        subtype == "FreeText" && !g.box.isEmpty ? g.box : g.bounds
    }

    /// The geometry resized so its `frame` becomes `frame`. A FreeText keeps its callout's tip where it is (only the box
    /// changes); everything else is scaled.
    public static func withFrame(_ subtype: String, _ g: AnnotGeometry, _ frame: RectD) -> AnnotGeometry {
        subtype == "FreeText" ? AnnotGeometry(box: frame, paths: g.paths, callout: g.callout) : g.mapTo(frame)
    }

    /// Distance from `p` to the segment `a`–`b`.
    public static func distanceToSegment(_ p: PointD, _ a: PointD, _ b: PointD) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        let x = a.x + t * dx - p.x, y = a.y + t * dy - p.y
        return (x * x + y * y).squareRoot()
    }

    /// Distance from `p` to an open (or `closed`) polyline.
    public static func distanceToPath(_ p: PointD, _ path: [PointD], closed: Bool = false) -> Double {
        if path.isEmpty { return .infinity }
        if path.count == 1 { return distanceToSegment(p, path[0], path[0]) }
        var best = Double.infinity
        for i in 1..<path.count { best = min(best, distanceToSegment(p, path[i - 1], path[i])) }
        if closed { best = min(best, distanceToSegment(p, path[path.count - 1], path[0])) }
        return best
    }

    /// True when `p` is inside the polygon (even-odd rule).
    public static func insidePolygon(_ p: PointD, _ poly: [PointD]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// True when a press at `p` picks the drawing annotation: on its stroke (within its half width plus `tolerance`),
    /// inside a filled shape, anywhere in a FreeText box, or on a callout's leader line.
    public static func hit(_ subtype: String, _ g: AnnotGeometry, _ style: AnnotStyle?, _ p: PointD, _ tolerance: Double) -> Bool {
        let stroke = style.map { $0.color != nil && $0.width > 0 ? $0.width : 0 } ?? 0
        let filled = style?.fill != nil
        let near = tolerance + stroke / 2
        switch subtype {
        case "Ink", "PolyLine", "Line":
            return g.paths.contains { distanceToPath(p, $0) <= near }
        case "Polygon":
            return g.paths.contains { distanceToPath(p, $0, closed: true) <= near || (filled && insidePolygon(p, $0)) }
        case "Square":
            let b = g.box
            if filled && b.inflate(tolerance).contains(p.x, p.y) { return true }
            // The stroke lies inside the box: its middle runs half a width in.
            let inner = b.width > stroke && b.height > stroke ? b.inflate(-stroke / 2) : b
            let corners = [PointD(inner.x, inner.y), PointD(inner.right, inner.y), PointD(inner.right, inner.bottom), PointD(inner.x, inner.bottom)]
            return distanceToPath(p, corners, closed: true) <= near
        case "Circle":
            let b = g.box
            let rx = max((b.width - stroke) / 2, 0.01), ry = max((b.height - stroke) / 2, 0.01)
            let nx = (p.x - b.centerX) / rx, ny = (p.y - b.centerY) / ry
            let d = (nx * nx + ny * ny).squareRoot()
            if filled && d <= 1 { return true }
            // Distance to the ellipse, approximately (exact on circles): radial gap scaled by the radius in that direction.
            let radius = d == 0 ? min(rx, ry) : (pow(nx / d * rx, 2) + pow(ny / d * ry, 2)).squareRoot()
            return abs(d - 1) * radius <= near
        case "FreeText":
            if g.box.inflate(tolerance).contains(p.x, p.y) { return true }
            if g.callout.isEmpty { return false }
            let leader = g.callout + [nearestOnRect(g.box, g.callout[g.callout.count - 1])]
            return distanceToPath(p, leader) <= near
        default:
            return g.bounds.inflate(tolerance + stroke / 2).contains(p.x, p.y)
        }
    }

    /// The point of `r`'s outline nearest to `p` (outside it: the nearest point of the box).
    public static func nearestOnRect(_ r: RectD, _ p: PointD) -> PointD {
        PointD(min(max(p.x, r.x), r.right), min(max(p.y, r.y), r.bottom))
    }

    /// A freehand stroke thinned (Ramer–Douglas–Peucker): points closer than `tolerance` to the line through their
    /// neighbours are dropped; the first and last points always stay.
    public static func simplify(_ points: [PointD], _ tolerance: Double) -> [PointD] {
        if points.count < 3 || tolerance <= 0 { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (from, to) = stack.popLast() {
            var worst = -1
            var worstD = tolerance
            for i in (from + 1)..<to {
                let d = distanceToSegment(points[i], points[from], points[to])
                if d > worstD {
                    worstD = d
                    worst = i
                }
            }
            if worst < 0 { continue }
            keep[worst] = true
            stack.append((from, worst))
            stack.append((worst, to))
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}
