import Foundation

/// Axis-aligned rectangle in page space: PDF points, origin at the page's top-left, y down.
public struct RectD: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The empty rectangle at the origin (.NET's `default(RectD)`).
    public static let zero = RectD(0, 0, 0, 0)

    public var right: Double { x + width }
    public var bottom: Double { y + height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public static func fromEdges(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> RectD {
        RectD(min(left, right), min(top, bottom), abs(right - left), abs(bottom - top))
    }

    public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px <= right && py >= y && py <= bottom }

    public func union(_ other: RectD) -> RectD {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return .fromEdges(min(x, other.x), min(y, other.y), max(right, other.right), max(bottom, other.bottom))
    }

    public func intersect(_ other: RectD) -> RectD {
        let l = max(x, other.x), t = max(y, other.y)
        let r = min(right, other.right), b = min(bottom, other.bottom)
        return r > l && b > t ? RectD(l, t, r - l, b - t) : .zero
    }

    public func inflate(_ d: Double) -> RectD { RectD(x - d, y - d, width + 2 * d, height + 2 * d) }
}

/// Page box size in points, as displayed (rotation applied); the origin is where MuPDF's page space puts its top-left.
public struct PageGeometry: Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(_ originX: Double, _ originY: Double, _ width: Double, _ height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }
}

/// A point in page space: PDF points, origin at the page's top-left, y down.
public struct PointD: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A view turned by a multiple of 90° clockwise (the file is unchanged): maps page-space points and rectangles of a
/// `width` × `height` page into the turned page's own space (origin at its top-left, y down) and back.
public enum RotatedView {
    /// 0, 90, 180 or 270 (any multiple of 90, negative too; other angles snap down to one).
    public static func normalize(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 / 90 * 90 }

    /// The turned page's size.
    public static func size(_ width: Double, _ height: Double, _ rotation: Int) -> (width: Double, height: Double) {
        rotation == 90 || rotation == 270 ? (height, width) : (width, height)
    }

    public static func toView(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ rotation: Int) -> (x: Double, y: Double) {
        switch rotation {
        case 90: (height - y, x)
        case 180: (width - x, height - y)
        case 270: (y, width - x)
        default: (x, y)
        }
    }

    public static func fromView(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ rotation: Int) -> (x: Double, y: Double) {
        switch rotation {
        case 90: (y, height - x)
        case 180: (width - x, height - y)
        case 270: (width - y, x)
        default: (x, y)
        }
    }

    public static func toView(_ r: RectD, _ width: Double, _ height: Double, _ rotation: Int) -> RectD {
        let a = toView(r.x, r.y, width, height, rotation)
        let b = toView(r.right, r.bottom, width, height, rotation)
        return .fromEdges(a.x, a.y, b.x, b.y)
    }

    public static func fromView(_ r: RectD, _ width: Double, _ height: Double, _ rotation: Int) -> RectD {
        let a = fromView(r.x, r.y, width, height, rotation)
        let b = fromView(r.right, r.bottom, width, height, rotation)
        return .fromEdges(a.x, a.y, b.x, b.y)
    }
}
