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

    /// <summary>
    /// The lines as paragraphs (roadmap 4.14, a scan saved as Word or text): a new paragraph after a gap more than
    /// <see cref="ParagraphGap"/> of a line's height, or where the size changes; a line a third taller than most is a heading. A
    /// word broken with a hyphen at a line's end is joined again ("ink-" "jet" → "inkjet" only when the next line goes on in lower case).
    /// </summary>
    public static List<TextParagraph> Paragraphs(IReadOnlyList<TextLine> lines)
    {
        var result = new List<TextParagraph>();
        if (lines.Count == 0) return result;
        var heights = lines.Select(l => l.Height).OrderBy(h => h).ToList();
        var usual = heights[heights.Count / 2];
        var text = new System.Text.StringBuilder();
        TextLine? previous = null;
        var heading = false;
        foreach (var line in lines)
        {
            var isHeading = line.Height >= usual * 4 / 3;
            var gap = previous is null ? 0 : line.Top - (previous.Top + previous.Height);
            var breaks = previous is null || isHeading != heading || gap > ParagraphGap * Math.Max(previous.Height, line.Height)
                || (isHeading && Math.Abs(line.Height - previous.Height) > 0.2 * previous.Height);
            if (breaks && text.Length > 0)
            {
                result.Add(new TextParagraph(text.ToString(), heading));
                text.Clear();
            }
            var words = WithoutStrays(line).Trim();
            if (words.Length == 0) continue;
            if (text.Length == 0) text.Append(words);
            else if (text[^1] == '-' && text.Length > 1 && char.IsLetter(text[^2]) && words.Length > 0 && char.IsLower(words[0]))
                text.Remove(text.Length - 1, 1).Append(words); // "ink-" + "jet"
            else text.Append(' ').Append(words);
            heading = isHeading;
            previous = line;
        }
        if (text.Length > 0) result.Add(new TextParagraph(text.ToString(), heading));
        return result;
    }

    /// <summary>
    /// The line's text without a lone character at either end standing apart from the rest (a punch hole or a speck read as "O"
    /// or "."): further from its neighbour than the line is tall.
    /// </summary>
    public static string WithoutStrays(TextLine line)
    {
        var words = line.Words.ToList();
        if (words.Count < 2) return line.Text;
        static bool Lone(OcrWord w) => w.Text.Trim().Length <= 1;
        if (Lone(words[0]) && words[1].X - (words[0].X + words[0].Width) > line.Height) words.RemoveAt(0);
        if (words.Count >= 2 && Lone(words[^1]) && words[^1].X - (words[^2].X + words[^2].Width) > line.Height) words.RemoveAt(words.Count - 1);
        return string.Join(' ', words.Select(w => w.Text.Trim()));
    }

    /// <summary>A gap between lines more than this share of a line's height starts a new paragraph (lines of a paragraph sit about half a line apart).</summary>
    public const double ParagraphGap = 0.9;
}

/// <summary>A paragraph of recognized text; <see cref="Heading"/> when its lines stand taller than most.</summary>
public sealed record TextParagraph(string Text, bool Heading);
