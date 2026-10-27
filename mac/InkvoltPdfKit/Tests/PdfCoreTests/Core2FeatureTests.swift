import Foundation
import Testing
@testable import PdfCore

/// Ported from Core2FeatureTests.cs: its comment parts (highlights, strike-outs, notes, replies, edits and deletes; the
/// Fill & Sign stamp in the comments list). The reply is made with MuPDF's objects where Windows uses PDFsharp's, and the
/// form of ListsStampsAndSkipsWidgets is written by hand (FormTests.MakeForm comes with D5). The other parts of the file
/// (attachments, page labels and the rest) come with their steps.
struct Core2FeatureTests {
    static func lineRects(_ data: [UInt8], _ word: String, page: Int = 0) throws -> [RectD] {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let text = try engine.text(page)
        let hit = try #require(text.find(word, matchCase: true, wholeWord: false).first)
        return text.rects(hit.start, hit.end)
    }

    @Test(arguments: [0, 90])
    func highlightsNotesRepliesAndDeletes(_ rotation: Int) throws {
        let doc = rotation == 0 ? TestPdf.make(1) : try PageEditor.rotate(TestPdf.make(1), nil, [0], rotation)
        let rects = try Self.lineRects(doc, "quick brown")
        let id = Annotations.newId()
        var data = try Annotations.addTextMarkup(doc, nil, 0, .highlight, rects, .yellow, note: "check this", author: "Gabriel", id: id)
        data = try Annotations.addTextMarkup(data, nil, 0, .strikeOut, Self.lineRects(data, "lazy"), .red, note: nil, author: "Gabriel")
        data = try Annotations.addNote(data, nil, 0, 400, 50, "A sticky note", author: "Ana")

        let list = try Annotations.read(data, nil)
        #expect(list.count == 3)
        let hl = try #require(list.first { $0.id == id })
        #expect(hl.kind == .highlight)
        #expect(hl.contents == "check this")
        #expect(hl.author == "Gabriel")
        #expect(hl.modified != nil)
        try #require(hl.quadRects.count == 1)
        let q = hl.quadRects[0]
        #expect(abs(rects[0].x - q.x) <= 0.5 && abs(rects[0].y - q.y) <= 0.5 && abs(rects[0].width - q.width) <= 0.5, "\(q) vs \(rects[0])")
        let note = try #require(list.first { $0.kind == .text })
        let r = note.rect
        #expect([r.x, r.y, r.width, r.height].map { $0.rounded() } == [400, 50, 20, 20], "\(r)")

        // Drawn: the highlight tints the words yellow, the text stays readable; the note icon is drawn.
        do {
            let engine = try PdfEngine.open(data)
            defer { engine.close() }
            let img = try engine.render(0, scale: 1, region: rects[0])
            var yellow = 0
            var i = 0
            while i + 2 < img.pixels.count {
                // RGB (Windows reads BGR): little blue, much green and red.
                if img.pixels[i + 2] < 120 && img.pixels[i + 1] > 150 && img.pixels[i] > 200 { yellow += 1 }
                i += 3
            }
            #expect(yellow > img.width * img.height / 4, "the highlight is yellow")
            #expect(try engine.text(0, cache: false).text.contains("quick brown"))
        }
        #expect(try Core2Pdf.ink(data, 0, RectD(402, 52, 16, 16)) > 0.1)

        // A reply to the highlight, then edit and delete.
        let noteId = note.id
        data = try PageEditor.edit(data, nil) { d in
            let annots = d.page(0).array("Annots")?.elements ?? []
            let target = try #require(annots.first { $0.text("NM") == noteId })
            let highlight = try #require(annots.first { $0.text("NM") == id })
            target.set("IRT", highlight)
        }
        #expect(try Annotations.read(data, nil).first { $0.id == noteId }?.replyTo == id)
        data = try Annotations.setContents(data, nil, id, "edited")
        #expect(try Annotations.read(data, nil).first { $0.id == id }?.contents == "edited")
        data = try Annotations.delete(data, nil, id)
        let left = try Annotations.read(data, nil)
        try #require(left.count == 1) // the reply went with it
        #expect(left[0].kind == .strikeOut)
        #expect(throws: PdfEditError.self) { try Annotations.delete(data, nil, id) }
    }

    @Test func listsStampsAndSkipsWidgets() throws {
        let form = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] /Resources << /Font << /Helv 5 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /V (Alice) /F 4 /P 3 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let data = try TextStamps.put(form, nil, 0, RectD(300, 300, 100, 20), .text, "Hi", 12)
        let all = try Annotations.read(data, nil)
        try #require(all.count == 1)
        #expect(all[0].isInkvoltPdfStamp)
        #expect(all[0].kind == .freeText)
        // The form's own Helvetica is shared with the stamp.
        #expect(try Core2Pdf.lastAnnot(data).dict("AP")?.dict("N")?.dict("Resources")?.dict("Font")?["Helv"]?.num == 5)
    }
}
