using System.Text;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>Copy Text and Copy as Table from an area boxed with Snapshot (roadmap 4.6, <see cref="AreaCopy"/>).</summary>
public class AreaCopyTests
{
    private static ExportPage Page(byte[] pdf, int page = 0)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return engine.GetExportPage(page, images: false);
    }

    private static ExportLine Line(string text, double x, double y, double size = 10)
    {
        var w = text.Length * size * 0.5;
        return ExportLine.Of([new ExportSpan(text, "Arial", size, false, false, 0, new RectD(x, y, w, size * 1.15))]);
    }

    private static RectD TableBox(ExportPage page) =>
        DocLayout.Analyze([page]).Single().Blocks.OfType<DocTable>().Single().Box;

    [Fact]
    public void TheTableTheExcelExportFindsIsCopiedCellForCell()
    {
        var page = Page(ExportTestPdf.Make());
        var box = TableBox(page);
        var table = AreaCopy.Table(AreaCopy.Clip(page, new RectD(box.X - 6, box.Y - 6, box.Width + 12, box.Height + 12)));
        Assert.Equal(ExportTestPdf.Table, table.Rows.Select(r => r.Select(c => c.Text).ToArray()).ToArray());
        Assert.Equal("Item\tQty\tPrice\r\nApples\t4\t1.20\r\nPears\t12\t3.05\r\nPlums\t7\t0.99\r\n", table.Tsv());
        Assert.StartsWith("<table><tr><td>Item</td><td>Qty</td>", table.Html());
        Assert.Equal(3, table.ColumnCount);

        // The same table without its rules: found by its columns, as the export finds it.
        var bare = Page(ExportTestPdf.Make(ruledTable: false));
        var bareBox = TableBox(bare);
        Assert.Equal(ExportTestPdf.Table, AreaCopy.Table(AreaCopy.Clip(bare, bareBox with { X = bareBox.X - 4, Width = bareBox.Width + 8 }))
            .Rows.Select(r => r.Select(c => c.Text).ToArray()).ToArray());
    }

    [Fact]
    public void ColumnsTheTableFinderDoesntTakeAreStillCells()
    {
        // Two rows of three short columns: too few for a table, still cells when copied as one.
        var page = new ExportPage(612, 792, [Line("Name", 72, 100), Line("Qty", 200, 100), Line("Total", 300, 100),
            Line("Bolts", 72, 120), Line("40", 200, 120), Line("$12.00", 300, 120), Line("Far away", 72, 600)], [], []);
        var table = AreaCopy.Table(AreaCopy.Clip(page, new RectD(60, 90, 300, 50)));
        Assert.Equal("Name\tQty\tTotal\r\nBolts\t40\t$12.00\r\n", table.Tsv());
        Assert.True(AreaCopy.Table(AreaCopy.Clip(page, new RectD(0, 300, 50, 50))).IsEmpty);
    }

    [Fact]
    public void OneCharacterLinesOnADiagonal_AreNoTableOfMillionsOfCells_ButText()
    {
        // Lines each its own row and its own column: 20,000 made 400 million cells, out of memory in Html(); 6,000 make 36 million.
        var lines = Enumerable.Range(0, 6_000).Select(i =>
            ExportLine.Of([new ExportSpan("x", "Arial", 1, false, false, 0, new RectD(i * 0.1, i * 0.13, 0.05, 0.05))])).ToList();
        var page = new ExportPage(612, 792, lines, [], []);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var table = AreaCopy.Table(AreaCopy.Clip(page, new RectD(0, 0, 612, 792)));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(30), $"took {clock.Elapsed}");
        Assert.True(table.TooLarge);
        Assert.Empty(table.Rows);
        Assert.Equal("<table></table>", table.Html());
        Assert.Contains("x", AreaCopy.Text(AreaCopy.Clip(page, new RectD(0, 0, 612, 792)))); // what is copied instead

        // At the limit's edge a table is still a table: 300 rows of 300 columns is 90,000 cells.
        var grid = Enumerable.Range(0, 300).Select(i =>
            ExportLine.Of([new ExportSpan("y", "Arial", 1, false, false, 0, new RectD(i * 2, i * 2.6, 1, 1))])).ToList();
        var square = AreaCopy.Table(new ExportPage(612, 792, grid, [], []));
        Assert.False(square.TooLarge);
        Assert.Equal(300, square.Rows.Count);
        Assert.Equal(300, square.ColumnCount);
        using var stop = new CancellationTokenSource();
        stop.Cancel();
        Assert.Throws<OperationCanceledException>(() => AreaCopy.Table(new ExportPage(612, 792, grid, [], []), stop.Token));
    }

    [Fact]
    public void TextIsCutToTheBoxAndReadInOrder()
    {
        var page = Page(ExportTestPdf.Make());
        var all = AreaCopy.Text(AreaCopy.Clip(page, new RectD(0, 0, page.Width, page.Height)));
        Assert.Contains(ExportTestPdf.Para1, all);
        Assert.DoesNotContain("\r\n\r\n", all);

        // Half a line: the characters whose middles are in the box, the line it only grazes left out.
        var line = new ExportPage(612, 792, [Line("Hello brave new world", 100, 100), Line("Next line", 100, 115)], [], []);
        var span = line.Lines[0].Spans[0].Box;
        var text = AreaCopy.Text(AreaCopy.Clip(line, new RectD(span.X + span.Width * 6 / 21.0 - 1, span.Y, span.Width * 5 / 21.0 + 2, span.Height + 2)));
        Assert.Equal("brave", text.Trim());
        Assert.False(AreaCopy.HasText(line, new RectD(100, 300, 100, 100)));
        Assert.True(AreaCopy.HasText(line, new RectD(90, 95, 30, 15)));
    }

    [Fact]
    public void ALineReadingUpwardsIsCutAlongItsOwnDirection()
    {
        // A sideways label reading bottom to top: "ABCDEF" with A at the bottom.
        var span = new ExportSpan("ABCDEF", "Arial", 10, false, false, 0, new RectD(100, 100, 12, 60));
        var page = new ExportPage(612, 792, [new ExportLine([span], span.Box, true) { Turn = 3 }], [], []);
        var clipped = AreaCopy.Clip(page, new RectD(90, 130, 40, 40)); // the lower half: A, B, C
        Assert.Equal("ABC", Assert.Single(clipped.Lines).Text);
    }

    /// <summary>Reads a dark box as one word, wherever it is in the picture it's given.</summary>
    private sealed class BoxReader : ITextRecognizer
    {
        public string Language => "en-US";
        public string LanguageName => "English";
        public (int Width, int Height) Seen { get; private set; }

        public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
        {
            Seen = (width, height);
            int x0 = width, y0 = height, x1 = -1, y1 = -1;
            for (var y = 0; y < height; y++)
                for (var x = 0; x < width; x++)
                    if (pixels[(y * width + x) * channels] < 100)
                        (x0, y0, x1, y1) = (Math.Min(x0, x), Math.Min(y0, y), Math.Max(x1, x), Math.Max(y1, y));
            return x1 < 0 ? [] : [new RecognizedWord("Total", x0, y0, x1 - x0 + 1, y1 - y0 + 1, 0)];
        }
    }

    [Fact]
    public void AnAreaWithoutTextIsReadFromItsPictureAndItsWordsLandWhereTheyAre()
    {
        // A scan's stand-in: a black box drawn at (200, 300) 80 × 20 points, no text.
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            Core2Pdf.Stream("0 g 200 472 80 20 re f"),
        ]);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var page = engine.GetExportPage(0, images: false);
        var area = new RectD(150, 280, 200, 60);
        Assert.False(AreaCopy.HasText(page, area));
        var reader = new BoxReader();
        var word = Assert.Single(AreaCopy.Recognize(engine, 0, area, reader));
        Assert.Equal("Total", word.Text);
        Assert.Equal(200, word.Rect.X, 1.0);
        Assert.Equal(300, word.Rect.Y, 1.0);
        Assert.Equal(80, word.Rect.Width, 1.0);
        Assert.InRange(reader.Seen.Width, 830, 836); // 200 points at 300 dpi
        Assert.Equal("Total", AreaCopy.Text(AreaCopy.FromWords(page, [word])));

        // Out of the page, or no area: nothing read.
        Assert.Empty(AreaCopy.Recognize(engine, 0, new RectD(700, 900, 50, 50), reader));
        Assert.Empty(AreaCopy.Recognize(engine, 3, area, reader));
        Assert.Empty(AreaCopy.Recognize(engine, 0, new RectD(double.NaN, 0, 10, 10), reader));
    }

    [Fact]
    public void TheClipboardsHtmlHeaderPointsAtTheFragment()
    {
        var fragment = new AreaTable([[new AreaCell("Año <1>"), new AreaCell("€ & co", 2)]]).Html();
        Assert.Equal("<table><tr><td>Año &lt;1&gt;</td><td colspan=\"2\">€ &amp; co</td></tr></table>", fragment);
        var bytes = ClipboardHtml.Wrap(fragment);
        var text = Encoding.UTF8.GetString(bytes);
        int Offset(string key) => int.Parse(text[(text.IndexOf(key, StringComparison.Ordinal) + key.Length)..][..10]);
        Assert.Equal(fragment, Encoding.UTF8.GetString(bytes[Offset("StartFragment:")..Offset("EndFragment:")]));
        Assert.StartsWith("<html>", Encoding.UTF8.GetString(bytes[Offset("StartHTML:")..]));
        Assert.Equal(bytes.Length, Offset("EndHTML:"));

        // A tab in a cell can't split it.
        Assert.Equal("a b\tc\r\n", new AreaTable([[new AreaCell("a\tb"), new AreaCell("c")]]).Tsv());
    }
}
