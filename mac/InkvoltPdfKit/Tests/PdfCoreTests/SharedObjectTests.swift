import Foundation
import Testing
@testable import PdfCore

/// Mac additions (fix round 1 of 3.1's review): an inline (direct) dictionary or array two parents share is renumbered
/// once through each when MuPDF compacts a file, and its references then point at other objects. Each case is saved,
/// reopened, and its references checked: the pass before every compacting save (`MuDoc.unshareDirectObjects`) and the
/// deep copies at each place an edit copies entries.
@Suite(.serialized) struct SharedObjectTests {
    static let letters = TranslationCopyTests.letters
    typealias T = TranslationCopyTests

    /// Two pages sharing one /Resources object whose /Font dictionary is inline. /FU, written before the pages, is in the
    /// file but unused: a compacting save drops it, so the objects after it (the pages, their fonts' programs) get new
    /// numbers, as an edit that replaces things does.
    static func twoPages(_ first: String = T.lines(72, 700, 12, 14, "Hello World"), _ second: String = T.lines(72, 700, 12, 14, "2024 draft!"),
                         form: String? = nil, formInherits: Bool = false) -> [UInt8] {
        let pdf = ContentEditPdf.make(pages: [first, second], form: form, formInherits: formInherits, fontText: letters)
        let doc = try! PdfEdit.open(pdf, nil)
        let fonts = doc.page(0).dict("Resources")!.dict("Font")!
        fonts.remove("FU")
        // /FA as a new object after /FU (its first one unused too), so dropping /FU moves it.
        let old = fonts.dict("FA")!
        let fa = doc.dict()
        for k in old.keys { if let v = old[k] { fa.set(k, ContentEditor.ownCopy(doc, v)) } }
        let moved = doc.add(fa)
        fonts.set("FA", moved)
        doc.page(0).dict("Resources")?.dict("XObject")?.dict("Fm1")?.dict("Resources")?.dict("Font")?.set("FA", moved)
        try! doc.checkFailure()
        return try! doc.write("")
    }

    /// How wide MuPDF reads the first occurrence of `word` on a page (points).
    static func readWidth(_ pdf: [UInt8], _ page: Int, _ word: String) -> Double {
        guard let engine = try? PdfEngine.open(pdf) else { return 0 }
        defer { engine.close() }
        guard let text = try? engine.text(page, cache: false), let hit = text.find(word, matchCase: true, wholeWord: false).first else { return 0 }
        let rects = text.rects(hit.start, hit.end)
        return rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }.width
    }

    static func text(_ pdf: [UInt8], _ page: Int) -> String { ContentEditPdf.text(pdf, page: page) }

    /// The /FA a page's resources name, reopened: a font dictionary of Arial (MuPDF reads text with a fallback font when
    /// a reference points at nothing, so the words alone don't show it).
    static func fontIntact(_ pdf: [UInt8], _ page: Int) -> Bool {
        guard let doc = try? Core2Pdf.open(pdf), let fa = doc.page(page).dict("Resources")?.dict("Font")?.dict("FA") else { return false }
        return fa.name("Type") == "Font" && (fa.name("BaseFont") ?? "").contains("Arial")
    }

    @Test func aDirectDictionaryTwoParentsShareKeepsItsReferencesThroughACompactingSave() throws {
        let doc = try PdfEdit.open(Self.twoPages(), nil)
        let shared = doc.dict([("P", doc.page(1)), ("Kids", doc.array([doc.page(0), doc.page(1)]))])
        doc.page(0).set("InkTest", shared)
        doc.page(1).set("InkTest", shared)
        try doc.checkFailure()
        let saved = try doc.write("garbage=compact")
        let back = try Core2Pdf.open(saved)
        for i in 0..<2 {
            let d = try #require(back.page(i).dict("InkTest"))
            #expect(d["P"]?.identity == back.page(1).identity, "page \(i + 1)'s /P")
            #expect(d.array("Kids")?[0]?.identity == back.page(0).identity, "page \(i + 1)'s /Kids")
        }
        #expect(Self.text(saved, 0).contains("Hello World") && Self.text(saved, 1).contains("2024 draft!"))
    }

    @Test func theUnsharingPassStaysBoundedOnHostileNesting() throws {
        let doc = try PdfEdit.open(Self.twoPages(), nil)
        // An inline array nested 5,000 deep (far past the pass's limit), shared by both pages, and a chain of 100,000
        // references.
        var deep = doc.array()
        for _ in 0..<5_000 { deep = doc.array([deep]) }
        doc.page(0).set("Deep", deep)
        doc.page(1).set("Deep", deep)
        var chain = doc.add(doc.dict())
        for _ in 0..<100_000 { chain = doc.add(doc.dict([("Next", chain)])) }
        doc.page(0).set("Chain", chain)
        let start = Date()
        let result = doc.unshareDirectObjects()
        #expect(Date().timeIntervalSince(start) < 60, "\(Date().timeIntervalSince(start)) s")
        #expect(!result.complete) // past its depth: the save is written without renumbering
    }

    @Test func aLinkCopiedForAWrappedLineKeepsItsDestination() throws {
        let doc = try PdfEdit.open(Self.twoPages(), nil)
        let page = doc.page(0)
        let action = doc.dict([("S", doc.name("GoTo")), ("D", doc.array([doc.page(1), doc.name("XYZ"), doc.real(0), doc.real(700), doc.null]))])
        let link = doc.add(doc.dict([("Type", doc.name("Annot")), ("Subtype", doc.name("Link")), ("Rect", doc.reals(72, 690, 200, 704)), ("A", action)]))
        page.set("Annots", doc.array([link]))
        let copies = ContentEditor.place(doc, page, link, [RectD(72, 88, 100, 14), RectD(72, 102, 60, 14)])
        let annots = try #require(page.array("Annots"))
        for c in copies { annots.append(c) }
        try doc.checkFailure()
        let back = try Core2Pdf.open(try doc.write("garbage=compact"))
        let list = try #require(back.page(0).array("Annots"))
        #expect(list.count == 2)
        for i in 0..<list.count {
            #expect(list[i]?.dict("A")?.array("D")?[0]?.identity == back.page(1).identity, "link \(i + 1) goes to page 2")
        }
    }

    @Test func aTranslatedFormThePagesShareLeavesTheOtherPagesFontsAlone() throws {
        let pdf = Self.twoPages("/Fm1 Do", "/Fm1 Do", form: T.lines(72, 700, 12, 14, "Hello World"))
        let (_, r) = try T.translate(pdf, { _ in "Un ñandú corre" }, pages: [0])
        let copy = try #require(r.data)
        #expect(Self.text(copy, 0).contains("ñandú"))
        #expect(Self.text(copy, 1).contains("Hello World"), "\(Self.text(copy, 1))")
    }

    @Test func aParagraphEditedInAFormThePagesShareLeavesTheOtherPagesFontsAlone() throws {
        let pdf = Self.twoPages("/Fm1 Do", "/Fm1 Do", form: T.lines(72, 700, 12, 14, "Hello World"))
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "Hello ñandú")
        #expect(Self.text(edited, 0).contains("ñandú"))
        #expect(Self.text(edited, 1).contains("Hello World"), "\(Self.text(edited, 1))")
    }

    @Test func aWatermarkOnPagesSharingResourcesKeepsTheirText() throws {
        let marked = try Watermarks.apply(Self.twoPages(), nil, [0, 1], WatermarkOptions(text: "DRAFT", opacity: 0.3))
        #expect(Self.fontIntact(marked, 0) && Self.fontIntact(marked, 1))
        #expect(Self.text(marked, 0).contains("Hello World") && Self.text(marked, 1).contains("2024 draft!"))
        let flat = try Flattener.flatten(marked, nil)
        #expect(Self.fontIntact(flat, 0) && Self.fontIntact(flat, 1))
    }

    /// The pages' /Resources inherited from the page tree, and a square comment with an appearance on each.
    static func inheritedWithComments() throws -> [UInt8] {
        let doc = try PdfEdit.open(Self.twoPages(), nil)
        let resources = try #require(doc.page(0)["Resources"])
        doc.catalog.dict("Pages")?.set("Resources", resources)
        for i in 0..<2 {
            let page = doc.page(i)
            page.remove("Resources")
            let look = doc.formXObject(Array("0 0 1 rg 0 0 20 20 re f".utf8), 0, 0, 20, 20, nil)
            page.set("Annots", doc.array([doc.add(doc.dict([("Type", doc.name("Annot")), ("Subtype", doc.name("Square")),
                                                             ("Rect", doc.reals(300, 300, 320, 320)), ("AP", doc.dict([("N", look)]))]))]))
        }
        try doc.checkFailure()
        return try doc.write("")
    }

    @Test func flatteningPagesThatInheritSharedResourcesKeepsTheirText() throws {
        let flat = try Flattener.flatten(try Self.inheritedWithComments(), nil)
        #expect(Self.fontIntact(flat, 0) && Self.fontIntact(flat, 1))
        #expect(Self.text(flat, 0).contains("Hello World") && Self.text(flat, 1).contains("2024 draft!"))
    }

    /// The pages' /FA made inline in their shared resources, with a width for "H" only: a translation's other letters
    /// get theirs from the font program as they are written (`TextFont.prepare`).
    static func inlineNarrowFont(_ pdf: [UInt8]) throws -> [UInt8] {
        let doc = try PdfEdit.open(pdf, nil)
        let fonts = try #require(doc.page(0).dict("Resources")?.dict("Font"))
        let fa = try #require(fonts.dict("FA"))
        let inline = doc.dict()
        for k in fa.keys where !["FirstChar", "LastChar", "Widths"].contains(k) { if let v = fa[k] { inline.set(k, v) } }
        let h = fa.int("FirstChar").map { 72 - $0 } ?? 0
        inline.set("FirstChar", doc.int(72))
        inline.set("LastChar", doc.int(72))
        inline.set("Widths", doc.array([fa.array("Widths")?[h] ?? doc.int(722)]))
        fonts.set("FA", inline)
        try doc.checkFailure()
        return try doc.write("")
    }

    @Test func fontsPreparedForNewCodesAreTheOnesThePageDrawsWith() throws {
        // Page 1: a paragraph in the inline /FA, and a form both pages draw (copied for page 1's own text: the page's
        // resources are made its own before its fonts are written).
        let pdf = try Self.inlineNarrowFont(Self.twoPages(T.lines(72, 500, 12, 14, "HHHH") + "/Fm1 Do", "/Fm1 Do", form: T.lines(72, 700, 12, 14, "Hello World")))
        let (_, r) = try T.translate(pdf, { $0 == "HHHH" ? "World World World" : "THE DOG" }, pages: [0])
        let copy = try #require(r.data)
        // About 108 points in Arial at 12, as MuPDF reads the copy; with no widths the letters would all stand at one place.
        let width = Self.readWidth(copy, 0, "World World World")
        #expect(width > 80, "\(width)")
        #expect(Self.text(copy, 0).contains("World World World"))
    }

    @Test func aParagraphEditInAFormNeedingNewCodesPreparesTheFontThePageUses() throws {
        // The form borrows the page's resources (no /Resources of its own) and both pages draw it: it is copied for page 1.
        let pdf = try Self.inlineNarrowFont(Self.twoPages("/Fm1 Do", "/Fm1 Do", form: T.lines(72, 700, 12, 14, "HHHH"), formInherits: true))
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, "World World World")
        let width = Self.readWidth(edited, 0, "World World World")
        #expect(width > 80, "\(width)")
        #expect(Self.text(edited, 1).contains("HHHH"))
    }
}
