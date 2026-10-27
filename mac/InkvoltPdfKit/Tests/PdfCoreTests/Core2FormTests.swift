import Foundation
import Testing
@testable import PdfCore

/// |a - b| within one unit of the `decimals`-th decimal place (xUnit's Assert.Equal with a precision).
func near(_ a: Double, _ b: Double, _ decimals: Int) -> Bool { abs(a - b) <= pow(10, -Double(decimals)) }

/// Ported from Core2FormTests.cs, whole. The PDFsharp object checks read the same objects through MuPDF (`PObj`).
struct Core2FormTests {
    static let w = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R"

    static func textForm(_ extra: String = "", rect: String = "72 700 300 720", da: String = "/Helv 12 Tf 0 g") -> [UInt8] {
        Core2Pdf.form(["<< \(w) /FT /Tx /T (name) /Rect [\(rect)] /DA (\(da)) \(extra) >>"])
    }

    @Test func hostileFieldSettingsStayCheapAndWriteAValidStream() throws {
        // A comb field claiming a billion cells, a NaN font size and a broken format script.
        let data = Self.textForm("/Ff 16777216 /MaxLen 1000000000 /MK << /BC [0 0 0] >> /AA << /F << /S /JavaScript /JS (AFNumber_Format\\(1.2.3, 0\\);) >> >>",
                                 da: "/Helv NaN Tf 0 g")
        let result = try filled(data, ["name": "12345"])
        #expect(try Core2Pdf.allText(Core2Pdf.withoutNeedAppearances(result)).contains("12345"))

        // One unbroken multiline value much wider than the box: wrapped in linear time.
        let multi = Self.textForm("/Ff 4096", rect: "72 500 200 720")
        let start = Date()
        _ = try filled(multi, ["name": String(repeating: "W", count: 20_000)])
        #expect(Date().timeIntervalSince(start) < 20)
    }

    @Test func fillingWritesAnAppearanceStreamThatViewersUseWithoutNeedAppearances() throws {
        let result = try filled(Self.textForm(), ["name": "Bob Builder"])
        let doc = try Core2Pdf.open(result)
        let field = try #require(Core2Pdf.field(doc, "name"))
        #expect(field.dict("AP")?["N"] != nil)
        // Built: no NeedAppearances, so pdf.js and poppler show this appearance instead of drawing their own.
        #expect(doc.catalog.dict("AcroForm")?["NeedAppearances"]?.bool != true)
        let strict = try Core2Pdf.withoutNeedAppearances(result)
        #expect(try Core2Pdf.allText(strict).contains("Bob Builder"))
        #expect(try Core2Pdf.ink(strict, 0, RectD(72, 72, 228, 20)) > 0.02)
    }

    @Test func nonLatinTextIsDrawnWithAnEmbeddedUnicodeFont() throws {
        let value = "Ωμέγα Привет 你好"
        let result = try Core2Pdf.withoutNeedAppearances(filled(Self.textForm(), ["name": value]))
        let text = try Core2Pdf.allText(result)
        #expect(text.contains("Ωμέγα"))
        #expect(text.contains("Привет"))
        #expect(text.contains("你好"))
        #expect(try FormEditor.read(result, nil).first?.value == value)
    }

    @Test func combFieldsPutOneCharacterPerCell() throws {
        // 100 pt wide, MaxLen 5 → 20 pt cells starting at x = 72.
        let form = Self.textForm("/Ff 16777216 /MaxLen 5", rect: "72 700 172 720", da: "/Helv 0 Tf 0 g")
        let result = try Core2Pdf.withoutNeedAppearances(filled(form, ["name": "12345"]))
        let chars = try Core2Pdf.lines(result).flatMap(\.chars).filter { $0.ch.first?.isNumber == true }
        try #require(chars.count == 5)
        for i in 0..<5 { #expect(near(chars[i].box.centerX, Double(72 + 20 * i + 10), 2), "\(chars[i].box.centerX)") }
    }

    @Test func centeredAndMultilineTextIsLaidOut() throws {
        let centered = try Core2Pdf.withoutNeedAppearances(filled(Self.textForm("/Q 1"), ["name": "Mid"]))
        let line = try #require(try Core2Pdf.lines(centered).first { $0.text.contains("Mid") })
        #expect(near(line.box.centerX, 72 + 228 / 2.0, 1), "\(line.box.centerX)")

        let multi = Self.textForm("/Ff 4096", rect: "72 600 200 720", da: "/Helv 0 Tf 0 g")
        let long = "The quick brown fox jumps over the lazy dog and keeps running far away"
        let wrapped = try Core2Pdf.withoutNeedAppearances(filled(multi, ["name": long]))
        let lines = try Core2Pdf.lines(wrapped).filter { $0.box.y >= 72 && $0.box.bottom <= 192 }
        #expect(lines.count >= 3, "expected wrapped lines, got \(lines.count)")
        for l in lines { #expect(l.box.right <= 200 + 1, "line overflows: \(l.text)") }
    }

    @Test func widgetRotationTurnsTheText() throws {
        let form = Self.textForm("/MK << /R 90 /BC [0 0 1] /BG [1 1 0.8] >>", rect: "72 500 92 700")
        let result = try Core2Pdf.withoutNeedAppearances(filled(form, ["name": "VERTICAL"]))
        let line = try #require(try Core2Pdf.lines(result).first { $0.text.contains("VERTICAL") })
        #expect(line.box.height > line.box.width * 2, "text should run vertically: \(line.box)")
    }

    @Test func fillingRemovesXfaAndRichValues() throws {
        let form = Core2Pdf.form(["<< \(Self.w) /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /RV (<body>old</body>) >>"],
                                 acroExtra: "/XFA 6 0 R", more: [Core2Pdf.stream("<xdp:xdp/>")])
        #expect(try FormEditor.hasXfa(form, nil) == (true, false))
        let result = try filled(form, ["name": "New"])
        #expect(try FormEditor.hasXfa(result, nil) == (false, false))
        #expect(try Core2Pdf.field(Core2Pdf.open(result), "name")?.has("RV") == false)

        let xfaOnly = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [] /XFA 4 0 R >> /NeedsRendering true >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            Core2Pdf.stream("<xdp:xdp/>"),
        ])
        #expect(try FormEditor.hasXfa(xfaOnly, nil) == (true, true))
        #expect(try FormEditor.hasXfa(TestPdf.make(1), nil) == (false, false))
    }

    @Test func choiceFieldsWithLabelsAndMultiSelect() throws {
        let form = Core2Pdf.form([
            "<< \(Self.w) /FT /Ch /Ff 2097152 /T (sizes) /Opt [[(s) (Small)] [(m) (Medium)] [(l) (Large)]] /Rect [72 600 200 660] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(Self.w) /FT /Ch /Ff 131072 /T (combo) /Opt [[(us) (United States)] [(pr) (Puerto Rico)]] /Rect [72 500 250 520] /DA (/Helv 10 Tf 0 g) >>",
        ])
        let sizes = try #require(try FormEditor.read(form, nil).first { $0.fieldName == "sizes" })
        #expect(sizes.multiSelect)
        #expect(sizes.options == ["s", "m", "l"])
        #expect(sizes.optionLabels == ["Small", "Medium", "Large"])

        let result = try filled(form, ["sizes": "l\ns", "combo": "Puerto Rico"])
        let read = try FormEditor.read(result, nil)
        #expect(read.first { $0.fieldName == "sizes" }?.value == "s\nl") // stored in option order
        #expect(read.first { $0.fieldName == "combo" }?.value == "pr")
        let f = try #require(Core2Pdf.field(Core2Pdf.open(result), "sizes"))
        #expect(f.array("V")?.count == 2)
        #expect(f.array("I")?.elements.map { $0.int ?? -1 } == [0, 2])
        let text = try Core2Pdf.allText(Core2Pdf.withoutNeedAppearances(result))
        #expect(text.contains("Puerto Rico")) // the combo shows the display text
        #expect(text.contains("Small")) // the list box shows its items
    }

    @Test func calculationsAndFormatsRunAfterFilling() throws {
        let form = Core2Pdf.form([
            "<< \(Self.w) /FT /Tx /T (a) /Rect [72 700 200 720] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(Self.w) /FT /Tx /T (b) /Rect [72 670 200 690] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(Self.w) /FT /Tx /Ff 1 /T (total) /Rect [72 640 200 660] /DA (/Helv 10 Tf 0 g) /AA << /C << /S /JavaScript /JS (AFSimple_Calculate\\(\"SUM\", new Array\\(\"a\", \"b\"\\)\\);) >> /F << /S /JavaScript /JS (AFNumber_Format\\(2, 0, 0, 0, \"$\", true\\);) >> >> >>",
            "<< \(Self.w) /FT /Tx /Ff 1 /T (double) /Rect [72 610 200 630] /DA (/Helv 10 Tf 0 g) /AA << /C << /S /JavaScript /JS 9 0 R >> >> >>",
        ], acroExtra: "/CO [7 0 R 8 0 R]", more: [
            Core2Pdf.stream("var t = this.getField(\"total\").value;\nevent.value = t * 2 - AFMakeNumber(getField(\"a\").value);"),
        ])
        let result = try filled(form, ["a": "1200", "b": "34.5"])
        let widgets = try FormEditor.read(result, nil)
        let total = try #require(widgets.first { $0.fieldName == "total" })
        #expect(total.value == "1234.5")
        #expect(total.displayValue == "$1,234.50")
        #expect(total.calculated)
        #expect(widgets.first { $0.fieldName == "double" }?.value == "1269")
        #expect(try Core2Pdf.allText(Core2Pdf.withoutNeedAppearances(result)).contains("$1,234.50"))
    }

    @Test func widgetFlagsAndRadioRules() throws {
        let form = Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /F 36 /P 3 0 R /FT /Tx /T (noview) /Rect [72 700 200 720] >>",
            "<< /Type /Annot /Subtype /Widget /F 68 /P 3 0 R /FT /Tx /T (locked) /Rect [72 670 200 690] >>",
            "<< /FT /Btn /Ff 49152 /T (pick) /Kids [8 0 R 9 0 R] /V /A >>",
        ], more: [
            "<< \(Self.w) /Parent 7 0 R /Rect [72 600 90 618] /AS /A /AP << /N << /A 10 0 R /Off 10 0 R >> >> >>",
            "<< \(Self.w) /Parent 7 0 R /Rect [120 600 138 618] /AS /Off /AP << /N << /B 10 0 R /Off 10 0 R >> >> >>",
            Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
        ], extraAnnots: "8 0 R 9 0 R")
        let widgets = try FormEditor.read(form, nil)
        #expect(!widgets.contains { $0.fieldName == "noview" })
        #expect(widgets.first { $0.fieldName == "locked" }?.readOnly == true)
        let picks = widgets.filter { $0.fieldName == "pick" }
        #expect(picks.allSatisfy { $0.noToggleToOff })

        // NoToggleToOff: "Off" is ignored, the group keeps its choice.
        let off = try filled(form, ["pick": "Off"])
        #expect(try FormEditor.read(off, nil).first { $0.fieldName == "pick" }?.value == "A")
        let b = try filled(form, ["pick": "B"])
        #expect(try FormEditor.read(b, nil).first { $0.fieldName == "pick" }?.value == "B")
    }

    @Test func structureTabOrderBeatsGeometry() throws {
        // Geometrically "top" comes first, but the structure tree lists "bottom" first and the page asks for /Tabs /S.
        let form = Core2Pdf.form([
            "<< \(Self.w) /FT /Tx /T (top) /Rect [72 700 200 720] >>",
            "<< \(Self.w) /FT /Tx /T (bottom) /Rect [72 600 200 620] >>",
        ], pageExtra: "/Tabs /S", catalogExtra: "/StructTreeRoot 7 0 R", more: [
            "<< /Type /StructTreeRoot /K [8 0 R] >>",
            "<< /S /Form /P 7 0 R /K [<< /Type /OBJR /Obj 6 0 R >> << /Type /OBJR /Obj 5 0 R >>] >>",
        ])
        let widgets = try FormEditor.read(form, nil)
        #expect(widgets.map(\.fieldName) == ["bottom", "top"])
        #expect(widgets.map(\.tabOrder) == [0, 1])

        let geometric = Core2Pdf.form(["<< \(Self.w) /FT /Tx /T (top) /Rect [72 700 200 720] >>", "<< \(Self.w) /FT /Tx /T (bottom) /Rect [72 600 200 620] >>"])
        #expect(try FormEditor.read(geometric, nil).map(\.fieldName) == ["top", "bottom"])
    }

    @Test func toleratesFontsWithDictionaryEncodingsAndOddEntries() throws {
        // Real forms: /DR fonts with an /Encoding dictionary (Differences), an indirect /BaseFont, a widget /Subtype stored oddly.
        let form = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R /TiRo 6 0 R >> /Encoding << /PDFDocEncoding 7 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] /Resources << >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /Differences [32 /space] >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/TiRo 11 Tf 0 0 1 rg) /F 4 /P 3 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont 8 0 R /Encoding 7 0 R >>",
            "<< /Type /Encoding /Differences [24 /breve /caron] >>",
            "/Times-Roman",
        ])
        #expect(try Core2Pdf.allText(Core2Pdf.withoutNeedAppearances(filled(form, ["name": "Tolerant"]))).contains("Tolerant"))
    }

    @Test func existingFormStillFillsAndRendersThroughMuPdf() throws {
        // The original fixture: checks and radios unchanged, text gets an appearance.
        let strict = try Core2Pdf.withoutNeedAppearances(filled(FormTests.makeForm(), ["name": "Zoë", "size": "L"]))
        let text = try Core2Pdf.allText(strict)
        #expect(text.contains("Zoë"))
        #expect(text.contains("L"))
    }
}
