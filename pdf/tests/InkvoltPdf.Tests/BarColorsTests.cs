using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class BarColorsTests
{
    [Fact]
    public void OnlyWordExcelPowerPointPdfAAndApplyRedactionsAreColored()
    {
        // The owner (2026-11-08): three touches of color; text, HTML and pictures stay the text color.
        var colored = CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().SelectMany(e => e.Commands)
            .Where(c => c.IconBrush is { } key && BarColors.All.Any(t => t.Key == key)).Select(c => c.Name);
        string[] expected = ["ExportWord", "ExportPowerPoint", "ExportExcel", "SaveAsPdfA", "ApplyRedactions"];
        Assert.Equal(expected.Order(), colored.Order());
        Assert.Equal(BarColors.All.Count, BarColors.All.Select(t => t.Key).Distinct().Count());
        // Every tint is used by a command of the table (none defined for nothing).
        var keys = CommandBarLayout.Bar.OfType<CommandBarLayout.Entry>().SelectMany(e => e.Commands).Select(c => c.IconBrush).ToHashSet();
        Assert.All(BarColors.All, t => Assert.Contains(t.Key, keys));
    }

    [Fact]
    public void EachColorHasALightAndADarkVariantWithThreeToOneContrast()
    {
        Assert.All(BarColors.All, t =>
        {
            Assert.NotEqual(t.Light, t.Dark);
            foreach (var bg in BarColors.LightBackgrounds) Assert.True(BarColors.ContrastRatio(t.Light, bg) >= 3, $"{t.Key} on {bg}");
            foreach (var bg in BarColors.DarkBackgrounds) Assert.True(BarColors.ContrastRatio(t.Dark, bg) >= 3, $"{t.Key} dark on {bg}");
        });
        Assert.Equal(BarColors.All.Select(t => t.Light), BarColors.For(dark: false, highContrast: false).Values);
        Assert.Equal(BarColors.All.Select(t => t.Dark), BarColors.For(dark: true, highContrast: false).Values);
    }

    [Fact]
    public void UnderHighContrastNoColorIsUsed()
    {
        // The system's colors draw every icon then (the app maps each key to them).
        Assert.Empty(BarColors.For(dark: false, highContrast: true));
        Assert.Empty(BarColors.For(dark: true, highContrast: true));
    }

    [Fact]
    public void ContrastIsWcags()
    {
        Assert.Equal(21, BarColors.ContrastRatio("#000000", "#FFFFFF"), 3);
        Assert.Equal(1, BarColors.ContrastRatio("#777777", "#777777"), 3);
        Assert.Equal(4.48, BarColors.ContrastRatio("#777777", "#FFFFFF"), 2);
        Assert.Throws<FormatException>(() => BarColors.Rgb("blue"));
    }
}
