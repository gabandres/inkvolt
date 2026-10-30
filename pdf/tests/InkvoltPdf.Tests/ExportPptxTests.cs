using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;
using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using A = DocumentFormat.OpenXml.Drawing;
using P = DocumentFormat.OpenXml.Presentation;

namespace InkvoltPdf.Tests;

/// <summary>Export to PowerPoint (<see cref="PptxWriter"/>), through <see cref="DocumentExport.Export"/> and opened with the Open XML SDK.</summary>
public class ExportPptxTests
{
    private const long Emu = 12700;

    internal static byte[] Pptx(byte[] pdf, string? title = "Sample", ExportOptions? options = null)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        using var ms = new MemoryStream();
        var report = DocumentExport.Export(engine, ExportFormat.PowerPoint, ms, (options ?? new ExportOptions()) with { Title = title });
        Assert.True(report.Saved);
        return ms.ToArray();
    }

    private static void AssertValid(PresentationDocument doc)
    {
        foreach (var version in new[] { FileFormatVersions.Office2013, FileFormatVersions.Microsoft365 })
        {
            var errors = new OpenXmlValidator(version).Validate(doc).ToList();
            Assert.True(errors.Count == 0, string.Join("\n", errors.Take(10).Select(e => $"{e.Part?.Uri} {e.Path?.XPath}: {e.Description}")));
        }
    }

    private static List<P.Slide> Slides(PresentationDocument doc)
    {
        var part = doc.PresentationPart!;
        return [.. part.Presentation.SlideIdList!.Elements<P.SlideId>().Select(id => ((SlidePart)part.GetPartById(id.RelationshipId!)).Slide)];
    }

    private static List<SlidePart> SlideParts(PresentationDocument doc)
    {
        var part = doc.PresentationPart!;
        return [.. part.Presentation.SlideIdList!.Elements<P.SlideId>().Select(id => (SlidePart)part.GetPartById(id.RelationshipId!))];
    }

    private static P.Shape? TitleOf(P.Slide slide) => slide.Descendants<P.Shape>().FirstOrDefault(s =>
        s.NonVisualShapeProperties?.ApplicationNonVisualDrawingProperties?.PlaceholderShape?.Type?.Value == P.PlaceholderValues.Title);

    private static List<P.Shape> TextBoxes(P.Slide slide) => [.. slide.Descendants<P.Shape>().Where(s => s.TextBody is not null)];

    private static string Text(P.Shape s) => string.Join("\n", s.TextBody!.Elements<A.Paragraph>().Select(p => string.Concat(p.Descendants<A.Text>().Select(t => t.Text))));

    /// <summary>A page with one each of the simple shapes, a polygon and a label.</summary>
    private static byte[] ShapesPdf()
    {
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        var page = doc.AddPage();
        page.Width = XUnit.FromPoint(612);
        page.Height = XUnit.FromPoint(792);
        using (var gfx = XGraphics.FromPdfPage(page))
        {
            gfx.DrawRectangle(new XSolidBrush(XColor.FromArgb(200, 30, 40)), 72, 100, 120, 60);
            gfx.DrawRectangle(new XPen(XColor.FromArgb(10, 120, 50), 2), 240, 100, 120, 60);
            gfx.DrawEllipse(new XSolidBrush(XColor.FromArgb(20, 60, 200)), 400, 100, 100, 60);
            gfx.DrawLine(new XPen(XColor.FromArgb(90, 20, 150), 1.5), 72, 220, 500, 220);
            gfx.DrawPolygon(new XSolidBrush(XColor.FromArgb(240, 160, 0)), new[] { new XPoint(100, 300), new XPoint(200, 300), new XPoint(150, 380) }, XFillMode.Winding);
            gfx.DrawString("A label beside the shapes", new XFont("Arial", 11), XBrushes.Black, new XPoint(72, 500));
        }
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    private static byte[] MixedSizesPdf()
    {
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        foreach (var (w, h, text) in new[] { (612.0, 792.0, "First"), (612.0, 792.0, "Second"), (792.0, 612.0, "Wide page"), (2000.0, 3000.0, "Huge page") })
        {
            var page = doc.AddPage();
            page.Width = XUnit.FromPoint(w);
            page.Height = XUnit.FromPoint(h);
            using var gfx = XGraphics.FromPdfPage(page);
            gfx.DrawString(text, new XFont("Arial", 14), XBrushes.Black, new XPoint(w - 150, h - 60));
        }
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    [Fact]
    public void One_valid_slide_per_page_at_the_pages_size()
    {
        var bytes = Pptx(ExportTestPdf.Make());
        ExportSamples.Save("export-sample.pptx", bytes);
        using var doc = PresentationDocument.Open(new MemoryStream(bytes), false);
        AssertValid(doc);
        Assert.Equal(2, Slides(doc).Count);
        var size = doc.PresentationPart!.Presentation.SlideSize!;
        Assert.Equal(612 * Emu, size.Cx!.Value);
        Assert.Equal(792 * Emu, size.Cy!.Value);
        Assert.Equal("Sample", doc.PackageProperties.Title);
    }

    [Fact]
    public void Headings_title_the_slides_and_text_is_editable_boxes_in_reading_order()
    {
        using var doc = PresentationDocument.Open(new MemoryStream(Pptx(ExportTestPdf.Make())), false);
        var slides = Slides(doc);
        Assert.Equal("Quarterly Report", Text(TitleOf(slides[0])!));
        Assert.Equal("Two Columns", Text(TitleOf(slides[1])!));

        var page1 = TextBoxes(slides[0]).Select(Text).ToList();
        Assert.Contains(ExportTestPdf.Para1, page1);
        // In PowerPoint the order on the slide is the reading order.
        var summary = page1.IndexOf("Summary");
        Assert.True(summary >= 0 && summary < page1.IndexOf(ExportTestPdf.Para1));
        Assert.True(page1.IndexOf(ExportTestPdf.Para1) < page1.IndexOf(ExportTestPdf.Para2));

        // Where it is on the page, at its size, in its font.
        var heading = TextBoxes(slides[0]).Single(s => Text(s) == "Summary");
        var xfrm = heading.ShapeProperties!.Transform2D!;
        Assert.Equal(72, xfrm.Offset!.X!.Value / (double)Emu, 0);
        var run = heading.Descendants<A.Run>().First().RunProperties!;
        Assert.Equal(1600, run.FontSize!.Value);
        Assert.True(run.Bold!.Value);
        Assert.Equal("Arial", run.GetFirstChild<A.LatinFont>()!.Typeface!.Value);
    }

    [Fact]
    public void A_list_is_one_box_with_real_bullets()
    {
        using var doc = PresentationDocument.Open(new MemoryStream(Pptx(ExportTestPdf.Make())), false);
        var box = TextBoxes(Slides(doc)[0]).Single(s => Text(s).Contains(ExportTestPdf.Bullets[0]));
        var paragraphs = box.TextBody!.Elements<A.Paragraph>().ToList();
        Assert.Equal(ExportTestPdf.Bullets, paragraphs.Select(p => string.Concat(p.Descendants<A.Text>().Select(t => t.Text))));
        Assert.All(paragraphs, p => Assert.Equal("•", p.ParagraphProperties!.GetFirstChild<A.CharacterBullet>()!.Char!.Value));
    }

    [Fact]
    public void Pictures_are_pictures_stored_once_and_tables_are_tables()
    {
        using var doc = PresentationDocument.Open(new MemoryStream(Pptx(ExportTestPdf.Make(logo: true))), false);
        AssertValid(doc);
        var parts = SlideParts(doc);
        // The logo on both pages is one picture in the file.
        Assert.True(parts[0].Slide.Descendants<P.Picture>().Count() >= 2);
        Assert.Single(parts[1].Slide.Descendants<P.Picture>());
        var logo1 = parts[0].Slide.Descendants<P.Picture>().Single(p => p.ShapeProperties!.Transform2D!.Offset!.X!.Value == 492 * Emu);
        var logo2 = parts[1].Slide.Descendants<P.Picture>().Single();
        Assert.Equal(parts[0].GetPartById(logo1.BlipFill!.Blip!.Embed!).Uri, parts[1].GetPartById(logo2.BlipFill!.Blip!.Embed!).Uri);

        var table = parts[0].Slide.Descendants<A.Table>().Single();
        var rows = table.Elements<A.TableRow>().ToList();
        Assert.Equal(ExportTestPdf.Table.Length, rows.Count);
        Assert.Equal(ExportTestPdf.Table[2], rows[2].Elements<A.TableCell>().Select(c => c.InnerText.Trim()));
        Assert.Equal(3, table.TableGrid!.Elements<A.GridColumn>().Count());
    }

    [Fact]
    public void Simple_shapes_are_shapes_with_their_colors_and_others_are_pictures()
    {
        var bytes = Pptx(ShapesPdf());
        ExportSamples.Save("export-shapes.pptx", bytes);
        using var doc = PresentationDocument.Open(new MemoryStream(bytes), false);
        AssertValid(doc);
        var slide = Slides(doc)[0];
        var shapes = slide.Descendants<P.Shape>().Where(s => s.TextBody is null).ToList();

        var filled = shapes.Single(s => s.ShapeProperties!.GetFirstChild<A.PresetGeometry>()!.Preset!.Value == A.ShapeTypeValues.Rectangle && s.ShapeProperties.GetFirstChild<A.SolidFill>() is not null);
        Assert.Equal("C81E28", filled.ShapeProperties!.GetFirstChild<A.SolidFill>()!.RgbColorModelHex!.Val!.Value);
        Assert.Equal(72, filled.ShapeProperties.Transform2D!.Offset!.X!.Value / (double)Emu, 0);
        Assert.Equal(120, filled.ShapeProperties.Transform2D!.Extents!.Cx!.Value / (double)Emu, 0);

        var outline = shapes.Single(s => s.ShapeProperties!.GetFirstChild<A.PresetGeometry>()!.Preset!.Value == A.ShapeTypeValues.Rectangle && s.ShapeProperties.GetFirstChild<A.NoFill>() is not null);
        Assert.Equal("0A7832", outline.ShapeProperties!.GetFirstChild<A.Outline>()!.GetFirstChild<A.SolidFill>()!.RgbColorModelHex!.Val!.Value);
        Assert.Equal(240, outline.ShapeProperties.Transform2D!.Offset!.X!.Value / (double)Emu, 0);
        Assert.Equal(120, outline.ShapeProperties.Transform2D!.Extents!.Cx!.Value / (double)Emu, 0);
        Assert.Equal(2 * Emu, outline.ShapeProperties.GetFirstChild<A.Outline>()!.Width!.Value, 3000.0);

        var ellipse = shapes.Single(s => s.ShapeProperties!.GetFirstChild<A.PresetGeometry>()!.Preset!.Value == A.ShapeTypeValues.Ellipse);
        Assert.Equal("143CC8", ellipse.ShapeProperties!.GetFirstChild<A.SolidFill>()!.RgbColorModelHex!.Val!.Value);

        var line = slide.Descendants<P.ConnectionShape>().Single();
        Assert.Equal(A.ShapeTypeValues.Line, line.ShapeProperties!.GetFirstChild<A.PresetGeometry>()!.Preset!.Value);
        Assert.Equal("5A1496", line.ShapeProperties.GetFirstChild<A.Outline>()!.GetFirstChild<A.SolidFill>()!.RgbColorModelHex!.Val!.Value);

        // The triangle isn't a simple shape: it stays as it looks, a picture.
        Assert.Single(slide.Descendants<P.Picture>());
        Assert.Contains("A label beside the shapes", TextBoxes(slide).Select(Text));

        // Shapes lie behind the text and pictures.
        var order = slide.CommonSlideData!.ShapeTree!.ChildElements.ToList();
        Assert.True(order.IndexOf(filled) < order.IndexOf(TextBoxes(slide).Single()));
    }

    [Fact]
    public void A_pages_table_rules_are_the_tables_not_loose_lines()
    {
        using var doc = PresentationDocument.Open(new MemoryStream(Pptx(ExportTestPdf.Make())), false);
        var slide = Slides(doc)[0];
        Assert.Empty(slide.Descendants<P.ConnectionShape>());
    }

    [Fact]
    public void Pages_of_other_sizes_fit_the_slide_centered()
    {
        var bytes = Pptx(MixedSizesPdf());
        using var doc = PresentationDocument.Open(new MemoryStream(bytes), false);
        AssertValid(doc);
        var size = doc.PresentationPart!.Presentation.SlideSize!;
        // The size most pages have.
        Assert.Equal(612 * Emu, size.Cx!.Value);
        Assert.Equal(792 * Emu, size.Cy!.Value);
        var slides = Slides(doc);
        Assert.Equal(4, slides.Count);
        foreach (var slide in slides)
        foreach (var t in TextBoxes(slide))
        {
            var x = t.ShapeProperties!.Transform2D!;
            Assert.InRange(x.Offset!.X!.Value, 0, size.Cx.Value);
            Assert.InRange(x.Offset.Y!.Value, 0, size.Cy.Value);
            Assert.InRange(x.Offset.X.Value + x.Extents!.Cx!.Value, 0, size.Cx.Value);
        }
        // Scaled pages' type is scaled with them.
        var huge = TextBoxes(slides[3]).Single();
        Assert.True(huge.Descendants<A.Run>().First().RunProperties!.FontSize!.Value < 1400);
        Assert.Equal(1400, TextBoxes(slides[0]).Single().Descendants<A.Run>().First().RunProperties!.FontSize!.Value);
    }

    [Theory]
    [InlineData(20, 30)]        // under PowerPoint's 1 inch
    [InlineData(5000, 300)]     // over its 56 inches
    public void The_slide_stays_within_what_PowerPoint_allows(double w, double h)
    {
        TestPdf.UseFonts();
        using var pdf = new PdfDocument();
        var page = pdf.AddPage();
        page.Width = XUnit.FromPoint(w);
        page.Height = XUnit.FromPoint(h);
        using (var gfx = XGraphics.FromPdfPage(page))
            gfx.DrawString("Text", new XFont("Arial", 6), XBrushes.Black, new XPoint(2, 10));
        using var ms = new MemoryStream();
        pdf.Save(ms, false);
        using var doc = PresentationDocument.Open(new MemoryStream(Pptx(ms.ToArray())), false);
        AssertValid(doc);
        var size = doc.PresentationPart!.Presentation.SlideSize!;
        Assert.InRange(size.Cx!.Value, 914400, 51206400);
        Assert.InRange(size.Cy!.Value, 914400, 51206400);
    }

    [Fact]
    public void Text_from_the_PDF_is_only_ever_text()
    {
        var evil = "</a:t><p:sp xmlns:p=\"x\">&amp;<script>\u0001\u0008￾ \uD800 end";
        var span = new ExportSpan(evil, "Evil\"Font<&\u0002", 12, false, false, 0, new RectD(72, 72, 300, 14));
        var page = new ExportPage(612, 792, [new ExportLine([span], span.Box)], [], []);
        using var ms = new MemoryStream();
        DocumentExport.WritePptx(ms, [page], "T</dc:title>\u0001<x>", null);
        ms.Position = 0;
        using var doc = PresentationDocument.Open(ms, false);
        AssertValid(doc);
        var text = Text(TextBoxes(Slides(doc)[0]).Single());
        Assert.Contains("<script>", text);
        Assert.Contains("</a:t>", text);
        Assert.DoesNotContain('\u0001', text);
    }

    [Fact]
    public void A_line_set_sideways_is_a_turned_text_box()
    {
        var up = new ExportSpan("Sideways stamp", "Arial", 10, false, false, 0, new RectD(20, 200, 12, 100));
        var body = new ExportSpan("Body text on the page", "Arial", 12, false, false, 0, new RectD(72, 72, 200, 14));
        var page = new ExportPage(612, 792, [new ExportLine([up], up.Box, Sideways: true) { Turn = 3 }, new ExportLine([body], body.Box)], [], []);
        using var ms = new MemoryStream();
        DocumentExport.WritePptx(ms, [page], null, null);
        ms.Position = 0;
        using var doc = PresentationDocument.Open(ms, false);
        AssertValid(doc);
        var box = TextBoxes(Slides(doc)[0]).Single(s => Text(s) == "Sideways stamp");
        var x = box.ShapeProperties!.Transform2D!;
        Assert.Equal(270 * 60000, x.Rotation!.Value);
        // Unturned its box is as long as the line; turned about its center it lands where the page has it.
        Assert.Equal(100 * Emu, x.Extents!.Cx!.Value);
        Assert.Equal(12 * Emu, x.Extents.Cy!.Value);
        Assert.Equal(26 * Emu, x.Offset!.X!.Value + x.Extents.Cx.Value / 2);
        Assert.Equal(250 * Emu, x.Offset.Y!.Value + x.Extents.Cy.Value / 2);
    }

    [Fact]
    public void A_blank_page_is_an_empty_slide_and_a_slide_without_a_heading_has_no_title()
    {
        var text = new ExportSpan("Only body text here on this page and more of it.", "Arial", 11, false, false, 0, new RectD(72, 72, 300, 14));
        using var ms = new MemoryStream();
        DocumentExport.WritePptx(ms, [new ExportPage(612, 792, [new ExportLine([text], text.Box)], [], []), new ExportPage(612, 792, [], [], [])], null, null);
        ms.Position = 0;
        using var doc = PresentationDocument.Open(ms, false);
        AssertValid(doc);
        var slides = Slides(doc);
        Assert.Equal(2, slides.Count);
        Assert.Null(TitleOf(slides[0]));
        Assert.Empty(TextBoxes(slides[1]));
    }

    [Fact]
    public void A_running_head_never_titles_the_slide()
    {
        ExportLine Line(string s, double y, double size, bool bold = false)
        {
            var span = new ExportSpan(s, "Arial", size, bold, false, 0, new RectD(72, y, 200, size * 1.2));
            return new ExportLine([span], span.Box);
        }
        var pages = Enumerable.Range(1, 4).Select(i => new ExportPage(612, 792,
            [Line("The Big Running Head", 30, 18, true), Line($"Chapter {i}", 100, 24, true), .. Enumerable.Range(0, 10).Select(k => Line($"Body line number {k} of the page with enough words.", 150 + k * 16, 11))], [], [])).ToList();
        using var ms = new MemoryStream();
        DocumentExport.WritePptx(ms, pages, null, null);
        ms.Position = 0;
        using var doc = PresentationDocument.Open(ms, false);
        var slides = Slides(doc);
        for (var i = 0; i < 4; i++)
        {
            Assert.Equal($"Chapter {i + 1}", Text(TitleOf(slides[i])!));
            // The head stays on each slide, as the page has it.
            Assert.Contains("The Big Running Head", TextBoxes(slides[i]).Select(Text));
        }
    }

    [Fact]
    public void Alt_text_from_the_tags_goes_on_the_picture()
    {
        var tagged = ExportHtmlTests.TaggedPdf("A chart of sales & <costs>");
        var bytes = Pptx(tagged, options: new ExportOptions { Source = tagged });
        using var doc = PresentationDocument.Open(new MemoryStream(bytes), false);
        AssertValid(doc);
        var pic = Slides(doc)[0].Descendants<P.Picture>().First();
        Assert.Equal("A chart of sales & <costs>", pic.NonVisualPictureProperties!.NonVisualDrawingProperties!.Description!.Value);
    }
}

/// <summary>Saves an export where <c>INKVOLTPDF_SAMPLES</c> says, to open by hand.</summary>
internal static class ExportSamples
{
    public static void Save(string name, byte[] bytes)
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is not { Length: > 0 } dir) return;
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, name), bytes);
    }
}
