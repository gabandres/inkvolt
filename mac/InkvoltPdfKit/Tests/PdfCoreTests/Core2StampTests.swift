import Foundation
import Testing
@testable import PdfCore

/// Ported from Core2StampTests.cs. Adapted: StampsShareTheirFontObjects counts the Helvetica objects the stamps add (the
/// Mac's hand-written test page already has one, which PDFsharp's page doesn't).
struct Core2StampTests {
    @Test(arguments: [0, 90])
    func nonLatinStampTextRendersWithAnEmbeddedFont(_ rotation: Int) throws {
        let page = rotation == 0 ? TestPdf.make(1) : try PageEditor.rotate(TestPdf.make(1), nil, [0], rotation)
        let data = try TextStamps.put(page, nil, 0, RectD(100, 300, 300, 40), .text, "Привет мир\n日本語テキスト", 14)
        let text = try Core2Pdf.allText(data)
        #expect(text.contains("Привет мир"))
        #expect(text.contains("日本語テキスト"))
        #expect(try TextStamps.read(data, nil).first?.text == "Привет мир\n日本語テキスト")
        let line = try #require(try Core2Pdf.lines(data).first { $0.text.contains("Привет") })
        #expect(line.box.width > line.box.height * 2, "stamp text should be upright: \(line.box)")
        #expect(line.box.x >= 95 && line.box.x <= 120, "\(line.box)")
    }

    @Test func stampsShareTheirFontObjects() throws {
        var data = TestPdf.make(1)
        let before = Self.count(latin1(data), "/BaseFont", "/Helvetica")
        for i in 0..<3 { data = try TextStamps.put(data, nil, 0, RectD(100, 100 + 40 * Double(i), 200, 20), .text, "Line \(i)", 12) }
        data = try TextStamps.put(data, nil, 0, RectD(100, 300, 14, 14), .check, "", 12)
        data = try TextStamps.put(data, nil, 0, RectD(130, 300, 14, 14), .cross, "", 12)
        let raw = latin1(data)
        #expect(Self.count(raw, "/BaseFont", "/Helvetica") - before == 1)
        #expect(Self.count(raw, "/BaseFont", "/ZapfDingbats") == 1)
        #expect(try TextStamps.read(data, nil).count == 5)
        #expect(try Core2Pdf.allText(data).contains("Line 2"))
    }

    private static func count(_ s: String, _ key: String, _ value: String) -> Int {
        let pattern = NSRegularExpression.escapedPattern(for: key) + #"\s*"# + NSRegularExpression.escapedPattern(for: value) + #"(?![\w-])"#
        let re = try! NSRegularExpression(pattern: pattern)
        return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }
}
