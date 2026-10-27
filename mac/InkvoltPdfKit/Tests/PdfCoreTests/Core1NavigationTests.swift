import Foundation
import Testing
@testable import PdfCore

/// Ported from Core1NavigationTests.cs: bookmarks, links, named destinations and form fields across page edits, all 11
/// tests. The PDFsharp object checks read the same objects through MuPDF (`Core2Pdf.open`). Adapted: the widget checks
/// that use FormEditor.Read (D5) read the pages' widgets directly (`widgets`). Left out until D5: FieldsFromEachFileStay
/// Fillable's fill (FormEditor.SetValues); its AcroForm /DA and /DR checks are here.
struct Core1NavigationTests {
    private static let nav = Core1TestPdf.navigation()

    @Test func originalNavigationResolves() throws {
        #expect(try outlineText(Self.nav) == "Ch1@0;>Ch1.1@1;>Ch1.2@2;Ch2@3;>Ch2.1@4;")
        #expect(try linkTargets(Self.nav, 0) == [2, 3])
    }

    @Test func deleteDropsBookmarksLinksAndWidgetsOfRemovedPages() throws {
        let result = try PageEditor.delete(Self.nav, nil, [1])
        // Ch1.1 led to the deleted page (through a named destination); its siblings and the rest re-index.
        #expect(try outlineText(result) == "Ch1@0;>Ch1.2@1;Ch2@2;>Ch2.1@3;")
        #expect(try linkTargets(result, 0) == [1, 2])
        #expect(pageObjects(result) == 4)

        let doc = try Core2Pdf.open(result)
        let root = try #require(doc.catalog.dict("Outlines"))
        #expect(root.int("Count") == 3) // Ch1, Ch1.2, Ch2 (Ch2 is closed)
        let ch1 = try #require(root.dict("First"))
        #expect(ch1.int("Count") == 1)
        #expect(ch1.dict("Next")?.int("Count") == -1)
        let names = try #require(doc.catalog.dict("Names")?.dict("Dests")?.array("Names"))
        #expect(names.count == 2) // only "sec4" is left

        // The radio group keeps its surviving widget; the one on the deleted page is gone.
        let color = try widgets(result).filter { $0.field == "color" }
        #expect(color.count == 1)
        #expect(color.first?.page == 1)
    }

    @Test func deletingAParentBookmarksPageKeepsItsChildren() throws {
        let result = try PageEditor.delete(Self.nav, nil, [0])
        #expect(try outlineText(result) == "Ch1.1@0;Ch1.2@1;Ch2@2;>Ch2.1@3;")
        #expect(pageObjects(result) == 4)
    }

    @Test func extractKeepsOnlyNavigationIntoKeptPages() throws {
        let result = try PageEditor.extract(Self.nav, nil, [3, 0])
        #expect(try outlineText(result) == "Ch1@0;Ch2@1;")
        #expect(try linkTargets(result, 0) == [1]) // the link to page 3 went with it; "sec4" still resolves
        #expect(pageObjects(result) == 2)
        #expect(try fieldNames(result) == ["name"])
        #expect(throws: PdfEditError.self) { try PageEditor.extract(Self.nav, nil, [9]) }
    }

    @Test func deletingEveryBookmarkedPageRemovesTheOutline() throws {
        let result = try PageEditor.extract(TestPdf.make(1), nil, [0])
        #expect(try outlineText(result) == "")
        let merged = try PageEditor.merge([PdfSource(Self.nav, nil, "a.pdf")], false)
        let none = try PageEditor.delete(merged, nil, [0, 1, 2, 3])
        #expect(try outlineText(none) == "Ch2.1@0;")
    }

    @Test func mergeCarriesBookmarksLinksAndFields() throws {
        let merged = try PageEditor.merge([PdfSource(Self.nav, nil, "a.pdf"), PdfSource(Self.nav, nil, "b.pdf")], true)
        #expect(try outlineText(merged) == "a@0;>Ch1@0;>>Ch1.1@1;>>Ch1.2@2;>Ch2@3;>>Ch2.1@4;b@5;>Ch1@5;>>Ch1.1@6;>>Ch1.2@7;>Ch2@8;>>Ch2.1@9;")
        #expect(try linkTargets(merged, 0) == [2, 3])
        #expect(try linkTargets(merged, 5) == [7, 8])
        #expect(pageObjects(merged) == 10)
        #expect(try fieldNames(merged) == ["name", "color", "name_2", "color_2"])

        let w = try widgets(merged)
        #expect(w.filter { $0.field == "color_2" }.count == 2)
        #expect(w.filter { $0.field == "name_2" }.map(\.value) == ["Alice"])

        let flat = try PageEditor.merge([PdfSource(Self.nav, nil, "a.pdf"), PdfSource(TestPdf.make(1), nil, "b.pdf")], false)
        #expect(try outlineText(flat) == "Ch1@0;>Ch1.1@1;>Ch1.2@2;Ch2@3;>Ch2.1@4;")
    }

    @Test func insertCarriesBookmarksForTheImportedPages() throws {
        let result = try PageEditor.insert(TestPdf.make(2), nil, PdfSource(Self.nav, nil, "nav.pdf"), [2, 0], 1)
        #expect(TestPdf.pageNumbers(result) == [1, 3, 1, 2])
        // Ch1.1, Ch2 and Ch2.1 lead to pages that weren't inserted.
        #expect(try outlineText(result) == "Ch1@2;>Ch1.2@1;")
        #expect(try linkTargets(result, 2) == [1]) // the "sec4" link had nowhere to go
        #expect(pageObjects(result) == 4)
        #expect(try fieldNames(result).sorted() == ["color", "name"])
        #expect(try widgets(result).filter { $0.field == "color" }.count == 1)

        // Inserting into a document with bookmarks appends to them.
        let twice = try PageEditor.insert(result, nil, PdfSource(Self.nav, nil, "nav.pdf"), [3], 4)
        #expect(try outlineText(twice) == "Ch1@2;>Ch1.2@1;Ch2@4;")
    }

    @Test func duplicateKeepsLinksAndMakesSeparateFields() throws {
        let result = try PageEditor.duplicate(Self.nav, nil, [0])
        #expect(try linkTargets(result, 0) == [3, 4])
        #expect(try linkTargets(result, 1) == [3, 4])
        #expect(pageObjects(result) == 6)
        #expect(try fieldNames(result) == ["name", "color", "name_2"])
        #expect(try outlineText(result) == "Ch1@0;>Ch1.1@2;>Ch1.2@3;Ch2@4;>Ch2.1@5;")
    }

    @Test func linkAndBookmarkTargetsKeepTheirPosition() throws {
        do {
            let e = try PdfEngine.open(Self.nav)
            defer { e.close() }
            let links = try e.links(0)
            #expect(abs(try #require(links[0].targetY) - 100) <= 1) // /XYZ 0 692 on a 792pt page
            #expect(links[1].targetY == nil) // /Fit names no position
            let outline = try e.outline()
            #expect(abs(try #require(outline[0].targetY) - 92) <= 1)
            #expect(abs(try #require(outline[1].targetY) - 292) <= 1) // /FitH 500
        }

        let merged = try PageEditor.merge([PdfSource(TestPdf.make(1), nil, "a.pdf"), PdfSource(Self.nav, nil, "b.pdf")], true)
        let m = try PdfEngine.open(merged)
        defer { m.close() }
        #expect(abs(try #require(try m.links(1)[0].targetY) - 100) <= 1)
        #expect(abs(try #require(try m.outline()[1].children[0].targetY) - 92) <= 1)
    }

    @Test func linkTargetYFollowsRotation() throws {
        let rotated = try PageEditor.rotate(Self.nav, nil, [2], 90)
        let e = try PdfEngine.open(rotated)
        defer { e.close() }
        // Page 3 turned clockwise: its PDF y = 692 (100pt below the top edge) is now 100pt from the left; the visible top is x = 0.
        let y = try #require(try e.links(0)[0].targetY)
        #expect((0...e.page(2).height).contains(y))
    }

    @Test func fieldsFromEachFileStayFillable() throws {
        let merged = try PageEditor.merge([PdfSource(Self.nav, nil, "a.pdf"), PdfSource(Self.nav, nil, "b.pdf")], false)
        let acro = try #require(try Core2Pdf.open(merged).catalog.dict("AcroForm"))
        #expect(acro.text("DA") == "/Helv 0 Tf 0 g")
        #expect(acro.dict("DR")?.dict("Font")?["Helv"] != nil)
    }

    @Test func aDocumentWithoutAnOutlineHasNone() throws {
        #expect(try outlineText(TestPdf.make(2)) == "")
    }
}

/// Ported from Core1XmpTests (in Core1NavigationTests.cs): XMP metadata kept in step with the Info dictionary, read with
/// Foundation's XMLDocument where Windows uses XDocument. Adapted: EveryCoreSavePathKeepsTheXmpPacket saves through
/// comments and Fill & Sign (attachments, redaction and forms come with D5 and later, each with its XMP check).
/// EditsKeepTheOriginalPacketAndUpdateIt and WriteMetadataUpdatesXmpWithEscaping are whole.
struct Core1XmpTests {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let pdf = "http://ns.adobe.com/pdf/1.3/"

    private func readXmp(_ data: [UInt8]) throws -> XMLDocument {
        let doc = try Core2Pdf.open(data)
        let bytes = try #require(doc.catalog.dict("Metadata")?.streamData)
        return try XMLDocument(data: Data(bytes), options: [.nodeLoadExternalEntitiesNever])
    }

    /// A property of an rdf:Description, as an attribute or an element (its text).
    private func prop(_ x: XMLDocument, _ ns: String, _ local: String) throws -> String? {
        let descriptions = try x.nodes(forXPath: "//*[local-name()='Description']").compactMap { $0 as? XMLElement }
            .filter { $0.uri == Self.rdf }
        for d in descriptions {
            if let a = d.attribute(forLocalName: local, uri: ns)?.stringValue { return a }
            if let e = d.elements(forLocalName: local, uri: ns).first { return e.stringValue }
        }
        return nil
    }

    private var thisYear: String { String(Calendar(identifier: .gregorian).component(.year, from: Date())) }

    @Test func writeMetadataUpdatesXmpWithEscaping() throws {
        let updated = try PageEditor.writeMetadata(TestPdf.make(2), nil, "Fish & <Chips>", "Ana \"A\"", "About", "k1, k2")
        let x = try readXmp(updated)
        #expect(try prop(x, Self.dc, "title") == "Fish & <Chips>")
        #expect(try prop(x, Self.dc, "creator") == "Ana \"A\"")
        #expect(try prop(x, Self.dc, "description") == "About")
        #expect(try prop(x, Self.pdf, "Keywords") == "k1, k2")
        let modifyDate = try #require(try prop(x, Self.xmp, "ModifyDate"))
        let modified = try #require(ISO8601DateFormatter().date(from: modifyDate))
        #expect(abs(modified.timeIntervalSinceNow) < 300)
        #expect(try prop(x, Self.xmp, "ModifyDate") == prop(x, Self.xmp, "MetadataDate"))

        // The file is still sound for both readers.
        #expect(try PageEditor.readMetadata(updated, nil).title == "Fish & <Chips>")
        #expect(TestPdf.pageNumbers(updated) == [1, 2])
    }

    @Test func editsKeepTheOriginalPacketAndUpdateIt() throws {
        let original = Core1TestPdf.withXmp()
        let edited = try PageEditor.writeMetadata(original, nil, "New title", "", "", "")
        let x = try readXmp(edited)
        #expect(try prop(x, Self.dc, "title") == "New title")
        #expect(try prop(x, "urn:example:my", "Custom") == "keep me")
        #expect(try prop(x, "http://www.aiim.org/pdfa/ns/id/", "part") == "2")
        #expect(try prop(x, Self.dc, "creator") == nil) // empty Info values leave no stale XMP behind
        #expect(try prop(x, Self.xmp, "CreateDate")?.hasPrefix("2020-01-02") == true)
        #expect(try prop(x, Self.xmp, "ModifyDate")?.hasPrefix(thisYear) == true)

        // Page edits refresh ModifyDate too.
        let rotated = try PageEditor.rotate(original, nil, [0], 90)
        let x2 = try readXmp(rotated)
        #expect(try prop(x2, Self.dc, "title") == "Old title")
        #expect(try prop(x2, Self.xmp, "ModifyDate")?.hasPrefix(thisYear) == true)
        let engine = try PdfEngine.open(rotated)
        defer { engine.close() }
        #expect(try engine.text(0).text.contains("Page 1"))
    }

    @Test func everyCoreSavePathKeepsTheXmpPacket() throws {
        let original = Core1TestPdf.withXmp()
        let note = Annotations.newId()
        let saves: [(String, ([UInt8]) throws -> [UInt8])] = [
            ("note", { try Annotations.addNote($0, nil, 0, 50, 50, "Hi", author: "Me", id: note) }),
            ("markup", { try Annotations.addTextMarkup($0, nil, 0, .highlight, [RectD(50, 50, 100, 12)], .yellow, note: nil, author: "Me") }),
            ("contents", { try Annotations.setContents(Annotations.addNote($0, nil, 0, 50, 50, "Hi", author: "Me", id: note), nil, note, "Bye") }),
            ("stamp", { try TextStamps.put($0, nil, 0, RectD(60, 60, 80, 14), .text, "Signed", 11) }),
        ]
        for (name, save) in saves {
            let x = try readXmp(save(original))
            #expect(try prop(x, "urn:example:my", "Custom") == "keep me", "\(name): custom XMP property lost")
            #expect(try prop(x, Self.dc, "title") == "Old title", "\(name): title not kept")
            #expect(try prop(x, Self.xmp, "CreateDate")?.hasPrefix("2020-01-02") == true, "\(name): CreateDate changed")
        }
    }

    @Test func mergedDocumentGetsAValidPacket() throws {
        let merged = try PageEditor.merge([PdfSource(TestPdf.make(1), nil, "a & b.pdf")], true)
        let x = try readXmp(merged)
        #expect(try prop(x, Self.xmp, "ModifyDate") != nil)
        #expect(TestPdf.pageNumbers(merged).count == 1)
    }
}
