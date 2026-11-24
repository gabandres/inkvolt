import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import PrintCore
@testable import PrintMac

/// Separator sheets marked with a code saying PATCHT read with Vision (`VisionSeparatorCodes`): the cases of the Windows app's
/// SeparatorCodeTests.cs that decode a code drawn on a synthetic scan of a letter page at 100 dpi (850 × 1100), with the same
/// names. QR codes and Code 128 barcodes are made with Core Image's generators (ZXing's writers on Windows); macOS has no
/// Code 39 generator, so Code 39 is left to Vision's own reading (not drawn here).
struct VisionSeparatorCodesTests {
    private static let w = 850, h = 1100
    private static let ppi = 100.0
    private static let reader = VisionSeparatorCodes()

    private static func page(_ modules: [[Bool]], _ x: Double, _ y: Double, _ size: Double, degrees: Double = 0, height: Double = 0) -> GrayImage {
        var pixels = paper()
        let rows = modules.count, columns = modules[0].count
        let module = size / Double(columns)
        let rowHeight = height > 0 ? height / Double(rows) : module
        let sin = Foundation.sin(degrees * .pi / 180), cos = Foundation.cos(degrees * .pi / 180)
        let cx = Double(w) / 2, cy = Double(h) / 2
        for py in 0..<h {
            for px in 0..<w {
                let dx = Double(px) - cx, dy = Double(py) - cy
                let qx = (cos * dx + sin * dy + cx) / ppi - x
                let qy = (-sin * dx + cos * dy + cy) / ppi - y
                if qx < 0 || qy < 0 { continue }
                let c = Int(qx / module), r = Int(qy / rowHeight)
                if r < rows && c < columns && modules[r][c] { pixels[py * w + px] = 25 }
            }
        }
        return GrayImage(width: w, height: h, pixels: pixels)
    }

    private static func paper(_ w: Int = w, _ h: Int = h) -> [UInt8] {
        var seed: UInt64 = 5
        return (0..<(w * h)).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(242 + Int((seed >> 33) % 13) - 6)
        }
    }

    /// A Core Image generator's output as modules, true for dark, without the white it draws around them.
    private static func modules(_ image: CIImage?) -> [[Bool]] {
        guard let image else { return [[false]] }
        let iw = Int(image.extent.width), ih = Int(image.extent.height)
        var pixels = [UInt8](repeating: 255, count: iw * ih)
        CIContext().render(image, toBitmap: &pixels, rowBytes: iw, bounds: image.extent, format: .L8, colorSpace: nil)
        let rows = (0..<ih).map { y in (0..<iw).map { pixels[y * iw + $0] < 128 } }
        let dark = rows.indices.filter { rows[$0].contains(true) }
        let columns = (0..<iw).filter { x in rows.contains { $0[x] } }
        guard let top = dark.first, let bottom = dark.last, let left = columns.first, let right = columns.last else { return [[false]] }
        return (top...bottom).map { Array(rows[$0][left...right]) }
    }

    private static func qr(_ text: String) -> [[Bool]] {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        return modules(f.outputImage)
    }

    /// Code 128's bars as one row of modules (drawn tall with `page`'s height).
    private static func code128(_ text: String) -> [[Bool]] {
        let f = CIFilter.code128BarcodeGenerator()
        f.message = Data(text.utf8)
        f.quietSpace = 0
        f.barcodeHeight = 1
        return [modules(f.outputImage)[0]]
    }

    // ---- Reading ----

    @Test(arguments: [0.0, 4, 90, 180, -30])
    func A_QR_code_saying_PATCHT_is_a_separator_sheet_however_it_was_fed(_ degrees: Double) {
        let page = Self.page(SeparatorCodes.qrModules(), 3.5, 4, 1.25, degrees: degrees)

        #expect(SeparatorCodes.find(page, reader: Self.reader) == .qrCode)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: Self.reader) == SeparatorFound(.qrCode))
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .blankPage, codes: Self.reader).kind == .none) // not blank either
    }

    @Test(arguments: ["patcht", " PATCHT "]) // any case, as Paperless-ngx compares
    func The_text_is_read_loosely(_ text: String) {
        #expect(SeparatorCodes.find(Self.page(Self.qr(text), 3, 3, 1.5), reader: Self.reader) == .qrCode)
    }

    @Test(arguments: ["https://example.com/invoice/123", "PATCH T", "PATCHT PATCHT"])
    func A_QR_code_saying_anything_else_separates_nothing(_ text: String) {
        let page = Self.page(Self.qr(text), 3, 3, 1.5)

        #expect(Self.reader.codes(on: page, qrCodes: true).contains { $0.symbology == .qrCode && $0.text == text }) // read, then refused
        #expect(SeparatorCodes.find(page, reader: Self.reader) == nil)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: Self.reader).kind == .none)
    }

    @Test(arguments: [0.0, 90])
    func A_barcode_saying_PATCHT_is_a_separator_sheet(_ degrees: Double) {
        let page = Self.page(Self.code128("PATCHT"), 2.5, 4, 3, degrees: degrees, height: 1)

        #expect(SeparatorCodes.find(page, reader: Self.reader) == .barcode)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: Self.reader).description == "barcode sheet")
        #expect(SeparatorCodes.find(Self.page(Self.code128("INVOICE7"), 2.5, 4, 3, degrees: degrees, height: 1), reader: Self.reader) == nil)
    }

    @Test func Blank_text_and_dark_pages_have_no_code() {
        var text = Self.paper()
        for y in stride(from: 200, to: 900, by: 30) {
            for x in 100..<750 where x % 9 < 5 {
                for dy in 0..<12 { text[(y + dy) * Self.w + x] = 30 }
            }
        }
        #expect(SeparatorCodes.find(GrayImage(width: Self.w, height: Self.h, pixels: Self.paper()), reader: Self.reader) == nil)
        #expect(SeparatorCodes.find(GrayImage(width: Self.w, height: Self.h, pixels: text), reader: Self.reader) == nil)
        #expect(SeparatorCodes.find(GrayImage(width: Self.w, height: Self.h, pixels: [UInt8](repeating: 0, count: Self.w * Self.h)), reader: Self.reader) == nil)
    }

    // ---- Hostile pages ----

    @Test func A_very_large_page_is_read_reduced() {
        // 300 dpi letter, 2550 × 3300: read at a third of that.
        let w = 2550, h = 3300
        var pixels = Self.paper(w, h)
        let modules = SeparatorCodes.qrModules()
        let module = 1.25 * 300 / Double(modules[0].count)
        for y in 0..<Int(1.25 * 300) {
            for x in 0..<Int(1.25 * 300) where modules[Int(Double(y) / module)][Int(Double(x) / module)] {
                pixels[(1200 + y) * w + 1000 + x] = 25
            }
        }
        #expect(SeparatorCodes.find(GrayImage(width: w, height: h, pixels: pixels), reader: Self.reader) == .qrCode)
    }

    @Test func Pixels_that_dont_match_the_size_are_no_image() {
        #expect(VisionSeparatorCodes.cgImage(GrayImage(width: Self.w, height: Self.h, pixels: [UInt8](repeating: 0, count: 10))) == nil)
        #expect(Self.reader.codes(on: GrayImage(width: 0, height: 0, pixels: []), qrCodes: true).isEmpty)
    }

    // ---- The printed sheet ----

    @Test(arguments: [(8.5, 11.0), (210 / 25.4, 297 / 25.4)])
    func The_sheets_QR_code_reads_back_beside_its_patch(_ width: Double, _ height: Double) {
        let page = SeparatorSheet.image(.patchT, widthIn: width, heightIn: height, pixelsPerInch: Self.ppi)

        // Both read: the patch where the sheet's bars are, the QR code with them on the page.
        #expect(PatchCodes.find(page, pixelsPerInch: Self.ppi) == .patchT)
        #expect(SeparatorCodes.find(page, reader: Self.reader) == .qrCode)
        // Bars cut away, the QR code alone still makes the sheet a separator.
        let qrOnly = SeparatorSheet.image(.patchT, widthIn: width, heightIn: height, pixelsPerInch: Self.ppi, bars: false)
        #expect(Separators.detect(qrOnly, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: Self.reader).kind == .qrCode)
    }

    @Test func The_demo_batchs_QR_sheet_reads_as_a_separator() throws {
        let jpeg = DemoScanPage.jpeg(DemoScan.qrSheet, width: 2550, height: 3300)
        let gray = try ScanImaging.analysis(jpeg)
        let ppi = Double(gray.width) / 8.5
        #expect(Separators.detect(gray, pixelsPerInch: ppi, splitAt: .patchCode, codes: Self.reader).kind == .qrCode)
        let sheet = try ScanImaging.analysis(DemoScanPage.jpeg(DemoScan.separatorSheet, width: 2550, height: 3300))
        #expect(Separators.detect(sheet, pixelsPerInch: ppi, splitAt: .patchCode, codes: Self.reader) == SeparatorFound(.patchCode, code: .patchT))
    }
}
