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
    private static (byte[] Pdf, string Pre) WithPicture()
    {
        var lines = Wrap(Body, Width - 30);
        var words = lines[1].Split(' ');
        var pre = string.Join(' ', words.Take(3));
        var post = string.Join(' ', words.Skip(3));
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL {N(Left)} {N(Top)} Td ({lines[0]}) Tj");
        sb.Append($" T* ({pre}) Tj [{N(-18 * 1000 / Size)}] TJ ({post}) Tj");
        foreach (var l in lines.Skip(2)) sb.Append($" T* ({l}) Tj");
        sb.Append(" 0 -60 Td (Next block starts here) Tj ET\n");
        var x = Left + Measure(pre) + 3;
        sb.Append($"q 12 0 0 9 {N(x)} {N(Top - Step - 1)} cm /Im1 Do Q\n");
        return (ContentEditPdf.Make(sb.ToString(), fontText: Chars), pre);
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

    // ---- Cropping ----

    [Fact]
    public void ACropShowsPartOfThePictureAndMovesWithIt()
    {
        var pdf = ContentEditPdf.Make("q 100 0 0 50 72 600 cm /Im1 Do Q");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        var whole = new RectD(72, 792 - 650, 100, 50);
        Near(whole, image.Box);
        Assert.Null(image.Uncropped);

        // Its right half, the bottom 10 points off.
        var cropped = ContentEditor.CropImage(pdf, null, image, new RectD(122, 142, 50, 40));
        Assert.Contains("0.5 0.2 0.5 0.8 re W n", ContentEditPdf.Content(cropped));
        var c = ContentEditor.Read(cropped, null, 0).Images.Single();
        Near(new RectD(122, 142, 50, 40), c.Box);
        Near(whole, c.Uncropped!.Value);

        // Moved and made twice the size, the crop goes with it.
        var moved = ContentEditor.MoveImage(cropped, null, c, new RectD(200, 300, 100, 80));
        var m = ContentEditor.Read(moved, null, 0).Images.Single();
        Near(new RectD(200, 300, 100, 80), m.Box);
        Near(new RectD(100, 300, 200, 100), m.Uncropped!.Value);

        // Cropped again, from what is left to more of it; then all of it: the crop goes.
        var again = ContentEditor.CropImage(moved, null, m, new RectD(150, 300, 150, 80));
        Near(new RectD(150, 300, 150, 80), ContentEditor.Read(again, null, 0).Images.Single().Box);
        var whole2 = ContentEditor.Read(again, null, 0).Images.Single();
        var uncropped = ContentEditor.CropImage(again, null, whole2, whole2.Uncropped!.Value);
        var u = ContentEditor.Read(uncropped, null, 0).Images.Single();
        Assert.Null(u.Uncropped);
        Near(new RectD(100, 300, 200, 100), u.Box);
        Assert.DoesNotContain(" W n", ContentEditPdf.Content(uncropped));

        // Deleted, the crop goes with it.
        var deleted = ContentEditor.DeleteImage(cropped, null, c);
        Assert.Empty(ContentEditor.Read(deleted, null, 0).Images);
        Assert.DoesNotContain("re W n", ContentEditPdf.Content(deleted));
    }

    [Fact]
    public void APictureDrawnWithoutItsOwnSaveIsCroppedInOne()
    {
        var pdf = ContentEditPdf.Make("100 0 0 50 72 600 cm /Im1 Do");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        var cropped = ContentEditor.CropImage(pdf, null, image, new RectD(72, 142, 50, 50));
        var c = ContentEditor.Read(cropped, null, 0).Images.Single();
        Near(new RectD(72, 142, 50, 50), c.Box);
        var moved = ContentEditor.MoveImage(cropped, null, c, new RectD(300, 300, 50, 50));
        var m = ContentEditor.Read(moved, null, 0).Images.Single();
        Near(new RectD(300, 300, 50, 50), m.Box);
        Near(new RectD(300, 300, 100, 50), m.Uncropped!.Value);
    }

    [Fact]
    public void ACropOfAQuarterTurnedPictureFollowsItsTurn()
    {
        // Turned a quarter: 50 wide and 100 tall on the page.
        var pdf = ContentEditPdf.Make("q 0 100 -50 0 200 500 cm /Im1 Do Q");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        Assert.False(image.Turned);
        var crop = new RectD(image.Box.X, image.Box.Y, image.Box.Width, image.Box.Height / 2);
        var c = ContentEditor.Read(ContentEditor.CropImage(pdf, null, image, crop), null, 0).Images.Single();
        Near(crop, c.Box);
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
    }
}
