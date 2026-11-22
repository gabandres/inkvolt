namespace InkvoltPrint.Core.Pdf;

/// <summary>A line of recognized text on a page: its words in order, its top and left edge and its height (the image's pixels).</summary>
public sealed record TextLine(string Text, double Left, double Top, double Height)
{
    /// <summary>Its words, left to right.</summary>
    public IReadOnlyList<OcrWord> Words { get; init; } = [];
}

/// <summary>
/// A scanned page's recognized words (<see cref="OcrWord"/>, as the recognizer gives them) put back into lines, top to bottom:
/// words whose boxes share most of their height are one line, read left to right. What a scan's name is read from
/// (<see cref="Presets.TextFinds"/>).
/// </summary>
public static class PageText
{
    /// <summary>At most this many words are read from a page (a recognizer's answer is outside input).</summary>
    public const int MaxWords = 20_000;

    public static List<TextLine> Lines(IReadOnlyList<OcrWord>? words)
    {
        var lines = new List<(double Top, double Bottom, List<OcrWord> Words)>();
        if (words is null) return [];
        foreach (var w in words.Take(MaxWords)
                     .Where(w => !string.IsNullOrWhiteSpace(w.Text) && double.IsFinite(w.X) && double.IsFinite(w.Y) && double.IsFinite(w.Height) && w.Height > 0)
                     .OrderBy(w => w.Y + w.Height / 2))
        {
            var (top, bottom) = (w.Y, w.Y + w.Height);
            var line = lines.FindLastIndex(l => Math.Min(l.Bottom, bottom) - Math.Max(l.Top, top) >= 0.5 * Math.Min(l.Bottom - l.Top, bottom - top));
            if (line < 0) lines.Add((top, bottom, [w]));
            else
            {
                var l = lines[line];
                l.Words.Add(w);
                lines[line] = (Math.Min(l.Top, top), Math.Max(l.Bottom, bottom), l.Words);
            }
        }
        return [.. lines.OrderBy(l => l.Top).Select(l =>
        {
            var ordered = l.Words.OrderBy(w => w.X).ToList();
            var heights = ordered.Select(w => w.Height).OrderBy(h => h).ToList();
            return new TextLine(string.Join(' ', ordered.Select(w => w.Text.Trim())), ordered[0].X, l.Top, heights[heights.Count / 2]) { Words = ordered };
        })];
    }
}
