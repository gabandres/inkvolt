using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 3.3: scans lined up before the overlay, what looks different besides the words, and both in the annotated copy.</summary>
public class CompareAlignTests
{
    private const double Scale = 100.0 / 72;
    private const int W = 850, H = 1100;

    /// <summary>Lines of "words" on white, as a scanned page has them: rows of dark blocks of uneven lengths.</summary>
    private static bool Inked(double x, double y)
    {
        if (x < 90 || x > 760 || y < 90 || y > 1010) return false;
        var line = (int)((y - 90) / 30);
        if ((y - 90) - line * 30 > 12) return false;
        var word = (int)((x - 90 + line * 13) / 57);
        return (x - 90 + line * 13) - word * 57 < 40 + (word * 7 + line * 11) % 13;
    }

    /// <summary>The page, seen turned by <paramref name="angle"/> degrees clockwise and then shifted, as a crooked feed would.</summary>
    private static RenderedImage Scan(double angle = 0, double dx = 0, double dy = 0, Func<double, double, bool>? extra = null)
    {
        var (sin, cos) = Math.SinCos(angle * Math.PI / 180);
        var pixels = new byte[W * H * 3];
        var (cx, cy) = (W / 2.0, H / 2.0);
        for (var y = 0; y < H; y++)
            for (var x = 0; x < W; x++)
            {
                var (rx, ry) = (x + 0.5 - dx - cx, y + 0.5 - dy - cy);
                var (sx, sy) = (cx + rx * cos + ry * sin, cy - rx * sin + ry * cos);
                var v = (byte)(Inked(sx, sy) || extra?.Invoke(sx, sy) == true ? 30 : 245);
                var i = (y * W + x) * 3;
                pixels[i] = pixels[i + 1] = pixels[i + 2] = v;
            }
        return new RenderedImage(W, H, pixels);
    }

    private static RenderedImage Aligned(RenderedImage changed, PageAlignment a) => CompareAlign.Resample(changed, 0, 0, Scale, a, W, H);

    private static VisualDiff Overlay(RenderedImage a, RenderedImage b) => VisualCompare.Overlay(a, b, minPixels: 6, slack: 2);

    [Theory]
    [InlineData(0, 14, -9)]
    [InlineData(1.5, 0, 0)]
    [InlineData(-2.2, 12, 8)]
    [InlineData(4, -20, 15)]
    public void AShiftedOrSkewedScanOfTheSamePageLooksTheSameOnceAligned(double angle, double dx, double dy)
    {
        var (old, changed) = (Scan(), Scan(angle, dx, dy));
        Assert.True(VisualCompare.Overlay(old, changed).ChangedShare > 0.02, "not aligned, it differs all over");

        var a = CompareAlign.Find(old, changed, Scale);
        Assert.False(a.IsNone);
        Assert.Equal(angle, a.Angle, 0.3);
        var diff = Overlay(old, Aligned(changed, a));
        Assert.True(diff.ChangedShare < 0.003, $"left over {diff.ChangedShare:P2}, {a}");
        // A sliver a pixel wide in the drawing can fall between the turned page's samples.
        Assert.True(diff.Regions.All(r => Math.Min(r.Width, r.Height) <= 2), $"left over {string.Join(", ", diff.Regions)}, {a}");
    }

    [Fact]
    public void WhatReallyChangedStillShowsAfterAligning()
    {
        static bool Stamp(double x, double y) => x is > 500 and < 580 && y is > 1030 and < 1070;
        var (old, changed) = (Scan(), Scan(1.2, 10, -6, Stamp));
        var a = CompareAlign.Find(old, changed, Scale);
        var diff = Overlay(old, Aligned(changed, a));
        var region = Assert.Single(diff.Regions);
        Assert.InRange(region.CenterX, 500, 580);
        Assert.InRange(region.CenterY, 1030, 1070);
    }

    [Fact]
    public void AChangedWordOnAScanShowsAtTheScaleScansAreCheckedAt()
    {
        byte[] Pdf(string text) => TestPdf.Make(1, text);
        using var old = PdfEngine.Open(Pdf("The Buyer pays 1,250 on delivery"), MuPDFCore.InputFileTypes.PDF, null);
        using var changed = PdfEngine.Open(Pdf("The Seller pays 7,950 on delivery"), MuPDFCore.InputFileTypes.PDF, null);
        var diff = VisualCompare.OverlayScans(old.Render(0, VisualCompare.ScanCheckScale), changed.Render(0, VisualCompare.ScanCheckScale), VisualCompare.ScanCheckScale);
        Assert.NotEmpty(diff.Regions);
    }

    [Fact]
    public void WhatIsRemovedFromAPageWithNoCounterpartStillGetsItsNote()
    {
        var moved = string.Join(' ', Enumerable.Range(0, 80).Select(i => $"m{i}"));
        var first = string.Join(' ', Enumerable.Range(0, 60).Select(i => $"a{i}"));
        var last = string.Join(' ', Enumerable.Range(0, 60).Select(i => $"z{i}"));
        var oldPages = new[] { Line(first, 100), Line(moved + " gone0 gone1 gone2 gone3 gone4", 100), Line(last, 100) };
        var newPages = new[] { Line(first, 100), Line(last + " " + moved, 100) };
        var r = DocumentCompare.Run(oldPages, newPages);
        Assert.Contains(r.Changes, c => c.Kind == ChangeKind.Deleted);
        var notes = Annotations.Read(CompareReport.Annotate(TestPdf.Make(2, "x"), null, r, newPages, "old.pdf", r.Summary()), null);
        Assert.Contains(notes, a => a.Contents.Contains("gone0", StringComparison.Ordinal));
    }

    [Fact]
    public void AnAreaBeyondTheChangedPagesEdgeIsMentioned()
    {
        var (o, n) = (Line("same words here", 100), Line("same words here", 100));
        var r = DocumentCompare.Run([o], [n]);
        var notes = Annotations.Read(CompareReport.Annotate(TestPdf.Make(1, "x"), null, r, [n], "old.pdf", "summary", [new CompareVisualArea(0, []) { OffPage = 2 }]), null);
        Assert.Contains(notes, a => a.Contents.Contains("2 areas beyond this page's edge look different", StringComparison.Ordinal));
    }

    [Fact]
    public void TheSamePageNeedsNoAlignment()
    {
        var page = Scan();
        Assert.True(CompareAlign.Find(page, page, Scale).IsNone);
    }

    [Fact]
    public void AnAlignmentGoesThereAndBack()
    {
        var a = new PageAlignment(12, -7, 2.5, 300, 400);
        var (x, y) = a.ToOld(a.ToNew(120, 640).X, a.ToNew(120, 640).Y);
        Assert.Equal(120, x, 6);
        Assert.Equal(640, y, 6);
    }

    private static PageText Line(string text, double y, double x = 50) =>
        new([[.. text.Select((c, i) => (c.ToString(), new RectD(x + i * 6, y, 6, 10)))]]);

    [Fact]
    public void AreasUnderTextAreLeftToTheTextCompare()
    {
        var (old, changed) = (Line("the same words", 100), Line("the same words", 100));
        var overText = new RectD(55, 100, 40, 10);
        var onItsOwn = new RectD(300, 400, 80, 60);
        Assert.Equal([onItsOwn], VisualAreas.OffText([overText, onItsOwn], old, changed, PageAlignment.None));
    }

    [Fact]
    public void TextThatReflowedTellsNothingVisually()
    {
        Assert.True(VisualAreas.SameLayout(Line("the same words", 100), Line("the same words", 100)));
        Assert.False(VisualAreas.SameLayout(Line("the same words", 100), Line("the same words", 180)));
        Assert.True(VisualAreas.SameLayout(PageText.Empty, Line("words", 100)));
    }

    [Fact]
    public void TheAnnotatedCopyHasMovesFormattingAndWhatLooksDifferent()
    {
        const string Before = "the first long part of this line stays where it was and so does";
        const string After = "the last long part of this very line that also keeps its place here";
        const string Goes = "one two three four five six seven eight";
        var (oldPage, newPage) = (Line($"{Before} {Goes} {After}", 100), Line($"{Before} {After} {Goes}", 100));
        var moved = DocumentCompare.Run([oldPage], [newPage]);
        Assert.Equal(1, moved.Moved);

        var plain = new WordLook("Arial", 11, false, false, 0);
        var bold = plain with { Bold = true };
        var (o, n) = (Line("same words here", 100), Line("same words here", 100));
        var styled = DocumentCompare.Run(new CompareSource([o], [new PageLooks([(0, plain)])]), new CompareSource([n], [new PageLooks([(0, plain), (5, bold), (10, plain)])]));
        Assert.Equal(1, styled.Formatted);

        var one = TestPdf.Make(1, "x");
        var fromMoved = Annotations.Read(CompareReport.Annotate(one, null, moved, [newPage], "old.pdf", moved.Summary()), null);
        Assert.Contains(fromMoved, a => a.Kind == AnnotationKind.Highlight && a.Contents.Contains("Moved here from page 1 of old.pdf"));

        var box = new RectD(200, 300, 60, 40);
        var fromStyled = Annotations.Read(CompareReport.Annotate(one, null, styled, [n], "old.pdf", styled.Summary(), [new CompareVisualArea(0, [box])]), null);
        Assert.Contains(fromStyled, a => a.Kind == AnnotationKind.Highlight && a.Contents == "Formatting: bold added");
        var area = Assert.Single(fromStyled, a => a.Contents == "Looks different in old.pdf.");
        Assert.True(area.Rect.Contains(box.CenterX, box.CenterY));
    }
}
