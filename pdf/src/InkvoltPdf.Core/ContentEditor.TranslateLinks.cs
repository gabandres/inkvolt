using System.Globalization;
using System.Text;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// A translated paragraph's links and underlines (roadmap 3.1). The words move, so what marked them where they were would
/// mark the middle of other words: a link (/Link) whose words the translation keeps as they were (an identifier, a
/// document number: "SP 800-63A", "(SP) 800-63A") moves onto them, a copy for each further line they reach, with its underline redrawn
/// under them; a link whose words were translated is taken off the page (it can't be told what they became), with its
/// underline. An underline that is no link's, or that can't be drawn again, stays as drawn.
/// </summary>
public static partial class ContentEditor
{
    /// <summary>The most links on a page looked at: more is a crafted page, and they stay as they are.</summary>
    private const int MaxLinksToFollow = 2_000;

    /// <summary>The most words of a link matched against its new text.</summary>
    private const int MaxLinkWords = 64;

    /// <summary>The most words of a paragraph's new text a link is looked for in.</summary>
    private const int MaxWordsToSearch = 4_000;

    /// <summary>
    /// A link on a translated paragraph's lines (<see cref="TranslationWritten.Slot"/>): its annotation, where it was, its
    /// words then, its underline (<see cref="LinkUnderline"/>; null: none to move) and the baseline of its line; where the
    /// new text is, where its lines start (page as shown) and how far it shrank (<paramref name="Placed"/> null: a turned
    /// paragraph, whose link is dropped), and the paragraph's size.
    /// </summary>
    internal sealed record LinkFix(int Slot, PdfDictionary Annot, RectD Box, List<string> Words, Paint? Underline, double Baseline, RectD? Placed,
        IReadOnlyList<PointD> Lines, double Fit, double FontSize);

    /// <summary>The page's /Link annotations and where they are (none past <see cref="MaxLinksToFollow"/>).</summary>
    private static List<(PdfDictionary Annot, RectD Box)> PageLinks(PdfPage page)
    {
        var links = new List<(PdfDictionary, RectD)>();
        if (PdfObj.Array(page.Elements["/Annots"]) is not { } annots || annots.Elements.Count > MaxLinksToFollow) return links;
        foreach (var item in annots.Elements)
            if (PdfObj.Dict(item) is { } a && PdfObj.NameOf(a, "/Subtype") == "/Link" && PdfObj.Array(a.Elements["/Rect"]) is { Elements.Count: >= 4 } rect
                && PdfObj.RectToPage(page, rect) is { Width: > 0, Height: > 0 } box && double.IsFinite(box.X + box.Y + box.Width + box.Height))
                links.Add((a, box));
        return links;
    }

    /// <summary>The line of a paragraph a box sits on: its center within the line's height (a little more), and inside its width.</summary>
    private static int LineOf(TextParagraph p, RectD box)
    {
        var tol = 0.25 * p.FontSize;
        for (var k = 0; k < p.Lines.Count; k++)
        {
            var l = p.Lines[k];
            if (box.CenterY >= l.Y - tol && box.CenterY <= l.Bottom + tol && box.CenterX >= l.X - 1 && box.CenterX <= l.Right + 1) return k;
        }
        return -1;
    }

    /// <summary>
    /// A link's underline on an upright paragraph's line: one rectangle filled in a plain color (so it can be drawn again,
    /// and no other link's or line's mark is in the same operator), no thicker than a sixth of the text, its top between
    /// the line's middle and a third of an em below it, and within the link's own width. Null when there is none: a stroke,
    /// a color that isn't followed, several marks filled together, or one reaching past the link stays as drawn.
    /// <paramref name="gone"/>: underlines already a link's.
    /// </summary>
    private static Paint? LinkUnderline(TextParagraph p, RectD line, RectD link, IReadOnlyList<Paint> paints, List<COp> ops, HashSet<int> gone)
    {
        var em = p.FontSize;
        var tol = 0.3 * em;
        foreach (var u in paints)
        {
            if (u is not { Rect: true, Color: not null, Box: { } b } || u.Id < 0 || u.Id >= ops.Count || ops[u.Id].Name is not ("f" or "F" or "f*") || gone.Contains(u.Id)) continue;
            if (b.Height > Math.Max(1, em / 6) || b.Width < 0.5 * em || b.X < link.X - tol || b.Right > link.Right + tol || b.Y < line.CenterY || b.Y > line.Bottom + em / 3) continue;
            gone.Add(u.Id);
            return u;
        }
        return null;
    }

    /// <summary>The words of a paragraph's runs inside a box, in order (upright runs only, where their glyphs are).</summary>
    private static List<string> WordsIn(IEnumerable<TextRun> runs, RectD box)
    {
        var words = new List<string>();
        foreach (var r in runs.Where(r => Math.Abs(r.Angle) < 0.5 && r.Box.CenterY >= box.Y && r.Box.CenterY <= box.Bottom).OrderBy(r => r.Origin.Y).ThenBy(r => r.Box.X))
            foreach (var (start, end, text) in LineWords(r))
                if ((start + end) / 2 >= box.X && (start + end) / 2 <= box.Right)
                    words.AddRange(text.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        return words.Count > MaxLinkWords ? words[..MaxLinkWords] : words;
    }

    private static readonly char[] AroundWords = [',', '.', ';', ':', '!', '?', '"', '\'', '“', '”', '‘', '’', '(', ')', '[', ']', '«', '»'];

    /// <summary>A word as compared: without the punctuation around it.</summary>
    private static string Bare(string word) => word.Trim(AroundWords);

    /// <summary>A bare word worth following a link by: with a figure, or of 4 letters or more (not "the" or "and").</summary>
    private static bool Telling(string bare) => bare.Any(char.IsDigit) || bare.Count(char.IsLetter) >= 4;

    /// <summary>
    /// Where a link's words are in the new text: each place (its first word, how many) the new words have the longest
    /// stretch of them, in their order, as they were (not already taken by another link), worth following
    /// (<see cref="Telling"/>); none when there is none. Spaces don't count, so "800-" "63A," (a line's gaps fall where
    /// its maker spaced it) is "800-63A," as one word. Only new words whose first letter starts the stretch are tried.
    /// </summary>
    internal static List<(int Start, int Count)> Follow(IReadOnlyList<string> linkWords, IReadOnlyList<string> newWords, ISet<int> taken)
    {
        var found = new List<(int Start, int Count)>();
        var placesFound = new HashSet<int>();
        var telling = linkWords.Select(w => Telling(Bare(w))).ToArray();
        var bare = new string[newWords.Count];
        var startsWith = new Dictionary<char, List<int>>();
        for (var i = 0; i < newWords.Count; i++)
        {
            bare[i] = Bare(newWords[i]);
            if (bare[i].Length == 0) continue;
            if (!startsWith.TryGetValue(bare[i][0], out var list)) startsWith[bare[i][0]] = list = [];
            list.Add(i);
        }
        for (var len = linkWords.Count; len >= 1 && found.Count == 0; len--)
            for (var from = 0; from + len <= linkWords.Count; from++)
            {
                if (Array.IndexOf(telling, true, from, len) < 0) continue;
                var want = Bare(string.Concat(linkWords.Skip(from).Take(len)));
                if (want.Length < 2 || !startsWith.TryGetValue(want[0], out var starts)) continue;
                foreach (var at in starts)
                {
                    // The stretch, without the punctuation before it, starts with the first word's bare form.
                    if (taken.Contains(at) || placesFound.Contains(at) || !want.StartsWith(bare[at], StringComparison.Ordinal)) continue;
                    var joined = "";
                    for (var end = at; end < newWords.Count && !taken.Contains(end); end++)
                    {
                        joined += newWords[end];
                        var got = joined.AsSpan().TrimStart(AroundWords);
                        if (got.TrimEnd(AroundWords).SequenceEqual(want))
                        {
                            found.Add((at, end - at + 1));
                            placesFound.Add(at);
                            break;
                        }
                        // More words only add to the end: once it isn't how the stretch begins, it never is.
                        if (!want.AsSpan().StartsWith(got, StringComparison.Ordinal)) break;
                    }
                }
            }
        return found;
    }

    /// <summary>
    /// Of the places a link's words are in its paragraph's new text (<see cref="Follow"/>), the one nearest where the link
    /// was (its first word's start and line against the link's left edge and middle); null when there is none or another
    /// is as near (within half an em): the link would then be on words that may not be its own.
    /// </summary>
    private static (int Start, int Count)? Nearest(List<(int Start, int Count)> found, List<(string Text, double Start, double End, TextRun Run)> words, RectD was, double em)
    {
        (int Start, int Count)? best = null;
        double nearest = double.MaxValue, next = double.MaxValue;
        foreach (var f in found)
        {
            var w = words[f.Start];
            var d = Math.Sqrt(Math.Pow(w.Start - was.X, 2) + Math.Pow(w.Run.Box.CenterY - was.CenterY, 2));
            if (d < nearest) (next, nearest, best) = (nearest, d, f);
            else next = Math.Min(next, d);
        }
        return next - nearest > 0.5 * em ? best : null;
    }

    /// <summary>
    /// The links of the paragraphs just written on a page, to be moved with their underlines or dropped once the page's
    /// fonts are in the document (<see cref="FixLinks"/>); nothing on the page changes yet. <paramref name="placed"/>: where
    /// each upright paragraph's new text is, where its lines start and how far it shrank. Turned paragraphs' links are
    /// dropped, their underlines left.
    /// </summary>
    private static List<LinkFix> LinksOfWritten(PdfPage page, List<TranslationSlot> slots, List<TranslationWritten> written,
        IReadOnlyDictionary<int, (RectD Box, double Fit, List<PointD> Lines)> placed, List<COp> ops, IReadOnlyList<Paint>? paints)
    {
        var found = new List<LinkFix>();
        var links = PageLinks(page);
        var claimed = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var gone = new HashSet<int>();
        foreach (var w in written)
        {
            var p = slots[w.Slot].Paragraph;
            var upright = p.Upright is null;
            foreach (var (annot, box) in links)
            {
                if (claimed.Contains(annot)) continue;
                var line = LineOf(p, box);
                if (line < 0) continue;
                claimed.Add(annot);
                var words = upright ? WordsIn(p.Runs, box) : [];
                var l = p.Lines[line];
                var baseline = p.Runs.Where(r => r.Box.CenterY >= l.Y && r.Box.CenterY <= l.Bottom).Select(r => r.Origin.Y).DefaultIfEmpty(l.Bottom).Max();
                var underline = upright && paints is not null ? LinkUnderline(p, l, box, paints, ops, gone) : null;
                var to = upright && placed.TryGetValue(w.Slot, out var at) ? at : ((RectD Box, double Fit, List<PointD> Lines)?)null;
                found.Add(new LinkFix(w.Slot, annot, box, words, underline, baseline, to?.Box, to?.Lines ?? [], to?.Fit ?? 1, p.FontSize));
            }
        }
        return found;
    }

    /// <summary>
    /// A paragraph's new words where they are now, line by line: those of the runs written on its new lines (starting on
    /// one of their baselines, at or after its start) inside where it was placed, so no other text there is taken for it.
    /// </summary>
    private static List<(string Text, double Start, double End, TextRun Run)> WrittenWords(PageContent after, RectD placed, IReadOnlyList<PointD> lines, double em)
    {
        var area = placed.Inflate(0.25 * em);
        var words = new List<(string Text, double Start, double End, TextRun Run)>();
        var mine = after.Runs.Where(r => Math.Abs(r.Angle) < 0.5 && r.Text.Trim().Length > 0 && area.Contains(r.Box.CenterX, r.Box.CenterY)
            && lines.Any(o => Math.Abs(r.Origin.Y - o.Y) < 0.5 && r.Origin.X >= o.X - 1));
        foreach (var r in mine.OrderBy(r => Math.Round(r.Origin.Y, 1)).ThenBy(r => r.Box.X))
            foreach (var (start, end, text) in LineWords(r))
                foreach (var part in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                    if (words.Count < MaxWordsToSearch) words.Add((part, start, end, r));
        return words;
    }

    /// <summary>
    /// Once a page's translated paragraphs are written and the fonts they use are in the document: each link
    /// (<see cref="LinksOfWritten"/>) is moved onto its words where its paragraph's new text keeps them (its /Rect around
    /// them, a copy for each further line they reach), with its underline redrawn under them as it was (its distance from
    /// the baseline and thickness scaled with the text, its color), or else taken off the page, and out of the structure
    /// tree, with its underline. The page is read first and changed after: if it can't be read, its links and underlines
    /// stay as they were; an underline not found again as it was drawn stays, and isn't drawn again.
    /// </summary>
    internal static void FixLinks(PdfDocument doc, int pageIndex, IReadOnlyList<LinkFix> links)
    {
        if (links.Count == 0) return;
        var page = doc.Pages[pageIndex];
        var streams = Streams(page);
        var ops = ContentLexer.Parse(streams.Bytes, CancellationToken.None);
        var walk = Walk(page, pageIndex, ops, CancellationToken.None);
        var paints = walk.PaintsCut ? null : walk.Paints;
        var drop = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var blank = new List<(int Start, int End, string Text)>();
        var underlines = new StringBuilder();
        var moves = new List<(PdfDictionary Annot, List<RectD> Boxes)>();

        // A link's underline in the page's content now: the one filled rectangle of its color where it was (unchanged by
        // the paragraph's rewrite), its operator to become "n" (the path ends unpainted). False: not found, or not alone.
        bool Blank(Paint? underline)
        {
            if (underline is not { Box: { } was, Color: { } color } || paints is null) return false;
            var hit = -1;
            foreach (var x in paints)
                if (x is { Rect: true, Box: { } b } && x.Color == color && x.Id >= 0 && x.Id < ops.Count && ops[x.Id].Name is "f" or "F" or "f*"
                    && Math.Abs(b.X - was.X) < 0.01 && Math.Abs(b.Y - was.Y) < 0.01 && Math.Abs(b.Right - was.Right) < 0.01 && Math.Abs(b.Bottom - was.Bottom) < 0.01)
                {
                    if (hit >= 0) return false;
                    hit = x.Id;
                }
            if (hit < 0) return false;
            blank.Add((ops[hit].Start, ops[hit].End, "n"));
            return true;
        }

        foreach (var group in links.GroupBy(l => l.Slot))
        {
            var first = group.First();
            if (first.Placed is not { } placed)
            {
                foreach (var l in group) drop.Add(l.Annot);
                continue;
            }
            var words = WrittenWords(walk.Content, placed, first.Lines, first.FontSize);
            var texts = words.Select(x => x.Text).ToList();
            var taken = new HashSet<int>();
            foreach (var l in group.OrderBy(x => x.Box.Y).ThenBy(x => x.Box.X))
            {
                if (l.Words.Count == 0 || Nearest(Follow(l.Words, texts, taken), words, l.Box, l.FontSize) is not var (at, count))
                {
                    drop.Add(l.Annot);
                    Blank(l.Underline);
                    continue;
                }
                for (var k = at; k < at + count; k++) taken.Add(k);
                // A box for each line the words reach.
                var boxes = new List<(RectD Box, TextRun Run)>();
                for (var k = at; k < at + count; k++)
                {
                    var (_, start, end, run) = words[k];
                    if (boxes.Count > 0 && Math.Abs(boxes[^1].Run.Origin.Y - run.Origin.Y) < 0.5)
                        boxes[^1] = (RectD.FromEdges(boxes[^1].Box.X, Math.Min(boxes[^1].Box.Y, run.Box.Y), Math.Max(boxes[^1].Box.Right, end), Math.Max(boxes[^1].Box.Bottom, run.Box.Bottom)), run);
                    else boxes.Add((RectD.FromEdges(start, run.Box.Y, end, run.Box.Bottom), run));
                }
                moves.Add((l.Annot, [.. boxes.Select(b => b.Box)]));
                if (l.Underline is { Box: { } was, Color: { } color } && Blank(l.Underline))
                {
                    var below = (was.Y - l.Baseline) * l.Fit;
                    var thick = Math.Max(0.25, was.Height * l.Fit);
                    foreach (var (box, run) in boxes) underlines.Append(Filled(page, RectD.FromEdges(box.X, run.Origin.Y + below, box.Right, run.Origin.Y + below + thick), color));
                }
            }
        }

        // Read and worked out: now the page changes (a damaged page refuses the first write, before anything else).
        if (blank.Count > 0) WriteContent(doc, page, streams, ops, blank);
        if (underlines.Length > 0) PdfObj.AppendContent(doc, page, underlines.ToString());
        var added = new List<PdfDictionary>();
        foreach (var (annot, boxes) in moves) added.AddRange(Place(doc, page, annot, boxes));
        if (drop.Count == 0 && added.Count == 0) return;
        var keys = new List<int>();
        if (PdfObj.Array(page.Elements["/Annots"]) is { } annots)
        {
            var kept = new PdfArray(doc); // the page's own: another page may share the old one
            foreach (var item in annots.Elements)
            {
                if (PdfObj.Dict(item) is { } a && drop.Contains(a))
                {
                    if (PdfObj.Int(a.Elements["/StructParent"]) is { } key) keys.Add(key);
                    continue;
                }
                kept.Elements.Add(item);
            }
            foreach (var a in added) kept.Elements.Add(a.Reference!);
            page.Elements["/Annots"] = kept;
        }
        if (drop.Count > 0) StructTree.Prune(doc, [], keys, drop.Contains);
    }

    /// <summary>
    /// A link annotation set around the first of some boxes of the page as shown, and a copy of it around each other one
    /// (returned, for the page's /Annots): one box spanning two lines would make the lines' whole width a link where
    /// /QuadPoints aren't read. A copy has no place in the structure tree or name of its own.
    /// </summary>
    private static List<PdfDictionary> Place(PdfDocument doc, PdfPage page, PdfDictionary annot, List<RectD> boxes)
    {
        PdfArray Rect(RectD b)
        {
            var (x1, y1) = PdfObj.ToPdf(page, b.X, b.Y);
            var (x2, y2) = PdfObj.ToPdf(page, b.Right, b.Bottom);
            return PdfObj.Reals(doc, Math.Min(x1, x2), Math.Min(y1, y2), Math.Max(x1, x2), Math.Max(y1, y2));
        }
        annot.Elements["/Rect"] = Rect(boxes[0]);
        annot.Elements.Remove("/QuadPoints");
        var copies = new List<PdfDictionary>();
        foreach (var box in boxes.Skip(1))
        {
            var copy = new PdfDictionary(doc);
            foreach (var key in annot.Elements.Keys)
                if (key is not ("/StructParent" or "/NM")) copy.Elements[key] = annot.Elements[key];
            copy.Elements["/Rect"] = Rect(box);
            doc.Internals.AddObject(copy);
            copies.Add(copy);
        }
        return copies;
    }

    /// <summary>A rectangle of the page as shown filled in a color, as operators in the page's default space.</summary>
    private static string Filled(PdfPage page, RectD box, int color)
    {
        var a = PdfObj.ToPdf(page, box.X, box.Y);
        var b = PdfObj.ToPdf(page, box.Right, box.Bottom);
        string N(double v) => ContentLexer.Number(v);
        return string.Create(CultureInfo.InvariantCulture,
            $"{N((color >> 16 & 0xFF) / 255.0)} {N((color >> 8 & 0xFF) / 255.0)} {N((color & 0xFF) / 255.0)} rg {N(Math.Min(a.X, b.X))} {N(Math.Min(a.Y, b.Y))} {N(Math.Abs(b.X - a.X))} {N(Math.Abs(b.Y - a.Y))} re f\n");
    }
}
