import Foundation
import Testing
@testable import PdfCore

/// Ported from FlattenTests.cs (same names); the objects are read through MuPDF.
struct FlattenTests {
    private static func subtypes(_ pdf: [UInt8], page: Int = 0) throws -> [String] {
        let doc = try Core2Pdf.open(pdf)
        return doc.page(page).array("Annots")?.elements.filter(\.isDict).map { $0.name("Subtype") ?? "" } ?? []
    }

    @Test func formValuesBecomePageText() throws {
        let form = Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 600 300 630] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (City) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
        ])
        let filled = try FormEditor.setValues(form, nil, ["Name": "Ada Lovelace", "City": "London"])
        #expect(!(try Core2Pdf.allText(filled, annotations: false)).contains("Ada Lovelace"))

        let flat = try Flattener.flatten(filled, nil)
        let text = try Core2Pdf.allText(flat, annotations: false)
        #expect(text.contains("Ada Lovelace"))
        #expect(text.contains("London"))
        #expect(try Self.subtypes(flat).isEmpty)
        #expect(try FormEditor.read(flat, nil).isEmpty)
        let doc = try Core2Pdf.open(flat)
        #expect(doc.catalog["AcroForm"] == nil)
    }

    @Test func valuesWithoutAppearancesGetOneFirst() throws {
        // /V set but no /AP (a producer relying on NeedAppearances).
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V (Grace Hopper) /Rect [72 600 300 630] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>"],
                                 acroExtra: "/NeedAppearances true")
        let flat = try Flattener.flatten(form, nil)
        #expect(try Core2Pdf.allText(flat, annotations: false).contains("Grace Hopper"))
    }

    private static func annotated() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 6 0 R 8 0 R 9 0 R 12 0 R 13 0 R] >>",
            "<< /Type /Annot /Subtype /Square /Rect [100 100 200 150] /F 4 /AP << /N 5 0 R >> /Popup 13 0 R >>",
            Core2Pdf.stream("0 g 0 0 20 10 re f", "/Type /XObject /Subtype /Form /BBox [0 0 20 10] /Matrix [0 1 -1 0 0 0]"),
            "<< /Type /Annot /Subtype /Square /Rect [300 300 400 400] /F 2 /AP << /N 7 0 R >> >>",
            Core2Pdf.stream("0 g 0 0 10 10 re f", "/BBox [0 0 10 10]"),
            "<< /Type /Annot /Subtype /Link /Rect [50 50 60 60] /A << /S /URI /URI (https://example.com/) >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) /Rect [400 600 420 620] /F 4 /AS /On /AP << /N << /On 10 0 R /Off 11 0 R >> >> >>",
            Core2Pdf.stream("0 g 0 0 20 20 re f", "/Type /XObject /Subtype /Form /BBox [0 0 20 20]"),
            Core2Pdf.stream(" ", "/Type /XObject /Subtype /Form /BBox [0 0 20 20]"),
            "<< /Type /Annot /Subtype /Square /Rect [450 100 500 150] /F 4 /CA 0.5 /AP << /N 7 0 R >> >>",
            "<< /Type /Annot /Subtype /Popup /Rect [200 200 300 300] /Parent 4 0 R >>",
        ])
    }

    @Test func appearancesAreMappedOntoTheirRect() throws {
        let pdf = Self.annotated()
        let flat = try Flattener.flatten(pdf, nil, FlattenOptions(formFields: false))
        // The link and the check box stay; the squares and the popup go.
        #expect(try Self.subtypes(flat) == ["Link", "Widget"])

        // The rotated 20x10 appearance fills the 100x50 rect (BBox through /Matrix, fitted to /Rect).
        #expect(try Core2Pdf.ink(flat, 0, RectD(102, 792 - 148, 96, 46)) > 0.97)
        #expect(try Core2Pdf.ink(flat, 0, RectD(205, 792 - 148, 40, 46)) < 0.01)
        // The hidden square was dropped, not drawn.
        #expect(try Core2Pdf.ink(flat, 0, RectD(302, 792 - 398, 96, 96)) < 0.01)
        // Half-transparent black on white: mid gray (the ink threshold counts it as dark only when darker than 128).
        let gray = TestImages.pixelAt(flat, 0, 475, 792 - 125)
        #expect(gray.r >= 100 && gray.r <= 160)

        let all = try Flattener.flatten(pdf, nil)
        #expect(try Self.subtypes(all) == ["Link"])
        // The check box's /AS state (On) is what's drawn.
        #expect(try Core2Pdf.ink(all, 0, RectD(402, 792 - 618, 16, 16)) > 0.97)

        let everything = try Flattener.flatten(pdf, nil, FlattenOptions(links: true))
        #expect(try Self.subtypes(everything).isEmpty)
    }

    @Test func inheritedResourcesAndSharedAnnotsSurvive() throws {
        // Both pages take their font from the page tree and share one /Annots array.
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Annots 7 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Annots 7 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Inherited font) Tj ET"),
            "[8 0 R]",
            "<< /Type /Annot /Subtype /Square /Rect [100 100 200 150] /F 4 /AP << /N 9 0 R >> >>",
            Core2Pdf.stream("0 g 0 0 10 10 re f", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
        ])
        let flat = try Flattener.flatten(pdf, nil)
        for page in 0..<2 {
            #expect(try Core2Pdf.allText(flat, page: page, annotations: false).contains("Inherited font"))
            #expect(try Self.subtypes(flat, page: page).isEmpty)
            #expect(try Core2Pdf.ink(flat, page, RectD(102, 792 - 148, 96, 46)) > 0.97)
        }
    }

    @Test func nothingToFlattenLeavesTheBytes() throws {
        let pdf = TestPdf.make(1)
        #expect(try Flattener.flatten(pdf, nil) == pdf)
    }

    @Test func signedFilesNeedConsent() throws {
        let signed = SignedEditTests.signed()
        let filled = try FormEditor.setValues(signed, nil, ["Name": "Ada"])
        #expect(throws: SignaturesWouldBreak.self) { try Flattener.flatten(filled, nil) }
        let (flat, report) = try SignedEdits.run({ try Flattener.flatten(filled, nil) }, allowRewrite: true)
        #expect(!report.appended)
        #expect(try Core2Pdf.allText(flat, annotations: false).contains("Ada"))
        // The signature field stays a field.
        #expect(try Self.subtypes(flat) == ["Widget"])
        #expect(try FormEditor.read(flat, nil).contains { $0.fieldName == "Approval" })
    }
}
