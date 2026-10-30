using System.Text;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>What <see cref="DocumentExport"/> makes: a Word document, an Excel workbook of the tables found, plain text, a PowerPoint presentation or a web page.</summary>
public enum ExportFormat { Word, Excel, Text, PowerPoint, Html }

public enum ExportStage { Reading, Recognizing, Writing }

/// <summary>Where an export is (<see cref="ExportOptions.Progress"/>).</summary>
/// <param name="Page">The page being read or recognized (0-based; -1 while writing).</param>
/// <param name="Index">How many pages were read before it.</param>
public readonly record struct ExportProgress(ExportStage Stage, int Page, int Index, int Count)
{
    public double Fraction => Count == 0 ? 1 : (double)Index / Count;
}

/// <summary>How to export (see <see cref="DocumentExport.Export"/>).</summary>
public sealed record ExportOptions
{
    /// <summary>The pages to export (0-based, in this order); null exports every page.</summary>
    public IReadOnlyList<int>? Pages { get; init; }

    /// <summary>The document's title in the Word and Excel file.</summary>
    public string? Title { get; init; }

    /// <summary>
    /// Text recognition for pages without text (scans): the words on a page of the engine. Null reads only the text the
    /// pages have. The app passes Windows' OCR.
    /// </summary>
    public Func<PdfEngine, int, CancellationToken, IReadOnlyList<OcrWord>>? Recognize { get; init; }

    /// <summary>Called as each page is read or recognized, and once before the file is written (on the exporting thread).</summary>
    public Action<ExportProgress>? Progress { get; init; }

    /// <summary>The PDF itself, for PowerPoint and HTML to read its language and its figures' alternate text; null goes without them.</summary>
    public byte[]? Source { get; init; }

    /// <summary>The password that opens <see cref="Source"/>.</summary>
    public string? SourcePassword { get; init; }
}

/// <summary>A page an export couldn't read, or couldn't recognize (0-based), and why.</summary>
public readonly record struct ExportProblem(int Page, string Message);

/// <summary>What an export did.</summary>
/// <param name="Saved">
/// False when nothing was extracted, so there is nothing to save: no text at all (and, for Word, PowerPoint and HTML, no
/// pictures either, and for PowerPoint no shapes), or, for Excel, no tables.
/// </param>
/// <param name="Pages">Pages exported.</param>
/// <param name="Recognized">Pages whose text came from <see cref="ExportOptions.Recognize"/>.</param>
/// <param name="NoText">Pages without text (after recognition).</param>
/// <param name="NoTextWithPictures">Of those, pages with pictures (Word, PowerPoint and HTML keep them).</param>
/// <param name="Tables">Excel: the tables found (one sheet each).</param>
/// <param name="Unreadable">Damaged pages: exported empty.</param>
/// <param name="RecognitionFailed">Pages whose recognition failed: exported without text.</param>
public sealed record ExportReport(bool Saved, int Pages, int Recognized, int NoText, int NoTextWithPictures, int Tables,
    IReadOnlyList<ExportProblem> Unreadable, IReadOnlyList<ExportProblem> RecognitionFailed);

/// <summary>
/// Export to Word, Excel, plain text, PowerPoint and HTML. <see cref="Export"/> (to a stream) and <see cref="ExportToFile"/> read the pages
/// (a damaged page exports empty; a page without text is recognized when the caller gives a recognizer), lay out the
/// document and write the format, or report that there was nothing to save. Pages come in one at a time; each format
/// lays the whole document out once all pages are in (body size and heading levels are document-wide).
/// </summary>
public static class DocumentExport
{
    /// <summary>The file extension of <paramref name="format"/> (".docx", ".xlsx", ".txt", ".pptx", ".html").</summary>
    public static string Extension(ExportFormat format) => format switch
    {
        ExportFormat.Word => ".docx",
        ExportFormat.Excel => ".xlsx",
        ExportFormat.PowerPoint => ".pptx",
        ExportFormat.Html => ".html",
        _ => ".txt",
    };

    /// <summary>
    /// Exports the pages of <paramref name="engine"/> to <paramref name="output"/>. When the report says nothing was
    /// <see cref="ExportReport.Saved"/>, discard the output: Excel and text wrote nothing, the others may have written part
    /// of a file. <see cref="ExportToFile"/> handles that.
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    public static ExportReport Export(PdfEngine engine, ExportFormat format, Stream output, ExportOptions? options = null, CancellationToken cancel = default)
    {
        options ??= new ExportOptions();
        var pages = options.Pages ?? [.. Enumerable.Range(0, engine.PageCount)];
        var tags = format is ExportFormat.PowerPoint or ExportFormat.Html ? ExportTags.Read(options.Source, options.SourcePassword) : ExportTags.None;
        var run = new Run(engine, pages, format is ExportFormat.Word or ExportFormat.PowerPoint or ExportFormat.Html, format == ExportFormat.PowerPoint, tags, options, cancel);
        var tables = 0;
        bool saved;
        switch (format)
        {
            case ExportFormat.Word:
                WriteDocx(output, run.Read().Select(x => x.Page), options.Title);
                saved = run.NoText < pages.Count || run.NoTextWithPictures > 0;
                break;
            case ExportFormat.PowerPoint:
                WritePptx(output, run.Read().Select(x => x.Page), options.Title, tags.Language);
                saved = run.NoText < pages.Count || run.NoTextWithPictures > 0 || run.WithShapes > 0;
                break;
            case ExportFormat.Html:
                WriteHtml(output, run.Read().Select(x => x.Page), options.Title, tags.Language);
                saved = run.NoText < pages.Count || run.NoTextWithPictures > 0;
                break;
            case ExportFormat.Excel:
            {
                var found = Tables(run.Read());
                tables = found.Count;
                saved = found.Count > 0;
                if (saved) XlsxWriter.Write(output, found, options.Title);
                break;
            }
            default:
            {
                var text = PlainText(run.Read().Select(x => x.Page));
                saved = run.NoText < pages.Count;
                if (saved) output.Write([.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes(text)]);
                break;
            }
        }
        return new ExportReport(saved, pages.Count, run.Recognized, run.NoText, run.NoTextWithPictures, tables, run.Unreadable, run.RecognitionFailed);
    }

    /// <summary>
    /// <see cref="Export"/> to <paramref name="path"/>, through a temporary file in the same folder that is swapped in at the
    /// end: a failed or cancelled export, or one with nothing to save, leaves the folder as it was.
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    /// <exception cref="IOException">The file can't be written (open in another program, say).</exception>
    public static ExportReport ExportToFile(PdfEngine engine, ExportFormat format, string path, ExportOptions? options = null, CancellationToken cancel = default)
    {
        var full = Path.GetFullPath(path);
        var tmp = Path.Combine(Path.GetDirectoryName(full)!, $"~inkvoltpdf-{Guid.NewGuid():N}.tmp");
        try
        {
            ExportReport report;
            using (var fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                report = Export(engine, format, fs, options, cancel);
                fs.Flush(flushToDisk: true);
            }
            cancel.ThrowIfCancellationRequested();
            if (report.Saved) File.Move(tmp, full, overwrite: true);
            else File.Delete(tmp);
            return report;
        }
        catch
        {
            try { File.Delete(tmp); } catch (Exception) { }
            throw;
        }
    }

    /// <summary>Reads the pages one at a time (lazily: Word stores each page's pictures as it arrives), counting as it goes.</summary>
    private sealed class Run(PdfEngine engine, IReadOnlyList<int> pages, bool images, bool shapes, ExportTags tags, ExportOptions options, CancellationToken cancel)
    {
        public int Recognized, NoText, NoTextWithPictures, WithShapes;
        public readonly List<ExportProblem> Unreadable = [], RecognitionFailed = [];

        public IEnumerable<(int Number, ExportPage Page)> Read()
        {
            for (var i = 0; i < pages.Count; i++)
            {
                cancel.ThrowIfCancellationRequested();
                var p = pages[i];
                options.Progress?.Invoke(new ExportProgress(ExportStage.Reading, p, i, pages.Count));
                ExportPage page;
                var readable = true;
                try
                {
                    page = tags.OnPictures(engine.GetExportPage(p, images, cancel, shapes: shapes), p);
                }
                catch (MuPDFException ex)
                {
                    // A damaged page: export the rest (it stays empty, and the report says so).
                    Unreadable.Add(new ExportProblem(p, ex.Message));
                    readable = false;
                    var g = engine.GetPage(p);
                    page = new ExportPage(g.Width, g.Height, [], [], []);
                }
                if (readable && !page.HasText && options.Recognize is { } recognize)
                {
                    options.Progress?.Invoke(new ExportProgress(ExportStage.Recognizing, p, i, pages.Count));
                    try
                    {
                        var words = recognize(engine, p, cancel);
                        if (words.Count > 0)
                        {
                            page = page with { Lines = ExportPage.LinesFromOcr(words), FromOcr = true };
                            Recognized++;
                        }
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        // Rendering or the recognizer failed on this page: go on without its text.
                        RecognitionFailed.Add(new ExportProblem(p, ex.Message));
                    }
                }
                if (!page.HasText)
                {
                    NoText++;
                    if (page.Images.Count > 0) NoTextWithPictures++;
                }
                if (page.Shapes.Count > 0) WithShapes++;
                yield return (p + 1, page);
            }
            options.Progress?.Invoke(new ExportProgress(ExportStage.Writing, -1, pages.Count, pages.Count));
        }
    }

    /// <summary>Writes a .docx. Pictures are stored as each page arrives; only the text is kept until the end.</summary>
    internal static void WriteDocx(Stream output, IEnumerable<ExportPage> pages, string? title)
    {
        using var writer = new DocxWriter(output);
        var kept = new List<ExportPage>();
        foreach (var page in pages)
            kept.Add(page.Images.Count == 0 ? page : page with
            {
                Images = [.. page.Images.Where(i => DocLayout.Keeps(page, i)).Select(i => i with { Data = [], Ref = writer.AddImage(i.Data, i.Extension) })],
            });
        writer.Finish(DocLayout.AnalyzeDocument(kept), title);
    }

    /// <summary>Writes a .pptx, one slide per page. Pictures are stored as each page arrives; only the rest is kept until the end.</summary>
    internal static void WritePptx(Stream output, IEnumerable<ExportPage> pages, string? title, string? language)
    {
        using var writer = new PptxWriter(output);
        var kept = new List<ExportPage>();
        foreach (var page in pages)
            kept.Add(page.Images.Count == 0 ? page : page with
            {
                Images = [.. page.Images.Where(i => DocLayout.Keeps(page, i) && i.Data.Length > 0).Select(i => i with { Data = [], Ref = writer.AddImage(i.Data, i.Extension) })],
            });
        writer.Finish(DocLayout.AnalyzeSlides(kept), title, language ?? GuessLanguage(kept));
    }

    /// <summary>Writes one .html. Its pictures are inside it, so they are kept until the end.</summary>
    internal static void WriteHtml(Stream output, IEnumerable<ExportPage> pages, string? title, string? language)
    {
        var list = pages.ToList();
        HtmlWriter.Write(output, DocLayout.AnalyzeDocument(list), title, language ?? GuessLanguage(list));
    }

    /// <summary>The language the words look like, when they say so.</summary>
    private static string? GuessLanguage(IReadOnlyList<ExportPage> pages) =>
        AutoTag.Language.Guess(string.Join(' ', pages.SelectMany(p => p.Lines).Take(2000).Select(l => l.Text)));

    /// <summary>The tables found on the pages, named after their page ("Page 3", "Page 3 (2)"); page numbers are 1-based.</summary>
    internal static List<(string Name, DocTable Table)> Tables(IEnumerable<(int PageNumber, ExportPage Page)> pages)
    {
        var list = pages.Select(p => (p.PageNumber, Page: p.Page.WithoutImages())).ToList();
        var laid = DocLayout.Analyze([.. list.Select(p => p.Page)]);
        var tables = new List<(string, DocTable)>();
        for (var i = 0; i < laid.Count; i++)
        {
            var onPage = laid[i].Blocks.OfType<DocTable>().ToList();
            for (var k = 0; k < onPage.Count; k++)
                tables.Add((k == 0 ? $"Page {list[i].PageNumber}" : $"Page {list[i].PageNumber} ({k + 1})", onPage[k]));
        }
        return tables;
    }

    /// <summary>
    /// Plain text in reading order: one paragraph per line with a blank line between paragraphs, table rows as
    /// tab-separated cells, list items with a bullet ("• ").
    /// </summary>
    internal static string PlainText(IEnumerable<ExportPage> pages)
    {
        var laid = DocLayout.Analyze([.. pages.Select(p => p.WithoutImages())]);
        var sb = new StringBuilder();
        foreach (var page in laid)
        {
            foreach (var block in page.Blocks)
            {
                switch (block)
                {
                    case DocParagraph p:
                        if (p.List == ListKind.Bullet) sb.Append("• ");
                        sb.Append(OneLine(p.Text)).Append("\r\n\r\n");
                        break;
                    case DocTable t:
                        foreach (var row in t.Rows)
                        {
                            var cells = new List<string>();
                            foreach (var cell in row)
                            {
                                cells.Add(OneLine(cell.Text));
                                for (var k = 1; k < cell.ColSpan; k++) cells.Add("");
                            }
                            sb.Append(string.Join('\t', cells).TrimEnd('\t')).Append("\r\n");
                        }
                        sb.Append("\r\n");
                        break;
                }
            }
        }
        return sb.ToString().TrimEnd() + "\r\n";

        static string OneLine(string s) => s.Replace("\r", " ").Replace('\n', ' ').Replace('\t', ' ');
    }
}
