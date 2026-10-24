using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

public class CopyLayoutTests
{
    // Letter paper and sides in DIPs (96 per inch), like the spooler hands them to the paginator.
    private const double LetterW = 816, LetterH = 1056;
    private static readonly (double, double) CardScan = (4.5 * 96, 3 * 96);

    [Fact]
    public void Id_card_sides_print_at_actual_size_centred_in_each_half()
    {
        var (front, back) = CopyLayout.IdCard(LetterW, LetterH, CardScan, CardScan);

        Assert.Equal(new Placement((816 - 432) / 2.0, (528 - 288) / 2.0, 432, 288), front);
        Assert.Equal(new Placement((816 - 432) / 2.0, 528 + (528 - 288) / 2.0, 432, 288), back);
        Assert.True(front.Y + front.Height <= LetterH / 2);
        Assert.True(back.Y >= LetterH / 2);
    }

    [Fact]
    public void Oversized_sides_shrink_together_to_fit_their_half_with_margins()
    {
        // A whole Letter page scanned by mistake for the back: both sides take its (smaller) scale.
        var (front, back) = CopyLayout.IdCard(LetterW, LetterH, CardScan, (LetterW, LetterH));

        Assert.True(back.Height <= LetterH / 2 - 2 * CopyLayout.IdCardMargin + 1e-9);
        Assert.True(back.Y >= LetterH / 2 + CopyLayout.IdCardMargin - 1e-9);
        var scale = back.Height / LetterH;
        Assert.Equal(CardScan.Item1 * scale, front.Width, 6);
        Assert.Equal(CardScan.Item2 * scale, front.Height, 6);
    }

    [Fact]
    public void Id_card_on_a4_stays_actual_size()
    {
        var (front, _) = CopyLayout.IdCard(793.7, 1122.5, CardScan, CardScan);

        Assert.Equal((432, 288), (front.Width, front.Height));
    }

    [Fact]
    public void Copied_page_is_centred_at_actual_size_and_only_shrinks()
    {
        Assert.Equal(new PagePlacement(new Placement(0, 0, LetterW, LetterH), false), CopyLayout.Page(LetterW, LetterH, LetterW, LetterH));
        Assert.Equal(new PagePlacement(new Placement(216, 336, 384, 384), false), CopyLayout.Page(384, 384, LetterW, LetterH)); // small page: not enlarged

        var a4OnLetter = CopyLayout.Page(793.7, 1122.5, LetterW, LetterH).At;
        Assert.Equal(LetterH, a4OnLetter.Height, 6);
        Assert.Equal(0, a4OnLetter.Y, 6);
    }

    [Fact]
    public void Landscape_copy_is_turned_like_it_prints()
    {
        // A 6 × 4 in photo on portrait Letter: turned a quarter (as the print path does), not shrunk.
        var p = CopyLayout.Page(576, 384, LetterW, LetterH);

        Assert.True(p.Rotated);
        Assert.Equal(new Placement((LetterW - 384) / 2, (LetterH - 576) / 2, 384, 576), p.At);
    }

    [Fact]
    public void Scanned_size_in_inches_from_pixels_and_dpi()
    {
        Assert.Equal((8.5, 11), CopyLayout.Inches(2550, 3300, 300));
        Assert.Equal((4.5, 3), CopyLayout.Inches(675, 450, 150));
        Assert.Equal((0, 0), CopyLayout.Inches(100, 100, 0));
    }

    [Fact]
    public void Id_card_scan_is_the_glass_corner_and_fits_the_m234dw_platen()
    {
        var caps = ScannerCapabilities.Parse(Fixture.Xml("eSCL_ScannerCapabilities.xml"));
        var request = CopyLayout.IdCardRequest(ScanColor.Grayscale, 300);

        var settings = EsclXml.BuildScanSettings(request, caps);
        var region = settings.Descendants(EsclXml.Pwg + "ScanRegion").Single();

        Assert.Equal(ScanSource.Platen, request.Source);
        Assert.Equal("1350", region.Element(EsclXml.Pwg + "Width")!.Value);
        Assert.Equal("900", region.Element(EsclXml.Pwg + "Height")!.Value);
        Assert.Equal("0", region.Element(EsclXml.Pwg + "XOffset")!.Value);
        Assert.Equal("Grayscale8", settings.Descendants(EsclXml.Scan + "ColorMode").Single().Value);
    }
}
