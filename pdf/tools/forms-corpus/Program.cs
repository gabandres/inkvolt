using System.Diagnostics;
using System.Text;
using System.Text.Json;
using InkvoltPdf.Core;
using InkvoltPdf.FormsCorpus;

// run [--corpus corpus.json] [--cache dir] [--out dir] [--only a,b] [--timeout s] [--jobs n] [--files a.pdf,b.pdf]
//     [--reuse] [--update-baseline]
//      Fills every cached form of the corpus (each in its own process, killed after the time limit: a hang), reads the
//      originals and the filled files with pdf.js, and writes <out>\results.json and <out>\summary.md (failures grouped
//      by signature). --files adds a user's PDFs (never baselined or committed). Exit code 1 when a form fails in a way
//      baseline.json doesn't list; --update-baseline accepts the run's failures instead.
// one <in.pdf> <out-dir> <name>     One form, in this process: <out-dir>\<name>.report.json and <name>.filled.pdf.
// summary <results.json>            The grouped summary again, from saved results.
// script <in.pdf> <out-dir> [n]     A --script for the app that clicks and types into the first n fillable fields
//                                    (mouse and keys, as a person would) and saves with Ctrl+S: <out-dir>\<name>.steps.txt, .expected.json.
// uicheck <saved.pdf> <expected.json>  What the app saved holds the values the script typed and clicked.
return args switch
{
    ["one", var pdf, var outDir, var name] => One(pdf, outDir, name),
    ["summary", var results] => Summary(results),
    ["script", var pdf, var outDir, ..] => Script(pdf, outDir, args.Length > 3 ? int.Parse(args[3]) : 8),
    ["uicheck", var saved, var expected] => UiCheck(saved, expected),
    ["run", ..] => Run(args[1..]),
    ["dump", var pdf, var field] => Dump(pdf, field),
    ["synth", var outDir] => Synth(outDir),
    _ => Usage(),
};

static int Usage()
{
    Console.Error.WriteLine("usage: run [--corpus f] [--cache d] [--out d] [--only a,b] [--timeout s] [--jobs n] [--files a,b] | one in.pdf out-dir name | summary results.json | script in.pdf out-dir [n] | uicheck saved.pdf expected.json");
    return 2;
}

static int One(string pdf, string outDir, string name)
{
    Directory.CreateDirectory(outDir);
    var report = FormsHarness.FillOne(name, File.ReadAllBytes(pdf), outDir);
    File.WriteAllText(Path.Combine(outDir, name + ".report.json"), JsonSerializer.Serialize(report, FormsHarness.Json));
    return 0;
}

static int Run(string[] a)
{
    string Opt(string key, string fallback) => Array.IndexOf(a, key) is var i and >= 0 && i + 1 < a.Length ? a[i + 1] : fallback;
    var toolDir = FindToolDir();
    var corpusPath = Opt("--corpus", Path.Combine(toolDir, "corpus.json"));
    var cache = Opt("--cache", Path.Combine(toolDir, ".cache", "pdfs"));
    var outDir = Path.GetFullPath(Opt("--out", Path.Combine(toolDir, ".cache", "out")));
    var only = Opt("--only", "").Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.OrdinalIgnoreCase);
    var timeout = TimeSpan.FromSeconds(int.Parse(Opt("--timeout", "120")));
    var reuse = a.Contains("--reuse"); // keep each form's last report (only the pdf.js comparison and summary run again)
    var jobs = int.Parse(Opt("--jobs", Math.Max(1, Math.Min(4, Environment.ProcessorCount / 2)).ToString()));
    Directory.CreateDirectory(outDir);

    var items = new List<(string Name, string Pdf, string? Sha)>();
    if (File.Exists(corpusPath))
        foreach (var e in JsonDocument.Parse(File.ReadAllText(corpusPath)).RootElement.EnumerateArray())
        {
            var name = e.GetProperty("name").GetString()!;
            if (only.Count > 0 && !only.Contains(name)) continue;
            var pdf = Path.Combine(cache, name + ".pdf");
            if (e.GetProperty("url").GetString()!.StartsWith("synthetic:", StringComparison.Ordinal))
            {
                // Written by SyntheticForms each run: nothing to download or pin.
                Directory.CreateDirectory(cache);
                File.WriteAllBytes(pdf, SyntheticForms.Build(name));
                items.Add((name, pdf, null));
                continue;
            }
            items.Add((name, pdf, e.TryGetProperty("sha256", out var s) ? s.GetString() : null));
        }
    foreach (var f in Opt("--files", "").Split(',', StringSplitOptions.RemoveEmptyEntries))
        items.Add(("local-" + Path.GetFileNameWithoutExtension(f), Path.GetFullPath(f), null));

    var reports = new FormReport?[items.Count];
    var self = Environment.ProcessPath!;
    var selfArgs = Path.GetFileNameWithoutExtension(self).Equals("dotnet", StringComparison.OrdinalIgnoreCase) ? new[] { typeof(FormsHarness).Assembly.Location } : [];
    var done = 0;
    Parallel.For(0, items.Count, new ParallelOptions { MaxDegreeOfParallelism = jobs }, i =>
    {
        var (name, pdf, sha) = items[i];
        if (!File.Exists(pdf))
        {
            reports[i] = new FormReport { Name = name, Status = "skip", Skip = "not downloaded (run fetch.ps1)" };
            return;
        }
        if (sha is not null && !string.Equals(sha, Sha256(pdf), StringComparison.OrdinalIgnoreCase))
        {
            reports[i] = new FormReport { Name = name, Status = "skip", Skip = "source changed (sha256 differs from corpus.json)" };
            return;
        }
        var reportPath = Path.Combine(outDir, name + ".report.json");
        if (reuse && File.Exists(reportPath) && File.GetLastWriteTimeUtc(reportPath) > File.GetLastWriteTimeUtc(pdf))
        {
            reports[i] = JsonSerializer.Deserialize<FormReport>(File.ReadAllText(reportPath), FormsHarness.Json);
            return;
        }
        File.Delete(reportPath);
        File.Delete(Path.Combine(outDir, name + ".filled.pdf"));
        var psi = new ProcessStartInfo(self) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var s in selfArgs) psi.ArgumentList.Add(s);
        foreach (var s in new[] { "one", pdf, outDir, name }) psi.ArgumentList.Add(s);
        var clock = Stopwatch.StartNew();
        using var p = Process.Start(psi)!;
        var stderr = p.StandardError.ReadToEndAsync();
        _ = p.StandardOutput.ReadToEndAsync();
        if (!p.WaitForExit(timeout))
        {
            p.Kill(true);
            var r = new FormReport { Name = name, Status = "fail", Ms = clock.ElapsedMilliseconds };
            r.Fail("hang", "", $"still running after {timeout.TotalSeconds:0} s (open, fill, save and read back)");
            reports[i] = r;
        }
        else if (File.Exists(reportPath))
            reports[i] = JsonSerializer.Deserialize<FormReport>(File.ReadAllText(reportPath), FormsHarness.Json);
        else
        {
            var r = new FormReport { Name = name, Status = "fail", Ms = clock.ElapsedMilliseconds };
            var last = stderr.Result.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(l => l.Contains("Exception", StringComparison.Ordinal)) ?? $"exit code {p.ExitCode}";
            r.Fail("crash", "", last.Trim());
            reports[i] = r;
        }
        var n = Interlocked.Increment(ref done);
        Console.WriteLine($"[{n}/{items.Count}] {name}: {reports[i]!.Status} {string.Join(", ", reports[i]!.Failures.Select(f => f.Kind).Distinct())}");
    });

    // pdf.js: the originals and the filled files.
    if (FindNode() is { } node && File.Exists(Path.Combine(toolDir, "..", "pdfjs-check", "node_modules", "pdfjs-dist", "package.json")))
    {
        var files = new List<string>();
        for (var i = 0; i < items.Count; i++)
        {
            if (reports[i]!.Status == "skip" && reports[i]!.Skip!.StartsWith("not downloaded", StringComparison.Ordinal)) continue;
            files.Add(Path.GetFullPath(items[i].Pdf));
            var filled = Path.Combine(outDir, items[i].Name + ".filled.pdf");
            if (File.Exists(filled)) files.Add(filled);
        }
        Console.WriteLine($"pdf.js: reading {files.Count} files...");
        var listings = FormsHarness.ReadPdfJs(node, toolDir, files);
        for (var i = 0; i < items.Count; i++)
        {
            listings.TryGetValue(Path.GetFullPath(items[i].Pdf), out var original);
            listings.TryGetValue(Path.Combine(outDir, items[i].Name + ".filled.pdf"), out var filled);
            FormsHarness.ComparePdfJs(reports[i]!, original, filled);
        }
    }
    else Console.WriteLine("pdf.js: not run (needs node and `npm ci` in pdf/tools/pdfjs-check)");

    var resultsPath = Path.Combine(outDir, "results.json");
    File.WriteAllText(resultsPath, JsonSerializer.Serialize(reports, FormsHarness.Json));
    var summary = FormsSummary.Markdown([.. reports.OfType<FormReport>()], name => items.FirstOrDefault(x => x.Name == name).Pdf);
    File.WriteAllText(Path.Combine(outDir, "summary.md"), summary);
    Console.WriteLine(summary);
    Console.WriteLine($"Results: {resultsPath}");

    // baseline.json: each failing corpus form's failure groups. A new group on any form is a regression.
    var corpusReports = reports.OfType<FormReport>().Where(r => !r.Name.StartsWith("local-", StringComparison.Ordinal)).ToList();
    var baselinePath = Path.Combine(toolDir, "baseline.json");
    if (a.Contains("--update-baseline"))
    {
        File.WriteAllText(baselinePath, JsonSerializer.Serialize(FormsSummary.Baseline(corpusReports), FormsHarness.Json));
        Console.WriteLine($"Baseline updated: {baselinePath}");
        return 0;
    }
    if (!File.Exists(baselinePath)) return 0;
    var baseline = JsonSerializer.Deserialize<Dictionary<string, List<string>>>(File.ReadAllText(baselinePath))!;
    var regressions = FormsSummary.Regressions(corpusReports, baseline);
    foreach (var r in regressions) Console.WriteLine("REGRESSION " + r);
    Console.WriteLine(regressions.Count == 0 ? "No regressions against baseline.json." : $"{regressions.Count} regression(s) against baseline.json.");
    return regressions.Count == 0 ? 0 : 1;
}

static int Summary(string results)
{
    var reports = JsonSerializer.Deserialize<List<FormReport>>(File.ReadAllText(results), FormsHarness.Json)!;
    var cache = Path.Combine(FindToolDir(), ".cache", "pdfs");
    Console.WriteLine(FormsSummary.Markdown(reports, name => Path.Combine(cache, name + ".pdf")));
    return 0;
}

static int Script(string pdf, string outDir, int count)
{
    Directory.CreateDirectory(outDir);
    var name = Path.GetFileNameWithoutExtension(pdf);
    var (steps, expected) = UiScript.Build(File.ReadAllBytes(pdf), count);
    File.WriteAllText(Path.Combine(outDir, name + ".steps.txt"), steps);
    File.WriteAllText(Path.Combine(outDir, name + ".expected.json"), JsonSerializer.Serialize(expected, FormsHarness.Json));
    Console.WriteLine(Path.Combine(outDir, name + ".steps.txt"));
    return 0;
}

static int UiCheck(string saved, string expectedPath)
{
    var expected = JsonSerializer.Deserialize<List<UiScript.Expected>>(File.ReadAllText(expectedPath), FormsHarness.Json)!;
    var problems = UiScript.Check(File.Exists(saved) ? File.ReadAllBytes(saved) : null, expected);
    foreach (var p in problems) Console.WriteLine(p);
    Console.WriteLine(problems.Count == 0 ? $"ui: {expected.Count} field(s) kept" : $"ui: {problems.Count} problem(s)");
    return problems.Count == 0 ? 0 : 1;
}

// dump <in.pdf> <field>   What a field holds, as FormEditor and as the raw widget dictionaries (for finding a failure's cause).
static int Dump(string pdf, string field)
{
    var data = File.ReadAllBytes(pdf);
    foreach (var w in FormEditor.Read(data, null).Where(w => w.FieldName == field))
        Console.WriteLine($"FormEditor widget: {w.Kind} page {w.PageIndex + 1} on={w.OnState} value='{w.Value}' display='{w.DisplayValue}' ro={w.ReadOnly} calc={w.Calculated} rect={w.Rect}");
    foreach (var f in FormEditor.DataFields(data, null).Where(f => f.Name == field))
        Console.WriteLine($"FormEditor field: {f.Kind} value='{f.Value}' options=[{string.Join("|", f.Options)}] labels=[{string.Join("|", f.Labels)}]");
    using var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(data), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
    var p = 0;
    var tree = new FormsHarness.FieldTree(doc);
    foreach (var page in doc.Pages)
    {
        p++;
        foreach (var w in FormsHarness.Widgets(page).Where(w => tree.FullName(w) == field))
        {
            Console.WriteLine($"page {p} widget: {Describe(w)}");
            if (FormsHarness.Resolve((FormsHarness.Resolve(w.Elements["/AP"]) as PdfSharp.Pdf.PdfDictionary)?.Elements["/N"]) is PdfSharp.Pdf.PdfDictionary n)
            {
                if (n.Stream is { } s) Console.WriteLine($"  /AP /N stream: {Describe(n)} | {Encoding.Latin1.GetString(s.UnfilteredValue).ReplaceLineEndings(" ")[..Math.Min(400, s.UnfilteredValue.Length)]}");
                else
                {
                    Console.WriteLine($"  /AP /N states: {string.Join(" ", n.Elements.Keys)}");
                    foreach (var key in n.Elements.Keys)
                        if (FormsHarness.Resolve(n.Elements[key]) is PdfSharp.Pdf.PdfDictionary { Stream: { } face } fd)
                            Console.WriteLine($"    {key}: {Describe(fd)} | {Encoding.Latin1.GetString(face.UnfilteredValue).ReplaceLineEndings(" ")[..Math.Min(200, face.UnfilteredValue.Length)]}");
                        else Console.WriteLine($"    {key}: not a stream: {(FormsHarness.Resolve(n.Elements[key]) is PdfSharp.Pdf.PdfDictionary nd ? Describe(nd) : FormsHarness.Resolve(n.Elements[key])?.GetType().Name ?? "null")}");
                }
            }
            foreach (var parent in tree.Chain(w).Skip(1))
                Console.WriteLine($"  parent: {Describe(parent)}");
        }
    }
    return 0;

    static string Describe(PdfSharp.Pdf.PdfDictionary d) => string.Join(" ", d.Elements.Keys.Where(k => k is not ("/Parent" or "/P" or "/AP" or "/Kids")).Select(k => $"{k}={Short(FormsHarness.Resolve(d.Elements[k]))}"))
        + (FormsHarness.Resolve(d.Elements["/Kids"]) is PdfSharp.Pdf.PdfArray kids ? $" /Kids[{kids.Elements.Count}]" : "");
    static string Short(PdfSharp.Pdf.PdfItem? i) { var s = i?.ToString() ?? "null"; return s.Length > 120 ? s[..120] + "…" : s; }
}

// synth <out-dir>   Writes the synthetic forms (SyntheticForms) to look at.
static int Synth(string outDir)
{
    Directory.CreateDirectory(outDir);
    foreach (var (name, _) in SyntheticForms.All) File.WriteAllBytes(Path.Combine(outDir, name + ".pdf"), SyntheticForms.Build(name));
    Console.WriteLine($"{SyntheticForms.All.Count} forms in {outDir}");
    return 0;
}

static string Sha256(string path)
{
    using var s = File.OpenRead(path);
    return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(s)).ToLowerInvariant();
}

static string FindToolDir()
{
    for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        if (File.Exists(Path.Combine(dir.FullName, "pdfjs-fields.mjs"))) return dir.FullName;
    return Directory.GetCurrentDirectory();
}

static string? FindNode()
{
    foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        foreach (var exe in new[] { "node.exe", "node" })
            if (File.Exists(Path.Combine(dir.Trim('"'), exe))) return Path.Combine(dir.Trim('"'), exe);
    return null;
}
