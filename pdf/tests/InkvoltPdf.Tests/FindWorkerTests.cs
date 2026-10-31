using System.Diagnostics;
using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>
/// Find in worker processes (roadmap 3.6): the pages a long search reads come from other processes, and everything else
/// about the search stays as it was. The worker here is the bench tool (it takes the same switch as the app).
/// </summary>
[Collection("KeptText")]
public class FindWorkerTests
{
    private static string WorkerExe => Path.Combine(AppContext.BaseDirectory, "Bench.exe");

    /// <summary>Two workers from the start, the search's own threads waiting for them so the pages go through them.</summary>
    private static FindWorkerPlan Forced(int workers = 2, int readAhead = 256) =>
        new(WorkerExe, [], workers) { PaysMs = 0, MinPages = 0, ReadAhead = readAhead, InProcessWaits = true };

    /// <summary>Pages that differ: accents, case, a blank page, a turned page, a page of many lines, a page wider than long.</summary>
    private static byte[] MixedDocument(int repeat = 6)
    {
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        var font = new XFont("Arial", 14);
        for (var r = 0; r < repeat; r++)
        {
            void Page(Action<XGraphics> draw, int rotate = 0, int width = 612)
            {
                var page = doc.AddPage();
                page.Width = XUnit.FromPoint(width);
                page.Height = XUnit.FromPoint(792);
                if (rotate != 0) page.Rotate = rotate;
                using var gfx = XGraphics.FromPdfPage(page);
                draw(gfx);
            }
            Page(g => g.DrawString($"Café au lait, round {r}", font, XBrushes.Black, new XPoint(72, 100)));
            Page(g => g.DrawString($"CAFE AU LAIT Página {r} señor", font, XBrushes.Black, new XPoint(72, 100)));
            Page(_ => { });
            Page(g => g.DrawString($"Turned cafe {r}", font, XBrushes.Black, new XPoint(72, 100)), rotate: 90);
            Page(g =>
            {
                for (var l = 0; l < 40; l++) g.DrawString($"Line {l} of a long page: the quick brown fox, cafe", font, XBrushes.Black, new XPoint(40, 40 + l * 18));
            });
            Page(g => g.DrawString($"A wide sheet, DETAIL {r}", font, XBrushes.Black, new XPoint(72, 100)), width: 2000);
        }
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    private static void AssertSameAsInProcess(PdfEngine withWorkers, byte[] data, string query, bool matchCase, bool wholeWord, bool ignoreAccents)
    {
        using var plain = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var expected = plain.FindAll(query, matchCase, wholeWord, ignoreAccents).ToList();
        var actual = withWorkers.FindAll(query, matchCase, wholeWord, ignoreAccents).ToList();
        Assert.Equal(expected.Select(m => m.Page), actual.Select(m => m.Page));
        for (var i = 0; i < expected.Count; i++)
        {
            Assert.Null(actual[i].Error);
            Assert.Equal(expected[i].Hits, actual[i].Hits);
            Assert.Equal(expected[i].Text?.Text, actual[i].Text?.Text);
            foreach (var (s, e) in expected[i].Hits)
            {
                Assert.Equal(expected[i].Text!.GetRects(s, e), actual[i].Text!.GetRects(s, e));
                Assert.Equal(expected[i].Text!.Excerpt(s, e), actual[i].Text!.Excerpt(s, e));
            }
        }
    }

    private static void AssertAllGone(PdfEngine engine)
    {
        foreach (var pid in engine.FindWorkerPids)
            Assert.False(IsRunning(pid), $"Worker {pid} is still running.");
    }

    private static bool IsRunning(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return !p.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    [Theory]
    [InlineData("fox", false, false, false)]
    [InlineData("FOX", true, false, false)]
    [InlineData("cafe", false, false, false)]
    [InlineData("cafe", false, false, true)]
    [InlineData("Café", true, false, false)]
    [InlineData("señor", false, true, true)]
    [InlineData("Line 3", false, true, false)]
    [InlineData("zebra", false, false, false)]
    public void HitsMatchTheSingleProcessSearchOnAMixedDocument(string query, bool matchCase, bool wholeWord, bool ignoreAccents)
    {
        var data = MixedDocument();
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = Forced();
        AssertSameAsInProcess(engine, data, query, matchCase, wholeWord, ignoreAccents);
        var stats = engine.LastFindWorkers!;
        Assert.Equal(2, stats.Started);
        Assert.Equal(0, stats.Failed);
        Assert.Equal(engine.PageCount, stats.PagesFromWorkers);
        AssertAllGone(engine);
    }

    [Fact]
    public void AFileOpenedInPlaceIsReadByTheWorkersFromItsPath()
    {
        var data = MixedDocument();
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllBytes(path, data);
            using (var engine = PdfEngine.OpenFile(path, InputFileTypes.PDF, null))
            {
                engine.WorkerPlan = Forced();
                AssertSameAsInProcess(engine, data, "cafe", false, false, true);
                Assert.Equal(engine.PageCount, engine.LastFindWorkers!.PagesFromWorkers);
                AssertAllGone(engine);
            }
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void AWorkerKilledMidSearchLosesNoPage()
    {
        var data = MixedDocument();
        using var plain = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var expected = plain.FindAll("cafe", false, false, true).ToList();
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = Forced(readAhead: 4); // they can't finish before the kill: the window holds them back
        var actual = new List<PdfEngine.PageMatches>();
        foreach (var page in engine.FindAll("cafe", false, false, true))
        {
            if (actual.Count == 0)
            {
                while (engine.FindWorkerPids.Count < 2) Thread.Sleep(1);
                foreach (var pid in engine.FindWorkerPids)
                    Process.GetProcessById(pid).Kill();
            }
            actual.Add(page);
        }
        Assert.Equal(expected.Select(m => m.Page), actual.Select(m => m.Page));
        Assert.Equal(expected.Select(m => m.Hits), actual.Select(m => m.Hits));
        Assert.All(actual, m => Assert.Null(m.Error));
        Assert.Equal(2, engine.LastFindWorkers!.Failed);
        Assert.True(engine.LastFindWorkers.PagesFromWorkers < engine.PageCount);
        AssertAllGone(engine);
    }

    [Fact]
    public void OneWorkerKilledLeavesTheOtherAtWork()
    {
        var data = MixedDocument();
        using var plain = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var expected = plain.FindAll("cafe", false, false, true).ToList();
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = Forced(readAhead: 4);
        var actual = new List<PdfEngine.PageMatches>();
        foreach (var page in engine.FindAll("cafe", false, false, true))
        {
            if (actual.Count == 0) Process.GetProcessById(engine.FindWorkerPids[0]).Kill();
            actual.Add(page);
        }
        Assert.Equal(expected.Select(m => m.Hits), actual.Select(m => m.Hits));
        Assert.Equal(1, engine.LastFindWorkers!.Failed);
        AssertAllGone(engine);
    }

    private static FindWorkerPlan Faulty(string how, int page) => Forced() with { Args = ["find-worker-fault", how, page.ToString()] };

    [Fact]
    public void APageAWorkerCantReadIsReadHereAndTheWorkerGoesOn()
    {
        var data = MixedDocument();
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = Faulty("throw", 7);
        AssertSameAsInProcess(engine, data, "cafe", false, false, true);
        Assert.Equal(0, engine.LastFindWorkers!.Failed);
        Assert.Equal(engine.PageCount - 1, engine.LastFindWorkers.PagesFromWorkers);
        AssertAllGone(engine);
    }

    [Fact]
    public void APageThatKillsTheWorkerReadingItLosesNoOtherPage()
    {
        var data = MixedDocument();
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = Faulty("die", 7);
        AssertSameAsInProcess(engine, data, "cafe", false, false, true);
        Assert.Equal(2, engine.LastFindWorkers!.Started);
        Assert.Equal(1, engine.LastFindWorkers.Failed); // the page goes on to be read here, not by the other worker
        AssertAllGone(engine);
    }

    [Fact]
    public void APageNobodyCanReadComesBackWithItsErrorAlone()
    {
        var data = MixedDocument();
        using var plain = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var expected = plain.FindAll("cafe", false, false, true).ToList();
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = Faulty("throw", 7);
        engine.PageFault = page =>
        {
            if (page == 7) throw new InvalidDataException("This page can't be read here either.");
        };
        var actual = engine.FindAll("cafe", false, false, true).ToList();
        Assert.Equal(engine.PageCount, actual.Count);
        Assert.Equal(expected.Select(m => m.Page), actual.Select(m => m.Page));
        Assert.IsType<InvalidDataException>(actual[7].Error);
        Assert.Empty(actual[7].Hits);
        Assert.NotEmpty(expected[7].Hits); // it would have had hits: the other pages' are what must still arrive
        for (var i = 0; i < actual.Count; i++)
        {
            if (i == 7) continue;
            Assert.Null(actual[i].Error);
            Assert.Equal(expected[i].Hits, actual[i].Hits);
        }
        Assert.Equal(0, engine.LastFindWorkers!.Failed);
        AssertAllGone(engine);
    }

    [Fact]
    public void ANonPageInThePageTreeDoesntStopTheWorkers()
    {
        // MuPDF counts it as a page and can't read it; for real, with no test hook.
        const string font = "/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>";
        var data = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 42 5 0 R] /Count 3 >>",
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R {font} >>",
            Core2Pdf.Stream("BT /F1 14 Tf 72 700 Td (cafe one) Tj ET"),
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R {font} >>",
            Core2Pdf.Stream("BT /F1 14 Tf 72 700 Td (cafe three) Tj ET"),
        ]);
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        Assert.Equal(3, engine.PageCount);
        engine.WorkerPlan = Forced();
        var found = engine.FindAll("cafe", false, false).ToList();
        Assert.Equal(3, engine.LastFindWorkers!.PagesFromWorkers);
        Assert.Equal(0, engine.LastFindWorkers.Failed);
        Assert.Equal([0, 2], found.Where(m => m.Hits.Count > 0).Select(m => m.Page));
        Assert.All(found, m => Assert.Null(m.Error));
        AssertAllGone(engine);
    }

    [Fact]
    public void AWorkerThatCantStartLeavesTheSearchInProcess()
    {
        var data = MixedDocument();
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = Forced() with { Exe = Path.Combine(AppContext.BaseDirectory, "no-such-worker.exe") };
        AssertSameAsInProcess(engine, data, "cafe", false, false, false);
        Assert.Equal(0, engine.LastFindWorkers!.PagesFromWorkers);
        Assert.Equal(2, engine.LastFindWorkers.Failed);
    }

    [Fact]
    public void AWorkerThatConnectsToNothingLeavesTheSearchInProcess()
    {
        // A program that starts and never connects: the search carries on as soon as the wait for it ends.
        var data = TestPdf.Make(12);
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = Forced() with { Exe = Path.Combine(Environment.SystemDirectory, "cmd.exe"), Args = ["/c", "exit"], ConnectMs = 300 };
        AssertSameAsInProcess(engine, data, "fox", false, false, false);
        Assert.Equal(0, engine.LastFindWorkers!.PagesFromWorkers);
        AssertAllGone(engine);
    }

    [Fact]
    public void CancelEndsTheWorkers()
    {
        using var engine = PdfEngine.Open(MixedDocument(), InputFileTypes.PDF, null);
        engine.WorkerPlan = Forced(readAhead: 4);
        using var cts = new CancellationTokenSource();
        var seen = 0;
        Assert.Throws<OperationCanceledException>(() =>
        {
            foreach (var _ in engine.FindAll("fox", false, false, cancel: cts.Token))
                if (++seen == 2) cts.Cancel();
        });
        Assert.Equal(2, seen);
        Assert.NotEmpty(engine.FindWorkerPids);
        AssertAllGone(engine);
    }

    [Fact]
    public void StoppingEarlyAndDisposingEndTheWorkers()
    {
        var engine = PdfEngine.Open(MixedDocument(), InputFileTypes.PDF, null);
        engine.WorkerPlan = Forced(readAhead: 4);
        Assert.Equal(0, engine.FindAll("fox", false, false).First().Page);
        AssertAllGone(engine);
        engine.Dispose();

        var second = PdfEngine.Open(MixedDocument(), InputFileTypes.PDF, null);
        second.WorkerPlan = Forced(readAhead: 4);
        Assert.Throws<ObjectDisposedException>(() =>
        {
            foreach (var _ in second.FindAll("fox", false, false)) second.Dispose();
        });
        AssertAllGone(second);
    }

    [Fact]
    public void ASmallFileStartsNoWorker()
    {
        using var engine = PdfEngine.Open(TestPdf.Make(9), InputFileTypes.PDF, null);
        engine.WorkerPlan = new FindWorkerPlan(WorkerExe, [], 2);
        Assert.Equal(9, engine.FindAll("fox", false, false).Count(m => m.Hits.Count > 0));
        Assert.Equal(0, engine.LastFindWorkers?.Started ?? 0);
        Assert.Empty(engine.FindWorkerPids);
    }

    [Fact]
    public void ALongSearchStartsThemOnItsOwn()
    {
        // The pace decides: asked to start whenever more than a millisecond of pages is left, they start at the first check.
        var data = TestPdf.Make(600);
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        engine.WorkerPlan = new FindWorkerPlan(WorkerExe, [], 2) { PaysMs = 1, MinPages = 1, ProbeMs = 0 };
        Assert.Equal(600, engine.FindAll("fox", false, false).Count(m => m.Hits.Count > 0));
        Assert.Equal(2, engine.LastFindWorkers!.Started);
        AssertAllGone(engine);
    }

    [Fact]
    public void WithoutAPlanNoWorkerStarts()
    {
        using var engine = PdfEngine.Open(TestPdf.Make(3), InputFileTypes.PDF, null);
        Assert.Equal(3, engine.FindAll("fox", false, false).Count(m => m.Hits.Count > 0));
        Assert.Null(engine.LastFindWorkers);
    }

    [Fact]
    public void AFileWithAPasswordStaysInProcess()
    {
        const string password = "s3cret";
        using var engine = PdfEngine.Open(TestPdf.Encrypted(12, password), InputFileTypes.PDF, password);
        engine.WorkerPlan = Forced();
        Assert.Equal(12, engine.FindAll("fox", false, false).Count(m => m.Hits.Count > 0));
        Assert.Empty(engine.FindWorkerPids);
    }

    [Fact]
    public void WhatWorkersReadIsRememberedForLaterSearches()
    {
        var keep = PdfEngine.KeptTextChars;
        using var engine = PdfEngine.Open(TestPdf.Make(8), InputFileTypes.PDF, null);
        engine.WorkerPlan = Forced();
        Assert.Equal(8, engine.FindAll("fox", false, false).Count(m => m.Hits.Count > 0));
        Assert.Equal(8, engine.Extractions);

        // As in process: the pages with little text are kept whole, so nothing is read again and no worker starts.
        var pids = engine.FindWorkerPids.Count;
        var found = engine.FindAll("Page 7", false, true).Single(m => m.Hits.Count > 0);
        Assert.Equal(6, found.Page);
        Assert.NotEmpty(found.Text!.GetRects(found.Hits[0].Start, found.Hits[0].End));
        Assert.Same(found.Text, engine.GetText(6));
        Assert.Equal(8, engine.Extractions);
        Assert.Equal(keep, PdfEngine.KeptTextChars);
        AssertAllGone(engine);
        Assert.True(engine.FindWorkerPids.Count >= pids);
    }

    [Fact]
    public void AnEditSearchesTheNewContentThroughTheWorkers()
    {
        var first = PdfEngine.Open(TestPdf.Make(4, "alpha"), InputFileTypes.PDF, null);
        first.WorkerPlan = Forced();
        Assert.Equal(4, first.FindAll("alpha", false, false).Count(m => m.Hits.Count > 0));
        first.Dispose();
        using var second = PdfEngine.Open(TestPdf.Make(4, "omega"), InputFileTypes.PDF, null);
        second.WorkerPlan = Forced();
        Assert.Empty(second.FindAll("alpha", false, false).SelectMany(m => m.Hits));
        Assert.Equal(4, second.FindAll("omega", false, false).Count(m => m.Hits.Count > 0));
    }

    [Theory]
    [InlineData("not-a-name")]
    [InlineData("")]
    [InlineData(@"..\..\pipe\InkvoltPdf.find.00112233445566778899aabbccddeeff")]
    [InlineData("InkvoltPdf.find.00112233445566778899AABBCCDDEEFF")]
    [InlineData("InkvoltPdf.find.00112233445566778899aabbccddeef")]
    [InlineData("InkvoltPdf.find.00112233445566778899aabbccddeeff0")]
    [InlineData("other.00112233445566778899aabbccddeeff")]
    public void TheSwitchRefusesAnythingButAPipeNameOfItsOwn(string name)
    {
        Assert.Equal(FindWorkers.BadArguments, FindWorkers.Run([FindWorkers.Switch, name]));
    }

    [Fact]
    public void TheSwitchTakesExactlyOneArgument()
    {
        const string good = "InkvoltPdf.find.00112233445566778899aabbccddeeff";
        Assert.Equal(FindWorkers.BadArguments, FindWorkers.Run([FindWorkers.Switch]));
        Assert.Equal(FindWorkers.BadArguments, FindWorkers.Run([FindWorkers.Switch, good, @"C:\some\file.pdf"]));
        Assert.Equal(FindWorkers.BadArguments, FindWorkers.Run(["--other", good]));
        // The right shape, nobody there: it gives up, having touched nothing.
        Assert.Equal(FindWorkers.Failed, FindWorkers.Run([FindWorkers.Switch, good], connectMs: 100));
    }

    [Fact]
    public void PipeNamesArePerLaunchAndAreTheOnesTheSwitchTakes()
    {
        var names = Enumerable.Range(0, 16).Select(_ => FindWorkers.NewPipeName()).ToList();
        Assert.Equal(16, names.Distinct().Count());
        Assert.All(names, n => Assert.True(FindWorkers.IsPipeName(n)));
    }

    [Theory]
    [InlineData(12, 16L << 30, 0, 8)]        // this PC: bounded by the most that help
    [InlineData(8, 16L << 30, 0, 6)]         // two cores left for the app and everything else
    [InlineData(4, 16L << 30, 0, 2)]
    [InlineData(3, 16L << 30, 0, 0)]         // one worker isn't worth a process: the two threads do as well
    [InlineData(2, 16L << 30, 0, 0)]
    [InlineData(12, 1L << 30, 0, 5)]         // 1 GB free: half of it, at 100 MB a worker
    [InlineData(12, 300L << 20, 0, 0)]
    [InlineData(12, 16L << 30, 900L << 20, 3)] // the document's shared copy counts against the 1.2 GB they may take
    public void WorkersAreBoundedByCoresAndMemory(int cores, long available, long document, int expected)
    {
        Assert.Equal(expected, FindWorkers.CountFor(cores, available, document));
    }

    [Fact]
    public void ACorruptAnswerIsRefused()
    {
        var text = new PageText([[("a", new RectD(0, 0, 5, 5)), ("b", new RectD(5, 0, 5, 5))]]);
        using var ms = new MemoryStream();
        text.WriteTo(ms);
        var good = ms.ToArray();

        var back = PageText.ReadFrom(new MemoryStream(good));
        Assert.Equal("ab", back.Text);
        Assert.Equal(text.GetRects(0, 2), back.GetRects(0, 2));

        // A length past what it may hold, a line number past the lines, a stream cut short: all refused (a worker reads
        // an untrusted file, so its answers aren't trusted either).
        var huge = (byte[])good.Clone();
        BitConverter.TryWriteBytes(huge, int.MaxValue);
        Assert.Throws<InvalidDataException>(() => PageText.ReadFrom(new MemoryStream(huge)));
        var badLine = (byte[])good.Clone();
        BitConverter.TryWriteBytes(badLine.AsSpan(4 + 4 + 2 * 32), 99);
        Assert.Throws<InvalidDataException>(() => PageText.ReadFrom(new MemoryStream(badLine)));
        Assert.Throws<EndOfStreamException>(() => PageText.ReadFrom(new MemoryStream(good[..^4])));
    }

    [Fact]
    public void AWorkerDoesntKeepAnotherTabsFile()
    {
        // Big file B is open in place in another tab; a search with workers runs in file A; B saves. The workers must have no
        // hold on B: MuPDF's handle to it is inheritable.
        var dir = Directory.CreateTempSubdirectory("inkvolt-worker-handles-");
        try
        {
            var a = Path.Combine(dir.FullName, "a.pdf");
            var b = Path.Combine(dir.FullName, "b.pdf");
            var copy = Path.Combine(dir.FullName, "b copy.pdf");
            File.WriteAllBytes(a, MixedDocument());
            File.WriteAllBytes(b, TestPdf.Make(2, "file b"));
            File.WriteAllBytes(copy, TestPdf.Make(2, "file b, saved"));
            var tabB = PdfEngine.OpenFile(b, InputFileTypes.PDF, null);
            using var tabA = PdfEngine.OpenFile(a, InputFileTypes.PDF, null);
            tabA.WorkerPlan = Forced();
            var replaced = false;
            foreach (var _ in tabA.FindAll("fox", false, false))
            {
                if (replaced) continue;
                while (tabA.FindWorkerPids.Count < 2) Thread.Sleep(1);
                Assert.Contains(tabA.FindWorkerPids, IsRunning);
                tabB.Dispose(); // what a save does: MuPDF lets go, the copy goes over the file
                File.Move(copy, b, overwrite: true);
                Assert.Contains(tabA.FindWorkerPids, IsRunning);
                replaced = true;
            }
            Assert.True(replaced);
            Assert.True(tabA.LastFindWorkers!.PagesFromWorkers > 0); // they still read, without inheriting anything
            using var saved = PdfEngine.OpenFile(b, InputFileTypes.PDF, null);
            Assert.Contains("saved", saved.GetText(0).Text);
        }
        finally
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            try { dir.Delete(true); } catch (IOException) { }
        }
    }

    [Theory]
    [InlineData("plain")]
    [InlineData("two words")]
    [InlineData(@"C:\Program Files\Inkvolt\")]
    [InlineData("a \"quoted\" word")]
    [InlineData(@"back\\slashes\ and ""quotes"" \\")]
    [InlineData("")]
    public void AWorkersArgumentsReachItAsTheyAre(string arg)
    {
        var line = FindWorkers.CommandLine(WorkerExe, [arg, "--find-worker"]);
        var argv = CommandLineToArgvW(line, out var count);
        try
        {
            Assert.Equal(3, count);
            Assert.Equal(WorkerExe, System.Runtime.InteropServices.Marshal.PtrToStringUni(System.Runtime.InteropServices.Marshal.ReadIntPtr(argv, 0)));
            Assert.Equal(arg, System.Runtime.InteropServices.Marshal.PtrToStringUni(System.Runtime.InteropServices.Marshal.ReadIntPtr(argv, IntPtr.Size)));
        }
        finally
        {
            LocalFree(argv);
        }
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr CommandLineToArgvW(string line, out int count);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [Fact]
    public void WorkersEndWhenTheAppIsKilled()
    {
        // The bench tool as the app: it starts a search with workers, prints their ids and kills itself mid-search.
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllBytes(path, MixedDocument());
            var info = new ProcessStartInfo(WorkerExe) { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            info.ArgumentList.Add("find-crash");
            info.ArgumentList.Add(path);
            info.ArgumentList.Add("fox");
            using var app = Process.Start(info)!;
            var pids = new List<int>();
            while (app.StandardOutput.ReadLine() is { } line)
                if (int.TryParse(line, out var pid)) pids.Add(pid);
            Assert.True(app.WaitForExit(30_000));
            Assert.NotEmpty(pids);
            var deadline = Stopwatch.StartNew();
            while (pids.Exists(IsRunning) && deadline.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(50);
            Assert.DoesNotContain(pids, IsRunning);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
