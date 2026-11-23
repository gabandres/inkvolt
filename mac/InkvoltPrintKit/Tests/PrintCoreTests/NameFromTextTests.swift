import Foundation
import Testing
@testable import PrintCore

/// Ported from NameFromTextTests.cs: naming a scan's file from its first page's text (roadmap 4.11): the lines, a date, the
/// heading, a number, and the template. Adapted: words are `PdfWriter.Word` (Windows' `OcrWord`, the image's pixels from its
/// top left), a culture is a `Locale`, a found date a `TextDate`; subfolders join with "/".
struct NameFromTextTests {
    private static let us = Locale(identifier: "en_US"), mx = Locale(identifier: "es_MX")

    /// Words as a recognizer gives them: each line's words left to right, `height` pixels tall, a line every 1.6 heights.
    private static func words(_ lines: (String, Double)...) -> [PdfWriter.Word] {
        var words: [PdfWriter.Word] = []
        var y = 100.0
        for (text, height) in lines {
            var x = 120.0
            for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let length = Double(word.utf16.count)
                // A little uneven, as recognized.
                words.append(PdfWriter.Word(word, x: x, y: y + Double(word.utf16.count % 3), width: length * height * 0.55, height: height))
                x += (length + 1) * height * 0.55
            }
            y += height * 1.6
        }
        return words
    }

    @Test func wordsGoBackIntoTheirLinesInReadingOrder() {
        var words = Self.words(("Maple Street Hardware", 60), ("Invoice INV-20931", 30), ("Garden hose 50 ft", 30))
        words.reverse() // in any order
        let lines = PageText.lines(words)
        #expect(lines.map(\.text) == ["Maple Street Hardware", "Invoice INV-20931", "Garden hose 50 ft"])
        #expect(lines[0].height == 60)
        #expect(PageText.lines(nil).isEmpty)
        #expect(PageText.lines([PdfWriter.Word(" ", x: 0, y: 0, width: 1, height: 1), PdfWriter.Word("nan", x: .nan, y: 0, width: 1, height: 1),
                                PdfWriter.Word("flat", x: 0, y: 0, width: 1, height: 0)]).isEmpty)
    }

    @Test func anInvoiceGivesItsDateHeadingAndNumber() {
        let found = TextFinds.find(Self.words(("Maple Street Hardware", 60), ("Invoice INV-20931", 30), ("Date: March 4, 2026", 30),
                                              ("Garden hose 50 ft 2 12.50", 30)), locale: Self.us)
        #expect(found.date == TextDate(2026, 3, 4))
        #expect(found.title == "Maple Street Hardware")
        #expect(found.number == "INV-20931")
    }

    @Test(arguments: [
        ("Issued 2026-03-04", "en_US", TextDate(2026, 3, 4)),
        ("3/4/2026", "en_US", TextDate(2026, 3, 4)),
        ("3/4/2026", "es_MX", TextDate(2026, 4, 3)),
        ("25/12/2025", "en_US", TextDate(2025, 12, 25)), // the day is over 12: day first whatever the culture
        ("12.25.25", "es_MX", TextDate(2025, 12, 25)),
        ("4 March 2026", "en_US", TextDate(2026, 3, 4)),
        ("Sept. 30th, 2026", "en_US", TextDate(2026, 9, 30)),
        ("Fecha: 4 de marzo de 2026", "es_MX", TextDate(2026, 3, 4)),
        ("Monterrey, 15 ene 2027", "en_US", TextDate(2027, 1, 15)),
    ])
    func datesAreReadAsWritten(_ line: String, _ locale: String, _ expected: TextDate) {
        #expect(TextFinds.find(Self.words((line, 30)), locale: Locale(identifier: locale)).date == expected)
    }

    @Test(arguments: ["31/02/2026", "13/13/2026", "Call 555-0142 today", "Order 2026 of 3000", "Version 1.2.3"])
    func whatIsntADateIsntTakenForOne(_ line: String) {
        #expect(TextFinds.find(Self.words((line, 30)), locale: Self.us).date == nil)
    }

    @Test(arguments: [
        ("en_US", false), ("es_MX", true), ("en_GB", true),
        ("ja_JP", false), // yyyy/MM/dd: the month before the day
        ("zh_CN", false), ("ko_KR", false), ("sv_SE", false), ("hu_HU", false),
    ])
    func dayOrMonthFirstIsWhereTheCultureWritesThem(_ locale: String, _ dayFirst: Bool) {
        let l = Locale(identifier: locale)
        #expect(TextFinds.dayFirst(l) == dayFirst)
        #expect(TextFinds.find(Self.words(("3/4/2026", 30)), locale: l).date == (dayFirst ? TextDate(2026, 4, 3) : TextDate(2026, 3, 4)))
    }

    @Test func aLineThatSaysDateComesFirst() {
        let found = TextFinds.find(Self.words(("Shipped 1/2/2026", 30), ("Invoice date: 1/9/2026", 30)), locale: Self.us)
        #expect(found.date == TextDate(2026, 1, 9))
    }

    @Test(arguments: [
        ("Order #1042", "1042"),
        ("Receipt No. A-77813", "A-77813"),
        ("Factura Nº 0045/2026", "0045/2026"),
        ("Ref: PO-55120", "PO-55120"),
        ("Thanks! Your code is ABC-12345", "ABC-12345"),
    ])
    func numbersAreFoundByTheirLabelOrTheirShape(_ line: String, _ expected: String) {
        #expect(TextFinds.find(Self.words(("Header text", 30), (line, 30)), locale: Self.us).number == expected)
    }

    @Test func noNumberNoHeadingNoDateOnAPageThatDoesntSay() {
        let found = TextFinds.find(Self.words(("the quick brown fox", 30), ("jumps over no one", 30)), locale: Self.us)
        #expect(found.number == nil)
        #expect(found.date == nil)
        #expect(found.title == "the quick brown fox") // no heading: the first line
        #expect(TextFinds.find(nil, locale: Self.us) == FoundInText.none)
    }

    @Test func aPunchHoleReadAsALetterIsntPartOfTheHeading() {
        var words = Self.words(("Maple Street Hardware", 60), ("Invoice INV-20931", 30))
        words.append(PdfWriter.Word("O", x: 10, y: 100, width: 30, height: 60)) // the hole, left of the heading by more than its height
        #expect(TextFinds.find(words, locale: Self.us).title == "Maple Street Hardware")
        #expect(TextFinds.find(Self.words(("A Tale of Two Cities", 60), ("Chapter one", 30)), locale: Self.us).title == "A Tale of Two Cities") // a word, not a stray
    }

    @Test func aLongHeadingIsCutAtAWord() throws {
        let heading = "Annual report on the state of the community garden and its many volunteers and friends"
        let title = try #require(TextFinds.find(Self.words((heading, 30)), locale: Self.us).title)
        #expect((TextFinds.maxTitle / 2...TextFinds.maxTitle).contains(title.count))
        #expect(heading.hasPrefix(title))
        #expect(Array(heading)[title.count] == " ") // a whole word last
    }

    // ---- The template ----

    private static func context(_ found: FoundInText?) -> NameContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9, minute: 30))!
        return NameContext(now: now, preset: "Bills", printer: "Office", number: 7, pages: 2, timeZone: TimeZone(identifier: "UTC")!,
                           locale: Locale(identifier: "en_US_POSIX"), found: found)
    }

    @Test func theTextTokensFillTheName() {
        let found = FoundInText(date: TextDate(2026, 3, 4), title: "Maple Street Hardware", number: "INV-20931")
        #expect(FileNameTemplate.fileName("{text-date} {text-title} {text-number}", Self.context(found)) == "2026-03-04 Maple Street Hardware INV-20931")
        #expect(FileNameTemplate.fileName("{text-date:yyyy-MM} {preset}", Self.context(found)) == "2026-03 Bills")
        #expect(FileNameTemplate.subfolder("Receipts\\{text-date:yyyy}", Self.context(found)) == "Receipts/2026")
        var other = found
        other.number = "0045/2026"
        #expect(FileNameTemplate.fileName("Order {text-number}", Self.context(other)) == "Order 0045-2026") // made safe
    }

    @Test func whatThePageDoesntSayLeavesNoGap() {
        let maple = FoundInText(title: "Maple")
        #expect(FileNameTemplate.fileName("{text-title} - {text-number} - {date}", Self.context(maple)) == "Maple - 2026-11-22")
        #expect(FileNameTemplate.fileName("{text-date} {preset}  {n}", Self.context(nil)) == "Bills  7") // the separator after it goes, the name's own stay
        #expect(FileNameTemplate.fileName("Bills_{text-number}_{date}", Self.context(nil)) == "Bills_2026-11-22")
        #expect(FileNameTemplate.fileName("{text-title} - {text-number}", Self.context(maple)) == "Maple")
        #expect(FileNameTemplate.fileName("{text-title}", Self.context(FoundInText.none)) == FileNameTemplate.sanitize(""))
        // The review (Mac only): a separator with a combining mark after it is still a separator; a long title in a script
        // of 3-byte characters fits APFS's 255 bytes.
        #expect(!FileNameTemplate.fileName("{text-title}", Self.context(FoundInText(title: "Acme/\u{301}Invoice"))).contains("/"))
        #expect(!FileNameTemplate.sanitize("a\\\u{FE0F}b:\u{200D}c").unicodeScalars.contains { "\\:".unicodeScalars.contains($0) })
        let long = FileNameTemplate.fileName("{preset} - {text-title}", Self.context(FoundInText(title: String(repeating: "請求書", count: 40))))
        #expect(long.utf8.count <= FileNameTemplate.maxNameBytes && long.hasPrefix("Bills - 請求書"))
        // Separators typed in the name are kept, wherever the page's text goes in it.
        #expect(FileNameTemplate.fileName("{preset} -- {text-title} -- {n}", Self.context(maple)) == "Bills -- Maple -- 7")
        #expect(FileNameTemplate.fileName("{preset}  {n}", Self.context(nil)) == "Bills  7")
    }

    @Test func templatesWithTextTokensAreFineAndReadThePage() {
        #expect(FileNameTemplate.problem("{text-date:yyyy-MM-dd} {text-title} {text-number}") == nil)
        #expect(FileNameTemplate.problem("{text-title:upper}") != nil)
        #expect(FileNameTemplate.problem("{text-heading}") != nil)
        #expect(FileNameTemplate.readsText("Scan {TEXT-DATE}"))
        #expect(!FileNameTemplate.readsText("{preset} {date} {{text-date}}")) // braces doubled: literal text
    }

    @Test func aPresetNamedFromItsTextReadsTheText() {
        let input = InputCaps(minWidth: 0, maxWidth: 2550, minHeight: 0, maxHeight: 3508, colorModes: ["RGB24", "Grayscale8"],
                              documentFormats: ["image/jpeg"], resolutions: [300], intents: ["Document"])
        let caps = ScannerCapabilities(version: "2.6", makeAndModel: "Test", uuid: nil, platen: input, adf: nil, adfDuplex: false)
        var pdf = ScanPreset()
        pdf.id = "p"
        pdf.name = "Bills"
        pdf.fileType = .pdf
        pdf.fileName = "{text-date} {text-title}"
        func plan(_ p: ScanPreset, ocr: Bool = true) -> PresetPlan { PresetPlan.plan(p, caps, feederLoaded: nil, ocrAvailable: ocr, metric: false) }
        #expect(plan(pdf).ocr)
        var plain = pdf
        plain.fileName = "{preset} {date}"
        #expect(!plan(plain).ocr)
        let noOcr = plan(pdf, ocr: false)
        #expect(!noOcr.ocr)
        #expect(noOcr.notes.count == 1)
        var sub = pdf
        sub.fileName = "{preset}"
        sub.subfolder = "{text-date:yyyy}"
        #expect(plan(sub).ocr)
    }
}
