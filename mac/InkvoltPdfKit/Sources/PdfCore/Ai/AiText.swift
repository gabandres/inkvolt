import Foundation

/// A page's text as sent to the model (`page` is 0-based).
public struct AiPageText: Sendable, Equatable {
    public let page: Int
    public let text: String
    public init(_ page: Int, _ text: String) {
        self.page = page
        self.text = text
    }
}

/// Consecutive pages' text that fits one request, each page headed by its "[Page N]" marker.
public struct AiChunk: Sendable, Equatable {
    public let firstPage: Int
    public let lastPage: Int
    public let text: String
    public init(_ firstPage: Int, _ lastPage: Int, _ text: String) {
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.text = text
    }

    /// "page 3" or "pages 3–7" (1-based).
    public var pagesText: String { AiText.pagesText(firstPage, lastPage) }
}

/// A "[p. N]" citation in an answer: where it is (UTF-16 offsets) and the page it names (0-based).
public struct AiCitation: Sendable, Equatable {
    public let start: Int
    public let length: Int
    public let page: Int
}

/// Text handling for the AI assistant: size estimates, the context budget, chunking, page citations. Offsets and limits
/// count UTF-16 units, as Windows' do, so chunks and estimates are the same on both.
public enum AiText {
    /// Context sizes offered in Settings (tokens).
    public static let contextSizes = [2048, 4096, 8192, 16384, 32768, 65536, 131072]

    /// The context assumed when nothing better is known: Ollama's default on a machine without a large GPU, and LM
    /// Studio's default when it loads a model. A model given more reads more once the size is set (or, for Ollama, asked).
    public static let defaultContextTokens = 4096

    /// What one UTF-16 unit costs in `estimateTokens`.
    private static func cost(_ c: UInt16) -> Double {
        if isSpace(c) { return 0.1 }
        if c >= 0x2E80 && !UTF16.isLeadSurrogate(c) && !UTF16.isTrailSurrogate(c) { return 1 } // CJK, kana, Hangul and later scripts
        guard let scalar = Unicode.Scalar(c) else { return 1 } // emoji halves
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark: return 0.3
        default: return 1 // digits, punctuation, symbols
        }
    }

    /// .NET's `char.IsWhiteSpace`.
    static func isSpace(_ c: UInt16) -> Bool {
        switch c {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    /// A cautious token count (the real one depends on the model's tokenizer): about 3.3 letters per token, every digit,
    /// punctuation mark and symbol a token of its own (many tokenizers split numbers into single digits, so tables of
    /// figures cost about one token per character), each CJK character a token, spaces almost nothing. Rounds up.
    public static func estimateTokens(_ text: String) -> Int {
        var tokens = 0.0
        for c in text.utf16 { tokens += cost(c) }
        return Int(tokens.rounded(.up))
    }

    /// The tokens of a whole request: the messages' text plus a few per message for the chat format.
    public static func estimateTokens(_ messages: [AiMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1.content) + 4 }
    }

    /// The room for the answer in a model reading `contextTokens`: a quarter of it, from 256 to 2,048 tokens. Sent as the
    /// answer's limit where the server is known to honour it (Ollama).
    public static func answerTokens(_ contextTokens: Int) -> Int {
        min(max(max(contextTokens, 1024) / 4, 256), 2048)
    }

    /// How many (estimated) tokens of document text one request may carry for a model reading `contextTokens`: the context
    /// minus the answer's room and the instructions and chat format, less 10% for the estimate's error, so the prompt and
    /// the answer stay under the context together.
    public static func inputTokens(_ contextTokens: Int) -> Int {
        let context = max(contextTokens, 1024)
        return max(300, Int(Double(context - answerTokens(context) - 400) * 0.9))
    }

    /// "[Page 3]": the marker before each page's text, which the model cites as [p. 3].
    public static func pageMarker(_ page: Int) -> String { "[Page \(page + 1)]" }

    /// "page 3" or "pages 3–7" (1-based).
    public static func pagesText(_ first: Int, _ last: Int) -> String {
        first == last ? "page \(first + 1)" : "pages \(first + 1)–\(last + 1)"
    }

    /// "pages 1–3, 5" for a set of 0-based pages.
    public static func pagesText(_ pages: [Int]) -> String {
        let list = Array(Set(pages)).sorted()
        return list.count == 1 ? "page \(list[0] + 1)" : "pages \(PageRange.format(list).replacingOccurrences(of: "-", with: "–"))"
    }

    /// 12,345 (.NET's "N0").
    public static func n0(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return n < 0 ? "-" + out : out
    }

    /// .NET's `Trim()`.
    public static func trim(_ s: String) -> String { trimEnd(trimStart(s)) }

    static func trimStart(_ s: String) -> String {
        let u = s.utf16
        var i = u.startIndex
        while i < u.endIndex, isSpace(u[i]) { i = u.index(after: i) }
        return String(s[i...])
    }

    static func trimEnd(_ s: String) -> String {
        let u = s.utf16
        var i = u.endIndex
        while i > u.startIndex, isSpace(u[u.index(before: i)]) { i = u.index(before: i) }
        return String(s[..<i])
    }

    /// Tidies extracted text: trims lines, collapses runs of spaces and of blank lines.
    public static func clean(_ text: String) -> String {
        var lines: [[UInt16]] = [[]]
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let c = units[i]
            if c == 13 {
                if i + 1 < units.count && units[i + 1] == 10 { i += 1 }
                lines.append([])
            } else if c == 10 {
                lines.append([])
            } else {
                lines[lines.count - 1].append(c)
            }
            i += 1
        }
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var blank = 0
        for raw in lines {
            var line: [UInt16] = []
            line.reserveCapacity(raw.count)
            var inRun = false
            for c in raw {
                if c == 0x20 || c == 0x09 || c == 0xA0 { // runs of spaces, tabs and no-break spaces become one space
                    if !inRun { line.append(0x20) }
                    inRun = true
                } else {
                    line.append(c)
                    inRun = false
                }
            }
            var start = 0
            var end = line.count
            while start < end, isSpace(line[start]) { start += 1 }
            while end > start, isSpace(line[end - 1]) { end -= 1 }
            if start == end {
                blank += 1
                continue
            }
            if !out.isEmpty {
                out.append(10)
                if blank > 0 { out.append(10) }
            }
            blank = 0
            out.append(contentsOf: line[start..<end])
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Splits pages into chunks of at most `maxTokens` (estimated) tokens, whole pages where they fit, each page headed by
    /// its marker. A page longer than a chunk is cut at a paragraph, line, sentence or word break (its pieces keep the
    /// page's marker). Pages without text are left out.
    public static func chunk(_ pages: [AiPageText], _ maxTokensWanted: Int) -> [AiChunk] {
        let maxTokens = max(maxTokensWanted, 60)
        var chunks: [AiChunk] = []
        var text = ""
        var size = 0
        var first = -1
        var last = -1
        func close() {
            if text.isEmpty { return }
            chunks.append(AiChunk(first, last, text))
            text = ""
            size = 0
            first = -1
            last = -1
        }
        for p in pages {
            let cleaned = clean(p.text)
            if cleaned.isEmpty { continue }
            let marker = pageMarker(p.page)
            let markerTokens = estimateTokens(marker) + 1
            for piece in pieces(cleaned, maxTokens - markerTokens - 1) {
                let block = "\(marker)\n\(piece)"
                let tokens = estimateTokens(block)
                if !text.isEmpty && size + 1 + tokens > maxTokens { close() }
                if !text.isEmpty {
                    text += "\n\n"
                    size += 1
                }
                text += block
                size += tokens
                if first < 0 { first = p.page }
                last = p.page
            }
        }
        close()
        return chunks
    }

    /// Cuts text into pieces of at most `maxTokens` (estimated) tokens at the nicest break available.
    static func pieces(_ text: String, _ maxTokensWanted: Int) -> [String] {
        let maxTokens = max(maxTokensWanted, 20)
        let units = Array(text.utf16)
        var out: [String] = []
        var at = 0
        while tokens(units, at, units.count) > maxTokens {
            let cut = at + breakBefore(units, at, charsWithin(units, at, maxTokens))
            var end = cut
            while end > at, isSpace(units[end - 1]) { end -= 1 }
            out.append(String(decoding: units[at..<end], as: UTF16.self))
            at = cut
            while at < units.count, isSpace(units[at]) { at += 1 }
        }
        if at < units.count { out.append(String(decoding: units[at...], as: UTF16.self)) }
        return out
    }

    /// The start of `text` that fits `maxTokens`, with "…" when cut.
    public static func truncate(_ text: String, _ maxTokens: Int) -> String {
        if text.isEmpty || estimateTokens(text) <= maxTokens { return text }
        let units = Array(text.utf16)
        var end = breakBefore(units, 0, charsWithin(units, 0, max(1, maxTokens - 1)))
        while end > 0, isSpace(units[end - 1]) { end -= 1 }
        return String(decoding: units[0..<end], as: UTF16.self) + "…"
    }

    private static func tokens(_ units: [UInt16], _ from: Int, _ to: Int) -> Int {
        var sum = 0.0
        for i in from..<to { sum += cost(units[i]) }
        return Int(sum.rounded(.up))
    }

    /// How many units from `at` fit in `maxTokens` (at least one).
    private static func charsWithin(_ units: [UInt16], _ at: Int, _ maxTokens: Int) -> Int {
        var sum = 0.0
        var i = at
        while i < units.count {
            sum += cost(units[i])
            if Int(sum.rounded(.up)) > maxTokens { break }
            i += 1
        }
        return max(1, i - at)
    }

    private static let separators: [[UInt16]] = ["\n\n", "\n", ". ", "? ", "! ", "; ", " "].map { Array($0.utf16) }

    /// Where to cut (from `at`) within its first `limit` units: the last paragraph, line, sentence or word break in the
    /// second half; failing all, `limit`, but not inside a surrogate pair.
    private static func breakBefore(_ units: [UInt16], _ at: Int, _ limit: Int) -> Int {
        if limit < 2 { return min(units.count - at, UTF16.isLeadSurrogate(units[at]) ? 2 : 1) }
        let floor = limit / 2 // don't make tiny pieces just to break nicely
        for sep in separators {
            var i = limit - sep.count
            while i >= floor {
                if i > 0, (0..<sep.count).allSatisfy({ units[at + i + $0] == sep[$0] }) { return min(i + sep.count, limit) }
                i -= 1
            }
        }
        return UTF16.isLeadSurrogate(units[at + limit - 1]) ? limit - 1 : limit
    }

    // [p. 3], [p 3], [pp. 3-4], [page 3], [pages 3–5, 7], (p. 3): the first page is the link.
    private static let citationPattern = try! NSRegularExpression(pattern: #"[\[(](?:pp?\.?|pages?)\s*(\d{1,5})(?:\s*[-–—,]\s*\d{1,5})*[\])]"#, options: [.caseInsensitive])

    /// The "[p. N]" style citations in an answer that name a page of the document (others are left as text).
    public static func citations(_ text: String, _ pageCount: Int) -> [AiCitation] {
        let ns = text as NSString
        var list: [AiCitation] = []
        for m in citationPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let n = Int(ns.substring(with: m.range(at: 1))), n >= 1, n <= pageCount else { continue }
            list.append(AiCitation(start: m.range.location, length: m.range.length, page: n - 1))
        }
        return list
    }

    /// The answer without a reasoning model's "<think>…</think>" part. `thinking` is true while that part is still open
    /// (streaming), when nothing is shown yet.
    public static func withoutThinking(_ text: String) -> (text: String, thinking: Bool) {
        let start = trimStart(text)
        guard start.range(of: "<think>", options: [.caseInsensitive, .anchored, .literal]) != nil else { return (text, false) }
        guard let end = start.range(of: "</think>", options: [.caseInsensitive, .literal]) else { return ("", true) }
        return (trimStart(String(start[end.upperBound...])), false)
    }
}
