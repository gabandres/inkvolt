import Foundation
import Testing
@testable import PrintCore

/// Batch scanning: patch code and blank separator sheets found on synthetic scans (a letter page at 100 dpi, 850 × 1100,
/// as the app analyses it), one feeder run split into files at them, and the printable separator sheet. Ported from
/// BatchScanTests.cs (the noise comes from a seeded generator of its own, not .NET's Random). The .NET sheet test reads the
/// written PDF; PrintCore has the sheet as geometry the Mac draws, so that test checks the geometry and reads its raster back.
/// One at a time: each page check is a second or more of CPU, and a full set at once starves the timing tests beside them.
@Suite(.serialized)
struct BatchScanTests {
    private static let w = 850, h = 1100
    private static let ppi = 100.0

    /// SplitMix64: repeatable noise.
    private struct Noise {
        var state: UInt64
        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return range.lowerBound + Int(z % UInt64(range.count))
        }
    }

    /// Off-white paper with scanner noise (±6 levels, repeatable).
    private static func paper(_ level: Int = 242, seed: UInt64 = 1, count: Int = w * h) -> [UInt8] {
        var noise = Noise(state: seed)
        return (0..<count).map { _ in UInt8(level + noise.next(-6...6)) }
    }

    /// A patch drawn from `SeparatorSheet.bars` at `ppi`: bars `length` inches long starting at (`x`, `y`) inches, running down
    /// the page (vertical) or across it, turned `degrees` clockwise about the page centre. `gain` widens every bar (and
    /// narrows every space) by that many inches, as toner spread or a photocopy does.
    private static func patchPage(_ code: PatchCode, x: Double = 3.5, y: Double = 3, length: Double = 3, vertical: Bool = true,
                                  degrees: Double = 0, gain: Double = 0, ppi: Double = ppi, ink: UInt8 = 25) -> GrayImage {
        let (pw, ph) = (Int(8.5 * ppi), Int(11 * ppi))
        var pixels = paper(seed: 3, count: pw * ph)
        let bars = SeparatorSheet.bars(code)
        let (s, c) = (sin(degrees * .pi / 180), cos(degrees * .pi / 180))
        let (cx, cy) = (Double(pw) / 2, Double(ph) / 2)
        for py in 0..<ph {
            for px in 0..<pw {
                // Where this pixel was on the straight page, in inches.
                let (dx, dy) = (Double(px) - cx, Double(py) - cy)
                let qx: Double = (c * dx + s * dy + cx) / ppi
                let qy: Double = (-s * dx + c * dy + cy) / ppi
                let (across, along) = vertical ? (qx - x, qy - y) : (qy - y, qx - x)
                if along < 0 || along > length { continue }
                for bar in bars where across >= bar.offset - gain / 2 && across < bar.offset + bar.width + gain / 2 {
                    pixels[py * pw + px] = ink
                }
            }
        }
        return GrayImage(width: pw, height: ph, pixels: pixels)
    }

    private static func fill(_ pixels: inout [UInt8], _ x: Int, _ y: Int, _ fw: Int, _ fh: Int, _ level: UInt8) {
        for yy in y..<(y + fh) {
            for xx in x..<(x + fw) { pixels[yy * w + xx] = level }
        }
    }

    private static func image(_ pixels: [UInt8]) -> GrayImage { GrayImage(width: w, height: h, pixels: pixels) }

    // ---- The patch codes themselves ----

    @Test func patchBarsFollowTheKodakSpec() {
        // Two wide bars (0.20 in), two narrow bars (0.08 in), three narrow spaces (0.08 in): 0.80 in across.
        func round(_ bars: [PatchBar]) -> [[Double]] {
            bars.map { [($0.offset * 1e6).rounded() / 1e6, ($0.width * 1e6).rounded() / 1e6] }
        }
        #expect(round(SeparatorSheet.bars(.patchT)) == [[0.0, 0.08], [0.16, 0.20], [0.44, 0.08], [0.60, 0.20]])
        #expect(round(SeparatorSheet.bars(.patch2)) == [[0.0, 0.20], [0.28, 0.08], [0.44, 0.08], [0.60, 0.20]])
        #expect(round(SeparatorSheet.bars(.patch3)) == [[0.0, 0.20], [0.28, 0.08], [0.44, 0.20], [0.72, 0.08]])
        for code in PatchCode.allCases {
            let bars = SeparatorSheet.bars(code)
            let last = bars[bars.count - 1]
            #expect(abs(last.offset + last.width - 0.80) < 1e-6)
            #expect(bars.filter { $0.width > 0.1 }.count == 2)
        }
    }

    @Test(arguments: PatchCode.allCases)
    func readsEachPatch(_ code: PatchCode) async {
        #expect(await offPool { PatchCodes.find(Self.patchPage(code), pixelsPerInch: Self.ppi) } == code)
    }

    @Test func readsPatchesAcrossThePageToo() async {
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patch2, x: 2, y: 5, vertical: false), pixelsPerInch: Self.ppi) } == .patch2)
    }

    @Test(arguments: [4.0, -6.0])
    func readsASheetFedCrooked(_ degrees: Double) async {
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patchT, degrees: degrees), pixelsPerInch: Self.ppi) } == .patchT)
    }

    @Test func readsAPhotocopiedOrLowResolutionPatch() async {
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patchT, gain: 0.02), pixelsPerInch: Self.ppi) } == .patchT) // bars spread
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patchT, gain: -0.015), pixelsPerInch: Self.ppi) } == .patchT) // bars thin
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patchT, ppi: 72), pixelsPerInch: 72) } == .patchT) // legal from the feeder
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patchT, ink: 110), pixelsPerInch: Self.ppi) } == .patchT) // grey toner
    }

    @Test func upsideDownPatchTReadsAsPatch3AndStillSeparates() async {
        let turned = Self.patchPage(.patchT, degrees: 180)

        #expect(await offPool { PatchCodes.find(turned, pixelsPerInch: Self.ppi) } == .patch3) // NWNW read backwards is WNWN
        #expect(await offPool { Separators.detect(turned, pixelsPerInch: Self.ppi, splitAt: .patchCode).kind } == .patchCode)
    }

    @Test func tooShortTooSmallOrTooLargeIsNoPatch() async {
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patchT, length: 0.5), pixelsPerInch: Self.ppi) } == nil) // a fragment, not a 2 in patch
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patchT, ppi: 40), pixelsPerInch: 100) } == nil) // at 40% size: 0.32 in across
        #expect(await offPool { PatchCodes.find(Self.patchPage(.patchT, ppi: 200), pixelsPerInch: 100) } == nil) // at twice the size: 1.6 in across
    }

    @Test func textTablesAndBarsOfOneWidthAreNoPatch() async {
        // Lines of words.
        var text = Self.paper()
        for row in 0..<30 {
            for x in stride(from: 110, to: 740, by: 70) { Self.fill(&text, x, 150 + row * 24, 58, 8, 40) }
        }
        let textImage = Self.image(text)
        #expect(await offPool { PatchCodes.find(textImage, pixelsPerInch: Self.ppi) } == nil)

        // A table: thin rules every 0.5 in, with text in the cells.
        var table = Self.paper()
        for x in stride(from: 100, through: 700, by: 50) { Self.fill(&table, x, 200, 2, 600, 30) }
        for y in stride(from: 200, through: 800, by: 30) { Self.fill(&table, 100, y, 600, 2, 30) }
        let tableImage = Self.image(table)
        #expect(await offPool { PatchCodes.find(tableImage, pixelsPerInch: Self.ppi) } == nil)

        // Four bars of one width, spaced like a patch: two must be wide.
        var even = Self.paper()
        for i in 0..<4 { Self.fill(&even, 300 + i * 20, 300, 12, 300, 25) }
        let evenImage = Self.image(even)
        #expect(await offPool { PatchCodes.find(evenImage, pixelsPerInch: Self.ppi) } == nil)

        // A barcode: thin bars far below the patch's size.
        var barcode = Self.paper()
        for i in 0..<60 { Self.fill(&barcode, 300 + i * 4, 300, i % 3 == 0 ? 2 : 1, 80, 25) }
        let barcodeImage = Self.image(barcode)
        #expect(await offPool { PatchCodes.find(barcodeImage, pixelsPerInch: Self.ppi) } == nil)

        #expect(await offPool { PatchCodes.find(Self.image(Self.paper(70)), pixelsPerInch: Self.ppi) } == nil) // a dark page
    }

    // ---- What counts as a separator ----

    @Test func separatorPagesByMode() async {
        let patchT = Self.patchPage(.patchT)
        let blank = Self.image(Self.paper())
        var textPixels = Self.paper()
        Self.fill(&textPixels, 200, 300, 400, 10, 40)
        let text = Self.image(textPixels)
        let ppi = Self.ppi

        #expect(await offPool { Separators.detect(patchT, pixelsPerInch: ppi, splitAt: .patchCode) } == SeparatorFound(.patchCode, code: .patchT))
        #expect(await offPool { Separators.detect(blank, pixelsPerInch: ppi, splitAt: .patchCode).kind } == .none)
        #expect(await offPool { Separators.detect(blank, pixelsPerInch: ppi, splitAt: .blankPage).kind } == .blankPage)
        #expect(await offPool { Separators.detect(patchT, pixelsPerInch: ppi, splitAt: .blankPage).kind } == .none)
        #expect(await offPool { Separators.detect(patchT, pixelsPerInch: ppi, splitAt: .patchCodeOrBlankPage).kind } == .patchCode)
        #expect(await offPool { Separators.detect(blank, pixelsPerInch: ppi, splitAt: .patchCodeOrBlankPage).kind } == .blankPage)
        #expect(await offPool { Separators.detect(text, pixelsPerInch: ppi, splitAt: .patchCodeOrBlankPage).kind } == .none)
        #expect(await offPool { Separators.detect(patchT, pixelsPerInch: ppi, splitAt: .none).kind } == .none)
    }

    @Test(arguments: [PatchCode.patch1, .patch4, .patch6])
    func imageControlPatchesAreNotSeparators(_ code: PatchCode) async {
        #expect(await offPool { Separators.detect(Self.patchPage(code), pixelsPerInch: Self.ppi, splitAt: .patchCode).kind } == .none)
    }

    // ---- Splitting a run into files ----

    private static let p = BatchPage(separator: false, startsFile: false, skipped: false)
    private static let s = BatchPage(separator: true, startsFile: false, skipped: false)
    private static let start = BatchPage(separator: false, startsFile: true, skipped: false)
    private static let skip = BatchPage(separator: false, startsFile: false, skipped: true)

    @Test func splitsAtEachSeparatorAndDropsIt() {
        let (p, s) = (Self.p, Self.s)
        let parts = BatchSplit.parts([p, p, s, p, s, p, p, p], keepSeparators: false)

        #expect(parts == [[0, 1], [3], [5, 6, 7]])
    }

    @Test func keptSeparatorsStartTheNextFile() {
        let (p, s) = (Self.p, Self.s)
        let parts = BatchSplit.parts([p, s, p, p, s, p], keepSeparators: true)

        #expect(parts == [[0], [1, 2, 3], [4, 5]])
    }

    @Test func leadingTrailingAndRepeatedSeparatorsMakeNoEmptyFiles() {
        let (p, s) = (Self.p, Self.s)
        #expect(BatchSplit.parts([s, s, p, p, s, s, p, s], keepSeparators: false) == [[2, 3], [6]])
        // Kept: in front of the next page; the last ones (no page after them) end the last file.
        #expect(BatchSplit.parts([s, s, p, p, s, s, p, s], keepSeparators: true) == [[0, 1, 2, 3], [4, 5, 6, 7]])
        #expect(BatchSplit.parts([s, s], keepSeparators: true).isEmpty)
        #expect(BatchSplit.parts([], keepSeparators: false).isEmpty)
    }

    @Test func splitPointsSetByHandAndSkippedPages() {
        let (p, s, start, skip) = (Self.p, Self.s, Self.start, Self.skip)
        // A page marked "starts a new file", and a blank page skipped (not a separator) in between.
        #expect(BatchSplit.parts([p, p, skip, start, p, s, p], keepSeparators: false) == [[0, 1], [3, 4], [6]])
        #expect(BatchSplit.parts([start, p, p], keepSeparators: false) == [[0, 1, 2]]) // first page: nothing to split from
        #expect(BatchSplit.parts([p, s, start], keepSeparators: true) == [[0], [1, 2]]) // after a separator: one split
        #expect(BatchSplit.parts([p, p, skip, p], keepSeparators: false) == [[0, 1, 3]])
    }

    @Test func splitPointsAreReportedPerPage() {
        let (p, s, start) = (Self.p, Self.s, Self.start)
        let starts = BatchSplit.fileStarts([p, p, s, p, start, p, s], keepSeparators: false)

        #expect(starts == [1, 0, 0, 2, 3, 0, 0]) // the file each page begins (0: none)
        #expect(BatchSplit.fileStarts([p, p, s, p, p], keepSeparators: true) == [1, 0, 2, 0, 0])
    }

    @Test func presetsKeepTheirSplitAndRepairUnknownOnes() {
        var batch = ScanPreset()
        batch.id = "batch"
        batch.name = "Batch"
        batch.splitAt = .patchCode
        batch.keepSeparators = true
        var newer = ScanPreset()
        newer.id = "newer"
        newer.name = "Newer"
        newer.splitAt = SplitAt(rawValue: 42)
        let stored = ScanPresetSettings(items: [batch, newer])

        let presets = ScanPresets.normalize(stored)

        #expect(presets[0].splitAt == .patchCode)
        #expect(presets[0].keepSeparators)
        #expect(presets[1].splitAt == .none)
        #expect(ScanPresetText.summary(presets[0]).contains("a new file at each patch code sheet"))
        #expect(!ScanPresetText.summary(presets[1]).contains("new file"))
    }

    @Test func twoSidedRunsGiveAPatchSheetsOtherSideToTheSheet() {
        // Front, back pairs (an even run): the patch sheet's back goes with it even when show-through makes it look printed.
        #expect(BatchSplit.duplexSeparatorBacks(patch: [false, false, true, false, false, false],
                                                blank: [false, true, false, false, false, true]) == [3])
        // Laid face down: the patch on the back, its front goes with it.
        #expect(BatchSplit.duplexSeparatorBacks(patch: [false, false, false, true], blank: [false, false, false, false]) == [2])
        // An odd run (a side dropped): the pairing isn't known, so only a back that looks blank.
        #expect(BatchSplit.duplexSeparatorBacks(patch: [false, false, true, false, false],
                                                blank: [false, false, false, false, false]).isEmpty)
        #expect(BatchSplit.duplexSeparatorBacks(patch: [false, false, true, false, false],
                                                blank: [false, false, false, true, false]) == [3])
        #expect(BatchSplit.duplexSeparatorBacks(patch: [true, true], blank: [false, false]).isEmpty) // both sides patch sheets already
    }

    @Test func aRetryAfterAPartialSaveSkipsTheFilesAlreadyWritten() {
        // The Mac's pages are values; a page is known by its id (the .NET test compares page objects by reference).
        let (a, b, c) = ("a.jpg", "b.jpg", "c.jpg")
        var saved = SavedParts<String>()
        saved.add([a, b], paths: ["Doc 1.pdf"])

        #expect(saved.find([a, b]) == ["Doc 1.pdf"])
        #expect(saved.find([c]) == nil)
        #expect(saved.find([b, a]) == nil) // reordered: a different file now
        #expect(saved.find([a]) == nil)
        saved.clear()
        #expect(saved.find([a, b]) == nil)
    }

    @Test func eachFileGetsItsOwnNumberEvenWhenThePresetIsGone() {
        var reserved = PartNumbers(5)
        let fromCounter: [Int] = [reserved.take(7), reserved.take(8)]
        #expect(fromCounter == [7, 8])

        var deleted = PartNumbers(5)
        let countingOn: [Int] = [deleted.take(nil), deleted.take(nil), deleted.take(nil)]
        #expect(countingOn == [5, 6, 7])

        var midway = PartNumbers(5) // deleted after the first file took 9
        let both: [Int] = [midway.take(9), midway.take(nil)]
        #expect(both == [9, 10])
    }

    // ---- The printable separator sheet ----

    @Test func separatorSheetIsAOnePageVectorPdfWithThePatch() throws {
        // Adapted: the .NET test reads the written PDF; here the page the Mac draws (points, from the bottom left).
        let page = try #require(SeparatorSheet.page(.patchT, widthIn: 8.5, heightIn: 11))

        #expect(page.width == 612 && page.height == 792)
        #expect(page.title == "Separator sheet (Patch T)")
        #expect(page.lines.contains { $0.text == "Patch T" })
        #expect(page.lines.first?.text == "Separator sheet")
        // The bars at their exact widths: 0.08 in = 5.76 pt, 0.20 in = 14.4 pt; four of them, nothing else drawn.
        #expect(page.bars.count == 4)
        #expect(page.bars.map { ($0.width * 100).rounded() / 100 } == [5.76, 14.4, 5.76, 14.4])
        #expect(page.bars.allSatisfy { abs($0.height - 288) < 1e-9 })
        // Text stays clear of the bars: above the top or below the bottom.
        let (low, high) = (page.bars[0].y, page.bars[0].y + page.bars[0].height)
        #expect(page.lines.allSatisfy { $0.baseline > high + $0.size || $0.baseline + $0.size < low })
        #expect(SeparatorSheet.page(.patchT, widthIn: 8.27, heightIn: 11.69) != nil) // A4
        #expect(SeparatorSheet.page(.patchT, widthIn: 8.5, heightIn: 6) == nil) // too short for the patch and its text
    }

    @Test func separatorSheetLayoutReadsBackAsItsPatch() async {
        // Every bar the sheet draws (in inches on the page), rendered at 100 dpi, is read as the sheet's patch.
        for code in [PatchCode.patchT, .patch2] {
            var pixels = Self.paper()
            for r in SeparatorSheet.layout(code, widthIn: 8.5, heightIn: 11) {
                let x = Int((r.x * Self.ppi).rounded()), y = Int((r.y * Self.ppi).rounded())
                let rw = Int((r.width * Self.ppi).rounded()), rh = Int((r.height * Self.ppi).rounded())
                Self.fill(&pixels, x, y, rw, rh, 25)
            }
            let pixelsImage = Self.image(pixels)
            #expect(await offPool { PatchCodes.find(pixelsImage, pixelsPerInch: Self.ppi) } == code)
            // The same bars from PrintCore's own raster (demo mode's scans of a sheet).
            let sheet = SeparatorSheet.image(code, widthIn: 8.5, heightIn: 11, pixelsPerInch: Self.ppi)
            #expect(sheet.width == Self.w && sheet.height == Self.h)
            #expect(await offPool { PatchCodes.find(sheet, pixelsPerInch: Self.ppi) } == code)
        }
    }
}
