using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Edit Text &amp; Images (roadmap 2.1): pictures in a paragraph's flow, and cropping pictures.</summary>
public partial class ParagraphEditTests
{
    private static void Near(RectD expected, RectD actual, double within = 0.6)
    {
        Assert.True(Math.Abs(expected.X - actual.X) < within && Math.Abs(expected.Y - actual.Y) < within &&
                    Math.Abs(expected.Width - actual.Width) < within && Math.Abs(expected.Height - actual.Height) < within, $"{expected} ≠ {actual}");
    }

    // ---- Pictures in the flow ----

    /// <summary>
    /// Body as a left-aligned paragraph with a 12 x 9 pt picture (/Im1) on its second line after its third word, its
    /// foot a point below the baseline, the words around it 18 pt apart; a line of text under the paragraph.
    /// </summary>
    /// <param name="line">The line it is on (its third word before it).</param>
    /// <param name="height">Its height (points).</param>
    private static (byte[] Pdf, string Pre) WithPicture(int line = 1, double height = 9)
    {
        var lines = Wrap(Body, Width - 30);
        var words = lines[line].Split(' ');
        var pre = string.Join(' ', words.Take(3));
        var post = string.Join(' ', words.Skip(3));
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top)} Td");
        for (var i = 0; i < lines.Count; i++)
        {
            if (i > 0) sb.Append(" T*");
            sb.Append(i == line ? $" ({pre}) Tj [{N(-18 * 1000 / Size)}] TJ ({post}) Tj" : $" ({lines[i]}) Tj");
        }
        sb.Append(" 0 -60 Td (Next block starts here) Tj ET\n");
        var x = Left + Measure(pre) + 3;
        sb.Append($"q 12 0 0 {N(height)} {N(x)} {N(Top - line * Step - 1)} cm /Im1 Do Q\n");
        return (ContentEditPdf.Make(sb.ToString(), fontText: Chars), pre);
    }

    [Fact]
    public void TakingATallPictureOffTheFirstLineLiftsNothing()
    {
        // A picture twice the type's height on the first line: without it, the first line stays where it was.
        var (pdf, _) = WithPicture(line: 0, height: 22);
        var p = Body0(pdf);
        Assert.Single(p.Pictures);
        var first = p.Runs[0].Origin.Y;
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, p.Text.Replace(" ￼", "", StringComparison.Ordinal));
        Assert.Equal(first, Body0(edited).Runs[0].Origin.Y, 1);
        // Kept, and unchanged text in front of it: the first line stays too.
        var same = ContentEditor.ReplaceParagraph(pdf, null, p, p.Text + " end");
        Assert.Equal(first, Body0(same).Runs[0].Origin.Y, 1);
    }

    [Fact]
    public void APictureBeforeALineThatIsntInTheFlowDoesntWidenIt()
    {
        // The second line starts after a picture lined up with the line above, but its foot hangs 7 points below the
        // baseline: not a picture in the flow, so the line isn't widened to it and rewritten text isn't drawn over it.
        var lines = Wrap(Body, Width);
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Left)} {N(Top)} Td ({lines[0]}) Tj ET\n");
        sb.Append($"BT /FA {N(Size)} Tf {N(Left + 16)} {N(Top - Step)} Td ({lines[1]}) Tj ET\n");
        sb.Append($"q 12 0 0 9 {N(Left)} {N(Top - Step - 7)} cm /Im1 Do Q\n");
        var pdf = ContentEditPdf.Make(sb.ToString(), fontText: Chars);
        var content = ContentEditor.Read(pdf, null, 0);
        var picture = content.Images.Single().Box;
        foreach (var p in content.Paragraphs.Where(q => q.Blocked is null))
        {
            Assert.Empty(p.Pictures);
            var edited = ContentEditor.ReplaceParagraph(pdf, null, p, p.Text + " and a few more words here", allowOverlap: true);
            Assert.DoesNotContain(ContentEditor.Read(edited, null, 0).Runs, r => r.Box.Intersect(picture) is { Width: > 1, Height: > 1 });
        }
    }

    [Fact]
    public void AMarkThePagesOwnTextHasIsNoPicture()
    {
        // The text has a U+FFFC of its own (a glyph whose ToUnicode says so) before the picture's mark: each keeps its part.
        const string old = "a ￼ b ￼ c";
        InlinePicture[] pictures = [new InlinePicture(new PageImage(0, 1, new RectD(0, 0, 1, 1), false, null), 0) { Mark = 6 }];
        Assert.Equal([ContentEditor.TextMark, 0], ContentEditor.PictureMarks(old, old, pictures));
        Assert.Equal([ContentEditor.TextMark, 0], ContentEditor.PictureMarks(old, "x " + old, pictures));
        Assert.Equal([0], ContentEditor.PictureMarks(old, "a b ￼ c", pictures)); // the page's own one deleted
        Assert.Equal([ContentEditor.TextMark], ContentEditor.PictureMarks(old, "a ￼ b c", pictures)); // the picture's deleted
        Assert.Equal([ContentEditor.TextMark, 0, -1], ContentEditor.PictureMarks(old, old + " ￼", pictures)); // one typed in
    }

    [Fact]
    public void APictureOnAParagraphsLineIsPartOfItsFlow()
    {
        var (pdf, pre) = WithPicture();
        var content = ContentEditor.Read(pdf, null, 0);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        var picture = Assert.Single(p.Pictures);
        Assert.Equal(content.Images.Single(), picture.Image);
        Assert.Equal(1, picture.Drop, 1);
        Assert.Contains(pre + " ￼ ", p.Text);
        Assert.Equal(Body, p.Text.Replace(" ￼", "", StringComparison.Ordinal));
    }

    [Fact]
    public void ThePictureMovesWithItsPlaceInTheText()
    {
        var (pdf, pre) = WithPicture();
        var p = Body0(pdf);
        var old = p.Pictures[0].Image.Box;
        var text = "Now then, a few more words in front " + p.Text;
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
        var content = ContentEditor.Read(edited, null, 0);
        var image = content.Images.Single();
        Assert.False(Math.Abs(image.Box.X - old.X) < 1 && Math.Abs(image.Box.Y - old.Y) < 1, "moved");
        Assert.Equal(old.Width, image.Box.Width, 1);
        Assert.Equal(old.Height, image.Box.Height, 1);
        // Read again, the picture is in the same place of the text, between the same words, its foot as far below its line.
        var q = Body0(edited, "Now then");
        Assert.Equal(text, q.Text);
        Assert.Equal(1, Assert.Single(q.Pictures).Drop, 1);
        var lastPre = pre.Split(' ')[^1];
        var before = q.Runs.Last(r => r.Text.TrimEnd().EndsWith(lastPre, StringComparison.Ordinal) && r.Box.Right <= image.Box.X + 0.5 && Math.Abs(r.Box.CenterY - image.Box.CenterY) < Size);
        Assert.True(image.Box.X - before.Box.Right < 0.5 * Size + 3);
        // One edit, one undo step: the earlier bytes have the picture where it was.
        Near(old, ContentEditor.Read(pdf, null, 0).Images.Single().Box);
    }

    [Fact]
    public void APictureWrappedToTheStartOfALineIsStillInTheSameParagraph()
    {
        // The picture moved to the front, after a word that grows until the picture no longer fits beside it and starts
        // the second line: read again, it is one paragraph with the same text.
        var (pdf, _) = WithPicture();
        var p = Body0(pdf);
        var rest = p.Text.Replace(" ￼", "", StringComparison.Ordinal);
        for (var n = 60; n <= 160; n++)
        {
            var text = "Now" + new string('i', n) + " ￼ " + rest;
            var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text, allowOverlap: true);
            var image = ContentEditor.Read(edited, null, 0).Images.Single();
            if (Math.Abs(image.Box.X - Left) > 1) continue;
            var q = Body0(edited, "Now");
            Assert.Equal(text, q.Text);
            Assert.Equal(1, Assert.Single(q.Pictures).Drop, 1);
            return;
        }
        Assert.Fail("the picture never started a line");
    }

    [Fact]
    public void TakingThePicturesMarkOutTakesThePictureOff()
    {
        var (pdf, _) = WithPicture();
        var p = Body0(pdf);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, p.Text.Replace(" ￼", "", StringComparison.Ordinal));
        var content = ContentEditor.Read(edited, null, 0);
        Assert.Empty(content.Images);
        Assert.Equal(Body, Body0(edited).Text);
        Assert.DoesNotContain("/Im1 Do", ContentEditPdf.Content(edited));
    }

    [Fact]
    public void AMarkTypedInIsNoPicture()
    {
        var (pdf, _) = WithPicture();
        var p = Body0(pdf);
        var text = p.Text + " ￼";
        Assert.Contains("￼", p.Check(text).Missing);
        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(pdf, null, p, text));
        Assert.Contains("can't be typed", ex.Message);
        // A paragraph without pictures: the mark is no picture either.
        var (plain, _) = Page(ParagraphAlign.Left);
        Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(plain, null, Body0(plain), Body + " ￼"));
    }

    [Fact]
    public void APictureUnderTheTextIsNotInItsFlow()
    {
        // A picture the paragraph's text is drawn over (a background) stays where it is, outside the text.
        var (page, _) = Page(ParagraphAlign.Left, gap: 120);
        var pdf = ContentEditPdf.Make(ContentEditPdf.Content(page) + $"\nq 60 0 0 9 {N(Left + 10)} {N(Top - 1)} cm /Im1 Do Q\n", fontText: Chars);
        var p = Body0(pdf);
        Assert.Empty(p.Pictures);
        Assert.Equal(Body, p.Text);
    }

    // ---- New pictures in the flow ----

    /// <summary>A 30 x 10 pixel PNG, orange.</summary>
    private static NewPicture Orange() =>
        new(PngEncoder.Encode(30, 10, [.. Enumerable.Repeat(new byte[] { 255, 140, 0 }, 300).SelectMany(x => x)], false), "orange.png");

    [Fact]
    public void ANewPictureGoesIntoTheFlowWhereItsMarkIs()
    {
        var (pdf, _) = Page(ParagraphAlign.Left, gap: 120);
        var p = Body0(pdf);
        Assert.Empty(p.Pictures);
        var text = p.Text.Replace("boxing", "boxing ￼", StringComparison.Ordinal);
        // The editor's note: the mark stands for the picture, nothing missing.
        Assert.Empty(p.Check(text, added: [Orange()]).Missing);
        Assert.Contains("￼", p.Check(text).Missing); // without the picture: a mark for nothing
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text, added: [Orange()]);
        var image = ContentEditor.Read(edited, null, 0).Images.Single();
        // As tall as the capitals reach, three times as wide, its foot on the baseline, after "boxing".
        Assert.Equal(3 * image.Box.Height, image.Box.Width, 1);
        Assert.True(image.Box.Height > 0.6 * Size && image.Box.Height < 1.1 * Size);
        var q = Body0(edited);
        Assert.Equal(text, q.Text);
        var pic = Assert.Single(q.Pictures);
        Assert.Equal(0, pic.Drop, 1);
        var boxing = q.Runs.Single(r => r.Text.TrimEnd().EndsWith("boxing", StringComparison.Ordinal));
        Assert.True(image.Box.X >= boxing.Box.Right - 0.5 && image.Box.X - boxing.Box.Right < 0.5 * Size); // its run ends with the space before it
        // Its pixels are the file's: orange.
        Assert.Contains(PicturesIn(edited), x => (x.W, x.H) == (30, 10) && Holds(x.Samples, 255, 140, 0));
        // Edited again, it is one of the paragraph's pictures and moves with its words.
        var again = ContentEditor.ReplaceParagraph(edited, null, q, "Now then " + q.Text);
        Assert.Equal("Now then " + text, Body0(again, "Now then").Text);
    }

    [Theory]
    [InlineData("flipped")]
    [InlineData("scaled")]
    public void ANewPictureUnderTheGeneratorsOwnCtmLandsByItsWord(string kind)
    {
        // The text drawn under a cm of the generator's: flipped (top-down, as many converters write) or scaled by 0.5.
        var lines = Wrap(Body, Width);
        var sb = new StringBuilder(kind == "flipped" ? "q 1 0 0 -1 0 792 cm BT /FA 11 Tf" : "q 0.5 0 0 0.5 0 0 cm BT /FA 22 Tf");
        for (var i = 0; i < lines.Count; i++)
        {
            var y = Top - i * Step;
            sb.Append(kind == "flipped" ? $" 1 0 0 -1 {N(Left)} {N(792 - y)} Tm ({lines[i]}) Tj" : $" 1 0 0 1 {N(2 * Left)} {N(2 * y)} Tm ({lines[i]}) Tj");
        }
        sb.Append(" ET Q\nBT /FA 11 Tf 72 500 Td (Next block starts here) Tj ET");
        var pdf = ContentEditPdf.Make(sb.ToString(), fontText: Chars);
        var p = Body0(pdf);
        var text = p.Text.Replace("boxing", "boxing \uFFFC", StringComparison.Ordinal);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text, added: [Orange()]);
        var image = ContentEditor.Read(edited, null, 0).Images.Single();
        var q = Body0(edited);
        var boxing = q.Runs.Single(r => r.Text.TrimEnd().EndsWith("boxing", StringComparison.Ordinal));
        Assert.True(Math.Abs(image.Box.Bottom - boxing.Origin.Y) < 1, $"{image.Box} on {boxing.Origin}"); // its foot on the baseline
        Assert.True(image.Box.X >= boxing.Box.Right - 0.5 && image.Box.X - boxing.Box.Right < 0.5 * Size);
        Assert.Equal(3 * image.Box.Height, image.Box.Width, 1);
        Assert.Equal(text, q.Text);
    }

    [Fact]
    public void AnInsertedMarkIsTheNewPicturesThoughAnOldOneMoved()
    {
        // The paragraph's picture cut from its line and pasted at the end; a new one inserted at the start: each its own.
        var (pdf, _) = WithPicture();
        var p = Body0(pdf);
        var text = "\uFFFC " + p.Text.Replace(" \uFFFC", "", StringComparison.Ordinal) + " \uFFFC";
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text, allowOverlap: true, added: [Orange() with { Mark = 0 }]);
        var images = ContentEditor.Read(edited, null, 0).Images;
        Assert.Equal(2, images.Count);
        var first = images.MinBy(i => (i.Box.Y, i.Box.X))!;
        Assert.Equal(3, first.Box.Width / first.Box.Height, 1); // the new, orange one where it was inserted
        Assert.Equal(Left, first.Box.X, 0);
        var moved = images.Single(i => i != first);
        Assert.Equal((12, 9), ((int)Math.Round(moved.Box.Width), (int)Math.Round(moved.Box.Height))); // the old one, at the end
    }

    [Fact]
    public void TakingATallPictureOffTheEndOfTheFirstLineLiftsNothing()
    {
        // A picture twice the type's height right after the first line's last word (the line reaches to it).
        var lines = Wrap(Body, Width - 40);
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top)} Td ({lines[0]}) Tj");
        foreach (var l in lines.Skip(1)) sb.Append($" T* ({l}) Tj");
        sb.Append(" 0 -60 Td (Next block starts here) Tj ET\n");
        sb.Append($"q 12 0 0 22 {N(Left + Measure(lines[0]) + 3)} {N(Top)} cm /Im1 Do Q\n");
        var pdf = ContentEditPdf.Make(sb.ToString(), fontText: Chars);
        var p = Body0(pdf);
        Assert.Single(p.Pictures);
        var first = p.Runs[0].Origin.Y;
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, p.Text.Replace(" \uFFFC", "", StringComparison.Ordinal));
        Assert.Equal(first, Body0(edited).Runs[0].Origin.Y, 1);
    }

    [Fact]
    public void NewPicturesTakeTheTypedMarksInOrderAndNoMore()
    {
        var (pdf, _) = Page(ParagraphAlign.Left, gap: 120);
        var p = Body0(pdf);
        var wide = new NewPicture(PngEncoder.Encode(10, 10, new byte[300], false), "black.png");
        var text = "￼ " + p.Text + " ￼";
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text, added: [Orange(), wide]);
        var images = ContentEditor.Read(edited, null, 0).Images.OrderBy(i => i.Box.Y).ThenBy(i => i.Box.X).ToList();
        Assert.Equal(2, images.Count);
        Assert.Equal(3, images[0].Box.Width / images[0].Box.Height, 1); // the first mark: the orange one
        Assert.Equal(1, images[1].Box.Width / images[1].Box.Height, 1);
        // Three marks for two pictures: the last stands for nothing.
        Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(pdf, null, p, text + " ￼", added: [Orange(), wide]));
        // Not an image: refused, nothing written.
        Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(pdf, null, p, text, added: [Orange(), new NewPicture([1, 2, 3], "x.png")]));
    }

    /// <summary>Insert Picture takes a JPEG (the pre-release review: it was "not an image"), embedded at its own shape.</summary>
    [Fact]
    public void AJpegIsAPictureTheParagraphTakes()
    {
        var (pdf, _) = Page(ParagraphAlign.Left, gap: 120);
        var p = Body0(pdf);
        var photo = new NewPicture(TestImages.Jpeg(60, 20), "photo.jpg");
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, p.Text + " ￼", added: [photo]);
        var image = Assert.Single(ContentEditor.Read(edited, null, 0).Images);
        Assert.Equal(3, image.Box.Width / image.Box.Height, 1);
    }

    // ---- Cropping ----

    /// <summary>A page drawing /Im1 as given, its 4 x 2 pixels one color a column: red, green, blue, white.</summary>
    /// <param name="change">Changes to /Im1's dictionary, in its document.</param>
    private static byte[] Columns(string content, Action<PdfSharp.Pdf.PdfDocument, PdfSharp.Pdf.PdfDictionary>? change = null)
    {
        var pdf = ContentEditPdf.Make(content);
        using var d = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(pdf), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Modify);
        var im = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!.Elements["/Im1"])!;
        byte[] row = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255];
        im.Stream!.Value = [.. row, .. row];
        im.Elements.Remove("/Filter");
        im.Elements["/Length"] = new PdfSharp.Pdf.PdfInteger(24);
        change?.Invoke(d, im);
        using var ms = new MemoryStream();
        d.Save(ms, false);
        return ms.ToArray();
    }

    /// <summary>Every picture the file holds, as its pixel size and samples (RGB triples).</summary>
    private static List<(int W, int H, byte[] Samples)> PicturesIn(byte[] pdf)
    {
        using var d = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(pdf), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        return [.. d.Internals.GetAllObjects().OfType<PdfSharp.Pdf.PdfDictionary>()
            .Where(o => o.Elements.GetName("/Subtype") == "/Image" && o.Elements.GetName("/ColorSpace") == "/DeviceRGB")
            .Select(o => (o.Elements.GetInteger("/Width"), o.Elements.GetInteger("/Height"), PdfObj.StreamBytes(o)))];
    }

    private static bool Holds(byte[] samples, byte r, byte g, byte b)
    {
        for (var i = 0; i + 2 < samples.Length; i += 3)
            if (samples[i] == r && samples[i + 1] == g && samples[i + 2] == b) return true;
        return false;
    }

    [Fact]
    public void ACropKeepsOnlyThePixelsItShows()
    {
        // 100 x 50 points, 25 points a pixel: the right half (blue and white) kept, out to whole pixels.
        var pdf = Columns("q 100 0 0 50 72 600 cm /Im1 Do Q");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        Near(new RectD(72, 142, 100, 50), image.Box);
        var cropped = ContentEditor.CropImage(pdf, null, image, new RectD(123, 150, 48, 30));
        var c = ContentEditor.Read(cropped, null, 0).Images.Single();
        Near(new RectD(122, 142, 50, 50), c.Box);
        Assert.Null(c.Uncropped); // nothing cut off left to show again
        Assert.DoesNotContain("re W n", ContentEditPdf.Content(cropped));
        var pictures = PicturesIn(cropped);
        var kept = Assert.Single(pictures);
        Assert.Equal((2, 2), (kept.W, kept.H));
        Assert.True(Holds(kept.Samples, 0, 0, 255) && Holds(kept.Samples, 255, 255, 255));
        // The red and green columns are nowhere in the file.
        Assert.DoesNotContain(pictures, p => Holds(p.Samples, 255, 0, 0) || Holds(p.Samples, 0, 255, 0));

        // Moved and resized as any picture; cropped again; deleted.
        var moved = ContentEditor.MoveImage(cropped, null, c, new RectD(200, 300, 100, 100));
        var m = ContentEditor.Read(moved, null, 0).Images.Single();
        Near(new RectD(200, 300, 100, 100), m.Box);
        var again = ContentEditor.CropImage(moved, null, m, new RectD(250, 300, 50, 100));
        var a = ContentEditor.Read(again, null, 0).Images.Single();
        Near(new RectD(250, 300, 50, 100), a.Box);
        Assert.DoesNotContain(PicturesIn(again), p => Holds(p.Samples, 0, 0, 255));
        Assert.Empty(ContentEditor.Read(ContentEditor.DeleteImage(cropped, null, c), null, 0).Images);
    }

    [Fact]
    public void APictureDrawnWithoutItsOwnSaveIsCroppedInOne()
    {
        var pdf = Columns("100 0 0 50 72 600 cm /Im1 Do");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        var cropped = ContentEditor.CropImage(pdf, null, image, new RectD(72, 142, 50, 50));
        var c = ContentEditor.Read(cropped, null, 0).Images.Single();
        Near(new RectD(72, 142, 50, 50), c.Box);
        var kept = Assert.Single(PicturesIn(cropped));
        Assert.True(Holds(kept.Samples, 255, 0, 0) && !Holds(kept.Samples, 0, 0, 255));
        var moved = ContentEditor.MoveImage(cropped, null, c, new RectD(300, 300, 50, 50));
        Near(new RectD(300, 300, 50, 50), ContentEditor.Read(moved, null, 0).Images.Single().Box);
    }

    [Fact]
    public void ACropOfAQuarterTurnedPictureFollowsItsTurn()
    {
        // Turned a quarter: 50 wide and 100 tall on the page, its columns running down it.
        var pdf = Columns("q 0 100 -50 0 200 500 cm /Im1 Do Q");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        Assert.False(image.Turned);
        var crop = new RectD(image.Box.X, image.Box.Y, image.Box.Width, image.Box.Height / 2);
        var cropped = ContentEditor.CropImage(pdf, null, image, crop);
        Near(crop, ContentEditor.Read(cropped, null, 0).Images.Single().Box);
        Assert.Equal((2, 2), Assert.Single(PicturesIn(cropped)) is var k ? (k.W, k.H) : default);
    }

    [Fact]
    public void ACropMadeByAClipOnThePageIsMadeReal()
    {
        // Another program's crop (a clip before the picture): cropping again keeps the pixels asked for, the clip goes.
        var pdf = Columns("q 100 0 0 50 72 600 cm 0 0 0.5 1 re W n /Im1 Do Q");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        Near(new RectD(72, 142, 50, 50), image.Box);
        Near(new RectD(72, 142, 100, 50), image.Uncropped!.Value);
        var cropped = ContentEditor.CropImage(pdf, null, image, image.Box);
        Assert.DoesNotContain("re W n", ContentEditPdf.Content(cropped));
        var kept = Assert.Single(PicturesIn(cropped));
        Assert.Equal(2, kept.W);
        Assert.False(Holds(kept.Samples, 0, 0, 255));
        Near(new RectD(72, 142, 50, 50), ContentEditor.Read(cropped, null, 0).Images.Single().Box);
    }

    [Fact]
    public void AClipDrawnBeforeAPictureOutsideItsOwnSaveStays()
    {
        // The clip also governs what follows the picture (a rectangle filled after it): cropping keeps it.
        var pdf = Columns("q 100 0 0 50 72 600 cm 0 0 0.75 1 re W n /Im1 Do 0 0 1 1 re f Q");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        var cropped = ContentEditor.CropImage(pdf, null, image, new RectD(72, 142, 50, 50));
        Assert.Contains("0 0 0.75 1 re W n", ContentEditPdf.Content(cropped));
        Assert.Contains("0 0 1 1 re f", ContentEditPdf.Content(cropped));
        Assert.Equal(2, Assert.Single(PicturesIn(cropped)).W);
    }

    [Fact]
    public void ACropKeepsThePicturesLayerAndIntent()
    {
        var pdf = Columns("q 100 0 0 50 72 600 cm /Im1 Do Q", (d, im) =>
        {
            var layer = new PdfSharp.Pdf.PdfDictionary(d);
            layer.Elements["/Type"] = new PdfSharp.Pdf.PdfName("/OCG");
            layer.Elements["/Name"] = new PdfSharp.Pdf.PdfString("Photos");
            d.Internals.AddObject(layer);
            im.Elements["/OC"] = layer.Reference!;
            im.Elements["/Intent"] = new PdfSharp.Pdf.PdfName("/Perceptual");
        });
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        var cropped = ContentEditor.CropImage(pdf, null, image, new RectD(122, 142, 50, 50));
        using var d = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(cropped), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var kept = d.Internals.GetAllObjects().OfType<PdfSharp.Pdf.PdfDictionary>().Single(o => o.Elements.GetName("/Subtype") == "/Image" && o.Elements.GetName("/ColorSpace") == "/DeviceRGB");
        Assert.Equal("Photos", PdfObj.Dict(kept.Elements["/OC"])!.Elements.GetString("/Name"));
        Assert.Equal("/Perceptual", kept.Elements.GetName("/Intent"));
    }

    [Fact]
    public void ACropThatCantBeMadeIsRefused()
    {
        var turned = ContentEditPdf.Make("q 70.71 70.71 -35.36 35.36 200 400 cm /Im1 Do Q");
        var t = ContentEditor.Read(turned, null, 0).Images.Single();
        Assert.True(t.Turned);
        Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(turned, null, t, t.Box));
        var pdf = ContentEditPdf.Make("q 100 0 0 50 72 600 cm /Im1 Do Q");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(pdf, null, image, new RectD(double.NaN, 0, 10, 10)));
        Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(pdf, null, image, new RectD(400, 400, 50, 50))); // outside it
        Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(pdf, null, image, new RectD(72, 142, 0.5, 50)));
        // A stencil (an inline image mask): one color painted through it.
        var stencil = ContentEditPdf.Make("q 100 0 0 50 72 600 cm BI /W 8 /H 2 /IM true ID ðð EI Q");
        var s = ContentEditor.Read(stencil, null, 0).Images.Single();
        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(stencil, null, s, new RectD(72, 142, 50, 50)));
        Assert.Contains("stencil", ex.Message);
        // Transparency inside JPEG 2000 data, or a soft mask blended with a matte color.
        var inData = Columns("q 100 0 0 50 72 600 cm /Im1 Do Q", (_, im) => im.Elements["/SMaskInData"] = new PdfSharp.Pdf.PdfInteger(1));
        var i1 = ContentEditor.Read(inData, null, 0).Images.Single();
        Assert.Contains("transparency", Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(inData, null, i1, new RectD(72, 142, 50, 50))).Message);
        var matte = Columns("q 100 0 0 50 72 600 cm /Im1 Do Q", (d, im) =>
        {
            var mask = ImageImport.ImageStream(d, 4, 2, new byte[8], "/DeviceGray");
            mask.Elements["/Matte"] = new PdfSharp.Pdf.PdfArray(d, new PdfSharp.Pdf.PdfReal(1), new PdfSharp.Pdf.PdfReal(1), new PdfSharp.Pdf.PdfReal(1));
            im.Elements["/SMask"] = mask.Reference!;
        });
        var i2 = ContentEditor.Read(matte, null, 0).Images.Single();
        Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(matte, null, i2, new RectD(72, 142, 50, 50)));
        // A picture that says it is 60,000 pixels square: refused before MuPDF decodes it.
        var huge = Columns("q 100 0 0 50 72 600 cm /Im1 Do Q", (_, im) =>
        {
            im.Elements["/Width"] = new PdfSharp.Pdf.PdfInteger(60000);
            im.Elements["/Height"] = new PdfSharp.Pdf.PdfInteger(60000);
        });
        var i3 = ContentEditor.Read(huge, null, 0).Images.Single();
        Assert.Contains("too large", Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(huge, null, i3, new RectD(72, 142, 1, 1))).Message);
    }

    [Fact]
    public void AHostileCropOnThePageIsHeldToThePicture()
    {
        // A clip that reaches far past the picture, or is no number at all, crops nothing.
        foreach (var clip in new[] { "-5 -5 1e30 1e30 re W n", "0 0 0 0 re W n", "-1 -1 0.5 0.5 re W n" })
        {
            var pdf = ContentEditPdf.Make($"q 100 0 0 50 72 600 cm {clip} /Im1 Do Q");
            var image = ContentEditor.Read(pdf, null, 0).Images.Single();
            Assert.Null(image.Uncropped);
            Near(new RectD(72, 142, 100, 50), image.Box);
        }
        // A picture claiming a size past any page's: refused before anything is drawn.
        var huge = ContentEditPdf.Make("q 100 0 0 50 72 600 cm BI /W 9000000 /H 2 /CS /G /BPC 8 ID \u0000\u0000 EI Q");
        if (ContentEditor.Read(huge, null, 0).Images.SingleOrDefault() is { Blocked: null } h)
            Assert.Throws<ContentEditException>(() => ContentEditor.CropImage(huge, null, h, new RectD(72, 142, 50, 50)));
    }
}
