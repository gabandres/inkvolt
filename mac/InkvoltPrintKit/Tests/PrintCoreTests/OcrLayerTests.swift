import Foundation
import Testing
@testable import PrintCore

/// The scan PDF's text layer (roadmap 2.3): a CID font with a /ToUnicode map. Ported from OcrLayerTests.cs with the same
/// names; read here byte by byte, with no PDF library. What MuPDF and pdf.js make of the same files is in pdf/tests
/// (OcrLayerSearchTests, Windows). A Swift string can't hold half a surrogate pair: those cases come in as U+FFFD, which is
/// left out the same way.
struct OcrLayerTests {
    private static let jpeg = TestJpeg.build(width: 2550, height: 3300, dnlHeight: nil)

    private static func at(_ text: String, x: Double = 300, y: Double = 300, w: Double = 600, h: Double = 60) -> PdfWriter.Word {
        PdfWriter.Word(text, x: x, y: y, width: w, height: h)
    }

    private static func pdf(_ words: PdfWriter.Word...) throws -> String { try pdf([PdfWriter.Page(jpeg, dpi: 300, words: words)]) }

    private static func pdf(_ pages: [PdfWriter.Page], title: String? = "Scan") throws -> String {
        let bytes = try PdfWriter.write(pages, title: title)
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    // MARK: Reading the file

    /// Each match's groups (0 the whole match) and where the match starts and ends, in the file's bytes.
    private static func matches(_ pattern: String, _ text: String) -> [(groups: [String], start: Int, end: Int)] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            ((0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) },
             m.range.location, m.range.location + m.range.length)
        }
    }

    private static func substring(_ text: String, _ from: Int, _ length: Int) -> String {
        (text as NSString).substring(with: NSRange(location: from, length: length))
    }

    private static func hexBytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return Swift.stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(decoding: digits[$0...($0 + 1)], as: UTF8.self), radix: 16)! }
    }

    private static func utf16BE(_ bytes: [UInt8]) -> String {
        String(decoding: Swift.stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }, as: UTF16.self)
    }

    private static func be16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
    private static func s16(_ b: [UInt8], _ at: Int) -> Int { Int(Int16(bitPattern: UInt16(be16(b, at)))) }
    private static func be32(_ b: [UInt8], _ at: Int) -> UInt32 { UInt32(be16(b, at)) << 16 | UInt32(be16(b, at + 2)) }

    /// Every code's text in the ToUnicode map, checking its syntax and each block's limit of 100 entries.
    private static func toUnicode(_ pdf: String) -> [Int: String] {
        guard let start = pdf.range(of: "begincmap"), let end = pdf.range(of: "endcmap", range: start.upperBound..<pdf.endIndex) else {
            Issue.record("no ToUnicode CMap in the file")
            return [:]
        }
        let cmap = String(pdf[start.lowerBound..<end.lowerBound])
        #expect(cmap.contains("<0000> <FFFF>"))
        for block in matches(#"(\d+) beginbfchar(.*?)endbfchar"#, cmap) {
            let n = Int(block.groups[1])!
            #expect((1...100).contains(n))
            #expect(matches(#"<[0-9A-F]{4}> <[0-9A-F]+>"#, block.groups[2]).count == n)
        }
        var map: [Int: String] = [:]
        for entry in matches(#"<([0-9A-F]{4})> <([0-9A-F]+)>\r?\n"#, cmap) {
            if entry.groups[1] == "0000" && entry.groups[2] == "FFFF" { continue }
            let utf16 = hexBytes(entry.groups[2])
            #expect(entry.groups[2].count % 4 == 0)
            let code = Int(entry.groups[1], radix: 16)!
            #expect(map[code] == nil, "code \(code) twice")
            map[code] = utf16BE(utf16)
        }
        return map
    }

    /// What each word's hex string in the content says through the map, in writing order, spaces included.
    private static func shown(_ pdf: String) -> [String] {
        let map = toUnicode(pdf)
        return matches(#"<([0-9A-F]+)> Tj"#, pdf).map { tj in
            #expect(tj.groups[1].count % 4 == 0)
            let codes = hexBytes(tj.groups[1])
            return Swift.stride(from: 0, to: codes.count - 1, by: 2).map { map[be16(codes, $0)] ?? "�" }.joined()
        }
    }

    private static func contentOf(_ pdf: String) -> String {
        guard let start = pdf.range(of: "BT 3 Tr"), let end = pdf.range(of: "ET\n", range: start.upperBound..<pdf.endIndex) else { return "" }
        return String(pdf[start.lowerBound..<end.lowerBound])
    }

    private static func number(_ pattern: String, _ text: String) -> Double { Double(matches(pattern, text).first?.groups[1] ?? "") ?? .nan }

    // MARK: Words

    @Test func nonLatinWordsKeepTheirLetters() throws {
        let words = ["Καλημέρα", "Привет", "東京都庁", "中华人民共和国", "안녕하세요", "नमस्ते", "Hello"]
        let pdf = try Self.pdf([PdfWriter.Page(Self.jpeg, dpi: 300, words: words.enumerated().map { Self.at($0.element, y: 100 + Double($0.offset) * 100) })])
        #expect(Self.shown(pdf) == words)
        #expect(!Self.shown(pdf).joined().contains("?"))
    }

    @Test func theFontIsACompositeFontWithAUnicodeMap() throws {
        let pdf = try Self.pdf(Self.at("Привет"))
        #expect(pdf.contains("/Subtype /Type0"))
        #expect(pdf.contains("/Encoding /Identity-H"))
        #expect(pdf.contains("/Subtype /CIDFontType2"))
        #expect(pdf.contains("/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>"))
        #expect(!Self.matches(#"/ToUnicode \d+ 0 R"#, pdf).isEmpty)
        #expect(!Self.matches(#"/FontFile2 \d+ 0 R"#, pdf).isEmpty)
        #expect(!Self.matches(#"/CIDToGIDMap \d+ 0 R"#, pdf).isEmpty)
        #expect(!pdf.contains("WinAnsiEncoding"))
    }

    @Test func charactersOutsideTheFirstPlaneAreOneCodeWithASurrogatePair() throws {
        let pdf = try Self.pdf(Self.at("𠮷野家"))
        #expect(Self.toUnicode(pdf).values.contains("𠮷"))
        #expect(!Self.matches(#"<[0-9A-F]{4}> <D842DFB7>"#, pdf).isEmpty) // U+20BB7, as two UTF-16 units in big-endian
        #expect(Self.shown(pdf) == ["𠮷野家"])
        #expect(Self.matches(#"<([0-9A-F]+)> Tj"#, pdf)[0].groups[1].count / 4 == 3)
    }

    @Test func aLetterAndItsMarksAreOneCode() throws {
        let pdf = try Self.pdf(Self.at("नमस्ते"))
        let codes = Self.matches(#"<([0-9A-F]+)> Tj"#, pdf)[0].groups[1].count / 4
        #expect(codes < "नमस्ते".utf16.count, "\(codes) codes")
        #expect(Self.toUnicode(pdf).values.map { String($0.unicodeScalars.prefix(2)) }.contains("स्"))
    }

    @Test func aRightToLeftWordIsTurnedRoundCharacterByCharacterMarksToo() throws {
        // pdf.js and MuPDF turn it back the same way; reversing by cluster would leave each mark on the wrong side of its letter when read back.
        let word = "שָׁלום".precomposedStringWithCanonicalMapping
        let pdf = try Self.pdf(Self.at(word))
        var written = String.UnicodeScalarView()
        written.append(contentsOf: word.unicodeScalars.reversed())
        #expect(Self.shown(pdf) == [String(written)])
        for v in Self.toUnicode(pdf).values { #expect(v.unicodeScalars.count == 1) }
    }

    @Test func decomposedLettersAreWrittenComposedSoATypedSearchFindsThem() throws {
        let decomposed = "Чайка" // и + breve
        #expect(Self.shown(try Self.pdf(Self.at(decomposed))) == ["Чайка"])
    }

    @Test(arguments: [
        ("مرحبا", "ابحرم"),
        ("שלום", "םולש"),
        ("عام2026", "2026ماع"), // digits keep their order: pdf.js and MuPDF read them forward
        ("2026عام", "ماع2026"),
        ("٢٠٢٦", "٢٠٢٦"),
        ("مبلغ 1,234.50 ريال", "لاير 1,234.50 غلبم"),
        ("(كلمة)", ")ةملك("),
    ] as [(String, String)])
    func rightToLeftWordsAreWrittenInVisualOrder(_ word: String, _ written: String) throws {
        #expect(Self.shown(try Self.pdf(Self.at(word))) == [written])
    }

    @Test func latinWordsAreLeftAlone() throws {
        #expect(Self.shown(try Self.pdf(Self.at("Hello (world)", y: 100), Self.at("a\\b", y: 300), Self.at("100%", y: 500))) == ["Hello (world)", "a\\b", "100%"])
    }

    @Test(arguments: [
        String(decoding: [0xD83D] as [UInt16], as: UTF16.self), // a lone high surrogate
        String(decoding: [0xDC00] as [UInt16], as: UTF16.self),
        "\u{0000}",
        "\u{200F}", // only a direction mark
        "\u{FEFF}",
        "\u{FFFF}",
        "\u{001F}\u{0007}",
        "   ",
        "",
    ])
    func aWordWithNothingLeftToShowIsLeftOut(_ text: String) throws {
        #expect(Self.shown(try Self.pdf(Self.at(text), Self.at("kept", y: 500))) == ["kept"])
    }

    @Test(arguments: [
        (String(decoding: [0x61, 0xD83D, 0x62] as [UInt16], as: UTF16.self), "ab"),
        ("\u{200F}שלום\u{200E}", "םולש"), // direction marks would split a search
        ("\u{FEFF}word\u{FEFF}", "word"),
        ("tab\there", "tabhere"),
        ("  padded  ", "padded"),
        ("(((", "((("),
        (">><<", ">><<"),
        ("%PDF-1.7 endobj", "%PDF-1.7 endobj"),
    ] as [(String, String)])
    func unusualWordsStayValid(_ text: String, _ shown: String) throws {
        let pdf = try Self.pdf(Self.at(text))
        #expect(Self.shown(pdf) == [shown])
        #expect(Self.contentOf(pdf).unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) || $0 == "\n" })
        Self.xrefPointsAtObjects(pdf)
    }

    @Test(arguments: [
        (Double.nan, 10, 10, 10),
        (10, Double.infinity, 10, 10),
        (10, 10, Double.nan, 10),
        (10, 10, 10, Double.nan),
        (10, 10, 10, 0),
        (10, 10, 10, -5),
    ] as [(Double, Double, Double, Double)])
    func aBoxNoPageCanHaveIsLeftOut(_ x: Double, _ y: Double, _ w: Double, _ h: Double) throws {
        let pdf = try Self.pdf(Self.at("gone", x: x, y: y, w: w, h: h), Self.at("kept", y: 500))
        #expect(Self.shown(pdf) == ["kept"])
        #expect(!pdf.contains("nan") && !pdf.contains("NaN"))
        #expect(!pdf.contains("inf") && !pdf.contains("Infinity"))
        #expect(!pdf.contains("∞"))
    }

    @Test(arguments: [0.0, 1e-9, 1e7]) // no width at all, nearly none, far too much
    func textScalingStaysInARangeViewersAccept(_ width: Double) throws {
        let tz = Self.number(#"([\d.]+) Tz"#, Self.contentOf(try Self.pdf(Self.at("word", w: width))))
        #expect(tz >= 1 && tz <= 1000, "\(tz)")
    }

    @Test func aTinyBoxStillGetsARealFontSize() throws {
        let size = Self.number(#"/F1 ([\d.]+) Tf"#, Self.contentOf(try Self.pdf(Self.at("word", h: 1e-6))))
        #expect(size > 0, "size \(size)")
    }

    @Test func nothingIsAddedWhenThereAreNoWords() throws {
        let pdf = try Self.pdf([PdfWriter.Page(Self.jpeg, dpi: 300), PdfWriter.Page(Self.jpeg, dpi: 300, words: [])])
        #expect(!pdf.contains("/Font"))
        #expect(!pdf.contains("FontFile2"))
        Self.xrefPointsAtObjects(pdf)
    }

    @Test func oneFontServesEveryPageAndALetterKeepsItsCode() throws {
        let pdf = try Self.pdf([PdfWriter.Page(Self.jpeg, dpi: 300, words: [Self.at("Привет")]),
                                PdfWriter.Page(Self.jpeg, dpi: 300, words: [Self.at("привет Привет", y: 100)]), PdfWriter.Page(Self.jpeg, dpi: 300)])
        #expect(Self.matches("/FontFile2", pdf).count == 1)
        let map = Self.toUnicode(pdf)
        #expect(map.values.count == Set(map.values).count)
        #expect(Self.shown(pdf) == ["Привет", "привет Привет"])
        Self.xrefPointsAtObjects(pdf)
    }

    @Test func aLargeAlphabetIsWrittenInBlocksOfAtMost100() throws {
        let text = String(String.UnicodeScalarView((0x4E00..<(0x4E00 + 750)).map { Unicode.Scalar($0)! }))
        let pdf = try Self.pdf(Self.at(text))
        #expect(Self.toUnicode(pdf).count == 750)
        #expect(Self.shown(pdf) == [text])
    }

    @Test func aClusterNoMapShouldHoldIsSplitUp() throws {
        // Zalgo: a base with many marks. A single entry that long is legal but unwise; each mark then gets its own code.
        let zalgo = "a" + String(repeating: "\u{0301}", count: 200)
        let pdf = try Self.pdf(Self.at(zalgo))
        for v in Self.toUnicode(pdf).values { #expect(v.utf16.count <= 32, "\(v.utf16.count) units") }
        #expect(Self.shown(pdf) == [zalgo.precomposedStringWithCanonicalMapping])
    }

    @Test func pastWhatAFontCanHoldTheFileIsStillValid() throws {
        // More different letters than two bytes can number, as a hostile list of words might give: the rest are left out, the file stays readable.
        var words: [PdfWriter.Word] = []
        for c in Swift.stride(from: 0x10000, to: 0x10000 + 70_000, by: 100) {
            var s = String.UnicodeScalarView()
            for k in 0..<100 {
                if let one = Unicode.Scalar(c + k), one.properties.generalCategory != .unassigned { s.append(one) }
            }
            if !s.isEmpty { words.append(Self.at(String(s))) }
        }
        let pdf = try Self.pdf([PdfWriter.Page(Self.jpeg, dpi: 300, words: words)])
        #expect(Self.toUnicode(pdf).count <= 65_535)
        for m in Self.matches(#"<([0-9A-F]+)> Tj"#, pdf) { #expect(m.groups[1].count % 4 == 0) }
        Self.xrefPointsAtObjects(pdf)
    }

    // MARK: The file

    @Test func eachStreamLengthIsRight() throws {
        let pdf = try Self.pdf(Self.at("Привет"), Self.at("東京", y: 200))
        var checked = 0
        for m in Self.matches(#"/Length (\d+)[^\n]*>>\nstream\n"#, pdf) {
            #expect(Self.substring(pdf, m.end + Int(m.groups[1])!, "\nendstream".utf16.count) == "\nendstream")
            checked += 1
        }
        #expect(checked >= 5, "\(checked) streams") // image, content, font program, CID map, unicode map
    }

    @Test func theFontProgramIsAWellFormedTrueTypeFontWhoseGlyphPaintsNothing() throws {
        let pdf = try Self.pdf(Self.at("Привет"))
        let id = Self.matches(#"/FontFile2 (\d+) 0 R"#, pdf)[0].groups[1]
        let found = Self.matches("\n\(id) 0 obj\n<< /Length (\\d+) /Length1 (\\d+) >>\nstream\n", pdf)
        try #require(found.count == 1)
        #expect(found[0].groups[1] == found[0].groups[2])
        let ttf = Self.substring(pdf, found[0].end, Int(found[0].groups[1])!).unicodeScalars.map { UInt8($0.value) }

        #expect(Self.be32(ttf, 0) == 0x0001_0000)
        let count = Self.be16(ttf, 4)
        var tables: [String: (offset: Int, length: Int)] = [:]
        var previous = ""
        for i in 0..<count {
            let entry = 12 + 16 * i
            let tag = String(decoding: ttf[entry..<(entry + 4)], as: UTF8.self)
            #expect(previous < tag, "tables must be sorted by tag")
            previous = tag
            let (offset, length) = (Int(Self.be32(ttf, entry + 8)), Int(Self.be32(ttf, entry + 12)))
            #expect(offset % 4 == 0)
            #expect(offset + length <= ttf.count)
            tables[tag] = (offset, length)
            if tag != "head" { #expect(Self.be32(ttf, entry + 4) == Self.sum(Array(ttf[offset..<(offset + length)]))) }
        }
        for required in ["cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"] { #expect(tables[required] != nil, "\(required)") }

        // The whole file sums to the magic number head's checkSumAdjustment makes it.
        #expect(Self.sum(ttf) == 0xB1B0_AFBA)
        let head = tables["head"]!.offset
        #expect(Self.be32(ttf, head + 12) == 0x5F0F_3CF5)
        #expect(Self.be16(ttf, head + 18) == 1000)

        // Glyph 1, which every code draws, encloses no area but has a real box (MuPDF drops text with empty bounds), and the width the PDF says.
        let loca = tables["loca"]!.offset
        let glyph = Array(ttf[(tables["glyf"]!.offset + Self.be16(ttf, loca + 2) * 2)...])
        #expect(Self.s16(glyph, 0) == 1)
        #expect(Self.s16(glyph, 6) > Self.s16(glyph, 2) && Self.s16(glyph, 8) > Self.s16(glyph, 4), "a box with an area")
        let points = Self.s16(glyph, 10) + 1
        var (x, y) = (0, 0)
        var corners: [(Int, Int)] = []
        for i in 0..<points {
            x += Self.s16(glyph, 14 + points + i * 2)
            y += Self.s16(glyph, 14 + points + points * 2 + i * 2)
            corners.append((x, y))
        }
        var area = 0
        for i in 0..<points {
            let (from, to) = (corners[i], corners[(i + 1) % points])
            area += from.0 * to.1 - to.0 * from.1
        }
        #expect(area == 0)
        #expect(Self.be16(ttf, tables["hmtx"]!.offset + 4) == 500)
        #expect(pdf.contains("/DW 500"))
    }

    private static func sum(_ data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        for i in Swift.stride(from: 0, to: data.count, by: 4) {
            var word: UInt32 = 0
            for k in 0..<4 { word = (word << 8) | UInt32(i + k < data.count ? data[i + k] : 0) }
            sum &+= word
        }
        return sum
    }

    @Test func everyCodeIsMappedToTheGlyphByTheCIDMap() throws {
        let pdf = try Self.pdf(Self.at("Привет"))
        let id = Self.matches(#"/CIDToGIDMap (\d+) 0 R"#, pdf)[0].groups[1]
        let found = Self.matches("\n\(id) 0 obj\n<< /Length (\\d+) >>\nstream\n", pdf)
        try #require(found.count == 1)
        let map = Self.substring(pdf, found[0].end, Int(found[0].groups[1])!).unicodeScalars.map { UInt8($0.value) }
        let highest = Self.matches(#"<([0-9A-F]+)> Tj"#, Self.contentOf(pdf)).flatMap { m in
            let codes = Self.hexBytes(m.groups[1])
            return Swift.stride(from: 0, to: codes.count - 1, by: 2).map { Self.be16(codes, $0) }
        }.max()!
        #expect(map.count == (highest + 1) * 2)
        #expect(Self.be16(map, 0) == 0) // code 0 is .notdef
        for i in Swift.stride(from: 2, to: map.count, by: 2) { #expect(Self.be16(map, i) == 1) }
    }

    @Test func aNonLatinFileNameIsKeptInTheTitle() throws {
        let pdf = try Self.pdf([PdfWriter.Page(Self.jpeg, dpi: 300)], title: "Счёт (март) 𠮷")
        let hex = Self.matches(#"/Title <([0-9A-F]+)>"#, pdf)[0].groups[1]
        #expect(hex.hasPrefix("FEFF"))
        #expect(Self.utf16BE(Self.hexBytes(String(hex.dropFirst(4)))) == "Счёт (март) 𠮷")
    }

    @Test func aTitleWithABrokenCharacterStaysValid() throws {
        let title = String(decoding: Array("bad".utf16) + [0xD83D] + Array("name\u{0000})".utf16), as: UTF16.self)
        let pdf = try Self.pdf([PdfWriter.Page(Self.jpeg, dpi: 300)], title: title)
        let hex = Self.matches(#"/Title <([0-9A-F]+)>"#, pdf)[0].groups[1]
        #expect(Self.utf16BE(Self.hexBytes(String(hex.dropFirst(4)))) == "badname)")
    }

    // MARK: Spaces

    @Test func wordsOnOneLineGetASpaceBetweenThemAndANewLineNone() throws {
        let pdf = try Self.pdf(Self.at("one", x: 100, w: 200), Self.at("two", x: 320, w: 200), Self.at("three", x: 100, y: 500, w: 300))
        #expect(Self.shown(pdf) == ["one", " ", "two", "three"])
    }

    @Test func wordsOnARightToLeftLineGetASpaceInTheGapToTheirLeft() throws {
        // The words of a right-to-left line come in reading order: the first is the one furthest right.
        let pdf = try Self.pdf(Self.at("שלום", x: 600, w: 200), Self.at("עולם", x: 340, w: 200))
        #expect(Self.shown(pdf) == ["םולש", "םלוע "])
    }

    @Test func chineseAndJapaneseWordsOnOneLineRunTogetherWithNoGap() throws {
        let pdf = try Self.pdf(Self.at("東京", x: 100, w: 120), Self.at("都庁", x: 230, w: 120), Self.at("です", x: 360, w: 120))
        #expect(Self.shown(pdf) == ["東京", "都庁", "です"])
        // The first word is stretched up to the second, so no reader sees a gap to turn into a space.
        let tz = Self.matches(#"([\d.]+) Tz"#, Self.contentOf(pdf)).map { Double($0.groups[1])! }
        #expect(tz[0] > tz[2], "\(tz[0]) then \(tz[2])")
    }

    @Test func wordsWhoseBoxesTouchStillGetASpace() throws {
        #expect(Self.shown(try Self.pdf(Self.at("one", x: 100, w: 200), Self.at("two", x: 300, w: 200))) == ["one", " ", "two"])
        #expect(Self.shown(try Self.pdf(Self.at("one", x: 100, w: 200), Self.at("two", x: 295, w: 200))) == ["one", " ", "two"])
    }

    @Test func aCJKWordAndALatinWordStillGetASpace() throws {
        #expect(Self.shown(try Self.pdf(Self.at("東京", x: 100, w: 120), Self.at("Tokyo", x: 240, w: 200))) == ["東京", " ", "Tokyo"])
    }

    // MARK: Mac additions

    /// What a caller can get wrong (no pages, a page that isn't a JPEG, a resolution no scan has, a huge word list) is an
    /// error or a bounded file, never a crash or a number a reader can't parse.
    @Test func noPagesOrAPageThatIsntAJpegIsAnError() {
        #expect(throws: (any Error).self) { try PdfWriter.write([]) }
        #expect(throws: (any Error).self) { try PdfWriter.write([PdfWriter.Page([1, 2, 3], dpi: 300)]) }
        #expect(throws: (any Error).self) { try PdfWriter.write([PdfWriter.Page(TestJpeg.build(width: 100, height: 0, dnlHeight: nil), dpi: 300)]) }
    }

    @Test(arguments: [0, -300, Int.min, Int.max])
    func aResolutionNoScanHasStillGivesAValidPage(_ dpi: Int) throws {
        let pdf = try Self.pdf([PdfWriter.Page(Self.jpeg, dpi: dpi, words: [Self.at("word")])])
        let box = Self.matches(#"/MediaBox \[0 0 ([\d.]+) ([\d.]+)\]"#, pdf)
        try #require(box.count == 1)
        #expect(Double(box[0].groups[1])! > 0 && Double(box[0].groups[2])! > 0, "\(box[0].groups[0])")
        #expect(Self.shown(pdf) == ["word"])
    }

    @Test func numbersAreWrittenAsReadersParseThem() {
        #expect(PdfWriter.f(0) == "0")
        #expect(PdfWriter.f(612) == "612")
        #expect(PdfWriter.f(1.23456) == "1.235")
        #expect(PdfWriter.f(-2.5) == "-2.5")
        #expect(PdfWriter.f(0.0005) == "0.001") // away from zero, as .NET's "0.###"
        #expect(PdfWriter.f(.nan) == "0") // .NET writes "NaN"; its PdfWriter never passes one (it drops such words)
        #expect(PdfWriter.f(1e20) == "100000000000000000000")
    }

    /// Byte for byte what .NET 10's `ToString("0.###", InvariantCulture)` wrote for each (checked with dotnet): a negative
    /// that rounds to zero keeps its sign, and a double is rounded to 15 significant digits before its thousandths.
    private static let dotNetNumbers: [(Double, String)] = [(-0.0001, "-0"), (-0.0, "-0"), (-1e-10, "-0"), (-5e-324, "-0"), (5e-324, "0"), (0.0004, "0"), (-0.0005, "-0.001"),
                      (-1.0005, "-1.001"), (1.0005, "1.001"), (2.0005, "2.001"), (-2.0004, "-2"), (0.0015, "0.002"), (-999.9996, "-1000"),
                      (1e15, "1000000000000000"), (-1e15, "-1000000000000000"), (1.5e15, "1500000000000000"),
                      (1e16, "10000000000000000"), (123456789012345.67, "123456789012346"),
                      (1e300, "1" + String(repeating: "0", count: 300))]

    @Test(arguments: dotNetNumbers)
    func numbersAreWrittenAsDotNetWritesThem(_ value: Double, _ written: String) {
        #expect(PdfWriter.f(value) == written)
    }

    @Test func theTextLayerReadsTheSameAsTheWindowsOne() throws {
        // Windows' byte layout for one word, read off PdfWriter.cs: the image drawn, then the text in render mode 3.
        let pdf = try Self.pdf(Self.at("Hi", x: 300, y: 300, w: 600, h: 60))
        #expect(pdf.contains("q 612 0 0 792 0 0 cm /Im0 Do Q\nBT 3 Tr\n/F1 14.4 Tf 1000 Tz 1 0 0 1 72 708.48 Tm <00010002> Tj\nET\n"))
        #expect(pdf.hasPrefix("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"))
        #expect(pdf.hasSuffix("%%EOF\n"))
    }

    private static func xrefPointsAtObjects(_ pdf: String) {
        guard let marker = pdf.range(of: "startxref\n", options: .backwards),
              let startxref = Int(pdf[marker.upperBound...].split(separator: "\n")[0]) else {
            Issue.record("no startxref")
            return
        }
        let tail = Self.substring(pdf, startxref, (pdf as NSString).length - startxref)
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "xref")
        let count = Int(lines[1].split(separator: " ")[1])!
        for id in 1..<count {
            let entry = lines[2 + id]
            #expect(entry.hasSuffix(" n "), "object \(id) missing") // no holes in the numbering
            let offset = Int(entry.prefix(10))!
            #expect(Self.substring(pdf, offset, "\(id) 0 obj".utf16.count) == "\(id) 0 obj")
        }
    }
}
