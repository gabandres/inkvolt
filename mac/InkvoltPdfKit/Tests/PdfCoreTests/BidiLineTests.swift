import Foundation
import Testing
@testable import PdfCore

/// Ported from BidiLineTests.cs, whole: mixed-direction Fill & Sign text and form values extract as one line in
/// logical order.
struct BidiLineTests {
    static let mixed = ["Hello مرحبا world", "abc שלום def", "שלום abc!", "مرحبا 123 بكم", "Pay שלום עולם to Ada (now)"]

    @Test(arguments: mixed)
    func stampIsOneLogicalLine(_ text: String) throws {
        let data = try TextStamps.put(TestPdf.make(1), nil, 0, RectD(100, 300, 400, 30), .text, text, 14)
        let lines = try Core2Pdf.lines(data).filter { $0.box.y > 290 && $0.box.y < 330 }
        try #require(lines.count == 1, "\(lines.map(\.text))")
        #expect(lines[0].text == text)
        #expect(!lines[0].text.contains { $0 == "\u{200E}" || $0 == "\u{200F}" })
    }

    @Test(arguments: mixed)
    func formValueIsOneLogicalLine(_ text: String) throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>"])
        let lines = try Core2Pdf.lines(Core2Pdf.withoutNeedAppearances(filled(form, ["name": text])))
        try #require(lines.count == 1, "\(lines.map(\.text))")
        #expect(lines[0].text == text)
    }

    @Test func singleDirectionLinesHaveNoMarks() throws {
        let arial = try #require(SystemFonts.get("arial.ttf"))
        #expect(!TextShaper.shape("Hello world", arial).mixed)
        #expect(!TextShaper.shape("שלום עולם", arial).mixed)
        #expect(TextShaper.shape("Hello שלום", arial).mixed)
        #expect(!TextShaper.shape("Hello שלום", arial, visualOrder: true).mixed)
    }
}
