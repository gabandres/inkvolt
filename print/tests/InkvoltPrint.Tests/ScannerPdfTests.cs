using System.Text;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Tests;

/// <summary>
/// Scanners that only give PDF (print/ROADMAP.md 1.3): the demo inkjet's feeder set to PDF only scans the same pages, byte for
/// byte, as its JPEG run (so the split, straightening, crop and OCR the review runs on them are the same); pages that aren't one
/// JPEG are rendered; a file saved untouched is the scanner's own PDF.
/// </summary>
public sealed class ScannerPdfTests : IDisposable
{
    private const string Host = "192.0.2.11";

    public ScannerPdfTests() => ScannerPdf.Renderer = null;

    public void Dispose() => ScannerPdf.Renderer = null;

    private static string InkjetFile(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo", name);

    /// <summary>Six different pages, as a feeder batch (sizes differ, so the bytes do).</summary>
    private static readonly IReadOnlyList<byte[]> Six = [.. Enumerable.Range(0, 6).Select(i => TestJpeg.Build(2550 - i * 10, 3300, null))];

    /// <summary>The inkjet's capabilities with JPEG taken out of its feeder's profile, as demo mode serves them (Demo.FeederPdfOnly).</summary>
    private static byte[] FeederPdfOnly(byte[] capabilities)
    {
        var text = Encoding.UTF8.GetString(capabilities);
        var glass = text.IndexOf("<scan:Platen>", StringComparison.Ordinal);
        return Encoding.UTF8.GetBytes(Regex.Replace(text[..glass], @"\s*<(pwg:DocumentFormat|scan:DocumentFormatExt)>image/jpeg</\1>", "") + text[glass..]);
    }

    private static FixtureHandler Inkjet(bool feederPdfOnly, Func<byte[]>? glassPage = null, Func<string, byte[]?>? replace = null) => new(name =>
        replace?.Invoke(name) ?? (!File.Exists(InkjetFile(name)) ? null
            : name == "eSCL_ScannerCapabilities.xml" && feederPdfOnly ? FeederPdfOnly(File.ReadAllBytes(InkjetFile(name)))
            : File.ReadAllBytes(InkjetFile(name))),
        glassPage ?? (() => Six[0]), feederBatch: () => Six);

    private static async Task<List<byte[]>> ScanAsync(HttpMessageHandler printer, ScanSource source, List<string>? settings = null)
    {
        using var http = new DeviceHttp(Host, settings is null ? printer : new Spy(printer, settings));
        var client = new EsclClient(http, http.Http("/eSCL/"));
        var pages = new List<byte[]>();
        await foreach (var page in client.ScanAsync(new ScanRequest(source, Resolution: 300))) pages.Add(page);
        return pages;
    }

    [Fact]
    public async Task A_PDF_only_feeder_scans_the_same_pages_as_its_JPEG_run()
    {
        var jpegRun = await ScanAsync(Inkjet(feederPdfOnly: false), ScanSource.Adf);
        var settings = new List<string>();
        var pdfRun = await ScanAsync(Inkjet(feederPdfOnly: true), ScanSource.Adf, settings);

        Assert.Equal(6, jpegRun.Count);
        Assert.Equal(jpegRun.Count, pdfRun.Count);
        for (var i = 0; i < 6; i++) Assert.Equal(jpegRun[i], pdfRun[i]); // byte for byte: the same split, straightening, crop and OCR
        Assert.Contains(settings, s => s.Contains("<pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>", StringComparison.Ordinal));
        Assert.Contains(settings, s => s.Contains("<scan:XResolution>300</scan:XResolution>", StringComparison.Ordinal));

        // Every page knows its PDF: one for the feeder run, six pages, taken out (not rendered).
        var origins = pdfRun.Select(ScannerPdf.OriginOf).ToList();
        Assert.All(origins, o => Assert.NotNull(o));
        Assert.Single(origins.Select(o => o!.Pdf).Distinct());
        Assert.Equal([0, 1, 2, 3, 4, 5], origins.Select(o => o!.Page));
        Assert.All(origins, o => Assert.False(o!.Rendered));
        Assert.All(jpegRun, p => Assert.Null(ScannerPdf.OriginOf(p)));
    }

    [Fact]
    public async Task The_glass_and_the_feeder_still_send_JPEG_when_they_offer_it()
    {
        var text = Encoding.UTF8.GetString(FeederPdfOnly(File.ReadAllBytes(InkjetFile("eSCL_ScannerCapabilities.xml"))));
        var caps = ScannerCapabilities.Parse(System.Xml.Linq.XDocument.Parse(text));
        Assert.True(caps.Adf!.PdfOnly);
        Assert.False(caps.Platen!.PdfOnly);

        var settings = new List<string>();
        var glass = await ScanAsync(Inkjet(feederPdfOnly: true), ScanSource.Platen, settings);
        Assert.Equal(Six[0], Assert.Single(glass));
        Assert.Contains(settings, s => s.Contains("<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>", StringComparison.Ordinal));
        Assert.Null(ScannerPdf.OriginOf(glass[0]));
    }

    [Fact]
    public async Task A_PDF_only_glass_gives_its_page_from_a_one_page_PDF()
    {
        var caps = File.ReadAllText(InkjetFile("eSCL_ScannerCapabilities.xml"))
            .Replace("<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>", "").Replace("<scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>", "");
        var page = TestJpeg.Build(1275, 1650, null, components: 1);
        var glass = await ScanAsync(Inkjet(false, () => page, name => name == "eSCL_ScannerCapabilities.xml" ? Encoding.UTF8.GetBytes(caps) : null), ScanSource.Platen);

        Assert.Equal(page, Assert.Single(glass));
        Assert.Equal(1, ScannerPdf.OriginOf(glass[0])!.PageCount);
    }

    [Fact]
    public async Task A_source_with_neither_JPEG_nor_PDF_says_so()
    {
        var caps = File.ReadAllText(InkjetFile("eSCL_ScannerCapabilities.xml")).Replace("image/jpeg", "image/png").Replace("application/pdf", "image/tiff");
        var ex = await Assert.ThrowsAsync<ScanException>(() =>
            ScanAsync(Inkjet(false, replace: name => name == "eSCL_ScannerCapabilities.xml" ? Encoding.UTF8.GetBytes(caps) : null), ScanSource.Adf));
        Assert.Equal("This scanner doesn't send JPEG or PDF pages from this source, which Inkvolt Print needs.", ex.Message);
    }

    // ------------------------------------------------------------------------------------------------ taking pictures out

    private static byte[] Pdf(IReadOnlyList<PdfPage> pages)
    {
        using var ms = new MemoryStream();
        PdfWriter.Write(ms, pages, "Scan");
        return ms.ToArray();
    }

    private static byte[] Edit(byte[] pdf, string from, string to) => Encoding.Latin1.GetBytes(Encoding.Latin1.GetString(pdf).Replace(from, to));

    [Fact]
    public void Pages_that_are_one_JPEG_come_out_byte_for_byte()
    {
        var words = new List<OcrWord> { new("Invoice", 100, 100, 300, 40) };
        var pdf = Pdf([new PdfPage(Six[0], 300, words), new PdfPage(Six[1], 300), new PdfPage(TestJpeg.Build(800, 600, null, components: 1), 150)]);

        var pages = ScannerPdf.JpegPages(pdf);

        Assert.NotNull(pages);
        Assert.Equal([Six[0], Six[1], TestJpeg.Build(800, 600, null, components: 1)], pages);
    }

    [Fact]
    public void A_page_tree_with_inherited_resources_and_indirect_lengths_is_read()
    {
        var a = TestJpeg.Build(100, 200, null);
        var b = TestJpeg.Build(120, 200, null);
        var pdf = new MemoryStream();
        void Raw(string s) => pdf.Write(Encoding.Latin1.GetBytes(s));
        Raw("%PDF-1.7\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n");
        Raw("2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 2>>\nendobj\n");
        Raw("3 0 obj\n<</Type/Pages/Parent 2 0 R/Kids[4 0 R 5 0 R]/Count 2/Resources 6 0 R>>\nendobj\n");
        Raw("4 0 obj\n<</Type/Page/Parent 3 0 R/MediaBox[0 0 24 48]/Contents 9 0 R>>\nendobj\n");
        Raw("5 0 obj\n<</Type/Page/Parent 3 0 R/MediaBox[0 0 29 48]/Resources<</XObject<</X1 8 0 R>>>>/Contents 9 0 R>>\nendobj\n");
        Raw("6 0 obj\n<</XObject 10 0 R>>\nendobj\n10 0 obj\n<</Im7 7 0 R>>\nendobj\n");
        Raw($"7 0 obj\n<</Type/XObject/Subtype/Image/Width 100/Height 200/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter[/DCTDecode]/Length 11 0 R>>\nstream\r\n");
        pdf.Write(a);
        Raw($"\r\nendstream\nendobj\n11 0 obj\n{a.Length}\nendobj\n");
        Raw($"8 0 obj\n<</Type/XObject/Subtype/Image/Width 120/Height 200/ColorSpace/DeviceRGB/BitsPerComponent 8/Filter/DCTDecode>>\nstream\n");
        pdf.Write(b);
        Raw("\nendstream\nendobj\n9 0 obj\n<</Length 0>>\nstream\n\nendstream\nendobj\ntrailer\n<</Root 1 0 R/Size 12>>\n%%EOF\n");

        Assert.Equal([a, b], ScannerPdf.JpegPages(pdf.ToArray()));
    }

    [Theory]
    [InlineData("/Type /Page /Parent", "/Type /Page /Rotate 90 /Parent")] // turned: drawn, so it shows as the scanner meant
    [InlineData("/Filter /DCTDecode", "/Filter /FlateDecode")] // not a JPEG
    [InlineData("/Filter /DCTDecode", "/SMask 3 0 R /Filter /DCTDecode")] // a mask over it
    [InlineData("%PDF-1.4", "%PS-Adobe")] // not a PDF
    public void Anything_else_is_left_to_the_renderer(string from, string to)
    {
        var pdf = Edit(Pdf([new PdfPage(Six[0], 300)]), from, to);
        Assert.Null(ScannerPdf.JpegPages(pdf));
    }

    [Fact]
    public async Task Pages_that_arent_one_JPEG_are_rendered_and_without_a_renderer_it_says_so()
    {
        var flate = Edit(Pdf([new PdfPage(Six[0], 300), new PdfPage(Six[1], 300)]), "/Filter /DCTDecode", "/Filter /FlateDecode");

        var ex = await Assert.ThrowsAsync<ScanException>(() => ScannerPdf.PagesAsync(flate, 300));
        Assert.Equal("This scanner sent its pages as a PDF whose pictures Inkvolt Print can't take out here.", ex.Message);

        var renderer = new FakeRenderer([Six[4], Six[5]]);
        ScannerPdf.Renderer = renderer;
        var pages = await ScannerPdf.PagesAsync(flate, 200);

        Assert.Equal([Six[4], Six[5]], pages);
        Assert.Equal((flate, 200), renderer.Asked.Single());
        Assert.All(pages, p => Assert.True(ScannerPdf.OriginOf(p)!.Rendered));
    }

    [Fact]
    public async Task A_renderer_that_fails_is_a_scan_error_in_words()
    {
        ScannerPdf.Renderer = new FakeRenderer(null);
        var flate = Edit(Pdf([new PdfPage(Six[0], 300)]), "/Filter /DCTDecode", "/Filter /FlateDecode");
        var ex = await Assert.ThrowsAsync<ScanException>(() => ScannerPdf.PagesAsync(flate, 300));
        Assert.StartsWith("The scanner's PDF couldn't be opened:", ex.Message);
    }

    // ------------------------------------------------------------------------------------------------ keeping the scanner's PDF

    [Fact]
    public async Task Saved_untouched_the_file_is_the_scanners_own_PDF()
    {
        var pdf = Pdf([.. Six.Select(p => new PdfPage(p, 300))]);
        var pages = await ScannerPdf.PagesAsync(pdf, 300);
        List<PageToSave> Plan(Func<int, bool>? changed = null) => [.. pages.Select((p, i) => new PageToSave(ScannerPdf.OriginOf(p), changed?.Invoke(i) ?? false))];

        Assert.Same(pdf, ScannerPdf.KeepAsSent(Plan()));
        Assert.Null(ScannerPdf.WhyNotAsSent(Plan()));

        // A page turned, cropped or given a text layer: made from the pages (the JPEGs as they came), and said why.
        Assert.Null(ScannerPdf.KeepAsSent(Plan(i => i == 2)));
        Assert.Equal("Your changes (or the text layer) are in it, so it was made from the scanner's pages, pictures unchanged.",
            ScannerPdf.WhyNotAsSent(Plan(i => i == 2)));
        // A page left out (blank), moved, or a page from another scan: the same.
        Assert.Null(ScannerPdf.KeepAsSent(Plan().Skip(1).ToList()));
        Assert.Null(ScannerPdf.KeepAsSent([.. Plan().AsEnumerable().Reverse()]));
        Assert.Null(ScannerPdf.KeepAsSent([.. Plan(), new PageToSave(null, false)]));
        Assert.StartsWith("Pages were added, left out, moved or split into files", ScannerPdf.WhyNotAsSent(Plan().Skip(1).ToList()));
        // JPEG pages: nothing to keep, nothing to say.
        Assert.Null(ScannerPdf.WhyNotAsSent([new PageToSave(null, false)]));
        // A file made from the pages is the same pictures: each page's JPEG goes back in as it came.
        Assert.Equal(pages, ScannerPdf.JpegPages(Pdf([.. pages.Select(p => new PdfPage(p, 300))])));
    }

    private sealed class FakeRenderer(IReadOnlyList<byte[]>? pages) : IPdfPageRenderer
    {
        public List<(byte[], int)> Asked { get; } = [];

        public Task<IReadOnlyList<byte[]>> RenderAsync(byte[] pdf, int dpi, CancellationToken ct)
        {
            Asked.Add((pdf, dpi));
            return pages is null ? throw new InvalidOperationException("damaged") : Task.FromResult(pages);
        }
    }

    private sealed class Spy(HttpMessageHandler inner, List<string> settings) : DelegatingHandler(inner)
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            if (request.Method == HttpMethod.Post && request.Content is { } c) settings.Add(await c.ReadAsStringAsync(ct));
            return await base.SendAsync(request, ct);
        }
    }
}
