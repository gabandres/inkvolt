using System.IO;
using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>Where Save AI Answer puts the answers.</summary>
public enum AiSaveTarget { Word, Pdf, Comment, Audio }

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
            choices.Add((AiSaveTarget.Audio, Strings.TabAi_SaveAsAudio));
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

        if (target == AiSaveTarget.Audio) return await SaveAiAudio(owner, list, one, path);

        var word = target == AiSaveTarget.Word;
        var name = Loc.Format(Strings.TabAi_SavedFileName, Path.GetFileNameWithoutExtension(Session.DisplayName)) + (word ? ".docx" : ".pdf");
        path ??= CommentFileActions.PickSave(owner, one ? Strings.TabAi_SaveAnswerTitle : Strings.TabAi_SaveConversationTitle,
            word ? Strings.Export_WordFilter : PdfFiles.PdfFilter, name, Path.GetDirectoryName(Session.FilePath));
        if (path is null) return false;
        // Never over a PDF open in a tab (this one included): its tab reads that file.
        if (PdfFiles.IsOpenInTab(path))
        {
            OpenInTabRefused(path);
            return false;
        }
        var documentName = Session.DisplayName;
        try
        {
            var bytes = await Task.Run(() => word ? AiAnswerExport.ToDocx(list, documentName) : AiAnswerExport.ToPdf(list, documentName));
            var file = path;
            await Task.Run(() => AtomicFile.WriteAllBytes(file, bytes));
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

    /// <summary>What the last recording came to, for the dev script.</summary>
    internal SpeechFileResult? LastAudio { get; private set; }

    /// <summary>
    /// The answers read aloud to a WAV or MP3 file (roadmap 4.24) with Read Aloud's voice and speed: nothing leaves the PC,
    /// Windows' own voice speaks the text already here. Stop on the progress window ends it with nothing written.
    /// </summary>
    private async Task<bool> SaveAiAudio(Window owner, IReadOnlyList<AiExchange> list, bool one, string? path)
    {
        if (Windows.Media.SpeechSynthesis.SpeechSynthesizer.AllVoices.Count == 0)
        {
            Prompt.Error(owner, Strings.Read_NoVoices, Strings.Read_NoVoicesBody);
            return false;
        }
        var name = Loc.Format(one && list[0].Kind == AiAnswerKind.Summary ? Strings.TabAi_AudioFileName : Strings.TabAi_SavedFileName,
            Path.GetFileNameWithoutExtension(Session.DisplayName)) + ".mp3";
        path ??= CommentFileActions.PickSave(owner, Strings.TabAi_AudioTitle, Strings.TabAi_AudioFilter, name, Path.GetDirectoryName(Session.FilePath));
        if (path is null) return false;
        var paragraphs = AiAnswerSpeech.Paragraphs(list);
        using var prompt = new ProgressPrompt(owner, Strings.TabAi_AudioTitle, Strings.TabAi_AudioSpeaking);
        try
        {
            var progress = new Progress<(int Done, int Total)>(p => prompt.Report(Loc.Format(Strings.TabAi_AudioProgress, p.Done, p.Total), (double)p.Done / p.Total));
            var result = await SpeechFile.SaveAsync(paragraphs, path, progress, prompt.Token);
            LastAudio = result;
            Log.Write($"AI answers ({list.Count}) read aloud to {Log.Name(result.Path)}, {result.Duration.TotalSeconds:0} s");
            var said = Loc.Format(Strings.TabAi_AudioSaved, Path.GetFileName(result.Path), result.Duration.ToString(result.Duration.TotalHours >= 1 ? @"h\:mm\:ss" : @"m\:ss"));
            if (result.Mp3Refused) said = Strings.TabAi_AudioNoMp3 + " " + said;
            Notify(said, Strings.TabAi_OpenSaved, () => Shell.Open(result.Path));
            return true;
        }
        catch (OperationCanceledException)
        {
            Notify(Strings.TabAi_AudioStopped);
            return false;
        }
        catch (WavTooLongException ex)
        {
            Log.Write($"Reading AI answers aloud to a file stopped: too long ({paragraphs.Count} paragraphs)");
            Prompt.Error(owner, Strings.TabAi_AudioTitle, ex.Message);
            return false;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) // fire-and-forget: anything that fails is said
        {
            Log.Write($"Reading AI answers aloud to a file failed: {ex.GetType().Name} 0x{ex.HResult:X8}");
            Prompt.Error(owner, Strings.TabAi_AudioTitle, Strings.TabAi_AudioFailed);
            return false;
        }
    }

    /// <summary>Summary to Audio: the pages summarized (the send window as always), then the summary read aloud to a file.</summary>
    public async Task AiSummaryToAudio(int[] pages, string? path = null)
    {
        var before = LastAiAnswer;
        await AiSummarize(pages);
        if (_disposed || LastAiAnswer is not { Kind: AiAnswerKind.Summary } summary || ReferenceEquals(summary, before)) return;
        await SaveAiAnswers([summary], AiSaveTarget.Audio, path);
    }

    /// <summary>The last recording: its file, length, and what the file holds (a WAV's format, or an MP3's first bytes).</summary>
    internal string DevAudioState()
    {
        if (LastAudio is not { } a) return "audio: none";
        var bytes = File.Exists(a.Path) ? File.ReadAllBytes(a.Path) : [];
        string kind;
        try
        {
            var wav = WavFile.Read(bytes);
            kind = $"wav {wav.SampleRate} Hz {wav.Channels} ch {wav.BitsPerSample} bit {wav.Duration.TotalSeconds:0.0} s";
        }
        catch (InvalidDataException)
        {
            kind = bytes.Length >= 3 && (bytes.AsSpan(0, 3).SequenceEqual("ID3"u8) || (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)) ? "mp3" : "unknown";
        }
        return $"audio: {Path.GetFileName(a.Path)} {bytes.Length} bytes, {kind}, said {a.Duration.TotalSeconds:0.0} s, mp3 refused={a.Mp3Refused}";
    }

    internal string DevAiConversation() =>
        $"ai conversation: {Session.AiConversation.Exchanges.Count}" + string.Concat(Session.AiConversation.Exchanges.Select(e => $" | {e.Kind} '{AiProtocol.Shorten(e.Shown, 40)}' → '{AiProtocol.Shorten(e.Answer.Replace('\n', ' '), 50)}' by {e.Model}"));
}
