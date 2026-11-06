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
            guard images.count == 1, let image = images[0], doc.isImage(image) else { return nil }
            let dict = doc.text(image.dict)
            if !matches(dctFilter, dict) || matches(masked, dict) { return nil }
            guard let jpeg = doc.streamData(image), jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return nil }
            guard let components = jpegComponents(jpeg), components == 1 || components == 3 else { return nil }
            jpegs.append(jpeg)
        }
        return jpegs
    }

    // The patterns are fixed and valid; made once, not once per page.
    private static let dctFilter = try! NSRegularExpression(pattern: #"/Filter\s*(?:/DCTDecode\b|\[\s*/DCTDecode\s*\])"#)
    private static let masked = try! NSRegularExpression(pattern: #"/(SMask|Mask|Decode|ImageMask)\b"#)

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
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
    public static func write(_ pages: [(jpeg: [UInt8], dpi: Int, words: [String]?)], title: String = "Scan") -> [UInt8] { // English: the fixture scanner's PDF title
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
