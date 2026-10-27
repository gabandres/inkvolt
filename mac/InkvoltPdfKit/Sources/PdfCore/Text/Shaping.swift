import CoreGraphics
import CoreText
import Foundation

/// A glyph placed on a line: its origin (offsets applied) in ems from the line's start, the text it stands for, and
/// whether it belongs to a right-to-left run.
struct PlacedGlyph {
    var font: TrueTypeFont
    var glyph: Int
    var x: Double
    var y: Double
    var text: String
    var rtl = false
}

/// A shaped line: glyphs in the order they are written to the content stream (logical order), and its advance width in
/// ems.
struct ShapedLine {
    var text: String
    var glyphs: [PlacedGlyph]
    var width: Double
    /// The paragraph direction is right to left (its first strong character).
    var rtl: Bool
    /// Glyphs in logical order with both left-to-right and right-to-left runs (see `Type3FontWriter.emit`).
    var mixed = false
}

/// Lays a line of Unicode text out for PDF (the Windows app's `TextShaper`). Windows runs its own bidi, picks a font per
/// run and shapes each with HarfBuzz; on the Mac Core Text does all three in one `CTLine` (Arabic joining, Indic
/// reordering and conjuncts, marks, kerning, font fallback through the font's cascade list, the bidi algorithm with the
/// paragraph direction `Bidi` finds). The runs come back as Windows has them: glyphs with their positions and the text
/// each stands for, written in logical order, so the fonts' /ToUnicode makes copy and search return the typed string.
enum TextShaper {
    static func measure(_ text: String, _ primary: TrueTypeFont?) -> Double { shape(text, primary).width }

    /// - Parameter visualOrder: write the glyphs left to right (visual order) instead of in logical order.
    static func shape(_ text: String, _ primary: TrueTypeFont?, visualOrder: Bool = false) -> ShapedLine {
        if text.isEmpty { return ShapedLine(text: text, glyphs: [], width: 0, rtl: false) }
        let para = Bidi.levels(text).paragraph
        let units = Array(text.utf16)
        let line = makeLine(text, primary, rtl: para == 1)
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil)) / 1000

        var runs: [(start: Int, x: Double, rtl: Bool, glyphs: [PlacedGlyph])] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            if let shaped = shapeRun(run, units) { runs.append(shaped) }
        }
        if visualOrder {
            runs.sort { $0.x < $1.x }
            let glyphs = runs.flatMap { $0.rtl ? Array($0.glyphs.reversed()) : $0.glyphs }
            return ShapedLine(text: text, glyphs: glyphs, width: width, rtl: para == 1)
        }
        runs.sort { $0.start < $1.start }
        let mixed = runs.contains { $0.rtl } && runs.contains { !$0.rtl }
        return ShapedLine(text: text, glyphs: runs.flatMap(\.glyphs), width: width, rtl: para == 1, mixed: mixed)
    }

    private static func makeLine(_ text: String, _ primary: TrueTypeFont?, rtl: Bool) -> CTLine {
        let font = (primary ?? SystemFonts.get("arial.ttf"))?.font ?? CTFontCreateWithName("Helvetica" as CFString, 1000, nil)
        var direction: CTWritingDirection = rtl ? .rightToLeft : .leftToRight
        let style = withUnsafeBytes(of: &direction) { raw -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: raw.count, value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    }

    /// One Core Text run: its glyphs in logical order (a right-to-left run last glyph first), each with the text of its
    /// cluster (one character per glyph, the rest on the cluster's last glyph, as Windows hands HarfBuzz's clusters out).
    private static func shapeRun(_ run: CTRun, _ units: [UInt16]) -> (start: Int, x: Double, rtl: Bool, glyphs: [PlacedGlyph])? {
        let count = CTRunGetGlyphCount(run)
        if count == 0 { return nil }
        var ids = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        let all = CFRange(location: 0, length: 0)
        CTRunGetGlyphs(run, all, &ids)
        CTRunGetPositions(run, all, &positions)
        CTRunGetStringIndices(run, all, &indices)
        let range = CTRunGetStringRange(run)
        let rtl = CTRunGetStatus(run).contains(.rightToLeft)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let ctFont = attributes[kCTFontAttributeName as String] else { return nil }
        let font = SystemFonts.wrap(ctFont as! CTFont)

        // Glyphs as Core Text stores them (visual order), without the ones shaping deleted.
        var placed: [(glyph: Int, x: Double, y: Double, index: Int)] = []
        for k in 0..<count where ids[k] != 0xFFFF {
            placed.append((Int(ids[k]), Double(positions[k].x) / 1000, Double(positions[k].y) / 1000, indices[k]))
        }
        if placed.isEmpty { return nil }
        let minX = placed.map(\.x).min() ?? 0
        if rtl { placed.reverse() }

        // Clusters (HarfBuzz's): glyphs whose characters interleave, written in order, share one (a reordered matra
        // joins its consonant); each cluster is named by its first character.
        var groups: [(lo: Int, hi: Int, members: [Int])] = []
        for (k, p) in placed.enumerated() {
            var group = (lo: p.index, hi: p.index, members: [k])
            while let top = groups.last, top.hi >= group.lo {
                groups.removeLast()
                group = (min(top.lo, group.lo), max(top.hi, group.hi), top.members + group.members)
            }
            groups.append(group)
        }
        let runStart = range.location, runEnd = range.location + range.length
        let starts = groups.map(\.lo).sorted()
        var clusterOf = [Int](repeating: 0, count: placed.count)
        for g in groups { for m in g.members { clusterOf[m] = g.lo } }
        var texts: [Int: [String]] = [:]
        for (c, s) in starts.enumerated() {
            let from = c == 0 ? min(s, runStart) : s
            let end = c + 1 < starts.count ? starts[c + 1] : max(runEnd, s)
            let slice = String(decoding: units[max(0, from)..<min(units.count, max(from, end))], as: UTF16.self)
            texts[s] = slice.unicodeScalars.map { String(Character($0)) }
        }
        var counts: [Int: Int] = [:]
        for c in clusterOf { counts[c, default: 0] += 1 }
        var seen: [Int: Int] = [:]
        var glyphs: [PlacedGlyph] = []
        for (k, p) in placed.enumerated() {
            let c = clusterOf[k]
            let i = seen[c, default: 0]
            seen[c] = i + 1
            let parts = texts[c] ?? []
            let n = counts[c] ?? 1
            let t = i < n - 1 ? (i < parts.count ? parts[i] : "") : parts.dropFirst(i).joined()
            glyphs.append(PlacedGlyph(font: font, glyph: p.glyph, x: p.x, y: p.y, text: t, rtl: rtl))
        }
        return (runStart, minX, rtl, glyphs)
    }
}

/// Writes shaped text with embedded fonts (the Windows app's `CidFontWriter`). Windows embeds a HarfBuzz subset of each
/// TrueType file as a CIDFontType2 font; macOS's fallback fonts are often collections or CFF outlines, so here each font
/// becomes Type 3 fonts whose glyph procedures are Core Text's outlines (filled, in the text's color). Codes are handed
/// out per (glyph, text) pair, 255 to a Type 3 font, mapped to the text by /ToUnicode, so the same glyph can stand for
/// different text (a ligature, a reordered matra) and extraction still returns the logical string. Positions come from
/// the shaper and are written as TJ adjustments against the /Widths.
final class Type3FontWriter {
    private final class Used {
        let font: TrueTypeFont
        let name: String
        var byCode: [(glyph: Int, text: String)] = [(0, "")]
        init(_ font: TrueTypeFont, _ name: String) {
            self.font = font
            self.name = name
        }
    }

    private struct Key: Hashable {
        var font: ObjectIdentifier
        var glyph: Int
        var text: String
    }

    private let namePrefix: String
    private var fonts: [Used] = []
    private var codes: [Key: (Used, Int)] = [:]

    init(namePrefix: String = "/PdU") { self.namePrefix = namePrefix }

    var isEmpty: Bool { fonts.isEmpty }

    static let lrm = "\u{200E}", rlm = "\u{200F}"

    private static func width(_ font: TrueTypeFont, _ glyph: Int) -> Double { font.glyphAdvance(glyph).rounded() }

    /// A code's width: direction marks take no room.
    private static func width(_ u: Used, _ code: Int) -> Double {
        let e = u.byCode[code]
        return e.text == lrm || e.text == rlm ? 0 : width(u.font, e.glyph)
    }

    private func code(_ font: TrueTypeFont, _ glyph: Int, _ text: String) -> (Used, Int) {
        let key = Key(font: ObjectIdentifier(font), glyph: glyph, text: text)
        if let hit = codes[key] { return hit }
        let used: Used
        if let last = fonts.last(where: { $0.font === font }), last.byCode.count < 256 {
            used = last
        } else {
            used = Used(font, "\(namePrefix)\(fonts.count)")
            fonts.append(used)
        }
        let c = used.byCode.count
        used.byCode.append((glyph, text))
        codes[key] = (used, c)
        return (used, c)
    }

    private static func hex2(_ v: Int) -> String { String(format: "%02X", v) }

    private static func utf16Hex(_ s: String) -> String { s.utf16.map { String(format: "%04X", $0) }.joined() }

    /// Appends Tf / Ts / TJ operators drawing `line` from the current text-matrix origin (inside BT/ET).
    ///
    /// A mixed-direction line written in logical order jumps where its runs meet. MuPDF accepts a jump only where the
    /// text switches direction, and it takes the direction of a space or punctuation from the character before it, so
    /// each run begins with an invisible, zero-width direction mark (LRM / RLM, an empty glyph) inside an empty
    /// /ActualText: it sets the direction the run's leading spaces inherit, and extraction leaves it out.
    func emit(_ sb: inout String, _ line: ShapedLine, size: Double) {
        // A cluster drawn with more glyphs than it has characters leaves glyphs with no text of their own: the line's
        // /ActualText then gives extraction the exact string.
        let actual = line.glyphs.contains { $0.text.isEmpty }
        if actual { sb += "/Span <</ActualText <FEFF\(Self.utf16Hex(line.text))>>> BDC " }
        var cur: Used?
        var pen = 0.0, rise = 0.0
        var open = false
        func close(_ sb: inout String) {
            if open { sb += "] TJ " }
            open = false
        }
        var direction: Bool?
        for g in line.glyphs {
            if line.mixed && direction != g.rtl {
                close(&sb)
                let (u, mark) = code(g.font, g.font.glyphOf(32), g.rtl ? Self.rlm : Self.lrm)
                if u !== cur {
                    sb += "\(u.name) \(PdfNum.f(size)) Tf "
                    cur = u
                }
                sb += "/Span <</ActualText ()>> BDC <\(Self.hex2(mark))> Tj EMC "
                direction = g.rtl
            }
            let (u, c) = code(g.font, g.glyph, g.text)
            if u !== cur {
                close(&sb)
                sb += "\(u.name) \(PdfNum.f(size)) Tf "
                cur = u
            }
            let y = g.y * size
            if abs(y - rise) > 0.001 {
                close(&sb)
                sb += "\(PdfNum.f(y)) Ts "
                rise = y
            }
            if !open { sb += "[" }
            open = true
            let target = g.x * 1000
            let adjust = pen - target
            if abs(adjust) >= 0.001 { sb += PdfNum.f(adjust) + " " }
            sb += "<\(Self.hex2(c))>"
            pen = target + Self.width(g.font, g.glyph)
        }
        close(&sb)
        if rise != 0 { sb += "0 Ts " }
        if actual { sb += "EMC " }
    }

    /// Adds the font objects to `doc` and returns a /Font resource dictionary naming them.
    func buildFonts(_ doc: MuDoc) -> PObj {
        let dict = doc.dict()
        var procs: [Key: PObj] = [:]
        for u in fonts {
            let name = u.name.hasPrefix("/") ? String(u.name.dropFirst()) : u.name
            dict.set(name, buildFont(doc, u, &procs))
        }
        return dict
    }

    private func buildFont(_ doc: MuDoc, _ u: Used, _ procs: inout [Key: PObj]) -> PObj {
        let charProcs = doc.dict()
        let differences = doc.array([doc.int(1)])
        var widths: [PObj] = []
        var x0 = 0.0, y0 = 0.0, x1 = 0.0, y1 = 0.0
        for code in 1..<u.byCode.count {
            let (glyph, text) = u.byCode[code]
            let mark = text == Self.lrm || text == Self.rlm
            let key = Key(font: ObjectIdentifier(u.font), glyph: mark ? -1 : glyph, text: "")
            let w = Self.width(u, code)
            let proc: PObj
            if let hit = procs[key] {
                proc = hit
            } else {
                let (ops, box) = mark ? ("0 0 0 0 0 0 d1\n", CGRect.zero) : Self.glyphProcedure(u.font, glyph, w)
                proc = doc.addStream(Array(ops.utf8), deflate: ops.utf8.count > 64)
                procs[key] = proc
                x0 = min(x0, Double(box.minX))
                y0 = min(y0, Double(box.minY))
                x1 = max(x1, Double(box.maxX))
                y1 = max(y1, Double(box.maxY))
            }
            charProcs.set("g\(code)", proc)
            differences.append(doc.name("g\(code)"))
            widths.append(doc.real(w))
        }
        if x1 <= x0 || y1 <= y0 { (x0, y0, x1, y1) = (u.font.bbox[0], u.font.bbox[1], u.font.bbox[2], u.font.bbox[3]) }
        let font = doc.dict([
            ("Type", doc.name("Font")), ("Subtype", doc.name("Type3")),
            ("FontBBox", doc.reals(x0.rounded(.down), y0.rounded(.down), x1.rounded(.up), y1.rounded(.up))),
            ("FontMatrix", doc.reals(0.001, 0, 0, 0.001, 0, 0)), ("CharProcs", charProcs),
            ("Encoding", doc.dict([("Type", doc.name("Encoding")), ("Differences", differences)])),
            ("FirstChar", doc.int(1)), ("LastChar", doc.int(u.byCode.count - 1)), ("Widths", doc.array(widths)),
            ("Resources", doc.dict()),
            ("ToUnicode", doc.addStream(Self.toUnicode(u.byCode), deflate: true)),
        ])
        return doc.add(font)
    }

    /// The glyph's outline as a Type 3 glyph procedure (d1: drawn in the text's color), and its box.
    private static func glyphProcedure(_ font: TrueTypeFont, _ glyph: Int, _ width: Double) -> (String, CGRect) {
        let (path, box) = font.outline(glyph)
        let b = box.isNull || box.isInfinite ? CGRect.zero : box
        var ops = "\(PdfNum.f(width)) 0 \(PdfNum.f(Double(b.minX))) \(PdfNum.f(Double(b.minY))) \(PdfNum.f(Double(b.maxX))) \(PdfNum.f(Double(b.maxY))) d1\n"
        guard let path, !path.isEmpty else { return (ops, b) }
        final class Builder {
            var ops = ""
            var current = CGPoint.zero
            var start = CGPoint.zero
            func pt(_ p: CGPoint) -> String { "\(PdfNum.f(Double(p.x))) \(PdfNum.f(Double(p.y)))" }
        }
        let b2 = Builder()
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                b2.ops += "\(b2.pt(e.points[0])) m\n"
                b2.current = e.points[0]
                b2.start = e.points[0]
            case .addLineToPoint:
                b2.ops += "\(b2.pt(e.points[0])) l\n"
                b2.current = e.points[0]
            case .addQuadCurveToPoint:
                let q = e.points[0], end = e.points[1], p0 = b2.current
                let c1 = CGPoint(x: p0.x + (q.x - p0.x) * 2 / 3, y: p0.y + (q.y - p0.y) * 2 / 3)
                let c2 = CGPoint(x: end.x + (q.x - end.x) * 2 / 3, y: end.y + (q.y - end.y) * 2 / 3)
                b2.ops += "\(b2.pt(c1)) \(b2.pt(c2)) \(b2.pt(end)) c\n"
                b2.current = end
            case .addCurveToPoint:
                b2.ops += "\(b2.pt(e.points[0])) \(b2.pt(e.points[1])) \(b2.pt(e.points[2])) c\n"
                b2.current = e.points[2]
            case .closeSubpath:
                b2.ops += "h\n"
                b2.current = b2.start
            @unknown default:
                break
            }
        }
        ops += b2.ops + "f\n"
        return (ops, b)
    }

    private static func toUnicode(_ byCode: [(glyph: Int, text: String)]) -> [UInt8] {
        var sb = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        sb += "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
        sb += "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
        let entries = (1..<max(byCode.count, 1)).filter { !byCode[$0].text.isEmpty }
        var at = 0
        while at < entries.count {
            let chunk = entries[at..<min(at + 100, entries.count)]
            sb += "\(chunk.count) beginbfchar\n"
            for code in chunk { sb += "<\(hex2(code))> <\(utf16Hex(byCode[code].text))>\n" }
            sb += "endbfchar\n"
            at += 100
        }
        sb += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return Array(sb.utf8)
    }
}
