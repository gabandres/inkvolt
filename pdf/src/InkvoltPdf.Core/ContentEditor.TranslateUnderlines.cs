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
        foreach (var paint in candidates)
        {
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
            for (var k = lo; k < runs.Count && runs[k].Origin.Y <= b.Y + 0.05 * biggest && near.Count <= MaxRunsUnderOne; k++)
            {
                var r = runs[k];
                var em = r.FontSize;
                if (b.Y < r.Origin.Y - 0.05 * em || b.Y > r.Origin.Y + 0.4 * em || r.Box.Right <= b.X || r.Box.X >= b.Right) continue;
                near.Add(r);
            }
            if (near.Count == 0 || near.Count > MaxRunsUnderOne) continue;
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
    /// A written paragraph's plain underlines: each of the page's (<paramref name="underlines"/>) under its runs is taken
    /// off (its operator becomes "n", once however many paragraphs it reaches), and the new text's underlined stretches
    /// (<see cref="ParagraphLayout.Underlined"/>) are drawn as the first of them was, scaled with the text: page operators
    /// to add after the content (empty when there is nothing to draw).
    /// </summary>
    private static string RedrawUnderlines(PdfPage page, TextParagraph p, IReadOnlyList<Underline> underlines, ParagraphLayout layout, double fit, List<COp> ops,
        List<(int Start, int End, string Text)> pageEdits, HashSet<int> blanked)
    {
        var mine = new HashSet<TextRun>(p.Runs, ReferenceEqualityComparer.Instance);
        Underline? first = null;
        foreach (var u in underlines)
        {
            if (!u.Runs.Any(mine.Contains)) continue;
            first ??= u;
            if (blanked.Add(u.Id)) pageEdits.Add((ops[u.Id].Start, ops[u.Id].End, "n"));
        }
        if (first is null || layout.Underlined.Count == 0) return "";
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
}
