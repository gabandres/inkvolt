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
