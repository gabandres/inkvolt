import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Ported from ScannerPdfTests.cs: scanners that only give PDF (print/ROADMAP.md 1.3). Adapted: the scanner's PDFs are
/// written by `ScannerPdf.write` (PrintCore's, the JPEGs embedded as they are; Windows uses its `PdfWriter`, whose OCR text
/// layer is PrintMac's `ScanPdf` on the Mac, so the page with words gets a plain text run instead); `ScannerPdf.renderer` is
/// global, so the suite runs one test at a time; a page's origin is looked up by its bytes (Swift's arrays have no identity),
/// so the same bytes scanned as JPEG after a PDF run share its origin: the JPEG run's "no origin" checks use pages of their own.
@Suite(.serialized)
final class ScannerPdfTests {
    private static let host = "192.0.2.11"

    init() { ScannerPdf.renderer = nil }
    deinit { ScannerPdf.renderer = nil }

    /// Six different pages, as a feeder batch (sizes differ, so the bytes do).
    private static let six: [[UInt8]] = (0..<6).map { TestJpeg.build(width: 2550 - $0 * 10, height: 3300, dnlHeight: nil) }

    private static func inkjetFile(_ name: String) -> [UInt8]? { try? Fixtures.data("inkjet-demo/\(name)") }

    /// The inkjet's capabilities with JPEG taken out of its feeder's profile, as demo mode serves them.
    private static func feederPdfOnly(_ capabilities: [UInt8]) -> [UInt8] {
        let text = String(decoding: capabilities, as: UTF8.self)
        guard let glass = text.range(of: "<scan:Platen>") else { return capabilities }
        let feeder = String(text[..<glass.lowerBound])
            .replacingOccurrences(of: #"\s*<(pwg:DocumentFormat|scan:DocumentFormatExt)>image/jpeg</\1>"#, with: "", options: .regularExpression)
        return Array((feeder + text[glass.lowerBound...]).utf8)
    }

    private static func inkjet(feederPdfOnly: Bool, glassPage: (@Sendable () -> [UInt8])? = nil,
                               replace: (@Sendable (String) -> [UInt8]?)? = nil) -> FixtureTransport {
        FixtureTransport(document: { name in
            if let replaced = replace?(name) { return replaced }
            guard let bytes = inkjetFile(name) else { return nil }
            return name == "eSCL_ScannerCapabilities.xml" && feederPdfOnly ? Self.feederPdfOnly(bytes) : bytes
        }, scanPage: glassPage ?? { Self.six[0] }, feederBatch: { Self.six })
    }

    /// The pages of a scan, and the ScanSettings each job posted.
    private static func scan(_ printer: FixtureTransport, _ source: ScanSource) async throws -> (pages: [[UInt8]], settings: [String]) {
        let network = Network(printer)
        let http = DeviceHttp(host: host, transport: network)
        let client = EsclClient(http, root: try http.http("/eSCL/"))
        var pages: [[UInt8]] = []
        for try await page in client.scan(ScanRequest(source: source, resolution: 300)) { pages.append(page) }
        let settings = network.seen.filter { $0.method == "POST" && $0.url.path.hasSuffix("/ScanJobs") }.map { String(decoding: $0.body ?? [], as: UTF8.self) }
        return (pages, settings)
    }

    @Test func A_PDF_only_feeder_scans_the_same_pages_as_its_JPEG_run() async throws {
        let jpegRun = try await Self.scan(Self.inkjet(feederPdfOnly: false), .adf).pages
        let (pdfRun, settings) = try await Self.scan(Self.inkjet(feederPdfOnly: true), .adf)

        #expect(jpegRun.count == 6)
        #expect(pdfRun == jpegRun) // byte for byte: the same split, straightening, crop and OCR
        #expect(settings.contains { $0.contains("<pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>") })
        #expect(settings.contains { $0.contains("<scan:XResolution>300</scan:XResolution>") })

        // Every page knows its PDF: one for the feeder run, six pages, taken out (not rendered).
        let origins = pdfRun.map(ScannerPdf.origin(of:))
        #expect(origins.allSatisfy { $0 != nil })
        #expect(Set(origins.map { $0?.document }).count == 1)
        #expect(origins.map { $0?.page } == [0, 1, 2, 3, 4, 5])
        #expect(origins.allSatisfy { $0?.rendered == false })
    }

    /// A Mac addition: demo mode's inkjet serves its capabilities as the Windows demo does (`Demo.feederPdfOnly`), so its
    /// feeder's pages come out of one PDF, taken out as they are, and its glass still sends JPEG.
    @Test func The_demo_inkjets_feeder_sends_PDF_only() async throws {
        let six = Self.six
        let network = Demo.network(fixtures: Fixtures.root, scanPage: { page, _, _ in six[page] })
        let http = DeviceHttp(host: Demo.inkjetHost, transport: network.http)
        let client = EsclClient(http, root: try http.http("/eSCL/"))
        let caps = try #require(try await client.capabilities())
        #expect(caps.adf?.pdfOnly == true)
        #expect(caps.platen?.pdfOnly == false)

        var feeder: [[UInt8]] = []
        for try await page in client.scan(ScanRequest(source: .adf, resolution: 300)) { feeder.append(page) }
        #expect(feeder == DemoScan.feeder.map { six[$0] })
        let origins = feeder.map(ScannerPdf.origin(of:))
        #expect(origins.allSatisfy { $0?.rendered == false && $0?.pageCount == 3 })
        #expect(Set(origins.map { $0?.document }).count == 1)

        var glass: [[UInt8]] = []
        for try await page in client.scan(ScanRequest(source: .platen, resolution: 300)) { glass.append(page) }
        #expect(glass.count == 1)
    }

    @Test func The_glass_and_the_feeder_still_send_JPEG_when_they_offer_it() async throws {
        let caps = ScannerCapabilities.parse(try DeviceXml.load(Self.feederPdfOnly(try Fixtures.data("inkjet-demo/eSCL_ScannerCapabilities.xml"))))
        #expect(caps.adf?.pdfOnly == true)
        #expect(caps.platen?.pdfOnly == false)

        let glassPage = TestJpeg.build(width: 2400, height: 3000, dnlHeight: nil) // never served as a PDF page here
        let (glass, settings) = try await Self.scan(Self.inkjet(feederPdfOnly: true, glassPage: { glassPage }), .platen)
        #expect(glass == [glassPage])
        #expect(settings.contains { $0.contains("<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>") })
        #expect(ScannerPdf.origin(of: glass[0]) == nil)
    }

    @Test func A_PDF_only_glass_gives_its_page_from_a_one_page_PDF() async throws {
        let caps = String(decoding: try Fixtures.data("inkjet-demo/eSCL_ScannerCapabilities.xml"), as: UTF8.self)
            .replacingOccurrences(of: "<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>", with: "")
            .replacingOccurrences(of: "<scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>", with: "")
        let page = TestJpeg.build(width: 1275, height: 1650, dnlHeight: nil, components: 1)
        let printer = Self.inkjet(feederPdfOnly: false, glassPage: { page }, replace: { $0 == "eSCL_ScannerCapabilities.xml" ? Array(caps.utf8) : nil })
        let glass = try await Self.scan(printer, .platen).pages

        #expect(glass == [page])
        #expect(ScannerPdf.origin(of: glass[0])?.pageCount == 1)
    }

    @Test func A_source_with_neither_JPEG_nor_PDF_says_so() async throws {
        let caps = String(decoding: try Fixtures.data("inkjet-demo/eSCL_ScannerCapabilities.xml"), as: UTF8.self)
            .replacingOccurrences(of: "image/jpeg", with: "image/png").replacingOccurrences(of: "application/pdf", with: "image/tiff")
        let printer = Self.inkjet(feederPdfOnly: false, replace: { $0 == "eSCL_ScannerCapabilities.xml" ? Array(caps.utf8) : nil })
        await #expect(throws: ScanError("This scanner doesn't send JPEG or PDF pages from this source, which Inkvolt Print needs.")) {
            _ = try await Self.scan(printer, .adf)
        }
    }

    // MARK: Taking pictures out

    private static func pdf(_ pages: [(jpeg: [UInt8], dpi: Int, words: [String]?)]) -> [UInt8] { ScannerPdf.write(pages) }

    /// The PDF's text as Latin-1 (a byte per character) with `from` replaced.
    private static func edit(_ pdf: [UInt8], _ from: String, _ to: String) -> [UInt8] {
        let latin1 = String(String.UnicodeScalarView(pdf.map { Unicode.Scalar($0) }))
        return latin1.replacingOccurrences(of: from, with: to).unicodeScalars.map { UInt8($0.value) }
    }

    @Test func Pages_that_are_one_JPEG_come_out_byte_for_byte() {
        let grey = TestJpeg.build(width: 800, height: 600, dnlHeight: nil, components: 1)
        let pdf = Self.pdf([(Self.six[0], 300, ["Invoice"]), (Self.six[1], 300, nil), (grey, 150, nil)])

        #expect(ScannerPdf.jpegPages(pdf) == [Self.six[0], Self.six[1], grey])
    }

    @Test func A_page_tree_with_inherited_resources_and_indirect_lengths_is_read() {
        let a = TestJpeg.build(width: 100, height: 200, dnlHeight: nil)
        let b = TestJpeg.build(width: 120, height: 200, dnlHeight: nil)
        var pdf: [UInt8] = []
        func raw(_ s: String) { pdf += s.unicodeScalars.map { UInt8($0.value) } }
        raw("%PDF-1.7\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n")
        raw("2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 2>>\nendobj\n")
        raw("3 0 obj\n<</Type/Pages/Parent 2 0 R/Kids[4 0 R 5 0 R]/Count 2/Resources 6 0 R>>\nendobj\n")
        raw("4 0 obj\n<</Type/Page/Parent 3 0 R/MediaBox[0 0 24 48]/Contents 9 0 R>>\nendobj\n")
        raw("5 0 obj\n<</Type/Page/Parent 3 0 R/MediaBox[0 0 29 48]/Resources<</XObject<</X1 8 0 R>>>>/Contents 9 0 R>>\nendobj\n")
        raw("6 0 obj\n<</XObject 10 0 R>>\nendobj\n10 0 obj\n<</Im7 7 0 R>>\nendobj\n")
        raw("7 0 obj\n<</Type/XObject/Subtype/Image/Width 100/Height 200/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter[/DCTDecode]/Length 11 0 R>>\nstream\r\n")
        pdf += a
        raw("\r\nendstream\nendobj\n11 0 obj\n\(a.count)\nendobj\n")
        raw("8 0 obj\n<</Type/XObject/Subtype/Image/Width 120/Height 200/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode>>\nstream\n")
        pdf += b
        raw("\nendstream\nendobj\n9 0 obj\n<</Length 0>>\nstream\n\nendstream\nendobj\ntrailer\n<</Root 1 0 R/Size 12>>\n%%EOF\n")

        #expect(ScannerPdf.jpegPages(pdf) == [a, b])
    }

    @Test(arguments: [
        ("/Type /Page /Parent", "/Type /Page /Rotate 90 /Parent"), // turned: drawn, so it shows as the scanner meant
        ("/Filter /DCTDecode", "/Filter /FlateDecode"), // not a JPEG
        ("/Filter /DCTDecode", "/SMask 3 0 R /Filter /DCTDecode"), // a mask over it
        ("%PDF-1.4", "%PS-Adobe"), // not a PDF
    ])
    func Anything_else_is_left_to_the_renderer(_ from: String, _ to: String) {
        let pdf = Self.edit(Self.pdf([(Self.six[0], 300, nil)]), from, to)
        #expect(ScannerPdf.jpegPages(pdf) == nil)
    }

    final class FakeRenderer: PdfPageRenderer {
        struct Damaged: Error, CustomStringConvertible {
            var description: String { "damaged" }
        }

        private let pages: [[UInt8]]?
        let asked = Mutex<[(pdf: [UInt8], dpi: Int)]>([])

        init(_ pages: [[UInt8]]?) { self.pages = pages }

        func render(_ pdf: [UInt8], dpi: Int) async throws -> [[UInt8]] {
            asked.withLock { $0.append((pdf, dpi)) }
            guard let pages else { throw Damaged() }
            return pages
        }
    }

    @Test func Pages_that_arent_one_JPEG_are_rendered_and_without_a_renderer_it_says_so() async throws {
        let flate = Self.edit(Self.pdf([(Self.six[0], 300, nil), (Self.six[1], 300, nil)]), "/Filter /DCTDecode", "/Filter /FlateDecode")

        await #expect(throws: ScanError("This scanner sent its pages as a PDF whose pictures Inkvolt Print can't take out here.")) {
            _ = try await ScannerPdf.pages(flate, dpi: 300)
        }

        let renderer = FakeRenderer([Self.six[4], Self.six[5]])
        ScannerPdf.renderer = renderer
        let pages = try await ScannerPdf.pages(flate, dpi: 200)

        #expect(pages == [Self.six[4], Self.six[5]])
        let asked = renderer.asked.withLock { $0 }
        #expect(asked.count == 1 && asked[0].pdf == flate && asked[0].dpi == 200)
        #expect(pages.allSatisfy { ScannerPdf.origin(of: $0)?.rendered == true })
    }

    @Test func A_renderer_that_fails_is_a_scan_error_in_words() async throws {
        ScannerPdf.renderer = FakeRenderer(nil)
        let flate = Self.edit(Self.pdf([(Self.six[0], 300, nil)]), "/Filter /DCTDecode", "/Filter /FlateDecode")
        do {
            _ = try await ScannerPdf.pages(flate, dpi: 300)
            Issue.record("rendered")
        } catch let e as ScanError {
            #expect(e.description.hasPrefix("The scanner's PDF couldn't be opened:"))
        }
    }

    // MARK: Keeping the scanner's PDF

    @Test func Saved_untouched_the_file_is_the_scanners_own_PDF() async throws {
        let pdf = Self.pdf(Self.six.map { ($0, 300, nil) })
        let pages = try await ScannerPdf.pages(pdf, dpi: 300)
        func plan(_ changed: ((Int) -> Bool)? = nil) -> [PageToSave] {
            pages.enumerated().map { PageToSave(ScannerPdf.origin(of: $0.element), changed: changed?($0.offset) ?? false) }
        }

        #expect(ScannerPdf.keepAsSent(plan()) == pdf)
        #expect(ScannerPdf.whyNotAsSent(plan()) == nil)

        // A page turned, cropped or given a text layer: made from the pages (the JPEGs as they came), and said why.
        #expect(ScannerPdf.keepAsSent(plan { $0 == 2 }) == nil)
        #expect(ScannerPdf.whyNotAsSent(plan { $0 == 2 })
            == "Your changes (or the text layer) are in it, so it was made from the scanner's pages, pictures unchanged.")
        // A page left out (blank), moved, or a page from another scan: the same.
        #expect(ScannerPdf.keepAsSent(Array(plan().dropFirst())) == nil)
        #expect(ScannerPdf.keepAsSent(plan().reversed()) == nil)
        #expect(ScannerPdf.keepAsSent(plan() + [PageToSave(nil, changed: false)]) == nil)
        #expect(ScannerPdf.whyNotAsSent(Array(plan().dropFirst()))?.hasPrefix("Pages were added, left out, moved or split into files") == true)
        // JPEG pages: nothing to keep, nothing to say.
        #expect(ScannerPdf.whyNotAsSent([PageToSave(nil, changed: false)]) == nil)
        // A file made from the pages is the same pictures: each page's JPEG goes back in as it came.
        #expect(ScannerPdf.jpegPages(Self.pdf(pages.map { ($0, 300, nil) })) == pages)
    }

    // MARK: Mac additions

    @Test func Origins_are_kept_for_the_last_scanner_PDFs_only() async throws {
        let first = try await ScannerPdf.pages(Self.pdf([(TestJpeg.build(width: 11, height: 11, dnlHeight: nil), 300, nil)]), dpi: 300)
        #expect(ScannerPdf.origin(of: first[0]) != nil)
        for i in 0..<ScannerPdf.rememberedDocuments {
            _ = try await ScannerPdf.pages(Self.pdf([(TestJpeg.build(width: 20 + i, height: 11, dnlHeight: nil), 300, nil)]), dpi: 300)
        }
        #expect(ScannerPdf.origin(of: first[0]) == nil)
    }
}
