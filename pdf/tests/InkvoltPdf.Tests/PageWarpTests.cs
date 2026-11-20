using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 2.2's trapezoid correction and straightened lines: pages photographed at an angle or open in a book
/// (<see cref="PhotoCorpus"/>, with known maps) are straightened only when the page shows it clearly, and recognized words
/// map back onto the photo.
/// </summary>
public class PageWarpTests
{
    private static PhotoFile Photo(string name) => PhotoCorpus.Files.Single(f => f.Name == name);

    private static double Distance((double X, double Y) a, (double X, double Y) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    [Theory]
    [InlineData("en-trapezoid")]
    [InlineData("es-trapezoid")]
    public void APagePhotographedAtAnAngleIsFoundAndStraightened(string name)
    {
        var (px, w, h, _) = PhotoCorpus.Photo(Photo(name));
        var truth = PhotoCorpus.Corners(w, h);
        var found = Trapezoid.Find(new GrayImage(w, h, px));
        Assert.NotNull(found);
        for (var i = 0; i < 4; i++)
        {
            Assert.True(Distance(found!.Corners[i], truth[i]) < 12, $"corner {i}: {found.Corners[i]} for {truth[i]}");
            // The straightened page's corners come from the photo's.
            var rect = i switch { 0 => (found.Left, found.Top), 1 => (found.Right, found.Top), 2 => (found.Right, found.Bottom), _ => (found.Left, found.Bottom) };
            Assert.True(Distance(found.Source(rect.Item1, rect.Item2), found.Corners[i]) < 0.5);
        }

        // Cleaned with it, the page's lines run level and the desk is gone.
        var cleaned = ScanCleanup.Clean(px, w, h, 1, PhotoCorpus.Dpi, steps: CleanupSteps.Trapezoid);
        Assert.NotNull(cleaned.Perspective);
        Assert.Equal(0, cleaned.QuarterTurns);
        Assert.InRange(Math.Abs(cleaned.Skew), 0, 0.5);
        Assert.Equal(0, ScanCleanup.SkewOf(cleaned.Gray, PhotoCorpus.Dpi), 0.3);
        var dark = cleaned.Gray.Pixels.Count(p => p < 128) / (double)cleaned.Gray.Pixels.Length;
        Assert.InRange(dark, 0.005, 0.12); // the print, not a desk's worth of grey
        // Without the step the same photo isn't warped.
        Assert.Null(ScanCleanup.Clean(px, w, h, 1, PhotoCorpus.Dpi).Perspective);
    }

    [Fact]
    public void APageLyingSquareOrCutOffOrWithoutADeskIsLeftAsItIs()
    {
        var (clean, w, h, _) = ScanCorpus.CleanPage(ScanCorpus.Files[0], 0);
        Assert.Null(Trapezoid.Find(new GrayImage(w, h, clean))); // no desk around it
        var rng = new InkvoltPdf.Bench.Rng(7);
        // Square on the desk (a flatbed with a dark lid): Deskew's to straighten, not warped.
        (double, double)[] square = [(0.1 * w, 0.08 * h), (0.9 * w, 0.08 * h), (0.9 * w, 0.92 * h), (0.1 * w, 0.92 * h)];
        Assert.Null(Trapezoid.Find(new GrayImage(w, h, PhotoCorpus.OnDesk(clean, w, h, square, ref rng))));
        // A corner out of the photo: not sure where the page ends.
        (double, double)[] cut = [(-0.05 * w, 0.1 * h), (0.86 * w, 0.075 * h), (0.95 * w, 0.93 * h), (0.06 * w, 0.95 * h)];
        Assert.Null(Trapezoid.Find(new GrayImage(w, h, PhotoCorpus.OnDesk(clean, w, h, cut, ref rng))));
        // A dark photo of no page at all.
        var dim = new byte[w * h];
        for (var i = 0; i < dim.Length; i++) dim[i] = (byte)(60 + rng.Next(40));
        Assert.Null(Trapezoid.Find(new GrayImage(w, h, dim)));
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(5000, 3)]
    [InlineData(3, 5000)]
    public void TinyAndHugeImagesAreLeftAlone(int w, int h)
    {
        // Sizes the warps never take on (a hostile page's image is held to ScanText's render limit before it gets here).
        var px = new byte[w * h];
        Assert.Null(Trapezoid.Find(new GrayImage(w, h, px)));
        Assert.Null(CurvedLines.Find(new GrayImage(w, h, px), 300));
    }

    [Theory]
    [InlineData("en-book")]
    [InlineData("es-book")]
    public void ABooksBentLinesAreFlattened(string name)
    {
        var (px, w, h, _) = PhotoCorpus.Photo(Photo(name));
        var curve = CurvedLines.Find(new GrayImage(w, h, px), PhotoCorpus.Dpi);
        Assert.NotNull(curve);
        Assert.False(curve!.Vertical);

        // The map follows the known sag: between two places along a line, the line moved as the book moved it.
        var (x0, x1) = (0.2 * w, 0.7 * w); // within the text: past its lines the map holds still
        var worst = 0.0;
        for (var y = 0.2 * h; y <= 0.8 * h; y += 0.05 * h)
        {
            var (a, b) = (curve.Source(x0, y).Y, curve.Source(x1, y).Y);
            // The content at b (column x1) and at a (column x0) is one line of the page: solve each back to the typeset page.
            double Typeset(double x, double shown)
            {
                var from = shown;
                for (var k = 0; k < 6; k++) from = shown - PhotoCorpus.Sag(x, from, w, h);
                return from;
            }
            worst = Math.Max(worst, Math.Abs(Typeset(x0, a) - Typeset(x1, b)));
        }
        Assert.True(worst < 4, $"lines off by up to {worst:0.0} px");

        // Flattened, nothing is left to straighten.
        var flat = curve.Apply(px, w, h, 1);
        Assert.Null(CurvedLines.Find(new GrayImage(w, h, flat), PhotoCorpus.Dpi));

        // Through the whole cleanup.
        var cleaned = ScanCleanup.Clean(px, w, h, 1, PhotoCorpus.Dpi, steps: CleanupSteps.CurvedLines);
        Assert.NotNull(cleaned.Curve);
        Assert.Equal(0, cleaned.Skew); // tilted only by its bend: flattened as it is, not turned, so its margins stay upright
        Assert.Null(ScanCleanup.Clean(px, w, h, 1, PhotoCorpus.Dpi).Curve);
    }

    [Fact]
    public void SidewaysBentLinesAreFlattenedAlongTheirOwnWay()
    {
        var (px, w, h, _) = PhotoCorpus.Photo(Photo("en-book"));
        var turned = ScanCleanup.Turn(px, w, h, 1, 1); // h × w, lines running down
        var curve = CurvedLines.Find(new GrayImage(h, w, turned), PhotoCorpus.Dpi, vertical: true);
        Assert.NotNull(curve);
        Assert.True(curve!.Vertical);
        Assert.Null(CurvedLines.Find(new GrayImage(h, w, curve.Apply(turned, h, w, 1)), PhotoCorpus.Dpi, vertical: true));
    }

    [Theory]
    [InlineData("en-skew3-light", 0)]
    [InlineData("es-skew8-shaded", 1)]
    public void FlatScansAreNotWarped(string name, int page)
    {
        var (pixels, w, h, truth) = ScanCorpus.MakePage(ScanCorpus.Files.Single(f => f.Name == name), page);
        var cleaned = ScanCleanup.Clean(pixels, w, h, 1, ScanCorpus.Dpi, steps: CleanupSteps.All);
        Assert.Null(cleaned.Perspective);
        Assert.Null(cleaned.Curve);
        Assert.Equal(truth.Skew, cleaned.Skew, 0.3);
    }

    [Fact]
    public void ThePageTypesetIsNotBent()
    {
        var (clean, w, h, _) = ScanCorpus.CleanPage(ScanCorpus.Files[1], 0);
        Assert.Null(CurvedLines.Find(new GrayImage(w, h, clean), ScanCorpus.Dpi));
    }

    [Fact]
    public void AHomographyTakesEachCornerToItsPartner()
    {
        (double, double)[] from = [(0, 0), (100, 0), (100, 50), (0, 50)];
        (double, double)[] to = [(10, 5), (95, 12), (110, 70), (-3, 60)];
        var map = Homography.Between(from, to)!;
        for (var i = 0; i < 4; i++) Assert.True(Distance(map.Apply(from[i].Item1, from[i].Item2), to[i]) < 1e-6);
        Assert.Null(Homography.Between([(0, 0), (1, 1), (2, 2), (3, 3)], to)); // in a line: no map
    }

    /// <summary>"Reads" the topmost line of ink as one word, as <see cref="ScanTextTests"/>' stand-in does.</summary>
    private sealed class TopLineReader : ITextRecognizer
    {
        public string Language => "en-US";
        public string LanguageName => "English";

        public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
        {
            var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, width, height);
            int Ink(int y) => Enumerable.Range(0, width).Count(x => gray[y * width + x] < 128);
            var top = Enumerable.Range(0, height).First(y => Ink(y) > 3);
            var bottom = top;
            while (bottom + 1 < height && Ink(bottom + 1) > 0) bottom++;
            var xs = Enumerable.Range(top, bottom - top + 1).SelectMany(y => Enumerable.Range(0, width).Where(x => gray[y * width + x] < 128)).ToList();
            return [new RecognizedWord("Heading", xs.Min(), top, xs.Max() - xs.Min() + 1, bottom - top + 1, 0)];
        }
    }

    [Fact]
    public void WordsReadOnAStraightenedPhotoLandOnThePhoto()
    {
        var file = Photo("en-trapezoid");
        var pdf = PhotoCorpus.Pdf(file);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var options = new RecognizeOptions(CheckWords: false, RereadMissed: false, Trapezoid: true);
        var word = Assert.Single(ScanText.Recognize(engine, 0, new TopLineReader(), options).Words);

        // The heading sits at the page's top left: on the photo, inside the page's tipped-back top, slanted as its top edge.
        var corners = PhotoCorpus.Corners(2550, 3300).Select(c => (X: c.X * 72 / 300, Y: c.Y * 72 / 300)).ToArray();
        var topEdge = Math.Atan2(corners[1].Y - corners[0].Y, corners[1].X - corners[0].X) * 180 / Math.PI;
        Assert.Equal(topEdge, word.Angle, 1.0);
        Assert.InRange(word.Rect.CenterX, corners[0].X, corners[1].X);
        Assert.InRange(word.Rect.CenterY, corners[0].Y, corners[0].Y + 120);
        Assert.InRange(word.Rect.Height, 8, 20); // 16 pt at about four fifths of its size
        Assert.True(Core2Pdf.Ink(pdf, 0, word.Rect) > 0.08, "the word lies on the heading's ink");

        // Kept as the cleaned page instead, the words fit the straightened page (level).
        var kept = ScanText.Recognize(engine, 0, new TopLineReader(), options with { KeepCleanedImage = true });
        Assert.Equal(0, Assert.Single(kept.Words).Angle);
        Assert.NotNull(kept.Cleaned);
    }

    [Fact]
    public void APointOfAFlattenedPageMapsBackThroughTheCurve()
    {
        var (px, w, h, _) = PhotoCorpus.Photo(Photo("en-book"));
        var curve = CurvedLines.Find(new GrayImage(w, h, px), PhotoCorpus.Dpi)!;
        var frame = new ScanFrame(w, h, 0, 0, null, curve);
        Assert.Equal(curve.Source(400, 900), frame.ToRendered(400, 900));
        var word = frame.ToRendered(new RecognizedWord("bent", 300, 880, 200, 40, 0), 300 / 72.0);
        Assert.InRange(word.Angle, -20, -0.5); // towards the spine (left) the line sags: it rises to the right
    }
}
