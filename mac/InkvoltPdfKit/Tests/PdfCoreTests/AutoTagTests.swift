import Foundation
import Testing
@testable import PdfCore

/// What the tag tests share: reading a plan, and the structure tree and content read back.
enum TagTest {
    static func plan(_ pdf: [UInt8]) throws -> TagPlan {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try AutoTag.plan(engine, pdf, nil)
    }

    static func withAlt(_ plan: TagPlan, _ alt: String = "A colored gradient") -> TagPlan {
        var plan = plan
        for i in plan.blocks.indices where plan.blocks[i].kind == .figure { plan.blocks[i].alt = alt }
        return plan
    }

    /// The structure tree, depth-first, with each element's depth.
    static func tree(_ doc: MuDoc) -> [(type: String, depth: Int, elem: PObj)] {
        var list: [(type: String, depth: Int, elem: PObj)] = []
        func visit(_ item: PObj?, _ depth: Int) {
            guard let item else { return }
            if item.isArray {
                for x in item.elements { visit(x, depth) }
            } else if item.isDict, item.name("Type") == "StructElem" {
                list.append((item.name("S") ?? "", depth, item))
                visit(item["K"], depth + 1)
            }
        }
        visit(doc.catalog.dict("StructTreeRoot")?["K"], 0)
        return list
    }

    static func content(_ page: PObj) -> String { latin1String(page["Contents"]?.streamData ?? []) }

    static func all(_ pattern: String, _ text: String) -> [[String]] {
        let r = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return r.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }

    /// The parent tree's array for a page's key.
    static func parents(_ doc: MuDoc, _ key: Int) -> PObj? {
        PdfStructure.numberTree(doc.catalog.dict("StructTreeRoot")?.dict("ParentTree")).first { $0.key == key }?.value
    }

    /// What the machine check (`AccessibilityCheck`, roadmap 1.3, not on this branch) would also see in the tags: every page
    /// has marks that balance, numbered in order, each MCID's parent holds it, no element is empty.
    static func tagsHold(_ pdf: [UInt8]) throws {
        let doc = try PdfEdit.openToRead(pdf, nil)
        #expect(doc.catalog.dict("MarkInfo")?["Marked"]?.bool == true)
        #expect(AutoTag.isLanguage(doc.catalog.text("Lang")))
        #expect(!InfoDict.text(doc, "Title").isEmpty)
        for page in try doc.pages() {
            let text = content(page)
            #expect(all(#"\bBDC\b|\bBMC\b"#, text).count == all(#"\bEMC\b"#, text).count)
            let mcids = all(#"MCID (\d+)"#, text).map { Int($0[1])! }
            #expect(mcids == Array(0..<mcids.count))
            if mcids.isEmpty { continue }
            let entry = try #require(parents(doc, try #require(page.int("StructParents"))))
            #expect(entry.count == mcids.count)
            for m in mcids {
                let owner = try #require(entry[m])
                let k = owner["K"]
                let holds = k?.int == m || k?.elements.contains { $0.int == m } == true
                #expect(holds, "MCID \(m)")
            }
        }
        for t in tree(doc) where t.type != "TD" && t.type != "TH" { #expect(t.elem.has("K"), "\(t.type) is empty") }
    }
}

/// Ported from AutoTagTests.cs (same names): Make Accessible: an untagged PDF tagged from its layout, each tag kind, the
/// marked content in the page streams, title, language and tab order, reading-order edits, alternate text. Adapted: the
/// Windows tests also ask `AccessibilityCheck` (roadmap 1.3), which isn't on this branch: `TagTest.tagsHold` looks at the
/// tags instead, and `Untagged_file_passes_the_machine_checks…` waits for it. PDF/A-2a and Batch: `AutoTagOutputTests`.
/// `Alt_text_request_carries_the_picture…` isn't ported: the Mac app has no AI client (`docs/PLAN.md`).
@Suite struct AutoTagTests {
    private func plan(_ pdf: [UInt8]) throws -> TagPlan { try TagTest.plan(pdf) }

    @Test func Plan_finds_headings_paragraphs_list_table_figure_and_running_header() throws {
        let plan = try plan(ExportTestPdf.make(logo: true))
        let page1 = plan.blocks.filter { $0.page == 0 }
        #expect(page1[0].kind == .heading)
        #expect(page1[0].text == "Quarterly Report")
        #expect(page1.contains { $0.kind == .heading && $0.text == "Summary" })
        #expect(page1.contains { $0.kind == .paragraph && $0.text.hasPrefix("Inkvolt keeps every page") })
        let lists = page1.filter { $0.kind == .list }
        #expect(lists.count == 1)
        #expect(lists.first?.items.count == 3)
        let tables = page1.filter { $0.kind == .table }
        #expect(tables.count == 1)
        #expect(tables.first?.rows.count == 4)
        #expect(tables.first?.headerRow == true)
        #expect(page1.count { $0.kind == .figure } == 1)
        // The logo at the top of both pages is a running header: an artifact on each page.
        #expect(plan.running.allSatisfy { !$0.isEmpty })
        #expect(plan.title == "Quarterly Report")
        #expect(plan.titleFrom == .heading)
        #expect(plan.language == "en")
        #expect(plan.languageGuessed)
        #expect(!plan.wasTagged)
        #expect(plan.figuresWithoutAlt == 1)
    }

    @Test func Tags_each_kind_with_its_structure() throws {
        let pdf = ExportTestPdf.make(logo: true)
        let tagged = try AutoTag.write(pdf, nil, TagTest.withAlt(plan(pdf)))
        let doc = try PdfEdit.openToRead(tagged, nil)
        let tree = TagTest.tree(doc)
        #expect(tree[0].type == "Document")
        #expect(tree[1].type == "H1")
        #expect(tree.contains { $0.type == "H2" })
        #expect(tree.contains { $0.type == "P" })
        #expect(tree.count { $0.type == "L" } == 1)
        #expect(tree.count { $0.type == "LI" } == 3)
        #expect(tree.count { $0.type == "LBody" } == 3)
        #expect(tree.count { $0.type == "Table" } == 1)
        #expect(tree.count { $0.type == "TR" } == 4)
        // Column headers across the top, and the fruit in front of its numbers as row headers.
        let th = tree.filter { $0.type == "TH" }.map { $0.elem.dict("A")?.name("Scope") }
        #expect(th.count { $0 == "Column" } == 3)
        #expect(th.count { $0 == "Row" } == 3)
        #expect(tree.count { $0.type == "TD" } == 6)
        let figures = tree.filter { $0.type == "Figure" }
        #expect(figures.count == 1)
        let figure = try #require(figures.first?.elem)
        #expect(figure.text("Alt") == "A colored gradient")
        let bbox = try #require(figure.dict("A")?.array("BBox"))
        #expect(bbox.count == 4)
        // Page 1: x 72-232, 120 high (PDF space: y from the bottom).
        #expect((70...74).contains(bbox.num(0)))
        #expect((230...234).contains(bbox.num(2)))
        // Every element points at its parent.
        #expect(tree.dropFirst().allSatisfy { $0.elem.has("P") })
    }

    @Test func Content_is_marked_with_mcids_the_parent_tree_resolves_and_running_content_is_an_artifact() throws {
        let pdf = ExportTestPdf.make(logo: true)
        let tagged = try AutoTag.write(pdf, nil, TagTest.withAlt(plan(pdf)))
        let doc = try PdfEdit.openToRead(tagged, nil)
        let page = doc.page(0)
        let text = TagTest.content(page)
        let mcids = TagTest.all(#"/(\w+) <</MCID (\d+)>> BDC"#, text).map { Int($0[2])! }
        #expect(!mcids.isEmpty)
        #expect(mcids == Array(0..<mcids.count)) // numbered in order, each once
        #expect(text.contains("/Artifact <</Type /Pagination>> BDC")) // the logo
        #expect(text.contains("/Artifact BMC")) // the table's rules
        #expect(TagTest.all(#"\bBDC\b|\bBMC\b"#, text).count == TagTest.all(#"\bEMC\b"#, text).count)

        let key = try #require(page.int("StructParents"))
        let entry = try #require(TagTest.parents(doc, key))
        #expect(entry.count == mcids.count)
        // MCID 0 is the title, in the H1 element.
        #expect(entry[0]?.name("S") == "H1")
        try TagTest.tagsHold(tagged)
    }

    @Test func Sets_title_language_tab_order_display_title_and_the_pdfua_identifier() throws {
        let pdf = ExportTestPdf.make()
        let tagged = try AutoTag.write(pdf, nil, plan(pdf), AccessibleOptions(title: "Q3 report", language: "en-US"))
        let doc = try PdfEdit.openToRead(tagged, nil)
        let catalog = doc.catalog
        #expect(InfoDict.text(doc, "Title") == "Q3 report")
        #expect(catalog.text("Lang") == "en-US")
        #expect(catalog.dict("MarkInfo")?["Marked"]?.bool == true)
        #expect(catalog.dict("ViewerPreferences")?["DisplayDocTitle"]?.bool == true)
        #expect(try doc.pages().allSatisfy { $0.name("Tabs") == "S" })
        let xmp = String(decoding: catalog.dict("Metadata")?.streamData ?? [], as: UTF8.self)
        #expect(xmp.contains("<pdfuaid:part>1</pdfuaid:part>"))
        #expect(xmp.contains("Q3 report")) // dc:title
    }

    @Test func Headings_are_evened_out_first_is_h1_and_none_skipped() {
        func h(_ level: Int) -> TagBlock {
            var b = TagBlock(page: 0, kind: .heading, box: .zero)
            b.level = level
            return b
        }
        let even = AutoTag.evenHeadings([h(2), h(4), TagBlock(page: 0, kind: .paragraph, box: .zero), h(3), h(1), h(3)])
        #expect(even.map(\.level) == [1, 2, 0, 3, 1, 2])
    }

    @Test(arguments: [("3 Model Architecture", 1), ("3.1 Encoder and Decoder Stacks", 2), ("3.2.1. Scaled Dot-Product Attention", 3), ("A.1 Proofs", 2)] as [(String, Int?)]
        + [("2023 was a good year", nil), ("Introduction", nil)])
    func Section_numbers_give_heading_depth(_ c: (String, Int?)) {
        #expect(AutoTag.sectionDepth(c.0) == c.1)
    }

    @Test func Reading_order_edit_moves_a_block_within_its_page_and_the_tree_follows() throws {
        let pdf = ExportTestPdf.make()
        let plan = try plan(pdf)
        let tableAt = try #require(plan.blocks.firstIndex { $0.kind == .table })
        let moved = AutoTag.move(plan, tableAt, -100) // to the top of page 1
        #expect(moved.blocks[0].kind == .table)
        #expect(moved.blocks.count == plan.blocks.count)
        // It never leaves its page.
        let lastOnPage1 = try #require(moved.blocks.lastIndex { $0.page == 0 })
        #expect(AutoTag.move(moved, lastOnPage1 + 1, -1).blocks[lastOnPage1 + 1].page == 1)

        let tagged = try AutoTag.write(pdf, nil, TagTest.withAlt(moved))
        let doc = try PdfEdit.openToRead(tagged, nil)
        #expect(TagTest.tree(doc).first { $0.depth == 1 }?.type == "Table")
        try TagTest.tagsHold(tagged)
    }

    @Test func A_piece_moves_to_another_page_and_is_read_there_while_its_content_stays() throws {
        let pdf = ExportTestPdf.make()
        let plan = try plan(pdf)
        let at = try #require(plan.blocks.firstIndex { $0.page == 1 }) // page 2's heading
        let heading = plan.blocks[at]

        // Read with page 1: after page 1's last piece.
        let moved = AutoTag.moveToPage(plan, at, -1)
        var read = heading
        read.readWith = 0
        let now = try #require(moved.blocks.firstIndex(of: read))
        #expect(moved.blocks.lastIndex { AutoTag.readingPage($0) == 0 } == now)
        #expect(moved.blocks[now].page == 1) // its content is still on page 2
        #expect(AutoTag.readingPage(moved.blocks[now]) == 0)
        #expect(AutoTag.moveToPage(moved, now, -1) == moved) // no page before the first
        // Moving within its reading page now stays among page 1's pieces.
        #expect(AutoTag.readingPage(AutoTag.move(moved, now, -100).blocks[0]) == 0)

        // The tree reads it after page 1's last piece.
        let tagged = try AutoTag.write(pdf, nil, TagTest.withAlt(moved))
        let doc = try PdfEdit.openToRead(tagged, nil)
        let top = TagTest.tree(doc).filter { $0.depth == 1 }
        let h = try #require(top.firstIndex { doc.pageIndex(of: $0.elem["Pg"]) == 1 })
        #expect(h > 0)
        #expect(top[h].type.hasPrefix("H"))
        #expect(top[..<h].allSatisfy { $0.elem["Pg"] == nil || doc.pageIndex(of: $0.elem["Pg"]) == 0 })
        try TagTest.tagsHold(tagged)

        // Back with its own page: before page 2's first piece, read with its own page again.
        let back = AutoTag.moveToPage(moved, now, 1)
        #expect(back.blocks[now].readWith == nil)
        #expect(back.blocks[now] == heading)
        #expect(back.blocks == plan.blocks)
    }

    @Test func Decorative_figure_is_an_artifact_and_needs_no_alt_text() throws {
        let pdf = ExportTestPdf.make()
        var plan = try plan(pdf)
        let fig = try #require(plan.blocks.firstIndex { $0.kind == .figure })
        plan = AutoTag.with(plan, fig) { $0.decorative = true }
        #expect(plan.figuresWithoutAlt == 0)
        let tagged = try AutoTag.write(pdf, nil, plan)
        let doc = try PdfEdit.openToRead(tagged, nil)
        #expect(!TagTest.tree(doc).contains { $0.type == "Figure" })
        try TagTest.tagsHold(tagged)
    }

    @Test func Alt_text_round_trips_and_tagging_again_replaces_the_tags() throws {
        let pdf = ExportTestPdf.make()
        let once = try AutoTag.write(pdf, nil, TagTest.withAlt(plan(pdf), "Chart of sales"))
        let again = try plan(once)
        #expect(again.wasTagged)
        let figures = again.blocks.filter { $0.kind == .figure }
        #expect(figures.count == 1)
        #expect(figures.first?.alt == "Chart of sales")

        let twice = try AutoTag.write(once, nil, again)
        let doc = try PdfEdit.openToRead(twice, nil)
        let mcids = TagTest.all(#"MCID (\d+)"#, TagTest.content(doc.page(0))).map { $0[1] }
        #expect(Set(mcids).count == mcids.count) // the old ones are gone
        #expect(TagTest.tree(doc).count { $0.type == "Document" } == 1)
        try TagTest.tagsHold(twice)
    }

    @Test func Link_gets_a_link_tag_with_its_annotation_and_a_description() throws {
        // A link over "Summary" (baseline 120, 16 pt) to a web address.
        let edit = try PdfEdit.open(ExportTestPdf.make(), nil)
        let link = edit.add(edit.dict([
            ("Type", edit.name("Annot")), ("Subtype", edit.name("Link")), ("Rect", edit.reals(70, 792 - 124, 150, 792 - 104)),
            ("A", edit.dict([("S", edit.name("URI")), ("URI", edit.text("https://example.com/"))])),
        ]))
        edit.page(0).set("Annots", edit.array([link]))
        let pdf = try edit.write("")

        let tagged = try AutoTag.write(pdf, nil, TagTest.withAlt(plan(pdf)))
        let read = try PdfEdit.openToRead(tagged, nil)
        let tree = TagTest.tree(read)
        let links = tree.indices.filter { tree[$0].type == "Link" }
        #expect(links.count == 1)
        let at = try #require(links.first)
        #expect(tree[..<at].last { $0.depth == tree[at].depth - 1 }?.type == "H2")
        let annot = try #require(read.page(0).array("Annots")?[0])
        #expect(annot.has("StructParent"))
        #expect(annot.text("Contents") == "Summary")
        try TagTest.tagsHold(tagged)
    }

    // ---- Crafted files (the Mac's own; the Windows tests have none for these) ----

    /// A page drawing a form with `artifact` marks in it, whose resources lead back to itself.
    private static func formLoop() -> [UInt8] {
        Core1TestPdf.build([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /X 5 0 R >> >> /Contents 4 0 R >>",
            4: Core1TestPdf.stream("q /X Do Q"),
            5: Core1TestPdf.stream("/Artifact BMC /X Do /X Do EMC", "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /XObject << /X 5 0 R >> >>"),
        ])
    }

    @Test func A_form_that_draws_itself_ends() throws {
        let pdf = Self.formLoop()
        let tagged = try AutoTag.write(pdf, nil, plan(pdf), AccessibleOptions(title: "Loop", language: "en"))
        #expect(try PdfEdit.openToRead(tagged, nil).catalog.has("StructTreeRoot"))
    }

    @Test func Forms_that_draw_each_other_many_times_end() throws {
        var objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /X 10 0 R >> >> /Contents 4 0 R >>",
            4: Core1TestPdf.stream("/X Do"),
        ]
        for i in 0..<40 {
            let next = i < 39 ? "/Resources << /XObject << /X \(11 + i) 0 R >> >>" : ""
            objects[10 + i] = Core1TestPdf.stream("/Artifact BMC /X Do /X Do /X Do EMC", "/Type /XObject /Subtype /Form /BBox [0 0 100 100] \(next)")
        }
        let pdf = Core1TestPdf.build(objects)
        let tagged = try AutoTag.write(pdf, nil, TagPlan(blocks: [], running: [[]]), AccessibleOptions(title: "Forms", language: "en"))
        #expect(try PdfEdit.openToRead(tagged, nil).catalog.has("StructTreeRoot"))
    }

    @Test func Marks_that_dont_balance_and_a_plan_past_the_last_page_dont_break_it() throws {
        let pdf = Core1TestPdf.build([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            4: Core1TestPdf.stream("EMC EMC /P <</MCID 7>> BDC /Nope 12 Tf (x) Tj q q Q BT (y) Tj 1e308 1e308 1e308 1e308 1e308 1e308 cm (z) Tj /Artifact BMC"),
        ])
        var figure = TagBlock(page: 5, kind: .figure, box: RectD(0, 0, 10, 10))
        figure.sources = [figure.box]
        let tagged = try AutoTag.write(pdf, nil, TagPlan(blocks: [figure], running: [[]]), AccessibleOptions(title: "Marks", language: "en"))
        let doc = try PdfEdit.openToRead(tagged, nil)
        let text = TagTest.content(doc.page(0))
        #expect(!TagTest.tree(doc).contains { $0.type == "Figure" })
        #expect(!text.isEmpty)
    }
}

/// Ported from AutoTagKindsTests.cs (same names): Make Accessible's further tag kinds: a table of contents (TOC › TOCI,
/// nested), nested lists (L inside LBody), display math (Formula with alternate text), footnotes (Note with an ID), captions
/// (inside their table, beside their figure), row headers and a header spanning columns; and a chart's labels that aren't a
/// table. `Make` draws what the Windows test draws with PDFsharp on `ExportTestPdf`'s canvas.
@Suite struct AutoTagKindsTests {
    /// Page 1: a title, "Contents" and four entries with dot leaders (the third indented). Page 2: a heading, a nested list,
    /// a numbered formula, a captioned table (a header spanning two columns over Q1 and Q2, fruit names as row headers), a
    /// captioned picture, and a footnote.
    static func make() -> [UInt8] {
        var p1 = ExportTestPdf.Canvas()
        p1.text("Annual Review", "F2", 24, 72, 80)
        p1.text("Contents", "F2", 16, 72, 130)
        var y = 160.0
        for (text, x, number) in [("Introduction", 72.0, "2"), ("Methods", 72.0, "2"), ("Data sources", 96.0, "3"), ("Results", 72.0, "3")] {
            p1.text(text, "F1", 11, x, y)
            var dx = x + ExportTestPdf.width(text, 11) + 6
            while dx < 520 {
                p1.text(".", "F1", 11, dx, y)
                dx += 5
            }
            p1.text(number, "F1", 11, 530, y)
            y += 18
        }
        p1.text("The review covers the orchard's year from planting to the harvest and the sales that followed it.", "F1", 11, 72, y + 30)

        var p2 = ExportTestPdf.Canvas()
        p2.text("Introduction", "F2", 16, 72, 80)
        p2.text("The orchard grows two kinds of produce, sold at the market every week of the season.", "F1", 11, 72, 106)
        y = 132
        for (text, level) in [("Fruit", 0.0), ("Apples from the hill", 1.0), ("Pears from the valley", 1.0), ("Vegetables", 0.0)] {
            let x = 84 + level * 24
            p2.text(level == 0 ? "\u{2022}" : "\u{96}", "F1", 11, x, y) // WinAnsi's en dash
            p2.text(text, "F1", 11, x + 16, y)
            y += 16
        }
        y += 20
        let formula = "y = \u{E1} x + \u{E2}    (1)" // alpha and beta in F4
        p2.text(formula, "F4", 11, 306 - ExportTestPdf.width(formula, 11) / 2, y)
        y += 34

        p2.text("Table 1: Fruit sold by quarter.", "F1", 11, 72, y)
        y += 10
        let cells = [["Fruit", "2025", ""], ["", "Q1", "Q2"], ["Apples", "40", "52"], ["Pears", "12", "13"], ["Plums", "7", "8"]]
        let cols: [Double] = [72, 252, 342, 432]
        let rowH = 20.0
        let top = y
        for r in cells.indices {
            for c in 0..<3 where !cells[r][c].isEmpty {
                p2.text(cells[r][c], r < 2 ? "F2" : "F1", 11, cols[c] + 6, top + Double(r) * rowH + 14)
            }
        }
        for r in 0...cells.count { p2.line(cols[0], top + Double(r) * rowH, cols[3], top + Double(r) * rowH) }
        for x in cols {
            p2.line(x, x == cols[2] ? top + rowH : top, x, top + Double(cells.count) * rowH) // "2025" spans two columns
        }
        y = top + Double(cells.count) * rowH + 30

        p2.image("/Fig", 72, y, 160, 100)
        p2.text("North orchard", "F1", 8, 80, y + 20) // a label on the picture
        p2.text("Hill", "F1", 8, 240, y + 50) // and one just beside it
        p2.text("Figure 1: The orchard in spring.", "F1", 11, 72, y + 116)

        p2.text("1 Weights are in crates of twelve kilos.", "F1", 8, 72, 740)
        return ExportTestPdf.written([p1, p2], greek: true)
    }

    private static func show(_ plan: TagPlan) -> String {
        plan.blocks.map { "p\($0.page) \($0.kind) \($0.text)" }.joined(separator: "\n")
    }

    @Test func Plan_finds_contents_nested_list_formula_captions_note_and_table_headers() throws {
        let plan = try TagTest.plan(Self.make())
        let why = Comment(rawValue: Self.show(plan))
        #expect(plan.blocks.count { $0.kind == .contents } == 1, why)
        let toc = try #require(plan.blocks.first { $0.kind == .contents }, why)
        #expect(toc.page == 0)
        let spaces = try NSRegularExpression(pattern: #"[\s.]+"#)
        #expect(toc.items.map { spaces.stringByReplacingMatches(in: $0.text, range: NSRange(location: 0, length: $0.text.utf16.count), withTemplate: " ") }
            == ["Introduction 2", "Methods 2", "Data sources 3", "Results 3"])
        #expect(toc.items.map(\.level) == [0, 0, 1, 0])

        let list = try #require(plan.blocks.first { $0.kind == .list }, why)
        #expect(plan.blocks.count { $0.kind == .list } == 1, why)
        #expect(list.items.map(\.level) == [0, 1, 1, 0], why)

        let formula = try #require(plan.blocks.first { $0.kind == .formula }, why)
        #expect(plan.blocks.count { $0.kind == .formula } == 1, why)
        #expect(formula.alt?.contains("=") == true)

        let table = try #require(plan.blocks.first { $0.kind == .table }, why)
        #expect(table.headerRows == 2, why)
        #expect(table.headerColumn, why)
        #expect(table.rows[0][1].colSpan == 2, why)

        #expect(plan.blocks.filter { $0.kind == .caption }.map(\.text) == ["Table 1: Fruit sold by quarter.", "Figure 1: The orchard in spring."], why)
        let note = try #require(plan.blocks.first { $0.kind == .note }, why)
        #expect(note.text.hasPrefix("1 Weights"))
        // The label on the picture is the picture's; body text stays paragraphs.
        #expect(!plan.blocks.contains { $0.text.contains("North orchard") || $0.text == "Hill" }, why)
        #expect(plan.blocks.contains { $0.kind == .paragraph && $0.text.hasPrefix("The orchard grows") }, why)
    }

    @Test func Writes_toc_nested_lists_formula_note_captions_and_row_and_spanning_headers() throws {
        let pdf = Self.make()
        let tagged = try AutoTag.write(pdf, nil, TagTest.withAlt(TagTest.plan(pdf), "Blossom on apple trees"))
        let doc = try PdfEdit.openToRead(tagged, nil)
        let tree = TagTest.tree(doc)
        func parent(_ e: PObj) -> String? { e.dict("P")?.name("S") }

        // Contents: TOC › TOCI ×3 at the top, the indented one in a TOC inside the entry before it.
        let tocs = tree.filter { $0.type == "TOC" }
        #expect(tocs.count == 2)
        #expect(parent(tocs[1].elem) == "TOCI")
        #expect(tree.count { $0.type == "TOCI" } == 4)
        // A list inside the first item's body.
        let lists = tree.filter { $0.type == "L" }
        #expect(lists.count == 2)
        #expect(parent(lists[1].elem) == "LBody")
        #expect(tree.count { $0.type == "LI" } == 4)
        // The formula reads as its text.
        let formula = try #require(tree.first { $0.type == "Formula" }?.elem)
        #expect(formula.text("Alt")?.contains("=") == true)
        // The note has an ID.
        #expect(tree.first { $0.type == "Note" }?.elem.text("ID") == "note-1")
        // The table's caption is its first part; the figure's stands beside it.
        let captions = tree.filter { $0.type == "Caption" }
        #expect(captions.count == 2)
        #expect(parent(captions[0].elem) == "Table")
        #expect(parent(captions[1].elem) == "Document")
        // Headers: two rows of column headers (one spanning two columns), each data row's first cell a row header.
        let th = tree.filter { $0.type == "TH" }.compactMap { $0.elem.dict("A") }
        #expect(th.count { $0.name("Scope") == "Row" } == 3)
        #expect(th.count { $0.name("Scope") == "Column" } == 5)
        #expect(th.contains { $0.int("ColSpan") == 2 })
        #expect(tree.count { $0.type == "TD" } == 6)
        try TagTest.tagsHold(tagged)
    }

    @Test func Lists_and_contents_nest_by_indent_never_more_than_one_level_at_a_time() {
        #expect(AutoTag.levels([72, 96, 96, 72, 96, 120]) == [0, 1, 1, 0, 1, 2])
        #expect(AutoTag.levels([72, 120, 72]) == [0, 1, 0]) // a jump of two indents is one level deeper
        #expect(AutoTag.levels([96, 72, 72]) == [0, 0, 0]) // the first item is the list's own level
        #expect(AutoTag.levels([72, 74]) == [0, 0]) // within 6 points: the same indent
    }

    @Test func A_chart_with_labels_on_its_gridlines_isnt_a_table() {
        func cell(_ text: String) -> DocCell {
            text.isEmpty ? DocCell([]) : DocCell([DocParagraph([ExportSpan(text, "Arial", 9, false, false, 0, RectD(0, 0, 10, 9))], RectD(0, 0, 10, 9))])
        }
        func table(_ rows: [[String]]) -> DocTable { DocTable(rows.map { $0.map(cell) }, [50, 50, 50, 50], true, RectD(0, 0, 200, 100)) }

        // A bar chart's gridlines: values on the axis, a label under a bar here and there.
        #expect(!AutoTag.plausibleTable(table([["100", "", "", ""], ["75", "", "", ""], ["50", "", "", ""], ["25", "", "", ""], ["0", "2022", "2023", "2024"]])))
        // Labels scattered over a diagram.
        #expect(!AutoTag.plausibleTable(table([["Input", "", "", ""], ["", "", "Encoder", ""], ["", "", "", "Output"]])))
        // A real table, and one with a few blanks.
        #expect(AutoTag.plausibleTable(table([["Item", "Qty", "Price", "Total"], ["Apples", "4", "1.20", "4.80"], ["Pears", "12", "", "36.60"]])))
        #expect(AutoTag.plausibleTable(table([["Name", "Phone", "", ""], ["Ada", "555-0101", "", ""], ["Grace", "555-0102", "", ""]])))
    }

    @Test(arguments: [
        ("1 Weights are in crates of twelve kilos.", true), ("4To illustrate why the dot products get large", true),
        ("*Equal contribution. Listing order is random.", true), ("†Work performed while at the lab.", true),
        ("3x3 conv, 512, /2", false), ("100 Bureau Drive (Mail Stop 2000)", false), ("Weights are in crates.", false), ("2 kg", false),
    ])
    func Footnotes_start_with_their_number_or_mark(_ c: (String, Bool)) {
        #expect(AutoTag.noteStart(c.0) == c.1)
    }

    @Test(arguments: [
        ("y = αx + β (1)", "Arial", true), ("L = −Σ log p(x)", "CMMI10", true),
        ("The price rose = 4 (1)", "Arial", false), ("Results are summarized in Table 2 below.", "Arial", false),
    ])
    func Display_math_is_a_formula(_ c: (String, String, Bool)) {
        var p = DocParagraph([ExportSpan(c.0, c.1, 11, false, false, 0, RectD(0, 0, 100, 11))], RectD(0, 0, 100, 11))
        p.align = .center
        #expect(AutoTag.isFormula(p) == c.2)
    }
}

/// Ported from FontUnicodeTests.cs (same names): characters without Unicode in TeX's fonts (Matterhorn 31-027, veraPDF
/// 7.21.7-1). Adapted: built with `Core1TestPdf` (the Windows tests' `A11yDoc` comes with the checker, whose verdict the
/// Windows tests also ask: here the CMap is what's looked at). `Adobe_glyph_list_math_and_greek_names_count_as_text…` asks the
/// checker: here `GlyphNames` itself.
@Suite struct FontUnicodeTests {
    @Test(arguments: [
        ("parenleftbig", "("), ("bracketleftbigg", "["), ("bracketrightBigg", "]"), ("summationtext", "∑"), ("summationdisplay", "∑"),
        ("integraldisplay", "∫"), ("uniondisplay", "⋃"), ("radicalBig", "√"), ("bracketlefttp", "⎡"), ("braceleftmid", "⎨"),
        ("floorleftbig", "⌊"), ("angbracketrightBig", "⟩"), ("hatwide", "\u{302}"), ("element", "∈"), ("epsilon1", "ε"),
        ("arrowhookleft", "↪"), ("zerooldstyle", "0"), ("minusplus", "∓"), ("dotlessj", "ȷ"),
    ])
    func Tex_glyph_names_read_as_text(_ c: (String, String)) {
        #expect(TexGlyphs.toUnicode(c.0) == c.1)
    }

    @Test func Tex_glyph_names_read_as_text_not_a_name() { #expect(TexGlyphs.toUnicode("notatexname") == nil) }

    @Test(arguments: [
        ("ABCDEF+CMSY10", 50, "element"), ("CMSY7", 0, "minus"), ("XYZABC+CMMI10", 27, "sigma"), ("CMMIB10", 11, "alpha"),
        ("THPNLT+CMEX9", 80, "summationtext"), ("CMEX10", 20, "bracketleftbigg"),
    ])
    func Tex_math_encodings_name_codes_by_the_fonts_family(_ c: (String, Int, String)) {
        #expect(TexGlyphs.nameIn(c.0, c.1) == c.2)
    }

    @Test func Tex_math_encodings_name_codes_only_for_those_fonts() {
        #expect(TexGlyphs.nameIn("Times-Roman", 50) == nil)
        #expect(TexGlyphs.nameIn("CMSY10", 200) == nil)
    }

    @Test func Adobe_glyph_list_math_and_greek_names_count_as_text_as_veraPDF_reads_them() {
        #expect(GlyphNames.toUnicode("element") == "∈")
        #expect(GlyphNames.toUnicode("sigma") == "σ")
        #expect(GlyphNames.toUnicode("bracketleftbt") == "⎣")
    }

    private static func onePage(_ font: String, _ content: String, more: [Int: String] = [:]) -> [UInt8] {
        var objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            4: font,
            5: Core1TestPdf.stream(content),
        ]
        objects.merge(more) { $1 }
        return Core1TestPdf.build(objects)
    }

    private static func tag(_ pdf: [UInt8]) throws -> [UInt8] {
        try AutoTag.write(pdf, nil, TagTest.plan(pdf), AccessibleOptions(title: "A test", language: "en"))
    }

    private static func toUnicode(_ pdf: [UInt8]) throws -> String {
        let doc = try PdfEdit.openToRead(pdf, nil)
        let font = try #require(doc.page(0).dict("Resources")?.dict("Font")?.dict("F1"))
        return latin1String(try #require(font.dict("ToUnicode")?.streamData))
    }

    @Test func Make_accessible_gives_tex_glyph_names_a_tounicode() throws {
        let pdf = Self.onePage(
            "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /summationdisplay 9 0 R /bracketleftbigg 9 0 R >> "
                + "/Encoding << /Type /Encoding /Differences [65 /summationdisplay /bracketleftbigg] >> /FirstChar 65 /LastChar 66 /Widths [600 600] >>",
            "BT /F1 12 Tf 72 700 Td (AB) Tj ET", more: [9: Core1TestPdf.stream("600 0 d0 0 0 500 500 re f")])

        let cmap = try Self.toUnicode(Self.tag(pdf))

        #expect(cmap.contains("<41> <2211>"))
        #expect(cmap.contains("<42> <005B>"))
    }

    @Test func A_math_font_without_glyph_names_gets_its_tex_encoding() throws {
        // CMSY10 without an Encoding or a program to read one from: the codes are OMS's (50 is element, 0 minus).
        let pdf = Self.onePage(
            "<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+CMSY10 /FirstChar 0 /LastChar 127 /FontDescriptor 11 0 R >>",
            "BT /F1 12 Tf 72 700 Td (x2\\000) Tj ET",
            more: [11: "<< /Type /FontDescriptor /FontName /ABCDEF+CMSY10 /Flags 4 /FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 750 /Descent -250 /CapHeight 700 /StemV 80 >>"])

        let cmap = try Self.toUnicode(Self.tag(pdf))

        #expect(cmap.contains("<32> <2208>"))
        #expect(cmap.contains("<00> <2212>"))
        #expect(cmap.contains("<78> <00A7>")) // 120: section
    }
}
