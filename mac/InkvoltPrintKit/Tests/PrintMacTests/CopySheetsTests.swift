import CoreGraphics
import Foundation
import PDFKit
import PrintCore
import Testing
@testable import PrintMac

/// A page copy's sides as a PDF (`CopySheets`, Mac only: Windows lays them out with WPF's paginator in the app, untested
/// there): one PDF page per entry of the order, a blank back for −1, 2-up portrait pages turned a quarter clockwise one above
/// the other. Scanned pages are made-up JPEGs at 20 dpi, small enough to decode fast.
struct CopySheetsTests {
    /// A Letter page at 20 dpi (170 × 220 px), white, with a black block across its top fifth.
    private static func page() throws -> BatchPrintPage {
        let (w, h) = (170, 220)
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: h - h / 5, width: w, height: h / 5)) // y up: the top
        let image = try #require(context.makeImage())
        return BatchPrintPage(try ScanImaging.jpeg(image), 8.5, 11)
    }

    private static func sides(_ pages: [BatchPrintPage], perSheet: Int, order: [Int]) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("copy-sheets-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try CopySheets.write(pages, perSheet: perSheet, order: order, paper: CGSize(width: 612, height: 792), sizing: .actualSize, to: url)
        return try #require(PDFDocument(data: try Data(contentsOf: url)))
    }

    /// The share of dark pixels in `rect` (points, y up) of the page drawn at 1 px a point.
    private static func dark(_ page: PDFPage, _ rect: CGRect) throws -> Double {
        let context = try #require(CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        page.draw(with: .mediaBox, to: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var dark = 0, all = 0
        for y in Int(rect.minY)..<Int(rect.maxY) { // rows from the top in memory: y up is 791 − row
            for x in Int(rect.minX)..<Int(rect.maxX) {
                all += 1
                if data[(791 - y) * 612 + x] < 128 { dark += 1 }
            }
        }
        return Double(dark) / Double(max(1, all))
    }

    @Test func eachSideOfTheOrderIsAPageAndABlankBackIsEmpty() throws {
        let page = try Self.page()
        let (order, _) = CopyLayout.order(2, 2, collate: false, twoSided: true) // one sheet, twice: 0 1 0 1
        let document = try Self.sides([page, page, page], perSheet: 2, order: order + [-1])
        #expect(document.pageCount == 5)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        #expect(try Self.dark(try #require(document.page(at: 4)), CGRect(x: 0, y: 0, width: 612, height: 792)) == 0)
    }

    @Test func twoUpTurnsThePagesSoTheirTopsAreOnTheRight() throws {
        let page = try Self.page()
        let document = try Self.sides([page, page], perSheet: 2, order: [0])
        let side = try #require(document.page(at: 0))
        // Each page (Letter, turned, at 61%: x 64 to 548 pt) has its black top band down the right fifth of its cell (x 451 to
        // 548); the left of a cell stays white. Top cell y 400 to 774 pt, bottom 18 to 392 (y up).
        #expect(try Self.dark(side, CGRect(x: 470, y: 450, width: 60, height: 200)) > 0.9)
        #expect(try Self.dark(side, CGRect(x: 470, y: 100, width: 60, height: 200)) > 0.9)
        #expect(try Self.dark(side, CGRect(x: 100, y: 450, width: 60, height: 200)) == 0)
    }

    /// Opt-in, a real printer (never run by default): `INKVOLT_COPY_PRINTER=<address>` copies its glass as the app's Copy does
    /// when the printer is printed to straight: one page scanned over eSCL in grey at 300 dpi, laid out by `CopySheets` on
    /// the printer's default paper, sent as a file through `DirectBatchQueue` and Batch Print's runner, followed to its end.
    /// Printed only when the glass is blank (nobody's document is copied), named "Copy (blank glass)". The address stays in
    /// the environment, never in the repo.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INKVOLT_COPY_PRINTER"] != nil))
    func oneCopyOfTheGlassPrintsOnARealPrinter() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["INKVOLT_COPY_PRINTER"])
        let transport = URLSessionTransport.factory(localNetwork: nil)
        let scanner = EsclClient(DeviceHttp(host: host, transport: transport), root: try #require(URL(string: "http://\(host)/eSCL/")))
        let caps = try #require(try await scanner.capabilities())
        let dpi = ScanChoices.resolutions(caps, .platen, wanted: [300]).first ?? 300
        let size = ScanChoices.defaultPageSize(ScanChoices.pageSizes(caps, .platen), remembered: nil, metric: false)
        var jpegs: [[UInt8]] = []
        for try await jpeg in scanner.scan(ScanChoices.request(.platen, .grayscale, dpi, size)) { jpegs.append(jpeg) }
        let jpeg = try #require(jpegs.first)
        let px = try #require(ScanImaging.size(jpeg))
        let small = try #require(CopySheets.thumbnail(jpeg, maxPixels: 600))
        let context = try #require(CGContext(data: nil, width: small.width, height: small.height, bitsPerComponent: 8, bytesPerRow: small.width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(small, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let count = small.width * small.height
        let dark = Double((0..<count).reduce(0) { $0 + (data[$1] < 128 ? 1 : 0) }) / Double(count)
        print("real copy: scanned \(px.width) × \(px.height) px at \(dpi) dpi, " + String(format: "%.4f", dark) + " dark")
        guard dark < 0.005 else {
            print("real copy: something is on the glass; not printed")
            return
        }

        let ipp = IppClient(DeviceHttp(host: host, transport: transport), endpoint: try #require(URL(string: "http://\(host):631/ipp/print")))
        let capsCache = IppCapsCache({ IppPrintCaps.from(try await ipp.printerAttributes(IppPrintCaps.requested)) })
        let queue = DirectBatchQueue("Copy check", ipp: ipp, caps: capsCache, send: DirectBatchJobs.send(ipp, caps: capsCache, user: "inkvolt"))
        let info = try #require(try await queue.read())
        let paper = info.defaultPaper.flatMap(BatchQueueReading.size) ?? (612, 792)
        let inches = CopyLayout.inches(px.width, px.height, dpi)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Copy (blank glass).pdf")
        try CopySheets.write([BatchPrintPage(jpeg, inches.width, inches.height)], perSheet: 1, order: [0],
                             paper: CGSize(width: paper.width, height: paper.height), sizing: .actualSize, to: url)
        let documents = MacBatchDocuments()
        let line = BatchPrintLine(url.path, BatchPrintSettings(), try await BatchMeasurer.measure(url.path, offered: nil, documents, ask: nil), info)
        let summary = await BatchPrintRunner.run([line], queue, documents)
        print("real copy: \(info.defaultPaper ?? "-"), \(summary.text)")
        #expect(summary.items.map(\.state) == [.sent], "\(summary.text)")
    }

    @Test func pagesPerSheetOtherThanOneTwoOrFourWriteNothing() {
        #expect(throws: CopyLayout.PagesPerSheetError(pagesPerSheet: 3)) { try Self.sides([], perSheet: 3, order: [0]) }
    }
}
