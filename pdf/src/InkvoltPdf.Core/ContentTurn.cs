using System.Globalization;

namespace InkvoltPdf.Core;

/// <summary>
/// Edit Text &amp; Images' turn handle and angle box (roadmap 4.22), the rules <c>PageViewer.EditContent</c> passes the
/// pointer and typed text to (ADR 1). Angles are degrees clockwise as the page shows, -180 (excluded) to 180; the handle
/// sits out from the selection's top-right corner as shown (clear of the paragraph editor's look bar, which sits above its
/// left end), and a drag turns it by how far the pointer goes round the
/// middle of its box (Shift: to the nearest 15°). The edit itself is <see cref="ContentEditor.RotateImage"/> or
/// <see cref="ContentEditor.RotateParagraph"/>, by <see cref="TurnBy"/>.
/// </summary>
public static class ContentTurn
{
    /// <summary>How far out from the box's top-right corner the handle sits, across and up (view units: DIPs).</summary>
    public const double HandleGap = 16;

    /// <summary>The step Shift turns by.</summary>
    public const double Step = 15;

    /// <summary>An angle as -180 (excluded) to 180, rounded to a hundredth.</summary>
    public static double Normalize(double degrees)
    {
        if (!double.IsFinite(degrees)) return 0;
        var a = degrees % 360;
        if (a > 180) a -= 360;
        else if (a <= -180) a += 360;
        a = Math.Round(a, 2);
        return a == -180 ? 180 : a + 0.0; // + 0.0: never -0
    }

    /// <summary>Where the handle is for a box as shown (view space, y down).</summary>
    public static PointD HandlePoint(RectD shown) => new(shown.Right + HandleGap, shown.Y - HandleGap);

    /// <summary>Whether a point (view space) is on the handle of a box as shown.</summary>
    public static bool OnHandle(RectD shown, PointD p, double reach)
    {
        var h = HandlePoint(shown);
        return Math.Abs(p.X - h.X) <= reach && Math.Abs(p.Y - h.Y) <= reach;
    }

    /// <summary>
    /// The angle a drag of the handle sets: <paramref name="start"/> turned by how far the pointer went round
    /// <paramref name="center"/> from <paramref name="from"/> to <paramref name="to"/> (view space); with
    /// <paramref name="steps"/> (Shift), the nearest multiple of <see cref="Step"/>. A pointer on the middle itself turns nothing.
    /// </summary>
    public static double Dragged(PointD center, PointD from, PointD to, double start, bool steps)
    {
        const double still = 1e-6;
        if (Math.Abs(to.X - center.X) < still && Math.Abs(to.Y - center.Y) < still || Math.Abs(from.X - center.X) < still && Math.Abs(from.Y - center.Y) < still)
            return Normalize(start);
        var a0 = Math.Atan2(from.Y - center.Y, from.X - center.X);
        var a1 = Math.Atan2(to.Y - center.Y, to.X - center.X);
        var angle = start + (a1 - a0) * 180 / Math.PI;
        return Normalize(steps ? Math.Round(angle / Step) * Step : angle);
    }

    /// <summary>An angle typed in the box ("30", "-12.5", "45°", "30,5" where the comma is the decimal sign); null when it isn't one.</summary>
    public static double? Parse(string typed, CultureInfo? culture = null)
    {
        var text = typed.Trim().TrimEnd('°', 'º').Trim();
        if (text.Length == 0) return null;
        culture ??= CultureInfo.CurrentCulture;
        if (double.TryParse(text, NumberStyles.Float, culture, out var v) || double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out v))
            return double.IsFinite(v) && Math.Abs(v) <= 100_000 ? Normalize(v) : null;
        return null;
    }

    /// <summary>The turn that takes something at <paramref name="current"/> to <paramref name="wanted"/> (the shorter way);
    /// null when it is there already.</summary>
    public static double? TurnBy(double current, double wanted)
    {
        var d = Normalize(wanted - current);
        return Math.Abs(d) < 0.01 ? null : d;
    }

    /// <summary>An angle as the box shows it ("30°", "-12.5°").</summary>
    public static string Format(double degrees, CultureInfo? culture = null) =>
        Normalize(degrees).ToString("0.##", culture ?? CultureInfo.CurrentCulture) + "°";

    /// <summary>A box's corners turned <paramref name="degrees"/> about its middle (clockwise on a y-down page): the outline a turn shows while dragged.</summary>
    public static IReadOnlyList<PointD> Corners(RectD box, double degrees)
    {
        var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
        double cx = box.CenterX, cy = box.CenterY;
        return [.. new[] { new PointD(box.X, box.Y), new PointD(box.Right, box.Y), new PointD(box.Right, box.Bottom), new PointD(box.X, box.Bottom) }
            .Select(p => new PointD(cx + (p.X - cx) * cos - (p.Y - cy) * sin, cy + (p.X - cx) * sin + (p.Y - cy) * cos))];
    }
}
