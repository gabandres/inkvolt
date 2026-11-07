import Testing
@testable import PdfCore

/// Mac addition (roadmap 3.6): the page view draws one page ahead of those shown, the way it last moved (`ReadAhead`).
struct ReadAheadTests {
    @Test func Scrolling_down_asks_the_page_after_and_up_the_page_before() {
        var ahead = ReadAhead()
        #expect(ahead.page(after: 0...1, of: 10) == 2)
        #expect(ahead.page(after: 1...2, of: 10) == 3)
        #expect(ahead.page(after: 0...1, of: 10) == nil, "up from the first page: none")
        #expect(ahead.page(after: 3...4, of: 10) == 5)
        #expect(ahead.page(after: 8...9, of: 10) == nil, "down past the last page: none")
    }

    @Test func The_way_changes_only_when_the_first_page_shown_does() {
        var ahead = ReadAhead()
        _ = ahead.page(after: 5...6, of: 10)
        #expect(ahead.page(after: 4...5, of: 10) == 3)
        // Asked again with the same pages (a tile arrived, a zoom that keeps the first page): still up.
        #expect(ahead.page(after: 4...5, of: 10) == 3)
        #expect(ahead.page(after: 4...6, of: 10) == 3)
        #expect(ahead.page(after: 5...6, of: 10) == 7)
        #expect(ahead.page(after: 5...6, of: 10) == 7)
    }

    @Test func A_new_layout_forgets_the_way() {
        var ahead = ReadAhead()
        _ = ahead.page(after: 7...8, of: 10)
        #expect(ahead.page(after: 5...6, of: 10) == 4)
        // Pages inserted or deleted, the document reloaded, another reading mode: the page shown now says nothing of a move.
        ahead.reset()
        #expect(ahead.page(after: 2...3, of: 10) == 4)
    }
}
