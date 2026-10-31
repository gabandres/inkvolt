using System.Diagnostics;
using System.Text;
using System.Text.Json;
using InkvoltPdf.Core;
using MuPDFCore;
using ScanPage = InkvoltPrint.Core.Pdf.PdfPage;
using ScanPdfWriter = InkvoltPrint.Core.Pdf.PdfWriter;
using ScanWord = InkvoltPrint.Core.Pdf.OcrWord;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 2.3 of Inkvolt Print: its scan PDF's text layer, read by the readers it is written for. Inkvolt PDF's own search
/// (MuPDF, <see cref="PageText.Find"/>) always runs; pdf.js is opt-in with INKVOLTPDF_PDFJS (it needs Node, as
/// <see cref="ParagraphEditTests"/>' check does), the font's validity with INKVOLTPDF_VERAPDF naming verapdf.bat. Acrobat isn't
/// on the test PC, so that half isn't checked. The words are planted, not recognized: the test PC has English and Spanish OCR only.
/// </summary>
public class OcrLayerSearchTests
{
    private const int Dpi = 4; // the 40 × 56 px test JPEG as a 720 × 1008 pt page: boxes below are in its pixels

    /// <summary>Each planted word with what to search for it (what a person would type).</summary>
    public static readonly (string Script, string Word, string Search)[] Planted =
    [
        ("Greek", "Καλημέρα", "Καλημέρα"),
        ("Greek polytonic", "Ἀθῆναι", "Ἀθῆναι"),
        ("Cyrillic", "Привет", "Привет"),
        ("Cyrillic, decomposed by the recognizer", "Чайка", "Чайка"),
        ("Serbian", "Љубљана", "Љубљана"),
        ("Arabic", "مرحبا", "مرحبا"),
        ("Arabic with harakat", "السَّلام", "السَّلام"),
        ("Arabic with a number", "عام2026", "عام"), // MuPDF reads the runs as they lie, so only each part is found there
        ("Arabic in brackets", "(كلمة)", "كلمة"),
        ("Hebrew", "שלום", "שלום"),
        ("Hebrew with points", "שָׁלוֹם", "שָׁלוֹם"),
        ("Japanese", "東京都庁", "東京都庁"),
        ("Japanese kana", "カタカナとひらがな", "カタカナ"),
        ("Chinese", "中华人民共和国", "人民"),
        ("Korean", "안녕하세요", "안녕"),
        ("A character beyond the first plane", "𠮷野家", "𠮷野家"),
        ("Devanagari", "नमस्ते", "नमस्ते"),
        ("Thai", "สวัสดี", "สวัสดี"),
        ("Latin", "Résumé", "Résumé"),
    ];

    private static ScanWord Word(string text, double x, double line, double width = 16) => new(text, x, 1 + line * 1.5, width, 1);

    private static byte[] Pdf(IReadOnlyList<ScanWord> words, string title = "Scan")
    {
        using var ms = new MemoryStream();
        ScanPdfWriter.Write(ms, [new ScanPage(ScanPdfTests.Jpeg, Dpi, words)], title);
        return ms.ToArray();
    }

    private static byte[] PlantedPdf() => Pdf([.. Planted.Select((p, i) => Word(p.Word, 4, i))]);

    private static byte[] Phrases() => Pdf(
    [
        Word("first", 2, 0, 6), Word("second", 9, 0, 6), Word("third", 16, 0, 6),
        Word("один", 2, 1, 6), Word("два", 9, 1, 6), Word("три", 16, 1, 6),
        // A right-to-left line: the first word in reading order lies furthest right.
        Word("שלום", 16, 2, 6), Word("עולם", 9, 2, 6),
        Word("مرحبا", 16, 3, 6), Word("بالعالم", 9, 3, 6),
        // Japanese as Windows gives it, in pieces with small gaps: found as one run.
        Word("東京", 2, 4, 4), Word("都庁", 6.3, 4, 4), Word("です", 10.6, 4, 4),
    ]);

    private static readonly string[] PhrasesToFind = ["first second third", "один два три", "שלום עולם", "مرحبا بالعالم", "東京都庁です"];

    [Fact]
    public void InkvoltPdfSearchFindsEveryPlantedWord()
    {
        using var engine = PdfEngine.Open(PlantedPdf(), InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        var missing = Planted.Where(p => text.Find(p.Search.Normalize(), matchCase: true, wholeWord: false).Count == 0)
            .Select(p => $"{p.Script}: {p.Search}").ToList();
        Assert.True(missing.Count == 0, $"Not found: {string.Join("; ", missing)}\nMuPDF read:\n{text.Text}");
    }

    [Fact]
    public void InkvoltPdfSearchFindsPhrasesAcrossWords()
    {
        using var engine = PdfEngine.Open(Phrases(), InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        var missing = PhrasesToFind.Where(p => text.Find(p, matchCase: true, wholeWord: false).Count == 0).ToList();
        Assert.True(missing.Count == 0, $"Not found: {string.Join("; ", missing)}\nMuPDF read:\n{text.Text}");
    }

    [Fact]
    public void TheLayerDrawsNothing()
    {
        using var with = PdfEngine.Open(PlantedPdf(), InputFileTypes.PDF, null);
        using var without = PdfEngine.Open(Pdf([]), InputFileTypes.PDF, null);
        var (a, b) = (with.Render(0, 0.5), without.Render(0, 0.5));
        Assert.Equal(b.Pixels, a.Pixels);
    }

    [Fact]
    public void AWordIsSelectedOverItsOwnBox()
    {
        using var engine = PdfEngine.Open(Pdf([new ScanWord("Привет", 10, 20, 12, 1)]), InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        Assert.True(text.Find("Привет", matchCase: true, wholeWord: false).Count == 1, $"MuPDF read: {text.Text}");
        var hit = text.Find("Привет", matchCase: true, wholeWord: false).Single();
        var boxes = text.GetRects(hit.Start, hit.End);
        var (left, right) = (boxes.Min(b => b.X), boxes.Max(b => b.Right));
        Assert.InRange(left, 10 * 18 - 1, 10 * 18 + 1);
        Assert.InRange(right, 22 * 18 - 2, 22 * 18 + 2);
    }

    [Fact]
    public void ASecondSaveThroughInkvoltPdfKeepsTheWords()
    {
        // Open in Inkvolt PDF, turn a page, save: the font and its map survive PDFsharp's round trip.
        var saved = PageEditor.Rotate(PlantedPdf(), null, [0], 90);
        using var engine = PdfEngine.Open(saved, InputFileTypes.PDF, null);
        var text = engine.GetText(0);
        foreach (var (script, _, search) in Planted) Assert.True(text.Find(search.Normalize(), matchCase: true, wholeWord: false).Count > 0, $"{script}: {search} / MuPDF read: {text.Text}");
    }

    // ---- pdf.js ----

    private static string? PdfJsTool()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "tools", "pdfjs-check", "index.mjs"))) return Path.Combine(dir.FullName, "tools", "pdfjs-check");
        return null;
    }

    private static string? OnPath(string name)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            foreach (var ext in new[] { ".cmd", ".exe", "" }) // npm is also a shell script here, which can't be started
                if (Path.Combine(dir.Trim('"'), name + ext) is var path && File.Exists(path)) return path;
        return null;
    }

    private static string Run(string exe, string args, string workDir)
    {
        var psi = new ProcessStartInfo(exe, args)
        {
            WorkingDirectory = workDir, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException($"{Path.GetFileName(exe)} {args}: exit {p.ExitCode}\n{stderr.Result}");
        return stdout.Result;
    }

    /// <summary>The page's text as pdf.js reads it, or null when the check is off (no INKVOLTPDF_PDFJS, no Node).</summary>
    private static string? PdfJsText(byte[] pdf)
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_PDFJS") is not { Length: > 0 } || OnPath("node") is not { } node || OnPath("npm") is not { } npm) return null;
        var tool = PdfJsTool();
        Assert.NotNull(tool);
        if (!Directory.Exists(Path.Combine(tool, "node_modules"))) Run(npm, "ci --no-audit --no-fund", tool);
        var file = Path.Combine(Path.GetTempPath(), $"inkvolt-ocr-layer-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(file, pdf);
        try
        {
            using var doc = JsonDocument.Parse(Run(node, $"index.mjs \"{file}\" 1 1", tool));
            return doc.RootElement.GetProperty("pages")[0].GetProperty("text").GetString() ?? "";
        }
        finally
        {
            File.Delete(file);
        }
    }

    [Fact]
    public void PdfJsFindsEveryPlantedWord()
    {
        if (PdfJsText(PlantedPdf()) is not { } read) return;
        var missing = Planted.Where(p => !read.Contains(p.Search.Normalize(), StringComparison.Ordinal)).Select(p => $"{p.Script}: {p.Search}").ToList();
        Assert.True(missing.Count == 0, $"Not found: {string.Join("; ", missing)}\npdf.js read:\n{read}");
    }

    /// <summary>
    /// pdf.js reads every word of a right-to-left line, in order, but drops the spaces between them: it finds each word and not
    /// a phrase across two (a known limit, in print/ROADMAP.md 2.3). Left-to-right phrases and CJK runs are found whole.
    /// </summary>
    /// <summary>
    /// pdf.js reads every word of a right-to-left line, in order, but drops the spaces between them: it finds each word and not
    /// a phrase across two (a known limit, in print/ROADMAP.md 2.3). Left-to-right phrases and CJK runs are found whole.
    /// </summary>
    [Fact]
    public void PdfJsFindsPhrasesAcrossWords()
    {
        if (PdfJsText(Phrases()) is not { } read) return;
        string[] whole = ["first second third", "один два три", "東京都庁です"], eachWord = ["שלום", "עולם", "مرحبا", "بالعالم"];
        var missing = whole.Concat(eachWord).Where(p => !read.Contains(p, StringComparison.Ordinal)).ToList();
        Assert.True(missing.Count == 0, $"Not found: {string.Join("; ", missing)} / pdf.js read: {read}");
    }

    // ---- veraPDF ----

    /// <summary>
    /// The file isn't PDF/A (no XMP, no output intent), so the check is on the rules about fonts and text only: veraPDF's
    /// PDF/A-2b profile has rules for the embedded font, its CIDSystemInfo, CIDToGIDMap and ToUnicode (6.2.11.x) and they must all pass.
    /// </summary>
    [Fact]
    public void VeraPdfFindsNothingWrongWithTheFont()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_VERAPDF") is not { Length: > 0 } vera || !File.Exists(vera)) return;
        var file = Path.Combine(Path.GetTempPath(), $"inkvolt-ocr-layer-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(file, PlantedPdf());
        try
        {
            var info = new ProcessStartInfo("cmd.exe") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
            foreach (var a in new[] { "/c", vera, "--flavour", "2b", "--format", "xml", file }) info.ArgumentList.Add(a);
            using var p = Process.Start(info)!;
            var error = p.StandardError.ReadToEndAsync();
            var report = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            Assert.Contains("<rule ", report);
            var failed = System.Text.RegularExpressions.Regex.Matches(report, @"<rule specification=""[^""]*"" clause=""([^""]*)"" testNumber=""(\d+)"" status=""failed""")
                .Select(m => $"{m.Groups[1].Value}-{m.Groups[2].Value}").ToList();
            Assert.DoesNotContain(failed, f => f.StartsWith("6.2.11", StringComparison.Ordinal));
        }
        finally
        {
            File.Delete(file);
        }
    }
}
