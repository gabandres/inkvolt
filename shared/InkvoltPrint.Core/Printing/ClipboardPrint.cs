using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.Printing;

/// <summary>What the clipboard holds, as the app read it: text, a picture's size, files copied in File Explorer.</summary>
/// <param name="Text">Its text, or null.</param>
/// <param name="Picture">Its picture's size in pixels, or null.</param>
/// <param name="Files">Files copied in File Explorer (full paths), or empty.</param>
public sealed record ClipboardContent(string? Text, (int Width, int Height)? Picture, IReadOnlyList<string> Files);

/// <summary>What Print the clipboard does with it.</summary>
public enum ClipboardWhat
{
    /// <summary>Nothing it can print: no text, picture or file.</summary>
    Nothing,

    /// <summary>The text, laid out on pages and opened in Print a PDF.</summary>
    Text,

    /// <summary>The picture, opened in Print photos.</summary>
    Picture,

    /// <summary>One PDF copied in File Explorer, opened in Print a PDF.</summary>
    Pdf,

    /// <summary>Pictures copied in File Explorer, opened in Print photos.</summary>
    Pictures,

    /// <summary>Several files, PDFs and pictures, opened in Batch.</summary>
    Batch,

    /// <summary>Files, but none is a PDF or a picture.</summary>
    NotPrintable,

    /// <summary>A picture or text too big to print from the clipboard.</summary>
    TooBig,
}

/// <summary>The decision: what to print, and the files when they came from File Explorer.</summary>
public sealed record ClipboardPlan(ClipboardWhat What, IReadOnlyList<string> Files);

/// <summary>Where the text's lines go on the paper: how many characters a line holds and how many lines a page.</summary>
public sealed record ClipboardTextLayout(double PaperWidthInches, double PaperHeightInches, double MarginInches, double FontPoints, int Columns, int Lines)
{
    /// <summary>The distance between two lines' baselines, in inches.</summary>
    public double LineInches => FontPoints * ClipboardPrint.LineSpacing / 72;

    /// <summary>One character's width, in inches (a monospaced font: Consolas's advance is 0.55 of its size).</summary>
    public double ColumnInches => FontPoints * ClipboardPrint.CharWidth / 72;
}

/// <summary>
/// Print the clipboard (roadmap 4.13): what's on it decides where it goes, so the usual print options come with it. Files copied in
/// File Explorer go as they are (one PDF to Print a PDF, pictures to Print photos, several to Batch); a picture goes to Print
/// photos; text is laid out on pages here (<see cref="Pages"/>) and printed as a PDF in Print a PDF. When there are both text and a
/// picture (Word and Excel put both; a browser's copied picture often brings its address), the text wins unless it's one line
/// with no space in it (<see cref="PrefersPicture"/>). Everything on the clipboard came from another app: it is bounded
/// (<see cref="MaxChars"/>, <see cref="MaxPages"/>, <see cref="MaxPicturePixels"/>, <see cref="MaxFiles"/>).
/// </summary>
public static class ClipboardPrint
{
    public const int MaxChars = 2_000_000, MaxPages = 300, MaxFiles = 100, TabStop = 8;
    public const long MaxPicturePixels = 100_000_000;
    public const double CharWidth = 0.55, LineSpacing = 1.2;

    private static readonly string[] PictureTypes = [".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".heic", ".heif", ".webp"];

    public static ClipboardPlan Choose(ClipboardContent content)
    {
        var files = (content.Files ?? []).Where(f => !string.IsNullOrWhiteSpace(f)).Take(MaxFiles + 1).ToList();
        if (files.Count > 0)
        {
            if (files.Count > MaxFiles) return new(ClipboardWhat.TooBig, []);
            var printable = files.Where(f => IsPdf(f) || IsPicture(f)).ToList();
            if (printable.Count == 0) return new(ClipboardWhat.NotPrintable, []);
            if (printable.All(IsPicture)) return new(ClipboardWhat.Pictures, printable);
            return printable.Count == 1 ? new(ClipboardWhat.Pdf, printable) : new(ClipboardWhat.Batch, printable);
        }
        var text = content.Text is { } t && t.Any(c => !char.IsWhiteSpace(c)) ? t : null;
        var picture = content.Picture is { Width: > 0, Height: > 0 } p ? p : ((int, int)?)null;
        if (picture is { } size && (text is null || PrefersPicture(text)))
            return (long)size.Item1 * size.Item2 > MaxPicturePixels ? new(ClipboardWhat.TooBig, []) : new(ClipboardWhat.Picture, []);
        if (text is null) return new(ClipboardWhat.Nothing, []);
        return text.Length > MaxChars ? new(ClipboardWhat.TooBig, []) : new(ClipboardWhat.Text, []);
    }

    /// <summary>Text beside a picture that's only its address or file name: one line with no space in it.</summary>
    public static bool PrefersPicture(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length <= 2048 && !trimmed.Any(char.IsWhiteSpace);
    }

    public static bool IsPdf(string path) => path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase);

    public static bool IsPicture(string path) => PictureTypes.Any(e => path.EndsWith(e, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// The layout on <paramref name="widthInches"/> × <paramref name="heightInches"/> paper: 3/4-inch margins, 10-point type
    /// (a little smaller on narrow paper so a line still holds 40 characters), as many whole columns and lines as fit.
    /// </summary>
    public static ClipboardTextLayout Layout(double widthInches, double heightInches)
    {
        if (!double.IsFinite(widthInches) || !double.IsFinite(heightInches) || widthInches < 2 || heightInches < 2 || widthInches > 50 || heightInches > 50)
            (widthInches, heightInches) = (8.5, 11);
        const double margin = 0.75;
        var points = 10.0;
        var usable = widthInches - 2 * margin;
        while (points > 6 && usable / (points * CharWidth / 72) < 40) points -= 0.5;
        var columns = Math.Max(1, (int)Math.Floor(usable / (points * CharWidth / 72) + 1e-9));
        var lines = Math.Max(1, (int)Math.Floor((heightInches - 2 * margin) / (points * LineSpacing / 72) + 1e-9));
        return new ClipboardTextLayout(widthInches, heightInches, margin, points, columns, lines);
    }

    /// <summary>
    /// The text in pages of lines: line ends of any kind, tabs to the next stop of <see cref="TabStop"/>, control characters out,
    /// lines wrapped at a space where one is near the end else cut, a wide character (CJK, Hangul, fullwidth forms) counted
    /// as two columns. A form feed starts a new page. Past <see cref="MaxPages"/> the rest is left out and
    /// <paramref name="cut"/> says so. Trailing empty lines and pages are dropped.
    /// </summary>
    public static IReadOnlyList<IReadOnlyList<string>> Pages(string text, int columns, int linesPerPage, out bool cut)
    {
        columns = Math.Max(1, columns);
        linesPerPage = Math.Max(1, linesPerPage);
        var over = text.Length > MaxChars;
        if (over) text = text[..MaxChars];
        var pages = new List<List<string>>();
        var page = new List<string>();
        foreach (var raw in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var parts = raw.Split('\f');
            for (var p = 0; p < parts.Length && !over; p++)
            {
                if (p > 0 && page.Count > 0) (pages, page) = (Then(pages, page), []);
                foreach (var line in Wrap(Expand(parts[p]), columns))
                {
                    if (page.Count == linesPerPage) (pages, page) = (Then(pages, page), []);
                    if (pages.Count >= MaxPages)
                    {
                        over = true;
                        break;
                    }
                    page.Add(line);
                }
            }
            if (over) break;
        }
        if (page.Count > 0 && pages.Count < MaxPages) pages.Add(page);
        cut = over;
        // No blank lines or pages at the end.
        while (pages.Count > 0)
        {
            var last = pages[^1];
            while (last.Count > 0 && last[^1].Length == 0) last.RemoveAt(last.Count - 1);
            if (last.Count > 0) break;
            pages.RemoveAt(pages.Count - 1);
        }
        return pages;

        static List<List<string>> Then(List<List<string>> pages, List<string> page)
        {
            pages.Add(page);
            return pages;
        }
    }

    /// <summary>Tabs to spaces at the next stop; control characters (other than tab) and lone surrogates out.</summary>
    internal static string Expand(string line)
    {
        var sb = new StringBuilder(line.Length);
        var column = 0;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (c == '\t')
            {
                var spaces = TabStop - column % TabStop;
                sb.Append(' ', spaces);
                column += spaces;
            }
            else if (char.IsHighSurrogate(c) && i + 1 < line.Length && char.IsLowSurrogate(line[i + 1]))
            {
                sb.Append(c).Append(line[++i]);
                column += 2;
            }
            else if (!char.IsControl(c) && !char.IsSurrogate(c))
            {
                sb.Append(c);
                column += Width(c);
            }
        }
        return sb.ToString();
    }

    /// <summary>A line cut to <paramref name="columns"/>: at the last space in its second half when there is one, else where it's full.</summary>
    internal static IEnumerable<string> Wrap(string line, int columns)
    {
        if (line.Length == 0)
        {
            yield return "";
            yield break;
        }
        var start = 0;
        while (start < line.Length)
        {
            var width = 0;
            var end = start;
            while (end < line.Length)
            {
                var step = char.IsHighSurrogate(line[end]) && end + 1 < line.Length ? 2 : 1;
                var w = step == 2 ? 2 : Width(line[end]);
                if (width + w > columns && end > start) break;
                width += w;
                end += step;
            }
            if (end < line.Length)
            {
                var space = line.LastIndexOf(' ', end - 1, end - start);
                if (space > start + (end - start) / 2) end = space + 1;
            }
            yield return line[start..end].TrimEnd();
            start = end;
        }
    }

    /// <summary>Two columns for East Asian wide and fullwidth characters, one for the rest.</summary>
    internal static int Width(char c) =>
        c is >= '\u1100' and <= '\u115F' or >= '\u2E80' and <= '\uA4CF' or >= '\uAC00' and <= '\uD7A3' or >= '\uF900' and <= '\uFAFF'
            or >= '\uFE30' and <= '\uFE4F' or >= '\uFF00' and <= '\uFF60' or >= '\uFFE0' and <= '\uFFE6' ? 2 : 1;

    /// <summary>"Clipboard 2026-11-22 0130": the name the PDF or picture is saved under (a job's name in the queue).</summary>
    public static string Name(DateTime now, string word) =>
        string.Format(CultureInfo.InvariantCulture, "{0} {1:yyyy-MM-dd HHmm}", word, now);
}
