import Foundation

/// A paragraph's looks as a translation request carries them (roadmap 3.1; the Windows app's `TranslationMarkup`): its
/// bold, italic, subscript and superscript stretches as <b>, <i>, <sub> and <sup> tags in the text, and the reply's tags
/// read back as looks. A model drops, moves and invents tags: a reply whose markup can't be trusted comes back plain, with
/// no tag left in its text. UTF-16 throughout, as the paragraph's spans are.
enum TranslationMarkup {
    /// The most stretches a paragraph's markup has: more goes plain (a crafted page, or a paragraph a model would garble).
    static let maxStretches = 64

    /// The most tags read from a reply before it is given up on as plain.
    private static let maxReplyTags = 4 * maxStretches * 2 + 16

    struct Kind: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let bold = Kind(rawValue: 1), italic = Kind(rawValue: 2), sub = Kind(rawValue: 4), sup = Kind(rawValue: 8)
        static let scripts: Kind = [.sub, .sup]
        static let faces: Kind = [.bold, .italic]
    }

    private static let names: [(kind: Kind, name: String)] = [(.bold, "b"), (.italic, "i"), (.sub, "sub"), (.sup, "sup")]

    private static func kindOf(_ look: TextLook?) -> Kind {
        guard let look else { return [] }
        var k: Kind = []
        if look.bold == true { k.insert(.bold) }
        if look.italic == true { k.insert(.italic) }
        if look.script == .sub { k.insert(.sub) } else if look.script == .superscript { k.insert(.sup) }
        return k
    }

    private static let lt: UInt16 = 60, gt: UInt16 = 62, slash: UInt16 = 47, space: UInt16 = 32

    /// Whether text can carry markup at all: angle brackets of its own would be read as tags.
    private static func markable(_ u: [UInt16]) -> Bool { !u.contains(lt) && !u.contains(gt) }

    /// `text` with its looks as tags, nested in one order (bold, italic, then sub or sup); the text as it is when it has
    /// none, has angle brackets of its own, or more than `maxStretches` stretches.
    static func mark(_ text: String, _ spans: [TextSpan]) -> String {
        let u = Array(text.utf16)
        if spans.isEmpty || spans.count > 4 * maxStretches || !markable(u) { return text }
        let kinds = kindsOf(u.count, spans)
        var out: [UInt16] = []
        out.reserveCapacity(u.count + 32)
        var open: [Kind] = []
        var stretches = 0
        var i = 0
        while i <= u.count {
            // A stretch of one look goes out whole: a crafted paragraph of millions of characters is copied, not walked.
            let to = i < u.count ? kinds.withUnsafeBufferPointer { k in
                var j = i + 1
                while j < k.count && k[j] == k[i] { j += 1 }
                return j
            } : i + 1
            defer { i = to }
            let want: Kind = i < u.count ? kinds[i] : []
            let wanted = ordered(want)
            var keep = 0
            while keep < open.count && keep < wanted.count && open[keep] == wanted[keep] { keep += 1 }
            var k = open.count - 1
            while k >= keep {
                out += Array("</\(nameOf(open[k]))>".utf16)
                k -= 1
            }
            open.removeSubrange(keep...)
            for w in wanted[keep...] {
                out += Array("<\(nameOf(w))>".utf16)
                open.append(w)
                stretches += 1
                if stretches > maxStretches { return text }
            }
            if i < u.count { out.append(contentsOf: u[i..<to]) }
        }
        return stretches == 0 ? text : String(decoding: out, as: UTF16.self)
    }

    /// Each character's looks: bold or italic where any span gives it; a later span's script replacing an earlier one's
    /// (as looks lay over each other), never sub and sup at once. Linear in the text and the spans, however they overlap.
    private static func kindsOf(_ length: Int, _ spans: [TextSpan]) -> [Kind] {
        var kinds = [Kind](repeating: [], count: length)
        var bold: [Int]?, italic: [Int]?, next: [Int]?
        func count(_ starts: inout [Int]?, _ from: Int, _ to: Int) {
            if starts == nil { starts = [Int](repeating: 0, count: length + 1) }
            starts![from] += 1
            starts![to] -= 1
        }
        var s = spans.count - 1
        while s >= 0 {
            defer { s -= 1 }
            let k = kindOf(spans[s].look)
            let from = max(0, spans[s].start), to = min(length, spans[s].end)
            if k.isEmpty || from >= to { continue }
            if k.contains(.bold) { count(&bold, from, to) }
            if k.contains(.italic) { count(&italic, from, to) }
            if k.intersection(.scripts).isEmpty { continue }
            // Latest span first: a character's script is the first one set; next[i] skips characters already set.
            if next == nil { next = Array(0...length) }
            let script = k.intersection(.scripts)
            kinds.withUnsafeMutableBufferPointer { kp in
                next!.withUnsafeMutableBufferPointer { np in
                    var i = unset(np, from)
                    while i < to {
                        kp[i] = script
                        np[i] = i + 1
                        i = unset(np, i)
                    }
                }
            }
        }
        if bold == nil && italic == nil { return kinds }
        kinds.withUnsafeMutableBufferPointer { k in
            for (starts, kind) in [(bold, Kind.bold), (italic, Kind.italic)] {
                guard let starts else { continue }
                starts.withUnsafeBufferPointer { s in
                    var depth = 0
                    for i in 0..<length {
                        depth += s[i]
                        if depth > 0 { k[i].formUnion(kind) }
                    }
                }
            }
        }
        return kinds
    }

    /// The first character at or after `i` with no script set yet (path halving).
    private static func unset(_ next: UnsafeMutableBufferPointer<Int>, _ start: Int) -> Int {
        var i = start
        while next[i] != i {
            next[i] = next[next[i]]
            i = next[i]
        }
        return i
    }

    private static func ordered(_ k: Kind) -> [Kind] { names.filter { k.contains($0.kind) }.map(\.kind) }

    private static func nameOf(_ k: Kind) -> String { names.first { $0.kind == k }!.name }

    /// The text of marked text with its tags taken out (what goes to a model when the markup can't go whole).
    static func plain(_ marked: String) -> String { stripped(marked) }

    /// Whether `answer` to a paragraph's `text` (sent as `sent`, its markup if it had looks) is the text itself: the
    /// markup echoed, or the plain text, or the markup with tags dropped.
    static func echoes(_ answer: String, _ text: String, _ sent: String) -> Bool {
        if answer == sent || answer == text { return true }
        return sent != text && collapsed(stripped(answer)) == collapsed(text)
    }

    private static func collapsed(_ s: String) -> String { TranslationText.collapse(s) }

    /// A reply with every tag but ours taken out (for text sent with markup).
    static func withoutOtherTags(_ reply: String) -> String {
        anyTag.replace(reply) { isOurs(Array($0.utf16)) ? $0 : "" }
    }

    /// Whether a whole tag ("<b>", "</SUB>") is one of ours.
    private static func isOurs(_ tag: [UInt16]) -> Bool {
        tag.count >= 3 && tag[0] == lt && tag[tag.count - 1] == gt && !kindNamed(Array(tag[1..<(tag.count - 1)])).isEmpty
    }

    /// The look a tag's name (with or without its closing slash) stands for; none when it isn't ours.
    private static func kindNamed(_ name: [UInt16]) -> Kind {
        let n = name.first == slash ? Array(name.dropFirst()) : name
        let s = String(decoding: n, as: UTF16.self).lowercased()
        return names.first { $0.name == s }?.kind ?? []
    }

    /// A reply to the paragraph `text` with looks `spans`: its text and its looks. The markup is trusted when its tags are
    /// ours and balanced, nest properly (no tag inside itself, no sub and sup together), name only looks the paragraph
    /// had, and cover about as much as they did (a stretch at most twice as long as the paragraph's longest of that look
    /// and a little more, at most twice its share of the text and a little more); a tag dropped only leaves its words
    /// plain. Otherwise the reply comes back plain, every tag and fragment of one taken out. Text with angle brackets of
    /// its own was sent as it is and comes back as it is. Linear in the reply's length.
    static func read(_ answer: String, _ text: String, _ spans: [TextSpan]) -> (text: String, spans: [TextSpan]) {
        if !markable(Array(text.utf16)) { return (answer, []) }
        if markable(Array(answer.utf16)) { return (answer, []) }
        let marked = mark(text, spans)
        guard let source = parse(marked), let reply = parse(answer), trusted(source, reply) else { return (stripped(answer), []) }
        // Each combination of looks back as a look: the family the paragraph had it in, if any.
        var families: [Kind: String] = [:]
        for s in spans {
            if let f = s.look.font, families[kindOf(s.look).intersection(.faces)] == nil { families[kindOf(s.look).intersection(.faces)] = f }
        }
        var result: [TextSpan] = []
        let kinds = reply.kinds
        var i = 0
        while i < kinds.count {
            let k = kinds[i]
            var j = i + 1
            while j < kinds.count && kinds[j] == k { j += 1 }
            if !k.isEmpty {
                let script: TextScript? = k.contains(.sub) ? .sub : k.contains(.sup) ? .superscript : nil
                let look = TextLook(font: families[k.intersection(.faces)], bold: k.contains(.bold) ? true : nil,
                                    italic: k.contains(.italic) ? true : nil, script: script)
                result.append(TextSpan(i, j - i, look))
            }
            i = j
        }
        return (reply.text, result)
    }

    /// Text read from markup: its characters (spaces collapsed, ends trimmed), each one's looks, and per look its
    /// stretches' lengths (not counting spaces).
    private struct Parsed {
        var text: String
        var kinds: [Kind]
        var stretches: [Kind: [Int]]
        var letters: Int
        var opened: Kind
    }

    /// Whether '<' followed by `next` opens a tag ("<b", "</", "<!--"), not a bare bracket ("a < b", "<-").
    private static func opensTag(_ next: UInt16) -> Bool {
        (next >= 65 && next <= 90) || (next >= 97 && next <= 122) || next == slash || next == 33 || next == 63
    }

    private static func isWhite(_ u: UInt16) -> Bool { Unicode.Scalar(u)?.properties.isWhitespace ?? false }

    /// Markup read in one pass; nil when it isn't well formed (another tag, one unclosed or crossed, a tag inside itself,
    /// sub and sup together, a piece of one of ours). A bare '<' or '>' ("->", "a < b") is text.
    private static func parse(_ string: String) -> Parsed? {
        if brokenEnd.isMatch(string) { return nil }
        let s = Array(string.utf16)
        var text: [UInt16] = []
        text.reserveCapacity(s.count)
        var kinds: [Kind] = []
        kinds.reserveCapacity(s.count)
        var stack: [(kind: Kind, letters: Int)] = []
        var stretches: [Kind: [Int]] = [:]
        var cur: Kind = [], opened: Kind = []
        var tags = 0, letters = 0
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == lt && i + 1 < s.count && opensTag(s[i + 1]) {
                let limit = min(i + 1 + min(6, s.count - i - 1), s.count)
                guard let end = (i + 1..<limit).first(where: { s[$0] == gt }) else { return nil }
                let name = Array(s[(i + 1)..<end])
                let closing = name.first == slash
                let kind = kindNamed(name)
                tags += 1
                if kind.isEmpty || tags > maxReplyTags { return nil }
                if !closing {
                    if !cur.intersection(kind).isEmpty || stack.count >= 3
                        || (!kind.intersection(.scripts).isEmpty && !cur.intersection(.scripts).isEmpty) { return nil }
                    stack.append((kind, letters))
                    cur.formUnion(kind)
                    opened.formUnion(kind)
                } else {
                    guard let top = stack.last, top.kind == kind else { return nil }
                    let length = letters - top.letters
                    stack.removeLast()
                    cur.subtract(kind)
                    if length > 0 { stretches[kind, default: []].append(length) }
                }
                i = end + 1
                continue
            }
            if isWhite(c) {
                // One space between words, whatever tags stand between them; none at the start.
                if let last = text.last, last != space {
                    text.append(space)
                    kinds.append(cur)
                }
            } else {
                text.append(c)
                kinds.append(cur)
                letters += 1
            }
            i += 1
        }
        if !stack.isEmpty { return nil }
        while text.last == space {
            text.removeLast()
            kinds.removeLast()
        }
        return Parsed(text: String(decoding: text, as: UTF16.self), kinds: kinds, stretches: stretches, letters: letters, opened: opened)
    }

    /// Whether a reply's markup says about what the source's did (see `read`).
    private static func trusted(_ source: Parsed, _ reply: Parsed) -> Bool {
        if !reply.opened.subtracting(source.opened).isEmpty { return false } // a look the paragraph didn't have, even around nothing
        for (kind, lengths) in reply.stretches {
            guard let had = source.stretches[kind], let hadMax = had.max(), let most = lengths.max() else { return false }
            if lengths.count > 2 * had.count + 1 { return false }
            let script = kind == .sub || kind == .sup
            if most > 2 * hadMax + (script ? 4 : 12) { return false }
            let share = Double(had.reduce(0, +)) / Double(max(1, source.letters))
            let now = Double(lengths.reduce(0, +)) / Double(max(1, reply.letters))
            if now > 2 * share + 0.1 { return false }
        }
        return true
    }

    /// A reply with every tag, and every piece of one of ours, taken out; then any '<' left that opens a tag; spaces
    /// collapsed. A bare '<' or '>' ("->", "a < b") stays.
    private static func stripped(_ reply: String) -> String {
        var s = anyTag.replace(reply, "")
        s = tagPiece.replace(s, "")
        s = tagOpening.replace(s, "")
        return collapsed(s)
    }

    private static let anyTag = Rx(#"</?[A-Za-z][^<>]{0,60}>|<[!?][^<>]{0,60}>"#)

    // What is left of one of ours cut short or garbled: "<b", "</sub", "< sup>", "/b>", "/SUB >", "sup>", " i>". A lone
    // letter's '>' counts only when it touches the letter and no number or '=' follows: "i > 0", "b >= a", "i>0" are text.
    private static let tagPiece = Rx(#"<\s*/?\s*(?:b|i|sub|sup)\b(?:\s*>)?|/\s*(?:b|i|sub|sup)\s*>|(?<![\p{L}\p{N}])(?:b|i|sub|sup)>(?![\p{N}=])"#,
                                     ignoreCase: true)

    // The end of one of ours whose '<' is gone ("negrita/b>", "x /sub>", "word i>"); a whole tag ("<b>", "</b>") isn't
    // one, nor a comparison ("i > 0", "b >= a", "i>0").
    private static let brokenEnd = Rx(#"(?<!<)/\s*(?:b|i|sub|sup)\s*>|(?<![\p{L}\p{N}</])(?:b|i|sub|sup)>(?![\p{N}=])"#, ignoreCase: true)

    // A '<' that opens a tag never closed ("<span", "</").
    private static let tagOpening = Rx(#"<(?=[A-Za-z/!?])"#)
}

/// A regular expression over a string's UTF-16 (as .NET's are), compiled once.
struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false, dotAll: Bool = false) {
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        re = try! NSRegularExpression(pattern: pattern, options: options) // swiftlint:disable:this force_try
    }

    func isMatch(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Every match replaced by `template` ($1 for a group).
    func replace(_ s: String, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    /// Every match replaced by what `with` makes of it.
    func replace(_ s: String, _ with: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var at = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += with(ns.substring(with: m.range))
            at = m.range.location + m.range.length
        }
        out += ns.substring(from: at)
        return out
    }

    /// The pieces between matches.
    func split(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var at = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            at = m.range.location + m.range.length
        }
        out.append(ns.substring(from: at))
        return out
    }
}
