using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Find &amp; Replace (Edit › Replace…, Ctrl+H; roadmap 4.2): <see cref="ReplaceDialog"/> finds and lists the matches,
/// Core's <see cref="TextReplace"/> replaces them through the paragraph editing of Edit Text &amp; Images, as one edit
/// (one undo step; a signed file gets it appended). What couldn't be replaced as asked is listed afterwards, never dropped.
/// </summary>
public partial class DocumentTab
{
    /// <summary>The last Find &amp; Replace's text and options, offered again next time.</summary>
    internal ReplaceQuery LastReplaceQuery { get; set; } = new("");

    internal string LastReplaceWith { get; set; } = "";

    /// <summary>What the last Replace or Replace All did (the dev script reads it).</summary>
    internal ReplaceResult? LastReplace { get; private set; }

    /// <summary>Edit › Replace…: the dialog, then Replace All for the matches left ticked.</summary>
    public async Task ShowReplaceAsync()
    {
        if (!Session.IsPdf || Window.GetWindow(this) is not { } owner) return;
        if (IsOrganizing) SetOrganizing(false);
        Viewer.CommitEditor();
        // A paragraph just committed is still being written: find in the document as it will be.
        for (var i = 0; IsBusy && i < 200; i++) await Task.Delay(50);
        // The selected words (a phrase on one line) are what people usually mean to replace.
        if (Viewer.HasSelection && Viewer.GetSelectedText().Trim() is { Length: > 0 and <= 200 } selected && !selected.Contains('\n'))
            LastReplaceQuery = LastReplaceQuery with { Find = selected };
        if (ReplaceDialog.Show(owner, this) is not var (matches, with)) return;
        await ReplaceMatches(matches, with, all: true);
    }

    /// <summary>The matches of <paramref name="query"/> in the document as it is now, off the UI thread.</summary>
    internal Task<ReplaceFound> FindForReplace(ReplaceQuery query, IProgress<int>? progress, CancellationToken cancel)
    {
        var (data, pw) = (Session.Data, Session.Password);
        return Task.Run(() => TextReplace.Find(data, pw, query, progress, cancel), cancel);
    }

    /// <summary>
    /// Replaces <paramref name="matches"/> with <paramref name="with"/> as one edit; then says how it went: a toast when every
    /// one was made as asked, else the list of what was done instead. False when nothing was committed.
    /// </summary>
    internal async Task<bool> ReplaceMatches(IReadOnlyList<ReplaceMatch> matches, string with, bool all)
    {
        if (matches.Count == 0) return false;
        ReplaceResult? result = null;
        var outcome = await TryEdit(all ? Strings.Replace_All : Strings.Replace_Replace, (d, pw) =>
        {
            var r = TextReplace.Replace(d, pw, matches, with);
            result = r;
            return r.Data;
        });
        LastReplace = result;
        if (outcome == EditOutcome.Busy) Notify(Strings.EditContent_StillApplying, error: true);
        if (outcome is not (EditOutcome.Done or EditOutcome.NoChange) || result is null) return false;
        if (result.Notes.Count > 0) ShowReplaceNotes(result);
        else Notify(Loc.Plural(result.Replaced, Strings.Replace_Done_One, Strings.Replace_Done_Many), Strings.Common_Undo, () =>
        {
            if (!IsBusy && Session.CanUndo) Undo();
        });
        return outcome == EditOutcome.Done;
    }

    /// <summary>Each replacement not made as asked, and what was done instead.</summary>
    private void ShowReplaceNotes(ReplaceResult result)
    {
        if (Window.GetWindow(this) is not { } owner) return;
        var dlg = new FormDialog(owner, Strings.Replace_NotesTitle, Strings.Common_Close, 620);
        dlg.HideCancel();
        dlg.AddNote(Loc.Format(Strings.Replace_NotesIntro, result.Replaced, result.Left));
        var list = new System.Windows.Controls.TextBox
        {
            Text = string.Join("\n\n", result.Notes.Select(NoteLine)),
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            MaxHeight = 360,
            VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto,
        };
        System.Windows.Automation.AutomationProperties.SetName(list, Strings.Replace_NotesTitle);
        dlg.Add(null, list);
        dlg.ShowModal();
    }

    /// <summary>"Page 2 · “…the invoice total…”: what happened."</summary>
    internal string NoteLine(ReplaceNote n)
    {
        static string Chars(IReadOnlyList<string> chars) =>
            string.Join(Strings.EditContent_ListSeparator, chars.Take(10).Select(c => c == " " ? Strings.EditContent_Space : Loc.Format(Strings.EditContent_QuotedChar, c)));
        var m = n.Match;
        var what = n.Kind switch
        {
            ReplaceNoteKind.StandIn => Loc.Format(Strings.Replace_NoteStandIn, Chars(n.Chars), string.Join(Strings.Viewer_ListAnd, n.Fonts)),
            ReplaceNoteKind.Wider => Loc.Format(Strings.Replace_NoteWider, n.Wider),
            ReplaceNoteKind.Missing => Loc.Format(Strings.Replace_NoteMissing, Chars(n.Chars)),
            ReplaceNoteKind.WouldOverlap => Strings.Replace_NoteOverlap,
            ReplaceNoteKind.CantEdit => Loc.Format(Strings.Replace_NoteCantEdit, n.Why ?? ""),
            _ => Strings.Replace_NoteChanged,
        };
        if (n.Count > 1) what += Loc.Format(Strings.Replace_NoteCount, n.Count);
        var where = Loc.Format(Strings.Viewer_PageN, PageLabel(m.PageIndex));
        return Loc.Format(Strings.Replace_NoteLine, where, Loc.Format(Strings.EditContent_QuotedChar, Shorten(m.Before + m.Found + m.After)), what);
    }

    /// <summary>Text from the page, shortened to fit a line.</summary>
    internal static string Shorten(string s) => s.Length <= 90 ? s : s[..89] + "…";
}
