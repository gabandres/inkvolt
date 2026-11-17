using MuPDFCore;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// <see cref="Annotations.Move"/> and <see cref="Annotations.SetColor"/>: sticky notes and text marks (highlight,
/// underline, strike-out, squiggly) moved and recolored in place, keeping their id, text, replies and appearance. The
/// Mac's CommentMoveTests (same names), plus signed files, hostile input and the page view's geometry for them.
/// </summary>
public class CommentMoveTests
{
    /// <summary>The pixel at a page point (page space, 1 px per point), as R, G, B.</summary>
    private static (int R, int G, int B) Pixel(byte[] pdf, double x, double y)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var image = engine.Render(0, 1);
        var i = (int)y * image.Stride + (int)x * 3; // BGR
        return (image.Pixels[i + 2], image.Pixels[i + 1], image.Pixels[i]);
    }

    private static bool IsWhite((int R, int G, int B) p) => p.R > 240 && p.G > 240 && p.B > 240;

    private static AnnotationInfo Get(byte[] pdf, string id) => Annotations.Read(pdf, null).Single(a => a.Id == id);

    [Fact]
    public void NotesMoveWithTheirAppearance()
    {
        var pdf = TestPdf.Make(1);
        pdf = Annotations.AddNote(pdf, null, 0, 400, 300, "Look here", "Ana", id: "note-1");
        pdf = Annotations.AddReply(pdf, null, "note-1", "Seen", "Bo", "reply-1");
        Assert.False(IsWhite(Pixel(pdf, 410, 310)));
        var moved = Annotations.Move(pdf, null, "note-1", 60, 120);
        var note = Get(moved, "note-1");
        Assert.Equal(460, note.Rect.X, 0.01);
        Assert.Equal(420, note.Rect.Y, 0.01);
        Assert.Equal(20, note.Rect.Width, 0.01);
        Assert.Equal("Look here", note.Contents);
        Assert.Equal("Ana", note.Author);
        var reply = Get(moved, "reply-1"); // the reply came along
        Assert.Equal("note-1", reply.ReplyTo);
        Assert.Equal(460, reply.Rect.X, 0.01);
        Assert.Equal(420, reply.Rect.Y, 0.01);
        var there = Pixel(moved, 470, 426);
        Assert.True(there is { R: > 200, G: > 180, B: < 120 }, $"the yellow bubble came along: {there}");
        Assert.True(IsWhite(Pixel(moved, 410, 310)));
    }

    [Fact]
    public void TextMarksMoveWithTheirQuads()
    {
        var pdf = TestPdf.Make(1);
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Highlight, [new RectD(380, 200, 120, 14), new RectD(380, 216, 80, 14)],
            AnnotColor.Yellow, null, "Ana", "mark-1");
        var moved = Annotations.Move(pdf, null, "mark-1", -20, 150);
        var mark = Get(moved, "mark-1");
        Assert.Equal(2, mark.QuadRects.Count);
        Assert.Equal(360, mark.QuadRects[0].X, 0.01);
        Assert.Equal(350, mark.QuadRects[0].Y, 0.01);
        Assert.Equal(366, mark.QuadRects[1].Y, 0.01);
        Assert.Equal(80, mark.QuadRects[1].Width, 0.01);
        var there = Pixel(moved, 420, 357);
        Assert.True(there is { B: < 120, R: > 200 }, $"yellow, multiplied onto white: {there}");
        Assert.True(IsWhite(Pixel(moved, 440, 207)));
    }

    [Fact]
    public void RecoloringRedrawsNotesAndTextMarks()
    {
        var pdf = TestPdf.Make(1);
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Highlight, [new RectD(380, 200, 120, 14)], AnnotColor.Yellow, null, "Ana", "mark-1");
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Underline, [new RectD(380, 400, 120, 14)], AnnotColor.Red, null, "Ana", "line-1");
        pdf = Annotations.AddNote(pdf, null, 0, 400, 300, "Look here", "Ana", id: "note-1");
        AnnotColor blue = new(0.1, 0.4, 0.9), green = new(0.15, 0.65, 0.2);
        pdf = Annotations.SetColor(pdf, null, "mark-1", blue);
        pdf = Annotations.SetColor(pdf, null, "line-1", green);
        pdf = Annotations.SetColor(pdf, null, "note-1", green);
        Assert.Equal(blue, Get(pdf, "mark-1").Color);
        Assert.Equal(green, Get(pdf, "line-1").Color);
        Assert.Equal(green, Get(pdf, "note-1").Color);
        Assert.Single(Get(pdf, "mark-1").QuadRects);
        var mark = Pixel(pdf, 440, 207);
        Assert.True(mark is { B: > 200, R: < 80 }, $"blue now: {mark}");
        var note = Pixel(pdf, 410, 306);
        Assert.True(note is { G: > 120, R: < 100, B: < 100 }, $"green bubble: {note}");
        // A second recolor and a move after it keep the new look.
        var again = Annotations.Move(Annotations.SetColor(pdf, null, "mark-1", AnnotColor.Yellow), null, "mark-1", 0, 40);
        var moved = Pixel(again, 440, 247);
        Assert.True(moved is { R: > 200, B: < 120 }, $"yellow where it went: {moved}");
    }

    [Fact]
    public void OnlyNotesAndTextMarksMoveThisWay()
    {
        var pdf = Annotations.AddShape(TestPdf.Make(1), null, 0, ShapeKind.Rectangle, new RectD(100, 100, 50, 40), AnnotStyle.Pen(AnnotColor.Red), "Ana", "box-1");
        Assert.Throws<InvalidOperationException>(() => Annotations.Move(pdf, null, "box-1", 10, 10));
        Assert.Throws<InvalidOperationException>(() => Annotations.SetColor(pdf, null, "box-1", AnnotColor.Yellow));
        Assert.Throws<InvalidOperationException>(() => Annotations.Move(pdf, null, "missing", 10, 10));
        // Nothing to do: the same bytes back.
        var noted = Annotations.AddNote(pdf, null, 0, 300, 300, "x", "Ana", id: "note-1");
        Assert.Same(noted, Annotations.Move(noted, null, "note-1", 0, 0));
    }

    [Fact]
    public void MovesFollowThePageAsShownOnRotatedPages()
    {
        var pdf = PageEditor.Rotate(TestPdf.Make(1), null, [0], 90);
        pdf = Annotations.AddNote(pdf, null, 0, 300, 200, "Sideways", "Ana", id: "note-1");
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.StrikeOut, [new RectD(100, 400, 150, 14)], AnnotColor.Red, null, "Ana", "mark-1");
        var moved = Annotations.Move(Annotations.Move(pdf, null, "note-1", 40, 25), null, "mark-1", 30, -50);
        var note = Get(moved, "note-1");
        var mark = Get(moved, "mark-1");
        Assert.Equal(340, note.Rect.X, 0.01);
        Assert.Equal(225, note.Rect.Y, 0.01);
        Assert.Equal(130, mark.QuadRects[0].X, 0.01);
        Assert.Equal(350, mark.QuadRects[0].Y, 0.01);
        Assert.Equal(150, mark.QuadRects[0].Width, 0.01);
    }

    // ───────────────────────────── Windows additions ─────────────────────────────

    [Fact]
    public void MovingAndRecoloringASignedFileIsAppended_AndKeepsItsSignature()
    {
        var pdf = SignedEditTests.Signed();
        var signatures = Signatures.Verify(pdf);
        var noted = SignedEdits.Run(() => Annotations.AddNote(pdf, null, 0, 300, 300, "Remark", "Me", id: "note-1")).Data;
        var (moved, report) = SignedEdits.Run(() => Annotations.Move(noted, null, "note-1", 20, 20));
        Assert.Equal(new SignedEditReport(true, false), report);
        var (recolored, report2) = SignedEdits.Run(() => Annotations.SetColor(moved, null, "note-1", AnnotColor.Red));
        Assert.Equal(new SignedEditReport(true, false), report2);
        Assert.True(recolored.AsSpan(0, pdf.Length).SequenceEqual(pdf));
        Assert.Empty(Signatures.BrokenByEdits(signatures, recolored));
        Assert.Equal(320, Get(recolored, "note-1").Rect.X, 0.01);
    }

    [Theory]
    [InlineData(double.NaN, 0)]
    [InlineData(0, double.PositiveInfinity)]
    [InlineData(double.NegativeInfinity, 5)]
    [InlineData(1e300, 0)]
    public void AMoveThatIsntANumber_IsRefused(double dx, double dy)
    {
        var pdf = Annotations.AddNote(TestPdf.Make(1), null, 0, 300, 300, "x", "Ana", id: "note-1");
        Assert.Throws<ArgumentOutOfRangeException>(() => Annotations.Move(pdf, null, "note-1", dx, dy));
    }

    [Theory]
    [InlineData(double.NaN, 0, 0)]
    [InlineData(0, double.PositiveInfinity, 0)]
    [InlineData(0, 0, 2)]
    [InlineData(-0.5, 0, 0)]
    public void AColorThatIsntOneIsRefused(double r, double g, double b)
    {
        var pdf = Annotations.AddNote(TestPdf.Make(1), null, 0, 300, 300, "x", "Ana", id: "note-1");
        Assert.Throws<ArgumentOutOfRangeException>(() => Annotations.SetColor(pdf, null, "note-1", new AnnotColor(r, g, b)));
    }

    [Fact]
    public void BrokenMarksFromAnotherApp_MoveAndRecolorWithoutFailing()
    {
        // Quad points short of a line, names where numbers go, an odd count; a note with no /Rect.
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [5 0 R 6 0 R 7 0 R] >>",
            Core2Pdf.Stream(""),
            "<< /Type /Annot /Subtype /Highlight /NM (short) /Rect [100 100 200 120] /QuadPoints [100 120 200] >>",
            "<< /Type /Annot /Subtype /Underline /NM (names) /Rect [100 200 200 220] /QuadPoints [/a /b 200 220 100 200 200 200 300] >>",
            "<< /Type /Annot /Subtype /Text /NM (norect) >>",
        ]);
        foreach (var id in new[] { "short", "names", "norect" })
        {
            var moved = Annotations.Move(pdf, null, id, 10, 10);
            var recolored = Annotations.SetColor(moved, null, id, AnnotColor.Red);
            Assert.Equal(AnnotColor.Red, Get(recolored, id).Color);
        }
        using var engine = PdfEngine.Open(Annotations.SetColor(pdf, null, "names", AnnotColor.Red), InputFileTypes.PDF, null);
        engine.Render(0, 1);
    }

    [Fact]
    public void ThePageViewSelectsNotesAndTextMarks_ButNotRepliesOrHugeMarks()
    {
        var pdf = TestPdf.Make(1);
        pdf = Annotations.AddNote(pdf, null, 0, 400, 300, "Look here", "Ana", id: "note-1");
        pdf = Annotations.AddReply(pdf, null, "note-1", "Seen", "Bo", "reply-1");
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Highlight, [new RectD(380, 200, 120, 14), new RectD(380, 216, 80, 14)],
            AnnotColor.Yellow, null, "Ana", "mark-1");
        pdf = Annotations.AddShape(pdf, null, 0, ShapeKind.Rectangle, new RectD(100, 500, 50, 40), AnnotStyle.Pen(AnnotColor.Red), "Ana", "box-1");

        var note = DrawingGeometry.OfComment(Get(pdf, "note-1"))!;
        Assert.Equal(400, note.Box.X, 0.01);
        Assert.True(DrawingGeometry.Hit("Text", note, null, new PointD(410, 310), 1));
        Assert.Null(DrawingGeometry.OfComment(Get(pdf, "reply-1")));
        Assert.Null(DrawingGeometry.OfComment(Get(pdf, "box-1")));
        Assert.True(Annotations.MovesInPlace(Get(pdf, "mark-1")));
        Assert.False(Annotations.MovesInPlace(Get(pdf, "box-1")));

        var mark = DrawingGeometry.OfComment(Get(pdf, "mark-1"))!;
        Assert.Equal(2, mark.Paths.Count);
        Assert.True(DrawingGeometry.Hit("Highlight", mark, null, new PointD(450, 207), 1));
        Assert.False(DrawingGeometry.Hit("Highlight", mark, null, new PointD(480, 223), 1)); // past the shorter second line
        Assert.Equal(new RectD(380, 200, 120, 30), mark.Bounds with { X = Math.Round(mark.Bounds.X), Y = Math.Round(mark.Bounds.Y), Width = Math.Round(mark.Bounds.Width), Height = Math.Round(mark.Bounds.Height) });

        // A hostile file's mark of a million lines, or one at NaN, isn't picked up.
        var huge = Get(pdf, "mark-1") with { QuadRects = [.. Enumerable.Repeat(new RectD(1, 1, 1, 1), Annotations.MaxQuads + 1)] };
        Assert.Null(DrawingGeometry.OfComment(huge));
        Assert.Null(DrawingGeometry.OfComment(Get(pdf, "mark-1") with { QuadRects = [new RectD(double.NaN, 1, 1, 1)] }));
        Assert.Null(DrawingGeometry.OfComment(Get(pdf, "note-1") with { Rect = new RectD(double.PositiveInfinity, 1, 20, 20) }));
    }
}
