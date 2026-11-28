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

    /// One scanned page: a JPEG, its resolution, and the words for its text layer (nil or none: no layer); or, made with
    /// `blackAndWhite`, a 1-bit image (`bits`) in place of the JPEG, for a small file (roadmap 4.4).
    public struct Page: Sendable {
        public var jpeg: [UInt8]
        public var dpi: Int
        public var words: [Word]?
        /// The page in black and white; when set, it is the page's image and `jpeg` is unused.
        public var bits: BitImage?
        /// `bits` may be written as lossless JBIG2 when smaller (Inkvolt PDF's scans, Windows' `Jbig2`).
        public var jbig2 = false

        public init(_ jpeg: [UInt8], dpi: Int, words: [Word]? = nil) {
            self.jpeg = jpeg
            self.dpi = dpi
            self.words = words
        }

        /// A black-and-white page: written as CCITT G4, or as 1-bit Flate when that is smaller (`PdfWriter.oneBit`).
        public static func blackAndWhite(_ bits: BitImage, dpi: Int, words: [Word]? = nil) -> Page {
            var page = Page([], dpi: dpi, words: words)
            page.bits = bits
            return page
        }
    }

    public enum WriteError: Error, Equatable {
        case noPages
        /// Not a JPEG with a frame header, or one with no height (an unterminated feeder page).
        case notAJpeg
        /// PDF/A and a password together: PDF/A forbids encryption.
        case pdfAWithPassword
        /// A CMYK picture in a PDF/A file (its sRGB output intent allows RGB and grey only).
        case cmykInPdfA
    }

    /// Text scaling (Tz, percent) is kept within what readers accept, whatever box a recognizer gives.
    private static let minScale = 1.0, maxScale = 1000.0

    /// The smallest font size written, in points: at "0.###" a smaller one would read as 0.
    private static let minSize = 0.01

    /// The PDF's bytes. `title`: the Info dictionary's (nil: "Scan"). `options`: PDF/A-2b or a password (`PdfWriteOptions`,
    /// roadmap 4.18); nil writes the plain file as before.
    /// - Throws: `WriteError.pdfAWithPassword` (PDF/A forbids encryption), `WriteError.cmykInPdfA`, `PdfEncryption.Problem` for
    ///   a password that can't be used or no cryptography installed.
    public static func write(_ pages: [Page], title: String? = nil, options: PdfWriteOptions? = nil) throws -> [UInt8] {
        if pages.isEmpty { throw WriteError.noPages }
        let archive = options?.pdfA == true
        if archive && options?.password != nil { throw WriteError.pdfAWithPassword }
        let crypt = try options?.password.map { try PdfEncryption.create($0) }
        // PDF/A's sRGB output intent allows DeviceRGB and DeviceGray, never DeviceCMYK (ISO 19005-2, 6.2.4.3). Scans are never CMYK.
        if archive, try pages.contains(where: { try $0.bits == nil && jpegInfo($0.jpeg).components == 4 }) { throw WriteError.cmykInPdfA }
        var w = ObjWriter()
        var font = OcrFont()
        // AES-256 (AESV3) is PDF 2.0's, Adobe's extension level 8 of PDF 1.7.
        w.raw(crypt == nil ? "%PDF-1.4\n" : "%PDF-1.7\n")
        w.bytes([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        // Fixed ids: 1 catalog, 2 pages, 3 info; then 3 objects per page, then the font's when any page has text (6), then
        // PDF/A's metadata and profile, or the encryption dictionary.
        let infoId = 3
        let pageIds = pages.indices.map { 4 + $0 * 3 }
        let fontId = 4 + pages.count * 3
        let (metadataId, profileId, encryptId) = (fontId + 6, fontId + 7, fontId + 6)
        let created = options?.now ?? Date()
        let shownTitle = title ?? "Scan"

        var catalog = "<< /Type /Catalog /Pages 2 0 R"
        if archive {
            catalog += " /Metadata \(metadataId) 0 R /OutputIntents [<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) "
                + "/Info (sRGB IEC61966-2.1) /DestOutputProfile \(profileId) 0 R >>]"
        }
        if crypt != nil { catalog += " /Extensions << /ADBE << /BaseVersion /1.7 /ExtensionLevel 8 >> >>" }
        // From here every object but the encryption dictionary has its strings and streams encrypted.
        w.encryption = crypt
        w.obj(1, catalog + " >>")
        w.obj(2, "<< /Type /Pages /Count \(pages.count) /Kids [\(pageIds.map { "\($0) 0 R" }.joined(separator: " "))] >>")
        w.obj(infoId, "<< /Producer (Inkvolt Print) /Title \(textString(shownTitle)) /CreationDate (\(PdfArchive.pdfDate(created))) >>")

        for (p, page) in pages.enumerated() {
            let (pxW, pxH, components) = try page.bits.map { ($0.width, $0.height, 1) } ?? jpegInfo(page.jpeg)
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
            if let bits = page.bits {
                let (filter, data) = try oneBit(bits, jbig2: page.jbig2)
                w.stream(imgId, "<< /Type /XObject /Subtype /Image /Width \(pxW) /Height \(pxH) /ColorSpace /DeviceGray "
                    + "/BitsPerComponent 1 \(filter) /Length \(data.count) >>", data)
            } else {
                let space = components == 1 ? "/DeviceGray" : components == 4 ? "/DeviceCMYK" : "/DeviceRGB"
                w.stream(imgId, "<< /Type /XObject /Subtype /Image /Width \(pxW) /Height \(pxH) /ColorSpace \(space) "
                    + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(page.jpeg.count) >>", page.jpeg)
            }
            w.stream(contentId, "<< /Length \(contentBytes.count) >>", contentBytes)
        }
        if !font.isEmpty { font.write({ w.obj($0, $1) }, { w.stream($0, $1, $2) }, fontId: fontId, firstId: fontId + 1) }
        if archive {
            let xmp = PdfArchive.xmp(title: shownTitle, producer: "Inkvolt Print", created: created)
            w.stream(metadataId, "<< /Type /Metadata /Subtype /XML /Length \(xmp.count) >>", xmp)
            let icc = IccProfiles.srgbForPrint()
            w.stream(profileId, "<< /N 3 /Length \(icc.count) >>", icc)
        }
        w.encryption = nil
        if let crypt { w.obj(encryptId, crypt.dictionary()) }

        try w.finish(rootId: 1, infoId: infoId, encryptId: crypt == nil ? nil : encryptId, withId: archive || crypt != nil)
        return w.out
    }

    /// A black-and-white image's stream for a /DeviceGray image at 1 bit: the filter entries (with their parameters) and the
    /// data, CCITT G4 (`CcittG4`) or Flate of the rows (0 black, `Deflate`), whichever is smaller. G4 wins on text; Flate can on
    /// a page of fine, even patterns (a halftone), where G4's runs are short. With `jbig2`, lossless JBIG2 (`Jbig2Generic`)
    /// too, a quarter or so smaller than G4 on text (Inkvolt PDF's roadmap 4.8).
    /// - Throws: `CancellationError` when `stop` fires.
    public static func oneBit(_ image: BitImage, jbig2: Bool = false, stop: BatchStop? = nil) throws -> (filter: String, data: [UInt8]) {
        let (coding, data) = try oneBitData(image, jbig2: jbig2, stop: stop)
        switch coding {
        case .ccittG4: return ("/Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns \(image.width) /Rows \(image.height) >>", data)
        case .jbig2: return ("/Filter /JBIG2Decode", data)
        case .flate: return ("/Filter /FlateDecode", data)
        }
    }

    /// How a black-and-white image's samples are stored (`oneBitData`).
    public enum OneBitCoding: Sendable { case ccittG4, jbig2, flate }

    /// `oneBit`'s choice and data. Each decodes to the same samples: 0 where the image is black (a set bit), as /DeviceGray
    /// reads 1 bit.
    /// - Throws: `CancellationError` when `stop` fires.
    public static func oneBitData(_ image: BitImage, jbig2: Bool = false, stop: BatchStop? = nil) throws -> (coding: OneBitCoding, data: [UInt8]) {
        var best = (coding: OneBitCoding.ccittG4, data: try CcittG4.encode(image, stop: stop))
        if jbig2 {
            let j = try Jbig2Generic.encode(image, stop: stop)
            if j.count < best.data.count { best = (.jbig2, j) }
        }
        try stop?.check()
        let flate = Deflate.zlib(image.inverted())
        return flate.count < best.data.count ? (.flate, flate) : best
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

    /// Pixel size and component count from the JPEG's frame header.
    public static func jpegInfo(_ jpeg: [UInt8]) throws -> (width: Int, height: Int, components: Int) {
        let off = JpegFix.findSofHeightOffset(jpeg)
        guard off >= 0, off + 4 < jpeg.count else { throw WriteError.notAJpeg }
        let h = Int(jpeg[off]) << 8 | Int(jpeg[off + 1])
        let w = Int(jpeg[off + 2]) << 8 | Int(jpeg[off + 3])
        guard h > 0, w > 0 else { throw WriteError.notAJpeg }
        return (w, h, Int(jpeg[off + 4]))
    }

    /// A number as .NET's "0.###" writes it, byte for byte: the double rounded to 15 significant digits, then to at most
    /// three decimals (halves away from zero), no exponent; a negative that rounds to zero is "-0", as there. Not a number
    /// or infinite: "0" (.NET would write "NaN", which no reader parses; its PdfWriter never passes one).
    static func f(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        let sign = d.sign == .minus ? "-" : ""
        if d == 0 { return sign + "0" }
        // "d.dddddddddddddde±x": the 15 significant digits, and where the point goes.
        let sci = String(format: "%.14e", abs(d))
        guard let ePos = sci.firstIndex(of: "e"), let exponent = Int(sci[sci.index(after: ePos)...]) else { return "0" }
        var digits = sci[..<ePos].compactMap(\.wholeNumberValue)
        var point = exponent + 1 // digits before the point
        let keep = point + 3
        if keep < 0 {
            digits = []
        } else if keep < digits.count {
            let up = digits[keep] >= 5
            digits.removeLast(digits.count - keep)
            if up {
                var i = keep - 1
                while i >= 0 && digits[i] == 9 {
                    digits[i] = 0
                    i -= 1
                }
                if i >= 0 {
                    digits[i] += 1
                } else {
                    digits.insert(1, at: 0)
                    point += 1
                }
            }
        }
        while let last = digits.last, last == 0, digits.count > max(point, 0) { digits.removeLast() }
        if digits.isEmpty { return sign + "0" }
        let text = { (ds: ArraySlice<Int>) in ds.map { String($0) }.joined() }
        var s = sign
        if point <= 0 {
            s += "0." + String(repeating: "0", count: -point) + text(digits[...])
        } else if point >= digits.count {
            s += text(digits[...]) + String(repeating: "0", count: point - digits.count)
        } else {
            s += text(digits[..<point]) + "." + text(digits[point...])
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

        /// While set, each object's strings and each stream's data are encrypted as written.
        var encryption: PdfEncryption?

        /// The first body whose strings couldn't be read for encryption: `finish` throws it, so no file goes out half open.
        private var failure: (any Error)?

        mutating func obj(_ id: Int, _ body: String) {
            offsets[id] = out.count
            raw("\(id) 0 obj\n\(encrypted(body))\nendobj\n")
        }

        mutating func stream(_ id: Int, _ dict: String, _ data: [UInt8]) {
            offsets[id] = out.count
            var (dict, data) = (dict, data)
            if let crypt = encryption {
                let plain = data.count
                data = crypt.encrypt(data)
                dict = encrypted(Self.replaceLength(dict, plain, data.count))
            }
            raw("\(id) 0 obj\n\(dict)\nstream\n")
            bytes(data)
            raw("\nendstream\nendobj\n")
        }

        private mutating func encrypted(_ body: String) -> String {
            guard let crypt = encryption else { return body }
            do {
                return try crypt.encryptStrings(body)
            } catch {
                if failure == nil { failure = error }
                return body
            }
        }

        /// "/Length <plain>" (not followed by another digit) made "/Length <encrypted>".
        static func replaceLength(_ dict: String, _ plain: Int, _ length: Int) -> String {
            let key = "/Length \(plain)"
            var rest = Substring(dict)
            var out = ""
            while let r = rest.range(of: key) {
                let after = rest[r.upperBound...]
                if let next = after.first, next.isASCII, next.isNumber {
                    out += rest[..<r.upperBound]
                } else {
                    out += rest[..<r.lowerBound] + "/Length \(length)"
                }
                rest = after
            }
            return out + rest
        }

        /// - Parameters:
        ///   - encryptId: the encryption dictionary's object, when the file has a password.
        ///   - withId: writes the file identifier PDF/A and encryption ask for (a new random one).
        mutating func finish(rootId: Int, infoId: Int, encryptId: Int? = nil, withId: Bool = false) throws {
            if let failure { throw failure }
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
            var extra = encryptId.map { " /Encrypt \($0) 0 R" } ?? ""
            if withId {
                let id = PdfEncryption.hex(PdfEncryption.random(16))
                extra += " /ID [<\(id)> <\(id)>]"
            }
            s += "trailer\n<< /Size \(max + 1) /Root \(rootId) 0 R /Info \(infoId) 0 R\(extra) >>\nstartxref\n\(xref)\n%%EOF\n"
            raw(s)
        }
    }
}
