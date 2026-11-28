import Foundation

/// A paragraph's looks as a translation request carries them (roadmap 3.1; the Windows app's `TranslationMarkup`): its
/// bold, italic, underlined, subscript and superscript stretches as <b>, <i>, <u>, <sub> and <sup> tags in the text, a
/// stretch in another color or class of font as <span> (a second and a third such look as <font> and <mark>), and the
/// reply's tags read back as looks. A model drops, moves and invents tags: a reply whose markup can't be trusted comes
/// back plain, with no tag left in its text. UTF-16 throughout, as the paragraph's spans are.
enum TranslationMarkup {
    /// The most stretches a paragraph's markup has: past it only its scripts are marked, and past that it goes plain (a
    /// crafted page, or a paragraph a model would garble).
    static let maxStretches = 64

    /// The most tags read from a reply before it is given up on as plain.
    private static let maxReplyTags = 4 * maxStretches * 2 + 16

    /// The deepest tags nest: bold, italic, underline, another look, then a script.
    private static let maxDepth = 5

    /// What a stretch has besides its paragraph's own look. `other`, `other2` and `other3` are a paragraph's first, second
    /// and third other looks (`otherOf`: a red word, a word in Courier), as <span>, <font> and <mark>; a character has one
    /// of them at most.
    struct Kind: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let bold = Kind(rawValue: 1), italic = Kind(rawValue: 2), other = Kind(rawValue: 4), sub = Kind(rawValue: 8)
        static let sup = Kind(rawValue: 16), underline = Kind(rawValue: 32), other2 = Kind(rawValue: 64), other3 = Kind(rawValue: 128)
        static let scripts: Kind = [.sub, .sup]
        static let faces: Kind = [.bold, .italic]
        static let others: Kind = [.other, .other2, .other3]
    }

    /// The other looks a paragraph's markup tells apart, in the order of `other`, `other2`, `other3`.
    private static let otherKinds: [Kind] = [.other, .other2, .other3]

    private static let names: [(kind: Kind, name: String)] =
        [(.bold, "b"), (.italic, "i"), (.underline, "u"), (.other, "span"), (.other2, "font"), (.other3, "mark"), (.sub, "sub"), (.sup, "sup")]

    /// A look's family and color where neither bold nor italic explains them.
    struct OtherLook: Hashable {
        var font: String?
        var color: Int?
    }

    /// What a look sets apart from the paragraph's own: bold or italic either way (a bold word, or a regular one in a bold
    /// paragraph), underlined, another look (`otherOf`; which of the paragraph's is told by `othersOf`), a script.
    private static func kindOf(_ look: TextLook?) -> Kind {
        guard let look else { return [] }
        var k: Kind = []
        if look.bold != nil { k.insert(.bold) }
        if look.italic != nil { k.insert(.italic) }
        if look.underline == true { k.insert(.underline) }
        if otherOf(look) != nil { k.insert(.other) }
        if look.script == .sub { k.insert(.sub) } else if look.script == .superscript { k.insert(.sup) }
        return k
    }

    /// A look's family and color where neither bold nor italic explains them (a name in Times among Arial, a red word);
    /// nil when it has neither.
    private static func otherOf(_ look: TextLook) -> OtherLook? {
        let font = look.bold == nil && look.italic == nil ? look.font : nil
        return font == nil && look.color == nil ? nil : OtherLook(font: font, color: look.color)
    }

    private static let lt: UInt16 = 60, gt: UInt16 = 62, slash: UInt16 = 47, space: UInt16 = 32

    private static func hasBrackets(_ u: [UInt16]) -> Bool { u.contains(lt) || u.contains(gt) }

    /// Whether text can carry markup: its own angle brackets, if any, read as text whatever happens to the reply ("a < b",
    /// "->", "p<0.05"); not when one would be read as a tag or a piece of one ("<html>", "x<y", "b>").
    private static func markable(_ text: String) -> Bool {
        let u = Array(text.utf16)
        if !hasBrackets(u) { return true }
        if u.count > 1 {
            for i in 0..<(u.count - 1) where u[i] == lt && opensTag(u[i + 1]) { return false }
        }
        return !brokenEnd.isMatch(text) && !tagPiece.isMatch(text) && stripped(text) == collapsed(text)
    }

    /// `text` with its looks as tags, nested in one order (bold, italic, underline, another look, then sub or sup); the
    /// text as it is when it has none or can't carry them (`markable`), only its scripts when it has more than
    /// `maxStretches` stretches, plain when even those are more.
    static func mark(_ text: String, _ spans: [TextSpan]) -> String { marking(text, spans).marked }

    /// The markup `mark` writes, and the looks it marked (`kept`, or only the scripts of them).
    private static func marking(_ text: String, _ spans: [TextSpan]) -> (marked: String, kept: [TextSpan]) {
        if spans.isEmpty || spans.count > 4 * maxStretches || !markable(text) { return (text, []) }
        let u = Array(text.utf16)
        var kept = keptOf(spans)
        var marked = write(text, u, kept)
        if marked == nil {
            // Too many looks: the scripts alone ("x_1", "10^3": they change what the text says), else none.
            kept = kept.filter { $0.look.script != nil }.map {
                TextSpan($0.start, $0.length, TextLook(size: $0.look.size, script: $0.look.script, rise: $0.look.rise))
            }
            marked = write(text, u, kept)
        }
        guard let marked, marked != text else { return (text, []) }
        return (marked, kept)
    }

    /// The looks a paragraph's markup carries: in a bold (italic) paragraph, its regular stretches (a bold word's "bold"
    /// says nothing there); of its stretches in another color or class of font, those of its first three such looks (one
    /// tag each, `otherKinds`), any further one keeping only its bold, italic, underline or script.
    private static func keptOf(_ spans: [TextSpan]) -> [TextSpan] {
        let boldOff = spans.contains { $0.look.bold == false }, italicOff = spans.contains { $0.look.italic == false }
        var others: [OtherLook] = []
        var kept: [TextSpan] = []
        kept.reserveCapacity(spans.count)
        for s in spans {
            var look = s.look
            // (A family it had went with that face: it isn't another look of its own.)
            if look.bold == true && boldOff {
                look.bold = nil
                if look.italic == nil { look.font = nil }
            }
            if look.italic == true && italicOff {
                look.italic = nil
                if look.bold == nil { look.font = nil }
            }
            if let o = otherOf(look), !others.contains(o) {
                if others.count < otherKinds.count {
                    others.append(o)
                } else {
                    look.color = nil
                    if look.bold == nil && look.italic == nil { look.font = nil }
                }
            }
            if !kindOf(look).isEmpty { kept.append(TextSpan(s.start, s.length, look)) }
        }
        return kept
    }

    /// The other looks of kept stretches (`keptOf`), in the order they first come: the n-th is marked as `otherKinds`' n-th.
    private static func othersOf(_ kept: [TextSpan]) -> [OtherLook] {
        var others: [OtherLook] = []
        for s in kept {
            if let o = otherOf(s.look), !others.contains(o), others.count < otherKinds.count { others.append(o) }
        }
        return others
    }

    /// A kept look's kinds, its other look told apart among the paragraph's (`others`).
    private static func kindOf(_ look: TextLook, _ others: [OtherLook]) -> Kind {
        var k = kindOf(look)
        if !k.contains(.other) { return k }
        k.remove(.other)
        if let o = otherOf(look), let at = others.firstIndex(of: o) { k.insert(otherKinds[at]) }
        return k
    }

    /// The looks set the other way round: bold (italic) where the paragraph's own text is, its regular stretches being
    /// the ones its spans name.
    private static func inverted(_ kept: [TextSpan]) -> Kind {
        var k: Kind = []
        if kept.contains(where: { $0.look.bold == false }) { k.insert(.bold) }
        if kept.contains(where: { $0.look.italic == false }) { k.insert(.italic) }
        return k
    }

    /// The text with the looks as tags; nil past `maxStretches` stretches.
    private static func write(_ text: String, _ u: [UInt16], _ kept: [TextSpan]) -> String? {
        if kept.isEmpty { return text }
        let kinds = kindsOf(u.count, kept, inverted(kept))
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
                if stretches > maxStretches { return nil }
            }
            if i < u.count { out.append(contentsOf: u[i..<to]) }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Each character's tags: bold, italic or underline where any span gives it (where none does, for a look `inverted`);
    /// a later span's script, or other look, replacing an earlier one's (as looks lay over each other), never sub and sup
    /// at once nor two other looks. Linear in the text and the spans, however they overlap (a crafted page's 256 spans
    /// over a paragraph of millions of characters).
    private static func kindsOf(_ length: Int, _ spans: [TextSpan], _ inverted: Kind) -> [Kind] {
        var kinds = [Kind](repeating: [], count: length)
        let others = othersOf(spans)
        var bold: [Int]?, italic: [Int]?, under: [Int]?, nextScript: [Int]?, nextOther: [Int]?
        func count(_ starts: inout [Int]?, _ from: Int, _ to: Int) {
            if starts == nil { starts = [Int](repeating: 0, count: length + 1) }
            starts![from] += 1
            starts![to] -= 1
        }
        // Latest span first: a character's script (other look) is the first one set; next[i] skips characters already set.
        func latest(_ next: inout [Int]?, _ kind: Kind, _ from: Int, _ to: Int) {
            if next == nil { next = Array(0...length) }
            kinds.withUnsafeMutableBufferPointer { kp in
                next!.withUnsafeMutableBufferPointer { np in
                    var i = unset(np, from)
                    while i < to {
                        kp[i].formUnion(kind)
                        np[i] = i + 1
                        i = unset(np, i)
                    }
                }
            }
        }
        var s = spans.count - 1
        while s >= 0 {
            defer { s -= 1 }
            let k = kindOf(spans[s].look, others)
            let from = max(0, spans[s].start), to = min(length, spans[s].end)
            if k.isEmpty || from >= to { continue }
            if k.contains(.bold) { count(&bold, from, to) }
            if k.contains(.italic) { count(&italic, from, to) }
            if k.contains(.underline) { count(&under, from, to) }
            if !k.intersection(.scripts).isEmpty { latest(&nextScript, k.intersection(.scripts), from, to) }
            if !k.intersection(.others).isEmpty { latest(&nextOther, k.intersection(.others), from, to) }
        }
        if bold == nil && italic == nil && under == nil && inverted.isEmpty { return kinds }
        kinds.withUnsafeMutableBufferPointer { k in
            for (starts, kind) in [(bold, Kind.bold), (italic, Kind.italic), (under, Kind.underline)] {
                let flip = inverted.contains(kind)
                guard let starts else {
                    if flip { for i in 0..<length { k[i].formUnion(kind) } }
                    continue
                }
                starts.withUnsafeBufferPointer { s in
                    var depth = 0
                    for i in 0..<length {
                        depth += s[i]
                        if (depth > 0) != flip { k[i].formUnion(kind) }
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

    /// Marked text in pieces of at most about `maxTokens` tokens (`AiText.pieces`), each with its tags closed at its end and
    /// opened again at the next one's start, so each piece is markup of its own and the answers joined are markup for the
    /// whole. Nil when a cut falls inside a tag.
    static func pieces(_ marked: String, _ maxTokens: Int) -> [String]? {
        let pieces = AiText.pieces(marked, maxTokens)
        if pieces.count <= 1 { return pieces }
        var open: [Kind] = []
        var result: [String] = []
        for piece in pieces {
            var sb = ""
            for k in open { sb += "<\(nameOf(k))>" }
            sb += piece
            let p = Array(piece.utf16)
            var i = 0
            while i < p.count {
                defer { i += 1 }
                if p[i] != lt || i + 1 >= p.count || !opensTag(p[i + 1]) { continue }
                let limit = min(i + 1 + min(6, p.count - i - 1), p.count)
                guard let end = (i + 1..<limit).first(where: { p[$0] == gt }) else { return nil }
                let name = Array(p[(i + 1)..<end])
                let kind = kindNamed(name)
                if kind.isEmpty { return nil }
                if name.first != slash {
                    open.append(kind)
                } else if open.last == kind {
                    open.removeLast()
                } else {
                    return nil
                }
                i = end
            }
            for k in open.reversed() { sb += "</\(nameOf(k))>" }
            result.append(sb)
        }
        return open.isEmpty ? result : nil
    }

    /// Whether `answer` to a paragraph's `text` (sent as `sent`, its markup if it had looks) is the text itself: the
    /// markup echoed, or the plain text, or the markup with tags dropped.
    static func echoes(_ answer: String, _ text: String, _ sent: String) -> Bool {
        if answer == sent || answer == text { return true }
        return sent != text && collapsed(stripped(answer)) == collapsed(text)
    }

    private static func collapsed(_ s: String) -> String { TranslationText.collapse(s) }

    /// A reply with every tag taken out but ours of the looks `sent` (the marked text) has; a model's own name for one of
    /// them ("<bold>", "<strong>", "<em>": a real model wrote them for <b> and <i>) read as ours.
    static func withoutOtherTags(_ reply: String, _ sent: String) -> String {
        var had: Kind = []
        anyTag.each(sent) { m, ns in
            let tag = Array(ns.substring(with: m.range).utf16)
            if isOurs(tag) { had.formUnion(kindNamed(Array(tag[1..<(tag.count - 1)]))) }
        }
        var reply = reply
        if !had.intersection(.faces).isEmpty {
            reply = synonym.replaceMatches(reply) { m, ns in
                let name = ns.substring(with: m.range(at: 2)).lowercased()
                let bold = name == "bold" || name == "strong" || name == "bf"
                if !had.contains(bold ? .bold : .italic) { return ns.substring(with: m.range) }
                return (m.range(at: 1).location != NSNotFound ? "</" : "<") + (bold ? "b" : "i") + ">"
            }
        }
        return anyTag.replaceMatches(reply) { m, ns in
            let tag = Array(ns.substring(with: m.range).utf16)
            if isOurs(tag) && !kindNamed(Array(tag[1..<(tag.count - 1)])).intersection(had).isEmpty { return ns.substring(with: m.range) }
            return unwrapped(ns, m)
        }
    }

    private static let synonym = Rx("<(/)?(bold|strong|bf|em|italic)>", ignoreCase: true)

    /// What a bracketed stretch of a reply that isn't kept as one of our tags leaves: nothing when it is shaped as a tag
    /// ("<br/>", "<font color="#00F">", "<bold>"), its words when it isn't ("<Décodage :>", "<Aidan N. Gomez>": how a real
    /// model marked a label or a name it was sent in bold, which taking out as a tag lost). Its words keep a space from a
    /// letter or digit right beside it ("Voir<Annexe A>," reads "Voir Annexe A,"), and none from anything else. `input`
    /// is the text `m` was found in.
    static func unwrapped(_ input: NSString, _ m: NSTextCheckingResult) -> String {
        let bracketed = input.substring(with: m.range)
        let b = Array(bracketed.utf16)
        if b.count < 3 || b[1] == 33 || b[1] == 63 { return "" }
        // The usual tag, a name alone ("<b>", "</bold>"), without a regex: a crafted reply has hundreds of thousands.
        let closing = b[1] == slash
        let name = b[(closing ? 2 : 1)..<(b.count - 1)]
        if !name.isEmpty && name.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }) { return "" }
        if tagShaped.isMatch(bracketed) { return "" }
        let before = m.range.location - 1, after = m.range.location + m.range.length
        let left = before >= 0 && isLetterOrDigit(input.character(at: before)) ? " " : ""
        let right = after < input.length && isLetterOrDigit(input.character(at: after)) ? " " : ""
        var inner = Array(b[1..<(b.count - 1)])
        while inner.first == slash { inner.removeFirst() }
        return left + TranslationText.trim(String(decoding: inner, as: UTF16.self)) + right
    }

    /// .NET's `char.IsLetterOrDigit` on one UTF-16 unit (a surrogate is neither).
    private static func isLetterOrDigit(_ u: UInt16) -> Bool {
        guard let s = Unicode.Scalar(u) else { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
        default: return false
        }
    }

    // A tag's shape: a name of ASCII letters and digits, then nothing or attributes with '=', an optional '/'.
    private static let tagShaped = Rx(#"^</?[A-Za-z][A-Za-z0-9]*(?:\s+[A-Za-z_:][^<>=]*=[^<>]*)?\s*/?>$"#)

    /// Whether a whole tag ("<b>", "</SUB>") is one of ours.
    private static func isOurs(_ tag: [UInt16]) -> Bool {
        tag.count >= 3 && tag[0] == lt && tag[tag.count - 1] == gt && !kindNamed(Array(tag[1..<(tag.count - 1)])).isEmpty
    }

    /// The look a tag's name (with or without its closing slash) stands for; none when it isn't ours.
    private static func kindNamed(_ name: [UInt16]) -> Kind {
        let n = name.first == slash ? Array(name.dropFirst()) : name
        if n.isEmpty || n.count > 4 { return [] }
        let s = String(decoding: n, as: UTF16.self).lowercased()
        return names.first { $0.name == s }?.kind ?? []
    }

    /// A reply to the paragraph `text` with looks `spans`: its text and its looks. The markup is trusted when its tags are
    /// ours and balanced, nest properly (no tag inside itself, no sub and sup together), name only looks the paragraph
    /// had, and cover about as much as they did (a stretch at most twice as long as the paragraph's longest of that look
    /// and a little more, at most twice its share of the text and a little more; a look the paragraph had nearly
    /// everywhere, its bold around a regular word, at least about half its share); a tag dropped only leaves its words
    /// plain. Otherwise the reply comes back plain, every tag and fragment of one taken out. Text with angle brackets of
    /// its own that could be read as tags was sent as it is and comes back as it is. Linear in the reply's length.
    static func read(_ answer: String, _ text: String, _ spans: [TextSpan]) -> (text: String, spans: [TextSpan]) {
        let judged = judge(answer, text, spans)
        if let plain = judged.plain { return (plain, []) }
        let reply = judged.reply!, kept = judged.kept, inverted = judged.inverted
        // What each look was on the page: the family of its face, each other look's family and color; each script
        // stretch's size and rise, in order (a footnote mark and an exponent in one paragraph keep their own).
        var faces: [Kind: String] = [:]
        let others = othersOf(kept)
        var scripts: [Kind: [(size: Double?, rise: Double?)]] = [:]
        var last: TextSpan?
        for s in kept.filter({ $0.look.script != nil }).enumerated().sorted(by: { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }).map(\.element) {
            // One stretch however many runs drew it: a span right after one of the same look goes on it.
            if last == nil || last!.look != s.look || s.start > last!.end {
                scripts[kindOf(s.look).intersection(.scripts), default: []].append((s.look.size, s.look.rise))
            }
            last = s
        }
        for s in kept {
            let k = kindOf(s.look)
            if !k.intersection(.faces).isEmpty, let f = s.look.font, faces[k.intersection(.faces)] == nil { faces[k.intersection(.faces)] = f }
        }
        var result: [TextSpan] = []
        let kinds = reply.kinds
        var seen: [Kind: Int] = [:] // script stretches of each kind met so far in the reply
        var previous: Kind = []
        var i = 0
        while i < kinds.count {
            let k = kinds[i]
            var j = i + 1
            while j < kinds.count && kinds[j] == k { j += 1 }
            let rel = k.symmetricDifference(inverted) // against the paragraph's own: in a bold paragraph, no <b> is a regular word
            let script = k.intersection(.scripts)
            if !script.isEmpty && previous.intersection(script).isEmpty { seen[script, default: 0] += 1 }
            previous = k
            if !rel.isEmpty {
                // The reply's n-th stretch of a script takes the source's n-th (its last when the reply has more).
                var size: Double?, rise: Double?
                if let looks = scripts[script], !looks.isEmpty { (size, rise) = looks[min(seen[script] ?? 1, looks.count) - 1] }
                let mine: OtherLook? = otherKinds.firstIndex(of: rel.intersection(.others)).flatMap { $0 < others.count ? others[$0] : nil }
                result.append(TextSpan(i, j - i, TextLook(
                    font: faces[rel.intersection(.faces)] ?? mine?.font,
                    size: size,
                    color: mine?.color,
                    bold: rel.contains(.bold) ? !inverted.contains(.bold) : nil,
                    italic: rel.contains(.italic) ? !inverted.contains(.italic) : nil,
                    script: k.contains(.sub) ? .sub : k.contains(.sup) ? .superscript : nil,
                    rise: rise,
                    underline: rel.contains(.underline) ? true : nil)))
            }
            i = j
        }
        return (reply.text, result)
    }

    /// What `read` makes of a reply, before its looks are rebuilt: the reply as plain text when its markup is not used
    /// (nil when it is), the reply's markup read, the looks marked and which are inverted.
    private static func judge(_ answer: String, _ text: String, _ spans: [TextSpan]) -> (plain: String?, reply: Parsed?, kept: [TextSpan], inverted: Kind) {
        if !markable(text) { return (answer, nil, [], []) }
        let (marked, kept) = marking(text, spans)
        let inverted = inverted(kept)
        if !hasBrackets(Array(answer.utf16)) { return (answer, nil, kept, inverted) }
        guard let source = parse(marked), let reply = parse(answer) else { return (stripped(answer), nil, kept, inverted) }
        if !trusted(source, reply, inverted) { return (stripped(answer), reply, kept, inverted) }
        return (nil, reply, kept, inverted)
    }

    /// The tags marked text has, as a request names them ("<b> (bold) and <sub> (subscript)"), in one order; empty when it
    /// has none.
    static func tagsNamed(_ marked: String) -> String {
        var had: Kind = []
        tagNames.each(marked) { m, ns in had.formUnion(kindNamed(Array(ns.substring(with: m.range(at: 1)).utf16))) }
        var parts: [String] = []
        for (kind, _) in names where had.contains(kind) {
            if !kind.intersection(.others).isEmpty {
                // The other looks once, together, where the first of them nests.
                if kind != otherKinds.first(where: { had.contains($0) }) { continue }
                let others = otherKinds.filter { had.contains($0) }.map { "<\(nameOf($0))>" }
                parts.append(others.count == 1 ? "\(others[0]) (another font or color)" : "\(others.joined(separator: ", ")) (each another font or color)")
                continue
            }
            switch kind {
            case .bold: parts.append("<b> (bold)")
            case .italic: parts.append("<i> (italic)")
            case .underline: parts.append("<u> (underlined)")
            case .sub: parts.append("<sub> (subscript)")
            default: parts.append("<sup> (superscript)")
            }
        }
        return parts.count <= 1 ? parts.joined() : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    /// The answers to a marked text's pieces (`pieces`) joined into one, the tags a seam closed and opened again
    /// ("</b> <b>") taken out, so a stretch cut by a seam is one stretch again.
    static func join(_ parts: [String]) -> String {
        seam.replaceMatches(parts.joined(separator: " ")) { m, ns in
            func names(_ s: String) -> [String] {
                var out: [String] = []
                tagNames.each(s) { t, tns in out.append(tns.substring(with: t.range(at: 1)).lowercased()) }
                return out
            }
            let closed = names(ns.substring(with: m.range(at: 1))).reversed()
            let opened = names(ns.substring(with: m.range(at: 3)))
            return Array(closed) == opened ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range)
        }
    }

    private static let seam = Rx(#"((?:</(?:b|i|u|span|font|mark|sub|sup)>){1,5})(\s+)((?:<(?:b|i|u|span|font|mark|sub|sup)>){1,5})"#, ignoreCase: true)

    private static let tagNames = Rx("</?(b|i|u|span|font|mark|sub|sup)>", ignoreCase: true)

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
    /// sub and sup together, two other looks together, a piece of one of ours). A bare '<' or '>' ("->", "a < b") is text.
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
                    if !cur.intersection(kind).isEmpty || stack.count >= maxDepth
                        || (!kind.intersection(.scripts).isEmpty && !cur.intersection(.scripts).isEmpty)
                        || (!kind.intersection(.others).isEmpty && !cur.intersection(.others).isEmpty) { return nil }
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
    private static func trusted(_ source: Parsed, _ reply: Parsed, _ inverted: Kind) -> Bool {
        if !reply.opened.subtracting(source.opened).isEmpty { return false } // a look the paragraph didn't have, even around nothing
        for (kind, lengths) in reply.stretches {
            guard let had = source.stretches[kind], let hadMax = had.max(), let most = lengths.max() else { return false }
            if lengths.count > 2 * had.count + 1 { return false }
            let script = kind == .sub || kind == .sup
            // A look set the other way round covers most of its paragraph: its stretches are as long as the text between regular words.
            if inverted.intersection(kind).isEmpty && most > 2 * hadMax + (script ? 4 : 12) { return false }
            let share = Double(had.reduce(0, +)) / Double(max(1, source.letters))
            let now = Double(lengths.reduce(0, +)) / Double(max(1, reply.letters))
            if now > 2 * share + 0.1 { return false }
        }
        // A bold paragraph's bold dropped around its words would make them regular: most of it must still be bold.
        for kind in [Kind.bold, Kind.italic] {
            guard inverted.contains(kind), let had = source.stretches[kind] else { continue }
            let share = Double(had.reduce(0, +)) / Double(max(1, source.letters))
            let now = reply.stretches[kind].map { Double($0.reduce(0, +)) / Double(max(1, reply.letters)) } ?? 0
            if now < share / 2 - 0.1 { return false }
        }
        return true
    }

    /// A reply with every tag, and every piece of one of ours, taken out; then any '<' left that opens a tag; spaces
    /// collapsed. A bare '<' or '>' ("->", "a < b") stays.
    private static func stripped(_ reply: String) -> String {
        var s = anyTag.replaceMatches(reply) { m, ns in unwrapped(ns, m) }
        s = tagPiece.replace(s, "")
        s = tagOpening.replace(s, "")
        return collapsed(s)
    }

    private static let anyTag = Rx(#"</?[A-Za-z][^<>]{0,60}>|<[!?][^<>]{0,60}>"#)

    // What is left of one of ours cut short or garbled: "<b", "</sub", "< sup>", "/b>", "/SUB >", "sup>", " i>". A lone
    // letter's '>' counts only when it touches the letter and no number or '=' follows: "i > 0", "b >= a", "i>0" are text.
    private static let tagPiece = Rx(#"<\s*/?\s*(?:b|i|u|span|font|mark|sub|sup)\b(?:\s*>)?|/\s*(?:b|i|u|span|font|mark|sub|sup)\s*>|(?<![\p{L}\p{N}])(?:b|i|u|span|font|mark|sub|sup)>(?![\p{N}=])"#,
                                     ignoreCase: true)

    // The end of one of ours whose '<' is gone ("negrita/b>", "x /sub>", "word i>"); a whole tag ("<b>", "</b>") isn't
    // one, nor a comparison ("i > 0", "b >= a", "i>0").
    private static let brokenEnd = Rx(#"(?<!<)/\s*(?:b|i|u|span|font|mark|sub|sup)\s*>|(?<![\p{L}\p{N}</])(?:b|i|u|span|font|mark|sub|sup)>(?![\p{N}=])"#,
                                      ignoreCase: true)

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
        replaceMatches(s) { m, ns in with(ns.substring(with: m.range)) }
    }

    /// Every match replaced by what `with` makes of it and the string it was found in (its groups, what stands beside it).
    func replaceMatches(_ s: String, _ with: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var at = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += with(m, ns)
            at = m.range.location + m.range.length
        }
        out += ns.substring(from: at)
        return out
    }

    /// Each match in turn, with the string it was found in.
    func each(_ s: String, _ body: (NSTextCheckingResult, NSString) -> Void) {
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) { body(m, ns) }
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
