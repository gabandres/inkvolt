import Foundation
import Testing
import PrintCore
@testable import PdfCore

/// Ported from EditableTextTests.cs: Make Text Editable (roadmap 2.2, for 2.1): a scan's recognized words become real text
/// in the installed font closest to the scan's, at their size and place, the scan covered behind them, so a paragraph can
/// be edited. The scans are corpus pages typeset in a known font (`ScanCorpus`), their words boxed as a recognizer boxes
/// them (each word's own ink, as Windows' and Tesseract's are, or its line's height). Adapted: the JPEGs are ImageIO's,
/// the RGB page is the Mac's own order.
struct EditableTextTests {
    static let dpi = 300.0

    /// A corpus page as a scan (its typeset text rendered at 300 dpi on paper of `paper`, as a JPEG) with an invisible text
    /// layer of its words, boxed around each word's ink (or, `lineBoxes`, its line's height); and the words, in order, with
    /// where the typeset page has them.
    static func scan(_ file: CorpusFile, lineBoxes: Bool = false, paper: Int = 255, angle: Double = 0) throws -> (scan: [UInt8], words: [OcrWord]) {
        let (scan, words) = try scans(ScanCorpus.textPdf(file).pdf, [0], lineBoxes: lineBoxes, paper: paper, angle: angle)
        return (scan, words[0])
    }

    /// `pages` of a typeset PDF as a scan (grey JPEGs, or with `color` flate-compressed RGB), each with an invisible text
    /// layer of its words boxed as a recognizer boxes them (see `scan`).
    static func scans(_ typeset: [UInt8], _ pages: [Int], lineBoxes: Bool = false, paper: Int = 255, angle: Double = 0,
                      color: Bool = false) throws -> (scan: [UInt8], words: [[OcrWord]]) {
        let engine = try PdfEngine.open(typeset)
        defer { engine.close() }
        var jpegs: [(jpeg: [UInt8], width: Int, height: Int)] = []
        var rgbs: [(rgb: [UInt8], width: Int, height: Int)] = []
        var all: [[OcrWord]] = []
        for pageIndex in pages {
            let image = try engine.render(pageIndex, scale: dpi / 72)
            let (w, h) = (image.width, image.height)
            var gray = [UInt8](repeating: 0, count: w * h)
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x, o = y * image.stride + x * 3
                    for c in 0..<3 { rgb[3 * i + c] = UInt8(30 + (paper - 30) * Int(image.pixels[o + c]) / 255) }
                    let ink = (Int(image.pixels[o + 2]) * 29 + Int(image.pixels[o + 1]) * 150 + Int(image.pixels[o]) * 77) >> 8
                    gray[i] = UInt8(30 + (paper - 30) * ink / 255)
                }
            }
            if color { rgbs.append((rgb, w, h)) } else { jpegs.append((try ScanCorpus.jpeg(gray, w, h, quality: 0.9), w, h)) }

            // Each word as a recognizer boxes it.
            let text = try engine.text(pageIndex)
            let units = Array(text.text.utf16)
            var found: [(text: String, em: RectD, ink: RectD)] = []
            var i = 0
            func space(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 || u == 0xA0 }
            while i < units.count {
                if space(units[i]) {
                    i += 1
                    continue
                }
                let start = i
                while i < units.count && !space(units[i]) { i += 1 }
                let em = text.rects(start, i).reduce(text.rects(start, i)[0]) { $0.union($1) }
                // Its own ink: the dark pixels inside the box the text has.
                let (x0, y0) = (Int(em.x * dpi / 72), Int(em.y * dpi / 72))
                let (x1, y1) = (Int((em.right * dpi / 72).rounded(.up)), Int((em.bottom * dpi / 72).rounded(.up)))
                var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
                if max(0, y0) < min(h, y1) && max(0, x0) < min(w, x1) {
                    for y in max(0, y0)..<min(h, y1) {
                        for x in max(0, x0)..<min(w, x1) where gray[y * w + x] < 128 {
                            (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                        }
                    }
                }
                if maxX < 0 { continue }
                let word = String(decoding: units[start..<i], as: UTF16.self)
                found.append((word, em, RectD(Double(minX) * 72 / dpi, Double(minY) * 72 / dpi, Double(maxX - minX + 1) * 72 / dpi, Double(maxY - minY + 1) * 72 / dpi)))
            }
            var words: [OcrWord] = []
            for (word, em, ink) in found {
                var box = ink
                if lineBoxes {
                    // Its line's height: from the highest ink on its line to the lowest.
                    let line = found.filter { abs($0.em.centerY - em.centerY) < 1 }
                    let (top, bottom) = (line.map(\.ink.y).min()!, line.map(\.ink.bottom).max()!)
                    box = RectD(ink.x, top, ink.width, bottom - top)
                }
                if angle != 0 {
                    // A skewed scan's word: its centre turned with the page about the page's middle.
                    let (s, c) = (sin(angle * .pi / 180), cos(angle * .pi / 180))
                    let (dx, dy) = (box.centerX - 306, box.centerY - 396)
                    let (cx, cy) = (306 + dx * c - dy * s, 396 + dx * s + dy * c)
                    box = RectD(cx - box.width / 2, cy - box.height / 2, box.width, box.height)
                }
                words.append(OcrWord(word, box, angle: angle))
            }
            all.append(words)
        }
        let scan = color ? rgbPdf(rgbs) : ScanCorpus.scanPdf(ScanCorpus.files[0], jpegs)
        var layers: [Int: [OcrWord]] = [:]
        for (i, w) in all.enumerated() { layers[i] = w }
        return (try TextLayer.addInvisibleText(scan, nil, layers, language: "en-US"), all)
    }

    /// RGB pages at 300 dpi, one image filling each.
    private static func rgbPdf(_ pages: [(rgb: [UInt8], width: Int, height: Int)]) -> [UInt8] {
        var writer = CorpusPdf()
        let parent = writer.reserve()
        var kids: [Int] = []
        for (rgb, width, height) in pages {
            let (pw, ph) = (Double(width) * 72 / dpi, Double(height) * 72 / dpi)
            let image = writer.addStream("/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8", rgb)
            let content = writer.addStream("", Array("q \(PdfNum.f2(pw)) 0 0 \(PdfNum.f2(ph)) 0 0 cm /Im0 Do Q".utf8))
            kids.append(writer.add("<< /Type /Page /Parent \(parent) 0 R /MediaBox [0 0 \(PdfNum.f2(pw)) \(PdfNum.f2(ph))] /Resources << /XObject << /Im0 \(image) 0 R >> >> /Contents \(content) 0 R >>"))
        }
        writer.put(parent, "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>")
        let catalog = writer.add("<< /Type /Catalog /Pages \(parent) 0 R >>")
        return writer.finish(catalog)
    }

    private static var times: CorpusFile { ScanCorpus.file("en-skew3-light") } // Times-Roman 11 pt

    private static var helvetica: CorpusFile { ScanCorpus.file("en-skew6-noisy") } // Helvetica 10 pt

    private static func wordsOf(_ data: [UInt8]) throws -> [String] {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        return try engine.text(0).text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    @Test(.enabled(if: ScanCorpus.runs), arguments: [false, true])
    func recognizedWordsBecomeTextInTheFontTheyWereSetIn(_ lineBoxes: Bool) throws {
        for (file, family, size) in [(Self.times, "Times New Roman", 11.0), (Self.helvetica, "Arial", 10.0)] {
            let (scan, words) = try Self.scan(file, lineBoxes: lineBoxes)
            #expect(try EditableText.pages(scan, nil) == [0])
            let made = try EditableText.make(scan, nil, pages: [0], keepScan: false)
            #expect(made.pages == 1 && made.words == words.count)
            // The body in its family (Helvetica's shapes are Arial's), the Helvetica-Bold heading in Arial's bold face:
            // picked by how the words look set in each installed face where the scan has them.
            #expect([family, "Arial Bold"].sorted() == made.fonts.sorted(), "\(file.name): \(made.fonts.joined(separator: ", "))")

            // The words read back in order, once each: the invisible layer is gone.
            #expect(try Self.wordsOf(made.data) == words.map(\.text))
            #expect(try TextLayer.words(made.data, nil).isEmpty)
            #expect(try EditableText.pages(made.data, nil).isEmpty)

            // At the size and place the scan has them.
            let content = try ContentEditor.read(made.data, nil, 0)
            let body = content.runs.filter { $0.fontSize < 14 }
            for r in body { #expect(abs(r.fontSize - size) <= (lineBoxes ? 0.5 : 0.35), "\(file.name): \(r.fontSize)") }
            let engine = try PdfEngine.open(made.data)
            defer { engine.close() }
            let text = try engine.text(0)
            var off = 0.0
            for word in words.filter({ $0.text.count >= 5 }).prefix(60) {
                let hits = text.find(word.text, matchCase: true, wholeWord: false).map { f in text.rects(f.start, f.end).reduce(text.rects(f.start, f.end)[0]) { $0.union($1) } }
                let hit = try #require(hits.min { abs($0.centerY - word.rect.centerY) + abs($0.x - word.rect.x) < abs($1.centerY - word.rect.centerY) + abs($1.x - word.rect.x) })
                off = max(off, abs(hit.x - word.rect.x))
                #expect(hit.centerY >= word.rect.y - 2 && hit.centerY <= word.rect.bottom + 2)
            }
            #expect(off < 1.5, "\(file.name): a word starts \(off) pt from the scan's")
        }
    }

    @Test(.enabled(if: ScanCorpus.runs)) func itsParagraphsCanBeEditedAsParagraphs() throws {
        let (scan, _) = try Self.scan(Self.times)
        let made = try EditableText.make(scan, nil, pages: [0], keepScan: false).data
        let content = try ContentEditor.read(made, nil, 0)
        // The typeset page's paragraphs: lines of one font, size, step and left edge, joined as 2.1 joins them.
        let paragraphs = content.paragraphs.filter { $0.lines.count >= 2 }
        #expect(paragraphs.count >= 3, "\(paragraphs.count) paragraphs of two lines or more")
        #expect(paragraphs.allSatisfy { $0.blocked == nil }, "\(paragraphs.compactMap(\.blocked))")
        let lines = content.paragraphs.reduce(0) { $0 + $1.lines.count }
        #expect(Double(paragraphs.reduce(0) { $0 + $1.lines.count }) >= 0.8 * Double(lines), "most lines are in paragraphs")

        let first = try #require(paragraphs.min { $0.box.y < $1.box.y })
        let edited = try ContentEditor.replaceParagraph(made, nil, first, first.text + " Seven added words keep their paragraph here.", allowOverlap: true)
        let words = try Self.wordsOf(edited).joined(separator: " ")
        #expect(words.contains("Seven added words keep their paragraph here."))
        #expect(words.contains(first.text.split(separator: " ").last.map(String.init) ?? "?"))
    }

    @Test(.enabled(if: ScanCorpus.runs)) func theScanIsCoveredBehindTheTextInThePapersColourOrKept() throws {
        let (scan, words) = try Self.scan(Self.times, paper: 205)
        let covered = try EditableText.make(scan, nil, pages: [0], keepScan: false).data
        let kept = try EditableText.make(scan, nil, pages: [0], keepScan: true).data

        // Between two words of a line, at their middle height: the paper's grey where the scan is covered, never white.
        let pair = try #require(zip(words, words.dropFirst()).first { a, b in
            a.text.count > 3 && abs(a.rect.centerY - b.rect.centerY) < 1 && b.rect.x - a.rect.right > 2
        })
        let space = pair.1.rect.x - pair.0.rect.right
        let gap = RectD(pair.0.rect.right + 0.3 * space, pair.0.rect.centerY - 0.5, 0.4 * space, 1)
        let grey = try Self.gray(covered, gap)
        #expect(grey >= 190 && grey <= 220, "\(grey)")

        // Under a word, what shows is the new text alone where the scan is covered; kept, the scan's ink shows too.
        #expect(try Self.darkness(kept, pair.0.rect) >= Self.darkness(covered, pair.0.rect))
        #expect(try Core2Pdf.ink(covered, 0, pair.0.rect) > 0.05)
    }

    private static func gray(_ data: [UInt8], _ region: RectD) throws -> Double {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let img = try engine.render(0, scale: 4, region: region)
        var sum = 0.0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let o = y * img.stride + x * 3
                sum += Double(Int(img.pixels[o]) + Int(img.pixels[o + 1]) + Int(img.pixels[o + 2])) / 3
            }
        }
        return sum / Double(img.width * img.height)
    }

    private static func darkness(_ data: [UInt8], _ region: RectD) throws -> Double { 255 - (try gray(data, region)) }

    @Test(.enabled(if: ScanCorpus.runs)) func wordsOnASkewedScanBecomeTextAtTheirAngle() throws {
        // A scan recognized without replacing it: its words carry its skew.
        let (scan, words) = try Self.scan(Self.times, angle: 3)
        let made = try EditableText.make(scan, nil, pages: [0], keepScan: false)
        #expect(try Self.wordsOf(made.data) == words.map(\.text))
        let content = try ContentEditor.read(made.data, nil, 0)
        for r in content.runs where !r.text.trimmingCharacters(in: .whitespaces).isEmpty { #expect(abs(r.angle - 3) <= 0.1, "\(r.angle)") }
        #expect(content.paragraphs.contains { $0.lines.count >= 2 && $0.blocked == nil && abs($0.angle - 3) < 0.1 })
    }

    @Test(.enabled(if: ScanCorpus.runs)) func onlyThePagesAskedForAndWithRecognizedTextChange() throws {
        let (scan, words) = try Self.scan(Self.times)
        // A second page, a copy without a text layer.
        let two = try PageEditor.insertBlank(scan, nil, 1, 1, 612, 792)
        var made = try EditableText.make(two, nil, pages: [1, 5, -1], keepScan: false)
        #expect(made.pages == 0)
        #expect(made.data == two)
        made = try EditableText.make(two, nil, pages: [0, 1], keepScan: false)
        #expect(made.pages == 1 && made.words == words.count)
    }

    @Test func wordsNoPageHasAreLeftOut() throws {
        let words = [
            OcrWord("ok", RectD(72, 100, 12, 8)),
            OcrWord(String(repeating: "x", count: EditableText.maxWordLength + 1), RectD(90, 100, 400, 8)),
            OcrWord("flat", RectD(72, 120, 20, 0)),
            OcrWord("   ", RectD(72, 140, 20, 8)),
        ]
        let plan = try #require(try EditableText.plan(words))
        #expect(plan.lines.count == 1)
        #expect(plan.lines.first?.words.map(\.text) == ["ok"])
        #expect(try EditableText.plan([]) == nil)
        // Many thousands: only so many are made text.
        let many = (0..<(EditableText.maxWords + 50)).map { i in OcrWord("w\(i)", RectD(72 + Double(i % 40) * 12, 20 + Double(i / 40) * 0.5, 10, 8)) }
        #expect(try EditableText.plan(many)?.lines.reduce(0) { $0 + $1.words.count } == EditableText.maxWords)
    }

    /// .NET's bench `Prose` words, which the typeset page below draws from with the same generator.
    private static let prose = [
        "the", "a", "and", "of", "to", "in", "that", "with", "for", "on", "by", "from", "as", "at", "but", "not", "this", "which", "or", "an",
        "river", "lantern", "harbor", "window", "meadow", "ledger", "engine", "bridge", "garden", "letter", "market", "valley", "signal", "copper",
        "quarry", "orchard", "compass", "granite", "thunder", "candle", "willow", "saddle", "anchor", "barrel", "beacon", "canvas", "cellar",
        "chapel", "cobble", "cotton", "dagger", "ember", "falcon", "fossil", "furnace", "glacier", "hammer", "harvest", "hollow", "island",
        "jacket", "kettle", "lumber", "marble", "mirror", "needle", "oyster", "parcel", "pillar", "pocket", "quiver", "ribbon", "rudder",
        "shadow", "silver", "spring", "stable", "summit", "tunnel", "turret", "velvet", "wagon", "walnut", "whistle", "winter", "yonder",
        "walks", "turns", "carries", "builds", "finds", "holds", "keeps", "leaves", "meets", "opens", "reads", "sends", "stands", "takes",
        "waits", "writes", "measures", "returns", "follows", "answers", "gathers", "crosses", "remains", "settles", "remembers", "counts",
        "quiet", "early", "narrow", "steady", "bright", "distant", "hollow", "patient", "simple", "sudden", "little", "broad", "plain",
        "heavy", "gentle", "ancient", "careful", "common", "eager", "formal", "honest", "modest", "narrow", "proper", "rough", "sharp",
        "slowly", "often", "again", "almost", "rather", "nearly", "still", "already", "perhaps", "later", "before", "after", "between",
        "morning", "evening", "season", "village", "country", "station", "journey", "history", "minute", "moment", "number", "reason",
        "weather", "account", "balance", "chapter", "company", "council", "customs", "deposit", "freight", "invoice", "manager", "meeting",
        "notice", "office", "payment", "project", "record", "report", "request", "schedule", "service", "summary", "survey", "ticket",
    ]

    /// A typeset page of four paragraphs: Times, Times italic, Times again, and Times in dark blue; each four lines of 12 pt
    /// on 17.
    static func looksPdf() -> [UInt8] {
        var rng = Rng(5)
        let words = (0..<200).map { _ in prose[rng.next(prose.count)] }
        var ops = ""
        var y = 720.0
        var n = 0
        for (font, color) in [("/F1", "0 g"), ("/F2", "0 g"), ("/F1", "0 g"), ("/F1", "0.05 0.1 0.6 rg")] {
            for _ in 0..<4 {
                let line = (0..<8).map { _ -> String in
                    defer { n += 1 }
                    return words[n % words.count]
                }.joined(separator: " ")
                ops += "BT \(color) \(font) 12 Tf 72 \(PdfNum.f2(y)) Td (\(line)) Tj ET\n"
                y -= 17
            }
            y -= 12
        }
        return Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >> /F2 << /Type /Font /Subtype /Type1 /BaseFont /Times-Italic >> >> >> >>",
            Core2Pdf.stream(ops),
        ])
    }

    @Test(.enabled(if: ScanCorpus.runs)) func anItalicParagraphIsItalicAndAColouredOneKeepsItsColour() throws {
        let (scan, _) = try Self.scans(Self.looksPdf(), [0], color: true)
        let made = try EditableText.make(scan, nil, pages: [0], keepScan: false)
        let content = try ContentEditor.read(made.data, nil, 0)
        #expect(made.fonts.sorted() == ["Times New Roman", "Times New Roman Italic"].sorted(),
                "\(made.fonts) | \(content.runs.map { "\($0.fontName) \($0.fontSize) \(Int($0.box.y)): \($0.text.prefix(20))" })")
        let paragraphs = content.paragraphs.sorted { $0.box.y < $1.box.y }
        #expect(paragraphs.count == 4)
        #expect(paragraphs.allSatisfy { $0.lines.count == 4 })
        guard paragraphs.count == 4 else { return }
        #expect((paragraphs[0].runs + paragraphs[2].runs).allSatisfy { !$0.italic })
        #expect(paragraphs[1].runs.allSatisfy { $0.fontName.contains("Italic") }, "\(paragraphs[1].runs.map(\.fontName))")
        #expect(paragraphs.prefix(3).flatMap(\.runs).allSatisfy { $0.color == 0 })
        // The blue paragraph: blue, near the typeset 0.05 0.1 0.6 as the scan shows it.
        for r in paragraphs[3].runs {
            let (red, green, blue) = (r.color >> 16 & 255, r.color >> 8 & 255, r.color & 255)
            #expect(blue > 100 && red < 60 && green < 80, "\(red),\(green),\(blue)")
        }
    }

    @Test(.enabled(if: ScanCorpus.runs)) func makingPagesEditableTakesUnderASecondAPage() throws {
        // Two corpus pages: the first chooses among the installed families, the second compares the short list.
        let typeset = ScanCorpus.textPdf(Self.times).pdf
        let (scan, words) = try Self.scans(typeset, [0, 1])
        _ = try EditableText.make(scan, nil, pages: [0], keepScan: false) // fonts loaded once for the run, as in the app after its first use
        let start = Date()
        let made = try EditableText.make(scan, nil, pages: [0, 1], keepScan: false)
        let perPage = Date().timeIntervalSince(start) / 2
        #expect(made.pages == 2 && made.words == words.reduce(0) { $0 + $1.count })
        // Windows: 0.58 s a page in a Release build. `swift test` builds for debugging, several times slower: only a gross
        // slip fails it.
        #expect(perPage < 10, "\(perPage) s a page")
    }

    @Test func wordsOnBothSidesOfHalfATurnAreOneLine() throws {
        // An upside-down page read through a warp: its words' angles straddle ±180°.
        let words = [
            OcrWord("upside", RectD(400, 300, 40, 10), angle: 179.9),
            OcrWord("down", RectD(361, 300.1, 34, 10), angle: -179.9),
            OcrWord("line", RectD(330, 300.2, 26, 10), angle: 179.95),
        ]
        let groups = EditableText.byAngle(words)
        #expect(groups.count == 1)
        #expect(abs(Angles.difference(groups[0].angle, 180)) <= 0.5)
        let lines = try #require(try EditableText.plan(words)).lines
        #expect(lines.count == 1)
        #expect(lines.first?.words.map(\.text) == ["upside", "down", "line"])

        // The invisible layer spaces them as one line too.
        let scan = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
            Core2Pdf.stream("0.9 g 0 0 10 10 re f"),
        ])
        let data = try TextLayer.addInvisibleText(scan, nil, [0: words])
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        #expect(try engine.text(0).text.contains("upside down line"))
    }

    /// Reads the topmost line of ink as four words, quarters of its width.
    struct QuarterReader: TextRecognizer {
        var language: String? { "en-US" }

        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
            let (width, height) = (image.width, image.height)
            func dark(_ x: Int, _ y: Int) -> Bool { image.pixels[y * image.stride + x * 3] < 128 }
            func ink(_ y: Int) -> Int { (0..<width).filter { dark($0, y) }.count }
            guard let top = (0..<height).first(where: { ink($0) > 3 }) else { return [] }
            var bottom = top
            while bottom + 1 < height && ink(bottom + 1) > 0 { bottom += 1 }
            let xs = (top...bottom).flatMap { y in (0..<width).filter { dark($0, y) } }
            let left = Double(xs.min() ?? 0), w = Double((xs.max() ?? 0) - (xs.min() ?? 0) + 1) / 4
            return (0..<4).map { i in
                OcrWord("word\(i)", RectD(Double(Int(left + Double(i) * w)), Double(top), Double(Int(w * 0.9)), Double(bottom - top + 1)))
            }
        }
    }

    @Test(.enabled(if: ScanCorpus.runs)) func anUpsideDownBentPageReadsAsOneLineAtHalfATurn() throws {
        // A book's page photographed upside down: flattened, turned over, and its top line's words, mapped back, are near 180°.
        let (px, w, h, _) = try PhotoCorpus.photo(PhotoCorpus.file("en-book"))
        let turned = ScanCleanup.turn(px, w, h, 1, 2)
        let pdf = ScanCorpus.scanPdf(ScanCorpus.files[0], [(try ScanCorpus.jpeg(turned, w, h, quality: 0.85), w, h)])
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let read = try ScanText.recognize(engine, 0, QuarterReader(), RecognizeOptions(checkWords: false, curvedLines: true))
        #expect(read.quarterTurns == 2)
        for x in read.words { #expect(abs(Angles.difference(x.angle, 180)) <= 10, "\(x.angle)") }
        let lines = try #require(try EditableText.plan(read.words)).lines
        #expect(lines.count == 1)
        #expect(lines.first?.words.count == 4)
    }
}
