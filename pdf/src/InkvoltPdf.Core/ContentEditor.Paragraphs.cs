using System.Text;
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

    /// <summary>Its type size on the page (points).</summary>
    public double FontSize => Runs.Count > 0 ? Runs[0].FontSize : 0;

    /// <summary>The line edges new text is laid out between (the box but the first line's indent) and the first baseline.</summary>
    internal double Left, Right, Center, Baseline, FirstBottom;

    /// <summary>What <paramref name="text"/> would look like here: its box, line count, missing characters and what it would run into.</summary>
    public ParagraphCheck Check(string text)
    {
        if (Blocked is not null) return new ParagraphCheck(Box, Lines.Count, [], null);
        var layout = ContentEditor.LayOut(this, Runs, ContentEditor.ParagraphText(text));
        return layout.Check;
    }
}

/// <summary>New text for a paragraph: the box it would take, its line count, characters its font lacks, and what it would run into below (null: nothing).</summary>
public sealed record ParagraphCheck(RectD Box, int LineCount, IReadOnlyList<string> Missing, RectD? Overlaps);

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
        public double Size = first.FontSize;
        public string Text = first.Text;
        public TextRun Lead => Runs[0];

        public void Add(TextRun r)
        {
            var gap = r.Box.X - Box.Right;
            if (gap > 0.15 * Size && !Text.EndsWith(' ') && !r.Text.StartsWith(' ')) Text += " ";
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
            if (best.Lines.Count == 1) best.Step = line.Baseline - best.Lines[0].Baseline;
            best.Lines.Add(line);
        }
        return stacks;
    }

    private static bool SameLook(TextRun a, TextRun b) =>
        a.FontName == b.FontName && ReferenceEquals(a.Font, b.Font) && Math.Abs(a.FontSize - b.FontSize) <= Math.Max(0.3, 0.05 * a.FontSize) && a.Color == b.Color;

    /// <summary>The gap between the stack's last line and <paramref name="line"/> when the line carries the stack on; else null.</summary>
    private static double? Joins(PStack s, PLine line)
    {
        var last = s.Lines[^1];
        var size = last.Size;
        if (!SameLook(last.Lead, line.Lead)) return null;
        var step = line.Baseline - last.Baseline;
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
        if (blocked is null && runs.Any(r => !SameLook(runs[0], r) || r.Bold != runs[0].Bold || r.Italic != runs[0].Italic))
            blocked = "it mixes fonts, sizes or colors, and this version rewrites a paragraph in one font only";
        if (blocked is null && runs.Any(r => r.Info is null)) blocked = "part of it can't be read for editing";

        var text = new StringBuilder();
        foreach (var l in lines)
        {
            var t = l.Text.Trim();
            if (text.Length > 0)
            {
                var hyphen = text.Length >= 2 && text[^1] == '-' && char.IsLetter(text[^2]) && t.Length > 0 && char.IsLower(t[0]);
                if (!hyphen) text.Append(' ');
            }
            text.Append(t);
        }
        var box = lines.Select(l => l.Box).Aggregate((a, b) => a.Union(b));
        var step = n > 1 ? (lines[^1].Baseline - first.Baseline) / (n - 1) : 1.2 * size;

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
            Left = left,
            Right = right,
            Center = center,
            Baseline = first.Baseline,
            FirstBottom = first.Box.Bottom,
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
    /// paragraph's alignment (a justified paragraph's last line, and each line before a break, start left), its line step.
    /// </summary>
    internal static ParagraphLayout LayOut(TextParagraph p, IReadOnlyList<TextRun> runs, string text)
    {
        var anchor = runs.MinBy(r => r.Id)!;
        var font = anchor.Font!;
        var m = anchor with { };
        m.WordSpacing = 0; // the lines are written with Tw 0 (justification goes into adjustments)
        var all = font.Encode(text.Replace('\n', ' '));
        if (all.Missing.Count > 0) return new ParagraphLayout([], new ParagraphCheck(p.Box, p.Lines.Count, all.Missing, null), [], "");

        double W(List<Part> parts) => parts.Count == 0 ? 0 : m.Width(parts) * m.Scale;
        var space = Parts(m, font.Encode(" ").Codes);
        var wrap = p.Lines.Count > 1;
        var lines = new List<(List<Part> Parts, int Spaces, bool Last)>();
        foreach (var segment in text.Split('\n'))
        {
            var cur = new List<Part>();
            var spaces = 0;
            foreach (var word in segment.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                var parts = Parts(m, font.Encode(word).Codes);
                if (cur.Count == 0)
                {
                    cur.AddRange(parts);
                    continue;
                }
                var avail = p.Right - p.Left - (lines.Count == 0 ? p.FirstIndent : 0);
                List<Part> joined = [.. cur, .. space, .. parts];
                if (!wrap || W(joined) <= avail + 0.01)
                {
                    cur = joined;
                    spaces++;
                    continue;
                }
                lines.Add((cur, spaces, false));
                cur = [.. parts];
                spaces = 0;
            }
            lines.Add((cur, spaces, true));
        }
        if (lines.Count == 1 && lines[0].Parts.Count == 0) lines.Clear(); // no text: the paragraph goes

        var placed = new List<(PointD, List<Part>)>();
        var maxRight = p.Box.Right;
        var minLeft = p.Box.X;
        for (var i = 0; i < lines.Count; i++)
        {
            var (parts, spaces, last) = lines[i];
            var w = W(parts);
            var x0 = p.Left + (i == 0 ? p.FirstIndent : 0);
            var x = p.Align switch
            {
                ParagraphAlign.Right => p.Right - w,
                ParagraphAlign.Center => p.Center - w / 2,
                _ => x0,
            };
            if (p.Align == ParagraphAlign.Justified && !last && spaces > 0 && p.Right - x0 - w > 0.01)
            {
                // The room left over goes into the word spaces, as adjustments after each space.
                var extra = -(p.Right - x0 - w) / spaces / m.Scale * 1000 / (m.Size * m.HScale);
                var spread = new List<Part>(parts.Count + spaces);
                for (var k = 0; k < parts.Count; k++)
                {
                    spread.Add(parts[k]);
                    if (IsSpaceAt(parts, k, space)) spread.Add(new Part(null, extra));
                }
                parts = spread;
                w = W(parts);
            }
            placed.Add((new PointD(x, p.Baseline + i * p.LineStep), parts));
            maxRight = Math.Max(maxRight, x + w);
            minLeft = Math.Min(minLeft, x);
        }
        var bottom = p.FirstBottom + Math.Max(0, placed.Count - 1) * p.LineStep;
        var box = RectD.FromEdges(minLeft, p.Box.Y, maxRight, Math.Max(bottom, p.Box.Y + 1));
        RectD? overlaps = p.Below is { } b && box.Bottom > b.Y + 0.5 && b.Right > box.X && b.X < box.Right ? b : null;
        var check = new ParagraphCheck(box, placed.Count, [], overlaps);
        return new ParagraphLayout(placed, check, all.Codes, text.Replace('\n', ' '));
    }

    /// <summary>Whether a space ends at part <paramref name="k"/> (the space's parts as <see cref="Parts"/> wrote them).</summary>
    private static bool IsSpaceAt(List<Part> parts, int k, List<Part> space)
    {
        if (space.Count == 0 || k + 1 < space.Count) return false;
        for (var s = 0; s < space.Count; s++)
            if (parts[k - space.Count + 1 + s] != space[s]) return false;
        return true;
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
    public static byte[] ReplaceParagraph(byte[] data, string? password, TextParagraph paragraph, string text, bool allowOverlap = false)
    {
        if (paragraph.Blocked is { } why0) throw new ContentEditException($"This paragraph can't be edited: {why0}.");
        text = ParagraphText(text);
        if (text == paragraph.Text) return data;
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
        var anchor = now.MinBy(r => r.Id)!;
        var font = anchor.Font!;
        var layout = LayOut(paragraph, now, text);
        if (layout.Check.Missing.Count > 0) throw MissingGlyphs(font, layout.Check.Missing);
        if (layout.Check.Overlaps is { } o && !allowOverlap)
            throw new ContentEditException(
                $"The new text takes {layout.Check.LineCount} lines and would run into what follows below it. Shorten it, or confirm to write it anyway.")
            { Overlaps = o };
        font.Prepare(doc, layout.Codes, layout.Encoded);

        var edits = new List<(int Start, int End, string Text)>();
        foreach (var run in now)
        {
            var op = ops[run.Id];
            edits.Add((op.Start, op.End, run == anchor ? WriteParagraph(page, op, run, font, layout) : Removed(op, run)));
        }
        WriteContent(doc, page, streams, ops, edits);
        SignedEdits.NoteRemoval(); // the old text stays in a signed file's earlier revision
        return PdfObj.Save(doc);
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
    private static string WriteParagraph(PdfPage page, COp op, TextRun run, TextFont font, ParagraphLayout layout)
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
            sb.Append(lineTm.Write()).Append(" Tm ").Append(ShowArray(info.Hex, font, parts)).Append(" TJ ");
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

    /// <summary>A TJ array of codes and adjustments.</summary>
    private static string ShowArray(bool hex, TextFont font, List<Part> parts)
    {
        var tokens = new List<string>();
        var codes = new List<int>();
        void Flush()
        {
            if (codes.Count == 0) return;
            var bytes = font.ToBytes(codes);
            tokens.Add(hex ? ContentLexer.HexString(bytes) : ContentLexer.Literal(bytes));
            codes.Clear();
        }
        foreach (var (c, n) in parts)
        {
            if (c is { } code) codes.Add(code);
            else if (Math.Abs(n) > 1e-9)
            {
                Flush();
                tokens.Add(ContentLexer.Number(n));
            }
        }
        Flush();
        return "[" + string.Join(" ", tokens) + "]";
    }
}
