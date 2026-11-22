using MuPDFCore;
using InkvoltPdf.Core;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>Bookmarks from Headings (roadmap 4.5): DocLayout's headings, nested by level, written through Bookmarks.</summary>
public class HeadingBookmarksTests
{
    private const string Body = "This paragraph is ordinary body text set at eleven points, long enough to tell the body size.";

    /// <summary>
    /// Three pages: "Chapter One" (24 pt) and "Background" (16 pt) with body text on page 1, "Method" (16 pt) on page 2,
    /// "Chapter Two" (24 pt) on page 3; each page also has a small running header that repeats.
    /// </summary>
    internal static byte[] Report()
    {
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        var body = new XFont("Arial", 11);
        var big = new XFont("Arial", 24, XFontStyleEx.Bold);
        var mid = new XFont("Arial", 16, XFontStyleEx.Bold);
        (string Text, XFont Font)[][] pages =
        [
            [("Chapter One", big), (Body, body), (Body, body), ("Background", mid), (Body, body), (Body, body)],
            [(Body, body), ("Method", mid), (Body, body), (Body, body)],
            [("Chapter Two", big), (Body, body), (Body, body), (Body, body)],
        ];
        foreach (var lines in pages)
        {
            var page = doc.AddPage();
            using var gfx = XGraphics.FromPdfPage(page);
            gfx.DrawString("Annual report", new XFont("Arial", 9), XBrushes.Gray, new XPoint(72, 40));
            var y = 100.0;
            foreach (var (text, font) in lines)
            {
                gfx.DrawString(text, font, XBrushes.Black, new XPoint(72, y));
                y += font.Size * 2.2;
            }
        }
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    private static IReadOnlyList<FoundHeading> Find(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return HeadingBookmarks.Find(engine);
    }

    [Fact]
    public void FindsTheHeadingsByTheirSize_NotTheRunningHeader()
    {
        var found = Find(Report());
        Assert.Equal([("Chapter One", 1, 0), ("Background", 2, 0), ("Method", 2, 1), ("Chapter Two", 1, 2)],
            found.Select(h => (h.Title, h.Level, h.PageIndex)));
        Assert.InRange(found[0].Top, 70, 100); // the line's top, from the page's top
        Assert.True(found[1].Top > found[0].Top);
    }

    [Fact]
    public void NestsByLevel_ASkippedLevelNestingOneStep()
    {
        FoundHeading H(string t, int level) => new(t, level, 0, 0);
        var tree = HeadingBookmarks.Tree([H("A", 1), H("A.1.1", 3), H("A.2", 2), H("A.2.1", 3), H("B", 1), H("Lead-in", 2)]);
        Assert.Equal(["A", "B"], tree.Select(b => b.Title));
        Assert.Equal(["A.1.1", "A.2"], tree[0].Children.Select(b => b.Title));
        Assert.Equal(["A.2.1"], tree[0].Children[1].Children.Select(b => b.Title));
        Assert.True(tree[0].Open);
        Assert.False(tree[0].Children[1].Open);
        Assert.Equal(["A", "B"], HeadingBookmarks.Tree([H("A", 1), H("A.1.1", 3), H("B", 1)], deepest: 1).Select(b => b.Title));
        Assert.Empty(HeadingBookmarks.Tree([H("A.1", 2)], deepest: 1));
    }

    [Fact]
    public void ReplacesTheBookmarks_OrAddsAfterThem()
    {
        var pdf = Bookmarks.SetOutline(Report(), null, [new Bookmark("Cover", 0)]);
        var headings = Find(pdf);

        var replaced = Bookmarks.Read(HeadingBookmarks.Write(pdf, null, headings, replace: true), null);
        Assert.Equal(["Chapter One", "Chapter Two"], replaced.Select(b => b.Title));
        Assert.Equal(["Background", "Method"], replaced[0].Children.Select(b => b.Title));
        Assert.Equal([0, 1], replaced[0].Children.Select(b => b.PageIndex));
        Assert.Equal(2, replaced[1].PageIndex);
        Assert.NotNull(replaced[0].Children[0].Top);

        var added = Bookmarks.Read(HeadingBookmarks.Write(pdf, null, headings, replace: false, deepest: 1), null);
        Assert.Equal(["Cover", "Chapter One", "Chapter Two"], added.Select(b => b.Title));
        Assert.All(added, b => Assert.Empty(b.Children));
    }

    [Fact]
    public void TitlesAreOneLine_AndBounded()
    {
        Assert.Equal("Part 2 Results", HeadingBookmarks.Title("  Part 2\n\tResults\u0007 "));
        var long_ = HeadingBookmarks.Title(string.Join(' ', Enumerable.Repeat("word", 100)));
        Assert.Equal(HeadingBookmarks.MaxTitle, long_.Length);
        Assert.EndsWith("…", long_);
    }

    [Fact]
    public void ASignedFileGetsThemAsAnAppendedChange()
    {
        var signed = SignedEditTests.Signed();
        var (edited, report) = SignedEdits.Run(() => HeadingBookmarks.Write(signed, null, [new FoundHeading("Contract", 1, 0, 72)], replace: true));
        Assert.True(report.Appended);
        Assert.True(edited.AsSpan(0, signed.Length).SequenceEqual(signed));
        Assert.Equal(SignatureStatus.ModifiedAfterSigning, Signatures.Verify(edited).Single(s => s.FieldName == "Approval").Status);
        Assert.Equal("Contract", Bookmarks.Read(edited, null).Single().Title);
    }

    [Fact]
    public void ALongTitleIsNeverCutInsideACharacter()
    {
        // An emoji (a surrogate pair) and an e with a combining accent where the cut falls.
        foreach (var tail in new[] { "😀😀😀", "ééé" })
        {
            var title = HeadingBookmarks.Title(new string('a', HeadingBookmarks.MaxTitle - 2) + tail);
            Assert.EndsWith("…", title);
            Assert.True(title.Length <= HeadingBookmarks.MaxTitle);
            Assert.DoesNotContain(System.Text.Rune.ReplacementChar, title.EnumerateRunes());
            Assert.False(title[^2] is '́', title); // an accent never stands without its letter
            Assert.Equal(title[..^1], string.Concat(title[..^1].EnumerateRunes().Select(r => r.ToString()))); // whole runes only
        }
    }

    [Fact]
    public void TheSearchSaysHowFarItIs_AndStopsWhenAsked()
    {
        using var engine = PdfEngine.Open(Report(), InputFileTypes.PDF, null);
        var seen = new List<(int Done, int Total)>();
        HeadingBookmarks.Find(engine, new DirectProgress<(int Done, int Total)>(seen.Add));
        Assert.Equal([(0, 3), (1, 3), (2, 3)], seen);
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => HeadingBookmarks.Find(engine, cancel: cts.Token));
    }
}
