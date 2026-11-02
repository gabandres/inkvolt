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
/// program (`TrueTypeSubset`) draws the glyphs it was asked for with the system font's widths, a PDF 2.0 file comes out as
/// 1.7, and what `LongNames` does that Windows does on PDFsharp's whole names. Fill & Sign marks are embedded from macOS's
/// ZapfDingbats where Windows' test names Segoe UI Symbol.
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

    private static let photoshopXmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:made=\"http://example.com/made/\"><made:Tool>Photoshop</made:Tool></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"

    /// A picture and a page with XMP packets of their own, in a schema PDF/A doesn't know (Photoshop's, InDesign's).
    static func ownMetadataPdf() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Metadata 7 0 R /Resources << /XObject << /Im0 5 0 R >> >> >>",
            Core2Pdf.stream("q 100 0 0 100 50 50 cm /Im0 Do Q"),
            Core2Pdf.stream("FF0000>", "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Metadata 6 0 R /Filter /ASCIIHexDecode"),
            Core2Pdf.stream(photoshopXmp, "/Type /Metadata /Subtype /XML"),
            Core2Pdf.stream(photoshopXmp, "/Type /Metadata /Subtype /XML"),
        ])
    }

    @Test func PicturesAndPagesLoseTheirOwnMetadata() throws {
        let pdf = Self.ownMetadataPdf()
        #expect(PdfA.validate(pdf).contains { $0.contains("metadata of its own") })
        let result = try PdfA.convert(pdf, nil)
        #expect(PdfA.validate(result.data) == [])
        let doc = try Core2Pdf.open(result.data)
        #expect(doc.catalog.dict("Metadata") != nil)
        #expect(!doc.page(0).has("Metadata"))
        let image = try #require(doc.page(0).dict("Resources")?.dict("XObject")?.dict("Im0"))
        #expect(!image.has("Metadata"))
        #expect(!latin1String(result.data).contains("made:Tool"))
        #expect(result.changes.contains { $0.contains("2 pictures' and pages' own metadata") })
        let before = try PdfEngine.open(pdf), after = try PdfEngine.open(result.data)
        defer {
            before.close()
            after.close()
        }
        #expect(try before.render(0, scale: 1).pixels == after.render(0, scale: 1).pixels)
    }

    private static let longRole = "Caption,Figure" + String(repeating: "#20Caption#20Char", count: 12)

    /// A role name over PDF/A's 127 bytes, as Word's styles make one (nist-sp800-63-3.pdf), in the role map and on the element.
    static func longRolePdf(_ content: String = "BT ET") -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> /StructTreeRoot << /Type /StructTreeRoot /RoleMap << /\(longRole) /P >> /K 5 0 R >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>",
            Core2Pdf.stream(content),
            "<< /Type /StructElem /S /\(longRole) /P null >>",
        ])
    }

    @Test func NamesOverPdfALimitAreShortenedTogether() throws {
        let pdf = Self.longRolePdf()
        #expect(PdfA.validate(pdf).contains { $0.contains("127") })
        let result = try PdfA.convert(pdf, nil)
        #expect(PdfA.validate(result.data) == [])
        #expect(result.changes.contains { $0.contains("1 name") })
        let doc = try Core2Pdf.open(result.data)
        let root = try #require(doc.catalog.dict("StructTreeRoot"))
        let roles = try #require(root.dict("RoleMap"))
        #expect(roles.keys.count == 1)
        let key = try #require(roles.keys.first)
        #expect((1...127).contains(key.utf8.count))
        #expect(key.contains("~"))
        #expect(root.dict("K")?.name("S") == key)
        #expect(roles.name(key) == "P")
    }

    @Test func ALongNameInPageContentRefuses() throws {
        // The page's content refers to it by name; a rewrite of the content is more than a copy should do.
        let blockers = try PdfA.check(Self.longRolePdf("/\(Self.longRole) BMC EMC"), nil)
        #expect(blockers.contains { $0.contains("127") })
    }

    /// A form as the IRS sends it: Reader usage rights in the catalog's /Perms (a /ByteRange, so it looks signed), no signed field.
    static func usageRightsPdf(_ perm: String = "/UR3") -> [UInt8] {
        Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /V (Ada) /P 3 0 R >>"],
                      catalogExtra: "/Perms << \(perm) << /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 10 20 30] /Contents <00> /Reference [<< /TransformMethod /UR3 >>] >> >>")
    }

    @Test func UsageRightsAreNoSignatureAndTheCopySaysTheyWent() throws {
        let pdf = Self.usageRightsPdf()
        #expect(SignedEdits.looksSigned(pdf))
        #expect(try PdfA.check(pdf, nil) == [])
        let result = try PdfA.convert(pdf, nil)
        #expect(PdfA.validate(result.data) == [])
        #expect(result.changes.contains { $0.contains("usage rights") })
        #expect(try FormEditor.read(result.data, nil).contains { $0.fieldName == "name" })
        #expect(try !Core2Pdf.open(result.data).catalog.has("Perms"))

        // A plain form says nothing about them.
        let plain = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>"])
        #expect(try !PdfA.convert(plain, nil).changes.contains { $0.contains("usage rights") })
    }

    @Test func ACertificationWithoutASignedFieldStillRefuses() throws {
        // Somebody certified it, even if no field shows it: a rewrite must not drop that quietly.
        let blockers = try PdfA.check(Self.usageRightsPdf("/DocMDP"), nil)
        #expect(blockers.contains { $0.contains("certified") })
    }

    static func marksPdf() throws -> [UInt8] {
        try TextStamps.put(TextStamps.put(TestPdf.make(1), nil, 0, RectD(300, 400, 14, 14), .check, "", 12), nil, 0, RectD(330, 400, 14, 14), .cross, "", 12)
    }

    @Test func FillAndSignMarksConvertWithTheirSymbolsEmbedded() throws {
        let pdf = try Self.marksPdf()
        #expect(try PdfA.check(pdf, nil) == [])
        let result = try PdfA.convert(pdf, nil)
        #expect(PdfA.validate(result.data) == [])
        #expect(result.changes.contains { $0.contains("ZapfDingbats") })
        #expect(result.changes.contains { $0.contains("1 standard font embedded") }) // TestPdf's Helvetica (Windows' embeds Arial); the marks aren't counted
        let engine = try PdfEngine.open(result.data)
        defer { engine.close() }
        // Drawn where the stamps are: dark pixels inside both boxes, none just beside them.
        let image = try engine.render(0, scale: 1)
        func dark(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> Int {
            let bpp = image.pixels.count / (image.width * image.height)
            var n = 0
            for y in y1..<y2 {
                for x in x1..<x2 where image.pixels[(y * image.width + x) * bpp + 1] < 128 { n += 1 }
            }
            return n
        }
        #expect(dark(300, 400, 314, 414) > 10)
        #expect(dark(330, 400, 344, 414) > 10)
        #expect(dark(316, 400, 328, 414) == 0)
    }

    @Test func EveryZapfDingbatsCodeIsCovered() throws {
        // Every symbol in the built-in encoding draws, in a string a form might use (no code falls back to nothing).
        let codes = Array(0x21..<(0x21 + 0x5E)) + Array(0xA1..<(0xA1 + 0x5E)).filter { $0 != 0xF0 }
        let all = codes.map { "\\" + String(format: "%03o", $0) }.joined()
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2000 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 9 Tf 5 40 Td (\(all)) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>",
        ])
        let result = try PdfA.convert(pdf, nil)
        #expect(PdfA.validate(result.data) == [])
        let engine = try PdfEngine.open(result.data)
        defer { engine.close() }
        let text = try engine.text(0).text
        for symbol in ["\u{2714}", "\u{2718}", "\u{2605}", "\u{25CF}", "\u{25A0}", "\u{25C6}", "\u{2460}", "\u{2192}", "\u{27BE}"] { #expect(text.contains(symbol), "\(symbol)") }
        // Mac addition: macOS's font has them all, so every code of the 187 gets its own glyph.
        let ttf = try #require(SystemFonts.get("ZapfDingbats.ttf"))
        #expect(codes.allSatisfy { PdfA.Pass.dingbatUnicode($0) != 0 && ttf.has(PdfA.Pass.dingbatUnicode($0)) })
        let file = try #require(ttf.fileData)
        #expect(TrueTypeSubset.allowsEmbedding(file))
    }

    @Test func ZapfDingbatsWithItsOwnEncodingOrWidthsRefusesSayingWhy() throws {
        #expect(try PdfA.check(Self.oneFont("<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats /Encoding << /Differences [114 /a20] >> >>"), nil).contains { $0.contains("encoding of its own") })
        #expect(try PdfA.check(Self.oneFont("<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats /FirstChar 114 /LastChar 114 /Widths [5] >>"), nil).contains { $0.contains("widths") })
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
            ("own-metadata", Self.ownMetadataPdf()),
            ("long-role", Self.longRolePdf()),
            ("usage-rights", Self.usageRightsPdf()),
            ("marks", try Self.marksPdf()),
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

    /// Two role names alike in their first 127 bytes, each its own role: MuPDF alone reads them as one.
    private static let twins = (String(repeating: "A", count: 130) + "1", String(repeating: "A", count: 130) + "2")

    @Test func twoLongNamesAlikeUpToTheLimitStayTwo() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> /StructTreeRoot << /Type /StructTreeRoot /RoleMap << /\(Self.twins.0) /P /\(Self.twins.1) /H1 >> /K [5 0 R 6 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>",
            Core2Pdf.stream("BT ET"),
            "<< /Type /StructElem /S /\(Self.twins.0) /P null >>",
            "<< /Type /StructElem /S /\(Self.twins.1) /P null >>",
        ])
        let result = try PdfA.convert(pdf, nil)
        #expect(result.changes.contains { $0.contains("2 names") })
        let doc = try Core2Pdf.open(result.data)
        let root = try #require(doc.catalog.dict("StructTreeRoot"))
        let roles = try #require(root.dict("RoleMap"))
        #expect(roles.keys.count == 2)
        let first = try #require(root.array("K")?[0]?.name("S")), second = try #require(root.array("K")?[1]?.name("S"))
        #expect(first != second)
        #expect(roles.name(first) == "P")
        #expect(roles.name(second) == "H1")
    }

    @Test func aLongNameInAnObjectStreamIsFoundToo() throws {
        // The element and the role map in an object stream, as Word writes them; no usable table, so MuPDF rebuilds it.
        let inStream = ["<< /Type /StructTreeRoot /RoleMap << /\(Self.longRole) /P >> /K 6 0 R >>", "<< /Type /StructElem /S /\(Self.longRole) /P null >>"]
        let header = "5 0 6 \(inStream[0].utf8.count + 1) "
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> /StructTreeRoot 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>",
            Core2Pdf.stream(header + inStream.joined(separator: " "), "/Type /ObjStm /N 2 /First \(header.utf8.count)"),
        ]).dropLastTable()
        #expect(PdfA.validate(pdf).contains { $0.contains("127") })
        let result = try PdfA.convert(pdf, nil)
        #expect(result.changes.contains { $0.contains("1 name") })
        let doc = try Core2Pdf.open(result.data)
        let root = try #require(doc.catalog.dict("StructTreeRoot"))
        let key = try #require(root.dict("RoleMap")?.keys.first)
        #expect(key.contains("~"))
        #expect(root.dict("K")?.name("S") == key)
    }

    @Test func aLongNameInAStreamsDictionaryKeepsTheStream() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>",
            Core2Pdf.stream("0 0 1 rg 10 10 100 100 re f", "/\(Self.longRole) 1"),
        ])
        let result = try PdfA.convert(pdf, nil)
        #expect(result.changes.contains { $0.contains("1 name") })
        let engine = try PdfEngine.open(result.data), before = try PdfEngine.open(pdf)
        defer {
            engine.close()
            before.close()
        }
        #expect(try engine.render(0, scale: 1).pixels == before.render(0, scale: 1).pixels)
    }

    @Test func aStringIsNotAName() throws {
        // Over the limit in a string, a comment and a stream's bytes: nothing to shorten.
        let long = "/" + String(repeating: "x", count: 200)
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /Note (\(long)) >> % \(long)",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Hex <2F78> >>",
            Core2Pdf.stream("% \(long)\n0 0 1 rg 10 10 100 100 re f"),
        ])
        #expect(!PdfA.validate(pdf).contains { $0.contains("127") })
        #expect(try !PdfA.convert(pdf, nil).changes.contains { $0.contains("shortened") })
    }

    @Test func aProtectedFilesLongNameIsShortenedAndItsStringsStayReadable() throws {
        // MuPDF writes a name of 127 bytes; a byte added afterwards makes it too long, offsets off (MuPDF rebuilds the table).
        let exact = String(repeating: "A", count: 127)
        let plain = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> /StructTreeRoot << /Type /StructTreeRoot /RoleMap << /\(exact) /P >> /K 5 0 R >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>",
            Core2Pdf.stream("BT ET"),
            "<< /Type /StructElem /S /\(exact) /P null /Alt (A cat) >>",
        ])
        let locked = try PdfSecurity.protect(plain, nil, userPassword: "", ownerPassword: "owner")
        let longer = latin1Bytes(latin1String(locked).replacingOccurrences(of: "/" + exact, with: "/" + exact + "B"))
        #expect(longer.count > locked.count)
        let result = try PdfA.convert(longer, "owner")
        #expect(PdfA.validate(result.data) == [])
        #expect(result.changes.contains { $0.contains("1 name") })
        let doc = try Core2Pdf.open(result.data)
        let root = try #require(doc.catalog.dict("StructTreeRoot"))
        let key = try #require(root.dict("RoleMap")?.keys.first)
        #expect(key.contains("~"))
        #expect(root.dict("K")?.name("S") == key)
        #expect(root.dict("K")?.text("Alt") == "A cat")
    }

    @Test func aSymbolicSubsetLooksItsCodesUpAtF000() throws {
        let ttf = try #require(SystemFonts.get("ZapfDingbats.ttf"))
        let file = try #require(ttf.fileData)
        let glyphs: [(codePoint: UInt32, glyph: Int)] = [(0xF034, ttf.glyphOf(0x2714))]
        let program = try #require(TrueTypeSubset.subset(file, glyphs, symbolic: true))
        let provider = try #require(CGDataProvider(data: Data(program) as CFData))
        let cg = try #require(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(cg, 1000, nil, nil)
        var glyph: CGGlyph = 0
        #expect(CTFontGetGlyphsForCharacters(font, [0xF034], &glyph, 1))
        #expect(Int(glyph) == ttf.glyphOf(0x2714))
        #expect(CTFontCreatePathForGlyph(font, glyph, nil) != nil)
    }

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

    @Test func theAppSaysWhatWasChangedAndWhatStopsIt() throws {
        #expect(PdfA.copyName("Annual report.pdf") == "Annual report (PDF-A).pdf")
        let result = try PdfA.convert(Self.scriptsPdf(), nil)
        let saved = PdfA.savedMessage("Annual report (PDF-A).pdf", result.changes)
        #expect(saved.hasPrefix("Annual report (PDF-A).pdf is an archival copy (PDF/A-2b)."))
        #expect(saved.contains("• sRGB output intent and PDF/A metadata added")) // not "SRGB", as Windows writes it
        #expect(saved.contains("• 1 hidden comment removed"))
        #expect(saved.hasSuffix("such as veraPDF."))
        let refused = PdfA.refusalMessage(["One.", "Two."])
        #expect(refused.hasPrefix("Nothing was saved."))
        #expect(refused.hasSuffix("\n\n• One.\n• Two."))
    }

    @Test func aPdf20FileComesOutAs17() throws {
        var pdf = TestPdf.make(1)
        pdf.replaceSubrange(0..<8, with: Array("%PDF-2.0".utf8))
        let result = try PdfA.convert(pdf, nil)
        #expect(String(decoding: result.data.prefix(8), as: UTF8.self) == "%PDF-1.7")
        #expect(PdfA.validate(result.data) == [])
    }
}

private extension Array where Element == UInt8 {
    /// The file without its cross-reference table: MuPDF rebuilds it, object streams included.
    func dropLastTable() -> [UInt8] {
        guard let at = firstRange(of: Array("xref\n".utf8))?.lowerBound else { return self }
        return Array(self[..<at]) + Array("trailer\n<< /Root 1 0 R >>\n".utf8)
    }
}
