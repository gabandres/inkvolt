namespace InkvoltPdf.Core;

public enum PageSubset { All, Even, Odd }

/// <summary>
/// Parses user page ranges such as "1-3, 5, 8-" or "2-end" (1-based) into sorted 0-based page indices. Bounded for any
/// text: the ranges are kept as ranges and merged once, so "-,-,-,…" (each the whole document) costs its length plus the
/// page count, not the two multiplied.
/// </summary>
public static class PageRange
{
    public static bool TryParse(string? text, int pageCount, out int[] pages, out string? error)
    {
        pages = [];
        error = null;
        if (string.IsNullOrWhiteSpace(text))
        {
            error = PdfStrings.Page_RangeEnter;
            return false;
        }

        var ranges = new List<(int From, int To)>();
        foreach (var raw in text.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var dash = raw.IndexOfAny(['-', '–', '—']); // en and em dashes come in from copied text and autocorrect
            int from, to;
            if (dash < 0)
            {
                if (!TryPage(raw, pageCount, out from)) return Fail(raw, out error);
                to = from;
            }
            else
            {
                var a = raw[..dash].Trim();
                var b = raw[(dash + 1)..].Trim();
                from = 1;
                to = pageCount;
                if (a.Length > 0 && !TryPage(a, pageCount, out from)) return Fail(raw, out error);
                if (b.Length > 0 && !TryPage(b, pageCount, out to)) return Fail(raw, out error);
            }

            if (from < 1 || to > pageCount || from > to)
            {
                error = Loc.Format(PdfStrings.Page_RangeOutside, raw, pageCount);
                return false;
            }
            ranges.Add((from - 1, to - 1));
        }

        ranges.Sort();
        var list = new List<int>();
        var next = 0; // the first page not yet listed: each page is listed once, a range inside one already listed adds nothing
        foreach (var (from, to) in ranges)
        {
            for (var p = Math.Max(from, next); p <= to; p++) list.Add(p);
            next = Math.Max(next, to + 1);
        }
        pages = [.. list];
        return pages.Length > 0 || Fail(text, out error);
    }

    public static int[] Apply(IEnumerable<int> pages, PageSubset subset) => subset switch
    {
        // "Even" and "odd" refer to 1-based page numbers, as the user sees them.
        PageSubset.Even => [.. pages.Where(p => (p + 1) % 2 == 0)],
        PageSubset.Odd => [.. pages.Where(p => (p + 1) % 2 == 1)],
        _ => [.. pages],
    };

    /// <summary>Formats 0-based indices back to a compact 1-based range string ("1-3, 5").</summary>
    public static string Format(IEnumerable<int> pages)
    {
        var sorted = pages.Distinct().Order().ToArray();
        var parts = new List<string>();
        for (var i = 0; i < sorted.Length;)
        {
            var j = i;
            while (j + 1 < sorted.Length && sorted[j + 1] == sorted[j] + 1) j++;
            parts.Add(i == j ? $"{sorted[i] + 1}" : $"{sorted[i] + 1}-{sorted[j] + 1}");
            i = j + 1;
        }
        return string.Join(", ", parts);
    }

    private static bool TryPage(string s, int pageCount, out int page)
    {
        if (s.Equals("end", StringComparison.OrdinalIgnoreCase) || s.Equals("last", StringComparison.OrdinalIgnoreCase))
        {
            page = pageCount;
            return true;
        }
        return int.TryParse(s, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out page);
    }

    private static bool Fail(string raw, out string? error)
    {
        error = Loc.Format(PdfStrings.Page_RangeInvalid, raw);
        return false;
    }
}
