import Foundation

/// How a stretch of a paragraph looks where it differs from the paragraph's own (roadmap 2.1, part c; the Windows app's
/// `TextLook`): an installed font family ("Georgia"), its size on the page (points), its color (0xRRGGBB), bold, italic,
/// a subscript or superscript, and a script's own rise (ems of the paragraph's text, up positive: a script the page set
/// at its own height; nil: the usual one). Nil keeps the paragraph's own.
public struct TextLook: Sendable, Hashable {
    public var font: String?
    public var size: Double?
    public var color: Int?
    public var bold: Bool?
    public var italic: Bool?
    public var script: TextScript?
    /// A script's baseline above the line's (below: negative), in ems of the paragraph's text; nil: the usual for a script
    /// (`ContentEditor.superRise`, `subRise`).
    public var rise: Double?
    /// Underlined by a rule the page draws under the words (a translated copy draws it again under their translation;
    /// the paragraph editor doesn't draw one).
    public var underline: Bool?

    public init(font: String? = nil, size: Double? = nil, color: Int? = nil, bold: Bool? = nil, italic: Bool? = nil, script: TextScript? = nil,
                rise: Double? = nil, underline: Bool? = nil) {
        self.font = font
        self.size = size
        self.color = color
        self.bold = bold
        self.italic = italic
        self.script = script
        self.rise = rise
        self.underline = underline
    }

    public static let plain = TextLook()

    public var isPlain: Bool {
        font == nil && size == nil && color == nil && bold == nil && italic == nil && script == nil && rise == nil && underline == nil
    }

    /// This look with what `other` sets laid over it.
    public func with(_ other: TextLook) -> TextLook {
        TextLook(font: other.font ?? font, size: other.size ?? size, color: other.color ?? color, bold: other.bold ?? bold,
                 italic: other.italic ?? italic, script: other.script ?? script, rise: other.rise ?? rise, underline: other.underline ?? underline)
    }
}

/// Text set below or above its line's baseline, smaller.
public enum TextScript: Sendable, Hashable { case sub, superscript }

/// A stretch of a paragraph's text (UTF-16 offsets into the text as written, line breaks as "\n") and its look.
public struct TextSpan: Sendable, Hashable {
    public var start: Int
    public var length: Int
    public var look: TextLook

    public init(_ start: Int, _ length: Int, _ look: TextLook) {
        self.start = start
        self.length = length
        self.look = look
    }

    public var end: Int { start + length }
}

extension ContentEditor {
    /// The installed font families a `TextLook` can name ("Arial", "Georgia", …).
    public static func lookFonts() -> [String] { StandInFonts.installed() }

    /// The marked-content tag a paragraph edit puts around text it gave a look of its own.
    static let lookTagName = "InkvoltLook"

    /// What the tag around styled text says: the font family, bold, italic and subscript or superscript that were asked
    /// for (size and color are read from the text: a script's size is `scriptScale` of its look's).
    struct LookTag: Sendable {
        var font: String?
        var bold: Bool?
        var italic: Bool?
        var script: TextScript?
        var rise: Double?

        static func read(_ props: CObj) -> LookTag {
            let font = props["Font"].flatMap { $0.kind == .string ? String(decoding: $0.bytes, as: UTF8.self) : nil }
            func flag(_ key: String) -> Bool? { props[key].flatMap { $0.kind == .bool ? $0.name == "true" : nil } }
            var script: TextScript?
            if let s = props["Script"], s.kind == .name { script = s.name == "Sub" ? .sub : s.name == "Super" ? .superscript : nil }
            // A script's own rise, held to what a script's can be (the tag is the page's: anything can be in it).
            var rise: Double?
            if let script, let n = props["Rise"], n.kind == .number, n.num.isFinite { rise = scriptRise(script, n.num) }
            return LookTag(font: font, bold: flag("Bold"), italic: flag("Italic"), script: script, rise: rise)
        }

        static func write(_ look: TextLook) -> String {
            var sb = "/\(lookTagName) <<"
            if let f = look.font { sb += " /Font " + ContentLexer.literal(Array(f.utf8)) }
            if let b = look.bold { sb += " /Bold " + (b ? "true" : "false") }
            if let i = look.italic { sb += " /Italic " + (i ? "true" : "false") }
            if let s = look.script { sb += " /Script " + (s == .sub ? "/Sub" : "/Super") }
            if look.script != nil, let rise = look.rise { sb += " /Rise " + ContentLexer.number(rise) }
            return sb + " >> BDC "
        }
    }

    /// A look resolved for writing: its size against the paragraph's (`scale`), its color (nil: the paragraph's), the
    /// installed font it is drawn in (nil: a page font), the look as asked (for the tag), the page's own font it is drawn
    /// in when the paragraph has that face (a bold word's font; nil: the paragraph's own), and how far its baseline sits
    /// above the line's (a superscript) or below (negative), in ems of the paragraph's text; `fill`: the page's own fill
    /// operators for `color` when its text has that color (nil: written as RGB). Compared by identity, as stretches of
    /// one look are.
    final class PartLook {
        let scale: Double
        let color: Int?
        let face: StandInFont?
        let asked: TextLook
        let page: TextRun?
        let rise: Double
        let fill: String?

        init(_ scale: Double, _ color: Int?, _ face: StandInFont?, _ asked: TextLook, _ page: TextRun?, _ rise: Double, fill: String? = nil) {
            (self.scale, self.color, self.face, self.asked, self.page, self.rise, self.fill) = (scale, color, face, asked, page, rise, fill)
        }
    }

    /// A subscript's or superscript's size against its line's text, and how far its baseline moves (ems of the line's
    /// text, up positive).
    static let scriptScale = 0.7, subRise = -0.15, superRise = 0.35

    /// A script's rise as read from a page or a tag, held to what a script's can be (ems, rounded to a hundredth).
    static func scriptRise(_ script: TextScript, _ rise: Double) -> Double {
        let held = script == .sub ? min(max(rise, -0.6), -0.08) : min(max(rise, 0.12), 0.9)
        return (held * 100).rounded(.toNearestOrEven) / 100
    }

    /// The look of each UTF-16 unit of `text` (nil: the paragraph's own), later spans over earlier ones.
    static func looksOf(_ text: [UInt16], _ spans: [TextSpan]?) -> [TextLook?] {
        var looks = [TextLook?](repeating: nil, count: text.count)
        guard let spans else { return looks }
        for s in spans {
            let lo = max(0, s.start), hi = min(text.count, s.end)
            if lo >= hi { continue }
            for i in lo..<hi { looks[i] = looks[i].map { $0.with(s.look) } ?? s.look }
        }
        return looks
    }

    /// The looks of a paragraph read back: each run an edit gave a look of its own, as a span over its text in `text`
    /// (where `at` says each run starts), its size and color as drawn, its font, bold and italic as its tag says; a run
    /// in another face of the paragraph's family (a bold word as the page's generator drew it) as bold or italic; a run in
    /// another family as that family (with bold or italic where its face differs); a subscript or superscript as its tag
    /// says, at the size of the look it is in; a run of the paragraph's own face in another size or color (a bigger or red
    /// word as the page drew it) as that size and color, a smaller one set off its line as the script `scripts` says (by
    /// run key); spans
    /// of one look next to each other or a space apart merged.
    static func spansOf(_ lead: TextRun, _ text: [UInt16], _ at: [(run: TextRun, start: Int, length: Int)],
                        _ scripts: [Int: (script: TextScript, size: Double, rise: Double)] = [:]) -> [TextSpan] {
        var spans: [TextSpan] = []
        for (r, start, length) in at where length > 0 {
            let drawn: Double = r.tag?.script != nil ? r.fontSize / scriptScale : r.fontSize
            let differs = abs(drawn - lead.fontSize) > max(0.3, 0.05 * lead.fontSize)
            let size: Double? = differs ? (drawn * 10).rounded() / 10 : nil
            let color: Int? = r.color != lead.color ? r.color : nil
            var look: TextLook
            if let tag = r.tag {
                look = TextLook(font: tag.font, size: size, color: color, bold: tag.bold, italic: tag.italic, script: tag.script, rise: tag.rise)
            } else if !r.standIn && r.font != nil && !sameFamily(r, lead) {
                look = TextLook(font: FontNames.family(r.fontName), size: size, color: color, bold: r.bold != lead.bold ? r.bold : nil,
                                italic: r.italic != lead.italic ? r.italic : nil)
            } else if !r.standIn && r.font !== lead.font && (r.bold != lead.bold || r.italic != lead.italic) {
                look = TextLook(size: size, color: color, bold: r.bold != lead.bold ? r.bold : nil, italic: r.italic != lead.italic ? r.italic : nil)
            } else if size != nil || color != nil {
                look = TextLook(size: size, color: color)
            } else {
                continue
            }
            if r.tag == nil, let s = scripts[r.key] {
                look.size = s.size
                look.script = s.script
                look.rise = s.rise
            }
            if look.isPlain { continue }
            if let last = spans.last, last.look == look, joinsAcrossSpace(last.end, start, { text[$0] }) {
                spans[spans.count - 1].length = start + length - last.start
            } else {
                spans.append(TextSpan(start, length, look))
            }
        }
        return spans
    }

    /// Whether a stretch starting at `start` carries on one ending at `end` of the same look: right after it, or with a
    /// space between ("brown fox"); not across a letter ("a²b³", "BoldxFace").
    static func joinsAcrossSpace(_ end: Int, _ start: Int, _ at: (Int) -> UInt16) -> Bool {
        start <= end || (start == end + 1 && at(end) == 32)
    }

    /// Spans of `old` carried over to `now` (text typed without looks): each character both texts share (their longest
    /// common subsequence) keeps its look, and a character typed inside a word takes the look of the one before it, as in
    /// a word processor.
    static func carry(_ oldText: String, _ nowText: String, _ spans: [TextSpan]) -> [TextSpan] {
        if spans.isEmpty { return [] }
        let old = Array(oldText.utf16), now = Array(nowText.utf16)
        if old == now { return spans }
        let map = charMap(old, now)
        let oldLooks = looksOf(old, spans)
        var looks = [TextLook?](repeating: nil, count: now.count)
        var mapped = [Bool](repeating: false, count: now.count)
        for i in 0..<old.count where map[i] >= 0 {
            looks[map[i]] = oldLooks[i]
            mapped[map[i]] = true
        }
        func white(_ u: UInt16) -> Bool { u == 32 || u == 10 || u == 13 || u == 9 || u == 0xA0 }
        if now.count > 1 {
            for i in 1..<now.count where !mapped[i] && !white(now[i]) && !white(now[i - 1]) { looks[i] = looks[i - 1] }
        }
        var result: [TextSpan] = []
        var i = 0
        while i < now.count {
            guard let look = looks[i], !look.isPlain else {
                i += 1
                continue
            }
            var j = i + 1
            while j < now.count && looks[j] == look { j += 1 }
            result.append(TextSpan(i, j - i, look))
            i = j
        }
        return result
    }

    /// A U+FFFC the page's own text has, kept as a character (`pictureMarks`).
    static let textMark = -2

    /// For each U+FFFC in `now`, in order: the paragraph's picture it stands for (its index in `pictures`, whose marks are
    /// where `InlinePicture.mark` says in `old`), `textMark` for one the page's own text had (a glyph whose text is
    /// U+FFFC), or -1 for one typed or pasted in. A mark kept from the old text keeps its picture; a picture's mark cut and
    /// pasted elsewhere (the text between can't keep both) is the next mark that came. `inserted`: places in `now` (UTF-16)
    /// of marks the editor put in for new pictures: -1, never a picture of the old text's.
    static func pictureMarks(_ oldText: String, _ nowText: String, _ pictures: [InlinePicture], inserted: Set<Int> = []) -> [Int] {
        let mark = TextParagraph.pictureMarkUnit
        let old = Array(oldText.utf16), now = Array(nowText.utf16)
        let marks = now.filter { $0 == mark }.count
        var result = [Int](repeating: -1, count: marks)
        if marks == 0 || !old.contains(mark) { return result }
        let map = charMap(old, now)
        var ordinal: [Int: Int] = [:] // a mark's place in now → its number among now's marks
        var insertedAt = Set<Int>() // the inserted marks' numbers among now's marks
        var k = 0
        for (i, u) in now.enumerated() where u == mark {
            if inserted.contains(i) { insertedAt.insert(k) } else { ordinal[i] = k }
            k += 1
        }
        var pictureAt: [Int: Int] = [:] // a picture's mark's place in old → the picture
        for (n, p) in pictures.enumerated() where p.mark >= 0 && p.mark < old.count && old[p.mark] == mark && pictureAt[p.mark] == nil {
            pictureAt[p.mark] = n
        }
        var used = [Bool](repeating: false, count: pictures.count)
        for i in 0..<old.count {
            guard old[i] == mark, map[i] >= 0, let at = ordinal[map[i]] else { continue }
            if let n = pictureAt[i] {
                result[at] = n
                used[n] = true
            } else {
                result[at] = textMark
            }
        }
        // A mark cut and pasted elsewhere (the text between can't keep both): the pictures whose marks went, in order.
        let owned = Set(pictureAt.values)
        var free = (0..<pictures.count).filter { !used[$0] && owned.contains($0) }[...]
        for i in 0..<marks where !free.isEmpty && result[i] == -1 && !insertedAt.contains(i) {
            result[i] = free.removeFirst()
        }
        return result
    }

    /// Where each character of `old` went in `now` (-1: gone): the characters both share (the same start and end, then
    /// their longest common subsequence in between, when it is small enough to work out).
    static func charMap(_ old: [UInt16], _ now: [UInt16]) -> [Int] {
        var map = [Int](repeating: -1, count: old.count) // where each old character went (-1: gone)
        var pre = 0
        while pre < old.count && pre < now.count && old[pre] == now[pre] {
            map[pre] = pre
            pre += 1
        }
        var suf = 0
        while suf < old.count - pre && suf < now.count - pre && old[old.count - 1 - suf] == now[now.count - 1 - suf] {
            map[old.count - 1 - suf] = now.count - 1 - suf
            suf += 1
        }
        let n = old.count - pre - suf, m = now.count - pre - suf
        if n > 0 && m > 0 && n * m <= 1_000_000 {
            // The middle: longest common subsequence, filled from the end so it can be walked forward.
            let w = m + 1
            var len = [Int32](repeating: 0, count: (n + 1) * w)
            for a in stride(from: n - 1, through: 0, by: -1) {
                for b in stride(from: m - 1, through: 0, by: -1) {
                    len[a * w + b] = old[pre + a] == now[pre + b] ? len[(a + 1) * w + b + 1] + 1 : max(len[(a + 1) * w + b], len[a * w + b + 1])
                }
            }
            var a = 0, b = 0
            while a < n && b < m {
                if old[pre + a] == now[pre + b] {
                    map[pre + a] = pre + b
                    a += 1
                    b += 1
                } else if len[(a + 1) * w + b] >= len[a * w + b + 1] {
                    a += 1
                } else {
                    b += 1
                }
            }
        }
        return map
    }

    /// A color as an RGB fill operator.
    static func rgbOp(_ color: Int) -> String {
        let r = ContentLexer.number(Double(color >> 16 & 0xFF) / 255)
        let g = ContentLexer.number(Double(color >> 8 & 0xFF) / 255)
        let b = ContentLexer.number(Double(color & 0xFF) / 255)
        return "\(r) \(g) \(b) rg "
    }
}
