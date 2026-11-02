import Foundation

/// A paragraph to read aloud: its spoken text (lines joined, hyphenation undone) and, for each spoken UTF-16 unit, where
/// it came from in the page text, so what the voice says can be highlighted on the page (the Windows app's `SpeechChunk`).
public struct SpeechChunk: Equatable, Sendable {
    public let page: Int
    public let text: String
    /// Per UTF-16 unit of `text`, its page-text offset.
    public let source: [Int]

    public init(page: Int, text: String, source: [Int]) {
        self.page = page
        self.text = text
        self.source = source
    }

    /// The page-text range [start, end) the spoken units [start, end) came from.
    public func sourceRange(_ start: Int, _ end: Int) -> (start: Int, end: Int) {
        guard !source.isEmpty else { return (0, 0) }
        let s = min(max(start, 0), source.count - 1)
        let e = min(max(end, s + 1), source.count)
        return (source[s], source[e - 1] + 1)
    }

    /// The page-text offset where the chunk starts.
    public var sourceStart: Int { source.first ?? 0 }

    /// The chunk from spoken unit `at` on (reading again from a sentence, after a change of voice or speed).
    public func suffix(from at: Int) -> SpeechChunk {
        let units = Array(text.utf16)
        let a = min(max(at, 0), units.count)
        return SpeechChunk(page: page, text: String(decoding: units[a...], as: UTF16.self), source: Array(source[a...]))
    }
}

/// Turns a page's text (`PageText.text`: lines in reading order, joined by "\n") into paragraphs for speech (the Windows
/// app's `ReadAloudText`). Lines are joined with a space, a word hyphenated across a line break is put back together, and
/// a paragraph ends at a blank line, a bullet or numbered item, or a sentence that stops short of the line width. Long
/// paragraphs are cut at sentence ends so each one is synthesized quickly. Offsets are UTF-16 units, as `PageText`'s.
public enum ReadAloudText {
    /// - Parameters:
    ///   - from: first page-text offset to read (e.g. the selection's start).
    ///   - to: end of the text to read (exclusive).
    ///   - maxLength: longest chunk; longer paragraphs are split at sentence ends.
    public static func chunks(_ page: Int, _ pageText: String, from: Int = 0, to: Int = Int.max, maxLength: Int = 1200) -> [SpeechChunk] {
        let text = Array(pageText.utf16)
        let from = min(max(from, 0), text.count)
        let to = min(max(to, from), text.count)
        var lines: [(start: Int, end: Int)] = []
        var s = from
        while s < to {
            var e = s
            while e < to && text[e] != 10 { e += 1 }
            lines.append((s, e))
            s = e + 1
        }
        let typical = Self.typical(lines.map { trimmed(text, $0.start, $0.end).count }.filter { $0 > 0 })

        var chunks: [SpeechChunk] = []
        var sb: [UInt16] = []
        var src: [Int] = []
        func flush() {
            // Trim, keeping the mapping in step.
            var a = 0, b = sb.count
            while a < b && isSpace(sb[a]) { a += 1 }
            while b > a && isSpace(sb[b - 1]) { b -= 1 }
            if b > a && sb[a..<b].contains(where: isLetterOrDigit) {
                for (cs, ce) in splitLong(Array(sb[a..<b]), maxLength) {
                    chunks.append(SpeechChunk(page: page, text: String(decoding: sb[(a + cs)..<(a + ce)], as: UTF16.self),
                                              source: Array(src[(a + cs)..<(a + ce)])))
                }
            }
            sb.removeAll()
            src.removeAll()
        }

        var prev: [UInt16]?
        for (start, end) in lines {
            let line = Array(text[start..<end])
            let trimmedLine = trimmed(text, start, end)
            if trimmedLine.isEmpty {
                flush()
                prev = nil
                continue
            }
            if let p = prev, startsNewParagraph(p, trimmedLine, typical) { flush() }

            var lead = 0
            while lead < line.count && isSpace(line[lead]) { lead += 1 }
            var bodyEnd = line.count
            while bodyEnd > 0 && isSpace(line[bodyEnd - 1]) { bodyEnd -= 1 }
            if !sb.isEmpty {
                if endsHyphenated(sb) && isLower(trimmedLine[0]) {
                    // "exam-" + "ple" → "example": drop the hyphen.
                    sb.removeLast()
                    src.removeLast()
                } else {
                    sb.append(32)
                    src.append(start - 1 >= 0 ? start - 1 : start) // the line break
                }
            }
            var i = lead
            while i < bodyEnd {
                let c = line[i]
                // Collapse runs of spaces (text extraction leaves them between columns of words).
                if !(isSpace(c) && sb.last == 32) {
                    sb.append(isSpace(c) ? 32 : c)
                    src.append(start + i)
                }
                i += 1
            }
            prev = trimmedLine
        }
        flush()
        return chunks
    }

    /// The length a full line has on this page (the longer lines' median), 0 when unknown.
    private static func typical(_ lengths: [Int]) -> Int {
        guard lengths.count >= 3 else { return 0 }
        let sorted = lengths.sorted()
        return sorted[Int(Double(sorted.count) * 0.75)]
    }

    private static func trimmed(_ text: [UInt16], _ start: Int, _ end: Int) -> [UInt16] {
        var a = start, b = end
        while a < b && isSpace(text[a]) { a += 1 }
        while b > a && isSpace(text[b - 1]) { b -= 1 }
        return Array(text[a..<b])
    }

    // .NET's char tests on one UTF-16 unit (a surrogate is neither).
    private static func scalar(_ u: UInt16) -> Unicode.Scalar? { UTF16.isSurrogate(u) ? nil : Unicode.Scalar(u) }
    private static func isSpace(_ u: UInt16) -> Bool { scalar(u)?.properties.isWhitespace ?? false }
    private static func isLetter(_ u: UInt16) -> Bool { scalar(u)?.properties.isAlphabetic ?? false }
    private static func isLower(_ u: UInt16) -> Bool { scalar(u)?.properties.isLowercase ?? false }
    private static func isUpper(_ u: UInt16) -> Bool { scalar(u)?.properties.isUppercase ?? false }
    private static func isDigit(_ u: UInt16) -> Bool { scalar(u)?.properties.numericType == .decimal }
    private static func isLetterOrDigit(_ u: UInt16) -> Bool { isLetter(u) || isDigit(u) }

    private static func endsHyphenated(_ sb: [UInt16]) -> Bool {
        sb.count >= 2 && (sb[sb.count - 1] == 0x2D || sb[sb.count - 1] == 0xAD) && isLetter(sb[sb.count - 2])
    }

    private static let sentenceEnds: Set<UInt16> = Set(".!?:\"”)…".utf16)

    private static func startsNewParagraph(_ prev: [UInt16], _ line: [UInt16], _ typical: Int) -> Bool {
        if isListItem(line) { return true }
        let last = prev[prev.count - 1]
        let ended = sentenceEnds.contains(last)
        // A sentence that stops well short of the usual line width closes its paragraph.
        if ended && typical > 0 && Double(prev.count) < Double(typical) * 0.8 { return true }
        // A heading: short, no closing punctuation, followed by a capitalized line.
        return typical > 0 && Double(prev.count) < Double(typical) * 0.5 && !ended && !Set(",-;".utf16).contains(last) && isUpper(line[0])
    }

    private static let bullets: Set<UInt16> = Set("•●▪–—*◦".utf16)

    private static func isListItem(_ line: [UInt16]) -> Bool {
        if bullets.contains(line[0]) { return true }
        if line.count >= 2 && line[0] == 0x2D && line[1] == 32 { return true }
        var digits = 0
        while digits < line.count && digits < 3 && isDigit(line[digits]) { digits += 1 }
        return digits > 0 && digits < line.count - 1 && (line[digits] == 0x2E || line[digits] == 0x29) && line[digits + 1] == 32
    }

    /// Pieces of at most `max` units, cut after a sentence end (else a space) where possible.
    private static func splitLong(_ text: [UInt16], _ max: Int) -> [(Int, Int)] {
        var pieces: [(Int, Int)] = []
        var start = 0
        let stops = Set(".!?;".utf16)
        while text.count - start > max {
            let limit = start + max
            var cut = -1
            var i = limit - 1
            while i > start + max / 3 {
                if text[i] == 32 && stops.contains(text[i - 1]) {
                    cut = i
                    break
                }
                i -= 1
            }
            if cut < 0 {
                // The last space before the limit (.NET's LastIndexOf(' ', limit - 1, limit - start - 1)).
                var j = limit - 1
                while j > start && text[j] != 32 { j -= 1 }
                cut = j > start ? j : -1
            }
            if cut <= start { cut = limit }
            pieces.append((start, cut))
            start = cut
            while start < text.count && text[start] == 32 { start += 1 }
        }
        if start < text.count { pieces.append((start, text.count)) }
        return pieces
    }
}
