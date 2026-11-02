import Foundation
import Testing
@testable import PdfCore

/// Ported from Core2FeatureTests.cs: its comment parts (highlights, strike-outs, notes, replies, edits and deletes; the
/// Fill & Sign stamp in the comments list). The reply is made with MuPDF's objects where Windows uses PDFsharp's, and the
/// form of ListsStampsAndSkipsWidgets is written by hand (FormTests.MakeForm comes with D5). Attachments and layers came
/// with E9 (below); page labels and the rest come with their steps.
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

// ---------------- Attachments and layers (E9) ----------------
// Ported from Core2FeatureTests.cs with the same names. Adapted: the file-attachment annotation is written by hand where
// Windows builds it with PDFsharp; the Windows path "C:\temp\notes.txt" keeps its backslashes (only the name is kept, as
// there). HostilePageLabelsAndCyclicTreesStayCheap waits for the page labels' reader (DocumentFeatures).

extension Core2FeatureTests {
    @Test func addsListsExtractsAndRemovesAttachments() throws {
        let bytes = Array(String(repeating: "hello attachment ", count: 50).utf8)
        var data = try Attachments.add(TestPdf.make(1), nil, #"C:\temp\notes.txt"#, bytes, description: "Meeting notes")
        data = try Attachments.add(data, nil, "notes.txt", [1, 2, 3])
        let list = try Attachments.list(data, nil)
        #expect(list.count == 2)
        let first = try #require(list.first { $0.fileName == "notes.txt" })
        #expect(first.description == "Meeting notes")
        #expect(first.size == bytes.count)
        #expect(first.source == .document)
        #expect(first.pageIndex == -1)
        #expect(first.mimeType == "text/plain")
        #expect(first.modified != nil)
        #expect(try Attachments.extract(data, nil, first.key) == bytes)
        let second = try #require(list.first { $0.fileName == "notes (2).txt" })
        #expect(try Attachments.extract(data, nil, second.key) == [1, 2, 3])

        data = try Attachments.remove(data, nil, first.key)
        #expect(try Attachments.list(data, nil).map(\.fileName) == ["notes (2).txt"])
        #expect(try Attachments.list(TestPdf.make(1), nil).isEmpty)
    }

    @Test func listsFileAttachmentAnnotations() throws {
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            "<< /Type /Annot /Subtype /FileAttachment /Rect [10 10 30 30] /NM (att1) /FS << /Type /Filespec /F (data.bin) /EF << /F 6 0 R >> >> >>",
            Core2Pdf.stream("\u{9}\u{8}\u{7}\u{6}"),
        ])
        let a = try #require(try Attachments.list(data, nil).first)
        #expect(try Attachments.list(data, nil).count == 1)
        #expect(a.source == .annotation)
        #expect(a.pageIndex == 1)
        #expect(a.fileName == "data.bin")
        #expect(a.size == 4)
        #expect(try Attachments.extract(data, nil, a.key) == [9, 8, 7, 6])
        #expect(try Attachments.list(Attachments.remove(data, nil, a.key), nil).isEmpty)
    }

    static func layeredPdf() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /ON [5 0 R] /OFF [6 0 R] /Locked [6 0 R] /Order [[(Group) 5 0 R] 6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Properties << /L1 5 0 R /L2 6 0 R >> >> >>",
            Core2Pdf.stream("/OC /L1 BDC 0 0 1 rg 100 600 100 100 re f EMC /OC /L2 BDC 1 0 0 rg 300 600 100 100 re f EMC"),
            "<< /Type /OCG /Name (Blue) >>",
            "<< /Type /OCG /Name (Red) >>",
        ])
    }

    @Test func listsLayersAndRendersChosenVisibility() throws {
        let data = Self.layeredPdf()
        let layers = try Layers.list(data, nil)
        #expect(layers == [LayerInfo(id: 5, name: "Blue", defaultVisible: true, locked: false), LayerInfo(id: 6, name: "Red", defaultVisible: false, locked: true)])
        let order = try Layers.readOrder(data, nil)
        try #require(order.count == 2)
        #expect(order[0].label == "Group")
        #expect(order[0].children.map(\.layerId) == [5])
        #expect(order[1].layerId == 6)

        let blue = RectD(100, 92, 100, 100), red = RectD(300, 92, 100, 100)
        #expect(try Core2Pdf.ink(data, 0, blue) > 0.9)
        #expect(try Core2Pdf.ink(data, 0, red) < 0.01)

        let swapped = try Layers.withVisibility(data, nil, [5: false, 6: true])
        #expect(try Core2Pdf.ink(swapped, 0, blue) < 0.01)
        #expect(try Core2Pdf.ink(swapped, 0, red) > 0.9)

        let saved = try Layers.setDefaultVisibility(data, nil, [6: true])
        #expect(try Layers.list(saved, nil).allSatisfy(\.defaultVisible))
        #expect(try Layers.list(TestPdf.make(1), nil).isEmpty)
    }

    /// A Mac addition: a layered document protected with an open password is shown with its layers chosen from a copy
    /// that opens without the password (written in memory only), and its layers are read with the password.
    @Test func aProtectedDocumentsLayersAreShownFromAnOpenCopy() throws {
        let protected = try PdfSecurity.protect(Self.layeredPdf(), nil, userPassword: "open", ownerPassword: "owner")
        #expect(try Layers.list(protected, "open").count == 2)
        let swapped = try Layers.withVisibility(protected, "open", [5: false, 6: true])
        #expect(try Core2Pdf.ink(swapped, 0, RectD(300, 92, 100, 100)) > 0.9)
    }

    /// A Mac addition: an /Order that holds itself, over and over, is read in bounded time (the budget, as on Windows).
    @Test func aHostileLayerOrderStaysCheap() throws {
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /Order 6 0 R >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< >>",
            "<< /Type /OCG /Name (Only) >>",
            "[5 0 R 6 0 R 6 0 R 6 0 R 6 0 R 6 0 R 6 0 R 6 0 R 6 0 R]",
        ])
        let started = Date()
        _ = try Layers.readOrder(data, nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
