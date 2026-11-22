namespace InkvoltPdf.Core;

/// <summary>A heading found on a page: its text, level (1-6), page and where its first line is (points from the page's top).</summary>
public sealed record FoundHeading(string Title, int Level, int PageIndex, double Top);

/// <summary>
/// Bookmarks from headings: the headings <see cref="DocLayout"/> finds (text set larger than the body, as Export to Word
/// and Make Accessible find them; running headers left out), nested by level, written through <see cref="Bookmarks"/>
/// in place of the document's bookmarks or after them.
/// </summary>
public static class HeadingBookmarks
{
    /// <summary>The most headings made into bookmarks (a document set all in large type would make a heading of every line).</summary>
    public const int MaxHeadings = 5000;

    /// <summary>The longest title kept (a longer one is shortened with "…").</summary>
    public const int MaxTitle = 200;

    /// <summary>The document's headings in reading order. A page that can't be read has none.</summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    public static IReadOnlyList<FoundHeading> Find(PdfEngine engine, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        var pages = new List<ExportPage>(engine.PageCount);
        for (var p = 0; p < engine.PageCount; p++)
        {
            cancel.ThrowIfCancellationRequested();
            progress?.Report((p, engine.PageCount));
            try
            {
                pages.Add(engine.GetExportPage(p, images: false, cancel, boxesOnly: true));
            }
            catch (Exception ex) when (ex is MuPDFCore.MuPDFException or InvalidOperationException or ArgumentException) // a refused page too
            {
                var g = engine.GetPage(p);
                pages.Add(new ExportPage(g.Width, g.Height, [], [], []));
            }
        }
        progress?.Report((engine.PageCount, engine.PageCount));
        return Headings(DocLayout.AnalyzeForTags(pages).Layout);
    }

    /// <summary>The headings of a laid-out document (<see cref="DocLayout.AnalyzeForTags"/>, whose paragraphs say where they are on the page).</summary>
    internal static List<FoundHeading> Headings(DocLayoutResult layout)
    {
        var found = new List<FoundHeading>();
        for (var p = 0; p < layout.Pages.Count && found.Count < MaxHeadings; p++)
            foreach (var paragraph in layout.Pages[p].Blocks.OfType<DocParagraph>())
            {
                if (paragraph.HeadingLevel <= 0 || Title(paragraph.Text) is not { Length: > 0 } title) continue;
                var top = paragraph.Sources.Count > 0 ? paragraph.Sources.Min(s => s.Y) : paragraph.Box.Y;
                found.Add(new FoundHeading(title, Math.Clamp(paragraph.HeadingLevel, 1, 6), p, double.IsFinite(top) ? Math.Max(0, top) : 0));
                if (found.Count >= MaxHeadings) break;
            }
        return found;
    }

    /// <summary>Whitespace (line breaks, tabs, runs of spaces) as one space, control characters left out, at most <see cref="MaxTitle"/> characters.</summary>
    internal static string Title(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(w => new string([.. w.Where(c => !char.IsControl(c) && c != DocLayout.PageField)]))
            .Where(w => w.Length > 0);
        var title = string.Join(' ', words);
        return title.Length > MaxTitle ? title[..(MaxTitle - 1)].TrimEnd() + "…" : title;
    }

    /// <summary>
    /// The headings as a bookmark tree: each under the nearest heading before it of a higher level (a level skipped, as a
    /// 1 followed by a 3, nests one step), the first level shown open. Only headings of level <paramref name="deepest"/> or
    /// higher are kept.
    /// </summary>
    public static IReadOnlyList<Bookmark> Tree(IReadOnlyList<FoundHeading> headings, int deepest = 6)
    {
        var roots = new List<Node>();
        var open = new List<Node>(); // the path from a root to the last heading placed
        foreach (var h in headings.Where(h => h.Level <= deepest))
        {
            while (open.Count > 0 && open[^1].Level >= h.Level) open.RemoveAt(open.Count - 1);
            var node = new Node(h);
            (open.Count == 0 ? roots : open[^1].Children).Add(node);
            open.Add(node);
        }
        return [.. roots.Select(n => n.ToBookmark(open: true))];
    }

    /// <summary>
    /// Writes the headings' bookmarks: in place of the document's bookmarks (<paramref name="replace"/>), or after them.
    /// A signed document gets them as an appended change, as every bookmark edit.
    /// </summary>
    public static byte[] Write(byte[] data, string? password, IReadOnlyList<FoundHeading> headings, bool replace, int deepest = 6)
    {
        var made = Tree(headings, deepest);
        return Bookmarks.SetOutline(data, password, replace ? made : [.. Bookmarks.Read(data, password), .. made]);
    }

    private sealed class Node(FoundHeading heading)
    {
        public int Level => heading.Level;
        public List<Node> Children { get; } = [];

        public Bookmark ToBookmark(bool open) => new(heading.Title, heading.PageIndex, heading.Top)
        {
            Children = [.. Children.Select(c => c.ToBookmark(open: false))],
            Open = open && Children.Count > 0,
        };
    }
}
