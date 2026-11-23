import Foundation
import Testing
@testable import PrintCore

/// Ported from HandDuplexTests.cs: two-sided printing by hand (roadmap 4.2), the fronts, the stack put back as the prompt says,
/// the backs in the order that stack feeds them (`HandDuplexPlan`), checked on a model of the paper: each sheet ends with its
/// own back. And which way up a printer delivers its sheets, from its IPP answer (`HandDuplex.faceOf`).
struct HandDuplexTests {
    private final class Sheet {
        let number: Int
        var front: Int?
        var back: Int?
        init(_ number: Int, front: Int) {
            self.number = number
            self.front = front
        }
    }

    /// The paper, as a printer and a person handle it: the fronts print one sheet at a time, each landing on top of the output
    /// stack (face up or down, the last on top either way); the person sets the top sheet aside when told, puts the stack back
    /// as told (turned over like a page: its order reverses; else as it is), and the tray feeds from the top for the backs.
    private static func run(_ plan: HandDuplexPlan, _ face: OutputFace) -> [Sheet] {
        var output = plan.fronts.enumerated().map { Sheet($0.offset, front: $0.element) } // last = top
        let all = output
        let reload = plan.reload(face)
        var aside: Sheet?
        if reload.setAside { aside = output.removeLast() }
        if reload.turnOver { output.reverse() }
        var tray = output // the top of the output is the top of the tray: fed from the end
        for back in plan.backs(face) { tray.removeLast().back = back }
        #expect(tray.isEmpty) // every sheet went through, none left in the tray
        #expect(aside == nil || aside?.number == plan.sheets - 1, "the sheet set aside is the last one")
        return all
    }

    @Test(arguments: OutputFace.allCases)
    func everySheetGetsItsOwnBack(_ face: OutputFace) {
        for (pages, copies) in [(1, 1), (2, 1), (3, 1), (4, 1), (7, 1), (10, 1), (3, 2), (4, 3), (5, 3)] {
            let plan = HandDuplexPlan.plan(Array(0..<pages), copies: copies)
            let sheets = Self.run(plan, face)
            for (i, sheet) in sheets.enumerated() {
                #expect(sheet.front == plan.fronts[i])
                #expect((plan.sheetBacks[i] < 0 ? nil : plan.sheetBacks[i]) == (sheet.back.map { $0 < 0 ? nil : $0 } ?? nil))
            }
        }
    }

    @Test func fivePagesFaceDownGoBackAsTheyCameAndTheBacksRunLastSheetFirst() {
        let plan = HandDuplexPlan.plan([0, 1, 2, 3, 4])
        #expect(plan.fronts == [0, 2, 4])
        #expect(plan.sheetBacks == [1, 3, -1])
        #expect(plan.backs(.down) == [3, 1]) // page 5's sheet is set aside, not sent through blank
        #expect(plan.reload(.down) == HandDuplexReload(.down, 3, turnOver: false, setAside: true, blankBacks: 0, lastPage: 5))
    }

    @Test func faceUpTheStackIsTurnedOverAndTheBacksRunInOrder() {
        let plan = HandDuplexPlan.plan([0, 1, 2, 3])
        #expect(plan.backs(.up) == [1, 3])
        #expect(plan.backs(.down) == [3, 1])
        let reload = plan.reload(.up)
        #expect(reload.turnOver)
        #expect(!reload.setAside)
        #expect(reload.lastPage == nil)
    }

    @Test func copiesEachStartOnASheetOfTheirOwn() {
        let plan = HandDuplexPlan.plan([0, 1, 2], copies: 2)
        #expect(plan.fronts == [0, 2, 0, 2])
        #expect(plan.sheetBacks == [1, -1, 1, -1])
        #expect(plan.backs(.down) == [1, -1, 1]) // the first copy's last sheet goes through blank
        let reload = plan.reload(.down)
        #expect(reload.blankBacks == 1)
        #expect(reload.lastPage == 3)
        #expect(plan.sheets == 4)
        #expect(plan.sheets == BatchPrintSettings.sheets(3, 2, true)) // the estimate the batch made
    }

    @Test func theSheetSetAsideIsNamedByItsPageInTheDocument() {
        // Pages 2, 4 and 6 printed: the last sheet shows page 6, not the third position.
        #expect(HandDuplexPlan.plan([0, 1, 2], pageNumber: { [2, 4, 6][$0] }).reload(.down).lastPage == 6)
        // Copy's collated copies of 3 pages come as one padded order: the last sheet is page 3 of its copy, not position 7.
        #expect(HandDuplexPlan.plan([0, 1, 2, -1, 0, 1, 2, -1]).reload(.down).lastPage == 3)
        // Two pages a side: side 2 starts with page 5.
        #expect(HandDuplexPlan.plan([0, 1, 2], pageNumber: { $0 * 2 + 1 }).reload(.up).lastPage == 5)
    }

    @Test func onePageHasNoBacksAndACopySidesOrderIsKept() {
        #expect(!HandDuplexPlan.plan([0]).hasBacks)
        #expect(HandDuplexPlan.plan([0, 1]).hasBacks)
        // A copy's sides with a blank one (Copy's 2-up layout ends on a blank side): kept where it is.
        let plan = HandDuplexPlan.plan([0, 1, -1, 2])
        #expect(plan.fronts == [0, -1])
        #expect(plan.sheetBacks == [1, 2])
    }

    @Test func offeredOnlyWhereThePrinterSaidItCant() {
        #expect(HandDuplex.offered(false))
        #expect(!HandDuplex.offered(true))
        #expect(!HandDuplex.offered(nil)) // not known yet
    }

    @Test func faceFromThePrintersOutputTrayOrItsDefaultBin() {
        // As an HP LaserJet MFP M234dw answers (no identifiers in it).
        #expect(HandDuplex.faceOf("face-down",
            ["type=unRemovableBin;maxcapacity=125;remaining=-3;status=0;name=face-down;stackingorder=firstToLast;pagedelivery=faceDown"]) == .down)
        #expect(HandDuplex.faceOf("rear", ["name=top;pagedelivery=faceDown", "name=rear;pagedelivery=faceUp;"]) == .up)
        #expect(HandDuplex.faceOf("face-up", []) == .up)
        #expect(HandDuplex.faceOf(nil, ["pagedelivery=faceDown"]) == .down) // one tray: that one
        #expect(HandDuplex.faceOf("top", []) == nil)
        #expect(HandDuplex.faceOf(nil, []) == nil)
        #expect(HandDuplex.faceOf(nil, ["name=a;pagedelivery=faceUp", "name=b;pagedelivery=faceDown"]) == nil) // which one isn't said
        #expect(HandDuplex.faceOf(nil, [String(repeating: "x", count: 5000) + ";pagedelivery=faceUp"]) == nil) // too long to read
    }
}
