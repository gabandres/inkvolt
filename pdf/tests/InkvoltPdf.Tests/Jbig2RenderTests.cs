using InkvoltPdf.Bench;
using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;
using Xunit.Abstractions;

namespace InkvoltPdf.Tests;

/// <summary>
/// Our lossless JBIG2 (<see cref="Jbig2Generic"/>, roadmap 4.8) read back by another program, MuPDF (jbig2dec), pixel for
/// pixel, and its size against <see cref="CcittG4"/> and a grey JPEG on 300 dpi pages of text.
/// </summary>
public class Jbig2RenderTests(ITestOutputHelper output)
{
    /// <summary>A one-page PDF at 72 dpi whose image is the 1-bit stream given.</summary>
    private static byte[] Pdf(BitImage image, string filter, byte[] data) =>
        Optimizer.OneImagePage($"/Type /XObject /Subtype /Image /Width {image.Width} /Height {image.Height} /ColorSpace /DeviceGray /BitsPerComponent 1 {filter}",
            data, image.Width, image.Height);

    private static BitImage Rendered(byte[] pdf, int width, int height)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var img = engine.Render(0, 1.0);
        Assert.Equal((width, height), (img.Width, img.Height));
        var gray = new byte[width * height];
        for (var i = 0; i < gray.Length; i++) gray[i] = img.Pixels[i * 3 + 1];
        return BitImage.FromGray(gray, width, height, 128);
    }

    private static BitImage Random(int width, int height, double density, int seed, double change = 0.05)
    {
        var rng = new Random(seed);
        var stride = (width + 7) / 8;
        var bits = new byte[stride * height];
        for (var y = 0; y < height; y++)
        {
            var black = rng.NextDouble() < density;
            for (var x = 0; x < width; x++)
            {
                if (rng.NextDouble() < change) black = rng.NextDouble() < density;
                if (black) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
            }
        }
        return new BitImage(width, height, bits);
    }

    [Theory]
    [InlineData(1, 1, 0.5, 0.05)]
    [InlineData(13, 9, 0.5, 0.05)]
    [InlineData(300, 200, 0.03, 0.05)]
    [InlineData(301, 77, 0.5, 0.05)]
    [InlineData(64, 64, 0.5, 1.0)]  // noise: every context, many carries in the coder
    [InlineData(500, 300, 0.5, 0.6)]
    [InlineData(2900, 12, 0.99, 0.05)]
    public void MuPdfReadsTheJbig2ImageBitForBit(int width, int height, double density, double change)
    {
        var image = Random(width, height, density, width * 31 + height, change);
        Assert.Equal(image.Bits, Rendered(Pdf(image, "/Filter /JBIG2Decode", Jbig2Generic.Encode(image)), width, height).Bits);
    }

    [Fact]
    public void RowsLikeTheOneAboveAndBlankPagesComeBackToo()
    {
        // Typical prediction: runs of rows equal to the one above (blank, and repeated ink), on and off.
        var (w, h) = (200, 120);
        var stride = (w + 7) / 8;
        var bits = new byte[stride * h];
        for (var y = 0; y < h; y++)
            if (y / 10 % 3 == 1)
                for (var x = y % 7; x < w; x += 5) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
            else if (y / 10 % 3 == 2)
                for (var x = 0; x < w; x += 3) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
        var image = new BitImage(w, h, bits);
        Assert.Equal(image.Bits, Rendered(Pdf(image, "/Filter /JBIG2Decode", Jbig2Generic.Encode(image)), w, h).Bits);
        var white = BitImage.White(w, h);
        Assert.Equal(white.Bits, Rendered(Pdf(white, "/Filter /JBIG2Decode", Jbig2Generic.Encode(white)), w, h).Bits);
    }

    [Fact]
    public void MuPdfReadsAScannedTextPageBitForBit()
    {
        var file = ScanCorpus.Files.Single(f => f.Name == "en-skew6-noisy");
        var (pixels, w, h, _) = ScanCorpus.MakePage(file, 0);
        var image = Bilevel.FromScan(pixels, w, h, ScanCorpus.Dpi);
        Assert.Equal(image.Bits, Rendered(Pdf(image, "/Filter /JBIG2Decode", Jbig2Generic.Encode(image)), w, h).Bits);
    }

    [Fact]
    public void CancellingStopsTheEncoder()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => Jbig2Generic.Encode(BitImage.White(100, 100), cts.Token));
    }

    /// <summary>
    /// The sizes on 300 dpi letter pages of text: the corpus's scans (light, noisy, shaded) and a page as typeset (clean),
    /// as a grey JPEG at quality 85 (a scanner's usual), in black and white as CCITT G4 and as our JBIG2. JBIG2 is kept
    /// because it is clearly smaller than G4 on every one.
    /// </summary>
    [Theory]
    [InlineData("en-skew3-light", false)]
    [InlineData("en-skew6-noisy", false)]
    [InlineData("es-skew8-shaded", false)]
    [InlineData("en-skew3-light", true)]
    public void Jbig2IsClearlySmallerThanG4OnTextPages(string name, bool typeset)
    {
        var file = ScanCorpus.Files.Single(f => f.Name == name);
        var (pixels, w, h) = typeset ? ScanCorpus.CleanPage(file, 0) is var c ? (c.Pixels, c.Width, c.Height) : default
            : ScanCorpus.MakePage(file, 0) is var m ? (m.Pixels, m.Width, m.Height) : default;
        var jpeg = JpegEncoder.EncodeGray(pixels, w, h, 85, ScanCorpus.Dpi).Length;
        var bits = Bilevel.FromScan(pixels, w, h, ScanCorpus.Dpi);
        var g4 = CcittG4.Encode(bits).Length;
        var started = System.Diagnostics.Stopwatch.StartNew();
        var jbig2 = Jbig2Generic.Encode(bits).Length;
        output.WriteLine(
            $"{name}{(typeset ? " as typeset" : "")}: {w} × {h}, JPEG q85 {jpeg:N0} bytes, G4 {g4:N0}, JBIG2 {jbig2:N0} ({100.0 * jbig2 / g4:0}% of G4, {started.ElapsedMilliseconds} ms)");
        Assert.True(jbig2 * 10 < g4 * 9, $"JBIG2 {jbig2} vs G4 {g4}");
    }
}
