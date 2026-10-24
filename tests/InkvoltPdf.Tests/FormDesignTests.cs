using InkvoltPdf.Core;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>Form authoring: fields made with <see cref="FormDesign"/> read back, fill with <see cref="FormEditor"/> and show in MuPDF.</summary>
public class FormDesignTests
{
    private static DesignField New(DesignFieldKind kind, RectD rect, string? name = null, IEnumerable<string>? existing = null, int page = 0) =>
        FormDesign.NewField(kind, page, rect, existing ?? [], name);

    private static byte[] Add(byte[] pdf, params DesignField[] fields) => FormDesign.Add(pdf, null, fields);

    [Fact]
    public void CreatedFieldsReopenAndFill()
    {
        var pdf = Add(TestPdf.Make(1),
            New(DesignFieldKind.Text, new RectD(72, 200, 200, 22), "Name") with { DefaultValue = "Jane", Tooltip = "Your full name", Required = true },
            New(DesignFieldKind.CheckBox, new RectD(72, 240, 14, 14), "Agree"),
            New(DesignFieldKind.Radio, new RectD(72, 270, 14, 14), "Size") with { ExportValue = "Small" },
            New(DesignFieldKind.Radio, new RectD(100, 270, 14, 14), "Size") with { ExportValue = "Large" },
            New(DesignFieldKind.ComboBox, new RectD(72, 300, 120, 20), "Color") with { Options = ["Red", "Green", "Blue"], DefaultValue = "Green" },
            New(DesignFieldKind.ListBox, new RectD(72, 330, 120, 60), "Fruit") with { Options = ["Apple", "Pear"], MultiSelect = true },
            New(DesignFieldKind.Signature, new RectD(72, 400, 200, 40), "Sign here"),
            New(DesignFieldKind.Button, new RectD(300, 400, 80, 24), "Reset"));

        var widgets = FormEditor.Read(pdf, null);
        Assert.Equal(FormFieldKind.Text, widgets.Single(w => w.FieldName == "Name").Kind);
        Assert.Equal("Jane", widgets.Single(w => w.FieldName == "Name").Value);
        Assert.Equal(FormFieldKind.CheckBox, widgets.Single(w => w.FieldName == "Agree").Kind);
        Assert.Equal(["Small", "Large"], widgets.Where(w => w.FieldName == "Size").Select(w => w.OnState));
        Assert.All(widgets.Where(w => w.FieldName == "Size"), w => Assert.Equal(FormFieldKind.Radio, w.Kind));
        var color = widgets.Single(w => w.FieldName == "Color");
        Assert.Equal(FormFieldKind.Choice, color.Kind);
        Assert.Equal(["Red", "Green", "Blue"], color.Options);
        Assert.Equal("Green", color.Value);
        Assert.True(widgets.Single(w => w.FieldName == "Fruit").MultiSelect);
        Assert.Equal(FormFieldKind.Signature, widgets.Single(w => w.FieldName == "Sign here").Kind);
        Assert.Equal(FormFieldKind.PushButton, widgets.Single(w => w.FieldName == "Reset").Kind);
        Assert.Equal(new RectD(72, 200, 200, 22), Round(widgets.Single(w => w.FieldName == "Name").Rect));

        // The text field's value is drawn in its appearance (MuPDF shows it without NeedAppearances).
        Assert.Contains("Jane", Core2Pdf.AllText(pdf));
        using (var doc = Core2Pdf.Open(pdf))
            Assert.False(PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"])!.Elements.ContainsKey("/NeedAppearances"));

        // Filling: values land, appearances follow.
        var filled = FormEditor.SetValues(pdf, null, new Dictionary<string, string> { ["Name"] = "Ada Lovelace", ["Agree"] = "Yes", ["Size"] = "Large", ["Color"] = "Blue" });
        var after = FormEditor.Read(filled, null);
        Assert.Equal("Ada Lovelace", after.Single(w => w.FieldName == "Name").Value);
        Assert.Equal("Yes", after.Single(w => w.FieldName == "Agree").Value);
        Assert.Equal("Large", after.First(w => w.FieldName == "Size").Value);
        Assert.Equal("Blue", after.Single(w => w.FieldName == "Color").Value);
        Assert.Contains("Ada Lovelace", Core2Pdf.AllText(filled));

        // The designer reads its own properties back.
        var design = FormDesign.Read(filled, null);
        var name = design.Single(f => f.Name == "Name");
        Assert.True(name.Required);
        Assert.Equal("Your full name", name.Tooltip);
        Assert.Equal("Jane", name.DefaultValue);
        Assert.Equal(FieldButtonAction.ResetForm, design.Single(f => f.Name == "Reset").Action);
        Assert.Equal("Reset", design.Single(f => f.Name == "Reset").Caption);
        Assert.Equal(8, design.Count);
    }

    [Fact]
    public void CheckBoxAndRadioFacesShowTheirState()
    {
        var box = new RectD(100, 100, 20, 20);
        var pdf = Add(TestPdf.Make(1), New(DesignFieldKind.CheckBox, box, "Agree"),
            New(DesignFieldKind.Radio, new RectD(100, 140, 20, 20), "Pick") with { ExportValue = "A" },
            New(DesignFieldKind.Radio, new RectD(140, 140, 20, 20), "Pick") with { ExportValue = "B" });
        var off = Core2Pdf.Ink(pdf, 0, box.Inflate(-4));
        var on = FormEditor.SetValues(pdf, null, new Dictionary<string, string> { ["Agree"] = "Yes", ["Pick"] = "B" });
        Assert.True(Core2Pdf.Ink(on, 0, box.Inflate(-4)) > off + 0.1, "the check mark shows");
        Assert.True(Core2Pdf.Ink(on, 0, new RectD(146, 146, 8, 8)) > 0.5, "the chosen radio button shows its dot");
        Assert.True(Core2Pdf.Ink(on, 0, new RectD(106, 146, 8, 8)) < 0.1, "the other one stays empty");
    }

    [Fact]
    public void DottedNamesNestUnderOneParent()
    {
        var pdf = Add(TestPdf.Make(1),
            New(DesignFieldKind.Text, new RectD(72, 100, 100, 20), "address.city"),
            New(DesignFieldKind.Text, new RectD(72, 130, 100, 20), "address.zip"));
        Assert.Equal(["address.city", "address.zip"], FormEditor.Read(pdf, null).Select(w => w.FieldName).Order());
        using var doc = Core2Pdf.Open(pdf);
        var fields = PdfObj.Array(PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"])!.Elements["/Fields"])!;
        var parent = Assert.Single(fields.Elements.Select(PdfObj.Dict));
        Assert.Equal("address", PdfObj.Str(parent!.Elements["/T"]));
        Assert.Equal(2, PdfObj.Array(parent.Elements["/Kids"])!.Elements.Count);

        // Deleting both removes the parent too.
        var ids = FormDesign.Read(pdf, null).Select(f => f.Id).ToList();
        var empty = FormDesign.Delete(pdf, null, ids);
        Assert.Empty(FormEditor.Read(empty, null));
        using var doc2 = Core2Pdf.Open(empty);
        Assert.Empty(PdfObj.Array(PdfObj.Dict(doc2.Internals.Catalog.Elements["/AcroForm"])!.Elements["/Fields"])!.Elements);
        Assert.Null(PdfObj.Array(doc2.Pages[0].Elements["/Annots"])?.Elements.Count is > 0 ? "annots" : null);
    }

    [Theory]
    [InlineData("", false)]
    [InlineData("Name", true)]
    [InlineData("a.b.c", true)]
    [InlineData(".a", false)]
    [InlineData("a..b", false)]
    [InlineData("a. b", false)]
    [InlineData("line\nbreak", false)]
    [InlineData("Größe", true)]
    public void NameRules(string name, bool ok) => Assert.Equal(ok, FormDesign.NameProblem(name) is null);

    [Fact]
    public void NamesMustNotClash()
    {
        var pdf = Add(TestPdf.Make(1), New(DesignFieldKind.Text, new RectD(72, 100, 100, 20), "a.b"), New(DesignFieldKind.Radio, new RectD(72, 140, 14, 14), "Pick"));
        Assert.Throws<ArgumentException>(() => Add(pdf, New(DesignFieldKind.Text, new RectD(72, 200, 100, 20)) with { Name = "a" }));
        Assert.Throws<ArgumentException>(() => Add(pdf, New(DesignFieldKind.Text, new RectD(72, 200, 100, 20)) with { Name = "a.b" }));
        Assert.Throws<ArgumentException>(() => Add(pdf, New(DesignFieldKind.Text, new RectD(72, 200, 100, 20)) with { Name = "a.b.c" }));
        Assert.Throws<ArgumentException>(() => Add(pdf, New(DesignFieldKind.CheckBox, new RectD(72, 200, 14, 14)) with { Name = "Pick" }));
        // A radio button with a group's name joins the group.
        var joined = Add(pdf, New(DesignFieldKind.Radio, new RectD(100, 140, 14, 14)) with { Name = "Pick", ExportValue = "Two" });
        Assert.Equal(2, FormEditor.Read(joined, null).Count(w => w.FieldName == "Pick"));

        Assert.Equal("Name_2", FormDesign.UniqueName(["Name"], "Name"));
        Assert.Equal("a_2", FormDesign.UniqueName(["a.b"], "a"));
        Assert.Equal("Text3", FormDesign.NextName(["Text1", "Text2"], DesignFieldKind.Text));
        Assert.NotNull(FormDesign.ExportValueProblem("Off"));
        Assert.NotNull(FormDesign.ExportValueProblem("a b"));
        Assert.Null(FormDesign.ExportValueProblem("Choice_1"));
    }

    [Fact]
    public void UpdateMovesRenamesAndChangesProperties()
    {
        var pdf = Add(TestPdf.Make(1), New(DesignFieldKind.Text, new RectD(72, 100, 100, 20), "Amount"));
        var f = FormDesign.Read(pdf, null).Single();
        var newIds = new Dictionary<string, string>();
        var changed = FormDesign.Update(pdf, null, [f with
        {
            Name = "Total", Rect = new RectD(80, 120, 150, 30), ReadOnly = true, Alignment = 2, FontSize = 14, MaxLength = 12,
            Format = new FieldFormat(FieldFormatKind.Number, 2, 0, 0, "$", true), DefaultValue = "1234.5",
            FillColor = new AnnotColor(0.9, 0.95, 1), BorderColor = null,
        }], newIds);
        Assert.Empty(newIds); // it already had an /NM
        var back = FormDesign.Read(changed, null).Single();
        Assert.Equal("Total", back.Name);
        Assert.Equal(new RectD(80, 120, 150, 30), Round(back.Rect));
        Assert.True(back.ReadOnly);
        Assert.Equal(2, back.Alignment);
        Assert.Equal(14, back.FontSize);
        Assert.Equal(12, back.MaxLength);
        Assert.Null(back.BorderColor);
        Assert.Equal(new FieldFormat(FieldFormatKind.Number, 2, 0, 0, "$", true), back.Format);
        var w = FormEditor.Read(changed, null).Single();
        Assert.True(w.ReadOnly);
        Assert.Equal("$1,234.50", w.DisplayValue);
        Assert.Contains("$1,234.50", Core2Pdf.AllText(changed));

        // A date format, then none.
        var dated = FormDesign.Update(changed, null, [back with { Format = new FieldFormat(FieldFormatKind.Date, DatePattern: "yyyy-mm-dd"), DefaultValue = "" }]);
        Assert.Equal("yyyy-mm-dd", FormDesign.Read(dated, null).Single().Format!.DatePattern);
        var plain = FormDesign.Update(dated, null, [FormDesign.Read(dated, null).Single() with { Format = null }]);
        Assert.Null(FormDesign.Read(plain, null).Single().Format);
        Assert.False(FormDesign.Read(plain, null).Single().CustomFormat);
    }

    [Fact]
    public void WidgetsWithoutIdsGetOne()
    {
        var form = Core2Pdf.Form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (Old) /Rect [72 600 272 620] /P 3 0 R /DA (/Helv 0 Tf 0 g) >>"]);
        var f = FormDesign.Read(form, null).Single();
        Assert.Equal("p0:0", f.Id);
        var newIds = new Dictionary<string, string>();
        var moved = FormDesign.Update(form, null, [f with { Rect = f.Rect with { X = 100 } }], newIds);
        var again = FormDesign.Read(moved, null).Single();
        Assert.Equal(newIds["p0:0"], again.Id);
        Assert.Equal(100, again.Rect.X, 2);
    }

    [Fact]
    public void FieldsWithNamesAndValuesWeWouldntMakeStillMove()
    {
        var form = Core2Pdf.Form(
        [
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Opt in. please) /Rect [72 600 86 614] /P 3 0 R /V /Off /AS /Off /MK << /CA (8) >> /AP << /N << /S#C3#AD 6 0 R /Off 6 0 R >> >> >>",
            Core2Pdf.Stream("0 0 14 14 re S", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
        ]);
        var f = FormDesign.Read(form, null).Single();
        Assert.Equal("Opt in. please", f.Name);
        Assert.NotNull(FormDesign.NameProblem(f.Name));
        var moved = FormDesign.Update(form, null, [f with { Rect = f.Rect with { X = 200 } }]);
        var back = FormDesign.Read(moved, null).Single();
        Assert.Equal(200, back.Rect.X, 2);
        Assert.Equal(f.ExportValue, back.ExportValue);
        Assert.Equal(f.Name, back.Name);
        // Its own symbol (a cross) is kept when it's redrawn at a new size.
        var resized = FormDesign.Update(moved, null, [back with { Rect = back.Rect with { Width = 20, Height = 20 } }]);
        using var doc = Core2Pdf.Open(resized);
        var w = PdfObj.Dict(PdfObj.Array(doc.Pages[0].Elements["/Annots"])!.Elements[0])!;
        Assert.Equal("8", PdfObj.Str(PdfObj.Dict(w.Elements["/MK"])!.Elements["/CA"]));
        Assert.Throws<ArgumentException>(() => FormDesign.Update(resized, null, [FormDesign.Read(resized, null).Single() with { ExportValue = "a b" }]));
    }

    [Fact]
    public void RadioButtonsMoveBetweenGroups()
    {
        var pdf = Add(TestPdf.Make(1),
            New(DesignFieldKind.Radio, new RectD(72, 100, 14, 14), "A") with { ExportValue = "One" },
            New(DesignFieldKind.Radio, new RectD(100, 100, 14, 14), "A") with { ExportValue = "Two" });
        var two = FormDesign.Read(pdf, null).Single(f => f.ExportValue == "Two");
        var split = FormDesign.Update(pdf, null, [two with { Name = "B" }]);
        var widgets = FormEditor.Read(split, null);
        Assert.Equal(["A", "B"], widgets.Select(w => w.FieldName).Order());

        // B's only button back into A: B goes.
        var b = FormDesign.Read(split, null).Single(f => f.Name == "B");
        var merged = FormDesign.Update(split, null, [b with { Name = "A" }]);
        Assert.Equal(["A", "A"], FormEditor.Read(merged, null).Select(w => w.FieldName));

        // Deleting one button keeps the group.
        var one = FormDesign.Read(merged, null).First();
        var left = FormDesign.Delete(merged, null, [one.Id]);
        Assert.Single(FormEditor.Read(left, null));

        // A default button.
        var g = FormDesign.Read(merged, null);
        var withDefault = FormDesign.Update(merged, null, [g[0] with { DefaultValue = "Two" }]);
        Assert.Equal("Two", FormEditor.Read(withDefault, null)[0].Value);
    }

    [Fact]
    public void DuplicatesGetNewNamesOrValues()
    {
        var pdf = Add(TestPdf.Make(1), New(DesignFieldKind.Text, new RectD(72, 100, 100, 20), "Name"),
            New(DesignFieldKind.Radio, new RectD(72, 140, 14, 14), "Pick") with { ExportValue = "Choice1" });
        var all = FormDesign.Read(pdf, null);
        var text = FormDesign.Duplicate(all.Single(f => f.Name == "Name"), all, 0, 30);
        var radio = FormDesign.Duplicate(all.Single(f => f.Name == "Pick"), all, 30, 0);
        Assert.Equal("Name_2", text.Name);
        Assert.Equal(130, text.Rect.Y);
        Assert.Equal("Pick", radio.Name);
        Assert.Equal("Choice2", radio.ExportValue);
        var both = FormDesign.Add(pdf, null, [text, radio]);
        Assert.Equal(4, FormEditor.Read(both, null).Count);
    }

    [Fact]
    public void TabOrderFollowsTheChosenOrder()
    {
        var pdf = Add(TestPdf.Make(1),
            New(DesignFieldKind.Text, new RectD(72, 100, 100, 20), "First"),
            New(DesignFieldKind.Text, new RectD(72, 140, 100, 20), "Second"),
            New(DesignFieldKind.Text, new RectD(72, 180, 100, 20), "Third"));
        Assert.Equal(["First", "Second", "Third"], FormEditor.Read(pdf, null).Select(w => w.FieldName));
        var ids = FormDesign.Read(pdf, null).ToDictionary(f => f.Name, f => f.Id);
        var reordered = FormDesign.SetTabOrder(pdf, null, 0, [ids["Third"], ids["First"], ids["Second"]]);
        Assert.Equal(["Third", "First", "Second"], FormEditor.Read(reordered, null).Select(w => w.FieldName));
        Assert.Equal([1, 2, 0], FormDesign.Read(reordered, null).OrderBy(f => f.Name).Select(f => f.TabIndex)); // First, Second, Third
    }

    [Fact]
    public void TurnedPagesKeepFieldsUpright()
    {
        byte[] pdf;
        using (var doc = PdfReader.Open(new MemoryStream(TestPdf.Make(1)), PdfDocumentOpenMode.Modify))
        {
            doc.Pages[0].Rotate = 90;
            using var ms = new MemoryStream();
            doc.Save(ms);
            pdf = ms.ToArray();
        }
        var rect = new RectD(100, 50, 200, 24);
        var added = Add(pdf, New(DesignFieldKind.Text, rect, "Turned") with { DefaultValue = "Upright" });
        Assert.Equal(rect, Round(FormDesign.Read(added, null).Single().Rect));
        Assert.Equal(rect, Round(FormEditor.Read(added, null).Single().Rect));
        using var check = Core2Pdf.Open(added);
        var w = PdfObj.Dict(PdfObj.Array(check.Pages[0].Elements["/Annots"])!.Elements[0])!;
        Assert.Equal(90, PdfObj.Int(PdfObj.Dict(w.Elements["/MK"])!.Elements["/R"]));
        Assert.Contains("Upright", Core2Pdf.AllText(added));
    }

    [Fact]
    public void EncryptedFilesKeepTheirProtection()
    {
        var pdf = TestPdf.Encrypted(1, "user");
        var (added, _) = KeptProtection.Run(null, false, () => SignedEdits.Run(() => FormDesign.Add(pdf, "user-owner", [New(DesignFieldKind.Text, new RectD(72, 100, 100, 20), "Secret")])));
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(added, MuPDFCore.InputFileTypes.PDF, null).Dispose());
        Assert.Equal("Secret", FormEditor.Read(added, "user").Single().FieldName);
    }

    [Fact]
    public void SignedFilesGetFieldsAppended()
    {
        var signed = SignedEditTests.Signed();
        var (added, report) = SignedEdits.Run(() => FormDesign.Add(signed, null, [New(DesignFieldKind.Text, new RectD(72, 300, 200, 20), "Notes")]));
        Assert.True(report.Appended);
        Assert.True(added.AsSpan(0, signed.Length).SequenceEqual(signed));
        Assert.Equal(SignatureStatus.ModifiedAfterSigning, Signatures.Verify(added).Single(s => s.FieldName == "Approval").Status);
        Assert.Contains("Notes", FormEditor.Read(added, null).Select(w => w.FieldName));

        // The signed signature field itself can't be changed or removed.
        var approval = FormDesign.Read(added, null).Single(f => f.Name == "Approval");
        Assert.True(approval.Signed);
        Assert.Throws<InvalidOperationException>(() => FormDesign.Delete(added, null, [approval.Id]));
        Assert.Throws<InvalidOperationException>(() => FormDesign.Update(added, null, [approval with { Rect = approval.Rect with { X = 10 } }]));
    }

    [Fact]
    public void PushButtonsPrintOrReset()
    {
        var pdf = Add(TestPdf.Make(1), New(DesignFieldKind.Button, new RectD(72, 100, 80, 24), "Go") with { Action = FieldButtonAction.Print, Caption = "Print" });
        var b = FormDesign.Read(pdf, null).Single();
        Assert.Equal(FieldButtonAction.Print, b.Action);
        Assert.Contains("Print", Core2Pdf.AllText(pdf));
        var w = FormEditor.Read(pdf, null).Single();
        Assert.True(w.Triggers.HasFlag(FormTriggers.Up));
    }

    /// <summary>The bytes of a widget's appearance entry (/N, /D or /R; a state's face with <paramref name="state"/>).</summary>
    private static byte[]? Face(byte[] pdf, int annot, string key = "/N", string? state = null)
    {
        using var doc = Core2Pdf.Open(pdf);
        var w = PdfObj.Dict(PdfObj.Array(doc.Pages[0].Elements["/Annots"])!.Elements[annot])!;
        var entry = PdfObj.Dict(PdfObj.Dict(w.Elements["/AP"])?.Elements[key]);
        if (state is not null) entry = PdfObj.Dict(entry?.Elements[state]);
        return entry is null ? null : PdfObj.StreamBytes(entry);
    }

    private static PdfDictionary Widget(PdfDocument doc, int annot) => PdfObj.Dict(PdfObj.Array(doc.Pages[0].Elements["/Annots"])!.Elements[annot])!;

    [Fact]
    public void PushButtonsKeepTheirFacesWhenMovedAndIconButtonsAlways()
    {
        var pdf = Add(TestPdf.Make(1), New(DesignFieldKind.Button, new RectD(72, 100, 80, 24), "Go"));
        var face = Face(pdf, 0);
        Assert.NotNull(face);
        var moved = FormDesign.Update(pdf, null, [FormDesign.Read(pdf, null).Single() with { Rect = new RectD(200, 300, 80, 24) }]);
        Assert.Equal(face, Face(moved, 0));
        var relabeled = FormDesign.Update(moved, null, [FormDesign.Read(moved, null).Single() with { Caption = "Clear" }]);
        Assert.NotEqual(face, Face(relabeled, 0));

        // A button with an icon and its own down and rollover faces: moved, resized or relabeled, they stay.
        var icon = Core2Pdf.Form(
        [
            "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Logo) /Rect [72 600 172 640] /P 3 0 R /MK << /I 6 0 R /CA (Go) >> /AP << /N 6 0 R /D 7 0 R /R 8 0 R >> >>",
            Core2Pdf.Stream("0 0 1 rg 0 0 100 40 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 40]"),
            Core2Pdf.Stream("1 0 0 rg 0 0 100 40 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 40]"),
            Core2Pdf.Stream("0 1 0 rg 0 0 100 40 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 40]"),
        ]);
        Assert.NotNull(Face(icon, 0, "/D"));
        var b = FormDesign.Read(icon, null).Single();
        var changed = FormDesign.Update(icon, null, [b with { Rect = new RectD(80, 160, 120, 50), Caption = "Start", FillColor = new AnnotColor(1, 1, 0) }]);
        Assert.Equal(Face(icon, 0), Face(changed, 0));
        Assert.Equal(Face(icon, 0, "/D"), Face(changed, 0, "/D"));
        Assert.Equal(Face(icon, 0, "/R"), Face(changed, 0, "/R"));
        using var doc = Core2Pdf.Open(changed);
        Assert.NotNull(PdfObj.Dict(PdfObj.Dict(Widget(doc, 0).Elements["/MK"])!.Elements["/I"]));
        Assert.Equal(new RectD(80, 160, 120, 50), Round(FormDesign.Read(changed, null).Single().Rect));
    }

    [Fact]
    public void RadioValuesStayUniqueInTheirGroup()
    {
        var pdf = Add(TestPdf.Make(1),
            New(DesignFieldKind.Radio, new RectD(72, 100, 14, 14), "A") with { ExportValue = "One" },
            New(DesignFieldKind.Radio, new RectD(100, 100, 14, 14), "A") with { ExportValue = "Two" },
            New(DesignFieldKind.Radio, new RectD(72, 140, 14, 14), "B") with { ExportValue = "One" });
        // Adding one with a value the group has.
        Assert.Throws<ArgumentException>(() => Add(pdf, New(DesignFieldKind.Radio, new RectD(130, 100, 14, 14), "A") with { ExportValue = "Two" }));
        var all = FormDesign.Read(pdf, null);
        // Changing a value to one the group has.
        Assert.Throws<ArgumentException>(() => FormDesign.Update(pdf, null, [all.Single(f => f.Name == "A" && f.ExportValue == "Two") with { ExportValue = "One" }]));
        // Moving into a group that has the value (from a group of two, and as a group's only button).
        Assert.Throws<ArgumentException>(() => FormDesign.Update(pdf, null, [all.Single(f => f.Name == "A" && f.ExportValue == "One") with { Name = "B" }]));
        Assert.Throws<ArgumentException>(() => FormDesign.Update(pdf, null, [all.Single(f => f.Name == "B") with { Name = "A" }]));
        // A free value is fine, and a plain move of a group that already repeats a value isn't refused.
        Assert.Equal(3, FormEditor.Read(FormDesign.Update(pdf, null, [all.Single(f => f.Name == "B") with { Name = "A", ExportValue = "Three" }]), null).Count(w => w.FieldName == "A"));
    }

    [Fact]
    public void RadioButtonsLeaveTheirGroupsDefaultBehind()
    {
        var pdf = Add(TestPdf.Make(1),
            New(DesignFieldKind.Radio, new RectD(72, 100, 14, 14), "A") with { ExportValue = "One" },
            New(DesignFieldKind.Radio, new RectD(100, 100, 14, 14), "A") with { ExportValue = "Two", DefaultValue = "Two" },
            New(DesignFieldKind.Radio, new RectD(72, 140, 14, 14), "C") with { ExportValue = "Three" });
        Assert.Equal("Two", FormEditor.Read(pdf, null).First(w => w.FieldName == "A").Value);
        var two = FormDesign.Read(pdf, null).Single(f => f.ExportValue == "Two");
        Assert.Equal("Two", two.DefaultValue);

        // Into an existing group: neither group points at a button it doesn't have.
        var joined = FormDesign.Update(pdf, null, [two with { Name = "C" }]);
        using (var doc = Core2Pdf.Open(joined))
        {
            var a = Core2Pdf.Field(doc, "A")!;
            var c = Core2Pdf.Field(doc, "C")!;
            Assert.False(a.Elements.ContainsKey("/DV"));
            Assert.Equal("Off", PdfObj.Name(a.Elements["/V"]));
            Assert.False(c.Elements.ContainsKey("/DV"));
            Assert.Equal("Off", PdfObj.Name(c.Elements["/V"]));
        }
        Assert.All(FormDesign.Read(joined, null), f => Assert.Equal("", f.DefaultValue));

        // Into a new group of its own: it stays that group's default.
        var alone = FormDesign.Update(pdf, null, [two with { Name = "D" }]);
        Assert.Equal("Two", FormEditor.Read(alone, null).Single(w => w.FieldName == "D").Value);
        using (var doc = Core2Pdf.Open(alone))
            Assert.False(Core2Pdf.Field(doc, "A")!.Elements.ContainsKey("/DV"));
    }

    [Fact]
    public void ChoicesKeepTheirShownText()
    {
        var form = Core2Pdf.Form(["<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (Metal) /Rect [72 600 222 620] /P 3 0 R /DA (/Helv 0 Tf 0 g) /Opt [[(g)(Gold)] [(s)(Silver)] (Bronze)] /V (s) >>"]);
        var f = FormDesign.Read(form, null).Single();
        Assert.Equal(["g", "s", "Bronze"], f.Options);
        Assert.Equal(["Gold", "Silver", "Bronze"], f.ShownOptions);

        // A move or another property keeps the pairs.
        var moved = FormDesign.Update(form, null, [f with { Rect = f.Rect with { X = 100 }, Required = true }]);
        Assert.Equal(["Gold", "Silver", "Bronze"], FormEditor.Read(moved, null).Single().OptionLabels ?? []);
        // Editing the choices writes pairs where the text differs.
        var edited = FormDesign.Update(moved, null, [FormDesign.Read(moved, null).Single() with { Options = ["g", "p"], OptionLabels = ["Gold", "Platinum"], DefaultValue = "p" }]);
        var w = FormEditor.Read(edited, null).Single();
        Assert.Equal(["g", "p"], w.Options);
        Assert.Equal(["Gold", "Platinum"], w.OptionLabels ?? []);
        Assert.Equal("p", w.Value);
        Assert.Contains("Platinum", Core2Pdf.AllText(edited));
    }

    [Fact]
    public void DefaultAppearancesAreComparedByMeaning()
    {
        Assert.True(FormDesign.SameAppearance("/Helv 0 Tf 0 g", "/Helv 0 Tf 0 0 0 rg"));
        Assert.True(FormDesign.SameAppearance("/Helv 10 Tf 0 0 0 1 k", "/Helv 10 Tf 0 0 0 rg"));
        Assert.False(FormDesign.SameAppearance("/Helv 10 Tf 0 g", "/Helv 12 Tf 0 g"));
        Assert.True(FormDesign.SameAppearance("/ZaDb 12 Tf 0 g", "/ZaDb 0 Tf 0 0 0 rg", colorOnly: true));

        // An Acrobat check box (DA "0 g", its own face) moved: face and DA untouched.
        var form = Core2Pdf.Form(
        [
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (Ok) /Rect [72 600 86 614] /P 3 0 R /DA (/ZaDb 0 Tf 0 g) /V /Off /AS /Off /MK << /BC [0] >> /AP << /N << /Yes 6 0 R /Off 7 0 R >> >> >>",
            Core2Pdf.Stream("q 0 0 14 14 re S 2 2 10 10 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
            Core2Pdf.Stream("q 0 0 14 14 re S Q", "/Type /XObject /Subtype /Form /BBox [0 0 14 14]"),
        ]);
        var f = FormDesign.Read(form, null).Single();
        Assert.NotNull(Face(form, 0, "/N", "/Yes"));
        var moved = FormDesign.Update(form, null, [f with { Rect = f.Rect with { X = 300 } }]);
        Assert.Equal(Face(form, 0, "/N", "/Yes"), Face(moved, 0, "/N", "/Yes"));
        using var doc = Core2Pdf.Open(moved);
        Assert.Equal("/ZaDb 0 Tf 0 g", PdfObj.Str(Widget(doc, 0).Elements["/DA"]));
    }

    private static RectD Round(RectD r) => new(Math.Round(r.X, 2), Math.Round(r.Y, 2), Math.Round(r.Width, 2), Math.Round(r.Height, 2));
}
