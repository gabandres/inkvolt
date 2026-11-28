import Foundation
import Testing
@testable import PdfCore

/// Edit Text & Images (roadmap 2.1): pictures in a paragraph's flow, and new pictures put into it
/// (ported from ParagraphEditTests.Pictures.cs, same names). The files' pictures are read through MuPDF (`PObj`) where
/// Windows reads them with PDFsharp.
extension ParagraphEditTests {
    static func near(_ expected: RectD, _ actual: RectD, within: Double) -> Bool {
        abs(expected.x - actual.x) < within && abs(expected.y - actual.y) < within
            && abs(expected.width - actual.width) < within && abs(expected.height - actual.height) < within
    }

    static func nearPicture(_ expected: RectD, _ actual: RectD?) -> Bool {
        guard let actual else { return false }
        let ok = near(expected, actual, within: 0.6)
        if !ok { Issue.record("\(expected) ≠ \(actual)") }
        return ok
    }

    static let mark = "\u{FFFC}"

    // ---- Pictures in the flow ----

    /// Body as a left-aligned paragraph with a 12 x 9 pt picture (/Im1) on its line `line` after its third word, its foot
    /// a point below the baseline, the words around it 18 pt apart; a line of text under the paragraph. `height`: its
    /// height (points).
    static func withPicture(line: Int = 1, height: Double = 9) -> (pdf: [UInt8], pre: String) {
        let lines = wrap(body, width - 30)
        let words = lines[line].split(separator: " ").map(String.init)
        let pre = words.prefix(3).joined(separator: " ")
        let post = words.dropFirst(3).joined(separator: " ")
        var sb = "BT /FA \(n(size)) Tf \(n(step)) TL \(n(left)) \(n(top)) Td"
        for (i, l) in lines.enumerated() {
            if i > 0 { sb += " T*" }
            sb += i == line ? " (\(pre)) Tj [\(n(-18 * 1000 / size))] TJ (\(post)) Tj" : " (\(l)) Tj"
        }
        sb += " 0 -60 Td (Next block starts here) Tj ET\n"
        let x: Double = left + measure(pre) + 3
        sb += "q 12 0 0 \(n(height)) \(n(x)) \(n(top - Double(line) * step - 1)) cm /Im1 Do Q\n"
        return (ContentEditPdf.make(sb, fontText: chars), pre)
    }

    static func withoutMarks(_ s: String) -> String { s.replacingOccurrences(of: " " + mark, with: "") }

    @Test func takingATallPictureOffTheFirstLineLiftsNothing() throws {
        // A picture twice the type's height on the first line: without it, the first line stays where it was.
        let (pdf, _) = Self.withPicture(line: 0, height: 22)
        let p = try Self.body0(pdf)
        #expect(p.pictures.count == 1)
        let first = p.runs[0].origin.y
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.withoutMarks(p.text))
        #expect(Self.equal(first, try Self.body0(edited).runs[0].origin.y, 1))
        // Kept, and unchanged text in front of it: the first line stays too.
        let same = try ContentEditor.replaceParagraph(pdf, nil, p, p.text + " end")
        #expect(Self.equal(first, try Self.body0(same).runs[0].origin.y, 1))
    }

    @Test func aPictureBeforeALineThatIsntInTheFlowDoesntWidenIt() throws {
        // The second line starts after a picture lined up with the line above, but its foot hangs 7 points below the
        // baseline: not a picture in the flow, so the line isn't widened to it and rewritten text isn't drawn over it.
        let lines = Self.wrap(Self.body, Self.width)
        var sb = "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.left)) \(Self.n(Self.top)) Td (\(lines[0])) Tj ET\n"
        sb += "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.left + 16)) \(Self.n(Self.top - Self.step)) Td (\(lines[1])) Tj ET\n"
        sb += "q 12 0 0 9 \(Self.n(Self.left)) \(Self.n(Self.top - Self.step - 7)) cm /Im1 Do Q\n"
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let content = try ContentEditor.read(pdf, nil, 0)
        #expect(content.images.count == 1)
        let picture = try #require(content.images.first).box
        for p in content.paragraphs where p.blocked == nil {
            #expect(p.pictures.isEmpty)
            let edited = try ContentEditor.replaceParagraph(pdf, nil, p, p.text + " and a few more words here", allowOverlap: true)
            #expect(!(try ContentEditor.read(edited, nil, 0).runs.contains { r in
                let i = r.box.intersect(picture)
                return i.width > 1 && i.height > 1
            }))
        }
    }

    @Test func aMarkThePagesOwnTextHasIsNoPicture() {
        // The text has a U+FFFC of its own (a glyph whose ToUnicode says so) before the picture's mark: each keeps its part.
        let old = "a \(Self.mark) b \(Self.mark) c"
        var picture = InlinePicture(image: PageImage(pageIndex: 0, id: 1, box: RectD(0, 0, 1, 1), inline: false, blocked: nil), drop: 0)
        picture.mark = 6
        let pictures = [picture]
        let textMark = ContentEditor.textMark
        #expect(ContentEditor.pictureMarks(old, old, pictures) == [textMark, 0])
        #expect(ContentEditor.pictureMarks(old, "x " + old, pictures) == [textMark, 0])
        #expect(ContentEditor.pictureMarks(old, "a b \(Self.mark) c", pictures) == [0]) // the page's own one deleted
        #expect(ContentEditor.pictureMarks(old, "a \(Self.mark) b c", pictures) == [textMark]) // the picture's deleted
        #expect(ContentEditor.pictureMarks(old, old + " " + Self.mark, pictures) == [textMark, 0, -1]) // one typed in
    }

    @Test func aPictureOnAParagraphsLineIsPartOfItsFlow() throws {
        let (pdf, pre) = Self.withPicture()
        let content = try ContentEditor.read(pdf, nil, 0)
        let p = try Self.body0(pdf)
        #expect(p.blocked == nil)
        #expect(p.pictures.count == 1)
        let picture = try #require(p.pictures.first)
        #expect(content.images.count == 1)
        #expect(content.images.first == picture.image)
        #expect(Self.equal(1, picture.drop, 1))
        #expect(p.text.contains(pre + " " + Self.mark + " "))
        #expect(Self.withoutMarks(p.text) == Self.body)
    }

    @Test func thePictureMovesWithItsPlaceInTheText() throws {
        let (pdf, pre) = Self.withPicture()
        let p = try Self.body0(pdf)
        let old = try #require(p.pictures.first).image.box
        let text = "Now then, a few more words in front " + p.text
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text)
        let content = try ContentEditor.read(edited, nil, 0)
        #expect(content.images.count == 1)
        let image = try #require(content.images.first)
        #expect(!(abs(image.box.x - old.x) < 1 && abs(image.box.y - old.y) < 1), "moved")
        #expect(Self.equal(old.width, image.box.width, 1))
        #expect(Self.equal(old.height, image.box.height, 1))
        // Read again, the picture is in the same place of the text, between the same words, its foot as far below its line.
        let q = try Self.body0(edited, "Now then")
        #expect(q.text == text)
        #expect(q.pictures.count == 1)
        #expect(Self.equal(1, try #require(q.pictures.first).drop, 1))
        let lastPre = String(pre.split(separator: " ").last!)
        let before = try #require(q.runs.last { r in
            trimmed(r.text).hasSuffix(lastPre) && r.box.right <= image.box.x + 0.5 && abs(r.box.centerY - image.box.centerY) < Self.size
        })
        #expect(image.box.x - before.box.right < 0.5 * Self.size + 3)
        // One edit, one undo step: the earlier bytes have the picture where it was.
        #expect(Self.nearPicture(old, try ContentEditor.read(pdf, nil, 0).images.first?.box))
    }

    @Test func aPictureWrappedToTheStartOfALineIsStillInTheSameParagraph() throws {
        // The picture moved to the front, after a word that grows until the picture no longer fits beside it and starts
        // the second line: read again, it is one paragraph with the same text.
        let (pdf, _) = Self.withPicture()
        let p = try Self.body0(pdf)
        let rest = Self.withoutMarks(p.text)
        for n in 60...160 {
            let text = "Now" + String(repeating: "i", count: n) + " " + Self.mark + " " + rest
            let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, allowOverlap: true)
            let image = try #require(try ContentEditor.read(edited, nil, 0).images.first)
            if abs(image.box.x - Self.left) > 1 { continue }
            let q = try Self.body0(edited, "Now")
            #expect(q.text == text)
            #expect(q.pictures.count == 1)
            #expect(Self.equal(1, q.pictures.first?.drop ?? .nan, 1))
            return
        }
        Issue.record("the picture never started a line")
    }

    @Test func takingThePicturesMarkOutTakesThePictureOff() throws {
        let (pdf, _) = Self.withPicture()
        let p = try Self.body0(pdf)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.withoutMarks(p.text))
        let content = try ContentEditor.read(edited, nil, 0)
        #expect(content.images.isEmpty)
        #expect(try Self.body0(edited).text == Self.body)
        #expect(!ContentEditPdf.content(edited).contains("/Im1 Do"))
    }

    @Test func aMarkTypedInIsNoPicture() throws {
        let (pdf, _) = Self.withPicture()
        let p = try Self.body0(pdf)
        let text = p.text + " " + Self.mark
        #expect(p.check(text).missing.contains(Self.mark))
        let e = Self.editError { try ContentEditor.replaceParagraph(pdf, nil, p, text) }
        #expect(e?.message.contains("can't be typed") == true)
        // A paragraph without pictures: the mark is no picture either.
        let (plain, _) = Self.page(.left)
        #expect(Self.editError { try ContentEditor.replaceParagraph(plain, nil, try Self.body0(plain), Self.body + " " + Self.mark) } != nil)
    }

    @Test func aPictureUnderTheTextIsNotInItsFlow() throws {
        // A picture the paragraph's text is drawn over (a background) stays where it is, outside the text.
        let (page, _) = Self.page(.left, gap: 120)
        let pdf = ContentEditPdf.make(ContentEditPdf.content(page) + "\nq 60 0 0 9 \(Self.n(Self.left + 10)) \(Self.n(Self.top - 1)) cm /Im1 Do Q\n",
                                      fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.pictures.isEmpty)
        #expect(p.text == Self.body)
    }

    // ---- New pictures in the flow ----

    /// A 30 x 10 pixel PNG, orange.
    static func orange() -> NewPicture {
        NewPicture(file: PngEncoder.encode(30, 10, Array([[UInt8]](repeating: [255, 140, 0], count: 300).joined()), alpha: false), name: "orange.png")
    }

    @Test func aNewPictureGoesIntoTheFlowWhereItsMarkIs() throws {
        let (pdf, _) = Self.page(.left, gap: 120)
        let p = try Self.body0(pdf)
        #expect(p.pictures.isEmpty)
        let text = p.text.replacingOccurrences(of: "boxing", with: "boxing " + Self.mark)
        // The editor's note: the mark stands for the picture, nothing missing.
        #expect(p.check(text, added: [Self.orange()]).missing.isEmpty)
        #expect(p.check(text).missing.contains(Self.mark)) // without the picture: a mark for nothing
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, added: [Self.orange()])
        let images = try ContentEditor.read(edited, nil, 0).images
        #expect(images.count == 1)
        let image = try #require(images.first)
        // As tall as the capitals reach, three times as wide, its foot on the baseline, after "boxing".
        #expect(Self.equal(3 * image.box.height, image.box.width, 1))
        #expect(image.box.height > 0.6 * Self.size && image.box.height < 1.1 * Self.size)
        let q = try Self.body0(edited)
        #expect(q.text == text)
        #expect(q.pictures.count == 1)
        #expect(Self.equal(0, q.pictures.first?.drop ?? .nan, 1))
        let boxing = try #require(q.runs.first { trimmed($0.text).hasSuffix("boxing") })
        #expect(q.runs.filter { trimmed($0.text).hasSuffix("boxing") }.count == 1)
        #expect(image.box.x >= boxing.box.right - 0.5 && image.box.x - boxing.box.right < 0.5 * Self.size) // its run ends with the space before it
        // Its pixels are the file's: orange.
        #expect(try Self.picturesIn(edited).contains { $0.w == 30 && $0.h == 10 && Self.holds($0.samples, 255, 140, 0) })
        // Edited again, it is one of the paragraph's pictures and moves with its words.
        let again = try ContentEditor.replaceParagraph(edited, nil, q, "Now then " + q.text)
        #expect(try Self.body0(again, "Now then").text == "Now then " + text)
    }

    @Test(arguments: ["flipped", "scaled"])
    func aNewPictureUnderTheGeneratorsOwnCtmLandsByItsWord(_ kind: String) throws {
        // The text drawn under a cm of the generator's: flipped (top-down, as many converters write) or scaled by 0.5.
        let lines = Self.wrap(Self.body, Self.width)
        var sb = kind == "flipped" ? "q 1 0 0 -1 0 792 cm BT /FA 11 Tf" : "q 0.5 0 0 0.5 0 0 cm BT /FA 22 Tf"
        for (i, line) in lines.enumerated() {
            let y: Double = Self.top - Double(i) * Self.step
            sb += kind == "flipped" ? " 1 0 0 -1 \(Self.n(Self.left)) \(Self.n(792 - y)) Tm (\(line)) Tj"
                : " 1 0 0 1 \(Self.n(2 * Self.left)) \(Self.n(2 * y)) Tm (\(line)) Tj"
        }
        sb += " ET Q\nBT /FA 11 Tf 72 500 Td (Next block starts here) Tj ET"
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let p = try Self.body0(pdf)
        let text = p.text.replacingOccurrences(of: "boxing", with: "boxing " + Self.mark)
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, added: [Self.orange()])
        let image = try #require(try ContentEditor.read(edited, nil, 0).images.first)
        let q = try Self.body0(edited)
        let boxing = try #require(q.runs.first { trimmed($0.text).hasSuffix("boxing") })
        #expect(abs(image.box.bottom - boxing.origin.y) < 1, "\(image.box) on \(boxing.origin)") // its foot on the baseline
        #expect(image.box.x >= boxing.box.right - 0.5 && image.box.x - boxing.box.right < 0.5 * Self.size)
        #expect(Self.equal(3 * image.box.height, image.box.width, 1))
        #expect(q.text == text)
    }

    @Test func anInsertedMarkIsTheNewPicturesThoughAnOldOneMoved() throws {
        // The paragraph's picture cut from its line and pasted at the end; a new one inserted at the start: each its own.
        let (pdf, _) = Self.withPicture()
        let p = try Self.body0(pdf)
        let text = Self.mark + " " + Self.withoutMarks(p.text) + " " + Self.mark
        var new = Self.orange()
        new.mark = 0
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, allowOverlap: true, added: [new])
        let images = try ContentEditor.read(edited, nil, 0).images
        #expect(images.count == 2)
        let first = try #require(images.min { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) })
        #expect(Self.equal(3, first.box.width / first.box.height, 1)) // the new, orange one where it was inserted
        #expect(Self.equal(Self.left, first.box.x, 0))
        let moved = try #require(images.first { $0 != first })
        #expect((moved.box.width.rounded(), moved.box.height.rounded()) == (12, 9)) // the old one, at the end
    }

    @Test func takingATallPictureOffTheEndOfTheFirstLineLiftsNothing() throws {
        // A picture twice the type's height right after the first line's last word (the line reaches to it).
        let lines = Self.wrap(Self.body, Self.width - 40)
        var sb = "BT /FA \(Self.n(Self.size)) Tf \(Self.n(Self.step)) TL \(Self.n(Self.left)) \(Self.n(Self.top)) Td (\(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
        sb += " 0 -60 Td (Next block starts here) Tj ET\n"
        sb += "q 12 0 0 22 \(Self.n(Self.left + Self.measure(lines[0]) + 3)) \(Self.n(Self.top)) cm /Im1 Do Q\n"
        let pdf = ContentEditPdf.make(sb, fontText: Self.chars)
        let p = try Self.body0(pdf)
        #expect(p.pictures.count == 1)
        let first = p.runs[0].origin.y
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, Self.withoutMarks(p.text))
        #expect(Self.equal(first, try Self.body0(edited).runs[0].origin.y, 1))
    }

    @Test func newPicturesTakeTheTypedMarksInOrderAndNoMore() throws {
        let (pdf, _) = Self.page(.left, gap: 120)
        let p = try Self.body0(pdf)
        let wide = NewPicture(file: PngEncoder.encode(10, 10, [UInt8](repeating: 0, count: 300), alpha: false), name: "black.png")
        let text = Self.mark + " " + p.text + " " + Self.mark
        let edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, added: [Self.orange(), wide])
        let images = try ContentEditor.read(edited, nil, 0).images.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
        #expect(images.count == 2)
        guard images.count == 2 else { return }
        #expect(Self.equal(3, images[0].box.width / images[0].box.height, 1)) // the first mark: the orange one
        #expect(Self.equal(1, images[1].box.width / images[1].box.height, 1))
        // Three marks for two pictures: the last stands for nothing.
        #expect(Self.editError { try ContentEditor.replaceParagraph(pdf, nil, p, text + " " + Self.mark, added: [Self.orange(), wide]) } != nil)
        // Not an image: refused, nothing written.
        #expect(Self.editError { try ContentEditor.replaceParagraph(pdf, nil, p, text, added: [Self.orange(), NewPicture(file: [1, 2, 3], name: "x.png")]) } != nil)
    }

    /// Every picture the file holds, as its pixel size and samples (RGB triples).
    static func picturesIn(_ pdf: [UInt8]) throws -> [(w: Int, h: Int, samples: [UInt8])] {
        let doc = try Core2Pdf.open(pdf)
        var found: [(w: Int, h: Int, samples: [UInt8])] = []
        for n in 1..<max(doc.objectCount, 1) {
            let o = doc.object(n)
            guard o.isDict, o.name("Subtype") == "Image", o.name("ColorSpace") == "DeviceRGB" else { continue }
            found.append((o.int("Width") ?? 0, o.int("Height") ?? 0, o.streamData ?? []))
        }
        return found
    }

    static func holds(_ samples: [UInt8], _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        var i = 0
        while i + 2 < samples.count {
            if samples[i] == r && samples[i + 1] == g && samples[i + 2] == b { return true }
            i += 3
        }
        return false
    }
}
