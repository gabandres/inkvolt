import Foundation
import Testing
@testable import PdfCore

/// Ported from Core2RedactionTests.cs. The PDFs are written by hand (`Core2Pdf`); "every byte inflated" is
/// `RedactionTestPdf.allBytesInflated`, Windows' `AllBytesInflated`.
struct Core2RedactionTests {
    /// Two pages; page 1 says TOPSECRET (uncompressed content) and has a comment and a form field.
    static func secret(rotate: Int = 0) -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [8 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotate) /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> /Annots [9 0 R 8 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 700 Td (Public heading) Tj ET BT /F1 24 Tf 72 600 Td (Code TOPSECRET here) Tj ET"),
            Core2Pdf.stream("BT /F1 24 Tf 72 700 Td (Second page stays) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (secretfield) /V (HIDDENVALUE) /Rect [72 400 300 420] /P 3 0 R >>",
            "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (NOTESECRET) >>",
        ])
    }

    static func area(_ data: [UInt8], _ text: String, page: Int = 0) throws -> RectD {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let t = try engine.text(page)
        let hits = t.find(text, matchCase: true, wholeWord: false)
        try #require(hits.count == 1)
        return t.rects(hits[0].start, hits[0].end).reduce(RectD.zero) { $0.union($1) }
    }

    @Test(arguments: [0, 90])
    func removesEverythingFromRedactedPagesOnly(_ rotate: Int) throws {
        let data = Self.secret(rotate: rotate)
        let area = try Self.area(data, "TOPSECRET").inflate(1)

        let redacted = try Redaction.apply(data, nil, [0: [area]], dpi: 150)

        let engine = try PdfEngine.open(redacted)
        defer { engine.close() }
        #expect(engine.pageCount == 2)
        #expect(!(try engine.text(0).text.contains("TOPSECRET")))
        #expect(try engine.text(0).isEmpty, "a redacted page is a picture")
        #expect(try engine.text(1).text.contains("Second page stays"))
        #expect(abs(engine.page(0).width - (rotate == 90 ? 792 : 612)) <= 0.5)
        #expect(try Core2Pdf.ink(redacted, 0, area.inflate(-2)) > 0.95, "area is black")
        // The rest of the page is still visible as pixels ("Public heading" draws ink where it was).
        let heading = try Self.area(data, "Public heading")
        #expect(try Core2Pdf.ink(data, 0, heading) > 0.05)
        #expect(try Core2Pdf.ink(redacted, 0, heading) > 0.05)

        #expect(try Annotations.read(redacted, nil).isEmpty)
        #expect(try FormEditor.read(redacted, nil).isEmpty)
        let everything = RedactionTestPdf.allBytesInflated(redacted)
        for secret in ["TOPSECRET", "HIDDENVALUE", "NOTESECRET"] { #expect(!everything.contains(secret), "\(secret)") }
    }

    /// A tagged form: the widget on page 1 is also reachable through the structure tree (OBJR), the calculation order
    /// (/CO), the XFA datasets and a popup on page 2; a marked-content stream (MCR /Stm) holds more page-1 text.
    @Test func noSideChannelKeepsRedactedPageContentReachable() throws {
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [8 0 R] /CO [8 0 R] /XFA [(datasets) 10 0 R] >> /StructTreeRoot 11 0 R /MarkInfo << /Marked true >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> /Annots [8 0 R 9 0 R] /StructParents 0 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> /Annots [13 0 R] >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 600 Td (Code TOPSECRET here) Tj ET"),
            Core2Pdf.stream("BT /F1 24 Tf 72 700 Td (Second page stays) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (secretfield) /V (HIDDENVALUE) /Rect [72 400 300 420] /P 3 0 R /StructParent 1 >>",
            "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (NOTESECRET) >>",
            Core2Pdf.stream("<xfa:datasets><data><secretfield>XFASECRET</secretfield></data></xfa:datasets>"),
            "<< /Type /StructTreeRoot /K 12 0 R >>",
            "<< /Type /StructElem /S /Form /Pg 3 0 R /K [<< /Type /OBJR /Obj 8 0 R >> << /Type /MCR /MCID 0 /Stm 14 0 R >>] >>",
            "<< /Type /Annot /Subtype /Popup /Rect [500 600 600 700] /Parent 9 0 R >>",
            Core2Pdf.stream("BT /F1 12 Tf 0 0 Td (STMSECRET) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 100 100]"),
        ])
        let everythingBefore = RedactionTestPdf.allBytesInflated(data)
        for secret in ["HIDDENVALUE", "XFASECRET", "STMSECRET", "NOTESECRET"] { #expect(everythingBefore.contains(secret)) }

        let redacted = try Redaction.apply(data, nil, [0: [RectD(0, 0, 612, 792)]], dpi: 72)

        let everything = RedactionTestPdf.allBytesInflated(redacted)
        for secret in ["TOPSECRET", "HIDDENVALUE", "XFASECRET", "STMSECRET", "NOTESECRET"] { #expect(!everything.contains(secret), "\(secret)") }
        let engine = try PdfEngine.open(redacted)
        defer { engine.close() }
        #expect(try engine.text(1).text.contains("Second page stays"))
    }

    /// Fields with a widget on each page: "ssn" and "agree" are covered by the redaction area on page 1, "keep" is on page
    /// 1 too but outside the area. The ssn widgets have appearances showing the value.
    @Test func redactedFieldIsEmptiedOnEveryPage() throws {
        let ap = "/Type /XObject /Subtype /Form /BBox [0 0 228 20] /Resources << /Font << /Helv 5 0 R >> >>"
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R 9 0 R 12 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Annots [7 0 R 10 0 R 13 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Annots [8 0 R 11 0 R 14 0 R] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /FT /Tx /T (ssn) /V (SSNSECRET) /DA (/Helv 12 Tf 0 g) /Kids [7 0 R 8 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [72 600 300 620] /P 3 0 R /AP << /N 15 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [72 600 300 620] /P 4 0 R /AP << /N 16 0 R >> >>",
            "<< /FT /Btn /T (agree) /V /Yes /Kids [10 0 R 11 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 9 0 R /Rect [72 500 90 518] /P 3 0 R /AS /Yes /AP << /N << /Yes 17 0 R /Off 17 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 9 0 R /Rect [72 500 90 518] /P 4 0 R /AS /Yes /AP << /N << /Yes 17 0 R /Off 17 0 R >> >> >>",
            "<< /FT /Tx /T (keep) /V (KEEPVALUE) /DA (/Helv 12 Tf 0 g) /Kids [13 0 R 14 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 12 0 R /Rect [72 300 300 320] /P 3 0 R >>",
            "<< /Type /Annot /Subtype /Widget /Parent 12 0 R /Rect [72 300 300 320] /P 4 0 R >>",
            Core2Pdf.stream("BT /Helv 12 Tf 2 5 Td (SSNSECRET) Tj ET", ap),
            Core2Pdf.stream("BT /Helv 12 Tf 2 5 Td (SSNSECRET) Tj ET", ap),
            Core2Pdf.stream("0 0 18 18 re f", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
        ])
        #expect(try Core2Pdf.allText(data, page: 1).contains("SSNSECRET"))

        // Page space: ssn at y 172–192, agree at 274–292, keep at 472–492.
        let redacted = try Redaction.apply(data, nil, [0: [RectD(60, 160, 260, 140)]], dpi: 72)

        #expect(!RedactionTestPdf.allBytesInflated(redacted).contains("SSNSECRET"))
        #expect(!(try Core2Pdf.allText(redacted, page: 1).contains("SSNSECRET")))
        let fields = try FormEditor.read(redacted, nil)
        #expect(fields.allSatisfy { $0.pageIndex == 1 })
        #expect(fields.first { $0.fieldName == "ssn" }?.value == "")
        #expect(fields.first { $0.fieldName == "agree" }?.value == "Off")
        #expect(fields.first { $0.fieldName == "keep" }?.value == "KEEPVALUE") // not under an area: unchanged
    }

    /// An XFA form whose field is on page 2; page 1 has a link and a comment, and an associated file (/AF).
    static func xfaWithExtras() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [7 0 R] /XFA [(datasets) 8 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 6 0 R >> >> /Annots [9 0 R 10 0 R] /AF [11 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [7 0 R] /Resources << >> >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 600 Td (Code TOPSECRET here) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Ada) /Rect [72 400 300 420] /P 4 0 R >>",
            Core2Pdf.stream("<xfa:datasets><data><name>Ada</name></data></xfa:datasets>"),
            "<< /Type /Annot /Subtype /Link /Rect [72 100 200 120] /A << /S /URI /URI (https://example.com/) >> >>",
            "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (Note) >>",
            "<< /Type /Filespec /F (source.txt) /UF (source.txt) /AFRelationship /Source /EF << /F 12 0 R >> >>",
            Core2Pdf.stream("AFSECRET source of the page", "/Type /EmbeddedFile"),
        ])
    }

    @Test func redactingAPageWithoutFieldsKeepsTheXfaFormButDropsItsAssociatedFiles() throws {
        let data = Self.xfaWithExtras()
        let redacted = try Redaction.apply(data, nil, [0: [RectD(60, 170, 200, 40)]], dpi: 72)
        let everything = RedactionTestPdf.allBytesInflated(redacted)
        #expect(!everything.contains("TOPSECRET"))
        #expect(!everything.contains("AFSECRET"))
        #expect(everything.contains("<xfa:datasets>")) // only a link and a comment went: the form is as it was

        // A redacted widget takes the XFA copy of the values with it.
        let fieldPage = try Redaction.apply(data, nil, [1: [RectD(0, 0, 10, 10)]], dpi: 72)
        #expect(!RedactionTestPdf.allBytesInflated(fieldPage).contains("<xfa:datasets>"))
    }

    @Test func nothingToRedactReturnsTheSameBytes() throws {
        let data = Self.secret()
        #expect(try Redaction.apply(data, nil, [:]) == data)
    }
}

/// PDFs written with Latin-1 bytes (binary stream data such as deflated text and pictures), and reading every byte of
/// one (the Windows tests' `Core2Pdf.Build` with binary streams, and `AllBytesInflated`).
enum RedactionTestPdf {
    /// Serializes objects 1…n, each as Latin-1 (one byte per character), with a classic xref table.
    static func build(_ objects: [String], trailerExtra: String = "") -> [UInt8] {
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += latin1Bytes("\(i + 1) 0 obj\n\(o)\nendobj\n")
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R \(trailerExtra) >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    /// A stream object whose content is Latin-1 (its /Length in bytes).
    static func stream(_ content: String, _ dict: String = "") -> String {
        "<< \(dict) /Length \(content.unicodeScalars.count) >>\nstream\n\(content)\nendstream"
    }

    /// Text deflated as a zlib stream, as Latin-1 characters.
    static func deflated(_ text: String) -> String { latin1String(Deflate.zlib(latin1Bytes(text))) }

    /// The file as text with every Flate stream inflated, to look for leftovers anywhere.
    static func allBytesInflated(_ pdf: [UInt8]) -> String { RedactionCheck.rawText(pdf, nil) }
}
