namespace InkvoltPrint.Core.Suite;

/// <summary>A rectangle in device-independent pixels (a window, a monitor's working area).</summary>
public readonly record struct ScreenRect(double Left, double Top, double Width, double Height)
{
    public double Right => Left + Width;
    public double Bottom => Top + Height;

    /// <summary>True when <paramref name="other"/> lies wholly inside this one (half a pixel of slack for rounding).</summary>
    public bool Contains(ScreenRect other) =>
        other.Left >= Left - 0.5 && other.Top >= Top - 0.5 && other.Right <= Right + 0.5 && other.Bottom <= Bottom + 0.5;
}

/// <summary>
/// Keeps a window on its screen: a window larger than the working area (1180 × 800 on a 1366 × 768 laptop, or one at 125 %
/// scale, 1092 × 582 without the taskbar) opened centred with its title bar above the top edge, so it had no frame, no
/// caption buttons and no way to minimize, and its right edge (the header's Print a PDF and Scan) cut off. Pure, so it is
/// tested here; the apps measure the working area and apply it.
/// </summary>
public static class ScreenFit
{
    /// <summary>
    /// A dev aid for both apps: <c>INKVOLT_FAKE_WORKAREA=1092x582</c> makes the primary monitor's working area that size
    /// (DIPs, from its top-left corner), as on a 1366 × 768 laptop at 125 %, to see a window kept on a small screen.
    /// </summary>
    public const string FakeWorkAreaVariable = "INKVOLT_FAKE_WORKAREA";

    /// <summary>"1092x582" (or with ×, X or *) as width and height; null when it isn't two positive numbers.</summary>
    public static (double Width, double Height)? ParseSize(string? text) =>
        text?.Split('x', 'X', '×', '*') is [var w, var h]
        && double.TryParse(w.Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var width)
        && double.TryParse(h.Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var height)
        && width > 0 && height > 0 && double.IsFinite(width) && double.IsFinite(height)
            ? (width, height) : null;

    /// <summary>
    /// The window's rectangle shrunk to the working area where it's larger, then moved the least it takes to lie wholly
    /// inside it (the title bar and caption buttons first: the top-left corner wins when it can't fit).
    /// </summary>
    public static ScreenRect Fit(ScreenRect window, ScreenRect work)
    {
        var w = Math.Min(window.Width, work.Width);
        var h = Math.Min(window.Height, work.Height);
        var left = Math.Max(work.Left, Math.Min(window.Left, work.Right - w));
        var top = Math.Max(work.Top, Math.Min(window.Top, work.Bottom - h));
        return new ScreenRect(left, top, w, h);
    }

    /// <summary>A rectangle of <paramref name="width"/> × <paramref name="height"/> (shrunk to fit) in the middle of the working area.</summary>
    public static ScreenRect Centre(double width, double height, ScreenRect work)
    {
        var w = Math.Min(width, work.Width);
        var h = Math.Min(height, work.Height);
        return new ScreenRect(work.Left + (work.Width - w) / 2, work.Top + (work.Height - h) / 2, w, h);
    }

    /// <summary>A window's minimum size where the screen has room for it: never more than the working area.</summary>
    public static double Minimum(double designed, double room) => Math.Max(0, Math.Min(designed, room));

    /// <summary>Of several working areas, the one the window overlaps most (the nearest by centre when it overlaps none).</summary>
    public static ScreenRect? Best(ScreenRect window, IReadOnlyList<ScreenRect> works)
    {
        ScreenRect? best = null;
        var bestScore = double.NegativeInfinity;
        var (cx, cy) = (window.Left + window.Width / 2, window.Top + window.Height / 2);
        foreach (var work in works)
        {
            var ow = Math.Min(window.Right, work.Right) - Math.Max(window.Left, work.Left);
            var oh = Math.Min(window.Bottom, work.Bottom) - Math.Max(window.Top, work.Top);
            var score = ow > 0 && oh > 0 ? ow * oh
                : -Math.Sqrt(Math.Pow(cx - (work.Left + work.Width / 2), 2) + Math.Pow(cy - (work.Top + work.Height / 2), 2));
            if (score <= bestScore) continue;
            bestScore = score;
            best = work;
        }
        return best;
    }
}
