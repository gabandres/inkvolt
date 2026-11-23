import Foundation
import Testing
@testable import PdfCore

/// Ported from TextReplaceTests.cs: Find & Replace across the document (roadmap 4.2): matches found in the paragraphs Edit
/// Text & Images edits, and replaced through its paragraph editing in one pass (one undo step, one incremental update for
/// a signed file), each replacement that can't be made as asked listed with what was done instead. Adapted: `nextAfter`
/// gives nil where Windows' gives -1; the signed file is signed-looking (a /ByteRange placeholder, as SignedEditTests').
struct TextReplaceTests {
    /// What `ContentEditPdf`'s fonts hold: no "@", "#" or "€".
    private static let chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 .,;:!?'-"

    private static func page(_ paragraphs: [[String]]) -> String {
        var s = ""
        var y = 700
        for lines in paragraphs {
            s += "BT /F1 12 Tf 15 TL 72 \(y) Td (\(lines[0])) Tj"
            for l in lines.dropFirst() { s += " T* (\(l)) Tj" }
            s += " ET\n"
            y -= 15 * lines.count + 60
        }
        return s
    }

    /// Pages of Helvetica paragraphs (each page a list of paragraphs, each a list of lines).
    private static func doc(_ pages: [[String]]...) -> [UInt8] {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(pages.indices.map { "\(4 + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        for i in pages.indices {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(5 + 2 * i) 0 R /Resources << /Font << /F1 3 0 R >> >> >>")
            objects.append(Core2Pdf.stream(page(pages[i])))
        }
        return Core2Pdf.build(objects)
    }

    private static let invoices = doc(
        [
            ["The invoice total is due on Friday. Send the", "invoice to the office before the deadline."],
            ["A second paragraph mentions the Invoice once,", "and invoices should not match whole words."],
        ],
        [["Page two has an invoice too, and the office."]])

    private static func text(_ pdf: [UInt8], _ page: Int = 0) throws -> String {
        try ContentEditor.read(pdf, nil, page).paragraphs.map(\.text).joined(separator: " | ")
    }

    private static func starts(_ hits: [(start: Int, length: Int)]) -> [Int] { hits.map(\.start) }

    @Test func CaseAndWholeWordsAreAsAsked() {
        let text = "Invoice, invoice and invoices; reinvoice INVOICE."
        #expect(TextReplace.findIn(text, ReplaceQuery("invoice")).count == 5)
        #expect(Self.starts(TextReplace.findIn(text, ReplaceQuery("invoice", matchCase: true))) == [9, 21, 33])
        #expect(Self.starts(TextReplace.findIn(text, ReplaceQuery("invoice", wholeWord: true))) == [0, 9, 41])
        #expect(TextReplace.findIn(text, ReplaceQuery("Invoice", wholeWord: true)).map { [$0.start, $0.length] } == [[0, 7], [9, 7], [41, 7]])
        #expect(TextReplace.findIn("aaa a, b", ReplaceQuery(", ", wholeWord: true)).map { [$0.start, $0.length] } == [[5, 2]]) // punctuation at its edges needs no word break
        #expect(TextReplace.findIn("aaaa", ReplaceQuery("aa")).map { [$0.start, $0.length] } == [[0, 2], [2, 2]]) // no overlaps
    }

    @Test func NothingIsFoundForNothing() throws {
        #expect(TextReplace.findIn("text", ReplaceQuery("")).isEmpty)
        #expect(try TextReplace.find(Self.invoices, nil, ReplaceQuery("")).matches.isEmpty)
    }

    @Test func AnOverlongQueryFindsNothing() {
        #expect(TextReplace.findIn(String(repeating: "a", count: 2000), ReplaceQuery(String(repeating: "a", count: TextReplace.maxQuery + 1))).isEmpty)
    }

    @Test func MatchesComeWithTheirPageAndTheWordsAround() throws {
        let found = try TextReplace.find(Self.invoices, nil, ReplaceQuery("invoice", wholeWord: true))
        #expect(!found.cutShort)
        #expect(found.matches.count == 4)
        #expect(found.pages == 2)
        #expect(found.matches.map(\.pageIndex) == [0, 0, 0, 1])
        let first = found.matches[0]
        #expect(first.before == "The " && first.found == "invoice")
        #expect(first.after.hasPrefix(" total is due on Friday."))
        #expect(first.after.hasSuffix("…"))
        #expect(found.matches[2].found == "Invoice")
        #expect(first.blocked == nil)
    }

    @Test func APhraseWrappedAcrossLinesIsFound() throws {
        let found = try TextReplace.find(Self.invoices, nil, ReplaceQuery("send the invoice"))
        #expect(found.matches.map(\.found) == ["Send the invoice"])
    }

    @Test func AListOfMatchesStopsAndSaysSo() throws {
        // Three pages of 45 lines of 45 words: 6,075 matches, more than are listed.
        let line = Array(repeating: "a", count: 45).joined(separator: " ")
        let page = [Array(repeating: line, count: 45)]
        let found = try TextReplace.find(Self.doc(page, page, page), nil, ReplaceQuery("a", wholeWord: true))
        #expect(found.cutShort)
        #expect(found.matches.count == TextReplace.maxMatches)
    }

    @Test func ReplaceAllRewritesEveryParagraphInOnePass() throws {
        let found = try TextReplace.find(Self.invoices, nil, ReplaceQuery("invoice", wholeWord: true))
        let result = try TextReplace.replace(Self.invoices, nil, found.matches, with: "bill")
        #expect(result.replaced == 4)
        #expect(result.notes.isEmpty)
        #expect(try Self.text(result.data) == "The bill total is due on Friday. Send the bill to the office before the deadline. | "
            + "A second paragraph mentions the bill once, and invoices should not match whole words.")
        #expect(try Self.text(result.data, 1) == "Page two has an bill too, and the office.")
        #expect(try TextReplace.find(result.data, nil, ReplaceQuery("invoice", wholeWord: true)).matches.isEmpty)
    }

    @Test func ReplaceChangesOnlyTheMatchesGiven() throws {
        let found = try TextReplace.find(Self.invoices, nil, ReplaceQuery("office"))
        let result = try TextReplace.replace(Self.invoices, nil, [found.matches[1]], with: "desk")
        #expect(result.replaced == 1)
        #expect(try Self.text(result.data).contains("invoice to the office before"))
        #expect(try Self.text(result.data, 1) == "Page two has an invoice too, and the desk.")
    }

    @Test func NothingReplacedGivesTheSameBytesBack() throws {
        #expect(try TextReplace.replace(Self.invoices, nil, [], with: "x").data == Self.invoices)
    }

    @Test func ReplacingWithTheSameTextChangesAndCountsNothing() throws {
        let found = try TextReplace.find(Self.invoices, nil, ReplaceQuery("Invoice"))
        let result = try TextReplace.replace(Self.invoices, nil, found.matches.filter { $0.found == "Invoice" }, with: "Invoice")
        #expect(result.replaced == 0)
        #expect(result.notes.isEmpty)
        #expect(result.data == Self.invoices)
    }

    @Test func APageOfManyMatchingParagraphsIsReadOnce_UnlessOneIsRewritten_AndReplaceAllStops() throws {
        // 4 columns of 30 short paragraphs, each "cat": 120 paragraphs on one page.
        var s = ""
        for col in 0..<4 {
            for row in 0..<30 { s += "BT /F1 6 Tf \(40 + col * 140) \(760 - row * 24) Td (cat number \(col * 30 + row)) Tj ET\n" }
        }
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [4 0 R] /Count 1 >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 3 0 R >> >> >>",
            Core2Pdf.stream(s),
        ])
        _ = try TextReplace.find(pdf, nil, ReplaceQuery("cat", wholeWord: true)) // warmed up: the time below is the page's reading
        var clock = ContinuousClock.now
        let found = try TextReplace.find(pdf, nil, ReplaceQuery("cat", wholeWord: true))
        let findTime = ContinuousClock.now - clock
        #expect(Set(found.matches.map(\.paragraph)).count == 120)

        // Nothing to write ("cat" for "cat"): the page is read once, not once a paragraph (120 times before).
        var steps: [[Int]] = []
        clock = ContinuousClock.now
        let same = try TextReplace.replace(pdf, nil, found.matches, with: "cat", progress: { steps.append([$0, $1]) })
        let replaceTime = ContinuousClock.now - clock
        print("find \(findTime), replace with the same \(replaceTime)")
        #expect(same.replaced == 0)
        #expect(replaceTime < findTime * 15 + .milliseconds(500), "find \(findTime), replace \(replaceTime)")
        #expect(steps == [[0, 1]])

        // Each rewrite reads the page again for the next paragraph, so every one is still made where it stands.
        let dogs = try TextReplace.replace(pdf, nil, Array(found.matches.prefix(5)), with: "dog")
        #expect(dogs.replaced == 5)
        #expect(try TextReplace.find(dogs.data, nil, ReplaceQuery("dog", wholeWord: true)).matches.count == 5)

        // Stopped: nothing is changed.
        let stop = CancelToken()
        stop.cancel()
        #expect(throws: CancellationError.self) { try TextReplace.replace(pdf, nil, found.matches, with: "dog", cancel: stop) }
    }

    @Test func AfterReplaceTheNextMatchIsPastTheInsertedText() throws {
        // "cat" → "cats": found again, the replaced match still holds "cat"; the next is the one after it.
        let pdf = Self.doc([["A cat sat by the cat door, and a third cat slept."]], [["One more cat."]])
        let before = try TextReplace.find(pdf, nil, ReplaceQuery("cat")).matches
        let replaced = before[0]
        let after = try TextReplace.find(try TextReplace.replace(pdf, nil, [replaced], with: "cats").data, nil, ReplaceQuery("cat")).matches
        #expect(before.count == after.count)
        let next = try #require(TextReplace.nextAfter(after, replaced, inserted: 4))
        #expect(next == 1)
        #expect(after[next].after.hasPrefix(" door"))
        // The last one replaced: nothing after it, and no going round to the start.
        var last = after[after.count - 1]
        last.length = 3
        #expect(TextReplace.nextAfter(after, last, inserted: 4) == nil)
    }

    @Test func AMatchKeepsItsKeyAcrossAReplaceBeforeIt() {
        let replaced = ReplaceMatch(1, 2, 10, 3, "cat", "", "")
        #expect(ReplaceKey(1, 2, 20).after(replaced, inserted: 4) == ReplaceKey(1, 2, 21)) // later in its paragraph: moves
        #expect(ReplaceKey(1, 2, 4).after(replaced, inserted: 4) == ReplaceKey(1, 2, 4)) // before it: stays
        #expect(ReplaceKey(1, 3, 20).after(replaced, inserted: 4) == ReplaceKey(1, 3, 20)) // another paragraph: stays
        #expect(ReplaceKey(2, 2, 20).after(replaced, inserted: 4) == ReplaceKey(2, 2, 20))
        #expect(ReplaceKey(1, 2, 10).after(replaced, inserted: 4) == nil) // the one replaced
    }

    @Test func MatchesOfAnOlderVersionAreListedAsChanged() throws {
        let found = try TextReplace.find(Self.invoices, nil, ReplaceQuery("office"))
        let edited = try TextReplace.replace(Self.invoices, nil, [found.matches[1]], with: "desk").data
        let result = try TextReplace.replace(edited, nil, found.matches, with: "room")
        #expect(result.replaced == 1) // page 1's paragraph still reads as found
        #expect(result.notes.map(\.kind) == [.changed])
        #expect(result.notes.first?.match.pageIndex == 1)
        #expect(result.left == 1)
    }

    @Test func ALongerParagraphThatWouldRunIntoWhatFollowsIsLeftAndListed() throws {
        let pdf = Self.doc([["A short paragraph here, wrapped in a box", "of two lines."], ["Next block starts right below."]])
        // The paragraphs are 60 points apart: a replacement ten lines long would reach the next one.
        let found = try TextReplace.find(pdf, nil, ReplaceQuery("here"))
        let result = try TextReplace.replace(pdf, nil, found.matches, with: Array(repeating: "many more words in this long replacement", count: 12).joined(separator: " "))
        let after = try Self.text(result.data)
        #expect(result.replaced == 0, "\(after)")
        #expect(result.notes.map(\.kind) == [.wouldOverlap])
        #expect(result.data == pdf)
    }

    @Test func TextOnOneLineDoesntWrapAndSaysHowMuchWiderItIs() throws {
        let pdf = Self.doc([["A heading"], ["Next block starts right below."]])
        let result = try TextReplace.replace(pdf, nil, try TextReplace.find(pdf, nil, ReplaceQuery("heading")).matches, with: "much longer heading")
        #expect(result.replaced == 1)
        let note = try #require(result.notes.count == 1 ? result.notes[0] : nil)
        #expect(note.kind == .wider)
        #expect(note.made)
        #expect((50...120).contains(note.wider))
        #expect(try Self.text(result.data) == "A much longer heading | Next block starts right below.")
    }

    @Test func CharactersTheFontLacksAreDrawnFromAnInstalledFontAndListed() throws {
        let pdf = ContentEditPdf.make("BT /FA 12 Tf 15 TL 72 700 Td (Write to the office today and keep a copy for later.) Tj ET", fontText: Self.chars)
        let found = try TextReplace.find(pdf, nil, ReplaceQuery("office"))
        let result = try TextReplace.replace(pdf, nil, found.matches, with: "office @ home #2")
        #expect(result.replaced == 1)
        let others = result.notes.filter { $0.kind != .wider } // one line: it is wider too
        let note = try #require(others.count == 1 ? others[0] : nil)
        #expect(note.kind == .standIn)
        #expect(note.made)
        #expect(note.chars == ["@", "#"])
        #expect(!note.fonts.isEmpty)
        #expect(try Self.text(result.data).contains("office @ home #2 today"))
    }

    @Test func CharactersNoFontHasAreListedAndTheTextStays() throws {
        let pdf = ContentEditPdf.make("BT /FA 12 Tf 15 TL 72 700 Td (Write to the office today.) Tj ET", fontText: Self.chars)
        let found = try TextReplace.find(pdf, nil, ReplaceQuery("office"))
        let result = try TextReplace.replace(pdf, nil, found.matches, with: "office \u{10FFFD}")
        #expect(result.replaced == 0)
        let note = try #require(result.notes.count == 1 ? result.notes[0] : nil)
        #expect(note.kind == .missing)
        #expect(!note.made)
        #expect(note.chars == ["\u{10FFFD}"])
        #expect(result.data == pdf)
    }

    @Test func ASignedFileGetsTheReplacementsAppendedOnce() throws {
        let placeholder = "[0 0000000000 0000000000 0000000000]"
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 750 272 780] /V 5 0 R /P 3 0 R /F 4 >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange \(placeholder) /Contents <\(String(repeating: "0", count: IncrSignatureTests.contentsHexLength))> >>",
            Core2Pdf.stream(Self.page([["This agreement is made between the two parties named", "below, who agree to the terms."], ["The two parties sign below."]])),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let found = try TextReplace.find(pdf, nil, ReplaceQuery("two parties"))
        #expect(found.matches.count == 2)
        let (edited, report) = try SignedEdits.run { try TextReplace.replace(pdf, nil, found.matches, with: "three parties").data }
        #expect(report.appended)
        #expect(Array(edited.prefix(pdf.count)) == pdf)
        #expect(Self.countOf(edited, "%%EOF") - Self.countOf(pdf, "%%EOF") == 1) // one update for both paragraphs
        #expect(try TextReplace.find(edited, nil, ReplaceQuery("three parties")).matches.count == 2)
    }

    private static func countOf(_ data: [UInt8], _ s: String) -> Int {
        let needle = Array(s.utf8)
        var n = 0, from = data.startIndex
        while let r = data[from...].firstRange(of: needle) {
            n += 1
            from = r.upperBound
        }
        return n
    }

    @Test func ReplaceAllIsOneUndoStep() async throws {
        let session = try DocumentSession.fromBytes(Self.invoices, "t.pdf")
        let found = try TextReplace.find(session.data, nil, ReplaceQuery("invoice"))
        let matches = found.matches
        let result = await session.edit(EditRequest("Replace All") { d, pw in try TextReplace.replace(d, pw, matches, with: "bill").data },
                                        prompts: EditTransactionTests.ScriptedPrompts())
        #expect(result.outcome == .done)
        #expect(try TextReplace.find(session.data, nil, ReplaceQuery("invoice")).matches.isEmpty)
        try session.undo()
        #expect(session.undoStepId == nil)
        #expect(try TextReplace.find(session.data, nil, ReplaceQuery("invoice")).matches.count == found.matches.count)
    }

    /// The pdf.js half (opt-in with INKVOLTPDF_PDFJS, as `ParagraphEditTests.editedParagraphsReadTheSameInPdfJs`): after
    /// Replace All, pdf.js reads each rewritten paragraph's words in order, the replacements and a stand-in character included.
    @Test func ReplacedTextReadsTheSameInPdfJs() throws {
        guard let flag = ProcessInfo.processInfo.environment["INKVOLTPDF_PDFJS"], !flag.isEmpty else { return }
        guard let node = ParagraphEditTests.onPath("node"), let npm = ParagraphEditTests.onPath("npm") else {
            print("Skipped: node or npm isn't on the PATH.")
            return
        }
        let tool = ParagraphEditTests.pdfJsTool
        if !FileManager.default.fileExists(atPath: tool.appendingPathComponent("node_modules").path) {
            _ = try ParagraphEditTests.runTool(npm, ["ci", "--no-audit", "--no-fund"], tool)
        }
        var failures: [String] = []
        let standIn = ContentEditPdf.make("BT /FA 12 Tf 15 TL 72 700 Td (Write to the office today and keep a copy) Tj T* (of the office letter for later.) Tj ET",
                                          fontText: Self.chars)
        for (name, pdf, find, with) in [("Helvetica", Self.invoices, "invoice", "purchase bill"), ("stand-ins", standIn, "office", "office @ home #2")] {
            let result = try TextReplace.replace(pdf, nil, try TextReplace.find(pdf, nil, ReplaceQuery(find, wholeWord: true)).matches, with: with)
            for page in 0..<(name == "Helvetica" ? 2 : 1) {
                for p in try ContentEditor.read(result.data, nil, page).paragraphs {
                    let got = Self.words(try ParagraphEditTests.pdfJsText(node, result.data, page))
                    let miss = ParagraphEditTests.firstMiss(Self.words(p.text), got)
                    print("\(name) p\(page + 1): '\(p.text)' \(miss.map { "DIFFERS: " + $0 } ?? "read in order")")
                    if let miss { failures.append("\(name) p\(page + 1): \(miss)") }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    private static func words(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
