using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// How Recognize Text reads a page. <see cref="Clean"/>: straighten, turn upright, despeckle and whiten the page image
/// first (<see cref="ScanCleanup"/>). <see cref="CheckWords"/>: mark suspect words (<see cref="SuspectWords"/>), which reads
/// the page a second time as scanned to compare. <see cref="KeepCleanedImage"/>: return the cleaned page to put in the
/// document in place of the scan (the user's choice, off by default); the words then fit the cleaned page.
/// <see cref="RereadMissed"/>: on a cleaned page, read again on its own each line-sized stretch of ink no word was read on
/// and each word left out inside a line read (<see cref="MissedLines"/>), as Windows' recognizer now and then skips a whole line.
/// <see cref="Trapezoid"/> and <see cref="CurvedLines"/> (with <see cref="Clean"/>): a page photographed at an angle is warped
/// back to a rectangle, and lines bent by a book's spine are flattened, each only when the page shows it clearly
/// (<see cref="ScanCleanup.Clean"/>'s <see cref="CleanupSteps"/>).
/// </summary>
public sealed record RecognizeOptions(bool Clean = true, bool CheckWords = true, bool KeepCleanedImage = false, bool RereadMissed = true,
    bool Trapezoid = false, bool CurvedLines = false)
{
    /// <summary>The cleanup's further steps these options ask for.</summary>
    public CleanupSteps Steps => (Trapezoid ? CleanupSteps.Trapezoid : 0) | (CurvedLines ? CleanupSteps.CurvedLines : 0);

    /// <summary>As Recognize Text read pages before 2.2: the page as rendered, no cleaning, no suspect words.</summary>
    public static readonly RecognizeOptions AsScanned = new(Clean: false, CheckWords: false, RereadMissed: false);
}

/// <summary>
/// A cleaned page to write into the document (<see cref="ScanPage.WriteBack"/>): straightened, despeckled and whitened, in
/// the page's displayed orientation, and the quarter turns clockwise that then set the page upright. <see cref="Deflated"/>:
/// the pixels as the PDF's image stream will hold them (rows of <see cref="Width"/> × <see cref="Channels"/> bytes, 1 = grey,
/// 3 = RGB, zlib-compressed), so many pages waiting to be written take what they will take in the file, not 25 MB each.
/// </summary>
public sealed record CleanedPageImage(int Width, int Height, int Channels, byte[] Deflated, int QuarterTurns)
{
    /// <summary>A cleaned page from its raw pixels (grey, or BGR as rendered).</summary>
    public static CleanedPageImage From(int width, int height, int channels, byte[] pixels, int quarterTurns)
    {
        if (channels == 3)
        {
            var rgb = new byte[pixels.Length];
            for (var i = 0; i + 2 < pixels.Length; i += 3)
            {
                rgb[i] = pixels[i + 2];
                rgb[i + 1] = pixels[i + 1];
                rgb[i + 2] = pixels[i];
            }
            pixels = rgb;
        }
        return new CleanedPageImage(width, height, channels, PdfObj.Deflate(pixels), quarterTurns);
    }
}

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
/// then mark suspect words. The engine is Windows' (WindowsRecognizer), Tesseract's (<see cref="TesseractRecognizer"/>) or
/// two of them line by line (<see cref="MixedRecognizer"/>).
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

        IReadOnlyList<RecognizedWord> ReadAsScanned() => recognizer.Recognize(image.Pixels, image.Width, image.Height, 3, cancel);
        List<OcrWord> OnPage(IReadOnlyList<RecognizedWord> read) =>
            read.Select(w => new OcrWord(w.Text, new RectD(w.X / scale, w.Y / scale, w.Width / scale, w.Height / scale))).ToList();

        if (!options.Clean)
        {
            var read = ReadAsScanned();
            var plain = OnPage(read);
            return new RecognizedPage(options.CheckWords ? Mark(plain, null, Unsure(read), spelling) : plain, 0, 0, null);
        }

        var color = options.KeepCleanedImage && IsColor(image.Pixels);
        var cleaned = ScanCleanup.Clean(image.Pixels, image.Width, image.Height, 3, dpi, color, cancel, options.Steps);
        var (turns, gray, bgr) = (cleaned.QuarterTurns, cleaned.Gray, cleaned.Bgr);
        var found = recognizer.Recognize(gray.Pixels, gray.Width, gray.Height, 1, cancel);
        if (!cleaned.UprightSure)
        {
            // The lines didn't say which way up: read it the other way too. The page is turned over only when the turned
            // reading has clearly more real words; otherwise it stays as rendered, whatever the ink hinted. Digits read
            // plausibly both ways (6 and 9, 0 and 8: the redaction corpus's page of numbers read "OO 6830 9999" turned),
            // and count as words neither way, so a page of numbers isn't turned on a guess.
            var other = ScanCleanup.Turn(gray.Pixels, gray.Width, gray.Height, 1, 2);
            var otherFound = recognizer.Recognize(other, gray.Width, gray.Height, 1, cancel);
            var hinted = (cleaned.QuarterTurns & 2) != 0;
            var (asRendered, turnedOver) = hinted ? (otherFound, found) : (found, otherFound);
            if (ClearlyMore(Plausible(turnedOver, spelling), Plausible(asRendered, spelling)) != hinted)
            {
                (found, turns) = (otherFound, (turns + 2) % 4);
                gray = new GrayImage(gray.Width, gray.Height, other);
                if (bgr is not null) bgr = ScanCleanup.Turn(bgr, gray.Width, gray.Height, 3, 2);
            }
        }

        if (options.RereadMissed && RereaderOf(recognizer) is { } rereader) found = MissedLines.Reread(gray, found, dpi, rereader, cancel);

        var frame = new ScanFrame(image.Width, image.Height, cleaned.Skew, turns, cleaned.Perspective, cleaned.Curve);
        var onScan = found.Select(w => frame.ToRendered(w, scale)).ToList();
        var words = options.KeepCleanedImage ? OnPage(found) : onScan;
        // A page that wasn't upright as scanned can't be read as scanned: nothing to compare with. An engine that says how
        // sure it is of each word (Tesseract) isn't asked twice: its confidence marks the doubtful words, at half the time.
        if (options.CheckWords)
        {
            var compare = turns == 0 && !found.Any(w => w.Confidence is not null);
            words = Mark(words, compare ? SuspectWords.ReadDifferently(onScan, OnPage(ReadAsScanned()), spelling) : null, Unsure(found), spelling);
        }

        CleanedPageImage? keep = null;
        if (options.KeepCleanedImage)
        {
            // Stored in the page's own orientation; the page's /Rotate then turns it upright.
            var (w, h) = turns % 2 == 0 ? (gray.Width, gray.Height) : (gray.Height, gray.Width);
            keep = bgr is not null
                ? CleanedPageImage.From(w, h, 3, ScanCleanup.Turn(bgr, gray.Width, gray.Height, 3, -turns), turns)
                : CleanedPageImage.From(w, h, 1, ScanCleanup.Turn(gray.Pixels, gray.Width, gray.Height, 1, -turns), turns);
        }
        return new RecognizedPage(words, cleaned.Skew, turns, keep);
    }

    /// <summary>
    /// The recognizer that reads again what <paramref name=recognizer/> left out (<see cref=MissedLines/>): itself,
    /// unless it names another or none (<see cref=IRereadsMissed/>).
    /// </summary>
    public static ITextRecognizer? RereaderOf(ITextRecognizer recognizer) => recognizer is IRereadsMissed r ? r.Rereader : recognizer;

    /// <summary>The languages a recognizer reads (BCP-47 tags, first one first): two for a page in two languages.</summary>
    public static IReadOnlyList<string> LanguagesOf(ITextRecognizer recognizer) => recognizer switch
    {
        SerialRecognizer s => LanguagesOf(s.Inner),
        MixedRecognizer m => [.. LanguagesOf(m.First).Concat(LanguagesOf(m.Second)).Distinct(StringComparer.OrdinalIgnoreCase)],
        TesseractRecognizer t => [.. t.Languages.Select(l => l.Tag)],
        _ => [recognizer.Language],
    };

    /// <summary>Which words the engine itself was unsure of (its confidence under <see cref="SuspectWords.UnsureBelow"/>; Tesseract's).</summary>
    private static bool[] Unsure(IReadOnlyList<RecognizedWord> read) => [.. read.Select(w => w.Confidence < SuspectWords.UnsureBelow)];

    private static List<OcrWord> Mark(List<OcrWord> words, bool[]? readDifferently, bool[] unsure, ISpelling? spelling)
    {
        for (var i = 0; i < words.Count; i++)
        {
            var reasons = SuspectWords.Check(words[i].Text, spelling);
            if (readDifferently is not null && readDifferently[i]) reasons |= SuspectReasons.ReadDifferently;
            if (i < unsure.Length && unsure[i]) reasons |= SuspectReasons.Unsure;
            if (reasons != SuspectReasons.None) words[i] = words[i] with { Suspect = reasons };
        }
        return words;
    }

    /// <summary>Whether a reading with <paramref name="more"/> real words beats one with <paramref name="fewer"/> by a margin: two words, or a quarter more.</summary>
    internal static bool ClearlyMore(int more, int fewer) => more >= fewer + Math.Max(2, (fewer + 3) / 4);

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
/// (<see cref="Width"/> × <see cref="Height"/> px), its photographed page warped to a rectangle (<see cref="Perspective"/>,
/// when there was one), straightened by <see cref="Skew"/> degrees (rotated anticlockwise by that much about its centre,
/// same size), its bent lines flattened (<see cref="Curve"/>) and then turned <see cref="QuarterTurns"/> quarters
/// clockwise. Turning and straightening are both about the centre, so going back is turning back, unbending, rotating
/// by the skew, then mapping into the photo.
/// </summary>
public readonly record struct ScanFrame(int Width, int Height, double Skew, int QuarterTurns, Perspective? Perspective = null, LineCurve? Curve = null)
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
        if (Curve is { } curve) (x, y) = curve.Source(x, y);
        if (Skew != 0)
        {
            // Undo the straightening: the content goes back clockwise by the skew, about the centre.
            var (sin, cos) = Math.SinCos(Skew * Math.PI / 180);
            var (dx, dy) = (x - w / 2.0, y - h / 2.0);
            (x, y) = (w / 2.0 + dx * cos - dy * sin, h / 2.0 + dx * sin + dy * cos);
        }
        return Perspective is { } p ? p.Source(x, y) : (x, y);
    }

    /// <summary>
    /// A recognized word of the cleaned image as a word on the page (points; its box turned by <see cref="TextAngle"/>).
    /// Through a warp (<see cref="Perspective"/>, <see cref="Curve"/>) a word takes the length, height and slant its
    /// box's middle lines have on the page.
    /// </summary>
    public OcrWord ToRendered(RecognizedWord word, double scale)
    {
        var (cx, cy) = ToRendered(word.X + word.Width / 2, word.Y + word.Height / 2);
        var level = new OcrWord(word.Text, new RectD((cx - word.Width / 2) / scale, (cy - word.Height / 2) / scale, word.Width / scale, word.Height / scale), TextAngle);
        if (Perspective is null && Curve is null) return level;
        var (mid, centre) = (word.Y + word.Height / 2, word.X + word.Width / 2);
        var (l, r) = (ToRendered(word.X, mid), ToRendered(word.X + word.Width, mid));
        var (t, b) = (ToRendered(centre, word.Y), ToRendered(centre, word.Y + word.Height));
        var width = Math.Sqrt((r.X - l.X) * (r.X - l.X) + (r.Y - l.Y) * (r.Y - l.Y));
        var height = Math.Sqrt((b.X - t.X) * (b.X - t.X) + (b.Y - t.Y) * (b.Y - t.Y));
        var angle = Math.Atan2(r.Y - l.Y, r.X - l.X) * 180 / Math.PI;
        if (!(width > 0 && height > 0 && double.IsFinite(width) && double.IsFinite(height) && double.IsFinite(angle) && double.IsFinite(cx) && double.IsFinite(cy))) return level;
        return new OcrWord(word.Text, new RectD((cx - width / 2) / scale, (cy - height / 2) / scale, width / scale, height / scale), Math.Round(angle, 2));
    }
}
