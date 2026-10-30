using System.Globalization;

namespace InkvoltPrint.Core.Suite;

/// <summary>
/// Windows' Settings › Accessibility › Text size (100–225 %) as both apps apply it: WPF only follows the display
/// scale, so the apps enlarge their own text and controls by this factor (WCAG 1.4.4 Resize Text; Windows apps are
/// expected to honor the setting). Pure, so it is tested here; the apps read the setting and scale.
/// </summary>
public static class TextSize
{
    /// <summary>The largest Windows offers.</summary>
    public const double Max = 2.25;

    /// <summary>The factor to scale by: 1 for anything unusable or smaller, at most <see cref="Max"/>.</summary>
    public static double Factor(double raw) => double.IsFinite(raw) && raw > 1 ? Math.Min(Math.Round(raw, 2), Max) : 1;

    /// <summary>
    /// A factor written by hand (the <c>INKVOLT_TEXTSCALE</c> override for checks and screenshots): "1.5", "150" or
    /// "150%". Null when there is none or it isn't a number.
    /// </summary>
    public static double? Parse(string? text)
    {
        var t = text?.Trim().TrimEnd('%').Trim();
        if (string.IsNullOrEmpty(t) || !double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) return null;
        return Factor(v >= 10 ? v / 100 : v);
    }

    /// <summary>
    /// A dialog's designed width (or height) at this factor: wider by the factor, so its text wraps as designed, but never
    /// past the room there is (and never narrower than designed). NaN (sized to its content) stays NaN.
    /// </summary>
    public static double Widen(double designed, double factor, double room) =>
        double.IsNaN(designed) || double.IsInfinity(designed) || factor <= 1 ? designed : Math.Max(designed, Math.Min(designed * factor, room));
}
