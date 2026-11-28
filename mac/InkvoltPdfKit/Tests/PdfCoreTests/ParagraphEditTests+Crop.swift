import Foundation
import Testing
@testable import PdfCore

/// Crop Picture (roadmap 2.1; ported from ParagraphEditTests.Pictures.cs's Cropping part, same names): what is cut off
/// leaves the file. The files' pictures are read through MuPDF (`PObj`) where Windows reads them with PDFsharp.
extension ParagraphEditTests {
    /// A page drawing /Im1 as given, its 4 x 2 pixels one color a column: red, green, blue, white. `change`: changes to
    /// /Im1's dictionary, in its document.
    static func columns(_ content: String, _ change: ((MuDoc, PObj) -> Void)? = nil) throws -> [UInt8] {
        let pdf = ContentEditPdf.make(content)
        let doc = try Core2Pdf.open(pdf)
        let im = try #require(doc.page(0).dict("Resources")?.dict("XObject")?.dict("Im1"))
        let row: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
        im.setStream(row + row, deflate: false)
        change?(doc, im)
        try doc.checkFailure()
        return try doc.write("")
    }

    @Test func aCropKeepsOnlyThePixelsItShows() throws {
        // 100 x 50 points, 25 points a pixel: the right half (blue and white) kept, out to whole pixels.
        let pdf = try Self.columns("q 100 0 0 50 72 600 cm /Im1 Do Q")
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        #expect(Self.nearPicture(RectD(72, 142, 100, 50), image.box))
        let cropped = try ContentEditor.cropImage(pdf, nil, image, RectD(123, 150, 48, 30))
        let c = try #require(try ContentEditor.read(cropped, nil, 0).images.first)
        #expect(Self.nearPicture(RectD(122, 142, 50, 50), c.box))
        #expect(c.uncropped == nil) // nothing cut off left to show again
        #expect(!ContentEditPdf.content(cropped).contains("re W n"))
        let pictures = try Self.picturesIn(cropped)
        #expect(pictures.count == 1)
        let kept = try #require(pictures.first)
        #expect((kept.w, kept.h) == (2, 2))
        #expect(Self.holds(kept.samples, 0, 0, 255) && Self.holds(kept.samples, 255, 255, 255))
        // The red and green columns are nowhere in the file.
        #expect(!pictures.contains { Self.holds($0.samples, 255, 0, 0) || Self.holds($0.samples, 0, 255, 0) })

        // Moved and resized as any picture; cropped again; deleted.
        let moved = try ContentEditor.moveImage(cropped, nil, c, RectD(200, 300, 100, 100))
        let m = try #require(try ContentEditor.read(moved, nil, 0).images.first)
        #expect(Self.nearPicture(RectD(200, 300, 100, 100), m.box))
        let again = try ContentEditor.cropImage(moved, nil, m, RectD(250, 300, 50, 100))
        let a = try #require(try ContentEditor.read(again, nil, 0).images.first)
        #expect(Self.nearPicture(RectD(250, 300, 50, 100), a.box))
        #expect(!(try Self.picturesIn(again)).contains { Self.holds($0.samples, 0, 0, 255) })
        #expect(try ContentEditor.read(try ContentEditor.deleteImage(cropped, nil, c), nil, 0).images.isEmpty)
    }

    @Test func aPictureDrawnWithoutItsOwnSaveIsCroppedInOne() throws {
        let pdf = try Self.columns("100 0 0 50 72 600 cm /Im1 Do")
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        let cropped = try ContentEditor.cropImage(pdf, nil, image, RectD(72, 142, 50, 50))
        let c = try #require(try ContentEditor.read(cropped, nil, 0).images.first)
        #expect(Self.nearPicture(RectD(72, 142, 50, 50), c.box))
        let pictures = try Self.picturesIn(cropped)
        #expect(pictures.count == 1)
        let kept = try #require(pictures.first)
        #expect(Self.holds(kept.samples, 255, 0, 0) && !Self.holds(kept.samples, 0, 0, 255))
        let moved = try ContentEditor.moveImage(cropped, nil, c, RectD(300, 300, 50, 50))
        #expect(Self.nearPicture(RectD(300, 300, 50, 50), try ContentEditor.read(moved, nil, 0).images.first?.box))
    }

    @Test func aCropOfAQuarterTurnedPictureFollowsItsTurn() throws {
        // Turned a quarter: 50 wide and 100 tall on the page, its columns running down it.
        let pdf = try Self.columns("q 0 100 -50 0 200 500 cm /Im1 Do Q")
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        #expect(!image.turned)
        let crop = RectD(image.box.x, image.box.y, image.box.width, image.box.height / 2)
        let cropped = try ContentEditor.cropImage(pdf, nil, image, crop)
        #expect(Self.nearPicture(crop, try ContentEditor.read(cropped, nil, 0).images.first?.box))
        let pictures = try Self.picturesIn(cropped)
        #expect(pictures.count == 1)
        #expect(pictures.first.map { ($0.w, $0.h) == (2, 2) } == true)
    }

    @Test func aCropMadeByAClipOnThePageIsMadeReal() throws {
        // Another program's crop (a clip before the picture): cropping again keeps the pixels asked for, the clip goes.
        let pdf = try Self.columns("q 100 0 0 50 72 600 cm 0 0 0.5 1 re W n /Im1 Do Q")
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        #expect(Self.nearPicture(RectD(72, 142, 50, 50), image.box))
        #expect(Self.nearPicture(RectD(72, 142, 100, 50), image.uncropped))
        let cropped = try ContentEditor.cropImage(pdf, nil, image, image.box)
        #expect(!ContentEditPdf.content(cropped).contains("re W n"))
        let pictures = try Self.picturesIn(cropped)
        #expect(pictures.count == 1)
        let kept = try #require(pictures.first)
        #expect(kept.w == 2)
        #expect(!Self.holds(kept.samples, 0, 0, 255))
        #expect(Self.nearPicture(RectD(72, 142, 50, 50), try ContentEditor.read(cropped, nil, 0).images.first?.box))
    }

    @Test func aClipDrawnBeforeAPictureOutsideItsOwnSaveStays() throws {
        // The clip also governs what follows the picture (a rectangle filled after it): cropping keeps it.
        let pdf = try Self.columns("q 100 0 0 50 72 600 cm 0 0 0.75 1 re W n /Im1 Do 0 0 1 1 re f Q")
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        let cropped = try ContentEditor.cropImage(pdf, nil, image, RectD(72, 142, 50, 50))
        #expect(ContentEditPdf.content(cropped).contains("0 0 0.75 1 re W n"))
        #expect(ContentEditPdf.content(cropped).contains("0 0 1 1 re f"))
        let pictures = try Self.picturesIn(cropped)
        #expect(pictures.count == 1)
        #expect(pictures.first?.w == 2)
    }

    @Test func aCropKeepsThePicturesLayerAndIntent() throws {
        let pdf = try Self.columns("q 100 0 0 50 72 600 cm /Im1 Do Q") { doc, im in
            let layer = doc.add(doc.dict([("Type", doc.name("OCG")), ("Name", doc.text("Photos"))]))
            im.set("OC", layer)
            im.set("Intent", doc.name("Perceptual"))
        }
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        let cropped = try ContentEditor.cropImage(pdf, nil, image, RectD(122, 142, 50, 50))
        let doc = try Core2Pdf.open(cropped)
        var found: PObj?
        for n in 1..<max(doc.objectCount, 1) {
            let o = doc.object(n)
            if o.isDict && o.name("Subtype") == "Image" && o.name("ColorSpace") == "DeviceRGB" { found = o }
        }
        let kept = try #require(found)
        #expect(kept.dict("OC")?.text("Name") == "Photos")
        #expect(kept.name("Intent") == "Perceptual")
    }

    @Test func aCropThatCantBeMadeIsRefused() throws {
        let turned = ContentEditPdf.make("q 70.71 70.71 -35.36 35.36 200 400 cm /Im1 Do Q")
        let t = try #require(try ContentEditor.read(turned, nil, 0).images.first)
        #expect(t.turned)
        #expect(Self.editError { try ContentEditor.cropImage(turned, nil, t, t.box) } != nil)
        let pdf = ContentEditPdf.make("q 100 0 0 50 72 600 cm /Im1 Do Q")
        let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
        #expect(Self.editError { try ContentEditor.cropImage(pdf, nil, image, RectD(.nan, 0, 10, 10)) } != nil)
        #expect(Self.editError { try ContentEditor.cropImage(pdf, nil, image, RectD(400, 400, 50, 50)) } != nil) // outside it
        #expect(Self.editError { try ContentEditor.cropImage(pdf, nil, image, RectD(72, 142, 0.5, 50)) } != nil)
        // A stencil (an inline image mask): one color painted through it.
        let stencil = ContentEditPdf.make("q 100 0 0 50 72 600 cm BI /W 8 /H 2 /IM true ID \u{F0}\u{F0} EI Q")
        let s = try #require(try ContentEditor.read(stencil, nil, 0).images.first)
        let e = Self.editError { try ContentEditor.cropImage(stencil, nil, s, RectD(72, 142, 50, 50)) }
        #expect(e?.message.contains("stencil") == true)
        // Transparency inside JPEG 2000 data, or a soft mask blended with a matte color.
        let inData = try Self.columns("q 100 0 0 50 72 600 cm /Im1 Do Q") { doc, im in im.set("SMaskInData", doc.int(1)) }
        let i1 = try #require(try ContentEditor.read(inData, nil, 0).images.first)
        #expect(Self.editError { try ContentEditor.cropImage(inData, nil, i1, RectD(72, 142, 50, 50)) }?.message.contains("transparency") == true)
        let matte = try Self.columns("q 100 0 0 50 72 600 cm /Im1 Do Q") { doc, im in
            let mask = ImageImport.imageStream(doc, 4, 2, [UInt8](repeating: 0, count: 8), "DeviceGray")
            mask.set("Matte", doc.reals(1, 1, 1))
            im.set("SMask", mask)
        }
        let i2 = try #require(try ContentEditor.read(matte, nil, 0).images.first)
        #expect(Self.editError { try ContentEditor.cropImage(matte, nil, i2, RectD(72, 142, 50, 50)) } != nil)
        // A picture that says it is 60,000 pixels square: refused before MuPDF decodes it.
        let huge = try Self.columns("q 100 0 0 50 72 600 cm /Im1 Do Q") { doc, im in
            im.set("Width", doc.int(60000))
            im.set("Height", doc.int(60000))
        }
        let i3 = try #require(try ContentEditor.read(huge, nil, 0).images.first)
        #expect(Self.editError { try ContentEditor.cropImage(huge, nil, i3, RectD(72, 142, 1, 1)) }?.message.contains("too large") == true)
    }

    @Test func aHostileCropOnThePageIsHeldToThePicture() throws {
        // A clip that reaches far past the picture, or is no number at all, crops nothing.
        for clip in ["-5 -5 1e30 1e30 re W n", "0 0 0 0 re W n", "-1 -1 0.5 0.5 re W n"] {
            let pdf = ContentEditPdf.make("q 100 0 0 50 72 600 cm \(clip) /Im1 Do Q")
            let image = try #require(try ContentEditor.read(pdf, nil, 0).images.first)
            #expect(image.uncropped == nil)
            #expect(Self.nearPicture(RectD(72, 142, 100, 50), image.box))
        }
        // A picture claiming a size past any page's: refused before anything is drawn.
        let huge = ContentEditPdf.make("q 100 0 0 50 72 600 cm BI /W 9000000 /H 2 /CS /G /BPC 8 ID \u{0}\u{0} EI Q")
        if let h = try ContentEditor.read(huge, nil, 0).images.first, h.blocked == nil {
            #expect(Self.editError { try ContentEditor.cropImage(huge, nil, h, RectD(72, 142, 50, 50)) } != nil)
        }
    }
}
