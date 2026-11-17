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

    // ───────────────────────────── Review fixes ─────────────────────────────

    [Fact]
    public void RecoloringANoteRecolorsTheRepliesOnIt()
    {
        var pdf = Annotations.AddNote(TestPdf.Make(1), null, 0, 400, 300, "Look here", "Ana", id: "note-1");
        pdf = Annotations.AddReply(pdf, null, "note-1", "Seen", "Bo", "reply-1");
        AnnotColor green = new(0.15, 0.65, 0.2);
        pdf = Annotations.SetColor(pdf, null, "note-1", green);
        Assert.Equal(green, Get(pdf, "reply-1").Color);
        var shown = Pixel(pdf, 410, 306); // the reply's bubble lies on the note's
        Assert.True(shown is { G: > 120, R: < 100, B: < 100 }, $"green on the page: {shown}");
    }

    [Fact]
    public void AMarkOfTooManyLinesIsRefused_NotDrawnShort()
    {
        var lines = Enumerable.Range(0, Annotations.MaxQuads + 1).Select(i => new RectD(72 + i % 40, 100 + i % 600, 10, 1)).ToList();
        var pdf = Annotations.AddTextMarkup(TestPdf.Make(1), null, 0, TextMarkupKind.Highlight, lines, AnnotColor.Yellow, null, "Ana", "mark-1");
        Assert.Throws<InvalidOperationException>(() => Annotations.SetColor(pdf, null, "mark-1", AnnotColor.Red));
        var mark = Get(pdf, "mark-1");
        Assert.Null(DrawingGeometry.OfComment(mark)); // the page view and the Comments pane's Color offer nothing for it
        // A reply takes its comment's color: no color of its own to choose.
        var noted = Annotations.AddReply(Annotations.AddNote(TestPdf.Make(1), null, 0, 300, 300, "x", "Ana", id: "note-1"), null, "note-1", "y", "Bo", "reply-1");
        Assert.Null(DrawingGeometry.OfComment(Get(noted, "reply-1")));
    }

    [Fact]
    public void AMoveTakesRepliesOfEveryKindAndPopupsNamingTheirParent()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [5 0 R 6 0 R 7 0 R 8 0 R] >>",
            Core2Pdf.Stream(""),
            "<< /Type /Annot /Subtype /Text /NM (note-1) /Rect [100 600 120 620] /Name /Comment >>",
            "<< /Type /Annot /Subtype /FreeText /NM (reply-ft) /IRT 5 0 R /Rect [100 560 200 580] /DA (/Helv 10 Tf 0 g) /Contents (Seen) >>",
            "<< /Type /Annot /Subtype /Highlight /NM (reply-hl) /IRT 5 0 R /Rect [100 500 200 515] /QuadPoints [100 515 200 515 100 500 200 500] >>",
            "<< /Type /Annot /Subtype /Popup /Parent 5 0 R /Rect [130 600 300 680] >>",
        ]);
        var moved = Annotations.Move(pdf, null, "note-1", 10, 20); // 20 down the page: PDF y - 20
        var all = Annotations.Read(moved, null);
        Assert.Equal(110, all.Single(a => a.Id == "reply-ft").Rect.X, 0.01);
        var hl = all.Single(a => a.Id == "reply-hl");
        Assert.Equal(110, hl.QuadRects[0].X, 0.01);
        Assert.Equal(792 - 515 + 20, hl.QuadRects[0].Y, 0.01);
        using var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(moved), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var popup = ((PdfSharp.Pdf.PdfArray)doc.Pages[0].Elements.GetObject("/Annots")!).Elements
            .Select(e => (e as PdfSharp.Pdf.Advanced.PdfReference)?.Value as PdfSharp.Pdf.PdfDictionary)
            .Single(d => d?.Elements.GetName("/Subtype") == "/Popup")!;
        var r = popup.Elements.GetArray("/Rect")!;
        Assert.Equal(140, r.Elements.GetReal(0), 0.01);
        Assert.Equal(580, r.Elements.GetReal(1), 0.01);
    }

    [Fact]
    public void MoveToGoesWhereAsked_FromWhereTheDocumentHasIt()
    {
        var pdf = Annotations.AddNote(TestPdf.Make(1), null, 0, 400, 300, "Look here", "Ana", id: "note-1");
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Underline, [new RectD(380, 200, 120, 14), new RectD(360, 216, 80, 14)],
            AnnotColor.Red, null, "Ana", "mark-1");
        // A first move that never reached the document (cancelled) doesn't count: the second lands where it was shown.
        var once = Annotations.MoveTo(pdf, null, "note-1", 300, 250);
        Assert.Equal(300, Get(once, "note-1").Rect.X, 0.01);
        Assert.Equal(250, Get(once, "note-1").Rect.Y, 0.01);
        Assert.Same(once, Annotations.MoveTo(once, null, "note-1", 300, 250)); // already there: nothing to do
        // A mark's frame is its lines' bounds, as the page view shows it.
        var mark = Annotations.MoveTo(pdf, null, "mark-1", 100, 500);
        var bounds = DrawingGeometry.OfComment(Get(mark, "mark-1"))!.Bounds;
        Assert.Equal(100, bounds.X, 0.01);
        Assert.Equal(500, bounds.Y, 0.01);
        Assert.Throws<ArgumentOutOfRangeException>(() => Annotations.MoveTo(pdf, null, "note-1", double.NaN, 0));
    }

    [Fact]
    public void RecoloringAnotherAppsNoteKeepsItsIcon()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [5 0 R] >>",
            Core2Pdf.Stream(""),
            "<< /Type /Annot /Subtype /Text /NM (key-1) /Name /Key /Rect [100 600 120 620] /C [1 1 0] /F 4 /AP << /N 6 0 R >> >>",
            Core2Pdf.Stream("1 1 0 rg 0 0 20 20 re f", "/Type /XObject /Subtype /Form /BBox [0 0 20 20]"),
        ]);
        var red = Annotations.SetColor(pdf, null, "key-1", AnnotColor.Red);
        Assert.Equal(AnnotColor.Red, Get(red, "key-1").Color);
        var text = System.Text.Encoding.Latin1.GetString(red);
        Assert.Contains("/Key", text); // its icon, drawn by the viewer in the new color (MuPDF here)
        using var engine = PdfEngine.Open(red, InputFileTypes.PDF, null);
        var image = engine.Render(0, 1);
        var reddish = 0;
        for (var y = 172; y < 192; y++)
            for (var x = 100; x < 120; x++)
            {
                var i = y * image.Stride + x * 3; // BGR
                if (image.Pixels[i + 2] > 150 && image.Pixels[i + 1] < 90 && image.Pixels[i] < 90) reddish++;
            }
        Assert.True(reddish > 20, $"the key icon in red: {reddish} pixels");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void AMarksLinesRunTheWayThePageShowsThem(int rotation)
    {
        var pdf = rotation == 0 ? TestPdf.Make(1) : PageEditor.Rotate(TestPdf.Make(1), null, [0], rotation);
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Underline, [new RectD(100, 300, 150, 14)], AnnotColor.Red, null, "Ana", "mark-1");
        // Text drawn the usual way on the page runs along the turned page: its baseline start and end, as shown.
        var mark = Get(pdf, "mark-1");
        Assert.Equal(rotation, mark.PageRotation);
        var line = DrawingGeometry.OfComment(mark)!.Paths[0];
        var (along, up) = (new PointD(line[1].X - line[0].X, line[1].Y - line[0].Y), new PointD(line[3].X - line[0].X, line[3].Y - line[0].Y));
        // Which way the PDF's own x axis runs on the shown page (the baseline), and its y axis (up from it).
        var o = PdfObjAt(pdf, 0, 0);
        var ex = PdfObjAt(pdf, 1, 0);
        var ey = PdfObjAt(pdf, 0, 1);
        double Dot(PointD v, (double X, double Y) a, (double X, double Y) b) => v.X * (b.X - a.X) + v.Y * (b.Y - a.Y);
        Assert.True(Dot(along, o, ex) > 0, "the baseline runs with the text");
        Assert.True(Dot(up, o, ey) > 0, "up from the baseline is up the text");
        Assert.Equal(mark.QuadRects[0], DrawingGeometry.OfComment(mark)!.Box); // the bounds a press is checked against first
    }

    /// <summary>Where a PDF-space point (x, y) of the first page is in page space.</summary>
    private static (double X, double Y) PdfObjAt(byte[] pdf, double x, double y)
    {
        using var doc = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(pdf), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var r = FormEditor.ToPageSpace(doc.Pages[0], x, y, x, y);
        return (r.X, r.Y);
    }

    [Fact]
    public void TheHandToolPansOverTextMarks_UntilOneIsSelected()
    {
        var pdf = Annotations.AddNote(TestPdf.Make(1), null, 0, 400, 300, "Look here", "Ana", id: "note-1");
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Highlight, [new RectD(380, 200, 120, 14)], AnnotColor.Yellow, null, "Ana", "mark-1");
        pdf = Annotations.AddShape(pdf, null, 0, ShapeKind.Rectangle, new RectD(100, 500, 50, 40), AnnotStyle.Pen(AnnotColor.Red), "Ana", "box-1");
        var mark = Get(pdf, "mark-1");
        Assert.Equal(DrawingGeometry.HandPress.PanOrSelect, DrawingGeometry.OnHandPress(mark, selected: false));
        Assert.Equal(DrawingGeometry.HandPress.Move, DrawingGeometry.OnHandPress(mark, selected: true));
        Assert.Equal(DrawingGeometry.HandPress.Move, DrawingGeometry.OnHandPress(Get(pdf, "note-1"), selected: false)); // as on the Mac
        Assert.Equal(DrawingGeometry.HandPress.Move, DrawingGeometry.OnHandPress(Get(pdf, "box-1"), selected: false));
    }

    // ───────────────────────────── Hostile input ─────────────────────────────

    [Fact]
    public void ANumberThatIsntOne_IsNeverWrittenBack_AndSuchAMarkIsntOffered()
    {
        // A 400-digit /Rect corner reads as infinity: the mark's lines are fine, its box isn't; so is a reply's box.
        var huge = "1" + new string('0', 400);
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [5 0 R 6 0 R 7 0 R] >>",
            Core2Pdf.Stream(""),
            $"<< /Type /Annot /Subtype /Highlight /NM (mark-1) /Rect [100 100 {huge} 120] /QuadPoints [100 120 200 120 100 100 200 100] >>",
            "<< /Type /Annot /Subtype /Text /NM (note-1) /Rect [300 600 320 620] >>",
            $"<< /Type /Annot /Subtype /Text /NM (reply-1) /IRT 6 0 R /Rect [300 600 {huge} 620] >>",
        ]);
        Assert.Null(DrawingGeometry.OfComment(Get(pdf, "mark-1"))); // the page view doesn't offer it
        Assert.Throws<InvalidOperationException>(() => Annotations.Move(pdf, null, "mark-1", 5, 5));
        Assert.Throws<InvalidOperationException>(() => Annotations.MoveTo(pdf, null, "mark-1", 50, 50));
        // The note moves; its reply's broken box stays as it is, and the file still reads and edits.
        var moved = Annotations.Move(pdf, null, "note-1", 10, 0);
        Assert.DoesNotContain("Infinity", System.Text.Encoding.Latin1.GetString(moved));
        Assert.Equal(310, Get(moved, "note-1").Rect.X, 0.01);
        Assert.Equal(300, Get(moved, "reply-1").Rect.X, 0.01);
        Assert.True(double.IsFinite(Get(moved, "reply-1").Rect.Width)); // written back as the largest real, read as one
        Annotations.SetColor(moved, null, "note-1", AnnotColor.Red);
        // Nothing writes a number that isn't one.
        using var doc = new PdfSharp.Pdf.PdfDocument();
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfObj.Reals(doc, 1, double.PositiveInfinity));
        Assert.Throws<ArgumentOutOfRangeException>(() => PdfObj.Reals(doc, double.NaN));
    }

    [Fact]
    public void ANoteListedOnTwoPagesMoves()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << >> /Annots [6 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << >> /Annots [6 0 R] >>",
            Core2Pdf.Stream(""),
            "<< /Type /Annot /Subtype /Text /NM (note-1) /Rect [100 600 120 620] >>",
        ]);
        var before = Annotations.Read(pdf, null).First(a => a.Id == "note-1").Rect;
        var moved = Annotations.MoveTo(pdf, null, "note-1", before.X + 50, before.Y);
        Assert.All(Annotations.Read(moved, null).Where(a => a.Id == "note-1"), a => Assert.Equal(before.X + 50, a.Rect.X, 0.01));
    }

    [Fact]
    public void LineListsAreBounded_PerMarkAndPerPage_ForSelecting()
    {
        // One mark lists more lines than any is drawn for; ten more share one indirect list of 15,000 lines.
        static string Lines(int n) => string.Join(' ', Enumerable.Range(0, n).Select(i => $"72 {700 - i % 600} 82 {700 - i % 600} 72 {699 - i % 600} 82 {699 - i % 600}"));
        var shared = Enumerable.Range(7, 10).Select(i => $"<< /Type /Annot /Subtype /Highlight /NM (shared-{i}) /Rect [72 100 82 700] /QuadPoints 6 0 R >>");
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [{string.Join(' ', Enumerable.Range(5, 12).Where(i => i != 6).Select(i => $"{i} 0 R"))}] >>",
            Core2Pdf.Stream(""),
            $"<< /Type /Annot /Subtype /Highlight /NM (huge) /Rect [72 100 82 700] /QuadPoints [{Lines(Annotations.MaxQuads + 5_000)}] >>",
            $"[{Lines(15_000)}]",
            .. shared,
        ]);
        var all = Annotations.Read(pdf, null);
        Assert.Equal(Annotations.MaxQuads + 1, all.Single(a => a.Id == "huge").QuadRects.Count); // enough to know it's too many
        Assert.Equal(15_000, all.First(a => a.Id == "shared-7").QuadRects.Count);

        // The page view gives selection geometry only while the page's budget of lines lasts.
        var shown = DrawingGeometry.WithCommentGeometry(all).ToList();
        Assert.Null(shown.Single(a => a.Id == "huge").Geometry);
        var selectable = shown.Where(a => a.Id.StartsWith("shared-") && a.Geometry is not null).ToList();
        Assert.Equal(new[] { "shared-7", "shared-8", "shared-9" }, selectable.Select(a => a.Id));
        var g = selectable[0].Geometry!;
        Assert.True(DrawingGeometry.Hit("Highlight", g, null, new PointD(77, 92.5), 0.5)); // on a line
        Assert.False(DrawingGeometry.Hit("Highlight", g, null, new PointD(90, 92.5), 0.5)); // past its end
    }

    [Fact]
    public void AThreadListedBackwardsIsFoundInOnePass()
    {
        // 20,000 replies, each to the one before, listed last first: a pass per reply took ~50 s.
        using var doc = new PdfSharp.Pdf.PdfDocument();
        doc.AddPage();
        PdfSharp.Pdf.PdfDictionary Note()
        {
            var d = new PdfSharp.Pdf.PdfDictionary(doc);
            d.Elements["/Type"] = new PdfSharp.Pdf.PdfName("/Annot");
            d.Elements["/Subtype"] = new PdfSharp.Pdf.PdfName("/Text");
            doc.Internals.AddObject(d);
            return d;
        }
        var root = Note();
        var chain = new List<PdfSharp.Pdf.PdfDictionary> { root };
        for (var k = 0; k < 20_000; k++)
        {
            var r = Note();
            r.Elements["/IRT"] = chain[^1].Reference!;
            chain.Add(r);
        }
        chain.Reverse();
        doc.Pages[0].Elements["/Annots"] = new PdfSharp.Pdf.PdfArray(doc, [.. chain.Select(d => (PdfSharp.Pdf.PdfItem)d.Reference!)]);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var thread = Annotations.ThreadOf(doc, root);
        Assert.Equal(20_001, thread.Count);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(5), $"{sw.Elapsed}");
    }

    [Fact]
    public void ANoteWithStrayLinesMovesByItsIcon()
    {
        // Another app's note with /QuadPoints near the corner: the page view drags its icon (/Rect), and so does MoveTo.
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [5 0 R] >>",
            Core2Pdf.Stream(""),
            "<< /Type /Annot /Subtype /Text /NM (note-1) /Rect [300 300 320 320] /QuadPoints [0 10 10 10 0 0 10 0] >>",
        ]);
        var box = DrawingGeometry.OfComment(Get(pdf, "note-1"))!.Box;
        var moved = Get(Annotations.MoveTo(pdf, null, "note-1", box.X + 10, box.Y), "note-1");
        Assert.Equal(box.X + 10, moved.Rect.X, 0.01);
        Assert.Equal(box.Y, moved.Rect.Y, 0.01);
    }
}
