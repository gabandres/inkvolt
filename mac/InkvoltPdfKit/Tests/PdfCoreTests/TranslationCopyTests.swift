import Foundation
import Testing
@testable import PdfCore

/// PDFs for Translate (Windows' `TranslationPdf`): a report with headings, paragraphs of several lines (each on a white
/// band painted just before it, as Word's and Acrobat's exports often do), a ruled table, a figure and a footer on each
/// page. Windows draws it with PDFsharp; here its content is written by hand in `ContentEditPdf`'s subsets of Arial,
/// Arial Bold (/FB) and Times New Roman (/FT), which hold printable ASCII only.
enum TranslationPdf {
    static let sentences = [
        "The committee reviewed the quarterly results and found that revenue had grown in every region during the period under review.",
        "Costs rose more slowly than expected because the new supplier contracts took effect earlier than the board had assumed in its plan.",
        "Staff turnover remained low, although recruitment in the northern offices continued to be harder than anywhere else in the company.",
        "The auditors asked management to document how the reserve for doubtful accounts is estimated and to review it at least once a year.",
    ]

    static let table = [["Region", "Sales", "Comment"], ["North", "1,204", "Growing fast"], ["South", "987", "Steady demand"], ["East", "1,450", "New stores open"]]

    static let figure = RectD(72, 330, 200, 90)

    static let ascii = String(String.UnicodeScalarView((32...126).compactMap(Unicode.Scalar.init)))

    private static func n(_ v: Double) -> String { ContentLexer.number(v) }

    /// How wide `text` is in a subset at `size` (points).
    static func width(_ text: String, _ size: Double, file: String = "Arial.ttf") -> Double {
        let font = ArialSubset.of(ascii, file: file)
        return text.unicodeScalars.reduce(0.0) { $0 + Double(font.width(font.gid(Int($1.value)))) } / 1000 * size
    }

    /// A string as a PDF literal.
    static func literal(_ s: String) -> String {
        "(" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)") + ")"
    }

    /// A line on a white band of its own, painted just before it: text put anywhere earlier in the content is painted over.
    private static func line(_ text: String, _ font: String, _ size: Double, _ x: Double, _ y: Double, _ width: Double) -> String {
        let top = 792 - (y - size * 0.95) // the band, PDF space
        return "1 g \(n(x - 1.5)) \(n(top - size * 1.2)) \(n(width + 3)) \(n(size * 1.2)) re f 0 g BT /\(font) \(n(size)) Tf 1 0 0 1 \(n(x)) \(n(792 - y)) Tm \(literal(text)) Tj ET "
    }

    /// A text's words in lines at most `width` wide, one show operator a line (y down from the page's top); the y after it.
    private static func wrapped(_ out: inout String, _ text: String, _ font: String, _ file: String, _ size: Double, _ x: Double, _ y: Double,
                                _ width: Double, _ step: Double) -> Double {
        var y = y
        var cur = ""
        for word in text.split(separator: " ").map(String.init) {
            let next = cur.isEmpty ? word : cur + " " + word
            if self.width(next, size, file: file) > width && !cur.isEmpty {
                out += line(cur, font, size, x, y, width)
                y += step
                cur = word
            } else {
                cur = next
            }
        }
        out += line(cur, font, size, x, y, width)
        return y + step
    }

    static func report(_ pages: Int) -> [UInt8] {
        var contents: [String] = []
        for p in 0..<pages {
            var c = "0 g BT /FB 16 Tf 1 0 0 1 72 712 Tm \(literal("Chapter \(p + 1): results of the year")) Tj ET "
            var y = 110.0
            for s in 0..<3 {
                let text = "Section \(p + 1).\(s + 1). " + sentences[(p + s) % sentences.count] + " " + sentences[(p + s + 1) % sentences.count]
                y = wrapped(&c, text, "FT", "Times New Roman.ttf", 11, 72, y, 468, 13) + 16
            }
            precondition(y < figure.y)
            c += "q \(n(figure.width)) 0 0 \(n(figure.height)) \(n(figure.x)) \(n(792 - figure.bottom)) cm /Im1 Do Q "
            // A ruled table with narrow gaps: cells close enough that without the grid their text would read as one line.
            let xs = [72.0, 190, 250, 400]
            let top = 450.0, rowH = 22.0
            c += "0 G 0.5 w "
            for r in 0...table.count { c += "\(n(xs[0])) \(n(792 - top - Double(r) * rowH)) m \(n(xs[3])) \(n(792 - top - Double(r) * rowH)) l S " }
            for x in xs { c += "\(n(x)) \(n(792 - top)) m \(n(x)) \(n(792 - top - Double(table.count) * rowH)) l S " }
            c += "BT /FA 9 Tf "
            for r in table.indices {
                for col in 0..<3 { c += "1 0 0 1 \(n(xs[col] + 3)) \(n(792 - (top + Double(r) * rowH + 14))) Tm \(literal(table[r][col])) Tj " }
            }
            c += "ET BT /FA 8 Tf 1 0 0 1 280 32 Tm \(literal("Page \(p + 1) of \(pages)")) Tj ET"
            contents.append(c)
        }
        return ContentEditPdf.make(pages: contents, fontText: ascii, faces: true)
    }

    static func images(_ pdf: [UInt8], _ page: Int) -> [RectD] { (try? ContentEditor.read(pdf, nil, page).images.map(\.box)) ?? [] }
}

/// What a reader gets from a page: the pixels (Windows' `TranslationInk`). Text can be there for extraction, at the right
/// size, and not show at all (a later white band paints over it, a clip cuts it), so each line is rendered and its ink
/// measured.
enum TranslationInk {
    /// The page's lines with letters whose ink doesn't show as text of their size: "text: why". Empty when all read.
    static func problems(_ pdf: [UInt8], _ page: Int, password: String? = nil, smallest: Double = 4.9) -> [String] {
        guard let engine = try? PdfEngine.open(pdf, password: password) else { return ["can't open"] }
        defer { engine.close() }
        return problems(engine, page, smallest: smallest)
    }

    static func problems(_ engine: PdfEngine, _ page: Int, smallest: Double = 4.9) -> [String] {
        let scale = 4.0
        var problems: [String] = []
        guard let export = try? engine.exportPage(page, images: false) else { return ["can't read"] }
        for line in export.lines {
            if line.sideways || line.text.unicodeScalars.filter(TranslationText.isLetter).count < 3 { continue }
            let size = line.spans.map(\.size).max() ?? 0
            var shown = TranslationText.collapse(line.text)
            if shown.count > 50 { shown = String(shown.prefix(50)) }
            if size < smallest { problems.append("\"\(shown)\": drawn at \(String(format: "%.1f", size)) pt") }
            guard let img = try? engine.render(page, scale: scale, region: line.box), img.width > 0, img.height > 0 else { continue }
            // Ink: what differs from the most common color there (the paper).
            var counts: [Int: Int] = [:]
            var i = 0
            while i + 2 < img.pixels.count {
                counts[Int(img.pixels[i] >> 4) | Int(img.pixels[i + 1] >> 4) << 4 | Int(img.pixels[i + 2] >> 4) << 8, default: 0] += 1
                i += 3
            }
            let paper = counts.max { $0.value < $1.value }!.key
            var top = Int.max, bottom = -1
            var columns = [Bool](repeating: false, count: img.width)
            for y in 0..<img.height {
                for x in 0..<img.width {
                    let k = y * img.stride + x * 3
                    let c = Int(img.pixels[k] >> 4) | Int(img.pixels[k + 1] >> 4) << 4 | Int(img.pixels[k + 2] >> 4) << 8
                    if c == paper { continue }
                    let d = abs(Int(img.pixels[k]) - (paper & 15) * 16) + abs(Int(img.pixels[k + 1]) - (paper >> 4 & 15) * 16) + abs(Int(img.pixels[k + 2]) - (paper >> 8 & 15) * 16)
                    if d < 120 { continue }
                    top = min(top, y)
                    bottom = max(bottom, y)
                    columns[x] = true
                }
            }
            let height = bottom < 0 ? 0 : Double(bottom - top + 1) / scale
            let across = Double(columns.filter { $0 }.count) / Double(img.width)
            if height < 0.45 * size || across < 0.3 {
                problems.append("\"\(shown)\": size \(String(format: "%.1f", size)) pt, but its ink is \(String(format: "%.1f", height)) pt high across \(Int(across * 100))% of the line")
            }
        }
        return problems
    }

    /// Whitespace out, so a line break anywhere doesn't matter when comparing words in order.
    static func solid(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { !$0.properties.isWhitespace })) }
}

/// The page side of Windows' `TranslationCopyTests` (roadmap 3.1): plan, answer, write; what the copy holds.
@Suite(.serialized) struct TranslationCopyTests {
    static let marked = "ñandú" // letters no test font's subset holds
    static let letters = "The quick brown fox jumps over a lazy dog, until the 0123456789 and THE QUICK BROWN FOX JUMPS OVER A LAZY DOG.!"

    static func plain(_ s: String) -> String { TranslationInk.solid(s) }

    /// Plan, answer every text through `translate`, write.
    static func translate(_ pdf: [UInt8], _ translate: (String) -> String?, tag: String? = "es", pages: [Int]? = nil,
                          password: String? = nil) throws -> (plan: TranslationPlan, result: TranslationResult) {
        let engine = try PdfEngine.open(pdf, password: password)
        let count = engine.pageCount
        engine.close()
        let plan = try Translation.makePlan(pdf, password, pages ?? Array(0..<count))
        var answers = TranslationAnswers()
        for (text, _) in plan.texts {
            if let done = translate(text) { answers.done[text] = done } else { answers.failed[text] = "it was refused by the test" }
        }
        return (plan, try Translation.apply(plan, answers, tag))
    }

    static func page(_ content: String, _ form: String? = nil, rotate: Int = 0, fontText: String = ContentEditPdf.fontText) -> [UInt8] {
        ContentEditPdf.make(content, rotate: rotate, form: form, fontText: fontText)
    }

    /// Lines of /FA text one under the other, as a page's content.
    static func lines(_ x: Double, _ y: Double, _ size: Double, _ step: Double, _ lines: String...) -> String {
        var sb = "BT /FA \(ContentLexer.number(size)) Tf "
        for (i, l) in lines.enumerated() { sb += "1 0 0 1 \(ContentLexer.number(x)) \(ContentLexer.number(y - Double(i) * step)) Tm (\(l)) Tj " }
        return sb + "ET "
    }

    static func read(_ pdf: [UInt8]) -> PageContent { try! ContentEditor.read(pdf, nil, 0) }

    static func repeated(_ s: String, _ n: Int) -> String { Array(repeating: s, count: n).joined(separator: " ") }

    @Test func theOriginalIsNotTouchedAndTheCopyDiffers() throws {
        let pdf = TranslationPdf.report(2)
        let before = pdf
        let (_, r) = try Self.translate(pdf) { "\(Self.marked) \($0)" }
        #expect(before == pdf)
        #expect(r.data != nil && r.data != pdf)
    }

    @Test func aParagraphKeepsItsLinesFontAndSizeWhenItsFontHasTheLetters() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "The quick brown fox jumps over a lazy dog and goes on", "over the lazy dog while the brown fox goes on and on",
                                       "until the dog is done."), fontText: Self.letters)
        let (_, r) = try Self.translate(pdf) { _ in
            "The lazy dog jumps over a quick brown fox and goes on over the quick fox while the lazy dog goes on and on until the fox is done."
        }
        #expect(r.report.translated == 1)
        #expect(r.report.shrunk == 0)
        #expect(r.report.fonts.isEmpty)
        let p = try #require(Self.read(r.data!).paragraphs.first { $0.text.hasPrefix("The lazy") })
        #expect(abs(p.fontSize - 12) < 0.1)
        #expect(FontNames.family(p.lead.fontName).lowercased().hasPrefix("arial"))
        #expect(abs(p.box.x - 72) < 1)
        #expect(p.lines.count == 3)
    }

    @Test func aTranslationTheSubsetLacksIsDrawnAllInOneFontNotLetterByLetter() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "Hello World draft, 2024! Hello World draft, 2024!", "Hello World draft, 2024! Hello World draft, 2024!"))
        let (_, r) = try Self.translate(pdf) { _ in "Había una vez un ñandú que corría por el campo con mucha prisa, señor." }
        #expect(r.report.translated == 1)
        #expect(!r.report.fonts.isEmpty)
        #expect(ContentEditPdf.text(r.data!).contains("ñandú"))
        // One stand-in font carries all of its text, "H" and "a" too, though the subset has them.
        let runs = Self.read(r.data!).runs.filter { $0.box.y > 72 && !trimmed($0.text).isEmpty && $0.text.contains("una") }
        #expect(!runs.isEmpty)
        let standIns = runs.filter(\.standIn).count
        #expect(standIns == runs.count)
    }

    @Test func aLongerTextShrinksToStayAboveWhatFollows() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "Hello World draft, 2024! Hello World draft, 2024!", "Hello World draft, 2024! Hello World draft, 2024!")
            + Self.lines(72, 660, 12, 14, "2024 draft!"), fontText: Self.letters)
        let words = Self.repeated("The quick brown fox jumps over a lazy dog.", 3)
        let (_, r) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? words : "THE DOG" }
        #expect(r.report.shrunk == 1)
        #expect(r.report.doNotFit == 0)
        #expect(r.report.flags.isEmpty)
        let after = Self.read(r.data!)
        let first = try #require(after.paragraphs.first { $0.text.hasPrefix("The quick") })
        let below = try #require(after.paragraphs.first { $0.text == "THE DOG" })
        #expect(first.fontSize < 12)
        #expect(first.box.bottom <= below.box.y + 1, "\(first.box.bottom) over \(below.box.y)")
    }

    static let line = "Hello World draft, 2024! Hello World draft, 2024!"

    static func column(_ x1: Double = 72, _ x2: Double = 72, _ x3: Double = 72) -> [UInt8] {
        page(lines(x1, 700, 10, 12, "Hello " + line, line) + lines(x2, 670, 10, 12, "World " + line, line) + lines(x3, 640, 10, 12, "Draft " + line, line)
             + lines(72, 610, 10, 12, "2024 draft!"), fontText: letters)
    }

    static func sizes(_ r: TranslationResult) -> [Double] { read(r.data!).paragraphs.filter { $0.text.hasPrefix("The quick") }.map(\.fontSize) }

    @Test func aColumnsParagraphsComeOutInOneSize() throws {
        // attn-v7 p. 8, resnet p. 6: each paragraph shrank as much as it needed, so one column showed two or three sizes.
        let pdf = Self.column()
        func longer(_ n: Int) -> String { Self.repeated("The quick brown fox jumps over a lazy dog.", n) }
        let (_, r) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? longer(3) : $0.hasPrefix("2024") ? "THE DOG" : longer(2) }
        let sizes = Self.sizes(r)
        #expect(sizes.count == 3)
        #expect((sizes.first ?? 10) < 10)
        #expect(sizes.allSatisfy { abs($0 - sizes[0]) < 0.01 }, "\(sizes)")
        #expect(r.report.shrunk == 3)

        // One that needs far less than the rest keeps its own size; the rest go no smaller than the floor (80%).
        let (_, r2) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? longer(6) : $0.hasPrefix("2024") ? "THE DOG" : longer(2) }
        let sizes2 = Self.sizes(r2)
        #expect(sizes2.count == 3)
        if sizes2.count == 3 {
            #expect(sizes2[0] < 8, "\(sizes2)")
            #expect(abs(sizes2[1] - 8) < 0.01 && abs(sizes2[2] - 8) < 0.01, "\(sizes2)")
        }
    }

    @Test func aParagraphThatFitsNowhereDoesntShrinkItsColumn() throws {
        // One paragraph far too long for its room is written at the smallest size and flagged; the rest of its column keep
        // the size they need, not the floor it would drag them to.
        let words = Self.repeated("The quick brown fox jumps over a lazy dog.", 2)
        let tooMuch = Self.repeated("The lazy dog jumps over a quick brown fox.", 40)
        let (_, r) = try Self.translate(Self.column()) { $0.hasPrefix("Hello") ? tooMuch : $0.hasPrefix("2024") ? "THE DOG" : words }
        #expect(r.report.doNotFit == 1)
        let sizes = Self.sizes(r)
        #expect(sizes.count == 2)
        #expect(sizes.allSatisfy { $0 > 8.4 }, "\(sizes)")
        #expect(sizes.count == 2 && abs(sizes[0] - sizes[1]) < 0.01)
    }

    @Test func aColumnsLeftEdgeIsTheSameAFractionOfAPointApart() throws {
        // 73.4 and 73.6 pt are one column's left edge, though they round to different 3 pt steps.
        func longer(_ n: Int) -> String { Self.repeated("The quick brown fox jumps over a lazy dog.", n) }
        let (_, r) = try Self.translate(Self.column(73.4, 73.6, 73.6)) { $0.hasPrefix("Hello") ? longer(3) : $0.hasPrefix("2024") ? "THE DOG" : longer(2) }
        let sizes = Self.sizes(r)
        #expect(sizes.count == 3)
        #expect((sizes.first ?? 10) < 10)
        #expect(sizes.allSatisfy { abs($0 - sizes[0]) < 0.01 }, "\(sizes)")
    }

    @Test func aShorterRoomWithTooMuchTextIsWrittenSmallAndFlagged() throws {
        let pdf = Self.page(Self.lines(72, 700, 10, 12, "Hello World draft, 2024!") + Self.lines(72, 688, 10, 12, "2024 draft! Hello World draft, 2024! Hello"),
                            fontText: Self.letters)
        let words = Self.repeated("The quick brown fox jumps over a lazy dog.", 80)
        let (_, r) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? words : "THE DOG" }
        #expect(r.report.doNotFit == 1)
        #expect(r.report.flags.count == 1)
        #expect(r.report.flags.first?.kind == .doesNotFit)
        #expect(r.report.notes == 1)
        #expect(try Annotations.read(r.data!, nil).filter { $0.contents.contains("doesn't fit") }.count == 1)
        // All of the text is there, not cut: what doesn't fit shows and is flagged.
        #expect(Self.plain(ContentEditPdf.text(r.data!)).contains(String(Self.plain(words).prefix(2000))))
        let size = Self.read(r.data!).paragraphs.first { $0.text.hasPrefix("The") }?.fontSize ?? 0
        #expect(size >= 4.9 && size <= 5.5, "\(size)")
    }

    @Test func aSingleLineWrapsInsideTheRoomItHasAndNotOverItsNeighbor() throws {
        // A label, with another column's text to its right.
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "Hello World") + Self.lines(250, 700, 12, 14, "2024 draft!"), fontText: Self.letters)
        let (_, r) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? "The quick brown fox jumps over a lazy dog" : "THE DOG" }
        for run in Self.read(r.data!).runs where (run.box.y > 72 && run.text.contains("quick")) || run.text.contains("lazy") {
            #expect(run.box.right <= 250, "\(run.text): \(run.box.right)")
        }
        #expect(r.report.doNotFit == 0)
    }

    @Test func aCenteredTitleStaysCenteredAndARightAlignedDateStaysRight() throws {
        let body = "Hello World draft, 2024! Hello World draft, 2024! Hello World draft, 2024! Hello World draft"
        // Measured first, then placed: the title in the middle of the body's width, the date ending where the body ends.
        let seed = Self.read(Self.page(Self.lines(72, 650, 10, 12, body) + Self.lines(72, 700, 14, 14, "Hello 2024") + Self.lines(72, 600, 10, 12, "World draft"),
                                       fontText: Self.letters))
        func width(_ t: String) -> Double { seed.paragraphs.first { $0.text == t }!.box.width }
        let right = 72 + width(body)
        let pdf = Self.page(Self.lines(72, 650, 10, 12, body) + Self.lines((72 + right) / 2 - width("Hello 2024") / 2, 700, 14, 14, "Hello 2024")
            + Self.lines(right - width("World draft"), 600, 10, 12, "World draft"), fontText: Self.letters)
        let (_, r) = try Self.translate(pdf) { $0 == "Hello 2024" ? "The quick brown fox" : $0 == "World draft" ? "THE LAZY DOG" : $0 }
        let after = Self.read(r.data!)
        let title = try #require(after.paragraphs.first { $0.text.hasPrefix("The quick") })
        let date = try #require(after.paragraphs.first { $0.text == "THE LAZY DOG" })
        #expect(abs(title.box.centerX - (72 + right) / 2) < 1, "\(title.box.centerX)")
        #expect(abs(date.box.right - right) < 1, "\(date.box.right)")
    }

    @Test func chineseBreaksBetweenCharactersAndStaysInsideItsBox() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "Hello World draft, 2024! Hello World draft, 2024!", "Hello World draft, 2024! Hello World draft, 2024!"))
        let zh = String(repeating: "委员会审查了季度业绩，发现收入增长。", count: 3)
        let (_, r) = try Self.translate(pdf) { _ in zh }
        #expect(r.report.translated == 1)
        #expect(Self.plain(ContentEditPdf.text(r.data!)).contains(Self.plain(zh)))
        let box = Self.read(pdf).paragraphs.last!.box
        for run in Self.read(r.data!).runs where run.box.y > 72 && run.text.contains("会") {
            #expect(run.box.right <= box.right + 1, "\(run.box.right) past \(box.right)")
        }
    }

    @Test func aWordWiderThanItsBoxIsBrokenAndStaysInside() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "Hello World draft", "draft World draft") + Self.lines(300, 700, 12, 14, "2024 draft!", "2024 draft!"),
                            fontText: Self.letters)
        let word = String(repeating: "thequickbrownfox", count: 8)
        let (_, r) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? word : $0 }
        let box = Self.read(pdf).paragraphs.first { $0.text.hasPrefix("Hello") }!.box
        let runs = Self.read(r.data!).runs.filter { $0.box.y > 72 && $0.box.x < 200 && $0.text.contains("quick") }
        #expect(!runs.isEmpty)
        #expect(runs.allSatisfy { $0.box.right <= box.right + 1 }, "\(runs.map(\.box.right)) past \(box.right)")
        #expect(Self.plain(ContentEditPdf.text(r.data!)).contains(word))
    }

    @Test func arabicReadsRightToLeftAgainstTheBoxsRightEdge() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "Hello World draft, 2024! Hello World draft, 2024!", "Hello World draft, 2024! Hello World draft, 2024!"))
        let ar = "نظرت اللجنة في النتائج الفصلية ووجدت أن الإيرادات نمت في كل منطقة خلال الفترة"
        let (_, r) = try Self.translate(pdf, { _ in ar }, tag: "ar")
        #expect(r.report.translated == 1)
        // Copied out, it reads as typed.
        #expect(Self.plain(ContentEditPdf.text(r.data!)).contains(String(Self.plain(ar).prefix(10))))
        let p = Self.read(pdf).paragraphs.last!
        let laid = ContentEditor.layOut(p, p.runs, ar, [], fit: 1.0)
        #expect(!laid.lines.isEmpty)
        for (origin, parts) in laid.lines {
            #expect(parts.count == 1)
            let shaped = try #require(parts.first?.standIn)
            #expect(abs(origin.x + shaped.width * p.fontSize - p.box.right) < 1)
            #expect(shaped.rtl)
        }
    }

    @Test func rightToLeftSourceTextIsTranslatedWhereTheEditorWouldRefuseIt() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "Hello World draft, 2024!"))
        #expect(Self.read(pdf).paragraphs.last?.blocked == nil)
        let (_, r) = try Self.translate(pdf) { _ in "שלום עולם" }
        let (plan, back) = try Self.translate(r.data!) { $0.contains("ש") || $0.contains("ם") ? "Back in English, señor" : $0 }
        #expect(plan.blocked.isEmpty, "\(plan.blocked.first?.why ?? "")")
        #expect(plan.texts.contains { $0.text.contains("ש") })
        #expect(ContentEditPdf.text(back.data!).contains("señor"))
        #expect(Self.read(back.data!).paragraphs.filter { $0.text.contains("señor") }.count == 1)
    }

    @Test func aRaisedMarkGoesWithTheParagraphAndABulletStaysInFront() throws {
        // "World" with a raised 1 in the middle of the line; a bullet of its own before a line, in another font.
        let content = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (Hello World) Tj ET BT /FA 7 Tf 1 0 0 1 137 705 Tm (1) Tj ET BT /FA 12 Tf 1 0 0 1 143 700 Tm (draft, 2024!) Tj ET "
            + "BT /FB 12 Tf 1 0 0 1 72 660 Tm (-) Tj ET BT /FA 12 Tf 1 0 0 1 86 660 Tm (Hello draft) Tj ET "
        let pdf = ContentEditPdf.make(content, fontText: Self.letters, faces: true)
        let (plan, r) = try Self.translate(pdf) { $0.contains("draft, 2024") ? "THE DOG" : $0 == "Hello draft" ? "THE FOX" : $0 }
        #expect(plan.texts.contains { $0.text == "Hello draft" }) // not "- Hello draft"
        #expect(plan.texts.contains { $0.text.contains("1") && $0.text.contains("draft, 2024") })
        let text = ContentEditPdf.text(r.data!)
        #expect(text.contains("THE DOG") && text.contains("THE FOX"))
        #expect(text.components(separatedBy: "THE FOX")[0].contains("-"))
        #expect(!(text.components(separatedBy: "THE DOG").last ?? "").contains("Hello World"))
        let fox = try #require(Self.read(r.data!).runs.first { $0.text == "THE FOX" })
        #expect(abs(fox.box.x - 86) < 1)
    }

    @Test func aLineOpeningWithABracketStaysInItsParagraphAndAHyphenJoinsTheNextLine() throws {
        // resnet p. 10: pdfTeX draws a line's opening "(" as its own operator; it isn't a bullet in front of the line, and
        // the paragraph's last line, after "(classi-", goes with it.
        let content = Self.lines(72, 700, 10, 12, "The quick brown fox jumps over a lazy dog, until the")
            + "BT /FA 10 Tf 1 0 0 1 72 688 Tm (\\() Tj 1 0 0 1 75.3 688 Tm (quick brown fox jumps over a lazy dog, until the dog) Tj ET "
            + Self.lines(72, 676, 10, 12, "the quick brown fox jumps over a lazy dog \\(classi-", "fication and dog.")
        let (plan, _) = try Self.translate(Self.page(content, fontText: Self.letters + "()-")) { _ in "THE DOG" }
        #expect(plan.texts.map(\.text) == ["The quick brown fox jumps over a lazy dog, until the (quick brown fox jumps over a lazy dog, until the dog the quick brown fox jumps over a lazy dog (classification and dog."])
    }

    @Test func aLabelEndingInAColonStaysApartFromTheRowUnderIt() throws {
        // The census's table without rules: "Income percentile ratios:" heads the rows under it, figures beside them.
        let content = Self.lines(72, 700, 8, 11, "Lazy dog and fox ratios:", "90th/10th", "90th/50th") + Self.lines(200, 689, 8, 11, "12.63", "2.71")
        let (plan, _) = try Self.translate(Self.page(content, fontText: Self.letters + ":/")) { _ in "THE DOG" }
        let words = plan.texts.map { TranslationText.trim($0.text) }.filter { $0.unicodeScalars.contains(where: TranslationText.isLetter) }
        #expect(words == ["Lazy dog and fox ratios:", "90th/10th", "90th/50th"])
    }

    static func table(_ rows: [[String]], ruleInner: Bool) -> [UInt8] {
        let xs = [72.0, 160, 250, 400]
        var sb = "0 G 0.5 w "
        for r in 0...rows.count { sb += "\(xs[0]) \(700 - 16 * r) m \(xs[3]) \(700 - 16 * r) l S " }
        for x in ruleInner ? xs : [xs[0], xs[3]] { sb += "\(x) 700 m \(x) \(700 - 16 * rows.count) l S " }
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() where !cell.isEmpty { sb += lines(xs[c] + 3, Double(700 - 16 * r - 12), 9, 11, cell) }
        }
        return page(sb, fontText: letters + ":,")
    }

    @Test func aLabelAloneOnItsRowGrowsIntoTheEmptyCellsBesideIt() throws {
        // The census's first "Income percentile ratios:": a label in a narrow first column, nothing else on its row, a row
        // right under it. Its translation is longer than its cell; the row's empty cells to its right take it at its size.
        // Only the outer columns ruled (the census rules none): nothing stands between the label and the empty cells.
        let pdf = Self.table([["North", "1,204", "Growing fast"], ["Lazy dog ratios:", "", ""], ["South", "987", "Steady demand"]], ruleInner: false)
        let long = "THE QUICK BROWN FOX AND THE LAZY DOG RATIOS:"
        let (plan, r) = try Self.translate(pdf) { $0 == "Lazy dog ratios:" ? long : $0 }
        #expect(plan.pages[0].cells.contains { $0.contains(100, 792 - 684 + 8) && $0.right >= 300 }) // the label's cell reaches the table's last column
        let runs = Self.read(r.data!).runs.filter { $0.text.contains("RATIOS") }
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(TranslationText.trim(run.text) == long)
        #expect(abs(run.fontSize - 9) < 0.01) // not shrunk
        let rowTop: Double = 792 - 700 + 16 - 0.5, rowBottom: Double = 792 - 700 + 32 + 0.5
        #expect(run.box.right <= 400 && run.box.y >= rowTop && run.box.bottom <= rowBottom, "\(run.box)")
        #expect(r.report.shrunk == 0)
    }

    @Test func aCellWithTextBesideItOnItsRowKeepsItsColumn() throws {
        // A row with a name and a figure, its last column empty: the figure isn't a label alone on its row, its cell ends at its column.
        let pdf = Self.table([["North", "1,204", "Growing fast"], ["East", "55", ""], ["South", "987", "Steady demand"]], ruleInner: true)
        let (plan, _) = try Self.translate(pdf) { $0 }
        let figures = plan.pages[0].cells.filter { $0.contains(200, 792 - 684 + 8) }
        #expect(figures.count == 1 && abs((figures.first?.right ?? 0) - 250) < 0.1, "\(figures)")
        let names = plan.pages[0].cells.filter { $0.contains(100, 792 - 684 + 8) }
        #expect(names.count == 1 && abs((names.first?.right ?? 0) - 160) < 0.1, "\(names)")
    }

    @Test func aSentenceWrappedAfterAColonStaysOneParagraph() throws {
        // Short lines of a narrow column: a line ending in ":" and the next going on in lowercase are one sentence.
        let pdf = Self.page(Self.lines(72, 700, 10, 12, "and the quick fox is as so:", "brown dogs jump over lazy"), fontText: Self.letters + ":")
        let (plan, _) = try Self.translate(pdf) { _ in "THE DOG" }
        #expect(plan.texts.map { TranslationText.trim($0.text) } == ["and the quick fox is as so: brown dogs jump over lazy"])
    }

    static func centeredLabel(_ ruleX: Double, _ x: Double, under: String) -> String {
        lines(72, 700, 10, 12, "The quick brown fox") + lines(470, 700, 10, 12, "lazy dog") + "0 G 0.4 w \(ContentLexer.number(ruleX)) 680 m \(ContentLexer.number(ruleX)) 640 l S "
            + lines(x, 660, 10, 12, "THE DOG") + under
    }

    @Test func aCenteredLabelWithFreeRoomOnOneSideKeepsItsSize() throws {
        // resnet Table 3's "top-1 err." as "error top-1": a rule close on its left, free room on its right, the next row
        // under it. Centered between the rule and as far again, the longer text shrank; it moves over instead.
        let under = Self.lines(250, 648, 10, 12, "The quick brown fox jumps over a lazy dog")
        let width = Self.read(Self.page(Self.centeredLabel(100, 290, under: under), fontText: Self.letters)).runs.first { $0.text == "THE DOG" }!.box.width
        let pdf = Self.page(Self.centeredLabel(306 - width / 2 - 6, 306 - width / 2, under: under), fontText: Self.letters) // centered on the page
        let label = Self.read(pdf).runs.first { $0.text == "THE DOG" }!.box
        let (_, r) = try Self.translate(pdf) { $0 == "THE DOG" ? "THE QUICK DOG" : $0 }
        let run = try #require(Self.read(r.data!).runs.first { $0.text.contains("QUICK") })
        #expect(TranslationText.trim(run.text) == "THE QUICK DOG")
        #expect(abs(run.fontSize - 10) < 0.01)
        #expect(run.box.x > label.x - 6, "\(run.box)")
        #expect(run.box.bottom < 652, "\(run.box)")
    }

    @Test func aCenteredLabelMovedIntoFreeRoomStaysAboveTheTextUnderThatRoom() throws {
        // The room beside the label has text right under it; under the label itself there is room for two lines. Moved
        // over, two lines would run into that text: it may go only as low as the room it moves into allows.
        let under = Self.lines(420, 648, 10, 12, "lazy dog jumps") + Self.lines(250, 630, 10, 12, "The quick brown fox jumps")
        let width = Self.read(Self.page(Self.centeredLabel(100, 290, under: under), fontText: Self.letters)).runs.first { $0.text == "THE DOG" }!.box.width
        let pdf = Self.page(Self.centeredLabel(306 - width / 2 - 6, 306 - width / 2, under: under), fontText: Self.letters)
        let below = Self.read(pdf).runs.first { $0.text == "lazy dog jumps" }!.box
        let (_, r) = try Self.translate(pdf) { $0 == "THE DOG" ? "THE QUICK BROWN DOG JUMPS OVER THE LAZY FOX AND THE QUICK DOG" : $0 }
        let after = Self.read(r.data!)
        #expect(after.runs.first { $0.text == "lazy dog jumps" }?.box == below)
        let moved = after.runs.filter { $0.text.contains("QUICK") || $0.text.contains("FOX") }
        #expect(!moved.isEmpty)
        for q in moved { #expect(q.box.intersect(below).isEmpty, "\(q.text) \(q.box) over \(below)") }
    }

    @Test func aSpaceTheFontLacksIsAsWideAsItsColumnsWordSpacesNotTheGapToTheNext() throws {
        // resnet Table 3's head row, one operator of pdfTeX's with no space glyph: its word spaces and the gap between its
        // columns are adjustments; counting the gap among the spaces made "error top-1" a space of 1.1 ems too wide.
        let pdf = Self.page("BT /FA 10 Tf 1 0 0 1 72 700 Tm [(top-1) -250 (err.) -3000 (top-5) -250 (err.)] TJ ET", fontText: "top-15err.")
        // Each column's spaces are its own: 0.25 ems, not the average with the 3 ems to the next column.
        let doc = try PdfEdit.open(pdf, nil)
        let columns = try ContentEditor.readRaw(doc, doc.page(0), 0, nil).runs.filter { !trimmed($0.text).isEmpty }.sorted { $0.box.x < $1.box.x }
        #expect(columns.map { trimmed($0.text) } == ["top-1 err.", "top-5 err."])
        #expect(columns.allSatisfy { abs($0.gapEms - 0.25) < 0.001 }, "\(columns.map(\.gapEms))")
        let (_, r) = try Self.translate(pdf) { $0 == "top-1 err." ? "err. top-1" : $0 }
        let run = try #require(Self.read(r.data!).runs.first { $0.text.hasPrefix("err.") })
        #expect(abs(run.fontSize - 10) < 0.01)
    }

    @Test func textTheEditorCantRewriteStaysAndGetsAComment() throws {
        // /ActualText says what it reads as: rewriting it would leave that wrong.
        let content = "/Span <</ActualText (Other)>> BDC BT /FA 12 Tf 1 0 0 1 72 700 Tm (Hello World) Tj ET EMC " + Self.lines(72, 650, 12, 14, "2024 draft!")
        let (plan, r) = try Self.translate(Self.page(content, fontText: Self.letters)) { _ in "THE DOG" }
        #expect(!plan.texts.contains { $0.text == "Hello World" })
        #expect(plan.blocked.contains { $0.why.contains("ActualText") })
        #expect(r.report.notTranslated == 1)
        #expect(r.report.flags.count == 1 && r.report.flags[0].message.contains("isn't translated"))
    }

    @Test func aParagraphWithNoUsableAnswerStaysAndGetsAComment() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "Hello World") + Self.lines(72, 650, 12, 14, "2024 draft!"), fontText: Self.letters)
        let (_, r) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? nil : "THE DOG" }
        #expect(r.report.translated == 1)
        #expect(r.report.notTranslated == 1)
        #expect(r.report.flags.count == 1 && r.report.flags[0].message.contains("refused by the test"))
        #expect(ContentEditPdf.text(r.data!).contains("Hello World"))
    }

    @Test func aScanIsNamedAndItsRecognizedTextIsntRewritten() throws {
        let pdf = Self.page("q 400 0 0 400 72 300 cm /Im1 Do Q BT 3 Tr /FA 12 Tf 1 0 0 1 72 700 Tm (Hello World) Tj ET 0 Tr", fontText: Self.letters)
        let plan = try Translation.makePlan(pdf, nil, [0])
        #expect(plan.texts.isEmpty)
        #expect(plan.scanPages == [0])
    }

    @Test func numbersArentSentAndStay() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "2024") + Self.lines(72, 650, 12, 14, "Hello World"), fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { _ in "THE DOG" }
        #expect(plan.texts.map(\.text) == ["Hello World"])
        #expect(plan.noWords == 1)
        #expect(ContentEditPdf.text(r.data!).contains("2024"))
    }

    @Test func repeatedParagraphsGoOnceAndAllAreWritten() throws {
        let (plan, r) = try Self.translate(TranslationPdf.report(3)) { "\(Self.marked) \($0)" }
        #expect(plan.texts.count == Set(plan.texts.map(\.text)).count)
        #expect(plan.paragraphCount > plan.texts.count) // the table's words are on each page
        #expect(r.report.translated == plan.paragraphCount)
        for p in 0..<3 {
            let text = ContentEditPdf.text(r.data!, page: p)
            #expect(text.contains("\(Self.marked) Growing"), "\(text)")
        }
    }

    @Test func eachTableCellGoesAloneAndStaysInItsCell() throws {
        let (plan, r) = try Self.translate(TranslationPdf.report(1)) { "\(Self.marked) \($0)" }
        for cell in ["Region", "Comment", "North", "South", "East", "Growing fast", "Steady demand", "New stores open"] {
            #expect(plan.texts.contains { $0.text == cell }, "\(cell)")
        }
        #expect(!plan.texts.contains { $0.text.contains("Sales") && $0.text != "Sales" })
        // A translation longer than its narrow cell: it wraps or shrinks, and stays between the rules.
        for run in Self.read(r.data!).runs where run.box.y >= 450 && run.box.bottom <= 450 + 4 * 22 + 1 && run.box.x < 190 && !trimmed(run.text).isEmpty {
            #expect(run.box.right <= 190 + 0.5, "\(run.text): \(run.box.right)")
        }
        #expect(r.report.doNotFit == 0)
    }

    @Test func aFormDrawnTwiceAndAFormOtherPagesShareAreCopiedForEachDrawing() throws {
        // A form drawn twice on one page, with different placements: each drawing gets its own text.
        let pdf = Self.page("q 1 0 0 1 0 0 cm /Fm1 Do Q q 1 0 0 1 0 -100 cm /Fm1 Do Q", Self.lines(72, 700, 12, 14, "Hello World"), fontText: Self.letters)
        let (plan, r) = try Self.translate(pdf) { _ in "THE DOG" }
        #expect(plan.paragraphCount == 2)
        #expect(r.report.translated == 2)
        let text = ContentEditPdf.text(r.data!)
        #expect(text.components(separatedBy: "THE DOG").count - 1 == 2)
        #expect(!text.contains("Hello World"))
    }

    @Test func textInsideAFormIsTranslatedWithThePagesOwnText() throws {
        let pdf = Self.page(Self.lines(72, 700, 12, 14, "2024 draft!") + "/Fm1 Do", Self.lines(72, 600, 12, 14, "Hello World"), fontText: Self.letters)
        let (_, r) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? "THE FOX" : "THE DOG" }
        let text = ContentEditPdf.text(r.data!)
        #expect(text.contains("THE FOX") && text.contains("THE DOG"))
    }

    @Test func textAfterAParagraphStaysWhereItWas() throws {
        // The second paragraph is placed relative to the first by Td: rewriting the first mustn't move it.
        let pdf = Self.page("BT /FA 12 Tf 72 700 Td (Hello World) Tj 0 -40 Td (2024 draft!) Tj ET", fontText: Self.letters)
        let (_, r) = try Self.translate(pdf) { $0.hasPrefix("Hello") ? "THE QUICK BROWN FOX" : "THE DOG" }
        let y = Self.read(r.data!).paragraphs.first { $0.text == "THE DOG" }?.box.y ?? 0
        #expect(y >= 792 - 660 - 14 && y <= 792 - 660 - 6, "\(y)")
    }

    @Test func aTurnedPageIsWrittenUprightAsItShows() throws {
        let pdf = Self.page("q 0 1 -1 0 612 0 cm " + Self.lines(72, 400, 12, 14, "Hello World draft, 2024! Hello World draft, 2024!", "Hello World draft, 2024! Hello World draft, 2024!") + "Q",
                            rotate: 90, fontText: Self.letters)
        let before = try #require(Self.read(pdf).paragraphs.first { $0.text.hasPrefix("Hello") })
        let (_, r) = try Self.translate(pdf) { _ in "The quick brown fox jumps over a lazy dog and goes on over the lazy dog." }
        let after = try #require(Self.read(r.data!).paragraphs.first { $0.text.hasPrefix("The quick") })
        #expect(abs(before.box.x - after.box.x) < 1 && abs(before.box.y - after.box.y) < 1, "\(before.box) → \(after.box)")
    }

    /// A ruled table of 3 rows (a label, its figures) set sideways on an upright page, reading bottom to top as a
    /// landscape table on a portrait page does, under an upright line. In the table's own frame (u along its rows, v up
    /// its columns) the label column is u 100–220, the figures' 220–300, rows 20 high from v 400 down. Returns the page and,
    /// on the page as shown (top-left origin), the label cells.
    static func sidewaysTable() -> (pdf: [UInt8], labelCells: [RectD]) {
        let labels = ["Quick fox", "Lazy dog", "Brown fox"], figures = ["12", "345", "6,789"]
        var sb = lines(72, 740, 12, 14, "The quick brown fox jumps over a lazy dog.")
        // Turned a quarter: (u, v) in the table's frame is (612 - v, u) on the page, in PDF space (y up).
        sb += "q 0 1 -1 0 612 0 cm 0.5 w "
        for r in 0...3 { sb += "100 \(400 - 20 * r) m 300 \(400 - 20 * r) l S " }
        for u in [100, 220, 300] { sb += "\(u) 400 m \(u) 340 l S " }
        sb += "BT /FA 9 Tf "
        for r in 0..<3 { sb += "1 0 0 1 103 \(400 - 20 * r - 14) Tm (\(labels[r])) Tj 1 0 0 1 223 \(400 - 20 * r - 14) Tm (\(figures[r])) Tj " }
        sb += "ET Q"
        // A label cell (u 100–220, v from 400 - 20 r down 20) on the page as shown: x = 612 - v, y = 792 - u.
        let cells = (0..<3).map { r -> RectD in
            let left = Double(612 - (400 - 20 * r)), right = Double(612 - (380 - 20 * r))
            return RectD.fromEdges(left, 792 - 220, right, 792 - 100)
        }
        return (page(sb, fontText: letters), cells)
    }

    @Test func aTableSetSidewaysIsTranslatedCellByCellAndStaysTurnedInItsCells() throws {
        let (pdf, cells) = Self.sidewaysTable()
        let (plan, r) = try Self.translate(pdf) { t in t.unicodeScalars.contains(where: TranslationText.isLetter) ? "\(Self.marked) \(t) and over the lazy dog" : t }
        // Each label goes alone, the figures stay, nothing is named as turned text left in English.
        for label in ["Quick fox", "Lazy dog", "Brown fox"] { #expect(plan.texts.contains { $0.text == label }, "\(label)") }
        #expect(!plan.texts.contains { $0.text.contains("fox") && $0.text.contains("dog") && $0.text.utf16.count < 30 })
        #expect(plan.turnedTextPages.isEmpty)
        #expect(r.report.translated == 4)
        // Its rows and columns were found with the page turned so the table reads left to right: 3 rows of 2 cells.
        #expect(plan.pages[0].turnedCells[3]?.count == 6)
        #expect(plan.pages[0].cells.isEmpty)

        let after = Self.read(r.data!)
        let text = ContentEditPdf.text(r.data!)
        for cell in cells {
            // Its new text reads as the old did (bottom to top), and stays between the cell's rules.
            let mine = after.runs.filter { !trimmed($0.text).isEmpty && cell.contains($0.box.centerX, $0.box.centerY) }
            #expect(!mine.isEmpty)
            #expect(mine.contains { $0.text.contains(Self.marked) || $0.text.contains("lazy") })
            for q in mine {
                #expect(abs(ContentEditor.turn(q.angle) + 90) < 0.1)
                #expect(q.box.x >= cell.x - 0.5 && q.box.right <= cell.right + 0.5 && q.box.y >= cell.y - 0.5 && q.box.bottom <= cell.bottom + 0.5,
                        "\(q.text): \(q.box) outside \(cell)")
            }
        }
        for figure in ["12", "345", "6,789"] { #expect(text.contains(figure)) }
    }

    @Test func textOfAnotherDirectionOnAParagraphsLinesIsInItsWay() throws {
        // A label set sideways (bottom to top, its baseline at x 300 from y 100 up, PDF space), an upright line across its
        // path (y 250) and an upright line beside it (y 120, from x 72): each translation grows, and none runs over the
        // other direction's text.
        let content = "BT /FA 12 Tf 1 0 0 1 280 250 Tm (Lazy dog) Tj 1 0 0 1 72 120 Tm (Brown dog) Tj ET q 0 1 -1 0 300 0 cm BT /FA 12 Tf 1 0 0 1 100 0 Tm (Quick fox) Tj ET Q"
        let (_, r) = try Self.translate(Self.page(content, fontText: Self.letters)) { "\($0) and the quick brown fox jumps over the lazy dog" }
        let after = Self.read(r.data!).runs.filter { !trimmed($0.text).isEmpty }
        let sideways = after.filter { abs($0.angle) >= 0.5 }, upright = after.filter { abs($0.angle) < 0.5 }
        #expect(sideways.contains { $0.text.contains("Quick fox and") })
        #expect(upright.contains { $0.text.contains("Brown dog and") })
        for s in sideways {
            for u in upright {
                let x = s.box.intersect(u.box)
                #expect(!(x.width > 0.5 && x.height > 0.5), "\"\(s.text)\" \(s.box) runs over \"\(u.text)\" \(u.box)")
            }
        }
    }
}
