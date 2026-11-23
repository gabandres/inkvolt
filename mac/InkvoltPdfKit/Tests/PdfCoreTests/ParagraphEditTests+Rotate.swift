import Foundation
import Testing
@testable import PdfCore

/// ParagraphEditTests.Rotate.cs (roadmap 4.22): a picture or a paragraph turned to any angle in Edit Text & Images
/// (`ContentEditor.rotateImage`, `rotateParagraph`), the turn handle's and angle box's rules (`ContentTurn`), and pdf.js
/// reading a turned paragraph's words in order (opt-in, as the other pdf.js test).
extension ParagraphEditTests {
    private static func near(_ expected: PointD, _ actual: PointD, _ slack: Double = 0.5) -> Bool {
        abs(expected.x - actual.x) < slack && abs(expected.y - actual.y) < slack
    }

    @Test(arguments: [30.0, -45, 90, 180])
    func aParagraphTurnsAboutItsMiddleKeepingItsTextAndWhatFollows(_ degrees: Double) throws {
        // Room all round (a turned paragraph reaching the heading would take it in as text inside it).
        let pdf = Self.turnedPdf(0, 150, 450, gap: 160)
        let before = try ContentEditor.read(pdf, nil, 0)
        let p = try Self.body0(pdf)
        let others = before.runs.filter { r in !p.runs.contains { $0.id == r.id } && !r.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (text: $0.text, box: $0.box) }
        #expect(!others.isEmpty)

        let turned = try ContentEditor.rotateParagraph(pdf, nil, p, degrees)
        let after = try ContentEditor.read(turned, nil, 0)
        let qs = after.paragraphs.filter { $0.text.hasPrefix("The quick") }
        #expect(qs.count == 1)
        let q = try #require(qs.first)
        // The same words, in the turned direction, about the same middle.
        #expect(q.text == p.text)
        #expect(q.lines.count == p.lines.count)
        #expect(Self.sameDirection(degrees, q.angle), "\(q.angle)° is not \(degrees)°")
        #expect(Self.near(PointD(p.box.centerX, p.box.centerY), PointD(q.box.centerX, q.box.centerY), 2))
        // Each glyph run turned about that middle: the first line's start went where the turn takes it.
        let first = try #require(p.runs.min { $0.origin.y + $0.origin.x / 1000 < $1.origin.y + $1.origin.x / 1000 })
        let r = degrees * .pi / 180
        let s = sin(r), c = cos(r)
        let cx = p.box.centerX, cy = p.box.centerY
        let ex: Double = cx + (first.origin.x - cx) * c - (first.origin.y - cy) * s
        let ey: Double = cy + (first.origin.x - cx) * s + (first.origin.y - cy) * c
        let expected = PointD(ex, ey)
        func off(_ o: PointD) -> Double { abs(o.x - expected.x) + abs(o.y - expected.y) }
        let firstAfter = try #require(after.runs.filter { $0.text == first.text }.min { off($0.origin) < off($1.origin) })
        #expect(Self.near(expected, firstAfter.origin, 0.6), "\(firstAfter.origin) is not \(expected)")
        // What follows is where it was.
        let lost = others.filter { o in !after.runs.contains { $0.text == o.text && abs($0.box.x - o.box.x) < 0.5 && abs($0.box.y - o.box.y) < 0.5 } }
        #expect(lost.isEmpty, "\(lost.map { "\($0.text) at \($0.box)" })")

        // Turned back: where it started.
        let back = try ContentEditor.rotateParagraph(turned, nil, q, -degrees)
        let again = try #require(ContentEditor.read(back, nil, 0).paragraphs.first { $0.text.hasPrefix("The quick") })
        #expect(abs(again.angle) < 1e-3)
        #expect(again.lines.count == p.lines.count)
        for i in 0..<min(p.lines.count, again.lines.count) {
            #expect(abs(p.lines[i].x - again.lines[i].x) < 0.1 && abs(p.lines[i].y - again.lines[i].y) < 0.1, "line \(i)")
        }
        #expect(try ContentEditor.rotateParagraph(pdf, nil, p, 360) == pdf)
    }

    @Test func aTurnedParagraphStaysEditableAndAFormsParagraphTurnsInItsForm() throws {
        let pdf = Self.turnedPdf(30, 150, 300)
        let p = try Self.body0(pdf)
        let turned = try ContentEditor.rotateParagraph(pdf, nil, p, 20)
        let q = try Self.body0(turned)
        #expect(Self.sameDirection(p.angle + 20, q.angle), "\(q.angle)° is not \(p.angle + 20)°")
        // Still a paragraph that reflows in its own direction.
        let edited = try ContentEditor.replaceParagraph(turned, nil, q, q.text + " " + Self.twenty)
        #expect(try Self.body0(edited).text == q.text + " " + Self.twenty)

        let form = ContentEditPdf.make("q /Fm1 Do Q", form: Self.formBody(), fontText: Self.chars)
        let fp = try #require(ContentEditor.read(form, nil, 0).paragraphs.filter { $0.blocked == nil }.max { $0.lines.count < $1.lines.count })
        let ft = try ContentEditor.rotateParagraph(form, nil, fp, -15)
        let afters = try ContentEditor.read(ft, nil, 0).paragraphs.filter { $0.text == fp.text }
        #expect(afters.count == 1)
        #expect(Self.sameDirection(-15, afters.first?.angle ?? 99))
    }

    @Test func aPictureTurnsAboutItsMiddleAndSaysItsAngle() throws {
        let pictures = "q 100 0 0 50 72 600 cm /Im1 Do Q\nq 40 0 0 20 300 300 cm /Im1 Do Q"
        let pdf = ContentEditPdf.make(pictures)
        let images = try ContentEditor.read(pdf, nil, 0).images
        #expect(images[0].angle == 0)
        let center = PointD(images[0].box.centerX, images[0].box.centerY)

        let turned = try ContentEditor.rotateImage(pdf, nil, images[0], 90)
        let after = try ContentEditor.read(turned, nil, 0).images
        #expect(abs(after[0].angle - 90) < 1e-3)
        #expect(Self.near(center, PointD(after[0].box.centerX, after[0].box.centerY)))
        #expect(abs(after[0].box.width - 50) < 0.1) // a quarter turn: its width is its height
        #expect(abs(after[0].box.height - 100) < 0.1)
        #expect(after[1].box == images[1].box) // the other use stays

        let more = try ContentEditor.rotateImage(turned, nil, after[0], -60)
        let a2 = try ContentEditor.read(more, nil, 0).images[0]
        #expect(abs(a2.angle - 30) < 1e-3)
        #expect(a2.turned)
        #expect(Self.near(center, PointD(a2.box.centerX, a2.box.centerY)))
        // The bounding box of a 100 x 50 box turned 30°.
        #expect(abs(a2.box.width - (100 * cos(Double.pi / 6) + 50 * sin(Double.pi / 6))) < 0.1)

        // MuPDF draws it there.
        let engine = try PdfEngine.open(more)
        defer { engine.close() }
        let shown = try engine.exportRead(0, images: true, jpegAbovePixels: 1 << 20, cancel: nil).images.map(\.box)
        #expect(shown.contains { abs($0.x + $0.width / 2 - center.x) < 1 && abs($0.y + $0.height / 2 - center.y) < 1 })

        #expect(try ContentEditor.rotateImage(pdf, nil, images[0], 0) == pdf)
        // On a turned page, the turn is as the page shows.
        let onTurned = ContentEditPdf.make(pictures, rotate: 90)
        let img = try ContentEditor.read(onTurned, nil, 0).images[0]
        let t = try ContentEditor.read(ContentEditor.rotateImage(onTurned, nil, img, 45), nil, 0).images[0]
        #expect(abs(t.angle - ContentTurn.normalize(img.angle + 45)) < 1e-3)
    }

    @Test func theTurnHandleAndAngleBoxRules() {
        #expect(ContentTurn.normalize(190) == -170)
        #expect(ContentTurn.normalize(-180) == 180)
        #expect(ContentTurn.normalize(720) == 0)
        #expect(ContentTurn.normalize(.nan) == 0)

        let box = RectD(100, 100, 200, 100)
        #expect(ContentTurn.handlePoint(box) == PointD(300 + ContentTurn.handleGap, 100 - ContentTurn.handleGap))
        #expect(ContentTurn.onHandle(box, PointD(318, 82), 5))
        #expect(!ContentTurn.onHandle(box, PointD(300, 100), 5))

        // From straight above the middle to straight right of it: a quarter turn clockwise.
        let c = PointD(200, 150)
        #expect(abs(ContentTurn.dragged(c, PointD(200, 50), PointD(300, 150), 0, steps: false) - 90) < 1e-6)
        #expect(abs(ContentTurn.dragged(c, PointD(200, 50), PointD(300, 150), 10, steps: false) - 100) < 1e-6)
        // Shift: the nearest 15°.
        let a = ContentTurn.dragged(c, PointD(200, 50), PointD(300, 140), 0, steps: false)
        #expect(a >= 80 && a <= 90)
        #expect(ContentTurn.dragged(c, PointD(200, 50), PointD(300, 140), 0, steps: true) == 90)
        #expect(ContentTurn.dragged(c, PointD(200, 50), c, 0, steps: false) == 0)
        #expect(abs(ContentTurn.dragged(c, PointD(200, 50), PointD(100, 150), 0, steps: false) + 90) < 1e-6)

        let posix = Locale(identifier: "en_US_POSIX")
        #expect(ContentTurn.parse("30°") == 30)
        #expect(ContentTurn.parse(" -12.5 ", locale: posix) == -12.5)
        #expect(ContentTurn.parse("12,5", locale: Locale(identifier: "es_ES")) == 12.5)
        #expect(ContentTurn.parse("270") == -90)
        #expect(ContentTurn.parse("abc") == nil)
        #expect(ContentTurn.parse("") == nil)
        #expect(ContentTurn.parse("1e300") == nil)

        #expect(ContentTurn.turnBy(10, 30) == 20)
        #expect(ContentTurn.turnBy(170, 150) == -20)
        #expect(ContentTurn.turnBy(170, -170) == 20)
        #expect(ContentTurn.turnBy(45, 45.001) == nil)
        #expect(ContentTurn.format(-12.5, locale: posix) == "-12.5°")

        let corners = ContentTurn.corners(RectD(0, 0, 20, 10), 90)
        #expect(Self.near(PointD(15, -5), corners[0], 1e-6))
        #expect(Self.near(PointD(15, 15), corners[1], 1e-6))
    }

    @Test func turnedParagraphsReadTheSameInPdfJs() throws {
        guard let flag = ProcessInfo.processInfo.environment["INKVOLTPDF_PDFJS"], !flag.isEmpty else { return }
        guard let node = Self.onPath("node"), let npm = Self.onPath("npm") else {
            print("Skipped: node or npm isn't on the PATH.")
            return
        }
        if !FileManager.default.fileExists(atPath: Self.pdfJsTool.appendingPathComponent("node_modules").path) {
            _ = try Self.runTool(npm, ["ci", "--no-audit", "--no-fund"], Self.pdfJsTool)
        }
        var failures: [String] = []
        for degrees in [30.0, -15, 90, 180] {
            let pdf = Self.turnedPdf(0, 150, 450, gap: 160)
            let p = try Self.body0(pdf)
            let turned = try ContentEditor.rotateParagraph(pdf, nil, p, degrees)
            let got = try Self.pdfJsText(node, turned, 0)
            let miss = Self.firstMiss(p.text, got)
            print("turned \(degrees)°: pdf.js \(miss == nil ? "reads it in order" : "DIFFERS: " + (miss ?? ""))")
            if let miss { failures.append("turned \(degrees)°: \(miss)") }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
