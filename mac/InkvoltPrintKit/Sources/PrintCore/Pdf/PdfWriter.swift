import Foundation

/// Minimal PDF 1.4 writer for scanned pages (the Windows app's `InkvoltPrint.Core/Pdf/PdfWriter.cs`, ported as is): JPEG
/// pages embedded as they are (DCTDecode, no re-encode) plus an invisible text layer (render mode 3), so the PDF is
/// searchable and selectable in any script: a CID font with a /ToUnicode map (`OcrFont`), the words as hex strings of its
/// codes, so nothing a word holds can reach the file's syntax. PrintMac's `ScanPdf` gives it the pages and the words Vision
/// recognizes.
public enum PdfWriter {
    /// A recognised word, in the page image's pixels (origin top left).
    public struct Word: Equatable, Sendable {
        public var text: String
        public var x: Double, y: Double, width: Double, height: Double

        public init(_ text: String, x: Double, y: Double, width: Double, height: Double) {
            self.text = text
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// One scanned page: a JPEG, its resolution, and the words for its text layer (nil or none: no layer).
    public struct Page: Sendable {
        public var jpeg: [UInt8]
        public var dpi: Int
        public var words: [Word]?

        public init(_ jpeg: [UInt8], dpi: Int, words: [Word]? = nil) {
            self.jpeg = jpeg
            self.dpi = dpi
            self.words = words
        }
    }

    public enum WriteError: Error, Equatable {
        case noPages
        /// Not a JPEG with a frame header, or one with no height (an unterminated feeder page).
        case notAJpeg
    }

    /// Text scaling (Tz, percent) is kept within what readers accept, whatever box a recognizer gives.
    private static let minScale = 1.0, maxScale = 1000.0

    /// The smallest font size written, in points: at "0.###" a smaller one would read as 0.
    private static let minSize = 0.01

    /// The PDF's bytes. `title`: the Info dictionary's (nil: "Scan").
    public static func write(_ pages: [Page], title: String? = nil) throws -> [UInt8] {
        if pages.isEmpty { throw WriteError.noPages }
        var w = ObjWriter()
        var font = OcrFont()
        w.raw("%PDF-1.4\n")
        w.bytes([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        // Fixed ids: 1 catalog, 2 pages, 3 info; then 3 objects per page, then the font's when any page has text.
        let infoId = 3
        let pageIds = pages.indices.map { 4 + $0 * 3 }
        let fontId = 4 + pages.count * 3

        w.obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        w.obj(2, "<< /Type /Pages /Count \(pages.count) /Kids [\(pageIds.map { "\($0) 0 R" }.joined(separator: " "))] >>")
        w.obj(infoId, "<< /Producer (Inkvolt Print) /Title \(textString(title ?? "Scan")) /CreationDate (D:\(creationDate(Date()))Z) >>")

        for (p, page) in pages.enumerated() {
            let (pxW, pxH, components) = try jpegInfo(page.jpeg)
            let scale = 72.0 / Double(min(max(page.dpi, 1), 9600))
            let (ptW, ptH) = (Double(pxW) * scale, Double(pxH) * scale)
            let (pageId, imgId, contentId) = (pageIds[p], pageIds[p] + 1, pageIds[p] + 2)

            var content = "q \(f(ptW)) 0 0 \(f(ptH)) 0 0 cm /Im0 Do Q\n"
            let layer = (page.words?.isEmpty ?? true) ? "" : textLayer(page.words!, &font, scale, ptH)
            content += layer
            let contentBytes = Array(content.utf8) // ASCII: numbers, names and hex strings

            let fontResource = layer.isEmpty ? "" : " /Font << /F1 \(fontId) 0 R >>"
            w.obj(pageId, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(f(ptW)) \(f(ptH))] "
                + "/Resources << /XObject << /Im0 \(imgId) 0 R >>\(fontResource) >> /Contents \(contentId) 0 R >>")
            let space = components == 1 ? "/DeviceGray" : components == 4 ? "/DeviceCMYK" : "/DeviceRGB"
            w.stream(imgId, "<< /Type /XObject /Subtype /Image /Width \(pxW) /Height \(pxH) /ColorSpace \(space) "
                + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(page.jpeg.count) >>", page.jpeg)
            w.stream(contentId, "<< /Length \(contentBytes.count) >>", contentBytes)
        }
        if !font.isEmpty { font.write({ w.obj($0, $1) }, { w.stream($0, $1, $2) }, fontId: fontId, firstId: fontId + 1) }

        w.finish(rootId: 1, infoId: infoId)
        return w.out
    }

    /// A page's words as invisible text; empty when none can be written. Each is stretched to fill its box in its own text
    /// matrix. A space goes in the gap to the next word of a line, so a phrase across words is found; Chinese and Japanese
    /// words on a line, which take none, are stretched up to the next one so that no reader sees a gap to turn into a space.
    private static func textLayer(_ words: [Word], _ font: inout OcrFont, _ scale: Double, _ pageHeight: Double) -> String {
        var usable: [(box: Word, text: String, clusters: [String])] = []
        for word in words where word.x.isFinite && word.y.isFinite && word.width.isFinite && word.height.isFinite && word.height > 0 {
            let text = OcrText.clean(word.text)
            if !text.isEmpty { usable.append((word, text, OcrText.clusters(text))) }
        }
        var content = ""
        for i in usable.indices {
            let (box, text, wordClusters) = usable[i]
            var clusters = wordClusters
            let next = i + 1 < usable.count ? usable[i + 1] : nil
            let sameLine = next.map { Self.sameLine(box, $0.box) } ?? false
            let unspaced = sameLine && OcrText.isUnspaced(text) && OcrText.isUnspaced(next!.text)
            var width = box.width
            if unspaced, let next {
                let gap = next.box.x - box.x - box.width
                if gap > 0 && gap < box.height { width += gap }
            }

            let size = max(minSize, box.height * scale)
            let baseline = pageHeight - (box.y + box.height) * scale + size * 0.2 // baseline about 20% above the box's bottom
            let right = box.x + box.width
            // Right to left, the word before lies to the right: the space between them goes in one string with this word, on
            // its right end, which is read as its first character. pdf.js drops a space shown by itself or leading a string.
            if i > 0 {
                let before = usable[i - 1]
                let gapRight = before.box.x - right
                if Self.sameLine(box, before.box) && !(OcrText.isUnspaced(text) && OcrText.isUnspaced(before.text))
                    && gapRight > 0 && gapRight < 2 * max(box.height, before.box.height) {
                    clusters.append(" ")
                    width += gapRight
                }
            }
            show(&content, &font, clusters, box.x * scale, baseline, size, width * scale)
            guard let next, sameLine, !unspaced, next.box.x + next.box.width > box.x else { continue }
            let gap = next.box.x - right
            // Boxes that touch or overlap a little are still two words: their space gets almost no width.
            if gap > -box.height / 2 && gap < 2 * max(box.height, next.box.height) {
                show(&content, &font, [" "], right * scale, baseline, size, max(gap, box.height / 100) * scale)
            }
        }
        return content.isEmpty ? "" : "BT 3 Tr\n\(content)ET\n"
    }

    private static func show(_ content: inout String, _ font: inout OcrFont, _ clusters: [String], _ x: Double, _ baseline: Double, _ size: Double,
                             _ width: Double) {
        let (codes, count) = font.encode(clusters)
        if count == 0 { return }
        let natural = Double(OcrFont.width) / 1000 * size * Double(count)
        let tz = min(max(width > 0 ? 100 * width / natural : 100, minScale), maxScale)
        content += "/F1 \(f(size)) Tf \(f(tz)) Tz 1 0 0 1 \(f(x)) \(f(baseline)) Tm <\(codes)> Tj\n"
    }

    /// Whether two boxes overlap by more than half the shorter's height.
    private static func sameLine(_ a: Word, _ b: Word) -> Bool {
        min(a.y + a.height, b.y + b.height) - max(a.y, b.y) > 0.5 * min(a.height, b.height)
    }

    /// A text string for the Info dictionary, in UTF-16 with its byte order mark, hex-encoded.
    private static func textString(_ text: String) -> String { "<FEFF\(utf16Hex(OcrText.clean(text)))>" }

    private static func creationDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ v: Int?) -> String { let v = v ?? 0; return v < 10 ? "0\(v)" : "\(v)" }
        return "\(c.year ?? 2000)\(two(c.month))\(two(c.day))\(two(c.hour))\(two(c.minute))\(two(c.second))"
    }

    /// Pixel size and component count from the JPEG's frame header.
    public static func jpegInfo(_ jpeg: [UInt8]) throws -> (width: Int, height: Int, components: Int) {
        let off = JpegFix.findSofHeightOffset(jpeg)
        guard off >= 0, off + 4 < jpeg.count else { throw WriteError.notAJpeg }
        let h = Int(jpeg[off]) << 8 | Int(jpeg[off + 1])
        let w = Int(jpeg[off + 2]) << 8 | Int(jpeg[off + 3])
        guard h > 0, w > 0 else { throw WriteError.notAJpeg }
        return (w, h, Int(jpeg[off + 4]))
    }

    /// A number as .NET's "0.###" writes it: at most three decimals (halves away from zero), no exponent, no "-0".
    static func f(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if abs(d) >= 1e15 { return String(format: "%.0f", d) } // no thousandths left to write
        let thousandths = (abs(d) * 1000).rounded(.toNearestOrAwayFromZero)
        if thousandths == 0 { return "0" }
        let whole = (thousandths / 1000).rounded(.down)
        let fraction = min(max(Int(thousandths - whole * 1000), 0), 999)
        var s = (d < 0 ? "-" : "") + String(format: "%.0f", whole)
        if fraction > 0 {
            var digits = String(fraction)
            digits = String(repeating: "0", count: 3 - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            s += "." + digits
        }
        return s
    }

    /// Four upper-case hex digits.
    static func hex4(_ v: Int) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - s.count)) + s
    }

    /// The text's UTF-16 units, big-endian, in upper-case hex.
    static func utf16Hex(_ text: String) -> String { text.utf16.map { hex4(Int($0)) }.joined() }

    private struct ObjWriter {
        var out: [UInt8] = []
        private var offsets: [Int: Int] = [:]

        mutating func raw(_ text: String) { out += Array(text.utf8) }

        mutating func bytes(_ data: [UInt8]) { out += data }

        mutating func obj(_ id: Int, _ body: String) {
            offsets[id] = out.count
            raw("\(id) 0 obj\n\(body)\nendobj\n")
        }

        mutating func stream(_ id: Int, _ dict: String, _ data: [UInt8]) {
            offsets[id] = out.count
            raw("\(id) 0 obj\n\(dict)\nstream\n")
            bytes(data)
            raw("\nendstream\nendobj\n")
        }

        mutating func finish(rootId: Int, infoId: Int) {
            let max = offsets.keys.max() ?? 0
            let xref = out.count
            var s = "xref\n0 \(max + 1)\n0000000000 65535 f \n"
            for i in Swift.stride(from: 1, through: max, by: 1) {
                if let off = offsets[i] {
                    let digits = String(off)
                    s += String(repeating: "0", count: Swift.max(0, 10 - digits.count)) + digits + " 00000 n \n"
                } else {
                    s += "0000000000 65535 f \n"
                }
            }
            s += "trailer\n<< /Size \(max + 1) /Root \(rootId) 0 R /Info \(infoId) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
            raw(s)
        }
    }
}
