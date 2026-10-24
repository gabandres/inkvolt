using InkvoltPdf.Core;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>Form field suggestions from generated pages: underscores, ruled lines, empty boxes and small squares.</summary>
public class FieldDetectionTests
{
    private static byte[] Page(Action<XGraphics> draw, int rotate = 0)
    {
        using var doc = new PdfDocument();
        var page = doc.AddPage();
        page.Width = XUnit.FromPoint(612);
        page.Height = XUnit.FromPoint(792);
        using (var gfx = XGraphics.FromPdfPage(page)) draw(gfx);
        if (rotate != 0) page.Rotate = rotate;
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    private static XFont Font
    {
        get
        {
            TestPdf.UseFonts(); // before PDFsharp looks up any font
            return new XFont("Arial", 11);
        }
    }

    private static IReadOnlyList<FieldSuggestion> Detect(byte[] pdf, IReadOnlyList<DesignField>? existing = null)
    {
        using var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null);
        return FieldDetection.Suggest(engine, pdf, null, [0], existing ?? []);
    }

    [Fact]
    public void UnderscoresBecomeTextFieldsNamedAfterTheirLabel()
    {
        var pdf = Page(g =>
        {
            g.DrawString("Name: ____________________", Font, XBrushes.Black, 72, 100);
            g.DrawString("Date of birth: __________   City: __________", Font, XBrushes.Black, 72, 130);
        });
        var s = Detect(pdf);
        Assert.Equal(["Name", "Date of birth", "City"], s.Select(x => x.Name));
        Assert.All(s, x => Assert.Equal(DesignFieldKind.Text, x.Kind));
        var name = s[0];
        Assert.True(name.Rect.X > 100 && name.Rect.Right > 200, $"over the underscores: {name.Rect}");
        Assert.InRange(name.Rect.Bottom, 98, 106); // stands on the baseline area
        Assert.True(name.Rect.Height >= 12);
    }

    [Fact]
    public void RuledLinesBecomeFieldsAndSignatureLinesSignatureFields()
    {
        var pdf = Page(g =>
        {
            g.DrawString("Email", Font, XBrushes.Black, 72, 200);
            g.DrawLine(XPens.Black, 110, 202, 320, 202);
            g.DrawLine(XPens.Black, 72, 300, 250, 300);
            g.DrawString("Signature", Font, XBrushes.Black, 72, 313);
        });
        var s = Detect(pdf);
        Assert.Equal(2, s.Count);
        var email = s.Single(x => x.Name == "Email");
        Assert.Equal(DesignFieldKind.Text, email.Kind);
        Assert.InRange(email.Rect.X, 109, 111);
        Assert.InRange(email.Rect.Bottom, 200, 203);
        var sig = s.Single(x => x.Name == "Signature");
        Assert.Equal(DesignFieldKind.Signature, sig.Kind);
    }

    [Fact]
    public void EmptyBoxesAndSquares()
    {
        var pdf = Page(g =>
        {
            g.DrawString("Address", Font, XBrushes.Black, 72, 95);
            g.DrawRectangle(XPens.Black, 72, 100, 300, 60);
            g.DrawString("Phone", Font, XBrushes.Black, 72, 196);
            g.DrawRectangle(XPens.Black, 120, 182, 150, 20);
            g.DrawRectangle(XPens.Black, 72, 230, 10, 10);
            g.DrawString("I agree to the terms", Font, XBrushes.Black, 88, 239);
        });
        var s = Detect(pdf);
        var address = s.Single(x => x.Name == "Address");
        Assert.True(address.Multiline);
        Assert.Equal(new RectD(72, 100, 300, 60), Round(address.Rect));
        var phone = s.Single(x => x.Name == "Phone");
        Assert.False(phone.Multiline);
        var agree = s.Single(x => x.Kind == DesignFieldKind.CheckBox);
        Assert.Equal("I agree to the terms", agree.Name);
        Assert.Equal(3, s.Count);
    }

    [Fact]
    public void BoxCharactersBecomeCheckBoxes()
    {
        // "☐ Married" as a page's text layer (fonts map their box symbols to ☐, ❑ and the like).
        var line = new List<(string, RectD)> { ("☐", new RectD(72, 90, 11, 12)), (" ", new RectD(83, 90, 3, 12)) };
        line.AddRange("Married".Select((c, i) => (c.ToString(), new RectD(90 + i * 6, 90, 6, 12))));
        var s = Assert.Single(FieldDetection.Suggest(0, 612, 792, new PageText([line]), [], [], []));
        Assert.Equal(DesignFieldKind.CheckBox, s.Kind);
        Assert.Equal("Married", s.Name);
        Assert.InRange(s.Rect.Width, 9, 11);
    }

    [Fact]
    public void TextUnderlinesBoxedTextAndFramesAreNotFields()
    {
        var pdf = Page(g =>
        {
            g.DrawString("Important notice", Font, XBrushes.Black, 72, 100);
            g.DrawLine(XPens.Black, 72, 102, 160, 102); // underlined text
            g.DrawRectangle(XPens.Black, 72, 150, 200, 30);
            g.DrawString("Already filled in", Font, XBrushes.Black, 80, 170); // a box with text
            g.DrawRectangle(XPens.Black, 20, 20, 572, 752); // page frame
            g.DrawLine(XPens.Black, 36, 400, 576, 400); // a separator across the page
        });
        Assert.Empty(Detect(pdf));
    }

    [Fact]
    public void PlacesWithFieldsAreSkipped()
    {
        var pdf = Page(g => g.DrawString("Name: ____________________", Font, XBrushes.Black, 72, 100));
        var first = Assert.Single(Detect(pdf));
        var withField = FormDesign.Add(pdf, null, [FormDesign.NewField(DesignFieldKind.Text, 0, first.Rect, [], first.Name)]);
        Assert.Empty(Detect(withField, FormDesign.Read(withField, null)));

        // A second page's suggestion doesn't reuse a taken name.
        var again = FieldDetection.Suggest(0, 612, 792, PageText.Empty, [new PageShape(new RectD(72, 300, 200, 20), false)], [], ["Text1"]);
        Assert.Equal("Text2", Assert.Single(again).Name);
    }

    [Fact]
    public void ShapesFollowTheTransformAndFormXObjects()
    {
        // A box drawn at (10,10) scaled 2x and moved, and the same drawn inside a form XObject placed with cm.
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Fm 5 0 R >> >> >>",
            Core2Pdf.Stream("q 2 0 0 2 100 100 cm 0 0 50 10 re S Q 1 1 1 RG 0 0 0 rg q 1 0 0 1 300 500 cm /Fm Do Q 0 G 72 700 m 272 700 l S"),
            Core2Pdf.Stream("0 0 40 40 re S 1 g 0 0 5 5 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [1 0 0 1 10 0]"),
        ]);
        var shapes = VectorShapes.Read(pdf, null, 0);
        var boxes = shapes.Where(s => !s.IsLine).Select(s => Round(s.Box)).ToList();
        Assert.Contains(new RectD(100, 792 - 120, 100, 20), boxes);
        Assert.DoesNotContain(boxes, b => b.Width == 40); // stroked white: invisible
        var line = Assert.Single(shapes, s => s.IsLine);
        Assert.Equal(72, line.Box.X, 1);
        Assert.Equal(200, line.Box.Width, 1);
        Assert.Equal(92, line.Box.CenterY, 1);
        Assert.DoesNotContain(boxes, b => b.Width == 5); // white fill
    }

    [Fact]
    public void TurnedPagesMapToTheShownPage()
    {
        var pdf = Page(g => g.DrawRectangle(XPens.Black, 100, 100, 200, 30), rotate: 90);
        var box = Assert.Single(VectorShapes.Read(pdf, null, 0)).Box;
        // Page space is the page as shown: turned 90° clockwise, 792 wide.
        Assert.Equal(new RectD(792 - 130, 100, 30, 200), Round(box));
    }

    [Theory]
    [InlineData("Name:", "Name")]
    [InlineData("1. Date of birth (mm/dd/yyyy):", "Date of birth")]
    [InlineData("E-mail address *", "E-mail address")]
    [InlineData("a.b", "a b")]
    public void LabelsBecomeNames(string label, string name) => Assert.Equal(name, FieldDetection.CleanLabel(label));

    [Fact]
    public void CaptionsRightOfABoxKeepTheirFirstWords() =>
        Assert.Equal("I agree to the terms", FieldDetection.CleanLabel("I agree to the terms and conditions", leading: true));

    [Fact]
    public void ACancelledPageStopsAndBusyPagesStayQuick()
    {
        // A dense page: 60 x 60 small squares (a grid of check boxes), each with a caption character to its right.
        var shapes = new List<PageShape>();
        var line = new List<(string, RectD)>();
        for (var row = 0; row < 60; row++)
            for (var col = 0; col < 60; col++)
            {
                shapes.Add(new PageShape(new RectD(10 + col * 13, 10 + row * 13, 8, 8), false));
                line.Add(("x", new RectD(19 + col * 13, 10 + row * 13, 3, 8)));
            }
        var text = new PageText([line]);
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => FieldDetection.Suggest(0, 800, 800, text, shapes, [], [], cts.Token));

        var watch = System.Diagnostics.Stopwatch.StartNew();
        var found = FieldDetection.Suggest(0, 800, 800, text, shapes, [], []);
        Assert.Equal(3600, found.Count);
        Assert.All(found, s => Assert.Equal(DesignFieldKind.CheckBox, s.Kind));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), $"took {watch.Elapsed}");
    }

    [Fact]
    public void TheGridFindsWhatTouchesARegion()
    {
        var rng = new Random(3);
        var grid = new RectGrid();
        var rects = new List<RectD>();
        for (var i = 0; i < 500; i++)
        {
            var r = new RectD(rng.NextDouble() * 600, rng.NextDouble() * 800, rng.NextDouble() * (i % 50 == 0 ? 2000 : 60), rng.NextDouble() * 40);
            rects.Add(r);
            grid.Add(r);
        }
        for (var q = 0; q < 200; q++)
        {
            var region = new RectD(rng.NextDouble() * 600, rng.NextDouble() * 800, rng.NextDouble() * 200, rng.NextDouble() * 200);
            var expected = Enumerable.Range(0, rects.Count).Where(i => rects[i].X <= region.Right && rects[i].Right >= region.X && rects[i].Y <= region.Bottom && rects[i].Bottom >= region.Y);
            Assert.Equal(expected, grid.NearIndices(region));
        }
    }

    private static RectD Round(RectD r) => new(Math.Round(r.X), Math.Round(r.Y), Math.Round(r.Width), Math.Round(r.Height));
}
