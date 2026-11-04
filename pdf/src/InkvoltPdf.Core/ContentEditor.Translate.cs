using System.Text;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>A paragraph of a page as a translated copy sees it, and the table cell it stays in (null: not in a table).</summary>
internal sealed record TranslationSlot(TextParagraph Paragraph, RectD? Cell);

/// <summary>What was written for one paragraph of a page: its place among the page's slots, how far it shrank, whether it fits.</summary>
internal sealed record TranslationWritten(int Slot, double Fit, bool Fits, IReadOnlyList<string> Dropped);

/// <summary>A paragraph that wasn't written, and why (as the end of a sentence: "it is …").</summary>
internal sealed record TranslationRefused(int Slot, string Why);

/// <summary>
/// The paragraph editor's reflow for a translated copy (roadmap 3.1): a whole page's paragraphs are found once and
/// rewritten together, in one pass over a document kept open, so a long report isn't reopened for each paragraph. Text
/// goes in its paragraph's box, wrapped wherever the language allows, and shrinks to fit; drawn in the page's own font
/// when that has every character, else in one installed font (a subset rarely holds a translation's letters).
/// </summary>
public static partial class ContentEditor
{
    /// <summary>The most pieces of text a page may have for its paragraphs to be worked out: more is a map or a crafted page, left as it is and reported.</summary>
    internal const int MaxRunsToTranslate = 20_000;

    /// <summary>The smallest text a paragraph shrinks to: half its size, and not under 5 points unless it was already.</summary>
    internal static double SmallestFit(double size) => !(size > 5) ? 1 : Math.Clamp(5 / size, 0.5, 1);

    private const double FitStep = 0.05;

    /// <summary>More text than this can't fit on a page at any size allowed: not laid out.</summary>
    private const int MaxTextToLayOut = 60_000;

    // ---- Finding the paragraphs ----

    /// <summary>A page's text runs and pictures, for <see cref="TranslationSlots"/>.</summary>
    /// <exception cref="ContentEditException">Its forms draw each other beyond any sensible amount: not all of it was read.</exception>
    internal static PageContent ReadRaw(PdfPage page, int pageIndex, CancellationToken cancel)
    {
        var walk = Walk(page, pageIndex, Parse(page, cancel), cancel);
        return walk.CutShort ? throw new ContentEditException(PdfStrings.Edit_DrawingsTooDeep) : walk.Content;
    }

    /// <summary>
    /// A page's paragraphs for translating, in reading order of their first line: each table cell's text apart from its
    /// neighbors', raised marks taken into the line they sit on, a bullet in front of a line left where it is.
    /// </summary>
    internal static List<TranslationSlot> TranslationSlots(PageContent content, IReadOnlyList<RectD> cells, CancellationToken cancel)
    {
        var groups = new Dictionary<int, List<TextRun>>();
        foreach (var r in content.Runs)
        {
            if (Math.Abs(r.Angle) >= 0.5 || r.Text.Trim().Length == 0 || r.FontSize <= 0.5 || r.Box.Width <= 0 || r.Blocked == HiddenLayerBlocked) continue;
            if (!double.IsFinite(r.FontSize) || !double.IsFinite(r.Box.X + r.Box.Y + r.Box.Width + r.Box.Height)) continue; // a crafted matrix
            var cell = -1;
            for (var i = 0; i < cells.Count; i++)
                if (cells[i].Contains(r.Box.CenterX, r.Box.CenterY))
                {
                    cell = i;
                    break;
                }
            if (!groups.TryGetValue(cell, out var list)) groups[cell] = list = [];
            list.Add(r);
        }
        // A paragraph looks through the page's runs for spaces drawn on their own: only those, or a crowded page takes its count squared.
        var spacesOnly = new PageContent([.. content.Runs.Where(r => r.Text.Trim().Length == 0)], []);
        var slots = new List<TranslationSlot>();
        foreach (var (cell, runs) in groups)
        {
            cancel.ThrowIfCancellationRequested();
            var lines = WithoutMarkers(WithMarksInLine(SplitAtColumns(LinesOf(runs))));
            foreach (var line in lines) line.Main = line.Runs.MaxBy(r => r.Text.Trim().Length);
            foreach (var stack in Stacks(lines))
            {
                cancel.ThrowIfCancellationRequested();
                foreach (var part in SplitShort(stack, translating: true))
                    slots.Add(new TranslationSlot(Paragraph(spacesOnly, part, translating: true), cell >= 0 ? cells[cell] : null));
            }
        }
        // The same order however the page's runs were grouped.
        return [.. slots.OrderBy(s => s.Paragraph.Box.Y).ThenBy(s => s.Paragraph.Box.X).ThenBy(s => s.Paragraph.Runs.Min(r => r.Id))];
    }

    /// <summary>
    /// A line the editor keeps whole comes apart where it is really two things: at a gap wider than word spacing goes (a
    /// label and what it labels, columns no rules mark), and where the size changes (a form's big title beside its small
    /// print), or one size would be forced on both. A small mark (a footnote number) stays on its line.
    /// </summary>
    private static List<PLine> SplitAtColumns(List<PLine> lines)
    {
        var result = new List<PLine>(lines.Count);
        foreach (var l in lines)
        {
            var cur = new PLine(l.Runs[0]);
            result.Add(cur);
            for (var i = 1; i < l.Runs.Count; i++)
            {
                var (prev, r) = (l.Runs[i - 1], l.Runs[i]);
                var bigger = Math.Max(prev.FontSize, r.FontSize);
                var smaller = r.FontSize < prev.FontSize ? r : prev;
                var gap = r.Box.X - cur.Box.Right;
                // Sizes touching are one word (small capitals: a big D, then "IGITAL"), or go on after a subscript.
                var sizes = bigger - smaller.FontSize > 0.15 * bigger && smaller.Text.Trim().Length > 4 && gap > 0.4 * bigger;
                // Figures after a gap are a column of their own, and stay where they are: nothing to translate, and a model would run them into the label.
                var figures = gap > 0.6 * bigger && (!r.Text.Any(char.IsLetter) || !prev.Text.Any(char.IsLetter));
                if (gap > 1.5 * bigger || sizes || figures)
                {
                    cur = new PLine(r);
                    result.Add(cur);
                }
                else cur.Add(r);
            }
        }
        return result;
    }

    /// <summary>A short "line" that sits on another (a raised footnote mark, a symbol in another font) goes into that line, in its place from left to right.</summary>
    private static List<PLine> WithMarksInLine(List<PLine> lines)
    {
        var byBaseline = lines.OrderBy(l => l.Baseline).ToList();
        var result = new HashSet<PLine>(lines);
        var joined = new Dictionary<PLine, List<PLine>>();
        for (var i = 0; i < byBaseline.Count; i++)
        {
            var mark = byBaseline[i];
            if (mark.Text.Trim().Length > 4) continue;
            var reach = 1.2 * Math.Max(mark.Size, 1);
            PLine? host = null;
            void Consider(PLine m)
            {
                if (m == mark || m.Text.Trim().Length <= 4 || m.Size < mark.Size) return;
                if (mark.Box.CenterY <= m.Box.Y || mark.Box.CenterY >= m.Box.Bottom) return;
                if (mark.Box.Right <= m.Box.X || mark.Box.X >= m.Box.Right + 0.5 * m.Size) return;
                host ??= m;
            }
            for (var k = i - 1; k >= 0 && mark.Baseline - byBaseline[k].Baseline <= reach * 2; k--) Consider(byBaseline[k]);
            for (var k = i + 1; k < byBaseline.Count && byBaseline[k].Baseline - mark.Baseline <= reach * 2; k++) Consider(byBaseline[k]);
            if (host is null) continue;
            if (!joined.TryGetValue(host, out var marks)) joined[host] = marks = [];
            marks.Add(mark);
            result.Remove(mark);
        }
        foreach (var (host, marks) in joined)
        {
            var runs = host.Runs.Concat(marks.SelectMany(m => m.Runs)).OrderBy(r => r.Box.X).ToList();
            var line = new PLine(runs[0]);
            foreach (var r in runs.Skip(1)) line.Add(r);
            line.Baseline = host.Baseline;
            result.Remove(host);
            result.Add(line);
        }
        return [.. result];
    }

    /// <summary>A bullet or dash in front of a line, its own piece of text, isn't translated or moved: the line starts after it.</summary>
    private static List<PLine> WithoutMarkers(List<PLine> lines)
    {
        var result = new List<PLine>(lines.Count);
        foreach (var l in lines)
        {
            var first = l.Runs[0];
            // Or a note's number, smaller than what follows: read as the line's size, the line would fall out of its paragraph.
            var note = l.Runs.Count > 1 && first.Text.Trim().Length <= 3 && first.FontSize < 0.85 * l.Runs[1].FontSize;
            if (l.Runs.Count > 1 && (note || first.Text.Trim().Length <= 2 && !first.Text.Any(char.IsLetterOrDigit)))
            {
                var line = new PLine(l.Runs[1]);
                foreach (var r in l.Runs.Skip(2)) line.Add(r);
                result.Add(line);
            }
            else result.Add(l);
        }
        return result;
    }

    // ---- The room a paragraph has ----

    /// <summary>What a page's new text must keep clear of, and how far its upright text reaches across.</summary>
    internal sealed class PageThings
    {
        public readonly List<(RectD Box, TextRun? Run)> Boxes = [];
        public readonly double TextLeft = double.MaxValue, TextRight = double.MinValue;
        /// <summary>A page too crowded to look around each paragraph on its lines: it stays as wide as it was.</summary>
        public bool Crowded => Boxes.Count > 5_000;

        public PageThings(PageContent content, IReadOnlyList<RectD> obstacles)
        {
            foreach (var r in content.Runs)
            {
                if (r.Text.Trim().Length == 0 || Math.Abs(r.Angle) >= 0.5) continue; // a margin's turned stamp isn't where the text column ends
                TextLeft = Math.Min(TextLeft, r.Box.X);
                TextRight = Math.Max(TextRight, r.Box.Right);
                Boxes.Add((r.Box, r));
            }
            foreach (var i in content.Images) Boxes.Add((i.Box, null));
            foreach (var o in obstacles) Boxes.Add((o, null));
            Boxes.Sort((a, b) => a.Box.Y.CompareTo(b.Box.Y));
            if (TextLeft > TextRight) (TextLeft, TextRight) = (0, 0);
        }

        /// <summary>The first box that starts at or below <paramref name="y"/>.</summary>
        public int FirstBelow(double y)
        {
            int lo = 0, hi = Boxes.Count;
            while (lo < hi)
            {
                var mid = (lo + hi) / 2;
                if (Boxes[mid].Box.Y < y) lo = mid + 1;
                else hi = mid;
            }
            return lo;
        }
    }

    /// <summary>
    /// A paragraph as it will be written: the edges its lines stay between, its alignment as the page shows it (a single
    /// line can't tell, so its place on the page or in its cell does), and how far down it may go.
    /// </summary>
    /// <param name="fills">Rectangles the page fills, with their place in its content: one filled after the paragraph is drawn would paint over text that grows into it.</param>
    internal static (TextParagraph Paragraph, double Bottom) Room(TranslationSlot slot, PageThings page, IReadOnlyList<RectD> obstacles, double pageWidth, double pageHeight,
        IReadOnlyList<(RectD Box, int Id)>? fills = null)
    {
        var p = slot.Paragraph;
        var framed = p with { };
        var mine = new HashSet<TextRun>(p.Runs, ReferenceEqualityComparer.Instance);

        // A panel the text sits in (a shaded box, a callout) holds it unless it is about the whole page.
        var panel = obstacles.Where(o => o.Width * o.Height < 0.8 * pageWidth * pageHeight && o.Contains(p.Box.CenterX, p.Box.CenterY) && o.Contains(p.Box.X + 0.5, p.Box.Y + 0.5) && o.Contains(p.Box.Right - 0.5, p.Box.Bottom - 0.5))
            .OrderBy(o => o.Width * o.Height).Select(o => (RectD?)o).FirstOrDefault();
        var holder = slot.Cell ?? panel;

        // Light text sits on something dark that isn't known here (a filled band): past its box it would be white on white.
        var color = p.Lead.Color;
        var light = slot.Cell is null && 0.3 * (color >> 16 & 0xFF) + 0.59 * (color >> 8 & 0xFF) + 0.11 * (color & 0xFF) > 0.85 * 255;

        if ((p.Lines.Count == 1 || slot.Cell is not null) && !page.Crowded && !light)
        {
            // Across: to the next thing on its line, inside what holds it. Its text column on the page is what the page's other text reaches.
            var reachLeft = holder?.X ?? Math.Min(p.Left, page.TextLeft);
            // To the right margin: as far as the page's text goes, or the left margin mirrored when no text on it is that long.
            var reachRight = holder?.Right ?? Math.Max(p.Right, Math.Min(pageWidth - 18, Math.Max(page.TextRight, pageWidth - page.TextLeft)));
            foreach (var (b, run) in page.Boxes)
            {
                if (b.Y >= p.Box.Bottom) break;
                if (b.Bottom <= p.Box.Y) continue; // not on its lines
                if (run is not null && mine.Contains(run)) continue;
                if (b.Width > 0.8 * (reachRight - reachLeft) && b.X < p.Box.X && b.Right > p.Box.Right) continue; // behind it
                // Text beside it may grow toward it too: each gets half the gap.
                if (b.X >= p.Box.Right - 1 && b.X < reachRight) reachRight = b.X - Math.Max(0.5 * p.FontSize, run is null ? 0 : (b.X - p.Box.Right) / 2);
                if (b.Right <= p.Box.X + 1 && b.Right > reachLeft) reachLeft = b.Right + Math.Max(0.5 * p.FontSize, run is null ? 0 : (p.Box.X - b.Right) / 2);
            }
            reachRight = Math.Max(reachRight, p.Right);
            reachLeft = Math.Min(reachLeft, p.Left);
            if (holder is not null)
            {
                reachLeft = Math.Min(p.Left, reachLeft + 1.5);
                reachRight = Math.Max(p.Right, reachRight - 1.5);
            }
            var tol = Math.Max(2, 0.2 * p.FontSize);
            var off = Math.Max(20, 2 * p.FontSize);
            var align = p.Align;
            if (p.Lines.Count == 1)
            {
                // What it could be centered on or end at: what holds it; else the page's text or the page itself.
                var (left, right) = holder is { } h ? (h.X, h.Right) : (page.TextLeft, page.TextRight);
                var centered = Math.Abs(p.Box.CenterX - (left + right) / 2) <= tol || (holder is null && Math.Abs(p.Box.CenterX - pageWidth / 2) <= tol);
                var ended = Math.Abs(p.Box.Right - right) <= tol || (holder is null && Math.Abs(p.Box.Right - (pageWidth - page.TextLeft)) <= tol);
                if (centered && p.Box.X - left > (holder is null ? off : 2)) align = ParagraphAlign.Center;
                else if (ended && p.Box.X - left > off) align = ParagraphAlign.Right;
            }
            framed = p with { Align = align };
            switch (align)
            {
                case ParagraphAlign.Center:
                    var half = Math.Min(p.Box.CenterX - reachLeft, reachRight - p.Box.CenterX);
                    framed.Left = p.Box.CenterX - half;
                    framed.Right = p.Box.CenterX + half;
                    framed.Center = p.Box.CenterX;
                    break;
                case ParagraphAlign.Right:
                    framed.Left = reachLeft;
                    framed.Right = p.Right;
                    break;
                default:
                    framed.Left = p.Left;
                    framed.Right = reachRight;
                    break;
            }
        }

        // Down: to the next thing below it across its width, and no lower than what holds it or the page's foot.
        var bottom = light ? p.Box.Bottom : slot.Cell?.Bottom ?? panel?.Bottom ?? Math.Max(p.Box.Bottom, pageHeight - 36);
        for (var i = page.FirstBelow(p.Box.Bottom - 1); i < page.Boxes.Count; i++)
        {
            var (b, run) = page.Boxes[i];
            if (b.Y >= bottom) break; // sorted: nothing later comes nearer
            if (b.Right <= framed.Left + 1 || b.X >= framed.Right - 1 || (run is not null && mine.Contains(run))) continue;
            // Some of the gap the page left stays, so a paragraph doesn't read as part of the next.
            bottom = b.Y - Math.Max(0.1 * p.FontSize, Math.Min(b.Y - p.Box.Bottom, 0.35 * p.FontSize));
            break;
        }
        // Filled after this paragraph is written: a band under some later line reaches across, even where no text is.
        if (fills is { Count: > 0 } && p.Runs.All(r => r.Info?.Form is null))
        {
            var last = p.Runs.Max(DrawOrder);
            foreach (var (box, id) in fills)
                if (id > last && box.Y >= p.Box.Bottom - 1 && box.Y < bottom && box.Right > framed.Left + 1 && box.X < framed.Right - 1) bottom = box.Y;
        }
        bottom = Math.Max(bottom, p.Box.Bottom);
        // What the page clips to hides whatever goes past it: new text stays inside, or is flagged. Each line is written
        // where one of the old lines was drawn, so what counts is what they clip to together.
        var drawnAt = LineRuns(p, PlainRun(p.Runs));
        // Lines below the old ones are written with the last: whatever clips that clips them, whatever the others do.
        if (drawnAt[^1].Info?.Clip is { } lowest) bottom = Math.Min(bottom, Math.Max(lowest.Bottom, p.Box.Bottom));
        if (drawnAt.All(r => r.Info?.Clip is not null) && drawnAt.Select(r => r.Info!.Clip!.Value).Aggregate((a, b) => a.Union(b)) is var clip)
        {
            bottom = Math.Min(bottom, Math.Max(clip.Bottom, p.Box.Bottom)); // a font's descent may reach past a tight clip: its own text was shown there
            framed.Right = Math.Max(Math.Min(framed.Right, clip.Right), Math.Min(p.Right, framed.Right));
            framed.Left = Math.Min(Math.Max(framed.Left, clip.X), Math.Max(p.Left, framed.Left));
        }
        return (framed, bottom);
    }

    /// <summary>
    /// The new text laid out at the largest size that fits its room (steps of 5%); at the smallest allowed when none does.
    /// Characters no font here has are left out and named.
    /// </summary>
    internal static (ParagraphLayout Layout, double Fit, bool Fits, IReadOnlyList<string> Dropped) FitText(TextParagraph framed, double bottom, string text)
    {
        var dropped = new List<string>();
        var smallest = SmallestFit(framed.Lead.FontSize); // of the size it is written in: its first run may be a mark or a big initial
        ParagraphLayout? best = null;
        var fit = 1.0;
        for (var tries = 0; ; tries++, fit = Math.Max(smallest, fit - FitStep))
        {
            if (tries > 2 / FitStep) fit = smallest; // whatever a crafted page's numbers make of the steps below
            best = LayOut(framed, framed.Runs, text, [], fit);
            if (best.Check.Missing.Count > 0)
            {
                foreach (var m in best.Check.Missing)
                {
                    dropped.Add(m);
                    text = text.Replace(m, "", StringComparison.Ordinal);
                }
                text = string.Join(' ', text.Split(' ', StringSplitOptions.RemoveEmptyEntries));
                if (text.Length == 0) return (best, 1, false, dropped);
                best = LayOut(framed, framed.Runs, text, [], fit);
                if (best.Check.Missing.Count > 0) return (best, 1, false, dropped);
            }
            var box = best.Check.Box;
            if (box.Bottom <= bottom + 0.5 && box.Right <= Math.Max(framed.Right, framed.Box.Right) + 1 && box.X >= Math.Min(framed.Left, framed.Box.X) - 1) return (best, fit, true, dropped);
            if (fit <= smallest || tries > 2 / FitStep) return (best, fit, false, dropped);
            // Far too tall: text takes room with the square of its size, so jump near where it will fit.
            var ratio = (bottom - framed.Box.Y) / Math.Max(1, box.Bottom - framed.Box.Y);
            if (double.IsFinite(ratio)) fit = Math.Min(fit, Math.Round(Math.Sqrt(Math.Max(ratio, 0.01)) * fit / FitStep) * FitStep + 2 * FitStep);
        }
    }

    // ---- Right to left ----

    /// <summary>Whether most of the text's letters read right to left (the paragraph then does).</summary>
    private static bool MostlyRightToLeft(string text)
    {
        int rtl = 0, ltr = 0;
        foreach (var cp in TrueTypeFont.CodePoints(text))
            switch (Bidi.Classify(cp))
            {
                case Bidi.Cls.R or Bidi.Cls.AL: rtl++; break;
                case Bidi.Cls.L: ltr++; break;
            }
        return rtl > ltr;
    }

    /// <summary>
    /// Right-to-left text in an installed font: words go on a line as long as it fits, each line shaped whole so its words
    /// come out in reading order, and it sits against the box's right edge (or its center, if centered).
    /// </summary>
    private static ParagraphLayout LayOutRightToLeft(TextParagraph p, TextRun m, string text, double shrink)
    {
        var cps = TrueTypeFont.CodePoints(text).Where(c => c > 32).Distinct().ToList();
        var ranked = StandInFonts.RankFor(m.Font!).FirstOrDefault(f => cps.All(f.Font.Has));
        var primary = ranked?.Font;
        var missing = TrueTypeFont.CodePoints(text)
            .Where(c => c > 32 && !(primary?.Has(c) == true || SystemFonts.For(c, primary) is { } fb && fb.Has(c)))
            .Distinct().Select(char.ConvertFromUtf32).ToList();
        if (missing.Count > 0) return new ParagraphLayout([], new ParagraphCheck(p.Box, p.Lines.Count, missing, null), []);

        double W(string line) => TextShaper.Measure(line, primary) * m.Size * m.HScale * m.Scale;
        // A word with no spaces can be the whole answer: longer than any line, it isn't measured whole for every line it breaks into.
        const int longest = 1024;
        var lines = new List<string>();
        var cur = "";
        var avail = p.Right - p.Left;
        foreach (var word in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var joined = cur.Length == 0 ? word : cur + " " + word;
            if (W(joined) <= avail + 0.01)
            {
                cur = joined;
                continue;
            }
            if (cur.Length > 0) lines.Add(cur);
            cur = word;
            while (cur.Length > 1 && (cur.Length > longest || W(cur) > avail + 0.01))
            {
                // A word wider than the line is broken: as much of it as fits.
                var els = System.Globalization.StringInfo.ParseCombiningCharacters(cur.Length > longest ? cur[..longest] : cur);
                var n = els.Length - 1;
                while (n > 1 && W(cur[..els[n]]) > avail + 0.01) n = n * 3 / 4;
                if (n < 1 || els[n] == 0) break;
                lines.Add(cur[..els[n]]);
                cur = cur[els[n]..];
            }
        }
        if (cur.Length > 0) lines.Add(cur);

        var placed = new List<(PointD, List<Part>)>();
        var names = new List<string>();
        var baseline = p.Box.Y + p.Ascent * shrink;
        var (minLeft, maxRight) = (p.Box.X, p.Box.Right);
        foreach (var line in lines)
        {
            var shaped = TextShaper.Shape(line, primary);
            foreach (var g in shaped.Glyphs)
            {
                var known = ReferenceEquals(g.Font, primary) ? ranked!.Name : StandInFonts.Pretty(g.Font.Family);
                if (!names.Contains(known)) names.Add(known);
            }
            var w = shaped.Width * m.Size * m.HScale * m.Scale;
            var x = p.Align == ParagraphAlign.Center ? p.Center - w / 2 : p.Right - w;
            placed.Add((new PointD(x, baseline), [new Part(null, 0, shaped)]));
            minLeft = Math.Min(minLeft, x);
            maxRight = Math.Max(maxRight, x + w);
            baseline += p.LineStep * shrink;
        }
        var bottom = baseline - p.LineStep * shrink + p.Descent * shrink;
        return new ParagraphLayout(placed, new ParagraphCheck(RectD.FromEdges(minLeft, p.Box.Y, maxRight, Math.Max(bottom, p.Box.Y + 1)), placed.Count, [], null) { StandIns = names }, []);
    }

    // ---- Wrapping ----

    /// <summary>
    /// Words on lines as wide as the paragraph's box: between words; in Chinese and Japanese between any two characters
    /// (not before closing punctuation or after opening punctuation); and a word wider than the whole line between its
    /// characters, so nothing runs off the box's edge.
    /// </summary>
    private static List<(List<Part> Parts, List<int> Spaces, bool Last)> FitLines(TextParagraph p, MixedText enc, string text, Func<List<Part>, double> width)
    {
        var lines = new List<(List<Part> Parts, List<int> Spaces, bool Last)>();
        var cur = new List<Part>();
        var ends = new List<int>();
        double Avail() => p.Right - p.Left - (lines.Count == 0 ? p.FirstIndent : 0);
        void Break()
        {
            lines.Add((cur, ends, false));
            cur = [];
            ends = [];
        }
        foreach (var (start, end, spaced) in FitTokens(text))
        {
            var parts = enc.Encode(start, end);
            var space = spaced && cur.Count > 0 ? enc.Encode(start - 1, start) : null;
            List<Part> joined = cur.Count == 0 ? parts : [.. cur, .. space ?? [], .. parts];
            if (width(joined) <= Avail() + 0.01)
            {
                if (space is not null && cur.Count > 0) ends.Add(cur.Count + space.Count - 1);
                cur = joined;
                continue;
            }
            if (cur.Count > 0) Break();
            if (width(parts) <= Avail() + 0.01)
            {
                cur = parts;
                continue;
            }
            // Too wide for a line of its own: broken between its characters.
            var chunk = start;
            var els = System.Globalization.StringInfo.ParseCombiningCharacters(text[start..end]);
            for (var e = 1; e < els.Length; e++)
            {
                var to = e + 1 < els.Length ? start + els[e + 1] : end;
                if (width(enc.Encode(chunk, to)) <= Avail() + 0.01) continue;
                cur = enc.Encode(chunk, start + els[e]);
                Break();
                chunk = start + els[e];
            }
            cur = enc.Encode(chunk, end);
        }
        lines.Add((cur, ends, true));
        if (lines.Count == 1 && lines[0].Parts.Count == 0) lines.Clear();
        return lines;
    }

    private const string NoBreakBefore = "、。，．・：；？！）〕］｝〉》」』】…ーゝゞ々ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ.,;:!?)]}%";
    private const string NoBreakAfter = "（〔［｛〈《「『【([{";

    /// <summary>Where a line may break: stretches of text, whether a space comes before each. Runs of spaces count as one.</summary>
    internal static IEnumerable<(int Start, int End, bool Spaced)> FitTokens(string text)
    {
        var spaced = false;
        for (var i = 0; i < text.Length;)
        {
            if (char.IsWhiteSpace(text[i]))
            {
                spaced = true;
                i++;
                continue;
            }
            var start = i;
            var ideographs = IsIdeograph(text, i);
            i += char.IsHighSurrogate(text[i]) && i + 1 < text.Length ? 2 : 1;
            while (i < text.Length && !char.IsWhiteSpace(text[i]))
            {
                // A break between two characters when either is an ideograph, unless punctuation holds them together.
                var next = IsIdeograph(text, i);
                if ((ideographs || next) && !NoBreakBefore.Contains(text[i]) && !NoBreakAfter.Contains(text[i - 1])) break;
                ideographs = next;
                i += char.IsHighSurrogate(text[i]) && i + 1 < text.Length ? 2 : 1;
            }
            yield return (start, i, spaced);
            spaced = false;
        }
    }

    private static bool IsIdeograph(string text, int i)
    {
        var cp = char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]) ? char.ConvertToUtf32(text[i], text[i + 1]) : text[i];
        return cp is >= 0x2E80 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF or >= 0x20000 and <= 0x3FFFF and not (>= 0x3000 and <= 0x303F);
    }

    // ---- Where each new line is drawn ----

    /// <summary>A run's place in the order its content draws things.</summary>
    private static int DrawOrder(TextRun run) => run.Info?.Form?.Index ?? run.Id;

    /// <summary>
    /// For each of a paragraph's old lines, the run a new line there is written at: its last one in the paragraph's color
    /// (what the line draws last has nothing of the line painted over it); a line with none takes the one above's.
    /// </summary>
    private static TextRun[] LineRuns(TextParagraph p, TextRun plain)
    {
        // New text takes the color of the run it is written at: the color most of the paragraph is in, not a link's.
        var color = p.Runs.Where(r => r.Info is not null).GroupBy(r => r.Color).MaxBy(g => g.Sum(r => r.Text.Trim().Length))?.Key ?? plain.Color;
        var chosen = new TextRun?[p.Lines.Count];
        foreach (var run in p.Runs)
        {
            var at = 0;
            for (var k = 1; k < p.Lines.Count; k++)
                if (Math.Abs(run.Box.CenterY - p.Lines[k].CenterY) < Math.Abs(run.Box.CenterY - p.Lines[at].CenterY)) at = k;
            if (run.Color == color && run.Info is not null && (chosen[at] is not { } had || DrawOrder(run) > DrawOrder(had))) chosen[at] = run;
        }
        var result = new TextRun[chosen.Length];
        var fallback = chosen.FirstOrDefault(r => r is not null) ?? Anchor(p.Runs);
        for (var k = 0; k < chosen.Length; k++) result[k] = fallback = chosen[k] ?? fallback;
        return result;
    }

    /// <summary>
    /// Which run each new line is written at. A page may paint under each line as it comes (a white band for every line, as
    /// Word and Acrobat exports do) or clip to it, so a new line goes where the lowest old line it reaches was drawn: with
    /// everything painted for it already down, and nothing later over it. Lines below the old ones go with the last.
    /// </summary>
    private static Dictionary<TextRun, List<(PointD Origin, List<Part> Parts)>> LinesToRuns(TextParagraph p, TextRun[] oldLines, ParagraphLayout layout, double fit)
    {
        var result = new Dictionary<TextRun, List<(PointD, List<Part>)>>(ReferenceEqualityComparer.Instance);
        foreach (var line in layout.Lines)
        {
            var bottom = line.Origin.Y + p.Descent * fit;
            var at = 0;
            for (var k = 1; k < oldLines.Length; k++)
                if (p.Lines[k].Y < bottom - 1) at = k;
            var run = oldLines[at];
            // Clipped to a rectangle this line isn't in: to one it is in.
            if (run.Info?.Clip is { } clip && (line.Origin.Y <= clip.Y || line.Origin.Y >= clip.Bottom)
                && oldLines.FirstOrDefault(r => r.Info?.Clip is { } c && line.Origin.Y > c.Y && line.Origin.Y < c.Bottom) is { } inside) run = inside;
            if (!result.TryGetValue(run, out var lines)) result[run] = lines = [];
            lines.Add(line);
        }
        return result;
    }

    /// <summary>
    /// New lines written at a run that may not be in the paragraph's own state: its spacing and horizontal scale are set for
    /// them, and its size made up for when the run's text matrix scales differently, so they come out as they were laid out.
    /// </summary>
    private static string WriteLinesAt(PdfPage page, COp op, TextRun run, TextRun plain, ParagraphLayout layout, CidFontWriter writer)
    {
        var face = plain;
        if (run.Scale > 0 && plain.Scale > 0 && Math.Abs(run.Scale / plain.Scale - 1) > 1e-6) face = plain with { Size = plain.Size * plain.Scale / run.Scale };
        var before = new StringBuilder();
        var after = new StringBuilder();
        if (op.Name != "\"" && Math.Abs(run.CharSpacing - plain.CharSpacing) > 1e-9)
        {
            before.Append(ContentLexer.Number(plain.CharSpacing)).Append(" Tc ");
            after.Append(' ').Append(ContentLexer.Number(run.CharSpacing)).Append(" Tc");
        }
        if (Math.Abs(run.HScale - plain.HScale) > 1e-9)
        {
            before.Append(ContentLexer.Number(plain.HScale * 100)).Append(" Tz ");
            after.Append(' ').Append(ContentLexer.Number(run.HScale * 100)).Append(" Tz");
        }
        return before + WriteParagraph(page, op, run, face, layout, writer) + after;
    }

    // ---- Writing a page ----

    /// <summary>
    /// What a run over a whole document shares: one font writer (a face is embedded once, however many pages use it),
    /// which dictionaries need its fonts, and which form XObjects more than one page can reach.
    /// </summary>
    internal sealed class TranslationWriter
    {
        private readonly PdfDocument _doc;
        private readonly List<PdfDictionary> _owners = [];
        private readonly HashSet<PdfDictionary> _seen = new(ReferenceEqualityComparer.Instance);
        private HashSet<PdfDictionary>? _shared;

        public CidFontWriter Fonts { get; }

        /// <summary>The installed fonts text was drawn in, as people know them.</summary>
        public List<string> FontNames { get; } = [];

        /// <param name="unique">Makes its fonts' resource names different from any earlier run's (a translated copy translated again).</param>
        public TranslationWriter(PdfDocument doc, string unique)
        {
            _doc = doc;
            Fonts = new CidFontWriter($"/{StandInKey}T{unique}_");
        }

        public void NeedsFonts(PdfDictionary owner)
        {
            if (_seen.Add(owner)) _owners.Add(owner);
        }

        /// <summary>The installed fonts drawn from go into the document and the resources of everything that uses them.</summary>
        public void Finish()
        {
            if (Fonts.IsEmpty) return;
            var fonts = Fonts.BuildFonts(_doc);
            foreach (var owner in _owners) AddFonts(_doc, owner, fonts);
        }

        /// <summary>Forms reachable from more than one page's resources, found once: asking per form and per page would take page count squared.</summary>
        public bool Shared(FormPlace place)
        {
            if (_shared is null)
            {
                _shared = new(ReferenceEqualityComparer.Instance);
                var once = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
                for (var i = 0; i < _doc.PageCount; i++)
                {
                    var onPage = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
                    void Visit(PdfDictionary? xo, int depth)
                    {
                        if (xo is null || depth > MaxDepth) return;
                        foreach (var item in xo.Elements.Values)
                        {
                            if (PdfObj.Dict(item) is not { } form || PdfObj.NameOf(form, "/Subtype") != "/Form" || !onPage.Add(form)) continue;
                            Visit(PdfObj.Dict(PdfObj.Dict(form.Elements["/Resources"])?.Elements["/XObject"]), depth + 1);
                        }
                    }
                    Visit(PdfObj.Dict(PdfObj.Dict(_doc.Pages[i].Elements["/Resources"])?.Elements["/XObject"]), 0);
                    foreach (var f in onPage)
                        if (!once.Add(f)) _shared.Add(f);
                }
            }
            return place.Chain().Any(_shared.Contains);
        }
    }

    /// <summary>
    /// Writes one page's translated paragraphs. <paramref name="textOf"/> gives a paragraph's new text (null: it stays as
    /// it is). Everything is worked out first and the page's content changes only at the end, so a page that fails
    /// partway stays as it was (the exception goes to the caller).
    /// </summary>
    internal static (List<TranslationSlot> Slots, List<TranslationWritten> Written, List<TranslationRefused> Refused) TranslatePage(
        TranslationWriter writer, PdfDocument doc, int pageIndex, IReadOnlyList<RectD> cells, IReadOnlyList<RectD> obstacles, Func<int, TextParagraph, string?> textOf, CancellationToken cancel)
    {
        var page = doc.Pages[pageIndex];
        var streams = Streams(page);
        var ops = ContentLexer.Parse(streams.Bytes, cancel);
        var walk = Walk(page, pageIndex, ops, cancel);
        var content = walk.Content;
        var slots = TranslationSlots(content, cells, cancel);
        var (pageWidth, pageHeight) = PdfObj.DisplaySize(page);
        var written = new List<TranslationWritten>();
        var refused = new List<TranslationRefused>();

        var pageEdits = new List<(int Start, int End, string Text)>();
        var pageTarget = new Target { Ops = ops, Bytes = streams.Bytes, Streams = streams, ResourceOwner = page, Resources = PdfObj.Dict(page.Elements["/Resources"]) };
        var forms = new Dictionary<(PdfDictionary Form, int DoId), (Target Target, List<(int, int, string)> Edits)>();
        var fonts = new List<(TextFont Font, IReadOnlyList<int> Codes, string Text)>();
        var owners = new List<PdfDictionary>();
        var taken = new HashSet<(Target, int)>();
        var things = new PageThings(content, obstacles);

        for (var i = 0; i < slots.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            var slot = slots[i];
            var p = slot.Paragraph;
            if (textOf(i, p) is not { Length: > 0 } text) continue;
            if (p.Blocked is { } blocked)
            {
                refused.Add(new TranslationRefused(i, blocked));
                continue;
            }
            if (text.Length > MaxTextToLayOut)
            {
                refused.Add(new TranslationRefused(i, PdfStrings.Translate_TooLongForBox));
                continue;
            }
            var (framed, bottom) = Room(slot, things, obstacles, pageWidth, pageHeight, walk.Fills);
            var (layout, fit, fits, dropped) = FitText(framed, bottom, text);
            if (layout.Check.Missing.Count > 0 || layout.Lines.Count == 0)
            {
                refused.Add(new TranslationRefused(i, PdfStrings.Translate_NoFontCanDraw));
                continue;
            }

            var anchor = Anchor(p.Runs);
            var plain = PlainRun(p.Runs) with { };
            var oldLines = LineRuns(p, plain);
            var newLines = LinesToRuns(p, oldLines, layout, fit);
            plain.Size *= fit;
            Target target;
            List<(int Start, int End, string Text)> edits;
            if (anchor.Info!.Form is not { } place)
            {
                target = pageTarget;
                edits = pageEdits;
            }
            else
            {
                var key = (place.Form, place.DoId);
                if (forms.TryGetValue(key, out var known))
                {
                    target = known.Target;
                    edits = known.Edits;
                }
                else
                {
                    var form = place;
                    if (walk.FormUses.GetValueOrDefault(place.Form) > 1 || writer.Shared(place))
                    {
                        if (place.Outer is not null)
                        {
                            refused.Add(new TranslationRefused(i, PdfStrings.Translate_SharedDrawing));
                            continue;
                        }
                        var copy = CopiedForm(doc, page, place, out var name);
                        var op = ops[place.DoId];
                        pageEdits.Add((op.Start, op.End, $"/{name} Do"));
                        form = place with { Form = copy };
                    }
                    PdfDictionary owner = page;
                    for (var f = form; f is not null; f = f.Outer)
                        if (PdfObj.Dict(f.Form.Elements["/Resources"]) is not null)
                        {
                            owner = f.Form;
                            break;
                        }
                    target = new Target { Ops = form.Ops, Bytes = form.Bytes, Form = form, ResourceOwner = owner, Resources = form.Resources };
                    edits = [];
                    forms[key] = (target, edits);
                }
            }

            foreach (var run in p.Runs)
            {
                var op = target.OpOf(run);
                edits.Add((op.Start, op.End, newLines.TryGetValue(run, out var lines) ? WriteLinesAt(page, op, run, plain, layout with { Lines = lines }, writer.Fonts) : Removed(op, run)));
                taken.Add((target, op.Start));
            }
            // Spaces drawn on their own go too; one on the lines of two paragraphs only once.
            foreach (var run in p.Spaces)
            {
                if (!ReferenceEquals(run.Info?.Form?.Form, anchor.Info.Form?.Form) || (anchor.Info.Form is { } a && run.Info!.Form!.DoId != a.DoId)) continue;
                var op = target.OpOf(run);
                if (taken.Add((target, op.Start))) edits.Add((op.Start, op.End, Removed(op, run)));
            }
            fonts.AddRange(layout.Fonts);
            owners.Add(target.ResourceOwner);
            foreach (var name in layout.Check.StandIns)
                if (!writer.FontNames.Contains(name)) writer.FontNames.Add(name);
            written.Add(new TranslationWritten(i, fit, fits, dropped));
        }

        if (written.Count == 0 && pageEdits.Count == 0) return (slots, written, refused);
        foreach (var (font, codes, text) in fonts) font.Prepare(doc, codes, text);
        foreach (var (target, edits) in forms.Values) WriteTarget(doc, page, target, edits);
        if (pageEdits.Count > 0) WriteTarget(doc, page, pageTarget, pageEdits);
        foreach (var owner in owners) writer.NeedsFonts(owner);
        SignedEdits.NoteRemoval();
        return (slots, written, refused);
    }

    /// <summary>A copy of a form the page draws directly, under a name of its own; the caller changes the Do.</summary>
    private static PdfDictionary CopiedForm(PdfDocument doc, PdfPage page, FormPlace place, out string name)
    {
        var copy = new PdfDictionary(doc);
        foreach (var key in place.Form.Elements.Keys)
            if (key is not ("/Filter" or "/DecodeParms" or "/Length")) copy.Elements[key] = place.Form.Elements[key];
        copy.CreateStream(place.Bytes);
        doc.Internals.AddObject(copy);
        name = AddXObject(doc, page, copy, "InkFm");
        return copy;
    }
}
