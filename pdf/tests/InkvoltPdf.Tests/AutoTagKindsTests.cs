using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// Make Accessible's further tag kinds: a table of contents (TOC › TOCI, nested), nested lists (L inside LBody), display
/// math (Formula with alternate text), footnotes (Note with an ID), captions (inside their table, beside their figure),
/// row headers and a header spanning columns; and a chart's labels that aren't a table.
/// </summary>
public class AutoTagKindsTests
{
    /// <summary>
    /// Page 1: a title, "Contents" and four entries with dot leaders (the third indented). Page 2: a heading, a nested
    /// list, a numbered formula, a captioned table (a header spanning two columns over Q1 and Q2, fruit names as row
    /// headers), a captioned picture, and a footnote.
    /// </summary>
    internal static byte[] Make()
    {
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        var title = new XFont("Arial", 24, XFontStyleEx.Bold);
        var heading = new XFont("Arial", 16, XFontStyleEx.Bold);
        var body = new XFont("Arial", 11);
        var bold = new XFont("Arial", 11, XFontStyleEx.Bold);
        var small = new XFont("Arial", 8);

        var page = doc.AddPage();
        page.Width = XUnit.FromPoint(612);
        page.Height = XUnit.FromPoint(792);
        using (var gfx = XGraphics.FromPdfPage(page))
        {
            gfx.DrawString("Annual Review", title, XBrushes.Black, new XPoint(72, 80));
            gfx.DrawString("Contents", heading, XBrushes.Black, new XPoint(72, 130));
            (string Text, double X, string Page)[] entries = [("Introduction", 72, "2"), ("Methods", 72, "2"), ("Data sources", 96, "3"), ("Results", 72, "3")];
            var y = 160.0;
            foreach (var (text, x, number) in entries)
            {
                gfx.DrawString(text, body, XBrushes.Black, new XPoint(x, y));
                var from = x + gfx.MeasureString(text, body).Width + 6;
                for (var dx = from; dx < 520; dx += 5) gfx.DrawString(".", body, XBrushes.Black, new XPoint(dx, y));
                gfx.DrawString(number, body, XBrushes.Black, new XPoint(530, y));
                y += 18;
            }
            gfx.DrawString("The review covers the orchard's year from planting to the harvest and the sales that followed it.", body, XBrushes.Black, new XPoint(72, y + 30));
        }

        var page2 = doc.AddPage();
        page2.Width = XUnit.FromPoint(612);
        page2.Height = XUnit.FromPoint(792);
        using (var gfx = XGraphics.FromPdfPage(page2))
        {
            gfx.DrawString("Introduction", heading, XBrushes.Black, new XPoint(72, 80));
            gfx.DrawString("The orchard grows two kinds of produce, sold at the market every week of the season.", body, XBrushes.Black, new XPoint(72, 106));
            var y = 132.0;
            foreach (var (text, level) in new[] { ("Fruit", 0), ("Apples from the hill", 1), ("Pears from the valley", 1), ("Vegetables", 0) })
            {
                var x = 84 + level * 24;
                gfx.DrawString(level == 0 ? "•" : "–", body, XBrushes.Black, new XPoint(x, y));
                gfx.DrawString(text, body, XBrushes.Black, new XPoint(x + 16, y));
                y += 16;
            }
            y += 20;
            const string formula = "y = α x + β    (1)";
            gfx.DrawString(formula, body, XBrushes.Black, new XPoint(306 - gfx.MeasureString(formula, body).Width / 2, y));
            y += 34;

            gfx.DrawString("Table 1: Fruit sold by quarter.", body, XBrushes.Black, new XPoint(72, y));
            y += 10;
            string[][] cells = [["Fruit", "2025", ""], ["", "Q1", "Q2"], ["Apples", "40", "52"], ["Pears", "12", "13"], ["Plums", "7", "8"]];
            double[] cols = [72, 252, 342, 432];
            const double rowH = 20;
            var top = y;
            for (var r = 0; r < cells.Length; r++)
                for (var c = 0; c < 3; c++)
                    if (cells[r][c].Length > 0)
                        gfx.DrawString(cells[r][c], r < 2 ? bold : body, XBrushes.Black, new XPoint(cols[c] + 6, top + r * rowH + 14));
            var pen = new XPen(XColors.Black, 0.75);
            for (var r = 0; r <= cells.Length; r++) gfx.DrawLine(pen, cols[0], top + r * rowH, cols[3], top + r * rowH);
            foreach (var x in cols)
                gfx.DrawLine(pen, x, x == cols[2] ? top + rowH : top, x, top + cells.Length * rowH); // "2025" spans two columns
            y = top + cells.Length * rowH + 30;

            var png = TestImages.Png(40, 30, (x, yy) => ((byte)(x * 6), (byte)(yy * 8), 200, 255));
            using var img = XImage.FromStream(new MemoryStream(png));
            gfx.DrawImage(img, 72, y, 160, 100);
            gfx.DrawString("North orchard", small, XBrushes.White, new XPoint(80, y + 20)); // a label on the picture
            gfx.DrawString("Figure 1: The orchard in spring.", body, XBrushes.Black, new XPoint(72, y + 116));

            gfx.DrawString("1 Weights are in crates of twelve kilos.", small, XBrushes.Black, new XPoint(72, 740));
        }
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    private static TagPlan Plan(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return AutoTag.Plan(engine, pdf, null);
    }

    private static string Show(TagPlan plan) => string.Join("\n", plan.Blocks.Select(b => $"p{b.Page} {b.Kind} {string.Concat(b.Text.Select(c => c is < ' ' or > '~' ? $"<{(int)c:X4}>" : c.ToString()))}"));

    [Fact]
    public void Plan_finds_contents_nested_list_formula_captions_note_and_table_headers()
    {
        var plan = Plan(Make());
        var why = Show(plan);
        Assert.True(plan.Blocks.Count(b => b.Kind == TagBlockKind.Contents) == 1, why);

        var toc = Assert.Single(plan.Blocks, b => b.Kind == TagBlockKind.Contents);
        Assert.Equal(0, toc.Page);
        Assert.Equal(["Introduction 2", "Methods 2", "Data sources 3", "Results 3"], toc.Items.Select(i => System.Text.RegularExpressions.Regex.Replace(i.Text, @"[\s.]+", " ")));
        Assert.Equal([0, 0, 1, 0], toc.Items.Select(i => i.Level));

        var list = Assert.Single(plan.Blocks, b => b.Kind == TagBlockKind.List);
        Assert.Equal([0, 1, 1, 0], list.Items.Select(i => i.Level));

        var formula = Assert.Single(plan.Blocks, b => b.Kind == TagBlockKind.Formula);
        Assert.Contains("=", formula.Alt);

        var table = Assert.Single(plan.Blocks, b => b.Kind == TagBlockKind.Table);
        Assert.Equal(2, table.HeaderRows);
        Assert.True(table.HeaderColumn, why);
        Assert.Equal(2, table.Rows[0][1].ColSpan);

        var captions = plan.Blocks.Where(b => b.Kind == TagBlockKind.Caption).Select(b => b.Text).ToList();
        Assert.Equal(["Table 1: Fruit sold by quarter.", "Figure 1: The orchard in spring."], captions);
        var note = Assert.Single(plan.Blocks, b => b.Kind == TagBlockKind.Note);
        Assert.StartsWith("1 Weights", note.Text);
        // The label on the picture is the picture's; body text stays paragraphs.
        Assert.DoesNotContain(plan.Blocks, b => b.Text.Contains("North orchard", StringComparison.Ordinal));
        Assert.Contains(plan.Blocks, b => b.Kind == TagBlockKind.Paragraph && b.Text.StartsWith("The orchard grows", StringComparison.Ordinal));
    }

    [Fact]
    public void Writes_toc_nested_lists_formula_note_captions_and_row_and_spanning_headers()
    {
        var pdf = Make();
        var plan = Plan(pdf);
        for (var i = 0; i < plan.Blocks.Count; i++)
            if (plan.Blocks[i].Kind == TagBlockKind.Figure) plan = AutoTag.With(plan, i, b => b with { Alt = "Blossom on apple trees" });
        var tagged = AutoTag.Write(pdf, null, plan);

        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var tree = Tree(doc);
        string Parent(PdfDictionary e) => ((PdfDictionary)((PdfReference)e.Elements["/P"]!).Value).Elements.GetName("/S").TrimStart('/');

        // Contents: TOC › TOCI ×3 at the top, the indented one in a TOC inside the entry before it.
        var tocs = tree.Where(t => t.Type == "TOC").ToList();
        Assert.Equal(2, tocs.Count);
        Assert.Equal("TOCI", Parent(tocs[1].Elem));
        Assert.Equal(4, tree.Count(t => t.Type == "TOCI"));
        // A list inside the first item's body.
        var lists = tree.Where(t => t.Type == "L").ToList();
        Assert.Equal(2, lists.Count);
        Assert.Equal("LBody", Parent(lists[1].Elem));
        Assert.Equal(4, tree.Count(t => t.Type == "LI"));
        // The formula reads as its text.
        var formula = Assert.Single(tree, t => t.Type == "Formula").Elem;
        Assert.Contains("=", formula.Elements.GetString("/Alt"));
        // The note has an ID.
        Assert.Equal("note-1", Assert.Single(tree, t => t.Type == "Note").Elem.Elements.GetString("/ID"));
        // The table's caption is its first part; the figure's stands beside it.
        var captions = tree.Where(t => t.Type == "Caption").ToList();
        Assert.Equal(2, captions.Count);
        Assert.Equal("Table", Parent(captions[0].Elem));
        Assert.Equal("Document", Parent(captions[1].Elem));
        // Headers: two rows of column headers (one spanning two columns), each data row's first cell a row header.
        var th = tree.Where(t => t.Type == "TH").Select(t => (PdfDictionary)t.Elem.Elements["/A"]!).ToList();
        Assert.Equal(3, th.Count(a => a.Elements.GetName("/Scope") == "/Row"));
        Assert.Equal(5, th.Count(a => a.Elements.GetName("/Scope") == "/Column"));
        Assert.Contains(th, a => a.Elements.GetInteger("/ColSpan") == 2);
        Assert.Equal(6, tree.Count(t => t.Type == "TD"));

        var report = AccessibilityCheck.Run(tagged, null);
        Assert.True(report.Passed, string.Join("\n", report.Failures.Select(f => $"{f.Condition} p{f.Page}: {f.Problem}")));
    }

    [Fact]
    public void Lists_and_contents_nest_by_indent_never_more_than_one_level_at_a_time()
    {
        Assert.Equal([0, 1, 1, 0, 1, 2], AutoTag.Levels([72, 96, 96, 72, 96, 120]));
        Assert.Equal([0, 1, 0], AutoTag.Levels([72, 120, 72])); // a jump of two indents is one level deeper
        Assert.Equal([0, 0, 0], AutoTag.Levels([96, 72, 72])); // the first item is the list's own level
        Assert.Equal([0, 0], AutoTag.Levels([72, 74])); // within 6 points: the same indent
    }

    [Fact]
    public void A_chart_with_labels_on_its_gridlines_isnt_a_table()
    {
        static DocCell Cell(string text) => new(text.Length == 0 ? [] : [new DocParagraph([new ExportSpan(text, "Arial", 9, false, false, 0, new RectD(0, 0, 10, 9))], new RectD(0, 0, 10, 9))]);
        DocTable Table(params string[][] rows) => new([.. rows.Select(r => (IReadOnlyList<DocCell>)[.. r.Select(Cell)])], [50, 50, 50, 50], true, new RectD(0, 0, 200, 100));

        // A bar chart's gridlines: values on the axis, a label under a bar here and there.
        Assert.False(AutoTag.PlausibleTable(Table(["100", "", "", ""], ["75", "", "", ""], ["50", "", "", ""], ["25", "", "", ""], ["0", "2022", "2023", "2024"])));
        // Labels scattered over a diagram.
        Assert.False(AutoTag.PlausibleTable(Table(["Input", "", "", ""], ["", "", "Encoder", ""], ["", "", "", "Output"])));
        // A real table, and one with a few blanks.
        Assert.True(AutoTag.PlausibleTable(Table(["Item", "Qty", "Price", "Total"], ["Apples", "4", "1.20", "4.80"], ["Pears", "12", "", "36.60"])));
        Assert.True(AutoTag.PlausibleTable(Table(["Name", "Phone", "", ""], ["Ada", "555-0101", "", ""], ["Grace", "555-0102", "", ""])));
    }

    [Theory]
    [InlineData("1 Weights are in crates of twelve kilos.", true)]
    [InlineData("4To illustrate why the dot products get large", true)]
    [InlineData("*Equal contribution. Listing order is random.", true)]
    [InlineData("†Work performed while at the lab.", true)]
    [InlineData("3x3 conv, 512, /2", false)]
    [InlineData("100 Bureau Drive (Mail Stop 2000)", false)]
    [InlineData("Weights are in crates.", false)]
    [InlineData("2 kg", false)]
    public void Footnotes_start_with_their_number_or_mark(string text, bool note) => Assert.Equal(note, AutoTag.NoteStart(text));

    [Theory]
    [InlineData("y = αx + β (1)", "Arial", true)]
    [InlineData("L = −Σ log p(x)", "CMMI10", true)]
    [InlineData("The price rose = 4 (1)", "Arial", false)]
    [InlineData("Results are summarized in Table 2 below.", "Arial", false)]
    public void Display_math_is_a_formula(string text, string font, bool formula)
    {
        var p = new DocParagraph([new ExportSpan(text, font, 11, false, false, 0, new RectD(0, 0, 100, 11))], new RectD(0, 0, 100, 11)) { Align = TextAlign.Center };
        Assert.Equal(formula, AutoTag.IsFormula(p));
    }

    private static List<(string Type, PdfDictionary Elem)> Tree(PdfDocument doc)
    {
        var list = new List<(string, PdfDictionary)>();
        void Visit(PdfItem? item)
        {
            switch (item is PdfReference r ? r.Value : item)
            {
                case PdfArray a:
                    foreach (var x in a.Elements) Visit(x);
                    break;
                case PdfDictionary d when d.Elements.GetName("/Type") == "/StructElem":
                    list.Add((d.Elements.GetName("/S").TrimStart('/'), d));
                    Visit(d.Elements["/K"]);
                    break;
            }
        }
        var root = (PdfDictionary)((PdfReference)doc.Internals.Catalog.Elements["/StructTreeRoot"]!).Value;
        Visit(root.Elements["/K"]);
        return list;
    }
}
