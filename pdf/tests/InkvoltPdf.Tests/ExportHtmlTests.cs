using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>Export to HTML (<see cref="HtmlWriter"/>): one file that reflows, and nothing from the PDF comes through as markup.</summary>
public class ExportHtmlTests
{
    internal static string Html(byte[] pdf, string? title = "Sample", ExportOptions? options = null)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        using var ms = new MemoryStream();
        var report = DocumentExport.Export(engine, ExportFormat.Html, ms, (options ?? new ExportOptions()) with { Title = title });
        Assert.True(report.Saved);
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    private static string Html(IEnumerable<ExportPage> pages, string? title = "Sample", string? language = null)
    {
        using var ms = new MemoryStream();
        DocumentExport.WriteHtml(ms, pages, title, language);
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    /// <summary>The file read as a tree: the writer's markup is well formed with its void elements closed here.</summary>
    private static XElement Dom(string html)
    {
        Assert.StartsWith("<!DOCTYPE html>", html);
        var body = html["<!DOCTYPE html>".Length..];
        body = Regex.Replace(body, @"<(meta|img|br|hr)\b([^>]*)>", "<$1$2/>");
        return XDocument.Parse(body).Root!;
    }

    private static IEnumerable<XElement> All(XElement root, string name) => root.Descendants(name);

    private static string TextOf(XElement e) => string.Concat(e.DescendantNodes().OfType<XText>().Select(t => t.Value));

    /// <summary>What no export may hold: anything that runs or fetches.</summary>
    private static void AssertInert(XElement root)
    {
        string[] banned = ["script", "iframe", "object", "embed", "link", "base", "form", "svg", "math", "video", "audio", "source", "a", "input", "button", "frame", "applet"];
        foreach (var e in root.DescendantsAndSelf())
        {
            Assert.DoesNotContain(e.Name.LocalName, banned);
            foreach (var a in e.Attributes())
            {
                Assert.False(a.Name.LocalName.StartsWith("on", StringComparison.OrdinalIgnoreCase), $"{e.Name} has {a.Name}");
                Assert.NotEqual("href", a.Name.LocalName);
                Assert.NotEqual("srcset", a.Name.LocalName);
                if (a.Name.LocalName == "src")
                    Assert.Matches("^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$", a.Value);
            }
        }
        var style = All(root, "style").Select(TextOf).Single();
        Assert.DoesNotContain("url(", style);
        Assert.DoesNotContain("@import", style);
        var csp = All(root, "meta").Single(m => (string?)m.Attribute("http-equiv") == "Content-Security-Policy");
        Assert.Contains("default-src 'none'", (string)csp.Attribute("content")!);
    }

    /// <summary>A page with a picture, and a Figure tag saying what it is (with a box: <paramref name="withBox"/>).</summary>
    internal static byte[] TaggedPdf(string alt, bool withBox = true)
    {
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        var page = doc.AddPage();
        page.Width = XUnit.FromPoint(612);
        page.Height = XUnit.FromPoint(792);
        using (var gfx = XGraphics.FromPdfPage(page))
        {
            gfx.DrawString("Sales report for the year", new XFont("Arial", 11), XBrushes.Black, new XPoint(72, 72));
            using var img = XImage.FromStream(new MemoryStream(TestImages.Png(40, 30, (x, y) => ((byte)(x * 6), (byte)(y * 8), 200, 255))));
            gfx.DrawImage(img, 72, 100, 160, 120);
        }
        var figure = new PdfDictionary(doc);
        figure.Elements["/Type"] = new PdfName("/StructElem");
        figure.Elements["/S"] = new PdfName("/Figure");
        figure.Elements["/Alt"] = new PdfString(alt, PdfStringEncoding.Unicode);
        figure.Elements["/Pg"] = page.Reference!;
        if (withBox)
        {
            var attrs = new PdfDictionary(doc);
            attrs.Elements["/O"] = new PdfName("/Layout");
            // PDF space: y up from the bottom of the 792 pt page.
            attrs.Elements["/BBox"] = new PdfArray(doc, new PdfReal(72), new PdfReal(792 - 220), new PdfReal(232), new PdfReal(792 - 100));
            figure.Elements["/A"] = attrs;
        }
        doc.Internals.AddObject(figure);
        var root = new PdfDictionary(doc);
        root.Elements["/Type"] = new PdfName("/StructTreeRoot");
        root.Elements["/K"] = figure.Reference!;
        doc.Internals.AddObject(root);
        doc.Internals.Catalog.Elements["/StructTreeRoot"] = root.Reference!;
        doc.Internals.Catalog.Elements["/Lang"] = new PdfString("es-PR");
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    private static ExportLine Line(string s, double x, double y, double size = 11, bool bold = false, bool mono = false)
    {
        var span = new ExportSpan(s, mono ? "Courier" : "Arial", size, bold, false, 0, new RectD(x, y, s.Length * size * 0.5, size * 1.2)) { Mono = mono };
        return new ExportLine([span], span.Box);
    }

    [Fact]
    public void One_file_with_real_headings_paragraphs_lists_tables_and_pictures()
    {
        var html = Html(ExportTestPdf.Make());
        ExportSamples.Save("export-sample.html", Encoding.UTF8.GetBytes(html));
        var root = Dom(html);
        AssertInert(root);
        Assert.Equal("html", root.Name.LocalName);
        Assert.DoesNotContain("http:", html);
        Assert.DoesNotContain("https:", html);
        Assert.Equal("Sample", TextOf(All(root, "title").Single()));
        Assert.Equal("utf-8", (string?)All(root, "meta").First().Attribute("charset"));

        Assert.Equal("Quarterly Report", TextOf(All(root, "h1").Single()));
        Assert.Equal(["Summary", "Prices", "Two Columns"], All(root, "h2").Select(TextOf));
        Assert.Contains(ExportTestPdf.Para1, All(root, "p").Select(TextOf));
        Assert.Equal(ExportTestPdf.Bullets, All(root, "ul").Single().Elements("li").Select(TextOf));

        var table = All(root, "table").Single();
        Assert.Equal(ExportTestPdf.Table[0], table.Element("thead")!.Descendants("th").Select(TextOf));
        Assert.All(table.Element("thead")!.Descendants("th"), th => Assert.Equal("col", (string?)th.Attribute("scope")));
        Assert.Equal(ExportTestPdf.Table[2], table.Element("tbody")!.Elements("tr").ElementAt(1).Elements("td").Select(TextOf));

        var img = All(root, "img").Single();
        Assert.StartsWith("data:image/png;base64,", (string)img.Attribute("src")!);
        Assert.NotNull(img.Attribute("alt"));
        Assert.Equal("213", (string?)img.Attribute("width")); // 160 pt
    }

    [Fact]
    public void Reads_in_order_across_columns_and_pages()
    {
        var html = Html(ExportTestPdf.Make());
        var text = TextOf(Dom(html).Element("body")!);
        var order = new[] { "Quarterly Report", "Summary", ExportTestPdf.Para1, ExportTestPdf.Bullets[2], "Prices", "Apples", "Figure 1. A picture.", "Two Columns" }
            .Select(s => text.IndexOf(s, StringComparison.Ordinal)).ToList();
        Assert.DoesNotContain(-1, order);
        Assert.Equal(order.OrderBy(i => i), order);
    }

    [Fact]
    public void Reflows_with_no_fixed_widths()
    {
        var html = Html(ExportTestPdf.Make());
        var root = Dom(html);
        Assert.Contains("max-width:100%", TextOf(All(root, "style").Single()));
        Assert.Equal("width=device-width, initial-scale=1", (string?)All(root, "meta").Single(m => (string?)m.Attribute("name") == "viewport").Attribute("content"));
        Assert.DoesNotContain("position:", html);
        Assert.DoesNotContain(root.Descendants("p"), p => p.Attribute("style") is not null);
    }

    [Fact]
    public void Everything_from_the_PDF_is_escaped()
    {
        const string evil = "<script>alert(1)</script> <img src=x onerror=alert(2)> \"quoted\" 'single' & &amp; ]]> <!-- javascript:alert(3)";
        var alt = "\"><script>alert(4)</script><img src=http://example.com/x onerror=alert(5)>";
        var title = "</title><script>alert(6)</script>";
        var png = TestImages.Png(4, 4, (_, _) => (1, 2, 3, 255));
        var picture = new ExportImage(png, "png", 4, 4, new RectD(72, 200, 40, 40)) { Alt = alt };
        var pages = new[] { new ExportPage(612, 792, [Line(evil, 72, 72), Line(evil, 72, 120, size: 30, bold: true)], [picture], []) };
        var html = Html(pages, title);
        var root = Dom(html);
        AssertInert(root);
        Assert.Equal(title, TextOf(All(root, "title").Single()));
        Assert.Equal(alt, (string?)All(root, "img").Single().Attribute("alt"));
        Assert.Contains(evil, TextOf(root.Element("body")!));
    }

    [Fact]
    public void A_table_or_list_from_the_PDF_cant_break_out_either()
    {
        const string evil = "</td></tr></table><script>alert(1)</script>";
        ExportLine L(double x, double y) => Line(evil[..8] + (int)x + (int)y, x, y);
        var rows = Enumerable.Range(0, 4).SelectMany(r => new[] { L(72, 100 + r * 20), L(300, 100 + r * 20), L(500, 100 + r * 20) }).ToList();
        var list = new[] { Line("• </li><script>alert(2)</script>", 72, 300), Line("• second", 72, 316) };
        var html = Html([new ExportPage(612, 792, [.. rows, .. list], [], [])]);
        AssertInert(Dom(html));
    }

    [Fact]
    public void Characters_HTML_forbids_are_dropped()
    {
        var bad = "a\u0001b\u0008c\u007Fd\u0085e﷐f￾g\uD800h􏿾ij";
        var html = Html([new ExportPage(612, 792, [Line(bad, 72, 72)], [], [])], "t\u0001i");
        var root = Dom(html);
        Assert.Contains("abcdefgh" + "ij", TextOf(root.Element("body")!));
        Assert.Equal("ti", TextOf(All(root, "title").Single()));
    }

    [Fact]
    public void An_empty_title_still_gives_a_title()
    {
        var root = Dom(Html([new ExportPage(612, 792, [Line("Some words on the page", 72, 72)], [], [])], "  "));
        Assert.False(string.IsNullOrWhiteSpace(TextOf(All(root, "title").Single())));
    }

    [Fact]
    public void Numbered_items_are_an_ordered_list_that_keeps_its_numbers()
    {
        var lines = new[]
        {
            Line("3. Third step of the job", 72, 100), Line("4. Fourth step of the job", 72, 116),
            Line("Some paragraph between the lists, long enough to be a paragraph of its own.", 72, 150),
            Line("a) Letter item one", 72, 190), Line("b) Letter item two", 72, 206),
            Line("(iv) Roman typed item", 72, 240), Line("(v) Roman typed item two", 72, 256),
        };
        var root = Dom(Html([new ExportPage(612, 792, lines, [], [])]));
        var ols = All(root, "ol").ToList();
        Assert.Equal(["Third step of the job", "Fourth step of the job"], ols[0].Elements("li").Select(TextOf));
        Assert.Equal(["3", "4"], ols[0].Elements("li").Select(li => (string?)li.Attribute("value")));
        Assert.Equal("a", (string?)ols[1].Attribute("type"));
        Assert.Equal(["Letter item one", "Letter item two"], ols[1].Elements("li").Select(TextOf));
        // Markers no list can show stay as typed.
        var typed = All(root, "ul").Single();
        Assert.Equal(["(iv) Roman typed item", "(v) Roman typed item two"], typed.Elements("li").Select(TextOf));
        Assert.Equal("typed", (string?)typed.Attribute("class"));
    }

    [Fact]
    public void A_deeper_indent_nests_the_list()
    {
        var lines = new[]
        {
            Line("• Outer one here", 72, 100), Line("• Inner one here", 100, 116), Line("• Inner two here", 100, 132), Line("• Outer two here", 72, 148),
        };
        var root = Dom(Html([new ExportPage(612, 792, lines, [], [])]));
        var outer = All(root, "ul").First();
        Assert.Equal(2, outer.Elements("li").Count());
        var inner = outer.Elements("li").First().Element("ul")!;
        Assert.Equal(["Inner one here", "Inner two here"], inner.Elements("li").Select(TextOf));
    }

    [Fact]
    public void Headings_never_skip_a_level()
    {
        List<ExportLine> lines = [Line("Small heading here", 72, 60, 16, true), Line("Bigger heading here", 72, 100, 32, true), Line("Second bigger heading", 72, 160, 32, true), .. Enumerable.Range(0, 20).Select(i => Line("Body text in the document fills this line.", 72, 220 + i * 14))];
        var root = Dom(Html([new ExportPage(612, 792, lines, [], [])]));
        var levels = root.Descendants().Where(e => Regex.IsMatch(e.Name.LocalName, "^h[1-6]$")).Select(e => e.Name.LocalName[1] - '0').ToList();
        Assert.Equal(1, levels[0]);
        for (var i = 1; i < levels.Count; i++) Assert.True(levels[i] <= levels[i - 1] + 1);
    }

    [Fact]
    public void A_tables_every_row_covers_every_column()
    {
        var cell = (string s) => new DocCell([new DocParagraph([new ExportSpan(s, "Arial", 11, false, false, 0, new RectD(0, 0, 10, 10))], new RectD(0, 0, 10, 10))]);
        DocTable table = new(
            [
                [cell("spans two") with { ColSpan = 2 }, cell("c")],
                [cell("short")],
                [cell("spans two more") with { ColSpan = 2 }, cell("x"), cell("over the edge")],
                [],
            ],
            [100, 100, 100], true, new RectD(72, 72, 300, 80));
        var page = new DocPage(612, 792, new RectD(72, 72, 300, 80), [table]);
        using var ms = new MemoryStream();
        HtmlWriter.Write(ms, new DocLayoutResult([page], null, null), "T", null);
        var root = Dom(Encoding.UTF8.GetString(ms.ToArray()));
        var rows = All(root, "tr").ToList();
        Assert.Equal(4, rows.Count);
        // The second column never starts a cell except where padding does: every row adds up to the same width.
        var widths = rows.Select(r => r.Elements().Sum(c => int.Parse((string?)c.Attribute("colspan") ?? "1"))).ToList();
        Assert.Single(widths.Distinct());
    }

    [Fact]
    public void A_column_no_cell_starts_in_is_taken_out()
    {
        var cell = (string s) => new DocCell([new DocParagraph([new ExportSpan(s, "Arial", 11, false, false, 0, new RectD(0, 0, 10, 10))], new RectD(0, 0, 10, 10))]);
        DocTable table = new([[cell("a") with { ColSpan = 2 }, cell("b")], [cell("c") with { ColSpan = 2 }, cell("d")]], [100, 100, 100], true, new RectD(72, 72, 300, 80));
        using var ms = new MemoryStream();
        HtmlWriter.Write(ms, new DocLayoutResult([new DocPage(612, 792, new RectD(72, 72, 300, 80), [table])], null, null), "T", null);
        var root = Dom(Encoding.UTF8.GetString(ms.ToArray()));
        Assert.All(All(root, "td"), td => Assert.Null(td.Attribute("colspan")));
    }

    [Fact]
    public void A_running_header_and_footer_appear_once()
    {
        var pages = Enumerable.Range(1, 4).Select(i => new ExportPage(612, 792,
            [Line("The Document Name", 72, 30, 9), Line($"Chapter text on page {i} that goes on for a while.", 72, 100), Line($"Page {i}", 72, 750, 9)], [], [])).ToList();
        var root = Dom(Html(pages));
        Assert.Contains("The Document Name", TextOf(root.Descendants("header").Single()));
        Assert.Single(Regex.Matches(TextOf(root.Element("body")!), "The Document Name"));
        Assert.DoesNotContain("Page 2", TextOf(root.Element("body")!));
        Assert.Contains("Chapter text on page 3", TextOf(root.Descendants("main").Single()));
    }

    [Fact]
    public void The_language_is_the_PDFs_or_is_left_out_when_it_cant_be_trusted()
    {
        var root = Dom(Html(TaggedPdf("alt"), options: new ExportOptions { Source = TaggedPdf("alt") }));
        Assert.Equal("es-PR", (string?)root.Attribute("lang"));
        var bad = Dom(Html([new ExportPage(612, 792, [Line("x y z", 72, 72)], [], [])], language: "\"><script>"));
        Assert.Null(bad.Attribute("lang"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Alt_text_comes_from_the_tags(bool withBox)
    {
        const string alt = "A chart of sales & <costs>";
        var pdf = TaggedPdf(alt, withBox);
        var root = Dom(Html(pdf, options: new ExportOptions { Source = pdf }));
        Assert.Equal(alt, (string?)All(root, "img").Single().Attribute("alt"));
    }

    [Fact]
    public void Without_tags_a_picture_has_an_empty_alt()
    {
        var root = Dom(Html(ExportTestPdf.Make(), options: new ExportOptions { Source = ExportTestPdf.Make() }));
        Assert.Equal("", (string?)All(root, "img").Single().Attribute("alt"));
    }

    [Fact]
    public void An_unreadable_source_only_loses_the_alt_text()
    {
        var pdf = ExportTestPdf.Make();
        var root = Dom(Html(pdf, options: new ExportOptions { Source = [1, 2, 3] }));
        Assert.NotEmpty(All(root, "h1"));
    }
}
