namespace InkvoltPdf.Core;

/// <summary>What looks different on a page of the new document, besides its words: boxes in the page's points.</summary>
public sealed record CompareVisualArea(int NewPage, IReadOnlyList<RectD> Boxes)
{
    /// <summary>Areas beyond the page's edge (the old page was larger), which only a note can mention.</summary>
    public int OffPage { get; init; }
}

/// <summary>
/// A compare report: a copy of the new document with the changes as comments, so it can be saved, shared and read in
/// any viewer. Inserted words get a green highlight, changed words an amber one whose comment quotes the old wording,
/// moved words a violet one, reformatted words a blue one saying what changed, areas that look different a light one;
/// a note marks where words were removed (quoting them) or moved from, an inserted page and the place of a removed page;
/// a note on the first page sums it all up. Signed files get the comments appended (signatures stay intact), protected files
/// keep their protection.
/// </summary>
public static class CompareReport
{
    public const string Author = "Inkvolt PDF Compare";

    public static readonly AnnotColor InsertedColor = new(0.45, 0.85, 0.4);
    public static readonly AnnotColor ChangedColor = new(1, 0.72, 0.2);
    public static readonly AnnotColor RemovedColor = new(0.9, 0.2, 0.2);
    public static readonly AnnotColor MovedColor = new(0.72, 0.58, 0.95);
    public static readonly AnnotColor FormattedColor = new(0.45, 0.78, 0.92);
    public static readonly AnnotColor VisualColor = new(0.72, 0.76, 1);

    private const int MaxQuote = 400;

    /// <param name="newPages">The new document's text, as compared (for where the changed words are).</param>
    /// <param name="oldName">The old document's name, for the comments.</param>
    /// <param name="summary">The first page's note.</param>
    /// <param name="visual">What looks different besides the words.</param>
    /// <exception cref="OwnerPasswordRequiredException">The new document needs its permissions password to be edited.</exception>
    public static byte[] Annotate(byte[] newData, string? password, CompareResult result, IReadOnlyList<PageText> newPages, string oldName, string summary,
        IReadOnlyList<CompareVisualArea>? visual = null)
    {
        using var doc = Annotations.OpenForEdit(newData, password);
        // Notes without a place in the text (the summary, removed and inserted pages, removals with no anchor) are
        // gathered into one note per page, in its top-left corner, so any number of them stays on the page.
        var margin = new SortedDictionary<int, List<(string Text, AnnotColor Color)>>();
        void MarginNote(int page, string text, AnnotColor color)
        {
            if (!margin.TryGetValue(page, out var notes)) margin[page] = notes = [];
            notes.Add((text, color));
        }

        if (doc.PageCount > 0) MarginNote(0, summary, AnnotColor.Yellow);
        foreach (var c in result.Changes)
        {
            var misread = c.MaybeMisread ? " This may be a misreading of the scan." : "";
            switch (c.Kind)
            {
                case ChangeKind.Inserted or ChangeKind.Changed:
                    foreach (var span in c.New)
                    {
                        if (span.Page >= doc.PageCount || span.Page >= newPages.Count) continue;
                        var rects = newPages[span.Page].GetRects(span.Start, span.End);
                        if (rects.Count == 0) continue;
                        Annotations.AddTextMarkupIn(doc, span.Page, TextMarkupKind.Highlight, rects,
                            c.Kind == ChangeKind.Inserted ? InsertedColor : ChangedColor,
                            (c.Kind == ChangeKind.Inserted ? $"Inserted (not in {oldName})" : $"Changed. {oldName} has: “{Quote(c.OldText)}”") + misread, Author);
                    }
                    break;
                case ChangeKind.Moved:
                {
                    var from = c.Old is [var was, ..] ? $" from page {was.Page + 1} of {oldName}" : "";
                    foreach (var span in c.New)
                    {
                        if (span.Page >= doc.PageCount || span.Page >= newPages.Count) continue;
                        var rects = newPages[span.Page].GetRects(span.Start, span.End);
                        if (rects.Count > 0) Annotations.AddTextMarkupIn(doc, span.Page, TextMarkupKind.Highlight, rects, MovedColor, $"Moved here{from}.", Author);
                    }
                    if (c.NewAnchor is { } a && a.Page < doc.PageCount && a.Page < newPages.Count && Spot(newPages[a.Page], a.Start) is { } spot && c.New is [var to, ..])
                        Annotations.AddNoteIn(doc, a.Page, spot.X, spot.Y, $"Moved to page {to.Page + 1}: “{Quote(c.OldText)}”", Author, MovedColor);
                    break;
                }
                case ChangeKind.Formatted:
                    foreach (var span in c.New)
                    {
                        if (span.Page >= doc.PageCount || span.Page >= newPages.Count) continue;
                        var rects = newPages[span.Page].GetRects(span.Start, span.End);
                        if (rects.Count > 0) Annotations.AddTextMarkupIn(doc, span.Page, TextMarkupKind.Highlight, rects, FormattedColor, $"Formatting: {c.Look?.Describe()}", Author);
                    }
                    break;
                case ChangeKind.Deleted:
                {
                    var text = $"Removed: “{Quote(c.OldText)}”{misread}";
                    if (c.NewAnchor is { } a && a.Page < doc.PageCount && a.Page < newPages.Count && Spot(newPages[a.Page], a.Start) is { } spot)
                        Annotations.AddNoteIn(doc, a.Page, spot.X, spot.Y, text, Author, RemovedColor);
                    else if (NearestNewPage(result, c.Row, doc.PageCount) is { } p)
                        MarginNote(p, text, RemovedColor);
                    break;
                }
                case ChangeKind.PageInserted when c.New is [var span, ..] && span.Page < doc.PageCount:
                    MarginNote(span.Page, $"Inserted page: {oldName} doesn't have it.", InsertedColor);
                    break;
                case ChangeKind.PageRemoved when c.Old is [var span, ..]:
                {
                    // On the next page the new document has, else its last one.
                    var next = result.Rows.Skip(c.Row + 1).FirstOrDefault(r => r.NewPage is not null)?.NewPage ?? doc.PageCount - 1;
                    if (next >= 0)
                        MarginNote(next, $"Removed page: page {span.Page + 1} of {oldName} was here" +
                                         (c.OldText.Length > 0 ? $": “{Quote(c.OldText)}”" : " (it has no text)."), RemovedColor);
                    break;
                }
            }
        }
        foreach (var area in visual ?? [])
        {
            if (area.NewPage >= doc.PageCount) continue;
            foreach (var box in area.Boxes)
                Annotations.AddTextMarkupIn(doc, area.NewPage, TextMarkupKind.Highlight, [box], VisualColor, $"Looks different in {oldName}.", Author);
            if (area.OffPage > 0)
                MarginNote(area.NewPage, $"{oldName}'s page is larger: {(area.OffPage == 1 ? "1 area" : $"{area.OffPage} areas")} beyond this page's edge {(area.OffPage == 1 ? "looks" : "look")} different.", VisualColor);
        }
        foreach (var (page, notes) in margin)
            Annotations.AddNoteIn(doc, page, 6, 6, string.Join("\n\n", notes.Select(n => n.Text)), Author, notes[0].Color);
        return PdfObj.Save(doc);
    }

    /// <summary>The new document's page for a change on a row: the row's, else the next one's, else the last before it (a page only the old document has has none).</summary>
    private static int? NearestNewPage(CompareResult result, int row, int pageCount)
    {
        for (var r = row; r < result.Rows.Count; r++)
            if (result.Rows[r].NewPage is { } p && p < pageCount) return p;
        for (var r = row - 1; r >= 0; r--)
            if (result.Rows[r].NewPage is { } p && p < pageCount) return p;
        return null;
    }

    /// <summary>Where a note for a position in the text goes: just above the character before it (or after it).</summary>
    private static (double X, double Y)? Spot(PageText text, int caret)
    {
        var rects = caret > 0 ? text.GetRects(caret - 1, caret) : text.GetRects(caret, Math.Min(text.Text.Length, caret + 1));
        if (rects.Count == 0) return null;
        var r = rects[0];
        return (Math.Max(0, (caret > 0 ? r.Right : r.X) - 10), Math.Max(0, r.Y - 20));
    }

    private static string Quote(string s) => s.Length <= MaxQuote ? s : s[..MaxQuote] + "…";
}
