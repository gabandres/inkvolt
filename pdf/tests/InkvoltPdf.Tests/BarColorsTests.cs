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
    public void ColoredFileTypesAreFilledSoTheColorReads()
    {
        // Outline glyphs carried almost no color at 16 px (the owner, 2026-11-08): the colored ones are a filled page.
        var convert = CommandBarLayout.Group("Convert").Commands;
        var tinted = BarColors.All.Select(t => t.Key).ToHashSet();
        Assert.All(convert, c => Assert.Equal(c.IconBrush is { } k && tinted.Contains(k), c.Glyph == CommandBarLayout.FilledDocument));
    }

    [Theory]
    [InlineData("FormatWordBrush", 205, 225)]       // blue
    [InlineData("FormatExcelBrush", 135, 155)]      // green, clearly apart from Word's blue
    [InlineData("FormatPowerPointBrush", 8, 20)]    // orange-red
    [InlineData("ApplyRedactionsBrush", -5, 5)]     // red, not brown or orange
    public void EachColorReadsAsItsHueInBothThemes(string key, double from, double to)
    {
        var tint = BarColors.All.Single(t => t.Key == key);
        foreach (var hex in new[] { tint.Light, tint.Dark })
        {
            var (h, s) = HueSaturation(hex);
            if (h > 180 && from < 0) h -= 360;
            Assert.InRange(h, from, to);
            Assert.True(s >= 0.6, $"{key} {hex} saturation {s:0.00}");
        }
    }

    // HSL hue (degrees) and saturation of a #RRGGBB color.
    private static (double Hue, double Saturation) HueSaturation(string hex)
    {
        var (r8, g8, b8) = BarColors.Rgb(hex);
        double r = r8 / 255.0, g = g8 / 255.0, b = b8 / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), d = max - min, l = (max + min) / 2;
        var s = d == 0 ? 0 : d / (1 - Math.Abs(2 * l - 1));
        var h = d == 0 ? 0 : max == r ? 60 * ((g - b) / d % 6) : max == g ? 60 * ((b - r) / d + 2) : 60 * ((r - g) / d + 4);
        return (h < 0 ? h + 360 : h, s);
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
