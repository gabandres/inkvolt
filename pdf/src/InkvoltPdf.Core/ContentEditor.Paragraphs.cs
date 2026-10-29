using System.Text;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>How a paragraph's lines sit in its box. Justified: every line but the last reaches both edges.</summary>
public enum ParagraphAlign { Left, Center, Right, Justified }

/// <summary>
/// A paragraph of a page's text, for Edit Text &amp; Images: lines of one font, size and color, one under the other at a
/// steady line step, their edges lined up (see <see cref="ContentEditor.GroupParagraphs"/>). Page space (points,
/// top-left origin of the page as shown).
/// </summary>
/// <param name="Runs">Its text runs (line by line, left to right).</param>
/// <param name="Lines">Each line's box, top to bottom.</param>
/// <param name="Text">Its text, the lines joined by a space (a line ending in a hyphen joins the next without one).</param>
/// <param name="Box">The lines' boxes together: the box new text wraps in (its width) and grows from (downward).</param>
/// <param name="LineStep">From one baseline to the next (points); for a single line, 1.2 times its size.</param>
/// <param name="FirstIndent">How much further right the first line starts than the others (left and justified text).</param>
/// <param name="Blocked">Why it can't be rewritten as one paragraph ("it is …"); null when it can.</param>
public sealed record TextParagraph(int PageIndex, IReadOnlyList<TextRun> Runs, IReadOnlyList<RectD> Lines, string Text, RectD Box,
    ParagraphAlign Align, double LineStep, double FirstIndent, string? Blocked)
{
    /// <summary>The nearest text or picture below the paragraph, across its width: what a longer text would run into.</summary>
    public RectD? Below { get; init; }

    /// <summary>Runs of spaces only drawn on its lines (some generators draw each space on its own): they go with its text.</summary>
    internal IReadOnlyList<TextRun> Spaces { get; init; } = [];

    /// <summary>Its type size on the page (points).</summary>
    public double FontSize => Runs.Count > 0 ? Runs[0].FontSize : 0;

    /// <summary>Its first run in its own font and look (not a stand-in or a look an earlier edit added): its font, style and color.</summary>
    public TextRun Lead => Runs.FirstOrDefault(r => !r.StandIn && !r.Styled) ?? Runs.FirstOrDefault(r => !r.StandIn) ?? Runs[0];

    /// <summary>The stretches of <see cref="Text"/> an earlier edit gave a look of their own (font, size, color, bold, italic).</summary>
    public IReadOnlyList<TextSpan> Spans { get; init; } = [];

    /// <summary>
    /// The line edges new text is laid out between (the box but the first line's indent); how far its own text reaches
    /// above and below its baseline (points).
    /// </summary>
    internal double Left, Right, Center, Ascent, Descent;

    /// <summary>
    /// What <paramref name="text"/> would look like here, its stretches with the looks <paramref name="spans"/> give them:
    /// its box, line count, missing characters and what it would run into.
    /// </summary>
    public ParagraphCheck Check(string text, IReadOnlyList<TextSpan>? spans = null)
    {
        if (Blocked is not null) return new ParagraphCheck(Box, Lines.Count, [], null);
        var layout = ContentEditor.LayOut(this, Runs, ContentEditor.ParagraphText(text), spans);
        return layout.Check;
    }
}

/// <summary>
/// New text for a paragraph: the box it would take, its line count, characters no font here can draw, and what it
/// would run into below (null: nothing).
/// </summary>
public sealed record ParagraphCheck(RectD Box, int LineCount, IReadOnlyList<string> Missing, RectD? Overlaps)
{
    /// <summary>Characters the paragraph's own font lacks, drawn from installed fonts (<see cref="StandIns"/>).</summary>
    public IReadOnlyList<string> Borrowed { get; init; } = [];

    /// <summary>The installed fonts they come from ("Arial Bold"), closest first.</summary>
    public IReadOnlyList<string> StandIns { get; init; } = [];

    /// <summary>The installed fonts the looks asked for are drawn in ("Georgia Bold"); a family not installed shows as the font used instead.</summary>
    public IReadOnlyList<string> Faces { get; init; } = [];

    /// <summary>Why the looks asked for can't be written (a color over a special ink); null when they can.</summary>
    public string? LookProblem { get; init; }
}

public static partial class ContentEditor
{
    private static PageContent WithParagraphs(PageContent content) => content with { Paragraphs = GroupParagraphs(content) };

    // ---- Grouping ----

    /// <summary>A line of text: runs on one baseline, left to right, with no column gap between them.</summary>
    private sealed class PLine(TextRun first)
    {
        public readonly List<TextRun> Runs = [first];
        public RectD Box = first.Box;
        public double Baseline = first.Origin.Y;
        public string Text = first.Text;
        /// <summary>Where each run's text starts in <see cref="Text"/>.</summary>
        public readonly List<int> Starts = [0];
        /// <summary>Its first run in its own look (not a stand-in or a look an edit gave it), else its first.</summary>
        public TextRun Lead => Runs.FirstOrDefault(r => !r.StandIn && !r.Styled) ?? Runs[0];
        public double Size => Lead.FontSize;
        /// <summary>Its biggest text against its own: 1 unless an edit made part of it bigger.</summary>
        public double Scale => Math.Max(1, Runs.Max(r => r.FontSize) / Math.Max(0.1, Size));

        public void Add(TextRun r)
        {
            var gap = r.Box.X - Box.Right;
            if (gap > 0.15 * Size && !Text.EndsWith(' ') && !r.Text.StartsWith(' ')) Text += " ";
            Starts.Add(Text.Length);
            Text += r.Text;
            Runs.Add(r);
            Box = Box.Union(r.Box);
        }
    }

    /// <summary>Lines stacked one under the other, and which alignments they still allow.</summary>
    private sealed class PStack(PLine first)
    {
        public readonly List<PLine> Lines = [first];
        public bool CanLeft = true, CanCenter = true, CanRight = true;
        public double Step;
    }

    /// <summary>
    /// The page's upright text runs as paragraphs, joined the way Export to Word joins lines (<c>DocLayout</c>): runs on
    /// one baseline with less than 2.5 ems between them make a line; a line carries on the paragraph above it when it
    /// is in the same font, size (within 5%) and color, below it with at most 0.65 ems between them and the same line
    /// step as the lines before (within 10%), overlapping it across, with its left edges (a first-line indent allowed),
    /// centers or right edges lined up; and when the line above didn't end short (its next first word would have fit
    /// on it). Turned text and runs of spaces only are left out.
    /// </summary>
    internal static IReadOnlyList<TextParagraph> GroupParagraphs(PageContent content)
    {
        var runs = content.Runs.Where(r => Math.Abs(r.Angle) < 0.5 && r.Text.Trim().Length > 0 && r.FontSize > 0.5 && r.Box.Width > 0).ToList();
        if (runs.Count == 0) return [];
        var result = new List<TextParagraph>();
        foreach (var stack in Stacks(LinesOf(runs)))
            foreach (var part in SplitShort(stack))
                result.Add(Paragraph(content, part));
        return result;
    }

    private static List<PLine> LinesOf(List<TextRun> runs)
    {
        var lines = new List<PLine>();
        var sorted = runs.OrderBy(r => r.Origin.Y).ToList();
        for (var i = 0; i < sorted.Count;)
        {
            // A band of runs on one baseline, then left to right.
            var y0 = sorted[i].Origin.Y;
            var j = i + 1;
            while (j < sorted.Count && sorted[j].Origin.Y - y0 <= 0.25 * Math.Max(sorted[i].FontSize, sorted[j].FontSize)) j++;
            PLine? cur = null;
            foreach (var r in sorted.Skip(i).Take(j - i).OrderBy(r => r.Box.X))
            {
                var size = Math.Max(r.FontSize, cur?.Size ?? 0);
                if (cur is not null && r.Box.X - cur.Box.Right <= 2.5 * size && r.Box.X >= cur.Box.Right - 0.5 * size) cur.Add(r);
                else
                {
                    cur = new PLine(r);
                    lines.Add(cur);
                }
            }
            i = j;
        }
        return lines;
    }

    private static List<PStack> Stacks(List<PLine> lines)
    {
        var stacks = new List<PStack>();
        foreach (var line in lines.OrderBy(l => l.Baseline).ThenBy(l => l.Box.X))
        {
            PStack? best = null;
            var bestGap = double.MaxValue;
            foreach (var s in stacks)
            {
                if (Joins(s, line) is not { } gap || gap >= bestGap) continue;
                best = s;
                bestGap = gap;
            }
            if (best is null)
            {
                stacks.Add(new PStack(line));
                continue;
            }
            var (l, c, r) = Fits(best, line);
            best.CanLeft = l;
            best.CanCenter = c;
            best.CanRight = r;
            if (best.Lines.Count == 1) best.Step = PlainStep(best.Lines[0], line, line.Baseline - best.Lines[0].Baseline);
            best.Lines.Add(line);
        }
        return stacks;
    }

    /// <summary>
    /// Same font, size (within 5%) and color; a stand-in run (characters an edit drew from another font) only needs the
    /// size and color, and text an edit gave a look of its own goes with anything.
    /// </summary>
    private static bool SameLook(TextRun a, TextRun b) =>
        a.Styled || b.Styled
        || (a.StandIn || b.StandIn || a.FontName == b.FontName && ReferenceEquals(a.Font, b.Font))
        && Math.Abs(a.FontSize - b.FontSize) <= Math.Max(0.3, 0.05 * a.FontSize) && a.Color == b.Color;

    /// <summary>The step from one baseline to the next as the paragraph's own (see <see cref="LayOut"/>: bigger text widens it).</summary>
    private static double PlainStep(PLine above, PLine below, double step) => step / (Rise * above.Scale + (1 - Rise) * below.Scale);

    /// <summary>How much of a line step is the line above's depth (the rest is the next line's height).</summary>
    private const double Rise = 0.25;

    /// <summary>The gap between the stack's last line and <paramref name="line"/> when the line carries the stack on; else null.</summary>
    private static double? Joins(PStack s, PLine line)
    {
        var last = s.Lines[^1];
        var size = last.Size;
        if (!SameLook(last.Lead, line.Lead)) return null;
        var step = PlainStep(last, line, line.Baseline - last.Baseline);
        if (step < 0.6 * size) return null;
        var gap = line.Box.Y - last.Box.Bottom;
        if (gap > 0.65 * size) return null;
        if (s.Lines.Count >= 2 && Math.Abs(step - s.Step) > Math.Max(0.5, 0.1 * size)) return null;
        if (line.Box.X >= last.Box.Right || line.Box.Right <= last.Box.X) return null;
        var (l, c, r) = Fits(s, line);
        return l || c || r ? Math.Max(0, gap) : null;
    }

    private static double Tolerance(double size) => Math.Max(1.5, 0.12 * size);

    /// <summary>The alignments the stack still allows with <paramref name="line"/> under it.</summary>
    private static (bool Left, bool Center, bool Right) Fits(PStack s, PLine line)
    {
        var first = s.Lines[0];
        var tol = Tolerance(first.Size);
        bool left;
        if (s.Lines.Count == 1)
        {
            var indent = first.Box.X - line.Box.X;
            left = Math.Abs(indent) <= tol || indent >= 0.5 * first.Size && indent <= 8 * first.Size;
        }
        else left = Math.Abs(line.Box.X - s.Lines[1].Box.X) <= tol;
        return (s.CanLeft && left, s.CanCenter && Math.Abs(line.Box.CenterX - first.Box.CenterX) <= tol,
            s.CanRight && Math.Abs(line.Box.Right - first.Box.Right) <= tol);
    }

    /// <summary>Splits a stack after each line that ended short: the next line's first word would have fit on it.</summary>
    private static List<List<PLine>> SplitShort(PStack s)
    {
        var parts = new List<List<PLine>>();
        var cur = new List<PLine> { s.Lines[0] };
        var width = s.Lines.Max(l => l.Box.Width);
        var right = s.Lines.Max(l => l.Box.Right);
        var indented = s.CanLeft && s.Lines.Count > 1 && s.Lines[0].Box.X - s.Lines[1].Box.X > Tolerance(s.Lines[0].Size);
        for (var i = 1; i < s.Lines.Count; i++)
        {
            var prev = s.Lines[i - 1];
            var line = s.Lines[i];
            var room = i == 1 && indented ? right - prev.Box.X : width;
            var word = line.Text.TrimStart().Split(' ')[0];
            var need = prev.Box.Width + WidthOf(line.Lead, " " + word, line);
            if (need < room - 0.5 * prev.Size)
            {
                parts.Add(cur);
                cur = [];
            }
            cur.Add(line);
        }
        parts.Add(cur);
        return parts;
    }

    /// <summary>How wide text is in a run's font and spacing (points); estimated from the line's characters when the font can't tell.</summary>
    private static double WidthOf(TextRun run, string text, PLine line)
    {
        if (run.Font is { } font && font.Encode(text) is { Missing.Count: 0 } enc)
            return run.Width(Parts(run, enc.Codes)) * run.Scale;
        return text.Length * line.Box.Width / Math.Max(1, line.Text.Length);
    }

    private static List<Part> Parts(TextRun run, IEnumerable<int> codes) =>
        [.. codes.Select(c => c == TextFont.Gap ? new Part(null, -run.GapEms * 1000) : new Part(c, 0))];

    private static TextParagraph Paragraph(PageContent content, List<PLine> lines)
    {
        var first = lines[0];
        var size = first.Size;
        var tol = Tolerance(size);
        var n = lines.Count;
        var rest = n > 1 ? lines.Skip(1).ToList() : lines;
        var left = rest.Min(l => l.Box.X);
        var right = lines.Max(l => l.Box.Right);
        var lefts = rest.All(l => Math.Abs(l.Box.X - left) <= tol);
        var indent = n > 1 && lefts ? first.Box.X - left : 0;
        if (indent < 0.5 * size) indent = 0;
        var flushLeft = lefts && (indent > 0 || Math.Abs(first.Box.X - left) <= tol);
        var center = lines.Average(l => l.Box.CenterX);
        var centers = lines.All(l => Math.Abs(l.Box.CenterX - center) <= tol);
        var rights = lines.All(l => Math.Abs(l.Box.Right - right) <= tol);
        var allLeft = flushLeft && indent == 0;
        var align = ParagraphAlign.Left;
        if (n >= 3 && flushLeft && lines.Take(n - 1).All(l => Math.Abs(l.Box.Right - right) <= tol)) align = ParagraphAlign.Justified;
        else if (n >= 2 && !allLeft && centers) align = ParagraphAlign.Center;
        else if (n >= 2 && !allLeft && rights) align = ParagraphAlign.Right;
        if (align is ParagraphAlign.Center or ParagraphAlign.Right)
        {
            indent = 0;
            left = lines.Min(l => l.Box.X);
        }

        var runs = lines.SelectMany(l => l.Runs).ToList();
        var mine = new HashSet<TextRun>(runs, ReferenceEqualityComparer.Instance);
        var blocked = runs.Select(r => r.Blocked).FirstOrDefault(b => b is not null);
        // Its own look: a run in its own font as it was; else (an edit gave all of it another look) its first run's.
        var own = runs.FirstOrDefault(r => !r.StandIn && !r.Styled) ?? runs.FirstOrDefault(r => !r.StandIn) ?? runs[0];
        if (blocked is null && runs.Any(r => !SameLook(own, r) || !r.StandIn && !r.Styled && (r.Bold != own.Bold || r.Italic != own.Italic)))
            blocked = "it mixes fonts, sizes or colors, and this version rewrites a paragraph in one font only";
        if (blocked is null && runs.Any(r => r.Info is null)) blocked = "part of it can't be read for editing";
        // Rewrapping lays words out left to right, so right-to-left text would come out in the wrong order.
        if (blocked is null && runs.Any(r => TrueTypeFont.CodePoints(r.Text).Any(c => Bidi.Classify(c) is Bidi.Cls.R or Bidi.Cls.AL)))
            blocked = "it is written right to left, and this version rewraps left-to-right text only";

        var text = new StringBuilder();
        var at = new List<(TextRun Run, int Start, int Length)>(); // where each run's text is in the paragraph's
        foreach (var l in lines)
        {
            var t = l.Text.Trim();
            if (text.Length > 0)
            {
                var hyphen = text.Length >= 2 && text[^1] == '-' && char.IsLetter(text[^2]) && t.Length > 0 && char.IsLower(t[0]);
                if (!hyphen) text.Append(' ');
            }
            var lead = l.Text.Length - l.Text.TrimStart().Length;
            for (var i = 0; i < l.Runs.Count; i++)
            {
                var from = Math.Clamp(l.Starts[i] - lead, 0, t.Length);
                var to = Math.Clamp(l.Starts[i] + l.Runs[i].Text.Length - lead, 0, t.Length);
                at.Add((l.Runs[i], text.Length + from, to - from));
            }
            text.Append(t);
        }
        var box = lines.Select(l => l.Box).Aggregate((a, b) => a.Union(b));
        // Other text on its lines (a raised footnote mark, a symbol in another font): rewrapping would leave it behind.
        // Spaces drawn on their own on its lines go with it.
        var spaces = new List<TextRun>();
        foreach (var r in content.Runs)
        {
            if (mine.Contains(r) || r.Box.Right <= box.X || r.Box.X >= box.Right || r.Box.Bottom <= box.Y || r.Box.Y >= box.Bottom) continue;
            var (cx, cy) = (r.Box.CenterX, r.Box.CenterY);
            // On a line: its middle inside the line's height, across from the line or right after its end (a mark after the last word).
            if (!lines.Any(l => cy > l.Box.Y && cy < l.Box.Bottom && r.Box.Right > l.Box.X && r.Box.X < l.Box.Right + 0.3 * l.Size)) continue;
            if (r.Text.Trim().Length > 0)
                blocked ??= "it has other text inside it (a raised mark, a symbol or words in another font), and this version rewrites a paragraph in one font only";
            else if (r.Info is not null && Math.Abs(r.Angle) < 0.5) spaces.Add(r);
        }
        // The line step as the paragraph's own: bigger text an edit gave part of it widened the steps around it.
        var step = n > 1 ? Enumerable.Range(1, n - 1).Average(i => PlainStep(lines[i - 1], lines[i], lines[i].Baseline - lines[i - 1].Baseline)) : 1.2 * size;
        var plain = own;

        // What follows below: the nearest other text or picture across the paragraph's width.
        RectD? below = null;
        foreach (var b in content.Runs.Where(r => !mine.Contains(r) && r.Text.Trim().Length > 0).Select(r => r.Box).Concat(content.Images.Select(i => i.Box)))
        {
            if (b.Y < box.Bottom - 1 || b.Right <= box.X + 1 || b.X >= box.Right - 1) continue;
            if (below is null || b.Y < below.Value.Y) below = b;
        }

        return new TextParagraph(runs[0].PageIndex, runs, [.. lines.Select(l => l.Box)], text.ToString(), box, align, step, indent, blocked)
        {
            Below = below,
            Spaces = spaces,
            Spans = SpansOf(plain, at),
            Left = left,
            Right = right,
            Center = center,
            Ascent = plain.Origin.Y - plain.Box.Y,
            Descent = plain.Box.Bottom - plain.Origin.Y,
        };
    }

    // ---- Laying out new text ----

    /// <summary>A paragraph's new text as typed: Windows line ends and tabs made plain, trailing space dropped.</summary>
    internal static string ParagraphText(string text) =>
        text.Replace("\r\n", "\n").Replace('\r', '\n').Replace('\t', ' ').TrimEnd();

    internal sealed record ParagraphLayout(List<(PointD Origin, List<Part> Parts)> Lines, ParagraphCheck Check, IReadOnlyList<int> Codes, string Encoded);

    /// <summary>
    /// New text laid out in a paragraph's box, in the font, size and spacing of its first run in content order (where it
    /// is written): words wrapped at the box's width (a single line doesn't wrap), a new line at each line break, the
    /// paragraph's alignment (a justified paragraph's last line, and each line before a break, start left), its line
    /// step. Stretches <paramref name="spans"/> give a look of their own are drawn in it: an installed font for another
    /// family, bold or italic, another size (a line with bigger text moves down as far as it needs), another color.
    /// </summary>
    internal static ParagraphLayout LayOut(TextParagraph p, IReadOnlyList<TextRun> runs, string text, IReadOnlyList<TextSpan>? spans = null)
    {
        var anchor = Anchor(runs);
        var font = anchor.Font!;
        var m = anchor with { };
        m.WordSpacing = 0; // the lines are written with Tw 0 (justification goes into adjustments)
        var enc = new MixedText(p, font, m, text, LooksOf(text, spans ?? Carry(p.Text, text, p.Spans)));
        if (enc.Missing.Count > 0) return new ParagraphLayout([], new ParagraphCheck(p.Box, p.Lines.Count, enc.Missing, null), [], "");

        double W(List<Part> parts) => parts.Count == 0 ? 0 : m.Width(parts) * m.Scale;
        var wrap = p.Lines.Count > 1;
        var lines = new List<(List<Part> Parts, List<int> Spaces, bool Last)>();
        var cur = new List<Part>();
        var spaceEnds = new List<int>(); // the index of each word space's last part in cur
        List<Part>? space = null;
        for (var pos = 0; pos <= text.Length;)
        {
            if (pos == text.Length || text[pos] == '\n')
            {
                lines.Add((cur, spaceEnds, true));
                cur = [];
                spaceEnds = [];
                space = null;
                pos++;
                continue;
            }
            if (text[pos] == ' ')
            {
                if (cur.Count > 0) space ??= enc.Encode(pos, pos + 1);
                pos++;
                continue;
            }
            var end = pos;
            while (end < text.Length && text[end] is not (' ' or '\n')) end++;
            var parts = enc.Encode(pos, end);
            pos = end;
            if (cur.Count == 0 || space is null)
            {
                cur.AddRange(parts);
                continue;
            }
            var avail = p.Right - p.Left - (lines.Count == 0 ? p.FirstIndent : 0);
            List<Part> joined = [.. cur, .. space, .. parts];
            if (!wrap || W(joined) <= avail + 0.01)
            {
                spaceEnds.Add(cur.Count + space.Count - 1);
                cur = joined;
            }
            else
            {
                lines.Add((cur, spaceEnds, false));
                cur = parts;
                spaceEnds = [];
            }
            space = null;
        }
        if (lines.Count == 1 && lines[0].Parts.Count == 0) lines.Clear(); // no text: the paragraph goes

        var placed = new List<(PointD, List<Part>)>();
        var maxRight = p.Box.Right;
        var minLeft = p.Box.X;
        double baseline = 0, scale = 1;
        for (var i = 0; i < lines.Count; i++)
        {
            var (parts, spaces, last) = lines[i];
            // A line with bigger text sits lower: the step to it grows with its biggest text, the step after it with its depth.
            var s = Math.Max(1, parts.Where(q => q.Code is not null || q.StandIn is not null).Select(q => q.Look?.Scale ?? 1).DefaultIfEmpty(1).Max());
            baseline = i == 0 ? p.Box.Y + p.Ascent * s : baseline + p.LineStep * (Rise * scale + (1 - Rise) * s);
            scale = s;
            var w = W(parts);
            var x0 = p.Left + (i == 0 ? p.FirstIndent : 0);
            var x = p.Align switch
            {
                ParagraphAlign.Right => p.Right - w,
                ParagraphAlign.Center => p.Center - w / 2,
                _ => x0,
            };
            if (p.Align == ParagraphAlign.Justified && !last && spaces.Count > 0 && p.Right - x0 - w > 0.01)
            {
                // The room left over goes into the word spaces, as adjustments after each space (at the space's size).
                var extra = -(p.Right - x0 - w) / spaces.Count / m.Scale * 1000 / (m.Size * m.HScale);
                var spread = new List<Part>(parts.Count + spaces.Count);
                for (var k = 0; k < parts.Count; k++)
                {
                    spread.Add(parts[k]);
                    if (spaces.Contains(k)) spread.Add(new Part(null, extra / (parts[k].Look?.Scale ?? 1), null, parts[k].Look));
                }
                parts = spread;
                w = W(parts);
            }
            placed.Add((new PointD(x, baseline), Merged(parts)));
            maxRight = Math.Max(maxRight, x + w);
            minLeft = Math.Min(minLeft, x);
        }
        var bottom = placed.Count == 0 ? p.Box.Y + p.Ascent + p.Descent : baseline + p.Descent * scale;
        var box = RectD.FromEdges(minLeft, p.Box.Y, maxRight, Math.Max(bottom, p.Box.Y + 1));
        RectD? overlaps = p.Below is { } b && box.Bottom > b.Y + 0.5 && b.Right > box.X && b.X < box.Right ? b : null;
        var problem = enc.Colored && anchor.Info?.FillOp is null
            ? "this paragraph's color is a special ink (a pattern or spot color), so part of it can't be given another color"
            : null;
        var check = new ParagraphCheck(box, placed.Count, [], overlaps) { Borrowed = enc.Borrowed, StandIns = enc.Names, Faces = enc.Faces, LookProblem = problem };
        return new ParagraphLayout(placed, check, enc.Codes, enc.Text.ToString());
    }

    /// <summary>
    /// A line's parts with stretches in other fonts next to each other (words and the spaces between them, the
    /// adjustments that justify them) joined into one, so each is drawn by one operator.
    /// </summary>
    private static List<Part> Merged(List<Part> parts)
    {
        var result = new List<Part>(parts.Count);
        for (var i = 0; i < parts.Count; i++)
        {
            if (parts[i].StandIn is not { } a)
            {
                result.Add(parts[i]);
                continue;
            }
            var look = parts[i].Look;
            var glyphs = new List<PlacedGlyph>(a.Glyphs);
            var text = new StringBuilder(a.Text);
            var width = a.Width;
            var j = i + 1;
            while (true)
            {
                // Adjustments of the same look in between become room, then the next stretch of the same look follows.
                var k = j;
                double room = 0;
                while (k < parts.Count && parts[k] is { Code: null, StandIn: null } adj && ReferenceEquals(adj.Look, look))
                {
                    room -= adj.Number / 1000;
                    k++;
                }
                if (k >= parts.Count || parts[k].StandIn is not { } b || !ReferenceEquals(parts[k].Look, look) || b.Rtl || a.Rtl) break;
                var off = width + room;
                glyphs.AddRange(b.Glyphs.Select(g => g with { X = g.X + off }));
                text.Append(b.Text);
                width = off + b.Width;
                j = k + 1;
            }
            result.Add(j == i + 1 ? parts[i] : new Part(null, 0, new ShapedLine(text.ToString(), glyphs, width, false), look));
            i = j - 1;
        }
        return result;
    }

    /// <summary>Where a paragraph's new text is written: its first run in content order in its own font and look.</summary>
    private static TextRun Anchor(IReadOnlyList<TextRun> runs) =>
        runs.Where(r => !r.StandIn && !r.Styled).MinBy(r => r.Id) ?? runs.Where(r => !r.StandIn).MinBy(r => r.Id) ?? runs.MinBy(r => r.Id)!;

    /// <summary>
    /// A paragraph's new text in its own font's codes; the characters that font lacks drawn from the closest installed
    /// font (<see cref="StandInFonts"/>), each stretch shaped as one <see cref="Part.StandIn"/>; stretches with a look
    /// of their own carry it (<see cref="Part.Look"/>), drawn in an installed font when the look asks for another
    /// family, bold or italic.
    /// </summary>
    private sealed class MixedText
    {
        private readonly TextParagraph _p;
        private readonly TextFont _font;
        private readonly TextRun _run;
        private readonly string _text;
        private readonly TextLook?[] _looks;
        private readonly HashSet<string> _lacking = [];
        private readonly Dictionary<int, StandInFont> _standIns;
        private readonly Dictionary<TextLook, PartLook?> _resolved = [];

        /// <summary>The own font's codes written, and the text they stand for (for <see cref="TextFont.Prepare"/>).</summary>
        public readonly List<int> Codes = [];
        public readonly StringBuilder Text = new();
        public readonly List<string> Missing = [];
        public readonly List<string> Borrowed = [];
        public readonly List<string> Names = [];
        public readonly List<string> Faces = [];
        /// <summary>A look asks for another color.</summary>
        public bool Colored;

        public MixedText(TextParagraph p, TextFont font, TextRun run, string text, TextLook?[] looks)
        {
            _p = p;
            _font = font;
            _run = run;
            _text = text;
            _looks = looks;
            var lacking = new List<string>();
            foreach (var (el, at) in Elements(0, text.Length))
            {
                if (el.All(char.IsWhiteSpace)) continue;
                if (Resolve(at) is { Face: { } face })
                {
                    // In a font a look asked for: what it lacks comes from the script fallbacks, else nothing.
                    if (!TrueTypeFont.CodePoints(el).All(cp => face.Font.Has(cp) || SystemFonts.For(cp, face.Font) is { } f && f.Has(cp)) && !Missing.Contains(el))
                        Missing.Add(el);
                }
                else if (font.Encode(el).Missing.Count > 0 && !lacking.Contains(el)) lacking.Add(el);
            }
            _standIns = StandInFonts.For(font, [.. lacking.SelectMany(TrueTypeFont.CodePoints).Distinct()]);
            foreach (var el in lacking)
            {
                if (TrueTypeFont.CodePoints(el).All(_standIns.ContainsKey))
                {
                    _lacking.Add(el);
                    Borrowed.Add(el);
                    foreach (var cp in TrueTypeFont.CodePoints(el))
                        if (!Names.Contains(_standIns[cp].Name)) Names.Add(_standIns[cp].Name);
                }
                else if (!Missing.Contains(el)) Missing.Add(el);
            }
        }

        /// <summary>The text elements (a character with its marks, a surrogate pair) of [start, end), with where each starts.</summary>
        private IEnumerable<(string Element, int At)> Elements(int start, int end)
        {
            var sub = _text[start..end];
            var e = System.Globalization.StringInfo.GetTextElementEnumerator(sub);
            while (e.MoveNext()) yield return (e.GetTextElement(), start + e.ElementIndex);
        }

        /// <summary>The look at a place of the text, resolved; null where it is the paragraph's own.</summary>
        private PartLook? Resolve(int at)
        {
            if (_looks[at] is not { IsPlain: false } look) return null;
            if (_resolved.TryGetValue(look, out var known)) return known;
            var lead = _p.Lead;
            var scale = look.Size is > 0 and var size && Math.Abs(size - _p.FontSize) > 0.01 ? size / _p.FontSize : 1;
            int? color = look.Color is { } c && c != lead.Color ? c : null;
            var bold = look.Bold ?? lead.Bold;
            var italic = look.Italic ?? lead.Italic;
            StandInFont? face = null;
            var family = look.Font is { } f && !f.Equals(FontNames.Family(lead.FontName), StringComparison.OrdinalIgnoreCase) ? f : null;
            if (family is not null || bold != lead.Bold || italic != lead.Italic)
            {
                face = StandInFonts.Styled(_font, family, bold, italic);
                if (!Faces.Contains(face.Name)) Faces.Add(face.Name);
            }
            Colored |= color is not null;
            var resolved = scale == 1 && color is null && face is null ? null : new PartLook(scale, color, face, look);
            _resolved[look] = resolved;
            return resolved;
        }

        private List<Part> Own(string chunk, PartLook? look)
        {
            var codes = _font.Encode(chunk).Codes;
            Codes.AddRange(codes);
            Text.Append(chunk);
            var parts = Parts(_run, codes);
            if (look is not null) for (var i = 0; i < parts.Count; i++) parts[i] = parts[i] with { Look = look };
            return parts;
        }

        /// <summary>The parts of [start, end): stretches in its own font, and stretches of each other font shaped, each with its look.</summary>
        public List<Part> Encode(int start, int end)
        {
            var parts = new List<Part>();
            var chunk = new StringBuilder();
            (PartLook? Look, StandInFont? Face) cur = default; // no face: the own font
            void Flush()
            {
                if (chunk.Length == 0) return;
                if (cur.Face is null) parts.AddRange(Own(chunk.ToString(), cur.Look));
                else parts.Add(new Part(null, 0, TextShaper.Shape(chunk.ToString(), cur.Face.Font), cur.Look));
                chunk.Clear();
            }
            foreach (var (el, at) in Elements(start, end))
            {
                var look = Resolve(at);
                var face = look?.Face ?? (_lacking.Contains(el) ? _standIns[TrueTypeFont.CodePoints(el).First()] : null);
                if ((look, face) != cur) Flush();
                cur = (look, face);
                chunk.Append(el);
            }
            Flush();
            return parts;
        }
    }

    // ---- Writing ----

    /// <summary>
    /// Replaces a paragraph's text: its show operators are taken out (each leaves the text position where it found it,
    /// so what follows stays in place) and the new text is written where the first of them was, in the paragraph's own
    /// font, laid out by <see cref="LayOut"/>. A box that would grow into what follows below is refused unless
    /// <paramref name="allowOverlap"/> (the caller has warned). Bytes in → bytes out, as <see cref="ReplaceText"/>.
    /// </summary>
    /// <exception cref="ContentEditException">The font can't draw the text (the message names the missing characters), the
    /// new text would run into what follows (<see cref="ContentEditException.Overlaps"/>), the paragraph can't be edited, or the page changed.</exception>
    public static byte[] ReplaceParagraph(byte[] data, string? password, TextParagraph paragraph, string text, bool allowOverlap = false,
        IReadOnlyList<TextSpan>? spans = null)
    {
        if (paragraph.Blocked is { } why0) throw new ContentEditException($"This paragraph can't be edited: {why0}.");
        text = ParagraphText(text);
        spans ??= Carry(paragraph.Text, text, paragraph.Spans);
        if (text == paragraph.Text && SameSpans(text, spans, paragraph.Spans)) return data;
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited");
        var page = PageOf(doc, paragraph.PageIndex);
        var streams = Streams(page);
        var ops = ContentLexer.Parse(streams.Bytes);
        var walk = Walk(page, paragraph.PageIndex, ops, default);
        var now = new List<TextRun>();
        foreach (var run in paragraph.Runs)
        {
            var found = walk.Content.Runs.FirstOrDefault(r => r.Id == run.Id && r.Text == run.Text)
                        ?? walk.Content.Runs.Where(r => r.Text == run.Text && Near(r.Box, run.Box)).MinBy(r => Math.Abs(r.Box.X - run.Box.X) + Math.Abs(r.Box.Y - run.Box.Y));
            if (found is { Blocked: { } why }) throw new ContentEditException($"This text can't be edited: {why}.");
            if (found?.Info is null || now.Any(r => r.Id == found.Id))
                throw new ContentEditException("The page changed since this paragraph was picked. Pick it again.");
            now.Add(found);
        }
        // Spaces drawn on their own on its lines go too (when they are still there).
        var spaces = paragraph.Spaces
            .Select(s => walk.Content.Runs.FirstOrDefault(r => r.Id == s.Id && r.Text == s.Text && r.Info is not null))
            .Where(r => r is not null && now.All(n => n.Id != r.Id)).Select(r => r!).ToList();
        var anchor = Anchor(now);
        var font = anchor.Font!;
        var layout = LayOut(paragraph, now, text, spans);
        if (layout.Check.Missing.Count > 0)
        {
            var list = string.Join(", ", layout.Check.Missing.Take(12).Select(c => char.IsControl(c[0]) || char.GetUnicodeCategory(c, 0) is System.Globalization.UnicodeCategory.PrivateUse or System.Globalization.UnicodeCategory.Surrogate
                ? $"U+{char.ConvertToUtf32(c, 0):X4}" : $"“{c}”"));
            throw new ContentEditException($"Neither this paragraph's font nor any font on this PC has {list}, so it can't be written. Leave {(layout.Check.Missing.Count == 1 ? "it" : "them")} out, or add a text box instead.", layout.Check.Missing);
        }
        if (layout.Check.LookProblem is { } lp) throw new ContentEditException($"This can't be written: {lp}.");
        if (layout.Check.Overlaps is { } o && !allowOverlap)
            throw new ContentEditException(
                $"The new text takes {layout.Check.LineCount} lines and would run into what follows below it. Shorten it, or confirm to write it anyway.")
            { Overlaps = o };
        font.Prepare(doc, layout.Codes, layout.Encoded);

        // Characters the font lacks: drawn in stand-in fonts, embedded as subsets under names no page font has.
        var fontRes = PdfObj.Dict(PdfObj.Dict(page.Elements["/Resources"])?.Elements["/Font"]);
        var k = 1;
        while (fontRes?.Elements.Keys.Any(key => key.StartsWith($"/{StandInKey}{k}_", StringComparison.Ordinal)) == true) k++;
        var writer = new CidFontWriter($"/{StandInKey}{k}_");

        var edits = new List<(int Start, int End, string Text)>();
        foreach (var run in now)
        {
            var op = ops[run.Id];
            edits.Add((op.Start, op.End, run == anchor ? WriteParagraph(page, op, run, font, layout, writer) : Removed(op, run)));
        }
        if (!writer.IsEmpty) AddFonts(doc, page, writer.BuildFonts(doc));
        foreach (var run in spaces) edits.Add((ops[run.Id].Start, ops[run.Id].End, Removed(ops[run.Id], run)));
        WriteContent(doc, page, streams, ops, edits);
        SignedEdits.NoteRemoval(); // the old text stays in a signed file's earlier revision
        return PdfObj.Save(doc);
    }

    /// <summary>Whether two sets of spans give every character of <paramref name="text"/> the same look.</summary>
    private static bool SameSpans(string text, IReadOnlyList<TextSpan> a, IReadOnlyList<TextSpan> b)
    {
        var x = LooksOf(text, a);
        var y = LooksOf(text, b);
        for (var i = 0; i < text.Length; i++)
            if ((x[i] is { IsPlain: false } ? x[i] : null) != (y[i] is { IsPlain: false } ? y[i] : null)) return false;
        return true;
    }

    /// <summary>A TJ adjustment that moves the text position as far as <paramref name="advance"/> (text space) without drawing.</summary>
    private static string Move(TextRun run, double advance)
    {
        var k = run.Size * run.HScale;
        if (Math.Abs(k) < 1e-9 || Math.Abs(advance) < 1e-9) return "";
        return $"[{ContentLexer.Number(-advance * 1000 / k)}] TJ";
    }

    /// <summary>A show operator taken out: what it set and moved stays (' and " go to the next line, " sets the spacing).</summary>
    private static string Removed(COp op, TextRun run)
    {
        var move = Move(run, run.Info!.Advance);
        return op.Name switch
        {
            "'" => $"T* {move}",
            "\"" => $"{ContentLexer.Number(op.N(0))} Tw {ContentLexer.Number(op.N(1))} Tc T* {move}",
            _ => move.Length > 0 ? move : " ",
        };
    }

    /// <summary>
    /// The paragraph's new lines in place of its first show operator: each line placed with Tm (word spacing 0 while
    /// they are written), then the line matrix and text position the operator left, so the rest of the content draws
    /// where it did.
    /// </summary>
    private static string WriteParagraph(PdfPage page, COp op, TextRun run, TextFont font, ParagraphLayout layout, CidFontWriter writer)
    {
        var info = run.Info!;
        var sb = new StringBuilder();
        if (op.Name == "\"") sb.Append($"{ContentLexer.Number(op.N(0))} Tw {ContentLexer.Number(op.N(1))} Tc ");
        var tw = run.WordSpacing;
        if (Math.Abs(tw) > 1e-9) sb.Append("0 Tw ");
        var toText = info.Tm.Times(info.Ctm).Invert() ?? throw new ContentEditException("This text is drawn squashed flat, so it can't be rewritten.");
        foreach (var (origin, parts) in layout.Lines)
        {
            if (parts.Count == 0) continue;
            var user = PdfObj.ToPdf(page, origin.X, origin.Y);
            var (tx, ty) = toText.Apply(user.X, user.Y);
            var lineTm = new Mat(1, 0, 0, 1, tx, ty - info.Rise).Times(info.Tm);
            sb.Append(lineTm.Write()).Append(" Tm ");
            WriteLine(sb, info.Hex, font, parts, run, writer);
        }
        if (Math.Abs(tw) > 1e-9) sb.Append(ContentLexer.Number(tw)).Append(" Tw ");
        // Back where the operator left things: the line matrix after it, the text position moved along its baseline.
        var tlm = info.TlmAfter;
        double along = 0;
        if (Math.Abs(tlm.A) >= Math.Abs(tlm.B) && Math.Abs(tlm.A) > 1e-12) along = (info.Tm.E - tlm.E) / tlm.A;
        else if (Math.Abs(tlm.B) > 1e-12) along = (info.Tm.F - tlm.F) / tlm.B;
        sb.Append(tlm.Write()).Append(" Tm ").Append(Move(run, along + info.Advance));
        return sb.ToString();
    }

    /// <summary>
    /// A line's parts as TJ arrays of codes and adjustments; stretches in other fonts in between, drawn by
    /// <paramref name="writer"/> with no character spacing; a stretch with a look of its own inside a marked-content
    /// tag (<see cref="LookTagName"/>), at its size and in its color. The run's font, size, spacing, rise and color are set back after.
    /// </summary>
    private static void WriteLine(StringBuilder sb, bool hex, TextFont font, List<Part> parts, TextRun run, CidFontWriter writer)
    {
        var info = run.Info!;
        var tokens = new List<string>();
        var codes = new List<int>();
        PartLook? tag = null;
        int? color = null; // null: the run's own
        var scale = 1.0;
        var ownFont = true;
        void Flush()
        {
            if (codes.Count == 0) return;
            var bytes = font.ToBytes(codes);
            tokens.Add(hex ? ContentLexer.HexString(bytes) : ContentLexer.Literal(bytes));
            codes.Clear();
        }
        void Close()
        {
            Flush();
            if (tokens.Count > 0) sb.Append('[').Append(string.Join(' ', tokens)).Append("] TJ ");
            tokens.Clear();
        }
        void Look(PartLook? look)
        {
            if (!ReferenceEquals(look, tag))
            {
                Close();
                if (tag is not null) sb.Append("EMC ");
                if (look is not null) sb.Append(LookTag.Write(look.Asked));
                tag = look;
            }
            if (look?.Color != color)
            {
                Close();
                sb.Append(look?.Color is { } c ? RgbOp(c) : info.FillOp + " ");
                color = look?.Color;
            }
        }
        void OwnFont(double s)
        {
            if (ownFont && Math.Abs(s - scale) < 1e-9) return;
            Close();
            sb.Append('/').Append(EscapeName(run.FontKey)).Append(' ').Append(ContentLexer.Number(run.Size * s)).Append(" Tf ");
            ownFont = true;
            scale = s;
        }
        foreach (var part in parts)
        {
            Look(part.Look);
            var s = part.Look?.Scale ?? 1;
            if (part.StandIn is { } standIn)
            {
                Close();
                var tc = Math.Abs(run.CharSpacing) > 1e-9;
                if (tc) sb.Append("0 Tc ");
                writer.Emit(sb, standIn, run.Size * s);
                ownFont = false;
                if (tc) sb.Append(ContentLexer.Number(run.CharSpacing)).Append(" Tc ");
                if (Math.Abs(info.Rise) > 1e-9) sb.Append(ContentLexer.Number(info.Rise)).Append(" Ts ");
                continue;
            }
            OwnFont(s);
            if (part.Code is { } code) codes.Add(code);
            else if (Math.Abs(part.Number) > 1e-9)
            {
                Flush();
                tokens.Add(ContentLexer.Number(part.Number));
            }
        }
        Look(null);
        OwnFont(1);
        Close();
    }

    /// <summary>Adds fonts to the page's own font resources (copying shared dictionaries first).</summary>
    private static void AddFonts(PdfDocument doc, PdfPage page, PdfDictionary fonts)
    {
        var res = page.Elements["/Resources"] switch
        {
            PdfDictionary d => d,
            PdfReference r when r.Value is PdfDictionary shared => shared.Clone(),
            _ => new PdfDictionary(doc),
        };
        page.Elements["/Resources"] = res;
        var fd = res.Elements["/Font"] switch
        {
            PdfDictionary d => d,
            PdfReference r when r.Value is PdfDictionary shared => shared.Clone(),
            _ => new PdfDictionary(doc),
        };
        res.Elements["/Font"] = fd;
        foreach (var (name, item) in fonts.Elements) fd.Elements[name] = item;
    }
}
