import Foundation
import Testing
@testable import PrintCore

/// Ported from TurnedStackTests.cs: two-sided scanning on a one-sided feeder (roadmap 4.1): the fronts, then the stack turned
/// over and its backs, put in page order (`TurnedStack`), and the preset option that asks for it (`PresetPlan`). Adapted:
/// pages are the review's ids (strings), so the stack's own places are kept by id, not by reference; a negative count reads
/// as none (Swift has no ArgumentOutOfRangeException) and `separatorBacks` answers nil for flags that don't fit; the Mac
/// scans no black and white (`ScanColor` has color and grey), so the one-bit half of
/// Mac only: aTurnedStacksPagesPairAndUndoInTheReview (`ScanPages.pair`, the Windows view model's `StackScan`).
struct TurnedStackTests {
    /// Pages as the feeder sends them: "F1".."Fn" for the fronts, then the backs last sheet first, "B3", "B2", "B1".
    private static func stack(_ sheets: Int, reversed: Bool = true) -> (fronts: [String], backs: [String]) {
        let fronts = (1...sheets).map { "F\($0)" }
        let backs = (1...sheets).map { "B\($0)" }
        return (fronts, reversed ? backs.reversed() : backs)
    }

    @Test func backsComeLastSheetFirstAndGoAfterTheirFronts() {
        let (fronts, backs) = Self.stack(4)
        #expect(TurnedStack.arrange(fronts, backs) == ["F1", "B1", "F2", "B2", "F3", "B3", "F4", "B4"])
        #expect(TurnedStack.order(4, 4) == [0, 7, 1, 6, 2, 5, 3, 4])
    }

    @Test func aTrayThatReversesTheStackSendsTheBacksFirstSheetFirst() {
        let (fronts, backs) = Self.stack(3, reversed: false)
        #expect(TurnedStack.arrange(fronts, backs, reversed: false) == ["F1", "B1", "F2", "B2", "F3", "B3"])
    }

    @Test func oneSheetAndNone() {
        #expect(TurnedStack.order(1, 1) == [0, 1])
        #expect(TurnedStack.order(3, 0) == [0, 1, 2])
        #expect(TurnedStack.order(0, 2) == [0, 1])
        #expect(TurnedStack.order(0, 0).isEmpty)
        #expect(TurnedStack.order(-1, 2) == [0, 1]) // Windows throws; here a negative count is none
    }

    @Test func aBackShortMatchesFromTheLastSheetAndTheFirstKeepsOneSide() {
        // Four sheets, but the backs pass took three (the first sheet stayed behind): the backs scanned are sheets 4, 3, 2.
        let fronts = ["F1", "F2", "F3", "F4"]
        let backs = ["B4", "B3", "B2"]
        #expect(TurnedStack.arrange(fronts, backs) == ["F1", "F2", "B2", "F3", "B3", "F4", "B4"])
        // Read first sheet first, the last sheet is the one without a back.
        #expect(TurnedStack.arrange(fronts, backs, reversed: false) == ["F1", "B4", "F2", "B3", "F3", "B2", "F4"])
    }

    @Test func aBackTooManyGoesAtTheEndAsScanned() {
        // A sheet went through twice on the backs pass.
        #expect(TurnedStack.arrange(["F1", "F2"], ["B2", "B1", "B1 again"]) == ["F1", "B1", "F2", "B2", "B1 again"])
    }

    @Test func theOtherOrderPutsTheStackBackInItsOwnPlaces() {
        // A page from an earlier scan before the stack and one scanned after it stay put; a back deleted in the review stays deleted.
        let f = ["F1", "F2", "F3"]
        let b = ["b3", "b2", "b1"] // as scanned, last sheet first
        let ordered = TurnedStack.rearrange(["earlier"] + f + b, f, b, reversed: true)
        #expect(ordered.joined(separator: " ") == "earlier F1 b1 F2 b2 F3 b3")

        let current = ordered.filter { $0 != "b2" } + ["later"]
        #expect(TurnedStack.rearrange(current, f, b, reversed: false).joined(separator: " ") == "earlier F1 b3 F2 F3 b1 later")
        // Undo's order: the fronts, then the backs as scanned, in the stack's places.
        #expect(TurnedStack.inPlaces(current, f + b).joined(separator: " ") == "earlier F1 F2 F3 b3 b1 later")
    }

    /// A page the list holds twice takes its place in the order once; its other place keeps it as it is.
    @Test func aPageHeldTwiceIsPlacedOnce() {
        #expect(TurnedStack.inPlaces(["a", "b", "a", "x"], ["b", "a"]) == ["b", "a", "a", "x"])
        #expect(TurnedStack.inPlaces(["a", "a", "a"], ["a"]) == ["a", "a", "a"])
    }

    @Test func aSeparatorSheetsOtherSideIsItsRealBackNotTheNextPage() {
        // Four sheets, the first a patch sheet; the backs pass took two (sheets 4 and 3). Paired by position, the patch
        // sheet's "back" would be front 2, a page of the document; really its back wasn't scanned, so nothing is taken.
        let sheet = [true, false, false, false, false, false]
        let blank = [false, false, false, false, false, false]
        #expect(TurnedStack.separatorBacks(4, 2, reversed: true, sheet: sheet, blank: blank) == [])
        #expect(TurnedStack.pairs(4, 2).map { [$0.front, $0.back] } == [[3, 0], [2, 1]])

        // Counts equal: the sheet's own back (scanned last, as the stack's last back) is taken whatever is on it.
        let even = [true, false, false, false, false, false, false, false]
        #expect(TurnedStack.separatorBacks(4, 4, reversed: true, sheet: even, blank: Array(repeating: false, count: 8)) == [7])
        #expect(TurnedStack.separatorBacks(4, 4, reversed: false, sheet: even, blank: Array(repeating: false, count: 8)) == [4])
        // A sheet among the backs takes its front; counts differing, only a blank other side is taken.
        let back = [false, false, false, true, false]
        #expect(TurnedStack.separatorBacks(3, 2, reversed: true, sheet: back, blank: Array(repeating: false, count: 5)) == [])
        #expect(TurnedStack.separatorBacks(3, 2, reversed: true, sheet: back, blank: [false, false, true, false, false]) == [2])
        #expect(TurnedStack.separatorBacks(2, 2, reversed: true, sheet: Array(repeating: false, count: 3), blank: Array(repeating: false, count: 4)) == nil)
    }

    @Test func One_sided_feeders_offer_the_turned_stack_and_black_and_white_saves_one_bit() {
        #expect(ScanChoices.offersTurnStack(Self.caps(duplex: false), .adf))
        #expect(!ScanChoices.offersTurnStack(Self.caps(duplex: true), .adf))
        #expect(!ScanChoices.offersTurnStack(Self.caps(duplex: false), .platen))
        #expect(ScanChoices.savesOneBit(.blackAndWhite))
        #expect(!ScanChoices.savesOneBit(.grayscale))
    }

    // ---- The preset option ----

    private static func input() -> InputCaps {
        InputCaps(minWidth: 0, maxWidth: 2550, minHeight: 0, maxHeight: 4200, colorModes: ["RGB24", "Grayscale8"], documentFormats: ["image/jpeg"],
                  resolutions: [150, 300, 600], intents: ["Document"])
    }

    private static func caps(duplex: Bool) -> ScannerCapabilities {
        ScannerCapabilities(version: "2.6", makeAndModel: "Test", uuid: nil, platen: input(), adf: input(), adfDuplex: duplex)
    }

    private static func twoSided(_ change: (inout ScanPreset) -> Void = { _ in }) -> ScanPreset {
        var p = ScanPresets.builtIns()[0]
        p.source = .feeder
        p.twoSided = true
        change(&p)
        return p
    }

    private static let oneSideOnly = "This scanner's feeder scans one side only."

    private static func plan(_ p: ScanPreset, duplex: Bool, turnsStacks: Bool = true) -> PresetPlan {
        PresetPlan.plan(p, caps(duplex: duplex), feederLoaded: nil, ocrAvailable: true, metric: false, turnsStacks: turnsStacks)
    }

    @Test func aPresetTurnsTheStackOnAOneSidedFeederOnlyWhenAsked() {
        let plain = Self.plan(Self.twoSided(), duplex: false)
        #expect(!plain.turnStack)
        #expect(plain.notes.contains(Self.oneSideOnly))

        let turning = Self.plan(Self.twoSided { $0.turnStack = true }, duplex: false)
        #expect(turning.turnStack)
        #expect(turning.request.source == .adf)
        #expect(!turning.notes.contains(Self.oneSideOnly))

        // A two-sided feeder does it itself; the glass has no stack; an app that can't (Inkvolt PDF's Scan) says one side only.
        let duplex = Self.plan(Self.twoSided { $0.turnStack = true }, duplex: true)
        #expect(duplex.request.source == .adfDuplex && !duplex.turnStack)
        #expect(!Self.plan(Self.twoSided { $0.turnStack = true; $0.source = .glass }, duplex: false).turnStack)
        let pdfApp = Self.plan(Self.twoSided { $0.turnStack = true }, duplex: false, turnsStacks: false)
        #expect(!pdfApp.turnStack)
        #expect(pdfApp.notes.contains(Self.oneSideOnly))
        // Off with one side.
        #expect(!Self.plan(Self.twoSided { $0.twoSided = false; $0.turnStack = true }, duplex: false).turnStack)
    }

    @Test func theSummarySaysTheStackIsTurnedOver() {
        let short = "the stack turned over for the backs"
        #expect(ScanPresetText.summary(Self.twoSided { $0.turnStack = true }).contains(short))
        #expect(!ScanPresetText.summary(Self.twoSided()).contains(short))
    }

    @Test func oldPresetsReadWithoutTheNewSettingsKeepTheirWays() throws {
        // Written before 4.1: no turned stack.
        let json = #"{"Version":1,"Items":[{"Id":"abc","Name":"Old","TwoSided":true,"Source":2}]}"#
        let stored = try JSONDecoder().decode(ScanPresetSettings.self, from: Data(json.utf8))
        let preset = ScanPresets.normalize(stored)[0]
        #expect(preset.twoSided && !preset.turnStack)
        // Written by this version, read back: the option and its field name are Windows' ("TurnStack").
        let written = try JSONEncoder().encode(ScanPresetSettings(items: [Self.twoSided { $0.turnStack = true }]))
        #expect(String(decoding: written, as: UTF8.self).contains(#""TurnStack":true"#))
        #expect(ScanPresets.normalize(try JSONDecoder().decode(ScanPresetSettings.self, from: written))[0].turnStack)
    }

    // ---- In the review (Mac only) ----

    @Test func aTurnedStacksPagesPairAndUndoInTheReview() {
        // An earlier page, then three sheets: the first a patch sheet (its back blank), the backs last sheet first.
        var pages = ScanPages(["earlier", "F1", "F2", "F3", "B3", "B2", "B1"].map { ScannedPage(id: $0, dpi: 300) })
        pages.analysed("F1", looksBlank: false, skew: 0, skipBlank: true, straighten: true, separator: SeparatorFound(.patchCode, code: .patchT))
        pages.analysed("B1", looksBlank: true, skew: 0, skipBlank: true, straighten: true)
        var stack = StackScan(fronts: ["F1", "F2", "F3"], backs: ["B3", "B2", "B1"])
        pages.pair(&stack, reversed: TurnedStack.backsReversed)
        #expect(pages.pages.map(\.id) == ["earlier", "F1", "B1", "F2", "B2", "F3", "B3"])
        #expect(pages.page("B1")?.separator.kind == .sheetBack && pages.page("B1")?.skipped == false)

        // The other order: B1 is the third sheet's back now, the patch sheet's is B3 (counts equal: taken as it is).
        pages.pair(&stack, reversed: false)
        #expect(pages.pages.map(\.id) == ["earlier", "F1", "B3", "F2", "B2", "F3", "B1"])
        #expect(pages.page("B1")?.separator == SeparatorFound.none && pages.page("B1")?.skipped == true)
        #expect(pages.page("B3")?.separator.kind == .sheetBack)

        // Undo: as scanned, the marks put back.
        pages.unpair(&stack)
        #expect(pages.pages.map(\.id) == ["earlier", "F1", "F2", "F3", "B3", "B2", "B1"])
        #expect(pages.page("B3")?.separator == SeparatorFound.none && stack.marks.isEmpty)
    }

    @Test func undoingTheOtherOrderAfterAnotherScanPutsEverySheetsMarkBack() {
        // Review finding: a scan after Backs in the Other Order lets the review's stack go; each step of Undo keeps its own.
        var pages = ScanPages(["F1", "F2", "F3", "B3", "B2", "B1"].map { ScannedPage(id: $0, dpi: 300) })
        pages.analysed("F1", looksBlank: false, skew: 0, skipBlank: true, straighten: true, separator: SeparatorFound(.patchCode, code: .patchT))
        pages.analysed("B1", looksBlank: true, skew: 0, skipBlank: true, straighten: true)
        var stack = StackScan(fronts: ["F1", "F2", "F3"], backs: ["B3", "B2", "B1"])
        pages.pair(&stack, reversed: TurnedStack.backsReversed)
        let first = stack
        let swap = pages.swapBacks(&stack) // B3, a page of the document, is now the patch sheet's other side
        #expect(pages.page("B3")?.separator.kind == .sheetBack)
        pages.add(ScannedPage(id: "N", dpi: 300)) // a plain second scan: the model's stack is gone

        pages.undoSwap(swap)
        #expect(pages.page("B3")?.separator == SeparatorFound.none && pages.page("B1")?.separator.kind == .sheetBack)
        var order = first
        pages.unpair(&order)
        #expect(pages.pages.map(\.id) == ["F1", "F2", "F3", "B3", "B2", "B1", "N"])
        #expect(!pages.pages.contains { $0.separator.kind == .sheetBack })
        #expect(pages.toSave.map(\.id).contains("B3"))
    }

    @Test func aKeptPageKeepsItsSmallerFile() throws {
        // Review finding: a crash restore keeps the page's 1-bit saving (Windows' ScanKeeper keeps OneBit).
        var page = ScannedPage(id: "a", dpi: 300)
        page.oneBit = true
        let kept = ScanPages([page, ScannedPage(id: "b", dpi: 300)]).kept(printerId: "p", printerName: "P", ocr: false, now: Date(timeIntervalSince1970: 0))
        let back = ScanPages(restoring: try JSONDecoder().decode(KeptScan.self, from: JSONEncoder().encode(kept)))
        #expect(back.pages.map(\.oneBit) == [true, false])
    }
}
