using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using Inkvolt.Testing;
using InkvoltPdf.Bench;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Page checks (<see cref="PageChecks"/>): MuPDF's own inflating, bounded by time. A page is first drawn in a check
/// process (the bench tool, which takes the app's switch) and refused if that takes past the limit; the rest of the
/// document draws, reads and searches as before. Timed, so alone.
/// </summary>
[Collection(Timing.Alone)]
public sealed class PageCheckTests : IDisposable
{
    private static string CheckExe => Path.Combine(AppContext.BaseDirectory, "Bench.exe");

    /// <summary>Short, so the bombs give up quickly here; the app's is <see cref="PageChecks.Limit"/>.</summary>
    private static readonly TimeSpan Limit = TimeSpan.FromSeconds(3);

    /// <summary>What a refusal may take past the limit: starting the check process and opening the document in it.</summary>
    private static readonly TimeSpan Slack = TimeSpan.FromSeconds(5);

    private readonly PageCheckPlan _plan = new(CheckExe, []) { Limit = Limit };

    public void Dispose() => _plan.Dispose();

    private static byte[] Zlib(byte[] head, long zeros)
    {
        using var output = new MemoryStream();
        using (var z = new ZLibStream(output, CompressionLevel.Optimal, leaveOpen: true))
        {
            z.Write(head);
            var chunk = new byte[1 << 20];
            for (var left = zeros; left > 0; left -= chunk.Length) z.Write(chunk, 0, (int)Math.Min(chunk.Length, left));
        }
        return output.ToArray();
    }

    private static readonly byte[] Drawn = Encoding.ASCII.GetBytes("BT /F1 12 Tf 72 600 Td (Hidden) Tj ET ");

    /// <summary>About 4 KB that inflate twice to 4 GB: MuPDF took 116 s of one core to draw its page, memory flat.</summary>
    private static readonly Lazy<byte[]> TwiceTo4Gb = new(() => Zlib(Zlib(Drawn, 4L << 30), 0));

    /// <summary>About 1 MB that inflates once to 1 GB: 12 s a draw.</summary>
    private static readonly Lazy<byte[]> OnceTo1Gb = new(() => Zlib(Drawn, 1L << 30));

    /// <summary>
    /// Three pages that each draw "Visit notes"; the second has <paramref name="packed"/> as a second content stream with
    /// <paramref name="dict"/>.
    /// </summary>
    private static byte[] ThreePages(byte[] packed, string dict) => Core2Pdf.Build([
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents [6 0 R 8 0 R] /Resources << /Font << /F1 7 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
        Core2Pdf.Stream("BT /F1 18 Tf 72 700 Td (Visit notes) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        Core2Pdf.Stream(Encoding.Latin1.GetString(packed), dict),
    ]);

    /// <summary>A page drawing <paramref name="picture"/> (its dictionary <paramref name="dict"/>) over most of it.</summary>
    private static byte[] Picture(byte[] picture, string dict) => Core2Pdf.Build([
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Im 5 0 R >> >> >>",
        Core2Pdf.Stream("q 500 0 0 500 50 150 cm /Im Do Q"),
        Core2Pdf.Stream(Encoding.Latin1.GetString(picture), dict),
    ]);

    private PdfEngine Open(byte[] file)
    {
        var engine = PdfEngine.Open(file, InputFileTypes.PDF, null);
        engine.CheckPlan = _plan;
        return engine;
    }

    public static TheoryData<string> Bombs => ["7 KB, Flate twice to 4 GB", "1 MB, Flate once to 1 GB"];

    private static byte[] Bomb(string name) => name.StartsWith("7 KB")
        ? ThreePages(TwiceTo4Gb.Value, "/Filter [/FlateDecode /FlateDecode]")
        : ThreePages(OnceTo1Gb.Value, "/Filter /FlateDecode");

    [Theory]
    [MemberData(nameof(Bombs))]
    public void AFlateBombsPageIsRefusedWithinTheLimitAndTheRestOfTheDocumentWorks(string name)
    {
        var file = Bomb(name);
        Assert.True(file.Length < (name.StartsWith("7 KB") ? 8 << 10 : (1 << 20) + (64 << 10)), $"{file.Length} bytes");
        using var engine = Open(file);

        var time = Stopwatch.StartNew();
        var refused = Assert.Throws<PageRefusedException>(() => engine.Render(1, 0.5));
        Assert.True(time.Elapsed < Timing.Limit(Limit + Slack), $"{name}: refused after {time.Elapsed}");
        Assert.True(refused.TooSlow);
        Assert.Equal(1, refused.Page);
        Assert.Contains("2", refused.Message); // the page number, as the user counts

        // Refused at once from then on, for its text too; the check process that read it is gone.
        time.Restart();
        Assert.Throws<PageRefusedException>(() => engine.Render(1, 2));
        Assert.Throws<PageRefusedException>(() => engine.GetText(1));
        Assert.Throws<PageRefusedException>(() => engine.GetExportPage(1, images: true));
        Assert.True(time.Elapsed < TimeSpan.FromSeconds(1), $"{time.Elapsed}");
        Assert.Contains(_plan.Pids, pid => Exited(pid));

        // The other pages draw and read.
        foreach (var page in new[] { 0, 2 })
        {
            Assert.True(engine.Render(page, 0.5).Pixels.Any(b => b < 128), $"page {page + 1} drew nothing");
            Assert.Contains("Visit notes", engine.GetText(page).Text);
        }
    }

    [Fact]
    public void FindOverADocumentWithABombFinishes()
    {
        using var engine = Open(Bomb("7 KB"));
        var time = Stopwatch.StartNew();
        var pages = engine.FindAll("Visit notes", matchCase: false, wholeWord: false).ToList();
        Assert.True(time.Elapsed < Timing.Limit(Limit + Slack), $"{time.Elapsed}");
        Assert.Equal([0, 1, 2], pages.Select(p => p.Page));
        Assert.Single(pages[0].Hits);
        Assert.IsType<PageRefusedException>(pages[1].Error);
        Assert.Single(pages[2].Hits);

        // Searched again: the refused page isn't asked about twice.
        time.Restart();
        Assert.Equal(2, engine.FindAll("notes", false, false).Sum(p => p.Hits.Count));
        Assert.True(time.Elapsed < TimeSpan.FromSeconds(2), $"{time.Elapsed}");
    }

    [Fact]
    public void APictureThatInflatesForSecondsIsRefusedAndOneMuPdfStopsAtItsSizeDraws()
    {
        // 20,000 x 20,000 RGB is 1.2 GB of samples: MuPDF inflates all of them for every draw, whatever the zoom (9 s a
        // draw here), and doesn't look at the render's cookie while it does. 1.2 MB of file; inflating twice, 1.2 KB.
        const long samples = 20_000L * 20_000 * 3;
        var bomb = Picture(Zlib([], samples), "/Type /XObject /Subtype /Image /Width 20000 /Height 20000 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode");
        Assert.True(bomb.Length < 2 << 20, $"{bomb.Length} bytes");
        using (var engine = Open(bomb))
        {
            var time = Stopwatch.StartNew();
            Assert.Throws<PageRefusedException>(() => engine.Render(0, 0.25));
            Assert.True(time.Elapsed < Timing.Limit(Limit + Slack), $"{time.Elapsed}");
        }

        // A picture of 10 x 10 whose data inflates to 1 GB: MuPDF reads no more than its size says (milliseconds).
        var small = Picture(OnceTo1Gb.Value, "/Type /XObject /Subtype /Image /Width 10 /Height 10 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode");
        using (var engine = Open(small))
        {
            engine.Render(0, 0.25);
            Assert.Equal(PageVerdict.Fine, engine.VerdictOf(0));
        }
    }

    [Fact]
    public void AJpegIsCheckedAtItsFullSizeNotTheSizeTheCheckDrawsItAt()
    {
        // A JPEG whose header says 30,000 x 30,000: MuPDF decodes it at an eighth of that for the check's 64 pixels
        // (milliseconds), but at its full 900 million pixels for an export or a deep zoom here.
        var jpeg = JpegEncoder.EncodeGray(new byte[16 * 16], 16, 16, 75, 72);
        var sof = jpeg.AsSpan().IndexOf([(byte)0xFF, (byte)0xC0]);
        Assert.True(sof > 0);
        jpeg[sof + 5] = jpeg[sof + 7] = 30_000 >> 8;
        jpeg[sof + 6] = jpeg[sof + 8] = 30_000 & 0xFF;
        using (var engine = Open(Picture(jpeg, "/Type /XObject /Subtype /Image /Width 30000 /Height 30000 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /DCTDecode")))
        {
            var time = Stopwatch.StartNew();
            Assert.Throws<PageRefusedException>(() => engine.Render(0, 0.25));
            Assert.True(time.Elapsed < Timing.Limit(Limit + Slack), $"{time.Elapsed}");
        }

        // A real scan's page, 2,550 x 3,300, is decoded in full and drawn.
        var scan = new byte[2550 * 3300];
        new Random(7).NextBytes(scan);
        using (var engine = Open(Picture(JpegEncoder.EncodeGray(scan, 2550, 3300, 75, 300), "/Type /XObject /Subtype /Image /Width 2550 /Height 3300 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /DCTDecode")))
        {
            engine.Render(0, 0.25);
            Assert.Equal(PageVerdict.Fine, engine.VerdictOf(0));
        }
    }

    [Fact]
    public void ReducingTheSizeLeavesAPictureThatInflatesForSeconds()
    {
        // The same picture, drawn small (2,880 dpi), so Reduce File Size would resample it through MuPDF: 8 s here.
        const long samples = 20_000L * 20_000 * 3;
        var file = Picture(Zlib([], samples), "/Type /XObject /Subtype /Image /Width 20000 /Height 20000 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode");
        Optimizer.CheckPlan = _plan;
        try
        {
            var time = Stopwatch.StartNew();
            var result = Optimizer.Optimize(file, null, new OptimizeOptions { MaxImageDpi = 150 });
            Assert.True(time.Elapsed < Timing.Limit(Limit + Slack), $"{time.Elapsed}");
            Assert.Equal(0, result.ImagesDownsampled); // left as it is

            // A real picture of 2,000 x 2,000 shown at 288 dpi is resampled as before (it isn't large enough to be checked).
            var real = new byte[2000 * 2000 * 3];
            new Random(5).NextBytes(real);
            var photo = Picture(Zlib(real, 0), "/Type /XObject /Subtype /Image /Width 2000 /Height 2000 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode");
            Assert.Equal(1, Optimizer.Optimize(photo, null, new OptimizeOptions { MaxImageDpi = 150 }).ImagesDownsampled);
        }
        finally
        {
            Optimizer.CheckPlan = null;
        }
    }

    [Fact]
    public void ARealDrawingSheetStillDrawsInFull()
    {
        // A sheet of the bench's drawing set: 72,000 paths, ARCH D, Flate content (about 0.3 s to draw small here).
        var content = Zlib(Corpus.SheetContent(3, 72_000), 0);
        var file = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {Corpus.SheetWidth} {Corpus.SheetHeight}] /Contents 4 0 R /Resources << /Font << /F2 5 0 R /F3 5 0 R >> >> >>",
            Core2Pdf.Stream(Encoding.Latin1.GetString(content), "/Filter /FlateDecode"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]);
        using var plan = new PageCheckPlan(CheckExe, []); // the app's limit
        using var checkedEngine = PdfEngine.Open(file, InputFileTypes.PDF, null);
        checkedEngine.CheckPlan = plan;
        using var plain = PdfEngine.Open(file, InputFileTypes.PDF, null);
        var scale = 1200 / Corpus.SheetWidth;
        Assert.Equal(plain.Render(0, scale).Pixels, checkedEngine.Render(0, scale).Pixels);
        Assert.Equal(PageVerdict.Fine, checkedEngine.VerdictOf(0));
        Assert.Contains("A-103", checkedEngine.GetText(0).Text);
    }

    [Fact]
    public void ACheckProcessThatEndsOnAPageRefusesItAfterASecondTry()
    {
        using var plan = new PageCheckPlan(CheckExe, ["page-check-fault"]) { Limit = Limit };
        using var engine = PdfEngine.Open(ThreePages(Drawn, ""), InputFileTypes.PDF, null);
        engine.CheckPlan = plan;
        var refused = Assert.Throws<PageRefusedException>(() => engine.Render(0, 0.5));
        Assert.False(refused.TooSlow);
        Assert.Equal(PageVerdict.Crashed, engine.VerdictOf(0));
        Assert.True(plan.Pids.Count >= 2, $"{plan.Pids.Count} started");
    }

    [Fact]
    public void APageWhoseCheckFailsIsRefusedNotDrawnHereUnlimited()
    {
        // MuPDF failing in the check process (its allocation stopped at the process's memory limit, say) says nothing
        // about what the page costs here, where nothing limits it.
        using var plan = new PageCheckPlan(CheckExe, ["page-check-fail"]) { Limit = Limit };
        using var engine = PdfEngine.Open(ThreePages(Drawn, ""), InputFileTypes.PDF, null);
        engine.CheckPlan = plan;
        var refused = Assert.Throws<PageRefusedException>(() => engine.Render(0, 0.5));
        Assert.False(refused.TooSlow);
        Assert.Equal(PageVerdict.Failed, engine.VerdictOf(0));
        Assert.Throws<PageRefusedException>(() => engine.GetText(0));
        Assert.DoesNotContain(plan.Pids, Exited); // an answer, not a crash: the process goes on, the page isn't tried again
    }

    [Fact]
    public void WithoutACheckProcessPagesDrawAsBeforeAndAreCheckedOnceOneStarts()
    {
        // No check process starts (the program is missing, or something holds up its start past ConnectMs): pages draw
        // as before rather than none at all (fail open), nothing about them is kept, and a start is tried again after a
        // pause that grows with each failure, not on every page meanwhile.
        using var plan = new PageCheckPlan(Path.Combine(AppContext.BaseDirectory, "no-such-program.exe"), []) { Limit = Limit, RetryAfter = TimeSpan.FromMilliseconds(500) };
        using var engine = PdfEngine.Open(ThreePages(Drawn, ""), InputFileTypes.PDF, null);
        engine.CheckPlan = plan;
        for (var page = 0; page < 3; page++) engine.Render(page, 0.25);
        Assert.Contains("Hidden", engine.GetText(1).Text);
        for (var i = 0; i < 5; i++) engine.Render(0, 0.25);
        Assert.Equal(PageVerdict.Unknown, engine.VerdictOf(0));
        Assert.Equal(1, plan.StartFailures);

        // The program is there again: once the pause is over, the pages are checked.
        plan.Exe = CheckExe;
        Thread.Sleep(TimeSpan.FromMilliseconds(600));
        engine.Render(0, 0.25);
        Assert.Equal(PageVerdict.Fine, engine.VerdictOf(0));
        Assert.Equal(0, plan.StartFailures);
    }

    [Fact]
    public void AWaitGivenUpLeavesTheCheckGoingAndItsVerdictKept()
    {
        using var engine = Open(Bomb("1 MB"));
        var time = Stopwatch.StartNew();
        using (var cancel = Timing.CancelAfter(TimeSpan.FromMilliseconds(300)))
            Assert.ThrowsAny<OperationCanceledException>(() => engine.Render(1, 0.5, cancel: cancel.Token));
        Assert.True(time.Elapsed < TimeSpan.FromSeconds(2), $"{time.Elapsed}");
        Assert.Throws<PageRefusedException>(() => engine.Render(1, 0.5));
        Assert.True(time.Elapsed < Timing.Limit(Limit + Slack), $"{time.Elapsed}: the check began again");
    }

    [Fact]
    public void ClosingADocumentOpenedInPlaceLetsTheCheckProcessGoOfItsFile()
    {
        var path = Path.Combine(Path.GetTempPath(), $"inkvolt-check-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, ThreePages(Drawn, ""));
        try
        {
            using (var engine = PdfEngine.OpenFile(path, InputFileTypes.PDF, null))
            {
                engine.CheckPlan = _plan;
                engine.Render(0, 0.25);
                Assert.Equal(PageVerdict.Fine, engine.VerdictOf(0));
            }
            File.Delete(path); // the check process (still running, for the next document) has let go of it
            Assert.Contains(_plan.Pids, pid => !Exited(pid));
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public async Task ADocumentClosedWhileItsCheckProcessStartsIsNeverOpenedThere()
    {
        // The document is closed (and its file may be saved over) after the process started but before it was known
        // to the link: closing found nothing to end, and the process then opened the file and checked the page.
        var path = Path.Combine(Path.GetTempPath(), $"inkvolt-check-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, ThreePages(Drawn, ""));
        var doc = new CheckedDocument(null, path, InputFileTypes.PDF, 3);
        using var plan = new PageCheckPlan(CheckExe, []) { Limit = Limit };
        plan.TestAfterStart = () => plan.Forget(doc);
        try
        {
            var request = plan.Ask(doc, 0);
            await request.Done.WaitAsync(Timing.Limit(Limit + Slack));
            Assert.Equal(PageVerdict.Unchecked, request.Result);
            var pid = Assert.Single(plan.Pids);
            Assert.True(Exited(pid), "the process started meanwhile goes on");
            File.Delete(path); // nothing holds it
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public void EnginesThatDrawNothingCheckNothingAndThumbnailsShareOneProcess()
    {
        var paths = Enumerable.Range(0, 3).Select(_ => Path.Combine(Path.GetTempPath(), $"inkvolt-check-{Guid.NewGuid():N}.pdf")).ToList();
        foreach (var path in paths) File.WriteAllBytes(path, ThreePages(Drawn, ""));
        using var app = PageChecks.UseForTests(_plan);
        try
        {
            // Opened for a page's size (Batch's largest page) or to try a password: nothing is drawn, nothing checked.
            using (var preview = PdfEngine.OpenPreview(paths[0])!) Assert.Equal(612, preview.GetPage(2).Width);
            using (PdfEngine.Open(File.ReadAllBytes(paths[0]), InputFileTypes.PDF, null)) { }
            Thread.Sleep(500);
            Assert.Empty(_plan.Pids);

            // The recent files' thumbnails: each first page checked in the same process, nothing ahead of it, each file let go.
            foreach (var path in paths)
            {
                using (var preview = PdfEngine.OpenPreview(path)!)
                {
                    preview.Render(0, 0.1);
                    Assert.Equal(PageVerdict.Fine, preview.VerdictOf(0));
                }
                File.Delete(path);
            }
            var pid = Assert.Single(_plan.Pids);
            Assert.False(Exited(pid));

            Assert.Equal(3, _plan.ChecksRun);

            // A document the user opens has its first page checked as it opens, before anything is drawn.
            using var session = DocumentSession.FromBytes(ThreePages(Drawn, ""), "opened.pdf");
            var since = Stopwatch.StartNew();
            while (_plan.ChecksRun == 3 && since.Elapsed < Timing.Limit(Limit + Slack)) Thread.Sleep(20);
            Assert.Equal(4, _plan.ChecksRun);
        }
        finally
        {
            foreach (var path in paths)
                if (File.Exists(path)) File.Delete(path);
        }
    }

    private static bool Exited(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return p.HasExited;
        }
        catch (ArgumentException)
        {
            return true;
        }
    }
}
