import Foundation
import Testing
@testable import PdfCore

/// Ported from DocumentWindowsTests.cs: two documents side by side (roadmap 4.9): which window owns which tab, moving and
/// tearing tabs off, launches, and what is remembered.
struct DocumentWindowsTests {
    @Test func AFileIsFoundInWhicheverWindowHasIt() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        let b = windows.open()
        try windows.add(a, 1, "/Docs/one.pdf")
        try windows.add(b, 2, "/Docs/two.pdf")
        try windows.add(b, 3, nil) // never saved

        #expect(windows.findFile("/docs/TWO.pdf").map { [$0.window, Int($0.tab)] } == [b, 2])
        #expect(windows.findFile("/Docs/one.pdf").map { [$0.window, Int($0.tab)] } == [a, 1])
        #expect(windows.findFile("/Docs/three.pdf") == nil)

        windows.setPath(3, "/Docs/three.pdf") // Save As
        #expect(windows.findFile("/Docs/three.pdf").map { [$0.window, Int($0.tab)] } == [b, 3])
        windows.remove(2)
        #expect(windows.findFile("/Docs/two.pdf") == nil)
    }

    @Test func AFileOnItsWayInOneWindowIsntReadAgainInAnother() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        _ = windows.open()
        #expect(windows.beginOpening("/Docs/big.pdf")) // window a starts reading it
        #expect(!windows.beginOpening("/docs/BIG.pdf")) // window b asks for it meanwhile
        try windows.add(a, 1, "/Docs/big.pdf")
        windows.endOpening("/Docs/big.pdf")
        #expect(!windows.beginOpening("/Docs/big.pdf")) // open in a tab now
        windows.remove(1)
        #expect(windows.beginOpening("/Docs/big.pdf")) // closed: it can open again
        windows.endOpening("/Docs/big.pdf") // a wrong password, say: not opened
        #expect(windows.beginOpening("/Docs/big.pdf"))
    }

    @Test func OtherLaunchesGoToTheWindowUsedLast() {
        let windows = DocumentWindows()
        let a = windows.open()
        #expect(windows.active == a)
        let b = windows.open()
        #expect(windows.active == b) // a new window is the one in use
        windows.activate(a)
        #expect(windows.active == a)
        windows.close(a)
        #expect(windows.active == b)
        windows.close(b)
        #expect(windows.active == nil)
        #expect(windows.count == 0)
    }

    @Test func ATabMovesToAnotherWindowUnlessItsDocumentIsBusy() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        let b = windows.open()
        try windows.add(a, 1, "1.pdf")
        try windows.add(a, 2, "2.pdf")
        try windows.add(b, 3, "3.pdf")

        #expect(windows.canMove(1, to: b, busy: true) == .busy)
        #expect(windows.canMove(1, to: a, busy: false) == .sameWindow)
        #expect(windows.canMove(9, to: b, busy: false) == .unknown)
        #expect(windows.canMove(1, to: 99, busy: false) == .unknown)
        #expect(windows.canMove(1, to: b, busy: false) == .moves)

        windows.activate(a)
        let moved = try windows.move(1, to: b, at: 0)
        #expect(moved == TabMoved(from: a, fromEmptied: false))
        #expect(windows.tabs(of: a) == [2])
        #expect(windows.tabs(of: b) == [1, 3])
        #expect(windows.window(of: 1) == b)
        #expect(windows.active == b) // the window it went to is in use now
    }

    @Test func AWindowEmptiedByAMoveCloses() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        let b = windows.open()
        try windows.add(a, 1, "1.pdf")
        try windows.add(b, 2, "2.pdf")
        let moved = try windows.move(1, to: b, at: 99) // past the end: last
        #expect(moved.fromEmptied)
        #expect(windows.tabs(of: b) == [2, 1])
    }

    @Test func MovingWithinAWindowReordersItsTabs() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        for t: Int64 in [1, 2, 3, 4] { try windows.add(a, t, "\(t).pdf") }
        // Tab 1 let go between 3 and 4: index 3 counts tab 1's own place, which it leaves.
        #expect(try !windows.move(1, to: a, at: 3).fromEmptied)
        #expect(windows.tabs(of: a) == [2, 3, 1, 4])
        _ = try windows.move(4, to: a, at: 0)
        #expect(windows.tabs(of: a) == [4, 2, 3, 1])
    }

    @Test func AWindowsOnlyTabDoesntTearOff() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        try windows.add(a, 1, "1.pdf")
        #expect(windows.canTearOff(1, busy: false) == .onlyTab)
        try windows.add(a, 2, "2.pdf")
        #expect(windows.canTearOff(1, busy: false) == .tearsOff)
        #expect(windows.canTearOff(1, busy: true) == .busy)
        #expect(windows.canTearOff(7, busy: false) == .unknown)
    }

    @Test func ATabIsInOneWindowOnly() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        let b = windows.open()
        try windows.add(a, 1, "1.pdf")
        #expect(throws: DocumentWindowsError.self) { try windows.add(b, 1, "1.pdf") }
        #expect(throws: DocumentWindowsError.self) { try windows.add(42, 2, "2.pdf") }
    }

    @Test func ClosingOneOfSeveralWindowsForgetsItsFiles() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        let b = windows.open()
        try windows.add(a, 1, "1.pdf")
        try windows.add(b, 2, "2.pdf")
        try windows.add(b, 3, nil)
        #expect(windows.remember(closing: a, everyWindow: false) == nil) // b is still open: what was remembered stays
        windows.close(a)
        #expect(windows.remember(closing: b, everyWindow: false) == ["2.pdf"]) // the last window: its saved files
    }

    @Test func WhenEveryWindowClosesAtOnceAllTheirFilesAreRememberedOnce() throws {
        let windows = DocumentWindows()
        let a = windows.open()
        let b = windows.open()
        try windows.add(a, 1, "1.pdf")
        try windows.add(b, 2, "2.pdf")
        try windows.add(b, 3, "1.PDF") // can't happen, but a file is listed once
        windows.closeAllStarting()
        #expect(windows.remember(closing: b, everyWindow: true) == ["1.pdf", "2.pdf"])
        windows.close(b)
        #expect(windows.remember(closing: a, everyWindow: true) == nil) // b's files stay remembered with a's

        // An Exit the user cancelled, then another: remembered afresh.
        windows.closeAllStarting()
        #expect(windows.remember(closing: a, everyWindow: true) == ["1.pdf"])
    }

    @Test func ALaunchCanAskForANewWindow() {
        let launch = WindowLaunch.parse(["--new-window", "/a.pdf"])
        #expect(launch.newWindow)
        #expect(launch.files == ["/a.pdf"])
        #expect(!WindowLaunch.parse(["/a.pdf"]).newWindow)
        #expect(WindowLaunch.parse(["--NEW-WINDOW"]).files.isEmpty)
    }

    // ── Dragging a tab ──

    private static let front = TabStripArea(window: 2, bounds: RectD(100, 0, 600, 40), tabMiddles: [150, 250, 350])
    private static let back = TabStripArea(window: 1, bounds: RectD(400, 0, 600, 40), tabMiddles: [450, 550])

    @Test func APressBecomesADragOnceItMovesWindowsDragDistance() {
        #expect(!TabDrag.started(pressed: PointD(10, 10), now: PointD(13, 12), minX: 4, minY: 4))
        #expect(TabDrag.started(pressed: PointD(10, 10), now: PointD(14, 10), minX: 4, minY: 4))
        #expect(TabDrag.started(pressed: PointD(10, 10), now: PointD(10, 6), minX: 4, minY: 4))
    }

    @Test func ATabLetGoOnAnotherWindowsStripMovesThereBetweenItsTabs() {
        let drop = TabDrag.drop(source: 1, sourceTabs: 2, at: PointD(300, 20), strips: [Self.front, Self.back])
        #expect(drop == TabDrop(.moveToWindow, window: 2, index: 2))
        // Just under the strip still counts, and the front window wins where the strips overlap.
        #expect(TabDrag.drop(source: 1, sourceTabs: 2, at: PointD(500, 40 + TabDrag.catchMargin - 1), strips: [Self.front, Self.back])
            == TabDrop(.moveToWindow, window: 2, index: 3))
        // Too far below: a window of its own.
        #expect(TabDrag.drop(source: 1, sourceTabs: 2, at: PointD(500, 40 + TabDrag.catchMargin + 1), strips: [Self.front, Self.back]).kind == .tearOff)
    }

    @Test func TheCatchGrowsWithTheScreensScale() {
        let y = 40 + TabDrag.catchMargin * 1.5 - 1
        #expect(TabDrag.drop(source: 1, sourceTabs: 2, at: PointD(300, y), strips: [Self.front]).kind == .tearOff)
        #expect(TabDrag.drop(source: 1, sourceTabs: 2, at: PointD(300, y), strips: [Self.front], scale: 1.5).kind == .moveToWindow)
    }

    @Test func ATabLetGoOnItsOwnStripReorders() {
        #expect(TabDrag.drop(source: 2, sourceTabs: 3, at: PointD(120, 10), strips: [Self.front, Self.back]) == TabDrop(.reorder, window: 2, index: 0))
        #expect(TabDrag.drop(source: 2, sourceTabs: 3, at: PointD(690, 10), strips: [Self.front, Self.back]) == TabDrop(.reorder, window: 2, index: 3))
    }

    @Test func AnOnlyTabLetGoAwayFromEveryStripStaysPut() {
        #expect(TabDrag.drop(source: 1, sourceTabs: 1, at: PointD(50, 500), strips: [Self.front, Self.back]).kind == TabDropKind.none)
        #expect(TabDrag.drop(source: 1, sourceTabs: 2, at: PointD(50, 500), strips: [Self.front, Self.back]).kind == .tearOff)
    }
}
