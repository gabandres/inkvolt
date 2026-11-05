using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// Make Accessible (roadmap 2.4): a ruled table's cell that spans rows (no rule under it across its columns) is one
/// cell, tagged with RowSpan, its text wherever it sits in it; the cells it covers aren't written.
/// </summary>
public class AutoTagRowSpanTests
{
    /// <summary>
    /// A ruled table: "Region" spans the two header rows beside "2025" over "Q1" and "Q2"; "North" spans two rows (its
    /// name drawn in the lower one, as centered text often lands); "South" one.
    /// </summary>
    internal static byte[] Make() => Table(
        [
            ("Region", 0, 0, true), ("2025", 0, 1, true), ("Q1", 1, 1, true), ("Q2", 1, 2, true),
            ("North", 3, 0, false), ("40", 2, 1, false), ("52", 2, 2, false), ("12", 3, 1, false), ("13", 3, 2, false),
            ("South", 4, 0, false), ("7", 4, 1, false), ("8", 4, 2, false),
        ], rows: 5, unruled: [(1, 0), (3, 0)], headerSpan: true); // none under "Region" and "North"

    /// <summary>
    /// A ruled table of three columns and <paramref name="rows"/> rows under a heading and a sentence: each rule between
    /// rows drawn across each column but those <paramref name="unruled"/> (row, column: no rule above that row there; a
    /// row with none at all keeps a short tick at its left edge, so the grid still has its line); with
    /// <paramref name="headerSpan"/> the first row's second cell spans the last two columns.
    /// </summary>
    private static byte[] Table((string Text, int Row, int Col, bool Bold)[] cells, int rows, (int Row, int Col)[] unruled, bool headerSpan = false)
    {
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        var body = new XFont("Arial", 11);
        var bold = new XFont("Arial", 11, XFontStyleEx.Bold);
        var page = doc.AddPage();
        page.Width = XUnit.FromPoint(612);
        page.Height = XUnit.FromPoint(792);
        using (var gfx = XGraphics.FromPdfPage(page))
        {
            gfx.DrawString("Sales by region", new XFont("Arial", 16, XFontStyleEx.Bold), XBrushes.Black, new XPoint(72, 80));
            gfx.DrawString("The table below gives the crates sold in each region by quarter of the year.", body, XBrushes.Black, new XPoint(72, 110));
            double[] cols = [72, 222, 342, 432];
            const double top = 140, rowH = 20;
            foreach (var (text, r, c, b) in cells)
                gfx.DrawString(text, b ? bold : body, XBrushes.Black, new XPoint(cols[c] + 6, top + r * rowH + 14));
            var pen = new XPen(XColors.Black, 0.75);
            for (var r = 0; r <= rows; r++)
            {
                var drawn = 0;
                for (var c = 0; c < 3; c++)
                    if (!unruled.Contains((r, c)))
                    {
                        gfx.DrawLine(pen, cols[c], top + r * rowH, cols[c + 1], top + r * rowH);
                        drawn++;
                    }
                if (drawn == 0) gfx.DrawLine(pen, cols[0], top + r * rowH, cols[0] + 8, top + r * rowH);
            }
            foreach (var x in cols)
                gfx.DrawLine(pen, x, headerSpan && x == cols[2] ? top + rowH : top, x, top + rows * rowH);
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

    private static PdfDictionary D(PdfItem? item) => (PdfDictionary)(item is PdfReference r ? r.Value : item)!;

    private static List<PdfDictionary> Kids(PdfDictionary e)
    {
        var k = e.Elements["/K"];
        var items = (k is PdfReference r ? r.Value : k) is PdfArray a ? a.Elements.ToList() : k is null ? [] : [k];
        return [.. items.Select(i => i is PdfReference rr ? rr.Value : i).OfType<PdfDictionary>().Where(d => d.Elements.GetName("/Type") == "/StructElem")];
    }

    private static PdfDictionary? Find(PdfDictionary e, string type) =>
        e.Elements.GetName("/S") == type ? e : Kids(e).Select(k => Find(k, type)).FirstOrDefault(x => x is not null);

    private static int Attr(PdfDictionary cell, string key) =>
        cell.Elements["/A"] is { } a && D(a).Elements.ContainsKey(key) ? D(a).Elements.GetInteger(key) : 1;

    [Fact]
    public void A_cell_spanning_rows_is_one_cell_with_its_text_wherever_it_sits()
    {
        var plan = Plan(Make());
        var table = Assert.Single(plan.Blocks, b => b.Kind == TagBlockKind.Table);
        Assert.Equal(5, table.Rows.Count);
        Assert.Equal(2, table.HeaderRows);
        Assert.True(table.HeaderColumn);
        var region = table.Rows[0][0];
        Assert.Equal("Region", region.Text);
        Assert.Equal(2, region.RowSpan);
        Assert.True(table.Rows[1][0].Covered);
        var north = table.Rows[2][0];
        Assert.Equal("North", north.Text); // drawn in the row it covers
        Assert.Equal(2, north.RowSpan);
        Assert.NotEmpty(north.Sources);
        Assert.True(table.Rows[3][0].Covered);
        Assert.Empty(table.Rows[3][0].Sources);
        Assert.Equal(1, table.Rows[4][0].RowSpan);
        Assert.All(table.Rows.SelectMany(r => r).Where(c => !c.Covered && c != region && c != north), c => Assert.Equal(1, c.RowSpan));
    }

    [Fact]
    public void Row_spans_are_written_as_RowSpan_and_covered_cells_left_out()
    {
        var pdf = Make();
        var tagged = AutoTag.Write(pdf, null, Plan(pdf));
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var root = D(doc.Internals.Catalog.Elements["/StructTreeRoot"]);
        var table = Find(Kids(root)[0], "/Table")!;
        var rows = Kids(table).Where(k => k.Elements.GetName("/S") == "/TR").ToList();
        Assert.Equal(5, rows.Count);
        var cells = rows.Select(Kids).ToList();
        Assert.Equal([2, 2, 3, 2, 3], cells.Select(c => c.Count));
        Assert.Equal("/TH", cells[0][0].Elements.GetName("/S"));
        Assert.Equal(2, Attr(cells[0][0], "/RowSpan"));
        Assert.Equal(2, Attr(cells[0][1], "/ColSpan"));
        Assert.Equal("/TH", cells[2][0].Elements.GetName("/S")); // "North", a row header over two rows
        Assert.Equal(2, Attr(cells[2][0], "/RowSpan"));
        Assert.Equal("/Row", D(cells[2][0].Elements["/A"]).Elements.GetName("/Scope"));
        Assert.All(cells[3], c => Assert.Equal("/TD", c.Elements.GetName("/S")));
        Assert.Equal(1, Attr(cells[4][0], "/RowSpan"));
        var report = AccessibilityCheck.Run(tagged, null);
        Assert.True(report.Passed, string.Join("\n", report.Failures.Select(f => $"{f.Condition}: {f.Problem}")));
    }

    [Fact]
    public void Export_to_Word_keeps_the_table_as_it_was()
    {
        // Row spans are for the tags: the exported table has its five rows of cells as before (text where it was drawn).
        var pdf = Make();
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var pages = Enumerable.Range(0, engine.PageCount).Select(p => engine.GetExportPage(p, images: true)).ToList();
        var table = DocLayout.Analyze(pages).SelectMany(p => p.Blocks).OfType<DocTable>().Single();
        Assert.Equal(5, table.Rows.Count);
        Assert.Equal("", table.Rows[2][0].Text);
        Assert.Equal("North", table.Rows[3][0].Text);
        Assert.True(table.Rows[3][0].Covered);
        Assert.Equal(2, table.Rows[2][0].RowSpan);
    }

    /// <summary>The table's rows as written: each TR's cells (type, RowSpan) and its count.</summary>
    private static List<List<(string Type, int RowSpan)>> WrittenRows(byte[] tagged)
    {
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var table = Find(Kids(D(doc.Internals.Catalog.Elements["/StructTreeRoot"]))[0], "/Table")!;
        return [.. Kids(table).Where(k => k.Elements.GetName("/S") == "/TR").Select(tr => Kids(tr).Select(c => (c.Elements.GetName("/S"), Attr(c, "/RowSpan"))).ToList())];
    }

    [Fact]
    public void A_row_all_covered_by_the_cells_above_is_no_row_of_its_own()
    {
        // Row 2 has no rule above it in any column (a tick keeps the grid's line): every cell of it continues row 1's.
        var pdf = Table(
        [
            ("Fruit", 0, 0, true), ("Q1", 0, 1, true), ("Q2", 0, 2, true),
            ("Apples", 1, 0, false), ("40", 1, 1, false), ("52", 1, 2, false), ("from the hill", 2, 0, false),
            ("Pears", 3, 0, false), ("12", 3, 1, false), ("13", 3, 2, false),
            ("Plums", 4, 0, false), ("7", 4, 1, false), ("8", 4, 2, false),
        ], rows: 5, unruled: [(2, 0), (2, 1), (2, 2)]);
        var table = Assert.Single(Plan(pdf).Blocks, b => b.Kind == TagBlockKind.Table);
        Assert.Equal(4, table.Rows.Count);
        Assert.All(table.Rows, r => Assert.Contains(r, c => !c.Covered));
        Assert.Contains("from the hill", table.Rows[1][0].Text);
        Assert.All(table.Rows.SelectMany(r => r), c => Assert.Equal(1, c.RowSpan));
        var tagged = AutoTag.Write(pdf, null, Plan(pdf));
        Assert.All(WrittenRows(tagged), r => Assert.Equal(3, r.Count));
        var report = AccessibilityCheck.Run(tagged, null);
        Assert.True(report.Passed, string.Join("\n", report.Failures.Select(f => $"{f.Condition}: {f.Problem}")));
    }

    [Fact]
    public void A_header_cell_spans_no_further_than_the_header_rows()
    {
        // "Region" has no rule under it down into the first data row: it heads the two header rows, "North" is a row of its own.
        var pdf = Table(
        [
            ("Region", 0, 0, true), ("2025", 0, 1, true), ("Q1", 1, 1, true), ("Q2", 1, 2, true),
            ("North", 2, 0, false), ("40", 2, 1, false), ("52", 2, 2, false),
            ("South", 3, 0, false), ("12", 3, 1, false), ("13", 3, 2, false),
            ("East", 4, 0, false), ("7", 4, 1, false), ("8", 4, 2, false),
        ], rows: 5, unruled: [(1, 0), (2, 0)], headerSpan: true);
        var table = Assert.Single(Plan(pdf).Blocks, b => b.Kind == TagBlockKind.Table);
        Assert.Equal(2, table.HeaderRows);
        Assert.Equal(2, table.Rows[0][0].RowSpan);
        Assert.Equal("Region", table.Rows[0][0].Text);
        Assert.False(table.Rows[2][0].Covered);
        Assert.Equal("North", table.Rows[2][0].Text);
        var rows = WrittenRows(AutoTag.Write(pdf, null, Plan(pdf)));
        Assert.Equal([2, 2, 3, 3, 3], rows.Select(r => r.Count));
        Assert.Equal(("/TH", 2), rows[0][0]);
    }

    [Fact]
    public void A_bold_row_header_over_two_rows_is_told_by_its_own_column()
    {
        // Words, not numbers, after the bold first column; one cell after it isn't bold, in the row its header covers.
        var pdf = Table(
        [
            ("Region", 0, 0, true), ("Spring", 0, 1, true), ("Autumn", 0, 2, true),
            ("North", 1, 0, true), ("high", 1, 1, true), ("low", 1, 2, true),
            ("low", 2, 1, false), ("high", 2, 2, true),
            ("South", 3, 0, true), ("high", 3, 1, true), ("high", 3, 2, true),
        ], rows: 4, unruled: [(2, 0)]);
        var table = Assert.Single(Plan(pdf).Blocks, b => b.Kind == TagBlockKind.Table);
        Assert.Equal(1, table.HeaderRows);
        Assert.Equal(2, table.Rows[1][0].RowSpan);
        Assert.True(table.HeaderColumn);
    }
}
