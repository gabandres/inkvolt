using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;
using DocumentFormat.OpenXml.Wordprocessing;
using InkvoltPdf.Core;
using MuPDFCore;
using X = DocumentFormat.OpenXml.Spreadsheet;

namespace InkvoltPdf.Tests;

public class ExportTests
{
    private static List<ExportPage> Read(byte[] pdf, string? password = null)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, password);
        return [.. Enumerable.Range(0, engine.PageCount).Select(i => engine.GetExportPage(i, images: true))];
    }

    private static byte[] Docx(IEnumerable<ExportPage> pages, string? title = "Sample")
    {
        using var ms = new MemoryStream();
        DocumentExport.WriteDocx(ms, pages, title);
        return ms.ToArray();
    }

    private static void AssertValid(OpenXmlPackage doc)
    {
        var errors = new OpenXmlValidator(FileFormatVersions.Office2013).Validate(doc).ToList();
        Assert.True(errors.Count == 0, string.Join("\n", errors.Take(10).Select(e => $"{e.Part?.Uri} {e.Path?.XPath}: {e.Description}")));
    }

    private static string Style(Paragraph p) => p.ParagraphProperties?.ParagraphStyleId?.Val?.Value ?? "";

    private static List<Paragraph> BodyParagraphs(WordprocessingDocument doc) =>
        [.. doc.MainDocumentPart!.Document.Body!.Elements<Paragraph>().Where(p => p.InnerText.Length > 0)];

    [Fact]
    public void Word_export_is_valid_and_keeps_headings_paragraphs_lists_tables_and_pictures()
    {
        var bytes = Docx(Read(ExportTestPdf.Make()));
        SaveSample("export-sample.docx", bytes);
        using var doc = WordprocessingDocument.Open(new MemoryStream(bytes), false);
        AssertValid(doc);
        var paras = BodyParagraphs(doc);
        var texts = paras.Select(p => p.InnerText).ToList();

        // Headings by size: the 24 pt title is level 1, the 16 pt headings level 2.
        Assert.Equal("Heading1", Style(paras.Single(p => p.InnerText == "Quarterly Report")));
        Assert.Equal("Heading2", Style(paras.Single(p => p.InnerText == "Summary")));
        Assert.Equal("Heading2", Style(paras.Single(p => p.InnerText == "Prices")));
        Assert.Equal("Heading2", Style(paras.Single(p => p.InnerText == "Two Columns")));

        // Wrapped lines are one paragraph again; the italic words keep their look.
        Assert.Contains(ExportTestPdf.Para1, texts);
        var p2 = paras.Single(p => p.InnerText == ExportTestPdf.Para2);
        Assert.Contains(p2.Descendants<Run>(), r => r.InnerText.Contains("same page.") && r.RunProperties?.Italic is not null);
        Assert.Contains(paras.Single(p => p.InnerText == "Quarterly Report").Descendants<Run>(),
            r => r.RunProperties?.Bold is not null && r.RunProperties.FontSize?.Val == "48" && r.RunProperties.RunFonts?.Ascii == "Arial");

        // Bullets are Word bullets (numbering), without the typed bullet character.
        var bullets = paras.Where(p => p.ParagraphProperties?.NumberingProperties is not null).Select(p => p.InnerText).ToList();
        Assert.Equal(ExportTestPdf.Bullets, bullets);

        // The ruled table, cell by cell.
        var table = Assert.Single(doc.MainDocumentPart!.Document.Body!.Elements<Table>());
        var cells = table.Elements<TableRow>().Select(r => r.Elements<TableCell>().Select(c => c.InnerText).ToArray()).ToArray();
        Assert.Equal(ExportTestPdf.Table, cells);

        // The picture is embedded inline.
        Assert.Single(doc.MainDocumentPart.ImageParts);
        Assert.Single(doc.MainDocumentPart.Document.Descendants<DocumentFormat.OpenXml.Drawing.Wordprocessing.Inline>());

        // Page 2's columns read left column first, each whole.
        var left = texts.FindIndex(t => t.StartsWith("The left column", StringComparison.Ordinal));
        var right = texts.FindIndex(t => t.StartsWith("The right column", StringComparison.Ordinal));
        Assert.True(left >= 0 && right > left, string.Join(" | ", texts));
        Assert.EndsWith("every autumn.", texts[left]);
        Assert.EndsWith("cellar room.", texts[right]);

        // Each PDF page is a section with its own size (612 x 792 pt = 12240 x 15840 twips).
        var sections = doc.MainDocumentPart.Document.Descendants<SectionProperties>().ToList();
        Assert.Equal(2, sections.Count);
        Assert.All(sections, s => Assert.Equal(12240u, s.GetFirstChild<PageSize>()!.Width!.Value));
        Assert.Equal("Sample", doc.PackageProperties.Title);
    }

    [Fact]
    public void Repeated_logo_goes_to_the_header_once_and_icons_stay_in_their_cells()
    {
        using var doc = WordprocessingDocument.Open(new MemoryStream(Docx(Read(ExportTestPdf.Make(logo: true)))), false);
        AssertValid(doc);
        var main = doc.MainDocumentPart!;
        Assert.Equal(3, main.ImageParts.Count()); // logo (stored once), icon, figure
        var header = Assert.Single(main.HeaderParts);
        Assert.Single(header.Header.Descendants<DocumentFormat.OpenXml.Drawing.Wordprocessing.Inline>());
        Assert.Single(header.ImageParts);
        var table = Assert.Single(main.Document.Body!.Elements<Table>());
        var pears = table.Elements<TableRow>().ElementAt(2).Elements<TableCell>().First();
        Assert.Equal("Pears", pears.InnerText);
        Assert.Single(pears.Descendants<DocumentFormat.OpenXml.Drawing.Wordprocessing.Inline>());
        Assert.Equal(2, main.Document.Body.Descendants<DocumentFormat.OpenXml.Drawing.Wordprocessing.Inline>().Count()); // icon + figure
    }

    [Fact]
    public void Text_aligned_in_columns_without_lines_is_a_table()
    {
        var pages = Read(ExportTestPdf.Make(ruledTable: false));
        var laid = DocLayout.Analyze(pages);
        var table = Assert.Single(laid[0].Blocks.OfType<DocTable>());
        Assert.False(table.Ruled);
        Assert.Equal(ExportTestPdf.Table, table.Rows.Select(r => r.Select(c => c.Text).ToArray()).ToArray());
        // The paragraphs and the list around it are untouched.
        Assert.Contains(laid[0].Blocks.OfType<DocParagraph>(), p => p.Text == ExportTestPdf.Para1);
        Assert.Equal(3, laid[0].Blocks.OfType<DocParagraph>().Count(p => p.List == ListKind.Bullet));
        // Two text columns are not a table.
        Assert.Empty(laid[1].Blocks.OfType<DocTable>());
    }

    [Fact]
    public void Excel_export_has_a_sheet_per_table_with_numbers_as_numbers()
    {
        var pages = Read(ExportTestPdf.Make());
        var tables = DocumentExport.Tables(pages.Select((p, i) => (i + 1, p)));
        var (name, table) = Assert.Single(tables);
        Assert.Equal("Page 1", name);
        using var ms = new MemoryStream();
        XlsxWriter.Write(ms, tables, "Sample");
        SaveSample("export-sample.xlsx", ms.ToArray());
        ms.Position = 0;
        using var book = SpreadsheetDocument.Open(ms, false);
        AssertValid(book);
        var sheet = Assert.Single(book.WorkbookPart!.Workbook.Sheets!.Elements<X.Sheet>());
        Assert.Equal("Page 1", sheet.Name!.Value);
        var ws = ((WorksheetPart)book.WorkbookPart.GetPartById(sheet.Id!)).Worksheet;
        var cells = ws.Descendants<X.Cell>().ToDictionary(c => c.CellReference!.Value!);
        Assert.Equal("Item", cells["A1"].InnerText);
        Assert.Equal(X.CellValues.InlineString, cells["A1"].DataType!.Value);
        Assert.Equal("1", cells["A1"].StyleIndex!.Value.ToString()); // bold header
        Assert.Null(cells["B2"].DataType);                            // a number
        Assert.Equal("4", cells["B2"].CellValue!.Text);
        Assert.Equal("3.05", cells["C3"].CellValue!.Text);
        Assert.Equal(12, cells.Count);
    }

    [Fact]
    public void Plain_text_reads_paragraphs_lists_and_table_rows_in_order()
    {
        var text = DocumentExport.PlainText(Read(ExportTestPdf.Make()));
        var lines = text.Split("\r\n");
        Assert.Equal("Quarterly Report", lines[0]);
        Assert.Contains(ExportTestPdf.Para1, lines);
        Assert.Contains("• First point in the list", lines);
        Assert.Contains("Apples\t4\t1.20", lines);
        Assert.True(Array.IndexOf(lines, "Apples\t4\t1.20") < Array.FindIndex(lines, l => l.StartsWith("The left column", StringComparison.Ordinal)));
    }

    [Fact]
    public void Encrypted_pdf_exports_once_opened()
    {
        var pdf = TestPdf.Encrypted(2, "secret");
        using var doc = WordprocessingDocument.Open(new MemoryStream(Docx(Read(pdf, "secret"))), false);
        AssertValid(doc);
        Assert.Contains(BodyParagraphs(doc), p => p.InnerText.StartsWith("Page 2 alpha", StringComparison.Ordinal));
    }

    [Fact]
    public void Scanned_page_keeps_its_picture_without_text_and_drops_it_once_recognized()
    {
        var png = TestImages.Png(20, 26, (_, _) => (250, 250, 250, 255));
        var scan = new ExportImage(png, "png", 20, 26, new RectD(0, 0, 612, 792));
        var bare = new ExportPage(612, 792, [], [scan], []);
        var laidBare = DocLayout.Analyze([bare]);
        Assert.IsType<DocPicture>(Assert.Single(laidBare[0].Blocks));

        var words = new[]
        {
            new OcrWord("Hello", new RectD(72, 100, 40, 12)), new OcrWord("world", new RectD(116, 101, 42, 12)),
            new OcrWord("Second", new RectD(72, 116, 50, 12)), new OcrWord("line", new RectD(126, 116, 30, 12)),
        };
        var ocr = bare with { Lines = ExportPage.LinesFromOcr(words), FromOcr = true };
        var laid = DocLayout.Analyze([ocr]);
        var p = Assert.IsType<DocParagraph>(Assert.Single(laid[0].Blocks));
        Assert.Equal("Hello world Second line", p.Text);
        using var doc = WordprocessingDocument.Open(new MemoryStream(Docx([ocr])), false);
        AssertValid(doc);
        Assert.Empty(doc.MainDocumentPart!.ImageParts);
    }

    [Fact]
    public void Ocr_words_form_lines_split_at_wide_gaps()
    {
        var words = new[]
        {
            new OcrWord("Name", new RectD(72, 100, 40, 12)), new OcrWord("Total", new RectD(400, 99, 40, 13)),
            new OcrWord("Apples", new RectD(72, 120, 50, 12)), new OcrWord("4", new RectD(400, 121, 8, 11)),
            new OcrWord("big", new RectD(130, 120, 25, 12)),
        };
        var lines = ExportPage.LinesFromOcr(words);
        Assert.Equal(["Name", "Total", "Apples big", "4"], lines.Select(l => l.Text));
        Assert.All(lines, l => Assert.InRange(l.Size, 12, 16));
    }

    [Fact]
    public void Empty_document_still_makes_a_valid_file()
    {
        using var doc = WordprocessingDocument.Open(new MemoryStream(Docx([new ExportPage(612, 792, [], [], [])])), false);
        AssertValid(doc);
        using var none = WordprocessingDocument.Open(new MemoryStream(Docx([])), false);
        AssertValid(none);
    }

    // ---- layout details on synthetic lines ----

    private static ExportLine Line(string text, double x, double y, double size = 11, bool bold = false, string font = "Arial")
    {
        var w = text.Length * size * 0.5;
        return ExportLine.Of([new ExportSpan(text, font, size, bold, false, 0, new RectD(x, y, w, size * 1.15))]);
    }

    [Fact]
    public void Hyphenated_line_ends_are_rejoined_and_short_lines_end_paragraphs()
    {
        // Lines 14 pt apart; the second paragraph starts after a line that ends short.
        var page = new ExportPage(612, 792,
        [
            Line("This sentence has a word that wraps over two exam-", 72, 100),
            Line("ples of lines in the original document text here.", 72, 114),
            Line("Short end.", 72, 128),
            Line("Next paragraph begins here and runs a long way on.", 72, 142),
        ], [], []);
        var laid = DocLayout.Analyze([page]);
        var paras = laid[0].Blocks.OfType<DocParagraph>().Select(p => p.Text).ToList();
        Assert.Equal(
        [
            "This sentence has a word that wraps over two examples of lines in the original document text here. Short end.",
            "Next paragraph begins here and runs a long way on.",
        ], paras);
    }

    [Fact]
    public void Heading_levels_follow_sizes_across_the_document()
    {
        ExportPage P(params ExportLine[] lines) => new(612, 792, lines, [], []);
        var body = string.Join(' ', Enumerable.Repeat("body text", 6));
        var pages = new[]
        {
            P(Line("Title", 72, 72, 28), Line("Part", 72, 120, 18), Line(body, 72, 160)),
            P(Line("Other part", 72, 72, 18), Line("Small head", 72, 110, 14), Line(body + " more", 72, 140)),
        };
        var laid = DocLayout.Analyze(pages);
        var levels = laid.SelectMany(p => p.Blocks.OfType<DocParagraph>()).GroupBy(p => p.Text).ToDictionary(g => g.Key, g => g.Single().HeadingLevel);
        Assert.Equal(1, levels["Title"]);
        Assert.Equal(2, levels["Part"]);
        Assert.Equal(2, levels["Other part"]);
        Assert.Equal(3, levels["Small head"]);
        Assert.Equal(0, levels[body]);
        Assert.Equal(0, levels[body + " more"]);
    }

    [Fact]
    public void Repeated_top_and_bottom_lines_become_the_header_and_footer_with_a_page_number()
    {
        var body = string.Join(' ', Enumerable.Repeat("body text", 6));
        var pages = Enumerable.Range(1, 3).Select(n => new ExportPage(612, 792,
        [
            Line("Acme Annual Report", 72, 30), Line($"Chapter text {n} " + body, 72, 100),
            Line("Confidential", 72, 760), Line($"Page {n}", 500, 760),
        ], [], [])).ToList();
        pages.Insert(0, new ExportPage(612, 792, [Line("Cover", 200, 300, 30)], [], [])); // no header or footer on it
        var result = DocLayout.AnalyzeDocument(pages);
        Assert.All(result.Pages, p => Assert.DoesNotContain(p.Blocks.OfType<DocParagraph>(), b => b.Text.Contains("Acme") || b.Text.Contains("Page")));
        var header = Assert.Single(Assert.Single(result.Header!.Rows).Parts);
        Assert.Equal("Acme Annual Report", header.Span.Text);
        var footer = Assert.Single(result.Footer!.Rows).Parts;
        Assert.Equal([(TextAlign.Left, "Confidential"), (TextAlign.Right, "Page " + DocLayout.PageField)], footer.Select(f => (f.Zone, f.Span.Text)));

        using var doc = WordprocessingDocument.Open(new MemoryStream(Docx(pages)), false);
        AssertValid(doc);
        var main = doc.MainDocumentPart!;
        var sections = main.Document.Descendants<SectionProperties>().ToList();
        Assert.Equal(4, sections.Count);
        string HeaderText(SectionProperties s) => ((HeaderPart)main.GetPartById(s.GetFirstChild<HeaderReference>()!.Id!)).Header.InnerText;
        Assert.Equal("", HeaderText(sections[0])); // the cover keeps no header
        Assert.All(sections.Skip(1), s => Assert.Equal("Acme Annual Report", HeaderText(s)));
        var ftr = (FooterPart)main.GetPartById(sections[1].GetFirstChild<FooterReference>()!.Id!);
        Assert.Equal(" PAGE ", Assert.Single(ftr.Footer.Descendants<SimpleField>()).Instruction!.Value);
        // Plain text leaves them out.
        Assert.DoesNotContain("Acme", DocumentExport.PlainText(pages));
    }

    [Theory]
    [InlineData("• Item", true)]
    [InlineData("- Item", true)]
    [InlineData(" Item", true)]
    [InlineData("1. Item", false)]
    [InlineData("(a) Item", false)]
    [InlineData("iv) Item", false)]
    [InlineData("7.2.1. Drives", false)]
    [InlineData("8.1 Clock Window", false)]
    public void List_markers(string text, bool bullet)
    {
        var m = DocLayout.ListMarker(text);
        Assert.NotNull(m);
        Assert.Equal(bullet, m.Value.Bullet);
    }

    [Theory]
    [InlineData("e.g. this")]
    [InlineData("2024 was a year")]
    [InlineData("-5 degrees")]
    [InlineData("3.5 percent more")]
    public void Not_list_markers(string text) => Assert.Null(DocLayout.ListMarker(text));

    [Theory]
    [InlineData("ABCDEF+ArialMT", "Arial")]
    [InlineData("Arial-BoldMT", "Arial")]
    [InlineData("Arial,Bold", "Arial")]
    [InlineData("TimesNewRomanPSMT", "Times New Roman")]
    [InlineData("Times-Roman", "Times New Roman")]
    [InlineData("Helvetica-Oblique", "Arial")]
    [InlineData("Calibri", "Calibri")]
    [InlineData("SegoeUI", "Segoe UI")]
    [InlineData("CourierNewPSMT", "Courier New")]
    public void Font_families(string pdfName, string family) => Assert.Equal(family, FontNames.Family(pdfName));

    [Theory]
    [InlineData("12", 12.0)]
    [InlineData("-3.5", -3.5)]
    [InlineData("1,234.50", 1234.5)]
    [InlineData("0.99", 0.99)]
    [InlineData("007", null)]
    [InlineData("$5", null)]
    [InlineData("12%", null)]
    [InlineData("1.234,50", null)]
    [InlineData("1234567890123456", null)]
    public void Excel_numbers(string text, double? value) => Assert.Equal(value, XlsxWriter.Number(text));

    [Fact]
    public void Excel_sheet_names_and_columns()
    {
        Assert.Equal(["Page 1", "page 1 (2)", "a b", new string('x', 31), new string('x', 27) + " (2)"],
            XlsxWriter.SheetNames(["Page 1", "page 1", "a/b", new string('x', 40), new string('x', 31)]));
        Assert.Equal("A", XlsxWriter.Column(0));
        Assert.Equal("Z", XlsxWriter.Column(25));
        Assert.Equal("AA", XlsxWriter.Column(26));
    }

    /// <summary>With INKVOLTPDF_SAMPLES set, writes the exported files there to open in Word / Excel.</summary>
    private static void SaveSample(string name, byte[] bytes)
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } dir)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, name), bytes);
            if (!name.EndsWith(".docx", StringComparison.Ordinal)) return;
            var pdf = ExportTestPdf.Make(logo: true);
            File.WriteAllBytes(Path.Combine(dir, "export-sample.pdf"), pdf);
            // The same pages as scans (pictures only), for trying OCR in the app.
            using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
            var scans = new List<(byte[], string)>();
            for (var i = 0; i < engine.PageCount; i++)
            {
                var png = Path.Combine(dir, $"scan-{i + 1}.png");
                engine.SaveImage(i, 200, png, jpeg: false);
                scans.Add((File.ReadAllBytes(png), png));
                File.Delete(png);
            }
            File.WriteAllBytes(Path.Combine(dir, "export-scan.pdf"), ImageImport.ImagesToPdf(scans));
        }
    }
}
