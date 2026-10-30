import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PdfCore

/// Ported from PdfATests.cs (same names): Save as PDF/A-2b. Adapted: the synthetic document gets its title
/// ("Synthetic") through `PageEditor.writeMetadata` (Windows' TestPdf has one); the properties test writes its Info
/// dictionary by hand (Windows makes it with PDFsharp); ConvertedFilesPassVeraPdf converts the same samples and checks
/// each with `PdfA.validate`, and with INKVOLTPDF_SAMPLES set writes them to its pdfa folder, for veraPDF on the Windows
/// PC (veraPDF needs Java, which the Mac doesn't get; pdf/tools/a11y-corpus/README.md). Mac additions: the subset font
/// program (`TrueTypeSubset`) draws the glyphs it was asked for with the system font's widths, and a PDF 2.0 file comes
/// out as 1.7.
struct PdfATests {
    private static func xmp(_ pdf: [UInt8]) throws -> String {
        let doc = try Core2Pdf.open(pdf)
        return String(decoding: try #require(doc.catalog.dict("Metadata")?.rawStreamData), as: UTF8.self)
    }

    static func scriptsPdf() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /OpenAction 5 0 R /AA << /WC 5 0 R >> /Names << /JavaScript << /Names [(a) 5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Annots [6 0 R 7 0 R 8 0 R 10 0 R] /AA << /O 5 0 R >> >>",
            Core2Pdf.stream("0 0 1 rg 72 72 100 100 re f"),
            "<< /Type /Action /S /JavaScript /JS (app.alert(1)) >>",
            "<< /Type /Annot /Subtype /Link /Rect [72 600 200 620] /A << /S /Launch /F (calc.exe) >> >>",
            "<< /Type /Annot /Subtype /Square /Rect [72 500 200 560] /F 2 /AP << /N 9 0 R >> >>",
            "<< /Type /Annot /Subtype /Square /Rect [72 400 200 460] /AP << /N 9 0 R /D 9 0 R >> >>",
            Core2Pdf.stream("0 0 1 RG 2 w 1 1 126 58 re S", "/Type /XObject /Subtype /Form /BBox [0 0 128 60]"),
            "<< /Type /Annot /Subtype /Link /Rect [72 300 200 320] /A << /S /Named /N /Print >> >>",
        ])
    }

    static func standardFontsPdf() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 700 Td (Archive \\222quote\\222 caf\\351) Tj ET BT /F2 12 Tf 72 650 Td (Courier text) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
        ])
    }

    @Test func theSrgbProfileIsAWellFormedIccProfile() throws {
        let p = IccProfiles.srgb()
        func be32(_ at: Int) -> Int { Int(p[at]) << 24 | Int(p[at + 1]) << 16 | Int(p[at + 2]) << 8 | Int(p[at + 3]) }
        func be16(_ at: Int) -> Int { Int(p[at]) << 8 | Int(p[at + 1]) }
        func ascii(_ at: Int) -> String { String(decoding: p[at..<at + 4], as: UTF8.self) }
        #expect(p.count == be32(0))
        #expect(ascii(36) == "acsp")
        #expect(ascii(12) == "mntr")
        #expect(ascii(16) == "RGB ")
        #expect(ascii(20) == "XYZ ")
        #expect(p[8] == 2) // version 2.x
        let count = be32(128)
        let tags = Set((0..<count).map { ascii(132 + 12 * $0) })
        #expect(tags.isSuperset(of: ["desc", "cprt", "wtpt", "rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC"]))
        for i in 0..<count {
            let offset = be32(132 + 12 * i + 4), size = be32(132 + 12 * i + 8)
            #expect(offset % 4 == 0 && offset + size <= p.count)
        }
        // The curve runs from 0 to 1, and mid-grey is about 21.4% light (sRGB 0.5).
        let trc = try #require((0..<count).first { ascii(132 + 12 * $0) == "rTRC" })
        let at = be32(132 + 12 * trc + 4)
        #expect(ascii(at) == "curv")
        #expect(be16(at + 12) == 0)
        #expect(be16(at + 12 + 2 * 1023) == 65535)
        let mid = Double(be16(at + 12 + 2 * 512)) / 65535
        #expect(mid >= 0.20 && mid <= 0.23)
    }

    @Test func aSimplePdfBecomesPdfA2b() throws {
        let source = try PageEditor.writeMetadata(TestPdf.make(2), nil, "Synthetic", "", "", "")
        #expect(!PdfA.validate(source).isEmpty) // no output intent, no pdfaid
        let result = try PdfA.convert(source, nil)
        #expect(PdfA.validate(result.data) == [])
        let xmp = try Self.xmp(result.data)
        #expect(xmp.contains("pdfaid"))
        #expect(xmp.contains("<pdfaid:part>2</pdfaid:part>"))
        #expect(xmp.contains("<pdfaid:conformance>B</pdfaid:conformance>"))
        #expect(xmp.contains("Synthetic")) // dc:title from the document properties
        let doc = try Core2Pdf.open(result.data)
        let intent = try #require(doc.catalog.array("OutputIntents")?[0])
        #expect(intent.name("S") == "GTS_PDFA1")
        #expect(intent.dict("DestOutputProfile")?.int("N") == 3)
        #expect(TestPdf.pageNumbers(source) == TestPdf.pageNumbers(result.data))
        #expect(result.changes.contains { $0.contains("output intent") })
    }

    @Test func scriptsActionsAndHiddenCommentsGo() throws {
        let result = try PdfA.convert(Self.scriptsPdf(), nil)
        #expect(PdfA.validate(result.data) == [])
        let doc = try Core2Pdf.open(result.data)
        let catalog = doc.catalog
        #expect(!catalog.has("AA"))
        #expect(catalog.dict("OpenAction")?.name("S") != "JavaScript")
        let annots = try #require(doc.page(0).array("Annots")).elements.filter(\.isDict)
        // The hidden square is gone; the link that launched a program went with Sanitize; the rest print.
        #expect(annots.filter { $0.name("Subtype") == "Square" }.count == 1)
        #expect(annots.allSatisfy { ($0.int("F") ?? 0) & 4 == 4 })
        #expect(annots.allSatisfy { $0.dict("A") == nil }) // Launch and Named Print removed
        let square = try #require(annots.first { $0.name("Subtype") == "Square" })
        #expect(square.dict("AP")?.has("D") == false)
        #expect(result.changes.contains { $0.contains("hidden comment") })
    }

    @Test func standardFontsAreEmbeddedFromWindowsTwins() throws {
        let pdf = Self.standardFontsPdf()
        let before = try Core2Pdf.allText(pdf)
        let result = try PdfA.convert(pdf, nil)
        #expect(PdfA.validate(result.data) == [])
        #expect(try Core2Pdf.allText(result.data) == before)
        let doc = try Core2Pdf.open(result.data)
        let fonts = try #require(doc.page(0).dict("Resources")?.dict("Font"))
        for key in ["F1", "F2"] {
            let f = try #require(fonts.dict(key))
            #expect(f.name("Subtype") == "TrueType")
            #expect(f.dict("FontDescriptor")?.dict("FontFile2") != nil)
        }
        // Courier had no encoding (StandardEncoding): WinAnsi plus differences for the codes it maps elsewhere.
        #expect(fonts.dict("F2")?.dict("Encoding")?.name("BaseEncoding") == "WinAnsiEncoding")
        #expect(result.changes.contains { $0.contains("2 standard fonts embedded") })
    }

    static func oneFont(_ font: String) -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 700 Td (ri) Tj ET"),
            font,
        ])
    }

    static let standardFaces: [(name: String, bold: Bool, italic: Bool)] = [
        ("Helvetica", false, false), ("Helvetica-BoldOblique", true, true), ("Times-Roman", false, false), ("ABCDEF+Arial,Bold", true, false),
        ("Arial,BoldItalic", true, true), ("Arial-ItalicMT", false, true), ("ArialMT", false, false), ("TimesNewRomanPS-BoldMT", true, false),
        ("TimesNewRoman,Italic", false, true), ("CourierNewPSMT", false, false), ("Courier-Oblique", false, true),
    ]

    @Test(arguments: standardFaces)
    func standardFacesAreRecognizedWithTheirStyle(_ face: (name: String, bold: Bool, italic: Bool)) throws {
        let f = try #require(PdfA.standardFace(face.name))
        #expect(f.bold == face.bold && f.italic == face.italic)
    }

    @Test(arguments: ["HelveticaNeue", "HelveticaNeue-Bold", "Helvetica-Condensed", "Arial-Black", "ArialNarrow", "Arial,Light", "TimesTen-Roman"])
    func otherDesignsOfTheFamilyAreNotStandardFaces(_ name: String) {
        #expect(PdfA.standardFace(name) == nil)
    }

    @Test func aBoldFontIsEmbeddedBoldAndWidthsMustFit() throws {
        // "i" is 278 wide in Arial Bold and 222 in Arial: a bold font named "Arial,Bold" with bold widths gets the bold face.
        let bold = try PdfA.convert(Self.oneFont("<< /Type /Font /Subtype /TrueType /BaseFont /Arial,Bold /FirstChar 105 /LastChar 114 /Widths [278 0 0 0 0 0 0 0 0 389] /Encoding /WinAnsiEncoding >>"), nil)
        #expect(PdfA.validate(bold.data) == [])
        let doc = try Core2Pdf.open(bold.data)
        let f = try #require(doc.page(0).dict("Resources")?.dict("Font")?.dict("F1"))
        #expect(f.name("BaseFont")?.hasSuffix("Arial-Bold") == true)
        #expect(try #require(f.array("Widths")).num(105 - (f.int("FirstChar") ?? 0)) == 278)
        // Widths that aren't the Windows face's (another design under a standard name) refuse, saying why.
        let narrow = Self.oneFont("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 105 /LastChar 105 /Widths [400] >>")
        #expect(try PdfA.check(narrow, nil).contains { $0.contains("widths") })
        #expect(try PdfA.check(Self.oneFont("<< /Type /Font /Subtype /Type1 /BaseFont /HelveticaNeue >>"), nil).contains { $0.contains("HelveticaNeue") })
    }

    @Test func documentPropertiesAndXmpSayTheSame() throws {
        let source = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>",
            "<< /Title (  Spaced\\001 title  ) /Author (Ada ) >>",
        ], trailerExtra: "/Info 4 0 R")
        let result = try PdfA.convert(source, nil)
        #expect(PdfA.validate(result.data) == [])
        let metadata = try PageEditor.readMetadata(result.data, nil)
        #expect(metadata.title == "Spaced title")
        #expect(metadata.author == "Ada")
        let xmp = try Self.xmp(result.data)
        #expect(xmp.contains(">Spaced title<"))
        #expect(xmp.contains(">Ada<"))
    }

    @Test func whatCantBeKeptRefusesTheConversion() throws {
        let cmyk = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            Core2Pdf.stream("0 0 0 1 k 72 72 100 100 re f"),
        ])
        let error = #expect(throws: PdfAError.self) { try PdfA.convert(cmyk, nil) }
        #expect(error?.blockers.contains { $0.contains("CMYK") } == true)
        #expect(!(try PdfA.check(cmyk, nil)).isEmpty)

        let symbol = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 700 Td (abc) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Symbol >>",
        ])
        #expect(try PdfA.check(symbol, nil).contains { $0.contains("Symbol") })
        #expect(try PdfA.check(Core2SignatureTests.signed(), nil).contains { $0.contains("signed") })
        #expect(try PdfA.check(TestPdf.make(1), nil) == [])
    }

    @Test func protectedFilesNeedTheirPermissionsPasswordAndComeOutUnencrypted() throws {
        let locked = try PdfSecurity.protect(TestPdf.make(1), nil, userPassword: "open", ownerPassword: "owner")
        #expect(throws: OwnerPasswordRequired.self) { try PdfA.convert(locked, "open") }
        let result = try PdfA.convert(locked, "owner")
        #expect(PdfA.validate(result.data) == [])
        let engine = try PdfEngine.open(result.data)
        defer { engine.close() }
        #expect(try engine.text(0).text.contains("Page 1"))
        #expect(result.changes.contains { $0.contains("password") })
    }

    /// The samples Windows checks with veraPDF, each converted and checked with `validate`. With INKVOLTPDF_SAMPLES set
    /// they are written to its pdfa folder, to be checked with veraPDF on the Windows PC; INKVOLTPDF_PDFA_INPUTS (a
    /// folder) adds more PDFs, and those that can't be converted are skipped (the refusals are written to refused.txt
    /// beside the samples).
    @Test func convertedFilesPassVeraPdf() throws {
        var samples: [(name: String, pdf: [UInt8])] = [
            ("synthetic", TestPdf.make(3)),
            ("scripts", Self.scriptsPdf()),
            ("standard-fonts", Self.standardFontsPdf()),
            ("bold-arial", Self.oneFont("<< /Type /Font /Subtype /TrueType /BaseFont /Arial,BoldItalic /Encoding /WinAnsiEncoding >>")),
            ("times-mt", Self.oneFont("<< /Type /Font /Subtype /TrueType /BaseFont /TimesNewRomanPS-BoldMT /Encoding /WinAnsiEncoding >>")),
            ("commented", try Annotations.addNote(Annotations.addTextMarkup(TestPdf.make(1), nil, 0, .highlight, [RectD(72, 80, 200, 24)], .yellow,
                                                                              note: "check", author: "Ada"), nil, 0, 300, 300, "A note", author: "Ada")),
            ("form", try FormEditor.setValues(Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>"]),
                                              nil, ["name": "Ada Lovelace"])),
            ("export", ExportTestPdf.make(logo: true)),
            ("stamped", try HeaderFooter.apply(Watermarks.apply(TestPdf.make(2), nil, [0, 1], WatermarkOptions(text: "DRAFT")), nil, [0, 1],
                                               { var o = HeaderFooterOptions(); o.footerCenter = "Page <<page>> of <<pages>>"; return o }())),
        ]
        let env = ProcessInfo.processInfo.environment
        var refused: [String] = []
        if let inputs = env["INKVOLTPDF_PDFA_INPUTS"], !inputs.isEmpty,
           let names = try? FileManager.default.contentsOfDirectory(atPath: inputs) {
            for name in names.sorted() where name.lowercased().hasSuffix(".pdf") {
                let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: (inputs as NSString).appendingPathComponent(name))))
                do {
                    let blockers = try PdfA.check(bytes, nil)
                    if blockers.isEmpty { samples.append(((name as NSString).deletingPathExtension, bytes)) }
                    else { refused.append("\(name): \(blockers.joined(separator: " "))") }
                } catch {
                    refused.append("\(name): \(error)") // restricted (needs its permissions password), or unreadable
                }
            }
        }
        var folder: String?
        if let keep = env["INKVOLTPDF_SAMPLES"], !keep.isEmpty {
            folder = (keep as NSString).appendingPathComponent("pdfa")
            try FileManager.default.createDirectory(atPath: folder!, withIntermediateDirectories: true)
            try Data(refused.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: (folder! as NSString).appendingPathComponent("refused.txt")))
        }
        for (name, pdf) in samples {
            let converted = try PdfA.convert(pdf, nil).data
            #expect(PdfA.validate(converted) == [], "\(name)")
            if let folder { try Data(converted).write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name + ".pdf"))) }
        }
    }

    // ───────────── Mac additions ─────────────

    @Test func theSubsetFontDrawsTheGlyphsItWasAskedFor() throws {
        let arial = try #require(StdFont(.helvetica, false, false).metrics)
        let program = try #require(arial.fileData)
        let wanted: [UInt32] = [0x41, 0x72, 0xE9, 0x2019, 0x20AC, 0x2022] // A r é ’ € •
        let subset = try #require(TrueTypeSubset.subset(program, wanted.map { ($0, arial.glyphOf($0)) }))
        #expect(subset.count < program.count / 10)
        let provider = try #require(CGDataProvider(data: Data(subset) as CFData))
        let cg = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(cg, 1000, nil, nil)
        for cp in wanted {
            let units = Array(String(Character(Unicode.Scalar(cp)!)).utf16)
            var glyph: CGGlyph = 0
            #expect(CTFontGetGlyphsForCharacters(font, units, &glyph, 1), "U+\(String(cp, radix: 16))")
            #expect(Int(glyph) == arial.glyphOf(cp))
            #expect(CTFontCreatePathForGlyph(font, glyph, nil) != nil, "an outline for U+\(String(cp, radix: 16))")
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, [glyph], &advance, 1)
            #expect(abs(Double(advance.width) - arial.advance(cp) * 1000) < 0.5)
        }
        var other: CGGlyph = 0
        let z = Array("Z".utf16)
        #expect(!CTFontGetGlyphsForCharacters(font, z, &other, 1) || CTFontCreatePathForGlyph(font, other, nil) == nil) // not asked for
    }

    @Test func aPdf20FileComesOutAs17() throws {
        var pdf = TestPdf.make(1)
        pdf.replaceSubrange(0..<8, with: Array("%PDF-2.0".utf8))
        let result = try PdfA.convert(pdf, nil)
        #expect(String(decoding: result.data.prefix(8), as: UTF8.self) == "%PDF-1.7")
        #expect(PdfA.validate(result.data) == [])
    }
}
