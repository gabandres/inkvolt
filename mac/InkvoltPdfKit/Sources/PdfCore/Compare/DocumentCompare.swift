import Foundation
import PrintCore

/// A word (or a punctuation mark) of a page: UTF-16 units [start, end) of its `PageText.text`, and the key it is
/// compared by.
public struct CompareWord: Sendable, Equatable {
    public var page: Int
    public var start: Int
    public var end: Int
    public var key: String
}

/// Splits a page's text into the words Compare matches (the Windows app's `CompareWords`).
public enum CompareWords {
    /// Words are runs of letters and digits (with apostrophes and combining marks); numbers keep their separators
    /// ("1,250.75"); each other mark is a word of its own, and so is each Chinese or Japanese character, since those
    /// scripts don't put spaces between words. A word hyphenated across a line break ("exam-" / "ple") is one word. Keys
    /// are NFKC-normalized, so ligatures ("ﬁ") match their letters.
    public static func of(_ text: PageText, _ page: Int) -> [CompareWord] {
        let s = Array(text.text.utf16)
        var words: [CompareWord] = []
        var key: [UInt16] = []
        var i = 0
        while i < s.count {
            if isWhiteSpace(s[i]) || s[i] == softHyphen {
                i += 1
                continue
            }
            let start = i
            key.removeAll(keepingCapacity: true)
            if isWordChar(s, i) && !isIdeograph(s, i) {
                while i < s.count {
                    if isWordChar(s, i) && !isIdeograph(s, i) {
                        let n = width(s, i)
                        key += s[i..<i + n]
                        i += n
                    } else if (s[i] == dot || s[i] == comma) && i > start && isDigit(s[i - 1]) && i + 1 < s.count && isDigit(s[i + 1]) {
                        key.append(s[i])
                        i += 1
                    } else if s[i] == hyphen && i + 2 < s.count && s[i + 1] == newline && isLetter(s[i - 1]) && isLetter(s[i + 2]) {
                        i += 2 // hyphenated at a line break
                    } else if s[i] == softHyphen && i + 1 < s.count
                        && (isWordChar(s, i + 1) || s[i + 1] == newline && i + 2 < s.count && isWordChar(s, i + 2)) {
                        i += s[i + 1] == newline ? 2 : 1 // soft hyphen
                    } else {
                        break
                    }
                }
            } else {
                let n = width(s, i)
                key += s[i..<i + n]
                i += n
            }
            words.append(CompareWord(page: page, start: start, end: i, key: normalize(key)))
        }
        return words
    }

    private static let softHyphen: UInt16 = 0xAD, dot: UInt16 = 46, comma: UInt16 = 44, hyphen: UInt16 = 45, newline: UInt16 = 10

    private static func normalize(_ units: [UInt16]) -> String {
        String(decoding: units, as: UTF16.self).precomposedStringWithCompatibilityMapping
    }

    private static func isHigh(_ u: UInt16) -> Bool { u >= 0xD800 && u <= 0xDBFF }
    private static func isLow(_ u: UInt16) -> Bool { u >= 0xDC00 && u <= 0xDFFF }

    private static func width(_ s: [UInt16], _ i: Int) -> Int { isHigh(s[i]) && i + 1 < s.count && isLow(s[i + 1]) ? 2 : 1 }

    /// The code point at `i` (a surrogate pair joined); nil for a lone surrogate.
    private static func scalar(_ s: [UInt16], _ i: Int) -> Unicode.Scalar? {
        if width(s, i) == 2 { return Unicode.Scalar(0x10000 + ((UInt32(s[i]) - 0xD800) << 10) + (UInt32(s[i + 1]) - 0xDC00)) }
        return Unicode.Scalar(s[i])
    }

    private static func isWhiteSpace(_ u: UInt16) -> Bool { Unicode.Scalar(u)?.properties.isWhitespace ?? false }

    private static func isDigit(_ u: UInt16) -> Bool { Unicode.Scalar(u)?.properties.generalCategory == .decimalNumber }

    private static func isLetter(_ u: UInt16) -> Bool {
        switch Unicode.Scalar(u)?.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    private static func isWordChar(_ s: [UInt16], _ i: Int) -> Bool {
        let c = s[i]
        if c == 95 || c == 39 || c == 0x2019 { return true }
        switch scalar(s, i)?.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark:
            return true
        default:
            return false
        }
    }

    /// Han, kana and the like: each is compared on its own.
    private static func isIdeograph(_ s: [UInt16], _ i: Int) -> Bool {
        let cp = scalar(s, i)?.value ?? UInt32(s[i])
        return (0x3040...0x30FF).contains(cp) || (0x3400...0x4DBF).contains(cp) || (0x4E00...0x9FFF).contains(cp)
            || (0xF900...0xFAFF).contains(cp) || (0x20000...0x3FFFF).contains(cp)
    }

    /// The text of UTF-16 units [start, end) for showing in a list: line breaks as spaces, words hyphenated at a break
    /// joined.
    public static func display(_ text: String, _ start: Int, _ end: Int) -> String { display(Array(text.utf16), start, end) }

    static func display(_ t: [UInt16], _ start: Int, _ end: Int) -> String {
        var out: [UInt16] = []
        out.reserveCapacity(max(0, end - start))
        var i = start
        while i < end {
            let c = t[i]
            if c == hyphen && i + 1 < end && t[i + 1] == newline && i > start && isLetter(t[i - 1]) && i + 2 < end && isLetter(t[i + 2]) {
                i += 1
            } else if c == softHyphen {
                if i + 1 < end && t[i + 1] == newline { i += 1 }
            } else {
                out.append(c == newline ? 32 : c)
            }
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }
}


/// How a row's text could be compared.
public enum RowText: Sendable, Equatable {
    /// Both pages have text, compared word by word.
    case compared
    /// The old page has no text (a scan?): compare the row visually.
    case noTextOld
    /// The new page has no text.
    case noTextNew
    /// Neither page has text.
    case noTextBoth
    /// A page only the old document has (removed).
    case onlyOld
    /// A page only the new document has (inserted).
    case onlyNew
}

/// One row of the comparison: an old page and the new page it lines up with, or a page only one side has. `changes`:
/// how many changes are on this row. `pageMoved`: a page only one side has here because it moved: its text is on
/// another row, as a move.
public struct CompareRow: Sendable, Equatable {
    public var oldPage: Int?
    public var newPage: Int?
    public var text: RowText
    public var changes = 0
    public var pageMoved = false
}

public enum ChangeKind: Sendable, Equatable { case inserted, deleted, changed, pageInserted, pageRemoved, moved, formatted }

/// UTF-16 units [start, end) of a page's text (start == end: a position between characters).
public struct WordSpan: Sendable, Equatable {
    public var page: Int
    public var start: Int
    public var end: Int

    public init(_ page: Int, _ start: Int, _ end: Int) {
        self.page = page
        self.start = start
        self.end = end
    }
}

/// A change: words removed (old), added (new) or both (a replacement), on one page of each side, or a whole page
/// removed or inserted, or text moved (old where it was, new where it is), or text set differently (`look`). An
/// insertion's `oldAnchor` is where it goes in the old text, a deletion's `newAnchor` where it was taken from in the new
/// text (nil when that isn't on the same row), a move's the same.
public struct CompareChange: Sendable, Equatable {
    public var kind: ChangeKind
    public var row: Int
    public var old: [WordSpan]
    public var new: [WordSpan]
    public var oldText: String
    public var newText: String
    public var oldAnchor: WordSpan?
    public var newAnchor: WordSpan?
    /// What a `.formatted` change did.
    public var look: LookChange?
    /// One of its sides was read from a picture of the page.
    public var readFromScan = false
    /// Read from a scan, and the difference is what recognizers confuse, or a stray mark: listed, but say so
    /// (`CompareScan.looksLikeASlip`).
    public var maybeMisread = false

    public init(kind: ChangeKind, row: Int, old: [WordSpan], new: [WordSpan], oldText: String, newText: String, oldAnchor: WordSpan? = nil,
                newAnchor: WordSpan? = nil, look: LookChange? = nil) {
        self.kind = kind
        self.row = row
        self.old = old
        self.new = new
        self.oldText = oldText
        self.newText = newText
        self.oldAnchor = oldAnchor
        self.newAnchor = newAnchor
        self.look = look
    }

    /// A change of the words themselves (not a move, a look or a whole page).
    public var isWording: Bool { kind == .inserted || kind == .deleted || kind == .changed }
}

public struct CompareResult: Sendable {
    public var rows: [CompareRow]
    public var changes: [CompareChange]
    public var inserted = 0
    public var deleted = 0
    public var changed = 0
    public var pagesInserted = 0
    public var pagesRemoved = 0
    public var moved = 0
    public var formatted = 0
    /// Of the text changes, those read from a scan that may be misreadings.
    public var maybeMisread = 0
    /// Rows pairing two pages whose text couldn't be compared, because one or both have none (scans).
    public var pairsWithoutText = 0

    /// No changes and every pair had text to compare.
    public var identical: Bool { changes.isEmpty && pairsWithoutText == 0 }

    /// "3 text changes (1 inserted, 2 changed); 1 moved; 1 page removed; 2 pages without text": one line for the
    /// toolbar and the report.
    public func summary() -> String {
        if identical { return loc("No differences in the text") }
        var parts: [String] = []
        let text = inserted + deleted + changed
        if text > 0 {
            var kinds: [String] = []
            if inserted > 0 { kinds.append(loc("{0} inserted", CoreLanguage.number(inserted))) }
            if deleted > 0 { kinds.append(loc("{0} removed", CoreLanguage.number(deleted))) }
            if changed > 0 { kinds.append(loc("{0} changed", CoreLanguage.number(changed))) }
            let list = kinds.joined(separator: ", ")
            let misread = maybeMisread > 0 ? loc(", {0} of them may be misread on the scan", CoreLanguage.number(maybeMisread)) : ""
            parts.append((text == 1 ? loc("{0} text change ({1})", 1, list) : loc("{0} text changes ({1})", CoreLanguage.number(text), list)) + misread)
        } else {
            parts.append(loc("No text changes"))
        }
        if moved > 0 { parts.append(loc("{0} moved", CoreLanguage.number(moved))) }
        if formatted > 0 {
            parts.append(formatted == 1 ? loc("{0} formatting change", 1) : loc("{0} formatting changes", CoreLanguage.number(formatted)))
        }
        if pagesInserted > 0 {
            parts.append(pagesInserted == 1 ? loc("{0} page inserted", 1) : loc("{0} pages inserted", CoreLanguage.number(pagesInserted)))
        }
        if pagesRemoved > 0 {
            parts.append(pagesRemoved == 1 ? loc("{0} page removed", 1) : loc("{0} pages removed", CoreLanguage.number(pagesRemoved)))
        }
        if pairsWithoutText > 0 {
            parts.append(pairsWithoutText == 1 ? loc("{0} page without text to compare", 1) : loc("{0} pages without text to compare", CoreLanguage.number(pairsWithoutText)))
        }
        return parts.joined(separator: "; ")
    }
}

/// Compares the text of two documents (the Windows app's `DocumentCompare`). The whole documents are diffed word by word
/// (so text that flows onto the next page isn't a change), then pages are lined up by the words they share: an old and a
/// new page that share most of their matched words are paired; between such pairs, pages are paired by a small
/// alignment that prefers pairing to leaving a page out (a page rewritten in place is "changed", not removed and
/// inserted). Pages left over were removed or inserted and are reported once each, not word by word; pages without text
/// (scans) are flagged instead of having all their words reported as changed. Running headers and footers both
/// documents have stay out of the diff (`CompareRunningLines`), text taken out in one place and put back in another is
/// one move (`CompareMoves`) and the same words set differently are formatting changes, where looks are known.
public enum DocumentCompare {
    /// Largest old × new page block aligned exactly; bigger blocks without shared words are paired in order.
    static let maxAlignCells = 4_000_000

    struct PagePair: Hashable {
        var old: Int
        var new: Int
    }

    public static func run(_ oldPages: [PageText], _ newPages: [PageText], cancel: CancelToken? = nil) throws -> CompareResult {
        try run(CompareSource(oldPages), CompareSource(newPages), cancel: cancel)
    }

    public static func run(_ oldSide: CompareSource, _ newSide: CompareSource, cancel: CancelToken? = nil) throws -> CompareResult {
        let oldPages = oldSide.pages, newPages = newSide.pages
        var oldHasText = [Bool](repeating: false, count: oldPages.count)
        var newHasText = [Bool](repeating: false, count: newPages.count)
        let running = try CompareRunningLines.find(oldPages, newPages, cancel: cancel)
        var oldWords: [CompareWord] = [], newWords: [CompareWord] = []
        for p in oldPages.indices { addWords(&oldWords, oldPages[p], p, running.old[p], &oldHasText) }
        for p in newPages.indices { addWords(&newWords, newPages[p], p, running.new[p], &newHasText) }
        try cancel?.check()

        let oldKeys = oldWords.map(\.key), newKeys = newWords.map(\.key)
        var ops = try pageWiseDiff(oldWords, newWords, oldKeys, newKeys, cancel)
        try cancel?.check()

        // What moved leaves the diff: without it the words around it line up again, even those it took a "." from.
        let moves = try CompareMoves.find(ops, oldKeys, newKeys, cancel: cancel)
        var movedOld = [Bool](repeating: false, count: oldWords.count)
        var movedNew = [Bool](repeating: false, count: newWords.count)
        for m in moves {
            for i in m.oldStart..<m.oldEnd { movedOld[i] = true }
            for j in m.newStart..<m.newEnd { movedNew[j] = true }
        }
        if !moves.isEmpty { ops = try diffOfTheRest(oldWords, newWords, movedOld, movedNew, cancel) }

        var shared: [PagePair: Int] = [:]
        for op in ops where op.kind == .equal {
            for k in 0..<op.length { shared[PagePair(old: oldWords[op.a + k].page, new: newWords[op.b + k].page), default: 0] += 1 }
        }

        let pairs = try align(oldPages.count, newPages.count, shared, cancel: cancel)
        var rows = pairs.map { p -> CompareRow in
            let text: RowText
            switch (p.old, p.new) {
            case (nil, _): text = .onlyNew
            case (_, nil): text = .onlyOld
            case let (o?, n?) where oldHasText[o] && newHasText[n]: text = .compared
            case let (o?, _) where oldHasText[o]: text = .noTextNew
            case let (_, n?) where newHasText[n]: text = .noTextOld
            default: text = .noTextBoth
            }
            return CompareRow(oldPage: p.old, newPage: p.new, text: text)
        }
        var rowOfOld = [Int](repeating: 0, count: oldPages.count)
        var rowOfNew = [Int](repeating: 0, count: newPages.count)
        for (r, row) in rows.enumerated() {
            if let o = row.oldPage { rowOfOld[o] = r }
            if let n = row.newPage { rowOfNew[n] = r }
        }

        // A page only one side has whose words are nearly all elsewhere on the other side isn't removed or inserted: its
        // text moved or flowed there. What is left on it is compared like any other words.
        var inPlaceOld = movedOld, inPlaceNew = movedNew
        for op in ops where op.kind == .equal {
            for k in 0..<op.length {
                inPlaceOld[op.a + k] = true
                inPlaceNew[op.b + k] = true
            }
        }
        for r in rows.indices {
            let row = rows[r]
            if row.text == .onlyOld, let o = row.oldPage, mostlyMoved(oldWords, inPlaceOld, o) { rows[r].pageMoved = true }
            if row.text == .onlyNew, let n = row.newPage, mostlyMoved(newWords, inPlaceNew, n) { rows[r].pageMoved = true }
        }

        // Words that are the same on both sides: where they stayed, then where they moved.
        var matched: [(old: Int, new: Int)] = []
        for op in ops where op.kind == .equal {
            for k in 0..<op.length { matched.append((op.a + k, op.b + k)) }
        }

        let oldUnits = oldPages.map { Array($0.text.utf16) }, newUnits = newPages.map { Array($0.text.utf16) }
        let sides = Sides(oldWords: oldWords, newWords: newWords, oldUnits: oldUnits, newUnits: newUnits, rowOfOld: rowOfOld, rowOfNew: rowOfNew)
        var changes = wordChanges(ops, sides, rows)
        var oldToNew: [Int: Int] = [:]
        for (o, n) in matched { oldToNew[o] = n }
        for m in moves {
            for op in m.inner where op.kind == .equal {
                for k in 0..<op.length { matched.append((op.a + k, op.b + k)) }
            }
            changes += wordChanges(m.inner, sides, rows, inMove: true)
            changes.append(moveChange(m, sides, oldToNew))
        }
        try cancel?.check()
        changes += formatChanges(matched, sides, oldSide, newSide)
        for (r, row) in rows.enumerated() where !row.pageMoved {
            if row.text == .onlyOld, let o = row.oldPage {
                changes.append(CompareChange(kind: .pageRemoved, row: r, old: [WordSpan(o, 0, 0)], new: [], oldText: excerpt(oldUnits[o]), newText: ""))
            } else if row.text == .onlyNew, let n = row.newPage {
                changes.append(CompareChange(kind: .pageInserted, row: r, old: [], new: [WordSpan(n, 0, 0)], oldText: "", newText: excerpt(newUnits[n])))
            }
        }
        // Stable: within a row, wording in reading order, then moves, then looks.
        func rank(_ kind: ChangeKind) -> Int { kind == .moved ? 1 : kind == .formatted ? 2 : 0 }
        changes = changes.map { markScan($0, oldSide, newSide, rows) }.enumerated()
            .sorted { ($0.element.row, rank($0.element.kind), $0.offset) < ($1.element.row, rank($1.element.kind), $1.offset) }.map(\.element)
        var perRow = [Int](repeating: 0, count: rows.count)
        for c in changes { perRow[c.row] += 1 }
        for r in rows.indices { rows[r].changes = perRow[r] }

        var result = CompareResult(rows: rows, changes: changes)
        result.inserted = changes.filter { $0.kind == .inserted }.count
        result.deleted = changes.filter { $0.kind == .deleted }.count
        result.changed = changes.filter { $0.kind == .changed }.count
        result.pagesInserted = changes.filter { $0.kind == .pageInserted }.count
        result.pagesRemoved = changes.filter { $0.kind == .pageRemoved }.count
        result.moved = changes.filter { $0.kind == .moved }.count
        result.formatted = changes.filter { $0.kind == .formatted }.count
        result.maybeMisread = changes.filter(\.maybeMisread).count
        result.pairsWithoutText = rows.filter { $0.text == .noTextOld || $0.text == .noTextNew || $0.text == .noTextBoth }.count
        return result
    }

    /// The word diff, preferring runs that start and end with a page, so a removed page doesn't take the next page's
    /// first word along; then with a sentence, so a removed paragraph doesn't take the next one's first word ("Article")
    /// along, which leaves that word removed on one side and inserted on the other when the paragraph only moved.
    private static func pageWiseDiff(_ oldWords: [CompareWord], _ newWords: [CompareWord], _ oldKeys: [String], _ newKeys: [String],
                                     _ cancel: CancelToken?) throws -> [DiffOp] {
        WordDiff.slide(try WordDiff.diff(oldKeys, newKeys, cancel: cancel), oldKeys, newKeys) { kind, s, e in
            let words = kind == .delete ? oldWords : newWords
            let spans = words[e - 1].page - words[s].page + 1
            let starts = s == 0 || words[s - 1].page != words[s].page
            let ends = e == words.count || words[e].page != words[e - 1].page
            let sentenceStarts = s == 0 || endsASentence(words[s - 1].key)
            let sentenceEnds = endsASentence(words[e - 1].key)
            let pages = Double(spans * 4 - (starts ? 1 : 0) - (ends ? 1 : 0))
            return pages - (sentenceStarts ? 0.4 : 0) - (sentenceEnds ? 0.4 : 0)
        }
    }

    private static func endsASentence(_ key: String) -> Bool { [".", "!", "?", ":", ";", "。"].contains(key) }

    /// The diff of the words no move took, as runs of word indices of the whole documents (a run may go past moved words).
    private static func diffOfTheRest(_ oldWords: [CompareWord], _ newWords: [CompareWord], _ movedOld: [Bool], _ movedNew: [Bool],
                                      _ cancel: CancelToken?) throws -> [DiffOp] {
        let oldRest = oldWords.indices.filter { !movedOld[$0] }, newRest = newWords.indices.filter { !movedNew[$0] }
        let oldLeft = oldRest.map { oldWords[$0] }, newLeft = newRest.map { newWords[$0] }
        var ops: [DiffOp] = []
        for op in try pageWiseDiff(oldLeft, newLeft, oldLeft.map(\.key), newLeft.map(\.key), cancel) {
            for k in 0..<op.length {
                let a = op.kind == .insert ? op.a : op.a + k
                let b = op.kind == .delete ? op.b : op.b + k
                ops.append(DiffOp(op.kind, a < oldRest.count ? oldRest[a] : oldWords.count, b < newRest.count ? newRest[b] : newWords.count, 1))
            }
        }
        return ops
    }

    private static func addWords(_ words: inout [CompareWord], _ page: PageText, _ p: Int, _ skip: [(start: Int, end: Int)], _ hasText: inout [Bool]) {
        let all = CompareWords.of(page, p)
        if !all.isEmpty { hasText[p] = true }
        if skip.isEmpty {
            words += all
            return
        }
        for w in all where !skip.contains(where: { w.start >= $0.start && w.start < $0.end }) { words.append(w) }
    }

    private static func mostlyMoved(_ words: [CompareWord], _ moved: [Bool], _ page: Int) -> Bool {
        var all = 0, gone = 0
        for (i, w) in words.enumerated() where w.page == page {
            all += 1
            if moved[i] { gone += 1 }
        }
        return all > 0 && Double(gone) >= Double(all) * 0.8
    }

    /// Says whether a change was read from a scan, and whether it may be a misreading.
    private static func markScan(_ c: CompareChange, _ oldSide: CompareSource, _ newSide: CompareSource, _ rows: [CompareRow]) -> CompareChange {
        // Its row too: a word only one side has may be one the scan on the other side lost.
        let row = rows[c.row]
        let rowOldScanned = row.oldPage.map(oldSide.isScanned) ?? false
        let rowNewScanned = row.newPage.map(newSide.isScanned) ?? false
        let spansScanned = c.old.contains { oldSide.isScanned($0.page) } || c.new.contains { newSide.isScanned($0.page) }
        if !spansScanned && !rowOldScanned && !rowNewScanned { return c }
        let slip: Bool
        switch c.kind {
        case .changed: slip = CompareScan.looksLikeASlip(c.oldText, c.newText)
        case .inserted: slip = CompareScan.isOnlyMarks(c.newText) || (rowOldScanned && CompareScan.couldBeALostLine(c.newText))
        case .deleted: slip = CompareScan.isOnlyMarks(c.oldText) || (rowNewScanned && CompareScan.couldBeALostLine(c.oldText))
        default: slip = false
        }
        var marked = c
        marked.readFromScan = true
        marked.maybeMisread = slip
        return marked
    }

    /// Both documents' words and text, and the row each page is on.
    private struct Sides {
        var oldWords: [CompareWord]
        var newWords: [CompareWord]
        var oldUnits: [[UInt16]]
        var newUnits: [[UInt16]]
        var rowOfOld: [Int]
        var rowOfNew: [Int]
    }

    /// A run of words as a span per page it is on, and its text for showing.
    private static func spans(_ words: [CompareWord], _ first: Int, _ last: Int, _ units: [[UInt16]]) -> (spans: [WordSpan], text: String) {
        var spans: [WordSpan] = []
        var parts: [String] = []
        var start = first
        for i in first...last {
            if i < last && words[i + 1].page == words[start].page { continue }
            let page = words[start].page, from = words[start].start, to = words[i].end
            spans.append(WordSpan(page, from, to))
            parts.append(CompareWords.display(units[page], from, to))
            start = i + 1
        }
        return (spans, parts.joined(separator: " "))
    }

    private static func moveChange(_ m: CompareMove, _ s: Sides, _ oldToNew: [Int: Int]) -> CompareChange {
        let (oldSpans, oldText) = spans(s.oldWords, m.oldStart, m.oldEnd - 1, s.oldUnits)
        let (newSpans, newText) = spans(s.newWords, m.newStart, m.newEnd - 1, s.newUnits)

        // Where it was, in the new text: right after the last word before it that stayed.
        var from: WordSpan?
        var i = m.oldStart - 1
        while i >= max(0, m.oldStart - 200) && from == nil {
            if let j = oldToNew[i] { from = WordSpan(s.newWords[j].page, s.newWords[j].end, s.newWords[j].end) }
            i -= 1
        }
        return CompareChange(kind: .moved, row: s.rowOfNew[newSpans[0].page], old: oldSpans, new: newSpans, oldText: oldText, newText: newText, newAnchor: from)
    }

    private struct LookRun {
        var oFirst: Int, oLast: Int, nFirst: Int, nLast: Int
        var look: LookChange
    }

    /// Matched words whose look differs, in the new text's order, one change per run of neighbouring words with the same
    /// change. Words with no look on either side are skipped.
    private static func formatChanges(_ matched: [(old: Int, new: Int)], _ s: Sides, _ oldSide: CompareSource, _ newSide: CompareSource) -> [CompareChange] {
        var changes: [CompareChange] = []
        if oldSide.looks == nil || newSide.looks == nil { return changes }
        var open: LookRun?

        func close() {
            guard let g = open else { return }
            let (oldSpans, oldText) = spans(s.oldWords, g.oFirst, g.oLast, s.oldUnits)
            let (newSpans, newText) = spans(s.newWords, g.nFirst, g.nLast, s.newUnits)
            changes.append(CompareChange(kind: .formatted, row: s.rowOfNew[newSpans[0].page], old: oldSpans, new: newSpans, oldText: oldText,
                                         newText: newText, look: g.look))
            open = nil
        }

        for (o, n) in matched.enumerated().sorted(by: { ($0.element.new, $0.offset) < ($1.element.new, $1.offset) }).map(\.element) {
            guard let look = lookOf(s.oldWords[o], s.newWords[n], oldSide, newSide) else {
                close()
                continue
            }
            if let g = open, g.oLast + 1 == o && g.nLast + 1 == n && sameChange(g.look, look) {
                open?.oLast = o
                open?.nLast = n
            } else {
                close()
                open = LookRun(oFirst: o, oLast: o, nFirst: n, nLast: n, look: look)
            }
        }
        close()
        return changes
    }

    private static func sameChange(_ a: LookChange, _ b: LookChange) -> Bool {
        a.parts == b.parts && a.old.partsDifferent(from: b.old).isEmpty && a.new.partsDifferent(from: b.new).isEmpty
    }

    /// How one word's look changed, or nil: unit by unit when both are spelled alike, else what most of each has.
    private static func lookOf(_ oldWord: CompareWord, _ newWord: CompareWord, _ oldSide: CompareSource, _ newSide: CompareSource) -> LookChange? {
        guard let oldLooks = oldSide.looksOf(oldWord.page), !oldLooks.isEmpty, let newLooks = newSide.looksOf(newWord.page), !newLooks.isEmpty else { return nil }
        if oldWord.end - oldWord.start == newWord.end - newWord.start {
            for k in 0..<(oldWord.end - oldWord.start) {
                guard let a = oldLooks.at(oldWord.start + k), let b = newLooks.at(newWord.start + k) else { continue }
                let parts = a.partsDifferent(from: b)
                if !parts.isEmpty { return LookChange(a, b, parts) }
            }
            return nil
        }
        guard let m = oldLooks.main(oldWord.start, oldWord.end), let n = newLooks.main(newWord.start, newWord.end) else { return nil }
        let parts = m.partsDifferent(from: n)
        return parts.isEmpty ? nil : LookChange(m, n, parts)
    }

    /// The start of a page's text, for naming a removed or inserted page.
    private static func excerpt(_ units: [UInt16]) -> String {
        let t = CompareWords.display(units, 0, min(units.count, 120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return units.count > 120 ? t + "…" : t
    }

    private struct Group {
        var oFirst: Int?, oLast: Int?, nFirst: Int?, nLast: Int?
        var prevOld: Int?, prevNew: Int?
    }

    /// Groups the diff's inserted and deleted words into changes: a group ends at an unchanged word, at a page break on
    /// either side and at a word of a row whose text isn't compared (a removed, inserted or textless page; a page whose
    /// text moved elsewhere is compared, so what is left on it shows). Words of a move aren't in the diff, and a group
    /// ends where one was. `inMove`: the diff inside a moved passage, whose two sides are on different rows and any page.
    private static func wordChanges(_ ops: [DiffOp], _ s: Sides, _ rows: [CompareRow], inMove: Bool = false) -> [CompareChange] {
        var changes: [CompareChange] = []
        var open = Group() // word indices of the open group, and the last unchanged word before it
        var prevEqualOld: Int?, prevEqualNew: Int?
        var pending: [Group] = []

        func listed(_ row: CompareRow) -> Bool { row.text == .compared || row.pageMoved }
        func close() {
            if open.oFirst == nil && open.nFirst == nil { return }
            open.prevOld = prevEqualOld
            open.prevNew = prevEqualNew
            pending.append(open)
            open = Group()
        }
        func resolve(_ nextOld: Int?, _ nextNew: Int?) {
            for g in pending { changes.append(make(g, nextOld, nextNew)) }
            pending.removeAll()
        }
        func make(_ g: Group, _ nextOld: Int?, _ nextNew: Int?) -> CompareChange {
            let oldSpan = g.oFirst.map { WordSpan(s.oldWords[$0].page, s.oldWords[$0].start, s.oldWords[g.oLast ?? $0].end) }
            let newSpan = g.nFirst.map { WordSpan(s.newWords[$0].page, s.newWords[$0].start, s.newWords[g.nLast ?? $0].end) }
            let row: Int
            if inMove, let ns = newSpan {
                row = s.rowOfNew[ns.page]
            } else if let os = oldSpan {
                row = s.rowOfOld[os.page]
            } else {
                row = s.rowOfNew[newSpan?.page ?? 0]
            }
            let kind: ChangeKind = oldSpan == nil ? .inserted : newSpan == nil ? .deleted : .changed

            // Where an insertion goes in the old text (or a deletion was in the new): next to the neighbouring unchanged
            // word, if that word is on this row.
            func anchor(_ words: [CompareWord], _ rowOf: [Int], _ before: Int?, _ after: Int?) -> WordSpan? {
                if let b = before, rowOf[words[b].page] == row { return WordSpan(words[b].page, words[b].end, words[b].end) }
                if let a = after, rowOf[words[a].page] == row { return WordSpan(words[a].page, words[a].start, words[a].start) }
                return nil
            }

            return CompareChange(kind: kind, row: row, old: oldSpan.map { [$0] } ?? [], new: newSpan.map { [$0] } ?? [],
                                 oldText: oldSpan.map { CompareWords.display(s.oldUnits[$0.page], $0.start, $0.end) } ?? "",
                                 newText: newSpan.map { CompareWords.display(s.newUnits[$0.page], $0.start, $0.end) } ?? "",
                                 oldAnchor: kind == .inserted ? anchor(s.oldWords, s.rowOfOld, g.prevOld, nextOld) : nil,
                                 newAnchor: kind == .deleted ? anchor(s.newWords, s.rowOfNew, g.prevNew, nextNew) : nil)
        }

        for op in ops {
            for k in 0..<op.length {
                switch op.kind {
                case .equal:
                    close()
                    resolve(op.a + k, op.b + k)
                    prevEqualOld = op.a + k
                    prevEqualNew = op.b + k
                case .delete:
                    let i = op.a + k
                    if !inMove && !listed(rows[s.rowOfOld[s.oldWords[i].page]]) {
                        close()
                        break
                    }
                    if let l = open.oLast, l + 1 != i || s.oldWords[l].page != s.oldWords[i].page { close() }
                    if open.oFirst == nil { open.oFirst = i }
                    open.oLast = i
                case .insert:
                    let j = op.b + k
                    if !inMove && !listed(rows[s.rowOfNew[s.newWords[j].page]]) {
                        close()
                        break
                    }
                    if let l = open.nLast, l + 1 != j || s.newWords[l].page != s.newWords[j].page {
                        close()
                    } else if !inMove, open.nLast == nil, let ol = open.oLast, s.rowOfOld[s.oldWords[ol].page] != s.rowOfNew[s.newWords[j].page] {
                        close()
                    }
                    if open.nFirst == nil { open.nFirst = j }
                    open.nLast = j
                }
            }
        }
        close()
        resolve(nil, nil)
        return changes
    }

    /// Lines up old and new pages. Pages that are each other's best match (most shared words) are fixed pairs; the
    /// stretches between them are aligned to share the most words, with each pairing worth a little on its own.
    static func align(_ oldCount: Int, _ newCount: Int, _ shared: [PagePair: Int], cancel: CancelToken? = nil) throws -> [(old: Int?, new: Int?)] {
        var bestNew = [(page: Int, words: Int)](repeating: (-1, 0), count: oldCount)
        var bestOld = [(page: Int, words: Int)](repeating: (-1, 0), count: newCount)
        for (pair, w) in shared {
            let (o, n) = (pair.old, pair.new)
            if w > bestNew[o].words || (w == bestNew[o].words && n < bestNew[o].page) { bestNew[o] = (n, w) }
            if w > bestOld[n].words || (w == bestOld[n].words && o < bestOld[n].page) { bestOld[n] = (o, w) }
        }

        var result: [(old: Int?, new: Int?)] = []

        func segment(_ o0: Int, _ o1: Int, _ n0: Int, _ n1: Int) throws {
            try cancel?.check()
            let p = o1 - o0, q = n1 - n0
            if p == 0 && q == 0 { return }
            var any = false
            if p * q <= shared.count {
                outer: for o in o0..<o1 {
                    for n in n0..<n1 where shared[PagePair(old: o, new: n)] != nil {
                        any = true
                        break outer
                    }
                }
            } else {
                any = shared.keys.contains { $0.old >= o0 && $0.old < o1 && $0.new >= n0 && $0.new < n1 }
            }
            if !any || (p + 1) * (q + 1) > maxAlignCells {
                // Nothing shared: pages in order, then whatever one side has more.
                let k = min(p, q)
                for i in 0..<k { result.append((o0 + i, n0 + i)) }
                for i in k..<max(p, k) { result.append((o0 + i, nil)) }
                for i in k..<max(q, k) { result.append((nil, n0 + i)) }
                return
            }

            // score[i][j]: best for the first i old and j new pages; a pair is worth 2 per shared word plus 1.
            let cols = q + 1
            var score = [Int](repeating: 0, count: (p + 1) * cols)
            func pairValue(_ i: Int, _ j: Int) -> Int { 2 * (shared[PagePair(old: o0 + i - 1, new: n0 + j - 1)] ?? 0) + 1 }
            for i in 0...p {
                for j in 0...q where i > 0 || j > 0 {
                    var best = Int.min
                    if i > 0 { best = score[(i - 1) * cols + j] }
                    if j > 0 { best = max(best, score[i * cols + j - 1]) }
                    if i > 0 && j > 0 { best = max(best, score[(i - 1) * cols + j - 1] + pairValue(i, j)) }
                    score[i * cols + j] = best
                }
            }
            var path: [(old: Int?, new: Int?)] = []
            var i = p, j = q
            while i > 0 || j > 0 {
                if i > 0 && j > 0 && score[i * cols + j] == score[(i - 1) * cols + j - 1] + pairValue(i, j) {
                    path.append((o0 + i - 1, n0 + j - 1))
                    i -= 1
                    j -= 1
                } else if j > 0 && score[i * cols + j] == score[i * cols + j - 1] {
                    path.append((nil, n0 + j - 1)) // walking back: an inserted page comes after a removed one
                    j -= 1
                } else {
                    path.append((o0 + i - 1, nil))
                    i -= 1
                }
            }
            result += path.reversed()
        }

        var po = 0, pn = 0
        for o in 0..<oldCount {
            let n = bestNew[o].page
            if n < pn || bestOld[n].page != o { continue } // not mutual, or out of order
            try segment(po, o, pn, n)
            result.append((o, n))
            po = o + 1
            pn = n + 1
        }
        try segment(po, oldCount, pn, newCount)
        return result
    }
}
