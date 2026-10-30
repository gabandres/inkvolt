import Foundation

/// What a measurement measures: a straight distance, the length of a path, or the area a path encloses.
public enum MeasureKind: Sendable, Equatable { case distance, perimeter, area }

/// Lengths and areas of page-space paths (points; any y direction).
public enum MeasureGeometry {
    /// The length of the path through `points` (with `closed`, back to the start too).
    public static func length(_ points: [PointD], closed: Bool = false) -> Double {
        var sum = 0.0
        for i in points.indices.dropFirst() { sum += distance(points[i - 1], points[i]) }
        if closed && points.count > 2 { sum += distance(points[points.count - 1], points[0]) }
        return sum
    }

    public static func distance(_ a: PointD, _ b: PointD) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The area enclosed by the polygon through `points` (shoelace formula; any winding).
    public static func area(_ points: [PointD]) -> Double {
        if points.count < 3 { return 0 }
        var twice = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }

    /// The polygon's centroid (where an area label goes); the points' middle when it has no area.
    public static func centroid(_ points: [PointD]) -> PointD {
        if points.isEmpty { return PointD(0, 0) }
        var twice = 0.0, cx = 0.0, cy = 0.0
        if points.count >= 3 {
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                let cross = a.x * b.y - b.x * a.y
                twice += cross
                cx += (a.x + b.x) * cross
                cy += (a.y + b.y) * cross
            }
        }
        if abs(twice) < 1e-9 {
            let xs = points.map(\.x), ys = points.map(\.y)
            return PointD((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
        }
        return PointD(cx / (3 * twice), cy / (3 * twice))
    }
}

/// A drawing scale: how many real units one PDF point stands for, the unit, and the ratio as people write it
/// ("1 in = 10 ft"). `decimals` is how many decimals values show.
public struct MeasureScale: Equatable, Sendable {
    public var perPoint: Double
    public var unit: String
    public var ratio: String
    public var decimals: Int
    /// Points per unit of the page's user space (its /UserUnit; 1 normally): page coordinates are multiplied by it before
    /// `perPoint` applies, so a drawing on a page with /UserUnit 2 measures true.
    public var userUnit = 1.0

    public init(_ perPoint: Double, _ unit: String, _ ratio: String, decimals: Int = 2, userUnit: Double = 1) {
        self.perPoint = perPoint
        self.unit = unit
        self.ratio = ratio
        self.decimals = decimals
        self.userUnit = userUnit
    }

    /// Real units per unit of page coordinates (what a PDF's /X /C conversion factor is).
    public var perUnit: Double { perPoint * userUnit }

    /// Points per unit (1 in = 72 pt).
    private static let pointsPer: [String: Double] = [
        "pt": 1, "in": 72, "ft": 72 * 12, "yd": 72 * 36, "mi": 72 * 63360,
        "mm": 72 / 25.4, "cm": 72 / 2.54, "m": 72 / 0.0254, "km": 72 / 0.0000254,
    ]

    /// The units a scale can use, in the order the dialogs list them.
    public static let units = ["in", "ft", "yd", "mi", "mm", "cm", "m", "km", "pt"]

    /// Real size: 1 in on the page is 1 in.
    public static let `default` = MeasureScale(1.0 / 72, "in", "1 in = 1 in")

    private static func clampDecimals(_ d: Int) -> Int { min(max(d, 0), 6) }

    /// `docValue` `docUnit` on the page = `realValue` `realUnit`.
    /// Throws `PdfEditError` when a value isn't positive or a unit isn't one of `units`.
    public static func from(_ docValue: Double, _ docUnit: String, _ realValue: Double, _ realUnit: String,
                            decimals: Int = 2) throws -> MeasureScale {
        if !(docValue > 0) || !(realValue > 0) || !docValue.isFinite || !realValue.isFinite {
            throw PdfEditError("Both lengths of a scale must be more than 0.")
        }
        guard let per = pointsPer[docUnit], pointsPer[realUnit] != nil else {
            throw PdfEditError("Units are \(units.joined(separator: ", ")).")
        }
        return MeasureScale(realValue / (docValue * per), realUnit, "\(n(docValue)) \(docUnit) = \(n(realValue)) \(realUnit)",
                            decimals: clampDecimals(decimals))
    }

    /// The scale that makes a line `measuredPoints` long on the page `realLength` long.
    public static func calibrate(_ measuredPoints: Double, _ realLength: Double, _ unit: String, decimals: Int = 2) throws -> MeasureScale {
        if !(measuredPoints > 0) || !(realLength > 0) { throw PdfEditError("Both lengths must be more than 0.") }
        if pointsPer[unit] == nil { throw PdfEditError("Units are \(units.joined(separator: ", ")).") }
        let perPoint = realLength / measuredPoints
        return MeasureScale(perPoint, unit, "1 in = \(n(72 * perPoint)) \(unit)", decimals: clampDecimals(decimals))
    }

    /// .NET's `Math.Round(v, 4).ToString("0.####", Invariant)`.
    static func n(_ v: Double) -> String { trimmed(v, 4) }

    /// `v` with at most `decimals` decimals and no trailing zeros (.NET's "0.##…" in the invariant culture).
    static func trimmed(_ v: Double, _ decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    private static let number = #"\d+(?:\.\d+)?"#
    private static let ratioPattern = try! NSRegularExpression(
        pattern: #"^\s*(\#(number)(?:\s*/\s*\#(number))?)\s*([a-z]+)\s*=\s*(-?\#(number)(?:\s*/\s*\#(number))?)\s*([a-z]+)\s*$"#,
        options: [.caseInsensitive])
    private static let colonPattern = try! NSRegularExpression(
        pattern: #"^\s*(\#(number))\s*:\s*(\#(number))\s*([a-z]+)\s*$"#, options: [.caseInsensitive])

    /// "1 in = 10 ft", "1/4 in = 1 ft", "1:100 m" (1 on the page is 100 real: the same unit on both sides); nil when the
    /// text isn't a scale (.NET's `TryParse`).
    public static func parse(_ text: String) -> MeasureScale? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        func number(_ s: String) -> Double? {
            let parts = s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let v = Double(parts[0]) else { return nil }
            if parts.count == 2 { return Double(parts[1]).map { v / $0 } }
            return v
        }
        if let m = ratioPattern.firstMatch(in: text, range: whole) {
            guard let dv = number(group(m, 1)), let rv = number(group(m, 3)) else { return nil }
            return try? from(dv, group(m, 2).lowercased(), rv, group(m, 4).lowercased())
        }
        if let c = colonPattern.firstMatch(in: text, range: whole) {
            let unit = group(c, 3).lowercased()
            guard let dv = Double(group(c, 1)), let rv = Double(group(c, 2)), var s = try? from(dv, unit, rv, unit) else { return nil }
            s.ratio = "\(group(c, 1)):\(group(c, 2)) \(unit)"
            return s
        }
        return nil
    }

    public var areaUnit: String { "sq " + unit }

    /// The real length (distance, perimeter: the path as drawn) or area of a page-space path.
    public func value(_ kind: MeasureKind, _ points: [PointD]) -> Double {
        kind == .area ? MeasureGeometry.area(points) * perUnit * perUnit : MeasureGeometry.length(points) * perUnit
    }

    /// "12.50 ft", "1,000.00 sq ft".
    public func format(_ kind: MeasureKind, _ points: [PointD]) -> String { formatValue(kind, value(kind, points)) }

    public func formatValue(_ kind: MeasureKind, _ value: Double) -> String {
        "\(Self.grouped(value, decimals)) \(kind == .area ? areaUnit : unit)"
    }

    /// .NET's "N<decimals>" in the invariant culture: thousands separated by commas, a point before the decimals.
    static func grouped(_ v: Double, _ decimals: Int) -> String {
        let fixed = String(format: "%.\(decimals)f", abs(v))
        let dot = fixed.firstIndex(of: ".") ?? fixed.endIndex
        let whole = Array(fixed[..<dot])
        var out = ""
        for (i, ch) in whole.enumerated() {
            if i > 0 && (whole.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        out += fixed[dot...]
        let negative = v < 0 && fixed.contains { $0 != "0" && $0 != "." }
        return negative ? "-" + out : out
    }
}

/// A measurement annotation on a page.
public struct MeasurementInfo: Sendable {
    public var id: String?
    public var kind: MeasureKind
    public var points: [PointD]
    public var scale: MeasureScale
    public var value: Double
    public var text: String
}

/// Measurements in the PDF's own terms (ISO 32000-1 12.9): a scale is a rectilinear measure dictionary (/Measure /RL:
/// /R the ratio, /X the number format with the conversion factor /C from points and the unit /U, /D distance and /A area
/// formats), kept by a page in its viewports (/VP, each with a /BBox; where viewports overlap, the last one listed applies)
/// and by each measurement. Measurements are Line, PolyLine and Polygon annotations with /IT LineDimension,
/// PolyLineDimension or PolygonDimension, their value as /Contents and drawn as a label in the appearance; they redraw
/// with a new value when reshaped (see `Annotations.apply`). Acrobat reads and keeps them as measurements. Written as
/// the Windows app writes them, so a file measured on one opens the same on the other.
public enum Measurements {
    /// The /Name of the viewport Inkvolt PDF writes for a page's scale (replaced when the scale is set again).
    public static let viewportName = "Inkvolt PDF scale"

    /// The scaled areas of one page (page space), in lookup order.
    public typealias Viewports = [(area: RectD, scale: MeasureScale)]

    public static func defaultStyle(_ kind: MeasureKind) -> AnnotStyle {
        var s = AnnotStyle(color: AnnotColor(0.8, 0.1, 0.1), width: 1)
        s.startEnding = kind == .distance ? .butt : .none
        s.endEnding = kind == .distance ? .butt : .none
        return s
    }

    public static func subtype(_ kind: MeasureKind) -> String {
        switch kind {
        case .distance: "Line"
        case .perimeter: "PolyLine"
        case .area: "Polygon"
        }
    }

    static func kindOf(_ subtype: String?) -> MeasureKind? {
        switch subtype {
        case "Line": .distance
        case "PolyLine": .perimeter
        case "Polygon": .area
        default: nil
        }
    }

    /// The scale the page's viewports give at `at` (page space), or nil when none does.
    public static func pageScale(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ at: PointD) throws -> MeasureScale? {
        let doc = try PdfEdit.openToRead(data, password)
        if try pageIndex < 0 || pageIndex >= doc.pageCount() { return nil }
        return pageScale(doc.page(pageIndex), at)
    }

    /// The scaled areas of every page (page space), in the order a lookup goes: where they overlap the last one listed
    /// applies (see `scaleAt`). Read once per document version, then looked up while the pointer moves.
    public static func viewports(_ data: [UInt8], _ password: String?) throws -> [Int: Viewports] {
        let doc = try PdfEdit.openToRead(data, password)
        var all: [Int: Viewports] = [:]
        for i in 0..<(try doc.pageCount()) {
            let page = doc.page(i)
            guard let vps = page.array("VP") else { continue }
            var list: Viewports = []
            for vp in vps.elements where vp.isDict {
                guard let b = PageBoxes.rect(vp.array("BBox")), let m = vp.dict("Measure"),
                      let s = scaleOf(m, PageMarks.userUnit(page)) else { continue }
                list.append((PageBoxes.toPageSpace(page, b.x1, b.y1, b.x2, b.y2), s))
            }
            if !list.isEmpty { all[i] = list }
        }
        return all
    }

    /// The /UserUnit of every page that has one other than 1 (points per unit of its coordinates).
    public static func userUnits(_ data: [UInt8], _ password: String?) throws -> [Int: Double] {
        let doc = try PdfEdit.openToRead(data, password)
        var units: [Int: Double] = [:]
        for i in 0..<(try doc.pageCount()) {
            let u = PageMarks.userUnit(doc.page(i))
            if u != 1 { units[i] = u }
        }
        return units
    }

    /// The scale at `at` among `viewports` (page space; the last that contains it), else nil.
    public static func scaleAt(_ viewports: Viewports?, _ at: PointD) -> MeasureScale? {
        viewports?.last { v in
            at.x >= v.area.x - 0.01 && at.x <= v.area.right + 0.01 && at.y >= v.area.y - 0.01 && at.y <= v.area.bottom + 0.01
        }?.scale
    }

    static func pageScale(_ page: PObj, _ at: PointD) -> MeasureScale? {
        guard let vps = page.array("VP") else { return nil }
        let (x, y) = PageBoxes.toPdf(page, at.x, at.y)
        var found: MeasureScale?
        for vp in vps.elements where vp.isDict {
            guard let b = PageBoxes.rect(vp.array("BBox")) else { continue }
            if x < b.x1 || x > b.x2 || y < b.y1 || y > b.y2 { continue }
            if let m = vp.dict("Measure"), let s = scaleOf(m, PageMarks.userUnit(page)) { found = s }
        }
        return found
    }

    /// Sets (or with nil removes) the scale of `pages`: a viewport over the whole page, replacing any other viewport that
    /// covers the whole page, and listed first so the document's viewports for parts of the page (details at other
    /// scales) keep applying inside their areas.
    public static func setPageScale(_ data: [UInt8], _ password: String?, _ pages: [Int], _ scale: MeasureScale?) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            let count = try doc.pageCount()
            for i in Set(pages).sorted() where i >= 0 && i < count {
                let page = doc.page(i)
                let existing = page.array("VP")
                let vps = doc.array(existing?.elements ?? [])
                let media = PageBoxes.mediaBox(page)
                func wholePage(_ vp: PObj) -> Bool {
                    guard let b = PageBoxes.rect(vp.array("BBox")) else { return false }
                    return b.x1 <= media.x1 + 1 && b.x2 >= media.x2 - 1 && b.y1 <= media.y1 + 1 && b.y2 >= media.y2 - 1
                }
                for k in stride(from: vps.count - 1, through: 0, by: -1) {
                    guard let vp = vps[k] else { continue }
                    if !vp.isDict || vp.text("Name") == viewportName || wholePage(vp) { vps.remove(at: k) }
                }
                if var scale {
                    scale.userUnit = PageMarks.userUnit(page)
                    let vp = doc.dict([
                        ("Type", doc.name("Viewport")),
                        ("BBox", doc.realArray([media.x1, media.y1, media.x2, media.y2])),
                        ("Name", doc.text(viewportName)),
                        ("Measure", measureDict(doc, scale)),
                    ])
                    vps.insert(vp, at: 0)
                }
                if vps.count == 0 { page.remove("VP") } else { page.set("VP", vps) }
            }
        }
    }

    /// Adds a measurement through `points` (page space) at `scale`, labeled with its value.
    /// Throws `PdfEditError` with too few points for `kind`.
    public static func add(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ kind: MeasureKind, _ points: [PointD],
                           _ scale: MeasureScale, author: String, id: String? = nil, style: AnnotStyle? = nil) throws -> [UInt8] {
        try Annotations.addMeasurement(data, password, pageIndex, subtype(kind), points, style ?? defaultStyle(kind), author, id, scale)
    }

    /// The measurements on a page (annotations with a rectilinear measure), with their values.
    public static func read(_ data: [UInt8], _ password: String?, _ pageIndex: Int) throws -> [MeasurementInfo] {
        let doc = try PdfEdit.openToRead(data, password)
        if try pageIndex < 0 || pageIndex >= doc.pageCount() { return [] }
        let page = doc.page(pageIndex)
        var list: [MeasurementInfo] = []
        for a in page.array("Annots")?.elements ?? [] where a.isDict {
            guard let m = a.dict("Measure"), let scale = scaleOf(m, PageMarks.userUnit(page)), let kind = kindOf(a.name("Subtype")) else { continue }
            let pts = points(page, a.array(kind == .distance ? "L" : "Vertices"))
            if pts.count < (kind == .area ? 3 : 2) { continue }
            let value = scale.value(kind, pts)
            list.append(MeasurementInfo(id: a.text("NM"), kind: kind, points: pts, scale: scale, value: value, text: scale.formatValue(kind, value)))
        }
        return list
    }

    private static func points(_ page: PObj, _ flat: PObj?) -> [PointD] {
        guard let flat else { return [] }
        return stride(from: 0, to: flat.count - 1, by: 2).map { i in
            let q = PageBoxes.toPage(page, flat.num(i), flat.num(i + 1))
            return PointD(q.x, q.y)
        }
    }

    /// A rectilinear measure dictionary for `scale` (X: points to the unit; D and A in that unit).
    static func measureDict(_ doc: MuDoc, _ scale: MeasureScale) -> PObj {
        func format(_ unit: String, _ factor: Double) -> PObj {
            var d = 1
            for _ in 0..<scale.decimals { d *= 10 }
            return doc.array([doc.dict([
                ("Type", doc.name("NumberFormat")), ("U", doc.text(unit)), ("C", doc.real(factor)), ("F", doc.name("D")),
                ("D", doc.int(d)), ("RT", doc.text("")), ("SS", doc.text("")),
            ])])
        }
        return doc.dict([
            ("Type", doc.name("Measure")), ("Subtype", doc.name("RL")), ("R", doc.text(scale.ratio)),
            ("X", format(scale.unit, scale.perUnit)), // from the page's user space units
            ("D", format(scale.unit, 1)), ("A", format(scale.areaUnit, 1)),
        ])
    }

    /// The scale of a rectilinear measure dictionary on a page with `userUnit` (nil for geospatial ones or without a
    /// conversion factor). /X /C converts from user space units, so per point it is /C ÷ /UserUnit.
    static func scaleOf(_ measure: PObj, _ userUnit: Double) -> MeasureScale? {
        if let st = measure.name("Subtype"), st != "RL" { return nil }
        guard let x = measure.array("X")?[0], x.isDict else { return nil }
        let c = x.number("C") ?? .nan
        if !(c > 0) || !c.isFinite { return nil }
        let u = x.text("U") ?? ""
        let unit = u.isEmpty ? "units" : u.trimmingCharacters(in: .whitespaces)
        let d = x.number("D") ?? 100
        let decimals = d >= 1 ? min(max(Int(log10(d).rounded()), 0), 6) : 2
        var perPoint = c / userUnit
        let r = measure.text("R") ?? ""
        let ratio = r.isEmpty ? "1 pt = \(MeasureScale.trimmed(perPoint, 6)) \(unit)" : r.trimmingCharacters(in: .whitespaces)
        // /C is written with a few digits: when the ratio says the same, take its exact value.
        if let exact = MeasureScale.parse(ratio), exact.unit == unit, abs(exact.perPoint - perPoint) <= perPoint * 1e-4 { perPoint = exact.perPoint }
        return MeasureScale(perPoint, unit, ratio, decimals: decimals, userUnit: userUnit)
    }

    // ───────────── the label in a measurement's appearance ─────────────

    /// The value label of a measurement (`points` page space): its drawing operators (Helvetica under /Helv, upright as
    /// the page is shown) and the corners it covers (PDF space), or nil when the annotation isn't one.
    static func label(_ page: PObj, _ annot: PObj, _ subtype: String, _ points: [PointD], _ style: AnnotStyle)
        -> (ops: [UInt8], corners: [(x: Double, y: Double)], text: String, kind: MeasureKind)? {
        guard let m = annot.dict("Measure"), let scale = scaleOf(m, PageMarks.userUnit(page)), let kind = kindOf(subtype) else { return nil }
        let text = scale.format(kind, points)
        let size = 9.0
        let width = StdFont.helvetica.measure(text) * size
        let center: PointD
        switch kind {
        case .distance:
            let a = points[0], b = points[points.count - 1]
            let len = max(1e-6, MeasureGeometry.distance(a, b))
            let dx = (b.x - a.x) / len, dy = (b.y - a.y) / len
            var nx = dy, ny = -dx // a normal; take the one pointing up the page as shown
            if ny > 0 || abs(ny) < 1e-9 && nx < 0 { (nx, ny) = (-nx, -ny) }
            let reach = size * 0.8 + style.width + abs(nx) * width / 2
            center = PointD((a.x + b.x) / 2 + nx * reach, (a.y + b.y) / 2 + ny * reach)
        case .perimeter:
            let last = points[points.count - 1]
            center = PointD(last.x + width / 2 + 6, last.y - size)
        case .area:
            center = MeasureGeometry.centroid(points)
        }
        let left = center.x - width / 2
        let baseline = center.y + size * 0.35
        let corners: [(x: Double, y: Double)] = [
            PageBoxes.toPdf(page, left - 2, center.y - size * 0.75), PageBoxes.toPdf(page, left + width + 2, center.y - size * 0.75),
            PageBoxes.toPdf(page, left - 2, center.y + size * 0.6), PageBoxes.toPdf(page, left + width + 2, center.y + size * 0.6),
        ]
        let (bx, by) = PageBoxes.toPdf(page, left, baseline)
        let rot = Double(PageBoxes.rotate(page)) * Double.pi / 180
        let cos = (Foundation.cos(rot) * 1e6).rounded() / 1e6, sin = (Foundation.sin(rot) * 1e6).rounded() / 1e6
        let c = style.color ?? AnnotStyle.black
        let f = PdfNum.f
        let (tl, tr, bl, br) = (corners[0], corners[1], corners[2], corners[3])
        // A white backing, so the value reads over drawings and pictures.
        var ops = "q 1 1 1 rg \(f(tl.x)) \(f(tl.y)) m \(f(tr.x)) \(f(tr.y)) l \(f(br.x)) \(f(br.y)) l \(f(bl.x)) \(f(bl.y)) l h f Q\n"
        ops += "BT \(f(c.r)) \(f(c.g)) \(f(c.b)) rg /Helv \(f(size)) Tf "
        ops += "\(f(cos)) \(f(sin)) \(f(-sin)) \(f(cos)) \(f(bx)) \(f(by)) Tm ("
        // The text as WinAnsi bytes (a unit read from another app's file may reach beyond ASCII).
        return (Array(ops.utf8) + WinAnsi.literal(text) + Array(") Tj ET\n".utf8), corners, text, kind)
    }

    static func labelResources(_ doc: MuDoc) -> PObj {
        doc.dict([("Font", doc.dict([("Helv", FontResources.standard(doc, "Helvetica"))]))])
    }
}
