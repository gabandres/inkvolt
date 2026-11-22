using System.Globalization;

namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// What turns a scanned page upright: <see cref="QuarterTurns"/> quarters clockwise, after straightening it by
/// <see cref="Skew"/> degrees (measured the way its lines run, so on a page lying sideways too). <see cref="Sure"/> only when
/// both the way its lines run and which way up they are were clear; a page that isn't sure is never turned.
/// </summary>
public readonly record struct UprightFound(int QuarterTurns, double Skew, bool Sure)
{
    public static readonly UprightFound Unsure = new(0, 0, false);

    /// <summary>The turns to make, or 0 when not sure.</summary>
    public int Turns => Sure ? QuarterTurns : 0;
}

/// <summary>
/// Pages turned upright on their own (a sheet fed upside down, a landscape page in a portrait feeder): the way a page's
/// lines run and which way up they are, read on the small copy of a scan the page checks use (about 100 dpi), with the
/// same steps Inkvolt PDF's text recognition takes (<see cref="ScanCleanup"/>'s lines, <see cref="Upright"/>): the lines
/// measured across the page and down it, the page straightened and its paper evened out, then the ink above and below
/// each line's middle. Latin, Greek and Cyrillic letters rise above the line more than they hang below it; scripts that
/// don't (Hebrew, Arabic, Chinese, Indian scripts…) aren't turned (<see cref="SuitsLanguage"/>).
/// </summary>
public static class PageUpright
{
    /// <param name="small">The page in grey, about 100 dpi (a copy at more than 150 is made smaller first).</param>
    /// <param name="dpi">The copy's pixels per inch.</param>
    public static UprightFound Find(GrayImage small, double dpi)
    {
        if (!double.IsFinite(dpi) || dpi < 20 || small.Width < 32 || small.Height < 32) return UprightFound.Unsure;
        var factor = dpi > 150 ? (int)Math.Round(dpi / 100) : 1;
        var img = ScanCleanup.Downscale(small, factor);
        var ppi = (int)Math.Round(dpi / factor);
        var (skew, sideways, axisSure) = ScanCleanup.LinesOf(img);
        if (!axisSure) return UprightFound.Unsure;
        var (w, h) = (img.Width, img.Height);
        var px = skew != 0 ? PageRotate.Rotate(img.Pixels, w, h, w, 1, -skew) : (byte[])img.Pixels.Clone();
        PaperLevel.Whiten(px, PaperLevel.Estimate(px, w, h, ppi));
        var upright = sideways ? new GrayImage(h, w, ScanCleanup.Turn(px, w, h, 1, 1)) : new GrayImage(w, h, px);
        var (flipped, waySure) = Upright.UpsideDown(upright);
        return waySure ? new(((sideways ? 1 : 0) + (flipped ? 2 : 0)) % 4, skew, true) : UprightFound.Unsure;
    }

    /// <summary>
    /// The straightening a scan's check gives a page by <paramref name="skew"/> (<see cref="UprightFound.Skew"/>): what
    /// <see cref="Deskew.Angle"/> would, within its limits (<see cref="Deskew.MinAngle"/> to <see cref="Deskew.MaxAngle"/>), else none.
    /// </summary>
    public static double StraightenBy(double skew) =>
        double.IsFinite(skew) && Math.Abs(skew) >= Deskew.MinAngle && Math.Abs(skew) <= Deskew.MaxAngle ? skew : 0;

    /// <summary>
    /// Whether pages in <paramref name="language"/> (a BCP-47 tag, the OCR language) can be told which way up: not a script
    /// written right to left, nor one of the scripts listed below. Unknown or empty: yes.
    /// </summary>
    public static bool SuitsLanguage(string? language)
    {
        if (string.IsNullOrWhiteSpace(language)) return true;
        var primary = language.Split('-', '_')[0].ToLowerInvariant();
        if (OtherScripts.Contains(primary)) return false;
        try
        {
            return !CultureInfo.GetCultureInfo(language).TextInfo.IsRightToLeft;
        }
        catch (CultureNotFoundException)
        {
            return true;
        }
    }

    /// <summary>Languages whose letters don't sit like Latin ones (left to right, but not Latin, Greek, Cyrillic or Armenian).</summary>
    private static readonly HashSet<string> OtherScripts =
    [
        "he", "iw", "yi", "ar", "fa", "ur", "ps", "sd", "ug", "ckb", "dv", "syr",
        "zh", "ja", "ko", "th", "lo", "km", "my", "bo", "dz",
        "hi", "mr", "ne", "sa", "bn", "as", "pa", "gu", "or", "ta", "te", "kn", "ml", "si", "am", "ti", "ka",
    ];
}
