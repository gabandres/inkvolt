import Foundation
import Testing
@testable import PdfCore

/// Ported from FormDesignTests.cs, whole: fields made with `FormDesign` read back, fill with `FormEditor` and show in
/// MuPDF. The PDFsharp object checks read the same objects through MuPDF (`PObj`). Windows' ArgumentException and
/// InvalidOperationException are `PdfEditError` here. A turned page is made by setting /Rotate through MuPDF.
struct FormDesignTests {
    private func new(_ kind: DesignFieldKind, _ rect: RectD, _ name: String? = nil, existing: [String] = [], page: Int = 0,
                     _ change: (inout DesignField) -> Void = { _ in }) -> DesignField {
        FormDesign.newField(kind, page, rect, existing, name).with(change)
    }

    private func add(_ pdf: [UInt8], _ fields: DesignField...) throws -> [UInt8] { try FormDesign.add(pdf, nil, fields) }

    private func round(_ r: RectD) -> RectD {
        func v(_ d: Double) -> Double { (d * 100).rounded() / 100 }
        return RectD(v(r.x), v(r.y), v(r.width), v(r.height))
    }

    private func single<T>(_ list: [T], _ matching: (T) -> Bool = { _ in true }) throws -> T {
        let found = list.filter(matching)
        try #require(found.count == 1, "\(found.count) matches")
        return found[0]
    }

    @Test func createdFieldsReopenAndFill() throws {
        let pdf = try add(TestPdf.make(1),
                          new(.text, RectD(72, 200, 200, 22), "Name") {
                              $0.defaultValue = "Jane"
                              $0.tooltip = "Your full name"
                              $0.required = true
                          },
                          new(.checkBox, RectD(72, 240, 14, 14), "Agree"),
                          new(.radio, RectD(72, 270, 14, 14), "Size") { $0.exportValue = "Small" },
                          new(.radio, RectD(100, 270, 14, 14), "Size") { $0.exportValue = "Large" },
                          new(.comboBox, RectD(72, 300, 120, 20), "Color") {
                              $0.options = ["Red", "Green", "Blue"]
                              $0.defaultValue = "Green"
                          },
                          new(.listBox, RectD(72, 330, 120, 60), "Fruit") {
                              $0.options = ["Apple", "Pear"]
                              $0.multiSelect = true
                          },
                          new(.signature, RectD(72, 400, 200, 40), "Sign here"),
                          new(.button, RectD(300, 400, 80, 24), "Reset"))

        let widgets = try FormEditor.read(pdf, nil)
        func widget(_ name: String) throws -> FormWidget { try single(widgets) { $0.fieldName == name } }
        #expect(try widget("Name").kind == .text)
        #expect(try widget("Name").value == "Jane")
        #expect(try widget("Agree").kind == .checkBox)
        #expect(widgets.filter { $0.fieldName == "Size" }.map(\.onState) == ["Small", "Large"])
        #expect(widgets.filter { $0.fieldName == "Size" }.allSatisfy { $0.kind == .radio })
        let color = try widget("Color")
        #expect(color.kind == .choice)
        #expect(color.options == ["Red", "Green", "Blue"])
        #expect(color.value == "Green")
        #expect(try widget("Fruit").multiSelect)
        #expect(try widget("Sign here").kind == .signature)
        #expect(try widget("Reset").kind == .pushButton)
        #expect(round(try widget("Name").rect) == RectD(72, 200, 200, 22))

        // The text field's value is drawn in its appearance (MuPDF shows it without NeedAppearances).
        #expect(try Core2Pdf.allText(pdf).contains("Jane"))
        let doc = try Core2Pdf.open(pdf)
        #expect(doc.catalog.dict("AcroForm")?.has("NeedAppearances") == false)

        // Filling: values land, appearances follow.
        let filledPdf = try FormEditor.setValues(pdf, nil, ["Name": "Ada Lovelace", "Agree": "Yes", "Size": "Large", "Color": "Blue"])
        let after = try FormEditor.read(filledPdf, nil)
        #expect(try single(after) { $0.fieldName == "Name" }.value == "Ada Lovelace")
        #expect(try single(after) { $0.fieldName == "Agree" }.value == "Yes")
        #expect(after.first { $0.fieldName == "Size" }?.value == "Large")
        #expect(try single(after) { $0.fieldName == "Color" }.value == "Blue")
        #expect(try Core2Pdf.allText(filledPdf).contains("Ada Lovelace"))

        // The designer reads its own properties back.
        let design = try FormDesign.read(filledPdf, nil)
        let name = try single(design) { $0.name == "Name" }
        #expect(name.required)
        #expect(name.tooltip == "Your full name")
        #expect(name.defaultValue == "Jane")
        let reset = try single(design) { $0.name == "Reset" }
        #expect(reset.action == .resetForm)
        #expect(reset.caption == "Reset")
        #expect(design.count == 8)
    }

    @Test func checkBoxAndRadioFacesShowTheirState() throws {
        let box = RectD(100, 100, 20, 20)
        let pdf = try add(TestPdf.make(1), new(.checkBox, box, "Agree"),
                          new(.radio, RectD(100, 140, 20, 20), "Pick") { $0.exportValue = "A" },
                          new(.radio, RectD(140, 140, 20, 20), "Pick") { $0.exportValue = "B" })
        let off = try Core2Pdf.ink(pdf, 0, box.inflate(-4))
        let on = try FormEditor.setValues(pdf, nil, ["Agree": "Yes", "Pick": "B"])
        #expect(try Core2Pdf.ink(on, 0, box.inflate(-4)) > off + 0.1, "the check mark shows")
        #expect(try Core2Pdf.ink(on, 0, RectD(146, 146, 8, 8)) > 0.5, "the chosen radio button shows its dot")
        #expect(try Core2Pdf.ink(on, 0, RectD(106, 146, 8, 8)) < 0.1, "the other one stays empty")
    }

    @Test func dottedNamesNestUnderOneParent() throws {
        let pdf = try add(TestPdf.make(1), new(.text, RectD(72, 100, 100, 20), "address.city"), new(.text, RectD(72, 130, 100, 20), "address.zip"))
        #expect(try FormEditor.read(pdf, nil).map(\.fieldName).sorted() == ["address.city", "address.zip"])
        let doc = try Core2Pdf.open(pdf)
        let fields = try #require(doc.catalog.dict("AcroForm")?.array("Fields"))
        try #require(fields.count == 1)
        let parent = try #require(fields[0])
        #expect(parent.text("T") == "address")
        #expect(parent.array("Kids")?.count == 2)

        // Deleting both removes the parent too.
        let ids = try FormDesign.read(pdf, nil).map(\.id)
        let empty = try FormDesign.delete(pdf, nil, ids)
        #expect(try FormEditor.read(empty, nil).isEmpty)
        let doc2 = try Core2Pdf.open(empty)
        #expect(doc2.catalog.dict("AcroForm")?.array("Fields")?.count == 0)
        #expect((doc2.page(0).array("Annots")?.count ?? 0) == 0)
    }

    @Test(arguments: [
        ("", false), ("Name", true), ("a.b.c", true), (".a", false), ("a..b", false), ("a. b", false), ("line\nbreak", false), ("Größe", true),
    ] as [(String, Bool)])
    func nameRules(_ name: String, _ ok: Bool) {
        #expect((FormDesign.nameProblem(name) == nil) == ok)
    }

    @Test func namesMustNotClash() throws {
        let pdf = try add(TestPdf.make(1), new(.text, RectD(72, 100, 100, 20), "a.b"), new(.radio, RectD(72, 140, 14, 14), "Pick"))
        for (kind, name) in [(DesignFieldKind.text, "a"), (.text, "a.b"), (.text, "a.b.c"), (.checkBox, "Pick")] {
            #expect(throws: PdfEditError.self) { try add(pdf, new(kind, RectD(72, 200, 100, 20)) { $0.name = name }) }
        }
        // A radio button with a group's name joins the group.
        let joined = try add(pdf, new(.radio, RectD(100, 140, 14, 14)) {
            $0.name = "Pick"
            $0.exportValue = "Two"
        })
        #expect(try FormEditor.read(joined, nil).filter { $0.fieldName == "Pick" }.count == 2)

        #expect(FormDesign.uniqueName(["Name"], "Name") == "Name_2")
        #expect(FormDesign.uniqueName(["a.b"], "a") == "a_2")
        #expect(FormDesign.nextName(["Text1", "Text2"], .text) == "Text3")
        #expect(FormDesign.exportValueProblem("Off") != nil)
        #expect(FormDesign.exportValueProblem("a b") != nil)
        #expect(FormDesign.exportValueProblem("Choice_1") == nil)
    }

    @Test func updateMovesRenamesAndChangesProperties() throws {
        let pdf = try add(TestPdf.make(1), new(.text, RectD(72, 100, 100, 20), "Amount"))
        let f = try single(FormDesign.read(pdf, nil))
        var newIds: [String: String] = [:]
        let money = FieldFormat(.number, decimals: 2, separatorStyle: 0, negativeStyle: 0, currency: "$", currencyPrepend: true)
        let changed = try FormDesign.update(pdf, nil, [f.with {
            $0.name = "Total"
            $0.rect = RectD(80, 120, 150, 30)
            $0.readOnly = true
            $0.alignment = 2
            $0.fontSize = 14
            $0.maxLength = 12
            $0.format = money
            $0.defaultValue = "1234.5"
            $0.fillColor = AnnotColor(0.9, 0.95, 1)
            $0.borderColor = nil
        }], newIds: &newIds)
        #expect(newIds.isEmpty) // it already had an /NM
        let back = try single(FormDesign.read(changed, nil))
        #expect(back.name == "Total")
        #expect(round(back.rect) == RectD(80, 120, 150, 30))
        #expect(back.readOnly)
        #expect(back.alignment == 2)
        #expect(back.fontSize == 14)
        #expect(back.maxLength == 12)
        #expect(back.borderColor == nil)
        #expect(back.format == money)
        let w = try single(FormEditor.read(changed, nil))
        #expect(w.readOnly)
        #expect(w.displayValue == "$1,234.50")
        #expect(try Core2Pdf.allText(changed).contains("$1,234.50"))

        // A date format, then none.
        let dated = try FormDesign.update(changed, nil, [back.with {
            $0.format = FieldFormat(.date, datePattern: "yyyy-mm-dd")
            $0.defaultValue = ""
        }])
        #expect(try single(FormDesign.read(dated, nil)).format?.datePattern == "yyyy-mm-dd")
        let plain = try FormDesign.update(dated, nil, [single(FormDesign.read(dated, nil)).with { $0.format = nil }])
        #expect(try single(FormDesign.read(plain, nil)).format == nil)
        #expect(try !single(FormDesign.read(plain, nil)).customFormat)
    }

    @Test func widgetsWithoutIdsGetOne() throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (Old) /Rect [72 600 272 620] /P 3 0 R /DA (/Helv 0 Tf 0 g) >>"])
        let f = try single(FormDesign.read(form, nil))
        #expect(f.id == "p0:0")
        var newIds: [String: String] = [:]
        let moved = try FormDesign.update(form, nil, [f.with { $0.rect.x = 100 }], newIds: &newIds)
        let again = try single(FormDesign.read(moved, nil))
        #expect(newIds["p0:0"] == again.id)
        #expect(near(again.rect.x, 100, 2))
    }

    @Test func fieldsWithNamesAndValuesWeWouldntMakeStillMove() throws {
        let form = Core2Pdf.form(
            ["<< /Type /Annot /Subtype /Widget /FT /Btn /T (Opt in. please) /Rect [72 600 86 614] /P 3 0 R /V /Off /AS /Off /MK << /CA (8) >> /AP << /N << /S#C3#AD 6 0 R /Off 6 0 R >> >> >>"],
            more: [Core2Pdf.stream("0 0 14 14 re S", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]")])
        let f = try single(FormDesign.read(form, nil))
        #expect(f.name == "Opt in. please")
        #expect(FormDesign.nameProblem(f.name) != nil)
        let moved = try FormDesign.update(form, nil, [f.with { $0.rect.x = 200 }])
        let back = try single(FormDesign.read(moved, nil))
        #expect(near(back.rect.x, 200, 2))
        #expect(back.exportValue == f.exportValue)
        #expect(back.name == f.name)
        // Its own symbol (a cross) is kept when it's redrawn at a new size.
        let resized = try FormDesign.update(moved, nil, [back.with {
            $0.rect.width = 20
            $0.rect.height = 20
        }])
        let doc = try Core2Pdf.open(resized)
        #expect(doc.page(0).array("Annots")?[0]?.dict("MK")?.text("CA") == "8")
        #expect(throws: PdfEditError.self) { try FormDesign.update(resized, nil, [single(FormDesign.read(resized, nil)).with { $0.exportValue = "a b" }]) }
    }

    @Test func radioButtonsMoveBetweenGroups() throws {
        let pdf = try add(TestPdf.make(1),
                          new(.radio, RectD(72, 100, 14, 14), "A") { $0.exportValue = "One" },
                          new(.radio, RectD(100, 100, 14, 14), "A") { $0.exportValue = "Two" })
        let two = try single(FormDesign.read(pdf, nil)) { $0.exportValue == "Two" }
        let split = try FormDesign.update(pdf, nil, [two.with { $0.name = "B" }])
        #expect(try FormEditor.read(split, nil).map(\.fieldName).sorted() == ["A", "B"])

        // B's only button back into A: B goes.
        let b = try single(FormDesign.read(split, nil)) { $0.name == "B" }
        let merged = try FormDesign.update(split, nil, [b.with { $0.name = "A" }])
        #expect(try FormEditor.read(merged, nil).map(\.fieldName) == ["A", "A"])

        // Deleting one button keeps the group.
        let one = try #require(try FormDesign.read(merged, nil).first)
        let left = try FormDesign.delete(merged, nil, [one.id])
        #expect(try FormEditor.read(left, nil).count == 1)

        // A default button.
        let g = try FormDesign.read(merged, nil)
        let withDefault = try FormDesign.update(merged, nil, [g[0].with { $0.defaultValue = "Two" }])
        #expect(try FormEditor.read(withDefault, nil)[0].value == "Two")
    }

    @Test func duplicatesGetNewNamesOrValues() throws {
        let pdf = try add(TestPdf.make(1), new(.text, RectD(72, 100, 100, 20), "Name"),
                          new(.radio, RectD(72, 140, 14, 14), "Pick") { $0.exportValue = "Choice1" })
        let all = try FormDesign.read(pdf, nil)
        let text = FormDesign.duplicate(try single(all) { $0.name == "Name" }, all, 0, 30)
        let radio = FormDesign.duplicate(try single(all) { $0.name == "Pick" }, all, 30, 0)
        #expect(text.name == "Name_2")
        #expect(text.rect.y == 130)
        #expect(radio.name == "Pick")
        #expect(radio.exportValue == "Choice2")
        let both = try FormDesign.add(pdf, nil, [text, radio])
        #expect(try FormEditor.read(both, nil).count == 4)
    }

    @Test func tabOrderFollowsTheChosenOrder() throws {
        let pdf = try add(TestPdf.make(1), new(.text, RectD(72, 100, 100, 20), "First"), new(.text, RectD(72, 140, 100, 20), "Second"),
                          new(.text, RectD(72, 180, 100, 20), "Third"))
        #expect(try FormEditor.read(pdf, nil).map(\.fieldName) == ["First", "Second", "Third"])
        let ids = Dictionary(uniqueKeysWithValues: try FormDesign.read(pdf, nil).map { ($0.name, $0.id) })
        let reordered = try FormDesign.setTabOrder(pdf, nil, 0, [ids["Third"]!, ids["First"]!, ids["Second"]!])
        #expect(try FormEditor.read(reordered, nil).map(\.fieldName) == ["Third", "First", "Second"])
        // First, Second, Third
        #expect(try FormDesign.read(reordered, nil).sorted { $0.name < $1.name }.map(\.tabIndex) == [1, 2, 0])
    }

    @Test func turnedPagesKeepFieldsUpright() throws {
        let turned = try Core2Pdf.open(TestPdf.make(1))
        turned.page(0).set("Rotate", turned.int(90))
        let pdf = try turned.write("")
        let rect = RectD(100, 50, 200, 24)
        let added = try add(pdf, new(.text, rect, "Turned") { $0.defaultValue = "Upright" })
        #expect(round(try single(FormDesign.read(added, nil)).rect) == rect)
        #expect(round(try single(FormEditor.read(added, nil)).rect) == rect)
        let check = try Core2Pdf.open(added)
        #expect(check.page(0).array("Annots")?[0]?.dict("MK")?.int("R") == 90)
        #expect(try Core2Pdf.allText(added).contains("Upright"))
    }

    @Test func encryptedFilesKeepTheirProtection() throws {
        let pdf = TestPdf.encrypted(1, "user")
        let field = new(.text, RectD(72, 100, 100, 20), "Secret")
        let (added, _) = try KeptProtection.run(openPassword: nil, dropOpenPassword: false) {
            try SignedEdits.run { try FormDesign.add(pdf, "user-owner", [field]) }
        }
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(added) }
        #expect(try single(FormEditor.read(added, "user")).fieldName == "Secret")
    }

    @Test func signedFilesGetFieldsAppended() throws {
        let signed = SignedEditTests.signed()
        let field = new(.text, RectD(72, 300, 200, 20), "Notes")
        let (added, report) = try SignedEdits.run { try FormDesign.add(signed, nil, [field]) }
        #expect(report.appended)
        #expect(Array(added.prefix(signed.count)) == signed)
        #expect(Signatures.verify(added).first { $0.fieldName == "Approval" }?.status == .modifiedAfterSigning)
        #expect(try FormEditor.read(added, nil).map(\.fieldName).contains("Notes"))

        // The signed signature field itself can't be changed or removed.
        let approval = try single(FormDesign.read(added, nil)) { $0.name == "Approval" }
        #expect(approval.signed)
        #expect(throws: PdfEditError.self) { try FormDesign.delete(added, nil, [approval.id]) }
        #expect(throws: PdfEditError.self) { try FormDesign.update(added, nil, [approval.with { $0.rect.x = 10 }]) }
    }

    @Test func pushButtonsPrintOrReset() throws {
        let pdf = try add(TestPdf.make(1), new(.button, RectD(72, 100, 80, 24), "Go") {
            $0.action = .print
            $0.caption = "Print"
        })
        let b = try single(FormDesign.read(pdf, nil))
        #expect(b.action == .print)
        #expect(try Core2Pdf.allText(pdf).contains("Print"))
        let w = try single(FormEditor.read(pdf, nil))
        #expect(w.triggers.contains(.up))
    }

    /// The bytes of a widget's appearance entry (/N, /D or /R; a state's face with `state`).
    private func face(_ pdf: [UInt8], _ annot: Int, _ key: String = "N", state: String? = nil) throws -> [UInt8]? {
        let doc = try Core2Pdf.open(pdf)
        var entry = doc.page(0).array("Annots")?[annot]?.dict("AP")?.dict(key)
        if let state { entry = entry?.dict(state) }
        return entry?.streamData
    }

    @Test func pushButtonsKeepTheirFacesWhenMovedAndIconButtonsAlways() throws {
        let pdf = try add(TestPdf.make(1), new(.button, RectD(72, 100, 80, 24), "Go"))
        let first = try face(pdf, 0)
        #expect(first != nil)
        let moved = try FormDesign.update(pdf, nil, [single(FormDesign.read(pdf, nil)).with { $0.rect = RectD(200, 300, 80, 24) }])
        #expect(try face(moved, 0) == first)
        let relabeled = try FormDesign.update(moved, nil, [single(FormDesign.read(moved, nil)).with { $0.caption = "Clear" }])
        #expect(try face(relabeled, 0) != first)

        // A button with an icon and its own down and rollover faces: moved, resized or relabeled, they stay.
        let icon = Core2Pdf.form(
            ["<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Logo) /Rect [72 600 172 640] /P 3 0 R /MK << /I 6 0 R /CA (Go) >> /AP << /N 6 0 R /D 7 0 R /R 8 0 R >> >>"],
            more: [
                Core2Pdf.stream("0 0 1 rg 0 0 100 40 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 40]"),
                Core2Pdf.stream("1 0 0 rg 0 0 100 40 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 40]"),
                Core2Pdf.stream("0 1 0 rg 0 0 100 40 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 40]"),
            ])
        #expect(try face(icon, 0, "D") != nil)
        let b = try single(FormDesign.read(icon, nil))
        let changed = try FormDesign.update(icon, nil, [b.with {
            $0.rect = RectD(80, 160, 120, 50)
            $0.caption = "Start"
            $0.fillColor = AnnotColor(1, 1, 0)
        }])
        #expect(try face(changed, 0) == face(icon, 0))
        #expect(try face(changed, 0, "D") == face(icon, 0, "D"))
        #expect(try face(changed, 0, "R") == face(icon, 0, "R"))
        let doc = try Core2Pdf.open(changed)
        #expect(doc.page(0).array("Annots")?[0]?.dict("MK")?.dict("I") != nil)
        #expect(round(try single(FormDesign.read(changed, nil)).rect) == RectD(80, 160, 120, 50))
    }

    @Test func radioValuesStayUniqueInTheirGroup() throws {
        let pdf = try add(TestPdf.make(1),
                          new(.radio, RectD(72, 100, 14, 14), "A") { $0.exportValue = "One" },
                          new(.radio, RectD(100, 100, 14, 14), "A") { $0.exportValue = "Two" },
                          new(.radio, RectD(72, 140, 14, 14), "B") { $0.exportValue = "One" })
        // Adding one with a value the group has.
        #expect(throws: PdfEditError.self) { try add(pdf, new(.radio, RectD(130, 100, 14, 14), "A") { $0.exportValue = "Two" }) }
        let all = try FormDesign.read(pdf, nil)
        let aOne = try single(all) { $0.name == "A" && $0.exportValue == "One" }
        let aTwo = try single(all) { $0.name == "A" && $0.exportValue == "Two" }
        let b = try single(all) { $0.name == "B" }
        // Changing a value to one the group has.
        #expect(throws: PdfEditError.self) { try FormDesign.update(pdf, nil, [aTwo.with { $0.exportValue = "One" }]) }
        // Moving into a group that has the value (from a group of two, and as a group's only button).
        #expect(throws: PdfEditError.self) { try FormDesign.update(pdf, nil, [aOne.with { $0.name = "B" }]) }
        #expect(throws: PdfEditError.self) { try FormDesign.update(pdf, nil, [b.with { $0.name = "A" }]) }
        // A free value is fine, and a plain move of a group that already repeats a value isn't refused.
        let free = try FormDesign.update(pdf, nil, [b.with {
            $0.name = "A"
            $0.exportValue = "Three"
        }])
        #expect(try FormEditor.read(free, nil).filter { $0.fieldName == "A" }.count == 3)
    }

    @Test func radioButtonsLeaveTheirGroupsDefaultBehind() throws {
        let pdf = try add(TestPdf.make(1),
                          new(.radio, RectD(72, 100, 14, 14), "A") { $0.exportValue = "One" },
                          new(.radio, RectD(100, 100, 14, 14), "A") {
                              $0.exportValue = "Two"
                              $0.defaultValue = "Two"
                          },
                          new(.radio, RectD(72, 140, 14, 14), "C") { $0.exportValue = "Three" })
        #expect(try FormEditor.read(pdf, nil).first { $0.fieldName == "A" }?.value == "Two")
        let two = try single(FormDesign.read(pdf, nil)) { $0.exportValue == "Two" }
        #expect(two.defaultValue == "Two")

        // Into an existing group: neither group points at a button it doesn't have.
        let joined = try FormDesign.update(pdf, nil, [two.with { $0.name = "C" }])
        let doc = try Core2Pdf.open(joined)
        let a = try #require(Core2Pdf.field(doc, "A"))
        let c = try #require(Core2Pdf.field(doc, "C"))
        #expect(!a.has("DV"))
        #expect(a.name("V") == "Off")
        #expect(!c.has("DV"))
        #expect(c.name("V") == "Off")
        #expect(try FormDesign.read(joined, nil).allSatisfy { $0.defaultValue.isEmpty })

        // Into a new group of its own: it stays that group's default.
        let alone = try FormDesign.update(pdf, nil, [two.with { $0.name = "D" }])
        #expect(try single(FormEditor.read(alone, nil)) { $0.fieldName == "D" }.value == "Two")
        let doc2 = try Core2Pdf.open(alone)
        #expect(Core2Pdf.field(doc2, "A")?.has("DV") == false)
    }

    @Test func choicesKeepTheirShownText() throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (Metal) /Rect [72 600 222 620] /P 3 0 R /DA (/Helv 0 Tf 0 g) /Opt [[(g)(Gold)] [(s)(Silver)] (Bronze)] /V (s) >>"])
        let f = try single(FormDesign.read(form, nil))
        #expect(f.options == ["g", "s", "Bronze"])
        #expect(f.shownOptions == ["Gold", "Silver", "Bronze"])

        // A move or another property keeps the pairs.
        let moved = try FormDesign.update(form, nil, [f.with {
            $0.rect.x = 100
            $0.required = true
        }])
        #expect(try single(FormEditor.read(moved, nil)).optionLabels ?? [] == ["Gold", "Silver", "Bronze"])
        // Editing the choices writes pairs where the text differs.
        let edited = try FormDesign.update(moved, nil, [single(FormDesign.read(moved, nil)).with {
            $0.options = ["g", "p"]
            $0.optionLabels = ["Gold", "Platinum"]
            $0.defaultValue = "p"
        }])
        let w = try single(FormEditor.read(edited, nil))
        #expect(w.options == ["g", "p"])
        #expect(w.optionLabels ?? [] == ["Gold", "Platinum"])
        #expect(w.value == "p")
        #expect(try Core2Pdf.allText(edited).contains("Platinum"))
    }

    @Test func defaultAppearancesAreComparedByMeaning() throws {
        #expect(FormDesign.sameAppearance("/Helv 0 Tf 0 g", "/Helv 0 Tf 0 0 0 rg"))
        #expect(FormDesign.sameAppearance("/Helv 10 Tf 0 0 0 1 k", "/Helv 10 Tf 0 0 0 rg"))
        #expect(!FormDesign.sameAppearance("/Helv 10 Tf 0 g", "/Helv 12 Tf 0 g"))
        #expect(FormDesign.sameAppearance("/ZaDb 12 Tf 0 g", "/ZaDb 0 Tf 0 0 0 rg", colorOnly: true))

        // An Acrobat check box (DA "0 g", its own face) moved: face and DA untouched.
        let form = Core2Pdf.form(
            ["<< /Type /Annot /Subtype /Widget /FT /Btn /T (Ok) /Rect [72 600 86 614] /P 3 0 R /DA (/ZaDb 0 Tf 0 g) /V /Off /AS /Off /MK << /BC [0] >> /AP << /N << /Yes 6 0 R /Off 7 0 R >> >> >>"],
            more: [
                Core2Pdf.stream("q 0 0 14 14 re S 2 2 10 10 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
                Core2Pdf.stream("q 0 0 14 14 re S Q", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
            ])
        let f = try single(FormDesign.read(form, nil))
        #expect(try face(form, 0, "N", state: "Yes") != nil)
        let moved = try FormDesign.update(form, nil, [f.with { $0.rect.x = 300 }])
        #expect(try face(moved, 0, "N", state: "Yes") == face(form, 0, "N", state: "Yes"))
        let doc = try Core2Pdf.open(moved)
        #expect(doc.page(0).array("Annots")?[0]?.text("DA") == "/ZaDb 0 Tf 0 g")
    }

    /// A Mac addition: on Windows `SetDefault` compares an array /DV with nothing, so any change of such a list box
    /// clears its /DV and /V. Here an unchanged array default stays, with the selection.
    @Test func aListBoxWithSeveralDefaultsKeepsThemWhenMoved() throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 2097152 /T (Fruit) /Rect [72 600 222 660] /P 3 0 R /DA (/Helv 0 Tf 0 g) /Opt [(a)(b)(c)] /V [(a)(b)] /DV [(a)(b)] >>"])
        let f = try single(FormDesign.read(form, nil))
        #expect(f.defaultValue == "a\nb")
        let moved = try FormDesign.update(form, nil, [f.with { $0.rect.x = 100 }])
        #expect(try single(FormEditor.read(moved, nil)).value == "a\nb")
        #expect(try single(FormDesign.read(moved, nil)).defaultValue == "a\nb")
    }
}
