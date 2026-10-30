using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Tests;

/// <summary>
/// Cleaning a scanned page before text recognition (roadmap 2.2): straightening up to ±15°, turning upright, smoothing,
/// evening out the paper, removing specks. Pages come from the OCR corpus's generator (pdf/tools/ocr-corpus), so the
/// expectations hold for any port that cleans the same way (the Mac's, with Core Image).
/// </summary>
public class ScanCleanupTests
{
    private static CorpusFile File(string name) => ScanCorpus.Files.Single(f => f.Name == name);

    [Theory]
    [InlineData("en-skew3-light", 0)]
    [InlineData("en-skew6-noisy", 1)]
    [InlineData("en-skew10-shaded", 0)]
    [InlineData("es-skew4-noisy", 1)]
    [InlineData("es-skew8-shaded", 0)]
    public void CorpusPagesAreStraightenedAndLeftUpright(string name, int page)
    {
        var (pixels, w, h, truth) = ScanCorpus.MakePage(File(name), page);
        Assert.InRange(Math.Abs(truth.Skew), 3, 10);

        var cleaned = ScanCleanup.Clean(pixels, w, h, 1, ScanCorpus.Dpi);
        Assert.Equal(truth.Skew, cleaned.Skew, 0.3);
        Assert.Equal(0, cleaned.QuarterTurns);
        Assert.True(cleaned.UprightSure);
        Assert.Equal(0, ScanCleanup.SkewOf(cleaned.Gray, ScanCorpus.Dpi), 0.3);
        // The paper is white now, and the ink still dark.
        Assert.Equal(255, GrayImage.Median(cleaned.Gray, 0, 0, w, h));
        Assert.Contains(cleaned.Gray.Pixels, p => p < 60);
    }

    [Theory]
    [InlineData(0, 2)] // upside down: two turns
    [InlineData(1, 3)] // turned clockwise on the glass: three more make it upright
    public void TurnedPagesAreTurnedUpright(int page, int expected)
    {
        var (pixels, w, h, truth) = ScanCorpus.MakePage(File("en-turned"), page);
        Assert.NotEqual(0, truth.Turns);
        var cleaned = ScanCleanup.Clean(pixels, w, h, 1, ScanCorpus.Dpi);
        Assert.Equal(expected, cleaned.QuarterTurns);
        Assert.True(cleaned.UprightSure);
        Assert.Equal(expected % 2 == 0 ? (w, h) : (h, w), (cleaned.Gray.Width, cleaned.Gray.Height));
    }

    [Theory]
    [InlineData(-15)]
    [InlineData(-12.5)]
    [InlineData(14)]
    [InlineData(15)]
    public void SkewsUpToFifteenDegreesAreFound(double skew)
    {
        var (pixels, w, h, _) = ScanCorpus.MakePage(File("en-skew3-light"), 0);
        var straight = ScanCleanup.Clean(pixels, w, h, 1, ScanCorpus.Dpi).Gray;
        var turned = PageRotate.Rotate(straight.Pixels, w, h, w, 1, skew);
        Assert.Equal(skew, ScanCleanup.SkewOf(new GrayImage(w, h, turned), ScanCorpus.Dpi), 0.35);
    }

    [Fact]
    public void LoneSpecksGoButFullStopsAndDotsStay()
    {
        const int w = 300, h = 200;
        var px = Enumerable.Repeat((byte)255, w * h).ToArray();
        void Box(int x0, int y0, int bw, int bh)
        {
            for (var y = y0; y < y0 + bh; y++)
                for (var x = x0; x < x0 + bw; x++)
                    px[y * w + x] = 10;
        }
        Box(40, 60, 6, 30);   // the stem of an i
        Box(40, 50, 6, 6);    // its dot, 4 px above
        Box(50, 84, 5, 5);    // a full stop after it
        Box(260, 170, 4, 4);  // a speck far from everything
        Box(250, 30, 3, 2);   // another
        Box(150, 100, 40, 40); // a big dark square: not a speck

        var removed = Despeckle.Remove(px, w, h, 300);
        Assert.Equal(2, removed);
        Assert.Equal(255, px[171 * w + 261]);
        Assert.Equal(255, px[31 * w + 251]);
        Assert.Equal(10, px[52 * w + 42]); // the dot
        Assert.Equal(10, px[86 * w + 52]); // the full stop
        Assert.Equal(10, px[120 * w + 170]);
    }

    [Fact]
    public void UnevenPaperBecomesWhiteAndInkStays()
    {
        const int w = 600, h = 400;
        var px = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                px[y * w + x] = (byte)(240 - 90 * x / w); // paper from 240 down to 150 (a lid's shadow)
        for (var y = 100; y < 110; y++)
            for (var x = 20; x < 580; x += 3)
                px[y * w + x] = (byte)(px[y * w + x] / 8); // a line of ink across the shading

        var paper = PaperLevel.Estimate(px, w, h, 300);
        PaperLevel.Whiten(px, paper);
        Assert.Equal(255, px[300 * w + 30]);
        Assert.Equal(255, px[300 * w + 570]); // the shaded side too
        Assert.True(px[105 * w + 20] < 60);
        Assert.True(px[105 * w + 578] < 60);
    }

    [Fact]
    public void TurningMovesPixelsClockwise()
    {
        // 3 × 2: a b c / d e f
        byte[] px = [1, 2, 3, 4, 5, 6];
        Assert.Equal([4, 1, 5, 2, 6, 3], ScanCleanup.Turn(px, 3, 2, 1, 1)); // 2 × 3: d a / e b / f c
        Assert.Equal([6, 5, 4, 3, 2, 1], ScanCleanup.Turn(px, 3, 2, 1, 2));
        Assert.Equal([3, 6, 2, 5, 1, 4], ScanCleanup.Turn(px, 3, 2, 1, 3));
        Assert.Equal(px, ScanCleanup.Turn(ScanCleanup.Turn(px, 3, 2, 1, 1), 2, 3, 1, 3));
    }

    [Fact]
    public void ColourIsKeptWhenAsked()
    {
        var (gray, w, h, _) = ScanCorpus.MakePage(File("en-skew3-light"), 0);
        var bgr = new byte[w * h * 3];
        for (var i = 0; i < gray.Length; i++)
        {
            bgr[i * 3] = gray[i];
            bgr[i * 3 + 1] = gray[i];
            bgr[i * 3 + 2] = (byte)Math.Min(255, gray[i] + 10); // a warm paper
        }
        var cleaned = ScanCleanup.Clean(bgr, w, h, 3, ScanCorpus.Dpi, keepColor: true);
        Assert.NotNull(cleaned.Bgr);
        Assert.Equal(cleaned.Gray.Pixels.Length * 3, cleaned.Bgr!.Length);
        for (var i = 0; i < cleaned.Gray.Pixels.Length; i += 997)
            if (cleaned.Gray.Pixels[i] == 255) Assert.Equal(255, cleaned.Bgr[i * 3 + 2]);
    }
}
