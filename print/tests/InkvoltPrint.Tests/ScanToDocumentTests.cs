using System.IO.Compression;
using System.Text;
using System.Xml.Linq;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Office;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.Tests;

/// <summary>A scan saved straight to Word or text (roadmap 4.14): paragraphs from the recognized lines, pictures for photos.</summary>
public class ScanToDocumentTests
{
    private static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

    /// <summary>A line of words <paramref name="height"/> tall at <paramref name="top"/>.</summary>
    private static IEnumerable<OcrWord> Line(string text, double top, double height = 30)
    {
        var x = 100.0;
        foreach (var word in text.Split(' '))
        {
            yield return new OcrWord(word, x, top, word.Length * height * 0.5, height);
            x += (word.Length + 1) * height * 0.5;
        }
    }

    /// <summary>A heading, a paragraph of two lines (a word broken across them), a gap, a paragraph of one line.</summary>
    private static List<OcrWord> Letter() =>
    [
        .. Line("Quarterly report", 100, 60),
        .. Line("The year began with steady sales of ink-", 200),
        .. Line("jet paper and toner across every region.", 245),
        .. Line("Shipping costs fell in the spring.", 340),
    ];

    [Fact]
    public void Lines_become_paragraphs_and_a_heading()
    {
        var paragraphs = PageText.Paragraphs(PageText.Lines(Letter()));
        Assert.Equal(
        [
            new TextParagraph("Quarterly report", true),
            new TextParagraph("The year began with steady sales of inkjet paper and toner across every region.", false),
            new TextParagraph("Shipping costs fell in the spring.", false),
        ], paragraphs);
        Assert.Empty(PageText.Paragraphs([]));
        // A punch hole beside the heading, read as "O", isn't part of it.
        Assert.Equal("Quarterly report", PageText.Paragraphs(PageText.Lines([new OcrWord("O", 0, 100, 20, 60), .. Letter()]))[0].Text);
        // A hyphen before a capital or a number stays: "Wi-" "Fi", "2025-" "2026".
        Assert.Equal("Set up Wi- Fi", PageText.Paragraphs(PageText.Lines([.. Line("Set up Wi-", 100), .. Line("Fi", 145)]))[0].Text);
    }

    private static (XDocument Document, ZipArchive Zip) Open(byte[] docx)
    {
        var zip = new ZipArchive(new MemoryStream(docx));
        using var s = zip.GetEntry("word/document.xml")!.Open();
        return (XDocument.Load(s), zip);
    }

    [Fact]
    public void A_word_document_has_the_text_headings_and_pictures_each_page_on_its_own()
    {
        var photo = TestJpeg.Build(1800, 1200, null);
        var pages = new List<ScanDocPage>
        {
            new(Letter(), 300, []),
            new(null, 300, [photo, photo]), // two photos from the glass: stored once
            new([.. Line("Thank you", 100)], 300, []),
        };
        using var ms = new MemoryStream();
        ScanDocx.Write(ms, pages, "Report");
        var (doc, zip) = Open(ms.ToArray());
        using (zip)
        {
            var paragraphs = doc.Descendants(W + "p").ToList();
            Assert.Equal(["Quarterly report", "The year began with steady sales of inkjet paper and toner across every region.", "Shipping costs fell in the spring.", "", "", "Thank you"],
                paragraphs.Select(p => string.Concat(p.Descendants(W + "t").Select(t => t.Value))));
            Assert.Equal("Heading1", paragraphs[0].Element(W + "pPr")?.Element(W + "pStyle")?.Attribute(W + "val")?.Value);
            // The second and third scanned pages start new pages in Word; the first doesn't.
            Assert.Equal([false, false, false, true, false, true], paragraphs.Select(p => p.Element(W + "pPr")?.Element(W + "pageBreakBefore") is not null));
            Assert.Equal(2, doc.Descendants().Count(e => e.Name.LocalName == "inline"));
            Assert.Equal(2, zip.Entries.Count(e => e.FullName.StartsWith("word/media/", StringComparison.Ordinal)));
            // 6 × 4 inches at 300 dpi: its own size, in EMU.
            var extent = doc.Descendants().First(e => e.Name.LocalName == "extent");
            Assert.Equal(("5486400", "3657600"), (extent.Attribute("cx")!.Value, extent.Attribute("cy")!.Value));
            foreach (var part in new[] { "[Content_Types].xml", "_rels/.rels", "word/_rels/document.xml.rels", "word/styles.xml", "docProps/core.xml", "docProps/app.xml" })
            {
                using var s = zip.GetEntry(part)!.Open();
                Assert.NotNull(XDocument.Load(s).Root);
            }
            using var app = zip.GetEntry("docProps/app.xml")!.Open();
            Assert.Contains("Inkvolt Print", new StreamReader(app).ReadToEnd());
        }
    }

    [Fact]
    public void A_large_picture_is_made_to_fit_the_page_and_a_broken_one_is_left_out()
    {
        var (cx, cy) = ScanDocx.Size(TestJpeg.Build(2550 * 2, 3300 * 2, null), 300)!.Value; // 17 × 22 inches
        Assert.Equal((long)(ScanDocx.MaxWidth * 914400), cx);
        Assert.InRange(cy / (double)cx, 22 / 17.0 - 0.001, 22 / 17.0 + 0.001);
        Assert.Null(ScanDocx.Size([1, 2, 3], 300));
        using var ms = new MemoryStream();
        ScanDocx.Write(ms, [new ScanDocPage(null, 300, [[1, 2, 3]])], null);
        var (doc, zip) = Open(ms.ToArray());
        using (zip) Assert.Single(doc.Descendants(W + "p")); // nothing to show: the one paragraph Word needs
    }

    [Fact]
    public void Text_the_scanner_misread_into_control_characters_still_makes_a_document()
    {
        using var ms = new MemoryStream();
        ScanDocx.Write(ms, [new ScanDocPage([.. Line("bad \u0001\u0007 text \uD800 here", 100)], 300, [])], "\u0002title");
        var (doc, zip) = Open(ms.ToArray());
        using (zip) Assert.Equal("bad  text  here", string.Concat(doc.Descendants(W + "t").Select(t => t.Value)));
    }

    [Fact]
    public void A_text_file_has_the_paragraphs_and_pages_apart()
    {
        var text = ScanText.Text([new ScanDocPage(Letter(), 300, []), new ScanDocPage(null, 300, [TestJpeg.Build(10, 10, null)]), new ScanDocPage([.. Line("Thank you", 100)], 300, [])]);
        Assert.Equal("Quarterly report\r\n\r\nThe year began with steady sales of inkjet paper and toner across every region.\r\n\r\n"
            + "Shipping costs fell in the spring.\r\n\r\n\r\nThank you\r\n", text);
        Assert.Equal("", ScanText.Text([new ScanDocPage(null, 300, [])]));
        using var ms = new MemoryStream();
        ScanText.Write(ms, [new ScanDocPage([.. Line("Año nuevo", 100)], 300, [])]);
        Assert.Equal([0xEF, 0xBB, 0xBF], ms.ToArray()[..3]); // UTF-8 that Notepad and older tools read alike
        Assert.Equal("Año nuevo\r\n", Encoding.UTF8.GetString(ms.ToArray()[3..]));
    }

    [Fact]
    public void Word_and_text_presets_read_the_pages_and_save_their_kind_of_file()
    {
        var caps = new ScannerCapabilities("2.6", "Test", null, new InputCaps(0, 2550, 0, 3508, ["RGB24", "Grayscale8"], ["image/jpeg"], [300], ["Document"]), null, false);
        foreach (var type in new[] { PresetFileType.Word, PresetFileType.Text })
        {
            var preset = new ScanPreset { Id = "w", Name = "Letters", FileType = type, SmallerFile = true };
            Assert.True(PresetPlan.For(preset, caps, null, ocrAvailable: true, metric: false).Ocr);
            Assert.Single(PresetPlan.For(preset, caps, null, ocrAvailable: false, metric: false).Notes); // what it means without text recognition
            Assert.False(ScanPresets.SavesSmallerFile(preset)); // black and white is for PDFs
            Assert.False(ScanPresets.IsPdf(type));
            Assert.Equal(type, ScanPresets.Normalize(new ScanPresetSettings { Items = [preset] })[0].FileType);
        }
        Assert.Equal(".docx", ScanPresets.Extension(PresetFileType.Word));
        Assert.Equal(".txt", ScanPresets.Extension(PresetFileType.Text));
        Assert.Equal(".pdf", ScanPresets.Extension(PresetFileType.SearchablePdf));
        Assert.Contains("Word document", ScanPresetText.Summary(new ScanPreset { Name = "x", FileType = PresetFileType.Word }));
    }
}
