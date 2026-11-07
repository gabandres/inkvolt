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

    @Test func plainPagesPrintAsVectorsFromMuPdfsRewrite() throws {
        let pdf = TestPdf.make(3)
        let copy = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf))
        #expect(copy.pages.count == 3 && copy.pages.allSatisfy(Self.isVector))
        #expect(copy.pages[0] == .vector(toPage: Affine(1, 0, 0, -1, 0, 792)))
        // Never the document's own bytes (theCopyIsMuPdfsRewriteSoPaperReadsTheFileAsTheScreenDoes), its text kept.
        let writtenPages = try Self.shown(copy.data).count
        #expect(copy.data != pdf && writtenPages == 3)
        #expect(try Core2Pdf.allText(copy.data, page: 1).contains("Page 2 alpha"))
        // Its streams as they were (not inflated): about the document's size.
        #expect(copy.data.count < pdf.count * 2 + 4096, "\(copy.data.count) bytes from \(pdf.count)")
    }

    /// The ink in a region of page 1 on screen (MuPDF, comments and fields drawn) and in the copy's page content.
    private static func inks(_ original: [UInt8], _ copy: PrintCopy, _ region: RectD) throws -> (screen: Double, paper: Double) {
        (try Core2Pdf.ink(original, 0, region), try Core2Pdf.ink(copy.data, 0, region))
    }

    @Test func whatMuPdfDoesntDrawIsntDrawnOnPaperAndKeepsItsPageVector() throws {
        let black = Core2Pdf.stream("0 g 0 0 100 50 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 50]")
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [8 0 R 9 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 5 0 R 6 0 R 7 0 R 8 0 R 9 0 R] >>",
            // A popup with an appearance of its own (MuPDF never draws popups).
            "<< /Type /Annot /Subtype /Popup /Rect [100 600 200 650] /F 4 /AP << /N 10 0 R >> >>",
            // A square marked Invisible.
            "<< /Type /Annot /Subtype /Square /Rect [250 600 350 650] /F 5 /AP << /N 10 0 R >> >>",
            // A square marked NoView.
            "<< /Type /Annot /Subtype /Square /Rect [400 600 500 650] /F 36 /AP << /N 10 0 R >> >>",
            // A widget of no field (no /FT, no /T): MuPDF draws no such widget.
            "<< /Type /Annot /Subtype /Widget /Rect [100 400 200 450] /F 4 /AP << /N 10 0 R >> >>",
            // An invisible signature: signed, a Rect with no area, no appearance (Print and Locked).
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signer) /Rect [0 0 0 0] /F 132 /P 3 0 R /V 11 0 R >>",
            // A text field squeezed to no height.
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Flat) /Rect [250 400 350 400] /F 4 /P 3 0 R /AP << /N 10 0 R >> >>",
            black,
            "<< /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 10 20 30] /Contents <00> >>",
        ])
        let copy = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf))
        #expect(copy.pages.allSatisfy(Self.isVector), "\(copy.pages)")
        for region in [RectD(100, 142, 100, 50), RectD(250, 142, 100, 50), RectD(400, 142, 100, 50), RectD(100, 342, 100, 50)] {
            let ink = try Self.inks(pdf, copy, region)
            #expect(ink.screen < 0.01 && ink.paper < 0.01, "\(region): screen \(ink.screen), paper \(ink.paper)")
        }
        // Flatten (File › Flatten) keeps the same rule: the popup isn't drawn into the page.
        let popup = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Popup /Rect [100 600 200 650] /F 4 /AP << /N 5 0 R >> >>",
            black,
        ])
        let flat = try Flattener.flatten(popup, nil)
        let popupInk = try Core2Pdf.ink(flat, 0, RectD(100, 142, 100, 50))
        #expect(flat != popup && popupInk < 0.01)
    }

    @Test func aFieldPrintsTheAppearanceTheScreenShowsNotOneMadeAgain() throws {
        // /NeedAppearances asks for new appearances, but MuPDF shows the field's own (a black box here): so does paper.
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /NeedAppearances true /DA (/Helv 12 Tf 0 g) >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V (Ada) /Rect [100 600 200 650] /F 4 /P 3 0 R /AP << /N 5 0 R >> >>",
            Core2Pdf.stream("0 g 0 0 100 50 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 50]"),
        ])
        let copy = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf))
        #expect(copy.pages.allSatisfy(Self.isVector))
        let ink = try Self.inks(pdf, copy, RectD(102, 144, 96, 46))
        #expect(ink.screen > 0.9 && ink.paper > 0.9, "screen \(ink.screen), paper \(ink.paper)")
    }

    @Test func anAppearanceFlatteningCantPlaceMakesThePageAPicture() throws {
        func doc(_ widget: String, _ appearance: String) -> [UInt8] {
            Core2Pdf.build([
                "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
                widget,
                appearance,
            ])
        }
        let why = PrintedPage.picture("a comment or form field on it has no appearance of its own")
        // A text field whose appearance has no width: flattening can't fit it to the field; MuPDF may draw its own.
        let thin = doc("<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 600 300 630] /F 4 /P 3 0 R /AP << /N 5 0 R >> >>",
                       Core2Pdf.stream("0 g 0 0 0 30 re f", "/Type /XObject /Subtype /Form /BBox [0 0 0 30]"))
        #expect(try PrintCopy.make(thin, nil, shown: try Self.shown(thin)).pages == [why])
        // A check box whose state (/AS /Yes) isn't among its appearances: MuPDF makes one up.
        let box = doc("<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) /Rect [72 600 92 620] /F 4 /P 3 0 R /V /Yes /AS /Yes /AP << /N << /Off 5 0 R >> >> >>",
                      Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 20 20]"))
        #expect(try PrintCopy.make(box, nil, shown: try Self.shown(box)).pages == [why])
        // An unsigned signature field: MuPDF shows its own "sign here" box, not the file's appearance.
        let unsigned = doc("<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signer) /Rect [100 100 300 160] /F 4 /P 3 0 R /AP << /N 5 0 R >> >>",
                           Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 200 60]"))
        #expect(try PrintCopy.make(unsigned, nil, shown: try Self.shown(unsigned)).pages == [why])
    }

    @Test func aPageCoreGraphicsReadsDifferentlyPrintsAsAPicture() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [10 20 610 780] /Rotate 90 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ])
        let copy = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf))
        let letter = PageBox(0, 0, 612, 792, rotation: 0)
        #expect(copy.boxes == [PageBox(10, 20, 610, 780, rotation: 90), letter, letter])
        // Page 1 read alike (within MuPDF's rounding, its turn written as -270), page 2 another size, page 3 turned.
        let read: [PageBox?] = [PageBox(10, 20, 610.2, 780, rotation: -270), PageBox(0, 0, 595, 842, rotation: 0), PageBox(0, 0, 612, 792, rotation: 180)]
        let checked = copy.checked { read[$0] }
        let why = PrintedPage.picture("Core Graphics reads its box or turn differently than MuPDF")
        #expect(Self.isVector(checked[0]) && checked[1] == why && checked[2] == why)
        // A page Core Graphics doesn't have prints as a picture too.
        #expect(copy.checked { $0 == 0 ? read[0] : nil }[1] == .picture("Core Graphics couldn't read the page"))
    }

    @Test func makingTheCopyStopsWhenCancelled() throws {
        let pdf = TestPdf.make(3)
        let token = CancelToken()
        token.cancel()
        #expect(throws: CancellationError.self) { try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf), cancel: token) }
    }

    @Test func commentsAndFieldsAreDrawnIntoTheCopysPages() throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 600 300 630] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>"])
        let filled = try FormEditor.setValues(form, nil, ["Name": "Ada Lovelace"])
        let copy = try PrintCopy.make(filled, nil, shown: try Self.shown(filled))
        #expect(copy.pages.allSatisfy(Self.isVector))
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
        #expect(copy.pages.allSatisfy(Self.isVector))
        #expect(!PdfSecurity.needsOpenPassword(copy.data))
        #expect(try Core2Pdf.allText(copy.data, page: 1).contains("Page 2 alpha"))
        #expect(throws: PasswordRequired.self) { try PrintCopy.make(pdf, nil, shown: [(612, 792), (612, 792)]) }
    }

    /// A Mac addition from the hostile-input review: Core Graphics draws a page with no bound, so a page the bounded engine
    /// refuses (a decompression bomb, here at the tests' budget) prints as a picture of what the screen shows (nothing),
    /// never as vectors; the others still print as vectors.
    @Test func aPageTheBoundedEngineRefusesPrintsAsAPicture() throws {
        let file = PageCheckTests.bomb("7 KB")
        let copy = try PdfEngine.$budgetForTests.withValue(PageCheckTests.limit) {
            try PrintCopy.make(file, nil, shown: try Self.shown(file))
        }
        #expect(Self.isVector(copy.pages[0]) && Self.isVector(copy.pages[2]))
        let refused = [true, false].map { PrintedPage.picture(PageRefused(page: 1, tooSlow: $0).message) }
        #expect(refused.contains(copy.pages[1]), "\(copy.pages[1])")
    }

    /// A Mac addition from the hostile-input review: the paper must show what the screen shows, so Core Graphics draws
    /// MuPDF's rewrite, never the document's own bytes, which it may read differently (an object defined twice, a broken
    /// cross-reference table that each repairs its own way).
    @Test func theCopyIsMuPdfsRewriteSoPaperReadsTheFileAsTheScreenDoes() throws {
        var pdf = Array("%PDF-1.7\n".utf8)
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
            "4 0 obj\n" + Core2Pdf.stream("BT /F1 18 Tf 72 700 Td (Paper only) Tj ET") + "\nendobj\n",
            "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
            "4 0 obj\n" + Core2Pdf.stream("BT /F1 18 Tf 72 700 Td (Screen text) Tj ET") + "\nendobj\n",
        ]
        for o in objects { pdf += Array(o.utf8) }
        pdf += Array("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n999999\n%%EOF\n".utf8) // no table: each reader repairs
        #expect(try Core2Pdf.allText(pdf).contains("Screen text"))
        for data in [pdf, TestPdf.make(3)] {
            let copy = try PrintCopy.make(data, nil, shown: try Self.shown(data))
            #expect(copy.data != data && copy.pages.allSatisfy(Self.isVector))
            #expect(try Self.shown(copy.data).count == (try Self.shown(data)).count)
        }
        let copy = try PrintCopy.make(pdf, nil, shown: try Self.shown(pdf))
        let text = String(decoding: copy.data, as: UTF8.self)
        #expect(text.components(separatedBy: "\n4 0 obj").count == 2, "one object 4, the one the screen shows")
        #expect(try Core2Pdf.allText(copy.data).contains("Screen text"))
        #expect(!(try Core2Pdf.allText(copy.data).contains("Paper only")))
        #expect(text.contains("\nxref\n") || text.contains("/Type /XRef") || text.contains("/Type/XRef"))
    }

    /// The pages a test hook was asked to read.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Int] = []
        func add(_ page: Int) { lock.withLock { pages.append(page) } }
        var list: [Int] { lock.withLock { pages.sorted() } }
    }

    /// Review of the hostile-input fixes: a page the view engine has read within its bounds already is not read again
    /// (a 400-page scan waited minutes for every page to be drawn again before the print panel opened).
    @Test func aPageTheViewEngineReadFineIsntReadAgain() throws {
        let file = PageCheckTests.bomb("7 KB")
        let copy = try PdfEngine.$budgetForTests.withValue(PageCheckTests.limit) {
            try PrintCopy.make(file, nil, shown: try Self.shown(file), rated: [.fine, .fine, .fine])
        }
        #expect(copy.pages.allSatisfy(Self.isVector), "\(copy.pages)")
    }

    /// A page the view engine refused for a picture too large or a stream inflated too often prints its sentence, unread;
    /// one it found too slow (its drawing may be what took the time) is read again, without drawing.
    @Test func aPageTheViewEngineRefusedPrintsItsSentenceAndOneTooSlowIsReadAgain() throws {
        let file = TestPdf.make(3)
        let reads = Reads()
        let copy = try PrintCopy.$readForTests.withValue({ reads.add($0) }) {
            try PrintCopy.make(file, nil, shown: try Self.shown(file), rated: [.failed, .tooSlow, .unknown])
        }
        #expect(copy.pages[0] == .picture(PageRefused(page: 0, tooSlow: false).message))
        #expect(Self.isVector(copy.pages[1]) && Self.isVector(copy.pages[2]))
        #expect(reads.list == [1, 2])
    }

    /// Checking a page reads its content through every bound but draws nothing: its pictures are checked by their size,
    /// never decoded (here 12 of 16,000 x 16,000 gray, seconds to decode, at the tests' 1 s budget), and one larger than
    /// MuPDF may decode still refuses its page.
    @Test func checkingAPageForPrintingDecodesNoPicture() throws {
        func picture(_ side: Int) -> [UInt8] {
            let dict = "/Type /XObject /Subtype /Image /Width \(side) /Height \(side) /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode"
            return PageCheckTests.stream(PageCheckTests.zlib([], zeros: side * side), dict)
        }
        let count = 12
        let names = (0..<count).map { "/I\($0) \($0 + 7) 0 R" }.joined(separator: " ")
        let content = (0..<count).map { "q 40 0 0 40 \(50 + ($0 % 6) * 80) \(100 + ($0 / 6) * 80) cm /I\($0) Do Q" }.joined(separator: "\n")
        let one = picture(16_000)
        let objects: [[UInt8]] = [
            PageCheckTests.obj("<< /Type /Catalog /Pages 2 0 R >>"),
            PageCheckTests.obj("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>"),
            PageCheckTests.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /XObject << \(names) >> >> >>"),
            PageCheckTests.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /XObject << /Big \(count + 7) 0 R >> >> >>"),
            PageCheckTests.stream(content),
            PageCheckTests.stream("q 500 0 0 500 50 150 cm /Big Do Q"),
        ]
        let file = PageCheckTests.build(objects + Array(repeating: one, count: count) + [picture(17_000)])
        var copy: PrintCopy?
        let took = try PageCheckTests.time {
            copy = try PdfEngine.$budgetForTests.withValue(PageCheckTests.limit) {
                try PrintCopy.make(file, nil, shown: try Self.shown(file))
            }
        }
        #expect(copy.map { Self.isVector($0.pages[0]) } == true, "\(copy?.pages ?? [])")
        #expect(copy?.pages[1] == .picture(PageRefused(page: 1, tooSlow: false).message))
        #expect(took < PageCheckTests.limit + PageCheckTests.slack, "\(took) s")
    }

    /// A page MuPDF fails on without refusing it (an error of its own, not a bound) prints as vectors, as before the
    /// bound: a picture of it would fail too, and the sheet would come out blank.
    @Test func aPageMuPdfFailsOnWithoutRefusingStillPrintsAsVectors() throws {
        let file = TestPdf.make(2)
        let failing: @Sendable (Int) throws -> Void = { page in
            if page == 0 { throw PdfEngineError(message: "syntax error") }
        }
        let copy = try PrintCopy.$readForTests.withValue(failing) {
            try PrintCopy.make(file, nil, shown: try Self.shown(file))
        }
        #expect(copy.pages.allSatisfy(Self.isVector), "\(copy.pages)")
    }

    /// No page in vectors: nothing for Core Graphics to read, so MuPDF writes no copy (the document's own bytes are kept).
    @Test func noCopyIsWrittenWhenNoPagePrintsAsVectors() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 45 >>",
        ])
        let copy = try PrintCopy.make(pdf, nil, shown: [(612, 792)])
        #expect(!copy.hasVectors && copy.data == pdf)
    }

    /// MuPDF can't write the copy: the vector pages print from the document's own bytes, as before the copy was always
    /// MuPDF's, when they are all Core Graphics needs (nothing flattened, not encrypted); else no copy at all.
    @Test func aCopyMuPdfCantWritePrintsFromTheDocumentsOwnBytes() throws {
        let plain = TestPdf.make(2)
        let copy = try PrintCopy.$writeFailsForTests.withValue(true) {
            try PrintCopy.make(plain, nil, shown: try Self.shown(plain))
        }
        #expect(copy.data == plain && copy.pages.allSatisfy(Self.isVector))
        let locked = TestPdf.encrypted(2, "secret")
        let shown = try Self.shown(locked, "secret")
        #expect(throws: (any Error).self) {
            try PrintCopy.$writeFailsForTests.withValue(true) { try PrintCopy.make(locked, "secret", shown: shown) }
        }
    }
}
