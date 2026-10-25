using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// The export module through its interface (<see cref="DocumentExport.Export"/>, <see cref="DocumentExport.ExportToFile"/>):
/// which pages are read, recognition of pages without text, and when nothing is saved.
/// </summary>
public sealed class ExportPipelineTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("inkvolt-export-").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    /// <summary>Pages without any text (a scan without its text layer, say).</summary>
    private static byte[] Blank(int pages)
    {
        using var doc = new PdfSharp.Pdf.PdfDocument();
        for (var i = 0; i < pages; i++) doc.AddPage();
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    private static PdfEngine Open(byte[] pdf) => PdfEngine.Open(pdf, InputFileTypes.PDF, null);

    private string[] Files() => [.. Directory.GetFiles(_dir).Select(Path.GetFileName)!];

    [Theory]
    [InlineData(ExportFormat.Word)]
    [InlineData(ExportFormat.Excel)]
    [InlineData(ExportFormat.Text)]
    public void ExportsToAFileWithNothingLeftBehind(ExportFormat format)
    {
        using var engine = Open(ExportTestPdf.Make());
        var path = Path.Combine(_dir, "out" + DocumentExport.Extension(format));
        var report = DocumentExport.ExportToFile(engine, format, path, new ExportOptions { Title = "Sample" });
        Assert.True(report.Saved);
        Assert.Equal(engine.PageCount, report.Pages);
        Assert.Equal(format == ExportFormat.Excel ? 1 : 0, report.Tables);
        Assert.Equal(["out" + DocumentExport.Extension(format)], Files()); // the temporary file is gone
        if (format == ExportFormat.Text)
        {
            var bytes = File.ReadAllBytes(path);
            Assert.Equal(Encoding.UTF8.GetPreamble(), bytes[..3]);
            Assert.StartsWith("Quarterly Report", Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3));
        }
    }

    [Theory]
    [InlineData(ExportFormat.Word)]
    [InlineData(ExportFormat.Excel)]
    [InlineData(ExportFormat.Text)]
    public void NothingExtractedSavesNothing(ExportFormat format)
    {
        using var engine = Open(Blank(2));
        var report = DocumentExport.ExportToFile(engine, format, Path.Combine(_dir, "out" + DocumentExport.Extension(format)));
        Assert.False(report.Saved);
        Assert.Equal(2, report.NoText);
        Assert.Equal(0, report.NoTextWithPictures);
        Assert.Empty(Files());

        // Text but no tables: Excel saves nothing either.
        using var text = Open(TestPdf.Make(1));
        Assert.Equal(format != ExportFormat.Excel, DocumentExport.Export(text, format, new MemoryStream()).Saved);
    }

    [Fact]
    public void PagesWithoutTextAreRecognizedWhenARecognizerIsGiven()
    {
        using var engine = Open(Blank(3));
        var asked = new List<int>();
        var options = new ExportOptions
        {
            Pages = [2, 0],
            Recognize = (_, page, _) =>
            {
                asked.Add(page);
                if (page == 0) throw new InvalidOperationException("no OCR today");
                return [new OcrWord("Recognized", new RectD(72, 72, 120, 14)), new OcrWord("words", new RectD(200, 72, 60, 14))];
            },
        };
        var ms = new MemoryStream();
        var report = DocumentExport.Export(engine, ExportFormat.Text, ms, options);

        Assert.Equal([2, 0], asked);
        Assert.True(report.Saved);
        Assert.Equal(2, report.Pages);
        Assert.Equal(1, report.Recognized);
        Assert.Equal(1, report.NoText);
        Assert.Equal(new ExportProblem(0, "no OCR today"), Assert.Single(report.RecognitionFailed));
        Assert.Contains("Recognized words", Encoding.UTF8.GetString(ms.ToArray()));

        // Without a recognizer the same pages have no text: nothing to save.
        Assert.False(DocumentExport.Export(engine, ExportFormat.Text, new MemoryStream(), options with { Recognize = null }).Saved);
    }

    [Fact]
    public void ReportsProgressPageByPageThenWriting()
    {
        using var engine = Open(TestPdf.Make(3));
        var seen = new List<ExportProgress>();
        DocumentExport.Export(engine, ExportFormat.Text, new MemoryStream(), new ExportOptions { Pages = [1, 2], Progress = seen.Add });
        Assert.Equal(
            [new(ExportStage.Reading, 1, 0, 2), new(ExportStage.Reading, 2, 1, 2), new ExportProgress(ExportStage.Writing, -1, 2, 2)],
            seen);
        Assert.Equal(0.5, seen[1].Fraction);
    }

    [Fact]
    public void ACancelledExportLeavesNothing()
    {
        using var engine = Open(TestPdf.Make(2));
        using var cancel = new CancellationTokenSource();
        var options = new ExportOptions { Progress = p => { if (p.Index == 1) cancel.Cancel(); } };
        Assert.ThrowsAny<OperationCanceledException>(() =>
            DocumentExport.ExportToFile(engine, ExportFormat.Word, Path.Combine(_dir, "out.docx"), options, cancel.Token));
        Assert.Empty(Files());
    }
}
