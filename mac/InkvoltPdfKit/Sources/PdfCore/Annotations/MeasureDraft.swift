import Foundation

/// What a measuring tool measures: a distance, a perimeter, an area, or a distance whose real length sets the scale.
public enum MeasureTool: Sendable, Equatable {
    case distance, perimeter, area, calibrate

    public var kind: MeasureKind {
        switch self {
        case .perimeter: .perimeter
        case .area: .area
        case .distance, .calibrate: .distance
        }
    }
}

/// A measurement under way (the Windows page viewer's measuring state, kept here so it is tested): the points clicked on
/// one page and where the pointer is. A distance (or calibration) ends at its second click; a perimeter or an area at a
/// double-click or `finish` (Return) once it has enough points; `removeLast` (Backspace) takes a point back and
/// `cancel` (Esc) drops it. Shift keeps the next segment horizontal, vertical or at 45°. Points are page space, already
/// kept on the page by the caller.
public struct MeasureDraft: Sendable, Equatable {
    public let tool: MeasureTool
    /// The page being measured; -1 while nothing is under way.
    public private(set) var page = -1
    public private(set) var points: [PointD] = []
    /// Where the pointer is (the next point if clicked), on `page`.
    public private(set) var hover: PointD?

    public init(_ tool: MeasureTool) { self.tool = tool }

    public var isActive: Bool { page >= 0 }

    /// Points a finished measurement needs.
    public var needed: Int { tool == .area ? 3 : 2 }

    /// With Shift, the new point lies horizontally, vertically or at 45° from the last one.
    private func snap(_ p: PointD, _ shift: Bool) -> PointD {
        guard shift, let last = points.last else { return p }
        return DrawingGeometry.snapAngle(last, p)
    }

    /// A click (`clicks` 2 for a double-click's second press). Returns the finished measurement when the click ends it.
    public mutating func click(page: Int, _ p: PointD, clicks: Int = 1, shift: Bool = false) -> (page: Int, points: [PointD])? {
        if isActive && page != self.page { cancel() } // a click on another page starts over there
        let q = snap(p, shift)
        if !isActive {
            self.page = page
            points = []
        }
        // A double-click finishes a perimeter or area (its second press lands on the point just added).
        if clicks >= 2 && tool.kind != .distance { return finish() }
        if points.last.map({ MeasureGeometry.distance($0, q) > 0.01 }) ?? true { points.append(q) }
        if tool.kind == .distance && points.count == 2 { return finish() }
        return nil
    }

    /// The pointer moved over `page` (ignored unless a measurement is under way there).
    public mutating func move(page: Int, _ p: PointD, shift: Bool = false) {
        guard isActive, page == self.page else { return }
        hover = snap(p, shift)
    }

    /// Return: the measurement when it has enough points (it is then over), else nil and it goes on.
    public mutating func finish() -> (page: Int, points: [PointD])? {
        let done = (page: page, points: points)
        if page < 0 || points.count < needed { return nil }
        cancel()
        return done
    }

    /// Backspace: the last point taken back (none left: nothing is under way). False when there was none.
    @discardableResult
    public mutating func removeLast() -> Bool {
        guard !points.isEmpty else { return false }
        points.removeLast()
        if points.isEmpty { cancel() }
        return true
    }

    public mutating func cancel() {
        page = -1
        points = []
        hover = nil
    }

    /// The value so far at `scale` ("12.50 ft"; an area with its perimeter), with the pointer's spot as the next point
    /// when `includeHover`; "" while nothing is under way.
    public func value(_ scale: MeasureScale, includeHover: Bool = true) -> String {
        var pts = points
        if includeHover, let hover { pts.append(hover) }
        if !isActive || pts.isEmpty { return "" }
        if tool.kind == .area && pts.count >= 3 {
            let perimeter = scale.formatValue(.perimeter, MeasureGeometry.length(pts, closed: true) * scale.perUnit)
            return "\(scale.format(.area, pts)) · perimeter \(perimeter)"
        }
        return scale.format(.distance, pts)
    }

    /// For the self-test and VoiceOver: how many points and the value without the pointer (nil while nothing is under way).
    public func described(_ scale: MeasureScale) -> String? {
        isActive ? "\(points.count) point(s), \(value(scale, includeHover: false))" : nil
    }
}

/// The scales of one version of a document, read once (the Windows tab's cached viewports): at a point of a page, the
/// page's viewport there, else real size in that page's units (its /UserUnit).
public struct MeasureScales: Sendable {
    private let viewports: [Int: Measurements.Viewports]
    private let units: [Int: Double]

    /// Unreadable scales count as none (real size everywhere).
    public init(_ data: [UInt8], _ password: String?) {
        viewports = (try? Measurements.viewports(data, password)) ?? [:]
        units = (try? Measurements.userUnits(data, password)) ?? [:]
    }

    public func scaleAt(_ page: Int, _ at: PointD) -> MeasureScale {
        if let s = Measurements.scaleAt(viewports[page], at) { return s }
        var real = MeasureScale.default
        real.userUnit = units[page] ?? 1
        return real
    }

    /// The scale of a whole page (at its top-left corner, as Set Measuring Scale shows "Now:").
    public func pageScale(_ page: Int) -> MeasureScale { scaleAt(page, PointD(1, 1)) }
}

extension MeasureScale {
    /// The text a finished measurement is announced with: "Distance: 20.00 ft (scale 1 in = 10 ft)."; an area adds its
    /// perimeter (the Windows tab's notice).
    public func announcement(_ kind: MeasureKind, _ points: [PointD]) -> String {
        let name = kind == .distance ? "Distance" : kind == .perimeter ? "Perimeter" : "Area"
        var extra = ""
        if kind == .area { extra = ", perimeter \(formatValue(.perimeter, MeasureGeometry.length(points, closed: true) * perUnit))" }
        return "\(name): \(format(kind, points))\(extra) (scale \(ratio))."
    }

    /// A number typed in a dialog, in the Mac's own format or with a point, within `low`...`high` (Windows'
    /// `FormDialog.TryNumber`); nil when it isn't one.
    public static func number(_ text: String, _ low: Double, _ high: Double, locale: Locale = .current) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        guard let v = f.number(from: t)?.doubleValue ?? Double(t), v.isFinite, v >= low, v <= high else { return nil }
        return v
    }
}
