import Foundation
import Testing
@testable import PdfCore

/// Ported from ExportTests.cs, every test. Adapted: the Open XML SDK isn't available, so a file is read back with our own
/// ZIP reader and Foundation's XMLDocument, and its validator (AssertValid) is stood in for by `OpenXmlPackage.validate`
/// (every XML part well formed, every part with a content type, every relationship's target there, `unzip -t` clean);
/// the main Word sample is also read by `textutil` (Apple's converter). `ExportTestPdf` is written by hand in Helvetica
/// (Word gets "Arial", as from the Windows test's Arial). SaveSample (writing samples for a person to open in Word) is
/// left out.
struct ExportTests {
    private func read(_ pdf: [UInt8], password: String? = nil) throws -> [ExportPage] {
        let engine = try PdfEngine.open(pdf, password: password)
        defer { engine.close() }
        return try (0..<engine.pageCount).map { try engine.exportPage($0, images: true) }
    }

    private func docx(_ pages: [ExportPage], _ title: String? = "Sample") throws -> [UInt8] {
        let sink = MemorySink()
        try DocumentExport.writeDocx(sink, pages, title)
        return sink.bytes
    }

    private func assertValid(_ bytes: [UInt8]) throws {
        let problems = try OpenXmlPackage(bytes).validate()
        #expect(problems.isEmpty, "\(problems.prefix(10).joined(separator: "\n"))")
    }

    private typealias X = OpenXmlPackage

    @Test func wordExportIsValidAndKeepsHeadingsParagraphsListsTablesAndPictures() throws {
        let bytes = try docx(try read(ExportTestPdf.make()))
        try assertValid(bytes)
        let doc = try WordDoc(bytes)
        let paras = doc.bodyParagraphs
        let texts = paras.map(X.text)
        func single(_ text: String) throws -> XMLElement { try #require(paras.filter { X.text($0) == text }.count == 1 ? paras.first { X.text($0) == text } : nil) }

        // Headings by size: the 24 pt title is level 1, the 16 pt headings level 2.
        #expect(WordDoc.style(try single("Quarterly Report")) == "Heading1")
        #expect(WordDoc.style(try single("Summary")) == "Heading2")
        #expect(WordDoc.style(try single("Prices")) == "Heading2")
        #expect(WordDoc.style(try single("Two Columns")) == "Heading2")

        // Wrapped lines are one paragraph again; the italic words keep their look.
        #expect(texts.contains(ExportTestPdf.para1))
        let p2 = try single(ExportTestPdf.para2)
        #expect(X.elements(p2, "w:r").contains { X.text($0).contains("same page.") && !X.elements($0, "w:i").isEmpty })
        #expect(X.elements(try single("Quarterly Report"), "w:r").contains { r in
            !X.elements(r, "w:b").isEmpty && X.attr(X.elements(r, "w:sz").first, "w:val") == "48"
                && X.attr(X.elements(r, "w:rFonts").first, "w:ascii") == "Arial"
        })

        // Bullets are Word bullets (numbering), without the typed bullet character.
        #expect(paras.filter { !X.elements($0, "w:numPr").isEmpty }.map(X.text) == ExportTestPdf.bullets)

        // The ruled table, cell by cell.
        try #require(doc.tables.count == 1)
        #expect(WordDoc.cells(doc.tables[0]) == ExportTestPdf.table)

        // The picture is embedded inline.
        #expect(doc.mediaCount == 1)
        #expect(X.elements(doc.document, "wp:inline").count == 1)

        // Page 2's columns read left column first, each whole.
        let left = texts.firstIndex { $0.hasPrefix("The left column") }
        let right = texts.firstIndex { $0.hasPrefix("The right column") }
        try #require(left != nil && right != nil && right! > left!, "\(texts.joined(separator: " | "))")
        #expect(texts[left!].hasSuffix("every autumn."))
        #expect(texts[right!].hasSuffix("cellar room."))

        // Each PDF page is a section with its own size (612 x 792 pt = 12240 x 15840 twips).
        let sections = X.elements(doc.document, "w:sectPr")
        #expect(sections.count == 2)
        #expect(sections.allSatisfy { X.attr(X.children($0, "w:pgSz").first, "w:w") == "12240" })
        #expect(X.elements(try doc.package.xml("docProps/core.xml"), "dc:title").first.map(X.text) == "Sample")

        // Apple's converter reads it too.
        let plain = try #require(try X.textutil(bytes))
        #expect(plain.contains("Quarterly Report") && plain.contains("Apples") && plain.contains("cellar room."))
    }

    @Test func repeatedLogoGoesToTheHeaderOnceAndIconsStayInTheirCells() throws {
        let bytes = try docx(try read(ExportTestPdf.make(logo: true)))
        try assertValid(bytes)
        let doc = try WordDoc(bytes)
        #expect(doc.mediaCount == 3) // logo (stored once), icon, figure
        let headers = doc.package.parts.keys.filter { $0.hasPrefix("word/header") }
        try #require(headers == ["word/header1.xml"])
        #expect(X.elements(try doc.package.xml("word/header1.xml"), "wp:inline").count == 1)
        #expect(try doc.package.relationships(of: "word/header1.xml").values.filter { $0.hasPrefix("word/media/") }.count == 1)
        try #require(doc.tables.count == 1)
        let pears = X.children(X.children(doc.tables[0], "w:tr")[2], "w:tc")[0]
        #expect(X.text(pears) == "Pears")
        #expect(X.elements(pears, "wp:inline").count == 1)
        #expect(X.elements(doc.body, "wp:inline").count == 2) // icon + figure
    }

    @Test func textAlignedInColumnsWithoutLinesIsATable() throws {
        let laid = DocLayout.analyze(try read(ExportTestPdf.make(ruledTable: false)))
        try #require(laid[0].tables.count == 1)
        let table = laid[0].tables[0]
        #expect(!table.ruled)
        #expect(table.rows.map { $0.map(\.text) } == ExportTestPdf.table)
        // The paragraphs and the list around it are untouched.
        #expect(laid[0].paragraphs.contains { $0.text == ExportTestPdf.para1 })
        #expect(laid[0].paragraphs.filter { $0.list == .bullet }.count == 3)
        // Two text columns are not a table.
        #expect(laid[1].tables.isEmpty)
    }

    @Test func excelExportHasASheetPerTableWithNumbersAsNumbers() throws {
        let pages = try read(ExportTestPdf.make())
        let tables = DocumentExport.tables(pages.enumerated().map { ($0.offset + 1, $0.element) })
        try #require(tables.count == 1)
        #expect(tables[0].name == "Page 1")
        let sink = MemorySink()
        try XlsxWriter.write(sink, tables, "Sample")
        try assertValid(sink.bytes)
        let book = try OpenXmlPackage(sink.bytes)
        let sheets = X.elements(try book.xml("xl/workbook.xml"), "sheet")
        try #require(sheets.count == 1)
        #expect(X.attr(sheets[0], "name") == "Page 1")
        let target = try #require(try book.relationships(of: "xl/workbook.xml")[X.attr(sheets[0], "r:id") ?? ""])
        var cells: [String: XMLElement] = [:]
        for c in X.elements(try book.xml(target), "c") { cells[X.attr(c, "r") ?? ""] = c }
        #expect(X.text(cells["A1"]!) == "Item")
        #expect(X.attr(cells["A1"], "t") == "inlineStr")
        #expect(X.attr(cells["A1"], "s") == "1") // bold header
        #expect(X.attr(cells["B2"], "t") == nil)  // a number
        #expect(X.elements(cells["B2"]!, "v").first.map(X.text) == "4")
        #expect(X.elements(cells["C3"]!, "v").first.map(X.text) == "3.05")
        #expect(cells.count == 12)
    }

    @Test func plainTextReadsParagraphsListsAndTableRowsInOrder() throws {
        let text = DocumentExport.plainText(try read(ExportTestPdf.make()))
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "Quarterly Report")
        #expect(lines.contains(ExportTestPdf.para1))
        #expect(lines.contains("\u{2022} First point in the list"))
        let row = try #require(lines.firstIndex(of: "Apples\t4\t1.20"))
        let left = try #require(lines.firstIndex { $0.hasPrefix("The left column") })
        #expect(row < left)
    }

    @Test func encryptedPdfExportsOnceOpened() throws {
        let bytes = try docx(try read(TestPdf.encrypted(2, "secret"), password: "secret"))
        try assertValid(bytes)
        #expect(try WordDoc(bytes).bodyParagraphs.contains { X.text($0).hasPrefix("Page 2 alpha") })
    }

    @Test func scannedPageKeepsItsPictureWithoutTextAndDropsItOnceRecognized() throws {
        let png = TestImages.png(20, 26) { _, _ in (250, 250, 250, 255) }
        let scan = ExportImage(png, "png", 20, 26, RectD(0, 0, 612, 792))
        let bare = ExportPage(612, 792, [], [scan], [])
        let laidBare = DocLayout.analyze([bare])
        try #require(laidBare[0].blocks.count == 1)
        #expect(laidBare[0].blocks[0].picture != nil)

        let words = [
            OcrWord("Hello", RectD(72, 100, 40, 12)), OcrWord("world", RectD(116, 101, 42, 12)),
            OcrWord("Second", RectD(72, 116, 50, 12)), OcrWord("line", RectD(126, 116, 30, 12)),
        ]
        var ocr = bare
        ocr.lines = ExportPage.linesFromOcr(words)
        ocr.fromOcr = true
        let laid = DocLayout.analyze([ocr])
        try #require(laid[0].blocks.count == 1)
        #expect(laid[0].blocks[0].paragraph?.text == "Hello world Second line")
        let bytes = try docx([ocr])
        try assertValid(bytes)
        #expect(try WordDoc(bytes).mediaCount == 0)
    }

    @Test func ocrWordsFormLinesSplitAtWideGaps() {
        let words = [
            OcrWord("Name", RectD(72, 100, 40, 12)), OcrWord("Total", RectD(400, 99, 40, 13)),
            OcrWord("Apples", RectD(72, 120, 50, 12)), OcrWord("4", RectD(400, 121, 8, 11)),
            OcrWord("big", RectD(130, 120, 25, 12)),
        ]
        let lines = ExportPage.linesFromOcr(words)
        #expect(lines.map(\.text) == ["Name", "Total", "Apples big", "4"])
        #expect(lines.allSatisfy { (12...16).contains($0.size) })
    }

    @Test func emptyDocumentStillMakesAValidFile() throws {
        try assertValid(try docx([ExportPage(612, 792, [], [], [])]))
        try assertValid(try docx([]))
    }

    // ---- layout details on synthetic lines ----

    private func line(_ text: String, _ x: Double, _ y: Double, size: Double = 11, bold: Bool = false, font: String = "Arial") -> ExportLine {
        let w = Double(text.utf16.count) * size * 0.5
        return .of([ExportSpan(text, font, size, bold, false, 0, RectD(x, y, w, size * 1.15))])
    }

    @Test func hyphenatedLineEndsAreRejoinedAndShortLinesEndParagraphs() {
        // Lines 14 pt apart; the second paragraph starts after a line that ends short.
        let page = ExportPage(612, 792, [
            line("This sentence has a word that wraps over two exam-", 72, 100),
            line("ples of lines in the original document text here.", 72, 114),
            line("Short end.", 72, 128),
            line("Next paragraph begins here and runs a long way on.", 72, 142),
        ], [], [])
        #expect(DocLayout.analyze([page])[0].paragraphs.map(\.text) == [
            "This sentence has a word that wraps over two examples of lines in the original document text here. Short end.",
            "Next paragraph begins here and runs a long way on.",
        ])
    }

    @Test func headingLevelsFollowSizesAcrossTheDocument() throws {
        func p(_ lines: ExportLine...) -> ExportPage { ExportPage(612, 792, lines, [], []) }
        let body = Array(repeating: "body text", count: 6).joined(separator: " ")
        let pages = [
            p(line("Title", 72, 72, size: 28), line("Part", 72, 120, size: 18), line(body, 72, 160)),
            p(line("Other part", 72, 72, size: 18), line("Small head", 72, 110, size: 14), line(body + " more", 72, 140)),
        ]
        var levels: [String: Int] = [:]
        for para in DocLayout.analyze(pages).flatMap(\.paragraphs) {
            #expect(levels[para.text] == nil)
            levels[para.text] = para.headingLevel
        }
        #expect(levels["Title"] == 1)
        #expect(levels["Part"] == 2)
        #expect(levels["Other part"] == 2)
        #expect(levels["Small head"] == 3)
        #expect(levels[body] == 0)
        #expect(levels[body + " more"] == 0)
    }

    @Test func repeatedTopAndBottomLinesBecomeTheHeaderAndFooterWithAPageNumber() throws {
        let body = Array(repeating: "body text", count: 6).joined(separator: " ")
        var pages = (1...3).map { n in
            ExportPage(612, 792, [
                line("Acme Annual Report", 72, 30), line("Chapter text \(n) " + body, 72, 100),
                line("Confidential", 72, 760), line("Page \(n)", 500, 760),
            ], [], [])
        }
        pages.insert(ExportPage(612, 792, [line("Cover", 200, 300, size: 30)], [], []), at: 0) // no header or footer on it
        let result = DocLayout.analyzeDocument(pages)
        #expect(result.pages.allSatisfy { !$0.paragraphs.contains { $0.text.contains("Acme") || $0.text.contains("Page") } })
        let header = try #require(result.header)
        try #require(header.rows.count == 1 && header.rows[0].parts.count == 1)
        #expect(header.rows[0].parts[0].span.text == "Acme Annual Report")
        let footer = try #require(result.footer)
        try #require(footer.rows.count == 1)
        #expect(footer.rows[0].parts.map(\.zone) == [.left, .right])
        #expect(footer.rows[0].parts.map(\.span.text) == ["Confidential", "Page \u{E000}"])

        let bytes = try docx(pages)
        try assertValid(bytes)
        let doc = try WordDoc(bytes)
        let sections = X.elements(doc.document, "w:sectPr")
        #expect(sections.count == 4)
        let rels = try doc.package.relationships(of: "word/document.xml")
        func part(_ s: XMLElement, _ kind: String) throws -> XMLDocument {
            try doc.package.xml(rels[X.attr(X.children(s, "w:\(kind)Reference").first, "r:id") ?? ""] ?? "")
        }
        func headerText(_ s: XMLElement) throws -> String { X.text(try part(s, "header").rootElement()!) }
        #expect(try headerText(sections[0]) == "") // the cover keeps no header
        for s in sections.dropFirst() { #expect(try headerText(s) == "Acme Annual Report") }
        let fields = X.elements(try part(sections[1], "footer"), "w:fldSimple")
        try #require(fields.count == 1)
        #expect(X.attr(fields[0], "w:instr") == " PAGE ")
        // Plain text leaves them out.
        #expect(!DocumentExport.plainText(pages).contains("Acme"))
    }

    @Test(arguments: [
        ("\u{2022} Item", true), ("- Item", true), ("\u{F0B7} Item", true), ("1. Item", false), ("(a) Item", false),
        ("iv) Item", false), ("7.2.1. Drives", false), ("8.1 Clock Window", false),
    ])
    func listMarkers(_ text: String, _ bullet: Bool) throws {
        let m = try #require(DocLayout.listMarker(text))
        #expect(m.bullet == bullet)
    }

    @Test(arguments: ["e.g. this", "2024 was a year", "-5 degrees", "3.5 percent more"])
    func notListMarkers(_ text: String) { #expect(DocLayout.listMarker(text) == nil) }

    @Test(arguments: [
        ("ABCDEF+ArialMT", "Arial"), ("Arial-BoldMT", "Arial"), ("Arial,Bold", "Arial"), ("TimesNewRomanPSMT", "Times New Roman"),
        ("Times-Roman", "Times New Roman"), ("Helvetica-Oblique", "Arial"), ("Calibri", "Calibri"), ("SegoeUI", "Segoe UI"),
        ("CourierNewPSMT", "Courier New"),
    ])
    func fontFamilies(_ pdfName: String, _ family: String) { #expect(FontNames.family(pdfName) == family) }

    @Test(arguments: [
        ("12", 12.0), ("-3.5", -3.5), ("1,234.50", 1234.5), ("0.99", 0.99), ("0.5", 0.5), ("$5", 5.0), ("-$1,200.00", -1200.0),
        ("12%", 0.12), ("007", nil), ("1.234,50", nil), ("1234567890123456", nil), ("-$-5", nil), ("5 €", nil),
    ] as [(String, Double?)])
    func excelNumbers(_ text: String, _ value: Double?) {
        let n = XlsxWriter.number(text)
        if let value { #expect(n.map { abs($0 - value) < 1e-9 } == true) } else { #expect(n == nil) }
    }

    @Test(arguments: [
        ("12", nil), ("12.50", "0.00"), ("1,234.5", "#,##0.0"), ("1,234", "#,##0"), ("12.5%", "0.0%"), ("$5.00", "\"$\"#,##0.00"),
        ("-€3", "\"€\"#,##0"),
    ] as [(String, String?)])
    func excelNumberFormatsShowTheNumberAsWritten(_ text: String, _ format: String?) {
        #expect(XlsxWriter.parse(text)?.format == format)
    }

    private func cell(_ text: String) -> DocCell {
        DocCell([DocParagraph([ExportSpan(text, "Arial", 11, false, false, 0, RectD(0, 0, 10, 10))], RectD(0, 0, 10, 10))])
    }

    private func workbook(_ rows: [String]...) throws -> OpenXmlPackage {
        let table = DocTable(rows.map { $0.map(cell) }, rows[0].map { _ in 60.0 }, true, RectD(0, 0, 100, 100))
        let sink = MemorySink()
        try XlsxWriter.write(sink, [("Page 1", table)], nil)
        return try OpenXmlPackage(sink.bytes)
    }

    @Test func excelCellsKeepDecimalsSeparatorsPercentsAndCurrencyWithOneStyleEach() throws {
        let book = try workbook(["12.50", "1,234.50", "12.5%", "$5.00"], ["3.10", "2,000.75", "7", "-$1.25"])
        #expect(try book.validate().isEmpty)
        let styles = try book.xml("xl/styles.xml")
        let numFmts = X.elements(styles, "numFmt")
        var formats: [String: String] = [:]
        for f in numFmts { formats[X.attr(f, "numFmtId") ?? ""] = X.attr(f, "formatCode") }
        #expect(numFmts.compactMap { X.attr($0, "formatCode") } == ["0.00", "#,##0.00", "0.0%", "\"$\"#,##0.00"]) // each format once
        let xfs = X.children(X.elements(styles, "cellXfs")[0], "xf")
        var cells: [String: XMLElement] = [:]
        for c in X.elements(try book.xml("xl/worksheets/sheet1.xml"), "c") { cells[X.attr(c, "r") ?? ""] = c }
        func formatOf(_ c: XMLElement) -> String {
            guard let s = X.attr(c, "s"), let i = Int(s) else { return "General" }
            return formats[X.attr(xfs[i], "numFmtId") ?? ""] ?? "General"
        }
        func value(_ c: String) -> String? { X.elements(cells[c]!, "v").first.map(X.text) }
        #expect(value("A1") == "12.5")
        #expect(formatOf(cells["A1"]!) == "0.00")
        #expect(X.attr(cells["A1"], "s") == X.attr(cells["A2"], "s")) // same look, same style
        #expect(formatOf(cells["B2"]!) == "#,##0.00")
        #expect(value("C1") == "0.125")
        #expect(formatOf(cells["C2"]!) == "General")
        #expect(value("D2") == "-1.25")
        #expect(formatOf(cells["D2"]!) == "\"$\"#,##0.00")
        #expect(xfs.count == 5) // plain + the four formats
    }

    @Test func longCellsAndNamesAreCutWithoutSplittingAnEmoji() throws {
        #expect(OpenXmlParts.cut("ab\u{1F600}", 3) == "ab")
        #expect(OpenXmlParts.cut("ab\u{1F600}c", 4) == "ab\u{1F600}")
        #expect(OpenXmlParts.cut("abc", 5) == "abc")
        let text = String(repeating: "a", count: 32766) + "\u{1F600} and more"
        let book = try workbook([text, "x"])
        #expect(try book.validate().isEmpty)
        let first = X.elements(try book.xml("xl/worksheets/sheet1.xml"), "c")[0]
        #expect(X.text(first) == String(repeating: "a", count: 32766))
        #expect(XlsxWriter.sheetNames([String(repeating: "x", count: 30) + "\u{1F600}"]) == [String(repeating: "x", count: 30)])
        // A font name with an emoji across Word's 31-character limit.
        let span = ExportSpan("Hi", String(repeating: "F", count: 30) + "\u{1F600}", 11, false, false, 0, RectD(72, 72, 20, 12))
        try assertValid(try docx([ExportPage(612, 792, [.of([span])], [], [])]))
    }

    @Test func excelSheetNamesAndColumns() {
        #expect(XlsxWriter.sheetNames(["Page 1", "page 1", "a/b", String(repeating: "x", count: 40), String(repeating: "x", count: 31)])
            == ["Page 1", "page 1 (2)", "a b", String(repeating: "x", count: 31), String(repeating: "x", count: 27) + " (2)"])
        #expect(XlsxWriter.column(0) == "A")
        #expect(XlsxWriter.column(25) == "Z")
        #expect(XlsxWriter.column(26) == "AA")
    }
}
