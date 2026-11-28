import CoreGraphics
import CoreText
import Foundation

/// A glyph placed on a line: its origin (offsets applied) in ems from the line's start, the text it stands for, and
/// whether it belongs to a right-to-left run (in a line written `GlyphOrder.stretches`, not a hyphen or other character
/// MuPDF always reads left to right, which goes on its own); a styled line's glyph also its size against the line's
/// (`scale`) and its color (nil: the text's own).
struct PlacedGlyph {
    var font: TrueTypeFont
    var glyph: Int
    var x: Double
    var y: Double
    var text: String
    var rtl = false
    var scale = 1.0
    var color: Int?
}

/// How a stretch of a styled line is drawn (`TextShaper.shape(_:_:_:_:_:)`): the font it asks for (nil: the line's), its
/// size against the line's, how far its baseline rises (ems of the line's size, down negative), its color (nil: the
/// text's own).
struct GlyphStyle {
    var font: TrueTypeFont?
    var scale = 1.0
    var rise = 0.0
    var color: Int?
}

/// The order a shaped line's glyphs are written to the content stream, which is the order a reader that goes by the
/// content (MuPDF, pdf.js) takes them in.
enum GlyphOrder {
    /// Reading order: right-to-left runs last glyph first, runs as typed.
    case logical
    /// Left to right, as drawn.
    case visual
    /// Each right-to-left stretch left to right, the stretches and the left-to-right runs between them in reading order,
    /// so that MuPDF and pdf.js both read the line in order and pdf.js reads the spaces between its right-to-left words
    /// (`TextShaper`'s notes); a line where that can't hold is written `logical`.
    case stretches
}

/// A shaped line: glyphs in the order they are written to the content stream (`GlyphOrder`), and its advance width in
/// ems.
struct ShapedLine {
    var text: String
    var glyphs: [PlacedGlyph]
    var width: Double
    /// The paragraph direction is right to left (its first strong character).
    var rtl: Bool
    /// Written with its directions marked where they change (see `Type3FontWriter.emit`): glyphs in logical order with
    /// both left-to-right and right-to-left runs, or a line written `GlyphOrder.stretches`.
    var mixed = false
    /// A styled line's runs left to right: the style each is in (its index; -1: none) and where it starts and ends, in
    /// ems from the line's start.
    var runs: [(style: Int, start: Double, end: Double)] = []
}

/// Lays a line of Unicode text out for PDF (the Windows app's `TextShaper`). Windows runs its own bidi, picks a font per
/// run and shapes each with HarfBuzz; on the Mac Core Text does all three in one `CTLine` (Arabic joining, Indic
/// reordering and conjuncts, marks, kerning, font fallback through the font's cascade list, the bidi algorithm with the
/// paragraph direction `Bidi` finds). The runs come back as Windows has them: glyphs with their positions and the text
/// each stands for, written in logical order, so the fonts' /ToUnicode makes copy and search return the typed string.
enum TextShaper {
    static func measure(_ text: String, _ primary: TrueTypeFont?) -> Double { shape(text, primary).width }

    /// The advance width in ems of the line `shape(_:_:_:_:_:)` draws, without putting its glyphs in the order they are
    /// written (wrapping measures many candidate lines).
    static func measure(_ text: String, _ primary: TrueTypeFont?, _ styles: [GlyphStyle]?, _ styleAt: [Int]?, _ written: GlyphOrder) -> Double {
        shape(text, primary, styles, styleAt, written, measure: true).width
    }

    /// - Parameter visualOrder: write the glyphs left to right (visual order) instead of in logical order.
    static func shape(_ text: String, _ primary: TrueTypeFont?, visualOrder: Bool = false) -> ShapedLine {
        shape(text, primary, nil, nil, visualOrder ? .visual : .logical)
    }

    /// A line whose stretches are drawn in styles of their own (`styles`; `styleAt` gives each UTF-16 unit's): Core Text
    /// shapes each stretch in its style's font (characters it lacks from the fallbacks) at its size, in one line, so the
    /// line's bidi order is kept across them and a bold or red word inside right-to-left text sits where it reads; each
    /// glyph then takes its style's rise and color. `written`: the order the glyphs are written in.
    static func shape(_ text: String, _ primary: TrueTypeFont?, _ styles: [GlyphStyle]?, _ styleAt: [Int]?, _ written: GlyphOrder = .logical) -> ShapedLine {
        shape(text, primary, styles, styleAt, written, measure: false)
    }

    /// `measure`: only the width is wanted: the glyphs aren't put in written order.
    private static func shape(_ text: String, _ primary: TrueTypeFont?, _ styles: [GlyphStyle]?, _ styleAt: [Int]?, _ written: GlyphOrder,
                              measure: Bool) -> ShapedLine {
        if text.isEmpty { return ShapedLine(text: text, glyphs: [], width: 0, rtl: false) }
        let units = Array(text.utf16)
        let bidi = Bidi.levels(text)
        var levels = bidi.levels
        let para = bidi.paragraph
        let joined = written == .stretches ? joinLeftToRight(units, &levels) : []
        func styleOf(_ i: Int) -> Int {
            guard let styles, let styleAt, i < styleAt.count, styleAt[i] >= 0, styleAt[i] < styles.count else { return -1 }
            return styleAt[i]
        }
        let line = makeLine(text, primary, rtl: para == 1, styles: styles, styleOf, joined)
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil)) / 1000
        if measure { return ShapedLine(text: text, glyphs: [], width: width, rtl: para == 1) }

        var runs: [ShapedRun] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            guard var shaped = shapeRun(run, units) else { continue }
            if shaped.style >= 0, let look = styles?[shaped.style] {
                let (scale, rise) = sizeOf(look)
                for k in shaped.glyphs.indices {
                    shaped.glyphs[k].y += rise
                    shaped.glyphs[k].scale = scale
                    shaped.glyphs[k].color = look.color
                }
            }
            runs.append(shaped)
        }
        let placedRuns = runs.sorted { $0.x < $1.x }.map { (style: $0.style, start: $0.x, end: $0.end) }
        let logical = runs.sorted { $0.start < $1.start }
        let stretches = written == .stretches && runs.contains { $0.rtl } && stretchesRead(logical, levels, styles)
        if written == .visual || stretches {
            // A right-to-left run's glyphs go left to right, and a glyph standing for several characters (a ligature's
            // "لى", a letter and its mark) holds them backwards too: readers reverse the run character by character
            // (MuPDF, pdf.js, `Bidi.toReadingOrder`), which then gives them back in reading order.
            var drawn = logical
            for k in drawn.indices where drawn[k].rtl {
                drawn[k].glyphs.reverse()
                for g in drawn[k].glyphs.indices where drawn[k].glyphs[g].text.unicodeScalars.count > 1 {
                    drawn[k].glyphs[g].text = String(String.UnicodeScalarView(drawn[k].glyphs[g].text.unicodeScalars.reversed()))
                }
            }
            if !stretches {
                let glyphs = drawn.sorted { $0.x < $1.x }.flatMap(\.glyphs)
                return ShapedLine(text: text, glyphs: glyphs, width: width, rtl: para == 1, runs: placedRuns)
            }
            return ShapedLine(text: text, glyphs: inStretches(drawn), width: width, rtl: para == 1, mixed: true, runs: placedRuns)
        }
        let mixed = runs.contains { $0.rtl } && runs.contains { !$0.rtl }
        return ShapedLine(text: text, glyphs: logical.flatMap(\.glyphs), width: width, rtl: para == 1, mixed: mixed, runs: placedRuns)
    }

    /// One Core Text run as shaped: where its text starts, its left and right ends (ems from the line's start), its
    /// direction, its style (-1: none) and its glyphs in logical order.
    private struct ShapedRun {
        var start: Int
        var x: Double
        var end: Double
        var rtl: Bool
        var style: Int
        var glyphs: [PlacedGlyph]
    }

    /// The attribute naming a stretch's style, so Core Text keeps each style's glyphs in runs of their own.
    private static let styleKey = NSAttributedString.Key("InkvoltGlyphStyle")

    private static func makeLine(_ text: String, _ primary: TrueTypeFont?, rtl: Bool, styles: [GlyphStyle]? = nil, _ styleOf: (Int) -> Int = { _ in -1 },
                                 _ leftToRight: [Range<Int>] = []) -> CTLine {
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
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        if let styles {
            let n = (text as NSString).length
            var i = 0
            while i < n {
                let k = styleOf(i)
                var j = i + 1
                while j < n && styleOf(j) == k { j += 1 }
                if k >= 0 {
                    let look = styles[k]
                    let base = look.font?.font ?? font
                    let sized = CTFontCreateCopyWithAttributes(base, 1000 * sizeOf(look).scale, nil, nil)
                    string.addAttributes([NSAttributedString.Key(kCTFontAttributeName as String): sized, styleKey: k], range: NSRange(location: i, length: j - i))
                }
                i = j
            }
        }
        // A version inside right-to-left text ("2.0-beta"): one left-to-right embedding, so it is drawn whole as typed.
        for r in leftToRight {
            let embedding = [NSNumber(value: CTWritingDirection.leftToRight.rawValue)] // left to right, embedding (not override)
            string.addAttribute(NSAttributedString.Key(kCTWritingDirectionAttributeName as String), value: embedding,
                                range: NSRange(location: r.lowerBound, length: r.count))
        }
        return CTLineCreateWithAttributedString(string as CFAttributedString)
    }

    /// A style's size against the line's and its rise as drawn: a size not above zero or not finite is the line's, a rise
    /// not finite none.
    private static func sizeOf(_ look: GlyphStyle) -> (scale: Double, rise: Double) {
        (look.scale > 0 && look.scale.isFinite ? look.scale : 1, look.rise.isFinite ? look.rise : 0)
    }

    // ---- Right-to-left stretches written left to right (GlyphOrder.stretches) ----
    //
    // pdf.js makes a space only where the next glyph lies to the right of the one before, inside one item it reads (a
    // stretch of one font and size, its glyphs going right), and puts each item's characters in reading order itself. A
    // line written in reading order goes left for every right-to-left glyph: pdf.js reads its words run together.
    // MuPDF (the app's own reading: search, copy, export) gives each character a direction from its Unicode class
    // (Arabic and Hebrew letters and Arabic digits right to left; Latin letters, European digits, "+", "-", "%" and the
    // like left to right; spaces and other punctuation that of the character before) and, on a line whose right-to-left
    // glyphs go right, turns each stretch of right-to-left characters around where it stands; it never moves one past a
    // left-to-right run. So a line reads in order in both when each right-to-left stretch is written left to right and
    // the stretches and the left-to-right runs between them come in reading order (the Windows app's notes in
    // `Shaping.cs`, ported as they are).

    /// Whether a line can be written `GlyphOrder.stretches` (`runs` in logical order): each right-to-left stretch in one
    /// font, size and rise (pdf.js reads a change of font or size as a new item, and a stretch's items written left to
    /// right would come out right to left), no left-to-right run holding a character MuPDF reads right to left (Arabic
    /// digits: it would turn them around), no deeper embedding than a left-to-right run inside right-to-left text.
    private static func stretchesRead(_ runs: [ShapedRun], _ levels: [UInt8], _ styles: [GlyphStyle]?) -> Bool {
        if (levels.max() ?? 0) > 2 { return false }
        func size(_ style: Int) -> (Double, Double) { sizeOf(style >= 0 && styles != nil ? styles![style] : GlyphStyle()) }
        for (i, r) in runs.enumerated() {
            if !r.rtl {
                if r.glyphs.contains(where: { muPdfReadsRightToLeft($0.text) == true }) { return false }
            } else if i > 0 && runs[i - 1].rtl {
                let a = runs[i - 1], fontA = a.glyphs.first?.font, fontB = r.glyphs.first?.font
                if fontA !== fontB || size(a.style) != size(r.style) { return false }
            }
        }
        return true
    }

    /// For a line written `GlyphOrder.stretches`: punctuation inside a word between a Latin letter or a European digit on
    /// either side ("2.0-beta", "3.5-rc2", "a_b") goes with them, left to right, as one run. The bidi rules leave such a
    /// "-" or "_" right to left between a number and a word in right-to-left text, drawing "beta-2.0", and MuPDF, which
    /// reads them all left to right, can read that only as a new line ("2.0", "-", "beta"); kept whole it reads
    /// "2.0-beta" in MuPDF and pdf.js, as typed. The levels are changed as Windows changes them; Core Text, which runs its
    /// own bidi, is given each such word (all of it: a part alone would leave its figures on their own) as a
    /// left-to-right embedding. Linear: a word is found out to its ends once, however many such marks it holds (a
    /// 100,000-character "1-a-1-a…" took some 10^10 steps when each mark scanned the whole word again).
    static func joinLeftToRight(_ u: [UInt16], _ levels: inout [UInt8]) -> [Range<Int>] {
        func cls(_ c: UInt16) -> Bidi.Cls { Bidi.classify(UInt32(c)) }
        func leftToRight(_ c: UInt16) -> Bool { cls(c) == .L || cls(c) == .EN }
        func between(_ c: UInt16) -> Bool {
            !(Unicode.Scalar(c)?.properties.isWhitespace ?? false) && [.ES, .ET, .CS, .ON].contains(cls(c))
        }
        var words: [Range<Int>] = []
        var i = 1
        while i < u.count {
            defer { i += 1 }
            if levels[i] % 2 == 0 || !between(u[i]) || levels[i - 1] % 2 == 1 || !leftToRight(u[i - 1]) { continue }
            var j = i
            while j < u.count && levels[j] % 2 == 1 && between(u[j]) { j += 1 }
            if j < u.count && levels[j] % 2 == 0 && leftToRight(u[j]) {
                for k in i..<j { levels[k] = min(levels[i - 1], levels[j]) }
                // The whole word, out to the spaces (or right-to-left letters) on either side: already found when the
                // last word reaches past this mark (the same word, as its ends are the same).
                if let last = words.last, last.upperBound > j {
                    i = j - 1
                    continue
                }
                var lo = i - 1, hi = j + 1
                while lo > 0 && (leftToRight(u[lo - 1]) || between(u[lo - 1])) { lo -= 1 }
                while hi < u.count && (leftToRight(u[hi]) || between(u[hi])) { hi += 1 }
                if let last = words.last, last.upperBound >= lo { words[words.count - 1] = last.lowerBound..<max(last.upperBound, hi) } else { words.append(lo..<hi) }
            }
            i = j - 1
        }
        return words
    }

    /// The direction MuPDF gives a glyph's text (by its first character's class): true right to left (R, AL, AN), false
    /// left to right (L, EN, ES, ET), nil that of the character before.
    private static func muPdfReadsRightToLeft(_ text: String) -> Bool? {
        guard let first = text.unicodeScalars.first else { return nil }
        switch Bidi.classify(first.value) {
        case .R, .AL, .AN: return true
        case .L, .EN, .ES, .ET: return false
        default: return nil
        }
    }

    /// A line's glyphs in `GlyphOrder.stretches` order: `runs` in logical order, each run's glyphs left to right. A
    /// character MuPDF always reads left to right inside a right-to-left stretch (a hyphen between two Arabic words) goes
    /// on its own, marked left to right, between the pieces of the stretch on either side of it, in reading order. Two or
    /// more side by side ("--") go one by one in reading order too: each a short step back, which MuPDF keeps on the line
    /// (written left to right, it would read them backwards).
    private static func inStretches(_ runs: [ShapedRun]) -> [PlacedGlyph] {
        var written: [PlacedGlyph] = []
        var i = 0
        while i < runs.count {
            let odd = runs[i].rtl
            var j = i + 1
            while j < runs.count && runs[j].rtl == odd { j += 1 }
            let glyphs = runs[i..<j].sorted { $0.x < $1.x }.flatMap(\.glyphs)
            i = j
            if !odd {
                written += glyphs
                continue
            }
            // Right to left: its pieces from the right, each written left to right.
            var end = glyphs.count
            var g = glyphs.count - 1
            while g >= -1 {
                defer { g -= 1 }
                if g >= 0 && muPdfReadsRightToLeft(glyphs[g].text) != false { continue }
                written += glyphs[(g + 1)..<end]
                if g >= 0 {
                    var alone = glyphs[g]
                    alone.rtl = false
                    written.append(alone)
                }
                end = g
            }
        }
        return written
    }

    /// One Core Text run: its glyphs in logical order (a right-to-left run last glyph first), each with the text of its
    /// cluster (one character per glyph, the rest on the cluster's last glyph, as Windows hands HarfBuzz's clusters out).
    private static func shapeRun(_ run: CTRun, _ units: [UInt16]) -> ShapedRun? {
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
        let style = (attributes[styleKey.rawValue] as? Int) ?? -1
        let runWidth = Double(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)) / 1000

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
        return ShapedRun(start: runStart, x: minX, end: minX + runWidth, rtl: rtl, style: style, glyphs: glyphs)
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
    /// Stand-in fonts of a paragraph edit (`ContentEditor`): each font also says which system font it is (/BaseFont, its
    /// PostScript name) and that it is one (/Name, under the stand-in prefix), so the edit's text reads back as part of
    /// the paragraph.
    private let standIn: Bool
    private var fonts: [Used] = []
    private var codes: [Key: (Used, Int)] = [:]

    init(namePrefix: String = "/PdU", standIn: Bool = false) {
        self.namePrefix = namePrefix
        self.standIn = standIn
    }

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
    /// - Parameter baseRise: the text rise in effect (a paragraph's own, or a script's): glyphs are raised from it, and it
    ///   is set back after.
    /// - Parameter ownFill: the fill operator the text is in ("0 g"), set back after a styled glyph's own color; nil:
    ///   colors aren't changed.
    func emit(_ sb: inout String, _ line: ShapedLine, size: Double, baseRise: Double = 0, ownFill: String? = nil) {
        // A cluster drawn with more glyphs than it has characters leaves glyphs with no text of their own: the line's
        // /ActualText then gives extraction the exact string.
        let actual = line.glyphs.contains { $0.text.isEmpty }
        if actual { sb += "/Span <</ActualText <FEFF\(Self.utf16Hex(line.text))>>> BDC " }
        var cur: Used?
        var pen = 0.0, rise = baseRise, scale = 1.0 // pen: thousandths of the line's size; scale: the size set against it
        var color: Int?
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
                if u !== cur || abs(g.scale - scale) > 1e-9 {
                    sb += "\(u.name) \(PdfNum.f(size * g.scale)) Tf "
                    cur = u
                    scale = g.scale
                }
                sb += "/Span <</ActualText ()>> BDC <\(Self.hex2(mark))> Tj EMC "
                direction = g.rtl
            }
            let (u, c) = code(g.font, g.glyph, g.text)
            if u !== cur || abs(g.scale - scale) > 1e-9 {
                close(&sb)
                sb += "\(u.name) \(PdfNum.f(size * g.scale)) Tf "
                cur = u
                scale = g.scale
            }
            let want = ownFill == nil ? nil : g.color
            if want != color {
                close(&sb)
                sb += want.map { ContentEditor.rgbOp($0) } ?? (ownFill! + " ")
                color = want
            }
            let y: Double = baseRise + g.y * size
            if abs(y - rise) > 0.001 {
                close(&sb)
                sb += "\(PdfNum.f(y)) Ts "
                rise = y
            }
            if !open { sb += "[" }
            open = true
            let target = g.x * 1000
            let adjust = (pen - target) / scale // in thousandths of the size set
            if abs(adjust) >= 0.001 { sb += PdfNum.f(adjust) + " " }
            sb += "<\(Self.hex2(c))>"
            pen = target + Self.width(g.font, g.glyph) * scale
        }
        close(&sb)
        if color != nil, let ownFill { sb += ownFill + " " }
        if abs(scale - 1) > 1e-9, let cur { sb += "\(cur.name) \(PdfNum.f(size)) Tf " }
        if abs(rise - baseRise) > 0.001 { sb += "\(PdfNum.f(baseRise)) Ts " }
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
        var entries: [(String, PObj)] = [
            ("Type", doc.name("Font")), ("Subtype", doc.name("Type3")),
            ("FontBBox", doc.reals(x0.rounded(.down), y0.rounded(.down), x1.rounded(.up), y1.rounded(.up))),
            ("FontMatrix", doc.reals(0.001, 0, 0, 0.001, 0, 0)), ("CharProcs", charProcs),
            ("Encoding", doc.dict([("Type", doc.name("Encoding")), ("Differences", differences)])),
            ("FirstChar", doc.int(1)), ("LastChar", doc.int(u.byCode.count - 1)), ("Widths", doc.array(widths)),
            ("Resources", doc.dict()),
            ("ToUnicode", doc.addStream(Self.toUnicode(u.byCode), deflate: true)),
        ]
        if standIn {
            entries.append(("Name", doc.name(String(u.name.drop { $0 == "/" }))))
            // Named by its family and style as Windows names faces ("Arial,Bold"), so it reads back apart from a page font
            // of the same face ("ABCDEF+Arial-BoldMT").
            let traits = CTFontGetSymbolicTraits(u.font.font)
            let bold = traits.contains(.traitBold), italic = traits.contains(.traitItalic)
            let style = bold ? (italic ? ",BoldItalic" : ",Bold") : italic ? ",Italic" : ""
            entries.append(("BaseFont", doc.name(u.font.family.filter { $0 != " " } + style)))
            // Its ascent and descent, so the text reads back with the system font's height (a Type 3 font says none).
            var flags = 4 // symbolic: its own encoding
            if italic { flags |= 64 }
            if bold { flags |= 0x40000 }
            let descriptor = doc.dict([
                ("Type", doc.name("FontDescriptor")), ("FontName", doc.name(u.font.postScriptName)), ("Flags", doc.int(flags)),
                ("FontBBox", doc.reals(u.font.bbox[0], u.font.bbox[1], u.font.bbox[2], u.font.bbox[3])), ("ItalicAngle", doc.int(0)),
                ("Ascent", doc.real((u.font.ascent * 1000).rounded())), ("Descent", doc.real((u.font.descent * 1000).rounded())),
                ("StemV", doc.int(0)),
            ])
            entries.append(("FontDescriptor", doc.add(descriptor)))
        }
        return doc.add(doc.dict(entries))
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
