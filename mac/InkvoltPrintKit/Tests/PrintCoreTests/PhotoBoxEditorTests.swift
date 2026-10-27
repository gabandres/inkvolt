import Foundation
import Testing
@testable import PrintCore

/// The photo boxes adjusted by hand (`PhotoBoxEditor`). New for the Mac: the Windows app keeps these rules in its
/// `PhotoBoxesView` and `ScanViewModel`, untested; each test here is one of its behaviours. Points in scan widths; the scan
/// drawn 800 points wide, so a handle (9 pt) is about 0.011 of its width.
struct PhotoBoxEditorTests {
    private static let pageWidth = 800.0
    private static let aspect = 11.7 / 8.5

    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) < tolerance }

    /// A 0.4 × 0.3 box centred at (0.3, 0.4), straight.
    private static let straight = PhotoBox(centerX: 0.3, centerY: 0.4, width: 0.4, height: 0.3, angle: 0)
    private static let other = PhotoBox(centerX: 0.7, centerY: 1.0, width: 0.2, height: 0.2, angle: 10)

    private static func editor(_ boxes: PhotoBox...) -> PhotoBoxEditor { PhotoBoxEditor(boxes: boxes, aspect: aspect) }

    @Test func theFirstPhotoStartsSelectedAndNoneWhenThereAreNone() {
        #expect(Self.editor(Self.straight, Self.other).selected == 0)
        #expect(Self.editor().selected == -1)
        #expect(Self.editor().selectedBox == nil)
    }

    @Test func aPressPicksTheHandleThenACornerThenTheBoxThenTheGlass() {
        let e = Self.editor(Self.straight)
        let handle = PhotoBoxEditor.rotateHandle(Self.straight, pageWidth: Self.pageWidth)
        #expect(Self.near(handle.x, 0.3))
        #expect(Self.near(handle.y, 0.25 - 26 / Self.pageWidth)) // above the top edge's middle
        #expect(e.grip(at: handle, pageWidth: Self.pageWidth) == .rotate)
        #expect(e.grip(at: PhotoPoint(0.5, 0.55), pageWidth: Self.pageWidth) == .corner(2)) // bottom-right
        #expect(e.grip(at: PhotoPoint(0.105, 0.255), pageWidth: Self.pageWidth) == .corner(0)) // within 9 pt of top-left
        #expect(e.grip(at: PhotoPoint(0.3, 0.4), pageWidth: Self.pageWidth) == .move)
        #expect(e.grip(at: PhotoPoint(0.9, 0.1), pageWidth: Self.pageWidth) == .draw)
    }

    @Test func theTurningHandleFollowsTheBoxsAngle() {
        var turned = Self.straight
        turned.angle = 90
        let handle = PhotoBoxEditor.rotateHandle(turned, pageWidth: Self.pageWidth)
        // Turned a quarter clockwise, its top faces right: the handle is right of the box.
        #expect(handle.x > 0.3 + 0.15)
        #expect(Self.near(handle.y, 0.4, 1e-9))
    }

    @Test func onlyTheSelectedBoxShowsHandles() {
        var e = Self.editor(Self.straight, Self.other)
        e.select(1)
        // Just outside the straight box's corner: no handle while the other is selected, so it draws.
        #expect(e.grip(at: PhotoPoint(0.505, 0.555), pageWidth: Self.pageWidth) == .draw)
        e.select(0)
        #expect(e.grip(at: PhotoPoint(0.505, 0.555), pageWidth: Self.pageWidth) == .corner(2))
        #expect(e.grip(at: PhotoPoint(0.3, 0.4), pageWidth: Self.pageWidth) == .move)
    }

    @Test func draggingInsideABoxSelectsAndMovesIt() {
        var e = Self.editor(Self.straight, Self.other)
        e.press(at: PhotoPoint(0.7, 1.0), pageWidth: Self.pageWidth)
        #expect(e.selected == 1)
        e.drag(to: PhotoPoint(0.75, 0.9))
        #expect(Self.near(e.boxes[1].centerX, 0.75))
        #expect(Self.near(e.boxes[1].centerY, 0.9))
        #expect(e.boxes[1].angle == 10) // only moved
        e.release()
        #expect(!e.isDragging)
        #expect(e.boxes[0] == Self.straight)
    }

    @Test func overlappingBoxesGiveTheSelectedOneFirstThenTheLastDrawn() {
        let under = PhotoBox(centerX: 0.35, centerY: 0.4, width: 0.4, height: 0.3, angle: 0)
        var e = Self.editor(Self.straight, under)
        e.press(at: PhotoPoint(0.3, 0.4), pageWidth: Self.pageWidth)
        #expect(e.selected == 0) // in both; the selected one wins
        e.release()
        e.select(-1)
        e.press(at: PhotoPoint(0.3, 0.4), pageWidth: Self.pageWidth)
        #expect(e.selected == 1) // nothing selected: the last drawn
    }

    @Test func draggingACornerResizesWithTheOppositeCornerStaying() {
        var e = Self.editor(Self.straight)
        e.press(at: PhotoPoint(0.5, 0.55), pageWidth: Self.pageWidth)
        e.drag(to: PhotoPoint(0.6, 0.65))
        let box = e.boxes[0]
        #expect(Self.near(box.width, 0.5))
        #expect(Self.near(box.height, 0.4))
        let topLeft = box.corners()[0]
        #expect(Self.near(topLeft.x, 0.1))
        #expect(Self.near(topLeft.y, 0.25))
    }

    @Test func aCornerDraggedPastItsOppositeStopsAtTheSmallestSide() {
        var e = Self.editor(Self.straight)
        e.press(at: PhotoPoint(0.5, 0.55), pageWidth: Self.pageWidth)
        e.drag(to: PhotoPoint(0.0, 0.0))
        #expect(Self.near(e.boxes[0].width, PhotoBoxEditor.minSize))
        #expect(Self.near(e.boxes[0].height, PhotoBoxEditor.minSize))
    }

    @Test func theHandleTurnsTheBoxTowardThePointerAndShiftSnapsTo15Degrees() {
        var e = Self.editor(Self.straight)
        e.press(at: PhotoBoxEditor.rotateHandle(Self.straight, pageWidth: Self.pageWidth), pageWidth: Self.pageWidth)
        // Up and a little right of the centre: turned clockwise by atan(0.1 / 0.3) ≈ 18.4°.
        e.drag(to: PhotoPoint(0.4, 0.1))
        #expect(e.boxes[0].angle == 18.4)
        e.drag(to: PhotoPoint(0.4, 0.1), snap: true)
        #expect(e.boxes[0].angle == 15)
        #expect(e.boxes[0].width == 0.4) // turned, not resized
        #expect(e.boxes[0].centerX == 0.3)
    }

    @Test func draggingOnTheGlassDrawsANewPhotoOnceThePointerHasMoved() {
        var e = Self.editor(Self.straight)
        e.press(at: PhotoPoint(0.6, 0.8), pageWidth: Self.pageWidth)
        e.drag(to: PhotoPoint(0.605, 0.805)) // a twitch: nothing yet
        #expect(e.boxes.count == 1)
        e.drag(to: PhotoPoint(0.9, 1.0))
        #expect(e.boxes.count == 2)
        #expect(e.selected == 1)
        e.drag(to: PhotoPoint(0.8, 1.2)) // follows the pointer
        e.release()
        #expect(e.boxes.count == 2)
        let drawn = e.boxes[1]
        #expect(Self.near(drawn.centerX, 0.7))
        #expect(Self.near(drawn.centerY, 1.0))
        #expect(Self.near(drawn.width, 0.2))
        #expect(Self.near(drawn.height, 0.4))
        #expect(drawn.angle == 0)
    }

    @Test func aBoxDrawnTooSmallToBeAPhotoGoesAwayAgain() {
        var e = Self.editor(Self.straight)
        e.press(at: PhotoPoint(0.6, 0.8), pageWidth: Self.pageWidth)
        e.drag(to: PhotoPoint(0.62, 1.0)) // tall but 0.02 wide
        #expect(e.boxes.count == 2)
        e.release()
        #expect(e.boxes == [Self.straight])
        #expect(e.selected == 0)
    }

    @Test func tabGoesThroughThePhotosAndLetsTheFocusMoveOnAtEitherEnd() {
        var e = Self.editor(Self.straight, Self.other)
        let toSecond = e.selectNext()
        #expect(toSecond && e.selected == 1)
        let pastLast = e.selectNext()
        #expect(!pastLast && e.selected == 1)
        let back = e.selectNext(backwards: true)
        let beforeFirst = e.selectNext(backwards: true)
        #expect(back && !beforeFirst && e.selected == 0)
    }

    @Test func arrowsMoveShiftArrowsResizeOptionArrowsTurn() {
        var e = Self.editor(Self.straight)
        e.nudge(dx: 1, dy: 0)
        #expect(Self.near(e.boxes[0].centerX, 0.304))
        e.nudge(dx: 0, dy: -1)
        #expect(Self.near(e.boxes[0].centerY, 0.396))
        e.nudge(dx: -1, dy: 0, resize: true)
        #expect(Self.near(e.boxes[0].width, 0.396))
        #expect(e.boxes[0].height == 0.3)
        e.nudge(dx: 1, dy: 0, turn: true)
        #expect(e.boxes[0].angle == 0.5)
        e.nudge(dx: 0, dy: -1, turn: true, coarse: true)
        #expect(e.boxes[0].angle == -4.5)
    }

    @Test func resizingByKeyStopsAtTheSmallestSide() {
        var e = Self.editor(PhotoBox(centerX: 0.5, centerY: 0.5, width: 0.032, height: 0.2, angle: 0))
        e.nudge(dx: -1, dy: 0, resize: true)
        #expect(e.boxes[0].width == PhotoBoxEditor.minSize)
    }

    @Test func nothingSelectedLeavesTheArrowsAlone() {
        var e = Self.editor(Self.straight)
        e.select(-1)
        e.nudge(dx: 1, dy: 1)
        e.turnSelected()
        e.removeSelected()
        #expect(e.boxes == [Self.straight])
    }

    @Test func addPutsAPhotoInTheMiddleOfTheGlass() {
        var e = Self.editor()
        e.add()
        #expect(e.boxes == [PhotoBox(centerX: 0.5, centerY: Self.aspect / 2, width: 0.4, height: 0.3, angle: 0)])
        #expect(e.selected == 0)
    }

    @Test func removingSelectsTheNextOrTheLastLeft() {
        var e = Self.editor(Self.straight, Self.other, Self.straight)
        e.select(1)
        e.removeSelected()
        #expect(e.boxes.count == 2)
        #expect(e.selected == 1)
        e.removeSelected()
        #expect(e.selected == 0)
        e.removeSelected()
        #expect(e.selected == -1)
    }

    @Test func turnSavedPhotoGoesRoundInQuarters() {
        var e = Self.editor(Self.straight)
        for _ in 0..<3 { e.turnSelected() }
        #expect(e.boxes[0].quarterTurns == 3)
        e.turnSelected()
        #expect(e.boxes[0].quarterTurns == 0)
        #expect(e.boxes[0].angle == 0)
    }

    @Test func findAgainReplacesTheBoxesAndSelectsTheFirst() {
        var e = Self.editor(Self.straight)
        e.add()
        e.replaceAll([Self.other])
        #expect(e.boxes == [Self.other])
        #expect(e.selected == 0)
        e.replaceAll([])
        #expect(e.selected == -1)
    }

    @Test func theStatusSaysWhatIsMarked() {
        #expect(Self.editor().status(widthInches: 10)
            == "No photos marked: the whole scan is saved as one picture. Drag over a photo to mark it.")
        var e = Self.editor(Self.straight, Self.other)
        #expect(e.status(widthInches: 10) == "Photo 1 of 2: 4.0 × 3.0 in, straightened by 0°.")
        e.select(1)
        e.turnSelected()
        #expect(e.status(widthInches: 10) == "Photo 2 of 2: 2.0 × 2.0 in, straightened by 10°, saved turned 90°.")
        e.nudge(dx: 1, dy: 0, turn: true)
        #expect(e.status(widthInches: 10).contains("straightened by 10.5°"))
        e.select(-1)
        #expect(e.status(widthInches: 10) == "2 photos, each saved as its own picture.")
        var one = Self.editor(Self.straight)
        one.select(-1)
        #expect(one.status(widthInches: 10) == "1 photo, saved as its own picture.")
    }
}
