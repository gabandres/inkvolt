import CoreGraphics
import CoreText
import Foundation
import PrintCore

/// What Make Text Editable did: the document, how many pages and words became text, and the fonts it drew them in
/// ("Times New Roman").
public struct EditableTextResult: Sendable {
    public var data: [UInt8]
    public var pages: Int
    public var words: Int
    public var fonts: [String]
}

/// Make Text Editable (roadmap 2.2, for 2.1's paragraph editing; the Windows app's `EditableText`): a scanned page's
/// recognized words (its Inkvolt text layer, `TextLayer`) become real, visible text, so Edit Text & Images can change
/// them. The words are put in lines (by their angle, then their height on the page), the lines in paragraphs. The font is
/// matched, as recognized words carry none (`FontMatch`): the scan's class (serif, sans serif or monospaced) from the
/// common families, then of every installed family of that class whose glyphs' proportions fit the words' boxes, the one
/// whose words, drawn small at the scan's size, look most like the scan's; each paragraph then takes the face of that
/// family (regular, bold, italic, bold italic) that looks most like it, and a heading the face of any family short-listed.
/// Each paragraph is drawn in its ink's colour. Each line takes the size and baseline its words' boxes give in its face,
/// each word starts where the scan has it. Lines of a paragraph get one size, a steady line step and their left edges
/// lined up, as 2.1 groups a paragraph. The scan is covered behind each line with the paper's own colour (or left
/// showing), and the invisible layer goes.
///
/// Mac differences: the faces are Core Text's (any outline format), measured by Core Text's glyph boxes where Windows asks
/// HarfBuzz, and drawn to compare by Core Graphics where Windows renders them with MuPDF; the text is written in Type 3
/// fonts from their outlines, as every edit on the Mac writes installed fonts (`Type3FontWriter`), named as paragraph
/// editing's own (so Edit Text & Images edits them). A family that is a common one's metric twin (Helvetica as Arial,
/// Times as Times New Roman, Courier as Courier New) counts as that family, as Windows has only the common one.
public enum EditableText {
    /// More recognized words than this on a page is a crafted layer: only this many are made text.
    public static let maxWords = 20_000

    /// What a recognized word's box misses of its ink at each edge (points): half a pixel at 300 dpi, the resolution
    /// Recognize Text reads at.
    static let edgeLoss = 0.12

    /// A family whose measures miss the words by more than this (`misfit`) isn't compared by look.
    static let maxMisfit = 0.2

    /// The most headings a page compares the short-listed faces with.
    public static let maxHeadings = 6

    /// A recognized word longer than this (characters) is no word: left out.
    public static let maxWordLength = 200

    /// A font file larger than this (a CJK collection) isn't tried: its look is no Latin text's.
    static let maxFontFile = 4_000_000

    /// How much more like the scan another family must look than a common one to be chosen: print is mostly set in the
    /// common families, and at 150 dpi faces of one design (Times New Roman, Baskerville) look alike within this.
    static let commonFirst = 0.03

    /// A page's family is judged on the words that look most like it, this share of them: a page's italic or bold words
    /// look like no regular face.
    static let familyShare = 0.6

    /// Of the installed families of the scan's class, at most this many are measured (the common ones first).
    static let maxCandidates = 24

    /// The start of the resource names Make Text Editable's fonts take: paragraph editing's stand-in fonts' (so the text
    /// can be edited), then "E".
    static let fontKey = ContentEditor.standInKey + "E"

    /// A face's style.
    enum Style: Int, CaseIterable, Sendable {
        case regular = 0, bold = 1, italic = 2, boldItalic = 3
        var isBold: Bool { self == .bold || self == .boldItalic }
        var isItalic: Bool { self == .italic || self == .boldItalic }
        var suffix: String {
            switch self {
            case .bold: " Bold"
            case .italic: " Italic"
            case .boldItalic: " Bold Italic"
            case .regular: ""
            }
        }
    }

    /// An installed family: its name, class and whether it is one of the common ones.
    final class Family: Hashable, @unchecked Sendable {
        let name: String
        let kind: StandInFonts.Kind
        let common: Bool

        init(_ name: String, _ kind: StandInFonts.Kind, _ common: Bool) {
            self.name = name
            self.kind = kind
            self.common = common
        }

        static func == (a: Family, b: Family) -> Bool { a === b }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var families: [Family]?
        var faces: [String: TrueTypeFont?] = [:]
    }

    private static let cache = Cache()

    /// Every installed family to match against, the common ones first (each one's regular face found and its file's size
    /// checked once).
    static var families: [Family] {
        cache.lock.lock()
        if let known = cache.families {
            cache.lock.unlock()
            return known
        }
        cache.lock.unlock()
        var all: [Family] = []
        var taken = Set<String>()
        for f in StandInFonts.commonFamilies {
            let family = Family(f.name, f.kind, true)
            if face(family, .regular) != nil {
                all.append(family)
                taken.formUnion(f.aliases.map { $0.lowercased() })
                taken.insert(f.name.lowercased())
            }
        }
        for name in StandInFonts.installed() where !taken.contains(name.lowercased()) {
            let family = Family(name, StandInFonts.kindOf(name, 0), false)
            if let regular = face(family, .regular), !madeForAnotherScript(regular) { all.append(family) }
        }
        cache.lock.lock()
        cache.families = all
        cache.lock.unlock()
        return all
    }

    /// Languages whose scripts a family is made for when it supports them (Indic, Southeast Asian, East Asian, Ethiopic,
    /// Tibetan and the like): such a family's Latin letters are borrowed, a Bengali family's from a Helvetica, so it isn't
    /// offered for Latin text. macOS has dozens ("Bangla Sangam MN" read as closer to a Helvetica page than Arial);
    /// Windows' fonts for those scripts are CJK collections over `maxFontFile` or have no Latin, so Windows needs no list.
    private static let otherScripts: Set<String> = [
        "bn", "hi", "mr", "ne", "sa", "ta", "te", "kn", "ml", "gu", "pa", "or", "as", "si", "my", "km", "lo", "th", "bo", "dz",
        "zh", "ja", "ko", "am", "ti", "chr", "iu", "mn", "dv", "sat", "mni", "ks", "sd",
    ]

    /// Whether a face is made for a script other than Latin (`otherScripts`).
    private static func madeForAnotherScript(_ font: TrueTypeFont) -> Bool {
        let languages = (CTFontCopySupportedLanguages(font.font) as? [String]) ?? []
        return languages.contains { otherScripts.contains(String($0.prefix { $0 != "-" && $0 != "_" }).lowercased()) }
    }

    /// The families a page with no picture to compare with is measured against: the common ones.
    private static var common: [Family] { families.filter(\.common) }

    /// A family's face in `style`, loaded once for the process; nil when the family hasn't that style (Core Text's closest
    /// face is another) or its file is too large.
    static func face(_ family: Family, _ style: Style) -> TrueTypeFont? {
        let key = "\(family.name.lowercased())|\(style.rawValue)"
        cache.lock.lock()
        if let hit = cache.faces[key] {
            cache.lock.unlock()
            return hit
        }
        cache.lock.unlock()
        var found: TrueTypeFont?
        if let f = StandInFonts.face(family.name, style.isBold, style.isItalic), f.name.caseInsensitiveCompare(family.name + style.suffix) == .orderedSame,
           fileSize(f.font) <= maxFontFile {
            found = f.font
        }
        cache.lock.lock()
        cache.faces[key] = .some(found)
        cache.lock.unlock()
        return found
    }

    /// The size of a face's file (bytes); Int.max when Core Text doesn't say where it is.
    private static func fileSize(_ font: TrueTypeFont) -> Int {
        guard let url = CTFontCopyAttribute(font.font, kCTFontURLAttribute) as? URL,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return Int.max }
        return size.intValue
    }

    /// A face's name as people know it ("Times New Roman Bold Italic").
    static func nameOf(_ family: Family, _ style: Style) -> String { family.name + style.suffix }

    /// The pages that have recognized text to make editable, in order.
    public static func pages(_ data: [UInt8], _ password: String?) throws -> [Int] {
        try TextLayer.words(data, password).keys.sorted()
    }

    /// `pages`' recognized text made real text (pages without an Inkvolt text layer are left alone). `keepScan`: the scan
    /// stays showing behind the text (else it is covered behind each line). The data comes back unchanged when no page
    /// changed. `progress` gets (pages done, pages to do).
    /// - Throws: `CancellationError` when `cancel` fires; `PdfEditError` for a PDF that can't be edited.
    public static func make(_ data: [UInt8], _ password: String?, pages: [Int], keepScan: Bool, cancel: CancelToken? = nil,
                            progress: ((Int, Int) -> Void)? = nil) throws -> EditableTextResult {
        let layers = try TextLayer.words(data, password)
        let chosen = Array(Set(pages.filter { layers[$0] != nil })).sorted()
        if chosen.isEmpty { return EditableTextResult(data: data, pages: 0, words: 0, fonts: []) }
        var plans: [Int: PagePlan] = [:]
        var papers: [Int: [Rgb]] = [:]
        let match = FontMatch(cancel)
        let engine = try PdfEngine.open(data, password: password)
        do {
            defer { engine.close() }
            for (i, page) in chosen.enumerated() {
                try cancel.check()
                progress?(i, chosen.count)
                let look = ScanLook(engine, page, match, cancel)
                guard let recognized = layers[page]?.words, let planned = try plan(recognized, look: look), !planned.lines.isEmpty else { continue }
                plans[page] = planned
                // The paper behind each line, from the page as it shows.
                if !keepScan {
                    papers[page] = try planned.lines.map { l in
                        let face = planned.faceOf(l)
                        return try look.paper(cover(l, shape(l, face, planned.inks), face, planned.inks))
                    }
                }
            }
        }
        if plans.isEmpty { return EditableTextResult(data: data, pages: 0, words: 0, fonts: []) }

        var fonts: [String] = []
        var words = 0
        let out = try PageEditor.edit(data, password) { doc in
            for (index, plan) in plans.sorted(by: { $0.key < $1.key }) {
                try cancel.check()
                let page = doc.page(index)
                TextLayer.remove(doc, page)
                write(doc, page, plan, papers[index])
                words += plan.lines.reduce(0) { $0 + $1.words.count }
                for name in plan.lines.map(plan.nameOf) where !fonts.contains(name) { fonts.append(name) }
            }
        }
        progress?(chosen.count, chosen.count)
        return EditableTextResult(data: out, pages: plans.count, words: words, fonts: fonts)
    }

    // ---- Planning ----

    /// A colour, 0 to 1 each.
    typealias Rgb = (r: Double, g: Double, b: Double)

    /// A recognized word in its line's frame (the page turned back by the line's angle): its box, and where its text starts.
    final class PlanWord {
        let text: String
        let left: Double, right: Double, top: Double, bottom: Double
        var height: Double { bottom - top }
        var width: Double { right - left }
        /// Where its text starts along the line (frame points): the box's left less the first glyph's left side.
        var pen = 0.0

        init(_ text: String, _ left: Double, _ right: Double, _ top: Double, _ bottom: Double) {
            self.text = text
            self.left = left
            self.right = right
            self.top = top
            self.bottom = bottom
        }
    }

    /// A line of text to write: its words, its frame's angle (degrees clockwise; the frame is the page turned back by it
    /// about the page's top left), size (points), baseline, face and colour, in frame coordinates.
    final class PlanLine {
        let words: [PlanWord]
        let angle: Double
        var size = 0.0
        var baseline = 0.0
        var style = Style.regular
        /// A family of its own (a heading set apart from the page's text); nil: the page's.
        var family: Family?
        /// Its ink's colour (0 to 1 each); black unless its paragraph's ink is clearly another.
        var color: Rgb = (0, 0, 0)
        /// The paragraph it was put in (an index on its page).
        var paragraph = 0
        var left: Double { words[0].pen }
        var right: Double { words[words.count - 1].right }
        var top: Double { words.map(\.top).min() ?? 0 }
        var bottom: Double { words.map(\.bottom).max() ?? 0 }
        private(set) lazy var text: String = words.map(\.text).joined(separator: " ")

        init(_ words: [PlanWord], _ angle: Double) {
            self.words = words
            self.angle = angle
        }
    }

    /// A page's lines, the family they are written in, and the inks measured while planning (`inks`).
    final class PagePlan {
        let family: Family
        let lines: [PlanLine]
        let inks: Inks

        init(_ family: Family, _ lines: [PlanLine], _ inks: Inks) {
            self.family = family
            self.lines = lines
            self.inks = inks
        }

        func familyOf(_ line: PlanLine) -> Family { line.family ?? family }

        /// The style a line is drawn in: its own when its family has that face, else regular.
        func styleOf(_ line: PlanLine) -> Style { face(familyOf(line), line.style) != nil ? line.style : .regular }

        func faceOf(_ line: PlanLine) -> TrueTypeFont { face(familyOf(line), styleOf(line)) ?? face(family, .regular)! }

        /// The face a line is drawn in, as people know it ("Times New Roman Bold").
        func nameOf(_ line: PlanLine) -> String { EditableText.nameOf(familyOf(line), styleOf(line)) }
    }

    /// How far a word's ink reaches (ems): left and right from the pen, top and bottom from the baseline (up positive).
    struct Ink {
        var left: Double, right: Double, top: Double, bottom: Double
        var missing: Bool
        var width: Double { right - left }
        var height: Double { top - bottom }
    }

    /// Each text's ink in each font, worked out once (a page's planning, a run's drawing).
    final class Inks: @unchecked Sendable {
        private struct Key: Hashable {
            var text: String
            var font: ObjectIdentifier
        }

        private var known: [Key: Ink] = [:]

        /// The ink of `text` set in `font`; missing when the font lacks a character of it.
        func of(_ text: String, _ font: TrueTypeFont) -> Ink {
            let key = Key(text: text, font: ObjectIdentifier(font))
            if let hit = known[key] { return hit }
            let ink = EditableText.measured(text, font)
            known[key] = ink
            return ink
        }
    }

    private static func measured(_ text: String, _ font: TrueTypeFont) -> Ink {
        let line = TextShaper.shape(text, font, visualOrder: true)
        var (left, right, top, bottom) = (Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
        var missing = false
        for g in line.glyphs {
            missing = missing || g.font !== font || g.glyph == 0
            var glyph = CGGlyph(clamping: g.glyph)
            var box = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(g.font.font, .horizontal, &glyph, &box, 1)
            if box.isNull || box.width == 0 { continue }
            let upem = g.font.unitsPerEm
            left = min(left, g.x + Double(box.minX) / upem)
            right = max(right, g.x + Double(box.maxX) / upem)
            top = max(top, g.y + Double(box.maxY) / upem)
            bottom = min(bottom, g.y + Double(box.minY) / upem)
        }
        return left > right ? Ink(left: 0, right: line.width, top: 0.7, bottom: 0, missing: true) : Ink(left: left, right: right, top: top, bottom: bottom, missing: missing)
    }

    /// The page's recognized words as lines to write: grouped by angle and height into lines, the family that fits them
    /// best chosen, each line's size and baseline measured, its paragraph's lines made alike, then each paragraph's face
    /// and colour taken from the scan (`look`; without it, by measure among the common families, regular and black). Nil
    /// when no installed family is there to write in.
    static func plan(_ recognized: [OcrWord], look: ScanLook? = nil) throws -> PagePlan? {
        let words = Array(recognized.filter { w in
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && t.count <= maxWordLength && w.rect.width > 0 && w.rect.height > 0 && w.angle.isFinite && w.rect.x.isFinite && w.rect.y.isFinite
        }.prefix(maxWords))
        if words.isEmpty { return nil }
        var lines: [PlanLine] = []
        for (angle, group) in byAngle(words) { lines += linesOf(group, angle) }
        if lines.isEmpty { return nil }

        let inks = Inks()
        // Do the boxes hold each word's own ink, or the line's height for every word? Words in one line all as tall: the line's.
        let lineBoxes = lineBoxesOf(lines)
        guard let family = try choose(lines, lineBoxes, look, inks), let regular = face(family, .regular) else { return nil }
        for line in lines { measure(line, regular, lineBoxes, inks) }
        let plan = PagePlan(family, lines, inks)
        let paragraphs = paragraphsOf(plan)
        guard let look else { return plan }

        // Each paragraph in the face of the family that looks most like it (bold, italic), a heading (a line on its own a
        // sixth bigger than the body text or more, the first few on the page) in that of any family short-listed; each in
        // its ink's colour. The faces' words are drawn together, once for the page.
        let inParagraphs = paragraphs.filter { $0.count >= 2 }.flatMap { $0 }.map(\.size)
        let bodySize = median(inParagraphs.isEmpty ? lines.map(\.size) : inParagraphs)
        var headings = Set<Int>()
        for (i, p) in paragraphs.enumerated() where headings.count < maxHeadings {
            if p.count == 1 && p[0].size >= 1.15 * bodySize && p[0].words.reduce(0, { $0 + $1.text.filter(\.isLetter).count }) >= 6 { headings.insert(i) }
        }
        let samples = paragraphs.map { sampleOf($0, 10) }
        func facesOf(_ families: [Family]) -> [(family: Family, style: Style)] {
            families.flatMap { f in Style.allCases.map { (f, $0) } }.filter { face($0.0, $0.1) != nil }
        }
        let bodyFaces = facesOf([family])
        let headingFaces = facesOf(look.match.headingFamilies(family))
        var wanted: [(TrueTypeFont, String)] = []
        for x in bodyFaces {
            let font = face(x.family, x.style)!
            for (i, s) in samples.enumerated() where !headings.contains(i) { wanted += s.map { (font, $0.word.text) } }
        }
        for x in headingFaces {
            let font = face(x.family, x.style)!
            for i in headings { wanted += samples[i].map { (font, $0.word.text) } }
        }
        try look.draw(wanted)
        for (i, p) in paragraphs.enumerated() {
            let sample = samples[i]
            // A paragraph of a word or two says too little to change its face (a heading may).
            if sample.count >= 3 || headings.contains(i) && !sample.isEmpty {
                func score(_ x: (family: Family, style: Style)) -> Double { look.resemblance(face(x.family, x.style)!, sample) }
                let mine = score((family, .regular))
                let best = (headings.contains(i) ? headingFaces : bodyFaces).map { ($0, score($0)) }.max { $0.1 < $1.1 }
                if let best, best.1 > mine + 0.03 && (best.0.family != family || best.0.style != .regular) {
                    for l in p {
                        l.family = best.0.family == family ? nil : best.0.family
                        l.style = best.0.style
                        measure(l, plan.faceOf(l), lineBoxes, inks)
                    }
                    regularize(p)
                }
            }
            let color = look.inkColor(p)
            for l in p { l.color = color }
        }
        return plan
    }

    /// Up to `count` words of three letters or more of `lines`, spread over them.
    static func sampleOf(_ lines: [PlanLine], _ count: Int) -> [(line: PlanLine, word: PlanWord)] {
        let all = lines.flatMap { l in l.words.filter { $0.text.filter(\.isLetter).count >= 3 }.map { (line: l, word: $0) } }
        let n = min(count, all.count)
        return (0..<n).map { all[$0 * all.count / n] }
    }

    /// Words of about one angle (within half a degree of the next, round the circle: an upside-down page's words read at
    /// 179.9° and −179.9° are one direction), each group with its middle angle.
    static func byAngle(_ words: [OcrWord]) -> [(angle: Double, words: [OcrWord])] {
        let sorted = words.sorted { Angles.wrap($0.angle) < Angles.wrap($1.angle) }
        var groups: [[OcrWord]] = [[sorted[0]]]
        for w in sorted.dropFirst() {
            if Angles.wrap(w.angle) - Angles.wrap(groups[groups.count - 1].last!.angle) > 0.5 { groups.append([]) }
            groups[groups.count - 1].append(w)
        }
        // The last group and the first meet across ±180°.
        if groups.count > 1 && abs(Angles.difference(groups[0][0].angle, groups[groups.count - 1].last!.angle)) <= 0.5 {
            groups[0].insert(contentsOf: groups.removeLast(), at: 0)
        }
        return groups.map { g in
            // The middle angle, measured from the group's first so the values don't jump at ±180°.
            let first = g[0].angle
            let middle = g.map { first + Angles.difference($0.angle, first) }.sorted()[g.count / 2]
            return (Angles.wrap(middle), g)
        }
    }

    /// A page point turned back by `angle` about the page's top left (into the frame where the text is level).
    private static func toFrame(_ angle: Double, _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let (s, c) = (sin(-angle * .pi / 180), cos(-angle * .pi / 180))
        return (x * c - y * s, x * s + y * c)
    }

    /// A frame point back on the page.
    static func toPage(_ angle: Double, _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let (s, c) = (sin(angle * .pi / 180), cos(angle * .pi / 180))
        return (x * c - y * s, x * s + y * c)
    }

    /// Words on one band of height, left to right, split where a gap is a column's (over twice the line's height).
    private static func linesOf(_ words: [OcrWord], _ angle: Double) -> [PlanLine] {
        let framed = words.map { w -> PlanWord in
            let (cx, cy) = toFrame(angle, w.rect.centerX, w.rect.centerY)
            // A box around ink read at 300 dpi misses about half a pixel at each edge (the edges are lighter than ink): put back.
            let (hw, hh) = (w.rect.width / 2 + edgeLoss, w.rect.height / 2 + edgeLoss)
            return PlanWord(w.text.trimmingCharacters(in: .whitespacesAndNewlines), cx - hw, cx + hw, cy - hh, cy + hh)
        }.enumerated().sorted { ($0.element.top + $0.element.bottom, $0.offset) < ($1.element.top + $1.element.bottom, $1.offset) }.map(\.element)
        var lines: [PlanLine] = []
        var i = 0
        while i < framed.count {
            var band = [framed[i]]
            var j = i + 1
            // A word whose middle is within 0.4 of a word's usual height of the band's first words' middle joins it (a word
            // with ascenders, one with descenders and one of x-height alone sit about a quarter of that apart). The usual
            // height, not the band's: a word read too tall (two lines' ink in its box) doesn't swallow the next line.
            var bandMid = (framed[i].top + framed[i].bottom) / 2
            var usual = framed[i].height
            while j < framed.count {
                let mid = (framed[j].top + framed[j].bottom) / 2
                // Its first words' median height (a crafted band of thousands isn't sorted again for each).
                if band.count < 16 { usual = (band.map(\.height) + [framed[j].height]).sorted()[band.count / 2] }
                if mid - bandMid > 0.4 * usual { break }
                band.append(framed[j])
                if band.count <= 3 { bandMid = band.reduce(0) { $0 + ($1.top + $1.bottom) / 2 } / Double(band.count) }
                j += 1
            }
            i = j
            let height = band.map(\.height).sorted()[band.count / 2]
            var line: [PlanWord] = []
            for w in band.enumerated().sorted(by: { ($0.element.left, $0.offset) < ($1.element.left, $1.offset) }).map(\.element) {
                if let last = line.last, w.left - last.right <= 2.5 * height {
                    line.append(w)
                } else {
                    if !line.isEmpty { lines.append(PlanLine(line, angle)) }
                    line = [w]
                }
            }
            if !line.isEmpty { lines.append(PlanLine(line, angle)) }
        }
        return lines
    }

    /// Whether the recognizer boxed each word by its line's height (Windows' boxes are a word's own ink; a line box would
    /// make every word as tall).
    private static func lineBoxesOf(_ lines: [PlanLine]) -> Bool {
        let spreads = lines.filter { $0.words.count >= 3 }.map { l -> Double in
            let heights = l.words.map(\.height)
            let mean = heights.reduce(0, +) / Double(heights.count)
            return (heights.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(heights.count)).squareRoot() / mean
        }
        return !spreads.isEmpty && spreads.reduce(0, +) / Double(spreads.count) < 0.03
    }

    /// A word's size in a font: by its width (its box's width over its ink's in the font: many pixels, so the surest),
    /// unless that is far from what its height says (a word read short or long) or it has under two letters.
    private static func sizeOf(_ word: PlanWord, _ line: PlanLine, _ font: TrueTypeFont, _ lineBoxes: Bool, _ inks: Inks) -> Double {
        let byHeight = sizeByHeight(word, line, font, lineBoxes, inks)
        let ink = inks.of(word.text, font)
        if ink.missing || ink.width <= 0.05 || word.text.filter({ $0.isLetter || $0.isNumber }).count < 2 { return byHeight }
        let byWidth = word.width / ink.width
        return byHeight.isFinite && byHeight > 0 && abs(log(byWidth / byHeight)) > 0.25 ? byHeight : byWidth
    }

    /// A word's size by its height in a font: its own ink's, or (line boxes) its line's text's.
    private static func sizeByHeight(_ word: PlanWord, _ line: PlanLine, _ font: TrueTypeFont, _ lineBoxes: Bool, _ inks: Inks) -> Double {
        let ink = inks.of(lineBoxes ? line.text : word.text, font)
        return ink.height > 0.05 ? word.height / ink.height : .nan
    }

    /// How badly words fit a font: the median of |ln(size by width ÷ size by height)| over the words of `minLetters`
    /// letters or digits or more, and with boxes of each word's own ink, the median of how far each word's size by height
    /// is from its line's (a font whose ascenders and x-height are another's gives a line's words different sizes).
    static func misfit(_ lines: [PlanLine], _ font: TrueTypeFont, _ lineBoxes: Bool, _ minLetters: Int, _ inks: Inks) -> Double {
        var widths: [Double] = []
        var heights: [Double] = []
        for line in lines {
            var sizes: [Double] = []
            for w in line.words where w.text.filter({ $0.isLetter || $0.isNumber }).count >= minLetters {
                let ink = inks.of(w.text, font)
                let byHeight = sizeByHeight(w, line, font, lineBoxes, inks)
                if ink.missing || ink.width <= 0.05 || !(byHeight > 0) || !byHeight.isFinite { continue }
                widths.append(abs(log(w.width / ink.width / byHeight)))
                sizes.append(byHeight)
            }
            if !lineBoxes && sizes.count >= 2 {
                let middle = median(sizes)
                heights += sizes.map { abs(log($0 / middle)) }
            }
        }
        return widths.isEmpty ? .greatestFiniteMagnitude : median(widths) + (heights.isEmpty ? 0 : median(heights))
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// The installed family the page's text is set in. Without a picture, by measure (`misfit`) among the common families.
    /// With one (`look`): the scan's class from how the common serif, sans serif and monospaced families look against it;
    /// of that class's installed families (the common ones first, at most `maxCandidates`), those whose measures fit (a
    /// box's height and width are a few percent off, as much as faces differ, so measure only rules out faces far off), the
    /// eight closest by measure compared by look. The best four are kept for the document's next pages, which compare only
    /// those.
    private static func choose(_ lines: [PlanLine], _ lineBoxes: Bool, _ look: ScanLook?, _ inks: Inks) throws -> Family? {
        var measured = Array(lines.filter { $0.words.count >= 3 }.prefix(8))
        if measured.isEmpty { measured = lines }
        guard let look else {
            return common.compactMap { f in face(f, .regular).map { (f, misfit(measured, $0, lineBoxes, 3, inks)) } }.min { $0.1 < $1.1 }?.0
        }

        let sample = sampleOf(lines, ScanLook.samples)
        if sample.isEmpty { return look.match.shortlist?.first ?? common.first { face($0, .regular) != nil } }
        func ranked(_ families: [Family]) throws -> [Family] {
            let faces = families.filter { face($0, .regular) != nil }
            try look.draw(faces.flatMap { f in sample.map { (face(f, .regular)!, $0.word.text) } })
            let scored = faces.map { f in (f, look.resemblance(face(f, .regular)!, sample, share: familyShare) + (f.common ? commonFirst : 0)) }
            return scored.enumerated().sorted { ($1.element.1, $0.offset) < ($0.element.1, $1.offset) }.map(\.element.0)
        }
        if let kept = look.match.shortlist { return try ranked(kept).first }

        let representatives = [StandInFonts.Kind.serif, .sans, .mono].compactMap { k in common.first { $0.kind == k && face($0, .regular) != nil } }
        guard let kind = try ranked(representatives).first?.kind else { return nil }
        let candidates = families.filter { $0.kind == kind }.prefix(maxCandidates)
            .compactMap { f in face(f, .regular).map { (f, misfit(measured, $0, lineBoxes, 3, inks)) } }
            .filter { $0.1 <= maxMisfit }
            .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.prefix(8).map(\.element.0)
        let rankedList = try candidates.isEmpty ? ranked(representatives.filter { $0.kind == kind }) : ranked(Array(candidates))
        look.match.keep(Array(rankedList.prefix(4)), representatives)
        return rankedList.first
    }

    /// A line's size (the median of its words'), baseline (the median of where each word's ink puts it) and where each
    /// word's text starts.
    private static func measure(_ line: PlanLine, _ font: TrueTypeFont, _ lineBoxes: Bool, _ inks: Inks) {
        let sizes = line.words.map { sizeOf($0, line, font, lineBoxes, inks) }.filter { $0.isFinite && $0 > 0 }.sorted()
        let size = sizes.isEmpty ? line.words.reduce(0) { $0 + $1.height } / Double(line.words.count) / 0.72 : sizes[sizes.count / 2]
        line.size = (min(max(size, 1), 500) * 100).rounded(.toNearestOrEven) / 100
        let lineInk = inks.of(line.text, font)
        let baselines = line.words.map { $0.bottom + (lineBoxes ? lineInk.bottom : inks.of($0.text, font).bottom) * line.size }.sorted()
        line.baseline = baselines[baselines.count / 2]
        for w in line.words { w.pen = w.left - inks.of(w.text, font).left * line.size }
    }

    /// Lines one under the other in the same look (size within 15%, a step of 0.9 to 2.5 sizes, steady, left edges or a
    /// first-line indent lined up) are a paragraph; its lines take one size, an even step and one left edge where they are
    /// near it, as Edit Text & Images then reads them as one paragraph. The paragraphs, in the order found.
    private static func paragraphsOf(_ plan: PagePlan) -> [[PlanLine]] {
        var paragraphs: [[PlanLine]] = []
        var angles: [Double] = []
        for l in plan.lines where !angles.contains(l.angle) { angles.append(l.angle) }
        for angle in angles {
            // Open paragraphs by their index in `paragraphs`.
            var open: [Int] = []
            let group = plan.lines.enumerated().filter { $0.element.angle == angle }
                .sorted { ($0.element.baseline, $0.element.left, $0.offset) < ($1.element.baseline, $1.element.left, $1.offset) }.map(\.element)
            for line in group {
                // A paragraph whose last line is far above takes no more: a crafted page's thousands of lines don't each try every one.
                open.removeAll { p in
                    let last = paragraphs[p][paragraphs[p].count - 1]
                    return line.baseline - last.baseline > 3 * max(line.size, last.size)
                }
                var best: Int?
                var bestStep = Double.greatestFiniteMagnitude
                for p in open {
                    let para = paragraphs[p]
                    let last = para[para.count - 1]
                    let size = max(last.size, line.size)
                    let step = line.baseline - last.baseline
                    if last.style != line.style || abs(last.size - line.size) > 0.15 * size { continue }
                    if step < 0.9 * size || step > 2.5 * size || line.left >= last.right || line.right <= last.left { continue }
                    if para.count >= 2 && abs(step - (last.baseline - para[para.count - 2].baseline)) > 0.2 * size { continue }
                    let left = para.count >= 2 ? para[1].left : last.left
                    let indent = para.count == 1 && last.left - line.left >= 0.5 * size && last.left - line.left <= 8 * size
                    if abs(line.left - left) > size && !indent { continue }
                    if step < bestStep { (best, bestStep) = (p, step) }
                }
                if let best {
                    paragraphs[best].append(line)
                } else {
                    paragraphs.append([line])
                    open.append(paragraphs.count - 1)
                }
            }
        }
        for (i, p) in paragraphs.enumerated() {
            for l in p { l.paragraph = i }
            regularize(p)
        }
        return paragraphs
    }

    /// A paragraph's lines given one size, an even step and one left edge (and its first too unless indented).
    private static func regularize(_ p: [PlanLine]) {
        if p.count < 2 { return }
        let size = (p.map(\.size).sorted()[p.count / 2] * 10).rounded(.toNearestOrEven) / 10
        for l in p {
            // The words keep their places: their text grows or shrinks about each box's left.
            let scale = size / l.size
            for w in l.words { w.pen = w.left - (w.left - w.pen) * scale }
            l.size = size
        }
        // An even step: the baselines' straight fit, when every line is near it.
        if let fit = planFit(p) { for (k, l) in p.enumerated() { l.baseline = fit.first + Double(k) * fit.step } }
        let lefts = p.dropFirst().map(\.left).sorted()
        let edge = lefts[lefts.count / 2]
        for l in p where abs(l.left - edge) <= 0.6 * size { l.words[0].pen = edge }
    }

    private static func planFit(_ p: [PlanLine]) -> (first: Double, step: Double)? {
        let n = p.count
        let meanK = Double(n - 1) / 2
        let meanB = p.reduce(0) { $0 + $1.baseline } / Double(n)
        var (sxy, sxx) = (0.0, 0.0)
        for k in 0..<n {
            sxy += (Double(k) - meanK) * (p[k].baseline - meanB)
            sxx += (Double(k) - meanK) * (Double(k) - meanK)
        }
        let step = sxy / sxx
        let first = meanB - step * meanK
        return (0..<n).allSatisfy { abs(p[$0].baseline - (first + Double($0) * step)) <= 0.25 * p[$0].size } ? (first, step) : nil
    }

    // ---- Writing ----

    /// A line's glyphs: each word from its place, a space between words (narrowed to half when the words are close, never
    /// overlapping).
    private static func shape(_ line: PlanLine, _ font: TrueTypeFont, _ inks: Inks) -> ShapedLine {
        let size = line.size
        let space = TextShaper.shape(" ", font)
        var glyphs: [PlacedGlyph] = []
        let origin = line.left
        var end = 0.0 // points from the line's start
        for (i, word) in line.words.enumerated() {
            var start = word.pen - origin
            if i > 0 {
                if var g = space.glyphs.first {
                    g.x = end / size
                    glyphs.append(g)
                }
                start = max(start, end + 0.5 * space.width * size)
            } else {
                start = 0
            }
            let shaped = TextShaper.shape(word.text, font, visualOrder: true)
            for var g in shaped.glyphs {
                g.x += start / size
                glyphs.append(g)
            }
            end = start + shaped.width * size
        }
        return ShapedLine(text: line.text, glyphs: glyphs, width: end / size, rtl: false)
    }

    /// The page's lines as text after its content (the scan covered behind each line in `papers`' colour, when given).
    private static func write(_ doc: MuDoc, _ page: PObj, _ plan: PagePlan, _ papers: [Rgb]?) {
        let resources = ContentEditor.ownDict(doc, page, "Resources", PageBoxes.inherited(page, "Resources"))
        let fonts = ContentEditor.ownDict(doc, resources, "Font")
        let writer = Type3FontWriter(namePrefix: "/\(fontKey)\(ContentEditor.lowestFree(fonts.keys, fontKey, suffix: "_"))_", standIn: true)
        let frame = PageBoxes.frame(page)
        var ops = "q\n"
        let shaped = plan.lines.map { shape($0, plan.faceOf($0), plan.inks) }
        func f(_ v: Double) -> String { PdfNum.f(v) }

        if let papers {
            for (i, line) in plan.lines.enumerated() {
                let paper = papers[i]
                ops += "\(f(paper.r)) \(f(paper.g)) \(f(paper.b)) rg "
                let corners = cover(line, shaped[i], plan.faceOf(line), plan.inks).map { frame.toPdf($0.x, $0.y) }
                ops += "\(f(corners[0].x)) \(f(corners[0].y)) m "
                for c in corners.dropFirst() { ops += "\(f(c.x)) \(f(c.y)) l " }
                ops += "h f\n"
            }
        }

        ops += "BT 0 Tr 0 Tc 0 Tw 100 Tz 0 Ts\n"
        for (i, line) in plan.lines.enumerated() {
            ops += "\(f(line.color.r)) \(f(line.color.g)) \(f(line.color.b)) rg "
            let (s, c) = (sin(line.angle * .pi / 180), cos(line.angle * .pi / 180))
            let p = toPage(line.angle, line.left, line.baseline)
            let o = frame.toPdf(p.x, p.y)
            let u = frame.toPdf(p.x + c, p.y + s) // along the line
            let v = frame.toPdf(p.x + s, p.y - c) // up
            ops += "\(f(u.x - o.x)) \(f(u.y - o.y)) \(f(v.x - o.x)) \(f(v.y - o.y)) \(f(o.x)) \(f(o.y)) Tm "
            writer.emit(&ops, shaped[i], size: line.size)
            ops += "\n"
        }
        ops += "ET Q\n"

        let built = writer.buildFonts(doc)
        for key in built.keys { if let font = built[key] { fonts.set(key, font) } }

        // After the page's content, which is closed in q…Q first so nothing it leaves set reaches the text.
        let contents = doc.array([doc.addStream(Array("q\n".utf8), deflate: false)])
        if let current = page["Contents"] {
            if current.isArray {
                for e in current.elements { contents.append(e) }
            } else if current.isStream {
                contents.append(current)
            }
        }
        contents.append(doc.addStream(Array("\nQ\n".utf8), deflate: false))
        contents.append(doc.addStream(Array(ops.utf8), deflate: true))
        page.set("Contents", contents)
        page.remove("Thumb")
    }

    /// The four corners (page points) of what covers the scan behind a line: its words' boxes and its new text's ink, a
    /// tenth of its size around.
    private static func cover(_ line: PlanLine, _ shaped: ShapedLine, _ font: TrueTypeFont, _ inks: Inks) -> [(x: Double, y: Double)] {
        let ink = inks.of(line.text, font)
        let pad = 0.1 * line.size
        let left = min(line.words.map(\.left).min() ?? line.left, line.left) - pad
        let right = max(line.right, line.left + shaped.width * line.size) + pad
        let top = min(line.top, line.baseline - ink.top * line.size) - pad
        let bottom = max(line.bottom, line.baseline - ink.bottom * line.size) + pad
        return [toPage(line.angle, left, top), toPage(line.angle, right, top), toPage(line.angle, right, bottom), toPage(line.angle, left, bottom)]
    }
}

/// Angles round the circle (the Windows app's `Angles`).
public enum Angles {
    /// `a` in (−180, 180].
    public static func wrap(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 360)
        return r <= -180 ? r + 360 : r > 180 ? r - 360 : r
    }

    /// `a` − `b` in (−180, 180]: 179.9° and −179.9° are 0.2° apart.
    public static func difference(_ a: Double, _ b: Double) -> Double { wrap(a - b) }
}
