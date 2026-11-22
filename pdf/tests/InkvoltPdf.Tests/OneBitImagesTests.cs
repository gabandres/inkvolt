using System.Text;
using InkvoltPdf.Bench;
using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Suite;
using MuPDFCore;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>
/// Smaller black-and-white scans (roadmap 4.8): File › Scan's black-and-white pages at 1 bit (<see cref="ScanRun.ToPdf"/>),
/// Recognize Text's cleaned page of a black-and-white scan kept at 1 bit (<see cref="ScanPage"/>), and Reduce File Size's
/// lossless recoding of 1-bit pictures and, when asked, grey scans of text made black and white (<see cref="OneBitImages"/>).
/// </summary>
public class OneBitImagesTests
{
    private static readonly Lazy<(byte[] Gray, int Width, int Height)> Page = new(() =>
    {
        var (pixels, w, h, _) = ScanCorpus.MakePage(ScanCorpus.Files.Single(f => f.Name == "en-skew3-light"), 0);
        return (pixels, w, h);
    });

    /// <summary>The page's grey pixels, every <paramref name="step"/>th row and column: a smaller page for quicker tests.</summary>
    private static (byte[] Gray, int Width, int Height) Smaller(int step)
    {
        var (gray, w, h) = Page.Value;
        var (sw, sh) = (w / step, h / step);
        var small = new byte[sw * sh];
        for (var y = 0; y < sh; y++)
            for (var x = 0; x < sw; x++) small[y * sw + x] = gray[y * step * w + x * step];
        return (small, sw, sh);
    }

    private static string Latin1(byte[] b) => Encoding.Latin1.GetString(b);

    /// <summary>A Letter page drawing one picture over all of it.</summary>
    private static byte[] OnePicturePage(string imageDict, byte[] data) => Core2Pdf.Build(
    [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Im 5 0 R >> >> >>",
        Core2Pdf.Stream("q 612 0 0 792 0 0 cm /Im Do Q"),
        Core2Pdf.Stream(Latin1(data), imageDict),
    ]);

    private static PdfDictionary Picture(PdfDocument doc) =>
        PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/Im"])!;

    private static byte[] Pixels(byte[] pdf, double scale = 0.5)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return engine.Render(0, scale).Pixels;
    }

    /// <summary>A 1-bit picture's rows as /DeviceGray reads them (0 black): a set bit of <paramref name="bits"/> cleared.</summary>
    private static byte[] Samples(BitImage bits)
    {
        var raw = new byte[bits.Bits.Length];
        var tail = (byte)(0xFF << (8 * bits.Stride - bits.Width));
        for (var i = 0; i < raw.Length; i++) raw[i] = (byte)(i % bits.Stride == bits.Stride - 1 ? ~bits.Bits[i] & tail : ~bits.Bits[i]);
        return raw;
    }

    [Fact]
    public void ScannedInBlackAndWhiteAPageIsSavedAtOneBitAndInGreyAsItsJpeg()
    {
        var (gray, w, h) = Page.Value;
        var jpeg = JpegEncoder.EncodeGray(gray, w, h, 85, 300);
        var other = JpegEncoder.EncodeGray(gray, w, h, 80, 300);
        var decoded = 0;
        var pdf = ScanRun.ToPdf([(jpeg, 300, true), (jpeg, 300, false), (other, 300, true)], "Scan", j =>
        {
            Interlocked.Increment(ref decoded);
            return j == other ? throw new InvalidOperationException("not a picture") : (gray, w, h);
        });
        Assert.Equal(2, decoded); // the grey page isn't decoded
        var text = Latin1(pdf);
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(text, "/JBIG2Decode"));
        Assert.Equal(2, System.Text.RegularExpressions.Regex.Matches(text, "/DCTDecode").Count); // the page that couldn't be decoded stays as scanned
        Assert.True(pdf.Length < jpeg.Length + other.Length + jpeg.Length / 20, $"{pdf.Length} vs JPEGs {jpeg.Length} + {other.Length}");

        // What the page shows is the scan in black and white, as Inkvolt Print saves it.
        var bits = Bilevel.FromScan(gray, w, h, 300);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        Assert.Equal(612, engine.GetPage(0).Width, 1.0);
        var shown = engine.Render(0, 300 / 72.0);
        Assert.Equal((w, h), (shown.Width, shown.Height));
        var differ = 0;
        for (var y = 0; y < h; y += 3)
            for (var x = 0; x < w; x += 3)
                if (bits[x, y] != shown.Pixels[(y * w + x) * 3] < 128) differ++;
        Assert.Equal(0, differ);
    }

    [Fact]
    public void AScanOfTextLooksBlackAndWhiteAndAPhotoDoesnt()
    {
        var (gray, w, h) = Page.Value;
        Assert.True(OneBitImages.LooksBlackAndWhite(gray, w, h));
        var (noisy, nw, nh, _) = ScanCorpus.MakePage(ScanCorpus.Files.Single(f => f.Name == "en-skew6-noisy"), 0);
        Assert.True(OneBitImages.LooksBlackAndWhite(noisy, nw, nh));
        Assert.True(OneBitImages.LooksBlackAndWhite(new byte[1000].Select(_ => (byte)250).ToArray(), 40, 25)); // blank paper

        // A photo: shades all through.
        var rng = new Random(4);
        var photo = new byte[400 * 300];
        for (var y = 0; y < 300; y++)
            for (var x = 0; x < 400; x++) photo[y * 400 + x] = (byte)Math.Clamp(x * 255 / 400 + rng.Next(-20, 20), 0, 255);
        Assert.False(OneBitImages.LooksBlackAndWhite(photo, 400, 300));
        // Text on dark paper: ink and paper too close.
        Assert.False(OneBitImages.LooksBlackAndWhite(gray.Select(v => (byte)(60 + v / 3)).ToArray(), w, h));
        Assert.False(OneBitImages.LooksBlackAndWhite([], 0, 0));
    }

    [Fact]
    public void ReduceFileSizeCodesABlackAndWhitePictureAgainWithoutLosingAPixel()
    {
        var (gray, w, h) = Smaller(2);
        var bits = Bilevel.FromScan(gray, w, h, 150);
        var flate = PdfObj.Deflate(Samples(bits));
        var pdf = OnePicturePage($"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode", flate);
        var result = Optimizer.Optimize(pdf, null, new OptimizeOptions { MaxImageDpi = null });
        Assert.Equal(1, result.ImagesBlackAndWhite);
        using (var doc = Core2Pdf.Open(result.Data))
        {
            var image = Picture(doc);
            Assert.Equal("JBIG2Decode", PdfObj.Name(image.Elements["/Filter"]));
            Assert.Equal(1, PdfObj.Int(image.Elements["/BitsPerComponent"]));
            Assert.True(image.Stream!.Value.Length * 4 < flate.Length * 3, $"{image.Stream.Value.Length} vs Flate {flate.Length}");
        }
        Assert.Equal(Pixels(pdf, 1), Pixels(result.Data, 1));

        // Again: nothing smaller to be had, so it stays as it is.
        Assert.Equal(0, Optimizer.Optimize(result.Data, null, new OptimizeOptions { MaxImageDpi = null }).ImagesBlackAndWhite);
    }

    [Fact]
    public void AStencilsDecodeArrayAndAGreyPictureAreLeftAsTheyDraw()
    {
        // A stencil painting its 1 samples in red (Decode [1 0]), as CCITT G4: coded again, drawn the same.
        var (gray, w, h) = Smaller(3);
        var bits = Bilevel.FromScan(gray, w, h, 100);
        var g4 = CcittG4.Encode(bits);
        var stencil = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Im 5 0 R >> >> >>",
            Core2Pdf.Stream("1 0 0 rg q 612 0 0 792 0 0 cm /Im Do Q"),
            Core2Pdf.Stream(Latin1(g4), $"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ImageMask true /Decode [1 0] /Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns {w} /Rows {h} >>"),
        ]);
        var result = Optimizer.Optimize(stencil, null, new OptimizeOptions { MaxImageDpi = null });
        Assert.Equal(1, result.ImagesBlackAndWhite);
        using (var doc = Core2Pdf.Open(result.Data))
        {
            var image = Picture(doc);
            Assert.Equal("JBIG2Decode", PdfObj.Name(image.Elements["/Filter"]));
            Assert.Null(image.Elements["/DecodeParms"]);
            Assert.True(PdfObj.Resolve(image.Elements["/ImageMask"]) is PdfBoolean { Value: true });
            Assert.NotNull(PdfObj.Array(image.Elements["/Decode"]));
        }
        // Drawn the same, to MuPDF's smoothing of the edges (one filter or the other takes another path to the screen).
        var (a, b) = (Pixels(stencil), Pixels(result.Data));
        Assert.Equal(a.Length, b.Length);
        Assert.InRange(a.Zip(b, (x, y) => Math.Abs(x - y)).Max(), 0, 4);

        // A grey scan isn't made black and white unless asked.
        var (g, gw, gh) = Smaller(2);
        var jpeg = JpegEncoder.EncodeGray(g, gw, gh, 85, 150);
        var grey = OnePicturePage($"/Type /XObject /Subtype /Image /Width {gw} /Height {gh} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", jpeg);
        var kept = Optimizer.Optimize(grey, null, new OptimizeOptions { MaxImageDpi = null });
        Assert.Equal(0, kept.ImagesBlackAndWhite);
        using (var doc = Core2Pdf.Open(kept.Data)) Assert.Equal("DCTDecode", PdfObj.Name(Picture(doc).Elements["/Filter"]));
    }

    [Fact]
    public void AskedForBlackAndWhiteAGreyScanOfTextBecomesOneBitAndAPhotoDoesnt()
    {
        var (g, gw, gh) = Smaller(2);
        var jpeg = JpegEncoder.EncodeGray(g, gw, gh, 85, 150);
        var grey = OnePicturePage($"/Type /XObject /Subtype /Image /Width {gw} /Height {gh} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", jpeg);
        var options = new OptimizeOptions { MaxImageDpi = null, BlackAndWhiteScans = true };
        var result = Optimizer.Optimize(grey, null, options);
        Assert.Equal(1, result.ImagesBlackAndWhite);
        Assert.True(result.SizeAfter * 5 < result.SizeBefore, $"{result.SizeBefore} -> {result.SizeAfter}");
        using (var doc = Core2Pdf.Open(result.Data))
        {
            var image = Picture(doc);
            Assert.Equal(1, PdfObj.Int(image.Elements["/BitsPerComponent"]));
            Assert.Equal("/DeviceGray", PdfObj.Resolve(image.Elements["/ColorSpace"])!.ToString());
        }
        // The text is where it was: ink where the scan had ink.
        var before = Pixels(grey, 0.25);
        var after = Pixels(result.Data, 0.25);
        Assert.Equal(before.Length, after.Length);
        var (inkBefore, inkAfter, both) = (0, 0, 0);
        for (var i = 0; i < before.Length; i += 3)
        {
            var (a, b) = (before[i] < 160, after[i] < 128);
            inkBefore += a ? 1 : 0;
            inkAfter += b ? 1 : 0;
            both += a && b ? 1 : 0;
        }
        Assert.True(inkAfter > 0 && both > inkAfter * 0.6, $"ink {inkBefore} before, {inkAfter} after, {both} both");

        // A photo stays a photo.
        var rng = new Random(9);
        var photo = new byte[gw * gh];
        for (var y = 0; y < gh; y++)
            for (var x = 0; x < gw; x++) photo[y * gw + x] = (byte)Math.Clamp((x + y) * 255 / (gw + gh) + rng.Next(-10, 10), 0, 255);
        var photoPdf = OnePicturePage($"/Type /XObject /Subtype /Image /Width {gw} /Height {gh} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
            JpegEncoder.EncodeGray(photo, gw, gh, 85, 150));
        Assert.Equal(0, Optimizer.Optimize(photoPdf, null, options).ImagesBlackAndWhite);
    }

    [Fact]
    public void ACleanedPageOfABlackAndWhiteScanStaysBlackAndWhite()
    {
        var (gray, w, h) = Smaller(2);
        var bits = Bilevel.FromScan(gray, w, h, 150);
        var oneBit = OnePicturePage($"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode",
            PdfObj.Deflate(Samples(bits)));
        var greyScan = OnePicturePage($"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode",
            JpegEncoder.EncodeGray(gray, w, h, 85, 150));
        var cleaned = CleanedPageImage.From(w, h, 1, gray, 0);

        var written = ScanPage.WriteBack(oneBit, null, new Dictionary<int, CleanedPageImage> { [0] = cleaned });
        using (var doc = Core2Pdf.Open(written))
        {
            var image = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/PdScan"])!;
            Assert.Equal(1, PdfObj.Int(image.Elements["/BitsPerComponent"]));
            Assert.Equal("JBIG2Decode", PdfObj.Name(image.Elements["/Filter"]));
            Assert.True(image.Stream!.Value.Length * 10 < cleaned.Deflated.Length, $"{image.Stream.Value.Length} vs {cleaned.Deflated.Length}");
        }
        Assert.True(Core2Pdf.Ink(written, 0, new RectD(0, 0, 612, 792)) > 0.01);

        // A grey scan's cleaned page stays grey.
        var grey = ScanPage.WriteBack(greyScan, null, new Dictionary<int, CleanedPageImage> { [0] = cleaned });
        using (var doc = Core2Pdf.Open(grey))
        {
            var image = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(doc.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/PdScan"])!;
            Assert.Equal(8, PdfObj.Int(image.Elements["/BitsPerComponent"]));
        }
    }

    [Fact]
    public void BlackAndWhiteScansIsOffUnlessAskedAndKeptInABatchPreset()
    {
        Assert.False(new OptimizeOptions().BlackAndWhiteScans);
        var json = BatchPresets.Write(new BatchPreset { Name = "bw", Steps = [new OptimizeStep(new OptimizeOptions { BlackAndWhiteScans = true })] });
        Assert.Contains("blackAndWhiteScans", json);
        Assert.False(Assert.IsType<OptimizeStep>(Assert.Single(BatchPresets.Read(json.Replace("\"blackAndWhiteScans\": true,", "")).Steps)).Options.BlackAndWhiteScans);
        var read = Assert.IsType<OptimizeStep>(Assert.Single(BatchPresets.Read(json).Steps));
        Assert.True(read.Options.BlackAndWhiteScans);
    }
}
