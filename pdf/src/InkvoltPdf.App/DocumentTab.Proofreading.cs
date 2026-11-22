using System.Windows;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Proofreading marks (roadmap 4.17): Insert Text at a place in the text (after the selection, the caret, where text was
/// clicked, or where the page's menu was opened), and Replace Text over the selected words. Core draws and groups them
/// (<see cref="Annotations.AddInsertText"/>, <see cref="Annotations.AddReplaceText"/>); each is one undo step.
/// </summary>
public partial class DocumentTab
{
    public bool CanInsertText => Session.IsPdf && !IsOrganizing && Viewer.InsertionPoint is not null;

    public bool CanReplaceText => CanMarkup && Viewer.SelectionIsOnOnePage;

    private void InitProofreading()
    {
        CtxInsertText.Click += (_, _) =>
        {
            if (Viewer.ContextCaret is { } at) _ = InsertTextAt(at, null);
        };
        Viewer.ContextMenuOpening += (_, _) =>
        {
            CtxInsertText.Visibility = Session.IsPdf && !IsOrganizing && Viewer.ContextCaret is not null ? Visibility.Visible : Visibility.Collapsed;
            // Replace Text with the other markup (CanMarkup), the separator below whatever of them shows.
            CtxReplaceText.Visibility = CanMarkup ? Visibility.Visible : Visibility.Collapsed;
            CtxMarkupSeparator.Visibility = CtxStrikeOut.Visibility == Visibility.Visible || CtxReplaceText.Visibility == Visibility.Visible
                || CtxInsertText.Visibility == Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        };
    }

    /// <summary>The Comments pane's items as listed (title and text), for the developer script.</summary>
    internal string DevCommentList() =>
        $"{_commentItems.Count} items" + string.Concat(_commentItems.Select(c => $" | {c.Title}: '{c.Contents.Replace('\n', ' ')}'"));

    /// <summary>Insert Text at the viewer's insertion point (<see cref="PageViewer.InsertionPoint"/>).</summary>
    public async Task<bool> InsertText(string? text = null)
    {
        if (Viewer.InsertionPoint is not { } at)
        {
            Notify(Strings.Review_InsertNoCaret);
            return false;
        }
        return await InsertTextAt(at, text);
    }

    /// <summary>Asks for the text (unless given) and puts an Insert Text mark at <paramref name="at"/>.</summary>
    public async Task<bool> InsertTextAt(TextPos at, string? text)
    {
        if (!Session.IsPdf || IsOrganizing || Viewer.Engine is not { } engine || at.Page < 0 || at.Page >= Viewer.PageCount) return false;
        RectD? box;
        try
        {
            box = await Task.Run(() => Annotations.CaretAt(engine.GetText(at.Page), at.Caret));
        }
        catch (Exception ex) when (ex is ObjectDisposedException or MuPDFCore.MuPDFException or PageRefusedException)
        {
            Notify(Strings.Review_ChangedSelectAgain);
            return false;
        }
        if (!ReferenceEquals(engine, Viewer.Engine)) return false;
        if (box is not { } caret)
        {
            Notify(Strings.Review_InsertNoCaret);
            return false;
        }
        if (text is null)
        {
            if (Window.GetWindow(this) is not { } owner) return false;
            var dlg = new FormDialog(owner, Strings.Review_InsertTextTitle, Strings.Common_Add);
            var input = NoteBox(dlg, "");
            input.MinHeight = 70;
            dlg.AddNote(Loc.Format(Strings.Review_InsertTextNote, PageLabel(at.Page), Author));
            dlg.Validate(() => input.Text.Trim().Length == 0 ? Strings.Review_ProofTextEmpty : null);
            if (!dlg.ShowModal()) return false;
            text = input.Text;
        }
        var (author, words) = (Author, text);
        var ok = await RunEdit(Strings.Review_InsertTextTitle, (d, pw) => Annotations.AddInsertText(d, pw, at.Page, caret, words, author), contentOnly: true);
        if (ok) Viewer.ClearSelection();
        return ok;
    }

    /// <summary>Strikes out the selected words (one page) and puts a caret after them with the text that replaces them.</summary>
    public async Task<bool> ReplaceSelection(string? text = null)
    {
        if (!CanMarkup) return false;
        if (!Viewer.SelectionIsOnOnePage)
        {
            Notify(Strings.Review_ReplaceOnePage);
            return false;
        }
        var selected = AiProtocol.Shorten(AiText.Clean(Viewer.GetSelectedText()).Replace('\n', ' '), 80);
        if (await SelectionLineRects(Strings.Review_ReplaceTextTitle) is not { } parts) return false;
        if (parts.Count != 1)
        {
            Notify(parts.Count == 0 ? Strings.Review_NoTextToMark : Strings.Review_ReplaceOnePage);
            return false;
        }
        var (page, rects) = parts[0];
        if (text is null)
        {
            if (Window.GetWindow(this) is not { } owner) return false;
            var dlg = new FormDialog(owner, Strings.Review_ReplaceTextTitle, Strings.Common_Add);
            dlg.AddNote(Loc.Format(Strings.Review_ReplaceTextNote, selected, PageLabel(page), Author));
            var input = NoteBox(dlg, "");
            input.MinHeight = 70;
            dlg.Validate(() => input.Text.Trim().Length == 0 ? Strings.Review_ProofTextEmpty : null);
            if (!dlg.ShowModal()) return false;
            text = input.Text;
        }
        var (author, words) = (Author, text);
        var ok = await RunEdit(Strings.Review_ReplaceTextTitle, (d, pw) => Annotations.AddReplaceText(d, pw, page, rects, words, author), contentOnly: true);
        if (ok) Viewer.ClearSelection();
        return ok;
    }
}
