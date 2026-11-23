import CryptoKit
import Foundation
import PrintCore

/// Which way a guide or snap line runs in page space: at a page x (a line down the page) or a page y (across it).
public enum GuideAxis: Sendable { case x, y }

/// A guide on a page: a line at `at` points from the page's left (`.x`) or top.
public struct Guide: Equatable, Hashable, Sendable {
    public var page: Int
    public var axis: GuideAxis
    public var at: Double

    public init(_ page: Int, _ axis: GuideAxis, _ at: Double) {
        self.page = page
        self.axis = axis
        self.at = at
    }
}

/// A line something snapped to (page space), for the view to show while it holds.
public struct SnapLine: Equatable, Sendable {
    public var axis: GuideAxis
    public var at: Double

    public init(_ axis: GuideAxis, _ at: Double) {
        self.axis = axis
        self.at = at
    }
}

/// The unit the rulers count in: its name and how many PDF points one of it is.
public struct RulerUnit: Equatable, Sendable {
    public var name: String
    public var pointsPer: Double

    public init(_ name: String, _ pointsPer: Double) {
        self.name = name
        self.pointsPer = pointsPer
    }

    public static let inches = RulerUnit("in", 72)
    public static let millimeters = RulerUnit("mm", 72 / 25.4)
    public static let centimeters = RulerUnit("cm", 72 / 2.54)
    public static let points = RulerUnit("pt", 1)

    /// The units Ruler Units goes through ("auto" first: the page's measurement scale, else the region's).
    public static let choices = ["auto", "in", "mm", "cm", "pt"]

    /// The unit for a setting (`choices`): a fixed one, or "auto": the page's measurement scale when it has one (the rulers
    /// count real units, as Measure does), else inches where the region isn't metric and millimeters where it is.
    public static func `for`(_ setting: String, _ pageScale: MeasureScale?, metric: Bool) -> RulerUnit {
        switch setting {
        case "in": return .inches
        case "mm": return .millimeters
        case "cm": return .centimeters
        case "pt": return .points
        default:
            if let s = pageScale, s != .default, s.perUnit > 0, s.perUnit.isFinite { return RulerUnit(s.unit, 1 / s.perUnit) }
            return metric ? .millimeters : .inches
        }
    }
}

/// A tick of a ruler: where (points from the page's top-left as shown), how long (0: labelled, 1: half, 2: small), its label.
public struct RulerTick: Equatable, Sendable {
    public var at: Double
    public var level: Int
    public var label: String?
}

/// Rulers, guides, a grid and snapping (roadmap 4.19; the Windows app's `LayoutAids`): what the rulers mark, where a guide
/// dragged from a ruler lands, and what a point or box snaps to. The view (`PagesView`'s rulers and `LayoutView`) draws them
/// and passes the pointer in.
public enum LayoutAids {
    /// The fewest pixels between two labelled ticks.
    public static let minLabelGap = 60.0

    /// How near (pixels) a pointer must come to a guide, grid line or edge to snap to it.
    public static let snapPixels = 6.0

    /// The ticks of a ruler from `from` to `to` points along the page as shown (0: its top or left edge), at
    /// `pixelsPerPoint`: labelled every 1, 2 or 5 × 10ⁿ units, as many as fit `minLabelGap` apart, halves and tenths (or
    /// fifths, quarters) between them where there is room. `locale` writes the labels (the decimal comma).
    public static func ticks(_ from: Double, _ to: Double, _ pixelsPerPoint: Double, _ unit: RulerUnit, locale: Locale = .current) -> [RulerTick] {
        guard pixelsPerPoint > 0, unit.pointsPer > 0, from.isFinite, to.isFinite, to > from else { return [] }
        let pixelsPerUnit = pixelsPerPoint * unit.pointsPer
        let step = niceStep(minLabelGap / pixelsPerUnit)
        // Between labels: tenths, fifths or halves, whichever leaves at least 5 pixels apart.
        let labelPixels: Double = step * pixelsPerUnit
        var divisions = 1
        for d in [10, 5, 2] where labelPixels / Double(d) >= 5 {
            divisions = d
            break
        }
        let minor = step / Double(divisions)
        let first = (from / unit.pointsPer / minor).rounded(.down)
        let last = (to / unit.pointsPer / minor).rounded(.up)
        if last - first > 20_000 { return [] }
        let decimals = max(0, Int((-log10(step) - 1e-9).rounded(.up)))
        let format = NumberFormatter()
        format.locale = locale
        format.numberStyle = .decimal
        format.usesGroupingSeparator = false
        format.minimumFractionDigits = 0
        format.maximumFractionDigits = max(1, decimals)
        format.roundingMode = .halfEven
        var ticks: [RulerTick] = []
        var k = first
        while k <= last {
            defer { k += 1 }
            let units = k * minor
            let at = units * unit.pointsPer
            if at < from - 1e-9 || at > to + 1e-9 { continue }
            var i = Int(k.rounded()) % divisions
            if i < 0 { i += divisions }
            let level = i == 0 ? 0 : divisions % 2 == 0 && i == divisions / 2 ? 1 : 2
            let label = level == 0 ? format.string(from: NSNumber(value: roundedHalfEven(units, decimals))) : nil
            ticks.append(RulerTick(at: at, level: level, label: label))
        }
        return ticks
    }

    /// .NET's `Math.Round(v, decimals)` (to even).
    private static func roundedHalfEven(_ v: Double, _ decimals: Int) -> Double {
        let p = pow(10, Double(decimals))
        return (v * p).rounded(.toNearestOrEven) / p
    }

    /// The smallest 1, 2 or 5 × 10ⁿ at least `atLeast`.
    public static func niceStep(_ atLeast: Double) -> Double {
        guard atLeast > 0, atLeast.isFinite else { return 1 }
        let p = pow(10, log10(atLeast).rounded(.down))
        for m in [1.0, 2, 5, 10] where m * p >= atLeast * (1 - 1e-9) { return m * p }
        return 10 * p
    }

    /// The guide a drag from a ruler makes: from the top ruler a line across the screen, from the left one a line down it,
    /// at `viewPos` points from the page's top or left as shown; in page space that is a y or an x, depending on the view's
    /// turn. Nil when it is off the page.
    public static func fromRuler(_ page: Int, topRuler: Bool, _ viewPos: Double, _ pageWidth: Double, _ pageHeight: Double,
                                 _ viewRotation: Int) -> Guide? {
        let (vw, vh) = RotatedView.size(pageWidth, pageHeight, viewRotation)
        if viewPos < 0 || viewPos > (topRuler ? vh : vw) { return nil }
        // A point on the line as shown, turned back to page space; the line runs along the page's x or y.
        let p = RotatedView.fromView(topRuler ? 0 : viewPos, topRuler ? viewPos : 0, pageWidth, pageHeight, viewRotation)
        let turnedQuarter = viewRotation == 90 || viewRotation == 270
        return topRuler != turnedQuarter ? Guide(page, .y, p.y) : Guide(page, .x, p.x)
    }

    /// Whether a guide runs across the screen (else down it) at the view's turn.
    public static func acrossScreen(_ axis: GuideAxis, _ viewRotation: Int) -> Bool {
        (axis == .y) != (viewRotation == 90 || viewRotation == 270)
    }

    /// The grid's lines on a page (page space, from its top-left): every `step` points; none when too dense.
    public static func grid(_ pageWidth: Double, _ pageHeight: Double, _ step: Double) -> (xs: [Double], ys: [Double]) {
        guard step >= 1, pageWidth / step <= 2000, pageHeight / step <= 2000 else { return ([], []) }
        var xs: [Double] = [], ys: [Double] = []
        var x = step
        while x < pageWidth - 1e-6 {
            xs.append(x)
            x += step
        }
        var y = step
        while y < pageHeight - 1e-6 {
            ys.append(y)
            y += step
        }
        return (xs, ys)
    }

    /// The grid steps offered (points): ¼ in, ½ in, 1 in, 5 mm, 1 cm, 10 pt.
    public static let gridSteps: [Double] = [18, 36, 72, 72 / 25.4 * 5, 72 / 2.54, 10]
}

/// The guides of a document while it is open (never written into the PDF): kept per page, in page space.
public final class PageGuides {
    /// The most guides a page keeps.
    public static let maxPerPage = 200

    public private(set) var all: [Guide] = []

    /// Bumped on every change, so a view knows to draw again.
    public private(set) var version = 0

    public init() {}

    public func on(_ page: Int) -> [Guide] { all.filter { $0.page == page } }

    /// Adds a guide, kept on the page (a page's guides past `maxPerPage` are refused: false).
    @discardableResult
    public func add(_ g: Guide, _ pageWidth: Double, _ pageHeight: Double) -> Bool {
        guard g.at.isFinite, all.filter({ $0.page == g.page }).count < Self.maxPerPage else { return false }
        var kept = g
        kept.at = min(max(g.at, 0), g.axis == .x ? pageWidth : pageHeight)
        all.append(kept)
        version += 1
        return true
    }

    @discardableResult
    public func remove(_ g: Guide) -> Bool {
        guard let i = all.firstIndex(of: g) else { return false }
        all.remove(at: i)
        version += 1
        return true
    }

    /// A guide moved to `at`; off the page (dragged back onto the ruler) it goes.
    @discardableResult
    public func move(_ g: Guide, _ at: Double, _ pageWidth: Double, _ pageHeight: Double) -> Guide? {
        guard let i = all.firstIndex(of: g) else { return nil }
        let maxAt = g.axis == .x ? pageWidth : pageHeight
        if !at.isFinite || at < 0 || at > maxAt {
            all.remove(at: i)
            version += 1
            return nil
        }
        all[i].at = at
        version += 1
        return all[i]
    }

    /// Clears one page's guides, or every page's (nil).
    @discardableResult
    public func clear(_ page: Int? = nil) -> Int {
        let before = all.count
        all.removeAll { page == nil || $0.page == page }
        let n = before - all.count
        if n > 0 { version += 1 }
        return n
    }

    /// The guide nearest a page point, within `reach` points; nil: none.
    public func at(_ page: Int, _ p: PointD, _ reach: Double) -> Guide? {
        func d(_ g: Guide) -> Double { abs((g.axis == .x ? p.x : p.y) - g.at) }
        return all.filter { $0.page == page && d($0) <= reach }.min { d($0) < d($1) }
    }

    /// Each page's identity for its guides (roadmap 4.19): its boxes, its turn and its own content as stored. Annotations,
    /// form fields and the document's other pages don't change it; moving the page keeps it, turning, resizing, cropping
    /// or replacing the page (or editing its text) changes it.
    public static func keys(_ data: [UInt8], _ password: String?) throws -> [String] {
        let doc = try PdfEdit.openToRead(data, password)
        var keys: [String] = []
        for i in 0..<(try doc.pageCount()) {
            let page = doc.page(i)
            var hash = SHA256()
            func add(_ item: PObj?) {
                if let item, item.isStream, let bytes = item.rawStreamData { hash.update(data: bytes) }
            }
            if let parts = page["Contents"], parts.isArray {
                for part in parts.elements { add(part) }
            } else {
                add(page["Contents"])
            }
            func box(_ key: String) -> String {
                guard let b = PageBoxes.inherited(page, key), b.isArray else { return "" }
                return b.elements.map { PdfNum.f($0.number ?? 0) }.joined(separator: ",")
            }
            let digest = hash.finalize().map { String(format: "%02X", $0) }.joined()
            keys.append("\(PageBoxes.rotate(page))|\(box("MediaBox"))|\(box("CropBox"))|\(digest)")
        }
        return keys
    }

    /// The pages changed (`before` and `after`: `keys` of the document before and after): each page's guides follow the
    /// page to where it is now (of several alike, the nearest); a page that isn't there any more takes its guides with it.
    /// Returns how many guides went.
    @discardableResult
    public func remap(_ before: [String], _ after: [String]) -> Int {
        var positions: [String: [Int]] = [:]
        for (j, k) in after.enumerated() { positions[k, default: []].append(j) }
        var moved: [Guide] = []
        var gone = 0
        for g in all {
            guard before.indices.contains(g.page), let places = positions[before[g.page]] else {
                gone += 1
                continue
            }
            let to = places.min { abs($0 - g.page) < abs($1 - g.page) } ?? g.page
            moved.append(Guide(to, g.axis, g.at))
        }
        if gone == 0 && moved == all { return 0 }
        all = moved
        version += 1
        return gone
    }

    /// Pages moved, added or deleted with no way to tell which (their keys couldn't be read): the guides go.
    public func pagesChanged() { clear() }
}

/// What a point or box snaps to on one page: lines at page x's and y's (guides, other objects' edges and centers) and a
/// grid every `gridStep` points, within `reach` points. Each axis snaps on its own, to the nearest. `lines`: what the last
/// call snapped to, for the view to show.
public final class Snapper {
    private let xs: [Double]
    private let ys: [Double]
    public let gridStep: Double
    public let reach: Double
    public private(set) var lines: [SnapLine] = []

    init(_ xs: [Double], _ ys: [Double], _ gridStep: Double, _ reach: Double) {
        self.xs = xs
        self.ys = ys
        self.gridStep = gridStep
        self.reach = reach
    }

    /// What snapping takes on a page: guides (if given), the grid (if a step is given) and the left, middle and right (top,
    /// middle, bottom) of the `objects` (fields, comments, stamps), within `reach` points; nil when there is nothing to snap
    /// to.
    public static func `for`(_ guides: [Guide]?, _ objects: [RectD]?, gridStep: Double, reach: Double) -> Snapper? {
        var xs: [Double] = [], ys: [Double] = []
        for g in guides ?? [] {
            if g.axis == .x { xs.append(g.at) } else { ys.append(g.at) }
        }
        for r in (objects ?? []).prefix(2000) where !r.isEmpty {
            xs += [r.x, r.centerX, r.right]
            ys += [r.y, r.centerY, r.bottom]
        }
        if (xs.isEmpty && ys.isEmpty && !(gridStep >= 1)) || !(reach > 0) { return nil }
        return Snapper(xs, ys, gridStep >= 1 ? gridStep : 0, reach)
    }

    /// The nearest line to `v` on one axis within reach (nil: none).
    private func nearest(_ v: Double, _ axis: GuideAxis) -> Double? {
        var best: Double?
        var bestD = reach
        for t in axis == .x ? xs : ys {
            let d = abs(t - v)
            if d <= bestD {
                best = t
                bestD = d
            }
        }
        if gridStep > 0 {
            let g = (v / gridStep).rounded(.toNearestOrEven) * gridStep
            if abs(g - v) < bestD { best = g }
        }
        return best
    }

    /// A point snapped on each axis to the nearest line within reach.
    public func point(_ p: PointD) -> PointD {
        var found: [SnapLine] = []
        let x = nearest(p.x, .x), y = nearest(p.y, .y)
        if let x { found.append(SnapLine(.x, x)) }
        if let y { found.append(SnapLine(.y, y)) }
        lines = found
        return PointD(x ?? p.x, y ?? p.y)
    }

    /// A box moved (its size kept) so its nearest edge or center on each axis lies on a line within reach.
    public func move(_ r: RectD) -> RectD {
        var found: [SnapLine] = []
        let dx = shift([r.x, r.centerX, r.right], .x, &found)
        let dy = shift([r.y, r.centerY, r.bottom], .y, &found)
        lines = found
        return RectD(r.x + dx, r.y + dy, r.width, r.height)
    }

    private func shift(_ candidates: [Double], _ axis: GuideAxis, _ found: inout [SnapLine]) -> Double {
        var best: Double?
        var at = 0.0
        for c in candidates {
            if let t = nearest(c, axis), best == nil || abs(t - c) < abs(best ?? 0) {
                best = t - c
                at = t
            }
        }
        guard let best else { return 0 }
        found.append(SnapLine(axis, at))
        return best
    }

    /// A box resized: the edges that moved from `before` snap to lines within reach (no smaller than `min`).
    public func resize(_ before: RectD, _ r: RectD, min minSize: Double = 1) -> RectD {
        var found: [SnapLine] = []
        var l = r.x, t = r.y, right = r.right, b = r.bottom
        func edge(_ v: Double, _ was: Double, _ axis: GuideAxis) -> Double? { abs(v - was) < 1e-9 ? nil : nearest(v, axis) }
        // Each edge's line is shown only when the snap is taken (not when it would leave the box too small).
        if let nl = edge(l, before.x, .x), right - nl >= minSize {
            l = nl
            found.append(SnapLine(.x, nl))
        }
        if let nr = edge(right, before.right, .x), nr - l >= minSize {
            right = nr
            found.append(SnapLine(.x, nr))
        }
        if let nt = edge(t, before.y, .y), b - nt >= minSize {
            t = nt
            found.append(SnapLine(.y, nt))
        }
        if let nb = edge(b, before.bottom, .y), nb - t >= minSize {
            b = nb
            found.append(SnapLine(.y, nb))
        }
        lines = found
        return RectD.fromEdges(l, t, right, b)
    }
}
