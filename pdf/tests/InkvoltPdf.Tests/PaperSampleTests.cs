using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// With INKVOLTPDF_SAMPLES set to a folder, writes the files for checking Wave 4's paper commands in the app (Interleave,
/// Remove Blank Pages, Bookmarks from Headings, Resize, Replace, Page Labels): paper-*.pdf. Without it, does nothing.
/// </summary>
public class PaperSampleTests
{
    [Fact]
    public void WritesTheSamplesWhenAsked()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is not { Length: > 0 } dir) return;
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, "paper-scans.pdf"), TestPdf.Make(6, "scan"));
        File.WriteAllBytes(Path.Combine(dir, "paper-backs.pdf"), TestPdf.Make(3, "back"));
        File.WriteAllBytes(Path.Combine(dir, "paper-stack.pdf"), BlankPagesTests.WithBlanks());
        File.WriteAllBytes(Path.Combine(dir, "paper-report.pdf"), HeadingBookmarksTests.Report());
        File.WriteAllBytes(Path.Combine(dir, "paper-mixed.pdf"), PageEditor.InsertBlank(TestPdf.Make(2), null, 1, 1, 420, 595));
        File.WriteAllBytes(Path.Combine(dir, "paper-linked.pdf"),
            Links.Put(Bookmarks.SetOutline(TestPdf.Make(4), null, [new Bookmark("Third", 2)]), null, 0, new RectD(72, 300, 100, 20), null, 2));
        File.WriteAllBytes(Path.Combine(dir, "paper-new.pdf"), TestPdf.Make(2, "new"));
    }
}
