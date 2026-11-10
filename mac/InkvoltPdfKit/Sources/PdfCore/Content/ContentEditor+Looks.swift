import Foundation

/// How a stretch of a paragraph looks where it differs from the paragraph's own (roadmap 2.1, part c; the Windows app's
/// `TextLook`): an installed font family ("Georgia"), its size on the page (points), its color (0xRRGGBB), bold, italic,
/// a subscript or superscript. Nil keeps the paragraph's own.
public struct TextLook: Sendable, Hashable {
    public var font: String?
    public var size: Double?
    public var color: Int?
    public var bold: Bool?
    public var italic: Bool?
    public var script: TextScript?

    public init(font: String? = nil, size: Double? = nil, color: Int? = nil, bold: Bool? = nil, italic: Bool? = nil, script: TextScript? = nil) {
        self.font = font
        self.size = size
        self.color = color
        self.bold = bold
        self.italic = italic
        self.script = script
    }

    public static let plain = TextLook()

    public var isPlain: Bool { font == nil && size == nil && color == nil && bold == nil && italic == nil && script == nil }

    /// This look with what `other` sets laid over it.
    public func with(_ other: TextLook) -> TextLook {
        TextLook(font: other.font ?? font, size: other.size ?? size, color: other.color ?? color, bold: other.bold ?? bold,
                 italic: other.italic ?? italic, script: other.script ?? script)
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

        static func read(_ props: CObj) -> LookTag {
            let font = props["Font"].flatMap { $0.kind == .string ? String(decoding: $0.bytes, as: UTF8.self) : nil }
            func flag(_ key: String) -> Bool? { props[key].flatMap { $0.kind == .bool ? $0.name == "true" : nil } }
            var script: TextScript?
            if let s = props["Script"], s.kind == .name { script = s.name == "Sub" ? .sub : s.name == "Super" ? .superscript : nil }
            return LookTag(font: font, bold: flag("Bold"), italic: flag("Italic"), script: script)
        }

        static func write(_ look: TextLook) -> String {
            var sb = "/\(lookTagName) <<"
            if let f = look.font { sb += " /Font " + ContentLexer.literal(Array(f.utf8)) }
            if let b = look.bold { sb += " /Bold " + (b ? "true" : "false") }
            if let i = look.italic { sb += " /Italic " + (i ? "true" : "false") }
            if let s = look.script { sb += " /Script " + (s == .sub ? "/Sub" : "/Super") }
            return sb + " >> BDC "
        }
    }

    /// A look resolved for writing: its size against the paragraph's (`scale`), its color (nil: the paragraph's), the
    /// installed font it is drawn in (nil: a page font), the look as asked (for the tag), the page's own font it is drawn
    /// in when the paragraph has that face (a bold word's font; nil: the paragraph's own), and how far its baseline sits
    /// above the line's (a superscript) or below (negative), in ems of the paragraph's text. Compared by identity, as
    /// stretches of one look are.
    final class PartLook {
        let scale: Double
        let color: Int?
        let face: StandInFont?
        let asked: TextLook
        let page: TextRun?
        let rise: Double

        init(_ scale: Double, _ color: Int?, _ face: StandInFont?, _ asked: TextLook, _ page: TextRun?, _ rise: Double) {
            (self.scale, self.color, self.face, self.asked, self.page, self.rise) = (scale, color, face, asked, page, rise)
        }
    }

    /// A subscript's or superscript's size against its line's text, and how far its baseline moves (ems of the line's
    /// text, up positive).
    static let scriptScale = 0.7, subRise = -0.15, superRise = 0.35

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
    /// says, at the size of the look it is in; spans of one look next to each other or a space apart merged.
    static func spansOf(_ lead: TextRun, _ text: [UInt16], _ at: [(run: TextRun, start: Int, length: Int)]) -> [TextSpan] {
        var spans: [TextSpan] = []
        for (r, start, length) in at where length > 0 {
            let drawn: Double = r.tag?.script != nil ? r.fontSize / scriptScale : r.fontSize
            let differs = abs(drawn - lead.fontSize) > max(0.3, 0.05 * lead.fontSize)
            let size: Double? = differs ? (drawn * 10).rounded() / 10 : nil
            let color: Int? = r.color != lead.color ? r.color : nil
            let look: TextLook
            if let tag = r.tag {
                look = TextLook(font: tag.font, size: size, color: color, bold: tag.bold, italic: tag.italic, script: tag.script)
            } else if !r.standIn && r.font != nil && !sameFamily(r, lead) {
                look = TextLook(font: FontNames.family(r.fontName), size: size, color: color, bold: r.bold != lead.bold ? r.bold : nil,
                                italic: r.italic != lead.italic ? r.italic : nil)
            } else if !r.standIn && r.font !== lead.font && (r.bold != lead.bold || r.italic != lead.italic) {
                look = TextLook(size: size, color: color, bold: r.bold != lead.bold ? r.bold : nil, italic: r.italic != lead.italic ? r.italic : nil)
            } else {
                continue
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

    /// A color as an RGB fill operator.
    static func rgbOp(_ color: Int) -> String {
        let r = ContentLexer.number(Double(color >> 16 & 0xFF) / 255)
        let g = ContentLexer.number(Double(color >> 8 & 0xFF) / 255)
        let b = ContentLexer.number(Double(color & 0xFF) / 255)
        return "\(r) \(g) \(b) rg "
    }
}
