import Foundation
import Testing
@testable import PdfCore

/// Ported from ShapingTests.cs: complex-script shaping, bidi and the embedded fonts of Fill & Sign. Core Text shapes here
/// where Windows uses HarfBuzz, with the same Arial (macOS keeps it in /System/Library/Fonts/Supplemental). Adapted:
/// DevanagariFormsConjuncts shapes with the font Core Text falls back to for Devanagari (Windows: Nirmala UI).
struct ShapingTests {
    static var arial: TrueTypeFont { SystemFonts.get("arial.ttf")! }

    @Test func arabicIsJoined() {
        let joined = TextShaper.shape("مرحبا", Self.arial).glyphs.map(\.glyph)
        let isolated = "مرحبا".map { TextShaper.shape(String($0), Self.arial).glyphs.first?.glyph ?? -1 }
        #expect(joined.count == 5)
        // Written in logical order: the same letters, but in their initial, medial and final forms.
        #expect(isolated != joined)
        #expect(zip(joined, isolated).filter { $0 != $1 }.count >= 3, "most letters take a joined form")
    }

    @Test func hebrewRunsRightToLeft() {
        let line = TextShaper.shape("שלום", Self.arial)
        #expect(line.rtl)
        let xs = line.glyphs.map(\.x) // logical order
        for i in 1..<xs.count { #expect(xs[i] < xs[i - 1], "each next letter sits left of the previous one") }
        #expect(line.glyphs.map(\.text).joined() == "שלום")
    }

    @Test func numbersInRightToLeftTextStayLeftToRight() throws {
        let line = TextShaper.shape("مرحبا 123 بكم", Self.arial)
        func x(_ t: String) throws -> Double { try #require(line.glyphs.first { $0.text == t }).x }
        #expect(try x("1") < x("2") && x("2") < x("3"), "digits read left to right")
        #expect(try line.glyphs[0].x > x("3"), "the first word is rightmost")
        #expect(try line.glyphs[line.glyphs.count - 1].x < x("1"), "the last word is leftmost")
    }

    @Test func latinRunInsideRightToLeftParagraph() {
        let (levels, para) = Bidi.levels("שלום abc!")
        #expect(para == 1)
        #expect(levels.map(Int.init) == [1, 1, 1, 1, 1, 2, 2, 2, 1])
        #expect(Bidi.levels("abc שלום def").paragraph == 0)
        #expect(Bidi.levels("abc שלום def").levels.map(Int.init) == [0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0])
    }

    @Test func devanagariFormsConjuncts() throws {
        let font = try #require(SystemFonts.forCodePoint(0x0915, nil))
        let line = TextShaper.shape("क्ष", font)
        #expect(line.glyphs.count < 3, "ka + virama + ssa become one conjunct glyph")
        #expect(line.glyphs.map(\.text).joined() == "क्ष")
        // The i-matra is drawn before (left of) the consonant it follows in the text; extraction still reads "कि".
        let ki = TextShaper.shape("कि", font).glyphs
        try #require(ki.count == 2)
        #expect(ki[0].x < ki[1].x)
        #expect(ki.map(\.text).joined() == "कि")
    }

    @Test(arguments: ["مرحبا", "שלום עולם", "क्षत्रिय किताब", "Ελληνικά and Русский"])
    func stampTextExtractsAsTyped(_ text: String) throws {
        let data = try TextStamps.put(TestPdf.make(1), nil, 0, RectD(100, 300, 300, 30), .text, text, 14)
        #expect(try Core2Pdf.allText(data).contains(text))
        // Only the glyphs used are embedded: far smaller than the system fonts they came from.
        #expect(data.count < 120_000, "\(data.count) bytes")
    }

    @Test func formFieldAppearanceIsShaped() throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 372 630] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>"])
        let result = try Core2Pdf.withoutNeedAppearances(filled(form, ["name": "مرحبا שלום"]))
        let text = try Core2Pdf.allText(result)
        #expect(text.contains("مرحبا"))
        #expect(text.contains("שלום"))
        #expect(try Core2Pdf.ink(result, 0, RectD(72, 162, 300, 30)) > 0.01, "the value is drawn")
    }
}
