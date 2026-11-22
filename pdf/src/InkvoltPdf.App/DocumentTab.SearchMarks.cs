using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Mark All Matches (roadmap 4.18): every hit of the search just made (Find or the Search pane) highlighted, underlined
/// or struck out as comments, one undo step (<see cref="SearchMarks"/>); then the same search runs again on the marked
/// document, so its hits stay listed for another kind of mark.
/// </summary>
public partial class DocumentTab
{
    /// <summary>The search in <see cref="_results"/> has looked through every page.</summary>
    private bool _searchComplete;

    /// <summary>The search in <see cref="_results"/> stopped before its end (it failed, or was stopped without another taking its place).</summary>
    private bool _searchFailed;

    public async Task MarkAllMatches(TextMarkupKind kind)
    {
        if (!Session.IsPdf) return;
        if (_searched is not { } search || !_searchComplete || _searchFailed || _results.Count == 0)
        {
            // Nothing searched yet (or still searching, stopped, or no hits): the Search pane, to search for what to mark.
            ShowSearchPane();
            Notify(_searched is null ? Strings.Marks_SearchFirst
                : _searchFailed ? Strings.Marks_SearchStopped
                : !_searchComplete ? Strings.Marks_StillSearching : Strings.Marks_NoMatches);
            return;
        }
        var hits = _results.Select(h => new HitToMark(h.Page, h.Rects)).ToList();
        var author = Author;
        var (data, password) = (Session.Data, Session.Password);
        SearchMarksCount planned;
        try
        {
            planned = await Task.Run(() => SearchMarks.Count(data, password, hits, kind));
        }
        catch (Exception ex) when (ex is InvalidOperationException or PdfSharp.PdfSharpException or ArgumentException)
        {
            Log.Write($"Mark All Matches couldn't read the document: {ex.GetType().Name}: {ex.Message}");
            Notify(Strings.Marks_CouldntMark, error: true);
            return;
        }
        if (_disposed || !ReferenceEquals(data, Session.Data)) return; // changed meanwhile: the hits are gone with it
        if (planned.Marked == 0)
        {
            Notify(planned.AlreadyMarked > 0 ? Strings.Marks_AllMarkedAlready : Strings.Marks_NoMatches);
            return;
        }
        // The undo step is named after the marks made, not the hits found.
        var label = kind switch
        {
            TextMarkupKind.Underline => Loc.Plural(planned.Marked, Strings.Marks_Underline_One, Strings.Marks_Underline_Many),
            TextMarkupKind.StrikeOut => Loc.Plural(planned.Marked, Strings.Marks_StrikeOut_One, Strings.Marks_StrikeOut_Many),
            _ => Loc.Plural(planned.Marked, Strings.Marks_Highlight_One, Strings.Marks_Highlight_Many),
        };
        SearchMarksResult? result = null;
        var outcome = await TryEdit(label, (d, pw) =>
        {
            var r = SearchMarks.Apply(d, pw, hits, kind, author);
            result = r;
            return r.Data;
        }, contentOnly: true);
        if (result is not { Count: var done }) return;
        if (outcome == EditOutcome.NoChange) Notify(Strings.Marks_AllMarkedAlready);
        else if (outcome == EditOutcome.Done && (done.Limited > 0 || done.PagesNotAllRead > 0))
        {
            // Hits past the limit, and pages with more marks than were read (a hit under the rest is marked again): said.
            var notes = new List<string>();
            if (done.Limited > 0) notes.Add(Loc.Format(Strings.Marks_Limit, done.Marked, done.Marked + done.Limited));
            if (done.PagesNotAllRead > 0) notes.Add(Loc.Plural(done.PagesNotAllRead, Strings.Marks_NotAllRead_One, Strings.Marks_NotAllRead_Many));
            ShowNotice(string.Join(" ", notes), undo: true);
        }
        if (outcome == EditOutcome.Done)
        {
            // The edit cleared the hits: search again, staying where the view is.
            _jumpWhenFound = false;
            _ = RunSearch(search.Query, search.Case, search.Words, search.Accents);
        }
    }
}
