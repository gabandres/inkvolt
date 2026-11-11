import Foundation
import Testing
@testable import PdfCore

/// Ported from RedactionCorpusTests.cs (same names): roadmap 1.1's test, the corpus finds 100% and leaves 0 after applying;
/// what OCR can't read is never reported clean. The tests that read 300 dpi pages or make thousands of matches run on a Mac,
/// not in CI (`ScanCorpus.runs`: they starved the loopback servers of the timing tests on GitHub's runner). Adapted: a recognizer is a `TextRecognizer` given RGB images; the batch's
/// recognizer for Redact Patterns is `BatchHost.reader`; a timeout is `RedactionSearchTimeout`, a bad pattern `PdfEditError`
/// (Windows: `TimeoutException`, `ArgumentException`); the page budget is set for the test through a task local; the
/// expressions are ICU's (`(?<=(a+)+)b`, a look-behind without a bound, is refused by ICU before anything runs).
final class RedactionCorpusTests {
    private let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-redact-corpus-\(NewIds.hex().prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    private func p(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    private static func plain(_ s: String) -> String { String(s.unicodeScalars.filter { !$0.properties.isWhitespace && $0 != "-" }.map(Character.init)) }

    private static func findsAll(_ hits: [RedactionMatch]) {
        let missing = RedactionCorpus.values.filter { v in !hits.contains { $0.page == v.page && $0.pattern == v.kind && plain($0.normalized) == plain(v.value) } }
            .map { "page \($0.page + 1): \($0.kind) \($0.value)" }
        #expect(missing.isEmpty, "Not found: \(missing.joined(separator: "; "))\nFound: \(hits.map { "\($0.page + 1):\($0.pattern):\($0.normalized)" }.joined(separator: "; "))")
    }

    private static func applyAndReadBack(_ data: [UInt8], _ password: String?, _ reader: PlantedReader) throws
        -> (result: [UInt8], found: RedactionSearchResult, left: [RedactionMatch]) {
        let engine = try PdfEngine.open(data, password: password)
        let found = try RedactionSearch.find(engine, RedactionCorpus.search, ocr: reader)
        engine.close()
        findsAll(found.hits)
        let areas = RedactionSearch.areas(found.hits)
        let result = try Redaction.apply(data, password, areas)
        let left = try RedactionSearch.readBack(result, password, RedactionCorpus.search, ocr: reader, redactedPages: Set(areas.keys), kept: []).hits
        return (result, found, left)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func findsEveryPlantedValueAndLeavesNoneAfterApplying() throws {
        let (data, reader) = try RedactionCorpus.make()
        let (result, found, left) = try Self.applyAndReadBack(data, nil, reader)
        #expect(left.isEmpty, "Still there: \(left.map { "\($0.page + 1):\($0.pattern):\($0.normalized)" })")

        // Nothing of any planted value is in the pages' text or the file, and each hit's place is black.
        let engine = try PdfEngine.open(result)
        defer { engine.close() }
        for page in 0..<engine.pageCount {
            let text = Self.plain(try engine.text(page).text)
            for v in RedactionCorpus.values { #expect(!text.contains(Self.plain(v.value)), "page \(page + 1): \(v.value)") }
        }
        let report = try RedactionCheck.run(result, nil, RedactionCheckOptions(values: RedactionSearch.values(found.hits), patterns: RedactionCorpus.search, valuesOnly: true))
        #expect(report.isClean, "\(report.summary) \(report.findings.map { "\($0.place): \($0.kind)" })")
        #expect(!report.incomplete, "\(report.notes)")
        for hit in found.hits {
            for r in hit.rects { #expect(try Core2Pdf.ink(result, hit.page, r.inflate(-1)) > 0.9, "page \(hit.page + 1) \(hit.pattern) blacked out") }
        }
    }

    @Test(.enabled(if: ScanCorpus.runs)) func batchFindsAllLeavesNoneReportsMaskedAndKeepsThePassword() async throws {
        let (plain, reader) = try RedactionCorpus.make()
        let (a, b) = (p("plain.pdf"), p("locked.pdf"))
        try Data(plain).write(to: URL(fileURLWithPath: a))
        try Data(try RedactionCorpus.encrypted(plain)).write(to: URL(fileURLWithPath: b))
        let plan = BatchPlan(steps: [.redactPatterns(RedactionCorpus.search)], outputFolder: p("out"))
        let asked = Collected<String>()
        let host = BatchHost(askPassword: { request, _ in
            asked.add((request.file.path as NSString).lastPathComponent)
            return RedactionCorpus.password
        }, reader: reader)
        let summary = try await BatchRunner.run([BatchFile(a), BatchFile(b)], plan, host)
        for i in summary.items { #expect(i.state == .done, "\(i.file.path): \(i.state): \(i.message) \(i.notes)") }
        #expect(asked.all == ["locked.pdf"])

        let engine = try PdfEngine.open(Array(try Data(contentsOf: URL(fileURLWithPath: summary.items[0].outputs[0]))))
        for page in 0..<engine.pageCount {
            for v in RedactionCorpus.values { #expect(!Self.plain(try engine.text(page).text).contains(Self.plain(v.value))) }
        }
        engine.close()
        let locked = Array(try Data(contentsOf: URL(fileURLWithPath: summary.items[1].outputs[0])))
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(locked).close() }

        // The report: per file, page, pattern, masked value; every scan listed to look at; no value anywhere in it.
        let path = try #require(summary.redactionReportPath)
        let csv = Csv.decode(Array(try Data(contentsOf: URL(fileURLWithPath: path))))
        for v in RedactionCorpus.values {
            #expect(!csv.contains(v.value))
            #expect(!Self.plain(csv).contains(Self.plain(v.value)))
        }
        let rows = try Csv.read(csv)
        #expect(rows[0] == ["File", "Page", "What", "Masked value", "Result"])
        #expect(rows.contains { $0[0].hasSuffix("plain.pdf") && $0[1] == "1" && $0[2] == "US Social Security numbers" && $0[3] == "***-**-**89" && $0[4] == "Removed" })
        #expect(rows.contains { $0[0].hasSuffix("locked.pdf") && $0[1] == "1" && $0[2] == "US Social Security numbers" && $0[4] == "Removed" })
        for page in RedactionCorpus.scanPages {
            #expect(rows.contains { $0[0].hasSuffix("plain.pdf") && $0[1] == String(page + 1) && $0[4] == "Look by hand" }, "page \(page + 1)")
        }
        #expect(!summary.items[0].notes.contains { $0.lowercased().contains("clean") })
        #expect(summary.items[0].notes.contains { $0.hasPrefix("Look by hand at") })
    }

    // ---- what OCR can't read ----

    static func oneScan(_ reader: PlantedReader) throws -> (pdf: [UInt8], dropped: RectD) {
        let source = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 14 Tf 72 700 Td (A heading that reads well) Tj ET\nBT /F1 14 Tf 72 640 Td (SSN 111-22-3333 on this line) Tj ET\nBT /F1 14 Tf 72 580 Td (A closing line of words) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let engine = try PdfEngine.open(source)
        defer { engine.close() }
        let (gray, w, h) = try RedactionCorpus.gray(engine, 0, scale: 150.0 / 72)
        let text = try engine.text(0)
        reader.plant(612, 792, text)
        let hit = text.find("111-22-3333", matchCase: true, wholeWord: false)[0]
        return (RedactionCorpus.imagePdf(gray, w, h, 612, 792), text.rects(hit.start, hit.end)[0])
    }

    private static func find(_ pdf: [UInt8], _ options: RedactionPatternOptions = RedactionPatternOptions(), _ ocr: (any TextRecognizer)? = nil) throws -> RedactionSearchResult {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try RedactionSearch.find(engine, options, ocr: ocr)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aValueOcrCantReadIsFlaggedNeverPassedAsClean() throws {
        let reader = PlantedReader()
        let (scan, value) = try Self.oneScan(reader)
        for word in ["SSN", "111-22-3333", "on", "this", "line"] { reader.drop(word) }
        let found = try Self.find(scan, RedactionPatternOptions(), reader)

        #expect(found.hits.isEmpty) // OCR can't see it, so the search can't either
        let look = try #require(found.looks.count == 1 ? found.looks[0] : nil)
        #expect(look.reason == .scanReadByOcr)
        #expect(look.text.contains("read by text recognition"))
        #expect(look.unread.contains { !$0.intersect(value).isEmpty }) // and the place it is in is named
        #expect(reader.placesReadCount > 0) // after trying that place on its own
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aScanOcrReadsWellIsStillAPageToLookAt() throws {
        let reader = PlantedReader()
        let (scan, _) = try Self.oneScan(reader)
        let found = try Self.find(scan, RedactionPatternOptions(), reader)
        #expect(found.hits.map(\.normalized) == ["111-22-3333"])
        #expect(found.hits.first?.fromOcr == true)
        #expect(found.looks.map(\.reason) == [.scanReadByOcr])
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aLineDroppedOnTheWholePageComesBackWhenItsPlaceIsReadAlone() throws {
        let reader = PlantedReader()
        reader.readsPlacesAlone = true
        let (scan, value) = try Self.oneScan(reader)
        reader.drop("111-22-3333")
        let found = try Self.find(scan, RedactionPatternOptions(), reader)
        #expect(found.hits.map(\.normalized) == ["111-22-3333"])
        #expect(found.hits.first?.rects.contains { !$0.intersect(value).isEmpty } == true)
    }

    @Test func aScanWithoutARecognizerIsNotSearchedAndSaysSo() throws {
        let (scan, _) = try Self.oneScan(PlantedReader())
        let found = try Self.find(scan)
        #expect(found.hits.isEmpty)
        #expect(found.unreadScans == [0])
    }

    private struct BrokenReader: TextRecognizer {
        struct GaveUp: Error {}
        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] { throw GaveUp() }
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aRecognizerThatFailsLeavesTheScanNotReadNotClean() throws {
        let (scan, _) = try Self.oneScan(PlantedReader())
        #expect(try Self.find(scan, RedactionPatternOptions(), BrokenReader()).unreadScans == [0])
    }

    @Test func aVeryFaintScanIsntTakenForABlankPage() throws {
        let (w, h) = (200, 260)
        let faint = [UInt8](repeating: 240, count: w * h)
        #expect(try Self.find(RedactionCorpus.imagePdf(faint, w, h, 612, 792)).unreadScans == [0])
    }

    @Test func aBlankPageNeedsNoLook() throws {
        let pdf = Core2Pdf.build(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"])
        #expect(try Self.find(pdf).looks.isEmpty)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func keepingAHundredThousandHitsDoesntStallTheReadBack() throws {
        let line = Array(repeating: "555-201-3434", count: 40).joined(separator: " ")
        let content = (0..<200).map { "BT /F1 9 Tf 10 \(3900 - $0 * 12) Td (\(line)) Tj ET\n" }.joined()
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 6000 4000] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream(content),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let clock = Date()
        let hits = try Self.find(pdf).hits
        #expect(hits.count == 8000)
        #expect(try RedactionSearch.readBack(pdf, nil, RedactionPatternOptions(), ocr: nil, redactedPages: [], kept: hits).hits.isEmpty)
        #expect(Date().timeIntervalSince(clock) < 60, "took \(Date().timeIntervalSince(clock)) s")
    }

    @Test func batchFailsAFileWithAScanItCantRead() async throws {
        let path = p("scan.pdf")
        try Data(try Self.oneScan(PlantedReader()).pdf).write(to: URL(fileURLWithPath: path))
        let plan = BatchPlan(steps: [.redactPatterns(RedactionPatternOptions())], outputFolder: p("out"))
        let summary = try await BatchRunner.run([BatchFile(path)], plan, BatchHost())
        let item = summary.items[0]
        #expect(item.state == .failed)
        #expect(item.message.contains("is a scan"), "\(item.message)")
        #expect(item.outputs.isEmpty)
    }

    /// Reads the value wherever it is handed a picture, as if the black box had missed it.
    struct AlwaysReads: TextRecognizer {
        var language: String? { "en-US" }
        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
            let (w, h) = (Double(image.width), Double(image.height))
            return [OcrWord("111-22-3333", RectD(w * 0.2, h * 0.4, w * 0.3, h * 0.02))]
        }
    }

    @Test(.enabled(if: ScanCorpus.runs)) func batchFailsAFileWhenAHitIsStillThereAfterApplying() async throws {
        let path = p("scan.pdf")
        try Data(try Self.oneScan(PlantedReader()).pdf).write(to: URL(fileURLWithPath: path))
        let plan = BatchPlan(steps: [.redactPatterns(RedactionPatternOptions())], outputFolder: p("out"))
        let summary = try await BatchRunner.run([BatchFile(path)], plan, BatchHost(reader: AlwaysReads()))
        let item = summary.items[0]
        #expect(item.state == .failed)
        #expect(item.message.contains("still there"), "\(item.message)")
        #expect(item.outputs.isEmpty)
        let redaction = try #require(item.redaction)
        #expect(redaction.removals.contains { $0.outcome == .stillThere })
        #expect(!redaction.removals.contains { $0.outcome == .removed })
        let csv = Csv.decode(Array(try Data(contentsOf: URL(fileURLWithPath: try #require(summary.redactionReportPath)))))
        #expect(!csv.contains("111-22-3333"))
    }

    @Test func aSignedFileIsntExportedUnredacted() async throws {
        let signed = p("signed.pdf")
        try Data(try Core2SignatureTests.signed()).write(to: URL(fileURLWithPath: signed))
        let plan = BatchPlan(steps: [.redactPatterns(RedactionPatternOptions()), .export(.text, dpi: 150)], outputFolder: p("out"))
        let summary = try await BatchRunner.run([BatchFile(signed)], plan, BatchHost())
        #expect(summary.items[0].state == .skipped, "\(summary.items[0].message)")
        #expect(summary.items[0].outputs.isEmpty)
    }

    @Test func anExportBeforeRedactionIsRefused() {
        let plan = BatchPlan(steps: [.export(.text, dpi: 150), .redactPatterns(RedactionPatternOptions())], outputFolder: p("out"))
        #expect(plan.validate(ocrAvailable: false)?.contains("before exports") == true)
    }

    /// Opt-in: INKVOLTPDF_REDACT_CORPUS names a folder to write the corpus into, for driving the real app over it.
    @Test func writesTheCorpusWhenAsked() throws {
        guard let folder = ProcessInfo.processInfo.environment["INKVOLTPDF_REDACT_CORPUS"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let plain = try RedactionCorpus.make().pdf
        try Data(plain).write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("redaction-corpus.pdf")))
        try Data(try RedactionCorpus.encrypted(plain)).write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("redaction-corpus-locked.pdf")))
    }

    // ---- an ordinary file ----

    private struct CountingReader: TextRecognizer {
        struct Called: Error {}
        func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] { throw Called() }
    }

    @Test func anOrdinaryTextPageWithRulesIsntFlaggedOrRecognized() throws {
        let page = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (Plain words in a plain line of text) Tj ET\n1 w 72 690 m 540 690 l S\n72 600 468 80 re S\nBT /F1 12 Tf 80 640 Td (Inside a ruled box) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        #expect(try Self.find(page, RedactionPatternOptions(), CountingReader()).looks.isEmpty)
    }

    @Test func textDrawnAsShapesCountsAsInkNothingRead() throws {
        // Blocks a person reads as a word, no text in the file (a font turned into shapes).
        let shapes = (0..<14).map { "\(72 + $0 * 9) 700 6 10 re f\n" }.joined()
        let page = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 650 Td (Some real text too) Tj ET\n" + shapes),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let found = try Self.find(page)
        #expect(found.looks.count == 1)
        #expect(found.looks.first?.reason == .picturesNotRead)
        #expect(found.looks.first?.unread.count == 1)
    }

    // ---- how recognition's slips read ----

    private static func words(_ words: [String]) -> PageText {
        RedactionSearch.ocrPageText(words.enumerated().map { OcrWord($0.element, RectD(50 + Double($0.offset) * 80, 100, 70, 12)) })
    }

    @Test(arguments: [
        (RedactionPattern.socialSecurity, "l23-45-6789"), // l for 1
        (.socialSecurity, "123 - 45 - 6789"), // spaces round the dashes
        (.paymentCard, "4111 1lll 1111 1111"),
        (.paymentCard, "4111 1111 1111 1112"), // one digit misread: the check digit fails, it still counts
        (.email, "jane.doe @ example.com"),
    ])
    func slipsOfARecognizerStillCount(_ kind: RedactionPattern, _ read: String) throws {
        let options = RedactionPatternOptions(patterns: [kind])
        let parts = read.split(separator: " ").map(String.init)
        #expect(try RedactionPatterns.findOnPage(Self.words(parts), 0, options, nil, lenient: true).count == 1)
        #expect(try RedactionPatterns.findOnPage(Self.words(parts), 0, options, nil).isEmpty) // a page's own text isn't read so kindly
    }

    @Test func aHitOnARecognizedWordCoversTheWholeWord() throws {
        // "SSN:111-22-3333," read as one word: its place within the word isn't known, so all of it goes.
        let text = RedactionSearch.ocrPageText([OcrWord("SSN:111-22-3333,", RectD(100, 100, 120, 12))])
        let hits = try RedactionPatterns.findOnPage(text, 0, RedactionPatternOptions(), nil, lenient: true)
        #expect(hits.count == 1)
        #expect(abs((hits.first?.rects[0].x ?? 0) - 100) < 0.001)
        #expect(abs((hits.first?.rects[0].right ?? 0) - 220) < 0.001)
    }

    @Test func wordsAtAnAngleStayOnTheirLine() {
        // A sideways line: each word further down the page.
        let words = ["SSN", "111-22-3333", "here"].enumerated().map { OcrWord($0.element, RectD(300 - 35, 100 + Double($0.offset) * 80 + 30, 70, 12), angle: 90) }
        #expect(RedactionSearch.ocrPageText(words).text == "SSN 111-22-3333 here")
    }

    // ---- attacks ----

    private static func lines(_ lines: String...) -> PageText { RedactionPatternTests.page(lines) }

    @Test(.enabled(if: ScanCorpus.runs)) func hugeHitCountsStopRatherThanGrindAndNothingIsPartial() {
        // 200,000 phone numbers on one page: finding them mustn't be quadratic, and the search says it stopped.
        let line = Array(repeating: "555-201-3434", count: 200_000).joined(separator: " ")
        let clock = Date()
        #expect(throws: TooManyHits.self) { try RedactionPatterns.find(Self.lines(line), 0, RedactionPatternOptions()) }
        #expect(Date().timeIntervalSince(clock) < 60, "took \(Date().timeIntervalSince(clock)) s")
    }

    @Test(.enabled(if: ScanCorpus.runs)) func manyHitsUnderTheLimitAreFastEnough() throws {
        let line = Array(repeating: "555-201-3434", count: 20_000).joined(separator: " ")
        let clock = Date()
        #expect(try RedactionPatterns.find(Self.lines(line), 0, RedactionPatternOptions()).count == 20_000)
        #expect(Date().timeIntervalSince(clock) < 30, "took \(Date().timeIntervalSince(clock)) s")
    }

    @Test(.enabled(if: ScanCorpus.runs)) func anExpressionThatKeepsJustUnderItsTimeoutCantRunForever() {
        RedactionPatterns.$pageBudgetForTests.withValue(1) {
            // Each match costs real time (under the timeout per call), so only the page's budget stops it.
            let text = Self.lines(Array(repeating: String(repeating: "x", count: 21) + "! xxy", count: 400).joined(separator: " "))
            let options = RedactionPatternOptions(patterns: [], expression: "(x+x+)+y")
            let clock = Date()
            #expect(throws: RedactionSearchTimeout.self) { try RedactionPatterns.find(text, 0, options) }
            #expect(Date().timeIntervalSince(clock) < 60, "took \(Date().timeIntervalSince(clock)) s")
        }
    }

    @Test(.enabled(if: ScanCorpus.runs), arguments: ["(a{1000}){1000}{1000}", "((a+)+)+$", #"(\w+\s?)*$"#, "(?<=(a+)+)b"])
    func catastrophicExpressionsEndInAnErrorNotAHang(_ expression: String) {
        let options = RedactionPatternOptions(patterns: [], expression: expression)
        let clock = Date()
        do {
            _ = try RedactionPatterns.find(Self.lines(String(repeating: "a", count: 5000) + "!"), 0, options)
        } catch is RedactionSearchTimeout {
            // told, and nothing passes as clean
        } catch is PdfEditError {
            // refused before it ran
        } catch {
            Issue.record("\(error)")
        }
        #expect(Date().timeIntervalSince(clock) < 60, "took \(Date().timeIntervalSince(clock)) s")
    }

    @Test(arguments: ["123\u{200B}-45-6789", "123-45\u{AD}-6789", "１２３-４５-６７８９", "123-45\u{202E}-6789"])
    func invisibleAndWideCharactersDontHideANumber(_ text: String) throws {
        #expect(try RedactionPatterns.find(Self.lines("SSN \(text) here"), 0, RedactionPatternOptions()).count == 1)
    }

    @Test func aDashStartingTheNextLineKeepsTheNumberWhole() throws {
        let hits = try RedactionPatterns.find(Self.lines("SSN 123-45", "-6789 here"), 0, RedactionPatternOptions())
        #expect(hits.map(\.normalized) == ["123-45-6789"])
    }

    @Test func textWithoutABoxStillTakesItsPage() throws {
        let empty = RectD(10, 10, 0, 0)
        let text = PageText([Array("123-45-6789").map { (String($0), empty) }])
        let hits = try RedactionPatterns.find(text, 0, RedactionPatternOptions())
        #expect(hits.count == 1)
        #expect(hits.first?.rects[0].isEmpty == false)
    }

    @Test func hostileContextIsMadeHarmlessToShow() throws {
        let hits = try RedactionPatterns.find(Self.lines("\u{202E}evil\u{7} text 123-45-6789 \u{202D}more\u{1} words"), 0, RedactionPatternOptions())
        #expect(hits.count == 1)
        #expect(hits.first?.before == "evil text ")
        #expect(hits.first?.after == " more words")
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aHiddenPageTextOverAPictureDoesntVouchForIt() throws {
        // Invisible text boxes a whole page tall can't vouch for the ink under them.
        let (data, reader) = try RedactionCorpus.make()
        let layered = try Self.find(data, RedactionPatternOptions(pages: [8]), reader)
        #expect(layered.hits.contains { $0.normalized == "321-54-9876" })
    }

    @Test func patternsFindWhatNoPageShows() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Annots [6 0 R] /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (Nothing private on this page) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Call 555-201-3434 or mail hidden@example.org) >>",
        ])
        let report = try RedactionCheck.run(pdf, nil, RedactionCheckOptions(patterns: RedactionPatternOptions(), valuesOnly: true))
        #expect(!report.isClean)
        #expect(report.findings.contains { $0.kind == .annotation })
    }

    @Test func whatThePersonKeptIsntReportedLeft() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (Mail kept@example.org today) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let kept = ["kept@example.org"]
        #expect(try !RedactionCheck.run(pdf, nil, RedactionCheckOptions(values: kept, valuesOnly: true)).isClean)
        #expect(try RedactionCheck.run(pdf, nil, RedactionCheckOptions(values: kept, kept: kept, valuesOnly: true)).isClean)

        let hits = try Self.find(pdf).hits
        #expect(hits.count == 1)
        #expect(try RedactionSearch.readBack(pdf, nil, RedactionPatternOptions(), ocr: nil, redactedPages: [], kept: []).hits.count == 1)
        #expect(try RedactionSearch.readBack(pdf, nil, RedactionPatternOptions(), ocr: nil, redactedPages: [], kept: hits).hits.isEmpty)
    }

    @Test func aValueAmongPicturePixelsInAStreamIsStillInTheRawText() {
        let inside = [UInt8](repeating: 0, count: 2_000_000) + Array("hidden 123-45-6789 value".utf8) + [UInt8](repeating: 0xFF, count: 2_000_000)
        let file = Array("1 0 obj\nstream\n".utf8) + Deflate.zlib(inside) + Array("endstream\n".utf8)
        let text = RedactionCheck.rawText(file, nil)
        #expect(text.contains("hidden 123-45-6789 value"))
        #expect(text.utf16.count < 1_000_000, "\(text.utf16.count) characters kept")
    }

    @Test func manyValuesAreLookedForOrTheCheckSaysItCouldnt() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (A plain value here) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let values = (1000..<1800).map { "value-number-\($0)-\(String(repeating: "x", count: 150))" }
        let report = try RedactionCheck.run(pdf, nil, RedactionCheckOptions(values: values, valuesOnly: true))
        #expect(report.incomplete)
        #expect(report.notes.contains { $0.contains("first 500") })

        // A few hundred numbers are more than one search could hold on Windows: each is still found.
        let numbers = (0..<400).map { "\(100 + $0)-55-\(1000 + $0)" } + ["Plain value"]
        let found = try RedactionCheck.run(pdf, nil, RedactionCheckOptions(values: numbers, valuesOnly: true))
        #expect(!found.incomplete, "\(found.notes)")
        #expect(found.findings.contains { $0.kind == .pageText })
    }
}
