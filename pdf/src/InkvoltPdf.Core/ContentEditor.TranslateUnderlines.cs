using System.Text;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// A translated paragraph's plain underlines (roadmap 3.1): a rule the page draws under some of a line's words, no link's.
/// The words it underlines go to the model as &lt;u&gt; (<see cref="TranslationMarkup"/>); the copy takes the rule off the
/// page and draws one, in its color, at its distance below the baseline and its thickness (scaled with the text), under
/// the words of the translation the answer's markup underlines.
/// </summary>
public static partial class ContentEditor
{
    /// <summary>
    /// A rule under a line's words: its box (page as shown), its painting operator in the page's content, its color, and
    /// the runs it underlines (on that line, half of each at least over it).
    /// </summary>
    internal sealed record Underline(RectD Box, int Id, int Color, IReadOnlyList<TextRun> Runs);

    /// <summary>The most filled rectangles a page may have for its underlines to be looked for: more is a chart or a crafted page.</summary>
    private const int MaxUnderlineCandidates = 4_000;

    /// <summary>The most runs one rectangle is compared with (a crafted page's thousands of runs on one baseline).</summary>
    private const int MaxRunsUnderOne = 256;

    /// <summary>The most runs looked at on one rectangle's baseline band, and on all of a page's: past them, no more underlines are looked for.</summary>
    private const int MaxRunsScannedForOne = 2_048, MaxRunsScanned = 1_000_000;

    /// <summary>How much of a rule the words above it must cover for it to be their underline, not a table's rule or a field's line.</summary>
    private const double UnderlineCovered = 0.7;

    /// <summary>
    /// The page's plain underlines: each rectangle its own content fills in a plain color (one rectangle, one operator, so
    /// it can be taken off and drawn again) that is thin (a sixth of the text at most, or a point), at least half an em
    /// wide, its top from just above the baseline of the words over it to 0.4 em below it, inside no link (a link's
    /// underline moves with the link, <see cref="LinkUnderline"/>), and covered for <see cref="UnderlineCovered"/> of its width
    /// by upright text on that baseline. Where it sits is what tells it from a strike-out (through the words), a table's
    /// rule (wider than the text over it) and a field's line (nothing over it). Each run goes with one underline at most.
    /// </summary>
    internal static List<Underline> PlainUnderlines(PdfPage page, PageContent content, IReadOnlyList<Paint> paints, List<COp> ops)
    {
        var found = new List<Underline>();
        var candidates = paints.Where(p => p is { Rect: true, Color: not null, Box: { } b } && p.Id >= 0 && p.Id < ops.Count && ops[p.Id].Name is "f" or "F" or "f*"
                                           && double.IsFinite(b.X + b.Y + b.Width + b.Height) && b.Width > 0 && b.Height > 0).ToList();
        if (candidates.Count == 0 || candidates.Count > MaxUnderlineCandidates) return found;
        var runs = content.Runs.Where(r => Math.Abs(r.Angle) < 0.5 && r.Info is not null && r.Blocked != HiddenLayerBlocked && r.FontSize > 0.5 && double.IsFinite(r.FontSize)
                                           && double.IsFinite(r.Origin.Y + r.Box.X + r.Box.Width) && r.Text.Any(char.IsLetterOrDigit))
            .OrderBy(r => r.Origin.Y).ToList();
        if (runs.Count == 0) return found;
        var biggest = Math.Min(runs.Max(r => r.FontSize), 500);
        var links = PageLinks(page).Select(l => l.Box).ToList();
        var taken = new HashSet<TextRun>(ReferenceEqualityComparer.Instance);
        var scanned = 0;
        foreach (var paint in candidates)
        {
            if (scanned > MaxRunsScanned) break; // a crafted page's rectangles over a baseline of a hundred thousand runs
            var b = paint.Box!.Value;
            // The runs whose baseline is near enough above it, sorted by baseline: from 0.4 of the biggest text above its top to just below it.
            int lo = 0, hi = runs.Count;
            while (lo < hi)
            {
                var mid = (lo + hi) / 2;
                if (runs[mid].Origin.Y < b.Y - 0.4 * biggest) lo = mid + 1;
                else hi = mid;
            }
            var near = new List<TextRun>();
            var looked = 0;
            for (var k = lo; k < runs.Count && runs[k].Origin.Y <= b.Y + 0.05 * biggest && near.Count <= MaxRunsUnderOne; k++)
            {
                // Every run on the band counts, kept or not: what bounds the work is how many are looked at.
                scanned++;
                if (++looked > MaxRunsScannedForOne) break;
                var r = runs[k];
                var em = r.FontSize;
                if (b.Y < r.Origin.Y - 0.05 * em || b.Y > r.Origin.Y + 0.4 * em || r.Box.Right <= b.X || r.Box.X >= b.Right) continue;
                near.Add(r);
            }
            if (near.Count == 0 || near.Count > MaxRunsUnderOne || looked > MaxRunsScannedForOne) continue;
            // The words over it: the baseline nearest above its top.
            var baseline = near.Max(r => r.Origin.Y);
            var over = near.Where(r => baseline - r.Origin.Y < 0.25 * r.FontSize).OrderBy(r => r.Box.X).ToList();
            var size = over.Max(r => r.FontSize);
            if (b.Height > Math.Max(1, size / 6) || b.Width < 0.5 * size) continue;
            if (links.Any(l => l.Inflate(0.3 * size).Contains(b.CenterX, b.CenterY))) continue;
            // How much of its width the words over it cover (their boxes joined where they overlap).
            double covered = 0, reach = b.X;
            foreach (var r in over)
            {
                double from = Math.Max(reach, Math.Max(b.X, r.Box.X)), to = Math.Min(b.Right, r.Box.Right);
                if (to > from) covered += to - from;
                reach = Math.Max(reach, to);
            }
            if (covered < UnderlineCovered * b.Width) continue;
            var under = over.Where(r => !taken.Contains(r) && Math.Min(b.Right, r.Box.Right) - Math.Max(b.X, r.Box.X) >= 0.5 * r.Box.Width).ToList();
            if (under.Count == 0) continue;
            foreach (var r in under) taken.Add(r);
            found.Add(new Underline(b, paint.Id, paint.Color!.Value & 0xFFFFFF, under));
        }
        return found;
    }

    /// <summary>
    /// A written paragraph's new underlines: its text's underlined stretches (<see cref="ParagraphLayout.Underlined"/>) drawn
    /// as the first of the page's rules under its old words was (<paramref name="underlines"/>), at its distance below the
    /// baseline and thickness scaled with the text, in its color: page operators to add after the content (empty when there
    /// is nothing to draw). The old rules go in <see cref="TakeOffUnderlines"/>, once every paragraph is written.
    /// </summary>
    private static string NewUnderlines(PdfPage page, TextParagraph p, IReadOnlyList<Underline> underlines, ParagraphLayout layout, double fit)
    {
        if (layout.Underlined.Count == 0) return "";
        var mine = new HashSet<TextRun>(p.Runs, ReferenceEqualityComparer.Instance);
        if (underlines.FirstOrDefault(u => u.Runs.Any(mine.Contains)) is not { } first) return "";
        var em = p.FontSize;
        if (!(em > 0)) return "";
        // Its place and thickness in ems of the paragraph's text, from the baseline of the words it was under.
        var below = (first.Box.Y - first.Runs.Max(r => r.Origin.Y)) / em;
        var thick = first.Box.Height / em;
        var sb = new StringBuilder();
        foreach (var (left, right, baseline) in layout.Underlined)
        {
            var top = baseline + below * em * fit;
            sb.Append(Filled(page, RectD.FromEdges(left, top, right, top + Math.Max(0.25, thick * em * fit)), first.Color));
        }
        return sb.ToString();
    }

    /// <summary>
    /// The page's plain underlines under words that were written (<paramref name="written"/>) taken off, each operator
    /// becoming "n" (in <paramref name="pageEdits"/>); a rule also under words that weren't (a paragraph whose answer was
    /// refused, one beside it on the line) is drawn again over just those words' width, as it was: page operators to add
    /// after the content.
    /// </summary>
    private static string TakeOffUnderlines(PdfPage page, IReadOnlyList<Underline> underlines, HashSet<TextRun> written, List<COp> ops,
        List<(int Start, int End, string Text)> pageEdits)
    {
        var sb = new StringBuilder();
        foreach (var u in underlines)
        {
            if (!u.Runs.Any(written.Contains)) continue;
            pageEdits.Add((ops[u.Id].Start, ops[u.Id].End, "n"));
            // The rest, run by run (runs side by side make one piece), within the rule's own width.
            double? from = null, to = null;
            foreach (var r in u.Runs.OrderBy(r => r.Box.X))
            {
                if (written.Contains(r))
                {
                    if (from is not null) sb.Append(Filled(page, RectD.FromEdges(from.Value, u.Box.Y, to!.Value, u.Box.Bottom), u.Color));
                    from = to = null;
                    continue;
                }
                from ??= Math.Max(u.Box.X, r.Box.X);
                to = Math.Min(u.Box.Right, r.Box.Right);
            }
            if (from is not null && to > from) sb.Append(Filled(page, RectD.FromEdges(from.Value, u.Box.Y, to!.Value, u.Box.Bottom), u.Color));
        }
        return sb.ToString();
    }
}