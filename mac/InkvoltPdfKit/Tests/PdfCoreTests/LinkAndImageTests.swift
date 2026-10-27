import Foundation
import Testing
@testable import PdfCore

/// Ported from LinkAndImageTests.cs, whole. Refusals are `PdfEditError`s (.NET's ArgumentException and
/// InvalidOperationException); the PDFsharp object checks read the same objects through MuPDF.
struct LinkAndImageTests {
    static func blue(_ w: Int = 30, _ h: Int = 20) -> StampImage {
        StampImage(w, h, Array([[UInt8]](repeating: [20, 40, 200], count: w * h).joined()), nil)
    }

    static let addresses: [(String, String?)] = [
        ("example.com/docs", "https://example.com/docs"),
        ("www.example.com", "https://www.example.com/"),
        ("https://example.com/a b", "https://example.com/a%20b"),
        ("ada@example.com", "mailto:ada@example.com"),
        ("mailto:ada@example.com", "mailto:ada@example.com"),
        ("ftp://files.example.com/x", "ftp://files.example.com/x"),
        // /URI is 7-bit ASCII: international domains as punycode, the rest percent-encoded (UTF-8).
        ("https://bücher.example/straße?q=ü", "https://xn--bcher-kva.example/stra%C3%9Fe?q=%C3%BC"),
        ("münchen.de", "https://xn--mnchen-3ya.de/"),
        ("josé@bücher.example", "mailto:jos%C3%A9@xn--bcher-kva.example"),
        ("mailto:ada@example.com?subject=Grüße aus Köln", "mailto:ada@example.com?subject=Gr%C3%BC%C3%9Fe%20aus%20K%C3%B6ln"),
        ("https://例え.テスト/パス", "https://xn--r8jz45g.xn--zckzah/%E3%83%91%E3%82%B9"),
        ("javascript:alert(1)", nil),
        ("data:text/html,hi", nil),
        ("not a link", nil),
        ("", nil),
    ]

    @Test(arguments: addresses)
    func addressesAreNormalized(_ typed: String, _ expected: String?) {
        #expect(Links.normalize(typed) == expected)
    }

    @Test func onlyWebAndEmailAreSafe() {
        #expect(Links.isSafe("https://example.com/"))
        #expect(Links.isSafe("mailto:a@b.c"))
        #expect(!Links.isSafe("ftp://example.com/"))
        #expect(!Links.isSafe("file:///C:/Windows/notepad.exe"))
    }

    @Test func linksRoundTripThroughMuPdf() throws {
        let pdf = TestPdf.make(3)
        let web = try Links.put(pdf, nil, 0, RectD(72, 80, 150, 30), uri: "example.com", targetPage: -1)
        let both = try Links.put(web, nil, 0, RectD(72, 200, 100, 20), uri: nil, targetPage: 2)

        let read = try Links.read(both, nil)
        #expect(read.count == 2)
        let w = try #require(read.first { $0.uri != nil })
        #expect(w.uri == "https://example.com/")
        #expect(abs(w.rect.x - 72) <= 1)
        #expect(abs(w.rect.y - 80) <= 1)
        #expect(read.first { $0.uri == nil }?.targetPage == 2)

        // What the page view follows: MuPDF's own reading of the same links.
        let engine = try PdfEngine.open(both)
        defer { engine.close() }
        let links = try engine.links(0)
        #expect(links.contains { $0.uri == "https://example.com/" && abs($0.area.x - 72) < 1 })
        #expect(links.contains { $0.uri == nil && $0.pageIndex == 2 })
    }

    @Test func editingMovesAndRetargets() throws {
        let pdf = try Links.put(TestPdf.make(2), nil, 0, RectD(72, 80, 150, 30), uri: "https://example.com/", targetPage: -1)
        let id = try #require(try Links.read(pdf, nil).first).id
        let moved = try Links.put(pdf, nil, 1, RectD(100, 300, 50, 50), uri: nil, targetPage: 0, replaceId: id)
        let links = try Links.read(moved, nil)
        try #require(links.count == 1)
        let link = links[0]
        #expect(link.id == id)
        #expect(link.pageIndex == 1)
        #expect(link.uri == nil)
        #expect(link.targetPage == 0)
        #expect(abs(link.rect.y - 300) <= 1)

        let gone = try Links.delete(moved, nil, id)
        #expect(try Links.read(gone, nil).isEmpty)
        #expect(throws: PdfEditError.self) { try Links.delete(gone, nil, id) }
        #expect(throws: PdfEditError.self) {
            try Links.put(pdf, nil, 0, RectD(0, 0, 10, 10), uri: "javascript:alert(1)", targetPage: -1)
        }
    }

    @Test func movingKeepsActionsItCantEdit() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [100 700 200 720] /A << /S /Named /N /NextPage >> >>",
        ])
        let link = try #require(try Links.read(pdf, nil).first)
        #expect(link.uri == nil && link.targetPage == -1)
        #expect(link.describe() == "Another action")
        let moved = try Links.move(pdf, nil, link.id, 0, RectD(10, 10, 50, 20))
        let annot = try #require(try Core2Pdf.open(moved).page(0).array("Annots")?.elements.first)
        #expect(annot.dict("A")?.name("N") == "NextPage")
        #expect(abs((try Links.read(moved, nil).first?.rect.x ?? 0) - 10) <= 1)
    }

    @Test func selectedTextBecomesOneLinkOverItsLines() throws {
        let lines = [RectD(150, 125, 200, 20), RectD(72, 155, 120, 20)]
        let pdf = try Links.putOnText(TestPdf.make(1), nil, 0, lines, uri: "https://example.com/", targetPage: -1)
        let link = try #require(try Links.read(pdf, nil).first)
        let r = link.rect
        #expect([r.x, r.y, r.width, r.height].map { $0.rounded() } == [72, 125, 278, 50])
        let annot = try Core2Pdf.lastAnnot(pdf)
        let qp = try #require(annot.array("QuadPoints"))
        #expect(qp.count == 16)
        // The first line's upper-left corner, in PDF space (y up).
        #expect(qp.num(0) == 150 && qp.num(1) == 792 - 125)
        #expect(throws: PdfEditError.self) { try Links.putOnText(pdf, nil, 0, [], uri: "https://example.com/", targetPage: -1) }
    }

    @Test func allTransparentPicturesAreShownOpaque() throws {
        // A 32-bit clipboard bitmap whose app wrote no alpha: every pixel's alpha is 0.
        var img = Self.blue()
        img.alpha = [UInt8](repeating: 0, count: 30 * 20)
        let pdf = try SignatureStamps.putImage(TestPdf.make(1), nil, 0, RectD(300, 400, 90, 60), img, label: "Pasted image")
        let px = TestImages.pixelAt(pdf, 0, 345, 430)
        #expect(px.b > 150 && px.r < 80)
    }

    @Test func linksOnTurnedPagesUsePageSpace() throws {
        let turned = try PageEditor.rotate(TestPdf.make(1), nil, [0], 90)
        let pdf = try Links.put(turned, nil, 0, RectD(50, 60, 200, 40), uri: "https://example.com/", targetPage: -1)
        let r = try #require(try Links.read(pdf, nil).first).rect
        #expect(abs(r.x - 50) <= 1 && abs(r.y - 60) <= 1 && abs(r.width - 200) <= 1 && abs(r.height - 40) <= 1, "\(r)")
    }

    @Test func imagesArePlacedMovedAndListed() throws {
        let pdf = try SignatureStamps.putImage(TestPdf.make(1), nil, 0, RectD(300, 400, 90, 60), Self.blue(), label: "logo.png", author: "Tester")
        let placed = try #require(try SignatureStamps.read(pdf, nil).first)
        #expect(placed.kind == .image)
        #expect(placed.text == "logo.png")
        #expect(TestImages.pixelAt(pdf, 0, 345, 430).b > 150)

        let moved = try SignatureStamps.put(pdf, nil, 0, RectD(100, 100, 45, 30), nil, replaceId: placed.id)
        let after = try SignatureStamps.read(moved, nil)
        try #require(after.count == 1)
        #expect(after[0].id == placed.id && after[0].kind == .image)
        #expect(abs(after[0].rect.x - 100) <= 1)
        #expect(TestImages.pixelAt(moved, 0, 120, 115).b > 150)
        let old = TestImages.pixelAt(moved, 0, 345, 430)
        #expect(old.b > 240 && old.r > 240)

        // A stamp in the Comments pane, with its author and subject.
        let comments = try Annotations.read(moved, nil)
        try #require(comments.count == 1)
        #expect(comments[0].kind == .stamp)
        #expect(comments[0].subject == "Image")
        #expect(comments[0].author == "Tester")
        #expect(try SignatureStamps.read(TextStamps.remove(moved, nil, placed.id), nil).isEmpty)
    }
}
