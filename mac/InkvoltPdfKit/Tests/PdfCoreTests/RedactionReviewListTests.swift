import Foundation
import Testing
@testable import PdfCore
import PrintCore

/// A Mac addition: Redact by Pattern's list (`RedactionReviewList`), which the Windows app keeps in its dialog
/// (`RedactReviewDialog`, driven by its developer script) and the Mac keeps in PdfCore: the order of the lines, Accept All
/// and Skip All, what the button says and what the person's choice comes to.
struct RedactionReviewListTests {
    private static func hit(_ page: Int, _ y: Double, _ text: String = "123-45-6789") -> RedactionMatch {
        RedactionMatch(page: page, pattern: .socialSecurity, start: 0, end: text.utf16.count, text: text, rects: [RectD(10, y, 60, 12)])
    }

    private static let found = RedactionSearchResult(
        hits: [hit(1, 300), hit(0, 200), hit(1, 100)],
        looks: [RedactionLook(1, .scanReadByOcr, [RectD(5, 5, 40, 10), RectD(5, 50, 40, 10)]), RedactionLook(2, .scanReadByOcr, [])])

    @Test func linesAreInPageOrderAPageToLookAtBeforeItsHits() {
        let list = RedactionReviewList(Self.found, earlier: [(page: 0, rect: RectD(10, 50, 20, 20))])
        let order = list.rows.map { row -> String in
            switch row.item {
            case .hit(let h): "hit \(h.page) \(Int(h.rects[0].y))"
            case .look(let l): "look \(l.page)"
            case .earlier(let page, _): "earlier \(page)"
            }
        }
        #expect(order == ["earlier 0", "hit 0 200", "look 1", "hit 1 100", "hit 1 300", "look 2"])
        #expect(list.rows.filter(\.accepted).count == 4) // hits and the earlier area start ticked, looks don't
        #expect(!list.rows[5].tickable) // a look with nothing unread has no box
    }

    @Test func acceptAllAndSkipAllTouchOnlyTheHits() {
        var list = RedactionReviewList(Self.found, earlier: [(page: 0, rect: RectD(10, 50, 20, 20))])
        list.set(2, true) // the look on page 2 with two unread places
        #expect(list.redactCount == 3 + 1 + 2)
        #expect(list.redactTitle == loc("Redact {0}", CoreLanguage.number(6)))
        list.setAll(false)
        #expect(list.redactCount == 1 + 2)
        let choice = list.choice
        #expect(choice.accepted.isEmpty && choice.skipped.count == 3)
        #expect(choice.lookAreas.count == 2 && choice.earlierApplied.count == 1 && choice.earlierKept.isEmpty)
        list.set(0, false)
        list.set(2, false)
        #expect(list.redactTitle == loc("Keep All"))
        #expect(list.choice.earlierKept.count == 1)
    }

    // ---- from the code review of the port (Mac additions) ----

    @Test func aLineSaysWhetherItIsTickedForAScreenReader() {
        var list = RedactionReviewList(Self.found, earlier: [(page: 0, rect: RectD(10, 50, 20, 20))])
        #expect(list.rows[1].spoken.contains(loc("Checked: it will be redacted.")))
        list.set(1, false)
        #expect(!list.rows[1].spoken.contains(loc("Checked: it will be redacted.")))
        #expect(!list.rows[5].spoken.contains("Checked")) // a look with nothing to tick
    }

    @Test func aValueBesideAKeptOneIsStillThere() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (123-45-6789 223-45-6789) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let engine = try PdfEngine.open(pdf)
        let hits = try RedactionSearch.find(engine, RedactionPatternOptions()).hits
        engine.close()
        #expect(hits.count == 2)
        // The kept one's box grown as a recognized word's is: it touches its neighbour, which isn't kept for that.
        var kept = hits[1]
        kept.rects = kept.rects.map { $0.inflate(4) }
        let left = try RedactionSearch.readBack(pdf, nil, RedactionPatternOptions(), ocr: nil, redactedPages: [], kept: [kept]).hits
        #expect(left.map(\.normalized) == ["123-45-6789"])
    }

    @Test func aScriptInANameTreeIsSearchedButTheNamesArent() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /Names << /JavaScript << /Names [(paragraph.1.2.3.4) << /S /JavaScript /JS (var s = '123-45-6789';) >>] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (Nothing private here) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let ssn = try RedactionCheck.run(pdf, nil, RedactionCheckOptions(patterns: RedactionPatternOptions(patterns: [.socialSecurity]), valuesOnly: true))
        #expect(!ssn.isClean)
        let address = try RedactionCheck.run(pdf, nil, RedactionCheckOptions(patterns: RedactionPatternOptions(patterns: [.ipAddress]), valuesOnly: true))
        #expect(address.isClean, "\(address.findings.map(\.text))")
    }

    @Test func aSetIsDeletedFromTheFileItWasReadFrom() throws {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-set-delete-\(NewIds.hex().prefix(8))")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let saved = try RedactionPatternSets.save(RedactionPatternSet("Clients", RedactionPatternOptions()), folder)
        let copy = (folder as NSString).appendingPathComponent("Clients copy.json")
        try FileManager.default.moveItem(atPath: saved, toPath: copy)
        let set = try #require(RedactionPatternSets.list(folder).sets.first)
        try RedactionPatternSets.delete(set)
        #expect(RedactionPatternSets.list(folder).sets.isEmpty)
    }

    @Test func aHostileHitIsShownHarmlessAndShortened() {
        var h = Self.hit(0, 10, "123-45-6789\u{202E}")
        h.before = String(repeating: "x", count: 40)
        h.fromOcr = true
        let row = RedactionReviewList(RedactionSearchResult(hits: [h], looks: []), earlier: []).rows[0]
        #expect(row.value == "123-45-6789")
        #expect(row.before.hasPrefix("…") && row.before.utf16.count == 29)
        #expect(row.kind == loc("{0} (read by OCR)", RedactionPatterns.name(.socialSecurity)))
    }
}
