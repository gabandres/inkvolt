using System.Buffers.Binary;
using System.IO.Compression;
using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>Export fixes found on real documents: turned tables, transparent pictures, hyphens, indented blocks, charts, close number columns.</summary>
public class ExportRealWorldTests
{
    private static ExportLine Line(string text, double x, double y, double size = 10, int turn = 0)
    {
        var w = text.Length * size * 0.5;
        var h = size * 1.15;
        // A turned line's box stands across the page: tall and narrow.
        var box = turn is 1 or 3 ? new RectD(x, y, h, w) : new RectD(x, y, w, h);
        return ExportLine.Of([new ExportSpan(text, "Arial", size, false, false, 0, box)], turn != 0) with { Turn = turn };
    }

    private static List<string> Paragraphs(DocPage page) => [.. page.Blocks.OfType<DocParagraph>().Select(p => p.Text)];

    [Fact]
    public void A_page_of_text_turned_sideways_is_laid_out_turned_back_as_a_landscape_page()
    {
        // A portrait page whose text reads bottom to top (a landscape table set on its side), with an upright footer.
        // Lines read upward: the first line is leftmost, each line's text runs up the page.
        var lines = new List<ExportLine>
        {
            Line("Table A-2. Households by income", 60, 300, 12, turn: 3),
            Line("The first paragraph of the turned page runs over", 90, 200, 10, turn: 3),
            Line("two lines that belong together in one paragraph.", 102, 200, 10, turn: 3),
            Line("U.S. Census Bureau", 400, 760, 8),
        };
        // Upward lines: their tops face left, so the box's right edge is the baseline side; place the boxes as MuPDF would.
        var page = new ExportPage(612, 792, lines, [], []);
        var up = DocLayout.Upright(page);
        Assert.Equal((792.0, 612.0), (up.Width, up.Height));
        Assert.All(up.Lines.Where(l => l.Text.StartsWith("T", StringComparison.Ordinal)), l => Assert.False(l.Sideways));

        var laid = DocLayout.Analyze([page]).Single();
        Assert.True(laid.Width > laid.Height); // exported as a landscape section
        var paras = Paragraphs(laid);
        Assert.Contains("The first paragraph of the turned page runs over two lines that belong together in one paragraph.", paras);
        Assert.Contains("U.S. Census Bureau", paras); // the upright footer is now the sideways part: one paragraph
        Assert.True(paras.IndexOf("Table A-2. Households by income") < paras.IndexOf("The first paragraph of the turned page runs over two lines that belong together in one paragraph."));
    }

    [Fact]
    public void A_few_sideways_lines_on_an_upright_page_read_as_one_paragraph()
    {
        var body = string.Join(' ', Enumerable.Repeat("upright body text", 4));
        var lines = new List<ExportLine>
        {
            Line(body, 72, 100), Line(body, 72, 114), Line(body, 72, 128),
            // A margin stamp of two lines reading upward.
            Line("arXiv:1512.03385v1 [cs.CV] 10 Dec", 20, 300, 10, turn: 3),
            Line("2015 submitted version", 32, 360, 10, turn: 3), // both lines start at the same bottom
        };
        var laid = DocLayout.Analyze([new ExportPage(612, 792, lines, [], [])]).Single();
        Assert.True(laid.Width < laid.Height);
        var paras = Paragraphs(laid);
        Assert.Equal(2, paras.Count);
        Assert.Contains("arXiv:1512.03385v1 [cs.CV] 10 Dec 2015 submitted version", paras);
    }

    [Fact]
    public void Turning_a_page_maps_boxes_into_the_turned_frame()
    {
        var page = new ExportPage(600, 800, [Line("x", 10, 20, 10, turn: 3)], [], [new RectD(100, 200, 50, 0)]);
        var up = page.Turned(3);
        Assert.Equal((800.0, 600.0), (up.Width, up.Height));
        // (x, y) -> (h - y, x): the rule at y 200 from x 100 to 150 becomes a vertical rule at x 600.
        Assert.Equal(new RectD(600, 100, 0, 50), up.Rules[0]);
        Assert.Equal(0, up.Lines[0].Turn);
        var down = page.Turned(1);
        Assert.Equal(new RectD(200, 450, 0, 50), down.Rules[0]); // (x, y) -> (y, w - x)
    }

    [Theory]
    [InlineData(1, 0, 0)]
    [InlineData(0.99, 0.05, 0)]
    [InlineData(0, -1, 3)]
    [InlineData(0, 1, 1)]
    [InlineData(-1, 0, 2)]
    public void Turns_from_baseline_directions(double dx, double dy, int turn) => Assert.Equal(turn, ExportLine.TurnOf(dx, dy));

    private static DocLayoutResult Layout(params ExportLine[] lines) => DocLayout.AnalyzeDocument([new ExportPage(612, 792, lines, [], [])]);

    [Fact]
    public void Soft_hyphens_at_line_ends_rejoin_the_word_and_hard_hyphens_stay_in_such_documents()
    {
        var r = Layout(
            Line("Income inequality and access to educa­", 72, 100),
            Line("tion changed little for the equivalence-", 72, 112),
            Line("adjusted measure in this ex­ample year.", 72, 124));
        var text = Assert.Single(Paragraphs(r.Pages[0]));
        Assert.Equal("Income inequality and access to education changed little for the equivalence-adjusted measure in this example year.", text);
    }

    [Fact]
    public void Hard_hyphens_at_line_ends_are_dropped_unless_both_halves_are_words_the_document_uses()
    {
        var r = Layout(
            Line("The rate of change was measured in the study with an exam-", 72, 100),
            Line("ple of the method; the result was fairly steady and well-", 72, 112),
            Line("known. Readers know the well known steady example well.", 72, 124));
        var text = Assert.Single(Paragraphs(r.Pages[0]));
        Assert.Contains("an example of the method", text);
        Assert.Contains("well-known.", text);
    }

    [Fact]
    public void An_indented_justified_block_stays_one_paragraph_beside_wider_text()
    {
        // An abstract indented on both sides (right edge 480) above a wider footnote (right edge 560): its lines end at
        // 480, short of the column's edge, but they fill the block.
        string L(int n) => new('a', n);
        var r = Layout(
            Line($"{L(30)} {L(30)} {L(9)}", 120, 100),  // 70 chars x 5 = 350 wide: 120..470
            Line($"{L(30)} {L(31)} {L(8)}", 120, 112),
            Line($"{L(30)} {L(30)} {L(9)}", 120, 124),
            Line($"{L(1)} {L(30)} {L(30)} end.", 120, 136), // its first word is short enough to fit the column's edge
            Line($"{L(20)} last line.", 120, 148),
            Line("Footnote " + new string('f', 88), 72, 200));
        var paras = Paragraphs(r.Pages[0]);
        Assert.Equal(2, paras.Count);
        Assert.EndsWith("last line.", paras[0]);
    }

    [Fact]
    public void Short_lines_of_an_address_stay_apart()
    {
        var r = Layout(
            Line("Bermuda Supplies Ltd.", 72, 100),
            Line("12 Harbour Road", 72, 112),
            Line("Hamilton", 72, 124),
            Line("Thank you for your order, which ships on Monday with the usual courier service.", 72, 150));
        Assert.Equal(4, Paragraphs(r.Pages[0]).Count);
    }

    [Fact]
    public void A_chart_drawn_with_many_paths_and_few_labels_is_a_figure_and_a_ruled_table_is_not()
    {
        // A bar chart: 12 bars and 2 axes, with a few labels.
        var chart = new List<(RectD, bool)> { (new RectD(100, 100, 0.5, 200), true), (new RectD(100, 300, 300, 0.5), true) };
        for (var i = 0; i < 12; i++) chart.Add((new RectD(110 + i * 24, 300 - 10 * (i + 3), 18, 10 * (i + 3)), false));
        var labels = new List<ExportLine> { Line("2010", 110, 304, 8), Line("2020", 360, 304, 8), Line("Income", 86, 180, 8) };
        var figures = DocLayout.FigureRegions(chart, labels, 612, 792);
        var f = Assert.Single(figures);
        Assert.True(f.Contains(100, 100) && f.Contains(400, 300) && f.Contains(88, 182)); // the labels go with it

        // A ruled 4 x 4 table with text in every cell: rules but not a figure.
        var grid = new List<(RectD, bool)>();
        for (var k = 0; k <= 4; k++)
        {
            grid.Add((new RectD(100, 400 + k * 20, 320, 0.5), true));
            grid.Add((new RectD(100 + k * 80, 400, 0.5, 80), true));
        }
        for (var k = 0; k < 4; k++) grid.Add((new RectD(100 + k * 80, 400, 80, 20), false)); // header shading
        var cells = Enumerable.Range(0, 16).Select(i => Line($"v{i}", 105 + i % 4 * 80, 404 + i / 4 * 20, 8)).ToList();
        Assert.Empty(DocLayout.FigureRegions(grid, cells, 612, 792));
    }

    [Fact]
    public void Number_columns_set_close_together_split_but_words_with_wide_spaces_do_not()
    {
        // "28.54" then "10.02" 14 pt later (size 9): two columns.
        var chars = new List<(string, double, double, double)>();
        void Word(string w, double x)
        {
            foreach (var c in w)
            {
                chars.Add((c.ToString(), x, x + 4.5, 9));
                x += 4.5;
            }
        }
        Word("28.54", 100);
        chars.Add((" ", 122.5, 136, 9));
        Word("10.02", 136.5);
        Assert.Equal([(0, 5), (6, 11)], ExportLine.SplitAtColumnGaps(chars));

        chars.Clear();
        Word("hello", 100);
        chars.Add((" ", 122.5, 136, 9));
        Word("world", 136.5); // the same gap between words: justified text, one line
        Assert.Equal([(0, 11)], ExportLine.SplitAtColumnGaps(chars));
        Assert.True(ExportLine.NumberLike("–") && ExportLine.NumberLike("(3.5)") && !ExportLine.NumberLike("top-1"));
    }

    [Fact]
    public void A_long_table_cut_into_row_groups_is_one_table_and_leaders_are_dropped_in_Excel()
    {
        // Two groups of rows with a gap between them, as long statistical tables are set.
        var page = new ExportPage(612, 792, [Line("2023 . . . . .", 72, 100, 9), Line("12", 160, 100, 9), Line("7.5", 200, 100, 9),
            Line("2022 . . . . .", 72, 112, 9), Line("11", 160, 112, 9), Line("7.1", 200, 112, 9),
            Line("2021 . . . . .", 72, 124, 9), Line("10", 160, 124, 9), Line("6.8", 200, 124, 9),
            Line("2019 . . . . .", 72, 150, 9), Line("9", 160, 150, 9), Line("6.0", 200, 150, 9),
            Line("2018 . . . . .", 72, 162, 9), Line("8", 160, 162, 9), Line("5.5", 200, 162, 9),
            Line("2017 . . . . .", 72, 174, 9), Line("7", 160, 174, 9), Line("5.1", 200, 174, 9)], [], []);
        var tables = DocumentExport.Tables([(1, page)]);
        var (_, table) = Assert.Single(tables);
        Assert.Equal(6, table.Rows.Count);

        using var ms = new MemoryStream();
        XlsxWriter.Write(ms, tables, null);
        ms.Position = 0;
        using var book = DocumentFormat.OpenXml.Packaging.SpreadsheetDocument.Open(ms, false);
        var first = book.WorkbookPart!.WorksheetParts.Single().Worksheet.Descendants<DocumentFormat.OpenXml.Spreadsheet.Cell>().First();
        Assert.Equal("2023", first.CellValue!.Text); // leaders gone, so it is a number
    }

    [Fact]
    public void A_transparent_picture_keeps_its_transparency()
    {
        TestPdf.UseFonts();
        // Left half fully transparent, right half opaque red.
        var png = TestImages.Png(40, 40, (x, _) => x < 20 ? ((byte)0, (byte)0, (byte)0, (byte)0) : ((byte)220, (byte)20, (byte)20, (byte)255));
        using var doc = new PdfDocument();
        var page = doc.AddPage();
        using (var gfx = XGraphics.FromPdfPage(page))
        using (var img = XImage.FromStream(new MemoryStream(png)))
            gfx.DrawImage(img, 100, 100, 80, 80);
        using var ms = new MemoryStream();
        doc.Save(ms, false);

        using var engine = PdfEngine.Open(ms.ToArray(), InputFileTypes.PDF, null);
        var picture = Assert.Single(engine.GetExportPage(0, images: true).Images);
        Assert.Equal("png", picture.Extension);
        var (w, h, colorType, pixels) = DecodePng(picture.Data);
        Assert.Equal(6, colorType); // RGBA
        Assert.Equal(0, pixels[(h / 2 * w + 2) * 4 + 3]);                                                // left: transparent
        Assert.Equal((255, true), (pixels[(h / 2 * w + w - 3) * 4 + 3], pixels[(h / 2 * w + w - 3) * 4] > 200)); // right: opaque red
    }

    /// <summary>Reads a PNG written without row filters (as Core's encoder writes them).</summary>
    private static (int W, int H, int ColorType, byte[] Pixels) DecodePng(byte[] png)
    {
        int w = 0, h = 0, type = 0;
        using var idat = new MemoryStream();
        for (var at = 8; at < png.Length;)
        {
            var len = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            var kind = System.Text.Encoding.ASCII.GetString(png, at + 4, 4);
            if (kind == "IHDR")
            {
                w = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at + 8));
                h = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at + 12));
                type = png[at + 17];
            }
            else if (kind == "IDAT") idat.Write(png, at + 8, len);
            at += 12 + len;
        }
        idat.Position = 0;
        using var z = new ZLibStream(idat, CompressionMode.Decompress);
        using var raw = new MemoryStream();
        z.CopyTo(raw);
        var bpp = type == 6 ? 4 : 3;
        var data = raw.ToArray();
        var pixels = new byte[w * h * bpp];
        for (var y = 0; y < h; y++)
        {
            Assert.Equal(0, data[y * (w * bpp + 1)]); // no filter
            Array.Copy(data, y * (w * bpp + 1) + 1, pixels, y * w * bpp, w * bpp);
        }
        return (w, h, type, pixels);
    }
}
