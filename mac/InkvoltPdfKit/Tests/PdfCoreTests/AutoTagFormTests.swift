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

    /// The heading and two paragraphs inside /Fm1 (object 5; its content `form` instead); each page draws it `draws` times
    /// (one page, or as many as `pages`) after `before`, its resources with `resources` and its dictionary `pageExtra`;
    /// objects `more` after the pages.
    private static func formPage(pages: Int = 1, draws: Int = 1, form: String? = nil, before: String = "", resources: String = "",
                                 pageExtra: String = "", more: [String] = []) -> [UInt8] {
        let form = form ?? "BT /F2 18 Tf 72 700 Td (\(heading)) Tj ET\n"
            + "BT /F1 11 Tf 72 660 Td (\(first)) Tj ET\n"
            + "BT /F1 11 Tf 72 620 Td (\(second)) Tj ET"
        let page = before + String(repeating: "q /Fm1 Do Q\n", count: draws)
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
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /XObject << /Fm1 5 0 R >> \(resources) >> \(pageExtra) >>")
        }
        objects += more
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

    @Test(arguments: [
        "annotation", // a stamp whose appearance is the form
        "pattern", // a tiling pattern that draws it
        "type3", // a Type 3 glyph that draws it
    ])
    func A_form_also_drawn_outside_the_page_content_is_tagged_as_a_whole(_ place: String) throws {
        // Drawn once by the page and again where tags can't reach: its stream can't hold the page's MCIDs.
        let pdf: [UInt8]
        switch place {
        case "annotation":
            pdf = Self.formPage(pageExtra: "/Annots [8 0 R]",
                                more: ["<< /Type /Annot /Subtype /Stamp /Rect [400 50 500 100] /Contents (Approved) /AP << /N 5 0 R >> >>"])
        case "pattern":
            pdf = Self.formPage(resources: "/Pattern << /P1 8 0 R >>", more: [
                RedactionTestPdf.stream("/Fm1 Do", "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 612 792] "
                    + "/XStep 612 /YStep 792 /Resources << /XObject << /Fm1 5 0 R >> >>"),
            ])
        default:
            pdf = Self.formPage(resources: "/Font << /T3 8 0 R >>", more: [
                "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 612 792] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /a 9 0 R >> "
                    + "/Encoding << /Type /Encoding /Differences [65 /a] >> /FirstChar 65 /LastChar 65 /Widths [600] /Resources << /XObject << /Fm1 5 0 R >> >> >>",
                RedactionTestPdf.stream("600 0 d0 /Fm1 Do"),
            ])
        }
        let tagged = try Self.write(pdf)
        let doc = try PdfEdit.openToRead(tagged, nil)
        #expect(TagTest.tree(doc).allSatisfy { Self.formRefs($0.elem).isEmpty })
        #expect(!Self.streamText(try Self.fm1(doc)).contains("MCID"))
        #expect(TagTest.content(doc.page(0)).contains("MCID"))
    }

    @Test func Text_inside_a_form_in_the_font_set_before_its_Do_is_read_in_that_font() throws {
        // The form shows its heading in the font the page set before drawing it (a form starts with the text state at its
        // Do): read in that font, the heading is the text of the link over it.
        let pdf = Self.formPage(
            form: "BT 72 700 Td (\(Self.heading)) Tj ET\nBT /F1 11 Tf 72 660 Td (\(Self.first)) Tj ET\nBT /F1 11 Tf 72 620 Td (\(Self.second)) Tj ET",
            before: "BT /F2 18 Tf ET\n", resources: "/Font << /F2 4 0 R >>", pageExtra: "/Annots [8 0 R]",
            more: ["<< /Type /Annot /Subtype /Link /Rect [70 694 240 716] /Border [0 0 0] /A << /S /URI /URI (https://example.com/) >> >>"])
        let tagged = try Self.write(pdf)
        let doc = try PdfEdit.openToRead(tagged, nil)
        let link = try #require(doc.page(0).array("Annots")?[0])
        #expect(link.text("Contents") == Self.heading)
        // The heading's link holds the heading's piece of the form.
        let elements = TagTest.tree(doc)
        let h1s = elements.filter { $0.type == "H1" }.map(\.elem)
        let links = elements.filter { $0.type == "Link" }.map(\.elem)
        try #require(h1s.count == 1 && links.count == 1)
        #expect(links[0].dict("P")?.identity == h1s[0].identity)
        #expect(Self.formRefs(links[0]).count == 1)
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
