import Foundation
import Testing
@testable import PdfCore

/// Ported from TextStampTests.cs, whole; the text drawn by annotations is read with MuPDF's structured text with the
/// annotations drawn in (`Core2Pdf.lines`), as Windows reads it through MuPDFCore.
struct TextStampTests {
    @Test func addsReadsEditsAndRemovesText() throws {
        let doc = TestPdf.make(2)
        let withText = try TextStamps.put(doc, nil, 1, RectD(100, 300, 200, 20), .text, "Juan Pérez", 12)

        let stamps = try TextStamps.read(withText, nil)
        try #require(stamps.count == 1)
        let s = stamps[0]
        #expect(s.pageIndex == 1)
        #expect(s.text == "Juan Pérez")
        #expect(s.fontSize == 12)
        #expect(abs(s.rect.x - 100) <= 0.5)
        #expect(abs(s.rect.y - 300) <= 0.5)

        // MuPDF draws it, accents included.
        #expect(try Core2Pdf.allText(withText, page: 1).contains("Juan Pérez"))

        let edited = try TextStamps.put(withText, nil, 1, s.rect, .text, "María", 14, replaceId: s.id)
        let e = try TextStamps.read(edited, nil)
        try #require(e.count == 1)
        #expect(e[0].text == "María")
        #expect(e[0].id == s.id)

        #expect(try TextStamps.read(TextStamps.remove(edited, nil, e[0].id), nil).isEmpty)
    }

    @Test func addsCheckMarks() throws {
        let data = try TextStamps.put(TestPdf.make(1), nil, 0, RectD(300, 400, 14, 14), .check, "", 12)
        let s = try TextStamps.read(data, nil)
        try #require(s.count == 1)
        #expect(s[0].kind == .check)
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let img = try engine.render(0, scale: 3, region: RectD(300, 400, 14, 14))
        var dark = 0
        var i = 0
        while i + 2 < img.pixels.count {
            if Int(img.pixels[i]) + Int(img.pixels[i + 1]) + Int(img.pixels[i + 2]) < 300 { dark += 1 }
            i += 3
        }
        #expect(Double(dark) / Double(img.width * img.height) > 0.1, "the check mark is drawn")
    }

    @Test(arguments: [0, 90, 180, 270])
    func textIsUprightAndInPlaceOnRotatedPages(_ rotation: Int) throws {
        let page = rotation == 0 ? TestPdf.make(1) : try PageEditor.rotate(TestPdf.make(1), nil, [0], rotation)
        let rect = RectD(150, 250, 260, 20)
        let data = try TextStamps.put(page, nil, 0, rect, .text, "UPRIGHT STAMP TEXT", 14)

        #expect(abs(try TextStamps.read(data, nil)[0].rect.x - rect.x) <= 0.5)
        let line = try #require(try Core2Pdf.lines(data).first { $0.text.contains("UPRIGHT") })
        #expect(line.text.contains("UPRIGHT STAMP TEXT"))
        let box = line.box
        #expect(box.width > box.height * 3, "rotation \(rotation): text runs sideways (\(box))")
        #expect(box.x >= rect.x - 2 && box.x <= rect.x + 20, "\(box)")
        #expect(box.y >= rect.y - 4 && box.y <= rect.bottom, "\(box)")
    }
}
