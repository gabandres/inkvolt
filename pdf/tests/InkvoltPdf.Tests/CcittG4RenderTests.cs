using InkvoltPdf.Bench;
using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;
using MuPDFCore;
using Xunit.Abstractions;

namespace InkvoltPdf.Tests;

/// <summary>
/// The shared core's black-and-white pages (Inkvolt Print's roadmap 4.4, reused by Inkvolt PDF's 4.8): <see cref="CcittG4"/>
/// written by <see cref="PdfWriter"/> and read back by another program, MuPDF, pixel for pixel; and what it saves on a scanned
/// page of text from the OCR corpus (pdf/tools/ocr-corpus).
/// </summary>
public class CcittG4RenderTests(ITestOutputHelper output)
{
    /// <summary>The page drawn by MuPDF at one pixel a point (the PDF written at 72 dpi), as black and white bits.</summary>
    private static BitImage Rendered(byte[] pdf, int width, int height)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var img = engine.Render(0, 1.0);
        Assert.Equal((width, height), (img.Width, img.Height));
        var gray = new byte[width * height];
        for (var i = 0; i < gray.Length; i++) gray[i] = img.Pixels[i * 3 + 1];
        return BitImage.FromGray(gray, width, height, 128);
    }

    private static byte[] Pdf(BitImage image)
    {
        using var ms = new MemoryStream();
        PdfWriter.Write(ms, [PdfPage.BlackAndWhite(image, 72)], "G4");
        return ms.ToArray();
    }

    [Theory]
    [InlineData(1, 1, 0.5)]
    [InlineData(13, 9, 0.5)]
    [InlineData(300, 200, 0.03)]
    [InlineData(301, 77, 0.5)]
    [InlineData(1728, 40, 0.1)]
    [InlineData(3000, 30, 0.01)] // white runs past 2560
    [InlineData(2900, 12, 0.99)] // black runs past 2560
    public void MuPdfReadsTheG4PageBitForBit(int width, int height, double density)
    {
        var rng = new Random(width + 7 * height);
        var stride = (width + 7) / 8;
        var bits = new byte[stride * height];
        for (var y = 0; y < height; y++)
        {
            var black = rng.NextDouble() < density;
            for (var x = 0; x < width; x++)
            {
                if (rng.NextDouble() < 0.05) black = rng.NextDouble() < density;
                if (black) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
            }
        }
        var image = new BitImage(width, height, bits);
        Assert.Equal(image.Bits, Rendered(Pdf(image), width, height).Bits);
    }

    [Fact]
    public void MuPdfReadsAScannedTextPageBitForBit()
    {
        var file = ScanCorpus.Files.Single(f => f.Name == "en-skew6-noisy");
        var (pixels, w, h, _) = ScanCorpus.MakePage(file, 0);
        var image = Bilevel.FromScan(pixels, w, h, ScanCorpus.Dpi);
        Assert.Contains("/CCITTFaxDecode", System.Text.Encoding.Latin1.GetString(Pdf(image)));
        Assert.Equal(image.Bits, Rendered(Pdf(image), w, h).Bits);
    }

    /// <summary>
    /// The size gain on a scanned letter page of text at 300 dpi (the corpus's light and noisy scans): the page as a grey
    /// JPEG at quality 85, a scanner's usual, against the same page in black and white as G4, each as a whole PDF.
    /// </summary>
    [Theory]
    [InlineData("en-skew3-light", false)]
    [InlineData("es-skew4-noisy", false)]
    [InlineData("en-skew3-light", true)] // the same page as typeset: no noise, specks or shading (a clean scan's best case for JPEG)
    public void ATextPageInBlackAndWhiteIsAFractionOfItsJpeg(string name, bool typeset)
    {
        var file = ScanCorpus.Files.Single(f => f.Name == name);
        var (pixels, w, h) = typeset ? ScanCorpus.CleanPage(file, 0) is var c ? (c.Pixels, c.Width, c.Height) : default
            : ScanCorpus.MakePage(file, 0) is var m ? (m.Pixels, m.Width, m.Height) : default;
        var jpeg = JpegEncoder.EncodeGray(pixels, w, h, 85, ScanCorpus.Dpi);
        var bits = Bilevel.FromScan(pixels, w, h, ScanCorpus.Dpi);
        long Size(PdfPage page)
        {
            using var ms = new MemoryStream();
            PdfWriter.Write(ms, [page], name);
            return ms.Length;
        }
        var (asJpeg, asBits) = (Size(new PdfPage(jpeg, ScanCorpus.Dpi)), Size(PdfPage.BlackAndWhite(bits, ScanCorpus.Dpi)));
        output.WriteLine($"{name}{(typeset ? " as typeset" : "")}: {w} × {h}, JPEG q85 PDF {asJpeg:N0} bytes, black-and-white PDF {asBits:N0} bytes ({PdfWriter.OneBit(bits).Filter}), " +
                         $"{(double)asJpeg / asBits:0.0} times smaller");
        Assert.True(asBits * 5 < asJpeg, $"{asBits} vs {asJpeg}");
    }
}
