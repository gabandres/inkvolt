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
    internal static byte[] Make()
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
            (string Text, int Row, int Col, bool Bold)[] cells =
            [
                ("Region", 0, 0, true), ("2025", 0, 1, true), ("Q1", 1, 1, true), ("Q2", 1, 2, true),
                ("North", 3, 0, false), ("40", 2, 1, false), ("52", 2, 2, false), ("12", 3, 1, false), ("13", 3, 2, false),
                ("South", 4, 0, false), ("7", 4, 1, false), ("8", 4, 2, false),
            ];
            foreach (var (text, r, c, b) in cells)
                gfx.DrawString(text, b ? bold : body, XBrushes.Black, new XPoint(cols[c] + 6, top + r * rowH + 14));
            var pen = new XPen(XColors.Black, 0.75);
            for (var r = 0; r <= 5; r++)
                gfx.DrawLine(pen, r is 1 or 3 ? cols[1] : cols[0], top + r * rowH, cols[3], top + r * rowH); // none under "Region" and "North"
            foreach (var x in cols)
                gfx.DrawLine(pen, x, x == cols[2] ? top + rowH : top, x, top + 5 * rowH); // "2025" spans two columns
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
}
