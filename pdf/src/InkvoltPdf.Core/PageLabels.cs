namespace InkvoltPdf.Core;

/// <summary>How a run of page labels is numbered: 1, 2, 3; I, II; i, ii; A, B; a, b; or no number (the prefix alone).</summary>
public enum PageNumbering { None, Decimal, UpperRoman, LowerRoman, UpperLetters, LowerLetters }

/// <summary>
/// A run of page labels: its numbering, the text before the number ("A-" makes A-1, A-2) and the first number.
/// </summary>
public sealed record PageLabelStyle(PageNumbering Numbering, string Prefix, int Start)
{
    /// <summary>The label of the page <paramref name="offset"/> pages into the run.</summary>
    public string Format(int offset) => Prefix + DocumentFeatures.FormatNumber((int)Math.Min(int.MaxValue, (long)Start + offset), PageLabels.StyleName(Numbering));
}

/// <summary>
/// Page labels (/PageLabels): what the page box, thumbnails and Go To Page show for a page ("iv", "A-3") instead of its
/// number. Edit Page Labels sets them for a range of pages, the pages after it keeping theirs; a document whose labels
/// all come back to plain 1, 2, 3 has none written. Pages moved, inserted or removed keep their labels
/// (<see cref="PageEditor"/>).
/// </summary>
public static class PageLabels
{
    /// <summary>The longest prefix kept, in characters.</summary>
    public const int MaxPrefix = 64;

    /// <summary>The largest first number (Roman numerals and letters past their range show as plain numbers).</summary>
    public const int MaxStart = 1_000_000;

    internal static string? StyleName(PageNumbering n) => n switch
    {
        PageNumbering.Decimal => "D",
        PageNumbering.UpperRoman => "R",
        PageNumbering.LowerRoman => "r",
        PageNumbering.UpperLetters => "A",
        PageNumbering.LowerLetters => "a",
        _ => null,
    };

    private static PageNumbering Numbering(string? style) => style switch
    {
        "D" => PageNumbering.Decimal,
        "R" => PageNumbering.UpperRoman,
        "r" => PageNumbering.LowerRoman,
        "A" => PageNumbering.UpperLetters,
        "a" => PageNumbering.LowerLetters,
        _ => PageNumbering.None,
    };

    /// <summary>The style page <paramref name="page"/> is labeled in, its own number as the start (plain numbers when the document has no labels).</summary>
    public static PageLabelStyle At(byte[] data, string? password, int page)
    {
        using var doc = PdfObj.Open(data, password, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var labels = PdfStructure.ReadLabels(doc);
        if (labels is null || page < 0 || page >= labels.Count) return new PageLabelStyle(PageNumbering.Decimal, "", Math.Max(1, page + 1));
        var l = labels[page].Label;
        return new PageLabelStyle(Numbering(l.Style), l.Prefix, Math.Clamp(l.Number, 1, MaxStart));
    }

    /// <summary>
    /// Labels <paramref name="pages"/> (0-based; a range, as "1-4") in <paramref name="style"/>, numbered in page order from
    /// its start; the other pages keep theirs (a page after the range goes on as it was, not from the range's last number).
    /// </summary>
    /// <exception cref="ArgumentException">The pages or the style aren't usable (no page, a page out of range, a prefix
    /// too long, a start number below 1 or above <see cref="MaxStart"/>).</exception>
    /// <param name="restartAfter">The pages after the last of <paramref name="pages"/> are numbered 1, 2, 3… (front matter
    /// in i, ii, then the body from 1).</param>
    public static byte[] Write(byte[] data, string? password, IReadOnlyCollection<int> pages, PageLabelStyle style, bool restartAfter = false)
    {
        Check(style);
        var ordered = pages.Distinct().Order().ToArray();
        return PageEditor.EditLabels(data, password, (labels, count) =>
        {
            if (ordered.Length == 0 || ordered[0] < 0 || ordered[^1] >= count) throw new ArgumentException(PdfStrings.Page_NoneSelected, nameof(pages));
            for (var k = 0; k < ordered.Length; k++)
                labels[ordered[k]] = new PdfStructure.PageLabel(StyleName(style.Numbering), style.Prefix, (int)Math.Min(int.MaxValue, (long)style.Start + k));
            if (restartAfter)
                for (var i = ordered[^1] + 1; i < count; i++) labels[i] = new PdfStructure.PageLabel("D", "", i - ordered[^1]);
            return labels;
        });
    }

    /// <summary>Removes every label: the pages show their plain numbers.</summary>
    public static byte[] Remove(byte[] data, string? password) => PageEditor.EditLabels(data, password, (_, _) => null);

    /// <exception cref="ArgumentException">A prefix too long or with control characters, or a start number out of range.</exception>
    public static void Check(PageLabelStyle style)
    {
        if (style.Prefix.Length > MaxPrefix || style.Prefix.Any(char.IsControl))
            throw new ArgumentException(Loc.Format(PdfStrings.Page_LabelPrefix, MaxPrefix), nameof(style));
        if (style.Start < 1 || style.Start > MaxStart)
            throw new ArgumentException(Loc.Format(PdfStrings.Page_LabelStart, MaxStart), nameof(style));
        if (style.Numbering == PageNumbering.None && style.Prefix.Length == 0)
            throw new ArgumentException(PdfStrings.Page_LabelEmpty, nameof(style));
    }
}
