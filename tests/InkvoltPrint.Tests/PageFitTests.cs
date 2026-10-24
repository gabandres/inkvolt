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
}
