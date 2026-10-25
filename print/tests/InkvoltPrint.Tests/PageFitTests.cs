using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

public class PageFitTests
{
    [Theory]
    [InlineData(4, 6, PageSizing.ActualSize, 1)]              // 4×6 label on Letter: stays 4×6
    [InlineData(4, 6, PageSizing.FitToPaper, 11.0 / 6)]      // ...or fills the height
    [InlineData(8.5, 11, PageSizing.FitToPaper, 1)]
    [InlineData(8.5, 11, PageSizing.ActualSize, 1)]
    [InlineData(8.27, 11.69, PageSizing.ActualSize, 11 / 11.69)] // A4 on Letter shrinks either way
    [InlineData(8.27, 11.69, PageSizing.FitToPaper, 11 / 11.69)]
    [InlineData(8.4, 10.9, PageSizing.FitToPaper, 1)]        // within 3% of the paper: actual size
    [InlineData(17, 22, PageSizing.ActualSize, 0.5)]
    public void ScalesOnLetter(double w, double h, PageSizing sizing, double expected) =>
        Assert.Equal(expected, PageFit.Scale(w, h, 8.5, 11, sizing), 6);

    [Fact]
    public void EmptyPageKeepsScale() => Assert.Equal(1, PageFit.Scale(0, 0, 8.5, 11, PageSizing.FitToPaper));

    [Theory]
    [InlineData(11, 8.5, 8.5, 11, true)]   // landscape page, portrait paper
    [InlineData(8.5, 11, 11, 8.5, true)]   // portrait page, landscape paper
    [InlineData(8.5, 11, 8.5, 11, false)]
    [InlineData(4, 4, 8.5, 11, false)]     // square: as is on portrait paper
    public void Place_turns_the_page_to_the_papers_orientation(double w, double h, double paperW, double paperH, bool rotated)
    {
        var p = PageFit.Place(w, h, paperW, paperH, PageSizing.ActualSize);

        Assert.Equal(rotated, p.Rotated);
        Assert.Equal(paperW, 2 * p.At.X + p.At.Width, 6); // centred
        Assert.Equal(paperH, 2 * p.At.Y + p.At.Height, 6);
    }

    [Fact]
    public void Place_fits_a_turned_page_by_its_turned_size()
    {
        // 17 × 11 tabloid on Letter: turned to 11 × 17, then its 17 in height fits the paper's 11.
        var p = PageFit.Place(17, 11, 8.5, 11, PageSizing.FitToPaper);

        Assert.True(p.Rotated);
        Assert.Equal(11 * 11 / 17.0, p.At.Width, 6);
        Assert.Equal(11, p.At.Height, 6);
    }
}
