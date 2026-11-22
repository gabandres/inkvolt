using System.IO;
using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>Where Save AI Answer puts the answers.</summary>
public enum AiSaveTarget { Word, Pdf, Comment }

/// <summary>
/// Save an AI answer (roadmap 4.20): an answer (its card's Save button, or the last one) or the whole conversation (the
/// pane's Save, or the menu) to a Word document or a PDF, or one answer into the document as a comment on the page it
/// cites (one undo step). Core writes them (<see cref="AiAnswerExport"/>); the conversation is the session's
/// (<see cref="DocumentSession.AiConversation"/>), kept while the document is open.
/// </summary>
public partial class DocumentTab
{
    public bool HasAiAnswers => Session.AiConversation.Exchanges.Count > 0;

    /// <summary>The last answer, for Save AI Answer from the menu.</summary>
    public AiExchange? LastAiAnswer => Session.AiConversation.Exchanges is [.., var last] ? last : null;

    /// <summary>
    /// Saves <paramref name="chosen"/> (null: the whole conversation), asking where unless <paramref name="target"/> (and,
    /// for a file, <paramref name="path"/>) are given. Returns whether it was saved.
    /// </summary>
    public async Task<bool> SaveAiAnswers(IReadOnlyList<AiExchange>? chosen, AiSaveTarget? target = null, string? path = null)
    {
        if (_disposed || Window.GetWindow(this) is not { } owner) return false;
        var list = chosen ?? Session.AiConversation.Exchanges.ToList();
        if (list.Count == 0)
        {
            Notify(Strings.TabAi_NothingToSave);
            return false;
        }
        var one = chosen is not null && list.Count == 1; // named by what was asked: the conversation, even of one answer, is a conversation
        var canComment = one && Session.IsPdf && !IsOrganizing && Viewer.PageCount > 0;
        var commentPage = canComment ? AiAnswerExport.CommentPage(list[0], Viewer.PageCount, Viewer.CurrentPage) : 0;
        if (target is null)
        {
            var dlg = new FormDialog(owner, one ? Strings.TabAi_SaveAnswerTitle : Strings.TabAi_SaveConversationTitle, Strings.Common_Save, 460);
            dlg.AddNote(one ? Loc.Format(Strings.TabAi_SaveAnswerNote, AiProtocol.Shorten(list[0].Shown.Replace('\n', ' '), 80))
                : Loc.Plural(list.Count, Strings.TabAi_SaveConversationNote_One, Strings.TabAi_SaveConversationNote_Many));
            List<(AiSaveTarget Target, string Text)> choices = [(AiSaveTarget.Word, Strings.TabAi_SaveAsWord), (AiSaveTarget.Pdf, Strings.TabAi_SaveAsPdf)];
            if (canComment) choices.Add((AiSaveTarget.Comment, Loc.Format(Strings.TabAi_SaveAsComment, PageLabel(commentPage))));
            var choice = dlg.AddChoice(Strings.TabAi_SaveAs, choices.Select(c => c.Text));
            dlg.AddNote(Strings.TabAi_SaveMarked);
            if (!dlg.ShowModal()) return false;
            target = choices[Math.Max(0, choice.SelectedIndex)].Target;
        }

        if (target == AiSaveTarget.Comment)
        {
            if (!canComment) return false;
            var e = list[0];
            var g = Viewer.Engine!.GetPage(commentPage);
            // At the top right of the page, clear of most text; the note's icon is 20 pt.
            double x = Math.Max(0, g.Width - 44), y = 16;
            var (author, text, page) = (Author, AiAnswerExport.CommentText(e), commentPage);
            var ok = await RunEdit(Strings.TabAi_SaveCommentUndo, (d, pw) => Annotations.AddNote(d, pw, page, x, y, text, author, new AnnotColor(0.55, 0.75, 1)), contentOnly: true);
            if (ok)
            {
                ActiveView.GoToPage(page);
                Notify(Loc.Format(Strings.TabAi_SavedComment, PageLabel(page)));
            }
            return ok;
        }

        var word = target == AiSaveTarget.Word;
        var name = Loc.Format(Strings.TabAi_SavedFileName, Path.GetFileNameWithoutExtension(Session.DisplayName)) + (word ? ".docx" : ".pdf");
        path ??= CommentFileActions.PickSave(owner, one ? Strings.TabAi_SaveAnswerTitle : Strings.TabAi_SaveConversationTitle,
            word ? Strings.Export_WordFilter : PdfFiles.PdfFilter, name, Path.GetDirectoryName(Session.FilePath));
        if (path is null) return false;
        var documentName = Session.DisplayName;
        try
        {
            var bytes = await Task.Run(() => word ? AiAnswerExport.ToDocx(list, documentName) : AiAnswerExport.ToPdf(list, documentName));
            await File.WriteAllBytesAsync(path, bytes);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) // fire-and-forget: anything that fails is said, never lost
        {
            Log.Write($"Saving AI answers failed: {ex.GetType().Name}");
            Prompt.Error(owner, Strings.TabAi_CantSave, Strings.TabAi_CantSaveBody);
            return false;
        }
        Log.Write($"AI answers ({list.Count}) saved to {Log.Name(path)}");
        if (word) Notify(Loc.Format(Strings.TabAi_SavedFile, Path.GetFileName(path)), Strings.TabAi_OpenSaved, () => Shell.Open(path));
        else if (owner is MainWindow host) host.OpenFiles([path]);
        return true;
    }

    internal string DevAiConversation() =>
        $"ai conversation: {Session.AiConversation.Exchanges.Count}" + string.Concat(Session.AiConversation.Exchanges.Select(e => $" | {e.Kind} '{AiProtocol.Shorten(e.Shown, 40)}' → '{AiProtocol.Shorten(e.Answer.Replace('\n', ' '), 50)}' by {e.Model}"));
}
