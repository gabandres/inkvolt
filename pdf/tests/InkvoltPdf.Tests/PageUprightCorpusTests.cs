using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Tests;

/// <summary>
/// Inkvolt Print's pages turned upright on their own (its roadmap 4.3, in the shared core): real text typeset by MuPDF and
/// "scanned" by the OCR corpus's generator, fed each way round and a little crooked, read on the small copy the scan review's
/// checks use (about 100 dpi). Every page must come out upright and sure: a scan that is turned wrongly is worse than one left as
/// it came, so this is what makes it reliable enough to be on by default.
/// </summary>
public class PageUprightCorpusTests
{
    public static TheoryData<string, string, double, int> Files => new()
    {
        { "en-upright-times", "/Times-Roman", 11, 0 },
        { "en-upright-helvetica", "/Helvetica", 10, 1 },
        { "es-upright-times", "/Times-Roman", 12, 2 },
    };

    [Theory]
    [MemberData(nameof(Files))]
    public void PagesFedEachWayRoundAreTurnedUpright(string name, string font, double size, int shift)
    {
        var turns = Enumerable.Range(0, 4).Select(t => (t + shift) % 4).ToArray();
        var file = new CorpusFile(name, name[..2], font, size, 0.5, 3.5, Noise: 14, Specks: 300, Shading: 30, Turns: turns, Pages: 4);
        for (var p = 0; p < 4; p++)
        {
            var (pixels, w, h, truth) = ScanCorpus.MakePage(file, p);
            var small = ScanCleanup.Downscale(new GrayImage(w, h, pixels), 3);
            var found = PageUpright.Find(small, ScanCorpus.Dpi / 3.0);
            Assert.True(found.Sure, $"{name} page {p + 1}, fed {truth.Turns} turns: not sure");
            Assert.Equal((4 - truth.Turns) % 4, found.QuarterTurns);
            // Lying sideways, it is straightened by its lines' own skew (the scan was skewed after it was turned).
            if (truth.Turns % 2 == 1) Assert.Equal(truth.Skew, found.Skew, 0.5);
        }
    }

    [Fact]
    public void APageWithAFewWordsIsLeftAsItCame()
    {
        // A heading and nothing else: too little text to say which way up, so no turn.
        var px = Enumerable.Repeat((byte)240, 850 * 1100).ToArray();
        for (var y = 100; y < 112; y++)
            for (var x = 100; x < 300; x++)
                px[y * 850 + x] = 30;
        Assert.Equal(0, PageUpright.Find(new GrayImage(850, 1100, px), 100).Turns);
    }
}
