import Foundation
import Testing
@testable import PdfCore

/// Ported from FormAppearanceTests.cs: filled forms show their values from their own appearance streams, without
/// /NeedAppearances (pdf.js and poppler redraw every field when it is set, losing formats and list and check box looks),
/// and check boxes with a single-stream appearance get proper on and off states. Adapted: the two tests that build
/// their forms with FormDesign (form design isn't in 1.0) write the same fields by hand:
/// EveryKindOfFieldIsFilledWithItsOwnAppearance… (a number-formatted text field, a combo box, a list box, a check box
/// drawn from its /MK, a radio pair and a signature field) and CheckMarksAreDrawnAsPaths… (a check box whose faces are
/// drawn from its /MK when it is filled).
struct FormAppearanceTests {
    static func needAppearances(_ pdf: [UInt8]) throws -> Bool {
        try Core2Pdf.open(pdf).catalog.dict("AcroForm")?["NeedAppearances"]?.bool == true
    }

    static func annot(_ doc: MuDoc, _ i: Int) throws -> PObj { try #require(doc.page(0).array("Annots")?[i]) }

    @Test func everyKindOfFieldIsFilledWithItsOwnAppearanceAndNoNeedAppearances() throws {
        let w = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R"
        let form = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 12 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R 7 0 R 8 0 R 10 0 R 11 0 R 12 0 R] /Resources << >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< \(w) /FT /Tx /T (Amount) /Rect [72 670 222 692] /DA (/Helv 0 Tf 0 g) /MK << /BC [0] >> /AA << /F << /S /JavaScript /JS (AFNumber_Format\\(2, 0, 0, 0, \"\", true\\);) >> >> >>",
            "<< \(w) /FT /Ch /Ff 131072 /T (Color) /Opt [(Red) (Green)] /Rect [72 630 222 652] /DA (/Helv 0 Tf 0 g) /MK << /BC [0] >> >>",
            "<< \(w) /FT /Ch /T (Fruit) /Opt [(Apple) (Banana) (Cherry)] /Rect [72 552 222 612] /DA (/Helv 0 Tf 0 g) /MK << /BC [0] >> >>",
            "<< \(w) /FT /Btn /T (Agree) /V /Off /Rect [72 518 86 532] /DA (/ZaDb 0 Tf 0 g) /MK << /BC [0] /CA (4) >> >>",
            "<< /FT /Btn /Ff 49152 /T (Pick) /V /Off /Kids [10 0 R 11 0 R] >>",
            "<< \(w) /Parent 9 0 R /Rect [72 488 86 502] /AS /Off /MK << /BC [0] >> /AP << /N << /A 13 0 R /Off 13 0 R >> >> >>",
            "<< \(w) /Parent 9 0 R /Rect [100 488 114 502] /AS /Off /MK << /BC [0] >> /AP << /N << /B 13 0 R /Off 13 0 R >> >> >>",
            "<< \(w) /FT /Sig /T (Sign) /Rect [72 450 222 472] /AP << /N 14 0 R >> >>",
            Core2Pdf.stream("0 0 14 14 re f", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
            Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 150 22]"),
        ])
        let result = try filled(form, ["Amount": "1234.5", "Color": "Green", "Fruit": "Banana", "Agree": "Yes", "Pick": "B"])
        #expect(try !Self.needAppearances(result))
        let text = try Core2Pdf.allText(result)
        #expect(text.contains("1,234.50"))
        #expect(text.contains("Green"))
        #expect(text.contains("Banana"))
        let doc = try Core2Pdf.open(result)
        for i in 0..<7 {
            let a = try Self.annot(doc, i)
            let normal = try #require(a.dict("AP")?["N"], "widget \(i)")
            // A check box or radio shows a state its normal appearance has.
            if let shown = a.name("AS"), shown != "Off" { #expect(normal.has(shown), "\(shown)") }
        }
        #expect(try Self.annot(doc, 3).name("AS") == "Yes")
        #expect(try Self.annot(doc, 5).name("AS") == "B")
        #expect(try Self.annot(doc, 4).name("AS") == "Off")
    }

    @Test func aFormWhoseProducerAskedForNeedAppearancesGetsItsAppearancesBuilt() throws {
        // Fields with values but no appearances: the producer left drawing them to the viewer.
        let form = Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [72 700 272 720] /P 3 0 R /DA (/Helv 0 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (b) /V (Kept value) /Rect [72 660 272 680] /P 3 0 R /DA (/Helv 0 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (c) /V /Off /Rect [72 620 86 634] /P 3 0 R /MK << /BC [0] /CA (4) >> /DA (/ZaDb 0 Tf 0 g) >>",
        ], acroExtra: "/NeedAppearances true")
        let result = try filled(form, ["a": "New value", "c": "Yes"])
        #expect(try !Self.needAppearances(result))
        let strict = try Core2Pdf.allText(result)
        #expect(strict.contains("New value"))
        #expect(strict.contains("Kept value")) // the untouched field shows too
        #expect(try Core2Pdf.ink(result, 0, RectD(74, 160, 10, 10)) > 0.1, "the check box shows its check")

        // A check box with no appearance and no /MK to draw one from keeps NeedAppearances, so viewers still try.
        let broken = Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [72 700 272 720] /P 3 0 R /DA (/Helv 0 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (c) /V /Off /Rect [72 620 86 634] /P 3 0 R >>",
        ], acroExtra: "/NeedAppearances true")
        #expect(try Self.needAppearances(filled(broken, ["a": "x"])))
    }

    @Test func aCheckBoxWithASingleAppearanceStreamGetsOnAndOffStates() throws {
        // As some producers write it: /N is one stream (the checked look); only /D is a state dictionary.
        let form = Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) /V /Off /AS /Off /Rect [72 600 86 614] /P 3 0 R /DA (/ZaDb 0 Tf 0 g) /MK << /BC [0] /CA (4) >> /AP << /N 8 0 R /D << /Off 9 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Plain) /V /Off /Rect [72 560 86 574] /P 3 0 R /AP << /N 10 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V (x) /Rect [72 500 272 520] /P 3 0 R /DA (/Helv 0 Tf 0 g) /AP << /N 11 0 R >> >>",
        ], more: [
            Core2Pdf.stream("q 0 G 0.5 0.5 13 13 re S Q BT 0 g /ZaDb 10 Tf 2 3 Td (4) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 14 14] /Resources << >>"),
            Core2Pdf.stream("q 0.75 g 0 0 14 14 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
            Core2Pdf.stream("0 0 14 14 re f", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
            Core2Pdf.stream("BT /Helv 12 Tf 2 4 Td (x) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 200 20]"),
        ])
        let widgets = try FormEditor.read(form, nil)
        #expect(widgets.first { $0.fieldName == "Agree" }?.onState == "Yes") // never "BBox" or "Resources"
        #expect(widgets.first { $0.fieldName == "Plain" }?.onState == "Yes")
        #expect(widgets.first { $0.fieldName == "Name" }?.onState == nil)

        let off = try Core2Pdf.ink(form, 0, RectD(75, 180, 8, 8))
        let on = try filled(form, ["Agree": "Yes", "Plain": "Yes"])
        #expect(try !Self.needAppearances(on))
        let doc = try Core2Pdf.open(on)
        let agree = try #require(Core2Pdf.field(doc, "Agree"))
        #expect(agree.name("V") == "Yes")
        #expect(agree.name("AS") == "Yes")
        let states = try #require(agree.dict("AP")?.dict("N"))
        #expect(!states.isStream)
        #expect(states.has("Yes") && states.has("Off"))
        // Without /MK the single face is kept as the "on" look.
        let plain = try #require(Core2Pdf.field(doc, "Plain")?.dict("AP")?.dict("N"))
        #expect(plain.keys.sorted() == ["Off", "Yes"])
        #expect(try Core2Pdf.ink(on, 0, RectD(75, 180, 8, 8)) > off)
        let cleared = try filled(on, ["Agree": "Off"])
        #expect(try FormEditor.read(cleared, nil).first { $0.fieldName == "Agree" }?.value == "Off")

        // With an /Opt, the state names are positions, as Acrobat writes them.
        let withOpt = Core2Pdf.form([
            "<< /FT /Btn /Ff 49152 /T (Size) /V /Off /Opt [(Small) (Large)] /Kids [6 0 R 7 0 R] >>",
        ], more: [
            "<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [72 600 86 614] /P 3 0 R /AP << /N 8 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 5 0 R /Rect [100 600 114 614] /P 3 0 R /AP << /N 8 0 R >> >>",
            Core2Pdf.stream("0 0 14 14 re f", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
        ], extraAnnots: "6 0 R 7 0 R")
        #expect(try FormEditor.read(withOpt, nil).map(\.onState) == ["0", "1"])
        let large = try filled(withOpt, ["Size": "Large"])
        #expect(try FormEditor.read(large, nil).first?.value == "1")
    }

    @Test func checkMarksAreDrawnAsPathsSoViewersWithoutZapfDingbatsShowThem() throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Btn /T (Agree) /V /Off /Rect [72 678 86 692] /P 3 0 R /MK << /BC [0] >> >>"])
        let doc = try Core2Pdf.open(filled(form, ["Agree": "Yes"]))
        let states = try #require(try Self.annot(doc, 0).dict("AP")?.dict("N"))
        let on = latin1(try #require(states.dict("Yes")?.streamData))
        #expect(!on.contains("Tf"))
        #expect(on.contains(" l S"))
    }
}
