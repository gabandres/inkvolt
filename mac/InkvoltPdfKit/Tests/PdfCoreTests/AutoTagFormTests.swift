import Foundation
import Testing
@testable import PdfCore

/// Ported from AutoTagFormTests.cs (same names): Make Accessible (roadmap 2.4): content a page draws through a form XObject
/// (a whole page placed as one drawing, a letterhead with its text) is tagged piece by piece inside the form, each piece in
/// its own element.
@Suite struct AutoTagFormTests {
    private static let heading = "Annual Summary"
    private static let first = "The first paragraph tells the reader what happened over the year and why it matters."
    private static let second = "The second paragraph says what comes next and who to ask about it."

    /// The heading and two paragraphs inside /Fm1; each page draws it `draws` times (one page, or as many as `pages`).
    private static func formPage(pages: Int = 1, draws: Int = 1) -> [UInt8] {
        let form = "BT /F2 18 Tf 72 700 Td (\(heading)) Tj ET\n"
            + "BT /F1 11 Tf 72 660 Td (\(first)) Tj ET\n"
            + "BT /F1 11 Tf 72 620 Td (\(second)) Tj ET"
        let page = String(repeating: "q /Fm1 Do Q\n", count: draws)
        let kids = (0..<pages).map { "\(7 + $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
            RedactionTestPdf.stream(form, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >>"),
            RedactionTestPdf.stream(page),
        ]
        for _ in 0..<pages {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /XObject << /Fm1 5 0 R >> >> >>")
        }
        return RedactionTestPdf.build(objects)
    }

    private static func write(_ pdf: [UInt8]) throws -> [UInt8] {
        try AutoTag.write(pdf, nil, TagTest.plan(pdf), AccessibleOptions(title: "A test", language: "en"))
    }

    /// An element's marked-content references to a form's stream (MCR with /Stm), as (MCID, form).
    private static func formRefs(_ elem: PObj) -> [(mcid: Int, form: PObj)] {
        guard let k = elem["K"] else { return [] }
        let items = k.isArray ? k.elements : [k]
        return items.filter { $0.isDict && $0.name("Type") == "MCR" && $0.has("Stm") }
            .compactMap { d in d.dict("Stm").map { (d.int("MCID") ?? -1, $0) } }
    }

    private static func streamText(_ d: PObj) -> String { latin1String(d.streamData ?? []) }

    private static func fm1(_ doc: MuDoc) throws -> PObj {
        try #require(doc.page(0).dict("Resources")?.dict("XObject")?.dict("Fm1"))
    }

    @Test func Content_inside_a_form_xobject_is_tagged_piece_by_piece() throws {
        let pdf = Self.formPage()
        let plan = try TagTest.plan(pdf)
        #expect(plan.blocks.contains { $0.text == Self.first })
        #expect(plan.blocks.contains { $0.text == Self.second })
        let tagged = try AutoTag.write(pdf, nil, plan, AccessibleOptions(title: "A test", language: "en"))
        let doc = try PdfEdit.openToRead(tagged, nil)
        let elements = TagTest.tree(doc)
        let h1s = elements.filter { $0.type == "H1" }.map(\.elem)
        try #require(h1s.count == 1)
        let ps = elements.filter { $0.type == "P" }.map(\.elem)
        try #require(ps.count == 2)

        // Each holds its own piece of the form, by MCID in the form's stream.
        let refs = [h1s[0], ps[0], ps[1]].map(Self.formRefs)
        try #require(refs.allSatisfy { $0.count == 1 })
        let form = refs[0][0].form
        #expect(refs.allSatisfy { $0[0].form.identity == form.identity })
        #expect(Set(refs.map { $0[0].mcid }).count == 3)
        let key = try #require(form.int("StructParents"))
        let content = Self.streamText(form)
        for (type, r) in [("H1", refs[0]), ("P", refs[1]), ("P", refs[2])] {
            #expect(content.contains("/\(type) <</MCID \(r[0].mcid)>> BDC"))
        }
        let opened = try #require(content.range(of: "/H1 <</MCID \(refs[0][0].mcid)>> BDC"))
        let text = try #require(content.range(of: Self.heading))
        #expect(text.lowerBound > opened.lowerBound)

        // The parent tree leads from the form's MCIDs back to the elements.
        let parents = try #require(TagTest.parents(doc, key))
        #expect(parents[refs[0][0].mcid]?.identity == h1s[0].identity)
        #expect(parents[refs[2][0].mcid]?.identity == ps[1].identity)

        // The page itself draws the form outside any marked content.
        #expect(!TagTest.content(doc.page(0)).contains("BDC"))
        try TagTest.passesTheCheck(tagged)
    }

    @Test func A_form_drawn_more_than_once_is_tagged_as_a_whole() throws {
        // Two pages drawing the same form: its stream can't hold one page's MCIDs, so each Do is tagged as before.
        let tagged = try Self.write(Self.formPage(pages: 2))
        let doc = try PdfEdit.openToRead(tagged, nil)
        #expect(TagTest.tree(doc).allSatisfy { Self.formRefs($0.elem).isEmpty })
        #expect(!Self.streamText(try Self.fm1(doc)).contains("MCID"))
        #expect(TagTest.content(doc.page(0)).contains("MCID"))
    }

    @Test func Re_tagging_a_form_tagged_piece_by_piece_replaces_its_tags() throws {
        let once = try Self.write(Self.formPage())
        let twice = try Self.write(once)
        let doc = try PdfEdit.openToRead(twice, nil)
        #expect(TagTest.tree(doc).filter { $0.type == "P" }.count == 2)
        let content = Self.streamText(try Self.fm1(doc))
        #expect(content.components(separatedBy: "MCID").count - 1 == 3)
        try TagTest.passesTheCheck(twice)
    }
}
