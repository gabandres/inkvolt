import Foundation
import Testing
@testable import PdfCore

/// Vector printing on the Mac (no Windows test to port: Windows prints through its own renderer): which pages print as
/// vectors from the print copy and which as pictures, and the matrices that put a copy's page on the paper.
struct PrintCopyTests {
    private static func shown(_ data: [UInt8], _ password: String? = nil) throws -> [(Double, Double)] {
        let engine = try PdfEngine.open(data, password: password)
        defer { engine.close() }
        return (0..<engine.pageCount).map { (engine.page($0).width, engine.page($0).height) }
    }

    private static func near(_ p: (x: Double, y: Double), _ x: Double, _ y: Double) -> Bool { abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9 }

    private static func isVector(_ p: PrintedPage) -> Bool {
        if case .vector = p { return true }
        return false
    }

    @Test(arguments: [0, 90, 180, 270])
    func thePageMatrixIsThePageSpaceMapping(rotation: Int) throws {
        let frame = PageFrame(bx1: 30, by2: 800, w: 500, h: 700, rot: rotation)
        let m = try #require(frame.toPageMatrix)
        for (x, y) in [(30.0, 100.0), (530, 800), (100, 450), (0, 0)] {
            let expected = frame.toPage(x, y)
            #expect(Self.near(m.apply(x, y), expected.x, expected.y))
        }
        #expect(PageFrame(bx1: 0, by2: 792, w: 612, h: 792, rot: 45).toPageMatrix == nil)
    }

    @Test func matricesComposeInOrder() {
        let scale = Affine(2, 0, 0, 3, 0, 0), shift = Affine(1, 0, 0, 1, 10, 20)
        #expect(Self.near(scale.then(shift).apply(1, 1), 12, 23))
        #expect(Self.near(shift.then(scale).apply(1, 1), 22, 63))
        #expect(Affine.identity.then(scale) == scale)
    }

    @Test func aPlacedPageFillsItsBoxAndATurnedOneGoesClockwise() {
        // Upright, half size: the page's corners on the box's.
        let upright = PrintLayout.toPaper(PlacedPage(0, RectD(36, 72, 306, 396), 0), 612, 792)
        #expect(Self.near(upright.apply(0, 0), 36, 72))
        #expect(Self.near(upright.apply(612, 792), 342, 468))
        // A landscape page turned onto portrait paper: its top-left at the box's top-right, its top-right at the
        // bottom-right, its bottom-left at the top-left.
        let turned = PrintLayout.toPaper(PlacedPage(0, RectD(18, 18, 576, 756), 1), 756, 576)
        #expect(Self.near(turned.apply(0, 0), 594, 18))
        #expect(Self.near(turned.apply(756, 0), 594, 774))
        #expect(Self.near(turned.apply(0, 576), 18, 18))
        #expect(Self.near(turned.apply(756, 576), 18, 774))
        // A poster tile: only its source fills the box (the rest falls outside it and is clipped).
        let tile = PrintLayout.toPaper(PlacedPage(0, RectD(0, 0, 600, 600), 0, source: RectD(300, 300, 300, 300)), 612, 792)
        #expect(Self.near(tile.apply(300, 300), 0, 0))
        #expect(Self.near(tile.apply(600, 600), 600, 600))
        #expect(Self.near(tile.apply(0, 0), -600, -600))
    }

    @Test func plainPagesPrintAsVectorsFromTheDocumentsOwnBytes() throws {
        let pdf = TestPdf.make(3)
        let copy = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf))
        #expect(copy.pages.count == 3 && copy.pages.allSatisfy(Self.isVector))
        #expect(!copy.rewritten && copy.data == pdf)
        #expect(copy.pages[0] == .vector(toPage: Affine(1, 0, 0, -1, 0, 792)))
        // Asked to (Core Graphics couldn't open the bytes): written by MuPDF, the same pages.
        let written = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf), rewrite: true)
        let writtenPages = try Self.shown(written.data).count
        #expect(written.rewritten && written.data != pdf && writtenPages == 3)
        #expect(try Core2Pdf.allText(written.data, page: 1).contains("Page 2 alpha"))
    }

    @Test func commentsAndFieldsAreDrawnIntoTheCopysPages() throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 600 300 630] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>"])
        let filled = try FormEditor.setValues(form, nil, ["Name": "Ada Lovelace"])
        let copy = try PrintCopy.make(filled, nil, shown: try Self.shown(filled))
        #expect(copy.rewritten && copy.pages.allSatisfy(Self.isVector))
        // The value is page text now, and nothing is left for a viewer to draw on top.
        #expect(try Core2Pdf.allText(copy.data, annotations: false).contains("Ada Lovelace"))
        #expect(try Core2Pdf.open(copy.data).page(0).array("Annots") == nil)
        // The document itself is untouched.
        #expect(try FormEditor.read(filled, nil).count == 1)
    }

    @Test func aSignatureFieldPrintsItsAppearanceWithoutAsking() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signer) /Rect [100 100 300 160] /F 4 /P 3 0 R /AP << /N 5 0 R >> /V 6 0 R >>",
            Core2Pdf.stream("0 g 0 0 200 60 re f", "/Type /XObject /Subtype /Form /BBox [0 0 200 60]"),
            "<< /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 10 20 30] /Contents <00> >>",
        ])
        #expect(SignedEdits.looksSigned(pdf))
        let copy = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf))
        #expect(copy.pages.allSatisfy(Self.isVector))
        #expect(try Core2Pdf.open(copy.data).page(0).array("Annots") == nil)
        // Drawn by the page's content (annotations off): the box under the signature's rectangle is inked.
        #expect(try Core2Pdf.ink(copy.data, 0, RectD(110, 640, 180, 40)) > 0.9)
    }

    @Test func aPageWithACommentMuPdfDrawsItsOwnWayPrintsAsAPicture() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [6 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [7 0 R 8 0 R 9 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [10 0 R] >>",
            // Page 1: a square without an appearance (MuPDF makes one up).
            "<< /Type /Annot /Subtype /Square /Rect [100 100 200 150] /C [1 0 0] /F 4 >>",
            // Page 2: a link, a popup and a hidden square: nothing shows that the copy can't draw.
            "<< /Type /Annot /Subtype /Link /Rect [50 50 60 60] >>",
            "<< /Type /Annot /Subtype /Popup /Rect [200 200 300 300] >>",
            "<< /Type /Annot /Subtype /Square /Rect [300 300 400 400] /F 2 >>",
            // Page 3: a note with its own appearance.
            "<< /Type /Annot /Subtype /Square /Rect [100 100 200 150] /F 4 /AP << /N 11 0 R >> >>",
            Core2Pdf.stream("0 g 0 0 100 50 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 50]"),
        ])
        let copy = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf))
        #expect(copy.pages[0] == .picture("a comment or form field on it has no appearance of its own"))
        #expect(Self.isVector(copy.pages[1]) && Self.isVector(copy.pages[2]))
    }

    @Test func aNoteKeptUprightOnATurnedPagePrintsAsAPicture() throws {
        func doc(_ rotate: Int) -> [UInt8] {
            Core2Pdf.build([
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotate) /Annots [4 0 R] >>",
                // A sticky note: Print, NoZoom and NoRotate, as most viewers write them.
                "<< /Type /Annot /Subtype /Text /Rect [100 700 120 720] /F 28 /AP << /N 5 0 R >> >>",
                Core2Pdf.stream("1 1 0 rg 0 0 20 20 re f", "/Type /XObject /Subtype /Form /BBox [0 0 20 20]"),
            ])
        }
        let turned = doc(90)
        #expect(try PrintCopy.make(turned, nil, shown: try Self.shown(turned)).pages == [.picture("a comment on it stays upright on the turned page")])
        let upright = doc(0)
        #expect(try PrintCopy.make(upright, nil, shown: try Self.shown(upright)).pages.allSatisfy(Self.isVector))
    }

    @Test func aTurnedPagePrintsAsVectorsWithItsTurn() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [10 20 610 780] /Rotate 90 >>",
        ])
        let shown = try Self.shown(pdf)
        #expect(abs(shown[0].0 - 760) < 0.01 && abs(shown[0].1 - 600) < 0.01)
        let copy = try PrintCopy.make(pdf, nil, shown: shown)
        guard case .vector(let m) = copy.pages[0] else { Issue.record("not vector"); return }
        // The crop box's top-left (10, 780) is the top-right of the page turned clockwise.
        #expect(Self.near(m.apply(10, 780), 760, 0))
        #expect(Self.near(m.apply(610, 20), 0, 600))
    }

    @Test func pagesMuPdfReadsDifferentlyPrintAsPictures() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 45 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ])
        let copy = try PrintCopy.make(pdf, nil, shown: [(612, 792), (500, 792)])
        #expect(copy.pages == [.picture("its /Rotate isn't a quarter turn"), .picture("its size reads differently than MuPDF shows it")])
        // A size within MuPDF's rounding is the same.
        let close = try PrintCopy.make(pdf, nil, shown: [(612, 792), (612.3, 791.8)])
        #expect(Self.isVector(close.pages[1]))
        // A page count that isn't the engine's: everything a picture, nothing read further.
        let other = try PrintCopy.make(pdf, nil, shown: [(612, 792)])
        #expect(other.pages.count == 1 && !Self.isVector(other.pages[0]) && other.data == pdf)
    }

    @Test func anEncryptedDocumentsCopyOpensWithoutItsPassword() throws {
        let pdf = TestPdf.encrypted(2, "secret")
        let copy = try PrintCopy.make(pdf, "secret", shown: try Self.shown(pdf, "secret"))
        #expect(copy.rewritten && copy.pages.allSatisfy(Self.isVector))
        #expect(!PdfSecurity.needsOpenPassword(copy.data))
        #expect(try Core2Pdf.allText(copy.data, page: 1).contains("Page 2 alpha"))
        #expect(throws: PasswordRequired.self) { try PrintCopy.make(pdf, nil, shown: [(612, 792), (612, 792)]) }
    }
}
