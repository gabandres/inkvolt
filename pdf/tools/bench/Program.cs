using InkvoltPdf.Bench;
using InkvoltPdf.Core;

// The app's own switch, so a search here reads in worker processes as it does in the app.
if (FindWorkers.IsCommand(args)) return FindWorkers.Run(args);
// A test's worker with a page it can't read (FindWorkerTests): "throw" fails that page, "die" ends the process on it.
if (args is ["find-worker-fault", var how, var badPage, .. var workerArgs] && FindWorkers.IsCommand(workerArgs))
{
    FindWorkers.TestPageFault = page =>
    {
        if (page != int.Parse(badPage)) return;
        if (how == "die") System.Diagnostics.Process.GetCurrentProcess().Kill();
        throw new InvalidDataException("This worker can't read this page.");
    };
    return FindWorkers.Run(workerArgs);
}

if (IndexWorkers.IsCommand(args)) return IndexWorkers.Run(args);
// A test's index worker with a file it can't get through (FolderIndexerTests): "die" ends the process on it, "hang" never answers, "spin" keeps a processor busy, "eat" takes memory without end.
if (args is ["index-worker-fault", var fileHow, var badFile, .. var indexWorkerArgs] && IndexWorkers.IsCommand(indexWorkerArgs))
{
    IndexWorkers.TestFileFault = path =>
    {
        if (!path.EndsWith(badFile, StringComparison.OrdinalIgnoreCase)) return;
        if (fileHow == "die") System.Diagnostics.Process.GetCurrentProcess().Kill();
        while (fileHow == "spin") { }
        if (fileHow == "eat")
        {
            // Memory until the job's limit stops it, up to three times that limit (past there the limit isn't working, and this hangs).
            var kept = new List<byte[]>();
            for (var i = 0; i < 96; i++)
            {
                var block = new byte[64 * 1048576];
                Array.Fill(block, (byte)1);
                kept.Add(block);
            }
        }
        Thread.Sleep(Timeout.Infinite);
    };
    return IndexWorkers.Run(indexWorkerArgs);
}
// A test: commits to an index for ever, until it is killed (FolderIndexerTests).
if (args is ["index-writer", var indexBase]) return InkvoltPdf.Bench.FolderIndexBench.WriteForever(indexBase);

// The report reads the same on any PC.
System.Globalization.CultureInfo.DefaultThreadCurrentCulture = System.Globalization.CultureInfo.InvariantCulture;
System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.InvariantCulture;

// make [--out dir] [--small] [--force]        Write the corpus (text.pdf, scan.pdf, drawings.pdf, comments.pdf) into dir
//                                             (default %LOCALAPPDATA%\Inkvolt\bench). Files that exist are kept unless --force.
// run [--out dir] [--reps n] [--app exe|none] [--note text]…
//                                             Measure every file n times (3) in child processes, scroll it in the app (the
//                                             Release build next to this tree, or exe), keep the medians in dir\results.json,
//                                             then write RESULTS.md as report does.
// report [--out dir] [--md path] [--note text]…
//                                             Write RESULTS.md (default: this tool's folder) from dir\results.json.
// one <file.pdf> <word>                       Measure one file in this process and print the JSON (what run spawns).
// index-make <dir> <files>                    Make the folder index corpus: that many PDFs, about 8 pages each (FolderIndexBench).
// index-run <dir>                             Index that folder, search it, change a file: the numbers of roadmap 3.5.
// find-crash <file.pdf> <word>                A test: starts a search with workers, prints their ids, kills itself mid-search.
// find-worker-fault throw|die <page> <switch> <pipe>  A test: a Find worker that can't read that page, or dies on it.
// png <file.pdf> <page> <out.png>             Render a page at 72 dpi, to look at a corpus file.
var dir = Harness.DefaultOut;
var small = false;
var force = false;
var reps = 3;
string? app = null;
var appGiven = false;
string? md = null;
var notes = new List<string>();
var rest = new List<string>();
for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--out": dir = args[++i]; break;
        case "--small": small = true; break;
        case "--force": force = true; break;
        case "--reps": reps = int.Parse(args[++i]); break;
        case "--app": app = args[++i]; appGiven = true; break;
        case "--md": md = args[++i]; break;
        case "--note": notes.Add(args[++i]); break;
        default: rest.Add(args[i]); break;
    }
}
var sizes = small ? Sizes.Small : Sizes.Full;

switch (rest)
{
    case ["make"]:
        Console.WriteLine($"Corpus folder: {dir}");
        Corpus.Make(dir, sizes, Console.WriteLine, force);
        return 0;
    case ["run"]:
    {
        if (!appGiven) app = Harness.FindApp();
        else if (app == "none") app = null;
        Console.WriteLine($"Corpus folder: {dir}; app: {app ?? "not run"}");
        var results = Harness.Run(dir, sizes, reps, app, [.. notes], Console.WriteLine);
        if (!results.Optimized) Console.WriteLine("WARNING: this is not an optimized build (use -c Release); the numbers don't count.");
        WriteReport(results, md);
        return 0;
    }
    case ["report"]:
    {
        var results = Harness.Load(dir) ?? throw new InvalidOperationException($"No results.json in {dir}: run first.");
        if (notes.Count > 0) results = results with { Notes = [.. notes] };
        WriteReport(results, md);
        return 0;
    }
    case ["one", var file, var word]:
        Measures.UseWorkers();
        Console.WriteLine(Harness.ToJson(Measures.Run(file, word)));
        return 0;
    case ["index-make", var indexDir, var indexFiles]:
        InkvoltPdf.Bench.FolderIndexBench.Make(indexDir, int.Parse(indexFiles), Console.WriteLine);
        return 0;
    case ["index-run", var indexDir]:
        return InkvoltPdf.Bench.FolderIndexBench.Run(indexDir, Console.WriteLine);
    case ["find-crash", var file, var word]:
        Measures.CrashDuringFind(file, word);
        return 0;
    case ["png", var file, var page, var png]:
    {
        using var engine = InkvoltPdf.Core.PdfEngine.Open(File.ReadAllBytes(file), MuPDFCore.InputFileTypes.PDF, null);
        engine.SaveImage(int.Parse(page) - 1, 72, png, jpeg: false);
        return 0;
    }
    default:
        Console.Error.WriteLine("usage: Bench make [--out dir] [--small] [--force] | run [--out dir] [--reps n] [--app exe|none] [--note text]… | report [--out dir] [--md path] [--note text]… | one <file.pdf> <word> | png <file.pdf> <page> <out.png>");
        return 2;
}

static void WriteReport(BenchResults results, string? md)
{
    md ??= Path.Combine(Harness.SourceDir() ?? Environment.CurrentDirectory, "RESULTS.md");
    File.WriteAllText(md, Harness.Report(results));
    Console.WriteLine($"Wrote {md}");
}
