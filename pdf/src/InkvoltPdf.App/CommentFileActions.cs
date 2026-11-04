using System.IO;
using System.Windows;
using InkvoltPdf.Core;
using Microsoft.Win32;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Export Comments…, Import Comments… and Summarize Comments… (roadmap 1.4): <see cref="CommentFiles"/> as
/// XFDF, FDF or CSV, and <see cref="CommentSummary"/>'s PDF. Import is an edit (one undo step) and says what it skipped.
/// </summary>
internal static class CommentFileActions
{
    private static string Filter => Strings.Comments_ExportFilter;
    private static string OpenFilter => Strings.Comments_OpenFilter;

    public static async Task Export(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        if (!Organize.ConfirmUnprotected(host, tab, Strings.Comments_ExportUnprotected, Strings.Comments_ExportAnyway)) return;
        if (PickSave(host, Strings.Comments_ExportTitle, Filter, name + ".xfdf", Path.GetDirectoryName(tab.Session.FilePath)) is not { } path) return;
        var format = CommentFiles.FormatOf(path) ?? CommentFileFormat.Xfdf;
        try
        {
            var export = await Task.Run(() => CommentFiles.Export(data, password, format, tab.Session.DisplayName));
            if (export.Count == 0)
            {
                Prompt.Info(host, Strings.Comments_NoComments, Strings.Comments_NoneToExport + Lines(export.Left));
                return;
            }
            await File.WriteAllBytesAsync(path, export.Data);
            Log.Write($"Export comments: {export.Count} as {format} to {Log.Name(path)}");
            host.ShowStatus(Loc.Plural(export.Count, Strings.Comments_Exported_One, Strings.Comments_Exported_Many, Path.GetFileName(path)));
            if (export.Left.Count > 0) Prompt.Info(host, Strings.Comments_SomeNotExported, string.Join("\n", export.Left));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Log.Write($"Export comments failed: {ex.Message}");
            Prompt.Error(host, Strings.Comments_CantExport, ex.Message);
        }
    }

    public static async Task Import(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        if (PickOpen(host, Strings.Comments_ImportTitle, OpenFilter) is not { } path) return;
        byte[] file;
        try
        {
            file = await File.ReadAllBytesAsync(path);
            CommentFiles.Count(file); // a file that isn't comments is refused before the edit
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Prompt.Error(host, Loc.Format(Strings.Comments_CantImport, Path.GetFileName(path)), ex.Message);
            return;
        }
        CommentImport? result = null;
        var outcome = await tab.TryEdit(Strings.Comments_ImportLabel, (d, pw) =>
        {
            result = CommentFiles.Import(d, pw, file);
            return result.Data;
        }, contentOnly: true, quiet: true);
        if (result is null || outcome is not (EditOutcome.Done or EditOutcome.NoChange)) return;
        Log.Write($"Import comments from {Log.Name(path)}: {result.Added} added, {result.Skipped.Count} skipped");
        var summary = result.Added == 0 ? Strings.Comments_NoneAdded : Loc.Plural(result.Added, Strings.Comments_Added_One, Strings.Comments_Added_Many);
        if (result.Skipped.Count == 0 && result.Notes.Count == 0)
        {
            host.ShowStatus(summary);
            return;
        }
        var dlg = new FormDialog(host, Strings.Comments_ImportedTitle, Strings.Common_Close, 560);
        dlg.HideCancel();
        dlg.AddNote(summary + (result.Skipped.Count > 0 ? " " + Loc.Plural(result.Skipped.Count, Strings.Comments_Skipped_One, Strings.Comments_Skipped_Many) : ""));
        if (result.Skipped.Count > 0)
        {
            var list = new System.Windows.Controls.TextBox
            {
                Text = string.Join("\n", result.Skipped.Take(2000)) + (result.Skipped.Count > 2000 ? "\n" + Loc.Format(Strings.Comments_AndMore, result.Skipped.Count - 2000) : ""),
                IsReadOnly = true,
                TextWrapping = TextWrapping.Wrap,
                VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto,
                MaxHeight = 260,
            };
            dlg.Add(Strings.Comments_Skipped, list);
        }
        foreach (var n in result.Notes) dlg.AddNote(n);
        dlg.ShowModal();
    }

    public static async Task Summarize(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        if (!Organize.ConfirmUnprotected(host, tab, Strings.Comments_SummaryUnprotected, Strings.Comments_SummarizeAnyway)) return;
        if (PickSave(host, Strings.Comments_SummarizeTitle, PdfFiles.PdfFilter, Loc.Format(Strings.Comments_SummaryFileName, name), Path.GetDirectoryName(tab.Session.FilePath)) is not { } path) return;
        try
        {
            byte[] summary;
            using (new ProgressPrompt(host, Strings.Comments_SummarizeTitle, Strings.Comments_LayingOut))
                summary = await Task.Run(() => CommentSummary.Make(data, password, tab.Session.DisplayName));
            await File.WriteAllBytesAsync(path, summary);
            Log.Write($"Summarize comments to {Log.Name(path)}");
            host.OpenFiles([path]);
        }
        catch (Exception ex) when (ex is InvalidOperationException)
        {
            Prompt.Info(host, Strings.Comments_NoComments, ex.Message);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(host, Strings.Comments_CantSaveSummary, ex.Message);
        }
    }

    internal static string? PickSave(Window owner, string title, string filter, string suggested, string? folder)
    {
        if (DevScript.TakeSavePath(out var scripted)) return scripted;
        var dlg = new SaveFileDialog
        {
            Title = title,
            Filter = filter,
            FileName = suggested,
            AddExtension = true,
            InitialDirectory = folder ?? AppSettings.Current.LastFolder,
        };
        return dlg.ShowDialog(owner) == true ? dlg.FileName : null;
    }

    /// <summary>An open-file picker (the dev script's <c>savepath</c> answers it too).</summary>
    internal static string? PickOpen(Window owner, string title, string filter)
    {
        if (DevScript.TakeSavePath(out var scripted)) return scripted;
        var dlg = new OpenFileDialog { Title = title, Filter = filter, InitialDirectory = AppSettings.Current.LastFolder };
        return dlg.ShowDialog(owner) == true ? dlg.FileName : null;
    }

    private static string Lines(IReadOnlyList<string> lines) => lines.Count == 0 ? "" : "\n\n" + string.Join("\n", lines);

    internal static string Count(int n, string one, string many) => n == 1 ? $"1 {one}" : $"{n:N0} {many}";
}
