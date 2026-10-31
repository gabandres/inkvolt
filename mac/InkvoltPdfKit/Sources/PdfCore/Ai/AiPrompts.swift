import Foundation

/// One step of a multi-request job: which request it is, of how many known so far, and whether it is the last.
public struct AiStep: Sendable, Equatable {
    public let index: Int
    public let total: Int
    public let isFinal: Bool
    public let what: String
    public init(_ index: Int, _ total: Int, _ isFinal: Bool, _ what: String) {
        self.index = index
        self.total = total
        self.isFinal = isFinal
        self.what = what
    }
}

/// A question asked earlier in the conversation and its answer (sent again so follow-ups make sense).
public struct AiTurn: Sendable, Equatable {
    public let question: String
    public let answer: String
    public init(_ question: String, _ answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// A chat request about the document: its messages and the pages whose text it carries.
public struct AiAskRequest: Sendable {
    public let messages: [AiMessage]
    public let pages: [Int]
    public let trimmed: Bool
}

/// The prompts of the AI assistant's uses (summarize, ask about the document, explain a selection), built only from the
/// text the user picked. Word for word as on Windows, since they are what the model gets. Every prompt asks the model to
/// cite pages as [p. N] from the "[Page N]" markers, which the answer view links to the pages.
public enum AiPrompts {
    public static let summarySystem =
        "You summarize documents for the reader. Use only the text you are given. Write in the language of the text. "
        + "The text marks where each page starts with [Page N]; after each point, cite the page it comes from as [p. N]. "
        + "If the text is empty or unreadable, say so instead of guessing."

    public static let askSystem =
        "You answer questions about a document, using only the document text below. If the answer isn't in it, say so. "
        + "The text marks where each page starts with [Page N]; cite the pages you rely on as [p. N]. "
        + "Answer in the language of the question."

    public static let explainSystem =
        "You explain passages from a document in plain words for the reader: what it says, and any terms a reader may not "
        + "know. Be concise. Use only the passage and general knowledge, and say when something can't be told from the passage. "
        + "Answer in the language of the passage."

    public static let altTextSystem =
        "You write alternate text for pictures in documents, for people who use screen readers. Say what the picture shows "
        + "and what it means in the document, in one or two plain sentences (at most 250 characters). Don't start with "
        + "\"Image of\" or \"Picture of\". For a chart, give its kind and main finding. Write in the document's language. "
        + "Answer with the alternate text only."

    /// The request for a figure's alternate text: the picture, and the text around it on its page for context.
    public static func altText(_ png: [UInt8], nearby: String, language: String?, page: Int) -> [AiMessage] {
        var context = AiText.clean(nearby)
        if context.utf16.count > 1500 { context = String(decoding: Array(context.utf16.prefix(1500)), as: UTF16.self) }
        let lang = (language ?? "").isEmpty ? "" : " The document's language is \(language!)."
        let around = context.isEmpty ? "" : "\n\nText near it on the page:\n\"\"\"\n\(context)\n\"\"\""
        return [.system(altTextSystem), AiMessage(role: "user", content: "Write the alternate text for this picture on page \(page + 1).\(lang)\(around)", images: [png])]
    }

    /// A model's answer as alternate text: one paragraph, without quotes or a leading label, at most 250 characters (whole words).
    public static func cleanAltText(_ answer: String) -> String {
        let words = answer.split(whereSeparator: { $0.unicodeScalars.allSatisfy { $0.value <= 0xFFFF && AiText.isSpace(UInt16($0.value)) } })
        var s = trimQuotes(AiText.trim(words.joined(separator: " ")), "\"“”'")
        for label in ["Alternate text:", "Alt text:", "Alt:"] {
            if s.range(of: label, options: [.caseInsensitive, .anchored, .literal]) != nil {
                s = trimQuotes(AiText.trim(String(s.dropFirst(label.count))), "\"“”")
            }
        }
        let units = Array(s.utf16)
        if units.count <= 250 { return s }
        var cut = -1
        var i = 250
        while i >= 0 {
            if units[i] == 0x20 {
                cut = i
                break
            }
            i -= 1
        }
        var kept = cut > 150 ? cut : 250
        if kept == 250 && UTF16.isLeadSurrogate(units[249]) { kept = 249 }
        var head = String(decoding: units[0..<kept], as: UTF16.self)
        while let last = head.last, ",;:".contains(last) { head.removeLast() }
        return head + "…"
    }

    private static func trimQuotes(_ s: String, _ quotes: String) -> String {
        var t = Substring(s)
        while let f = t.first, quotes.contains(f) { t = t.dropFirst() }
        while let l = t.last, quotes.contains(l) { t = t.dropLast() }
        return String(t)
    }

    /// The first requests of a summary: one for the whole text when it fits, else one per chunk (the map step).
    public static func summaryRequests(_ chunks: [AiChunk]) -> [[AiMessage]] {
        if chunks.count == 1 {
            return [[.system(summarySystem), .user("Summarize this document text (\(chunks[0].pagesText)): a short overview, then the key points.\n\n\(chunks[0].text)")]]
        }
        return chunks.enumerated().map { i, c in
            [.system(summarySystem), .user("This is part \(i + 1) of \(chunks.count) of one document (\(c.pagesText)). Summarize this part in a few bullet points.\n\n\(c.text)")]
        }
    }

    /// The request that combines partial summaries (the reduce step).
    public static func combineRequest(_ parts: [(part: AiChunk, summary: String)], final: Bool) -> [AiMessage] {
        var text = final
            ? "These are summaries of consecutive parts of one document. Combine them into one summary: a short overview, then the key points. Keep the [p. N] citations.\n"
            : "These are summaries of consecutive parts of one document. Combine them into one shorter summary of these parts, as bullet points. Keep the [p. N] citations.\n"
        for (part, summary) in parts { text += "\n### \(capital(part.pagesText))\n\(AiText.trim(summary))\n" }
        return [.system(summarySystem), .user(text)]
    }

    /// Summarizes `chunks`: one request when the text fits, else map-reduce (each chunk summarized, then the partial
    /// summaries combined, in rounds while they don't fit one request). `ask` sends one request; the last one
    /// (`AiStep.isFinal`) is the answer the user sees. Before each combining round, `confirmCombine` gets that round's
    /// requests exactly as they will be sent (they carry the model's own partial summaries); when it declines, nothing
    /// more is sent and the answer is the partial summaries as they are.
    public static func summarize(_ chunks: [AiChunk], inputTokens: Int,
                                 ask: @Sendable ([AiMessage], AiStep, CancelToken?) async throws -> String,
                                 cancel: CancelToken? = nil,
                                 confirmCombine: (@Sendable ([[AiMessage]], CancelToken?) async throws -> Bool)? = nil) async throws -> String {
        if chunks.isEmpty { throw AiError("These pages have no text to summarize. Scanned pages need Recognize Text (OCR) first.") }
        let first = summaryRequests(chunks)
        if first.count == 1 { return try await ask(first[0], AiStep(1, 1, true, "Summarizing \(chunks[0].pagesText)"), cancel) }

        var done = 0
        var total = chunks.count + 1 // grows if the summaries need more than one combining round
        var parts: [(part: AiChunk, summary: String)] = []
        for i in chunks.indices {
            try cancel.check()
            done += 1
            let summary = try await ask(first[i], AiStep(done, total, false, "Summarizing part \(i + 1) of \(chunks.count) (\(chunks[i].pagesText))"), cancel)
            parts.append((chunks[i], summary))
        }

        while true {
            try cancel.check()
            let groups = group(parts, inputTokens)
            let round: [[AiMessage]] = groups.count == 1
                ? [combineRequest(parts, final: true)]
                : groups.filter { $0.count > 1 }.map { combineRequest($0, final: false) }
            // A round where every summary is alone in its group sends nothing: no question, straight to shortening them.
            if !round.isEmpty, let confirmCombine, !(try await confirmCombine(round, cancel)) { return partsAsAnswer(parts) }
            if groups.count == 1 {
                done += 1
                return try await ask(round[0], AiStep(done, total, true, "Combining the parts into one summary"), cancel)
            }
            total += round.count // the requests this round really makes (the final combine is already counted)
            var next: [(part: AiChunk, summary: String)] = []
            var r = 0
            for g in groups {
                let span = AiChunk(g[0].part.firstPage, g[g.count - 1].part.lastPage, "")
                var summary = g[0].summary
                if g.count > 1 {
                    done += 1
                    summary = try await ask(round[r], AiStep(done, total, false, "Combining the summaries of \(span.pagesText)"), cancel)
                    r += 1
                }
                next.append((span, summary))
            }
            if next.count >= parts.count { // no progress: the summaries alone are too long; keep the start of each
                let count = next.count
                next = next.map { ($0.part, AiText.truncate($0.summary, max(60, inputTokens / (count + 1)))) }
            }
            parts = next
        }
    }

    /// The partial summaries, each under its pages, when they aren't to be combined.
    private static func partsAsAnswer(_ parts: [(part: AiChunk, summary: String)]) -> String {
        parts.map { "### \(capital($0.part.pagesText))\n\(AiText.trim($0.summary))" }.joined(separator: "\n\n")
    }

    /// Consecutive partial summaries grouped so each group fits one request.
    private static func group(_ parts: [(part: AiChunk, summary: String)], _ inputTokens: Int) -> [[(part: AiChunk, summary: String)]] {
        var groups: [[(part: AiChunk, summary: String)]] = []
        var current: [(part: AiChunk, summary: String)] = []
        var size = 0
        for p in parts {
            let length = AiText.estimateTokens(p.summary) + 12 // plus its "### Pages …" heading
            if !current.isEmpty && size + length > inputTokens {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(p)
            size += length
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// A question about the document. The pages' text goes in the system message, whole when it fits; else only the parts
    /// that share the most words with the question (and the earlier questions), in page order, so the request fits
    /// `inputTokens`. Earlier turns are kept, oldest dropped first, within a third of the budget.
    public static func ask(_ typed: String, history: [AiTurn], pages: [AiPageText], inputTokens: Int) -> AiAskRequest {
        let question = AiText.trim(typed)
        var turns: [AiTurn] = []
        var historySize = 0
        for t in history.reversed() {
            let length = AiText.estimateTokens(t.question) + AiText.estimateTokens(t.answer) + 8
            if historySize + length > inputTokens / 3 { break }
            turns.insert(t, at: 0)
            historySize += length
        }

        let room = max(150, inputTokens - historySize - AiText.estimateTokens(question))
        let all = AiText.chunk(pages, max(room / 6, 150)) // small pieces, so relevant ones can be picked
        let whole = all.reduce(0) { $0 + AiText.estimateTokens($1.text) + 1 }
        var chosen = all
        var trimmed = false
        if whole > room {
            trimmed = true
            let wanted = words((turns.map(\.question) + [question]).joined(separator: " "))
            let scored = all.enumerated().map { (index: $0.offset, chunk: $0.element, score: score($0.element.text, wanted)) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            var picked: [(chunk: AiChunk, index: Int)] = []
            var size = 0
            for x in scored {
                let tokens = AiText.estimateTokens(x.chunk.text) + 1
                if size + tokens > room { continue }
                picked.append((x.chunk, x.index))
                size += tokens
            }
            chosen = picked.sorted { $0.index < $1.index }.map(\.chunk) // back in reading order
        }

        let included = Array(Set(chosen.flatMap { Array($0.firstPage...$0.lastPage) })).sorted()
        let scope = included.isEmpty ? "(the chosen pages have no text)"
            : trimmed ? "Excerpts from \(AiText.pagesText(included)) (the parts most related to the question):"
            : "Text of \(AiText.pagesText(included)):"
        var messages: [AiMessage] = [.system("\(askSystem)\n\n\(scope)\n\n\(chosen.map(\.text).joined(separator: "\n\n"))")]
        for t in turns {
            messages.append(.user(t.question))
            messages.append(.assistant(t.answer))
        }
        messages.append(.user(question))
        return AiAskRequest(messages: messages, pages: included, trimmed: trimmed)
    }

    /// "Explain this passage" for a selection on `page` (0-based).
    /// - Throws: `AiError` when the selection is empty or longer than one request can carry.
    public static func explain(_ selection: String, page: Int, inputTokens: Int) throws -> [AiMessage] {
        let text = AiText.clean(selection)
        if text.isEmpty { throw AiError("The selection has no text to explain.") }
        let tokens = AiText.estimateTokens(text)
        if tokens > inputTokens {
            throw AiError("The selection is too long to explain at once (about \(AiText.n0(tokens)) tokens; the model's context leaves room for about \(AiText.n0(inputTokens))). "
                + "Select less, or use Summarize for whole pages.")
        }
        return [.system(explainSystem), .user("Explain this passage from page \(page + 1):\n\n\"\"\"\n\(text)\n\"\"\"")]
    }

    /// The requests exactly as sent (roles and text), for the "what will be sent" preview.
    public static func preview(_ requests: [[AiMessage]]) -> String {
        var out = ""
        for (r, request) in requests.enumerated() {
            if requests.count > 1 { out += "══════ Request \(r + 1) of \(requests.count) ══════\n" }
            for m in request {
                out += "── \(m.role) ──\n\(m.content)\n"
                for png in m.images { out += "[a picture: PNG, \(pngSize(png)), \(kilobytes(png.count)) KB]\n" }
                out += "\n"
            }
        }
        return AiText.trimEnd(out) + "\n"
    }

    private static func pngSize(_ png: [UInt8]) -> String {
        guard png.count >= 24 else { return "?" }
        func be(_ at: Int) -> Int { png[at..<(at + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        return "\(be(16)) × \(be(20)) pixels"
    }

    /// .NET's "0.#".
    private static func kilobytes(_ bytes: Int) -> String {
        let tenths = (Double(bytes) / 1024 * 10).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10))" : String(format: "%.1f", tenths / 10)
    }

    private static func capital(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\p{L}[\p{L}\p{Mn}\p{Nd}'’-]*|\p{Nd}+"#)

    private static func matches(_ lowered: String) -> [String] {
        let ns = lowered as NSString
        return wordPattern.matches(in: lowered, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func words(_ text: String) -> Set<String> {
        Set(matches(text.lowercased()).filter { $0.utf16.count >= 3 && !stopWords.contains($0) })
    }

    private static func score(_ text: String, _ words: Set<String>) -> Double {
        if words.isEmpty { return 0 }
        var counts: [String: Int] = [:]
        for m in matches(text.lowercased()) where words.contains(m) { counts[m, default: 0] += 1 }
        // Distinct words matter most; repeats add a little (log-scaled), per character so long pieces don't win by size.
        return Double(counts.count * 10) + counts.values.reduce(0.0) { $0 + log(1 + Double($1)) } - Double(text.utf16.count) / 100_000.0
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "has", "have", "her", "his", "how", "its",
        "may", "our", "out", "she", "that", "their", "them", "then", "there", "these", "they", "this", "was", "what",
        "when", "where", "which", "who", "why", "will", "with", "would", "does", "did", "from", "about", "into", "than",
        "document", "page", "pages", "tell", "say", "says", "said", "please",
    ]
}
