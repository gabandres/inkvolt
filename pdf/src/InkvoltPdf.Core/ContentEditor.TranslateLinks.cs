using System.Globalization;
using System.Text;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// A translated paragraph's links and underlines (roadmap 3.1). The words move, so what marked them where they were would
/// mark the middle of other words: a link (/Link) whose words the translation keeps as they were (an identifier, a
/// document number: "SP 800-63A", "(SP) 800-63A") moves onto them, a copy for each further line they reach, with its underline redrawn
/// under them; a link whose words were translated is taken off the page (it can't be told what they became), and a
/// thin underline drawn under the old words goes.
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
    /// words then, the underline under them and the baseline of its line; where the new text is and how far it shrank
    /// (null: a turned paragraph, whose link is dropped), and the paragraph's size.
    /// </summary>
    internal sealed record LinkFix(int Slot, PdfDictionary Annot, RectD Box, List<string> Words, Paint? Underline, double Baseline, RectD? Placed, double Fit, double FontSize);

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
    /// A thin stroke or filled rectangle under one of an upright paragraph's lines (an underline): no thicker than a
    /// sixth of the text, its top between the line's middle and a third of an em below it, and no wider than the line
    /// (a table's rule under a cell's text reaches past it).
    /// </summary>
    private static bool Underlines(TextParagraph p, Paint paint, List<COp> ops)
    {
        if (paint.Box is not { } b || paint.Id < 0 || paint.Id >= ops.Count || ops[paint.Id].Name is not ("f" or "F" or "f*" or "S" or "s" or "B" or "B*" or "b" or "b*")) return false;
        var em = p.FontSize;
        if (b.Height > Math.Max(1, em / 6) || b.Width < 0.5 * em) return false;
        foreach (var l in p.Lines)
            if (b.X >= l.X - 1 && b.Right <= l.Right + 1 && b.Y >= l.CenterY && b.Y <= l.Bottom + em / 3) return true;
        return false;
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

    /// <summary>A word as compared: without the punctuation around it.</summary>
    private static string Bare(string word) => word.Trim(',', '.', ';', ':', '!', '?', '"', '\'', '“', '”', '‘', '’', '(', ')', '[', ']', '«', '»');

    /// <summary>Words worth following a link by: a figure, or a word of 4 letters or more (not "the" or "and").</summary>
    private static bool Telling(IEnumerable<string> words) => words.Select(Bare).Any(w => w.Any(char.IsDigit) || w.Count(char.IsLetter) >= 4);

    /// <summary>
    /// Where a link's words are in the new text: the longest stretch of them, in their order, that the new words have as
    /// they were (not already taken by another link), worth following (<see cref="Telling"/>); null when there is none.
    /// Spaces don't count, so "800-" "63A," (a line's gaps fall where its maker spaced it) is "800-63A," as one word.
    /// </summary>
    internal static (int Start, int Count)? Follow(IReadOnlyList<string> linkWords, IReadOnlyList<string> newWords, ISet<int> taken)
    {
        for (var len = linkWords.Count; len >= 1; len--)
            for (var from = 0; from + len <= linkWords.Count; from++)
            {
                var stretch = linkWords.Skip(from).Take(len).ToList();
                var want = Bare(string.Concat(stretch));
                if (want.Length < 2 || !Telling(stretch)) continue;
                for (var at = 0; at < newWords.Count; at++)
                {
                    var joined = new StringBuilder();
                    for (var end = at; end < newWords.Count && !taken.Contains(end); end++)
                    {
                        joined.Append(newWords[end]);
                        var got = Bare(joined.ToString());
                        if (got == want && Bare(newWords[at]).Length > 0) return (at, end - at + 1);
                        if (got.Length > want.Length) break;
                    }
                }
            }
        return null;
    }

    /// <summary>
    /// The links and underlines of the paragraphs just written on a page: underlines' painting operators become "n" (the
    /// path ends unpainted) in <paramref name="pageEdits"/>; the links are returned, to be moved or dropped once the
    /// page's fonts are in the document (<see cref="FixLinks"/>). <paramref name="placed"/>: where each upright paragraph's
    /// new text is and how far it shrank. Turned paragraphs' links are dropped, their underlines left.
    /// </summary>
    private static List<LinkFix> LinksOfWritten(PdfPage page, List<TranslationSlot> slots, List<TranslationWritten> written, IReadOnlyDictionary<int, (RectD Box, double Fit)> placed,
        List<COp> ops, IReadOnlyList<Paint>? paints, List<(int Start, int End, string Text)> pageEdits)
    {
        var found = new List<LinkFix>();
        var links = PageLinks(page);
        var claimed = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var gone = new HashSet<int>();
        foreach (var w in written)
        {
            var p = slots[w.Slot].Paragraph;
            var upright = p.Upright is null;
            var under = upright && paints is not null ? paints.Where(x => Underlines(p, x, ops) && gone.Add(x.Id)).ToList() : [];
            foreach (var u in under) pageEdits.Add((ops[u.Id].Start, ops[u.Id].End, "n"));
            foreach (var (annot, box) in links)
            {
                if (claimed.Contains(annot)) continue;
                var line = LineOf(p, box);
                if (line < 0) continue;
                claimed.Add(annot);
                var words = upright ? WordsIn(p.Runs, box) : [];
                var l = p.Lines[line];
                var baseline = p.Runs.Where(r => r.Box.CenterY >= l.Y && r.Box.CenterY <= l.Bottom).Select(r => r.Origin.Y).DefaultIfEmpty(l.Bottom).Max();
                // Its underline: under its own words, in a plain color to draw it again in.
                var mine = under.Where(u => u.Color is not null && u.Box!.Value.CenterX >= box.X - 1 && u.Box.Value.CenterX <= box.Right + 1 && u.Box.Value.Y >= l.CenterY)
                    .Select(u => (Paint?)u).FirstOrDefault();
                var to = upright && placed.TryGetValue(w.Slot, out var at) ? at : ((RectD Box, double Fit)?)null;
                found.Add(new LinkFix(w.Slot, annot, box, words, mine, baseline, to?.Box, to?.Fit ?? 1, p.FontSize));
            }
        }
        return found;
    }

    /// <summary>
    /// Once a page's translated paragraphs are written and the fonts they use are in the document: each link
    /// (<see cref="LinksOfWritten"/>) is moved onto its words where the new text keeps them (its /Rect around them,
    /// /QuadPoints for each line they reach), with its underline redrawn under them as it was (its distance from the
    /// baseline and thickness scaled with the text, its color), or else taken off the page, and out of the structure tree.
    /// </summary>
    internal static void FixLinks(PdfDocument doc, int pageIndex, IReadOnlyList<LinkFix> links)
    {
        if (links.Count == 0) return;
        var page = doc.Pages[pageIndex];
        PageContent? after = null;
        var drop = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var underlines = new StringBuilder();
        var added = new List<PdfDictionary>();
        foreach (var group in links.GroupBy(l => l.Slot))
        {
            var first = group.First();
            if (first.Placed is not { } placed || group.All(l => l.Words.Count == 0))
            {
                foreach (var l in group) drop.Add(l.Annot);
                continue;
            }
            after ??= Walk(page, pageIndex, ContentLexer.Parse(Streams(page).Bytes, CancellationToken.None), CancellationToken.None).Content;
            // The new text's words where they are now: the runs in its box, line by line.
            var area = placed.Inflate(0.25 * first.FontSize);
            var words = new List<(string Text, double Start, double End, TextRun Run)>();
            foreach (var r in after.Runs.Where(r => Math.Abs(r.Angle) < 0.5 && r.Text.Trim().Length > 0 && area.Contains(r.Box.CenterX, r.Box.CenterY)).OrderBy(r => Math.Round(r.Origin.Y, 1)).ThenBy(r => r.Box.X))
                foreach (var (start, end, text) in LineWords(r))
                    foreach (var part in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                        if (words.Count < MaxWordsToSearch) words.Add((part, start, end, r));
            var texts = words.Select(x => x.Text).ToList();
            var taken = new HashSet<int>();
            foreach (var l in group.OrderBy(x => x.Box.Y).ThenBy(x => x.Box.X))
            {
                if (Follow(l.Words, texts, taken) is not var (at, count))
                {
                    drop.Add(l.Annot);
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
                added.AddRange(Place(doc, page, l.Annot, [.. boxes.Select(b => b.Box)]));
                if (l.Underline is { Box: { } was, Color: { } color })
                {
                    var below = (was.Y - l.Baseline) * l.Fit;
                    var thick = Math.Max(0.25, was.Height * l.Fit);
                    foreach (var (box, run) in boxes) underlines.Append(Filled(page, RectD.FromEdges(box.X, run.Origin.Y + below, box.Right, run.Origin.Y + below + thick), color));
                }
            }
        }
        if (underlines.Length > 0) PdfObj.AppendContent(doc, page, underlines.ToString());
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
