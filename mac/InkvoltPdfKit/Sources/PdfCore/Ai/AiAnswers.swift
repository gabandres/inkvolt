import Foundation
import PrintCore

/// What an AI assistant's answer answered: a summary, a question about the document, an explanation of a passage.
public enum AiAnswerKind: Sendable { case summary, answer, explanation }

/// One answer of the AI assistant with what it answered. `shown`: what the pane showed as asked ("Summarize pages 1–3",
/// the question, "Explain: …"), in the interface's language; `asked`: what a later question sends as this turn of the
/// conversation (the prompts are English); `model`: the model that answered.
public struct AiExchange: Equatable, Sendable {
    public var kind: AiAnswerKind
    public var shown: String
    public var asked: String
    public var answer: String
    public var model: String
    public var when: Date

    public init(_ kind: AiAnswerKind, shown: String, asked: String, answer: String, model: String, when: Date) {
        self.kind = kind
        self.shown = shown
        self.asked = asked
        self.answer = answer
        self.model = model
        self.when = when
    }

    /// The pages the answer cites ([p. N]), 0-based, each once, in the order cited.
    public func citedPages(_ pageCount: Int) -> [Int] {
        var seen = Set<Int>()
        return AiText.citations(answer, pageCount).map(\.page).filter { seen.insert($0).inserted }
    }
}

/// The AI assistant's conversation about one document (the Windows Core's `AiConversation`), kept with its session
/// (`DocumentSession.aiConversation`) until the user clears it or closes the document: what Save AI Answer saves, and what
/// a follow-up question sends again (`turns`). Nothing of it is written anywhere unless the user saves it.
public final class AiConversation: @unchecked Sendable {
    /// The most answers kept: the oldest go first.
    public static let maxExchanges = 500

    private let lock = NSLock()
    private var list: [AiExchange] = []

    public init() {}

    public var exchanges: [AiExchange] { lock.withLock { list } }

    public func add(_ exchange: AiExchange) {
        lock.withLock {
            list.append(exchange)
            if list.count > Self.maxExchanges { list.removeFirst() }
        }
    }

    public func clear() { lock.withLock { list.removeAll() } }

    /// The earlier questions and answers as a follow-up sends them.
    public var turns: [AiTurn] { exchanges.map { AiTurn($0.asked, $0.answer) } }
}

/// Save an AI answer (roadmap 4.20, the Windows Core's `AiAnswerExport`): one answer or the whole conversation as a Word
/// document (`DocxWriter`) or a PDF, or one answer as a comment on the page it cites. Each says it was made by an AI model
/// and may be wrong, names the model, keeps the answer's headings, bullets, bold and page citations, and holds nothing of
/// the document but the answer.
public enum AiAnswerExport {
    /// The longest answer a comment carries (a note isn't a document): the rest is cut with "…".
    public static let maxCommentChars = 20_000

    /// The page a comment goes on: the first the answer cites, else `current`.
    public static func commentPage(_ e: AiExchange, _ pageCount: Int, current: Int) -> Int {
        e.citedPages(pageCount).first ?? min(max(current, 0), max(0, pageCount - 1))
    }

    /// A comment's text: what was asked, the answer (plain, its Markdown marks gone), and that an AI model wrote it.
    public static func commentText(_ e: AiExchange, locale: Locale = CoreLanguage.locale) -> String {
        var answer = AiText.trim(blocks(e.answer).map { b -> String in
            switch b.kind {
            case .bullet: "• " + plain(b.text)
            case .blank: ""
            default: plain(b.text)
            }
        }.joined(separator: "\n"))
        if answer.utf16.count > maxCommentChars { answer = AiText.trimEnd(prefix(answer, maxCommentChars)) + "…" }
        return "\(e.shown)\n\n\(answer)\n\n\(note(e, locale: locale))"
    }

    /// "Written by an AI model (llama3.2) on …; it may be wrong."
    public static func note(_ e: AiExchange, locale: Locale = CoreLanguage.locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .short
        f.timeStyle = .short
        // macOS writes a narrow no-break space before AM/PM: a plain one, as Windows' "g" has, so the line stays in WinAnsi.
        let when = f.string(from: e.when).replacingOccurrences(of: "\u{202F}", with: " ")
        return loc("Written by an AI model ({0}) on {1}; it may be wrong. Check it against the document.", e.model, when)
    }

    /// The answers as a Word document: a title, then each as a heading (what was asked), the note, and the answer.
    /// - Throws: `PdfEditError` when there is nothing to save.
    public static func toDocx(_ exchanges: [AiExchange], _ documentName: String) throws -> [UInt8] {
        if exchanges.isEmpty { throw PdfEditError(loc("There's no AI answer to save.")) }
        let title = loc("AI answers about {0}", documentName)
        var blocks: [DocBlock] = []
        var y = 72.0
        func para(_ runs: [ExportSpan], heading: Int = 0, list: ListKind = .none, before: Double = 6, after: Double = 6) -> DocBlock {
            let size = runs.first?.size ?? 11
            var p = DocParagraph(runs, RectD(72, y, 468, size * 1.3))
            p.size = size
            p.headingLevel = heading
            p.list = list
            p.spaceBefore = before
            p.spaceAfter = after
            y += size * 1.3 + before + after
            return .paragraph(p)
        }
        func span(_ text: String, _ size: Double = 11, bold: Bool = false, italic: Bool = false, color: UInt32 = 0) -> ExportSpan {
            ExportSpan(text, "Calibri", size, bold, italic, color, RectD(0, 0, 0, 0))
        }

        blocks.append(para([span(title, 18, bold: true)], heading: 1, before: 0))
        for e in exchanges {
            blocks.append(para([span(e.shown, 13, bold: true)], heading: 2, before: 14))
            blocks.append(para([span(note(e), 9, italic: true, color: 0x595959)], before: 0))
            for b in self.blocks(e.answer) {
                if b.kind == .blank { continue }
                let runs = b.kind == .heading ? [span(b.text, 11, bold: true)] : self.runs(b.text).map { span($0.text, bold: $0.bold) }
                if runs.isEmpty { continue }
                blocks.append(para(runs, list: b.kind == .bullet ? .bullet : b.kind == .numbered ? .marker : .none, before: 2, after: 4))
            }
        }
        let layout = DocLayoutResult(pages: [DocPage(width: 612, height: 792, content: RectD(72, 72, 468, max(72, y - 72)), blocks: blocks)],
                                     header: nil, footer: nil)
        let sink = MemorySink()
        try DocxWriter(sink).finish(layout, title)
        return sink.bytes
    }

    private static let pageW = 612.0, pageH = 792.0, margin = 72.0, width = pageW - 2 * margin
    private static let black = PdfColorValue(c: [0, 0, 0]), gray = PdfColorValue(c: [0.35, 0.35, 0.35])

    /// One line to draw: its pieces (regular or bold), size, grey or not, indent and the space before it.
    private struct Line {
        var segments: [(text: String, bold: Bool)]
        var size: Double
        var gray: Bool
        var indent: Double
        var before: Double
    }

    /// The answers as a PDF of Letter pages: the same as `toDocx`, the text wrapped and flowing onto as many pages as it
    /// needs.
    /// - Throws: `PdfEditError` when there is nothing to save; MuPDF's failure.
    public static func toPdf(_ exchanges: [AiExchange], _ documentName: String) throws -> [UInt8] {
        if exchanges.isEmpty { throw PdfEditError(loc("There's no AI answer to save.")) }
        let title = loc("AI answers about {0}", documentName)
        var all = [title]
        for e in exchanges { all += [e.shown, note(e), e.answer] }
        let regular = TextPainter(.helvetica, all)
        let bold = TextPainter(StdFont(.helvetica, true, false), all)
        bold.namePrefix = "/PdB"
        var lines: [Line] = []

        // Word by word, each in its own weight, the line broken where the next word wouldn't fit.
        func wrap(_ runs: [(text: String, bold: Bool)], _ size: Double, _ isGray: Bool, _ indent: Double, _ before: Double, first: String = "") {
            let width = Self.width - indent
            var line: [(text: String, bold: Bool)] = []
            var used = 0.0
            var count = 0
            func close() {
                let hang = count == 0 && !first.isEmpty
                if hang { line.insert((first, false), at: 0) }
                lines.append(Line(segments: line, size: size, gray: isGray, indent: indent - (hang ? 12 : 0), before: count == 0 ? before : 0))
                count += 1
                line = []
                used = 0
            }
            for (text, isBold) in runs {
                let painter = isBold ? bold : regular
                for token in words(text) {
                    let w = painter.measure(AiText.trimEnd(token)) * size
                    if !line.isEmpty && used + w > width { close() }
                    if w > width { // one word wider than the line: in pieces that fit
                        for piece in painter.wrap(AiText.trimEnd(token), width, size) {
                            if !line.isEmpty { close() }
                            line.append((piece, isBold))
                            used = painter.measure(piece) * size
                        }
                        continue
                    }
                    line.append((token, isBold))
                    used += painter.measure(token) * size
                }
            }
            if !line.isEmpty || count == 0 { close() }
        }
        wrap([(title, true)], 18, false, 0, 0)
        for e in exchanges {
            wrap([(e.shown, true)], 13, false, 0, 16)
            wrap([(note(e), false)], 9, true, 0, 2)
            for b in blocks(e.answer) {
                switch b.kind {
                case .blank: continue
                case .heading: wrap([(b.text, true)], 11, false, 0, 8)
                case .bullet: wrap(runs(b.text), 11, false, 12, 3, first: "•  ")
                case .numbered: wrap(runs(b.text), 11, false, 12, 5)
                case .text: wrap(runs(b.text), 11, false, 0, 5)
                }
            }
        }

        let doc = try MuDoc.create()
        InfoDict.set(doc, "Title", title)
        InfoDict.set(doc, "Creator", "Inkvolt PDF")
        var pages: [[UInt8]] = []
        var ops: [UInt8]?
        var y = 0.0
        for line in lines {
            let height = line.size * 1.3
            if ops == nil || y - line.before - height < margin {
                if let done = ops { pages.append(done) }
                ops = []
                y = pageH - margin
            } else {
                y -= line.before
            }
            y -= height
            var x = margin + line.indent
            for (text, isBold) in line.segments {
                // Each piece goes out as it is drawn, in reading order, so the text copies and reads aloud as written.
                let painter = isBold ? bold : regular
                painter.draw(AiText.trimEnd(text), x, y + line.size * 0.25, line.size)
                ops? += painter.ops(isBold ? "/F2" : "/F1", line.gray ? gray : black)
                x += painter.measure(text) * line.size
            }
        }
        if let done = ops { pages.append(done) }

        // One font dictionary for every page, each font subset to every page's glyphs (as Summarize Comments does).
        let fonts = doc.dict()
        for (painter, name) in [(regular, "/F1"), (bold, "/F2")] {
            guard let f = painter.resources(doc, name).dict("Font") else { continue }
            for key in f.keys {
                if let v = f[key] { fonts.set(key == "F1" || key == "F2" ? PdfNames.bare(name) : key, v) }
            }
        }
        let fontsRef = doc.add(fonts)
        for (i, pageOps) in pages.enumerated() {
            let contents = doc.addStream(pageOps, deflate: true)
            let page = doc.add(doc.dict([("Type", doc.name("Page")), ("MediaBox", doc.reals(0, 0, pageW, pageH)), ("Contents", contents),
                                         ("Resources", doc.dict([("Font", fontsRef)]))]))
            doc.insertPage(page, at: i)
        }
        InfoDict.setDate(doc, "CreationDate", Date())
        try doc.checkFailure()
        return try doc.write("garbage=compact")
    }

    enum BlockKind: Equatable { case text, heading, bullet, numbered, blank }

    /// An answer's lines as the pane shows them: headings ("## …"), bullets ("- …", "* …", "• …"), numbered items, text,
    /// blank lines.
    static func blocks(_ answer: String) -> [(kind: BlockKind, text: String)] {
        var list: [(kind: BlockKind, text: String)] = []
        let text = AiText.withoutThinking(answer).text.replacingOccurrences(of: "\r\n", with: "\n")
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = AiText.trimEnd(raw)
            let trimmed = AiText.trim(line)
            if trimmed.isEmpty {
                list.append((.blank, ""))
            } else if let h = first(heading, line) {
                list.append((.heading, plain(h)))
            } else if let b = first(bullet, line) {
                list.append((.bullet, b))
            } else if numbered.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                list.append((.numbered, trimmed))
            } else {
                list.append((.text, trimmed))
            }
        }
        return list
    }

    /// A line without its **bold** marks.
    private static func plain(_ line: String) -> String { runs(line).map(\.text).joined() }

    /// A line's **bold** spans (an unclosed ** stays as text).
    static func runs(_ line: String) -> [(text: String, bold: Bool)] {
        let parts = line.components(separatedBy: "**")
        var runs: [(text: String, bold: Bool)] = []
        for (i, part) in parts.enumerated() {
            let isBold = i % 2 == 1 && i < parts.count - 1
            let text = isBold || i % 2 == 0 ? part : "**" + part
            if !text.isEmpty { runs.append((text, isBold)) }
        }
        return runs
    }

    /// A text's words, each with the spaces after it: what a line breaks between.
    private static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace = false
        for c in text {
            if c.isWhitespace {
                inSpace = true
            } else if inSpace {
                out.append(current)
                current = ""
                inSpace = false
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// At most `units` UTF-16 units of `s`, never half a character.
    private static func prefix(_ s: String, _ units: Int) -> String {
        var out = ""
        var n = 0
        for c in s {
            n += c.utf16.count
            if n > units { break }
            out.append(c)
        }
        return out
    }

    /// The first capture group of `regex` in `line`, or nil.
    private static func first(_ regex: NSRegularExpression, _ line: String) -> String? {
        guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let r = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[r])
    }

    private static let heading = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.*)$"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|•)\s+(.*)$"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^\s*\d{1,3}[.)]\s+"#)
}
