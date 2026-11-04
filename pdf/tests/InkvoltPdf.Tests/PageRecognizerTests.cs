using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>A page recognizer: the pages without text read into words for a text layer, as its options say, through a stand-in recognizer.</summary>
public sealed class PageRecognizerTests
{
    private const string Font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>";

    /// <summary>Page 1 has text of its own; pages 2 and 3 are blank, as a scan's page is to the text search.</summary>
    private static byte[] TextThenBlanks() => Core2Pdf.Build(
    [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 6 0 R 7 0 R] /Count 3 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        Core2Pdf.Stream("BT /F1 14 Tf 72 700 Td (A page with its own text) Tj ET"),
        Font,
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
    ]);

    /// <summary>Pixels of the page as read at 300 dpi.</summary>
    private static RectD Px(double x, double y, double w, double h) => new(x * 300 / 72, y * 300 / 72, w * 300 / 72, h * 300 / 72);

    private static string Text(byte[] pdf, int page)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return engine.GetText(page).Text;
    }

    [Fact]
    public void OnlyThePagesWithoutTextAreReadAndTheirLayerIsWritten()
    {
        var data = TextThenBlanks();
        var reader = new WordsReader(("Hello", Px(72, 72, 60, 14)), ("world", Px(140, 72, 60, 14)));
        var steps = new List<(int, int)>();
        var read = new PageRecognizer(reader, RecognizeOptions.AsScanned).Recognize(data, null, progress: new DirectProgress<(int Done, int Total)>(steps.Add));

        Assert.Equal(1, read.HadText);
        Assert.Equal([1, 2], read.Words.Keys.Order());
        Assert.Equal(4, read.WordCount);
        Assert.Equal(0, read.SuspectCount);
        Assert.Equal(2, reader.Calls); // as scanned: one reading a page
        Assert.Equal([(0, 3), (1, 3), (2, 3)], steps);

        var written = read.Write(data, null);
        Assert.Contains("Hello", Text(written, 1));
        Assert.Contains("world", Text(written, 2));
        Assert.Equal("A page with its own text", Text(written, 0).Trim());
        Assert.Equal("en-US", TextLayer.Words(written, null)[1].Language);
    }

    [Fact]
    public void AWordUnderABlackBoxIsntKeptNorALetterTouchingOne()
    {
        var data = TextThenBlanks();
        var reader = new WordsReader(("Secret", Px(30, 30, 80, 14)), ("ok", Px(118, 30, 12, 14)), ("Visible", Px(30, 300, 80, 14)));
        var box = new Dictionary<int, IReadOnlyList<RectD>> { [1] = [new RectD(20, 20, 100, 30)] };
        var read = new PageRecognizer(reader, RecognizeOptions.AsScanned).Recognize(data, null, [1], box);
        Assert.Equal(["Visible"], read.Words[1].Select(w => w.Text));
    }

    [Fact]
    public void ItReadsAsItsOptionsSay()
    {
        var data = TextThenBlanks();
        var asScanned = new WordsReader(("Recognized", Px(72, 72, 80, 14)));
        new PageRecognizer(asScanned, RecognizeOptions.AsScanned).Recognize(data, null, [1]);
        Assert.Equal([3], asScanned.Channels); // the page as rendered

        var cleaned = new WordsReader(("Recognized", Px(72, 72, 80, 14)), ("rivr", Px(160, 72, 40, 14)));
        var read = new PageRecognizer(cleaned, new RecognizeOptions(), new WordsReader.Dictionary("Recognized")).Recognize(data, null, [1]);
        Assert.Contains(1, cleaned.Channels); // cleaned: grey
        Assert.Equal(1, read.SuspectCount); // and suspect words marked, with its dictionary
        Assert.Equal(SuspectReasons.NotInDictionary, read.Words[1].Single(w => w.IsSuspect).Suspect);
    }

    [Fact]
    public void CancellingStopsIt()
    {
        using var cts = new CancellationTokenSource();
        var reader = new WordsReader { OnRead = _ => cts.Cancel() };
        Assert.ThrowsAny<OperationCanceledException>(() => new PageRecognizer(reader, RecognizeOptions.AsScanned).Recognize(TextThenBlanks(), null, cancel: cts.Token));
        Assert.Equal(1, reader.Calls);
    }

    [Fact]
    public void RedactedPagesGetTheirTextBackUnlessThatIsSkipped()
    {
        var data = TextThenBlanks();
        var areas = new Dictionary<int, IReadOnlyList<RectD>> { [0] = [new RectD(70, 85, 200, 20)] };
        var reader = new WordsReader(("Left", Px(72, 300, 60, 14)));
        var redacted = Redaction.ApplyWithText(data, null, areas, reader);
        Assert.False(redacted.TextSkipped);
        Assert.Equal("Left", Text(redacted.Data, 0).Trim());

        using var cts = new CancellationTokenSource();
        var skipped = Redaction.ApplyWithText(data, null, areas, new WordsReader { OnRead = t => { cts.Cancel(); t.ThrowIfCancellationRequested(); } }, skipText: cts.Token);
        Assert.True(skipped.TextSkipped);
        Assert.Equal("", Text(skipped.Data, 0).Trim()); // redacted all the same
        Assert.Equal("", Text(Redaction.ApplyWithText(data, null, areas, null).Data, 0).Trim());
    }
}
