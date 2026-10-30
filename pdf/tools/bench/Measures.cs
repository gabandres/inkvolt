using System.Diagnostics;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Bench;

/// <summary>
/// One run of the measures over one file, in this process (the harness runs it in a child process per repetition so
/// the peak working set is the file's own and every open is cold for the engine).
/// </summary>
public sealed record Measured(
    string File,
    long Bytes,
    int Pages,
    double ReadMs,
    double OpenMs,
    double FirstRenderMs,
    double[] PageMs,
    string FindWord,
    double FindMs,
    int FindHits,
    double CommentsMs,
    int Comments,
    double PeakWorkingSetMb,
    bool Optimized,
    int FindWorkers = 0,
    int FindWorkerPages = 0,
    double FindWorkersPeakMb = 0,
    double[]? PageAgainMs = null)
{
    /// <summary>Time to the first page on screen: read the file, open it, render page 1.</summary>
    public double FirstPageMs => ReadMs + OpenMs + FirstRenderMs;
    public double PageMsAverage => PageMs.Length == 0 ? 0 : PageMs.Average();
    public double PageMsMax => PageMs.Length == 0 ? 0 : PageMs.Max();
    public int PagesOver200 => PageMs.Count(m => m > 200);
    public double PageAgainMsAverage => PageAgainMs is { Length: > 0 } again ? again.Average() : 0;
    /// <summary>The app's peak and its workers' added up: an upper bound on what the search took, as the peaks needn't coincide.</summary>
    public double PeakWithWorkersMb => PeakWorkingSetMb + FindWorkersPeakMb;
}

public static class Measures
{
    /// <summary>The render scale: 100% zoom on a 150% display for ordinary pages, fit to a 1,200 px viewport for wide sheets.</summary>
    public static double ScaleFor(PageGeometry g) => Math.Min(2.0, 1200 / g.Width);

    /// <param name="scrollPages">How many consecutive pages the scrolling proxy renders after a cold open.</param>
    public static Measured Run(string path, string findWord, int scrollPages = 20)
    {
        var optimized = !(typeof(Measures).Assembly.GetCustomAttributes(typeof(DebuggableAttribute), false).FirstOrDefault() is DebuggableAttribute d && d.IsJITOptimizerDisabled);
        // As DocumentSession.Open does: a file of InPlaceBytes or more opens in place (nothing read up front), a smaller one
        // is read whole first.
        var bytes = new FileInfo(path).Length;
        var inPlace = bytes >= DocumentSession.InPlaceBytes;
        var sw = Stopwatch.StartNew();
        var data = inPlace ? null : File.ReadAllBytes(path);
        var readMs = Ms(sw);
        PdfEngine OpenEngine() => data is null ? PdfEngine.OpenFile(path, InputFileTypes.PDF, null) : PdfEngine.Open(data, InputFileTypes.PDF, null);

        // First page: open (MuPDF parses the file and reads every page's size) and render page 1 as the viewer would.
        sw.Restart();
        double openMs, firstRenderMs, scale;
        int pages;
        using (var engine = OpenEngine())
        {
            openMs = Ms(sw);
            pages = engine.PageCount;
            scale = ScaleFor(engine.GetPage(0));
            sw.Restart();
            engine.Render(0, scale);
            firstRenderMs = Ms(sw);
        }

        // Scrolling proxy: a fresh engine renders the first pages one after another, as a scroll from the top does.
        var pageMs = new List<double>();
        double findMs;
        int hits;
        FindWorkerStats? workers;
        double[] again;
        using (var engine = OpenEngine())
        {
            for (var p = 0; p < Math.Min(scrollPages, pages); p++)
            {
                sw.Restart();
                engine.Render(p, scale);
                pageMs.Add(Ms(sw));
            }

            // Scrolling back: the same pages again, while the engine still has them loaded (with their display lists).
            var pageAgainMs = new List<double>();
            for (var p = 0; p < Math.Min(scrollPages, pages); p++)
            {
                sw.Restart();
                engine.Render(p, scale);
                pageAgainMs.Add(Ms(sw));
            }
            again = [.. pageAgainMs];

            // Find: every page searched as the app's search does (FindAll: pages read on threads or, past a second's work, in worker processes; in order).
            engine.WorkerPlan = _plan;
            sw.Restart();
            hits = 0;
            foreach (var page in engine.FindAll(findWord, matchCase: false, wholeWord: false))
                hits += page.Hits.Count;
            findMs = Ms(sw);
            workers = engine.LastFindWorkers;
        }

        // The comment list: every annotation read through PDFsharp, as the Comments pane does when a file opens (a file
        // opened in place whose bytes never mention /Annots isn't read for it).
        sw.Restart();
        int comments;
        using (var session = inPlace ? DocumentSession.Open(path) : null)
            comments = session is null ? Annotations.Read(data!, null).Count : session.MayContain("/Annots") ? Annotations.Read(session.Data, null).Count : 0;
        var commentsMs = Ms(sw);

        var peak = Process.GetCurrentProcess().PeakWorkingSet64 / 1048576.0;
        return new Measured(Path.GetFileName(path), bytes, pages, readMs, openMs, firstRenderMs, [.. pageMs], findWord, findMs, hits, commentsMs, comments, peak, optimized,
            workers?.Started ?? 0, workers?.PagesFromWorkers ?? 0, (workers?.PeakBytes ?? 0) / 1048576.0, again);
    }

    /// <summary>A test's app that crashes: a search with workers under way, their process ids on the output, then this process killed.</summary>
    public static void CrashDuringFind(string path, string word)
    {
        using var engine = PdfEngine.OpenFile(path, InputFileTypes.PDF, null);
        engine.WorkerPlan = new FindWorkerPlan(Environment.ProcessPath!, [], 2) { PaysMs = 0, MinPages = 0, ReadAhead = 2, InProcessWaits = true };
        foreach (var _ in engine.FindAll(word, matchCase: false, wholeWord: false))
        {
            while (engine.FindWorkerPids.Count < 2) Thread.Sleep(1);
            foreach (var pid in engine.FindWorkerPids) Console.WriteLine(pid);
            Console.Out.Flush();
            Process.GetCurrentProcess().Kill();
        }
    }

    /// <summary>
    /// Lets the search use workers as the app's does; this tool takes the app's switch. INKVOLTPDF_BENCH_WORKERS says how
    /// many instead of the number the PC would get (0: none, as before there were workers).
    /// </summary>
    public static void UseWorkers()
    {
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("No process path.");
        string[] args = Path.GetFileNameWithoutExtension(exe).Equals("dotnet", StringComparison.OrdinalIgnoreCase) ? [typeof(Measures).Assembly.Location] : [];
        if (int.TryParse(Environment.GetEnvironmentVariable("INKVOLTPDF_BENCH_WORKERS"), out var count))
        {
            // Started at once, whatever the search's pace says, when INKVOLTPDF_BENCH_WORKERS_NOW is set: what they cost a short search.
            if (count > 0) _plan = new FindWorkerPlan(exe, args, count);
            if (count > 0 && Environment.GetEnvironmentVariable("INKVOLTPDF_BENCH_WORKERS_NOW") == "1") _plan = _plan! with { PaysMs = 0, MinPages = 0 };
            return;
        }
        FindWorkers.Use(exe, args);
    }

    private static FindWorkerPlan? _plan;

    private static double Ms(Stopwatch sw) => sw.Elapsed.TotalMilliseconds;
}
