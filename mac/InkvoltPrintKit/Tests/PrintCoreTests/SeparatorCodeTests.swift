import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Separator sheets marked with a code saying PATCHT (`SeparatorCodes`): PrintCore's rules on synthetic scans of a letter page
/// at 100 dpi (850 × 1100, as the app analyses it), with a reader that reports what the test says is on the page; and the QR
/// code on the printable sheet. Hostile pages: one crowded with QR corner squares, one far too large, one whose pixels don't
/// match its size. The same names as the Windows app's SeparatorCodeTests.cs; the cases that decode a code drawn on a page are
/// PrintMacTests' `VisionSeparatorCodesTests` (Vision reads them there, ZXing on Windows).
struct SeparatorCodeTests {
    static let w = 850, h = 1100
    static let ppi = 100.0

    static func paper(_ w: Int = w, _ h: Int = h) -> [UInt8] {
        var seed: UInt64 = 5
        return (0..<(w * h)).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(242 + Int((seed >> 33) % 13) - 6)
        }
    }

    /// `modules` (true for dark, [row][column]) drawn `size` inches across with their top-left corner at (`x`, `y`) inches,
    /// turned `degrees` clockwise about the page centre.
    static func page(_ modules: [[Bool]], _ x: Double, _ y: Double, _ size: Double, degrees: Double = 0, height: Double = 0) -> GrayImage {
        var pixels = paper()
        draw(&pixels, modules, x, y, size, degrees: degrees, height: height)
        return GrayImage(width: w, height: h, pixels: pixels)
    }

    static func draw(_ pixels: inout [UInt8], _ modules: [[Bool]], _ x: Double, _ y: Double, _ size: Double, degrees: Double = 0, height: Double = 0) {
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
    }

    /// A reader that reports `codes` on any page, and keeps what it was asked.
    final class Told: SeparatorCodeReader {
        let found: [ReadCode]
        private let asked = Mutex<[(width: Int, height: Int, qr: Bool)]>([])

        init(_ found: [ReadCode]) { self.found = found }

        var pages: [(width: Int, height: Int, qr: Bool)] { asked.withLock { $0 } }

        func codes(on page: GrayImage, qrCodes: Bool) -> [ReadCode] {
            asked.withLock { $0.append((page.width, page.height, qrCodes)) }
            return found.filter { qrCodes || $0.symbology != .qrCode }
        }
    }

    // ---- Reading ----

    @Test func A_QR_code_saying_PATCHT_is_a_separator_sheet_however_it_was_fed() {
        let page = Self.page(SeparatorCodes.qrModules(), 3.5, 4, 1.25)
        let reader = Told([ReadCode(.qrCode, "PATCHT")])

        #expect(SeparatorCodes.find(page, reader: reader) == .qrCode)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: reader) == SeparatorFound(.qrCode))
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCodeOrBlankPage, codes: reader).kind == .qrCode)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .blankPage, codes: reader).kind == .none) // not blank either
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .none, codes: reader).kind == .none)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCode).kind == .none) // no reader: patch codes only
    }

    @Test(arguments: ["patcht", " PATCHT ", "PATCHT"]) // any case, as Paperless-ngx compares
    func The_text_is_read_loosely(_ text: String) {
        #expect(SeparatorCodes.says(text))
        #expect(SeparatorCodes.find(Self.page(SeparatorCodes.qrModules(), 3, 3, 1.5), reader: Told([ReadCode(.qrCode, text)])) == .qrCode)
    }

    @Test(arguments: ["https://example.com/invoice/123", "PATCH T", "PATCHT PATCHT", "", String(repeating: " ", count: 70) + "PATCHT"])
    func A_QR_code_saying_anything_else_separates_nothing(_ text: String) {
        let page = Self.page(SeparatorCodes.qrModules(), 3, 3, 1.5)
        let reader = Told([ReadCode(.qrCode, text), ReadCode(.qrCode, nil)])

        #expect(SeparatorCodes.find(page, reader: reader) == nil)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: reader).kind == .none)
    }

    @Test(arguments: [ReadCode.Symbology.code128, .code39])
    func A_barcode_saying_PATCHT_is_a_separator_sheet(_ symbology: ReadCode.Symbology) {
        let page = GrayImage(width: Self.w, height: Self.h, pixels: Self.paper())

        #expect(SeparatorCodes.find(page, reader: Told([ReadCode(symbology, "PATCHT")])) == .barcode)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: Told([ReadCode(symbology, "PATCHT")])).description
            == "barcode sheet")
        #expect(SeparatorCodes.find(page, reader: Told([ReadCode(symbology, "INVOICE7")])) == nil)
        #expect(SeparatorCodes.find(page, reader: Told([ReadCode(.other, "PATCHT")])) == nil) // an EAN or a Data Matrix code: not one
    }

    @Test func A_QR_codes_other_side_belongs_to_the_sheet_in_a_two_sided_run() {
        #expect(SeparatorFound(.qrCode).isSheet)
        #expect(SeparatorFound(.barcode).isSheet)
        #expect(SeparatorFound(.patchCode, code: .patchT).isSheet)
        #expect(!SeparatorFound(.blankPage).isSheet)
        #expect(!SeparatorFound(.byHand).isSheet)
        #expect(!SeparatorFound(.sheetBack).isSheet)
    }

    // ---- Hostile pages ----

    @Test func A_page_crowded_with_corner_squares_is_not_searched() {
        // Rows of 1:1:3:1:1 marks, 7 pixels a mark, over the whole page: tens of thousands of finder candidates.
        var pixels = Self.paper()
        for y in 0..<Self.h {
            for x in 0..<Self.w {
                let cx = x % 9, cy = y % 9
                let ring = max(abs(cx - 3), abs(cy - 3))
                if cx < 7 && cy < 7 && ring != 2 { pixels[y * Self.w + x] = 20 }
            }
        }
        let page = GrayImage(width: Self.w, height: Self.h, pixels: pixels)
        let reader = Told([ReadCode(.qrCode, "PATCHT")])

        #expect(SeparatorCodes.finderMarks(page) > SeparatorCodes.maxFinderMarks)
        let clock = ContinuousClock.now
        #expect(SeparatorCodes.find(page, reader: reader) == nil)
        #expect(reader.pages.allSatisfy { !$0.qr }) // QR codes aren't looked for; barcodes still are
        #expect(ContinuousClock.now - clock < .seconds(10))
    }

    @Test func A_real_QR_code_has_few_corner_squares() {
        let page = Self.page(SeparatorCodes.qrModules(), 3.5, 4, 1.25)
        let marks = SeparatorCodes.finderMarks(page)
        #expect((30...300).contains(marks), "\(marks)")
    }

    @Test func A_very_large_page_is_read_reduced() {
        // 300 dpi letter, 2550 × 3300: read at half that, its longer side at most 1,700 pixels.
        let reader = Told([ReadCode(.qrCode, "PATCHT")])
        #expect(SeparatorCodes.find(GrayImage(width: 2550, height: 3300, pixels: Self.paper(2550, 3300)), reader: reader) == .qrCode)
        #expect(reader.pages.map(\.width) == [1275])
        #expect(reader.pages.map(\.height) == [1650])
    }

    @Test func Pixels_that_dont_match_the_size_or_a_tiny_page_are_no_code() {
        let reader = Told([ReadCode(.qrCode, "PATCHT")])
        #expect(SeparatorCodes.find(GrayImage(width: Self.w, height: Self.h, pixels: [UInt8](repeating: 0, count: 10)), reader: reader) == nil)
        #expect(SeparatorCodes.find(GrayImage(width: 10, height: 10, pixels: [UInt8](repeating: 0, count: 100)), reader: reader) == nil)
        #expect(SeparatorCodes.find(GrayImage(width: 0, height: 0, pixels: []), reader: reader) == nil)
        #expect(reader.pages.isEmpty) // never handed to the reader
    }

    // ---- The printed sheet ----

    @Test(arguments: [(8.5, 11.0), (210 / 25.4, 297 / 25.4)])
    func The_sheets_QR_code_lies_beside_its_patch_clear_of_the_bars(_ width: Double, _ height: Double) {
        let bars = SeparatorSheet.layout(.patchT, widthIn: width, heightIn: height)
        let qr = SeparatorSheet.qrLayout(.patchT, widthIn: width, heightIn: height)
        // Clear of the bars' clear zone (0.8 in), inside the page with its quiet zone (4 modules).
        let barsLeft = bars.map(\.x).min()!
        let qrRight = qr.map { $0.x + $0.width }.max()!
        #expect(barsLeft - qrRight >= 0.8)
        #expect(qr.map(\.x).min()! >= 0.5 && qr.map(\.y).min()! > 2.5)
        // The patch still reads where the sheet's bars are, with the QR code beside it.
        let page = SeparatorSheet.image(.patchT, widthIn: width, heightIn: height, pixelsPerInch: Self.ppi)
        #expect(PatchCodes.find(page, pixelsPerInch: Self.ppi) == .patchT)
        // Bars cut away, the QR code alone still makes the sheet a separator (when the reader finds it).
        let qrOnly = SeparatorSheet.image(.patchT, widthIn: width, heightIn: height, pixelsPerInch: Self.ppi, bars: false)
        #expect(PatchCodes.find(qrOnly, pixelsPerInch: Self.ppi) == nil)
        #expect(Separators.detect(qrOnly, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: Told([ReadCode(.qrCode, "PATCHT")])).kind == .qrCode)
    }

    @Test(arguments: [PatchCode.patch1, .patch4, .patch6])
    func An_image_control_sheet_has_no_QR_code_and_a_QR_beside_its_patch_separates_nothing(_ code: PatchCode) throws {
        #expect(SeparatorSheet.qrLayout(code, widthIn: 8.5, heightIn: 11).isEmpty)
        let sheet = try #require(SeparatorSheet.page(code, widthIn: 8.5, heightIn: 11))
        #expect(sheet.bars.count + sheet.qr.count == 4)

        // A Patch 1, 4 or 6 sheet with a PATCHT QR code drawn on it anyway (another program's sheet): the patch decides.
        var pixels = Self.paper()
        for r in SeparatorSheet.layout(code, widthIn: 8.5, heightIn: 11) + SeparatorSheet.qrLayout(.patchT, widthIn: 8.5, heightIn: 11) {
            let y0 = Int((r.y * Self.ppi).rounded()), y1 = Int(((r.y + r.height) * Self.ppi).rounded())
            let x0 = Int((r.x * Self.ppi).rounded()), x1 = Int(((r.x + r.width) * Self.ppi).rounded())
            for y in y0..<y1 { for x in x0..<x1 { pixels[y * Self.w + x] = 25 } }
        }
        let page = GrayImage(width: Self.w, height: Self.h, pixels: pixels)
        let reader = Told([ReadCode(.qrCode, "PATCHT")])
        #expect(SeparatorCodes.find(page, reader: reader) == .qrCode)
        #expect(Separators.detect(page, pixelsPerInch: Self.ppi, splitAt: .patchCode, codes: reader).kind == .none)
    }

    @Test func The_sheet_pdf_draws_the_QR_code() throws {
        let sheet = try #require(SeparatorSheet.page(.patchT, widthIn: 8.5, heightIn: 11))

        #expect(sheet.bars.count == 4)
        #expect(sheet.qr.count == SeparatorSheet.qrLayout(.patchT, widthIn: 8.5, heightIn: 11).count)
        #expect(sheet.qr.count > 30)
        #expect(sheet.lines.contains { $0.text.contains("Patch or QR codes") })
    }

    @Test func The_QR_code_is_version_1_at_the_highest_correction() {
        let modules = SeparatorCodes.qrModules()

        #expect(modules.count == 21)
        #expect(modules.allSatisfy { $0.count == 21 })
        // Version 1's corner squares, its timing rows and its dark module (ISO/IEC 18004 §6.3).
        for (r, c) in [(0, 0), (0, 14), (14, 0)] {
            #expect((0..<7).allSatisfy { modules[r][c + $0] && modules[r + 6][c + $0] && modules[r + $0][c] && modules[r + $0][c + 6] })
        }
        #expect((8...12).allSatisfy { modules[6][$0] == ($0 % 2 == 0) && modules[$0][6] == ($0 % 2 == 0) })
        #expect(modules[13][8])
        // Format information (row 8, then column 8 upwards): level H with mask 3, 001100111010000 once masked.
        let format = [0, 1, 2, 3, 4, 5, 7, 8].map { modules[8][$0] } + [7, 5, 4, 3, 2, 1, 0].map { modules[$0][8] }
        #expect(format.map { $0 ? "1" : "0" }.joined() == "001100111010000")
    }
}
