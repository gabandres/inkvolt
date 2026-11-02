using System.Diagnostics;
using System.Text;
using InkvoltPdf.Core;
using Xunit;
using Xunit.Abstractions;

namespace InkvoltPdf.Tests;

/// <summary>
/// The translated copy on real files, run only with INKVOLTPDF_CORPUS set to a folder of PDFs (the export corpus's
/// <c>.cache</c>). No model: each text comes back longer and marked. Checks page counts, pictures' places and that the
/// marked text shows: pixels change where each page's text was written (MuPDF's text extraction doesn't see clipping).
/// INKVOLTPDF_CORPUS_OUT saves the first pages of each copy there, to look at.
/// </summary>
public class TranslationCorpusTests(ITestOutputHelper output)
{
    private const string Marker = "ñandú";

    [Fact]
    public void Real_files_keep_their_pages_and_pictures_and_their_new_text_shows()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_CORPUS") is not { Length: > 0 } dir || !Directory.Exists(dir)) return;
        var outDir = Environment.GetEnvironmentVariable("INKVOLTPDF_CORPUS_OUT");
        var totalUnreadable = 0;
        foreach (var file in Directory.GetFiles(dir, "*.pdf"))
        {
            var pdf = File.ReadAllBytes(file);
            int count;
            using (var e = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null)) count = e.PageCount;
            var pages = Environment.GetEnvironmentVariable("INKVOLTPDF_CORPUS_PAGES") is { Length: > 0 } some && PageRange.TryParse(some, count, out var chosen, out _) ? chosen : [.. Enumerable.Range(0, Math.Min(count, 30))];
            var sw = Stopwatch.StartNew();
            var plan = Translation.MakePlan(pdf, null, pages);
            var answers = new TranslationAnswers();
            foreach (var (text, _) in plan.Texts) answers.Done[text] = $"{Marker} {text} y más";
            var read = sw.Elapsed;
            sw.Restart();
            var result = Translation.Apply(plan, answers, "es");
            var r = result.Report;
            output.WriteLine($"{Path.GetFileName(file)}: {pages.Length} pages, {plan.ParagraphCount} paragraphs ({plan.Texts.Count} texts), {r.Translated} written, {r.Shrunk} shrunk, {r.DoNotFit} don't fit, {r.NotTranslated} not translated, " +
                             $"{plan.Blocked.Count} blocked, scans {plan.ScanPages.Count}, turned {plan.TurnedTextPages.Count}, failed {r.FailedPages.Count}; fonts {string.Join("/", r.Fonts)}; read {read.TotalSeconds:0.0}s write {sw.Elapsed.TotalSeconds:0.0}s; {pdf.Length / 1024} KB → {(result.Data?.Length ?? 0) / 1024} KB");
            foreach (var g in plan.Blocked.GroupBy(b => b.Why).OrderByDescending(g => g.Count()).Take(3)) output.WriteLine($"  blocked {g.Count()}: {g.Key}");
            if (result.Data is null) continue;
            Assert.Equal(pdf.Length, File.ReadAllBytes(file).Length);
            using var copy = PdfEngine.Open(result.Data, MuPDFCore.InputFileTypes.PDF, null);
            using var original = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null);
            Assert.Equal(count, copy.PageCount);
            var hidden = 0;
            var unreadable = 0;
            foreach (var p in pages)
            {
                var before = ContentEditor.Read(pdf, null, p);
                var after = ContentEditor.Read(result.Data, null, p);
                // Every picture the page draws directly is where it was (a form copied for an edit keeps its own).
                var boxes = after.Images.Select(i => i.Box).ToList();
                foreach (var image in before.Images)
                    Assert.Contains(boxes, b => Math.Abs(b.X - image.Box.X) < 0.01 && Math.Abs(b.Y - image.Box.Y) < 0.01 && Math.Abs(b.Width - image.Box.Width) < 0.01 && Math.Abs(b.Height - image.Box.Height) < 0.01);
                // The new text's ink: a page whose marked text can be found but whose pixels didn't change hides it.
                if (copy.GetText(p, cache: false).Text.Contains(Marker, StringComparison.Ordinal) && SamePixels(original, copy, p)) hidden++;
                // Line by line: what the original shows (a page's own quirks) doesn't count against the copy.
                var problems = TranslationInk.Problems(copy, p);
                var had = TranslationInk.Problems(original, p).Count;
                unreadable += Math.Max(0, problems.Count - had);
                if (problems.Count > had)
                    foreach (var problem in problems.Take(4)) output.WriteLine($"    p{p + 1}: {problem}");
                if (outDir is not null && (p < 3 || problems.Count > had))
                {
                    Directory.CreateDirectory(outDir);
                    var (w, h, rgba) = Render(copy, p);
                    File.WriteAllBytes(Path.Combine(outDir, $"{Path.GetFileNameWithoutExtension(file)}-{p + 1}.png"), PngEncoder.Encode(w, h, rgba, alpha: false));
                }
            }
            output.WriteLine($"  {unreadable} lines don't show as text of their size");
            Assert.Equal(0, hidden);
            totalUnreadable += unreadable;
            Assert.Empty(r.FailedPages);
        }
    }

    /// <summary>A page at 1.5x as RGB (the engine gives BGR).</summary>
    private static (int W, int H, byte[] Rgba) Render(PdfEngine engine, int page)
    {
        var img = engine.Render(page, 1.5);
        var rgba = (byte[])img.Pixels.Clone();
        for (var i = 0; i + 2 < rgba.Length; i += 3) (rgba[i], rgba[i + 2]) = (rgba[i + 2], rgba[i]);
        return (img.Width, img.Height, rgba);
    }

    private static bool SamePixels(PdfEngine a, PdfEngine b, int page)
    {
        var (_, _, x) = Render(a, page);
        var (_, _, y) = Render(b, page);
        return x.AsSpan().SequenceEqual(y);
    }
}
