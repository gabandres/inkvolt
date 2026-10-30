import Foundation
import Testing
@testable import PdfCore

/// Ported from CompareTests.cs: compare two PDFs: the word diff, words of a page, page alignment, change grouping and
/// the pixel overlay. Adapted: the random rounds use SplitMix (.NET's `Random(7)` can't be reproduced) and a fixed hash
/// for Slide's cost; the contract versions are written by hand in Helvetica (PDFsharp draws them in Arial on Windows),
/// with the floor plan's ellipses as Bézier curves; renders are RGB (the Windows `RenderedImage` is BGR).
struct CompareTests {
    private static func w(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    /// Rebuilds both sides from the ops, so every op must cover the sequences in order without gaps.
    private static func assertCovers(_ a: [String], _ b: [String], _ ops: [DiffOp]) {
        var ia = 0, ib = 0
        for op in ops {
            #expect(op.length > 0, "empty op")
            #expect(op.a == ia && op.b == ib)
            switch op.kind {
            case .equal:
                for k in 0..<op.length where ia + k < a.count && ib + k < b.count { #expect(a[ia + k] == b[ib + k]) }
                ia += op.length
                ib += op.length
            case .delete: ia += op.length
            case .insert: ib += op.length
            }
        }
        #expect(ia == a.count && ib == b.count)
        for i in ops.indices.dropFirst() { #expect(ops[i - 1].kind != ops[i].kind) } // runs are merged
    }

    private static func matched(_ ops: [DiffOp]) -> Int { ops.filter { $0.kind == .equal }.reduce(0) { $0 + $1.length } }

    private static func lcs(_ a: [String], _ b: [String]) -> Int {
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                d[i][j] = a[i - 1] == b[j - 1] ? d[i - 1][j - 1] + 1 : max(d[i - 1][j], d[i][j - 1])
            }
        }
        return d[a.count][b.count]
    }

    @Test func identicalWordsAreOneEqualRun() throws {
        let a = Self.w("the quick brown fox")
        #expect(try WordDiff.diff(a, a) == [DiffOp(.equal, 0, 0, 4)])
    }

    @Test func insertedDeletedAndReplacedWordsAreFound() throws {
        #expect(try WordDiff.diff(Self.w("a b c d"), Self.w("a x b c d")) == [DiffOp(.equal, 0, 0, 1), DiffOp(.insert, 1, 1, 1), DiffOp(.equal, 1, 2, 3)])
        #expect(try WordDiff.diff(Self.w("a b c d"), Self.w("a c d")) == [DiffOp(.equal, 0, 0, 1), DiffOp(.delete, 1, 1, 1), DiffOp(.equal, 2, 1, 2)])
        #expect(try WordDiff.diff(Self.w("pay 100 dollars now"), Self.w("pay 150 dollars now"))
            == [DiffOp(.equal, 0, 0, 1), DiffOp(.delete, 1, 1, 1), DiffOp(.insert, 2, 1, 1), DiffOp(.equal, 2, 2, 2)])
    }

    @Test func emptySidesAreAllInsertedOrAllDeleted() throws {
        #expect(try WordDiff.diff([], []).isEmpty)
        #expect(try WordDiff.diff([], Self.w("a b")) == [DiffOp(.insert, 0, 0, 2)])
        #expect(try WordDiff.diff(Self.w("a b"), []) == [DiffOp(.delete, 0, 0, 2)])
    }

    @Test func myersFindsAShortestEditScript() throws {
        // The stretches between unique-word anchors go to Myers, which must be minimal: checked against the LCS.
        var rng = SplitMix(seed: 7)
        let letters = ["x", "y", "z"]
        for _ in 0..<300 {
            let a = (0..<rng.next(30)).map { _ in letters[rng.next(3)] }
            let b = (0..<rng.next(30)).map { _ in letters[rng.next(3)] }
            let ops = WordDiff.shortest(a, b)
            Self.assertCovers(a, b, ops)
            #expect(Self.lcs(a, b) == Self.matched(ops))
            Self.assertCovers(a, b, try WordDiff.diff(a, b))
        }
    }

    @Test func randomEditsAreValidAndNearlyMinimal() throws {
        var rng = SplitMix(seed: 11)
        let vocabulary = (0..<40).map { "w\($0)" }
        for round in 0..<200 {
            let a = (0..<rng.next(60)).map { _ in vocabulary[rng.next(vocabulary.count)] }
            var b = a
            for _ in 0..<rng.next(6) {
                let at = rng.next(b.count + 1)
                switch rng.next(3) {
                case 0: b.insert(vocabulary[rng.next(vocabulary.count)], at: at)
                case 1 where at < b.count: b.remove(at: at)
                default: if at < b.count { b[at] = vocabulary[rng.next(vocabulary.count)] }
                }
            }
            let ops = try WordDiff.diff(a, b)
            Self.assertCovers(a, b, ops)
            // Anchoring on unique words can cost a little against the true LCS, never much.
            #expect(Self.matched(ops) >= Self.lcs(a, b) - 3, "round \(round): matched \(Self.matched(ops)) of LCS \(Self.lcs(a, b))")
            // Sliding runs anywhere keeps the script valid and as short.
            let salt = rng.next(1_000_000)
            let slid = WordDiff.slide(ops, a, b) { k, s, _ in Double(((salt &* 31 &+ (k == .delete ? 1 : 2)) &* 31 &+ s) % 7) }
            Self.assertCovers(a, b, slid)
            #expect(Self.matched(ops) == Self.matched(slid))
        }
    }

    @Test func largeUnrelatedInputsFinishQuicklyAndStayValid() throws {
        let a = (0..<60_000).map { "a\($0)" }
        let b = (0..<60_000).map { "a\(59_999 - $0)" } // reversed: unique anchors everywhere
        var started = Date()
        var ops = try WordDiff.diff(a, b)
        #expect(Date().timeIntervalSince(started) < 5, "took \(Date().timeIntervalSince(started)) s")
        Self.assertCovers(a, b, ops)

        let c = (0..<40_000).map { $0 % 3 == 0 ? "x" : "y" }
        let d = (0..<40_000).map { $0 % 5 == 0 ? "x" : "y" } // no unique words at all
        started = Date()
        ops = try WordDiff.diff(c, d)
        #expect(Date().timeIntervalSince(started) < 5, "took \(Date().timeIntervalSince(started)) s")
        Self.assertCovers(c, d, ops)
    }

    @Test func diffCanBeCancelled() {
        let token = CancelToken()
        token.cancel()
        #expect(throws: CancellationError.self) { try WordDiff.diff(Self.w("a b"), Self.w("a c"), cancel: token) }
    }

    // ---- Words of a page ----

    private static let cw = 6.0, ch = 10.0

    /// A page whose lines are the given strings, fixed-width characters, one line every 14 pt.
    static func page(_ lines: String...) -> PageText { page(lines) }

    static func page(_ lines: [String]) -> PageText {
        PageText(lines.enumerated().map { li, l in
            l.enumerated().map { i, c in (String(c), RectD(50 + Double(i) * cw, 50 + Double(li) * 14, cw, ch)) }
        })
    }

    @Test func wordsSplitPunctuationKeepNumbersWholeAndJoinHyphenatedLineBreaks() throws {
        let page = Self.page("Hello, world: 1,250.75 was 3.", "the exam-", "ple ﬁle")
        let words = CompareWords.of(page, 2)
        #expect(words.map(\.key) == ["Hello", ",", "world", ":", "1,250.75", "was", "3", ".", "the", "example", "file"])
        #expect(words.allSatisfy { $0.page == 2 })
        let example = try #require(words.first { $0.key == "example" })
        #expect(String(decoding: Array(page.text.utf16)[example.start..<example.end], as: UTF16.self) == "exam-\nple")
        #expect((words[0].start, words[0].end) == (0, 5))
    }

    // ---- Page alignment and changes ----

    private static func pages(_ texts: String...) -> [PageText] { pages(texts) }
    private static func pages(_ texts: [String]) -> [PageText] { texts.map { $0.isEmpty ? PageText.empty : page($0) } }

    private static func rows(_ r: CompareResult) -> [String] { r.rows.map { "\($0.oldPage.map(String.init) ?? "-")/\($0.newPage.map(String.init) ?? "-")" } }

    @Test func identicalDocumentsPairPageByPageWithNoChanges() throws {
        let p = Self.pages("alpha one", "beta two", "gamma three")
        let r = try DocumentCompare.run(p, p)
        #expect(Self.rows(r) == ["0/0", "1/1", "2/2"])
        #expect(r.changes.isEmpty)
        #expect(r.identical)
        #expect(r.rows.allSatisfy { $0.text == .compared })
    }

    @Test func anEditedWordIsOneChangedChangeOnItsRowWithBothSidesHighlighted() throws {
        let r = try DocumentCompare.run(Self.pages("alpha one", "the fee is 100 dollars", "gamma three"), Self.pages("alpha one", "the fee is 150 dollars", "gamma three"))
        #expect(Self.rows(r) == ["0/0", "1/1", "2/2"])
        try #require(r.changes.count == 1)
        let c = r.changes[0]
        #expect(c.kind == .changed && c.row == 1 && c.oldText == "100" && c.newText == "150")
        #expect(c.old == [WordSpan(1, 11, 14)] && c.new == [WordSpan(1, 11, 14)])
        #expect((r.changed, r.inserted, r.deleted, r.pagesInserted + r.pagesRemoved) == (1, 0, 0, 0))
        #expect(r.rows[1].changes == 1)
        #expect(!r.identical)
    }

    @Test func insertedAndDeletedWordsAnchorOnTheOtherSide() throws {
        let r = try DocumentCompare.run(Self.pages("one two three four"), Self.pages("one three four five"))
        try #require(r.changes.count == 2)
        let del = r.changes[0]
        #expect(del.kind == .deleted && del.oldText == "two" && del.new.isEmpty)
        #expect(del.newAnchor == WordSpan(0, 3, 3)) // right after "one" in the new text
        let ins = r.changes[1]
        #expect(ins.kind == .inserted && ins.newText == "five")
        #expect(ins.oldAnchor == WordSpan(0, 18, 18)) // after "four" in the old text
        #expect((r.changed, r.inserted, r.deleted) == (0, 1, 1))
    }

    @Test func aRemovedPageIsOnePageChangeNotAWallOfDeletedWords() throws {
        let r = try DocumentCompare.run(Self.pages("alpha one", "beta removed text here", "gamma three"), Self.pages("alpha one", "gamma three"))
        #expect(Self.rows(r) == ["0/0", "1/-", "2/1"])
        try #require(r.changes.count == 1)
        #expect(r.changes[0].kind == .pageRemoved && r.changes[0].row == 1)
        #expect(r.pagesRemoved == 1)
        #expect(r.rows[1].text == .onlyOld)
    }

    @Test func anInsertedPageIsFoundEvenWhenItRepeatsWordsOfItsNeighbours() throws {
        let r = try DocumentCompare.run(Self.pages("intro text", "chapter one body", "chapter two body"),
                                        Self.pages("intro text", "chapter one body", "new chapter body", "chapter two body"))
        #expect(Self.rows(r) == ["0/0", "1/1", "-/2", "2/3"])
        try #require(r.changes.count == 1)
        #expect(r.changes[0].kind == .pageInserted && r.changes[0].row == 2)
        #expect(r.pagesInserted == 1)
    }

    @Test func aPageRewrittenInPlaceStaysPairedAsChanged() throws {
        let r = try DocumentCompare.run(Self.pages("alpha one", "old words entirely", "gamma three"), Self.pages("alpha one", "brand new content", "gamma three"))
        #expect(Self.rows(r) == ["0/0", "1/1", "2/2"])
        try #require(r.changes.count == 1)
        #expect(r.changes[0].kind == .changed && r.changes[0].oldText == "old words entirely" && r.changes[0].newText == "brand new content")
    }

    @Test func textMovingToTheNextPageIsNotAChange() throws {
        // The same words reflowed: the last line of page 1 moved to the top of page 2.
        let r = try DocumentCompare.run(Self.pages("one two three", "four five six"), Self.pages("one two", "three four five six"))
        #expect(Self.rows(r) == ["0/0", "1/1"])
        #expect(r.changes.isEmpty)
    }

    @Test func scannedPagesSayTheyHaveNoTextInsteadOfReportingEveryWordAsChanged() throws {
        var r = try DocumentCompare.run(Self.pages("alpha one", "beta two"), Self.pages("", ""))
        #expect(Self.rows(r) == ["0/0", "1/1"])
        #expect(r.changes.isEmpty)
        #expect(r.rows.allSatisfy { $0.text == .noTextNew })
        #expect(r.pairsWithoutText == 2)
        #expect(!r.identical) // nothing proves they're the same

        r = try DocumentCompare.run(Self.pages("", "", ""), Self.pages("", ""))
        #expect(Self.rows(r) == ["0/0", "1/1", "2/-"])
        #expect(r.rows[0].text == .noTextBoth)
        #expect(r.changes.map(\.kind) == [.pageRemoved])
    }

    @Test func aMixOfScannedAndTextPagesComparesTheTextOnes() throws {
        let r = try DocumentCompare.run(Self.pages("alpha one", "", "gamma three"), Self.pages("alpha uno", "", "gamma three"))
        #expect(Self.rows(r) == ["0/0", "1/1", "2/2"])
        #expect(r.rows[1].text == .noTextBoth)
        try #require(r.changes.count == 1)
        #expect(r.changes[0].oldText == "one" && r.changes[0].newText == "uno" && r.changes[0].row == 0)
        #expect(r.pairsWithoutText == 1)
    }

    @Test func changesSplitAtPageBreaks() throws {
        // "x y" were added at the end of page 1 and the start of page 2 of the new file.
        let r = try DocumentCompare.run(Self.pages("one two", "three four"), Self.pages("one two x", "y three four"))
        try #require(r.changes.count == 2)
        #expect(r.changes[0].kind == .inserted && r.changes[0].row == 0 && r.changes[0].newText == "x")
        #expect(r.changes[1].kind == .inserted && r.changes[1].row == 1 && r.changes[1].newText == "y")
    }

    @Test func manyPagesAlignFast() throws {
        let oldPages = (0..<1500).map { Self.page("page \($0) unique\($0) common words here", "more text \($0)") }
        var newPages = oldPages.enumerated().filter { $0.offset % 100 != 7 }.map(\.element)
        newPages.insert(Self.page("an inserted page", "with lines"), at: 500)
        let started = Date()
        let r = try DocumentCompare.run(oldPages, newPages)
        #expect(Date().timeIntervalSince(started) < 10, "took \(Date().timeIntervalSince(started)) s")
        #expect(r.pagesRemoved == 15)
        #expect(r.pagesInserted == 1)
        #expect(r.inserted + r.deleted + r.changed == 0)
    }

    @Test func summaryNamesWhatChanged() throws {
        #expect(try DocumentCompare.run(Self.pages("a b"), Self.pages("a b")).summary() == "No differences in the text")
        #expect(try DocumentCompare.run(Self.pages("one two three"), Self.pages("one 2 three four")).summary() == "2 text changes (1 inserted, 1 changed)")
        #expect(try DocumentCompare.run(Self.pages("alpha one", "beta two words", ""), Self.pages("alpha one", "")).summary()
            == "No text changes; 1 page removed; 1 page without text to compare")
    }

    @Test func slidingMovesARunToThePlaceThatCostsLeast() throws {
        // "b a b" inserted into "a b": the diff may put the run anywhere along the repeats; the cost picks the end.
        let a = ["a", "b"], b = ["a", "b", "a", "b"]
        var ops = WordDiff.slide(try WordDiff.diff(a, b), a, b) { kind, s, _ in kind == .insert ? -Double(s) : 0 }
        #expect(ops == [DiffOp(.equal, 0, 0, 2), DiffOp(.insert, 2, 2, 2)])
        ops = WordDiff.slide(try WordDiff.diff(a, b), a, b) { kind, s, _ in kind == .insert ? Double(s) : 0 }
        #expect(ops == [DiffOp(.insert, 0, 0, 2), DiffOp(.equal, 0, 2, 2)])
    }

    // ---- Real PDFs (MuPDF text) and the report ----

    static func textOf(_ pdf: [UInt8]) throws -> [PageText] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try (0..<engine.pageCount).map { try engine.text($0, cache: false) }
    }

    @Test func realPdfsCompareWordByWordAndTheReportMarksTheChanges() throws {
        let oldPdf = TestPdf.make(3, marker: "alpha")
        let newPdf = TestPdf.make(3, marker: "beta")
        let newText = try Self.textOf(newPdf)
        let r = try DocumentCompare.run(try Self.textOf(oldPdf), newText)
        #expect(Self.rows(r) == ["0/0", "1/1", "2/2"])
        #expect(r.changes.count == 3)
        #expect(r.changes.allSatisfy { $0.kind == .changed && $0.oldText == "alpha" && $0.newText == "beta" })

        let report = try CompareReport.annotate(newPdf, nil, r, newText, oldName: "old.pdf", summary: r.summary())
        let annots = try Annotations.read(report, nil)
        #expect(annots.filter { $0.kind == .highlight && $0.contents.contains("“alpha”") && $0.author == CompareReport.author }.count == 3)
        let notes = annots.filter { $0.kind == .text }
        try #require(notes.count == 1)
        #expect(notes[0].pageIndex == 0 && notes[0].contents == "3 text changes (3 changed)")
        let mark = try #require(annots.first { $0.kind == .highlight })
        let word = try #require(newText[mark.pageIndex].find("beta", matchCase: true, wholeWord: true).first)
        let box = try #require(newText[mark.pageIndex].rects(word.start, word.end).first)
        #expect(mark.rect.contains(box.centerX, box.centerY), "the highlight covers the changed word")
    }

    @Test func theReportNotesRemovedWordsAndPages() throws {
        let oldText = Self.pages("one two three", "a page that goes", "four five")
        let newPdf = TestPdf.make(2, marker: "x")
        let newText = Self.pages("one three", "four five")
        let r = try DocumentCompare.run(oldText, newText)
        let annots = try Annotations.read(try CompareReport.annotate(newPdf, nil, r, newText, oldName: "old.pdf", summary: r.summary()), nil)
        #expect(annots.contains { $0.kind == .text && $0.pageIndex == 0 && $0.contents == "Removed: “two”" })
        #expect(annots.contains { $0.kind == .text && $0.pageIndex == 1 && $0.contents.hasPrefix("Removed page: page 2 of old.pdf was here: “a page that goes”") })
    }

    @Test func manyPageNotesBecomeOneNoteSoNoneFallOffThePage() throws {
        let oldText = Self.pages(["keep this page"] + (0..<40).map { "gone page number\($0)" })
        let newText = Self.pages("keep this page")
        let r = try DocumentCompare.run(oldText, newText)
        #expect(r.pagesRemoved == 40)
        let notes = try Annotations.read(try CompareReport.annotate(TestPdf.make(1), nil, r, newText, oldName: "old.pdf", summary: r.summary()), nil)
            .filter { $0.kind == .text }
        try #require(notes.count == 1)
        #expect(notes[0].contents.hasPrefix("No text changes; 40 pages removed"))
        #expect(notes[0].contents.contains("page 41 of old.pdf was here: “gone page number39”"))
        #expect(notes[0].rect.y < 40, "in the top-left corner")
    }

    /// A two-version contract for the compare samples: wording edits, a removed and an inserted page, and a drawing with
    /// no text that changed. With INKVOLTPDF_SAMPLES set they are written there (compare-old.pdf, compare-new.pdf).
    static func contractVersions() -> (old: [UInt8], new: [UInt8]) {
        let oldPages: [[String]] = [
            ["Service Agreement", "This agreement is made between Contoso Ltd and Fabrikam Inc.", "The term of this agreement is twelve months from the start date.",
             "Fees: the client pays 1,200 dollars per month, due on the first day.", "Either party may end it with 30 days written notice."],
            ["Scope of work", "Fabrikam maintains the reception area, the meeting rooms", "and the kitchen on every working day.", "Supplies are ordered by Contoso."],
            ["Appendix A: old schedule", "Cleaning happens on Mondays and Thursdays."],
            [],
        ]
        let newPages: [[String]] = [
            ["Service Agreement", "This agreement is made between Contoso Ltd and Fabrikam Inc.", "The term of this agreement is eighteen months from the start date.",
             "Fees: the client pays 1,450 dollars per month, due on the first day.", "Late payments incur a 2% fee.", "Either party may end it with 30 days notice."],
            ["Scope of work", "Fabrikam maintains the reception area, the meeting rooms", "and the kitchen on every working day.", "Supplies are ordered by Contoso."],
            ["Appendix B: support hours", "Support is available from 8 am to 6 pm."],
            [],
        ]
        return (contract(oldPages, moved: false), contract(newPages, moved: true))
    }

    /// One version: text pages in Helvetica (the title bold), and a floor plan with no text, as a scan or a drawing would
    /// be: one room moves, a table is added. Coordinates as PDFsharp's (top-left), turned into PDF space.
    private static func contract(_ pages: [[String]], moved: Bool) -> [UInt8] {
        func y(_ top: Double) -> Double { 792 - top }
        func ellipse(_ x: Double, _ top: Double, _ w: Double, _ h: Double) -> String {
            let k = 0.5523, rx = w / 2, ry = h / 2, cx = x + rx, cy = y(top + ry)
            return "\(cx + rx) \(cy) m \(cx + rx) \(cy + ry * k) \(cx + rx * k) \(cy + ry) \(cx) \(cy + ry) c "
                + "\(cx - rx * k) \(cy + ry) \(cx - rx) \(cy + ry * k) \(cx - rx) \(cy) c "
                + "\(cx - rx) \(cy - ry * k) \(cx - rx * k) \(cy - ry) \(cx) \(cy - ry) c "
                + "\(cx + rx * k) \(cy - ry) \(cx + rx) \(cy - ry * k) \(cx + rx) \(cy) c S\n"
        }
        func rect(_ x: Double, _ top: Double, _ w: Double, _ h: Double) -> String { "\(x) \(y(top + h)) \(w) \(h) re S\n" }
        func escaped(_ s: String) -> String { s.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)") }
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
                       "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"]
        var kids: [String] = []
        for lines in pages {
            var content: String
            if lines.isEmpty {
                content = "3 w 0 G\n" + rect(72, 100, 468, 300) + "300 \(y(100)) m 300 \(y(400)) l S\n" + rect(moved ? 360 : 330, 180, 120, 90)
                    + ellipse(120, 200, 80, 80)
                if moved { content += ellipse(140, 450, 60, 60) }
            } else {
                content = "BT /F2 20 Tf 72 \(y(90)) Td (\(escaped(lines[0]))) Tj ET\n"
                for i in 1..<lines.count { content += "BT /F1 12 Tf 72 \(y(130 + Double(i) * 20)) Td (\(escaped(lines[i]))) Tj ET\n" }
            }
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents \(objects.count + 2) 0 R >>")
            kids.append("\(objects.count) 0 R")
            objects.append(Core1TestPdf.stream(content))
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>"
        return Core2Pdf.build(objects)
    }

    @Test func contractVersionsCompareAsAPersonWouldDescribeThem() throws {
        let (oldPdf, newPdf) = Self.contractVersions()
        let r = try DocumentCompare.run(try Self.textOf(oldPdf), try Self.textOf(newPdf))
        #expect(Self.rows(r) == ["0/0", "1/1", "2/2", "3/3"]) // the appendix was rewritten in place
        #expect(r.rows[3].text == .noTextBoth)
        let texts = r.changes.map { "\($0.kind)|\($0.oldText)|\($0.newText)" }
        #expect(texts.contains("changed|twelve|eighteen"), "\(texts)")
        #expect(texts.contains("changed|1,200|1,450"))
        #expect(texts.contains("inserted||Late payments incur a 2% fee."))
        #expect(texts.contains("deleted|written|"))
        #expect(r.changes.allSatisfy { $0.row != 1 }) // page 2 didn't change
        #expect(r.pairsWithoutText == 1)

        let a = try PdfEngine.open(oldPdf), b = try PdfEngine.open(newPdf)
        defer {
            a.close()
            b.close()
        }
        let visual = try VisualCompare.overlay(try a.render(3, scale: 0.7), try b.render(3, scale: 0.7))
        #expect((2...4).contains(visual.regions.count), "\(visual.regions.count) regions") // the moved room (both places) and the new table
        #expect(try VisualCompare.overlay(try a.render(1, scale: 0.7), try b.render(1, scale: 0.7)).regions.isEmpty)

        if let dir = ProcessInfo.processInfo.environment["INKVOLTPDF_SAMPLES"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(oldPdf).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("compare-old.pdf")))
            try Data(newPdf).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("compare-new.pdf")))
        }
    }

    // ---- Pixel overlay ----

    private static func blank(_ w: Int, _ h: Int) -> RenderedImage { RenderedImage(w, h, [UInt8](repeating: 255, count: w * h * 3)) }

    private static func withBox(_ img: RenderedImage, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ value: UInt8 = 0) -> RenderedImage {
        var px = img.pixels
        for yy in y..<(y + h) {
            for xx in x..<(x + w) {
                let i = yy * img.stride + xx * 3
                px[i] = value
                px[i + 1] = value
                px[i + 2] = value
            }
        }
        return RenderedImage(img.width, img.height, px)
    }

    private static func at(_ img: RenderedImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = y * img.stride + x * 3
        return (Int(img.pixels[i]), Int(img.pixels[i + 1]), Int(img.pixels[i + 2]))
    }

    @Test func identicalImagesHaveNoDifferencesAndShowGrey() throws {
        let a = Self.withBox(Self.blank(100, 80), 10, 10, 20, 20)
        let r = try VisualCompare.overlay(a, a)
        #expect(r.changedPixels == 0)
        #expect(r.regions.isEmpty)
        let p = Self.at(r.image, 15, 15)
        #expect(p.r == p.g && p.g == p.b && p.b < 200, "shared ink is grey")
        let white = Self.at(r.image, 90, 70)
        #expect(white.r == 255 && white.g == 255 && white.b == 255)
    }

    @Test func inkOnlyInOneSideIsTintedAndBoxed() throws {
        let blank = Self.blank(200, 100)
        let r = try VisualCompare.overlay(Self.withBox(blank, 10, 10, 20, 20), Self.withBox(blank, 150, 50, 30, 30))
        #expect(r.changedPixels == 20 * 20 + 30 * 30)
        let removed = Self.at(r.image, 15, 15)
        #expect(removed.r > 150 && removed.b < 100, "removed ink is red: \(removed)")
        let added = Self.at(r.image, 160, 60)
        #expect(added.b > 150 && added.r < 100, "added ink is blue: \(added)")
        #expect(r.regions.count == 2)
        #expect(r.regions.contains { $0.contains(10, 10) && $0.contains(29, 29) && $0.width < 40 })
        #expect(r.regions.contains { $0.contains(150, 50) && $0.contains(179, 79) })
    }

    @Test func faintNoiseAndLonePixelsAreIgnored() throws {
        let a = Self.blank(64, 64)
        let b = Self.withBox(Self.withBox(a, 5, 5, 40, 40, 235), 50, 50, 1, 1) // faint tint, and one dark pixel
        let r = try VisualCompare.overlay(a, b)
        #expect(r.regions.isEmpty)
        #expect(r.changedPixels == 1)
    }

    @Test func pagesOfDifferentSizesOverlayAtTheTopLeft() throws {
        let r = try VisualCompare.overlay(Self.blank(50, 40), Self.withBox(Self.blank(60, 70), 0, 50, 60, 20))
        #expect((r.image.width, r.image.height) == (60, 70))
        #expect(r.changedPixels == 60 * 20)
        #expect(r.regions.count == 1)
    }
}
