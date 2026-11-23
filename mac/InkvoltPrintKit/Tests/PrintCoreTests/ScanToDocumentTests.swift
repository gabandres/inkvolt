import Foundation
import Testing
@testable import PrintCore

/// Ported from ScanToDocumentTests.cs: a scan saved straight to Word or text (roadmap 4.14): paragraphs from the recognized
/// lines, pictures for photos. Adapted: the .docx is read back with PrintCore's `ZipArchive.entries` (the Mac's parts are
/// stored, not deflated) and its XML by the paragraphs' tags as `XmlOut` writes them (no XML reader on the PC's Foundation);
/// a Swift string holds no lone surrogate, so the misread text's is U+FFFF, which XML can't hold either.
struct ScanToDocumentTests {
    /// A line of words `height` tall at `top`.
    private static func line(_ text: String, _ top: Double, _ height: Double = 30) -> [PdfWriter.Word] {
        var x = 100.0
        return text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            let length = Double(word.utf16.count)
            defer { x += (length + 1) * height * 0.5 }
            return PdfWriter.Word(String(word), x: x, y: top, width: length * height * 0.5, height: height)
        }
    }

    /// A heading, a paragraph of two lines (a word broken across them), a gap, a paragraph of one line.
    private static func letter() -> [PdfWriter.Word] {
        line("Quarterly report", 100, 60) + line("The year began with steady sales of ink-", 200)
            + line("jet paper and toner across every region.", 245) + line("Shipping costs fell in the spring.", 340)
    }

    @Test func linesBecomeParagraphsAndAHeading() {
        let paragraphs = PageText.paragraphs(PageText.lines(Self.letter()))
        #expect(paragraphs == [
            TextParagraph("Quarterly report", heading: true),
            TextParagraph("The year began with steady sales of inkjet paper and toner across every region.", heading: false),
            TextParagraph("Shipping costs fell in the spring.", heading: false),
        ])
        #expect(PageText.paragraphs([]).isEmpty)
        // A punch hole beside the heading, read as "O", isn't part of it.
        #expect(PageText.paragraphs(PageText.lines([PdfWriter.Word("O", x: 0, y: 100, width: 20, height: 60)] + Self.letter()))[0].text == "Quarterly report")
        // A hyphen before a capital or a number stays: "Wi-" "Fi", "2025-" "2026".
        #expect(PageText.paragraphs(PageText.lines(Self.line("Set up Wi-", 100) + Self.line("Fi", 145)))[0].text == "Set up Wi- Fi")
    }

    /// The archive's parts by name, and document.xml's paragraphs: their text, whether a heading, whether from a new page.
    private struct Opened {
        var parts: [String: [UInt8]]
        var xml: String
        var paragraphs: [(text: String, heading: Bool, breaks: Bool)]
    }

    private static func open(_ docx: [UInt8]) throws -> Opened {
        let parts = Dictionary(try ZipArchive.entries(docx).map { ($0.name, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        let xml = String(decoding: try #require(parts["word/document.xml"]), as: UTF8.self)
        let re = try NSRegularExpression(pattern: "<w:p>(.*?)</w:p>|<w:p />", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        let t = try NSRegularExpression(pattern: "<w:t xml:space=\"preserve\">(.*?)</w:t>", options: [.dotMatchesLineSeparators])
        let paragraphs = re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { m -> (String, Bool, Bool) in
            let body = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
            let b = body as NSString
            let text = t.matches(in: body, range: NSRange(location: 0, length: b.length)).map { b.substring(with: $0.range(at: 1)) }.joined()
            let plain = text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
            return (plain, body.contains("<w:pStyle w:val=\"Heading1\" />"), body.contains("<w:pageBreakBefore />"))
        }
        return Opened(parts: parts, xml: xml, paragraphs: paragraphs)
    }

    @Test func aWordDocumentHasTheTextHeadingsAndPicturesEachPageOnItsOwn() throws {
        let photo = TestJpeg.build(width: 1800, height: 1200, dnlHeight: nil)
        let pages = [
            ScanDocPage(Self.letter(), dpi: 300),
            ScanDocPage(nil, dpi: 300, pictures: [photo, photo]), // two photos from the glass: stored once
            ScanDocPage(Self.line("Thank you", 100), dpi: 300),
        ]
        let doc = try Self.open(try ScanDocx.write(pages, title: "Report"))
        #expect(doc.paragraphs.map(\.text) == ["Quarterly report", "The year began with steady sales of inkjet paper and toner across every region.",
                                               "Shipping costs fell in the spring.", "", "", "Thank you"])
        #expect(doc.paragraphs[0].heading)
        // The second and third scanned pages start new pages in Word; the first doesn't.
        #expect(doc.paragraphs.map(\.breaks) == [false, false, false, true, false, true])
        #expect(doc.xml.components(separatedBy: "<wp:inline>").count - 1 == 2)
        #expect(doc.parts.keys.filter { $0.hasPrefix("word/media/") }.count == 2)
        // 6 × 4 inches at 300 dpi: its own size, in EMU.
        #expect(doc.xml.contains("<wp:extent cx=\"5486400\" cy=\"3657600\" />"))
        for part in ["[Content_Types].xml", "_rels/.rels", "word/_rels/document.xml.rels", "word/styles.xml", "docProps/core.xml", "docProps/app.xml"] {
            let text = String(decoding: try #require(doc.parts[part], "\(part)"), as: UTF8.self)
            #expect(text.hasPrefix("<?xml"))
        }
        #expect(String(decoding: doc.parts["docProps/app.xml"] ?? [], as: UTF8.self).contains("Inkvolt Print"))
    }

    @Test func aLargePictureIsMadeToFitThePageAndABrokenOneIsLeftOut() throws {
        let size = try #require(ScanDocx.size(TestJpeg.build(width: 2550 * 2, height: 3300 * 2, dnlHeight: nil), dpi: 300)) // 17 × 22 inches
        #expect(size.cx == Int64(ScanDocx.maxWidth * 914_400))
        #expect(abs(Double(size.cy) / Double(size.cx) - 22 / 17.0) <= 0.001)
        #expect(ScanDocx.size([1, 2, 3], dpi: 300) == nil)
        let doc = try Self.open(try ScanDocx.write([ScanDocPage(nil, dpi: 300, pictures: [[1, 2, 3]])], title: nil))
        #expect(doc.paragraphs.count == 1) // nothing to show: the one paragraph Word needs
    }

    @Test func textTheScannerMisreadIntoControlCharactersStillMakesADocument() throws {
        let doc = try Self.open(try ScanDocx.write([ScanDocPage(Self.line("bad \u{1}\u{7} text \u{FFFF} here", 100), dpi: 300)], title: "\u{2}title"))
        #expect(doc.paragraphs.map(\.text).joined() == "bad  text  here")
    }

    @Test func aTextFileHasTheParagraphsAndPagesApart() {
        let text = ScanText.text([ScanDocPage(Self.letter(), dpi: 300), ScanDocPage(nil, dpi: 300, pictures: [TestJpeg.build(width: 10, height: 10, dnlHeight: nil)]),
                                  ScanDocPage(Self.line("Thank you", 100), dpi: 300)])
        #expect(text == "Quarterly report\r\n\r\nThe year began with steady sales of inkjet paper and toner across every region.\r\n\r\n"
            + "Shipping costs fell in the spring.\r\n\r\n\r\nThank you\r\n")
        #expect(ScanText.text([ScanDocPage(nil, dpi: 300)]) == "")
        let bytes = ScanText.write([ScanDocPage(Self.line("Año nuevo", 100), dpi: 300)])
        #expect(Array(bytes.prefix(3)) == [0xEF, 0xBB, 0xBF]) // UTF-8 that Notepad and older tools read alike
        #expect(String(decoding: bytes.dropFirst(3), as: UTF8.self) == "Año nuevo\r\n")
    }

    @Test func wordAndTextPresetsReadThePagesAndSaveTheirKindOfFile() {
        let input = InputCaps(minWidth: 0, maxWidth: 2550, minHeight: 0, maxHeight: 3508, colorModes: ["RGB24", "Grayscale8"],
                              documentFormats: ["image/jpeg"], resolutions: [300], intents: ["Document"])
        let caps = ScannerCapabilities(version: "2.6", makeAndModel: "Test", uuid: nil, platen: input, adf: nil, adfDuplex: false)
        for type in [PresetFileType.word, .text] {
            var preset = ScanPreset()
            preset.id = "w"
            preset.name = "Letters"
            preset.fileType = type
            preset.smallerFile = true
            #expect(PresetPlan.plan(preset, caps, feederLoaded: nil, ocrAvailable: true, metric: false).ocr)
            #expect(PresetPlan.plan(preset, caps, feederLoaded: nil, ocrAvailable: false, metric: false).notes.count == 1) // what it means without text recognition
            #expect(!ScanPresets.savesSmallerFile(preset)) // black and white is for PDFs
            #expect(!ScanPresets.isPdf(type))
            #expect(ScanPresets.normalize(ScanPresetSettings(version: ScanPresets.currentVersion, items: [preset]))[0].fileType == type)
        }
        #expect(ScanPresets.fileExtension(.word) == ".docx")
        #expect(ScanPresets.fileExtension(.text) == ".txt")
        #expect(ScanPresets.fileExtension(.searchablePdf) == ".pdf")
        var word = ScanPreset()
        word.name = "x"
        word.fileType = .word
        #expect(ScanPresetText.summary(word).contains("Word document"))
    }
}
