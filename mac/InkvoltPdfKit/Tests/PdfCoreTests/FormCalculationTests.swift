import Foundation
import Testing
@testable import PdfCore

/// FormCalculationTests.cs (roadmap 4.12): calculated fields made in Prepare Form (`FormCalculations`, `FormDesign`'s
/// /AA /C and /CO), and several fields aligned, sized and spaced together (`FormDesignRules`, `FormDesigner`'s selection).
/// The Mac's designer takes the page's size with each press and keys go through the window, so "Key" steps are the calls
/// the window makes (`nudge`, `flushNudgeAll`, `escape`).
struct FormCalculationTests {
    private static func text(_ name: String, _ y: Double, x: Double = 72) -> DesignField {
        FormDesign.newField(.text, 0, RectD(x, y, 120, 20), [], name)
    }

    private static func value(_ pdf: [UInt8], _ name: String) throws -> String {
        try #require(FormEditor.read(pdf, nil).first { $0.fieldName == name }).value
    }

    private static func fill(_ pdf: [UInt8], _ values: [(String, String)]) throws -> [UInt8] {
        try FormEditor.setValues(pdf, nil, Dictionary(values, uniquingKeysWith: { a, _ in a }))
    }

    @Test func simpleCalculationsAreWrittenAsAcrobatWritesThemAndReadBack() throws {
        let sum = FieldCalc(.sum, ["a", "b \"c\""])
        let script = try FormCalculations.scriptOf(sum)
        #expect(script == "AFSimple_Calculate(\"SUM\", new Array (\"a\", \"b \\\"c\\\"\"));")
        #expect(FormCalculations.read(script) == sum)
        // Acrobat's own spellings of the same.
        #expect(FormCalculations.read("AFSimple_Calculate('AVG', ['x','y'])") == FieldCalc(.average, ["x", "y"]))
        #expect(FormCalculations.read("AFSimple_Calculate(\"PRD\", new Array (\"Qty\", \"Price\"));\r\n") == FieldCalc(.product, ["Qty", "Price"]))
        #expect(FormCalculations.read("AFSimple_Calculate(\"MIN\", new Array(\"a\"))")?.kind == .minimum)
        #expect(FormCalculations.read("AFSimple_Calculate(\"MAX\", new Array(\"a\"))")?.kind == .maximum)
        // Anything more is the form's own script, kept whole.
        let own = "AFSimple_Calculate(\"SUM\", new Array(\"a\")); event.value *= 2;"
        #expect(FormCalculations.read(own) == FieldCalc(.custom, [], script: own))
        #expect(FormCalculations.read("AFSimple_Calculate(\"SUM\", new Array(a))")?.kind == .custom)
        #expect(FormCalculations.read("  ") == nil)
    }

    @Test func simplifiedFieldNotationCompilesToJavaScriptAndKeepsTheNotation() throws {
        let js = try FormCalculations.compile("Price * Qty + 1.5")
        #expect(js == "event.value = AFMakeNumber(getField(\"Price\").value) * AFMakeNumber(getField(\"Qty\").value) + 1.5;")
        let calc = FieldCalc(.notation, ["Unit price", "Qty"], notation: "(Unit\\ price - 2) * Qty")
        let script = try FormCalculations.scriptOf(calc)
        #expect(script.hasPrefix("/** BVCALC (Unit\\ price - 2) * Qty EVCALC **/ "))
        #expect(FormCalculations.read(script) == calc)
        #expect(FormCalculations.notationFields("(Unit\\ price - 2) * Qty * Qty") == ["Unit price", "Qty"])
        #expect(FormCalculations.nameInNotation("Unit price") == "Unit\\ price")
        #expect(FormCalculations.nameInNotation("2nd") == "\\2nd")
        #expect(FormCalculations.nameInNotation("Text1.0") == "Text1.0")

        // An edited script after the notation is the form's own.
        #expect(FormCalculations.read("/** BVCALC a*b EVCALC **/ event.value = 3;")?.kind == .custom)

        for bad in ["", "a *", "* a", "(a + b", "a + b)", "a b", "a $ b", "a\\*/b", "a + EVCALC"] {
            #expect(throws: DesignRefusal.self, "\(bad)") { try FormCalculations.compile(bad) }
        }
        #expect(throws: DesignRefusal.self) { try FormCalculations.compile(String(repeating: "(", count: 40) + "a" + String(repeating: ")", count: 40)) }
        #expect(throws: DesignRefusal.self) { try FormCalculations.compile(Array(repeating: "a", count: 3000).joined(separator: "+")) }
    }

    @Test func calculatedFieldsRecalculateWhenTheFormIsFilled() throws {
        let fields = [Self.text("Price", 100), Self.text("Qty", 130), Self.text("Total", 160), Self.text("Tax", 190), Self.text("Sum", 220),
                      Self.text("Avg", 250), Self.text("Low", 280), Self.text("High", 310)]
        var pdf = try FormDesign.add(TestPdf.make(1), nil, fields)
        var design = try FormDesign.read(pdf, nil)
        func of(_ n: String) throws -> DesignField { try #require(design.first { $0.name == n }) }
        let changes = [
            try FormDesignRules.withCalculation(of("Total"), .notation, [], "Price * Qty", design),
            try FormDesignRules.withCalculation(of("Tax"), .notation, [], "Total * 0.1", design).with { $0.format = FormDesignRules.formats[1].format },
            try FormDesignRules.withCalculation(of("Sum"), .sum, ["Qty", "Price"], "", design),
            try FormDesignRules.withCalculation(of("Avg"), .average, ["Price", "Qty"], "", design),
            try FormDesignRules.withCalculation(of("Low"), .minimum, ["Price", "Qty"], "", design),
            try FormDesignRules.withCalculation(of("High"), .maximum, ["Price", "Qty"], "", design),
        ]
        // Picked fields are kept in the form's order.
        #expect(changes[2].calculation?.fields == ["Price", "Qty"])
        pdf = try FormDesign.update(pdf, nil, changes)

        // They read back, and the calculation order lists them as they were made.
        design = try FormDesign.read(pdf, nil)
        #expect(try of("Total").calculation == FieldCalc(.notation, ["Price", "Qty"], notation: "Price * Qty"))
        #expect(try of("Sum").calculation == FieldCalc(.sum, ["Price", "Qty"]))
        #expect(try of("Price").calculation == nil)
        #expect(try FormDesign.calculationOrder(pdf, nil) == ["Total", "Tax", "Sum", "Avg", "Low", "High"])

        let filled = try Self.fill(pdf, [("Price", "12.5"), ("Qty", "4")])
        #expect(try Self.value(filled, "Total") == "50")
        #expect(try Self.value(filled, "Tax") == "5")
        #expect(try Self.value(filled, "Sum") == "16.5")
        #expect(try Self.value(filled, "Avg") == "8.25")
        #expect(try Self.value(filled, "Low") == "4")
        #expect(try Self.value(filled, "High") == "12.5")
        #expect(try Core2Pdf.allText(filled).contains("5.00")) // Tax shows in its number format

        // Tax before Total: Tax reads the Total of before (Acrobat's order rule), until the next fill.
        let reordered = try FormDesign.setCalculationOrder(pdf, nil, ["Tax", "Total"])
        #expect(try FormDesign.calculationOrder(reordered, nil) == ["Tax", "Total", "Sum", "Avg", "Low", "High"])
        let stale = try Self.fill(reordered, [("Price", "10"), ("Qty", "2")])
        #expect(try Self.value(stale, "Total") == "20")
        #expect(try Self.value(stale, "Tax") == "0")
        #expect(try FormDesign.setCalculationOrder(reordered, nil, ["Tax"]) == reordered)

        // Not calculated any more: the script and its place in the order go.
        design = try FormDesign.read(pdf, nil)
        pdf = try FormDesign.update(pdf, nil, [try FormDesignRules.withCalculation(of("Sum"), .notCalculated, [], "", design)])
        #expect(try FormDesign.read(pdf, nil).first { $0.name == "Sum" }?.calculation == nil)
        #expect(try !FormDesign.calculationOrder(pdf, nil).contains("Sum"))
        #expect(try Self.value(Self.fill(pdf, [("Price", "3")]), "Sum") == "")
    }

    @Test func aFormsOwnCalculateScriptIsKeptAndTheRulesRefuseWhatCantWork() throws {
        var pdf = try FormDesign.add(TestPdf.make(1), nil, [Self.text("A", 100), Self.text("B", 130)])
        let design = try FormDesign.read(pdf, nil)
        let b = try #require(design.first { $0.name == "B" })
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withCalculation(b, .sum, ["B"], "", design) }
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withCalculation(b, .notation, [], "A + B", design) }
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withCalculation(b, .notation, [], "A + Missing", design) }
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withCalculation(b, .notation, [], " ", design) }
        // From a list to the notation: the picked fields, added.
        #expect(try FormDesignRules.withCalculation(b, .notation, ["A"], "", design).calculation?.notation == "A")
        #expect(FormDesignRules.calcSources(b, design) == ["A"])

        let custom = FieldCalc(.custom, [], script: "event.value = this.getField(\"A\").value * 3;")
        let withOwn = b.with { $0.calculation = custom }
        #expect(FormDesignRules.calcIndex(withOwn) == -1)
        #expect(throws: DesignRefusal.self) { try FormDesignRules.withCalculation(withOwn, .sum, ["A"], "", design) }
        #expect(FormDesignRules.calcIndex(b.with { $0.calculation = FieldCalc(.sum, ["A"]) }) == 1)
        #expect(FormDesignRules.calcIndex(b) == 0)

        // A script set some other way stays through a property change.
        pdf = try FormDesign.update(pdf, nil, [try FormDesignRules.withCalculation(b, .sum, ["A"], "", design)])
        let read = try #require(FormDesign.read(pdf, nil).first { $0.name == "B" })
        pdf = try FormDesign.update(pdf, nil, [read.with {
            $0.tooltip = "Three times A"
            $0.calculation = custom
        }])
        #expect(try FormDesign.read(pdf, nil).first { $0.name == "B" }?.calculation == FieldCalc(.sum, ["A"]))

        #expect(try FormDesignRules.movedInOrder(["a", "b", "c"], 1, -1) == ["b", "a", "c"])
        #expect(throws: DesignRefusal.self) { try FormDesignRules.movedInOrder(["a", "b"], 1, 1) }
    }

    @Test func numberFormatsAreAcrobatsAndReadBackAsTheirChoice() throws {
        var pdf = try FormDesign.add(TestPdf.make(1), nil, [Self.text("Euro", 100)])
        let f = try #require(FormDesign.read(pdf, nil).first)
        let euro = try #require(FormDesignRules.formats.firstIndex { $0.format?.currency == " €" })
        #expect(euro > 0)
        pdf = try FormDesign.update(pdf, nil, [f.with { $0.format = FormDesignRules.formats[euro].format }])
        #expect(try FormDesignRules.formatChoices(#require(FormDesign.read(pdf, nil).first)).selected == euro)
        #expect(FormDesign.formatScripts(try #require(FormDesignRules.formats[euro].format)).format == "AFNumber_Format(2, 2, 0, 0, \" €\", false);")
        #expect(try Core2Pdf.allText(Self.fill(pdf, [("Euro", "1234.5")])).contains("1.234,50 €"))
        let parens = try #require(FormDesignRules.formats.firstIndex { $0.format?.negativeStyle == 2 })
        pdf = try FormDesign.update(pdf, nil, [try #require(FormDesign.read(pdf, nil).first).with { $0.format = FormDesignRules.formats[parens].format }])
        #expect(try Core2Pdf.allText(Self.fill(pdf, [("Euro", "-1234.5")])).contains("(1,234.50)"))
    }

    // MARK: Several fields

    static func at(_ id: String, _ x: Double, _ y: Double, w: Double = 100, h: Double = 20, kind: DesignFieldKind = .text) -> DesignField {
        FormDesign.newField(kind, 0, RectD(x, y, w, h), [], id).with { $0.id = id }
    }

    private static let page = DesignPage(612, 792)

    private func press(_ d: inout FormDesigner, _ x: Double, _ y: Double, toggle: Bool = false) -> DesignPress {
        d.press(0, PointD(x, y), clicks: 1, reach: 5, pageWidth: 612, pageHeight: 792, toggle: toggle)
    }

    @Test func ctrlClickSelectsSeveralAndADragMovesThemTogether() throws {
        var d = FormDesigner()
        d.setFields([Self.at("a", 100, 100), Self.at("b", 100, 200), Self.at("c", 300, 300), Self.at("d", 100, 400).with { $0.pageIndex = 1 }])
        _ = press(&d, 110, 110)
        _ = d.release()
        // The Mac's DesignPress has no "selected": the press selected and nothing more.
        #expect(press(&d, 310, 310, toggle: true) == .none)
        #expect(d.release() == nil)
        _ = press(&d, 110, 210, toggle: true)
        #expect(d.selectedIds == ["a", "c", "b"])
        #expect(d.hasSeveral)
        #expect(d.handleAt(0, PointD(100, 100), reach: 5) == -1) // no handles on several

        // Taking the anchor out: the next one picked is the anchor.
        d.toggle("a")
        #expect(d.selectedIds == ["c", "b"])
        d.toggle("a")
        #expect(d.selectedIds == ["c", "b", "a"])

        // A drag of one moves them all, stopped where the last one meets the page's edge.
        _ = press(&d, 110, 210)
        d.dragged(to: PointD(110 + 500, 220), shift: false, threshold: 2)
        #expect(d.shownRect(try #require(d.fields.first { $0.id == "c" })) == RectD(512, 300 + 10, 100, 20))
        guard case .movedAll(let all) = d.release() else {
            Issue.record("not moved together")
            return
        }
        #expect(all.map(\.id) == ["b", "c", "a"])
        #expect(all.map(\.rect.x) == [312.0, 512, 312])
        #expect(d.selectedIds == ["c", "b", "a"])

        // Arrow keys move them all, written together once they rest.
        d.nudge(0, -10, pageWidth: 612, pageHeight: 792)
        let written = d.flushNudgeAll()
        _ = d.escape()
        #expect(written.map(\.rect.y) == [300.0, 200, 100])
        #expect(d.selectedIds.isEmpty)

        // A field of another page starts a new selection; a plain click on one, a single one.
        d.selectAll(["a", "b"])
        d.toggle("d")
        #expect(d.selectedIds == ["d"])
        d.selectAll(["a", "b", "d"])
        #expect(d.selectedIds == ["a", "b"])
        _ = press(&d, 520, 315)
        _ = d.release()
        #expect(d.selectedIds == ["c"])
    }

    @Test func severalFieldsAlignToTheFirstOnePicked() throws {
        let sel = [Self.at("a", 100, 100, w: 100, h: 20), Self.at("b", 150, 200, w: 60, h: 30), Self.at("c", 40, 300, w: 200, h: 10)]
        func r(_ moved: [DesignField], _ id: String) -> RectD { moved.first { $0.id == id }?.rect ?? .zero }

        let left = try FormDesignRules.aligned(sel, .left, Self.page)
        #expect([r(left, "b").x, r(left, "c").x] == [100.0, 100])
        let right = try FormDesignRules.aligned(sel, .right, Self.page)
        #expect([r(right, "b").right, r(right, "c").right] == [200.0, 200])
        let center = try FormDesignRules.aligned(sel, .center, Self.page)
        #expect([r(center, "b").centerX, r(center, "c").centerX] == [150.0, 150])
        let top = try FormDesignRules.aligned(sel, .top, Self.page)
        #expect([r(top, "b").y, r(top, "c").y] == [100.0, 100])
        let bottom = try FormDesignRules.aligned(sel, .bottom, Self.page)
        #expect([r(bottom, "b").bottom, r(bottom, "c").bottom] == [120.0, 120])
        let middle = try FormDesignRules.aligned(sel, .middle, Self.page)
        #expect([r(middle, "b").centerY, r(middle, "c").centerY] == [110.0, 110])
        #expect(!left.contains { $0.id == "a" })

        // Already lined up: nothing to write. A signed field never moves.
        #expect(try FormDesignRules.aligned([Self.at("a", 100, 100), Self.at("b", 100, 300)], .left, Self.page).isEmpty)
        #expect(try FormDesignRules.aligned([Self.at("a", 100, 100), Self.at("b", 50, 300).with { $0.signed = true }], .left, Self.page).isEmpty)
        #expect(throws: DesignRefusal.self) { try FormDesignRules.aligned([Self.at("a", 100, 100)], .left, Self.page) }

        // On a page shown turned 90°, "left" is the page as shown: the fields' page-space Y lines up.
        let turned = try FormDesignRules.aligned([Self.at("a", 100, 100), Self.at("b", 300, 200)], .left, DesignPage(612, 792, rotation: 90))
        #expect(RotatedView.toView(r(turned, "b"), 612, 792, 90).x == 792 - 120.0)
        #expect(r(turned, "b") == RectD(300, 100, 100, 20))
    }

    @Test func severalFieldsTakeTheFirstOnesSizeAndSpreadEvenly() throws {
        let sel = [Self.at("a", 100, 100, w: 150, h: 30), Self.at("b", 100, 200, w: 60, h: 20), Self.at("box", 100, 300, w: 14, h: 14, kind: .checkBox)]
        let width = try FormDesignRules.sizedAlike(sel, .width, Self.page)
        #expect(width.first { $0.id == "b" }?.rect == RectD(100, 200, 150, 20))
        #expect(width.first { $0.id == "box" }?.rect == RectD(100, 300, 150, 150)) // a check box stays square
        let both = try FormDesignRules.sizedAlike(sel, .both, Self.page)
        #expect(both.first { $0.id == "b" }?.rect == RectD(100, 200, 150, 30))
        #expect(try FormDesignRules.sizedAlike(sel, .height, Self.page).first { $0.id == "box" }?.rect == RectD(100, 300, 30, 30))
        // Kept on the page.
        #expect(try FormDesignRules.sizedAlike([Self.at("a", 0, 0, w: 400, h: 20), Self.at("b", 500, 50)], .width, Self.page).first?.rect.right == 612.0)

        // Across: the outer two stay, the gaps between are equal, in the order shown on the page.
        let row = [Self.at("m", 300, 100, w: 50), Self.at("first", 100, 100, w: 50), Self.at("last", 500, 100, w: 100), Self.at("n", 200, 100, w: 20)]
        let spread = try FormDesignRules.spread(row, .across, Self.page)
        // span 100..600 = 500, widths 220, gaps 280/3
        let gap = 280.0 / 3
        #expect(abs((spread.first { $0.id == "n" }?.rect.x ?? 0) - (150 + gap)) < 1e-6)
        #expect(abs((spread.first { $0.id == "m" }?.rect.x ?? 0) - (150 + gap + 20 + gap)) < 1e-6)
        #expect(!spread.contains { $0.id == "first" || $0.id == "last" })
        let down = try FormDesignRules.spread([Self.at("a", 100, 100), Self.at("b", 100, 130), Self.at("c", 100, 400)], .down, Self.page)
        #expect(down.count == 1 && down.first?.rect.y == 250.0)
        #expect(throws: DesignRefusal.self) { try FormDesignRules.spread([Self.at("a", 0, 0), Self.at("b", 0, 50)], .down, Self.page) }
    }
}
