using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace InkvoltPdf.Bench;

/// <summary>Roadmap 3.6's targets, in the units the measures use.</summary>
public static class Targets
{
    public const double FirstPageMs = 1000;
    public const double PageMs = 200;     // no page of a scroll takes longer than this
    public const double FindMs = 5000;
    public const double CommentsMs = 2000;
    public const double MemoryMb = 1536;
}

/// <summary>The on-screen scroll measured through the app's dev script (<c>scrollbench</c>), if the app was run.</summary>
public sealed record ScrollResult(double Fps, double LongestGapMs, int BlankFrames, int Frames, int BlankAfterPause, string Raw);

/// <summary>One file's medians over the repetitions, with every repetition kept.</summary>
public sealed record FileResult(string File, string What, string Sha256, Measured Median, Measured[] Runs, ScrollResult? Scroll);

public sealed record BenchResults(string Machine, string Build, string Date, int Repetitions, bool Optimized, string[] Notes, FileResult[] Files);

/// <summary>Runs the measures (each repetition in a child process), keeps the medians, writes results.json and RESULTS.md.</summary>
public static class Harness
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.Never };

    public static string DefaultOut => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Inkvolt", "bench");

    public static BenchResults Run(string dir, Sizes sizes, int reps, string? app, string[] notes, Action<string> log)
    {
        var results = new List<FileResult>();
        foreach (var f in Corpus.Files)
        {
            var path = Path.Combine(dir, f.Name);
            if (!File.Exists(path)) throw new FileNotFoundException($"{f.Name} isn't in {dir}: run make first.", path);
            var runs = new List<Measured>();
            for (var r = 0; r < reps; r++)
            {
                log($"{f.Name}: run {r + 1} of {reps}…");
                runs.Add(RunInChild(path, f.FindWord));
            }
            var median = Median(runs);
            ScrollResult? scroll = null;
            if (app is not null)
            {
                log($"{f.Name}: on-screen scroll in {Path.GetFileName(app)}…");
                scroll = ScrollInApp(app, path, log);
            }
            log($"{f.Name}: first page {median.FirstPageMs:N0} ms, {median.PageMsAverage:N0} ms/page (max {median.PageMsMax:N0}), find {median.FindMs:N0} ms ({median.FindHits} hits), comments {median.CommentsMs:N0} ms ({median.Comments}), peak {median.PeakWorkingSetMb:N0} MB");
            results.Add(new FileResult(f.Name, Corpus.Describe(f, sizes), Corpus.Sha256(path), median, [.. runs], scroll));
        }
        var all = new BenchResults(Machine(), Build(), DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), reps, results.All(r => r.Median.Optimized), notes, [.. results]);
        File.WriteAllText(Path.Combine(dir, "results.json"), JsonSerializer.Serialize(all, Json));
        return all;
    }

    public static BenchResults? Load(string dir)
    {
        var path = Path.Combine(dir, "results.json");
        return File.Exists(path) ? JsonSerializer.Deserialize<BenchResults>(File.ReadAllText(path), Json) : null;
    }

    /// <summary>The measure of each field that is the median over the runs (so one busy moment doesn't decide a number).</summary>
    private static Measured Median(List<Measured> runs)
    {
        double Med(Func<Measured, double> f)
        {
            var v = runs.Select(f).Order().ToArray();
            return v.Length % 2 == 1 ? v[v.Length / 2] : (v[v.Length / 2 - 1] + v[v.Length / 2]) / 2;
        }
        var first = runs[0];
        var pageMs = new double[first.PageMs.Length];
        for (var i = 0; i < pageMs.Length; i++)
        {
            var k = i;
            pageMs[i] = Med(m => m.PageMs[k]);
        }
        return first with
        {
            ReadMs = Med(m => m.ReadMs), OpenMs = Med(m => m.OpenMs), FirstRenderMs = Med(m => m.FirstRenderMs), PageMs = pageMs,
            FindMs = Med(m => m.FindMs), CommentsMs = Med(m => m.CommentsMs), PeakWorkingSetMb = Med(m => m.PeakWorkingSetMb),
            FindWorkersPeakMb = Med(m => m.FindWorkersPeakMb),
            PageAgainMs = first.PageAgainMs is { } again ? [.. again.Select((_, k) => Med(m => m.PageAgainMs?[k] ?? 0))] : null,
        };
    }

    /// <summary>Runs <c>one file word</c> in a fresh copy of this program and reads its JSON.</summary>
    private static Measured RunInChild(string path, string word)
    {
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("No process path.");
        var info = new ProcessStartInfo(exe) { RedirectStandardOutput = true, UseShellExecute = false };
        if (Path.GetFileNameWithoutExtension(exe).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) info.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
        info.ArgumentList.Add("one");
        info.ArgumentList.Add(path);
        info.ArgumentList.Add(word);
        using var p = Process.Start(info) ?? throw new InvalidOperationException("The child process didn't start.");
        var json = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException($"The measuring process failed (exit {p.ExitCode}): {json}");
        return JsonSerializer.Deserialize<Measured>(json, Json) ?? throw new InvalidOperationException("No measures came back.");
    }

    public static string ToJson(Measured m) => JsonSerializer.Serialize(m, Json);

    /// <summary>Scrolls the file in the app for 4 s through its dev script (<c>scrollbench</c>) and reads the line it logs.</summary>
    private static ScrollResult? ScrollInApp(string app, string path, Action<string> log)
    {
        var dir = Directory.CreateTempSubdirectory("inkvolt-bench-");
        try
        {
            var steps = Path.Combine(dir.FullName, "steps.txt");
            File.WriteAllLines(steps, ["scrollbench 4000 1500", "exit"]);
            var info = new ProcessStartInfo(app) { UseShellExecute = false };
            info.ArgumentList.Add(path);
            info.ArgumentList.Add("--script");
            info.ArgumentList.Add(steps);
            info.Environment["INKVOLTPDF_DEVSCRIPT"] = "1";
            using var p = Process.Start(info) ?? throw new InvalidOperationException("The app didn't start.");
            if (!p.WaitForExit(TimeSpan.FromMinutes(15)))
            {
                p.Kill(true);
                log("  the app didn't finish the scroll in 15 minutes");
                return null;
            }
            var logPath = steps + ".log";
            var line = File.Exists(logPath) ? File.ReadLines(logPath).FirstOrDefault(l => l.StartsWith("scrollbench:", StringComparison.Ordinal)) : null;
            if (line is null)
            {
                log("  no scrollbench line in the script log" + (File.Exists(logPath) ? ": " + string.Join(" | ", File.ReadLines(logPath).Take(3)) : ""));
                return null;
            }
            // scrollbench: 240 frames in 4001 ms = 60.0 fps; longest gap 33 ms; frames with a blank page 12 of 240; blank pages 200 ms after the stop: 0; page 9 of 5000
            var m = System.Text.RegularExpressions.Regex.Match(line, @"(\d+) frames in \d+ ms = ([\d.]+) fps; longest gap (\d+) ms; frames with a blank page (\d+) of \d+; blank pages 200 ms after the stop: (\d+)");
            if (!m.Success) return new ScrollResult(0, 0, 0, 0, 0, line);
            return new ScrollResult(double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture), int.Parse(m.Groups[3].Value), int.Parse(m.Groups[4].Value), int.Parse(m.Groups[1].Value), int.Parse(m.Groups[5].Value), line);
        }
        finally
        {
            try { dir.Delete(true); } catch (IOException) { }
        }
    }

    /// <summary>Finds the app's Release build next to this tool's source tree, if it was built.</summary>
    public static string? FindApp()
    {
        var src = SourceDir();
        if (src is null) return null;
        var bin = Path.Combine(src, "..", "..", "src", "InkvoltPdf.App", "bin", "Release");
        if (!Directory.Exists(bin)) return null;
        return Directory.EnumerateFiles(bin, "InkvoltPdf.exe", SearchOption.AllDirectories)
            .Where(p => p.Contains(RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
    }

    /// <summary>pdf/tools/bench in the checkout this build came from (walks up from the binary), or null.</summary>
    public static string? SourceDir()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "Bench.csproj"))) return d.FullName;
        return null;
    }

    private static string Machine()
    {
        var cpu = "";
        var model = "";
        if (OperatingSystem.IsWindows())
        {
            cpu = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString", "") as string ?? "";
            model = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\BIOS", "SystemProductName", "") as string ?? "";
        }
        var ram = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / (1024.0 * 1024 * 1024);
        return $"{model.Trim()}, {cpu.Trim()} ({Environment.ProcessorCount} logical processors), {Math.Round(ram)} GB RAM, {RuntimeInformation.OSDescription} {RuntimeInformation.OSArchitecture}, .NET {Environment.Version}";
    }

    private static string Build()
    {
        var commit = "";
        try
        {
            var info = new ProcessStartInfo("git", "rev-parse --short HEAD") { RedirectStandardOutput = true, UseShellExecute = false, WorkingDirectory = SourceDir() ?? Environment.CurrentDirectory };
            using var p = Process.Start(info);
            if (p is not null)
            {
                commit = p.StandardOutput.ReadToEnd().Trim();
                p.WaitForExit();
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            // no git: the commit stays unknown
        }
        return $"{(commit.Length > 0 ? "commit " + commit + ", " : "")}{RuntimeInformation.RuntimeIdentifier}";
    }

    // ---- RESULTS.md ----

    public static string Report(BenchResults r)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Benchmark results (roadmap 3.6)");
        sb.AppendLine();
        sb.AppendLine($"Written by `dotnet run --project pdf/tools/bench -c Release -- report` on {r.Date}. The corpus and the measures are described in");
        sb.AppendLine("[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.");
        sb.AppendLine();
        sb.AppendLine($"- **PC:** {r.Machine}.");
        sb.AppendLine($"- **Build:** {r.Build}, {(r.Optimized ? "Release (optimized)" : "NOT optimized (a Debug build: the numbers don't count)")}; each measure is the median of {r.Repetitions} runs, each in a fresh process.");
        foreach (var n in r.Notes) sb.AppendLine($"- {n}");
        sb.AppendLine();
        sb.AppendLine("## The corpus");
        sb.AppendLine();
        sb.AppendLine("| File | What | Size | SHA-256 |");
        sb.AppendLine("|---|---|---|---|");
        foreach (var f in r.Files) sb.AppendLine($"| `{f.File}` | {f.What} | {Size(f.Median.Bytes)} | `{(f.Sha256.Length > 16 ? f.Sha256[..16] + "…" : f.Sha256)}` |");
        sb.AppendLine();
        sb.AppendLine("## Measures against the targets");
        sb.AppendLine();
        sb.AppendLine("| Measure | Target | " + string.Join(" | ", r.Files.Select(f => $"`{f.File}`")) + " |");
        sb.AppendLine("|---|---|" + string.Concat(r.Files.Select(_ => "---|")));
        Row("Pages", "", f => $"{f.Median.Pages:N0}");
        Row("First page (read + open + render)", "< 1 s", f => Verdict($"{f.Median.FirstPageMs / 1000:N2} s", f.Median.FirstPageMs < Targets.FirstPageMs));
        Row("  of which: read the file / open / render", "", f => $"{f.Median.ReadMs:N0} / {f.Median.OpenMs:N0} / {f.Median.FirstRenderMs:N0} ms");
        Row($"Scrolling proxy: {r.Files.Max(f => f.Median.PageMs.Length)} pages after a cold open, ms/page (slowest)", "no page > 200 ms",
            f => Verdict($"{f.Median.PageMsAverage:N0} ms ({f.Median.PageMsMax:N0})", f.Median.PagesOver200 == 0) + (f.Median.PagesOver200 > 0 ? $", {f.Median.PagesOver200} over" : ""));
        Row("  the same pages again, engine still holding them: ms/page", "", f => $"{f.Median.PageAgainMsAverage:N0} ms");
        Row("Find a word across all pages", "< 5 s", f => Verdict($"{f.Median.FindMs / 1000:N2} s", f.Median.FindMs < Targets.FindMs) + $" (\"{f.Median.FindWord}\": {f.Median.FindHits:N0} hits)");
        Row("  find workers started, pages they read", "", f => $"{f.Median.FindWorkers} ({f.Median.FindWorkerPages:N0} pages)");
        Row("Comment list ready", "< 2 s", f => Verdict($"{f.Median.CommentsMs / 1000:N2} s", f.Median.CommentsMs < Targets.CommentsMs) + $" ({f.Median.Comments:N0} comments)");
        Row("Peak working set", "< 1.5 GB", f => Verdict($"{f.Median.PeakWorkingSetMb / 1024:N2} GB", f.Median.PeakWorkingSetMb < Targets.MemoryMb));
        Row("  with the find workers' peaks added (an upper bound)", "< 1.5 GB", f => Verdict($"{f.Median.PeakWithWorkersMb / 1024:N2} GB", f.Median.PeakWithWorkersMb < Targets.MemoryMb));
        if (r.Files.Any(f => f.Scroll is not null))
        {
            Row("On-screen scroll (app, 4 s at 1,500 px/s): frames per second", "60 fps", f => f.Scroll is null ? "not run" : Verdict($"{f.Scroll.Fps:N0} fps", f.Scroll.Fps >= 55) + $", longest gap {f.Scroll.LongestGapMs:N0} ms");
            Row("  frames with a blank page", "", f => f.Scroll is null ? "" : $"{f.Scroll.BlankFrames} of {f.Scroll.Frames}");
            Row("  pages still blank 200 ms after the scroll stops", "none", f => f.Scroll is null ? "" : Verdict($"{f.Scroll.BlankAfterPause}", f.Scroll.BlankAfterPause == 0));
        }
        sb.AppendLine();
        sb.AppendLine("## What missed");
        sb.AppendLine();
        var missed = new List<string>();
        foreach (var f in r.Files)
        {
            var m = f.Median;
            if (m.FirstPageMs >= Targets.FirstPageMs) missed.Add($"`{f.File}`: first page in {m.FirstPageMs / 1000:N1} s (reading the file {m.ReadMs / 1000:N1} s, opening {m.OpenMs / 1000:N1} s, the render {m.FirstRenderMs / 1000:N1} s).");
            if (m.PagesOver200 > 0) missed.Add($"`{f.File}`: {m.PagesOver200} of the first {m.PageMs.Length} pages took over 200 ms to render (slowest {m.PageMsMax:N0} ms; {m.PageMsAverage:N0} ms on average).");
            if (m.FindMs >= Targets.FindMs) missed.Add($"`{f.File}`: find across {m.Pages:N0} pages took {m.FindMs / 1000:N1} s.");
            if (m.CommentsMs >= Targets.CommentsMs) missed.Add($"`{f.File}`: the comment list took {m.CommentsMs / 1000:N1} s.");
            if (m.PeakWithWorkersMb >= Targets.MemoryMb) missed.Add($"`{f.File}`: peak working set {m.PeakWithWorkersMb / 1024:N2} GB with its find workers (the file is {Size(m.Bytes)}).");
            if (f.Scroll is { } s && (s.Fps < 55 || s.BlankAfterPause > 0)) missed.Add($"`{f.File}`: on-screen scroll at {s.Fps:N0} fps, {s.BlankAfterPause} page(s) still blank 200 ms after the scroll stopped.");
        }
        if (missed.Count == 0) sb.AppendLine("Nothing: every measure met its target on this run.");
        foreach (var m in missed) sb.AppendLine($"- {m}");
        if (!r.Files.Any(f => f.Scroll is not null))
        {
            sb.AppendLine();
            sb.AppendLine("On-screen scrolling wasn't measured on this run (pass `--app` to `run`, or measure it by hand: open the file, scroll a");
            sb.AppendLine("page per second for 10 s, and count pages that are still blank 200 ms after stopping).");
        }
        return sb.ToString();

        void Row(string name, string target, Func<FileResult, string> cell) => sb.AppendLine($"| {name} | {target} | {string.Join(" | ", r.Files.Select(cell))} |");
    }

    private static string Verdict(string value, bool pass) => $"{value} {(pass ? "pass" : "**miss**")}";

    private static string Size(long bytes) => bytes >= 1L << 30 ? $"{bytes / (1024.0 * 1024 * 1024):N2} GB" : $"{bytes / 1048576.0:N1} MB";
}
