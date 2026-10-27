import Foundation

/// Square (rectangle) or Circle (ellipse) annotation.
public enum ShapeKind: Sendable { case rectangle, ellipse }

/// A line ending (/LE). New annotations use none, openArrow, closedArrow, circle or square; the rest are read and drawn
/// too.
public enum LineEnding: Sendable { case none, openArrow, closedArrow, circle, square, diamond, butt, rOpenArrow, rClosedArrow, slash }

/// FreeText alignment (/Q).
public enum TextAlign: Sendable { case left, center, right }

/// How a drawing annotation looks. Shapes, lines and ink use `color` (/C, the stroke; nil = no stroke), `width`
/// (/BS /W), `dash` (/BS /D), `fill` (/IC: shape and polygon interiors, closed line endings) and `opacity` (/CA).
/// FreeText: `color` and `width` are the box border (nil = none: a typewriter), `fill` the background, `fontSize`,
/// `textColor` and `align` the text, `endEnding` the callout's end at its tip.
public struct AnnotStyle: Equatable, Sendable {
    public static let black = AnnotColor(0, 0, 0)

    public var color: AnnotColor? = .red
    public var fill: AnnotColor?
    public var width = 2.0
    public var opacity = 1.0
    /// Dash pattern in points (e.g. [3, 3]); nil or empty = solid.
    public var dash: [Double]?
    /// Ink highlighter: drawn with the Multiply blend mode, so the text underneath stays readable.
    public var highlighter = false
    public var startEnding = LineEnding.none
    public var endEnding = LineEnding.none
    public var fontSize = 12.0
    public var textColor = AnnotStyle.black
    public var align = TextAlign.left

    public init(color: AnnotColor? = .red, fill: AnnotColor? = nil, width: Double = 2) {
        self.color = color
        self.fill = fill
        self.width = width
    }

    public static func pen(_ color: AnnotColor, width: Double = 2) -> AnnotStyle { AnnotStyle(color: color, width: width) }

    public static func marker(_ color: AnnotColor? = nil, width: Double = 14) -> AnnotStyle {
        var s = AnnotStyle(color: color ?? .yellow, width: width)
        s.highlighter = true
        return s
    }

    public static func arrow(_ color: AnnotColor, width: Double = 2) -> AnnotStyle {
        var s = AnnotStyle(color: color, width: width)
        s.endEnding = .openArrow
        return s
    }

    public static func typewriter(fontSize: Double = 12, textColor: AnnotColor? = nil) -> AnnotStyle {
        var s = AnnotStyle(color: nil, width: 0)
        s.fontSize = fontSize
        s.textColor = textColor ?? black
        return s
    }

    public static func textBox(fontSize: Double = 12, border: AnnotColor? = nil, fill: AnnotColor? = nil) -> AnnotStyle {
        var s = AnnotStyle(color: border ?? .red, fill: fill, width: 1)
        s.fontSize = fontSize
        s.endEnding = .openArrow
        return s
    }
}

/// Where a drawing annotation is, in page space. Ink: `paths` = the strokes; Line: one path [start, end]; Polygon /
/// PolyLine: one path of vertices; Square / Circle: `box`; FreeText: `box` = the text box and `callout` = the leader
/// line's tip [, knee] (joined to the nearest side of the box).
public struct AnnotGeometry: Equatable, Sendable {
    public var box = RectD.zero
    public var paths: [[PointD]] = []
    public var callout: [PointD] = []

    public init(box: RectD = .zero, paths: [[PointD]] = [], callout: [PointD] = []) {
        self.box = box
        self.paths = paths
        self.callout = callout
    }

    /// Everything the geometry covers: the box, every point and the callout (what a selection frame shows).
    public var bounds: RectD {
        var l = Double.greatestFiniteMagnitude, t = Double.greatestFiniteMagnitude
        var r = -Double.greatestFiniteMagnitude, b = -Double.greatestFiniteMagnitude
        func add(_ x: Double, _ y: Double) {
            l = min(l, x)
            t = min(t, y)
            r = max(r, x)
            b = max(b, y)
        }
        if !box.isEmpty {
            add(box.x, box.y)
            add(box.right, box.bottom)
        }
        for p in paths.joined() { add(p.x, p.y) }
        for p in callout { add(p.x, p.y) }
        return l > r ? .zero : RectD(l, t, r - l, b - t)
    }

    /// The geometry moved and scaled so that its `bounds` become `bounds`.
    public func mapTo(_ target: RectD) -> AnnotGeometry {
        let from = bounds
        let sx = from.width > 0 ? target.width / from.width : 1
        let sy = from.height > 0 ? target.height / from.height : 1
        func m(_ p: PointD) -> PointD { PointD(target.x + (p.x - from.x) * sx, target.y + (p.y - from.y) * sy) }
        var mapped = box
        if !box.isEmpty {
            let a = m(PointD(box.x, box.y)), c = m(PointD(box.right, box.bottom))
            mapped = .fromEdges(a.x, a.y, c.x, c.y)
        }
        return AnnotGeometry(box: mapped, paths: paths.map { $0.map(m) }, callout: callout.map(m))
    }
}
