namespace InkvoltPdf.Core;

/// <summary>What differs between two looks of the same words.</summary>
[Flags]
public enum LookParts { None = 0, Font = 1, Size = 2, Color = 4, Bold = 8, Italic = 16 }

/// <summary>How text is set: its font family (<see cref="FontNames.Family"/>), size in points, bold, italic and color (0xRRGGBB).</summary>
public sealed record WordLook(string Font, double Size, bool Bold, bool Italic, uint Color)
{
    /// <summary>Sizes closer than this are the same (Word's sizes come out of a PDF as 11.04 or 10.98).</summary>
    public const double SizeTolerance = 0.25;

    /// <summary>A color channel closer than this is the same (black set as 0x050505, a color through another profile).</summary>
    public const int ColorTolerance = 12;

    public LookParts PartsDifferentFrom(WordLook other)
    {
        var parts = LookParts.None;
        if (!string.Equals(Font, other.Font, StringComparison.OrdinalIgnoreCase)) parts |= LookParts.Font;
        if (Math.Abs(Size - other.Size) >= SizeTolerance) parts |= LookParts.Size;
        if (Bold != other.Bold) parts |= LookParts.Bold;
        if (Italic != other.Italic) parts |= LookParts.Italic;
        if (Channel(Color, 16, other.Color) || Channel(Color, 8, other.Color) || Channel(Color, 0, other.Color)) parts |= LookParts.Color;
        return parts;

        static bool Channel(uint a, int shift, uint b) => Math.Abs((int)(a >> shift & 0xFF) - (int)(b >> shift & 0xFF)) > ColorTolerance;
    }
}

/// <summary>A formatting change: the same words, set as <see cref="Old"/> and now as <see cref="New"/>.</summary>
public sealed record LookChange(WordLook Old, WordLook New, LookParts Parts)
{
    /// <summary>"bold added, size 11 → 14 pt": for the list and the comments.</summary>
    public string Describe()
    {
        var parts = new List<string>();
        if (Parts.HasFlag(LookParts.Bold)) parts.Add(New.Bold ? "bold added" : "bold removed");
        if (Parts.HasFlag(LookParts.Italic)) parts.Add(New.Italic ? "italic added" : "italic removed");
        if (Parts.HasFlag(LookParts.Size)) parts.Add($"size {Points(Old.Size)} → {Points(New.Size)} pt");
        if (Parts.HasFlag(LookParts.Font)) parts.Add($"font {Name(Old.Font)} → {Name(New.Font)}");
        if (Parts.HasFlag(LookParts.Color)) parts.Add($"color {ColorName(Old.Color)} → {ColorName(New.Color)}");
        return string.Join(", ", parts);

        static string Points(double size) => size.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture);
        static string Name(string font) => font.Length > 0 ? font : "unnamed";
        static string ColorName(uint color) => color switch { 0 => "black", 0xFFFFFF => "white", _ => $"#{color:X6}" };
    }
}

/// <summary>The looks of a page's text: for each UTF-16 unit of <see cref="PageText.Text"/>, as runs. Immutable; shared freely.</summary>
public sealed class PageLooks
{
    private readonly int[] _starts;
    private readonly WordLook[] _looks;

    /// <param name="runs">Each run's first unit and its look, in order; the first run covers everything before it too.</param>
    public PageLooks(IReadOnlyList<(int Start, WordLook Look)> runs)
    {
        _starts = new int[runs.Count];
        _looks = new WordLook[runs.Count];
        for (var i = 0; i < runs.Count; i++) (_starts[i], _looks[i]) = runs[i];
    }

    public bool IsEmpty => _looks.Length == 0;

    /// <summary>The look at a unit of the text; null on a page without any.</summary>
    public WordLook? At(int index)
    {
        if (_looks.Length == 0) return null;
        var i = Array.BinarySearch(_starts, index);
        if (i < 0) i = ~i - 1;
        return _looks[Math.Max(0, i)];
    }

    /// <summary>The look most of [start, end) has.</summary>
    public WordLook? Main(int start, int end)
    {
        if (_looks.Length == 0) return null;
        WordLook? best = null;
        var bestUnits = -1;
        var i = Array.BinarySearch(_starts, start);
        if (i < 0) i = ~i - 1;
        for (i = Math.Max(0, i); i < _looks.Length && (i == 0 || _starts[i] < end); i++)
        {
            var from = Math.Max(start, i == 0 ? start : _starts[i]);
            var to = i + 1 < _starts.Length ? Math.Min(end, _starts[i + 1]) : end;
            if (to - from > bestUnits) (best, bestUnits) = (_looks[i], to - from);
        }
        return best;
    }
}

/// <summary>What Compare reads from a page.</summary>
/// <param name="IsPicture">Pictures cover most of the page: a scan, whatever text lies over it.</param>
public sealed record ComparePage(PageText Text, PageLooks Looks, bool IsPicture)
{
    public static ComparePage Empty { get; } = new(PageText.Empty, new PageLooks([]), false);
}

/// <summary>One document's side of a comparison: its pages' text, and what is known about them.</summary>
/// <param name="Looks">Per page, how its text is set; null, or null for a page, when unknown (a scan's text has no looks): nothing is said about formatting there.</param>
/// <param name="Scanned">Per page, whether its text was read from a picture of the page (recognized, or an OCR layer over a scan), so a difference may be a misreading.</param>
public sealed record CompareSource(IReadOnlyList<PageText> Pages, IReadOnlyList<PageLooks?>? Looks = null, IReadOnlyList<bool>? Scanned = null)
{
    public PageLooks? LooksOf(int page) => Looks is not null && page < Looks.Count ? Looks[page] : null;

    public bool IsScanned(int page) => Scanned is not null && page < Scanned.Count && Scanned[page];

    /// <summary>
    /// A document as read for Compare, with what was recognized on its scans in place of the pages' text (null where a page
    /// wasn't). A scan says nothing about formatting: an OCR layer's font and size aren't what the page shows.
    /// </summary>
    /// <param name="formatting">Whether formatting is compared at all.</param>
    public static CompareSource Of(IReadOnlyList<ComparePage> pages, IReadOnlyDictionary<int, PageText>? recognized = null, bool formatting = true) =>
        new([.. pages.Select((p, i) => recognized is not null && recognized.TryGetValue(i, out var read) ? read : p.Text)],
            formatting ? [.. pages.Select(p => p.IsPicture ? null : p.Looks)] : null,
            [.. pages.Select(p => p.IsPicture)]);
}
