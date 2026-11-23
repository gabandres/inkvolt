import Foundation
import Testing
@testable import PdfCore

/// Wave4CReviewTests.cs: review fixes for Wave 4 Batch C (4.12, 4.19), the cases the first version got wrong.
struct Wave4CReviewTests {
    private static func at(_ id: String, _ x: Double, _ y: Double, signed: Bool = false) -> DesignField {
        FormDesign.newField(signed ? .signature : .text, 0, RectD(x, y, 100, 20), [], id).with {
            $0.id = id
            $0.signed = signed
        }
    }

    @Test func aGroupDragGoesOnFromTheFieldsAsReadAgain() throws {
        var d = FormDesigner()
        d.setFields([Self.at("a", 100, 100), Self.at("b", 100, 200)])
        d.selectAll(["a", "b"])
        _ = d.press(0, PointD(110, 110), clicks: 1, reach: 5, pageWidth: 612, pageHeight: 792)
        d.dragged(to: PointD(120, 110), shift: false, threshold: 2)
        // The document catches up meanwhile (b was moved by an earlier edit): the drag carries b from where it is now.
        d.setFields([Self.at("a", 100, 100), Self.at("b", 300, 200)])
        d.dragged(to: PointD(130, 110), shift: false, threshold: 2)
        guard case .movedAll(let all) = d.release() else {
            Issue.record("not moved together")
            return
        }
        #expect(all.first { $0.id == "b" }?.rect == RectD(320, 200, 100, 20))
    }

    @Test func severalWithASignedAnchorStillDeleteAndNudgeTheUnsignedOnly() {
        var d = FormDesigner()
        let sig = Self.at("s", 100, 100, signed: true)
        let a = Self.at("a", 100, 200)
        d.setFields([sig, a])
        d.selectAll(["s", "a"])
        // Windows' Delete key: the window asks `canDelete` (the view's Delete and the panel's button).
        #expect(d.canDelete)
        d.nudge(10, 0, pageWidth: 612, pageHeight: 792)
        #expect(d.shownRect(sig) == sig.rect) // a signed field never shows moved
        #expect(d.shownRect(a).x == 110)
        #expect(d.flushNudgeAll().map(\.id) == ["a"])
    }

    @Test func aSnapRefusedForSizeShowsNoLine() throws {
        let snap = try #require(Snapper.for([Guide(0, .x, 100)], nil, gridStep: 0, reach: 5))
        #expect(snap.resize(RectD(90, 10, 12, 20), RectD(98, 10, 4, 20), min: 4) == RectD(98, 10, 4, 20))
        #expect(snap.lines.isEmpty)
        _ = snap.resize(RectD(10, 10, 80, 20), RectD(10, 10, 93, 20))
        #expect(snap.lines == [SnapLine(.x, 100)])
    }

    @Test func aNotationKeepsANameWithABracketAsWritten() throws {
        let notation = FormCalculations.nameInNotation("Unit )") + " * 2"
        let js = try FormCalculations.compile(notation)
        #expect(js.contains("getField(\"Unit )\")"))
        #expect(try FormCalculations.compile("(a + 1) * 2") == "event.value = (AFMakeNumber(getField(\"a\").value) + 1) * 2;")
        let calc = FieldCalc(.notation, ["Unit )"], notation: notation)
        #expect(FormCalculations.read(try FormCalculations.scriptOf(calc)) == calc)
    }

    @Test func aWidgetsOwnCalculateScriptIsReadChangedAndRemovedWhereItIs() throws {
        var pdf = try FormDesign.add(TestPdf.make(1), nil, [FormDesign.newField(.text, 0, RectD(72, 100, 100, 20), [], "A"),
                                                            FormDesign.newField(.text, 0, RectD(72, 200, 100, 20), [], "T")])
        // T as a parent field with one widget kid that holds the calculate script, as some forms are made.
        pdf = try PageEditor.edit(pdf, nil) { doc in
            guard let acro = doc.catalog.dict("AcroForm"), let fields = acro.array("Fields"),
                  let i = fields.elements.firstIndex(where: { $0.text("T") == "T" }) else { return }
            let w = fields.elements[i]
            let parent = doc.add(doc.dict([("FT", w["FT"] ?? doc.name("Tx")), ("T", doc.text("T")), ("Kids", doc.array([w]))]))
            w.remove("FT")
            w.remove("T")
            w.set("Parent", parent)
            let c = doc.dict([("S", doc.name("JavaScript")), ("JS", doc.text("AFSimple_Calculate(\"SUM\", new Array (\"A\"));"))])
            w.set("AA", doc.dict([("C", c)]))
            fields.replace(at: i, with: parent)
            acro.set("CO", doc.array([parent]))
        }
        func t(_ b: [UInt8]) throws -> DesignField { try #require(FormDesign.read(b, nil).first { $0.name == "T" }) }
        func scripts(_ b: [UInt8]) throws -> Int {
            try PdfEdit.openToRead(b, nil).allObjects().filter { $0.dict("AA")?.dict("C") != nil }.count
        }
        #expect(try t(pdf).calculation == FieldCalc(.sum, ["A"]))

        // Another property changed: the script stays on the widget, not copied to the field.
        let renamed = try FormDesign.update(pdf, nil, [try t(pdf).with { $0.tooltip = "Total" }])
        #expect(try t(renamed).calculation == FieldCalc(.sum, ["A"]))
        #expect(try scripts(renamed) == 1)

        // Changed where it is, then removed there (and from the order).
        let avg = try FormDesign.update(renamed, nil, [try t(renamed).with { $0.calculation = FieldCalc(.average, ["A"]) }])
        #expect(try t(avg).calculation?.kind == .average)
        #expect(try scripts(avg) == 1)
        let none = try FormDesign.update(avg, nil, [try t(avg).with { $0.calculation = nil }])
        #expect(try t(none).calculation == nil)
        #expect(try scripts(none) == 0)
        #expect(try FormDesign.calculationOrder(none, nil).isEmpty)
    }

    @Test func guidesFollowTheirPagesAndGoWithAPageThatChanged() throws {
        let pdf = TestPdf.make(3)
        let keys = try PageGuides.keys(pdf, nil)
        #expect(Set(keys).count == 3)
        let guides = PageGuides()
        guides.add(Guide(0, .x, 100), 612, 792)
        guides.add(Guide(2, .y, 300), 612, 792)

        // A comment changes nothing; a move takes the guides along.
        let noted = try Annotations.addNote(pdf, nil, 0, 100, 100, "note", author: "me")
        #expect(try PageGuides.keys(noted, nil) == keys)
        let moved = try PageEditor.reorder(noted, nil, [2, 0, 1])
        #expect(guides.remap(keys, try PageGuides.keys(moved, nil)) == 0)
        #expect(guides.all.map(\.page) == [1, 0] && guides.all.map(\.axis) == [.x, .y])

        // A turned page takes its guides with it; the other's stay.
        let before = try PageGuides.keys(moved, nil)
        let turned = try PageEditor.rotate(moved, nil, [1], 90)
        #expect(guides.remap(before, try PageGuides.keys(turned, nil)) == 1)
        #expect(guides.all.map(\.page) == [0] && guides.all.map(\.axis) == [.y])
    }
}
