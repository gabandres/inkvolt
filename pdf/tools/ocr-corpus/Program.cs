using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Windows.Ocr;
using MuPDFCore;

// dotnet run --project pdf/tools/ocr-corpus -c Release -- make|run|report|cleanup|layer [--out dir] [--note text] [--only name]
CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
var command = args.FirstOrDefault() ?? "run";
string Option(string name, string fallback) => args.SkipWhile(a => a != name).Skip(1).FirstOrDefault() ?? fallback;
var dir = Option("--out", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Inkvolt", "ocr-corpus"));
var note = Option("--note", "");
var toolDir = FindToolDir();
var resultsJson = Path.Combine(dir, "results.json");
// Typeset pages, in results.json and RESULTS.md (not scans: left out of "lower than today's"): the page Windows skips lines
// on, and a page of numbers that reads the same turned over.
const string SkippedName = "skipped-lines";
const string DigitsName = "digit-lines";
string[] typesetNames = [SkippedName, DigitsName];

switch (command)
{
    case "make":
        Make();
        break;
    case "run":
        Make();
        var results = Run();
        results.Add(Typeset(SkippedName, "Helvetica 14 pt, typeset, no damage: two lines Windows' recognizer skips", ScanCorpus.SkippedLinesPdf(), ScanCorpus.SkippedLines));
        results.Add(Typeset(DigitsName, "Helvetica 14 pt, typeset, no damage: three lines of numbers, which read plausibly turned over", ScanCorpus.DigitLinesPdf(), ScanCorpus.DigitLines));
        File.WriteAllText(resultsJson, JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
        Report(results);
        // The roadmap's test: lower than today's on every file; and re-reading missed lines makes no file worse.
        return results.All(r => (r.After < r.Today || typesetNames.Contains(r.Name)) && r.After <= r.Unread) ? 0 : 1;
    case "report":
        Report(JsonSerializer.Deserialize<List<FileResult>>(File.ReadAllText(resultsJson))!);
        break;
    case "cleanup":
        return Cleanup();
    case "layer":
        return Layer();
    case "probe":
        return Probe();
    default:
        Console.Error.WriteLine("Usage: make | run | report | cleanup | layer [--out dir] [--note text] [--only name]");
        return 2;
}
return 0;

// Inkvolt Print's filters (roadmap 2.3): today's reading and the cleaned one, in the languages this PC has.
int Cleanup()
{
    var only = Option("--only", "");
    var installed = WindowsRecognizer.Languages().Select(l => l.Tag).ToList();
    var measured = new List<CleanupResult>();
    foreach (var file in CleanupCorpus.Files.Where(f => only.Length == 0 || f.Name == only))
    {
        var tag = CleanupCorpus.Tag(file.Language);
        var recognizer = installed.Contains(tag, StringComparer.OrdinalIgnoreCase) ? WindowsRecognizer.Create(tag) : null;
        var result = CleanupCorpus.Measure(file, recognizer);
        Console.WriteLine(result.Today is null ? $"{file.Name}: {result.Words} words; {tag} isn't installed, not run"
            : $"{file.Name}: {result.Words} words; today {result.Today:P1}, cleaned {result.After:P1}; filters {result.AfterMs:0} ms a page");
        measured.Add(result);
    }
    if (only.Length == 0)
    {
        var path = Path.Combine(toolDir, "RESULTS-cleanup.md");
        File.WriteAllText(path, CleanupCorpus.Report(measured, installed));
        Console.WriteLine($"Wrote {path}");
    }
    return measured.Where(r => r.Today is not null).All(r => r.After < r.Today) ? 0 : 1;
}

// The whole way, as the Scan tab saves: a page's JPEG, Windows' recognizer, Inkvolt Print's PDF, then search for each true word in it.
int Layer()
{
    var dirOut = Path.Combine(Path.GetTempPath(), "inkvolt-ocr-layer");
    Directory.CreateDirectory(dirOut);
    var failed = false;
    foreach (var file in CleanupCorpus.Files.Where(f => f.Name is "en-grey" or "es-grey"))
    {
        var (px, w, h, _, words) = CleanupCorpus.ScanPage(file, 0);
        var cleaned = CleanupCorpus.Cleaned(px, w, h, 1, file.Filters);
        var jpeg = InkvoltPdf.Bench.JpegEncoder.EncodeGray(cleaned.Pixels, cleaned.Width, cleaned.Height, 90, CleanupCorpus.Dpi);
        var read = InkvoltPrint.Windows.Ocr.WindowsOcr.RecognizeAsync(jpeg, CleanupCorpus.Dpi, default, CleanupCorpus.Tag(file.Language)).GetAwaiter().GetResult();
        using var ms = new MemoryStream();
        InkvoltPrint.Core.Pdf.PdfWriter.Write(ms, [new InkvoltPrint.Core.Pdf.PdfPage(jpeg, CleanupCorpus.Dpi, read)], file.Name);
        File.WriteAllBytes(Path.Combine(dirOut, file.Name + ".pdf"), ms.ToArray());
        using var engine = PdfEngine.Open(ms.ToArray(), InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        var recognized = read.Select(r => r.Text).Distinct().ToList();
        // A hyphen at a line's end is joined up by the reader, as in any PDF: the word is found without it.
        var missed = recognized.Where(t => text.Find(t.TrimEnd('-'), matchCase: true, wholeWord: false).Count == 0).ToList();
        var foundRead = recognized.Count - missed.Count;
        foreach (var t in missed) Console.WriteLine($"  not found: [{t}] ({string.Join(' ', t.Select(c => $"{(int)c:X4}"))})");
        var foundTrue = words.Distinct().Count(t => text.Find(t, matchCase: true, wholeWord: false).Count > 0);
        Console.WriteLine($"{file.Name}: {read.Count} words read; {foundRead} of {recognized.Count} different words read found in the PDF; {foundTrue} of {words.Distinct().Count()} true words found");
        failed |= foundRead < recognized.Count;
    }
    return failed ? 1 : 0;
}

// Pages made like the corpus's with other seeds and settings, read cleaned with and without re-reading missed lines: finds
// pages on which Windows' recognizer skips a line (a run of true words left out as long as a line).
int Probe()
{
    var count = int.Parse(Option("--count", "12"), CultureInfo.InvariantCulture);
    var worse = 0;
    for (var i = 0; i < count; i++)
    {
        var basis = ScanCorpus.Files[i % ScanCorpus.Files.Count];
        var file = basis with { Name = $"probe-{i}", FontSize = basis.FontSize + (i / ScanCorpus.Files.Count) % 3 - 1, Turns = null };
        var (pdf, truth) = ScanCorpus.Make(file);
        var own = WindowsRecognizer.Create(file.Language == "es" ? "es-MX" : "en-US") ?? WindowsRecognizer.Create()!;
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        for (var p = 0; p < engine.PageCount; p++)
        {
            var expected = truth[p].Words;
            var sw = Stopwatch.StartNew();
            var plain = ScanText.Recognize(engine, p, own, new RecognizeOptions(CheckWords: false, RereadMissed: false)).Words.Select(w => w.Text).ToList();
            var plainMs = sw.Elapsed.TotalMilliseconds;
            sw.Restart();
            var reread = ScanText.Recognize(engine, p, own, new RecognizeOptions(CheckWords: false)).Words.Select(w => w.Text).ToList();
            var rereadMs = sw.Elapsed.TotalMilliseconds;
            var (a, b) = (WordErrorRate.Of(expected, plain), WordErrorRate.Of(expected, reread));
            if (b > a) worse++;
            Console.WriteLine($"{file.Name} p{p + 1} ({file.Describe()}): {expected.Count} words; cleaned {a:P1}, longest run missed {WordErrorRate.LongestMissedRun(expected, plain)}; " +
                              $"re-read {b:P1}, run {WordErrorRate.LongestMissedRun(expected, reread)}, {reread.Count - plain.Count:+0;-0;0} words; {plainMs:0} → {rereadMs:0} ms");
            var added = reread.ToList();
            foreach (var t in plain) added.Remove(t);
            if (added.Count > 0) Console.WriteLine($"  added: {string.Join(' ', added)}");
        }
    }
    return worse == 0 ? 0 : 1;
}

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
        var unread = Measure(own, new RecognizeOptions(CheckWords: false, RereadMissed: false));
        var after = Measure(own, new RecognizeOptions(CheckWords: false));
        var result = new FileResult(file.Name, file.Describe(), ScanCorpus.Sha256(pdf), expected.Count, today.Language, before.Wer, own.Language,
            beforeOwn.Wer, after.Wer, before.MsPerPage, after.MsPerPage, unread.Wer, unread.MsPerPage);
        Console.WriteLine($"{file.Name}: {expected.Count} words; today {before.Wer:P1} ({today.Language}), its language {beforeOwn.Wer:P1} ({own.Language}), " +
                          $"cleaned {unread.Wer:P1}, missed lines re-read {after.Wer:P1}; {before.MsPerPage:0} → {unread.MsPerPage:0} → {after.MsPerPage:0} ms a page");
        results.Add(result);
    }
    return results;
}

// A typeset page (ScanCorpus.SkippedLines, ScanCorpus.DigitLines): as rendered, cleaned, and with the lines read again.
FileResult Typeset(string name, string what, byte[] pdf, string[] lines)
{
    var expected = lines.SelectMany(l => l.Split(' ')).ToList();
    var en = WindowsRecognizer.Create("en-US") ?? WindowsRecognizer.Create() ?? throw new InvalidOperationException("No OCR language is installed.");
    using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
    (double Wer, double Ms) Measure(RecognizeOptions options)
    {
        var sw = Stopwatch.StartNew();
        var words = ScanText.Recognize(engine, 0, en, options).Words.Select(w => w.Text).ToList();
        return (WordErrorRate.Of(expected, words), sw.Elapsed.TotalMilliseconds);
    }
    var (today, unread, after) = (Measure(RecognizeOptions.AsScanned), Measure(new RecognizeOptions(CheckWords: false, RereadMissed: false)), Measure(new RecognizeOptions(CheckWords: false)));
    Console.WriteLine($"{name}: {expected.Count} words; today {today.Wer:P1}, cleaned {unread.Wer:P1}, missed lines re-read {after.Wer:P1}; {today.Ms:0} → {unread.Ms:0} → {after.Ms:0} ms");
    return new FileResult(name, what, ScanCorpus.Sha256(pdf), expected.Count,
        en.Language, today.Wer, en.Language, today.Wer, after.Wer, today.Ms, after.Ms, unread.Wer, unread.Ms);
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
    sb.AppendLine("| File | Words | Today | Today, its language chosen | Cleaned | Stage A (cleaned, missed lines re-read) | ms a page, today → cleaned → stage A |");
    sb.AppendLine("|---|---:|---:|---:|---:|---:|---:|");
    foreach (var r in results)
        sb.AppendLine($"| `{r.Name}` | {r.Words} | {r.Today:P1} ({r.TodayLanguage}) | {r.TodayOwnLanguage:P1} ({r.OwnLanguage}) | {r.Unread:P1} | **{r.After:P1}** | " +
                      $"{r.TodayMs:0} → {r.UnreadMs:0} → {r.AfterMs:0} |");
    sb.AppendLine();
    sb.AppendLine($"Lower than today's on every file: **{(results.Where(r => !typesetNames.Contains(r.Name)).All(r => r.After < r.Today) ? "yes" : "no")}**. " +
                  $"Re-reading missed lines no worse on every file: **{(results.All(r => r.After <= r.Unread) ? "yes" : "no")}**.");
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
    double TodayOwnLanguage, double After, double TodayMs, double AfterMs, double Unread, double UnreadMs);
