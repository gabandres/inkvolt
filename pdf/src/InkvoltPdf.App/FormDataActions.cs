using System.IO;
using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Edit › Forms › Export Form Data…, Import Form Data… and Fill Forms from CSV… (roadmap 1.4): <see cref="FormDataFiles"/>
/// as XFDF, FDF, CSV or JSON, and <see cref="FormMerge"/> (a filled copy of the form per CSV row, with a report of the
/// rows that failed). Import is an edit (one undo step); values the form refuses are listed.
/// </summary>
internal static class FormDataActions
{
    private const string Filter = "XFDF, for Acrobat and other PDF apps (*.xfdf)|*.xfdf|FDF (*.fdf)|*.fdf|CSV, a header and a row of values (*.csv)|*.csv|JSON (*.json)|*.json";
    private const string OpenFilter = "Form data (*.xfdf;*.fdf;*.csv;*.json;*.xml)|*.xfdf;*.fdf;*.csv;*.json;*.xml|All files (*.*)|*.*";

    public static async Task Export(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        if (!Organize.ConfirmUnprotected(host, tab, "The form data is saved without the document's password protection: anyone can read it.", "Export anyway")) return;
        if (CommentFileActions.PickSave(host, "Export Form Data", Filter, name + " data.xfdf", Path.GetDirectoryName(tab.Session.FilePath)) is not { } path) return;
        var format = FormDataFiles.FormatOf(path) ?? FormDataFormat.Xfdf;
        try
        {
            var bytes = await Task.Run(() => FormDataFiles.Export(data, password, format, tab.Session.DisplayName));
            await File.WriteAllBytesAsync(path, bytes);
            Log.Write($"Export form data as {format} to {Log.Name(path)}");
            host.ShowStatus($"Form data exported to {Path.GetFileName(path)}.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Prompt.Error(host, "Can't export the form data", ex.Message);
        }
    }

    public static async Task Import(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        if (CommentFileActions.PickOpen(host, "Import Form Data", OpenFilter) is not { } path) return;
        byte[] file;
        try
        {
            file = await File.ReadAllBytesAsync(path);
            if (FormDataFiles.Sniff(file) != FormDataFormat.Csv) FormDataFiles.ReadValues(file); // refused before the edit
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Prompt.Error(host, $"Can't import {Path.GetFileName(path)}", ex.Message);
            return;
        }
        FormDataImport? result = null;
        var outcome = await tab.TryEdit("Import form data", (d, pw) =>
        {
            result = FormDataFiles.Import(d, pw, file);
            return result.Data;
        }, contentOnly: true, quiet: true);
        if (result is null || outcome is not (EditOutcome.Done or EditOutcome.NoChange)) return;
        Log.Write($"Import form data from {Log.Name(path)}: {result.Filled} filled, {result.Rejected.Count} refused, {result.Unknown.Count} unknown");
        var summary = $"{CommentFileActions.Count(result.Filled, "value was", "values were")} filled in.";
        if (result.Rejected.Count == 0 && result.Unknown.Count == 0 && result.Notes.Count == 0)
        {
            host.ShowStatus(summary);
            return;
        }
        var lines = new List<string>();
        lines.AddRange(result.Rejected.Select(r => r.Message.Length > 0 ? r.Message : $"{r.FieldName}: refused by the form"));
        if (result.Unknown.Count > 0) lines.Add($"Not fields of this form: {string.Join(", ", result.Unknown.Take(30))}{(result.Unknown.Count > 30 ? ", …" : "")}");
        Prompt.Info(host, "Form data imported", string.Join("\n\n", [summary, .. lines, .. result.Notes]));
    }

    public static async Task FillFromCsv(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var form = tab.Session.Data;
        var password = tab.Session.Password;
        var formPath = tab.Session.FilePath ?? Path.Combine(AppSettings.Current.LastFolder ?? Path.GetTempPath(), tab.Session.DisplayName);
        if (FormEditor.DataFields(form, password).Count == 0)
        {
            Prompt.Info(host, "No form fields", "This document has no form fields to fill. Edit › Forms › Prepare Form adds them.");
            return;
        }
        if (CommentFileActions.PickOpen(host, "Fill Forms from CSV: choose the CSV", "CSV files (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*") is not { } csvPath) return;
        byte[] csv;
        IReadOnlyList<string> columns;
        try
        {
            csv = await File.ReadAllBytesAsync(csvPath);
            columns = FormMerge.Columns(csv);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Prompt.Error(host, $"Can't read {Path.GetFileName(csvPath)}", ex.Message);
            return;
        }

        var dlg = new FormDialog(host, "Fill Forms from CSV", "Fill", 560);
        dlg.AddNote($"Each row of {Path.GetFileName(csvPath)} fills a copy of this form. Its header names the fields; a row with a value the form " +
                    "refuses isn't saved and is listed in the report.");
        var folder = dlg.AddText("Save the forms in", Path.Combine(Path.GetDirectoryName(csvPath)!, Path.GetFileNameWithoutExtension(formPath) + " forms"));
        dlg.AddFooterButton("Choose Folder…").Click += (_, _) =>
        {
            if (PdfFiles.PickFolder(dlg, "Save the forms in", Directory.Exists(folder.Text) ? folder.Text : null) is { } picked) folder.Text = picked;
        };
        var pattern = dlg.AddText("File names", FormMergeOptions.DefaultTemplate);
        var named = columns.Where(c => c.Length > 0 && !FormMerge.IsBatchToken(c)).ToList();
        dlg.AddNote("<<name>> the form's name, <<n>> the row (<<n:3>> as 001), <<date>>" +
                    (named.Count > 0 ? $", or a column: {string.Join(", ", named.Take(12).Select(c => $"<<{c}>>"))}{(named.Count > 12 ? ", …" : "")}" : ""));
        var flatten = dlg.AddCheck("Flatten the forms (the values become part of the pages)");
        dlg.Validate(() =>
            string.IsNullOrWhiteSpace(folder.Text) || !Path.IsPathFullyQualified(folder.Text.Trim()) ? "Choose a folder for the forms." : FormMerge.ValidateTemplate(pattern.Text, columns));
        if (!dlg.ShowModal()) return;

        var options = new FormMergeOptions { OutputFolder = folder.Text.Trim(), NameTemplate = pattern.Text, Flatten = flatten.IsChecked == true };
        FormMergeReport report;
        using (var progress = new ProgressPrompt(host, "Fill Forms from CSV", "Filling the forms…"))
        {
            try
            {
                var report1 = new Progress<(int Done, int Total)>(p => progress.Report($"Row {p.Done:N0} of {p.Total:N0}…", (double)p.Done / Math.Max(1, p.Total)));
                report = await Task.Run(() => FormMerge.Run(form, password, csv, formPath, options, report1, progress.Token));
            }
            catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or IOException or UnauthorizedAccessException)
            {
                progress.Dispose();
                Prompt.Error(host, "The forms couldn't be filled", ex.Message);
                return;
            }
        }
        Log.Write($"Fill forms from CSV {Log.Name(csvPath)}: {report.Text}");
        string? reportPath = null;
        if (report.Failed.Count > 0 || report.UnknownColumns.Count > 0)
        {
            reportPath = Path.Combine(options.OutputFolder, Path.GetFileNameWithoutExtension(formPath) + " merge report.csv");
            try
            {
                Directory.CreateDirectory(options.OutputFolder);
                await File.WriteAllBytesAsync(reportPath, report.Csv());
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Log.Write($"Merge report not saved: {ex.Message}");
                reportPath = null;
            }
        }
        ShowReport(host, report, options.OutputFolder, reportPath);
    }

    private static void ShowReport(Window owner, FormMergeReport report, string folder, string? reportPath)
    {
        var dlg = new FormDialog(owner, "Forms Filled", "Close", 600);
        dlg.HideCancel();
        dlg.AddNote(report.Text + (reportPath is null ? "" : $" The report is saved as {Path.GetFileName(reportPath)} beside the forms."));
        if (report.UnknownColumns.Count > 0)
            dlg.AddNote($"Columns that aren't fields of the form were left out: {string.Join(", ", report.UnknownColumns.Take(20))}{(report.UnknownColumns.Count > 20 ? ", …" : "")}.");
        if (report.Failed.Count > 0)
        {
            var text = string.Join("\n", report.Failed.Take(1000).Select(r => $"Row {r.Row}: {string.Join("; ", r.Problems)}"));
            if (report.Failed.Count > 1000) text += $"\n… and {report.Failed.Count - 1000:N0} more (see the report)";
            dlg.Add("Rows not saved", new System.Windows.Controls.TextBox
            {
                Text = text,
                IsReadOnly = true,
                TextWrapping = TextWrapping.Wrap,
                VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto,
                MaxHeight = 280,
            });
        }
        if (report.Made.Count > 0) dlg.AddFooterButton("Open Folder").Click += (_, _) => Shell.Open(folder);
        dlg.ShowModal();
    }
}
