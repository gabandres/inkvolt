import Foundation
import Testing
@testable import PdfCore

/// Ported from RubberStampTests.cs; the PDFsharp object checks read the same objects through MuPDF (`PObj`). Adapted:
/// BuiltInSetAndDynamicApproval writes the date as a Foundation locale does (German, short date and time) where .NET uses
/// the invariant culture's "g"; the colors compared after reading are rounded to four decimals (MuPDF keeps reals as
/// 32-bit floats). Left out: FlattenedStampsBecomePageContent (flattening comes later).
struct RubberStampTests {
    @Test func builtInSetAndDynamicApproval() {
        #expect(RubberStamps.builtIn.map(\.title) == ["APPROVED", "REJECTED", "DRAFT", "FINAL", "CONFIDENTIAL", "FOR COMMENT", "RECEIVED"])
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 3, 9, 14, 5)
        let when = Calendar(identifier: .gregorian).date(from: c)!
        let by = RubberStamps.approvedBy("Ada Lovelace", when, locale: Locale(identifier: "de_DE"))
        #expect(by.detail?.hasPrefix("By Ada Lovelace on 09.03.26") == true, "\(by.detail ?? "")")
        #expect(by.detail?.hasSuffix("14:05") == true)
        // Wider titles make wider stamps; a detail line makes it taller.
        let draft = RubberStamps.naturalSize(RubberStamps.builtIn[2])
        let confidential = RubberStamps.naturalSize(RubberStamps.builtIn[4])
        let approved = RubberStamps.naturalSize(by)
        #expect(confidential.width > draft.width * 1.5)
        #expect(approved.height > draft.height)
    }

    @Test func aStampAnnotationWithItsOwnAppearance() throws {
        let design = RubberStamps.builtIn[0]
        let (w, h) = RubberStamps.naturalSize(design)
        let pdf = try RubberStamps.put(TestPdf.make(1), nil, 0, RectD(300, 500, w, h), design, author: "Tester")

        let a = try Core2Pdf.lastAnnot(pdf)
        #expect(a.name("Subtype") == "Stamp")
        #expect(a.name("Name") == "Approved")
        #expect(a.text("Subj") == "Approved")
        let bbox = try #require(a.dict("AP")?.dict("N")?.array("BBox"))
        #expect(abs(bbox.num(2) - w) <= 1)
        #expect(abs(bbox.num(3) - h) <= 1)

        // What any viewer draws: the title, in green, inside the rectangle.
        #expect(try Core2Pdf.allText(pdf).contains("APPROVED"))
        #expect(try !Core2Pdf.allText(pdf, annotations: false).contains("APPROVED"))
        let frame = TestImages.pixelAt(pdf, 0, 300 + 2, 500 + h / 2)
        #expect(frame.g > frame.r + 40 && frame.g > frame.b + 40, "frame color \(frame)")

        let placed = try SignatureStamps.read(pdf, nil)
        try #require(placed.count == 1)
        #expect(placed[0].kind == .stamp)
        let comments = try Annotations.read(pdf, nil)
        try #require(comments.count == 1)
        #expect(comments[0].kind == .stamp)
        #expect(comments[0].subject == "Approved")
        #expect(comments[0].author == "Tester")
    }

    @Test func resizingRedrawsTheSameDesign() throws {
        let by = RubberStamps.approvedBy("Zoë Ñúñez", Date())
        let (w, h) = RubberStamps.naturalSize(by)
        let pdf = try RubberStamps.put(TestPdf.make(2), nil, 0, RectD(100, 100, w, h), by, author: "Zoë")
        let id = try #require(try SignatureStamps.read(pdf, nil).first).id

        let moved = try RubberStamps.move(pdf, nil, id, 1, RectD(50, 600, w * 2, h * 2))
        let after = try SignatureStamps.read(moved, nil)
        try #require(after.count == 1)
        #expect(after[0].id == id && after[0].pageIndex == 1)
        #expect(abs(after[0].rect.width - w * 2) <= 1)
        let doc = try Core2Pdf.open(moved)
        let annots = try #require(doc.page(1).array("Annots")?.elements)
        try #require(annots.count == 1)
        #expect(RubberStamps.designOf(annots[0]) == by)
        #expect(annots[0].text("T") == "Zoë")
        let text = try Core2Pdf.allText(moved, page: 1)
        #expect(text.contains("APPROVED"))
        #expect(text.contains("Zoë Ñúñez"))
        #expect(try !Annotations.read(moved, nil).contains { $0.pageIndex == 0 })
    }

    @Test func movingKeepsTheAnnotationItself() throws {
        let design = RubberStamps.builtIn[0]
        let (w, h) = RubberStamps.naturalSize(design)
        let image = StampImage(4, 4, Array([[UInt8]](repeating: [30, 30, 200], count: 16).joined()), nil)
        var pdf = try RubberStamps.put(TestPdf.make(2), nil, 0, RectD(100, 100, w, h), design, author: "Tester")
        pdf = try SignatureStamps.putImage(pdf, nil, 0, RectD(300, 300, 40, 40), image, label: "logo.png")
        let ids = try SignatureStamps.read(pdf, nil).map(\.id)

        // Another app's reply to each, a see-through look and a tag: what a move used to lose.
        pdf = try PageEditor.edit(pdf, nil) { doc in
            let page = doc.page(0)
            let annots = doc.annots(page)
            for stamp in annots.elements {
                stamp.set("CA", doc.real(0.5))
                stamp.set("StructParent", doc.int(7))
                let reply = doc.add(doc.dict([
                    ("Type", doc.name("Annot")), ("Subtype", doc.name("Text")), ("Rect", doc.reals(0, 0, 20, 20)),
                    ("Contents", doc.text("Agreed")), ("IRT", stamp),
                ]))
                annots.append(reply)
            }
        }

        var moved = try RubberStamps.move(pdf, nil, ids[0], 0, RectD(50, 600, w * 2, h * 2))
        moved = try RubberStamps.move(moved, nil, ids[1], 0, RectD(400, 500, 80, 80))
        let after = try Core2Pdf.open(moved)
        let list = try #require(after.page(0).array("Annots")?.elements)
        #expect(list.count == 4)
        for i in 0..<2 {
            // The same place among the page's annotations, the same id, its extras kept, and the replies still point at it.
            let stamp = list[i]
            #expect(stamp.text("NM") == ids[i])
            #expect(stamp.number("CA") == 0.5)
            #expect(stamp.int("StructParent") == 7)
            #expect(list.contains { $0.dict("IRT")?.identity == stamp.identity })
        }
        let rects = try SignatureStamps.read(moved, nil)
        #expect(abs((rects.first { $0.id == ids[0] }?.rect.width ?? 0) - w * 2) <= 1)
        #expect(abs((rects.first { $0.id == ids[1] }?.rect.x ?? 0) - 400) <= 1)
        #expect(TestImages.pixelAt(moved, 0, 440, 540).b > 150)
        #expect(try Annotations.read(moved, nil).filter { $0.replyTo != nil }.count == 2)
    }

    @Test func otherScriptsInTheDetailLine() throws {
        let by = RubberStamps.approvedBy("Андрей", Date())
        let (w, h) = RubberStamps.naturalSize(by)
        let pdf = try RubberStamps.put(TestPdf.make(1), nil, 0, RectD(100, 100, w, h), by, author: nil)
        let text = try Core2Pdf.allText(pdf)
        #expect(text.contains("APPROVED"))
        #expect(text.contains("Андрей"))
    }

    @Test func customStampsFromAnImage() throws {
        let img = StampImage(10, 10, Array([[UInt8]](repeating: [200, 30, 30], count: 100).joined()), nil)
        let pdf = try RubberStamps.putImage(TestPdf.make(1), nil, 0, RectD(200, 200, 80, 80), img, label: "Paid in full", author: "Tester")
        let placed = try #require(try SignatureStamps.read(pdf, nil).first)
        #expect(placed.kind == .stamp)
        #expect(try Core2Pdf.lastAnnot(pdf).name("Name") == "Paidinfull")
        #expect(try Annotations.read(pdf, nil).first?.subject == "Paid in full")
        // Moved: the picture comes along.
        let moved = try RubberStamps.move(pdf, nil, placed.id, 0, RectD(400, 600, 40, 40))
        let px = TestImages.pixelAt(moved, 0, 420, 620)
        #expect(px.r > 150 && px.g < 80)
        #expect(try SignatureStamps.read(Annotations.delete(moved, nil, placed.id), nil).isEmpty)
    }
}
