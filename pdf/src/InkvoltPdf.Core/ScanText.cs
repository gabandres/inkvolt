using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// How Recognize Text reads a page. <see cref="Clean"/>: straighten, turn upright, despeckle and whiten the page image
/// first (<see cref="ScanCleanup"/>). <see cref="CheckWords"/>: mark suspect words (<see cref="SuspectWords"/>), which reads
/// the page a second time as scanned to compare. <see cref="KeepCleanedImage"/>: return the cleaned page to put in the
/// document in place of the scan (the user's choice, off by default); the words then fit the cleaned page.
/// </summary>
public sealed record RecognizeOptions(bool Clean = true, bool CheckWords = true, bool KeepCleanedImage = false)
{
    /// <summary>As Recognize Text read pages before 2.2: the page as rendered, no cleaning, no suspect words.</summary>
    public static readonly RecognizeOptions AsScanned = new(Clean: false, CheckWords: false);
}

/// <summary>
/// A cleaned page to write into the document (<see cref="ScanPage.WriteBack"/>): straightened, despeckled and whitened, in
/// the page's displayed orientation (rows of <see cref="Width"/> × <see cref="Channels"/> bytes, 1 = grey, 3 = BGR), and the
/// quarter turns clockwise that then set the page upright.
/// </summary>
public sealed record CleanedPageImage(int Width, int Height, int Channels, byte[] Pixels, int QuarterTurns);

/// <summary>
/// A recognized page: its words in page space (points from the top-left of the displayed page, each box turned by its
/// word's angle about its centre), how far the page was skewed (degrees clockwise) and how many quarter turns set it
/// upright, and the cleaned image when it was asked for. With a cleaned image, the words are placed for the page as it
/// will be after <see cref="ScanPage.WriteBack"/> (straight and upright).
/// </summary>
public sealed record RecognizedPage(IReadOnlyList<OcrWord> Words, double Skew, int QuarterTurns, CleanedPageImage? Cleaned);

/// <summary>
/// Text recognition of one page, engine-neutral: render the page at 300 dpi, clean it, hand it to an
/// <see cref="ITextRecognizer"/>, and map its words back onto the page (through the straightening and the quarter turns),
/// then mark suspect words. The engine is Windows' today (WindowsRecognizer), and could be another.
/// </summary>
public static class ScanText
{
    public const double Dpi = 300;
    private const long MaxRenderPixels = 60_000_000; // ~180 MB of BGR for very large pages; smaller pages render at 300 dpi

    public static RecognizedPage Recognize(PdfEngine pdf, int page, ITextRecognizer recognizer, RecognizeOptions options,
        ISpelling? spelling = null, CancellationToken cancel = default)
    {
        var g = pdf.GetPage(page);
        var scale = Dpi / 72;
        if (g.Width * g.Height * scale * scale > MaxRenderPixels) scale = Math.Sqrt(MaxRenderPixels / (g.Width * g.Height));
        // A page kept as its cleaned image keeps its comments as comments, so they're left out of the picture.
        var image = pdf.Render(page, scale, null, cancel, annotations: !options.KeepCleanedImage);
        var dpi = (int)Math.Round(scale * 72);

        List<OcrWord> AsScanned() => recognizer.Recognize(image.Pixels, image.Width, image.Height, 3, cancel)
            .Select(w => new OcrWord(w.Text, new RectD(w.X / scale, w.Y / scale, w.Width / scale, w.Height / scale))).ToList();

        if (!options.Clean)
        {
            var plain = AsScanned();
            return new RecognizedPage(options.CheckWords ? Mark(plain, null, spelling) : plain, 0, 0, null);
        }

        var color = options.KeepCleanedImage && IsColor(image.Pixels);
        var cleaned = ScanCleanup.Clean(image.Pixels, image.Width, image.Height, 3, dpi, color, cancel);
        var (turns, gray, bgr) = (cleaned.QuarterTurns, cleaned.Gray, cleaned.Bgr);
        var found = recognizer.Recognize(gray.Pixels, gray.Width, gray.Height, 1, cancel);
        if (!cleaned.UprightSure)
        {
            // The lines didn't say which way up: read it the other way too and keep the reading with more real words.
            var other = ScanCleanup.Turn(gray.Pixels, gray.Width, gray.Height, 1, 2);
            var otherFound = recognizer.Recognize(other, gray.Width, gray.Height, 1, cancel);
            if (Plausible(otherFound, spelling) > Plausible(found, spelling))
            {
                (found, turns) = (otherFound, (turns + 2) % 4);
                gray = new GrayImage(gray.Width, gray.Height, other);
                if (bgr is not null) bgr = ScanCleanup.Turn(bgr, gray.Width, gray.Height, 3, 2);
            }
        }

        var frame = new ScanFrame(image.Width, image.Height, cleaned.Skew, turns);
        var onScan = found.Select(w => frame.ToRendered(w, scale)).ToList();
        var words = options.KeepCleanedImage
            ? found.Select(w => new OcrWord(w.Text, new RectD(w.X / scale, w.Y / scale, w.Width / scale, w.Height / scale))).ToList()
            : onScan;
        // A page that wasn't upright as scanned can't be read as scanned: nothing to compare with.
        if (options.CheckWords) words = Mark(words, turns == 0 ? SuspectWords.ReadDifferently(onScan, AsScanned(), spelling) : null, spelling);

        CleanedPageImage? keep = null;
        if (options.KeepCleanedImage)
        {
            // Stored in the page's own orientation; the page's /Rotate then turns it upright.
            var (w, h) = turns % 2 == 0 ? (gray.Width, gray.Height) : (gray.Height, gray.Width);
            keep = bgr is not null
                ? new CleanedPageImage(w, h, 3, ScanCleanup.Turn(bgr, gray.Width, gray.Height, 3, -turns), turns)
                : new CleanedPageImage(w, h, 1, ScanCleanup.Turn(gray.Pixels, gray.Width, gray.Height, 1, -turns), turns);
        }
        return new RecognizedPage(words, cleaned.Skew, turns, keep);
    }

    private static List<OcrWord> Mark(List<OcrWord> words, bool[]? readDifferently, ISpelling? spelling)
    {
        for (var i = 0; i < words.Count; i++)
        {
            var reasons = SuspectWords.Check(words[i].Text, spelling);
            if (readDifferently is not null && readDifferently[i]) reasons |= SuspectReasons.ReadDifferently;
            if (reasons != SuspectReasons.None) words[i] = words[i] with { Suspect = reasons };
        }
        return words;
    }

    /// <summary>How much of a reading looks like real words: dictionary words, or without a dictionary, words of three letters or more.</summary>
    private static int Plausible(IReadOnlyList<RecognizedWord> words, ISpelling? spelling) =>
        words.Select(w => SuspectWords.Core(w.Text)).Count(c => c.Length >= 3 && c.All(char.IsLetter) && (spelling?.IsKnown(c) ?? true));

    /// <summary>Whether a BGR page has colour worth keeping (more than a trace of pixels whose channels differ).</summary>
    public static bool IsColor(byte[] bgr)
    {
        long colored = 0, sampled = 0;
        for (var i = 0; i + 2 < bgr.Length; i += 3 * 7, sampled++)
        {
            int b = bgr[i], g = bgr[i + 1], r = bgr[i + 2];
            if (Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b)) > 32) colored++;
        }
        return colored > sampled / 500;
    }
}

/// <summary>
/// Where a point of the cleaned page image was on the page as rendered: the cleaned image is the rendered one
/// (<see cref="Width"/> × <see cref="Height"/> px) straightened by <see cref="Skew"/> degrees (rotated anticlockwise by
/// that much about its centre, same size) and then turned <see cref="QuarterTurns"/> quarters clockwise. Turning and
/// straightening are both about the centre, so going back is turning back, then rotating by the skew.
/// </summary>
public readonly record struct ScanFrame(int Width, int Height, double Skew, int QuarterTurns)
{
    /// <summary>The angle (degrees clockwise) at which text that is level in the cleaned image runs on the rendered page.</summary>
    public double TextAngle
    {
        get
        {
            var a = Skew - 90.0 * (((QuarterTurns % 4) + 4) % 4);
            while (a <= -180) a += 360;
            while (a > 180) a -= 360;
            return a;
        }
    }

    /// <summary>A point of the cleaned image (pixels) on the rendered page (pixels).</summary>
    public (double X, double Y) ToRendered(double x, double y)
    {
        var (w, h) = (Width, Height);
        // Undo the quarter turns: one clockwise turn took (x, y) of a W × H image to (H − y, x).
        (x, y) = (((QuarterTurns % 4) + 4) % 4) switch
        {
            1 => (y, h - x),
            2 => (w - x, h - y),
            3 => (w - y, x),
            _ => (x, y),
        };
        if (Skew == 0) return (x, y);
        // Undo the straightening: the content goes back clockwise by the skew, about the centre.
        var (sin, cos) = Math.SinCos(Skew * Math.PI / 180);
        var (dx, dy) = (x - w / 2.0, y - h / 2.0);
        return (w / 2.0 + dx * cos - dy * sin, h / 2.0 + dx * sin + dy * cos);
    }

    /// <summary>A recognized word of the cleaned image as a word on the page (points; its box turned by <see cref="TextAngle"/>).</summary>
    public OcrWord ToRendered(RecognizedWord word, double scale)
    {
        var (cx, cy) = ToRendered(word.X + word.Width / 2, word.Y + word.Height / 2);
        return new OcrWord(word.Text, new RectD((cx - word.Width / 2) / scale, (cy - word.Height / 2) / scale, word.Width / scale, word.Height / scale), TextAngle);
    }
}
