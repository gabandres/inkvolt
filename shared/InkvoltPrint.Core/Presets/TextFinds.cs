using System.Globalization;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Core.Presets;

/// <summary>
/// What a scan's first page says that can name its file (roadmap 4.11): a <see cref="Date"/> found on it, its <see cref="Title"/>
/// (the first heading, else its first line) and an invoice-like <see cref="Number"/>. Each null when the page doesn't say.
/// </summary>
public sealed record FoundInText(DateTime? Date, string? Title, string? Number)
{
    public static readonly FoundInText None = new(null, null, null);
}

/// <summary>
/// Reads <see cref="FoundInText"/> from a page's recognized text, for the file-name template's <c>{text-date}</c>,
/// <c>{text-title}</c> and <c>{text-number}</c>. Dates: 2026-03-04, 3/4/2026 or 4.3.26 (day or month first as the culture
/// writes them, unless one of them is over 12), "March 4, 2026", "4 March 2026", "4 de marzo de 2026"; one on a line that says
/// date ("Date", "Fecha", "Dated") comes first. A number: what follows "Invoice", "Order", "Receipt", "No.", "#", "Factura"…
/// and has a digit, else a code like INV-20931. Never trusts the text: lines and lengths are bounded.
/// </summary>
public static partial class TextFinds
{
    /// <summary>Longest title kept (characters, cut at a word).</summary>
    public const int MaxTitle = 60;

    /// <summary>Lines read from the top of the page.</summary>
    public const int MaxLines = 200;

    private const int MaxLineLength = 500;

    public static FoundInText Find(IReadOnlyList<OcrWord>? words, CultureInfo? culture = null) => Find(PageText.Lines(words), culture);

    public static FoundInText Find(IReadOnlyList<TextLine> lines, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        var read = lines.Take(MaxLines).Select(l => l with { Text = l.Text.Length > MaxLineLength ? l.Text[..MaxLineLength] : l.Text }).ToList();
        return new FoundInText(FindDate(read.Select(l => l.Text).ToList(), culture), FindTitle(read), FindNumber(read.Select(l => l.Text).ToList()));
    }

    // ---- Dates ----

    [GeneratedRegex(@"\b(\d{4})[-./](\d{1,2})[-./](\d{1,2})\b")]
    private static partial Regex IsoDate();

    [GeneratedRegex(@"\b(\d{1,2})[-./](\d{1,2})[-./](\d{4}|\d{2})\b")]
    private static partial Regex NumericDate();

    [GeneratedRegex(@"\b(\d{1,2})(?:st|nd|rd|th|º)?\.?\s+(?:de\s+)?([\p{L}]{3,10})\.?,?\s+(?:de\s+|del\s+)?(\d{4})\b", RegexOptions.IgnoreCase)]
    private static partial Regex DayMonthYear();

    [GeneratedRegex(@"\b([\p{L}]{3,10})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b", RegexOptions.IgnoreCase)]
    private static partial Regex MonthDayYear();

    [GeneratedRegex(@"\b(date|dated|fecha|issued|emitid[ao])\b", RegexOptions.IgnoreCase)]
    private static partial Regex DateWord();

    /// <summary>The first date on the page, one on a line that says it is the date first.</summary>
    internal static DateTime? FindDate(IReadOnlyList<string> lines, CultureInfo culture)
    {
        var months = MonthNames(culture);
        var dayFirst = !culture.DateTimeFormat.ShortDatePattern.TrimStart().StartsWith('M');
        DateTime? first = null;
        foreach (var line in lines)
        {
            if (DateIn(line, months, dayFirst) is not { } date) continue;
            if (DateWord().IsMatch(line)) return date;
            first ??= date;
        }
        return first;
    }

    private static DateTime? DateIn(string line, Dictionary<string, int> months, bool dayFirst)
    {
        var found = new List<(int At, DateTime Date)>();
        foreach (Match m in IsoDate().Matches(line))
            if (Make(Int(m, 1), Int(m, 2), Int(m, 3)) is { } d) found.Add((m.Index, d));
        foreach (Match m in NumericDate().Matches(line))
        {
            var (a, b, y) = (Int(m, 1), Int(m, 2), Int(m, 3));
            if (m.Groups[3].Value.Length == 2) y += y < 70 ? 2000 : 1900;
            var day = a > 12 ? true : b > 12 ? false : dayFirst; // one over 12 can only be the day
            if (Make(y, day ? b : a, day ? a : b) is { } d) found.Add((m.Index, d));
        }
        foreach (Match m in DayMonthYear().Matches(line))
            if (months.TryGetValue(m.Groups[2].Value.ToLowerInvariant(), out var month) && Make(Int(m, 3), month, Int(m, 1)) is { } d) found.Add((m.Index, d));
        foreach (Match m in MonthDayYear().Matches(line))
            if (months.TryGetValue(m.Groups[1].Value.ToLowerInvariant(), out var month) && Make(Int(m, 3), month, Int(m, 2)) is { } d) found.Add((m.Index, d));
        return found.Count == 0 ? null : found.MinBy(f => f.At).Date;
    }

    private static int Int(Match m, int group) => int.TryParse(m.Groups[group].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : -1;

    private static DateTime? Make(int year, int month, int day) =>
        year is >= 1900 and <= 2100 && month is >= 1 and <= 12 && day >= 1 && day <= DateTime.DaysInMonth(year, month) ? new DateTime(year, month, day) : null;

    /// <summary>Month names and short names, lower case and without dots: English, Spanish and the culture's own.</summary>
    private static Dictionary<string, int> MonthNames(CultureInfo culture)
    {
        var names = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var c in new[] { CultureInfo.InvariantCulture, CultureInfo.GetCultureInfo("es"), culture })
            for (var i = 0; i < 12; i++)
                foreach (var name in new[] { c.DateTimeFormat.MonthNames[i], c.DateTimeFormat.AbbreviatedMonthNames[i], c.DateTimeFormat.MonthGenitiveNames[i] })
                {
                    var key = name.Trim().TrimEnd('.').ToLowerInvariant();
                    if (key.Length >= 3) names.TryAdd(key, i + 1);
                }
        names.TryAdd("sept", 9);
        names.TryAdd("setiembre", 9);
        return names;
    }

    // ---- The title ----

    /// <summary>
    /// The first heading: the tallest line in the page's top third, when it stands out (a third taller than most lines); else the
    /// first line with three letters or more. Cut to <see cref="MaxTitle"/> characters at a word.
    /// </summary>
    internal static string? FindTitle(IReadOnlyList<TextLine> lines)
    {
        var worded = lines.Where(l => l.Text.Count(char.IsLetter) >= 3).ToList();
        if (worded.Count == 0) return null;
        var heights = worded.Select(l => l.Height).OrderBy(h => h).ToList();
        var usual = heights[heights.Count / 2];
        var bottom = lines.Max(l => l.Top + l.Height);
        var top = lines.Min(l => l.Top);
        var heading = worded.Where(l => l.Top <= top + (bottom - top) / 3 && l.Height >= usual * 4 / 3).MaxBy(l => l.Height);
        return Shorten(PageText.WithoutStrays(heading ?? worded[0]));
    }

    private static string? Shorten(string text)
    {
        var s = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim(' ', '.', ',', ':', ';', '-');
        if (s.Length > MaxTitle)
        {
            var cut = s.LastIndexOf(' ', MaxTitle);
            s = (cut > MaxTitle / 2 ? s[..cut] : s[..MaxTitle]).TrimEnd(' ', ',', ':', ';', '-');
        }
        return s.Length == 0 ? null : s;
    }

    // ---- The number ----

    [GeneratedRegex(@"(?:\b(?:invoice|inv|receipt|order|ref|reference|document|doc|bill|factura|recibo|pedido|folio|n[uú]mero|no|num|nr)\b\.?|#|n[º°]\.?)\s*(?:(?:no|n[uú]mero|number|num|n[º°])\b\.?\s*)?[:#]?\s*([A-Z0-9][A-Z0-9\-/.]{1,24})", RegexOptions.IgnoreCase)]
    private static partial Regex LabelledNumber();

    [GeneratedRegex(@"\b([A-Z]{2,5}-?\d{3,12})\b")]
    private static partial Regex CodeLike();

    /// <summary>An invoice, order or receipt number: labelled first, else a code like INV-20931. It must have a digit.</summary>
    internal static string? FindNumber(IReadOnlyList<string> lines)
    {
        foreach (var line in lines)
            foreach (Match m in LabelledNumber().Matches(line))
            {
                var value = m.Groups[1].Value.TrimEnd('.', '-', '/');
                if (value.Any(char.IsDigit) && !IsoDate().IsMatch(value) && !NumericDate().IsMatch(value)) return value;
            }
        foreach (var line in lines)
            if (CodeLike().Match(line) is { Success: true } m) return m.Groups[1].Value;
        return null;
    }
}
