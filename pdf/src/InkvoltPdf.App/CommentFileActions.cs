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
    private const string Filter = "XFDF, for Acrobat and other PDF apps (*.xfdf)|*.xfdf|FDF, keeps every appearance (*.fdf)|*.fdf|CSV, a row per comment (*.csv)|*.csv";
    private const string OpenFilter = "Comment files (*.xfdf;*.fdf;*.csv;*.xml)|*.xfdf;*.fdf;*.csv;*.xml|All files (*.*)|*.*";

    public static async Task Export(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        if (!Organize.ConfirmUnprotected(host, tab, "The comments are saved without the document's password protection: anyone can read them.", "Export anyway")) return;
        if (PickSave(host, "Export Comments", Filter, name + ".xfdf", Path.GetDirectoryName(tab.Session.FilePath)) is not { } path) return;
        var format = CommentFiles.FormatOf(path) ?? CommentFileFormat.Xfdf;
        try
        {
            var export = await Task.Run(() => CommentFiles.Export(data, password, format, tab.Session.DisplayName));
            if (export.Count == 0)
            {
                Prompt.Info(host, "No comments", "This document has no comments to export, so no file was saved." + Lines(export.Left));
                return;
            }
            await File.WriteAllBytesAsync(path, export.Data);
            Log.Write($"Export comments: {export.Count} as {format} to {Log.Name(path)}");
            host.ShowStatus($"Exported {Count(export.Count, "comment", "comments")} to {Path.GetFileName(path)}.");
            if (export.Left.Count > 0) Prompt.Info(host, "Some annotations weren't exported", string.Join("\n", export.Left));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Log.Write($"Export comments failed: {ex.Message}");
            Prompt.Error(host, "Can't export the comments", ex.Message);
        }
    }

    public static async Task Import(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        if (PickOpen(host, "Import Comments", OpenFilter) is not { } path) return;
        byte[] file;
        try
        {
            file = await File.ReadAllBytesAsync(path);
            CommentFiles.Count(file); // a file that isn't comments is refused before the edit
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Prompt.Error(host, $"Can't import {Path.GetFileName(path)}", ex.Message);
            return;
        }
        CommentImport? result = null;
        var outcome = await tab.TryEdit("Import comments", (d, pw) =>
        {
            result = CommentFiles.Import(d, pw, file);
            return result.Data;
        }, contentOnly: true, quiet: true);
        if (result is null || outcome is not (EditOutcome.Done or EditOutcome.NoChange)) return;
        Log.Write($"Import comments from {Log.Name(path)}: {result.Added} added, {result.Skipped.Count} skipped");
        var summary = result.Added == 0 ? "No comments were added." : $"{Count(result.Added, "comment was", "comments were")} added. You can undo this until you save.";
        if (result.Skipped.Count == 0 && result.Notes.Count == 0)
        {
            host.ShowStatus(summary);
            return;
        }
        var dlg = new FormDialog(host, "Comments Imported", "Close", 560);
        dlg.HideCancel();
        dlg.AddNote(summary + (result.Skipped.Count > 0 ? $" {Count(result.Skipped.Count, "was", "were")} skipped:" : ""));
        if (result.Skipped.Count > 0)
        {
            var list = new System.Windows.Controls.TextBox
            {
                Text = string.Join("\n", result.Skipped.Take(2000)) + (result.Skipped.Count > 2000 ? $"\n… and {result.Skipped.Count - 2000:N0} more" : ""),
                IsReadOnly = true,
                TextWrapping = TextWrapping.Wrap,
                VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto,
                MaxHeight = 260,
            };
            dlg.Add("Skipped", list);
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
        if (!Organize.ConfirmUnprotected(host, tab, "The summary is saved without the document's password protection: anyone can open it.", "Summarize anyway")) return;
        if (PickSave(host, "Summarize Comments", PdfFiles.PdfFilter, name + " comments.pdf", Path.GetDirectoryName(tab.Session.FilePath)) is not { } path) return;
        try
        {
            byte[] summary;
            using (new ProgressPrompt(host, "Summarize Comments", "Laying out the pages and their comments…"))
                summary = await Task.Run(() => CommentSummary.Make(data, password, tab.Session.DisplayName));
            await File.WriteAllBytesAsync(path, summary);
            Log.Write($"Summarize comments to {Log.Name(path)}");
            host.OpenFiles([path]);
        }
        catch (Exception ex) when (ex is InvalidOperationException)
        {
            Prompt.Info(host, "No comments", ex.Message);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(host, "Can't save the summary", ex.Message);
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
