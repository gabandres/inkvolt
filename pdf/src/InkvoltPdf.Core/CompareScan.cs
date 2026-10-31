using System.Text;

namespace InkvoltPdf.Core;

/// <summary>Scans on one side of a comparison: recognized words as page text, and the slips recognizers make.</summary>
public static class CompareScan
{
    /// <summary>
    /// Recognized words as a page's text, in the order they were read: a new line where the next word sits on another
    /// row or goes back along the line (measured along the words' own angle, so a skewed page reads as lines). Each
    /// character gets its share of the word's box, along the word's angle.
    /// </summary>
    public static PageText PageTextOf(IReadOnlyList<OcrWord> words)
    {
        var lines = new List<List<(string, RectD)>>();
        var directions = new List<(double, double)>();
        var line = new List<(string, RectD)>();
        (double Along, double Across, double Height)? last = null;
        (double X, double Y) direction = (1, 0);
        foreach (var w in words)
        {
            if (w.Text.Length == 0) continue;
            var (sin, cos) = Math.SinCos(w.Angle * Math.PI / 180);
            var (cx, cy) = (w.Rect.X + w.Rect.Width / 2, w.Rect.Y + w.Rect.Height / 2);
            var along = cx * cos + cy * sin;
            var across = -cx * sin + cy * cos;
            if (last is { } l && (Math.Abs(across - l.Across) > Math.Max(l.Height, w.Rect.Height) / 2 || along < l.Along))
            {
                lines.Add(line);
                directions.Add(direction);
                line = [];
            }
            else if (last is not null)
            {
                // The space between two words of a line: a thin box where the word starts.
                var gap = Box(cx - w.Rect.Width / 2 * cos, cy - w.Rect.Width / 2 * sin, 0.5, w.Rect.Height, sin, cos);
                line.Add((" ", gap));
            }
            direction = (cos, sin);

            // Whole characters (a surrogate pair or combining mark stays with its letter).
            var parts = StringInfoElements(w.Text);
            var each = w.Rect.Width / parts.Count;
            for (var i = 0; i < parts.Count; i++)
            {
                var offset = (i + 0.5) * each - w.Rect.Width / 2;
                line.Add((parts[i], Box(cx + offset * cos, cy + offset * sin, each, w.Rect.Height, sin, cos)));
            }
            last = (along, across, w.Rect.Height);
        }
        if (line.Count > 0)
        {
            lines.Add(line);
            directions.Add(direction);
        }
        return lines.Count == 0 ? PageText.Empty : new PageText(lines, directions);
    }

    private static List<string> StringInfoElements(string text)
    {
        var parts = new List<string>();
        var e = System.Globalization.StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext()) parts.Add((string)e.Current);
        return parts;
    }

    /// <summary>The upright box around a box of this size turned about its centre.</summary>
    private static RectD Box(double cx, double cy, double width, double height, double sin, double cos)
    {
        var w = Math.Abs(width * cos) + Math.Abs(height * sin);
        var h = Math.Abs(width * sin) + Math.Abs(height * cos);
        return new RectD(cx - w / 2, cy - h / 2, w, h);
    }

    /// <summary>
    /// Whether two readings of the same place differ only in what recognizers confuse: l, I, 1 and |; O and 0; S and 5; B and
    /// 8; rn and m; case. A heuristic like suspect words, never a score: such a change stays listed, marked as maybe misread.
    /// </summary>
    public static bool LooksLikeASlip(string a, string b) => a != b && Blurred(a) == Blurred(b);

    /// <summary>Marks only: a stray speck read as punctuation.</summary>
    public static bool IsOnlyMarks(string s) => s.Length > 0 && !s.Any(char.IsLetterOrDigit);

    private static string Blurred(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var raw in s.Replace("rn", "m", StringComparison.Ordinal))
        {
            var c = char.ToLowerInvariant(raw);
            if (char.IsWhiteSpace(c)) continue;
            sb.Append(c switch
            {
                'i' or '1' or '|' or '!' => 'l',
                '0' => 'o',
                '5' => 's',
                '8' => 'b',
                _ => c,
            });
        }
        return sb.ToString();
    }
}
