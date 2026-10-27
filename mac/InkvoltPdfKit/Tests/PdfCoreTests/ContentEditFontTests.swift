import Foundation
import Testing
@testable import PdfCore

/// Ported from ContentEditFontTests.cs (Edit Text: which glyphs a page font really has, in Type 1, CFF and TrueType
/// programs, and what a new code adds to the font); all 6 tests. Adapted: the PDFs with binary font programs are written
/// as Latin-1 (`Core2Pdf.build` writes UTF-8), and where .NET reads the font dictionaries with PDFsharp the checks read
/// the same entries through `PObj`; ANewCodeGetsItsWidthFromTheProgram cuts /FA's widths through `PObj` too.
struct ContentEditFontTests {
    /// Numbered objects 1…n with a classic xref table, every byte as Latin-1 (font programs are binary).
    private static func build(_ objects: [String]) -> [UInt8] {
        var out = latin1Bytes("%PDF-1.7\n")
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += latin1Bytes("\(i + 1) 0 obj\n\(o)\nendobj\n")
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + latin1Bytes(table)
    }

    private static func stream(_ content: String, _ dict: String = "") -> String {
        "<< \(dict) /Length \(latin1Bytes(content).count) >>\nstream\n\(content)\nendstream"
    }

    /// A one-page PDF showing "ab" in a simple font (/F1) with the given dictionary and descriptor extras.
    private static func withFont(_ fontDict: String, _ programObject: String, show: String = "(ab) Tj") -> [UInt8] {
        let parts = programObject.split(separator: "|", maxSplits: 1).map(String.init)
        return build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            stream("BT /F1 20 Tf 72 700 Td \(show) ET"),
            fontDict,
            "<< /Type /FontDescriptor /FontName /ABCDEF+Test /Flags 32 /FontBBox [0 -200 1000 800] /Ascent 800 /Descent -200 /ItalicAngle 0 /StemV 80 /CapHeight 700 "
                + parts[0] + " >>",
            parts[1],
        ])
    }

    /// A Type 1 program (cleartext + eexec-encrypted part) whose CharStrings hold the given glyph names.
    private static func type1Program(_ names: String...) -> String {
        let clear = "%!PS-AdobeFont-1.0: Test\n/FontName /Test def\n/Encoding StandardEncoding def\ncurrentfile eexec\n"
        var priv = "dup /Private 8 dict dup begin /RD{string currentfile exch readstring pop}executeonly def end\n"
        priv += "2 index /CharStrings \(names.count) dict dup begin\n"
        for n in names { priv += "/\(n) 4 RD \u{01}\u{02}\u{03}\u{04} ND\n" }
        priv += "end\nend\nmark currentfile closefile\n"
        let plain = latin1Bytes("abcd" + priv) // four random bytes lead the encrypted part
        var enc = [UInt8](repeating: 0, count: plain.count)
        var r: UInt16 = 55665
        for (i, p) in plain.enumerated() {
            let c = p ^ UInt8(r >> 8)
            r = (UInt16(c) &+ r) &* 52845 &+ 22719
            enc[i] = c
        }
        let body = clear + latin1String(enc) + "\n" + String(repeating: "0", count: 64) + "\ncleartomark\n"
        return "/FontFile 7 0 R|" + stream(body, "/Length1 \(clear.utf8.count) /Length2 \(enc.count) /Length3 0")
    }

    @Test func type1CharStringsDecideWhichGlyphsExist() throws {
        let pdf = Self.withFont("<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Test /FirstChar 97 /LastChar 99 /Widths [500 600 700] "
            + "/Encoding << /Type /Encoding /Differences [97 /a /b /c] >> /FontDescriptor 6 0 R >>", Self.type1Program(".notdef", "a", "b"))
        let runs = try ContentEditor.read(pdf, nil, 0).runs
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.text == "ab")
        #expect(run.blocked == nil)
        #expect(run.check("ba").missing.isEmpty)
        #expect(run.check("abc").missing == ["c"]) // a width, but no glyph in the subset
        let edited = try ContentEditor.replaceText(pdf, nil, run, "bab")
        #expect(ContentEditPdf.content(edited).contains("(bab) Tj"))
    }

    @Test func type1ProgramParsing() throws {
        let program = Self.type1Program(".notdef", "eacute", "f_i")
        let start = try #require(program.range(of: "stream\n")).upperBound
        let end = try #require(program.range(of: "\nendstream", options: .backwards)).lowerBound
        let t1 = try #require(Type1Program.read(latin1Bytes(String(program[start..<end]))))
        #expect(t1.hasName("eacute"))
        #expect(t1.hasName("f_i"))
        #expect(!t1.hasName("a"))
    }

    /// A minimal CFF (one font) whose charset names the glyphs by SID, CharStrings all "endchar".
    private static func cff(_ sids: Int...) -> [UInt8] {
        func index(_ items: [[UInt8]]) -> [UInt8] {
            if items.isEmpty { return [0, 0] }
            var o: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 255), 2, 0, 1]
            var off = 1
            for it in items {
                off += it.count
                o += [UInt8(off >> 8), UInt8(off & 255)]
            }
            for it in items { o += it }
            return o
        }
        func int(_ v: Int) -> [UInt8] { [29, UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        let header: [UInt8] = [1, 0, 4, 1]
        let name = index([Array("Test".utf8)])
        let strings = index([])
        let gsubrs = index([])
        let n = sids.count + 1
        // Top DICT size is fixed (two 5-byte ints and their operators): 12 bytes.
        let topIndexSize = index([[UInt8](repeating: 0, count: 12)]).count
        let charsetAt = header.count + name.count + topIndexSize + strings.count + gsubrs.count
        var charset: [UInt8] = [0]
        for s in sids { charset += [UInt8(s >> 8), UInt8(s & 255)] }
        let charStringsAt = charsetAt + charset.count
        let top = index([int(charsetAt) + [15] + int(charStringsAt) + [17]])
        let charStrings = index((0..<n).map { _ in [14] })
        return header + name + top + strings + gsubrs + charset + charStrings
    }

    @Test func cffCharsetDecidesWhichGlyphsExist() throws {
        let cff = Self.cff(66, 67) // a, b (CFF standard strings)
        let parsed = try #require(CffProgram.read(cff))
        #expect(parsed.hasName("a"))
        #expect(!parsed.hasName("c"))

        let pdf = Self.withFont("<< /Type /Font /Subtype /Type1 /BaseFont /ABCDEF+Test /FirstChar 97 /LastChar 99 /Widths [500 600 700] "
            + "/Encoding /WinAnsiEncoding /FontDescriptor 6 0 R >>", "/FontFile3 7 0 R|" + Self.stream(latin1String(cff), "/Subtype /Type1C"))
        let run = try #require(try ContentEditor.read(pdf, nil, 0).runs.first)
        #expect(run.check("bba").missing.isEmpty)
        #expect(run.check("cab").missing == ["c"])
    }

    @Test func nonEmbeddedStandardFontsTakeAnyCharacterOfTheirEncoding() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 20 Tf 72 700 Td (Total: 12) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
        let run = try #require(try ContentEditor.read(pdf, nil, 0).runs.first)
        #expect(run.check("Zoë – €5 中").missing == ["中"])
        let edited = try ContentEditor.replaceText(pdf, nil, run, "Zoë – €5")
        #expect(ContentEditPdf.text(edited).contains("Zoë – €5"))
    }

    @Test func aNewCodeGetsItsWidthFromTheProgram() throws {
        // /FA with its widths cut down to "H" only: "W" is in the program but not in /Widths.
        var pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td (H) Tj ET")
        do {
            let d = try Core2Pdf.open(pdf)
            let font = try #require(d.page(0).dict("Resources")?.dict("Font")?.dict("FA"))
            font.set("FirstChar", d.int(72))
            font.set("LastChar", d.int(72))
            font.set("Widths", d.array([d.int(722)]))
            font.dict("FontDescriptor")?.set("MissingWidth", d.int(333))
            try d.checkFailure()
            pdf = try d.write("")
        }
        let run = try #require(try ContentEditor.read(pdf, nil, 0).runs.first)
        let edited = try ContentEditor.replaceText(pdf, nil, run, "HW")
        let e = try Core2Pdf.open(edited)
        let fa = try #require(e.page(0).dict("Resources")?.dict("Font")?.dict("FA"))
        #expect(fa.int("FirstChar") == 72)
        #expect(fa.int("LastChar") == 87)
        let widths = try #require(fa.array("Widths"))
        #expect((942...945).contains(widths.num(87 - 72))) // Arial's W
        #expect(widths.num(73 - 72) == 333) // codes in the gap keep the width viewers gave them
        // MuPDF places the next glyph after it: the run is as wide as H + W.
        let after = try #require(try ContentEditor.read(edited, nil, 0).runs.first)
        #expect(((722.0 + 943) / 1000 * 20).rounded() == after.oldWidth.rounded())
    }

    @Test func aNewCidGetsItsTextIntoToUnicodeAndItsWidthIntoW() throws {
        let pdf = ContentEditPdf.withoutSpace(ContentEditPdf.make("BT /FU 20 Tf 72 692 Td " + ContentEditPdf.cid("Hello") + " Tj ET"))
        let run = try #require(try ContentEditor.read(pdf, nil, 0).runs.first)
        let edited = try ContentEditor.replaceText(pdf, nil, run, "Hello Hello")
        #expect(try ContentEditor.read(edited, nil, 0).runs.map(\.text) == ["Hello Hello"])
        let e = try Core2Pdf.open(edited)
        let fu = try #require(e.page(0).dict("Resources")?.dict("Font")?.dict("FU"))
        let cmap = latin1String(try #require(fu.dict("ToUnicode")?.streamData))
        #expect(cmap.contains("<0003> <0020>"), "\(cmap)\n\(ContentEditPdf.content(edited))")
        #expect(ContentEditPdf.text(edited).contains("Hello Hello"))
    }
}
