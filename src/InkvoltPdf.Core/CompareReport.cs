namespace InkvoltPdf.Core;

/// <summary>
/// A compare report: a copy of the new document with the changes as comments, so it can be saved, shared and read in
/// any viewer. Inserted words get a green highlight, changed words an amber one whose comment quotes the old wording;
/// a note marks where words were removed (quoting them), an inserted page and the place of a removed page; a note on
/// the first page sums it all up. Signed files get the comments appended (signatures stay intact), protected files
/// keep their protection.
/// </summary>
public static class CompareReport
{
    public const string Author = "Inkvolt PDF Compare";

    public static readonly AnnotColor InsertedColor = new(0.45, 0.85, 0.4);
    public static readonly AnnotColor ChangedColor = new(1, 0.72, 0.2);
    public static readonly AnnotColor RemovedColor = new(0.9, 0.2, 0.2);

    private const int MaxQuote = 400;

    /// <param name="newPages">The new document's text, as compared (for where the changed words are).</param>
    /// <param name="oldName">The old document's name, for the comments.</param>
    /// <param name="summary">The first page's note.</param>
    /// <exception cref="OwnerPasswordRequiredException">The new document needs its permissions password to be edited.</exception>
    public static byte[] Annotate(byte[] newData, string? password, CompareResult result, IReadOnlyList<PageText> newPages, string oldName, string summary)
    {
        using var doc = Annotations.OpenForEdit(newData, password);
        var margin = new int[doc.PageCount]; // notes stacked down the top-left corner of each page
        void MarginNote(int page, string text, AnnotColor color)
        {
            Annotations.AddNoteIn(doc, page, 6, 6 + 24 * margin[page]++, text, Author, color);
        }

        if (doc.PageCount > 0) MarginNote(0, summary, AnnotColor.Yellow);
        foreach (var c in result.Changes)
        {
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
                            c.Kind == ChangeKind.Inserted ? $"Inserted (not in {oldName})" : $"Changed. {oldName} has: “{Quote(c.OldText)}”", Author);
                    }
                    break;
                case ChangeKind.Deleted:
                {
                    var text = $"Removed: “{Quote(c.OldText)}”";
                    if (c.NewAnchor is { } a && a.Page < doc.PageCount && a.Page < newPages.Count && Spot(newPages[a.Page], a.Start) is { } spot)
                        Annotations.AddNoteIn(doc, a.Page, spot.X, spot.Y, text, Author, RemovedColor);
                    else if (result.Rows[c.Row].NewPage is { } p && p < doc.PageCount)
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
        return PdfObj.Save(doc);
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
