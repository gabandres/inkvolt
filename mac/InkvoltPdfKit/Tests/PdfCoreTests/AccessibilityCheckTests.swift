import Foundation
import Testing
@testable import PdfCore

/// A tagged PDF built by hand for the accessibility check (the Windows tests' `A11yDoc`): one page, a Document tag holding
/// the `elems`, a Type 3 font (no font program to embed), XMP with a title and the PDF/UA identifier. As it is, it passes
/// every machine check; each test changes one thing. Objects: 1 catalog, 2 pages, 3 page, 4 content, 5 structure tree
/// root, 6 Document tag, 7 XMP, 8 font F1, 9 its glyph, 10… the elements, then `more`. Written as Latin-1, a byte per
/// character, because font programs are binary.
struct A11yDoc {
    static let goodXmp =
        "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
        + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\">"
        + "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">A test</rdf:li></rdf:Alt></dc:title><pdfuaid:part>1</pdfuaid:part></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"

    static let type3Font =
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 600 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /A 9 0 R /B 9 0 R >> "
        + "/Encoding << /Type /Encoding /Differences [65 /A /B] >> /FirstChar 65 /LastChar 66 /Widths [600 600] /Resources << >> >>"

    var header = "%PDF-1.7"
    var catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R"
    var tagged = true
    var rootExtra = ""
    var page = "/Tabs /S"
    var resources = ""
    /// More fonts in the page's /Font ("/F2 11 0 R").
    var fonts = ""
    var content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC"
    var elems = ["<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>"]
    var docKids = "10 0 R"
    var parentTree = "0 [10 0 R]"
    var xmp: String? = A11yDoc.goodXmp
    var annots = ""
    var font = A11yDoc.type3Font
    var more: [String] = []

    /// A stream object, a byte per character.
    static func stream(_ content: String, _ dict: String = "") -> String {
        "<< \(dict) /Length \(content.unicodeScalars.count) >>\nstream\n\(content)\nendstream"
    }

    /// Objects 1, 2… and a cross-reference table, a byte per character.
    static func file(_ objects: [String], trailerExtra: String = "", header: String = "%PDF-1.7") -> [UInt8] {
        var out = latin1Bytes(header + "\n")
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.count)
            out += latin1Bytes("\(i + 1) 0 obj\n\(body)\nendobj\n")
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for at in offsets { table += String(format: "%010d 00000 n \n", at) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R \(trailerExtra) >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + latin1Bytes(table)
    }

    /// The object number of `more[i]`.
    func moreAt(_ i: Int) -> Int { 10 + elems.count + i }

    func build() -> [UInt8] {
        let annotList = annots.isEmpty ? "" : "/Annots [\(annots)]"
        let objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R \(tagged ? "/StructTreeRoot 5 0 R" : "") \(catalog) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /StructParents 0 /Resources << /Font << /F1 8 0 R \(fonts) >> \(resources) >> \(annotList) \(page) >>",
            Self.stream(content),
            "<< /Type /StructTreeRoot /K 6 0 R /ParentTree << /Nums [\(parentTree)] >> \(rootExtra) >>",
            "<< /Type /StructElem /S /Document /P 5 0 R /K [\(docKids)] >>",
            xmp.map { Self.stream($0, "/Type /Metadata /Subtype /XML") } ?? "<< >>",
            font,
            Self.stream("600 0 d0 0 0 600 700 re f"),
        ] + elems + more
        // An Info dictionary with the same title: Inkvolt's saves keep XMP and Info in step.
        var data = Self.file(objects + ["<< /Title (A test) >>"], trailerExtra: "/Info \(objects.count + 1) 0 R")
        if header != "%PDF-1.7" { data.replaceSubrange(0..<header.utf8.count, with: Array(header.utf8)) }
        return data
    }

    func check() throws -> AccessibilityReport { try AccessibilityCheck.run(build(), nil) }

    /// The system's Arial (Windows: PDFsharp's subset of it, "AB"), as Latin-1 text. A and B are 667 wide in it.
    static let arial: (program: String, length: Int) = {
        let bytes = [UInt8](FileManager.default.contents(atPath: "/System/Library/Fonts/Supplemental/Arial.ttf") ?? Data())
        return (latin1String(bytes), bytes.count)
    }()

    /// A simple TrueType font F2 (object `at`, its descriptor and program after it) using the Arial program.
    static func trueType(_ at: Int, fontExtra: String = "/Encoding /WinAnsiEncoding", widths: String = "[667 667]", flags: Int = 32) -> [String] {
        [
            "<< /Type /Font /Subtype /TrueType /BaseFont /ABCDEF+Arial /FirstChar 65 /LastChar 66 /Widths \(widths) \(fontExtra) /FontDescriptor \(at + 1) 0 R >>",
            "<< /Type /FontDescriptor /FontName /ABCDEF+Arial /Flags \(flags) /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 \(at + 2) 0 R >>",
            stream(arial.program, "/Length1 \(arial.length)"),
        ]
    }

    /// A composite (Type 0) font F2 at `at`: the Arial program as a TrueType CID font, then its CID font, descriptor and program.
    static func composite(_ at: Int, encoding: String = "/Identity-H", cidExtra: String = "/CIDToGIDMap /Identity /W [36 [667 667]]", descriptorExtra: String = "",
                          info: String = "<< /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>") -> [String] {
        [
            "<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Arial /Encoding \(encoding) /DescendantFonts [\(at + 1) 0 R] >>",
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+Arial /CIDSystemInfo \(info) /FontDescriptor \(at + 2) 0 R /DW 1000 \(cidExtra) >>",
            "<< /Type /FontDescriptor /FontName /ABCDEF+Arial /Flags 32 /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 \(at + 3) 0 R \(descriptorExtra) >>",
            stream(arial.program, "/Length1 \(arial.length)"),
        ]
    }

    /// A ToUnicode for the composite font F2 (an extra object at the end).
    func withToUnicode() -> A11yDoc {
        var doc = self
        let at = moreAt(more.count)
        doc.more[0] = more[0].replacingOccurrences(of: "/DescendantFonts", with: "/ToUnicode \(at) 0 R /DescendantFonts")
        doc.more.append(Self.stream("1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfchar <0024> <0041> endbfchar"))
        return doc
    }

    func with(_ change: (inout A11yDoc) -> Void) -> A11yDoc {
        var doc = self
        change(&doc)
        return doc
    }
}

private func doc(_ change: (inout A11yDoc) -> Void) -> A11yDoc { A11yDoc().with(change) }

/// Ported from AccessibilityCheckTests.cs (same names). Adapted: the fonts are the system's whole Arial, written by hand
/// (Windows: PDFsharp's subset of it), and ProtectionMustLetScreenReadersRead protects through MuPDF.
struct AccessibilityCheckTests {
    private func fails(_ doc: A11yDoc, _ condition: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let report = try doc.check()
        #expect(!report.passed, sourceLocation: sourceLocation)
        #expect(report.failedConditions.contains(condition), "\(report.failedConditions)", sourceLocation: sourceLocation)
        for f in report.failures where f.condition == condition {
            #expect(!f.problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sourceLocation: sourceLocation)
            #expect(!f.fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sourceLocation: sourceLocation)
        }
    }

    private func passes(_ doc: A11yDoc, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let report = try doc.check()
        #expect(report.passed, "\(report.failures.map { "\($0.condition): \($0.problem)" })", sourceLocation: sourceLocation)
    }

    private func doesNotFail(_ doc: A11yDoc, _ condition: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try !doc.check().failedConditions.contains(condition), sourceLocation: sourceLocation)
    }

    private static let p = "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>"

    // MARK: The catalogue

    @Test func EveryMatterhornConditionIsListedAndEveryHumanOneIsInTheChecklist() {
        let matterhorn = AccessibilityCheck.conditions.filter { !$0.id.hasPrefix("UA") }
        #expect(matterhorn.count == 137)
        #expect(Set(matterhorn.map(\.id)).count == matterhorn.count)
        for c in AccessibilityCheck.conditions {
            #expect(AccessibilityCheck.checkpoints[c.checkpoint] != nil, "\(c.id)")
            if c.how == .machine { #expect(!c.fix.isEmpty, "\(c.id)") }
            if c.how == .notChecked { #expect(c.note?.isEmpty == false, "\(c.id)") }
        }
        let inChecklist = Set(AccessibilityCheck.humanChecks.flatMap(\.conditions))
        for c in AccessibilityCheck.conditions where c.how == .human { #expect(inChecklist.contains(c.id), "\(c.id)") }
        #expect(Set(AccessibilityCheck.humanChecks.map(\.id)).count == AccessibilityCheck.humanChecks.count)
    }

    @Test func AGoodTaggedDocumentPassesEveryMachineCheck() throws { try passes(A11yDoc()) }

    // MARK: Basics, metadata, dictionary

    @Test func AnUntaggedDocumentFails() throws {
        let report = try doc {
            $0.tagged = false
            $0.content = "BT /F1 12 Tf 72 700 Td (AB) Tj ET 0 0 10 10 re f"
        }.check()
        #expect(!report.tagged)
        #expect(report.failedConditions.contains("UA 7.1"))
        let untagged = report.failures.filter { $0.condition == "01-005" }
        #expect(untagged.count == 1)
        #expect(untagged.first?.page == 0)
        #expect(untagged.first?.count == 2)
        #expect(untagged.first?.box.isEmpty == false)
    }

    @Test func MarkInfoSuspectsHeaderAndParent() throws {
        try fails(doc { $0.catalog = "/Lang (en-US) /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R" }, "UA 6.2")
        try fails(doc { $0.catalog = "/Lang (en-US) /MarkInfo << /Marked true /Suspects true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R" }, "01-007")
        try fails(doc { $0.header = "%PDF-2.0" }, "UA 6.1")
        try fails(doc { $0.elems = ["<< /Type /StructElem /S /P /Pg 3 0 R /K 0 >>"] }, "UA 7.1-P")
    }

    @Test func MetadataNeedsXmpThePdfUaIdentifierAndATitle() throws {
        let part = "<pdfuaid:part>1</pdfuaid:part>"
        try fails(doc {
            $0.xmp = nil
            $0.catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >>"
        }, "06-001")
        try fails(doc { $0.xmp = A11yDoc.goodXmp.replacingOccurrences(of: part, with: "") }, "06-002")
        try fails(doc { $0.xmp = A11yDoc.goodXmp.replacingOccurrences(of: part, with: "<pdfuaid:part>2</pdfuaid:part>") }, "06-002")
        try fails(doc { $0.xmp = A11yDoc.goodXmp.replacingOccurrences(of: "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">A test</rdf:li></rdf:Alt></dc:title>", with: "") }, "06-003")
        // The identifier as an attribute of the description counts too.
        try passes(doc {
            $0.xmp = A11yDoc.goodXmp.replacingOccurrences(of: part, with: "").replacingOccurrences(of: "rdf:about=\"\"", with: "rdf:about=\"\" pdfuaid:part=\"1\"")
        })
    }

    @Test func TheTitleMustBeShown() throws {
        try fails(doc { $0.catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /Metadata 7 0 R" }, "07-001")
        try fails(doc { $0.catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle false >> /Metadata 7 0 R" }, "07-002")
    }

    // MARK: Content

    @Test func EveryContentItemIsTaggedOrAnArtifact() throws {
        try fails(doc { $0.content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC 72 600 100 1 re f" }, "01-005")
        try passes(doc { $0.content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC /Artifact BMC 72 600 100 1 re f EMC" })
        // Marked content whose id the parent tree doesn't name isn't tagged.
        try fails(doc { $0.parentTree = "0 [null]" }, "01-005")
        // Clipping paths aren't content.
        try passes(doc { $0.content = "0 0 612 792 re W n /P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC" })
    }

    @Test func ArtifactsAndTaggedContentDontNest() throws {
        try fails(doc { $0.content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET /Artifact BMC 0 0 5 5 re f EMC EMC" }, "01-003")
        try fails(doc { $0.content = "/Artifact BMC /P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC EMC" }, "01-004")
    }

    @Test func TaggedContentInAFormDrawnTwiceFails() throws {
        let twice = doc {
            $0.resources = "/XObject << /Fm1 11 0 R >>"
            $0.content = "/Fm1 Do /Fm1 Do"
            $0.more = [A11yDoc.stream("/P << /MCID 0 >> BDC BT /F1 12 Tf 10 10 Td (AB) Tj ET EMC", "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /Font << /F1 8 0 R >> >>")]
        }
        try fails(twice, "30-002")
        try passes(twice.with { $0.content = "/Fm1 Do" })
    }

    @Test func AReferenceXObjectFails() throws {
        try fails(doc {
            $0.resources = "/XObject << /Fm1 11 0 R >>"
            $0.content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET /Fm1 Do EMC"
            $0.more = [A11yDoc.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Ref << /F (other.pdf) /Page 0 >>")]
        }, "30-001")
    }

    // MARK: Role map

    @Test func CustomTypesMustMapToStandardOnes() throws {
        let custom = doc { $0.elems = ["<< /Type /StructElem /S /Para /P 6 0 R /Pg 3 0 R /K 0 >>"] }
        try fails(custom, "02-001")
        try passes(custom.with { $0.rootExtra = "/RoleMap << /Para /P >>" })
        try fails(custom.with { $0.rootExtra = "/RoleMap << /Para /Body /Body /Para >>" }, "02-003")
        try fails(doc { $0.rootExtra = "/RoleMap << /P /Span >>" }, "02-004")
        // A standard type mapped to itself is a circle, not a remapping.
        try fails(doc { $0.rootExtra = "/RoleMap << /P /P >>" }, "02-003")
    }

    // MARK: Language

    private static let noLang = "/MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R"

    @Test func TextNeedsALanguage() throws {
        try fails(doc { $0.catalog = Self.noLang }, "11-001")
        // ... from its tag, or from its marked content.
        try doesNotFail(doc {
            $0.catalog = Self.noLang
            $0.elems = ["<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 /Lang (de) >>"]
        }, "11-001")
        try doesNotFail(doc {
            $0.catalog = Self.noLang
            $0.content = "/P << /MCID 0 /Lang (fr) >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC"
        }, "11-001")
        try fails(doc { $0.catalog = "/Lang (en_US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R" }, "UA 7.2-Lang")
    }

    @Test func AlternateTextMetadataBookmarksCommentsAndFieldsNeedALanguage() throws {
        try fails(doc {
            $0.catalog = Self.noLang
            $0.elems = ["<< /Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 0 /Alt (A cat) >>"]
        }, "11-002")
        try fails(doc { $0.catalog = Self.noLang }, "11-006")
        try doesNotFail(doc {
            $0.catalog = Self.noLang
            $0.xmp = A11yDoc.goodXmp.replacingOccurrences(of: "x-default", with: "en")
        }, "11-006")
        let outlines = doc {
            $0.catalog = Self.noLang + " /Outlines 11 0 R"
            $0.more = ["<< /Type /Outlines /First 12 0 R /Last 12 0 R /Count 1 >>", "<< /Title (One) /Parent 11 0 R /Dest [3 0 R /Fit] >>"]
        }
        try fails(outlines, "11-003")
        try doesNotFail(outlines.with { $0.catalog += " /Lang (en)" }, "11-003")
        let note = doc {
            $0.catalog = Self.noLang
            $0.annots = "12 0 R"
            $0.elems = [Self.p, "<< /Type /StructElem /S /Annot /P 6 0 R /Pg 3 0 R /K << /Type /OBJR /Obj 12 0 R >> >>"]
            $0.docKids = "10 0 R 11 0 R"
            $0.parentTree = "0 [10 0 R] 1 11 0 R"
            $0.more = ["<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (A note) /StructParent 1 >>"]
        }
        try fails(note, "11-004")
        try doesNotFail(note.with { $0.catalog = Self.noLang + " /Lang (en)" }, "11-004")
        try fails(doc {
            $0.catalog = Self.noLang + " /AcroForm << /Fields [12 0 R] >>"
            $0.annots = "12 0 R"
            $0.elems = [Self.p, "<< /Type /StructElem /S /Form /P 6 0 R /Pg 3 0 R /K << /Type /OBJR /Obj 12 0 R >> >>"]
            $0.docKids = "10 0 R 11 0 R"
            $0.parentTree = "0 [10 0 R] 1 11 0 R"
            $0.more = ["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /TU (Your name) /Rect [100 100 200 120] /StructParent 1 >>"]
        }, "11-005")
    }

    // MARK: Tags

    private func tags(_ elems: String...) -> A11yDoc {
        doc {
            $0.content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC"
            $0.elems = [Self.p] + elems
            $0.docKids = (0...elems.count).map { "\(10 + $0) 0 R" }.joined(separator: " ")
        }
    }

    @Test func FiguresAndFormulasNeedAlternateText() throws {
        try fails(tags("<< /Type /StructElem /S /Figure /P 6 0 R >>"), "13-004")
        try passes(tags("<< /Type /StructElem /S /Figure /P 6 0 R /Alt (A cat on a mat) >>"))
        try passes(tags("<< /Type /StructElem /S /Figure /P 6 0 R /ActualText (A) >>"))
        try fails(tags("<< /Type /StructElem /S /Figure /P 6 0 R /Alt () >>"), "13-004")
        try fails(tags("<< /Type /StructElem /S /Formula /P 6 0 R >>"), "17-002")
        // A custom type mapped to Figure is a figure.
        try fails(tags("<< /Type /StructElem /S /Image /P 6 0 R >>").with { $0.rootExtra = "/RoleMap << /Image /Figure >>" }, "13-004")
    }

    @Test func HeadingsStartAtH1AndDontSkip() throws {
        try fails(tags("<< /Type /StructElem /S /H2 /P 6 0 R >>"), "14-002")
        try fails(tags("<< /Type /StructElem /S /H1 /P 6 0 R >>", "<< /Type /StructElem /S /H3 /P 6 0 R >>"), "14-003")
        try passes(tags("<< /Type /StructElem /S /H1 /P 6 0 R >>", "<< /Type /StructElem /S /H2 /P 6 0 R >>", "<< /Type /StructElem /S /H1 /P 6 0 R >>"))
        try fails(tags("<< /Type /StructElem /S /H /P 6 0 R >>", "<< /Type /StructElem /S /H /P 6 0 R >>"), "14-006")
        try fails(tags("<< /Type /StructElem /S /H /P 6 0 R >>", "<< /Type /StructElem /S /H1 /P 6 0 R >>"), "14-007")
    }

    @Test func TablesListsAndContentsFollowTheirStructure() throws {
        // 11 Table > 12 TR > 13 TH, 14 TH; 15 TR > 16 TD, 17 TD
        let table = [
            "<< /Type /StructElem /S /Table /P 6 0 R /K [12 0 R 15 0 R] >>",
            "<< /Type /StructElem /S /TR /P 11 0 R /K [13 0 R 14 0 R] >>",
            "<< /Type /StructElem /S /TH /P 12 0 R /A << /O /Table /Scope /Column >> >>",
            "<< /Type /StructElem /S /TH /P 12 0 R /A << /O /Table /Scope /Column >> >>",
            "<< /Type /StructElem /S /TR /P 11 0 R /K [16 0 R 17 0 R] >>",
            "<< /Type /StructElem /S /TD /P 15 0 R >>",
            "<< /Type /StructElem /S /TD /P 15 0 R >>",
        ]
        let good = doc {
            $0.elems = [Self.p] + table
            $0.docKids = "10 0 R 11 0 R"
        }
        try passes(good)
        // A cell directly in the table, not in a row.
        try fails(good.with {
            $0.elems = [Self.p, "<< /Type /StructElem /S /Table /P 6 0 R /K [12 0 R 15 0 R 17 0 R] >>", table[1], table[2], table[3],
                        "<< /Type /StructElem /S /TR /P 11 0 R /K [16 0 R] >>", table[5], "<< /Type /StructElem /S /TD /P 11 0 R >>"]
        }, "09-004")
        // Rows of different widths.
        try fails(good.with {
            $0.elems = [Self.p, table[0], table[1], table[2], table[3], "<< /Type /StructElem /S /TR /P 11 0 R /K [16 0 R] >>", table[5], "<< /Type /StructElem /S /P /P 6 0 R >>"]
        }, "09-004")
        // Header cells without scope, data cells without Headers.
        try fails(good.with {
            $0.elems = [Self.p, table[0], table[1], "<< /Type /StructElem /S /TH /P 12 0 R >>", table[3], table[4], table[5], table[6]]
        }, "15-003")
        // ... unless the data cells name their headers.
        try passes(good.with {
            $0.elems = [
                Self.p, table[0], table[1], "<< /Type /StructElem /S /TH /P 12 0 R /ID (h1) >>", "<< /Type /StructElem /S /TH /P 12 0 R /ID (h2) >>", table[4],
                "<< /Type /StructElem /S /TD /P 15 0 R /A << /O /Table /Headers [(h1)] >> >>", "<< /Type /StructElem /S /TD /P 15 0 R /A << /O /Table /Headers [(h2)] >> >>",
            ]
        })

        try fails(tags("<< /Type /StructElem /S /LI /P 6 0 R >>"), "09-005")
        try passes(tags("<< /Type /StructElem /S /L /P 6 0 R /K 12 0 R >>", "<< /Type /StructElem /S /LI /P 11 0 R /K [13 0 R 14 0 R] >>",
                        "<< /Type /StructElem /S /Lbl /P 12 0 R >>", "<< /Type /StructElem /S /LBody /P 12 0 R >>").with { $0.docKids = "10 0 R 11 0 R" })
        try fails(tags("<< /Type /StructElem /S /L /P 6 0 R /K 12 0 R >>", "<< /Type /StructElem /S /P /P 11 0 R >>").with { $0.docKids = "10 0 R 11 0 R" }, "09-005")
        try fails(tags("<< /Type /StructElem /S /TOCI /P 6 0 R >>"), "09-006")
    }

    @Test func NotesNeedUniqueIds() throws {
        try fails(tags("<< /Type /StructElem /S /Note /P 6 0 R >>"), "19-003")
        try fails(tags("<< /Type /StructElem /S /Note /P 6 0 R /ID (n1) >>", "<< /Type /StructElem /S /Note /P 6 0 R /ID (n1) >>"), "19-004")
        try passes(tags("<< /Type /StructElem /S /Note /P 6 0 R /ID (n1) >>", "<< /Type /StructElem /S /Note /P 6 0 R /ID (n2) >>"))
    }

    // MARK: Annotations

    /// The page with one annotation (object 12), tagged in an element of type `tag` (nil: untagged).
    private func annotated(_ annot: String, _ tag: String?, page: String = "/Tabs /S", catalog: String = "") -> A11yDoc {
        doc {
            $0.catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R " + catalog
            $0.page = page
            $0.annots = "12 0 R"
            $0.elems = [Self.p, tag.map { "<< /Type /StructElem /S /\($0) /P 6 0 R /Pg 3 0 R /K << /Type /OBJR /Obj 12 0 R >> >>" } ?? "<< /Type /StructElem /S /Span /P 6 0 R >>"]
            $0.docKids = "10 0 R 11 0 R"
            $0.parentTree = tag == nil ? "0 [10 0 R]" : "0 [10 0 R] 1 11 0 R"
            $0.more = [tag == nil ? annot : annot.replacingOccurrences(of: "/Rect", with: "/StructParent 1 /Rect")]
        }
    }

    @Test func CommentsAreTaggedAndDescribed() throws {
        try passes(annotated("<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (A note) >>", "Annot"))
        try fails(annotated("<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (A note) >>", nil), "28-002")
        try fails(annotated("<< /Type /Annot /Subtype /Square /Rect [100 100 120 120] >>", "Annot"), "28-004")
        // Hidden comments, and ones outside the page, aren't read.
        try passes(annotated("<< /Type /Annot /Subtype /Square /F 2 /Rect [100 100 120 120] >>", "Annot"))
        try passes(annotated("<< /Type /Annot /Subtype /Square /Rect [900 900 920 920] >>", "Annot"))
        try fails(annotated("<< /Type /Annot /Subtype /TrapNet /Rect [100 100 120 120] /Contents (x) >>", "Annot"), "28-007")
        try fails(annotated("<< /Type /Annot /Subtype /PrinterMark /Rect [100 100 120 120] >>", "Annot"), "28-017")
    }

    @Test func PagesWithAnnotationsFollowTheTagsTabOrder() throws {
        let note = "<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (A note) >>"
        try fails(annotated(note, "Annot", page: ""), "28-008")
        try fails(annotated(note, "Annot", page: "/Tabs /R"), "28-009")
    }

    @Test func LinksAreTaggedAndDescribed() throws {
        let link = "<< /Type /Annot /Subtype /Link /Rect [100 100 200 120] /Contents (Our web site) /A << /S /URI /URI (https://example.org) >> >>"
        try passes(annotated(link, "Link"))
        try fails(annotated(link, nil), "28-011")
        try fails(annotated(link, "Annot"), "28-011")
        try fails(annotated(link.replacingOccurrences(of: "/Contents (Our web site) ", with: ""), "Link"), "28-012")
    }

    @Test func FormFieldsAreTaggedAndHaveTooltips() throws {
        let field = "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /TU (Your name) /Rect [100 100 200 120] >>"
        let acro = "/AcroForm << /Fields [12 0 R] >>"
        try passes(annotated(field, "Form", catalog: acro))
        try fails(annotated(field, "P", catalog: acro), "28-010")
        let bare = field.replacingOccurrences(of: "/TU (Your name) ", with: "")
        try fails(annotated(bare, "Form", catalog: acro), "28-005")
        // The tag's alternate text describes the field too.
        let withAlt = annotated(bare, "Form", catalog: acro)
        try passes(withAlt.with { $0.elems = [Self.p, "<< /Type /StructElem /S /Form /P 6 0 R /Pg 3 0 R /Alt (Your name) /K << /Type /OBJR /Obj 12 0 R >> >>"] })
        // A Form tag holding more than its field needs a Role attribute.
        try fails(withAlt.with { $0.elems = [Self.p, "<< /Type /StructElem /S /Form /P 6 0 R /Pg 3 0 R /Alt (Your name) /K [0 << /Type /OBJR /Obj 12 0 R >>] >>"] }, "28-010")
    }

    @Test func MediaClipsAndAttachedFilesAreDescribed() throws {
        let clip = "<< /Type /Annot /Subtype /Screen /Rect [100 100 200 200] /Contents (A video) /A << /S /Rendition /R << /S /MR /C << /S /MCD /CT (video/mp4) /Alt [(en) (A video)] >> >> >> >>"
        try passes(annotated(clip, "Annot"))
        try fails(annotated(clip.replacingOccurrences(of: "/CT (video/mp4) ", with: ""), "Annot"), "28-014")
        try fails(annotated(clip.replacingOccurrences(of: "/Alt [(en) (A video)]", with: "/Alt [(en) ()]"), "Annot"), "28-015")
        try fails(annotated("<< /Type /Annot /Subtype /FileAttachment /Rect [100 100 120 120] /Contents (A file) /FS << /Type /Filespec /F (a.txt) /EF << /F 13 0 R >> >> >>", "Annot").with {
            $0.more = ["<< /Type /Annot /Subtype /FileAttachment /StructParent 1 /Rect [100 100 120 120] /Contents (A file) /FS << /Type /Filespec /F (a.txt) /EF << /F 13 0 R >> >> >>", A11yDoc.stream("hello")]
        }, "28-016")
        let embedded = doc {
            $0.catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R /Names << /EmbeddedFiles << /Names [(a.txt) << /Type /Filespec /F (a.txt) /EF << /F 11 0 R >> >>] >> >>"
            $0.more = [A11yDoc.stream("hello")]
        }
        try fails(embedded, "21-001")
        try passes(embedded.with { $0.catalog = embedded.catalog.replacingOccurrences(of: "/F (a.txt) /EF", with: "/F (a.txt) /UF (a.txt) /EF") })
    }

    // MARK: Optional content, XFA, security

    @Test func LayerConfigurationsAreNamedAndManual() throws {
        let catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R "
        try fails(doc { $0.catalog = catalog + "/OCProperties << /OCGs [] /D << /Order [] >> >>" }, "20-002")
        try fails(doc { $0.catalog = catalog + "/OCProperties << /OCGs [] /D << /Name (Default) >> /Configs [<< /Order [] >>] >>" }, "20-001")
        try fails(doc { $0.catalog = catalog + "/OCProperties << /OCGs [] /D << /Name (Default) /AS [] >> >>" }, "20-003")
        try passes(doc { $0.catalog = catalog + "/OCProperties << /OCGs [] /D << /Name (Default) >> >>" })
    }

    @Test func DynamicXfaFails() throws {
        try fails(doc {
            $0.catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R /AcroForm << /Fields [] /XFA [(config) 11 0 R] >>"
            $0.more = [A11yDoc.stream("<config><acrobat><acrobat7><dynamicRender\n>required</dynamicRender\n></acrobat7></acrobat></config>")]
        }, "25-001")
    }

    @Test func ProtectionMustLetScreenReadersRead() throws {
        // Inkvolt's own protection always lets screen readers copy text (P bit 10), even with copying off.
        var noCopy = PdfPermissions.all
        noCopy.copy = false
        let locked = try PdfSecurity.protect(A11yDoc().build(), nil, userPassword: nil, ownerPassword: "owner", permissions: noCopy)
        #expect(try !AccessibilityCheck.run(locked, nil).failedConditions.contains("26-002"))
        // P without bit 10 (copying for accessibility), or no P at all.
        #expect(AccessibilityCheck.permissionsCondition(-1028 & ~512) == "26-002")
        #expect(AccessibilityCheck.permissionsCondition(nil) == "26-001")
        #expect(AccessibilityCheck.permissionsCondition(-1028) == nil)
    }

    // MARK: Fonts

    /// The good document with its text in font F2 (objects from 11 on).
    private func inFont(_ font: [String], _ text: String = "(AB)") -> A11yDoc {
        doc {
            $0.content = "/P << /MCID 0 >> BDC BT /F2 12 Tf 72 700 Td \(text) Tj ET EMC"
            $0.fonts = "/F2 11 0 R"
            $0.more = font
        }
    }

    @Test func FontsMustBeEmbedded() throws {
        try fails(inFont(["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]), "31-009")
        try passes(inFont(A11yDoc.trueType(11)))
        // Text that doesn't show (render mode 3, as under OCR) needs no embedded font.
        try doesNotFail(doc {
            $0.content = "/P << /MCID 0 >> BDC BT 3 Tr /F2 12 Tf 72 700 Td (AB) Tj ET EMC"
            $0.fonts = "/F2 11 0 R"
            $0.more = ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
        }, "31-009")
    }

    @Test func CharactersMapToUnicode() throws {
        let odd = A11yDoc.type3Font.replacingOccurrences(of: "[65 /A /B]", with: "[65 /g123 /B]")
        try fails(doc { $0.font = odd }, "31-027")
        let withToUnicode = doc {
            $0.font = odd.replacingOccurrences(of: "/Resources << >>", with: "/Resources << >> /ToUnicode 11 0 R")
            $0.more = [A11yDoc.stream("1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <0041> <42> <0042> endbfchar")]
        }
        try passes(withToUnicode)
        try fails(withToUnicode.with { $0.more = [A11yDoc.stream("1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <0000> <42> <0042> endbfchar")] }, "31-028")
        try fails(withToUnicode.with { $0.more = [A11yDoc.stream("1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <FEFF> <42> <0042> endbfchar")] }, "31-029")
        try fails(doc {
            $0.font = A11yDoc.type3Font.replacingOccurrences(of: "[65 /A /B]", with: "[65 /.notdef /B]").replacingOccurrences(of: "/A 9 0 R", with: "/.notdef 9 0 R")
        }, "31-030")
    }

    @Test func TrueTypeWidthsAndEncodings() throws {
        try fails(inFont(A11yDoc.trueType(11, widths: "[500 500]")), "31-016")
        try fails(inFont(A11yDoc.trueType(11, fontExtra: "")), "31-019")
        try fails(inFont(A11yDoc.trueType(11, fontExtra: "/Encoding << /Differences [65 /A] >>")), "31-020")
        try fails(inFont(A11yDoc.trueType(11, fontExtra: "/Encoding /StandardEncoding")), "31-021")
        try fails(inFont(A11yDoc.trueType(11, fontExtra: "/Encoding << /BaseEncoding /WinAnsiEncoding /Differences [66 /notaglyphname] >>")), "31-022")
        try fails(inFont(A11yDoc.trueType(11, flags: 4)), "31-024")
    }

    @Test func CompositeFontsAndCMaps() throws {
        try passes(inFont(A11yDoc.composite(11), "<0024>").withToUnicode())
        try fails(inFont(A11yDoc.composite(11, cidExtra: ""), "<0024>").withToUnicode(), "31-005")
        // Glyph 0 is .notdef; a glyph past the program's end isn't in it.
        try fails(inFont(A11yDoc.composite(11), "<0000>").withToUnicode(), "31-030")
        try fails(inFont(A11yDoc.composite(11), "<FFF0>").withToUnicode(), "31-011")
        try fails(inFont(A11yDoc.composite(11, cidExtra: "/CIDToGIDMap /Other"), "<0024>").withToUnicode(), "31-004")
        try fails(inFont(A11yDoc.composite(11, encoding: "/Custom-H"), "<0024>").withToUnicode(), "31-006")
        // A standard CMap of another collection than the font's.
        try fails(inFont(A11yDoc.composite(11, encoding: "/UniJIS-UCS2-H"), "<0024>").withToUnicode(), "31-002")
        // An embedded CMap: its writing mode, the CMaps it uses.
        let cmap = A11yDoc.stream("/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Mine def /WMode 1 def 1 begincodespacerange <0000> <FFFF> endcodespacerange endcmap end end",
                                  "/Type /CMap /CMapName /Mine /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /WMode 0")
        let font = A11yDoc.composite(11, encoding: "15 0 R")
        try fails(inFont(font + [cmap], "<0024>").withToUnicode(), "31-007")
        let uses = A11yDoc.stream("/WMode 0 def", "/Type /CMap /CMapName /Mine /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /UseCMap /Custom-H")
        try fails(inFont(font + [uses], "<0024>").withToUnicode(), "31-008")
        // A subset's CIDSet must list the glyphs the program holds.
        try fails(inFont(A11yDoc.composite(11, descriptorExtra: "/CIDSet 15 0 R") + [A11yDoc.stream("\0")], "<0024>").withToUnicode(), "31-014")
    }

    // MARK: The report

    @Test func FindingsSayWhereAndWhatFixesThem() throws {
        let report = try tags("<< /Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 1 >>").with {
            $0.content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC /Figure << /MCID 1 >> BDC q 100 0 0 50 200 300 cm 0 0 1 1 re f Q EMC"
            $0.parentTree = "0 [10 0 R 11 0 R]"
        }.check()
        #expect(report.failures.count == 1)
        let figure = try #require(report.failures.first)
        #expect(figure.condition == "13-004")
        #expect(figure.page == 0)
        #expect(figure.element == "Figure")
        // The box is the figure's drawing, in page space (top-left origin): x 200-300, y from 792-350 to 792-300.
        #expect((199...201).contains(figure.box.x))
        #expect((441...443).contains(figure.box.y))
        #expect((99...101).contains(figure.box.width))
        #expect((49...51).contains(figure.box.height))
        #expect(figure.fix.contains("alternate text"))
        #expect(report.summary.contains("Fails 1 condition (1 problem)"))
    }

    @Test func TheHtmlReportIsSelfContainedAndAccessible() throws {
        let report = try tags("<< /Type /StructElem /S /Figure /P 6 0 R >>").check()
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 27, 9, 30)
        let html = AccessibilityReportHtml.write(report, "a <b> & c.pdf", checkedAt: try #require(Calendar.current.date(from: c)), done: ["title"])
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<html lang=\"en\">"))
        #expect(html.contains("<title>Accessibility report: a &lt;b&gt; &amp; c.pdf</title>"))
        #expect(html.contains("27 October 2026, 09:30"))
        #expect(html.range(of: "<script", options: .caseInsensitive) == nil)
        #expect(!html.contains("src="))
        #expect(!html.contains("href=\"http"))
        #expect(html.contains("<th scope=\"col\">"))
        #expect(html.contains("<th scope=\"row\">13-004</th>"))
        #expect(html.contains("Checkpoint 13: Graphics"))
        #expect(html.contains("(done)")) // the ticked title check
        #expect(html.contains("(not done yet)"))
        #expect(html.contains("1 of 15 done"))
        #expect(html.contains("prefers-color-scheme: dark"))
        // Headings in order: one h1, then h2s, h3s only under h2s.
        let pattern = try NSRegularExpression(pattern: "<h([1-6])[ >]")
        let levels = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { Int((html as NSString).substring(with: $0.range(at: 1)))! }
        #expect(levels[0] == 1)
        #expect(levels.filter { $0 == 1 }.count == 1)
        for (a, b) in zip(levels, levels.dropFirst()) { #expect(b <= a + 1) }
        // Every condition is in the table, with its result.
        for c in AccessibilityCheck.conditions { #expect(html.contains("<th scope=\"row\">\(InventoryReportFiles.encode(c.id))</th>"), "\(c.id)") }
        #expect(html.contains("Fails (1 problem)"))
    }

    @Test func ABrokenFileIsReportedNotThrownAtRandom() {
        #expect(throws: PdfEditError.self) { try AccessibilityCheck.run(Array("%PDF-1.7\nnot really a pdf".utf8), nil) }
    }

    /// The pane's words for a finding (the Windows app's `A11yItem`, which has no tests of its own there).
    @Test func APaneRowSaysWhereWhatAndHowToFixIt() {
        var f = AccessibilityFinding(condition: "13-004", problem: "This figure has no alternate text.")
        f.page = 2
        f.element = "Figure"
        #expect(f.rowTitle == "13-004 · Page 3 · Figure")
        #expect(f.rowProblem == "This figure has no alternate text.")
        #expect(f.rowFix.hasPrefix("Fix: "))
        #expect(f.spoken.hasPrefix("Condition 13-004, Page 3, Figure. This figure has no alternate text. Fix: "))
        var many = AccessibilityFinding(condition: "01-005", problem: "Content isn't tagged.")
        many.count = 4
        #expect(many.rowTitle == "01-005 · Document")
        #expect(many.rowProblem == "Content isn't tagged. (4 times)")
        many.problem = "4 content items aren't tagged."
        #expect(many.rowProblem == "4 content items aren't tagged.")
    }

    @Test func ThePaneTellsAPassFromAFail() throws {
        let good = try A11yDoc().check()
        #expect(good.paneSummary.hasPrefix("Passes the machine checks of PDF/UA-1. Passes every machine check"))
        #expect(good.failuresTabTitle == "Fails (none)")
        let bad = try tags("<< /Type /StructElem /S /Figure /P 6 0 R >>").check()
        #expect(bad.paneSummary.hasPrefix("Fails 1 condition"))
        #expect(bad.failuresTabTitle == "Fails (1)")
        #expect(AccessibilityReportHtml.fileName(for: "Annual report.pdf") == "Annual report accessibility.html")
    }

    // MARK: Hybrid-reference files

    @Test func TagsKeptInAWordStyleHybridFileAreFound() throws {
        let data = Self.hybridFile()
        // MuPDF alone doesn't see the structure tree root (it is in an object stream only the /XRefStm lists).
        #expect(try Core2Pdf.open(data).catalog.dict("StructTreeRoot") == nil)
        #expect(try Core2Pdf.open(HybridXref.normalize(data)).catalog.dict("StructTreeRoot") != nil)
        let report = try AccessibilityCheck.run(data, nil)
        #expect(report.tagged)
        #expect(!report.failedConditions.contains("01-005"))
        // A file that isn't hybrid comes back as it was.
        let plainFile = A11yDoc().build()
        #expect(HybridXref.normalize(plainFile) == plainFile)
    }

    /// As Word writes them: objects 1-4 and 7-9 in a classic table; the structure tree root (5) and the Document tag (6) in
    /// object stream 10, listed only by the xref stream 11 that the trailer's /XRefStm points at.
    private static func hybridFile() -> [UInt8] {
        let plain = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 5 0 R /MarkInfo << /Marked true >> /Lang (en) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /StructParents 0 /Resources << /Font << /F1 8 0 R >> >> >>",
            A11yDoc.stream("/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC"),
        ]
        let o5 = "<< /Type /StructTreeRoot /K 6 0 R /ParentTree << /Nums [0 [7 0 R]] >> >>"
        let o6 = "<< /Type /StructElem /S /Document /P 5 0 R /K [7 0 R] >>"
        let after = [
            "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>",
            A11yDoc.type3Font,
            A11yDoc.stream("600 0 d0 0 0 600 700 re f"),
        ]
        var out = Array("%PDF-1.5\n".utf8)
        var offsets: [Int: Int] = [:]
        func obj(_ n: Int, _ body: String) {
            offsets[n] = out.count
            out += latin1Bytes("\(n) 0 obj\n\(body)\nendobj\n")
        }
        for (i, body) in plain.enumerated() { obj(i + 1, body) }
        for (i, body) in after.enumerated() { obj(7 + i, body) }
        let header = "5 0 6 \(o5.utf8.count + 1) "
        obj(10, A11yDoc.stream(header + o5 + "\n" + o6, "/Type /ObjStm /N 2 /First \(header.utf8.count)"))
        // The xref stream: 5 and 6 in object stream 10 (type 2).
        let rows: [UInt8] = [2, 0, 0, 0, 10, 0, 2, 0, 0, 0, 10, 1]
        let xrefStmAt = out.count
        offsets[11] = xrefStmAt
        out += Array("11 0 obj\n<< /Type /XRef /Size 12 /Index [5 2] /W [1 4 1] /Root 1 0 R /Length \(rows.count) >>\nstream\n".utf8)
        out += rows
        out += Array("\nendstream\nendobj\n".utf8)
        let xref = out.count
        var table = "xref\n0 12\n0000000000 65535 f \n"
        for n in 1...11 {
            if let at = offsets[n], n != 5, n != 6 {
                table += String(format: "%010d 00000 n \n", at)
            } else {
                table += "0000000000 00000 f \n"
            }
        }
        table += "trailer\n<< /Size 12 /Root 1 0 R /XRefStm \(xrefStmAt) >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }
}

/// Batch's Check Accessibility action: the report beside each file; a file that fails isn't saved.
final class AccessibilityBatchTests {
    private let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-a11y-\(NewIds.hex().prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    private func path(_ parts: String...) -> String { parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) } }

    @Test func EachFileGetsItsReportAndAFailingFileFails() async throws {
        let good = path("good.pdf"), bad = path("bad.pdf")
        try Data(A11yDoc().build()).write(to: URL(fileURLWithPath: good))
        try Data(doc { $0.elems = ["<< /Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 0 >>"] }.build()).write(to: URL(fileURLWithPath: bad))
        let out = path("out")
        let plan = BatchPlan(steps: [.rotate(90), .checkAccessibility], outputFolder: out)

        let summary = try await BatchRunner.run([BatchFile(good), BatchFile(bad)], plan, BatchHost(), progress: nil, cancel: CancelToken())

        let ok = summary.items[0]
        #expect(ok.state == .done, "\(ok.message)")
        #expect(ok.outputs.contains(path("out", "good.pdf")))
        #expect(ok.outputs.contains(path("out", "good accessibility.html")))
        let goodReport = try String(contentsOfFile: path("out", "good accessibility.html"), encoding: .utf8)
        #expect(goodReport.contains("Passes the machine checks."))

        let failed = summary.items[1]
        #expect(failed.state == .failed)
        #expect(failed.message.hasPrefix("Accessibility check: Fails 1 condition"))
        #expect(failed.notes.contains { $0.hasPrefix("13-004") })
        #expect(!FileManager.default.fileExists(atPath: path("out", "bad.pdf"))) // a failing file isn't saved
        #expect(failed.outputs == [path("out", "bad accessibility.html")])
        let badReport = try String(contentsOfFile: path("out", "bad accessibility.html"), encoding: .utf8)
        #expect(badReport.contains("<th scope=\"row\">13-004</th>"))
    }

    @Test func ThePresetNameRoundTrips() throws {
        let json = BatchPresets.write(BatchPreset(name: "Check", steps: [.checkAccessibility]))
        #expect(json.contains("\"checkAccessibility\""))
        let steps = try BatchPresets.read(json).steps
        #expect(steps.count == 1)
        if case .checkAccessibility = steps[0] {} else { Issue.record("read back as \(steps[0])") }
    }
}
