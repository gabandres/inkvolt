using System.IO;
using System.Text;
using System.Windows;
using InkvoltPdf.Core;
using Microsoft.Win32;

namespace InkvoltPdf.App;

/// <summary>
/// File › Export: Word (.docx), Excel (.xlsx, the tables found) and plain text (.txt), rebuilt from the pages' text,
/// fonts, pictures and lines (see <see cref="DocLayout"/>). Scanned pages without a text layer are recognized with
/// Windows' OCR first, when the user leaves that on. Everything runs on this PC.
/// </summary>
internal static class ExportActions
{
    public enum Format { Word, Excel, Text }

    private sealed record Kind(string Title, string Extension, string Filter, string Note);

    private static Kind Describe(Format format) => format switch
    {
        Format.Word => new("Export to Word", ".docx", "Word document (*.docx)|*.docx",
            "Paragraphs, headings, lists, tables, pictures, running headers and footers and page sizes are rebuilt from the page layout, so the document can be edited; complex layouts may need tidying."),
        Format.Excel => new("Export Tables to Excel", ".xlsx", "Excel workbook (*.xlsx)|*.xlsx",
            "Each table found (ruled grids, or text lined up in columns) becomes a sheet, named after its page. Plain numbers become numbers; other values stay text as shown."),
        _ => new("Export as Plain Text", ".txt", "Text file (*.txt)|*.txt",
            "The text in reading order (columns one after another), a paragraph per line, table rows as tab-separated cells. UTF-8."),
    };

    public static async Task Export(Window owner, DocumentTab tab, MainWindow host, Format format)
    {
        if (!await tab.SettleAsync()) return;
        var kind = Describe(format);
        var ocr = PageOcr.Engine;
        var dlg = new FormDialog(owner, kind.Title, "Export…", 480);
        var range = dlg.AddRange(tab, preferSelection: false);
        var useOcr = dlg.AddCheck("Recognize text on scanned pages (OCR)", ocr is not null && AppSettings.Current.ExportOcr);
        useOcr.Margin = new Thickness(0, 14, 0, 0);
        if (ocr is null)
        {
            useOcr.IsEnabled = false;
            System.Windows.Automation.AutomationProperties.SetHelpText(useOcr, PageOcr.Unavailable);
            dlg.AddNote(PageOcr.Unavailable);
        }
        var open = dlg.AddCheck("Open the file when done", AppSettings.Current.ExportOpen);
        dlg.AddNote(kind.Note + (ocr is null ? "" : $" Text recognition uses Windows' {ocr.RecognizerLanguage.DisplayName} OCR; check important text."));
        int[] pages = [];
        dlg.Validate(() => range.TryGet(out pages, out var err) ? null : err);
        if (!dlg.ShowModal() || !await tab.SettleAsync()) return;
        pages = [.. pages.Where(p => p < tab.PageView.PageCount)];
        if (pages.Length == 0) return;
        if (!Organize.ConfirmUnprotected(owner, tab, "The exported file is saved without its password protection: anyone can open it.", "Export anyway")) return;
        var recognize = ocr is not null && useOcr.IsChecked == true;
        AppSettings.Current.ExportOpen = open.IsChecked == true;
        if (ocr is not null) AppSettings.Current.ExportOcr = recognize;

        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);
        var folder = Path.GetDirectoryName(tab.Session.FilePath) ?? AppSettings.Current.LastFolder;
        if (PickPath(owner, kind, name + kind.Extension, folder) is not { } path) return;
        AppSettings.Current.Save();

        // Busy from here, so nothing replaces the engine this export reads.
        using var busy = tab.BeginBusy($"Exporting {Pages(pages.Length)}…");
        var engine = tab.ViewEngine; // what is shown (chosen layers included)
        using var progress = new ProgressPrompt(owner, kind.Title, "Reading the pages…");
        var cancel = progress.Token;
        int recognized = 0, noText = 0, withPictures = 0, unreadable = 0, ocrFailed = 0, tables = 0;
        var images = format == Format.Word;

        IEnumerable<(int Number, ExportPage Page)> Read()
        {
            for (var i = 0; i < pages.Length; i++)
            {
                cancel.ThrowIfCancellationRequested();
                var p = pages[i];
                progress.Report($"Reading page {p + 1} ({i + 1} of {pages.Length})…", (double)i / pages.Length);
                ExportPage page;
                var readable = true;
                try
                {
                    page = engine.GetExportPage(p, images, cancel);
                }
                catch (MuPDFCore.MuPDFException ex)
                {
                    // A damaged page: export the rest (it stays empty, and the status says so).
                    Log.Write($"Export: page {p + 1} can't be read: {ex.Message}");
                    unreadable++;
                    readable = false;
                    var g = engine.GetPage(p);
                    page = new ExportPage(g.Width, g.Height, [], [], []);
                }
                if (readable && !page.HasText && recognize)
                {
                    progress.Report($"Recognizing text on page {p + 1} ({i + 1} of {pages.Length})…", (double)i / pages.Length);
                    try
                    {
                        var words = PageOcr.Recognize(ocr!, engine, p, cancel);
                        if (words.Count > 0)
                        {
                            page = page with { Lines = ExportPage.LinesFromOcr(words), FromOcr = true };
                            recognized++;
                        }
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        // Rendering or the OCR engine failed on this page: go on without its text.
                        Log.Write($"Export: text recognition failed on page {p + 1}: {ex.Message}");
                        ocrFailed++;
                    }
                }
                if (!page.HasText)
                {
                    noText++;
                    if (page.Images.Count > 0) withPictures++;
                }
                yield return (p + 1, page);
            }
            progress.Report("Writing the file…", 1);
        }

        try
        {
            // Nothing is saved when nothing was extracted: no text at all (and, for Word, no pictures either) or no tables.
            var written = await Task.Run(() =>
            {
                switch (format)
                {
                    case Format.Word:
                        return WriteVia(path, s =>
                        {
                            DocumentExport.WriteDocx(s, Read().Select(x => x.Page), name);
                            return noText < pages.Length || withPictures > 0;
                        }, cancel);
                    case Format.Excel:
                    {
                        var found = DocumentExport.Tables(Read());
                        tables = found.Count;
                        return found.Count > 0 && WriteVia(path, s =>
                        {
                            XlsxWriter.Write(s, found, name);
                            return true;
                        }, cancel);
                    }
                    default:
                    {
                        var text = DocumentExport.PlainText(Read().Select(x => x.Page));
                        return noText < pages.Length && WriteVia(path, s =>
                        {
                            s.Write([.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes(text)]);
                            return true;
                        }, cancel);
                    }
                }
            }, cancel);
            progress.Dispose();
            if (!written)
            {
                var these = pages.Length == 1 ? "this page" : "these pages";
                var why = "";
                if (noText > 0)
                {
                    why = noText == pages.Length ? (pages.Length == 1 ? " The page has no text" : " None of the pages has text") : $" {Pages(noText)} had no text";
                    why += recognize ? (ocrFailed > 0 ? "; text recognition failed on some of them." : ", even after text recognition.")
                        : ocr is null ? ", and Windows has no text recognition (OCR) language installed."
                        : ": turn on \"Recognize text on scanned pages\" to read scans.";
                }
                if (format == Format.Excel)
                    Prompt.Info(owner, "No tables found", $"No tables were found on {these}, so no workbook was saved. Tables are found from ruled grids, or from text lined up in columns over three rows or more.{why}");
                else
                    Prompt.Info(owner, "No text found", $"Nothing could be extracted from {these}, so no file was saved.{why}");
                return;
            }
            var notes = new List<string>();
            if (recognized > 0) notes.Add($"{Pages(recognized)} recognized with OCR");
            if (noText > 0) notes.Add($"{Pages(noText)} without text{(format == Format.Word && withPictures > 0 ? " (pictures kept)" : "")}");
            if (ocrFailed > 0) notes.Add($"text recognition failed on {Pages(ocrFailed)}");
            if (unreadable > 0) notes.Add($"{Pages(unreadable)} couldn't be read and {(unreadable == 1 ? "is" : "are")} empty");
            if (format == Format.Excel) notes.Insert(0, tables == 1 ? "1 table" : $"{tables} tables");
            Log.Write($"Export {format}: {pages.Length} page(s) to {Log.Name(path)}{(notes.Count > 0 ? "; " + string.Join("; ", notes) : "")}");
            host.ShowStatus($"Exported {Pages(pages.Length)} to {Path.GetFileName(path)}{(notes.Count > 0 ? $" ({string.Join(", ", notes)})" : "")}.");
            if (open.IsChecked == true) Shell.Open(path);
        }
        catch (OperationCanceledException)
        {
            Log.Write($"Export {format} cancelled");
            host.ShowStatus("Export cancelled. Nothing was saved.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Export {format} failed: {ex.Message}");
            Prompt.Error(owner, "Can't save the export", $"{ex.Message}\n\nIf the file is open in another program, close it there or choose another name.");
        }
        catch (Exception ex)
        {
            Log.Write($"Export {format} failed: {ex}");
            Prompt.Error(owner, "Export failed", ex.Message);
        }
    }

    private static string Pages(int n) => n == 1 ? "1 page" : $"{n} pages";

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

    /// <summary>
    /// Writes through a temporary file in the same folder, swapped in at the end, so a failed or cancelled export leaves
    /// nothing half-written. <paramref name="write"/> returns false to keep nothing (the export found nothing to save).
    /// </summary>
    private static bool WriteVia(string path, Func<Stream, bool> write, CancellationToken cancel)
    {
        var full = Path.GetFullPath(path);
        var tmp = Path.Combine(Path.GetDirectoryName(full)!, $"~inkvoltpdf-{Guid.NewGuid():N}.tmp");
        try
        {
            bool keep;
            using (var fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                keep = write(fs);
                fs.Flush(flushToDisk: true);
            }
            cancel.ThrowIfCancellationRequested();
            if (!keep)
            {
                File.Delete(tmp);
                return false;
            }
            File.Move(tmp, full, overwrite: true);
            return true;
        }
        catch
        {
            try { File.Delete(tmp); } catch (Exception) { }
            throw;
        }
    }
}
