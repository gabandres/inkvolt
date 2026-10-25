using System.Text;

namespace InkvoltPdf.Core;

/// <summary>A character as a page draws it: its text, its box (page space), its look and the line it belongs to.</summary>
public sealed record ExportGlyph(string Text, RectD Rect, ExportSpan Look);

/// <summary>
/// Fixes to a page's characters before they become lines: accents drawn as separate characters joined to their letters,
/// and runs of dots or rules (a form's fill-in lines) turned into one leader.
/// </summary>
public static class ExportGlyphs
{
    /// <summary>A dot leader (a run of dots); its box spans the run. Laid out as a tab with dots up to where it ended.</summary>
    public const char DotLeader = '';

    /// <summary>A rule to write on ("______"), laid out as a tab with an underline.</summary>
    public const char LineLeader = '';

    /// <summary>A dashed rule ("-------"), laid out as a tab with hyphens.</summary>
    public const char DashLeader = '';

    public static bool IsLeader(char c) => c is DotLeader or LineLeader or DashLeader;

    /// <summary>
    /// Whether a glyph is an accent standing alone (a space or the line's end on both sides): one no letter took. Some
    /// fonts name other shapes after accents ("dotaccent" drawing "="), so such a glyph is worth a look at its shape.
    /// </summary>
    public static bool IsLoneAccent(IReadOnlyList<ExportGlyph> line, int k) =>
        line[k].Text.Length == 1 && Combining.ContainsKey(line[k].Text[0])
        && (k == 0 || string.IsNullOrWhiteSpace(line[k - 1].Text))
        && (k == line.Count - 1 || string.IsNullOrWhiteSpace(line[k + 1].Text));

    /// <summary>
    /// What a glyph draws, from its rendering (alpha per pixel, <paramref name="width"/> × <paramref name="height"/>,
    /// <paramref name="pixelsPerPoint"/>) and its type size: "=" for two level bars as wide as each other (half the size
    /// across at least), "−" for one such bar; null for anything else (an accent's dot or stroke is small).
    /// </summary>
    public static string? DrawnAs(byte[] alpha, int width, int height, double pixelsPerPoint, double size)
    {
        int left = width, right = -1;
        var rows = new List<(int Y, int From, int To)>();
        for (var y = 0; y < height; y++)
        {
            int from = -1, to = -1, ink = 0;
            for (var x = 0; x < width; x++)
                if (alpha[y * width + x] > 96) { if (from < 0) from = x; to = x; ink++; }
            if (from < 0) continue;
            if (ink < 0.8 * (to - from + 1)) return null; // gaps in a row: dots side by side ("¨"), not a bar
            rows.Add((y, from, to));
            (left, right) = (Math.Min(left, from), Math.Max(right, to));
        }
        if (rows.Count == 0 || (right - left + 1) < 0.35 * size * pixelsPerPoint) return null;
        // Runs of rows with ink, each a bar when it is thin and spans most of the ink's width.
        var bars = new List<(int Top, int Bottom)>();
        foreach (var r in rows)
        {
            if (bars.Count > 0 && r.Y == bars[^1].Bottom + 1) bars[^1] = (bars[^1].Top, r.Y);
            else bars.Add((r.Y, r.Y));
        }
        var inkWidth = right - left + 1;
        foreach (var (top, bottom) in bars)
        {
            if (bottom - top + 1 > 0.2 * size * pixelsPerPoint) return null; // not thin: a letter's shape
            var span = rows.Where(r => r.Y >= top && r.Y <= bottom).Max(r => r.To - r.From + 1);
            if (span < 0.8 * inkWidth) return null;
        }
        return bars.Count switch { 2 => "=", 1 => "−", _ => null };
    }

    // Spacing accents a typesetter (TeX, older PostScript drivers) draws over or under a letter, and their combining forms.
    private static readonly Dictionary<char, char> Combining = new()
    {
        ['´'] = '́', ['`'] = '̀', ['ˆ'] = '̂', ['˜'] = '̃', ['¨'] = '̈', ['ˇ'] = '̌',
        ['˚'] = '̊', ['˘'] = '̆', ['˝'] = '̋', ['¯'] = '̄', ['˙'] = '̇', ['¸'] = '̧',
        ['˛'] = '̨',
    };

    /// <summary>Accents that go under the letter (cedilla, ogonek); the rest go over it.</summary>
    private static bool Below(char accent) => accent is '¸' or '˛';

    /// <summary>
    /// Joins accents drawn as their own characters (often with no width, placed over the letter by a kern back) to the
    /// letter they sit on: "Direcci" "´" "on" becomes "Dirección", and a capital's raised accent, which MuPDF reads as a
    /// line of its own above, goes onto its letter too ("PREDICACI" "´" "ON" → "PREDICACIÓN"). A space MuPDF put before
    /// the accent (the kern back looked like a gap) goes as well. A dotless i or j takes the accent as i or j. Before
    /// that, runs of four or more dots, underscores or dashes (spaces between them allowed), or of one accent repeated (a
    /// form's fonts sometimes name their leader dot "ogonek"), become one leader character spanning the run. Only
    /// left-to-right lines are changed; the result has one list per line given (a line of only an accent ends empty).
    /// </summary>
    public static List<List<ExportGlyph>> Compose(List<List<ExportGlyph>> lines, Func<int, bool>? leftToRight = null)
    {
        var ltr = leftToRight ?? (_ => true);
        // Leaders first: a run of one accent repeated is a leader, not accents for the letters around it.
        var result = lines.Select((l, i) => ltr(i) ? Leaders(l) : [.. l]).ToList();
        // Letters that can take an accent, by line.
        var letters = new List<(int Line, int Index)>();
        for (var i = 0; i < result.Count; i++)
        {
            if (!ltr(i)) continue;
            for (var k = 0; k < result[i].Count; k++)
                // "ˆ" and "ˇ" are letters to .NET (modifier letters): accents, not letters to put one on.
                if (result[i][k].Text.Length == 1 && char.IsLetter(result[i][k].Text[0]) && !Combining.ContainsKey(result[i][k].Text[0]))
                    letters.Add((i, k));
        }
        var removed = new HashSet<(int, int)>();
        for (var i = 0; i < result.Count; i++)
        {
            if (!ltr(i)) continue;
            for (var k = 0; k < result[i].Count; k++)
            {
                var g = result[i][k];
                if (g.Text.Length != 1 || !Combining.TryGetValue(g.Text[0], out var mark)) continue;
                var size = Math.Max(1, g.Look.Size);
                // One set over a letter by a kern back has little or no width; one with its own width (TeX's \accent
                // keeps it and kerns around it) must sit over its letter in the same line, centered on it.
                var wide = g.Rect.Width > 0.3 * size;
                var cx = g.Rect.CenterX;
                (int Line, int Index)? best = null;
                var bestDistance = double.MaxValue;
                foreach (var (li, lk) in letters)
                {
                    if (removed.Contains((li, lk))) continue;
                    var b = result[li][lk];
                    if (Math.Abs(b.Look.Size - g.Look.Size) > 0.35 * size) continue;
                    var inset = 0.1 * b.Rect.Width;
                    if (cx < b.Rect.X + inset || cx > b.Rect.Right - inset) continue;
                    // Over the letter (raised, or level with it), or under it for a cedilla.
                    var dy = g.Rect.CenterY - b.Rect.CenterY;
                    if (Math.Abs(dy) > 1.2 * size) continue;
                    if (Below(g.Text[0]) ? dy < -0.2 * size : dy > 0.2 * size) continue;
                    if (wide && Math.Abs(dy) > 0.95 * size) continue;
                    var distance = Math.Abs(dy) + Math.Abs(cx - b.Rect.CenterX);
                    if (distance < bestDistance) (best, bestDistance) = ((li, lk), distance);
                }
                if (best is not { } at) continue;
                var baseGlyph = result[at.Line][at.Index];
                var letter = baseGlyph.Text switch { "ı" => "i", "ȷ" => "j", _ => baseGlyph.Text };
                result[at.Line][at.Index] = baseGlyph with { Text = (letter + mark).Normalize(NormalizationForm.FormC) };
                removed.Add((i, k));
                // MuPDF reads the kern back before an accent as a space: drop it when the letter starts where the one
                // before it ended (no room for a space), not a real space between words ("en ´areas").
                for (var s = k - 1; s >= 1 && s >= k - 2; s--)
                {
                    var sp = result[i][s];
                    if (removed.Contains((i, s))) continue;
                    if (!string.IsNullOrWhiteSpace(sp.Text)) break;
                    var before = result[i][s - 1];
                    if (at.Line == i && !string.IsNullOrWhiteSpace(before.Text) && baseGlyph.Rect.X < before.Rect.Right + 0.15 * size)
                        removed.Add((i, s));
                    break;
                }
            }
        }
        for (var i = 0; i < result.Count; i++)
            if (removed.Any(r => r.Item1 == i))
                result[i] = [.. result[i].Where((_, k) => !removed.Contains((i, k)))];
        return result;
    }

    private static char? LeaderKind(string text) => text switch
    {
        "." or "·" or "․" or "‥" or "…" or "•" => DotLeader,
        "_" or "‗" => LineLeader,
        "-" or "–" or "—" or "‒" or "−" => DashLeader,
        _ when text.Length == 1 && Combining.ContainsKey(text[0]) => DotLeader,
        _ => null,
    };

    /// <summary>Runs of four or more of one leader character (spaces between allowed) as one leader glyph.</summary>
    private static List<ExportGlyph> Leaders(List<ExportGlyph> line)
    {
        var output = new List<ExportGlyph>(line.Count);
        for (var k = 0; k < line.Count;)
        {
            var g = line[k];
            if (LeaderKind(g.Text) is not { } kind)
            {
                output.Add(g);
                k++;
                continue;
            }
            // Extend over the same character, with spaces between allowed; "..." and "--" stay text.
            var end = k;
            var count = 1;
            for (var j = k + 1; j < line.Count; j++)
            {
                if (line[j].Text == g.Text) { end = j; count++; }
                else if (!string.IsNullOrWhiteSpace(line[j].Text)) break;
            }
            var box = g.Rect;
            for (var j = k + 1; j <= end; j++) box = box.Union(line[j].Rect);
            // Not an ellipsis or a rule typed in text: short runs, runs in a monospaced font ("+-----+"), runs
            // between letters ("wait....then").
            bool LetterAt(int j) => j >= 0 && j < line.Count && line[j].Text.Length > 0 && char.IsLetterOrDigit(line[j].Text[0]);
            if (count < 4 || box.Width < 2.5 * Math.Max(1, g.Look.Size) || g.Look.Mono || (LetterAt(k - 1) && LetterAt(end + 1)))
            {
                output.Add(g);
                k++;
                continue;
            }
            output.Add(new ExportGlyph(kind.ToString(), box, g.Look));
            k = end + 1;
        }
        return output;
    }
}
