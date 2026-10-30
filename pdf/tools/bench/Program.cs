using InkvoltPdf.Bench;

// make [--out dir] [--small] [--force]        Write the corpus (text.pdf, scan.pdf, drawings.pdf, comments.pdf) into dir
//                                             (default %LOCALAPPDATA%\Inkvolt\bench). Files that exist are kept unless --force.
// run [--out dir] [--reps n] [--app exe|none] [--note text]…
//                                             Measure every file n times (3) in child processes, scroll it in the app (the
//                                             Release build next to this tree, or exe), keep the medians in dir\results.json,
//                                             then write RESULTS.md as report does.
// report [--out dir] [--md path] [--note text]…
//                                             Write RESULTS.md (default: this tool's folder) from dir\results.json.
// one <file.pdf> <word>                       Measure one file in this process and print the JSON (what run spawns).
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
        Console.WriteLine(Harness.ToJson(Measures.Run(file, word)));
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
