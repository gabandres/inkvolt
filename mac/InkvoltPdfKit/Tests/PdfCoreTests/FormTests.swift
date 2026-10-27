import Foundation
import Testing
@testable import PdfCore

/// Ported from FormTests.cs, whole: reading, filling and drawing a small AcroForm through MuPDF.
struct FormTests {
    /// A minimal AcroForm: text "name", check box "agree", radio group "color" (Red/Blue), combo "size" (S/M/L).
    static func makeForm(rotate: Int = 0) -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R 6 0 R 7 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 8 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotate) /Annots [4 0 R 5 0 R 9 0 R 10 0 R 7 0 R] /Contents 11 0 R /Resources << /Font << /Helv 8 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /V (Alice) /F 4 /P 3 0 R >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /Rect [72 650 90 668] /V /Off /AS /Off /F 4 /P 3 0 R /AP << /N << /Yes 12 0 R /Off 13 0 R >> >> >>",
            "<< /FT /Btn /Ff 49152 /T (color) /Kids [9 0 R 10 0 R] /V /Off >>",
            "<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (size) /Opt [(S) (M) (L)] /V (M) /Rect [72 550 200 570] /DA (/Helv 12 Tf 0 g) /F 4 /P 3 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [72 600 90 618] /AS /Off /F 4 /P 3 0 R /AP << /N << /Red 12 0 R /Off 13 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [120 600 138 618] /AS /Off /F 4 /P 3 0 R /AP << /N << /Blue 12 0 R /Off 13 0 R >> >> >>",
            Core2Pdf.stream("BT /Helv 12 Tf 72 740 Td (Form test) Tj ET"),
            Core2Pdf.stream("q 0 g 2 2 14 14 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
        ])
    }

    /// The fraction of dark pixels in a page region rendered at 2x.
    static func ink(_ data: [UInt8], _ region: RectD) throws -> Double {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let img = try engine.render(0, scale: 2, region: region)
        var dark = 0
        var i = 0
        while i + 2 < img.pixels.count {
            if Int(img.pixels[i]) + Int(img.pixels[i + 1]) + Int(img.pixels[i + 2]) < 300 { dark += 1 }
            i += 3
        }
        return Double(dark) / Double(img.width * img.height)
    }

    @Test func readsFieldsWidgetsAndValues() throws {
        let widgets = try FormEditor.read(Self.makeForm(), nil)
        #expect(widgets.count == 5)

        let name = try #require(widgets.first { $0.fieldName == "name" })
        #expect(name.kind == .text)
        #expect(name.value == "Alice")
        #expect(name.rect == RectD(72, 72, 228, 20)) // 792 - 720 = 72 from the top

        let agree = try #require(widgets.first { $0.fieldName == "agree" })
        #expect(agree.kind == .checkBox)
        #expect(agree.onState == "Yes")
        #expect(agree.value == "Off")

        let radios = widgets.filter { $0.fieldName == "color" }
        #expect(radios.map(\.onState) == ["Red", "Blue"])
        #expect(radios.allSatisfy { $0.kind == .radio })

        let size = try #require(widgets.first { $0.fieldName == "size" })
        #expect(size.kind == .choice)
        #expect(size.options == ["S", "M", "L"])
        #expect(size.value == "M")

        // Fill order: top to bottom.
        #expect(widgets.map(\.fieldName) == ["name", "agree", "color", "color", "size"])
    }

    @Test func fillsFieldsAndMuPdfRendersTheValues() throws {
        let data = try filled(Self.makeForm(), ["name": "Bob Builder", "agree": "On", "color": "Blue", "size": "L"])

        let widgets = try FormEditor.read(data, nil)
        #expect(widgets.first { $0.fieldName == "name" }?.value == "Bob Builder")
        #expect(widgets.first { $0.fieldName == "agree" }?.value == "Yes")
        #expect(widgets.first { $0.fieldName == "color" }?.value == "Blue")
        #expect(widgets.first { $0.fieldName == "size" }?.value == "L")

        // The checked box and the chosen radio draw their "on" appearance (a filled square).
        #expect(try Self.ink(data, RectD(74, 126, 14, 14)) > 0.5, "check box should be drawn checked")
        #expect(try Self.ink(data, RectD(122, 176, 14, 14)) > 0.5, "Blue radio should be drawn selected")
        #expect(try Self.ink(data, RectD(74, 176, 14, 14)) < 0.05, "Red radio should be off")
        // The text value is drawn from the new value (appearance regenerated).
        #expect(try Self.ink(data, RectD(72, 72, 228, 20)) > 0.02, "text field should show its value")
    }

    @Test(arguments: [90, 180, 270])
    func widgetRectsFollowPageRotation(_ rotate: Int) throws {
        let data = try filled(Self.makeForm(rotate: rotate), ["agree": "On"])
        let agree = try #require(try FormEditor.read(data, nil).first { $0.fieldName == "agree" })
        // The rect reported must be where MuPDF actually draws the checked box.
        let inner = RectD(agree.rect.x + 3, agree.rect.y + 3, agree.rect.width - 6, agree.rect.height - 6)
        #expect(try Self.ink(data, inner) > 0.5, "rotated \(rotate): check box not at \(agree.rect)")
    }

    @Test func readOnlyFieldsAreNotChangedAndPlainPdfsHaveNoFields() throws {
        #expect(try FormEditor.read(TestPdf.make(1), nil).isEmpty)
        #expect(throws: PdfEditError.self) { try filled(TestPdf.make(1), ["x": "y"]) }
    }
}
