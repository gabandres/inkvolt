using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Windows.Ocr;
using MuPDFCore;

// dotnet run --project pdf/tools/ocr-corpus -c Release -- make|run|report [--out dir] [--note text]
CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
var command = args.FirstOrDefault() ?? "run";
string Option(string name, string fallback) => args.SkipWhile(a => a != name).Skip(1).FirstOrDefault() ?? fallback;
var dir = Option("--out", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Inkvolt", "ocr-corpus"));
var note = Option("--note", "");
var toolDir = FindToolDir();
var resultsJson = Path.Combine(dir, "results.json");

switch (command)
{
    case "make":
        Make();
        break;
    case "run":
        Make();
        var results = Run();
        File.WriteAllText(resultsJson, JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
        Report(results);
        // The roadmap's test: lower than today's on every file.
        return results.All(r => r.After < r.Today) ? 0 : 1;
    case "report":
        Report(JsonSerializer.Deserialize<List<FileResult>>(File.ReadAllText(resultsJson))!);
        break;
    default:
        Console.Error.WriteLine("Usage: make | run | report [--out dir] [--note text]");
        return 2;
}
return 0;

void Make()
{
    Directory.CreateDirectory(dir);
    foreach (var file in ScanCorpus.Files)
    {
        var pdf = Path.Combine(dir, file.Name + ".pdf");
        var truth = Path.Combine(dir, file.Name + ".json");
        if (File.Exists(pdf) && File.Exists(truth)) continue;
        var (bytes, pages) = ScanCorpus.Make(file);
        File.WriteAllBytes(pdf, bytes);
        File.WriteAllText(truth, JsonSerializer.Serialize(pages, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"{file.Name}.pdf: {pages.Count} pages, {bytes.Length / 1024} KB");
    }
}

List<FileResult> Run()
{
    var today = WindowsRecognizer.Create() ?? throw new InvalidOperationException("No OCR language is installed.");
    var results = new List<FileResult>();
    foreach (var file in ScanCorpus.Files)
    {
        var pdf = File.ReadAllBytes(Path.Combine(dir, file.Name + ".pdf"));
        var truth = JsonSerializer.Deserialize<List<CorpusPage>>(File.ReadAllText(Path.Combine(dir, file.Name + ".json")))!;
        var own = WindowsRecognizer.Create(file.Language == "es" ? "es-MX" : "en-US") ?? today;
        var expected = truth.SelectMany(p => p.Words).ToList();
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);

        (double Wer, double MsPerPage, List<string> Words) Measure(ITextRecognizer recognizer, RecognizeOptions options)
        {
            var sw = Stopwatch.StartNew();
            var words = new List<string>();
            for (var p = 0; p < engine.PageCount; p++)
                words.AddRange(ScanText.Recognize(engine, p, recognizer, options).Words.Select(w => w.Text));
            return (WordErrorRate.Of(expected, words), sw.Elapsed.TotalMilliseconds / engine.PageCount, words);
        }

        var before = Measure(today, RecognizeOptions.AsScanned);
        var beforeOwn = own.Language == today.Language ? before : Measure(own, RecognizeOptions.AsScanned);
        var after = Measure(own, new RecognizeOptions(CheckWords: false));
        var result = new FileResult(file.Name, file.Describe(), ScanCorpus.Sha256(pdf), expected.Count, today.Language, before.Wer, own.Language,
            beforeOwn.Wer, after.Wer, before.MsPerPage, after.MsPerPage);
        Console.WriteLine($"{file.Name}: {expected.Count} words; today {before.Wer:P1} ({today.Language}), its language {beforeOwn.Wer:P1} ({own.Language}), cleaned {after.Wer:P1}; " +
                          $"{before.MsPerPage:0} → {after.MsPerPage:0} ms a page");
        results.Add(result);
    }
    return results;
}

void Report(List<FileResult> results)
{
    var sb = new StringBuilder();
    sb.AppendLine("# OCR corpus: word error rate");
    sb.AppendLine();
    sb.AppendLine($"Made by `dotnet run --project pdf/tools/ocr-corpus -c Release -- run` on {DateTime.Now:yyyy-MM-dd}, Windows {Environment.OSVersion.Version}, " +
                  $"{System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}. See [README.md](README.md) for the corpus and the measure.");
    if (note.Length > 0) sb.AppendLine().AppendLine(note);
    sb.AppendLine();
    sb.AppendLine("| File | Words | Today | Today, its language chosen | Stage A (cleaned) | ms a page, today → stage A |");
    sb.AppendLine("|---|---:|---:|---:|---:|---:|");
    foreach (var r in results)
        sb.AppendLine($"| `{r.Name}` | {r.Words} | {r.Today:P1} ({r.TodayLanguage}) | {r.TodayOwnLanguage:P1} ({r.OwnLanguage}) | **{r.After:P1}** | {r.TodayMs:0} → {r.AfterMs:0} |");
    sb.AppendLine();
    sb.AppendLine($"Lower than today's on every file: **{(results.All(r => r.After < r.Today) ? "yes" : "no")}**.");
    sb.AppendLine();
    sb.AppendLine("| File | What | SHA-256 |");
    sb.AppendLine("|---|---|---|");
    foreach (var r in results) sb.AppendLine($"| `{r.Name}` | {r.What} | `{r.Sha256[..16]}…` |");
    var path = Path.Combine(toolDir, "RESULTS.md");
    File.WriteAllText(path, sb.ToString());
    Console.WriteLine($"Wrote {path}");
}

static string FindToolDir()
{
    for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
        if (File.Exists(Path.Combine(d.FullName, "OcrCorpus.csproj"))) return d.FullName;
    return Directory.GetCurrentDirectory();
}

internal sealed record FileResult(string Name, string What, string Sha256, int Words, string TodayLanguage, double Today, string OwnLanguage,
    double TodayOwnLanguage, double After, double TodayMs, double AfterMs);
