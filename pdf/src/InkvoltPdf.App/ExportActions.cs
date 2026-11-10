using System.IO;
using System.Windows;
using InkvoltPdf.Core;
using Microsoft.Win32;

namespace InkvoltPdf.App;

/// <summary>
/// File › Export: Word (.docx), Excel (.xlsx, the tables found), plain text (.txt), PowerPoint (.pptx) and HTML (.html),
/// rebuilt from the pages' text, fonts, pictures and lines by <see cref="DocumentExport"/>; this asks for the options and the file, shows progress and
/// says what was exported. Scanned pages without a text layer are recognized with Windows' OCR first, when the user
/// leaves that on. Everything runs on this PC.
/// </summary>
internal static class ExportActions
{
    private sealed record Kind(string Title, string Extension, string Filter, string Note);

    private static Kind Describe(ExportFormat format) => format switch
    {
        ExportFormat.Word => new(Strings.Export_WordTitle, ".docx", Strings.Export_WordFilter,
            Strings.Export_WordNote),
        ExportFormat.Excel => new(Strings.Export_ExcelTitle, ".xlsx", Strings.Export_ExcelFilter,
            Strings.Export_ExcelNote),
        ExportFormat.PowerPoint => new(Strings.Export_PowerPointTitle, ".pptx", Strings.Export_PowerPointFilter,
            Strings.Export_PowerPointNote),
        ExportFormat.Html => new(Strings.Export_HtmlTitle, ".html", Strings.Export_HtmlFilter,
            Strings.Export_HtmlNote),
        _ => new(Strings.Export_TextTitle, ".txt", Strings.Export_TextFilter,
            Strings.Export_TextNote),
    };

    public static async Task Export(Window owner, DocumentTab tab, MainWindow host, ExportFormat format)
    {
        if (!await tab.SettleAsync()) return;
        var kind = Describe(format);
        var ocr = PageOcr.Engine;
        var dlg = new FormDialog(owner, kind.Title, Strings.Export_ExportButton, 480);
        var range = dlg.AddRange(tab, preferSelection: false);
        var useOcr = dlg.AddCheck(Strings.Export_UseOcr, ocr is not null && AppSettings.Current.ExportOcr);
        useOcr.Margin = new Thickness(0, 14, 0, 0);
        if (ocr is null)
        {
            useOcr.IsEnabled = false;
            System.Windows.Automation.AutomationProperties.SetHelpText(useOcr, PageOcr.Unavailable);
            dlg.AddNote(PageOcr.Unavailable);
        }
        var open = dlg.AddCheck(Strings.Export_OpenWhenDone, AppSettings.Current.ExportOpen);
        dlg.AddNote(kind.Note + (ocr is null ? "" : " " + Loc.Format(Strings.Export_OcrNote, ocr.LanguageName)));
        int[] pages = [];
        dlg.Validate(() => range.TryGet(out pages, out var err) ? null : err);
        if (!dlg.ShowModal() || !await tab.SettleAsync()) return;
        pages = [.. pages.Where(p => p < tab.PageView.PageCount)];
        if (pages.Length == 0) return;
        if (!Organize.ConfirmUnprotected(owner, tab, Strings.Export_Unprotected, Strings.Comments_ExportAnyway)) return;
        var recognize = ocr is not null && useOcr.IsChecked == true;
        AppSettings.Current.ExportOpen = open.IsChecked == true;
        if (ocr is not null) AppSettings.Current.ExportOcr = recognize;

        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        var folder = Path.GetDirectoryName(tab.Session.FilePath) ?? AppSettings.Current.LastFolder;
        if (PickPath(owner, kind, name + kind.Extension, folder) is not { } path) return;
        AppSettings.Current.Save();
        await Run(owner, tab, host, format, pages, recognize, open.IsChecked == true, path, atOnce: false);
    }

    /// <summary>
    /// The command bar's Convert › Word (and Excel, PowerPoint, text, HTML): no questions. Every page, scanned pages
    /// recognized when Windows has a recognizer, saved as name.docx next to the PDF (never over a file: "name (2).docx"),
    /// in Documents when the PDF isn't saved yet or its folder refuses it (<see cref="ExportTarget"/>: the name is reserved
    /// off the UI thread by creating the file), then opened; the notice offers Show in folder and Change options… (the
    /// <see cref="Export"/> window). With nowhere to write (no Documents either) it says so and asks where. A second click
    /// while one runs on the same document is ignored.
    /// </summary>
    public static async Task ConvertAtOnce(Window owner, DocumentTab tab, MainWindow host, ExportFormat format)
    {
        if (!Converting.Add(tab)) return;
        string? reserved = null;
        try
        {
            if (!await tab.SettleAsync()) return;
            int[] pages = [.. Enumerable.Range(0, tab.PageView.PageCount)];
            if (pages.Length == 0) return;
            if (!Organize.ConfirmUnprotected(owner, tab, Strings.Export_Unprotected, Strings.Comments_ExportAnyway)) return;
            string path;
            var inDocuments = false;
            if (DevScript.TakeSavePath(out var scripted))
            {
                if (scripted is null) return; // a script's "savepath cancel", as the Save dialog's Cancel
                path = scripted;
            }
            else
            {
                var name = ConvertCommand.OutputName(tab.Session.DisplayName, format);
                var pdf = tab.Session.FilePath;
                ExportTarget.Reserved? target;
                // Busy while a slow share answers, so no edit starts that would replace the engine the export then reads.
                using (tab.BeginBusy(null))
                    target = await Reserve(pdf, name);
                if (target is not null) reserved = target.Path;
                if (tab.IsDisposed) return; // closed meanwhile: the empty reserved file goes (finally)
                if (target is null)
                {
                    Log.Write($"Convert {format}: nowhere to write (the PDF's folder refused it, no Documents folder)");
                    Prompt.Info(owner, Strings.Export_CantSave, Strings.Export_NowhereToSave);
                    Converting.Remove(tab);
                    await Export(owner, tab, host, format);
                    return;
                }
                (path, inDocuments) = (target.Path, target.InDocuments);
            }
            await Run(owner, tab, host, format, pages, recognize: true, open: true, path, atOnce: true, inDocuments);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Run catches its own; this is what comes before it (a settle or reservation that failed), never lost silently.
            Log.Write($"Convert {format} failed: {ex}");
            Prompt.Error(owner, Strings.Export_Failed, ex.Message);
        }
        finally
        {
            Converting.Remove(tab);
            // The reserved, still empty file of a conversion that wrote nothing (cancelled, failed, nothing to export).
            if (reserved is not null) DeleteIfEmpty(reserved);
        }
    }

    /// <summary>
    /// Explorer's "Convert to Word with Inkvolt PDF" for one file (<see cref="ConvertCommand"/>): the one-click Convert
    /// above without a tab. The file is read as File › Open reads it (its password asked for; a damaged or unreadable
    /// one ends with Open's message), a protected one asks "export anyway?", every page goes with scanned pages
    /// recognized, the output is reserved next to the PDF or in Documents, never over a file, and it is opened when
    /// <paramref name="open"/> (a request for this one file). Nothing is shown here: the outcome says what happened, and
    /// the caller shows it (<see cref="ExplorerConvert"/>: the notice, or the conversions window).
    /// </summary>
    public static async Task<ConvertOutcome> ConvertFile(Window owner, string pdf, ExportFormat format, Func<bool> open, CancellationToken cancel)
    {
        var fileName = Path.GetFileName(pdf);
        if (!await Task.Run(() => File.Exists(pdf), cancel))
            return ConvertOutcome.Failed(ConvertResult.NotFound, Loc.Format(Strings.Main_NotFound, fileName));
        DocumentSession session;
        string? password = null;
        var wrong = false;
        while (true)
        {
            try
            {
                var pw = password;
                session = await Task.Run(() => DocumentSession.Open(pdf, pw), cancel);
                break;
            }
            catch (PasswordRequiredException ex)
            {
                password = PdfFiles.PromptPassword(owner, fileName, wrong || ex.WrongPassword);
                if (password is null) return ConvertOutcome.Failed(ConvertResult.Cancelled, null);
                wrong = true;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                Log.Write($"Convert: open {Log.Name(pdf)} failed: {ex}");
                return ConvertOutcome.Failed(ConvertResult.NotOpened,
                    $"{Loc.Format(Strings.Main_OpenFailedTitle, fileName)}. {Strings.Main_OpenFailedBody} {ex.Message}");
            }
        }
        string? reserved = null;
        try
        {
            using (session)
            {
                var pages = Enumerable.Range(0, session.Engine.PageCount).ToArray();
                if (pages.Length == 0) return ConvertOutcome.Failed(ConvertResult.NothingToSave, Loc.Format(Strings.Export_NothingPages, ""));
                if (session.Engine.IsEncrypted
                    && !Prompt.Confirm(owner, Strings.Organize_ProtectedTitle, Strings.Export_Unprotected, Strings.Comments_ExportAnyway, warning: true))
                    return ConvertOutcome.Failed(ConvertResult.Cancelled, null);
                var target = await Reserve(pdf, ConvertCommand.OutputName(pdf, format));
                if (target is null)
                {
                    Log.Write($"Convert {format} from Explorer: nowhere to write (the PDF's folder refused it, no Documents folder)");
                    return ConvertOutcome.Failed(ConvertResult.Failed, Strings.Export_NowhereExplorer);
                }
                reserved = target.Path;
                var source = format is ExportFormat.PowerPoint or ExportFormat.Html && session.IsPdf ? session.Data : null;
                var done = await ExportPages(owner, session.Engine, source, session.Password, Path.GetFileNameWithoutExtension(pdf),
                    format, pages, recognize: true, target.Path, cancel, detached: true);
                if (!done.Saved) return ConvertOutcome.Failed(ConvertResult.NothingToSave, done.Message);
                Log.Write($"Convert {format} from Explorer: {pages.Length} page(s) to {Log.Name(target.Path)}");
                if (open()) Shell.Open(target.Path);
                return ConvertOutcome.Saved(target.Path, target.InDocuments, done.Notes.Count > 0 ? string.Join(", ", done.Notes) : null);
            }
        }
        catch (OperationCanceledException)
        {
            Log.Write($"Convert {format} from Explorer cancelled");
            return ConvertOutcome.Failed(ConvertResult.Cancelled, null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Convert {format} from Explorer failed: {ex.Message}");
            return ConvertOutcome.Failed(ConvertResult.Failed, Loc.Format(Strings.PdfA_SaveFailed, ex.Message));
        }
        catch (Exception ex)
        {
            Log.Write($"Convert {format} from Explorer failed: {ex}");
            return ConvertOutcome.Failed(ConvertResult.Failed, ex.Message);
        }
        finally
        {
            if (reserved is not null) DeleteIfEmpty(reserved);
        }
    }

    /// <summary>The one-click's output file, reserved off the UI thread (a share can be slow): next to the PDF, else Documents.</summary>
    private static Task<ExportTarget.Reserved?> Reserve(string? pdf, string name)
    {
        var documents = DocumentsFolder();
        return Task.Run(() => ExportTarget.Reserve(pdf, name, documents, (folder, file) => PdfFiles.UniquePath(folder, file)));
    }

    // The documents converting at once: a second click meanwhile is ignored rather than started twice.
    private static readonly HashSet<DocumentTab> Converting = [];

    private static string? DocumentsFolder()
    {
        try
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        }
        catch (Exception ex) when (ex is PlatformNotSupportedException or System.Security.SecurityException)
        {
            return null;
        }
    }

    private static void DeleteIfEmpty(string path)
    {
        try
        {
            if (new FileInfo(path) is { Exists: true, Length: 0 } empty) empty.Delete();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Convert: the empty reserved file stays ({ex.Message})");
        }
    }

    /// <summary>What one export did: saved, with its notes ("2 pages recognized"), or not, with the title and message saying why.</summary>
    private sealed record Exported(bool Saved, IReadOnlyList<string> Notes, string Title, string Message);

    /// <summary>
    /// Exports <paramref name="pages"/> of <paramref name="engine"/> to <paramref name="path"/> with a progress window
    /// (its Cancel, or <paramref name="cancel"/>, stops it: OperationCanceledException), and explains the result. File
    /// errors and the rest are thrown, the progress window already closed.
    /// </summary>
    private static async Task<Exported> ExportPages(Window owner, PdfEngine engine, byte[]? source, string? sourcePassword, string name,
        ExportFormat format, int[] pages, bool recognize, string path, CancellationToken cancel = default, bool detached = false)
    {
        var kind = Describe(format);
        var ocr = PageOcr.Engine;
        recognize &= ocr is not null;
        using var progress = new ProgressPrompt(owner, kind.Title, Strings.Access_ReadingPages, detached);
        using var both = CancellationTokenSource.CreateLinkedTokenSource(progress.Token, cancel);
        var options = new ExportOptions
        {
            Pages = pages,
            Title = name,
            Recognize = recognize ? PageOcr.AsSet(ocr!).Page : null,
            Source = source,
            SourcePassword = sourcePassword,
            Progress = at => progress.Report(at.Stage switch
            {
                ExportStage.Reading => Loc.Format(Strings.Export_ReadingPage, at.Page + 1, at.Index + 1, at.Count),
                ExportStage.Recognizing => Loc.Format(Strings.Export_RecognizingPage, at.Page + 1, at.Index + 1, at.Count),
                _ => Strings.Export_Writing,
            }, at.Fraction),
        };
        var token = both.Token;
        // Nothing is saved when nothing was extracted: no text at all (and, for Word, PowerPoint and HTML, no pictures either) or no tables.
        var report = await Task.Run(() => DocumentExport.ExportToFile(engine, format, path, options, token), token);
        progress.Dispose();
        foreach (var problem in report.Unreadable) Log.Write($"Export: page {problem.Page + 1} can't be read: {problem.Message}");
        foreach (var problem in report.RecognitionFailed) Log.Write($"Export: text recognition failed on page {problem.Page + 1}: {problem.Message}");
        var (recognized, noText, withPictures, tables) = (report.Recognized, report.NoText, report.NoTextWithPictures, report.Tables);
        var (unreadable, ocrFailed) = (report.Unreadable.Count, report.RecognitionFailed.Count);
        if (!report.Saved)
        {
            var one = pages.Length == 1;
            var why = "";
            if (noText > 0)
            {
                var clause = noText == pages.Length ? (one ? Strings.Export_PageNoText : Strings.Export_NoPagesText) : Loc.Plural(noText, Strings.Export_PagesNoText_One, Strings.Export_PagesNoText_Many);
                why = " " + Loc.Format(recognize ? (ocrFailed > 0 ? Strings.Export_WhyOcrFailed : Strings.Export_WhyEvenOcr)
                    : ocr is null ? Strings.Export_WhyNoOcr
                    : Strings.Export_WhyTurnOn, clause);
            }
            return format == ExportFormat.Excel
                ? new(false, [], Strings.Export_NoTables, Loc.Format(one ? Strings.Export_NoTablesPage : Strings.Export_NoTablesPages, why))
                : new(false, [], Strings.Export_NoText, Loc.Format(one ? Strings.Export_NothingPage : Strings.Export_NothingPages, why));
        }
        var notes = new List<string>();
        if (recognized > 0) notes.Add(Loc.Plural(recognized, Strings.Export_NoteOcr_One, Strings.Export_NoteOcr_Many));
        if (noText > 0) notes.Add(format != ExportFormat.Excel && format != ExportFormat.Text && withPictures > 0
            ? Loc.Plural(noText, Strings.Export_NoteNoTextPictures_One, Strings.Export_NoteNoTextPictures_Many)
            : Loc.Plural(noText, Strings.Export_NoteNoText_One, Strings.Export_NoteNoText_Many));
        if (report.SuspectWords > 0) notes.Add(Loc.Plural(report.SuspectWords, Strings.Export_NoteSuspects_One, Strings.Export_NoteSuspects_Many));
        if (ocrFailed > 0) notes.Add(Loc.Plural(ocrFailed, Strings.Export_NoteOcrFailed_One, Strings.Export_NoteOcrFailed_Many));
        if (unreadable > 0) notes.Add(Loc.Plural(unreadable, Strings.Export_NoteUnreadable_One, Strings.Export_NoteUnreadable_Many));
        if (format == ExportFormat.Excel) notes.Insert(0, Loc.Plural(tables, Strings.Access_Tables_One, Strings.Access_Tables_Many));
        Log.Write($"Export {format}: {pages.Length} page(s) to {Log.Name(path)}{(notes.Count > 0 ? "; " + string.Join("; ", notes) : "")}");
        return new(true, notes, "", "");
    }

    private static async Task Run(Window owner, DocumentTab tab, MainWindow host, ExportFormat format, int[] pages,
        bool recognize, bool open, string path, bool atOnce, bool inDocuments = false)
    {
        // Busy from here, so nothing replaces the engine this export reads.
        using var busy = tab.BeginBusy(Loc.Plural(pages.Length, Strings.Export_Exporting_One, Strings.Export_Exporting_Many));
        var engine = tab.ViewEngine; // what is shown (chosen layers included)
        // PowerPoint and HTML read the language and alternate text from the PDF itself; the others have no use for its bytes.
        var source = format is ExportFormat.PowerPoint or ExportFormat.Html && tab.Session.IsPdf ? tab.Session.Data : null;
        try
        {
            var done = await ExportPages(owner, engine, source, tab.Session.Password, Path.GetFileNameWithoutExtension(tab.Session.DisplayName),
                format, pages, recognize, path);
            if (!done.Saved)
            {
                Prompt.Info(owner, done.Title, done.Message);
                return;
            }
            var notes = done.Notes;
            if (atOnce)
            {
                // "Saved report.docx · Show in folder · Change options…" (the notes after the name, as the export's own notice).
                var saved = Loc.Format(inDocuments ? Strings.Export_SavedDocuments : Strings.Export_Saved, Path.GetFileName(path)) + (notes.Count > 0 ? " (" + string.Join(", ", notes) + ")" : "");
                host.ShowToast(new Toast(saved, Strings.Export_ShowInFolder, () => Shell.ShowInFolder(path),
                    Action2Label: Strings.Export_ChangeOptions, Action2: () =>
                    {
                        // The notice outlives the export: another job may have started on the tab, or the tab closed.
                        if (tab.IsDisposed) return;
                        if (tab.IsBusy) host.ShowStatus(Loc.Format(Strings.Main_StillBusy, tab.Session.DisplayName));
                        else _ = Export(owner, tab, host, format);
                    }), tab);
            }
            else
                host.ShowStatus(notes.Count > 0
                    ? Loc.Plural(pages.Length, Strings.Export_ExportedNotes_One, Strings.Export_ExportedNotes_Many, Path.GetFileName(path), string.Join(", ", notes))
                    : Loc.Plural(pages.Length, Strings.Export_Exported_One, Strings.Export_Exported_Many, Path.GetFileName(path)));
            if (open) Shell.Open(path);
        }
        catch (OperationCanceledException)
        {
            Log.Write($"Export {format} cancelled");
            host.ShowStatus(Strings.Export_Cancelled);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Export {format} failed: {ex.Message}");
            Prompt.Error(owner, Strings.Export_CantSave, Loc.Format(Strings.PdfA_SaveFailed, ex.Message));
        }
        catch (Exception ex)
        {
            Log.Write($"Export {format} failed: {ex}");
            Prompt.Error(owner, Strings.Export_Failed, ex.Message);
        }
    }

    private static string? PickPath(Window owner, Kind kind, string suggested, string folder)
    {
        if (DevScript.TakeSavePath(out var scripted)) return scripted;
        var dlg = new SaveFileDialog
        {
            Title = kind.Title,
            Filter = kind.Filter,
            FileName = suggested,
            DefaultExt = kind.Extension,
            AddExtension = true,
            InitialDirectory = folder,
        };
        return dlg.ShowDialog(owner) == true ? dlg.FileName : null;
    }
}
