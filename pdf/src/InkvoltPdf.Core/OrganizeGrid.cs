namespace InkvoltPdf.Core;

/// <summary>
/// Organize's page grid (the app's <c>OrganizerView</c>): the size of a card's page picture and how many cards fit in a
/// row. The size slider's value is as at 100 % Text size; the picture follows Windows' Text size, as the card's number and
/// hover buttons do, so they keep their place on it.
/// </summary>
public static class OrganizeGrid
{
    /// <summary>The size slider's range (DIPs at 100 % Text size).</summary>
    public const double MinSize = 90, MaxSize = 360;

    /// <summary>Around each picture: the card's padding and margins.</summary>
    public const double CardChrome = 28;

    /// <summary>What the grid keeps for its own margins and the scroll bar.</summary>
    public const double GridChrome = 48;

    /// <summary>The square a page picture fits in: the slider's <paramref name="size"/> times Windows' Text size.</summary>
    public static double Box(double size, double textScale)
    {
        var s = double.IsFinite(size) ? Math.Clamp(size, MinSize, MaxSize) : MinSize;
        var f = double.IsFinite(textScale) && textScale > 1 ? Math.Min(textScale, 3) : 1;
        return Math.Round(s * f);
    }

    /// <summary>How many cards of <paramref name="box"/> fit in a row of the grid <paramref name="width"/> wide (at least one).</summary>
    public static int Columns(double width, double box)
    {
        if (!double.IsFinite(width) || !double.IsFinite(box) || box <= 0) return 1;
        return (int)Math.Clamp(Math.Floor((width - GridChrome) / (box + CardChrome)), 1, 1000);
    }
}
