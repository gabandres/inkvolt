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

    public async Task MarkAllMatches(TextMarkupKind kind)
    {
        if (!Session.IsPdf) return;
        if (_searched is not { } search || !_searchComplete || _results.Count == 0)
        {
            // Nothing searched yet (or still searching, or no hits): the Search pane, to search for what to mark.
            ShowSearchPane();
            Notify(_searched is not null && !_searchComplete ? Strings.Marks_StillSearching
                : _searched is not null ? Strings.Marks_NoMatches : Strings.Marks_SearchFirst);
            return;
        }
        var hits = _results.Select(h => new HitToMark(h.Page, h.Rects)).ToList();
        var author = Author;
        SearchMarksResult? result = null;
        var label = kind switch
        {
            TextMarkupKind.Underline => Loc.Plural(hits.Count, Strings.Marks_Underline_One, Strings.Marks_Underline_Many),
            TextMarkupKind.StrikeOut => Loc.Plural(hits.Count, Strings.Marks_StrikeOut_One, Strings.Marks_StrikeOut_Many),
            _ => Loc.Plural(hits.Count, Strings.Marks_Highlight_One, Strings.Marks_Highlight_Many),
        };
        var outcome = await TryEdit(label, (d, pw) =>
        {
            var r = SearchMarks.Apply(d, pw, hits, kind, author);
            result = r;
            return r.Data;
        }, contentOnly: true);
        if (result is not { } done) return;
        if (outcome == EditOutcome.NoChange) Notify(Strings.Marks_AllMarkedAlready);
        else if (outcome == EditOutcome.Done && done.Marked < hits.Count - done.AlreadyMarked)
            ShowNotice(Loc.Format(Strings.Marks_Limit, done.Marked, hits.Count), undo: true);
        if (outcome == EditOutcome.Done)
        {
            // The edit cleared the hits: search again, staying where the view is.
            _jumpWhenFound = false;
            _ = RunSearch(search.Query, search.Case, search.Words, search.Accents);
        }
    }
}
