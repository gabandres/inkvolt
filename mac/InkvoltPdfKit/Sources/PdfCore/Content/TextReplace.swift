import Foundation
import PrintCore

/// What Find & Replace looks for: the text, and whether case and whole words count.
public struct ReplaceQuery: Equatable, Sendable {
    public var find: String
    public var matchCase: Bool
    public var wholeWord: Bool

    public init(_ find: String, matchCase: Bool = false, wholeWord: Bool = false) {
        self.find = find
        self.matchCase = matchCase
        self.wholeWord = wholeWord
    }
}

/// One place Find & Replace found the text: its page, its paragraph (by its place in the page's paragraphs as Edit Text &
/// Images groups them, and its text and box then), where in that text (UTF-16 units), and the words around it for the
/// preview.
public struct ReplaceMatch: Equatable, Sendable {
    public var pageIndex: Int
    public var paragraph: Int
    public var start: Int
    public var length: Int
    public var found: String
    public var before: String
    public var after: String
    /// The paragraph's text when it was found: a replacement is made only where the paragraph still reads so.
    public var paragraphText = ""
    /// The paragraph's box (page space, top-left origin), to show where the match is.
    public var box = RectD.zero
    /// Why the paragraph can't be changed ("it is …", as Edit Text & Images says it); nil when it can.
    public var blocked: String?

    public init(_ pageIndex: Int, _ paragraph: Int, _ start: Int, _ length: Int, _ found: String, _ before: String, _ after: String) {
        self.pageIndex = pageIndex
        self.paragraph = paragraph
        self.start = start
        self.length = length
        self.found = found
        self.before = before
        self.after = after
    }
}

/// Where a match is, as Find & Replace's list remembers it from one search to the next (an unticked match stays
/// unticked): its page, its paragraph and where it starts there.
public struct ReplaceKey: Hashable, Sendable {
    public var pageIndex: Int
    public var paragraph: Int
    public var start: Int

    public init(_ pageIndex: Int, _ paragraph: Int, _ start: Int) {
        self.pageIndex = pageIndex
        self.paragraph = paragraph
        self.start = start
    }

    public static func of(_ m: ReplaceMatch) -> ReplaceKey { ReplaceKey(m.pageIndex, m.paragraph, m.start) }

    /// Where this match is after `replaced` was replaced with text `inserted` UTF-16 units long: one later in the same
    /// paragraph moves by the difference; the replaced one itself is gone (nil).
    public func after(_ replaced: ReplaceMatch, inserted: Int) -> ReplaceKey? {
        if pageIndex != replaced.pageIndex || paragraph != replaced.paragraph || start < replaced.start { return self }
        if start < replaced.start + replaced.length { return nil }
        return ReplaceKey(pageIndex, paragraph, start + inserted - replaced.length)
    }
}

/// What Find & Replace found: the matches in page order, and whether there were more than it lists.
public struct ReplaceFound: Sendable {
    public var matches: [ReplaceMatch]
    public var cutShort: Bool

    /// The pages with a match.
    public var pages: Int { Set(matches.map(\.pageIndex)).count }
}

/// How a replacement went other than as asked.
public enum ReplaceNoteKind: Sendable, Equatable {
    /// Made, but characters the paragraph's font lacks are drawn in an installed font (`ReplaceNote.fonts`).
    case standIn
    /// Made in text on one line, which doesn't wrap: it is `ReplaceNote.wider` points wider and may run into what is
    /// beside it (as Edit Text & Images says of one line).
    case wider
    /// Not made: no font on this Mac has these characters (`ReplaceNote.chars`); the text stays as it was.
    case missing
    /// Not made: the longer paragraph would run into the text or picture below it.
    case wouldOverlap
    /// Not made: the paragraph can't be edited (`ReplaceNote.why`).
    case cantEdit
    /// Not made: the paragraph no longer reads as it did when it was found.
    case changed
}

/// A replacement that wasn't made as asked, and what was done instead: for the first of `count` matches in one paragraph
/// (they share it).
public struct ReplaceNote: Sendable {
    public var match: ReplaceMatch
    public var kind: ReplaceNoteKind
    public var count: Int
    /// `.standIn`: the characters borrowed; `.missing`: those no font has.
    public var chars: [String] = []
    /// `.standIn`: the installed fonts they are drawn in ("Arial").
    public var fonts: [String] = []
    /// `.cantEdit`: why, as a sentence for the user.
    public var why: String?
    /// `.wider`: how much wider the line is (points).
    public var wider = 0.0

    public init(_ match: ReplaceMatch, _ kind: ReplaceNoteKind, _ count: Int) {
        self.match = match
        self.kind = kind
        self.count = count
    }

    /// The replacement was made (`.standIn`, `.wider`).
    public var made: Bool { kind == .standIn || kind == .wider }
}

/// What Replace or Replace All did: the document (the same bytes when nothing was replaced), how many, and the notes.
public struct ReplaceResult: Sendable {
    public var data: [UInt8]
    public var replaced: Int
    public var notes: [ReplaceNote]

    /// Matches not replaced.
    public var left: Int { notes.filter { !$0.made }.reduce(0) { $0 + $1.count } }
}

/// Find & Replace across the document (roadmap 4.2; the Windows app's `TextReplace`): the text is found in each page's
/// paragraphs as Edit Text & Images groups them (so a phrase wrapped across two lines is found), and replaced through its
/// paragraph editing: the paragraph is rewritten in its box in its own font and looks, rewrapped, characters the font lacks
/// drawn from the closest font on this Mac. Replace All is one pass over the document kept open, saved once: one undo
/// step, one incremental update for a signed file. A replacement that can't be made as asked is never skipped silently:
/// each comes back as a `ReplaceNote` (characters no font has, a paragraph that would run into what follows, one that
/// can't be edited), and the text there stays as it was.
public enum TextReplace {
    /// Matches listed at most: a search for "e" in a long book stops here and says so.
    public static let maxMatches = 5_000

    /// The longest text looked for (UTF-16 units).
    public static let maxQuery = 1_000

    /// Characters of context on each side of a match in the preview.
    public static let contextChars = 40

    /// Where `query`'s text is in `text` (UTF-16 units): case ignored unless asked (as Find ignores it), a whole word only
    /// when asked (not inside a longer word). Matches don't overlap.
    public static func findIn(_ text: String, _ query: ReplaceQuery) -> [(start: Int, length: Int)] {
        var hits: [(start: Int, length: Int)] = []
        let find = query.find
        let ns = text as NSString
        let count = ns.length
        let findLength = (find as NSString).length
        if findLength == 0 || findLength > maxQuery || count == 0 { return hits }
        let options: NSString.CompareOptions = query.matchCase ? [] : [.caseInsensitive]
        let u = Array(text.utf16)
        var pos = 0
        while pos < count {
            let r = ns.range(of: find, options: options, range: NSRange(location: pos, length: count - pos))
            if r.location == NSNotFound || r.length == 0 { break }
            let start = r.location, end = r.location + r.length
            let inside = start > 0 && isWordChar(u[start - 1]) && isWordChar(u[start])
            let runsOn = end < count && isWordChar(u[end]) && isWordChar(u[end - 1])
            if !query.wholeWord || (!inside && !runsOn) {
                hits.append((start, r.length))
                pos = end
            } else {
                pos = start + 1
            }
        }
        return hits
    }

    private static func isWordChar(_ c: UInt16) -> Bool {
        if c == 0x5F { return true } // _
        guard let s = Unicode.Scalar(c) else { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber,
             .nonspacingMark, .spacingMark: return true
        default: return false
        }
    }

    /// Every match in the document, page by page, in the order of the page's paragraphs (at most `maxMatches`). A page that
    /// can't be read has none. `progress` hears each page read (its number, from 1).
    /// - Throws: `CancellationError` when `cancel` fired; `PdfEditError`, `PasswordRequired` when the file can't be read.
    public static func find(_ data: [UInt8], _ password: String?, _ query: ReplaceQuery, progress: ((Int) -> Void)? = nil,
                            cancel: CancelToken? = nil) throws -> ReplaceFound {
        var matches: [ReplaceMatch] = []
        let n = (query.find as NSString).length
        if n == 0 || n > maxQuery { return ReplaceFound(matches: matches, cutShort: false) }
        let doc = try PdfEdit.openToRead(data, password)
        for page in 0..<(try doc.pageCount()) {
            try cancel.check()
            progress?(page + 1)
            let paragraphs: [TextParagraph]
            do {
                paragraphs = try ContentEditor.paragraphsOf(doc, page, cancel)
            } catch is ContentEditError {
                continue // a page that can't be edited has nothing to find
            }
            for (i, p) in paragraphs.enumerated() {
                let text = p.text as NSString
                for (start, length) in findIn(p.text, query) {
                    if matches.count == maxMatches { return ReplaceFound(matches: matches, cutShort: true) }
                    var m = ReplaceMatch(page, i, start, length, text.substring(with: NSRange(location: start, length: length)),
                                         around(p.text, start, -1), around(p.text, start + length, 1))
                    m.paragraphText = p.text
                    m.box = p.box
                    m.blocked = p.blocked
                    matches.append(m)
                }
            }
        }
        return ReplaceFound(matches: matches, cutShort: false)
    }

    /// After Replace changed `replaced` into text `inserted` UTF-16 units long: the first of `matches` (found again) past
    /// the inserted text, so a replacement that holds the text found ("cat" → "cats") isn't found and replaced again; nil
    /// when none is left after it (no going round to the start, for the same reason).
    public static func nextAfter(_ matches: [ReplaceMatch], _ replaced: ReplaceMatch, inserted: Int) -> Int? {
        for (i, m) in matches.enumerated() {
            if m.pageIndex > replaced.pageIndex || (m.pageIndex == replaced.pageIndex && m.paragraph > replaced.paragraph) { return i }
            if m.pageIndex == replaced.pageIndex && m.paragraph == replaced.paragraph && m.start >= replaced.start + inserted { return i }
        }
        return nil
    }

    /// The words before (`direction` -1) or after (1) a place, about `contextChars` of them, on one line.
    private static func around(_ text: String, _ at: Int, _ direction: Int) -> String {
        let u = Array(text.utf16)
        func white(_ c: UInt16) -> Bool { Unicode.Scalar(c)?.properties.isWhitespace ?? false }
        let s: String
        if direction < 0 {
            var from = max(0, at - contextChars)
            while from > 0 && from < at && !white(u[from - 1]) { from += 1 } // start at a word
            s = (from > 0 ? "…" : "") + String(decoding: u[from..<at], as: UTF16.self)
        } else {
            var to = min(u.count, at + contextChars)
            while to < u.count && to > at && !white(u[to]) { to -= 1 } // end at a word
            s = String(decoding: u[at..<to], as: UTF16.self) + (to < u.count ? "…" : "")
        }
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    /// Replaces `matches` (from `find` on these bytes) with `with`, paragraph by paragraph, in one pass over the document;
    /// see the type's summary. Nothing replaced: the same bytes back. A page's paragraphs are read once, and again only
    /// after one of them was rewritten. `cancel` stops it between paragraphs (nothing is changed then); `progress` hears
    /// each page with matches begun (how many such pages are done, of how many).
    /// - Throws: `CancellationError` when `cancel` fired; `PdfEditError`, `PasswordRequired` when the file can't be edited.
    public static func replace(_ data: [UInt8], _ password: String?, _ matches: [ReplaceMatch], with: String, cancel: CancelToken? = nil,
                               progress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws -> ReplaceResult {
        var notes: [ReplaceNote] = []
        if matches.isEmpty { return ReplaceResult(data: data, replaced: 0, notes: notes) }
        let with = with.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        let withUnits = Array(with.utf16)
        var replaced = 0
        let doc = try PdfEdit.open(data, password, failure: loc("This PDF can't be edited"))
        struct Place: Hashable, Comparable {
            let page: Int, paragraph: Int
            static func < (a: Place, b: Place) -> Bool { a.page != b.page ? a.page < b.page : a.paragraph < b.paragraph }
        }
        let byPlace: [Place: [ReplaceMatch]] = Dictionary(grouping: matches) { (m: ReplaceMatch) -> Place in Place(page: m.pageIndex, paragraph: m.paragraph) }
        let places: [Place] = byPlace.keys.sorted()
        let groups: [(key: Place, items: [ReplaceMatch])] = places.map { ($0, byPlace[$0] ?? []) }
        let pageCount = Set(places.map(\.page)).count
        // The page whose paragraphs were last read, and them; nil once one of them was rewritten (read again when needed).
        var readPage = -1
        var pagesBegun = 0
        var now: [TextParagraph]?
        var unreadable: ContentEditError?
        for group in groups {
            try cancel.check()
            let first = group.items[0]
            if first.pageIndex != readPage {
                progress?(pagesBegun, pageCount)
                pagesBegun += 1
                (readPage, now, unreadable) = (first.pageIndex, nil, nil)
            }
            let count = group.items.count
            func note(_ kind: ReplaceNoteKind, _ n: Int, _ why: String? = nil) -> ReplaceNote {
                var note = ReplaceNote(first, kind, n)
                note.why = why
                return note
            }
            if let blocked = first.blocked {
                notes.append(note(.cantEdit, count, loc("This paragraph can't be edited: {0}.", blocked)))
                continue
            }
            // The page as it is now (read again only after an earlier paragraph on it was rewritten), and the paragraph on
            // it that still reads as it did, where it was.
            if now == nil && unreadable == nil {
                do {
                    now = try ContentEditor.paragraphsOf(doc, first.pageIndex, cancel)
                } catch let e as ContentEditError {
                    unreadable = e // the page reads no better for the next paragraph on it
                }
            }
            guard let paragraphs = now else {
                notes.append(note(.cantEdit, count, unreadable?.message))
                continue
            }
            func distance(_ q: TextParagraph) -> Double { abs(q.box.x - first.box.x) + abs(q.box.y - first.box.y) }
            let candidates = paragraphs.filter { ContentEditor.same($0.text, first.paragraphText) }
            guard let p = candidates.min(by: { distance($0) < distance($1) }), distance(p) <= 2 * max(1, p.fontSize) else {
                notes.append(note(.changed, count))
                continue
            }
            if let why = p.blocked {
                notes.append(note(.cantEdit, count, loc("This paragraph can't be edited: {0}.", why)))
                continue
            }

            // The paragraph's new text: each match, from the last, where it still reads as found.
            var text = Array(p.text.utf16)
            var made = 0
            var end = Int.max
            for m in group.items.sorted(by: { $0.start > $1.start }) {
                let found = Array(m.found.utf16)
                if m.start < 0 || m.start + m.length > end || m.start + m.length > text.count || found.count != m.length
                    || Array(text[m.start..<(m.start + m.length)]) != found {
                    notes.append(ReplaceNote(m, .changed, 1))
                    continue
                }
                text.replaceSubrange(m.start..<(m.start + m.length), with: withUnits)
                end = m.start
                made += 1
            }
            if made == 0 { continue }
            let newText = ContentEditor.paragraphText(String(decoding: text, as: UTF16.self))
            let spans = ContentEditor.carry(p.text, newText, p.spans)
            // The same text again ("cat" for "cat", or a match whose case only Match case would tell): nothing to write or count.
            if ContentEditor.same(newText, p.text) && ContentEditor.sameSpans(newText, spans, p.spans) { continue }
            let check = p.check(newText, spans: spans)
            if !check.missing.isEmpty {
                var n = note(.missing, made)
                n.chars = check.missing
                notes.append(n)
                continue
            }
            if let lp = check.lookProblem {
                notes.append(note(.cantEdit, made, loc("This can't be written: {0}.", lp)))
                continue
            }
            if check.overlaps != nil {
                notes.append(note(.wouldOverlap, made))
                continue
            }
            do {
                now = nil // the page changes (or may have, if this fails part-way): read it again for its next paragraph
                try ContentEditor.replaceParagraphIn(doc, p, newText, allowOverlap: false, spans: spans)
            } catch let e as ContentEditError {
                notes.append(note(.cantEdit, made, e.message))
                continue
            }
            replaced += made
            if !check.borrowed.isEmpty {
                var n = note(.standIn, made)
                n.chars = check.borrowed
                n.fonts = check.standIns
                notes.append(n)
            }
            if p.lines.count == 1 && check.lineCount == 1 && check.box.width - p.box.width > 0.5 {
                var n = note(.wider, made)
                n.wider = check.box.width - p.box.width
                notes.append(n)
            }
        }
        if replaced == 0 { return ReplaceResult(data: data, replaced: 0, notes: notes) }
        SignedEdits.noteRemoval() // the old text stays in a signed file's earlier revision
        try doc.checkFailure()
        return ReplaceResult(data: try PdfEdit.save(doc, original: data, password: password), replaced: replaced, notes: notes)
    }
}
