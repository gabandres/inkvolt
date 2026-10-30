using InkvoltPdf.Bench;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Smoke test for the speed benchmark (pdf/tools/bench, roadmap 3.6): the generator writes a small corpus, every file
/// opens, and the harness measures it. Opt-in (set INKVOLTPDF_BENCH): it takes a few seconds and isn't about the app.
/// </summary>
public class BenchTests
{
    private static bool Enabled => Environment.GetEnvironmentVariable("INKVOLTPDF_BENCH") is { Length: > 0 };

    [Fact]
    public void GeneratorAndHarnessRunOnASmallCorpus()
    {
        if (!Enabled) return;
        var dir = Directory.CreateTempSubdirectory("inkvolt-bench-");
        try
        {
            var log = new List<string>();
            Corpus.Make(dir.FullName, Sizes.Small, log.Add);
            Assert.Equal(Corpus.Files.Count, Directory.GetFiles(dir.FullName, "*.pdf").Length);

            var text = Measures.Run(Path.Combine(dir.FullName, "text.pdf"), "lantern", scrollPages: 4);
            Assert.Equal(Sizes.Small.TextPages, text.Pages);
            Assert.Equal(4, text.PageMs.Length);
            Assert.True(text.FindHits > 0, "the search word should be in the prose");
            Assert.Equal(0, text.Comments);

            var scan = Measures.Run(Path.Combine(dir.FullName, "scan.pdf"), "lantern", scrollPages: 2);
            Assert.Equal(Sizes.Small.ScanPages, scan.Pages);
            Assert.Equal(0, scan.FindHits);
            using (var engine = PdfEngine.Open(File.ReadAllBytes(Path.Combine(dir.FullName, "scan.pdf")), InputFileTypes.PDF, null))
            {
                Assert.Equal(612, engine.GetPage(0).Width, 0.5);
                var img = engine.Render(0, 0.1); // 61 × 79 px: paper with text-like lines, decoded from our own JPEG
                var gray = img.Pixels.Select(b => (int)b).Average();
                Assert.InRange(gray, 150, 245);
            }

            var drawings = Measures.Run(Path.Combine(dir.FullName, "drawings.pdf"), "detail", scrollPages: 2);
            Assert.Equal(Sizes.Small.DrawingSheets, drawings.Pages);
            Assert.True(drawings.FindHits >= 1, "a sheet title should hold the word");

            var comments = Measures.Run(Path.Combine(dir.FullName, "comments.pdf"), "lantern", scrollPages: 2);
            Assert.Equal(Sizes.Small.CommentPages, comments.Pages);
            Assert.Equal(Sizes.Small.CommentPages * Sizes.Small.CommentsPerPage, comments.Comments);
            var list = Annotations.Read(File.ReadAllBytes(Path.Combine(dir.FullName, "comments.pdf")), null);
            Assert.Contains(list, a => a.ReplyTo is not null);
            Assert.True(list.Select(a => a.Kind).Distinct().Count() >= 6, "mixed kinds");

            foreach (var m in new[] { text, scan, drawings, comments })
            {
                Assert.True(m.FirstPageMs > 0 && m.FindMs > 0 && m.CommentsMs > 0 && m.PeakWorkingSetMb > 0);
                Assert.True(m.PageMs.All(ms => ms > 0));
            }
            var report = Harness.Report(new BenchResults("pc", "build", "2026-01-01", 1, true, ["a note"], [new FileResult("text.pdf", "text", Corpus.Sha256(Path.Combine(dir.FullName, "text.pdf")), text, [text], null)]));
            Assert.Contains("| First page (read + open + render) | < 1 s |", report);
            Assert.Contains("- a note", report);
        }
        finally
        {
            dir.Delete(true);
        }
    }

    [Fact]
    public void TheCorpusIsTheSameEveryTime()
    {
        if (!Enabled) return;
        var a = Directory.CreateTempSubdirectory("inkvolt-bench-a-");
        var b = Directory.CreateTempSubdirectory("inkvolt-bench-b-");
        try
        {
            var small = Sizes.Small with { ScanPages = 1, DrawingSheets = 1 };
            Corpus.Make(a.FullName, small, _ => { });
            Corpus.Make(b.FullName, small, _ => { });
            foreach (var f in Corpus.Files)
                Assert.Equal(Corpus.Sha256(Path.Combine(a.FullName, f.Name)), Corpus.Sha256(Path.Combine(b.FullName, f.Name)));
        }
        finally
        {
            a.Delete(true);
            b.Delete(true);
        }
    }
}
