namespace InkvoltPrint.Core.Printing;

/// <summary>Parses print-dialog page ranges such as "1-3, 5" or "4-" into sorted, distinct 1-based page numbers.</summary>
public static class PageRange
{
    private const string Hint = "Use page numbers like 1-3, 5";

    /// <summary>Empty text means all pages.</summary>
    public static bool TryParse(string? text, int pageCount, out IReadOnlyList<int> pages, out string? error)
    {
        pages = [];
        error = null;
        if (string.IsNullOrWhiteSpace(text))
        {
            pages = Enumerable.Range(1, pageCount).ToList();
            return true;
        }

        var set = new SortedSet<int>();
        foreach (var raw in text.Replace('–', '-').Replace('—', '-').Split([',', ';'], StringSplitOptions.RemoveEmptyEntries))
        {
            var part = raw.Trim();
            if (part.Length == 0) continue;
            var dash = part.IndexOf('-');
            int from, to;
            if (dash < 0)
            {
                if (!int.TryParse(part, out from)) return Fail(Hint, out error);
                to = from;
            }
            else
            {
                var left = part[..dash].Trim();
                var right = part[(dash + 1)..].Trim();
                if (right.Contains('-')) return Fail(Hint, out error);
                if (left.Length == 0) from = 1;
                else if (!int.TryParse(left, out from)) return Fail(Hint, out error);
                if (right.Length == 0) to = pageCount;
                else if (!int.TryParse(right, out to)) return Fail(Hint, out error);
            }
            if (from > to) (from, to) = (to, from);
            if (from < 1) return Fail("Pages start at 1", out error);
            if (to > pageCount) return Fail($"This document has {pageCount} page{(pageCount == 1 ? "" : "s")}", out error);
            for (var p = from; p <= to; p++) set.Add(p);
        }
        if (set.Count == 0) return Fail(Hint, out error);
        pages = set.ToList();
        return true;
    }

    private static bool Fail(string message, out string? error)
    {
        error = message;
        return false;
    }
}
