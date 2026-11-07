import Foundation
import Testing
@testable import PdfCore

/// Ported from RealFormTraitTests.cs: traits of real forms the forms corpus (pdf/tools/forms-corpus, mac/tools/forms-corpus)
/// found Inkvolt mishandling, each in a small made-up form.
struct RealFormTraitTests {
    private static let helv = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    private static let zaDb = "<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>"

    /// Objects 1-5 (catalog, pages, page, Helvetica, ZapfDingbats) and then `objects` from 6.
    private func doc(_ fields: String, _ annots: String, _ objects: [String], acroExtra: String = "") -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(fields)] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R /ZaDb 5 0 R >> >> \(acroExtra) >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [\(annots)] /Resources << >> >>",
            Self.helv, Self.zaDb,
        ] + objects)
    }

    private func widget(_ extra: String) -> String { "<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R \(extra) >>" }

    /// The last object named `name`, from every object in the file.
    private func lastNamed(_ d: MuDoc, _ name: String) -> PObj? {
        for n in (1..<max(d.objectCount, 1)).reversed() {
            let o = d.object(n)
            if o.isDict, o.text("T") == name { return o }
        }
        return nil
    }

    // MARK: Widgets their parent doesn't list in /Kids (pdfjs-opt_demo, qpdf-form-errors)

    @Test func aWidgetJoinsItsParentFieldEvenWhenKidsLeavesItOut() throws {
        // veg (8) has no /Kids; its widgets are listed in /Fields and on the page. r2 (9) lists one of its two widgets.
        // r1 (14) has a named kid (a field of its own, r1.choice1) and two nameless ones: its own widgets (qpdf's
        // form-document-defaults).
        func ap(_ s: String) -> String { "/AP << /N << /\(s) 11 0 R /Off 12 0 R >> >> /MK << /CA (l) >>" }
        let data = doc("6 0 R 7 0 R 9 0 R 14 0 R", "6 0 R 7 0 R 10 0 R 13 0 R 15 0 R 16 0 R 17 0 R", [
            widget("/Parent 8 0 R /Rect [72 700 90 718] /AS /Off " + ap("0")),
            widget("/Parent 8 0 R /Rect [72 670 90 688] /AS /1 " + ap("1")),
            "<< /FT /Btn /Ff 49152 /T (veg) /V /1 /Opt [(Carrot) (Potato)] >>",
            "<< /FT /Btn /Ff 49152 /T (r2) /V /Off /Kids [10 0 R] >>",
            widget("/Parent 9 0 R /Rect [200 700 218 718] /AS /Off " + ap("a")),
            Core2Pdf.stream("0 g 4 4 10 10 re f", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            widget("/Parent 9 0 R /Rect [200 670 218 688] /AS /Off " + ap("b")),
            "<< /FT /Btn /Ff 49152 /T (r1) /V /1 /Kids [15 0 R 16 0 R 17 0 R] >>",
            widget("/Parent 14 0 R /T (choice1) /Rect [300 700 318 718] /AS /1 " + ap("1")),
            widget("/Parent 14 0 R /Rect [300 670 318 688] /AS /Off " + ap("2")),
            widget("/Parent 14 0 R /Rect [300 640 318 658] /AS /Off " + ap("3")),
        ])

        let widgets = try FormEditor.read(data, nil)
        #expect(widgets.map(\.fieldName).sorted() == ["r1", "r1", "r1.choice1", "r2", "r2", "veg", "veg"])
        #expect(widgets.filter { $0.fieldName == "r1" }.compactMap(\.onState) == ["2", "3"])
        #expect(widgets.filter { $0.fieldName == "veg" }.compactMap(\.onState) == ["0", "1"])
        #expect(widgets.filter { $0.fieldName == "r2" }.compactMap(\.onState).sorted() == ["a", "b"])
        #expect(try !FormEditor.dataFields(data, nil).contains { $0.name.hasPrefix("field") })

        let saved = try FormEditor.fill(data, nil, ["veg": "0", "r2": "b", "r1": "3"]).data
        let check = try Core2Pdf.open(saved)
        #expect(lastNamed(check, "r1")?.name("V") == "3")
        let after = try FormEditor.read(saved, nil)
        func shown(_ name: String) -> [String] {
            after.filter { $0.fieldName == name }.map { $0.value == $0.onState ? $0.onState ?? "" : "Off" }
        }
        #expect(shown("veg") == ["0", "Off"])
        #expect(shown("r2").sorted() == ["Off", "b"])
        #expect(lastNamed(check, "veg")?.name("V") == "0")
        #expect(lastNamed(check, "r2")?.name("V") == "b")
    }

    @Test func aFieldReachedThroughItsWidgetsListsEachWidgetOnce() throws {
        // /Fields leaves out "name" (6), whose /Kids lists both its nameless widgets (7, 8), found only on the page: the
        // first walks the field's tree, which reaches both, and neither is added to the field again.
        let data = doc("9 0 R", "7 0 R 8 0 R 9 0 R", [
            "<< /FT /Tx /T (name) /V (Ann) /DA (/Helv 12 Tf 0 g) /Kids [7 0 R 8 0 R] >>",
            widget("/Parent 6 0 R /Rect [72 700 272 720]"),
            widget("/Parent 6 0 R /Rect [72 650 272 670]"),
            widget("/FT /Tx /T (other) /Rect [72 600 272 620] /DA (/Helv 12 Tf 0 g)"),
        ])
        let widgets = try FormEditor.read(data, nil)
        #expect(widgets.map(\.fieldName).sorted() == ["name", "name", "other"])
        #expect(Set(widgets.filter { $0.fieldName == "name" }.map(\.annotIndex)).count == 2)
        let d = try Core2Pdf.open(data)
        let fields = try FormEditor.collect(d, d.catalog.dict("AcroForm"))
        #expect(fields.first { $0.name == "name" }?.widgets.count == 2)
    }

    @Test func aNamelessWidgetListedInFieldsIsNamedAfterItsOwnPage() throws {
        // A widget listed in /Fields whose parent (no name of its own) doesn't list it: named after the page it is on.
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R 7 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> >>",
            Self.helv,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [7 0 R] /Resources << >> >>",
            "<< /FT /Tx /DA (/Helv 12 Tf 0 g) /Kids [] >>",
            "<< /Type /Annot /Subtype /Widget /F 4 /P 5 0 R /Parent 6 0 R /Rect [72 700 272 720] >>",
        ])
        let widgets = try FormEditor.read(data, nil)
        #expect(widgets.count == 1)
        #expect(widgets.first?.pageIndex == 1)
        #expect(widgets.first?.fieldName == "field1_p2")
    }

    // MARK: A choice field's widgets with their own /I (pdflib-fancy_fields)

    @Test func aChoiceFieldsWidgetsDontKeepTheirOldSelection() throws {
        let data = doc("6 0 R", "7 0 R 8 0 R", [
            "<< /FT /Ch /Ff 131072 /T (gundam) /Opt [(Exia) (Kyrios) (Virtue) (Dynames)] /V (Dynames) /I [3] /DA (/Helv 12 Tf 0 g) /Kids [7 0 R 8 0 R] >>",
            widget("/Parent 6 0 R /Rect [72 700 172 720] /I [3] /V (Dynames)"),
            widget("/Parent 6 0 R /Rect [72 650 172 670] /I [3]"),
        ])
        let saved = try FormEditor.fill(data, nil, ["gundam": "Kyrios"]).data
        let d = try Core2Pdf.open(saved)
        #expect(lastNamed(d, "gundam")?.array("I")?.elements.compactMap(\.int) == [1])
        let widgets = d.page(0).array("Annots")?.elements ?? []
        #expect(widgets.count == 2)
        for w in widgets {
            #expect(w.array("I") == nil || w.array("I")?.elements.compactMap(\.int) == [1])
            #expect(w["V"] == nil || w.text("V") == "Kyrios")
        }
    }

    // MARK: Check box faces (pdfjs-checkbox_no_appearance, pypdf-pdflatex-forms)

    @Test(arguments: [
        "", // no appearance and no /MK at all
        "/AP << /N << /Yes << >> >> >> /MK << /BC [1 0 0] /BG [1 1 1] /CA (4) >> /DA (/ZaDb 10 Tf 0 0 0 rg)", // pdfTeX: the on face isn't a stream
        "/AP << /N << /Yes 7 0 R /Off 7 0 R >> >>", // the on face is an empty stream
    ])
    func aTickedCheckBoxGetsATickItCanShow(extra: String) throws {
        let data = doc("6 0 R", "6 0 R", [
            widget("/FT /Btn /T (cb) /Rect [100 600 140 640] /V /Off /AS /Off \(extra)"),
            Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 40 40]"),
        ])
        let box = try #require(try FormEditor.read(data, nil).first)
        let saved = try FormEditor.fill(data, nil, ["cb": try #require(box.onState)]).data
        #expect(!latin1(saved).contains("/NeedAppearances true"))
        let on = try Core2Pdf.ink(saved, 0, box.rect)
        #expect(on > 0.05, "the tick shows")
        let off = try FormEditor.fill(saved, nil, ["cb": "Off"]).data
        #expect(try Core2Pdf.ink(off, 0, box.rect) < on - 0.04, "and goes when unticked (the border stays)")
    }

    @Test func aCheckBoxsOwnFaceIsKeptWhateverItsMK() throws {
        // One face that draws (a filled square), with a border colour in /MK: kept as the on face, never redrawn as the
        // default tick; the off face it lacks is drawn from /MK (the border).
        let data = doc("6 0 R", "6 0 R", [
            widget("/FT /Btn /T (cb) /Rect [100 600 140 640] /V /Off /AS /Off /AP << /N 7 0 R >> /MK << /BC [0 0 1] >>"),
            Core2Pdf.stream("0 g 10 10 20 20 re f", "/Type /XObject /Subtype /Form /BBox [0 0 40 40]"),
        ])
        let saved = try FormEditor.fill(data, nil, ["cb": "Yes"]).data
        #expect(try face(saved, "cb", "N", "Yes") == "0 g 10 10 20 20 re f")
        let off = try face(saved, "cb", "N", "Off")
        #expect(off.contains("0 0 1 RG"))
        #expect(!off.contains("10 10 20 20"))
    }

    @Test func onlyACheckBoxsEmptyFaceIsRedrawnInItsOwnStyle() throws {
        // The on face is empty (the off face draws a border): the on face alone is drawn again, with /MK /CA's cross
        // (ZapfDingbats 8), not the default tick; the off face and the down faces stay as they are.
        let data = doc("6 0 R", "6 0 R", [
            widget("/FT /Btn /T (cb) /Rect [100 600 140 640] /V /Off /AS /Off /MK << /CA (8) >> /AP << /N << /Yes 7 0 R /Off 8 0 R >> /D << /Yes 8 0 R /Off 8 0 R >> >>"),
            Core2Pdf.stream(" \n", "/Type /XObject /Subtype /Form /BBox [0 0 40 40]"),
            Core2Pdf.stream("0 0 1 RG 1 1 38 38 re S", "/Type /XObject /Subtype /Form /BBox [0 0 40 40]"),
        ])
        let saved = try FormEditor.fill(data, nil, ["cb": "Yes"]).data
        let on = try face(saved, "cb", "N", "Yes")
        #expect(on.range(of: #"m [\d. ]+ l [\d. ]+ m [\d. ]+ l S"#, options: .regularExpression) != nil) // the cross's two strokes
        #expect(!on.contains("1 j")) // not the tick
        #expect(try face(saved, "cb", "N", "Off") == "0 0 1 RG 1 1 38 38 re S")
        #expect(try face(saved, "cb", "D", "Yes") == "0 0 1 RG 1 1 38 38 re S")
        #expect(try Core2Pdf.ink(saved, 0, RectD(100, 152, 40, 40)) > 0.05, "the cross shows")
    }

    @Test(arguments: [
        ("(u)", "h f"), // a diamond
        ("(n )", " re f Q"), // a square: the first character of a longer caption
    ])
    func aCheckBoxWithoutAFaceIsDrawnInTheStyleItsMKAsks(ca: String, drawn: String) throws {
        let data = doc("6 0 R", "6 0 R", [widget("/FT /Btn /T (cb) /Rect [100 600 140 640] /V /Off /AS /Off /MK << /CA \(ca) >>")])
        let saved = try FormEditor.fill(data, nil, ["cb": "Yes"]).data
        let on = try face(saved, "cb", "N", "Yes")
        #expect(on.contains(drawn))
        #expect(!on.contains("1 j"))
    }

    /// The content of a check box's face (/N or /D, the state's), "" when empty.
    private func face(_ data: [UInt8], _ name: String, _ kind: String, _ state: String) throws -> String {
        let d = try Core2Pdf.open(data)
        let w = try #require(lastNamed(d, name))
        let faces = try #require(w.dict("AP")?.dict(kind))
        let stream = try #require(faces[state]?.streamData)
        return latin1(stream).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: One widget on several pages (qpdf-form-fields-and-annotations-shared)

    @Test func aWidgetSharedByTwoPagesIsOnBoth() throws {
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 6 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] /Resources << >> >>",
            widget("/FT /Tx /T (shared) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /V (x)"),
            Self.helv,
        ])
        #expect(try FormEditor.read(data, nil).map(\.pageIndex) == [0, 1])
    }

    // MARK: A kid widget without /Parent (qpdf-form-document-defaults: MuPDF didn't show its value)

    @Test func aKidWidgetWithoutParentGetsItSoEveryViewerShowsItsValue() throws {
        let data = doc("6 0 R", "7 0 R", [
            "<< /FT /Tx /T (Text Box 1) /DA (0 g /Helv 12 Tf) /V () /Kids [7 0 R] >>",
            widget("/Rect [72 700 300 720]"),
        ])
        let saved = try FormEditor.fill(data, nil, ["Text Box 1": "Filled kid"]).data
        #expect(try Core2Pdf.allText(saved).contains("Filled kid"))
    }

    // MARK: Calculations (pdfjs-issue15753)

    @Test func aCalculationThatSetsItsOwnFieldThroughGetFieldKeepsTheValue() throws {
        let data = doc("6 0 R 7 0 R", "6 0 R 7 0 R", [
            widget("/FT /Tx /T (Field1) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g)"),
            widget("/FT /Tx /T (Field2) /Rect [72 650 300 670] /DA (/Helv 12 Tf 0 g) /AA << /C << /S /JavaScript /JS (var field1 = this.getField\\(\"Field1\"\\); var field2 = this.getField\\(\"Field2\"\\); field2.value = field1.value;) >> >>"),
        ], acroExtra: "/CO [7 0 R]")
        let saved = try FormEditor.fill(data, nil, ["Field1": "Copied"]).data
        #expect(try FormEditor.read(saved, nil).first { $0.fieldName == "Field2" }?.value == "Copied")
    }

    @Test func calculationsHaveAcrobatsSimpleAndExtractNumsHelpers() throws {
        let script = "var n = AFExtractNums\\(this.getField\\('in'\\).value\\); event.value = AFSimple\\('SUM', n[0], n[1]\\) + AFSimple\\('MAX', 2, 9\\) + AFSimple\\('PRD', 2, 3\\) + AFSimple\\('AVG', 4, 6\\) + AFSimple\\('XYZ', 7, 100\\);"
        let data = doc("6 0 R 7 0 R", "6 0 R 7 0 R", [
            widget("/FT /Tx /T (in) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g)"),
            widget("/FT /Tx /T (out) /Rect [72 650 300 670] /DA (/Helv 12 Tf 0 g) /AA << /C << /S /JavaScript /JS (\(script)) >> >>"),
        ], acroExtra: "/CO [7 0 R]")
        let saved = try FormEditor.fill(data, nil, ["in": "(555) 1234"]).data
        // 555 + 1234 + 9 + 6, then AVG's sum (AFSimple_Calculate divides it afterwards) and an unknown operation's first value.
        #expect(try FormEditor.read(saved, nil).first { $0.fieldName == "out" }?.value == "1821")
    }

    // MARK: Masked fields (ca-ftb-540)

    /// ca-ftb-540's SSN field: AFSpecial with a MaxLen of its digits. Typed as the page view types (each edit's verdict
    /// applied within MaxLen), the digits all fit: the dashes are the format's, as in Acrobat.
    @Test(arguments: [
        (3, 9, "123456789", "123-45-6789"),
        (1, 9, "123456789", "12345-6789"),
        (2, 10, "5551234567", "(555) 123-4567"),
        (0, 5, "12345", "12345"),
    ])
    func specialFieldsTakeTheirDigitsWithinMaxLenAndShowTheFormat(psf: Int, maxLen: Int, typed: String, shown: String) throws {
        let data = Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (f) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /MaxLen \(maxLen) /F 4 /P 3 0 R /AA << /K << /S /JavaScript /JS (AFSpecial_Keystroke\\(\(psf)\\);) >> /F << /S /JavaScript /JS (AFSpecial_Format\\(\(psf)\\);) >> >> >>",
        ])
        let keys = try #require(FieldKeystrokes.open(data, nil, "f"))
        var value = ""
        for c in typed {
            let r = FieldKeystrokes.typed(before: value, after: value + String(c), maxLength: maxLen, keys)
            #expect(!r.refused, "\(c) after \(value)")
            value = r.text
        }
        #expect(value == typed)
        let result = try FormEditor.fill(data, nil, ["f": value])
        #expect(result.rejected.isEmpty)
        let w = try #require(try FormEditor.read(result.data, nil).first)
        #expect(w.value == typed)
        #expect(w.displayValue == shown)
        #expect(try Core2Pdf.allText(result.data).contains(shown))
    }

    /// Comb cells for the digits alone: the format's dashes would push the last digits out of the cells, and they would
    /// never be drawn. The cells show what was typed.
    @Test func aFormattedCombFieldDrawsEveryDigit() throws {
        let data = Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (f) /Ff \(1 << 24) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /MaxLen 9 /F 4 /P 3 0 R /AA << /K << /S /JavaScript /JS (AFSpecial_Keystroke\\(3\\);) >> /F << /S /JavaScript /JS (AFSpecial_Format\\(3\\);) >> >> >>",
        ])
        let saved = try FormEditor.fill(data, nil, ["f": "123456789"]).data
        let d = try Core2Pdf.open(saved)
        let face = try #require(d.page(0).array("Annots")?.elements.first?.dict("AP")?["N"]?.streamData)
        let text = latin1(face)
        let cells = try NSRegularExpression(pattern: #"\((.)\) Tj"#).matches(in: text, range: NSRange(text.startIndex..., in: text))
        let digits: [String] = cells.compactMap { cell in
            guard let r = Range(cell.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        #expect(digits.joined() == "123456789")
        #expect(try FormEditor.read(saved, nil).first?.displayValue == "123-45-6789")
    }

    // MARK: Tab order across a fill

    /// A page box that comes back rounded (A4's 841.89) must not move a widget to another line: Tab keeps its order.
    @Test func tabKeepsItsOrderAcrossAFillOnARoundedPageBox() throws {
        var fields: [String] = []
        for i in 0..<30 {
            let y = 841.89 - 20 - Double(i) * 5.999
            fields.append("<< /Type /Annot /Subtype /Widget /FT /Tx /T (f\(i)) /Rect [\(72 + (i % 3) * 120) \(y) \(180 + (i % 3) * 120) \(y + 5)] /DA (/Helv 4 Tf 0 g) /F 4 /P 3 0 R >>")
        }
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(fields.indices.map { "\(5 + $0) 0 R" }.joined(separator: " "))] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.27563 841.88977] /Annots [\(fields.indices.map { "\(5 + $0) 0 R" }.joined(separator: " "))] /Resources << >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ] + fields)
        let before = try FormEditor.read(data, nil).map(\.fieldName)
        let saved = try FormEditor.fill(data, nil, ["f3": "x"]).data
        #expect(try FormEditor.read(saved, nil).map(\.fieldName) == before)
    }
}
