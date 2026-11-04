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
    private static string Filter => Strings.FormData_ExportFilter;
    private static string OpenFilter => Strings.FormData_OpenFilter;

    public static async Task Export(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        if (!Organize.ConfirmUnprotected(host, tab, Strings.FormData_ExportUnprotected, Strings.Comments_ExportAnyway)) return;
        if (CommentFileActions.PickSave(host, Strings.FormData_ExportTitle, Filter, Loc.Format(Strings.FormData_FileName, name), Path.GetDirectoryName(tab.Session.FilePath)) is not { } path) return;
        var format = FormDataFiles.FormatOf(path) ?? FormDataFormat.Xfdf;
        try
        {
            var bytes = await Task.Run(() => FormDataFiles.Export(data, password, format, tab.Session.DisplayName));
            await File.WriteAllBytesAsync(path, bytes);
            Log.Write($"Export form data as {format} to {Log.Name(path)}");
            host.ShowStatus(Loc.Format(Strings.FormData_Exported, Path.GetFileName(path)));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            Prompt.Error(host, Strings.FormData_CantExport, ex.Message);
        }
    }

    public static async Task Import(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        if (CommentFileActions.PickOpen(host, Strings.FormData_ImportTitle, OpenFilter) is not { } path) return;
        byte[] file;
        try
        {
            file = await File.ReadAllBytesAsync(path);
            if (FormDataFiles.Sniff(file) != FormDataFormat.Csv) FormDataFiles.ReadValues(file); // refused before the edit
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Prompt.Error(host, Loc.Format(Strings.Comments_CantImport, Path.GetFileName(path)), ex.Message);
            return;
        }
        FormDataImport? result = null;
        var outcome = await tab.TryEdit(Strings.FormData_ImportLabel, (d, pw) =>
        {
            result = FormDataFiles.Import(d, pw, file);
            return result.Data;
        }, contentOnly: true, quiet: true);
        if (result is null || outcome is not (EditOutcome.Done or EditOutcome.NoChange)) return;
        Log.Write($"Import form data from {Log.Name(path)}: {result.Filled} filled, {result.Rejected.Count} refused, {result.Unknown.Count} unknown");
        var summary = Loc.Plural(result.Filled, Strings.FormData_Filled_One, Strings.FormData_Filled_Many);
        if (result.Rejected.Count == 0 && result.Unknown.Count == 0 && result.Notes.Count == 0)
        {
            host.ShowStatus(summary);
            return;
        }
        var lines = new List<string>();
        lines.AddRange(result.Rejected.Select(r => r.Message.Length > 0 ? r.Message : Loc.Format(Strings.FormData_Refused, r.FieldName)));
        if (result.Unknown.Count > 0) lines.Add(Loc.Format(Strings.FormData_NotFields, string.Join(", ", result.Unknown.Take(30)) + (result.Unknown.Count > 30 ? ", …" : "")));
        Prompt.Info(host, Strings.FormData_Imported, string.Join("\n\n", [summary, .. lines, .. result.Notes]));
    }

    public static async Task FillFromCsv(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var form = tab.Session.Data;
        var password = tab.Session.Password;
        var formPath = tab.Session.FilePath ?? Path.Combine(AppSettings.Current.LastFolder ?? Path.GetTempPath(), tab.Session.DisplayName);
        if (FormEditor.DataFields(form, password).Count == 0)
        {
            Prompt.Info(host, Strings.FormData_NoFields, Strings.FormData_NoFieldsBody);
            return;
        }
        if (CommentFileActions.PickOpen(host, Strings.FormData_ChooseCsv, Strings.FormData_CsvFilter) is not { } csvPath) return;
        byte[] csv;
        IReadOnlyList<string> columns;
        try
        {
            csv = await File.ReadAllBytesAsync(csvPath);
            columns = FormMerge.Columns(csv);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Prompt.Error(host, Loc.Format(Strings.FormData_CantRead, Path.GetFileName(csvPath)), ex.Message);
            return;
        }

        var dlg = new FormDialog(host, Strings.FormData_FillTitle, Strings.FormData_Fill, 560);
        dlg.AddNote(Loc.Format(Strings.FormData_FillNote, Path.GetFileName(csvPath)));
        var folder = dlg.AddText(Strings.FormData_SaveIn, Path.Combine(Path.GetDirectoryName(csvPath)!, Loc.Format(Strings.FormData_FormsFolder, Path.GetFileNameWithoutExtension(formPath))));
        dlg.AddFooterButton(Strings.FormData_ChooseFolder).Click += (_, _) =>
        {
            if (PdfFiles.PickFolder(dlg, Strings.FormData_SaveIn, Directory.Exists(folder.Text) ? folder.Text : null) is { } picked) folder.Text = picked;
        };
        var pattern = dlg.AddText(Strings.FormData_FileNames, FormMergeOptions.DefaultTemplate);
        var named = columns.Where(c => c.Length > 0 && !FormMerge.IsBatchToken(c)).ToList();
        dlg.AddNote(named.Count > 0
                ? Loc.Format(Strings.FormData_PatternNoteColumns, string.Join(", ", named.Take(12).Select(c => $"<<{c}>>")) + (named.Count > 12 ? ", …" : ""))
                : Strings.FormData_PatternNote);
        var flatten = dlg.AddCheck(Strings.FormData_Flatten);
        dlg.Validate(() =>
            string.IsNullOrWhiteSpace(folder.Text) || !Path.IsPathFullyQualified(folder.Text.Trim()) ? Strings.FormData_ChooseFolderForms : FormMerge.ValidateTemplate(pattern.Text, columns));
        if (!dlg.ShowModal()) return;

        var options = new FormMergeOptions { OutputFolder = folder.Text.Trim(), NameTemplate = pattern.Text, Flatten = flatten.IsChecked == true };
        FormMergeReport report;
        using (var progress = new ProgressPrompt(host, Strings.FormData_FillTitle, Strings.FormData_Filling))
        {
            try
            {
                var report1 = new Progress<(int Done, int Total)>(p => progress.Report(Loc.Format(Strings.FormData_RowOf, p.Done, p.Total), (double)p.Done / Math.Max(1, p.Total)));
                report = await Task.Run(() => FormMerge.Run(form, password, csv, formPath, options, report1, progress.Token));
            }
            catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or IOException or UnauthorizedAccessException)
            {
                progress.Dispose();
                Prompt.Error(host, Strings.FormData_CouldntFill, ex.Message);
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
        var dlg = new FormDialog(owner, Strings.FormData_FilledTitle, Strings.Common_Close, 600);
        dlg.HideCancel();
        dlg.AddNote(report.Text + (reportPath is null ? "" : " " + Loc.Format(Strings.FormData_ReportSaved, Path.GetFileName(reportPath))));
        if (report.UnknownColumns.Count > 0)
            dlg.AddNote(Loc.Format(Strings.FormData_ColumnsLeftOut, string.Join(", ", report.UnknownColumns.Take(20)) + (report.UnknownColumns.Count > 20 ? ", …" : "")));
        if (report.Failed.Count > 0)
        {
            var text = string.Join("\n", report.Failed.Take(1000).Select(r => Loc.Format(Strings.FormData_RowProblems, r.Row, string.Join("; ", r.Problems))));
            if (report.Failed.Count > 1000) text += "\n" + Loc.Format(Strings.FormData_AndMore, report.Failed.Count - 1000);
            dlg.Add(Strings.FormData_RowsNotSaved, new System.Windows.Controls.TextBox
            {
                Text = text,
                IsReadOnly = true,
                TextWrapping = TextWrapping.Wrap,
                VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto,
                MaxHeight = 280,
            });
        }
        if (report.Made.Count > 0) dlg.AddFooterButton(Strings.FormData_OpenFolder).Click += (_, _) => Shell.Open(folder);
        dlg.ShowModal();
    }
}
