import Foundation
import Testing
@testable import PdfCore

/// Ported from ResizePagesTests.cs (roadmap 4.7), all 9 tests, same names: Letter, A4 or any size, the content scaled to
/// fit or given margins. Refusals are `PdfEditError`s (.NET's ArgumentOutOfRangeException and InvalidOperationException);
/// PDFsharp's object reads become MuPDF's (`PObj`). MuPDF reads the ±1e308 written out (whole numbers too large for it) as
/// 0, a media box of no size, which reaches the same refusal as on Windows (`PageEditor.shownBox`), and the cropped page
/// the same resize. EveryKindOfDestinationMovesWithTheContent builds its arrays in a document of its own.
struct ResizePagesTests {
    private static let a4w = 595.0, a4h = 842.0

    private static func sizes(_ pdf: [UInt8]) throws -> [[Double]] {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return (0..<engine.pageCount).map { [engine.page($0).width.rounded(), engine.page($0).height.rounded()] }
    }

    private static func near(_ a: Double, _ b: Double, _ places: Double) -> Bool { abs(a - b) <= 0.5 * pow(10, -places) }

    @Test func theContentIsScaledAndCentred_OrKeptWithMargins() throws {
        let scale = try #require(PageEditor.resizeTransform((0, 0, 612, 792), 0, Self.a4w, Self.a4h, .scale))
        #expect(Self.near(scale.s, Self.a4w / 612, 4))
        #expect(Self.near(scale.e, 0, 2))
        #expect(Self.near(scale.f, (Self.a4h - 792 * scale.s) / 2, 2))
        #expect(scale.w == Self.a4w && scale.h == Self.a4h)

        // Margins: a smaller page keeps its size, centred; a larger one shrinks to fit.
        let small = try #require(PageEditor.resizeTransform((0, 0, 420, 595), 0, 612, 792, .margins))
        #expect(small.s == 1 && small.e == 96 && small.f == 98.5)
        #expect(try #require(PageEditor.resizeTransform((0, 0, 842, 1191), 0, 612, 792, .margins)).s < 1)

        // A crop's corner goes to where the content starts.
        let cropped = try #require(PageEditor.resizeTransform((100, 50, 712, 842), 0, 612, 792, .scale))
        #expect(cropped.s == 1 && cropped.e == -100 && cropped.f == -50)
        #expect(PageEditor.resizeTransform((0, 0, 612, 792), 0, 612, 792, .scale) == nil) // already so
    }

    @Test func aPageSizeNoPageCanHave_IsRefusedWithAMessage_NeverWrittenAsNaN() throws {
        // ±1e308: the width is infinite, the scale nothing, the place NaN.
        let huge = "1" + String(repeating: "0", count: 308)
        func doc(_ mediaBox: String, _ pageExtra: String = "") -> [UInt8] {
            Core2Pdf.build([
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
                Core2Pdf.stream("0 0 1 rg 100 100 200 200 re f"),
                "<< /Type /Page /Parent 2 0 R /MediaBox [\(mediaBox)] \(pageExtra) /Contents 4 0 R /Annots [6 0 R] >>",
                "<< /Type /Annot /Subtype /Square /Rect [-\(huge) 0 \(huge) 10] >>",
            ])
        }
        #expect(PageEditor.resizeTransform((-1e308, 0, 1e308, 792), 0, Self.a4w, Self.a4h, .scale) == nil)
        #expect(PageEditor.resizeTransform((0, 0, .nan, 792), 0, Self.a4w, Self.a4h, .scale) == nil)

        // As wide as no page is (one side, or both): refused, saying which page.
        for box in ["-\(huge) 0 \(huge) 792", "-\(huge) -\(huge) \(huge) \(huge)", "0 0 612 20000000"] {
            let error = #expect(throws: PdfEditError.self) { try PageEditor.resize(doc(box), nil, [0, 1], Self.a4w, Self.a4h, .scale) }
            #expect(error?.message.contains("2") == true) // the page named
        }
        let bad = doc("-\(huge) 0 \(huge) 792")
        let first = try Core2Pdf.open(PageEditor.resize(bad, nil, [0], Self.a4w, Self.a4h, .scale)) // the other page alone: resized
        let m = PageBoxes.mediaBox(first.page(0))
        #expect(abs((m.x2 - m.x1) - Self.a4w) <= 0.1)

        // A crop that shows a page of a usable size: that is the page, and it resizes; the comment's absurd box stays as it was.
        let cropped = try PageEditor.resize(doc("-\(huge) 0 \(huge) 792", "/CropBox [0 0 612 792]"), nil, [1], Self.a4w, Self.a4h, .scale)
        let text = String(decoding: cropped, as: UTF8.self).lowercased()
        #expect(!text.contains("nan") && !text.contains("inf "))
        let doc2 = try Core2Pdf.open(cropped)
        let m2 = PageBoxes.mediaBox(doc2.page(1))
        #expect([(m2.x2 - m2.x1).rounded(), (m2.y2 - m2.y1).rounded()] == [Self.a4w, Self.a4h])
    }

    @Test func aPageKeepsTheWayItIsTurned() throws {
        // Landscape content gets the paper sideways; a page turned with /Rotate gets it in its own space.
        func size(_ t: (s: Double, e: Double, f: Double, w: Double, h: Double)?) -> [Double] { t.map { [$0.w, $0.h] } ?? [] }
        #expect(size(PageEditor.resizeTransform((0, 0, 792, 612), 0, Self.a4w, Self.a4h, .scale)) == [Self.a4h, Self.a4w])
        #expect(size(PageEditor.resizeTransform((0, 0, 612, 792), 90, Self.a4w, Self.a4h, .scale)) == [Self.a4w, Self.a4h])
        #expect(size(PageEditor.resizeTransform((0, 0, 612, 792), 0, Self.a4h, Self.a4w, .scale)) == [Self.a4w, Self.a4h]) // paper given sideways
    }

    @Test func mixedSizesBecomeOneSize_TheTextStaying() throws {
        let mixed = try PageEditor.insertBlank(TestPdf.make(2), nil, 1, 1, 420, 595) // Letter, A5, Letter
        let rotated = try PageEditor.rotate(mixed, nil, [2], 90)
        let pdf = try PageEditor.resize(rotated, nil, [0, 1, 2], Self.a4w, Self.a4h, .scale)
        #expect(try Self.sizes(pdf) == [[Self.a4w, Self.a4h], [Self.a4w, Self.a4h], [Self.a4h, Self.a4w]])
        #expect(TestPdf.pageNumbers(pdf) == [1, 0, 2])

        let some = try PageEditor.resize(mixed, nil, [1], 612, 792, .margins)
        #expect(try Self.sizes(some) == [[612, 792], [612, 792], [612, 792]])
    }

    @Test func commentsMoveWithTheContent_AndTheCropGoes() throws {
        let noted = try Annotations.addNote(TestPdf.make(1), nil, 0, 100, 100, "Look here", author: "Me")
        let before = try #require(Annotations.read(noted, nil).first).rect
        let pdf = try PageEditor.resize(noted, nil, [0], Self.a4w, Self.a4h, .scale)
        let after = try #require(Annotations.read(pdf, nil).first).rect
        let s = Self.a4w / 612
        #expect(Self.near(after.x, before.x * s, 1))
        #expect(Self.near(after.y, before.y * s + (Self.a4h - 792 * s) / 2, 1))
        #expect(Self.near(after.width, before.width * s, 1))

        let cropped = try PageEditor.crop(TestPdf.make(1), nil, [0], Margins(36, 36, 36, 36))
        let doc = try Core2Pdf.open(PageEditor.resize(cropped, nil, [0], 612, 792, .margins))
        let page = doc.page(0)
        #expect(page["CropBox"] == nil)
        let m = PageBoxes.mediaBox(page)
        #expect([m.x2 - m.x1, m.y2 - m.y1] == [612.0, 792.0])
    }

    @Test func anUnusablePaperSizeIsRefused() {
        let pdf = TestPdf.make(1)
        #expect(throws: PdfEditError.self) { try PageEditor.resize(pdf, nil, [0], .nan, 792, .scale) }
        #expect(throws: PdfEditError.self) { try PageEditor.resize(pdf, nil, [0], 612, 1e9, .scale) }
        #expect(throws: PdfEditError.self) { try PageEditor.resize(pdf, nil, [0], 10, 792, .scale) }
    }

    @Test func aSignedFileTakesItAsAnAppendedChange() throws {
        let signed = SignedEditTests.signed()
        let (edited, report) = try SignedEdits.run { try PageEditor.resize(signed, nil, [1], Self.a4w, Self.a4h, .scale) }
        #expect(report.appended)
        #expect(Array(edited.prefix(signed.count)) == signed)
        #expect(try Self.sizes(edited) == [[612, 792], [Self.a4w, Self.a4h]])
        let engine = try PdfEngine.open(edited)
        defer { engine.close() }
        #expect(try engine.text(1).text.contains("Second page"))
    }

    @Test func bookmarksAndLinksToAResizedPageLandOnTheSameSpot() throws {
        let pdf = try Bookmarks.setOutline(TestPdf.make(2), nil, [Bookmark("Here", 0, top: 100), Bookmark("Other page", 1, top: 100)])
        let resized = try PageEditor.resize(pdf, nil, [0], Self.a4w, Self.a4h, .scale)
        let s = Self.a4w / 612
        let f = (Self.a4h - 792 * s) / 2
        let read = try Bookmarks.read(resized, nil)
        #expect(Self.near(try #require(read[0].top), Self.a4h - (s * (792 - 100) + f), 1)) // the same line of the content
        #expect(Self.near(try #require(read[1].top), 100, 1)) // a page left as it was
    }

    @Test func everyKindOfDestinationMovesWithTheContent() throws {
        let doc = try MuDoc.create()
        func dest(_ kind: String, _ values: Double?...) -> PObj {
            let a = doc.array([doc.null, doc.name(kind)])
            for v in values { a.append(v.map { doc.real($0) } ?? doc.null) }
            return a
        }
        func values(_ a: PObj) -> [Double?] {
            (2..<max(2, a.count)).map { i in a[i]?.number.map { ($0 * 1000).rounded() / 1000 } }
        }

        let xyz = dest("XYZ", 10, 20, 2)
        PageEditor.moveDestination(doc, xyz, 0.5, 100, 200)
        #expect(values(xyz) == [105, 210, 2]) // the zoom stays
        let unset = dest("XYZ", nil, 20, nil)
        PageEditor.moveDestination(doc, unset, 0.5, 100, 200)
        #expect(values(unset) == [nil, 210, nil])
        let fitR = dest("FitR", 10, 20, 30, 40)
        PageEditor.moveDestination(doc, fitR, 2, 1, 1)
        #expect(values(fitR) == [21, 41, 61, 81])
        let fitH = dest("FitBH", 20)
        PageEditor.moveDestination(doc, fitH, 2, 1, 5)
        #expect(values(fitH) == [45])
        let fitV = dest("FitV", 20)
        PageEditor.moveDestination(doc, fitV, 2, 1, 5)
        #expect(values(fitV) == [41])
        let fit = dest("Fit")
        PageEditor.moveDestination(doc, fit, 2, 1, 5)
        #expect(values(fit).isEmpty)
    }
}
