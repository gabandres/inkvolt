import Foundation

public enum ExportShapeKind: Sendable { case line, rectangle, ellipse }

/// A simple shape a page draws (page space): a line along its box, a rectangle or an ellipse. `fill` and `stroke`: its
/// colors (0xRRGGBB), nil for none. `strokeWidth`: in points. A stroked shape's box runs along the middle of its outline.
public struct ExportShape: Equatable, Sendable {
    public var kind: ExportShapeKind
    public var box: RectD
    public var fill: UInt32?
    public var stroke: UInt32?
    public var strokeWidth: Double

    public init(_ kind: ExportShapeKind, _ box: RectD, _ fill: UInt32?, _ stroke: UInt32?, _ strokeWidth: Double) {
        self.kind = kind
        self.box = box
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
    }
}

/// A path a page draws, as the PDF reader gives it: only its bounds, whether it is stroked, and its color (0xRRGGBB).
public struct ExportPath: Equatable, Sendable {
    public var box: RectD
    public var stroked: Bool
    public var color: UInt32

    public init(_ box: RectD, _ stroked: Bool, _ color: UInt32) {
        self.box = box
        self.stroked = stroked
        self.color = color
    }
}

/// Tells which of a page's vector paths are simple shapes (the Windows app's `ExportShapes`). The reader gives a path's
/// bounds and no more, so what it draws decides: a thin path is a line, and a wider one is looked at in a rendering of the
/// page (its corners and edges) for a rectangle or an ellipse. Everything else (a triangle, a rounded box, a dashed or
/// see-through one) stays as it looks: its area becomes a picture, unless text lies on it (the picture would double the
/// text).
enum ExportShapes {
    static let thin = 3.0     // as DocLayout: a path this thin (pt) is a rule
    static let minLine = 4.0  // shorter rules are specks
    static let lineAlpha = 64 // a thin outline's pixels at the rendering's scale

    /// A page rendered on a transparent background: straight RGBA, `scale` pixels per point.
    struct Raster {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let scale: Double

        func at(_ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int, a: Int) {
            let px = clampInt(Int((x * scale).rounded(.down)), 0, width - 1)
            let py = clampInt(Int((y * scale).rounded(.down)), 0, height - 1)
            let i = (py * width + px) * 4
            return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]), Int(rgba[i + 3]))
        }

        /// The point shows this color, opaque (or, by `minAlpha`, partly: a thin line covers only part of its pixels).
        func isColor(_ x: Double, _ y: Double, _ color: UInt32, minAlpha: Int = 240) -> Bool {
            let p = at(x, y)
            return p.a >= minAlpha && abs(p.r - Int((color >> 16) & 255)) <= 16 && abs(p.g - Int((color >> 8) & 255)) <= 16
                && abs(p.b - Int(color & 255)) <= 16
        }

        /// `isColor` at the point or a pixel beside it: the outline found is only as exact as the pixels.
        func near(_ x: Double, _ y: Double, _ color: UInt32, _ minAlpha: Int) -> Bool {
            let step = 1 / scale
            for dy in -1...1 {
                for dx in -1...1 where isColor(x + Double(dx) * step, y + Double(dy) * step, color, minAlpha: minAlpha) { return true }
            }
            return false
        }

        /// The point's opaque color, or nil where it is see-through.
        func opaque(_ x: Double, _ y: Double) -> UInt32? {
            let p = at(x, y)
            return p.a >= 250 ? UInt32(p.r) << 16 | UInt32(p.g) << 8 | UInt32(p.b) : nil
        }

        private func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }
    }

    /// A rendering is needed: some path is wider than a line.
    static func needsRaster(_ paths: [ExportPath]) -> Bool { paths.contains { usable($0.box) && !isThin($0.box) } }

    /// The page's shapes in the order it draws them, and the areas to keep as pictures. `raster`: the page, when a path
    /// needs looking at; `lines` and `pictures`: what the page already gives as text and pictures.
    /// - Throws: `CancellationError` when `cancel` fires.
    static func read(_ paths: [ExportPath], _ raster: Raster?, _ lines: [ExportLine], _ pictures: [RectD], _ width: Double, _ height: Double,
                     cancel: CancelToken? = nil) throws -> (shapes: [ExportShape], pictures: [RectD]) {
        var shapes: [ExportShape] = []
        var others: [RectD] = []
        let sheet = RectD(0, 0, width, height)
        // Further off than this, a path is only what shows of it: the work stays a page's, and the slide's numbers in range.
        let nearby = sheet.inflate(max(width, height))
        for path in paths {
            try cancel.check()
            var box = path.box
            if !usable(box) { continue }
            let far = !(box.x >= nearby.x && box.y >= nearby.y && box.right <= nearby.right && box.bottom <= nearby.bottom)
            if isThin(box) {
                if far {
                    // A rule is cut at the page's edges along its length.
                    let (left, top, right, bottom) = (max(box.x, 0), max(box.y, 0), min(box.right, width), min(box.bottom, height))
                    if left > right || top > bottom { continue }
                    box = box.width >= box.height ? .fromEdges(left, box.y, right, box.bottom) : .fromEdges(box.x, top, box.right, bottom)
                }
                if max(box.width, box.height) >= minLine {
                    shapes.append(ExportShape(.line, box, nil, path.color, max(0.25, min(box.width, box.height))))
                }
                continue
            }
            // What shows of a fill far off the page is its part on the page; of an outline, no outline to read.
            if far && path.stroked {
                others.append(box.intersect(sheet))
                continue
            }
            if far { box = box.intersect(sheet) }
            var shape: ExportShape?
            if let raster {
                shape = path.stroked ? outline(raster, path) : filled(raster, ExportPath(box, path.stroked, path.color))
            }
            if let shape {
                // A white sheet under the whole page draws nothing a slide doesn't already show.
                if !(shape.fill == 0xFFFFFF && box.width * box.height >= 0.85 * width * height) { shapes.append(shape) }
            } else {
                others.append(box.intersect(sheet))
            }
        }
        return (shapes, keptAsPictures(others, lines, pictures))
    }

    private static func usable(_ b: RectD) -> Bool { b.width.isFinite && b.height.isFinite && b.width >= 0 && b.height >= 0 }

    private static func isThin(_ b: RectD) -> Bool { b.width <= thin || b.height <= thin }

    /// A filled rectangle or ellipse (the edges are looked at, not the middle: a label may lie there).
    private static func filled(_ r: Raster, _ path: ExportPath) -> ExportShape? {
        let b = path.box
        // Close enough to a corner that a small circle's corners lie outside it.
        let inset = min(1.5, 0.12 * min(b.width, b.height))
        // The path's own color, unless the rendering shows it differently (a blend, a pattern): that is what shows.
        let edge = 0.2 * min(b.width, b.height)
        guard let shown = r.opaque(b.x + edge, b.centerY) else { return nil }
        let color = r.isColor(b.x + edge, b.centerY, path.color) ? path.color : shown
        let l = b.x + inset, t = b.y + inset, right = b.right - inset, bottom = b.bottom - inset
        if !(r.isColor(b.centerX, b.y + edge, color) && r.isColor(b.right - edge, b.centerY, color) && r.isColor(b.centerX, b.bottom - edge, color)) {
            return nil
        }
        if r.isColor(l, t, color) && r.isColor(right, t, color) && r.isColor(right, bottom, color) && r.isColor(l, bottom, color) {
            return ExportShape(.rectangle, b, color, nil, 0)
        }
        return onEllipse(r, b, 0.8, color) && !onEllipse(r, b, 1.08, color) && !r.isColor(l, t, color) ? ExportShape(.ellipse, b, color, nil, 0) : nil
    }

    /// All four diagonal points at `at` times the ellipse's radius show the color.
    private static func onEllipse(_ r: Raster, _ b: RectD, _ at: Double, _ color: UInt32, outline: Bool = false) -> Bool {
        let dx = b.width / 2 * at * 0.5.squareRoot(), dy = b.height / 2 * at * 0.5.squareRoot()
        func on(_ x: Double, _ y: Double) -> Bool { outline ? r.near(x, y, color, lineAlpha) : r.isColor(x, y, color) }
        return on(b.centerX - dx, b.centerY - dy) && on(b.centerX + dx, b.centerY - dy) && on(b.centerX - dx, b.centerY + dy) && on(b.centerX + dx, b.centerY + dy)
    }

    /// An outlined rectangle or ellipse. A stroked path's bounds leave room for mitered corners, so the outline is found
    /// first, walking in from each side.
    private static func outline(_ r: Raster, _ path: ExportPath) -> ExportShape? {
        let b = path.box, color = path.color
        let step = 1 / r.scale
        func walk(_ x: Double, _ y: Double, _ dx: Double, _ dy: Double, _ maxD: Double) -> Double? {
            var d = 0.0
            while d <= maxD {
                if r.isColor(x + dx * d, y + dy * d, color, minAlpha: lineAlpha) { return d }
                d += step
            }
            return nil
        }
        guard let l = walk(b.x, b.centerY, 1, 0, b.width / 2), let right = walk(b.right, b.centerY, -1, 0, b.width / 2),
              let t = walk(b.centerX, b.y, 0, 1, b.height / 2), let bottom = walk(b.centerX, b.bottom, 0, -1, b.height / 2) else { return nil }
        // How thick: from the outer edge to where the color stops.
        var thick = 0.0
        while thick < b.width / 2 && r.isColor(b.x + l + thick, b.centerY, color, minAlpha: lineAlpha) { thick += step }
        thick = max(0.25, thick)
        let mid = RectD.fromEdges(b.x + l + thick / 2, b.y + t + thick / 2, b.right - right - thick / 2, b.bottom - bottom - thick / 2)
        if mid.width <= 0 || mid.height <= 0 { return nil }
        func corner(_ x: Double, _ y: Double) -> Bool { r.isColor(x, y, color, minAlpha: lineAlpha) }
        if corner(mid.x, mid.y) && corner(mid.right, mid.y) && corner(mid.right, mid.bottom) && corner(mid.x, mid.bottom) {
            // Outlines only: a dashed line passes through the corners and the walks too, so the sides must be whole.
            var k = 0.125
            while k < 1 {
                if !r.isColor(mid.x + mid.width * k, mid.y, color, minAlpha: lineAlpha) || !r.isColor(mid.x, mid.y + mid.height * k, color, minAlpha: lineAlpha) {
                    return nil
                }
                k += 0.125
            }
            return ExportShape(.rectangle, mid, nil, color, thick)
        }
        return onEllipse(r, mid, 1, color, outline: true) && !corner(mid.x, mid.y) ? ExportShape(.ellipse, mid, nil, color, thick) : nil
    }

    /// The paths that are no simple shape, joined where they touch; not where text lies on them or a picture already shows them.
    private static func keptAsPictures(_ others: [RectD], _ lines: [ExportLine], _ pictures: [RectD]) -> [RectD] {
        var areas = others.filter { $0.width >= 3 && $0.height >= 3 }
        var merged = true
        while merged {
            merged = false
            outer: for i in areas.indices {
                for j in (i + 1)..<areas.count where !areas[i].inflate(2).intersect(areas[j]).isEmpty {
                    areas[i] = areas[i].union(areas[j])
                    areas.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return areas.filter { a in
            !lines.contains { a.contains($0.box.centerX, $0.box.centerY) } && !pictures.contains { $0.inflate(1).contains(a.centerX, a.centerY) }
        }
    }
}
