using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>One search hit to mark: its page and its box on each line it runs over (page space).</summary>
public sealed record HitToMark(int Page, IReadOnlyList<RectD> Rects);

/// <summary>What <see cref="SearchMarks.Apply"/> did: the document, how many hits it marked and how many were marked already.</summary>
public sealed record SearchMarksResult(byte[] Data, int Marked, int AlreadyMarked);

/// <summary>
/// Mark All Matches (roadmap 4.18): every hit of a search highlighted, underlined or struck out as a comment of its own, as
/// Highlight Text marks a selection (<see cref="Annotations.AddTextMarkupIn"/>), all in one change of the document. A hit
/// already under a mark of the same kind is left alone, so running it twice adds nothing.
/// </summary>
public static class SearchMarks
{
    /// <summary>The most hits marked at once (a search for "e" finds tens of thousands; the reader would crawl).</summary>
    public const int MaxMarks = 5000;

    /// <summary>The usual colour of each kind (as Highlight, Underline and Strike Out Text use).</summary>
    public static AnnotColor ColorOf(TextMarkupKind kind) => kind switch
    {
        TextMarkupKind.Underline => new AnnotColor(0.1, 0.55, 0.2),
        TextMarkupKind.StrikeOut => AnnotColor.Red,
        TextMarkupKind.Squiggly => new AnnotColor(0.1, 0.45, 0.85),
        _ => AnnotColor.Yellow,
    };

    /// <summary>
    /// The hits marked (at most <see cref="MaxMarks"/>; a hit on a page the document doesn't have, or without a box, is
    /// passed over) as <paramref name="kind"/>, each a comment by <paramref name="author"/>.
    /// </summary>
    public static SearchMarksResult Apply(byte[] data, string? password, IReadOnlyList<HitToMark> hits, TextMarkupKind kind, string author)
    {
        using var doc = Annotations.OpenForEdit(data, password);
        var subtype = "/" + kind;
        var existing = new Dictionary<int, List<RectD>>();
        int marked = 0, already = 0;
        foreach (var hit in hits)
        {
            if (marked >= MaxMarks) break;
            if (hit.Page < 0 || hit.Page >= doc.PageCount) continue;
            var rects = hit.Rects.Where(r => !r.IsEmpty && double.IsFinite(r.X) && double.IsFinite(r.Y) && double.IsFinite(r.Width) && double.IsFinite(r.Height)).ToList();
            if (rects.Count == 0) continue;
            if (!existing.TryGetValue(hit.Page, out var quads)) existing[hit.Page] = quads = MarkedLines(doc.Pages[hit.Page], subtype);
            if (rects.All(r => quads.Any(q => Covers(q, r))))
            {
                already++;
                continue;
            }
            Annotations.AddTextMarkupIn(doc, hit.Page, kind, rects, ColorOf(kind), null, author);
            quads.AddRange(rects); // the same place twice in the list is marked once
            marked++;
        }
        return new SearchMarksResult(marked == 0 ? data : PdfObj.Save(doc), marked, already);
    }

    /// <summary>The lines the page's marks of this kind already cover.</summary>
    private static List<RectD> MarkedLines(PdfSharp.Pdf.PdfPage page, string subtype)
    {
        var lines = new List<RectD>();
        if (PdfObj.Array(page.Elements["/Annots"]) is not { } annots) return lines;
        foreach (var item in annots.Elements.Take(10_000))
            if (PdfObj.Dict(item) is { } a && PdfObj.NameOf(a, "/Subtype") == subtype)
                lines.AddRange(Annotations.QuadRectsOf(page, a));
        return lines;
    }

    /// <summary>Most of <paramref name="hit"/> lies under <paramref name="mark"/>.</summary>
    private static bool Covers(RectD mark, RectD hit)
    {
        var w = Math.Min(mark.Right, hit.Right) - Math.Max(mark.X, hit.X);
        var h = Math.Min(mark.Bottom, hit.Bottom) - Math.Max(mark.Y, hit.Y);
        return w > 0 && h > 0 && w * h >= 0.8 * hit.Width * hit.Height;
    }
}
