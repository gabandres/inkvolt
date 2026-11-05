import Foundation
import Testing
@testable import PdfCore

/// Ported from AutoTagKindChangeTests.cs (same names): Make Accessible (roadmap 2.4): the reading order panel changes a
/// piece's kind (`AutoTag.withKind`): a paragraph the layout took for body text made a heading, a list made one paragraph,
/// text that belongs to a chart made part of its picture, and the kinds each piece can be made. `Assert.Same` on a plan
/// left unchanged is `==` here (plans are values).
@Suite struct AutoTagKindChangeTests {
    private static let options = AccessibleOptions(title: "A test", language: "en")

    private static func write(_ pdf: [UInt8], _ plan: TagPlan) throws -> [UInt8] { try AutoTag.write(pdf, nil, plan, options) }

    /// The structure element types, depth-first, with how many content items (MCIDs) each holds directly.
    private static func tree(_ pdf: [UInt8]) throws -> [(type: String, mcids: Int)] {
        let doc = try PdfEdit.openToRead(pdf, nil)
        return TagTest.tree(doc).map { t in
            let k = t.elem["K"]
            let kids = k.map { $0.isArray ? $0.elements : [$0] } ?? []
            return (t.type, kids.count { $0.kind == .int })
        }
    }

    private static func passes(_ pdf: [UInt8]) throws -> Bool { try AccessibilityCheck.run(pdf, nil).passed }

    private static func indexOf(_ plan: TagPlan, _ match: (TagBlock) -> Bool) throws -> Int {
        let found = plan.blocks.firstIndex(where: match)
        return try #require(found)
    }

    private static func secondParagraph(_ b: TagBlock) -> Bool { b.kind == .paragraph && b.text.hasPrefix("A second paragraph") }

    @Test func A_paragraph_made_a_heading_is_written_as_one_at_its_level() throws {
        let pdf = ExportTestPdf.make(logo: true)
        let plan = TagTest.withAlt(try TagTest.plan(pdf))
        let i = try Self.indexOf(plan, Self.secondParagraph)
        let before = try Self.tree(Self.write(pdf, plan))
        let changed = AutoTag.withKind(plan, i, .heading, level: 2)
        #expect(changed.blocks[i].kind == .heading)
        #expect(changed.blocks[i].level == 2)
        #expect(changed.blocks[i].text == plan.blocks[i].text)
        #expect(changed.blocks[i].sources == plan.blocks[i].sources)
        let after = try Self.tree(Self.write(pdf, changed))
        #expect(after.count { $0.type == "P" } == before.count { $0.type == "P" } - 1)
        #expect(after.count { $0.type == "H2" } == before.count { $0.type == "H2" } + 1)
        #expect(after.filter { $0.type == "H2" }.allSatisfy { $0.mcids > 0 })
        #expect(try Self.passes(Self.write(pdf, changed)))
        // Its level changes in place; the same kind and level again changes nothing.
        #expect(AutoTag.withKind(changed, i, .heading, level: 3).blocks[i].level == 3)
        #expect(AutoTag.withKind(changed, i, .heading, level: 2) == changed)
    }

    @Test func A_list_made_a_paragraph_holds_all_its_entries() throws {
        let pdf = ExportTestPdf.make(logo: true)
        let plan = TagTest.withAlt(try TagTest.plan(pdf))
        let i = try Self.indexOf(plan) { $0.kind == .list }
        let list = plan.blocks[i]
        #expect(AutoTag.kindsFor(list).contains(.contents))
        let changed = AutoTag.withKind(plan, i, .paragraph)
        let p = changed.blocks[i]
        #expect(p.items.isEmpty)
        #expect(p.text == list.items.map(\.text).joined(separator: "\n"))
        #expect(p.sources.count == list.items.reduce(0) { $0 + $1.sources.count } + list.sources.count)
        let tagged = try Self.write(pdf, changed)
        #expect(!(try Self.tree(tagged)).contains { ["L", "LI", "LBody"].contains($0.type) })
        #expect(try Self.passes(tagged))
        // A paragraph can't be made a list or a table: their entries and cells aren't known.
        #expect(AutoTag.withKind(changed, i, .list) == changed)
        #expect(AutoTag.withKind(changed, i, .table) == changed)
        #expect(!AutoTag.kindsFor(p).contains(.list))
        #expect(!AutoTag.kindsFor(p).contains(.table))
    }

    @Test func Text_made_a_picture_needs_alternate_text_and_is_tagged_as_one() throws {
        let pdf = ExportTestPdf.make(logo: true)
        let plan = TagTest.withAlt(try TagTest.plan(pdf))
        let i = try Self.indexOf(plan, Self.secondParagraph)
        let changed = AutoTag.withKind(plan, i, .figure)
        let f = changed.blocks[i]
        #expect(f.kind == .figure)
        #expect(f.sources == [f.box])
        #expect(changed.figuresWithoutAlt == plan.figuresWithoutAlt + 1)
        let unnamed = try Self.write(pdf, changed)
        #expect(try AccessibilityCheck.run(unnamed, nil).failedConditions.contains("13-004"))
        let named = AutoTag.with(changed, i) { $0.alt = "A note about the page" }
        let tagged = try Self.write(pdf, named)
        let tree = try Self.tree(tagged)
        let figuresBefore = try Self.tree(Self.write(pdf, plan)).count { $0.type == "Figure" }
        #expect(tree.count { $0.type == "Figure" } == figuresBefore + 1)
        #expect(tree.filter { $0.type == "Figure" }.allSatisfy { $0.mcids > 0 })
        #expect(try Self.passes(tagged))

        // And back: a paragraph again, its area its source, its text what the panel had.
        let back = AutoTag.withKind(named, i, .paragraph)
        #expect(back.blocks[i].kind == .paragraph)
        #expect(back.blocks[i].alt == nil)
        #expect(try Self.passes(Self.write(pdf, back)))
    }

    @Test func A_picture_made_text_takes_the_text_drawn_in_it() throws {
        // The orchard's picture holds its labels ("North orchard" on it, "Hill" beside it): made a paragraph, they are its text.
        let pdf = AutoTagKindsTests.make()
        let plan = try TagTest.plan(pdf)
        let i = try Self.indexOf(plan) { $0.kind == .figure }
        let p = AutoTag.withKind(plan, i, .paragraph).blocks[i]
        #expect(p.text == "North orchard\nHill")
        #expect(p.sources == [plan.blocks[i].box])
    }

    @Test func A_table_made_a_paragraph_reads_its_rows_in_order() throws {
        let pdf = ExportTestPdf.make(logo: true)
        let plan = TagTest.withAlt(try TagTest.plan(pdf))
        let i = try Self.indexOf(plan) { $0.kind == .table }
        let table = plan.blocks[i]
        let changed = AutoTag.withKind(plan, i, .paragraph)
        let p = changed.blocks[i]
        #expect(p.rows.isEmpty)
        #expect(p.headerRows == 0)
        #expect(p.text.hasPrefix(table.rows[0].map(\.text).filter { !$0.isEmpty }.joined(separator: " ")))
        let tagged = try Self.write(pdf, changed)
        #expect(!(try Self.tree(tagged)).contains { ["Table", "TR", "TH", "TD"].contains($0.type) })
        #expect(try Self.passes(tagged))
    }
}
