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

    /// <summary>The most table cells kept for a page (a crafted page could claim any number).</summary>
    private const int MaxCells = 4_000;

    /// <summary>The smallest text a paragraph shrinks to: half its size, and not under 5 points unless it was already.</summary>
    internal static double SmallestFit(double size) => size <= 5 ? 1 : Math.Clamp(5 / size, 0.5, 1);

    private const double FitStep = 0.05;

    /// <summary>More text than this can't fit on a page at any size allowed: not laid out.</summary>
    private const int MaxTextToLayOut = 60_000;

    // ---- Finding the paragraphs ----

    /// <summary>A page's text runs and pictures, for <see cref="TranslationSlots"/>.</summary>
    internal static PageContent ReadRaw(PdfPage page, int pageIndex, CancellationToken cancel) => Walk(page, pageIndex, Parse(page, cancel), cancel).Content;

    /// <summary>
    /// A page's paragraphs for translating, in reading order of their first line: each table cell's text apart from its
    /// neighbors', raised marks taken into the line they sit on, a bullet in front of a line left where it is.
    /// </summary>
    internal static List<TranslationSlot> TranslationSlots(PageContent content, IReadOnlyList<RectD> cells, CancellationToken cancel)
    {
        var groups = new Dictionary<int, List<TextRun>>();
        foreach (var r in content.Runs)
        {
            if (Math.Abs(r.Angle) >= 0.5 || r.Text.Trim().Length == 0 || r.FontSize <= 0.5 || r.Box.Width <= 0) continue;
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
        var slots = new List<TranslationSlot>();
        foreach (var (cell, runs) in groups)
        {
            cancel.ThrowIfCancellationRequested();
            var lines = WithoutMarkers(WithMarksInLine(LinesOf(runs)));
            foreach (var stack in Stacks(lines))
            {
                cancel.ThrowIfCancellationRequested();
                foreach (var part in SplitShort(stack))
                    slots.Add(new TranslationSlot(Paragraph(content, part, translating: true), cell >= 0 ? cells[cell] : null));
            }
        }
        // The same order however the page's runs were grouped.
        return [.. slots.OrderBy(s => s.Paragraph.Box.Y).ThenBy(s => s.Paragraph.Box.X).ThenBy(s => s.Paragraph.Runs.Min(r => r.Id))];
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
            if (l.Runs.Count > 1 && first.Text.Trim().Length <= 2 && !first.Text.Any(char.IsLetterOrDigit))
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

    /// <summary>
    /// A paragraph as it will be written: the edges its lines stay between, its alignment as the page shows it (a single
    /// line can't tell, so its place on the page or in its cell does), and how far down it may go.
    /// </summary>
    private static (TextParagraph Paragraph, double Bottom) Room(TranslationSlot slot, PageContent content, IReadOnlyList<RectD> obstacles, double pageWidth, double pageHeight)
    {
        var p = slot.Paragraph;
        var framed = p with { };
        var mine = new HashSet<TextRun>(p.Runs, ReferenceEqualityComparer.Instance);
        var others = content.Runs.Where(r => !mine.Contains(r) && r.Text.Trim().Length > 0 && Math.Abs(r.Angle) < 0.5).Select(r => r.Box)
            .Concat(content.Images.Select(i => i.Box)).Concat(obstacles).ToList();

        // A panel the text sits in (a shaded box, a callout) holds it unless it is about the whole page.
        var panel = obstacles.Where(o => o.Width * o.Height < 0.8 * pageWidth * pageHeight && o.Contains(p.Box.CenterX, p.Box.CenterY) && o.Contains(p.Box.X + 0.5, p.Box.Y + 0.5) && o.Contains(p.Box.Right - 0.5, p.Box.Bottom - 0.5))
            .OrderBy(o => o.Width * o.Height).Select(o => (RectD?)o).FirstOrDefault();
        var holder = slot.Cell ?? panel;

        if (p.Lines.Count == 1 || slot.Cell is not null)
        {
            // Across: to the next thing on its line, inside what holds it. Its text column on the page is what the page's other text reaches.
            var reachLeft = holder?.X ?? Math.Min(p.Left, content.Runs.Where(r => r.Text.Trim().Length > 0).Select(r => r.Box.X).DefaultIfEmpty(p.Left).Min());
            var reachRight = holder?.Right ?? Math.Max(p.Right, Math.Min(pageWidth - 18, content.Runs.Where(r => r.Text.Trim().Length > 0).Select(r => r.Box.Right).DefaultIfEmpty(p.Right).Max()));
            foreach (var b in others)
            {
                if (b.Y >= p.Box.Bottom || b.Bottom <= p.Box.Y) continue; // not on its lines
                if (b.Width > 0.8 * (reachRight - reachLeft) && b.X < p.Box.X && b.Right > p.Box.Right) continue; // behind it
                if (b.X >= p.Box.Right - 1 && b.X < reachRight) reachRight = b.X - 0.5 * p.FontSize;
                if (b.Right <= p.Box.X + 1 && b.Right > reachLeft) reachLeft = b.Right + 0.5 * p.FontSize;
            }
            reachRight = Math.Max(reachRight, p.Right);
            reachLeft = Math.Min(reachLeft, p.Left);
            if (holder is not null)
            {
                reachLeft = Math.Min(p.Left, reachLeft + 1.5);
                reachRight = Math.Max(p.Right, reachRight - 1.5);
            }
            var (inLeft, inRight) = holder is { } h ? (h.X, h.Right) : (reachLeft, reachRight);
            var tol = Math.Max(2, 0.2 * p.FontSize);
            var off = Math.Max(20, 2 * p.FontSize);
            var align = p.Align;
            if (p.Lines.Count == 1)
            {
                if (Math.Abs(p.Box.CenterX - (inLeft + inRight) / 2) <= tol && p.Box.X - inLeft > (holder is null ? off : 2)) align = ParagraphAlign.Center;
                else if (Math.Abs(p.Box.Right - inRight) <= tol && p.Box.X - inLeft > off) align = ParagraphAlign.Right;
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
        var bottom = slot.Cell?.Bottom ?? panel?.Bottom ?? Math.Max(p.Box.Bottom, pageHeight - 36);
        foreach (var b in others)
        {
            if (b.Y < p.Box.Bottom - 1 || b.Right <= framed.Left + 1 || b.X >= framed.Right - 1) continue;
            if (b.Y - 0.1 * p.FontSize < bottom) bottom = b.Y - 0.1 * p.FontSize;
        }
        return (framed, Math.Max(bottom, p.Box.Bottom));
    }

    /// <summary>
    /// The new text laid out at the largest size that fits its room (steps of 5%); at the smallest allowed when none does.
    /// Characters no font here has are left out and named.
    /// </summary>
    private static (ParagraphLayout Layout, double Fit, bool Fits, IReadOnlyList<string> Dropped) FitText(TextParagraph framed, double bottom, string text)
    {
        var dropped = new List<string>();
        var smallest = SmallestFit(framed.FontSize);
        ParagraphLayout? best = null;
        var fit = 1.0;
        for (; ; fit = Math.Max(smallest, fit - FitStep))
        {
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
            if (best.Check.Box.Bottom <= bottom + 0.5) return (best, fit, true, dropped);
            if (fit <= smallest) return (best, fit, false, dropped);
            // Far too tall: text takes room with the square of its size, so jump near where it will fit.
            var ratio = (bottom - framed.Box.Y) / Math.Max(1, best.Check.Box.Bottom - framed.Box.Y);
            fit = Math.Min(fit, Math.Round(Math.Sqrt(Math.Max(ratio, 0.01)) * fit / FitStep) * FitStep + 2 * FitStep);
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
        var primary = StandInFonts.RankFor(m.Font!).FirstOrDefault(f => cps.All(f.Font.Has))?.Font;
        var missing = TrueTypeFont.CodePoints(text)
            .Where(c => c > 32 && !(primary?.Has(c) == true || SystemFonts.For(c, primary) is { } fb && fb.Has(c)))
            .Distinct().Select(char.ConvertFromUtf32).ToList();
        if (missing.Count > 0) return new ParagraphLayout([], new ParagraphCheck(p.Box, p.Lines.Count, missing, null), []);

        double W(string line) => TextShaper.Measure(line, primary) * m.Size * m.HScale * m.Scale;
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
            while (W(cur) > avail + 0.01 && cur.Length > 1)
            {
                // A word wider than the line is broken: as much of it as fits.
                var els = System.Globalization.StringInfo.ParseCombiningCharacters(cur);
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
                if (!names.Contains(g.Font.Family)) names.Add(g.Font.Family);
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
                refused.Add(new TranslationRefused(i, "its translation is far too long for any box"));
                continue;
            }
            var (framed, bottom) = Room(slot, content, obstacles, pageWidth, pageHeight);
            var (layout, fit, fits, dropped) = FitText(framed, bottom, text);
            if (layout.Check.Missing.Count > 0 || layout.Lines.Count == 0)
            {
                refused.Add(new TranslationRefused(i, "no font on this PC can draw it"));
                continue;
            }

            var anchor = Anchor(p.Runs);
            var plain = PlainRun(p.Runs) with { };
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
                            refused.Add(new TranslationRefused(i, "it is inside a drawing that other pages share, drawn through another drawing"));
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
                edits.Add((op.Start, op.End, ReferenceEquals(run, anchor) ? WriteParagraph(page, op, run, plain, layout, writer.Fonts) : Removed(op, run)));
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
