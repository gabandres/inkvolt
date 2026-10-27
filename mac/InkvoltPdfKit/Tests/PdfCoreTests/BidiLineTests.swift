import Foundation
import Testing
@testable import PdfCore

/// Ported from BidiLineTests.cs: mixed-direction Fill & Sign text extracts as one line in logical order. Left out:
/// FormValueIsOneLogicalLine (form appearances come with D5).
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

    @Test func singleDirectionLinesHaveNoMarks() throws {
        let arial = try #require(SystemFonts.get("arial.ttf"))
        #expect(!TextShaper.shape("Hello world", arial).mixed)
        #expect(!TextShaper.shape("שלום עולם", arial).mixed)
        #expect(TextShaper.shape("Hello שלום", arial).mixed)
        #expect(!TextShaper.shape("Hello שלום", arial, visualOrder: true).mixed)
    }
}
