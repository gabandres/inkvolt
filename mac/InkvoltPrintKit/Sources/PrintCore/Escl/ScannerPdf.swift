import Foundation
import Synchronization

/// Renders each page of a PDF to a JPEG (PDFKit in PrintMac, the engine Print a PDF uses; the Windows app's
/// `IPdfPageRenderer`).
public protocol PdfPageRenderer: Sendable {
    /// Every page of `pdf`, in order, as a JPEG at `dpi`.
    func render(_ pdf: [UInt8], dpi: Int) async throws -> [[UInt8]]
}

/// Where a scanned page came from when the scanner sent a PDF: that PDF, the page's place in it, and whether it was rendered.
/// `document` tells one scanner PDF from another (Windows compares the byte arrays by reference).
public struct PdfOrigin: Equatable, Sendable {
    public var pdf: [UInt8]
    public var document: Int
    public var page: Int
    public var pageCount: Int
    public var rendered: Bool
}

/// A page about to be saved, for `ScannerPdf.keepAsSent`: where it came from and whether it changed (turned, cropped,
/// straightened, cut into photos, or given a text layer).
public struct PageToSave: Equatable, Sendable {
    public var origin: PdfOrigin?
    public var changed: Bool

    public init(_ origin: PdfOrigin?, changed: Bool) {
        self.origin = origin
        self.changed = changed
    }
}

/// Scanners that send only PDF from a source (print/ROADMAP.md 1.3; the Windows Core's `ScannerPdf`). Their pages go to the
/// review, OCR, presets and photos as the JPEG pages every other scanner sends: a page that is one JPEG picture (a scanner's
/// PDF nearly always is) is taken out as it is, byte for byte, so nothing is re-encoded and the page is the one a JPEG scan
/// gives; anything else (a picture in another encoding, a turned page, compressed object streams) is rendered at the scan's
/// resolution by `renderer`. Each page remembers its PDF (`origin(of:)`), so a file saved as PDF with its pages as they came
/// is the scanner's own PDF (`keepAsSent`).
public enum ScannerPdf {
    public static let mediaType = "application/pdf"

    /// Pages remembered from this many scanner PDFs at most (the oldest forgotten first): Windows keeps an origin as long as
    /// its page's bytes live, which Swift's value arrays can't follow, so the Mac bounds the table instead.
    static let rememberedDocuments = 32

    private struct State {
        var renderer: (any PdfPageRenderer)?
        var origins: [[UInt8]: PdfOrigin] = [:]
        var documents: [Int] = []
        var next = 1
    }

    private static let state = Mutex(State())

    /// Renders the pages that aren't one JPEG picture (set by the app: PrintMac's PDFKit; nil in tests and where there is none).
    public static var renderer: (any PdfPageRenderer)? {
        get { state.withLock { $0.renderer } }
        set { state.withLock { $0.renderer = newValue } }
    }

    /// The PDF a page handed over by `pages` came from; nil for a page that came as a JPEG.
    public static func origin(of page: [UInt8]) -> PdfOrigin? { state.withLock { $0.origins[page] } }

    /// The scanner's PDF as JPEG pages (see the type's summary).
    public static func pages(_ pdf: [UInt8], dpi: Int) async throws -> [[UInt8]] {
        var pages = jpegPages(pdf)
        let rendered = pages == nil
        if pages == nil {
            guard let renderer else { throw ScanError(loc("This scanner sent its pages as a PDF whose pictures Inkvolt Print can't take out here.")) }
            do {
                pages = try await renderer.render(pdf, dpi: dpi)
            } catch let e as CancellationError {
                throw e
            } catch let e as ScanError {
                throw e
            } catch {
                throw ScanError(loc("The scanner's PDF couldn't be opened: {0}", error))
            }
        }
        guard let pages, !pages.isEmpty else { throw ScanError(loc("The scanner sent a PDF without pages.")) }
        state.withLock { s in
            let document = s.next
            s.next += 1
            s.documents.append(document)
            for (i, page) in pages.enumerated() {
                s.origins[page] = PdfOrigin(pdf: pdf, document: document, page: i, pageCount: pages.count, rendered: rendered)
            }
            if s.documents.count > rememberedDocuments {
                let forgotten = Set(s.documents.prefix(s.documents.count - rememberedDocuments))
                s.documents.removeFirst(forgotten.count)
                s.origins = s.origins.filter { !forgotten.contains($0.value.document) }
            }
        }
        return pages
    }

    /// The scanner's own PDF, when the file is exactly it: every page from one PDF, all of them, in order, none changed. Nil
    /// otherwise (the file is then made from the pages; a page taken out of the PDF goes back in as the same JPEG).
    public static func keepAsSent(_ pages: [PageToSave]) -> [UInt8]? {
        guard let first = pages.first?.origin, first.pageCount == pages.count else { return nil }
        for (i, page) in pages.enumerated() {
            guard !page.changed, let o = page.origin, o.document == first.document, o.page == i else { return nil }
        }
        return first.pdf
    }

    /// Why a file can't be the scanner's own PDF, in words for the status line; nil when it is, or none of it came as PDF.
    public static func whyNotAsSent(_ pages: [PageToSave]) -> String? {
        if pages.allSatisfy({ $0.origin == nil }) || keepAsSent(pages) != nil { return nil }
        return pages.contains { $0.changed }
            ? loc("Your changes (or the text layer) are in it, so it was made from the scanner's pages, pictures unchanged.")
            : loc("Pages were added, left out, moved or split into files, so it was made from the scanner's pages, pictures unchanged.")
    }

    // MARK: Taking pictures out

    /// Each page's JPEG, taken out as it is, when every page is one DCT-encoded picture (grey or color, no mask, not turned);
    /// nil when any isn't, or the file can't be read this simply (then it is rendered).
    public static func jpegPages(_ pdf: [UInt8]) -> [[UInt8]]? {
        guard let doc = MiniPdf(pdf), let pages = doc.pages(), !pages.isEmpty else { return nil }
        var jpegs: [[UInt8]] = []
        for (_, resources, rotate) in pages {
            if rotate % 360 != 0 { return nil }
            let images = doc.xObjects(resources).map(doc.object)
            guard images.count == 1, let image = images[0], MiniPdf.is(image.dict, "Subtype", "Image") else { return nil }
            if !MiniPdf.matches(#"/Filter\s*(?:/DCTDecode\b|\[\s*/DCTDecode\s*\])"#, image.dict)
                || MiniPdf.matches(#"/(SMask|Mask|Decode|ImageMask)\b"#, image.dict) { return nil }
            guard let jpeg = doc.streamData(image), jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return nil }
            guard let components = jpegComponents(jpeg), components == 1 || components == 3 else { return nil }
            jpegs.append(jpeg)
        }
        return jpegs
    }

    /// The JPEG's colour components from its frame header; nil when it has none or no size.
    static func jpegComponents(_ jpeg: [UInt8]) -> Int? {
        let at = JpegFix.findSofHeightOffset(jpeg)
        guard at >= 0, at + 4 < jpeg.count else { return nil }
        let height = Int(jpeg[at]) << 8 | Int(jpeg[at + 1]), width = Int(jpeg[at + 2]) << 8 | Int(jpeg[at + 3])
        return height == 0 || width == 0 ? nil : Int(jpeg[at + 4])
    }

    /// JPEG pages as a scanner's PDF, each embedded as it is at its resolution (the fixture scanner's PDF answers, and the
    /// tests; a scan saved by the app goes through PrintMac's `ScanPdf`). `words`: a text run per page, as a text layer adds.
    public static func write(_ pages: [(jpeg: [UInt8], dpi: Int, words: [String]?)], title: String = "Scan") -> [UInt8] {
        var out: [UInt8] = Array("%PDF-1.4\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        var offsets: [Int: Int] = [:]
        func obj(_ id: Int, _ body: String) {
            offsets[id] = out.count
            out += Array("\(id) 0 obj\n\(body)\nendobj\n".utf8)
        }
        func stream(_ id: Int, _ dict: String, _ data: [UInt8]) {
            offsets[id] = out.count
            out += Array("\(id) 0 obj\n\(dict)\nstream\n".utf8) + data + Array("\nendstream\nendobj\n".utf8)
        }
        func f(_ d: Double) -> String { String(format: "%.3f", d).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
        let pageIds = pages.indices.map { 4 + $0 * 3 }
        let fontId = 4 + pages.count * 3
        obj(1, "<< /Type /Catalog /Pages 2 0 R >>")
        obj(2, "<< /Type /Pages /Count \(pages.count) /Kids [\(pageIds.map { "\($0) 0 R" }.joined(separator: " "))] >>")
        obj(3, "<< /Producer (Inkvolt Print) /Title (\(title)) >>")
        var anyText = false
        for (p, page) in pages.enumerated() {
            let at = JpegFix.findSofHeightOffset(page.jpeg)
            let height = at >= 0 ? Int(page.jpeg[at]) << 8 | Int(page.jpeg[at + 1]) : 1
            let width = at >= 0 ? Int(page.jpeg[at + 2]) << 8 | Int(page.jpeg[at + 3]) : 1
            let components = at >= 0 ? Int(page.jpeg[at + 4]) : 3
            let scale = 72.0 / Double(page.dpi)
            let (w, h) = (Double(width) * scale, Double(height) * scale)
            let (pageId, imageId, contentId) = (pageIds[p], pageIds[p] + 1, pageIds[p] + 2)
            var content = "q \(f(w)) 0 0 \(f(h)) 0 0 cm /Im0 Do Q\n"
            let text = (page.words ?? []).filter { !$0.isEmpty }
            if !text.isEmpty {
                anyText = true
                content += "BT 3 Tr /F1 12 Tf 10 10 Td (\(text.joined(separator: " "))) Tj ET\n"
            }
            obj(pageId, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(f(w)) \(f(h))] /Resources << /XObject << /Im0 \(imageId) 0 R >>"
                + (text.isEmpty ? "" : " /Font << /F1 \(fontId) 0 R >>") + " >> /Contents \(contentId) 0 R >>")
            let colorSpace = components == 1 ? "/DeviceGray" : components == 4 ? "/DeviceCMYK" : "/DeviceRGB"
            stream(imageId, "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace \(colorSpace) "
                + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(page.jpeg.count) >>", page.jpeg)
            let bytes = Array(content.utf8)
            stream(contentId, "<< /Length \(bytes.count) >>", bytes)
        }
        if anyText { obj(fontId, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>") }
        let size = (offsets.keys.max() ?? 0) + 1
        let xref = out.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for id in 1..<size { table += offsets[id].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 65535 f \n" }
        table += "trailer\n<< /Size \(size) /Root 1 0 R /Info 3 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }
}

/// Just enough of a PDF to find each page's pictures: objects, the page tree, resources (inherited too), streams. The
/// text is the file's bytes as Latin-1, one UTF-16 unit per byte, so `NSString` positions are byte offsets.
struct MiniPdf {
    struct Obj {
        var id: Int
        var dict: String
        var streamStart: Int
    }

    private let bytes: [UInt8]
    private let text: NSString
    private var objects: [Int: Obj] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed and valid.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let objectStart = regex(#"(?<![0-9])(\d+)\s+\d+\s+obj\b"#)
    private static let streamKeyword = regex(#"(?<![a-z])stream\r?\n"#)
    private static let rootRef = regex(#"/Root\s+(\d+)\s+\d+\s+R"#)
    private static let refPattern = regex(#"(\d+)\s+\d+\s+R\b"#)

    init?(_ bytes: [UInt8]) {
        guard let text = String(data: Data(bytes), encoding: .isoLatin1), text.hasPrefix("%PDF-") else { return nil }
        self.bytes = bytes
        self.text = text as NSString
        let length = self.text.length
        // Object by object, stepping over each stream's data, so bytes inside a picture are never taken for an object.
        var pos = 0
        while pos < length, let m = Self.objectStart.firstMatch(in: text, range: NSRange(location: pos, length: length - pos)) {
            let start = m.range.location + m.range.length
            let endRange = self.text.range(of: "endobj", options: .literal, range: NSRange(location: start, length: length - start))
            var end = endRange.location == NSNotFound ? -1 : endRange.location
            let stream = Self.streamKeyword.firstMatch(in: text, range: NSRange(location: start, length: length - start))
            let isStream = stream != nil && (end < 0 || stream!.range.location < end)
            if end < 0 && !isStream { end = length }
            guard let id = Int(self.text.substring(with: m.range(at: 1))) else { return nil }
            let dictEnd = isStream ? stream!.range.location : end
            let obj = Obj(id: id, dict: self.text.substring(with: NSRange(location: start, length: dictEnd - start)),
                          streamStart: isStream ? stream!.range.location + stream!.range.length : -1)
            objects[id] = obj // a later revision of an object replaces the earlier one
            if !isStream {
                pos = end
                continue
            }
            let declared = Self.value(obj.dict, "Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            let data = min(obj.streamStart + max(0, declared), length)
            let after = self.text.range(of: "endstream", options: .literal, range: NSRange(location: data, length: length - data))
            pos = after.location == NSNotFound ? length : after.location
        }
    }

    func object(_ id: Int) -> Obj? { objects[id] }

    /// The pages in order, each with the resources it uses (its own or inherited) and its turn.
    func pages() -> [(page: Obj, resources: String, rotate: Int)]? {
        let all = Self.rootRef.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        guard let last = all.last, let catalog = object(ref(last, in: text)) else { return nil }
        guard let pagesId = Self.refAfter(catalog.dict, "Pages"), let tree = object(pagesId) else { return nil }
        var pages: [(Obj, String, Int)] = []
        var seen = Set<Int>()
        guard walk(tree, "", 0, &pages, 0, &seen) else { return nil }
        return pages
    }

    private func walk(_ node: Obj, _ resources: String, _ rotate: Int, _ pages: inout [(Obj, String, Int)], _ depth: Int, _ seen: inout Set<Int>) -> Bool {
        guard depth <= 32, seen.insert(node.id).inserted else { return false } // the page tree loops
        let resources = Self.value(node.dict, "Resources") ?? resources
        let rotate = Self.value(node.dict, "Rotate").flatMap { Int($0) } ?? rotate
        if Self.is(node.dict, "Type", "Pages") {
            guard let kids = Self.value(node.dict, "Kids") else { return false }
            for k in Self.refPattern.matches(in: kids, range: NSRange(location: 0, length: (kids as NSString).length)) {
                guard let kid = object(ref(k, in: kids as NSString)), walk(kid, resources, rotate, &pages, depth + 1, &seen) else { return false }
            }
        } else {
            pages.append((node, resources, rotate))
        }
        return true
    }

    /// The object numbers of the pictures and forms a page's resources name.
    func xObjects(_ resources: String) -> [Int] {
        let dict = resolve(resources)
        guard let xobjects = Self.value(dict, "XObject") else { return [] }
        let list = resolve(xobjects) as NSString
        return Self.refPattern.matches(in: list as String, range: NSRange(location: 0, length: list.length)).map { ref($0, in: list) }
    }

    func streamData(_ obj: Obj) -> [UInt8]? {
        if obj.streamStart < 0 { return nil }
        let start = obj.streamStart
        let lengthText = Self.value(obj.dict, "Length")
        var length: Int
        if let lengthText, let m = Self.refPattern.firstMatch(in: lengthText, range: NSRange(location: 0, length: (lengthText as NSString).length)),
           let lengthObj = object(ref(m, in: lengthText as NSString)) {
            guard let n = Int(lengthObj.dict.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            length = n
        } else if let lengthText, let n = Int(lengthText.trimmingCharacters(in: .whitespaces)) {
            length = n
        } else {
            let end = text.range(of: "endstream", options: .literal, range: NSRange(location: start, length: text.length - start))
            if end.location == NSNotFound { return nil }
            length = end.location - start
            while length > 0 && (bytes[start + length - 1] == 0x0A || bytes[start + length - 1] == 0x0D) { length -= 1 }
        }
        guard length >= 0, start + length <= bytes.count else { return nil } // the stream runs past the file
        return Array(bytes[start..<start + length])
    }

    /// An indirect reference's object's text, or the text itself.
    private func resolve(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        if let m = Self.refPattern.firstMatch(in: trimmed as String, range: NSRange(location: 0, length: trimmed.length)),
           m.range.location == 0, m.range.length == trimmed.length, let o = object(ref(m, in: trimmed)) {
            return o.dict
        }
        return value
    }

    private func ref(_ m: NSTextCheckingResult, in text: NSString) -> Int { Int(text.substring(with: m.range(at: 1))) ?? -1 }

    private static func refAfter(_ dict: String, _ key: String) -> Int? {
        guard let v = value(dict, key), let m = refPattern.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) else { return nil }
        return Int((v as NSString).substring(with: m.range(at: 1)))
    }

    static func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    static func `is`(_ dict: String, _ key: String, _ name: String) -> Bool { matches("/\(key)\\s*/\(name)\\b", dict) }

    /// A key's value in a dictionary's text: a nested dictionary or array (balanced), a reference, or one token.
    static func value(_ dict: String, _ key: String) -> String? {
        let ns = dict as NSString
        guard let m = regex("/\(key)(?![A-Za-z0-9])\\s*").firstMatch(in: dict, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let i = m.range.location + m.range.length
        if i >= ns.length { return nil }
        let rest = ns.substring(from: i)
        if rest.hasPrefix("[") || rest.hasPrefix("<<") {
            let (open, close) = rest.hasPrefix("[") ? ("[", "]") : ("<<", ">>")
            var depth = 0
            var j = i
            while j < ns.length {
                let here = ns.substring(from: j)
                if here.hasPrefix(open) {
                    depth += 1
                    j += open.count
                } else if here.hasPrefix(close) {
                    depth -= 1
                    j += close.count
                    if depth == 0 { return ns.substring(with: NSRange(location: i, length: j - i)) }
                } else {
                    j += 1
                }
            }
            return nil // unbalanced
        }
        if let r = refPattern.firstMatch(in: dict, range: NSRange(location: i, length: ns.length - i)), r.range.location == i {
            return ns.substring(with: r.range)
        }
        var end = i
        while end < ns.length {
            let c = ns.character(at: end)
            let isStop = c == 0x2F || c == 0x3E || c == 0x5B || c == 0x3C || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
            if isStop && !(end == i && c == 0x2F) { break }
            end += 1
        }
        return ns.substring(with: NSRange(location: i, length: end - i))
    }
}
