using System.Globalization;

namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// A pen or form color that Clean up's "Drop a color" turns white (roadmap 4.7, as Epson Scan 2's dropout): red, green or blue,
/// or a color picked off the page. Stored as <see cref="Hex"/> ("#RRGGBB").
/// </summary>
public readonly record struct DropColor(byte R, byte G, byte B)
{
    public static readonly DropColor Red = new(0xD2, 0x2B, 0x2B);
    public static readonly DropColor Green = new(0x2E, 0x9E, 0x4F);
    public static readonly DropColor Blue = new(0x2B, 0x55, 0xC8);

    /// <summary>The least colorfulness (the largest of R, G and B less the smallest) a picked color needs: grey and black have no hue to drop.</summary>
    public const int MinPickChroma = 40;

    public int Chroma => Math.Max(R, Math.Max(G, B)) - Math.Min(R, Math.Min(G, B));

    /// <summary>Colorful enough to be dropped by its hue (a pen's ink, a form's lines), not a grey, a black or the paper.</summary>
    public bool IsColorful => Chroma >= MinPickChroma;

    /// <summary>The hue, 0 to 360 degrees (red 0, green 120, blue 240).</summary>
    public double Hue => ColorDropout.HueOf(R, G, B);

    public string Hex => $"#{R:X2}{G:X2}{B:X2}";

    /// <summary>Red, green or blue (the three named choices); false for a color picked off a page.</summary>
    public bool IsNamed => this == Red || this == Green || this == Blue;

    /// <summary>"red", "green", "blue", or "picked color", in the interface's words.</summary>
    public string Name => this == Red ? CoreStrings.Imaging_DropRed : this == Green ? CoreStrings.Imaging_DropGreen
        : this == Blue ? CoreStrings.Imaging_DropBlue : CoreStrings.Imaging_DropPicked;

    /// <summary>"#RRGGBB" (or "RRGGBB") as a color; null for anything else, so a hand-edited setting can't be misread.</summary>
    public static DropColor? Parse(string? hex)
    {
        var s = hex?.Trim() ?? "";
        if (s.StartsWith('#')) s = s[1..];
        if (s.Length != 6 || !int.TryParse(s, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var rgb)) return null;
        return new DropColor((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    }

    public override string ToString() => Hex;
}

/// <summary>
/// Drops one color to white: every pixel whose hue is the color's (within <see cref="HueFull"/>°, fading out by
/// <see cref="HueNone"/>°) and colorful enough goes white, the more colorful the whiter, so a red form's lines, a blue pen's
/// notes or a stamp vanish and the black print over them stays. Greys, black and the paper have no hue and are left as they are.
/// Color scans only (a grey scan has no color to tell apart). Pixels are BGR, rows packed.
/// </summary>
public static class ColorDropout
{
    /// <summary>Hues this close to the color are dropped fully; past <see cref="HueNone"/> not at all.</summary>
    public const double HueFull = 25, HueNone = 45;

    /// <summary>Colorfulness below <see cref="ChromaNone"/> is grey (paper, black print, JPEG noise): kept. From <see cref="ChromaFull"/> up: dropped fully.</summary>
    public const int ChromaNone = 14, ChromaFull = 40;

    /// <summary>Drops <paramref name="color"/> in place; true when any pixel changed. Grey pages (1 channel) are left as they are.</summary>
    public static bool Apply(byte[] pixels, int width, int height, int channels, DropColor color, CancellationToken cancel = default)
    {
        if (channels != 3 || width < 1 || height < 1 || !color.IsColorful) return false;
        var target = color.Hue;
        var changed = 0;
        var options = new ParallelOptions { CancellationToken = cancel };
        Parallel.For(0, height, options, y =>
        {
            var row = y * width * 3;
            var any = false;
            for (var x = 0; x < width; x++)
            {
                var i = row + x * 3;
                var (b, g, r) = (pixels[i], pixels[i + 1], pixels[i + 2]);
                var weight = Weight(r, g, b, target);
                if (weight <= 0) continue;
                pixels[i] = Lift(b, weight);
                pixels[i + 1] = Lift(g, weight);
                pixels[i + 2] = Lift(r, weight);
                any = true;
            }
            if (any) Interlocked.Exchange(ref changed, 1);
        });
        return changed != 0;
    }

    /// <summary>How much of the way to white a pixel goes: 0 (kept) to 1 (white).</summary>
    internal static double Weight(byte r, byte g, byte b, double targetHue)
    {
        var chroma = Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b));
        if (chroma <= ChromaNone) return 0;
        var distance = Math.Abs(HueOf(r, g, b) - targetHue);
        if (distance > 180) distance = 360 - distance;
        if (distance >= HueNone) return 0;
        var byHue = distance <= HueFull ? 1 : (HueNone - distance) / (HueNone - HueFull);
        var byChroma = chroma >= ChromaFull ? 1 : (chroma - ChromaNone) / (double)(ChromaFull - ChromaNone);
        return byHue * byChroma;
    }

    private static byte Lift(byte value, double weight) => (byte)Math.Round(value + (255 - value) * weight);

    /// <summary>The hue of an RGB color, 0 to 360 degrees; 0 for a grey.</summary>
    public static double HueOf(byte r, byte g, byte b)
    {
        int max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        double c = max - min;
        if (c == 0) return 0;
        double h = max == r ? (g - b) / c : max == g ? 2 + (b - r) / c : 4 + (r - g) / c;
        h *= 60;
        return h < 0 ? h + 360 : h;
    }
}
