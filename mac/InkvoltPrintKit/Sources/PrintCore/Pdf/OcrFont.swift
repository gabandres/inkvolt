import Foundation

// The scan PDF's text layer (roadmap 2.3): the Windows app's `InkvoltPrint.Core/Pdf/OcrFont.cs`, ported as is so a
// searchable PDF from either app is found the same way (pdf.js, MuPDF, Acrobat).

/// A recognized word as the text layer writes it: broken and invisible characters out, composed (NFC, what a search box
/// holds), cut into what each code of the font stands for (a letter with its marks), in the order the letters lie on the
/// page. PDF readers rebuild the reading order of right-to-left text from where it lies, so a right-to-left word is
/// written in visual order, its runs of Latin letters and digits forward (the same reversal pdf.js and MuPDF undo).
public enum OcrText {
    /// The longest text one code stands for, in UTF-16 units; a longer cluster (Zalgo) gets a code per character.
    public static let maxCluster = 32

    /// The word as it will be found: only characters a search could match, composed, trimmed. Empty when nothing is left.
    /// (A Swift string holds no half surrogate pair: one decoded from broken UTF-16 has U+FFFD there, which goes too.)
    public static func clean(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s.value >= 0x10000 {
                if s.value & 0xFFFE != 0xFFFE { kept.append(s) } // a noncharacter of its plane
                continue
            }
            if !unwanted(s) { kept.append(s) }
        }
        return String(kept).precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Controls, the byte order mark, the replacement character, noncharacters, and direction marks and overrides, which
    /// would split a search.
    private static func unwanted(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F, 0xFEFF, 0xFFFD, 0xFFFE, 0xFFFF, 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069, 0xFDD0...0xFDEF: true
        default: false
        }
    }

    /// Whether the (cleaned) word has a letter of a right-to-left script.
    public static func isRightToLeft(_ text: String) -> Bool { text.unicodeScalars.contains(where: isStrongRtl) }

    private static func isStrongRtl(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFC, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
            switch s.properties.generalCategory {
            case .otherLetter, .modifierLetter, .letterNumber: true
            default: false
            }
        default: false
        }
    }

    /// Chinese, Japanese and Thai-like scripts don't put spaces between words: such a word runs into the next.
    public static func isUnspaced(_ text: String) -> Bool { !text.isEmpty && text.unicodeScalars.allSatisfy(isUnspacedLetter) }

    private static func isUnspacedLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF: true
        default: false
        }
    }

    /// The (cleaned) word cut into what each code stands for, in the order they lie on the page: clusters (a letter with
    /// its marks) left to right. A right-to-left word is cut into characters instead: pdf.js and MuPDF turn the characters
    /// they read back round one by one, so a cluster's would come out in the wrong order.
    public static func clusters(_ text: String) -> [String] {
        if isRightToLeft(text) { return visualOrder(characters(text)) }
        var clusters: [String] = []
        for element in text {
            let cluster = String(element)
            if cluster.utf16.count <= maxCluster { clusters.append(cluster) } else { clusters += characters(cluster) }
        }
        return clusters
    }

    private static func characters(_ text: String) -> [String] { text.unicodeScalars.map { String($0) } }

    /// Right-to-left at the word's level: the whole list turned round, then each run that reads left to right (Latin
    /// letters, digits, what joins digits) turned back.
    private static func visualOrder(_ logical: [String]) -> [String] {
        var forward = logical.map(readsForward)
        // A separator between two digits is part of the number: 1,234.50
        if logical.count >= 3 {
            for i in 1..<(logical.count - 1) where [",", ".", ":", "/", "-", "\u{066B}", "\u{066C}"].contains(logical[i])
                && forward[i - 1] && isDigit(logical[i - 1]) && isDigit(logical[i + 1]) { forward[i] = true }
        }
        var result: [String] = []
        result.reserveCapacity(logical.count)
        var i = logical.count - 1
        while i >= 0 {
            if !forward[i] {
                result.append(logical[i])
                i -= 1
                continue
            }
            let end = i
            while i >= 0 && forward[i] { i -= 1 }
            result += logical[(i + 1)...end]
        }
        return result
    }

    /// A decimal digit in the first plane (.NET's `char.IsDigit` on the cluster's first UTF-16 unit).
    private static func isDigit(_ cluster: String) -> Bool {
        guard let s = cluster.unicodeScalars.first, s.value <= 0xFFFF else { return false }
        return s.properties.generalCategory == .decimalNumber
    }

    private static func readsForward(_ cluster: String) -> Bool {
        guard let s = cluster.unicodeScalars.first, !isStrongRtl(s) else { return false }
        switch s.properties.generalCategory {
        case .decimalNumber, .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter: return true
        default: return false
        }
    }
}

/// The text layer's one font: a Type0 font (Identity-H) over an embedded TrueType program of a single empty glyph half an
/// em wide, so nothing can ever be drawn and no system font is needed. Each different cluster gets a code as it first
/// appears; /CIDToGIDMap sends them all to that glyph and /ToUnicode gives each its text (surrogate pairs and marks
/// included), which is what search, selection and copy read. Tesseract's PDF output and OCRmyPDF work the same way.
struct OcrFont {
    /// The advance of the glyph, in thousandths of the font size.
    static let width = 500

    /// A code is two bytes, and code 0 is .notdef.
    private static let maxCodesDefault = 65_535

    private var codes: [String: Int] = [:]
    private var texts: [String] = [""]
    private let maxCodes: Int

    init(maxCodes: Int = OcrFont.maxCodesDefault) { self.maxCodes = maxCodes }

    var isEmpty: Bool { codes.isEmpty }

    /// The clusters' codes as a PDF hex string, and how many; a cluster past what the font can hold is left out.
    mutating func encode(_ clusters: [String]) -> (hex: String, count: Int) {
        var hex = ""
        var count = 0
        for cluster in clusters {
            var code = codes[cluster]
            if code == nil {
                if texts.count > maxCodes { continue }
                code = texts.count
                texts.append(cluster)
                codes[cluster] = code
            }
            hex += PdfWriter.hex4(code!)
            count += 1
        }
        return (hex, count)
    }

    func write(_ obj: (Int, String) -> Void, _ stream: (Int, String, [UInt8]) -> Void, fontId: Int, firstId: Int) {
        let (descendant, descriptor, program, cidMap, unicode) = (firstId, firstId + 1, firstId + 2, firstId + 3, firstId + 4)
        let name = "/InkvoltOcrText"
        obj(fontId, "<< /Type /Font /Subtype /Type0 /BaseFont \(name) /Encoding /Identity-H /DescendantFonts [\(descendant) 0 R] /ToUnicode \(unicode) 0 R >>")
        obj(descendant, "<< /Type /Font /Subtype /CIDFontType2 /BaseFont \(name) /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
            + "/FontDescriptor \(descriptor) 0 R /DW \(Self.width) /CIDToGIDMap \(cidMap) 0 R >>")
        obj(descriptor, "<< /Type /FontDescriptor /FontName \(name) /Flags 4 /FontBBox [0 -200 500 800] /ItalicAngle 0 /Ascent 800 /Descent -200 "
            + "/CapHeight 700 /StemV 80 /FontFile2 \(program) 0 R >>")
        let ttf = Self.program
        stream(program, "<< /Length \(ttf.count) /Length1 \(ttf.count) >>", ttf)
        let map = cidMapBytes()
        stream(cidMap, "<< /Length \(map.count) >>", map)
        let cmap = toUnicode()
        stream(unicode, "<< /Length \(cmap.count) >>", cmap)
    }

    private func cidMapBytes() -> [UInt8] {
        var map = [UInt8](repeating: 0, count: texts.count * 2)
        for code in Swift.stride(from: 1, to: texts.count, by: 1) { map[code * 2 + 1] = 1 }
        return map
    }

    private func toUnicode() -> [UInt8] {
        var s = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
            + "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
            + "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        var code = 1
        while code < texts.count {
            let n = min(100, texts.count - code)
            s += "\(n) beginbfchar\n"
            for k in code..<(code + n) { s += "<\(PdfWriter.hex4(k))> <\(PdfWriter.utf16Hex(texts[k]))>\n" }
            s += "endbfchar\n"
            code += 100
        }
        s += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return Array(s.utf8)
    }

    // MARK: The font program

    private static let program = buildProgram()

    /// A TrueType font of two glyphs: .notdef (a small box) and glyph 1, half an em wide, whose outline runs out along a
    /// line and back: no area, so nothing to paint even in a reader that ignores render mode 3, but a real bounding box.
    /// MuPDF drops text whose bounds are empty, which is a whole line of it if the glyph has no outline at all. Fixed bytes:
    /// no dates.
    private static func buildProgram() -> [UInt8] {
        var head = [UInt8](repeating: 0, count: 54)
        be32(&head, 0, 0x0001_0000) // version
        be32(&head, 4, 0x0001_0000) // fontRevision
        be32(&head, 12, 0x5F0F_3CF5) // magicNumber
        be16(&head, 18, 1000) // unitsPerEm
        be16(&head, 36, 0) // xMin
        be16(&head, 38, -200) // yMin
        be16(&head, 40, 500) // xMax
        be16(&head, 42, 800) // yMax
        be16(&head, 46, 8) // lowestRecPPEM
        be16(&head, 48, 2) // fontDirectionHint

        var hhea = [UInt8](repeating: 0, count: 36)
        be32(&hhea, 0, 0x0001_0000)
        be16(&hhea, 4, 800) // ascender
        be16(&hhea, 6, -200) // descender
        be16(&hhea, 10, width) // advanceWidthMax
        be16(&hhea, 16, width) // xMaxExtent
        be16(&hhea, 18, 1) // caretSlopeRise
        be16(&hhea, 34, 2) // numberOfHMetrics

        var hmtx = [UInt8](repeating: 0, count: 8)
        be16(&hmtx, 0, width)
        be16(&hmtx, 4, width)

        var maxp = [UInt8](repeating: 0, count: 32)
        be32(&maxp, 0, 0x0001_0000)
        be16(&maxp, 4, 2) // numGlyphs
        be16(&maxp, 6, 4) // maxPoints
        be16(&maxp, 8, 1) // maxContours
        be16(&maxp, 14, 1) // maxZones

        // Each: one contour, on-curve points, sixteen-bit relative coordinates.
        let notdef = glyph([50, 450, 450, 50], [0, 0, 700, 700])
        let line = glyph([0, 500, 0], [-200, 800, -200])
        let glyf = notdef + line

        var loca = [UInt8](repeating: 0, count: 6) // short offsets: half the byte offset
        be16(&loca, 2, notdef.count / 2)
        be16(&loca, 4, glyf.count / 2)

        // Windows Unicode: U+0020 to glyph 1, and the closing segment format 4 requires.
        var cmap = [UInt8](repeating: 0, count: 4 + 8 + 32)
        be16(&cmap, 2, 1) // numTables
        be16(&cmap, 4, 3) // platform
        be16(&cmap, 6, 1) // encoding
        be32(&cmap, 8, 12) // offset
        let f4 = 12
        be16(&cmap, f4, 4) // format
        be16(&cmap, f4 + 2, 32) // length
        be16(&cmap, f4 + 6, 4) // segCountX2
        be16(&cmap, f4 + 8, 4) // searchRange
        be16(&cmap, f4 + 10, 1) // entrySelector
        be16(&cmap, f4 + 12, 0) // rangeShift
        be16(&cmap, f4 + 14, 0x0020) // endCode
        be16(&cmap, f4 + 16, 0xFFFF)
        be16(&cmap, f4 + 20, 0x0020) // startCode
        be16(&cmap, f4 + 22, 0xFFFF)
        be16(&cmap, f4 + 24, 1 - 0x20) // idDelta
        be16(&cmap, f4 + 26, 1)

        var post = [UInt8](repeating: 0, count: 32)
        be32(&post, 0, 0x0003_0000) // no glyph names

        let nameText = utf16BEBytes("InkvoltOcrText")
        var names = [UInt8](repeating: 0, count: 6 + 12 * 2) + nameText
        be16(&names, 2, 2) // count
        be16(&names, 4, 6 + 12 * 2) // stringOffset
        for (at, id) in [(6, 1), (18, 6)] {
            be16(&names, at, 3) // Windows
            be16(&names, at + 2, 1) // Unicode
            be16(&names, at + 4, 0x0409)
            be16(&names, at + 6, id)
            be16(&names, at + 8, nameText.count)
        }

        let tables: [(tag: String, data: [UInt8])] = [
            ("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea), ("hmtx", hmtx), ("loca", loca), ("maxp", maxp), ("name", names), ("post", post),
        ]
        let size = 12 + 16 * tables.count + tables.reduce(0) { $0 + (($1.data.count + 3) & ~3) }
        var font = [UInt8](repeating: 0, count: size)
        be32(&font, 0, 0x0001_0000)
        be16(&font, 4, tables.count)
        be16(&font, 6, 128) // searchRange
        be16(&font, 8, 3) // entrySelector
        be16(&font, 10, tables.count * 16 - 128) // rangeShift
        var offset = 12 + 16 * tables.count
        var headAt = 0
        for (i, table) in tables.enumerated() {
            let entry = 12 + 16 * i
            font.replaceSubrange(entry..<(entry + 4), with: Array(table.tag.utf8))
            be32(&font, entry + 4, checksum(table.data))
            be32(&font, entry + 8, UInt32(offset))
            be32(&font, entry + 12, UInt32(table.data.count))
            font.replaceSubrange(offset..<(offset + table.data.count), with: table.data)
            if table.tag == "head" { headAt = offset }
            offset += (table.data.count + 3) & ~3
        }
        be32(&font, headAt + 8, 0xB1B0_AFBA &- checksum(font))
        return font
    }

    private static func glyph(_ xs: [Int], _ ys: [Int]) -> [UInt8] {
        let n = xs.count
        var glyph = [UInt8](repeating: 0, count: (14 + n + n * 4 + 1) & ~1)
        be16(&glyph, 0, 1) // numberOfContours
        be16(&glyph, 2, xs.min()!)
        be16(&glyph, 4, ys.min()!)
        be16(&glyph, 6, xs.max()!)
        be16(&glyph, 8, ys.max()!)
        be16(&glyph, 10, n - 1) // endPtsOfContours[0]; instructionLength stays 0
        for i in 0..<n {
            glyph[14 + i] = 0x01 // on curve
            be16(&glyph, 14 + n + i * 2, xs[i] - (i > 0 ? xs[i - 1] : 0))
            be16(&glyph, 14 + n + n * 2 + i * 2, ys[i] - (i > 0 ? ys[i - 1] : 0))
        }
        return glyph
    }

    /// Sixteen bits, big-endian; a negative value as its two's complement.
    private static func be16(_ data: inout [UInt8], _ at: Int, _ value: Int) {
        let v = UInt16(truncatingIfNeeded: value)
        data[at] = UInt8(v >> 8)
        data[at + 1] = UInt8(v & 0xFF)
    }

    private static func be32(_ data: inout [UInt8], _ at: Int, _ value: UInt32) {
        for k in 0..<4 { data[at + k] = UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32(k))) }
    }

    private static func utf16BEBytes(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }

    private static func checksum(_ data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        for i in Swift.stride(from: 0, to: data.count, by: 4) {
            var word: UInt32 = 0
            for k in 0..<4 { word = (word << 8) | UInt32(i + k < data.count ? data[i + k] : 0) }
            sum &+= word
        }
        return sum
    }
}
