import Foundation

/// Drawing and markup annotations (the Windows app's `Annotations.Drawing`): ink (pen and highlighter), rectangles,
/// ellipses, lines and arrows, polygons and polylines, and FreeText boxes (typewriter, text box, callout). Each gets its
/// own appearance stream (/AP /N), built from the annotation's own entries, so every viewer draws it the same; editing the
/// geometry or the style rewrites the entries and rebuilds the appearance, keeping the annotation's id.
extension Annotations {
    static let maxPoints = 200_000

    // ---------------- Add ----------------

    /// Adds freehand ink: one or more strokes (page space), drawn smoothed (Catmull-Rom curves through the points).
    public static func addInk(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ strokes: [[PointD]], _ style: AnnotStyle,
                              author: String, id: String? = nil) throws -> [UInt8] {
        try addDrawing(data, password, pageIndex, "Ink", AnnotGeometry(paths: strokes), style, author, "", id)
    }

    /// Adds a rectangle (Square) or an ellipse (Circle) filling `box` (page space; the stroke lies inside it).
    public static func addShape(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ kind: ShapeKind, _ box: RectD, _ style: AnnotStyle,
                                author: String, id: String? = nil) throws -> [UInt8] {
        try addDrawing(data, password, pageIndex, kind == .ellipse ? "Circle" : "Square", AnnotGeometry(box: box), style, author, "", id)
    }

    /// Adds a line (an arrow with `endEnding` = .openArrow, see `AnnotStyle.arrow`).
    public static func addLine(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ start: PointD, _ end: PointD, _ style: AnnotStyle,
                               author: String, id: String? = nil) throws -> [UInt8] {
        try addDrawing(data, password, pageIndex, "Line", AnnotGeometry(paths: [[start, end]]), style, author, "", id)
    }

    /// Adds a closed polygon or an open polyline through `vertices` (page space).
    public static func addPolygon(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ vertices: [PointD], closed: Bool,
                                  _ style: AnnotStyle, author: String, id: String? = nil) throws -> [UInt8] {
        try addDrawing(data, password, pageIndex, closed ? "Polygon" : "PolyLine", AnnotGeometry(paths: [vertices]), style, author, "", id)
    }

    /// Adds a FreeText box at `box` (page space): the text wraps to the box and reads upright on rotated pages; any script
    /// works (embedded fonts when Helvetica can't encode it). With `callout` (tip [, knee]) it is a callout whose leader
    /// line runs from the tip to the box.
    public static func addFreeText(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ box: RectD, _ text: String, _ style: AnnotStyle,
                                   author: String, callout: [PointD]? = nil, id: String? = nil) throws -> [UInt8] {
        try addDrawing(data, password, pageIndex, "FreeText", AnnotGeometry(box: box, callout: callout ?? []), style, author, text, id)
    }

    /// The height a FreeText box of `width` needs to show `text` without clipping.
    public static func freeTextHeight(_ text: String, width: Double, _ style: AnnotStyle) -> Double {
        let s = normalize(style)
        let pad = textPad(s)
        let painter = TextPainter(.helvetica, [text])
        let lines = painter.wrap(text, max(1, width - 2 * pad), s.fontSize)
        let spacing: Double = Double(lines.count - 1) * s.fontSize * lineSpacing
        return 2 * pad + spacing + (painter.ascent - painter.descent) * s.fontSize
    }

    // ---------------- Edit ----------------

    /// Moves or reshapes a drawing annotation (page space) and rebuilds its appearance. The id stays the same.
    public static func updateGeometry(_ data: [UInt8], _ password: String?, _ id: String, _ geometry: AnnotGeometry) throws -> [UInt8] {
        try redraw(data, password, id) { _, s in (geometry, s) }
    }

    /// Moves and resizes a drawing annotation so that its `AnnotGeometry.bounds` become `bounds`.
    public static func setBounds(_ data: [UInt8], _ password: String?, _ id: String, _ bounds: RectD) throws -> [UInt8] {
        try redraw(data, password, id) { g, s in (g.mapTo(bounds), s) }
    }

    /// Restyles a drawing annotation (color, width, fill, dash, opacity, endings, font size...) and rebuilds its appearance.
    public static func updateStyle(_ data: [UInt8], _ password: String?, _ id: String, _ style: AnnotStyle) throws -> [UInt8] {
        try redraw(data, password, id) { g, _ in (g, style) }
    }

    private static func redraw(_ data: [UInt8], _ password: String?, _ id: String,
                               _ change: (AnnotGeometry, AnnotStyle) -> (AnnotGeometry, AnnotStyle)) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            guard let found = try find(doc, id) else { throw PdfEditError("That comment no longer exists.") }
            let page = doc.page(found.page)
            let subtype = found.annot.name("Subtype") ?? ""
            guard isDrawing(found.annot, subtype), let current = describe(page, found.annot, subtype) else {
                throw PdfEditError("This comment can't be reshaped or restyled.")
            }
            let (g, s) = change(current.geometry, current.style)
            try validate(subtype, g, s)
            apply(doc, page, found.annot, subtype, g, s)
        }
    }

    private static func addDrawing(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ subtype: String, _ g: AnnotGeometry,
                                   _ s: AnnotStyle, _ author: String, _ contents: String, _ id: String?) throws -> [UInt8] {
        try validate(subtype, g, s)
        return try PageEditor.edit(data, password) { doc in
            try checkPage(doc, pageIndex)
            let page = doc.page(pageIndex)
            let annot = newAnnot(doc, page, subtype, 0, 0, 0, 0, id, contents, author, s.color ?? AnnotStyle.black)
            apply(doc, page, annot, subtype, g, s)
        }
    }

    /// Adds a measurement (a Line, PolyLine or Polygon carrying `scale` as its /Measure), labeled with its value.
    static func addMeasurement(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ subtype: String, _ points: [PointD],
                               _ s: AnnotStyle, _ author: String, _ id: String?, _ scale: MeasureScale) throws -> [UInt8] {
        let g = AnnotGeometry(paths: [points])
        try validate(subtype, g, s)
        return try PageEditor.edit(data, password) { doc in
            try checkPage(doc, pageIndex)
            let page = doc.page(pageIndex)
            let annot = newAnnot(doc, page, subtype, 0, 0, 0, 0, id, "", author, s.color ?? AnnotStyle.black)
            var onPage = scale
            onPage.userUnit = PageMarks.userUnit(page)
            annot.set("Measure", Measurements.measureDict(doc, onPage))
            apply(doc, page, annot, subtype, g, s)
        }
    }

    /// A drawing annotation Inkvolt PDF can describe and redraw (Fill & Sign stamps are managed by `TextStamps`).
    static func isDrawing(_ a: PObj, _ subtype: String) -> Bool {
        ["Ink", "Square", "Circle", "Line", "Polygon", "PolyLine"].contains(subtype)
            || subtype == "FreeText" && !TextStamps.isOwnId(a.text("NM"))
    }

    private static func validate(_ subtype: String, _ g: AnnotGeometry, _ s: AnnotStyle) throws {
        let points = g.paths.joined() + g.callout
        if points.count > maxPoints { throw PdfEditError("Too many points.") }
        let box = g.box
        if points.contains(where: { !$0.x.isFinite || !$0.y.isFinite })
            || !box.x.isFinite || !box.y.isFinite || !box.width.isFinite || !box.height.isFinite {
            throw PdfEditError("The position isn't a number.")
        }
        if !s.width.isFinite || !s.opacity.isFinite || !s.fontSize.isFinite || (s.dash ?? []).contains(where: { !$0.isFinite }) {
            throw PdfEditError("The style isn't valid.")
        }
        switch subtype {
        case "Ink":
            if !g.paths.contains(where: { !$0.isEmpty }) { throw PdfEditError("Nothing was drawn.") }
        case "Line":
            if g.paths.count != 1 || g.paths[0].count != 2 { throw PdfEditError("A line needs a start and an end.") }
        case "Polygon", "PolyLine":
            if g.paths.count != 1 || g.paths[0].count < (subtype == "Polygon" ? 3 : 2) { throw PdfEditError("Not enough vertices.") }
        case "Square", "Circle", "FreeText":
            if g.box.isEmpty { throw PdfEditError("The box is empty.") }
            if g.callout.count > 2 { throw PdfEditError("A callout has a tip and at most one knee.") }
        default:
            break
        }
        let noLine = s.color == nil || s.width <= 0
        if ["Ink", "Line", "PolyLine"].contains(subtype) && noLine { throw PdfEditError("A line needs a color and a width.") }
        if ["Square", "Circle", "Polygon"].contains(subtype) && noLine && s.fill == nil { throw PdfEditError("A shape needs a border or a fill.") }
    }

    private static func normalize(_ s: AnnotStyle) -> AnnotStyle {
        var n = s
        n.width = min(max(s.width, 0), 200)
        n.opacity = min(max(s.opacity, 0), 1)
        n.fontSize = min(max(s.fontSize, 1), 500)
        if let d = s.dash, !d.isEmpty, d.allSatisfy({ $0 >= 0 }), d.contains(where: { $0 > 0 }) {
            n.dash = d.prefix(8).map { min($0, 1000) }
        } else {
            n.dash = nil
        }
        return n
    }

    // ---------------- Write ----------------

    static let lineSpacing = 1.2

    private static func textPad(_ s: AnnotStyle) -> Double { (s.color == nil ? 0 : s.width) + 2 }

    private static func endingSize(_ w: Double) -> Double { max(6, w * 4 + 2) }

    private static func rgb(_ c: AnnotColor) -> String { "\(PdfNum.f(c.r)) \(PdfNum.f(c.g)) \(PdfNum.f(c.b))" }

    typealias Pt = (x: Double, y: Double)

    private static func p(_ q: Pt) -> String { "\(PdfNum.f(q.x)) \(PdfNum.f(q.y))" }

    static func endingName(_ e: LineEnding) -> String {
        switch e {
        case .none: "None"
        case .openArrow: "OpenArrow"
        case .closedArrow: "ClosedArrow"
        case .circle: "Circle"
        case .square: "Square"
        case .diamond: "Diamond"
        case .butt: "Butt"
        case .rOpenArrow: "ROpenArrow"
        case .rClosedArrow: "RClosedArrow"
        case .slash: "Slash"
        }
    }

    static func ending(named name: String?) -> LineEnding { LineEnding.allCases.first { endingName($0) == name } ?? .none }

    /// Writes the annotation's geometry and style entries and its appearance stream.
    static func apply(_ doc: MuDoc, _ page: PObj, _ annot: PObj, _ subtype: String, _ g: AnnotGeometry, _ style: AnnotStyle) {
        let s = normalize(style)
        let stroke = s.color != nil && s.width > 0
        let w = stroke ? s.width : 0
        let fill = s.fill != nil && !["Ink", "Line", "PolyLine"].contains(subtype)

        if let c = s.color { annot.set("C", doc.realArray([c.r, c.g, c.b])) } else { annot.remove("C") }
        if let f = s.fill, subtype != "Ink" { annot.set("IC", doc.realArray([f.r, f.g, f.b])) } else { annot.remove("IC") }
        let bs = doc.dict([("Type", doc.name("Border")), ("W", doc.real((w * 1000).rounded() / 1000)),
                           ("S", doc.name(s.dash == nil ? "S" : "D"))])
        if let dash = s.dash { bs.set("D", doc.realArray(dash)) }
        annot.set("BS", bs)
        annot.remove("Border")
        annot.remove("BE")
        if s.opacity < 1 { annot.set("CA", doc.real((s.opacity * 1000).rounded() / 1000)) } else { annot.remove("CA") }
        annot.set("M", doc.now())
        for key in ["InkList", "L", "LE", "Vertices", "CL", "RD", "IT", "Rotate"] { annot.remove(key) }

        // The common appearance prologue: colors, width, dash.
        var ops = ""
        if let sc = s.color { ops += "\(rgb(sc)) RG " }
        if let fc = s.fill { ops += "\(rgb(fc)) rg " }
        ops += "\(PdfNum.f(w)) w "
        if let d = s.dash { ops += "[\(d.map(PdfNum.f).joined(separator: " "))] 0 d " }
        let paint = fill ? (stroke ? "B" : "f") : (stroke ? "S" : "n")

        if subtype == "FreeText" {
            applyFreeText(doc, page, annot, g, s, ops)
            return
        }

        var rectPts: [Pt] = []
        var labelCorners: [Pt] = []
        var labelOps: [UInt8] = []
        var resources: PObj?
        let pad: Double
        switch subtype {
        case "Ink":
            let strokes: [[Pt]] = g.paths.filter { !$0.isEmpty }.map { $0.map { PageBoxes.toPdf(page, $0.x, $0.y) } }
            annot.set("InkList", doc.array(strokes.map { st in doc.realArray(st.flatMap { [$0.x, $0.y] }) }))
            ops += "1 J 1 j\n"
            for st in strokes { smooth(&ops, st) }
            if !strokes.isEmpty { ops += "S\n" }
            rectPts = strokes.flatMap { $0 }
            pad = w / 2 + 1
        case "Line", "Polygon", "PolyLine":
            let pts: [Pt] = g.paths[0].map { PageBoxes.toPdf(page, $0.x, $0.y) }
            annot.set(subtype == "Line" ? "L" : "Vertices", doc.realArray(pts.flatMap { [$0.x, $0.y] }))
            let ends = subtype != "Polygon" && (s.startEnding != .none || s.endEnding != .none)
            if ends { annot.set("LE", doc.array([doc.name(endingName(s.startEnding)), doc.name(endingName(s.endEnding))])) }
            ops += subtype == "Polygon" ? "0 J 1 j\n" : "0 J 0 j\n"
            ops += "\(p(pts[0])) m"
            for q in pts.dropFirst() { ops += " \(p(q)) l" }
            ops += subtype == "Polygon" ? " h \(paint)\n" : " S\n"
            if ends {
                let endFill = s.fill != nil
                ending(&ops, s.startEnding, pts[0], dir(pts[1], pts[0]), w, endFill)
                ending(&ops, s.endEnding, pts[pts.count - 1], dir(pts[pts.count - 2], pts[pts.count - 1]), w, endFill)
            }
            // A measurement: its value as the comment's text and drawn as a label, recomputed whenever it is redrawn.
            if let label = Measurements.label(page, annot, subtype, g.paths[0], s) {
                labelOps = label.ops
                labelCorners = label.corners
                annot.set("Contents", doc.text(label.text))
                let it = label.kind == .distance ? "LineDimension" : label.kind == .perimeter ? "PolyLineDimension" : "PolygonDimension"
                annot.set("IT", doc.name(it))
                if subtype == "Line" { annot.set("Cap", doc.bool(true)) }
                resources = Measurements.labelResources(doc)
            }
            rectPts = pts
            pad = w / 2 + (ends ? endingSize(w) + w : 0) + 1
        default: // Square, Circle
            let r = PageBoxes.fromPageSpace(page, g.box)
            annot.set("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2]))
            let half = min(w / 2, min(r.x2 - r.x1, r.y2 - r.y1) / 2)
            let l = r.x1 + half, b = r.y1 + half, rt = r.x2 - half, t = r.y2 - half
            if subtype == "Square" {
                ops += "\(PdfNum.f(l)) \(PdfNum.f(b)) \(PdfNum.f(rt - l)) \(PdfNum.f(t - b)) re \(paint)\n"
            } else {
                ellipse(&ops, (l + rt) / 2, (b + t) / 2, (rt - l) / 2, (t - b) / 2)
                ops += "\(paint)\n"
            }
            setAppearance(doc, annot, appearance(doc, Array(ops.utf8), nil, r.x1, r.y1, r.x2, r.y2, nil, s))
            return
        }

        var rx1 = rectPts.map(\.x).min()! - pad, ry1 = rectPts.map(\.y).min()! - pad
        var rx2 = rectPts.map(\.x).max()! + pad, ry2 = rectPts.map(\.y).max()! + pad
        for (lx, ly) in labelCorners {
            (rx1, ry1, rx2, ry2) = (min(rx1, lx - 1), min(ry1, ly - 1), max(rx2, lx + 1), max(ry2, ly + 1))
        }
        annot.set("Rect", doc.realArray([rx1, ry1, rx2, ry2]))
        setAppearance(doc, annot, appearance(doc, Array(ops.utf8) + labelOps, resources, rx1, ry1, rx2, ry2, nil, s))
    }

    private static func applyFreeText(_ doc: MuDoc, _ page: PObj, _ annot: PObj, _ g: AnnotGeometry, _ s: AnnotStyle, _ prologue: String) {
        var ops = prologue
        let text = annot.text("Contents") ?? ""
        let box = g.box
        let border = s.color != nil && s.width > 0
        let w = border ? s.width : 0

        // The callout: tip [, knee], then where it meets the box (the middle of the nearest side).
        var callout = g.callout
        if let last = callout.last {
            let sides = [PointD(box.x, box.centerY), PointD(box.right, box.centerY), PointD(box.centerX, box.y), PointD(box.centerX, box.bottom)]
            func d2(_ q: PointD) -> Double { (q.x - last.x) * (q.x - last.x) + (q.y - last.y) * (q.y - last.y) }
            callout.append(sides.min { d2($0) < d2($1) }!)
        }
        let lw = max(w, 1) // a callout line is drawn even without a border
        let extent = endingSize(lw) + lw
        var outer = box
        for q in callout.dropLast() {
            outer = .fromEdges(min(outer.x, q.x - extent), min(outer.y, q.y - extent), max(outer.right, q.x + extent), max(outer.bottom, q.y + extent))
        }

        let r = PageBoxes.fromPageSpace(page, outer)
        annot.set("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2]))
        if !callout.isEmpty {
            let b = PageBoxes.fromPageSpace(page, box)
            annot.set("RD", doc.realArray([b.x1 - r.x1, b.y1 - r.y1, r.x2 - b.x2, r.y2 - b.y2]))
            let cl: [Pt] = callout.map { PageBoxes.toPdf(page, $0.x, $0.y) }
            annot.set("CL", doc.realArray(cl.flatMap { [$0.x, $0.y] }))
            annot.set("IT", doc.name("FreeTextCallout"))
            annot.set("LE", doc.name(endingName(s.endEnding)))
        } else if !border && s.fill == nil {
            annot.set("IT", doc.name("FreeTextTypewriter"))
        }
        let rot = PageBoxes.rotate(page)
        if rot != 0 { annot.set("Rotate", doc.int(rot)) }

        let size = s.fontSize
        let tc = s.textColor
        annot.set("DA", doc.text("\(rgb(tc)) rg /Helv \(PdfNum.f(size)) Tf"))
        let align = s.align == .center ? "center" : s.align == .right ? "right" : "left"
        func hex(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        annot.set("DS", doc.text("font: Helvetica,sans-serif \(PdfNum.f(size))pt; text-align:\(align); color:#\(hex(tc.r))\(hex(tc.g))\(hex(tc.b))"))
        annot.set("Q", doc.int(s.align == .center ? 1 : s.align == .right ? 2 : 0))
        let paras = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var rc = "<?xml version=\"1.0\"?><body xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:xfa=\"http://www.xfa.org/schema/xfa-data/1.0/\" xfa:APIVersion=\"Acrobat:11.0.0\" xfa:spec=\"2.0.2\">"
        for para in paras { rc += "<p dir=\"ltr\">\(xmlEscape(String(para)))</p>" }
        rc += "</body>"
        annot.set("RC", doc.text(rc))

        // The appearance in the displayed page's orientation (page-space units, y up from the bottom of the rect),
        // counter-rotated by /Matrix on rotated pages so the text reads upright.
        let width = outer.width, height = outer.height
        func fr(_ q: PointD) -> Pt { (q.x - outer.x, outer.bottom - q.y) }
        let fx = box.x - outer.x, fy = outer.bottom - box.bottom, fw = box.width, fh = box.height
        if let fill = s.fill { ops += "\n\(rgb(fill)) rg \(PdfNum.f(fx)) \(PdfNum.f(fy)) \(PdfNum.f(fw)) \(PdfNum.f(fh)) re f\n" }
        if border {
            let half = min(w / 2, min(fw, fh) / 2)
            ops += "\(PdfNum.f(fx + half)) \(PdfNum.f(fy + half)) \(PdfNum.f(fw - 2 * half)) \(PdfNum.f(fh - 2 * half)) re S\n"
        }
        if callout.count > 1 {
            let color = s.color ?? tc
            let pts = callout.map(fr)
            ops += "q [] 0 d \(rgb(color)) RG \(rgb(s.fill ?? color)) rg \(PdfNum.f(lw)) w 0 J 0 j \(p(pts[0])) m"
            for q in pts.dropFirst() { ops += " \(p(q)) l" }
            ops += " S\n"
            ending(&ops, s.endEnding, pts[0], dir(pts[1], pts[0]), lw, true)
            ops += "Q\n"
        }

        let pad = textPad(s)
        let painter = TextPainter(.helvetica, [text])
        let avail = max(1, fw - 2 * pad)
        var y = fy + fh - pad - painter.ascent * size
        for line in painter.wrap(text, avail, size) {
            let lineWidth = painter.measure(line) * size
            let x: Double
            switch s.align {
            case .center: x = fx + (fw - lineWidth) / 2
            case .right: x = fx + fw - pad - lineWidth
            case .left: x = fx + pad
            }
            painter.draw(line, x, y, size)
            y -= size * lineSpacing
        }
        let (textOps, resources) = painter.build(doc, width, height, "/Helv", PdfColorValue(c: [tc.r, tc.g, tc.b]))
        ops += "q \(PdfNum.f(fx + w)) \(PdfNum.f(fy + w)) \(PdfNum.f(max(0, fw - 2 * w))) \(PdfNum.f(max(0, fh - 2 * w))) re W n\n"
        let content = Array(ops.utf8) + textOps + Array("Q\n".utf8)
        setAppearance(doc, annot, appearance(doc, content, resources, 0, 0, width, height, doc.counterRotation(page), s))
    }

    static func xmlEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "&": out += "&amp;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// The normal appearance. With an opacity or the highlighter's Multiply blend, the drawing is an isolated
    /// transparency group painted through an ExtGState (/CA /ca /BM), so overlapping strokes don't darken each other.
    private static func appearance(_ doc: MuDoc, _ content: [UInt8], _ resources: PObj?, _ x1: Double, _ y1: Double, _ x2: Double,
                                   _ y2: Double, _ matrix: PObj?, _ s: AnnotStyle) -> PObj {
        if s.opacity >= 1 && !s.highlighter { return doc.formXObject(content, x1, y1, x2, y2, resources, matrix: matrix) }
        let inner = doc.formXObject(content, x1, y1, x2, y2, resources)
        inner.set("Group", doc.dict([("Type", doc.name("Group")), ("S", doc.name("Transparency")), ("I", doc.bool(true))]))
        let opacity = doc.real((s.opacity * 1000).rounded() / 1000)
        let gs = doc.dict([("Type", doc.name("ExtGState")), ("CA", opacity), ("ca", doc.real((s.opacity * 1000).rounded() / 1000))])
        if s.highlighter { gs.set("BM", doc.name("Multiply")) }
        let outer = doc.dict([("ExtGState", doc.dict([("GS0", gs)])), ("XObject", doc.dict([("Fm0", inner)]))])
        return doc.formXObject(Array("/GS0 gs /Fm0 Do\n".utf8), x1, y1, x2, y2, outer, matrix: matrix)
    }

    private static func dir(_ from: Pt, _ to: Pt) -> Pt {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = (dx * dx + dy * dy).squareRoot()
        return len < 1e-9 ? (1, 0) : (dx / len, dy / len)
    }

    /// A stroke through the points: Catmull-Rom segments as cubic Béziers (a dot for a single point).
    private static func smooth(_ ops: inout String, _ raw: [Pt]) {
        var pts: [Pt] = []
        for q in raw where pts.isEmpty || abs(pts[pts.count - 1].x - q.x) > 1e-6 || abs(pts[pts.count - 1].y - q.y) > 1e-6 { pts.append(q) }
        ops += "\(p(pts[0])) m\n"
        if pts.count == 1 {
            ops += "\(p(pts[0])) l\n"
            return
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1: Pt = (p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6)
            let c2: Pt = (p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6)
            ops += "\(p(c1)) \(p(c2)) \(p(p2)) c\n"
        }
    }

    private static func ellipse(_ ops: inout String, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) {
        let k = 0.5522847498
        let kx = k * rx, ky = k * ry
        ops += "\(p((cx + rx, cy))) m "
        ops += "\(p((cx + rx, cy + ky))) \(p((cx + kx, cy + ry))) \(p((cx, cy + ry))) c "
        ops += "\(p((cx - kx, cy + ry))) \(p((cx - rx, cy + ky))) \(p((cx - rx, cy))) c "
        ops += "\(p((cx - rx, cy - ky))) \(p((cx - kx, cy - ry))) \(p((cx, cy - ry))) c "
        ops += "\(p((cx + kx, cy - ry))) \(p((cx + rx, cy - ky))) \(p((cx + rx, cy))) c h "
    }

    /// Draws a line ending at `at`; `dir` points out of the line through that end.
    private static func ending(_ ops: inout String, _ ending: LineEnding, _ at: Pt, _ dir: Pt, _ w: Double, _ fill: Bool) {
        if ending == .none { return }
        let s = endingSize(w)
        let (dx, dy) = dir
        let (nx, ny) = (-dy, dx)
        func pos(_ along: Double, _ across: Double) -> Pt { (at.x + dx * along + nx * across, at.y + dy * along + ny * across) }
        let closedPaint = fill ? "b" : "s"
        switch ending {
        case .openArrow, .closedArrow, .rOpenArrow, .rClosedArrow:
            let back = ending == .rOpenArrow || ending == .rClosedArrow ? s : -s
            let closed = ending == .closedArrow || ending == .rClosedArrow
            ops += "\(p(pos(back, s / 2))) m \(p(at)) l \(p(pos(back, -s / 2))) l \(closed ? closedPaint : "S")\n"
        case .circle:
            ellipse(&ops, at.x, at.y, s / 2, s / 2)
            ops += "\(closedPaint)\n"
        case .square:
            ops += "\(p(pos(-s / 2, -s / 2))) m \(p(pos(s / 2, -s / 2))) l \(p(pos(s / 2, s / 2))) l \(p(pos(-s / 2, s / 2))) l \(closedPaint)\n"
        case .diamond:
            ops += "\(p(pos(-s / 2, 0))) m \(p(pos(0, -s / 2))) l \(p(pos(s / 2, 0))) l \(p(pos(0, s / 2))) l \(closedPaint)\n"
        case .butt:
            ops += "\(p(pos(0, s / 2))) m \(p(pos(0, -s / 2))) l S\n"
        case .slash:
            // 30° off the perpendicular.
            let c = cos(Double.pi / 6) * s / 2, t = sin(Double.pi / 6) * s / 2
            ops += "\(p(pos(t, c))) m \(p(pos(-t, -c))) l S\n"
        case .none:
            break
        }
    }

    // ---------------- Read ----------------

    /// The geometry (page space) and style of a drawing annotation, from its entries; nil when it has none usable.
    static func describe(_ page: PObj, _ a: PObj, _ subtype: String) -> (geometry: AnnotGeometry, style: AnnotStyle)? {
        func points(_ arr: PObj?) -> [PointD] {
            guard let arr, arr.isArray else { return [] }
            let n = min(arr.count, 2 * maxPoints) / 2
            return (0..<n).map { i in
                let q = PageBoxes.toPage(page, arr.num(2 * i), arr.num(2 * i + 1))
                return PointD(q.x, q.y)
            }
        }
        func inner() -> RectD {
            guard let r = a.array("Rect"), r.count >= 4 else { return .zero }
            var x1 = min(r.num(0), r.num(2)), y1 = min(r.num(1), r.num(3))
            var x2 = max(r.num(0), r.num(2)), y2 = max(r.num(1), r.num(3))
            if let rd = a.array("RD"), rd.count == 4 {
                let l = rd.num(0), b = rd.num(1), rr = rd.num(2), t = rd.num(3)
                if l >= 0 && b >= 0 && rr >= 0 && t >= 0 && l + rr < x2 - x1 && b + t < y2 - y1 {
                    (x1, y1, x2, y2) = (x1 + l, y1 + b, x2 - rr, y2 - t)
                }
            }
            return PageBoxes.toPageSpace(page, x1, y1, x2, y2)
        }

        var g: AnnotGeometry
        switch subtype {
        case "Ink":
            let strokes = (a.array("InkList")?.elements ?? []).filter(\.isArray).map(points).filter { !$0.isEmpty }
            if strokes.isEmpty { return nil }
            g = AnnotGeometry(paths: strokes)
        case "Line", "Polygon", "PolyLine":
            let pts = points(a.array(subtype == "Line" ? "L" : "Vertices"))
            if pts.count < 2 { return nil }
            g = AnnotGeometry(paths: [subtype == "Line" ? Array(pts.prefix(2)) : pts])
        case "Square", "Circle":
            g = AnnotGeometry(box: inner())
            if g.box.isEmpty { return nil }
        case "FreeText":
            let cl = points(a.array("CL"))
            g = AnnotGeometry(box: inner(), callout: cl.count >= 2 ? Array(cl.prefix(cl.count >= 3 ? 2 : 1)) : [])
            if g.box.isEmpty { return nil }
        default:
            return nil
        }
        if g.box.isEmpty { g.box = g.bounds }

        let bs = a.dict("BS")
        let width: Double
        if let bs, bs.has("W") {
            width = bs.number("W") ?? 1
        } else if let border = a.array("Border"), border.count >= 3 {
            width = border.num(2)
        } else {
            width = 1
        }
        var dash: [Double]?
        if bs?.name("S") == "D" {
            if let da = bs?.array("D"), da.count > 0 { dash = (0..<min(da.count, 8)).map { da.num($0) } } else { dash = [3] }
        }
        let le = a.array("LE")
        var color = colorOf(a.array("C"))
        if ["Ink", "Line", "PolyLine"].contains(subtype) && color == nil { color = AnnotStyle.black }
        var style = AnnotStyle(color: color, fill: subtype == "Ink" ? nil : colorOf(a.array("IC")), width: max(0, width))
        style.opacity = min(max(a.number("CA") ?? 1, 0), 1)
        style.dash = dash
        style.highlighter = usesMultiply(a.dict("AP")?.dict("N"), 0)
        style.startEnding = le.map { $0.count >= 1 ? ending(named: $0[0]?.name) : .none } ?? .none
        if subtype == "FreeText" {
            style.endEnding = ending(named: a.name("LE"))
        } else {
            style.endEnding = le.map { $0.count >= 2 ? ending(named: $0[1]?.name) : .none } ?? .none
        }
        if subtype == "FreeText" {
            let da = DefaultAppearance.parse(a.text("DA"))
            let c = da.color.c
            style.startEnding = .none
            style.fontSize = da.size > 0 ? da.size : 12
            switch c.count {
            case 1: style.textColor = AnnotColor(c[0], c[0], c[0])
            case 3: style.textColor = AnnotColor(c[0], c[1], c[2])
            default: style.textColor = AnnotColor((1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3]))
            }
            let q = a.int("Q") ?? 0
            style.align = q == 1 ? .center : q == 2 ? .right : .left
            style.highlighter = false
        }
        return (g, style)
    }

    /// The appearance paints through an ExtGState with the Multiply blend mode (a highlighter).
    private static func usesMultiply(_ form: PObj?, _ depth: Int) -> Bool {
        guard let form, form.isDict, depth <= 3 else { return false }
        let res = form.dict("Resources")
        for gs in res?.dict("ExtGState")?.values ?? [] where gs.isDict {
            guard let bm = gs["BM"] else { continue }
            if bm.name == "Multiply" || (bm.isArray && bm.count > 0 && bm[0]?.name == "Multiply") { return true }
        }
        for x in (res?.dict("XObject")?.values ?? []).prefix(8) where x.isDict && x.name("Subtype") == "Form" {
            if usesMultiply(x, depth + 1) { return true }
        }
        return false
    }
}
