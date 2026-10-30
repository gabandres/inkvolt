import Foundation
import Testing
@testable import PdfCore

/// A Mac addition (no .NET counterpart file): Prepare Form's clicks, drags, keys and panel rules, which the Windows app keeps
/// in `PageViewer.FormDesign` and `DocumentTab.FormDesign` (views, untested there) and the Mac keeps in PdfCore as
/// `FormDesigner` and `FormDesignRules`. The rules are the Windows viewer's and tab's.
struct FormDesignerTests {
    private func field(_ kind: DesignFieldKind = .text, _ rect: RectD = RectD(100, 100, 100, 20), name: String = "A", id: String = "a", page: Int = 0,
                       tab: Int = 0) -> DesignField {
        FormDesign.newField(kind, page, rect, [], name).with {
            $0.id = id
            $0.tabIndex = tab
        }
    }

    private func designer(_ fields: DesignField...) -> FormDesigner {
        var d = FormDesigner()
        d.setFields(fields)
        return d
    }

    private func press(_ d: inout FormDesigner, _ x: Double, _ y: Double, clicks: Int = 1, page: Int = 0) -> DesignPress {
        d.press(page, PointD(x, y), clicks: clicks, reach: 5, pageWidth: 612, pageHeight: 792)
    }

    @Test func aClickWithAToolPlacesTheUsualSizeKeptOnThePage() {
        var d = designer()
        d.kind = .signature
        #expect(press(&d, 600, 780) == .none)
        #expect(d.newBox != nil)
        #expect(d.release() == .placed(DesignPlacement(kind: .signature, pageIndex: 0, rect: RectD(432, 752, 180, 40))))
        #expect(d.newBox == nil)
    }

    @Test func aDragWithAToolPlacesThatBoxAndCheckBoxesStaySquare() {
        var d = designer()
        d.kind = .text
        _ = press(&d, 50, 50)
        d.dragged(to: PointD(250, 80), shift: false, threshold: 2)
        #expect(d.release() == .placed(DesignPlacement(kind: .text, pageIndex: 0, rect: RectD(50, 50, 200, 30))))

        d.kind = .checkBox
        _ = press(&d, 50, 50)
        d.dragged(to: PointD(90, 70), shift: false, threshold: 2)
        #expect(d.release() == .placed(DesignPlacement(kind: .checkBox, pageIndex: 0, rect: RectD(50, 50, 20, 20))))

        // Too small to be meant: the usual size.
        d.kind = .text
        _ = press(&d, 50, 50)
        d.dragged(to: PointD(53, 53), shift: false, threshold: 2)
        #expect(d.release() == .placed(DesignPlacement(kind: .text, pageIndex: 0, rect: RectD(50, 50, 160, 20))))
    }

    @Test func aClickSelectsADragMovesAndTheFieldStaysOnThePage() {
        var d = designer(field())
        #expect(press(&d, 150, 110) == .none)
        #expect(d.selectedId == "a")
        // A press without a drag writes nothing.
        #expect(d.release() == nil)

        _ = press(&d, 150, 110)
        d.dragged(to: PointD(160, 130), shift: false, threshold: 2)
        #expect(d.shownRect(d.fields[0]) == RectD(110, 120, 100, 20))
        let moved = d.release()
        #expect(moved == .moved(field(.text, RectD(110, 120, 100, 20))))
        // It shows there until the document catches up.
        #expect(d.shownRect(d.fields[0]) == RectD(110, 120, 100, 20))
        d.setFields([field(.text, RectD(110, 120, 100, 20))])

        _ = press(&d, 150, 130)
        d.dragged(to: PointD(5000, -500), shift: false, threshold: 2)
        #expect(d.shownRect(d.fields[0]) == RectD(512, 0, 100, 20))
    }

    @Test func handlesResizeAndCheckBoxesKeepTheirShape() {
        var d = designer(field())
        _ = press(&d, 150, 110)
        _ = d.release()
        // The bottom-right handle, pressed a little off it: the frame doesn't jump.
        let handle = DrawingGeometry.handlePoint(RectD(100, 100, 100, 20), 4)
        #expect(handle == PointD(200, 120))
        #expect(d.handleAt(0, PointD(203, 118), reach: 5) == 4)
        #expect(d.cursor(0, PointD(203, 118), reach: 5) == .resize(4))
        _ = press(&d, 203, 118)
        d.dragged(to: PointD(253, 138), shift: false, threshold: 2)
        #expect(d.release() == .moved(field(.text, RectD(100, 100, 150, 40))))

        var c = designer(field(.checkBox, RectD(100, 100, 20, 20), id: "c"))
        _ = press(&c, 110, 110)
        _ = c.release()
        _ = press(&c, 120, 120)
        c.dragged(to: PointD(160, 130), shift: false, threshold: 2)
        guard case .moved(let f)? = c.release() else {
            Issue.record("no resize")
            return
        }
        #expect(f.rect.width == f.rect.height)
    }

    @Test func signedFieldsSelectButNeverMove() {
        var d = designer(field(.signature, RectD(100, 100, 200, 40)).with { $0.signed = true })
        _ = press(&d, 150, 110)
        #expect(d.selectedId == "a")
        #expect(!d.isDragging)
        #expect(d.handleAt(0, PointD(100, 100), reach: 5) == -1)
        #expect(d.cursor(0, PointD(150, 110), reach: 5) == .arrow)
        d.nudge(5, 0, pageWidth: 612, pageHeight: 792)
        #expect(!d.hasNudge)
    }

    @Test func aDoubleClickOpensPropertiesOrAddsASuggestion() {
        var d = designer(field())
        #expect(press(&d, 150, 110, clicks: 2) == .properties)
        d.setSuggestions([FieldSuggestion(pageIndex: 0, rect: RectD(100, 300, 100, 20), kind: .text, name: "S", multiline: false, source: "line")])
        #expect(press(&d, 150, 310, clicks: 1) == .none)
        #expect(d.selectedSuggestion?.name == "S")
        #expect(d.selectedId == nil)
        #expect(d.cursor(0, PointD(150, 310), reach: 5) == .pointingHand)
        #expect(press(&d, 150, 310, clicks: 2) == .accept)
    }

    @Test func anEmptySpotLetsGoAndPans() {
        var d = designer(field())
        _ = press(&d, 150, 110)
        _ = d.release()
        #expect(press(&d, 400, 400) == .pan)
        #expect(d.selectedId == nil)
    }

    @Test func theSmallestFieldUnderThePointerWins() {
        let big = field(.text, RectD(100, 100, 300, 300), id: "big"), small = field(.checkBox, RectD(150, 150, 14, 14), name: "B", id: "small")
        let d = designer(big, small)
        #expect(d.fieldAt(0, PointD(155, 155))?.id == "small")
        #expect(d.fieldAt(0, PointD(300, 300))?.id == "big")
        #expect(d.fieldAt(1, PointD(155, 155)) == nil)
    }

    @Test func tabGoesThroughFieldsThenSuggestionsPageByPage() {
        var d = designer(field(name: "B", id: "b", tab: 1), field(.text, RectD(100, 50, 100, 20), id: "a", tab: 0), field(name: "C", id: "c", page: 1))
        d.setSuggestions([FieldSuggestion(pageIndex: 0, rect: RectD(100, 300, 100, 20), kind: .text, name: "S", multiline: false, source: "line")])
        #expect(d.step(1)?.rect.y == 50)
        #expect(d.selectedId == "a")
        _ = d.step(1)
        #expect(d.selectedId == "b")
        _ = d.step(1)
        #expect(d.selectedSuggestionIndex == 0 && d.selectedId == nil)
        #expect(d.step(1)?.page == 1)
        #expect(d.selectedId == "c")
        _ = d.step(1)
        #expect(d.selectedId == "a") // around
        _ = d.step(-1)
        #expect(d.selectedId == "c")
    }

    @Test func arrowsAddUpAndAreWrittenOnce() {
        var d = designer(field())
        d.select("a")
        d.nudge(1, 0, pageWidth: 612, pageHeight: 792)
        d.nudge(10, 0, pageWidth: 612, pageHeight: 792)
        d.nudge(0, -1, pageWidth: 612, pageHeight: 792)
        #expect(d.shownRect(d.fields[0]) == RectD(111, 99, 100, 20))
        #expect(d.flushNudge() == field(.text, RectD(111, 99, 100, 20)))
        #expect(d.flushNudge() == nil)
        #expect(d.shownRect(d.fields[0]) == RectD(111, 99, 100, 20))
        d.nudge(-5000, 0, pageWidth: 612, pageHeight: 792)
        #expect(d.flushNudge()?.rect.x == 0)
    }

    @Test func escLetsGoStepByStep() {
        var d = designer(field())
        d.select("a")
        d.kind = .text
        #expect(d.escape() == .droppedTool)
        #expect(d.escape() == .deselected)
        #expect(d.escape() == .leave)
    }

    @Test func reReadingKeepsTheSelectionWhileItsFieldIsThere() {
        var d = designer(field())
        d.select("a")
        d.setFields([field()])
        #expect(d.selectedId == "a")
        d.setFields([])
        #expect(d.selectedId == nil)
    }

    @Test func aRadioButtonDrawnWithOneSelectedJoinsItsGroup() {
        let first = field(.radio, RectD(100, 100, 14, 14), name: "Pick").with {
            $0.exportValue = "Choice1"
            $0.defaultValue = "Choice1"
        }
        let joined = FormDesignRules.placedField(DesignPlacement(kind: .radio, pageIndex: 1, rect: RectD(130, 100, 14, 14)), fields: [first], selected: first)
        #expect(joined.name == "Pick" && joined.exportValue == "Choice2" && joined.defaultValue == "Choice1")
        #expect(joined.pageIndex == 1 && joined.id != first.id)
        let alone = FormDesignRules.placedField(DesignPlacement(kind: .radio, pageIndex: 0, rect: RectD(130, 100, 14, 14)), fields: [first], selected: nil)
        #expect(alone.name == "Group1")
        let tall = FormDesignRules.placedField(DesignPlacement(kind: .text, pageIndex: 0, rect: RectD(0, 0, 100, 40)), fields: [], selected: nil)
        #expect(tall.multiline)
    }

    @Test func aDuplicateGoesBelowElseBeside() {
        let f = field()
        #expect(FormDesignRules.duplicated(f, fields: [f], pageWidth: 612, pageHeight: 792).rect == RectD(100, 128, 100, 20))
        let low = field(.text, RectD(100, 770, 100, 20))
        #expect(FormDesignRules.duplicated(low, fields: [low], pageWidth: 612, pageHeight: 792).rect == RectD(208, 770, 100, 20))
    }

    @Test func acceptedSuggestionsGetUniqueNamesAndRadioValues() {
        func s(_ kind: DesignFieldKind, _ name: String, multiline: Bool = false) -> FieldSuggestion {
            FieldSuggestion(pageIndex: 0, rect: RectD(0, 0, 50, 50), kind: kind, name: name, multiline: multiline, source: "box")
        }
        let existing = field(.radio, RectD(0, 0, 14, 14), name: "R").with { $0.exportValue = "Choice2" }
        let made = FormDesignRules.acceptedFields([s(.text, "A", multiline: true), s(.text, "A"), s(.radio, "R"), s(.radio, "R")], fields: [existing])
        #expect(made.map(\.name) == ["A", "A_2", "R", "R"])
        #expect(made[0].multiline)
        #expect(made[2].exportValue == "Choice3")
        #expect(made[3].exportValue == "Choice4")
    }

    @Test func afterDeletingTheNextFieldWithItsOwnIdIsSelected() {
        let a = field(id: "a"), b = field(id: "p0:1"), c = field(id: "c")
        #expect(FormDesignRules.nextField(after: a, in: [a, b, c]) == "c")
        #expect(FormDesignRules.nextField(after: c, in: [a, b, c]) == "a")
        #expect(FormDesignRules.nextField(after: a, in: [a]) == nil)
        #expect(FormDesignRules.isPositionalId("p12:3"))
        #expect(!FormDesignRules.isPositionalId("page:3"))
        #expect(!FormDesignRules.isPositionalId("InkvoltPdf-abc"))
    }

    @Test func tabOrderMovesWithinThePageAndStopsAtItsEnds() throws {
        let a = field(id: "a", tab: 0), b = field(id: "b", tab: 1), other = field(id: "o", page: 1)
        #expect(try FormDesignRules.tabOrder(moving: a, by: 1, in: [a, b, other]).get() == ["b", "a"])
        #expect(throws: DesignRefusal.self) { try FormDesignRules.tabOrder(moving: a, by: -1, in: [a, b]).get() }
        #expect(throws: DesignRefusal.self) { try FormDesignRules.tabOrder(moving: b, by: 1, in: [a, b]).get() }
    }

    @Test func aFieldCoveringASuggestionTakesItsPlace() {
        let s = FieldSuggestion(pageIndex: 0, rect: RectD(100, 100, 100, 20), kind: .text, name: "S", multiline: false, source: "line")
        #expect(FormDesignRules.stillSuggested([s], fields: [field()]).isEmpty)
        #expect(FormDesignRules.stillSuggested([s], fields: [field(page: 1)]) == [s])
        #expect(FormDesignRules.stillSuggested([s], fields: [field(.text, RectD(100, 300, 100, 20))]) == [s])
    }

    @Test func aRenameIsCheckedAgainstTheOtherFields() throws {
        let a = field(name: "A", id: "a"), b = field(name: "B", id: "b")
        #expect(try FormDesignRules.renamed(a, to: " A ", fields: [a, b]) == a)
        #expect(try FormDesignRules.renamed(a, to: " C ", fields: [a, b]).name == "C")
        #expect(throws: DesignRefusal.self) { try FormDesignRules.renamed(a, to: "B", fields: [a, b]) }
        #expect(throws: DesignRefusal.self) { try FormDesignRules.renamed(a, to: "B.c", fields: [a, b]) }
        // A group's other buttons don't clash with a rename of one of them, and another group can be joined.
        let r1 = field(.radio, name: "R", id: "1"), r2 = field(.radio, name: "R", id: "2"), g = field(.radio, name: "G", id: "3")
        #expect(try FormDesignRules.renamed(r1, to: "G", fields: [r1, r2, g]).name == "G")
    }

    @Test func typedLimitsAndValuesAreChecked() throws {
        let f = field()
        #expect(try FormDesignRules.withMaxLength(f, "12").maxLength == 12)
        #expect(try FormDesignRules.withMaxLength(f, "").maxLength == 0)
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withMaxLength(f, "many") }
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withMaxLength(f, "-1") }
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withMaxLength(f, "100001") }

        let r1 = field(.radio, name: "R", id: "1").with {
            $0.exportValue = "One"
            $0.defaultValue = "One"
        }
        let r2 = field(.radio, name: "R", id: "2").with { $0.exportValue = "Two" }
        let renamed = try FormDesignRules.withExportValue(r1, "First", fields: [r1, r2])
        #expect(renamed.exportValue == "First" && renamed.defaultValue == "First")
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withExportValue(r1, "Two", fields: [r1, r2]) }
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withExportValue(r1, "Off", fields: [r1, r2]) }
    }

    @Test func choicesAreOnePerLineWithShownTextAndValue() throws {
        let parsed = FormDesignRules.parseChoices("Gold = g\r\n\n Silver \nGold again = g\nBronze = \n")
        #expect(parsed.options == ["g", "Silver", "Bronze ="])
        #expect(parsed.labels == ["Gold", "Silver", "Bronze ="])

        var f = field(.comboBox)
        f.options = ["g", "s"]
        f.optionLabels = ["Gold", "s"]
        f.defaultValue = "s"
        #expect(FormDesignRules.choicesText(f) == "Gold = g\ns")
        #expect(try FormDesignRules.withChoices(f, "Gold = g\ns") == f)
        let changed = try FormDesignRules.withChoices(f, "a\nb")
        #expect(changed.options == ["a", "b"] && changed.optionLabels.isEmpty && changed.defaultValue.isEmpty)
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withChoices(f, "  \n") }
    }

    @Test func defaultsAndSizes() {
        let check = field(.checkBox)
        #expect(FormDesignRules.withDefaultOn(check, true).defaultValue == check.exportValue)
        #expect(FormDesignRules.withDefaultOn(check.with { $0.defaultValue = "Yes" }, false).defaultValue.isEmpty)
        // Turning off a radio button that isn't the default leaves the group's default.
        let radio = field(.radio).with {
            $0.exportValue = "A"
            $0.defaultValue = "B"
        }
        #expect(FormDesignRules.withDefaultOn(radio, false).defaultValue == "B")

        #expect(FormDesignRules.parseSize("Auto") == 0)
        #expect(FormDesignRules.parseSize("") == 0)
        #expect(FormDesignRules.parseSize("12 pt") == 12)
        #expect(FormDesignRules.parseSize("10.5") == 10.5)
        #expect(FormDesignRules.parseSize("300") == nil)
        #expect(FormDesignRules.parseSize("big") == nil)
        #expect(FormDesignRules.sizeText(0) == "Auto")
        #expect(FormDesignRules.sizeText(12) == "12")
        #expect(FormDesignRules.sizeText(10.5) == "10.5")
    }

    @Test func panelListsSayWhatIsKept() {
        let plain = field()
        #expect(FormDesignRules.formatChoices(plain).selected == 0)
        let money = plain.with { $0.format = FieldFormat(.number, decimals: 2, currency: "$", currencyPrepend: true) }
        #expect(FormDesignRules.formatChoices(money).selected == 3)
        let other = plain.with { $0.format = FieldFormat(.date, datePattern: "d mmm") }
        #expect(FormDesignRules.formatChoices(other).labels.last == "Other (date, kept)")
        #expect(FormDesignRules.formatChoices(other).selected == FormDesignRules.formats.count)
        let custom = plain.with { $0.customFormat = true }
        #expect(FormDesignRules.formatChoices(custom).labels.last == "Custom script (kept)")

        #expect(FormDesignRules.colorIndex(FormDesignRules.borderColors, nil) == 0)
        #expect(FormDesignRules.colorIndex(FormDesignRules.borderColors, AnnotColor(0.45, 0.46, 0.44)) == 2)
        #expect(FormDesignRules.colorIndex(FormDesignRules.fillColors, AnnotColor(0.2, 0.3, 0.4)) == nil)
        #expect(FormDesignRules.panelTitle(plain, nil) == "Text field · page 1")
        #expect(FormDesignRules.panelTitle(nil, nil) == "Prepare Form")
    }

    @Test func aChangeOnlyCountsWhenItShows() {
        let f = field(.comboBox).with {
            $0.options = ["a"]
            $0.optionLabels = []
        }
        #expect(!FormDesignRules.differs(f, f.with { $0.optionLabels = ["a"] }))
        #expect(FormDesignRules.differs(f, f.with { $0.optionLabels = ["A"] }))
        #expect(FormDesignRules.differs(f, f.with { $0.required = true }))
    }
}
