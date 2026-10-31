import Testing
@testable import PdfCore

/// The reading order pane's rules (the Windows app keeps them in `DocumentTab.ReadingOrder`, and checks them through its dev
/// script): the list and boxes of a page, the summary, moves to another page, a drop, the title and language window.
@Suite struct ReadingOrderTests {
    private func plan() throws -> TagPlan { try TagTest.plan(ExportTestPdf.make()) }

    @Test func The_list_shows_the_pages_pieces_numbered_and_the_boxes_every_page() throws {
        let plan = try plan()
        let s = ReadingOrder.state(plan, page: 0, selected: 0, stale: false, written: false)
        let onFirst = plan.blocks.count { $0.page == 0 }
        #expect(s.items.count == onFirst)
        #expect(s.items.map(\.number) == Array(1...onFirst))
        #expect(s.items[0].kind == "Heading 1")
        #expect(s.boxes.count == plan.blocks.count)
        #expect(s.boxes[0].selected && !s.boxes[1].selected)
        #expect(s.boxes.contains { $0.needsAlt })
        #expect(s.summary.hasPrefix("\(onFirst) pieces on page 1, in the order a screen reader reads them. 1 picture needs alternate text."))
        #expect(s.summary.hasSuffix("Apply changes to tag the document this way."))
        #expect(s.canApply && s.editable && !s.canMoveToPageBefore && s.canMoveToPageAfter)
    }

    @Test func Each_kind_is_said_in_words() throws {
        let plan = try plan()
        let kinds = ReadingOrder.state(plan, page: 0, selected: nil, stale: false, written: true).items.map(\.kind)
        #expect(kinds.contains("Heading 2"))
        #expect(kinds.contains("List (3 items)"))
        #expect(kinds.contains("Table (4 rows, column headers, row headers)"))
        #expect(kinds.contains("Picture: needs alternate text"))
        var fig = try #require(plan.blocks.first { $0.kind == .figure })
        fig.decorative = true
        #expect(ReadingOrderItem(index: 0, number: 1, block: fig).kind == "Picture (decorative)")
        #expect(!ReadingOrderItem(index: 0, number: 1, block: fig).needsAlt)
        fig.decorative = false
        fig.alt = "Sales by quarter"
        let item = ReadingOrderItem(index: 0, number: 3, block: fig)
        #expect(item.kind == "Picture")
        #expect(item.spoken == "3. Picture. Sales by quarter")
    }

    @Test func A_piece_read_with_another_page_is_listed_there_and_its_box_stays() throws {
        let plan = try plan()
        let at = try #require(plan.blocks.firstIndex { $0.page == 1 })
        let moved = try #require(ReadingOrder.movedToPage(plan, at, -1))
        #expect(moved.page == 0)
        let first = ReadingOrder.state(moved.plan, page: 0, selected: moved.index, stale: false, written: false)
        #expect(first.items.last?.index == moved.index)
        #expect(first.items.last?.kind.hasSuffix(" · from page 2") == true)
        let box = try #require(first.boxes.first { $0.selected })
        #expect(box.page == 1) // where its content is
        let second = ReadingOrder.state(moved.plan, page: 1, selected: nil, stale: false, written: false)
        #expect(second.summary.contains("1 piece here is read with another page."))
        #expect(ReadingOrder.movedToPage(moved.plan, moved.index, -1) == nil) // no page before the first
        #expect(ReadingOrder.firstPiece(plan, page: 1) == at)
        #expect(ReadingOrder.firstPiece(plan, page: 9) == nil)
    }

    @Test func A_drop_moves_within_the_page_only() throws {
        let plan = try plan()
        let last = try #require(plan.blocks.lastIndex { $0.page == 0 })
        #expect(ReadingOrder.dropped(plan, last, onto: 0).blocks[0] == plan.blocks[last])
        #expect(ReadingOrder.dropped(plan, 0, onto: last + 1).blocks[last] == plan.blocks[0]) // stops at its page's last place
    }

    @Test func A_stale_plan_says_so_and_offers_nothing() throws {
        let s = ReadingOrder.state(try plan(), page: 0, selected: 0, stale: true, written: false)
        #expect(s.summary.hasPrefix("The document changed since this reading order was made."))
        #expect(s.boxes.isEmpty && !s.editable && !s.canApply && !s.canMoveToPageAfter)
    }

    @Test func The_window_asks_for_a_title_and_a_language_code() throws {
        #expect(ReadingOrder.problem(title: "  ", language: "en")?.contains("title") == true)
        #expect(ReadingOrder.problem(title: "Report", language: "english language")?.contains("language code") == true)
        #expect(ReadingOrder.problem(title: "Report", language: "") != nil)
        #expect(ReadingOrder.problem(title: "Report", language: " es-PR ") == nil)
        let plan = try plan()
        #expect(ReadingOrder.titleNote(plan).hasPrefix("From the first heading"))
        #expect(ReadingOrder.languageNote(plan).hasPrefix("Read from the text"))
        #expect(ReadingOrder.found(plan).hasPrefix("Found: 4 headings, 1 table, 1 picture; 1 picture still needs alternate text"))
        #expect(ReadingOrder.written(plan).contains("1 picture needs alternate text"))
    }

    @Test func Language_tags_are_as_pdfua_asks() {
        for good in ["en", "en-US", "zh-Hant-TW", "x-klingon", "es-419"] { #expect(AccessibilityCheck.isLanguage(good), "\(good)") }
        for bad in [nil, "", "english language", "en_US", "-en", String(repeating: "a", count: 70)] as [String?] { #expect(!AccessibilityCheck.isLanguage(bad), "\(bad ?? "nil")") }
    }
}
