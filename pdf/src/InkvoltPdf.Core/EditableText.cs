using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>What Make Text Editable did: the document, how many pages and words became text, and the fonts it drew them in ("Times New Roman").</summary>
public sealed record EditableTextResult(byte[] Data, int Pages, int Words, IReadOnlyList<string> Fonts);

/// <summary>
/// Make Text Editable (roadmap 2.2, for 2.1's paragraph editing): a scanned page's recognized words (its Inkvolt text
/// layer, <see cref="TextLayer"/>) become real, visible text, so Edit Text &amp; Images can change them. The words are put
/// in lines (by their angle, then their height on the page), the lines in paragraphs. The font is matched, as recognized
/// words carry none: of the installed families whose glyphs' proportions fit the words' boxes, the one whose words, set
/// where the scan has them and drawn, look most like the scan (<see cref="ScanLook"/>); a heading picks among every face,
/// bold ones too. Each line takes the size and baseline its words' boxes give in that font, each word starts where the scan
/// has it. Lines of a paragraph get one size, a steady line step and their left edges lined up, as 2.1 groups a
/// paragraph. The scan is covered behind each line with the paper's own colour (or left showing), and the invisible layer
/// goes.
/// </summary>
public static class EditableText
{
    /// <summary>More recognized words than this on a page is a crafted layer: only this many are made text.</summary>
    public const int MaxWords = 20_000;

    /// <summary>What a recognized word's box misses of its ink at each edge (points): half a pixel at 300 dpi, the resolution Recognize Text reads at.</summary>
    internal const double EdgeLoss = 0.12;

    /// <summary>A family whose measures miss the words by more than this (<see cref="Misfit"/>) isn't compared by look.</summary>
    internal const double MaxMisfit = 0.2;

    /// <summary>The most headings a page compares every installed face with (each one draws the line in each of them).</summary>
    public const int MaxHeadings = 6;

    /// <summary>A recognized word longer than this (characters) is no word: left out.</summary>
    public const int MaxWordLength = 200;

    internal sealed record Family(string Name, string Pdf, string Regular, string? Bold);

    /// <summary>The installed families the text is matched against: the usual faces of printed documents on Windows.</summary>
    internal static readonly Family[] Families =
    [
        new("Times New Roman", "TimesNewRoman", "times.ttf", "timesbd.ttf"),
        new("Arial", "Arial", "arial.ttf", "arialbd.ttf"),
        new("Calibri", "Calibri", "calibri.ttf", "calibrib.ttf"),
        new("Cambria", "Cambria", "cambria.ttc", "cambriab.ttf"),
        new("Georgia", "Georgia", "georgia.ttf", "georgiab.ttf"),
        new("Verdana", "Verdana", "verdana.ttf", "verdanab.ttf"),
        new("Segoe UI", "SegoeUI", "segoeui.ttf", "segoeuib.ttf"),
        new("Courier New", "CourierNew", "cour.ttf", "courbd.ttf"),
    ];

    private static readonly ConcurrentDictionary<string, TrueTypeFont?> Loaded = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>An installed face under its family's PDF name ("TimesNewRoman", "ArialBold"), loaded once for the run.</summary>
    internal static TrueTypeFont? Face(Family family, bool bold) =>
        (bold ? family.Bold : family.Regular) is { } file
            ? Loaded.GetOrAdd(file, f => SystemFonts.Get(f) is { } font ? TrueTypeFont.Load(family.Pdf + (bold ? "Bold" : ""), font.Bytes) : null)
            : null;

    /// <summary>The pages that have recognized text to make editable, in order.</summary>
    public static IReadOnlyList<int> Pages(byte[] data, string? password) => [.. TextLayer.Words(data, password).Keys.Order()];

    /// <summary>
    /// <paramref name="pages"/>' recognized text made real text (pages without an Inkvolt text layer are left alone).
    /// <paramref name="keepScan"/>: the scan stays showing behind the text (else it is covered behind each line).
    /// </summary>
    public static EditableTextResult Make(byte[] data, string? password, IReadOnlyCollection<int> pages, bool keepScan, CancellationToken cancel = default,
        IProgress<(int Done, int Total)>? progress = null)
    {
        var layers = TextLayer.Words(data, password);
        var chosen = pages.Distinct().Where(layers.ContainsKey).Order().ToList();
        if (chosen.Count == 0) return new EditableTextResult(data, 0, 0, []);
        var plans = new Dictionary<int, PagePlan>();
        // The paper behind each line, from the page as it shows.
        var papers = new Dictionary<int, (double R, double G, double B)[]>();
        using (var engine = PdfEngine.Open(data, InputFileTypes.PDF, password))
            for (var i = 0; i < chosen.Count; i++)
            {
                cancel.ThrowIfCancellationRequested();
                progress?.Report((i, chosen.Count));
                var page = chosen[i];
                var scan = new ScanLook(engine, page, cancel);
                if (Plan(layers[page].Words, scan.Resemblance) is not { Lines.Count: > 0 } plan) continue;
                plans[page] = plan;
                if (!keepScan) papers[page] = PaperBehind(engine, page, plan, cancel);
            }
        if (plans.Count == 0) return new EditableTextResult(data, 0, 0, []);

        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, PdfStrings.Doc_CantEdit);
        var fonts = new List<string>();
        var words = 0;
        foreach (var (index, plan) in plans.OrderBy(kv => kv.Key))
        {
            cancel.ThrowIfCancellationRequested();
            var page = doc.Pages[index];
            TextLayer.Remove(doc, page);
            Write(doc, page, plan, papers.GetValueOrDefault(index));
            words += plan.Lines.Sum(l => l.Words.Count);
            foreach (var name in plan.Lines.Select(plan.NameOf))
                if (!fonts.Contains(name)) fonts.Add(name);
        }
        return new EditableTextResult(PdfObj.Save(doc), plans.Count, words, fonts);
    }

    // ---- Planning ----

    /// <summary>A recognized word in its line's frame (the page turned back by the line's angle): its box, and where its text starts.</summary>
    internal sealed class PlanWord(string text, double left, double right, double top, double bottom)
    {
        public string Text { get; } = text;
        public double Left { get; } = left;
        public double Right { get; } = right;
        public double Top { get; } = top;
        public double Bottom { get; } = bottom;
        public double Height => Bottom - Top;
        public double Width => Right - Left;
        /// <summary>Where its text starts along the line (frame points): the box's left less the first glyph's left side.</summary>
        public double Pen { get; set; }
    }

    /// <summary>
    /// A line of text to write: its words, its frame's angle (degrees clockwise; the frame is the page turned back by it about
    /// the page's top left), size (points), baseline and bold, in frame coordinates.
    /// </summary>
    internal sealed class PlanLine(List<PlanWord> words, double angle)
    {
        public List<PlanWord> Words { get; } = words;
        public double Angle { get; } = angle;
        public double Size { get; set; }
        public double Baseline { get; set; }
        public bool Bold { get; set; }
        /// <summary>A family of its own (a heading set apart from the page's text); null: the page's.</summary>
        public Family? Family { get; set; }
        public double Left => Words[0].Pen;
        public double Right => Words[^1].Right;
        public double Top => Words.Min(w => w.Top);
        public double Bottom => Words.Max(w => w.Bottom);
        public string Text => _text ??= string.Join(' ', Words.Select(w => w.Text));
        private string? _text;
        /// <summary>The paragraph it was put in (an index on its page).</summary>
        public int Paragraph { get; set; }
    }

    /// <summary>A page's lines and the family they are written in.</summary>
    internal sealed record PagePlan(Family Family, List<PlanLine> Lines)
    {
        public Family FamilyOf(PlanLine line) => line.Family ?? Family;

        public TrueTypeFont FaceOf(PlanLine line) => (line.Bold ? Face(FamilyOf(line), true) : null) ?? Face(FamilyOf(line), false)!;

        /// <summary>The face a line is drawn in, as people know it ("Times New Roman Bold").</summary>
        public string NameOf(PlanLine line) => FamilyOf(line).Name + (line.Bold && Face(FamilyOf(line), true) is not null ? " Bold" : "");
    }

    /// <summary>How far a word's ink reaches (ems): left and right from the pen, top and bottom from the baseline (up positive).</summary>
    internal readonly record struct Ink(double Left, double Right, double Top, double Bottom, bool Missing)
    {
        public double Width => Right - Left;
        public double Height => Top - Bottom;
    }

    /// <summary>While a page is planned, each text's ink in each font, worked out once.</summary>
    [ThreadStatic]
    private static Dictionary<(string, TrueTypeFont), Ink>? _inks;

    /// <summary>The ink of <paramref name="text"/> set in <paramref name="font"/>; Missing when the font lacks a character of it.</summary>
    internal static Ink InkOf(string text, TrueTypeFont font)
    {
        if (_inks is { } known)
        {
            if (!known.TryGetValue((text, font), out var ink)) known[(text, font)] = ink = Measured(text, font);
            return ink;
        }
        return Measured(text, font);
    }

    private static Ink Measured(string text, TrueTypeFont font)
    {
        var line = TextShaper.Shape(text, font, visualOrder: true);
        double left = double.MaxValue, right = double.MinValue, top = double.MinValue, bottom = double.MaxValue;
        var missing = false;
        foreach (var g in line.Glyphs)
        {
            missing |= !ReferenceEquals(g.Font, font) || g.Glyph == 0;
            if (!g.Font.HbFont.TryGetGlyphExtents((uint)g.Glyph, out var e) || e.Width == 0) continue;
            var upem = g.Font.UnitsPerEm;
            left = Math.Min(left, g.X + e.XBearing / upem);
            right = Math.Max(right, g.X + (e.XBearing + e.Width) / upem);
            top = Math.Max(top, g.Y + e.YBearing / upem);
            bottom = Math.Min(bottom, g.Y + (e.YBearing + e.Height) / upem);
        }
        return left > right ? new Ink(0, line.Width, 0.7, 0, true) : new Ink(left, right, top, bottom, missing);
    }

    /// <summary>
    /// The page's recognized words as lines to write: grouped by angle and height into lines, the family that fits them
    /// best chosen, each line's size, baseline and boldness measured, its paragraph's lines made alike. Null when no
    /// installed family is there to write in.
    /// </summary>
    /// <param name="resemblance">How much a font set where the words are looks like the scan (null: by measure alone).</param>
    internal static PagePlan? Plan(IReadOnlyList<OcrWord> recognized, Func<TrueTypeFont, List<PlanLine>, bool, double>? resemblance = null)
    {
        _inks = [];
        try
        {
            return Planned(recognized, resemblance);
        }
        finally
        {
            _inks = null;
        }
    }

    private static PagePlan? Planned(IReadOnlyList<OcrWord> recognized, Func<TrueTypeFont, List<PlanLine>, bool, double>? resemblance)
    {
        var words = recognized.Where(w => w.Text.Trim() is { Length: > 0 and <= MaxWordLength } && w.Rect.Width > 0 && w.Rect.Height > 0
                                          && double.IsFinite(w.Angle) && double.IsFinite(w.Rect.X) && double.IsFinite(w.Rect.Y)).Take(MaxWords).ToList();
        if (words.Count == 0) return null;
        var lines = new List<PlanLine>();
        foreach (var group in ByAngle(words)) lines.AddRange(LinesOf(group.Words, group.Angle));
        if (lines.Count == 0) return null;

        // Do the boxes hold each word's own ink, or the line's height for every word? Words in one line all as tall: the line's.
        var lineBoxes = LineBoxes(lines);
        var family = Choose(lines, lineBoxes, resemblance);
        if (family is null) return null;
        var regular = Face(family, false)!;
        foreach (var line in lines) Measure(line, regular, lineBoxes);
        var plan = new PagePlan(family, lines);
        Paragraphs(plan);

        // A line on its own may be set in another family or weight: it takes the face that fits it clearly better by
        // measure; a heading (a line on its own a sixth bigger than the body text or more, the first few on the page) the
        // face of them all that looks most like it.
        var inParagraphs = lines.GroupBy(l => l.Paragraph).Where(g => g.Count() >= 2).SelectMany(g => g).Select(l => l.Size).ToList();
        var bodySize = Median(inParagraphs.Count > 0 ? inParagraphs : [.. lines.Select(l => l.Size)]);
        var headings = 0;
        foreach (var alone in lines.GroupBy(l => l.Paragraph).Where(g => g.Count() == 1).Select(g => g.First()))
        {
            if (alone.Words.Sum(w => w.Text.Count(char.IsLetter)) < 8) continue;
            var faces = Families.SelectMany(f => new[] { (Family: f, Bold: false), (Family: f, Bold: true) }).Where(x => Face(x.Family, x.Bold) is not null).ToList();
            var current = (Family: plan.FamilyOf(alone), Bold: alone.Bold && Face(plan.FamilyOf(alone), true) is not null);
            (Family Family, bool Bold) pick;
            if (resemblance is not null && alone.Size >= 1.15 * bodySize && headings++ < MaxHeadings)
            {
                double Look((Family Family, bool Bold) f) => resemblance(Face(f.Family, f.Bold)!, [alone], lineBoxes);
                var mine = Look(current);
                var best = faces.Select(f => (Face: f, Look: Look(f))).MaxBy(x => x.Look);
                if (best.Look <= mine + 0.02) continue;
                pick = best.Face;
            }
            else
            {
                var now = Misfit([alone], Face(current.Family, current.Bold)!, lineBoxes, 2);
                var best = faces.Select(f => (Face: f, Score: Misfit([alone], Face(f.Family, f.Bold)!, lineBoxes, 2))).MinBy(x => x.Score);
                if (best.Score + 0.04 >= now) continue;
                pick = best.Face;
            }
            alone.Family = pick.Family == family ? null : pick.Family;
            alone.Bold = pick.Bold;
            Measure(alone, plan.FaceOf(alone), lineBoxes);
        }
        return plan;
    }

    /// <summary>Words of about one angle (within half a degree of the next), each group with its middle angle.</summary>
    private static IEnumerable<(double Angle, List<OcrWord> Words)> ByAngle(List<OcrWord> words)
    {
        var sorted = words.OrderBy(w => w.Angle).ToList();
        var group = new List<OcrWord> { sorted[0] };
        foreach (var w in sorted.Skip(1))
        {
            if (w.Angle - group[^1].Angle > 0.5)
            {
                yield return (group[group.Count / 2].Angle, group);
                group = [];
            }
            group.Add(w);
        }
        yield return (group[group.Count / 2].Angle, group);
    }

    /// <summary>A page point turned back by <paramref name="angle"/> about the page's top left (into the frame where the text is level).</summary>
    private static (double X, double Y) ToFrame(double angle, double x, double y)
    {
        var (sin, cos) = Math.SinCos(-angle * Math.PI / 180);
        return (x * cos - y * sin, x * sin + y * cos);
    }

    /// <summary>A frame point back on the page.</summary>
    private static (double X, double Y) ToPage(double angle, double x, double y)
    {
        var (sin, cos) = Math.SinCos(angle * Math.PI / 180);
        return (x * cos - y * sin, x * sin + y * cos);
    }

    /// <summary>Words on one band of height, left to right, split where a gap is a column's (over twice the line's height).</summary>
    private static List<PlanLine> LinesOf(List<OcrWord> words, double angle)
    {
        var framed = words.Select(w =>
        {
            var (cx, cy) = ToFrame(angle, w.Rect.CenterX, w.Rect.CenterY);
            // A box around ink read at 300 dpi misses about half a pixel at each edge (the edges are lighter than ink): put back.
            var (hw, hh) = (w.Rect.Width / 2 + EdgeLoss, w.Rect.Height / 2 + EdgeLoss);
            return new PlanWord(w.Text.Trim(), cx - hw, cx + hw, cy - hh, cy + hh);
        }).OrderBy(w => (w.Top + w.Bottom) / 2).ToList();
        var lines = new List<PlanLine>();
        for (var i = 0; i < framed.Count;)
        {
            var band = new List<PlanWord> { framed[i] };
            var (top, bottom) = (framed[i].Top, framed[i].Bottom);
            var j = i + 1;
            // A word whose middle is inside the band's middle half joins it.
            for (; j < framed.Count; j++)
            {
                var mid = (framed[j].Top + framed[j].Bottom) / 2;
                var h = bottom - top;
                if (mid > bottom - 0.25 * h) break;
                band.Add(framed[j]);
                (top, bottom) = (Math.Min(top, framed[j].Top), Math.Max(bottom, framed[j].Bottom));
            }
            i = j;
            var height = band.Select(w => w.Height).Order().ElementAt(band.Count / 2);
            List<PlanWord>? line = null;
            foreach (var w in band.OrderBy(w => w.Left))
            {
                if (line is null || w.Left - line[^1].Right > 2.5 * height)
                {
                    line = [];
                    lines.Add(new PlanLine(line, angle));
                }
                line.Add(w);
            }
        }
        return lines;
    }

    /// <summary>Whether the recognizer boxed each word by its line's height (Windows' boxes are a word's own ink; a line box would make every word as tall).</summary>
    private static bool LineBoxes(List<PlanLine> lines)
    {
        var spreads = lines.Where(l => l.Words.Count >= 3).Select(l =>
        {
            var heights = l.Words.Select(w => w.Height).ToList();
            var mean = heights.Average();
            return Math.Sqrt(heights.Average(h => (h - mean) * (h - mean))) / mean;
        }).ToList();
        return spreads.Count > 0 && spreads.Average() < 0.03;
    }

    /// <summary>
    /// A word's size in a font: by its width (its box's width over its ink's in the font: many pixels, so the surest),
    /// unless that is far from what its height says (a word read short or long) or it has under two letters.
    /// </summary>
    private static double SizeOf(PlanWord word, PlanLine line, TrueTypeFont font, bool lineBoxes)
    {
        var byHeight = SizeByHeight(word, line, font, lineBoxes);
        var ink = InkOf(word.Text, font);
        if (ink.Missing || ink.Width <= 0.05 || word.Text.Count(char.IsLetterOrDigit) < 2) return byHeight;
        var byWidth = word.Width / ink.Width;
        return double.IsFinite(byHeight) && byHeight > 0 && Math.Abs(Math.Log(byWidth / byHeight)) > 0.25 ? byHeight : byWidth;
    }

    /// <summary>A word's size by its height in a font: its own ink's, or (line boxes) its line's text's.</summary>
    private static double SizeByHeight(PlanWord word, PlanLine line, TrueTypeFont font, bool lineBoxes)
    {
        var ink = InkOf(lineBoxes ? line.Text : word.Text, font);
        return ink.Height > 0.05 ? word.Height / ink.Height : double.NaN;
    }

    /// <summary>
    /// How badly words fit a font: the median of |ln(size by width ÷ size by height)| over the words of
    /// <paramref name="minLetters"/> letters or digits or more, and with boxes of each word's own ink, the median of how far each
    /// word's size by height is from its line's (a font whose ascenders and x-height are another's gives a line's words
    /// different sizes).
    /// </summary>
    internal static double Misfit(IEnumerable<PlanLine> lines, TrueTypeFont font, bool lineBoxes, int minLetters)
    {
        var widths = new List<double>();
        var heights = new List<double>();
        foreach (var line in lines)
        {
            var sizes = new List<double>();
            foreach (var w in line.Words.Where(w => w.Text.Count(char.IsLetterOrDigit) >= minLetters))
            {
                var ink = InkOf(w.Text, font);
                var byHeight = SizeByHeight(w, line, font, lineBoxes);
                if (ink.Missing || ink.Width <= 0.05 || !(byHeight > 0) || !double.IsFinite(byHeight)) continue;
                widths.Add(Math.Abs(Math.Log(w.Width / ink.Width / byHeight)));
                sizes.Add(byHeight);
            }
            if (!lineBoxes && sizes.Count >= 2)
            {
                var middle = Median(sizes);
                heights.AddRange(sizes.Select(x => Math.Abs(Math.Log(x / middle))));
            }
        }
        return widths.Count == 0 ? double.MaxValue : Median(widths) + (heights.Count > 0 ? Median(heights) : 0);
    }

    private static double Median(List<double> values) => values.Order().ElementAt(values.Count / 2);

    /// <summary>
    /// The installed family whose regular face fits the page's words best: by measure (<see cref="Misfit"/> over its words of
    /// three letters or more: a box's height and width are a few percent off, as much as faces differ, so this only rules
    /// out faces far off), then among those by how much the words set in it look like the scan (<paramref name="resemblance"/>:
    /// serif or not, weight and shape tell faces apart that measure alike).
    /// </summary>
    private static Family? Choose(List<PlanLine> lines, bool lineBoxes, Func<TrueTypeFont, List<PlanLine>, bool, double>? resemblance)
    {
        var ranked = Families.Where(f => Face(f, false) is not null)
            .Select(f => (Family: f, Score: Misfit(lines, Face(f, false)!, lineBoxes, 3))).OrderBy(r => r.Score).ToList();
        if (ranked.Count == 0) return null;
        if (resemblance is null || ranked[0].Score == double.MaxValue) return ranked[0].Family;
        var close = ranked.Where(r => r.Score <= MaxMisfit).ToList();
        return close.Count < 2 ? ranked[0].Family : close.MaxBy(r => resemblance(Face(r.Family, false)!, lines, lineBoxes)).Family;
    }

    /// <summary>A line's size (the median of its words'), baseline (the median of where each word's ink puts it) and where each word's text starts.</summary>
    private static void Measure(PlanLine line, TrueTypeFont font, bool lineBoxes)
    {
        var sizes = line.Words.Select(w => SizeOf(w, line, font, lineBoxes)).Where(s => double.IsFinite(s) && s > 0).Order().ToList();
        var size = sizes.Count > 0 ? sizes[sizes.Count / 2] : line.Words.Average(w => w.Height) / 0.72;
        line.Size = Math.Round(Math.Clamp(size, 1, 500), 2);
        var lineInk = InkOf(line.Text, font);
        var baselines = line.Words.Select(w => w.Bottom + (lineBoxes ? lineInk.Bottom : InkOf(w.Text, font).Bottom) * line.Size).Order().ToList();
        line.Baseline = baselines[baselines.Count / 2];
        foreach (var w in line.Words) w.Pen = w.Left - InkOf(w.Text, font).Left * line.Size;
    }

    /// <summary>
    /// Lines one under the other in the same look (bold or not, size within 15%, a step of 0.9 to 2.5 sizes, steady, left
    /// edges or a first-line indent lined up) are a paragraph; its lines take one size, an even step and one left edge
    /// where they are near it, as Edit Text &amp; Images then reads them as one paragraph.
    /// </summary>
    private static void Paragraphs(PagePlan plan)
    {
        var paragraphs = new List<List<PlanLine>>();
        foreach (var angleGroup in plan.Lines.GroupBy(l => l.Angle))
        {
            var open = new List<List<PlanLine>>();
            foreach (var line in angleGroup.OrderBy(l => l.Baseline).ThenBy(l => l.Left))
            {
                // A paragraph whose last line is far above takes no more: a crafted page's thousands of lines don't each try every one.
                open.RemoveAll(p => line.Baseline - p[^1].Baseline > 3 * Math.Max(line.Size, p[^1].Size));
                List<PlanLine>? best = null;
                var bestStep = double.MaxValue;
                foreach (var p in open)
                {
                    var last = p[^1];
                    var size = Math.Max(last.Size, line.Size);
                    var step = line.Baseline - last.Baseline;
                    if (last.Bold != line.Bold || Math.Abs(last.Size - line.Size) > 0.15 * size) continue;
                    if (step < 0.9 * size || step > 2.5 * size || line.Left >= last.Right || line.Right <= last.Left) continue;
                    if (p.Count >= 2 && Math.Abs(step - (last.Baseline - p[^2].Baseline)) > 0.2 * size) continue;
                    var left = p.Count >= 2 ? p[1].Left : last.Left;
                    var indent = p.Count == 1 && last.Left - line.Left >= 0.5 * size && last.Left - line.Left <= 8 * size;
                    if (Math.Abs(line.Left - left) > size && !indent) continue;
                    if (step < bestStep) (best, bestStep) = (p, step);
                }
                if (best is null)
                {
                    best = [];
                    open.Add(best);
                    paragraphs.Add(best);
                }
                best.Add(line);
            }
        }
        for (var i = 0; i < paragraphs.Count; i++)
        {
            var p = paragraphs[i];
            foreach (var l in p) l.Paragraph = i;
            if (p.Count < 2) continue;
            var size = Math.Round(p.Select(l => l.Size).Order().ElementAt(p.Count / 2), 1);
            foreach (var l in p)
            {
                // The words keep their places: their text grows or shrinks about each box's left.
                var scale = size / l.Size;
                foreach (var w in l.Words) w.Pen = w.Left - (w.Left - w.Pen) * scale;
                l.Size = size;
            }
            // An even step: the baselines' straight fit, when every line is near it.
            if (PlanFit(p) is { } fit) for (var k = 0; k < p.Count; k++) p[k].Baseline = fit.First + k * fit.Step;
            // One left edge for the lines after the first (and the first too unless it is indented).
            var lefts = p.Skip(1).Select(l => l.Left).Order().ToList();
            var edge = lefts[lefts.Count / 2];
            foreach (var l in p)
                if (Math.Abs(l.Left - edge) <= 0.6 * size) l.Words[0].Pen = edge;
        }
    }

    private static (double First, double Step)? PlanFit(List<PlanLine> p)
    {
        var n = p.Count;
        var meanK = (n - 1) / 2.0;
        var meanB = p.Average(l => l.Baseline);
        double sxy = 0, sxx = 0;
        for (var k = 0; k < n; k++)
        {
            sxy += (k - meanK) * (p[k].Baseline - meanB);
            sxx += (k - meanK) * (k - meanK);
        }
        var step = sxy / sxx;
        var first = meanB - step * meanK;
        return Enumerable.Range(0, n).All(k => Math.Abs(p[k].Baseline - (first + k * step)) <= 0.25 * p[k].Size) ? (first, step) : null;
    }

    // ---- Writing ----

    /// <summary>A line's glyphs: each word from its place, a space between words (narrowed to half when the words are close, never overlapping).</summary>
    private static ShapedLine Shape(PlanLine line, TrueTypeFont font)
    {
        var size = line.Size;
        var space = TextShaper.Shape(" ", font);
        var spaceGlyph = space.Glyphs.Count > 0 ? space.Glyphs[0] : default;
        var glyphs = new List<PlacedGlyph>();
        var origin = line.Left;
        double end = 0; // points from the line's start
        for (var i = 0; i < line.Words.Count; i++)
        {
            var word = line.Words[i];
            var start = word.Pen - origin;
            if (i > 0)
            {
                if (space.Glyphs.Count > 0) glyphs.Add(spaceGlyph with { X = end / size });
                start = Math.Max(start, end + 0.5 * space.Width * size);
            }
            else start = 0;
            var shaped = TextShaper.Shape(word.Text, font, visualOrder: true);
            foreach (var g in shaped.Glyphs) glyphs.Add(g with { X = g.X + start / size });
            end = start + shaped.Width * size;
        }
        return new ShapedLine(line.Text, glyphs, end / size, false);
    }

    /// <summary>The page's lines as text after its content (the scan covered behind each line in <paramref name="papers"/>' colour, when given).</summary>
    private static void Write(PdfDocument doc, PdfPage page, PagePlan plan, (double R, double G, double B)[]? papers)
    {
        var fonts = PdfObj.Dict(PdfObj.Dict(page.Elements["/Resources"])?.Elements["/Font"]);
        var prefix = "/InkTx";
        for (var n = 1; fonts is not null && fonts.Elements.Keys.Any(k => k.StartsWith(prefix, StringComparison.Ordinal)); n++) prefix = $"/InkTx{n}_";
        var writer = new CidFontWriter(prefix);
        var ops = new StringBuilder("q\n");
        var shaped = plan.Lines.Select(l => Shape(l, plan.FaceOf(l))).ToList();

        if (papers is not null)
            for (var i = 0; i < plan.Lines.Count; i++)
            {
                var line = plan.Lines[i];
                var (r, g, b) = papers[i];
                ops.Append(CultureInfo.InvariantCulture, $"{PdfObj.F(r)} {PdfObj.F(g)} {PdfObj.F(b)} rg ");
                var corners = Cover(line, shaped[i], plan.FaceOf(line)).Select(c => PdfObj.ToPdf(page, c.X, c.Y)).ToList();
                ops.Append(CultureInfo.InvariantCulture, $"{PdfObj.F(corners[0].X)} {PdfObj.F(corners[0].Y)} m ");
                foreach (var c in corners.Skip(1)) ops.Append(CultureInfo.InvariantCulture, $"{PdfObj.F(c.X)} {PdfObj.F(c.Y)} l ");
                ops.Append("h f\n");
            }

        ops.Append("0 g BT 0 Tr 0 Tc 0 Tw 100 Tz 0 Ts\n");
        for (var i = 0; i < plan.Lines.Count; i++)
        {
            var line = plan.Lines[i];
            var (sin, cos) = Math.SinCos(line.Angle * Math.PI / 180);
            var (px, py) = ToPage(line.Angle, line.Left, line.Baseline);
            var o = PdfObj.ToPdf(page, px, py);
            var u = PdfObj.ToPdf(page, px + cos, py + sin); // along the line
            var v = PdfObj.ToPdf(page, px + sin, py - cos); // up
            ops.Append(CultureInfo.InvariantCulture,
                $"{PdfObj.F(u.X - o.X)} {PdfObj.F(u.Y - o.Y)} {PdfObj.F(v.X - o.X)} {PdfObj.F(v.Y - o.Y)} {PdfObj.F(o.X)} {PdfObj.F(o.Y)} Tm ");
            writer.Emit(ops, shaped[i], line.Size);
            ops.Append('\n');
        }
        ops.Append("ET Q\n");

        var resources = PdfObj.Dict(page.Elements["/Resources"]);
        if (resources is null)
        {
            resources = new PdfDictionary(doc);
            page.Elements["/Resources"] = resources;
        }
        if (fonts is null)
        {
            fonts = new PdfDictionary(doc);
            resources.Elements["/Font"] = fonts;
        }
        foreach (var (name, f) in writer.BuildFonts(doc).Elements) fonts.Elements[name] = f;

        // After the page's content, which is closed in q…Q first so nothing it leaves set reaches the text.
        var contents = new PdfArray(doc);
        contents.Elements.Add(PdfObj.AddStream(doc, "q\n"u8.ToArray(), compress: false).Reference!);
        switch (page.Elements["/Contents"])
        {
            case PdfReference { Value: PdfArray content }:
                foreach (var e in content.Elements) contents.Elements.Add(e);
                break;
            case PdfArray content:
                foreach (var e in content.Elements) contents.Elements.Add(e);
                break;
            case PdfReference r:
                contents.Elements.Add(r);
                break;
        }
        contents.Elements.Add(PdfObj.AddStream(doc, "\nQ\n"u8.ToArray(), compress: false).Reference!);
        contents.Elements.Add(PdfObj.AddStream(doc, Encoding.ASCII.GetBytes(ops.ToString())).Reference!);
        page.Elements["/Contents"] = contents;
        page.Elements.Remove("/Thumb");
    }

    /// <summary>
    /// The four corners (page points) of what covers the scan behind a line: its words' boxes and its new text's ink,
    /// a tenth of its size around.
    /// </summary>
    private static (double X, double Y)[] Cover(PlanLine line, ShapedLine shaped, TrueTypeFont font)
    {
        var ink = InkOf(line.Text, font);
        var pad = 0.1 * line.Size;
        var left = Math.Min(line.Words.Min(w => w.Left), line.Left) - pad;
        var right = Math.Max(line.Right, line.Left + shaped.Width * line.Size) + pad;
        var top = Math.Min(line.Top, line.Baseline - ink.Top * line.Size) - pad;
        var bottom = Math.Max(line.Bottom, line.Baseline - ink.Bottom * line.Size) + pad;
        return [ToPage(line.Angle, left, top), ToPage(line.Angle, right, top), ToPage(line.Angle, right, bottom), ToPage(line.Angle, left, bottom)];
    }

    /// <summary>
    /// The paper's colour behind each line: the page drawn small, the brightest part of what is under the line (the
    /// pixels at or above its 85th percentile of lightness), averaged.
    /// </summary>
    private static (double R, double G, double B)[] PaperBehind(PdfEngine engine, int page, PagePlan plan, CancellationToken cancel)
    {
        var g = engine.GetPage(page);
        var scale = Math.Min(0.5, Math.Sqrt(4_000_000 / Math.Max(1, g.Width * g.Height)));
        var image = engine.Render(page, scale, null, cancel, annotations: false);
        var result = new (double, double, double)[plan.Lines.Count];
        for (var i = 0; i < plan.Lines.Count; i++)
        {
            var line = plan.Lines[i];
            var corners = Cover(line, Shape(line, plan.FaceOf(line)), plan.FaceOf(line));
            var (x0, x1) = ((int)Math.Floor(corners.Min(c => c.X) * scale), (int)Math.Ceiling(corners.Max(c => c.X) * scale));
            var (y0, y1) = ((int)Math.Floor(corners.Min(c => c.Y) * scale), (int)Math.Ceiling(corners.Max(c => c.Y) * scale));
            (x0, x1, y0, y1) = (Math.Clamp(x0, 0, image.Width), Math.Clamp(x1, 0, image.Width), Math.Clamp(y0, 0, image.Height), Math.Clamp(y1, 0, image.Height));
            var pixels = new List<(int Light, int B, int G, int R)>();
            for (var y = y0; y < y1; y++)
                for (var x = x0; x < x1; x++)
                {
                    var o = y * image.Stride + x * 3;
                    int b = image.Pixels[o], gg = image.Pixels[o + 1], r = image.Pixels[o + 2];
                    pixels.Add(((b * 29 + gg * 150 + r * 77) >> 8, b, gg, r));
                }
            if (pixels.Count == 0)
            {
                result[i] = (1, 1, 1);
                continue;
            }
            var bright = pixels.OrderBy(p => p.Light).Skip(pixels.Count * 85 / 100).ToList();
            if (bright.Count == 0) bright = pixels;
            var (rr, gr, br) = (bright.Average(p => p.R) / 255, bright.Average(p => p.G) / 255, bright.Average(p => p.B) / 255);
            // Nearly white paper is white.
            result[i] = Math.Min(rr, Math.Min(gr, br)) >= 0.96 ? (1, 1, 1) : (Math.Round(rr, 3), Math.Round(gr, 3), Math.Round(br, 3));
        }
        return result;
    }

    /// <summary>
    /// A scanned page drawn in grey at about 150 dpi, to compare fonts with: some of its words are set in a font where the
    /// scan has them, drawn the same way, and the two pictures correlated over the words' boxes.
    /// </summary>
    internal sealed class ScanLook(PdfEngine engine, int page, CancellationToken cancel)
    {
        /// <summary>The words compared (spread over the page).</summary>
        public const int Samples = 40;

        private readonly (double W, double H) _size = (engine.GetPage(page).Width, engine.GetPage(page).Height);
        private double Scale => Math.Min(150 / 72.0, Math.Sqrt(6_000_000 / Math.Max(1, _size.W * _size.H)));
        private byte[]? _scan;
        private (int W, int H) _pixels;

        private byte[] Gray(RenderedImage image)
        {
            _pixels = (image.Width, image.Height);
            var gray = new byte[image.Width * image.Height];
            for (var i = 0; i < gray.Length; i++)
                gray[i] = (byte)((image.Pixels[3 * i] * 29 + image.Pixels[3 * i + 1] * 150 + image.Pixels[3 * i + 2] * 77) >> 8);
            return gray;
        }

        public double Resemblance(TrueTypeFont font, List<PlanLine> lines, bool lineBoxes)
        {
            var words = lines.SelectMany(l => l.Words.Where(w => w.Text.Count(char.IsLetter) >= 4).Select(w => (Line: l, Word: w))).ToList();
            if (words.Count == 0) return 0;
            var sample = Enumerable.Range(0, Math.Min(Samples, words.Count)).Select(i => words[i * words.Count / Math.Min(Samples, words.Count)]).ToList();
            _scan ??= Gray(engine.Render(page, Scale, null, cancel, annotations: false));

            // The sample set in the font, each word at the size and place its box gives in it, on a blank page of this size.
            using var doc = new PdfDocument();
            var p = doc.AddPage();
            p.Width = PdfSharp.Drawing.XUnit.FromPoint(_size.W);
            p.Height = PdfSharp.Drawing.XUnit.FromPoint(_size.H);
            var writer = new CidFontWriter("/F");
            var ops = new StringBuilder("0 g BT\n");
            var boxes = new List<(double X0, double Y0, double X1, double Y1)>();
            foreach (var (line, word) in sample)
            {
                var ink = InkOf(word.Text, font);
                var lineInk = lineBoxes ? InkOf(line.Text, font) : ink;
                var size = SizeOf(word, line, font, lineBoxes);
                if (ink.Missing || !(size > 0) || !double.IsFinite(size)) continue;
                var baseline = word.Bottom + lineInk.Bottom * size;
                var (px, py) = ToPage(line.Angle, word.Left - ink.Left * size, baseline);
                var (sin, cos) = Math.SinCos(line.Angle * Math.PI / 180);
                ops.Append(CultureInfo.InvariantCulture, $"{PdfObj.F(cos)} {PdfObj.F(-sin)} {PdfObj.F(sin)} {PdfObj.F(cos)} {PdfObj.F(px)} {PdfObj.F(_size.H - py)} Tm ");
                writer.Emit(ops, TextShaper.Shape(word.Text, font, visualOrder: true), size);
                ops.Append('\n');
                var corners = new[] { (word.Left, word.Top), (word.Right, word.Top), (word.Right, word.Bottom), (word.Left, word.Bottom) }.Select(c => ToPage(line.Angle, c.Item1, c.Item2)).ToList();
                // Around the box by a third of its height: a face too wide or too narrow shows there.
                var margin = 1 + word.Height / 3;
                boxes.Add((corners.Min(c => c.X) - margin, corners.Min(c => c.Y) - 1, corners.Max(c => c.X) + margin, corners.Max(c => c.Y) + 1));
            }
            if (boxes.Count == 0) return 0;
            ops.Append("ET\n");
            var resources = new PdfDictionary(doc);
            resources.Elements["/Font"] = writer.BuildFonts(doc);
            p.Elements["/Resources"] = resources;
            p.Elements["/Contents"] = PdfObj.AddStream(doc, Encoding.ASCII.GetBytes(ops.ToString())).Reference!;
            using var set = PdfEngine.Open(PdfObj.Save(doc), InputFileTypes.PDF, null);
            var drawn = Gray(set.Render(0, Scale, null, cancel, annotations: false));

            // Pearson's correlation over the words' boxes (each pixel once).
            var (w, h) = _pixels;
            var seen = new bool[w * h];
            double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0, paperA = 0, paperB = 0; // paper: the lightest each shows there
            long n = 0;
            foreach (var (x0, y0, x1, y1) in boxes)
                for (var y = Math.Max(0, (int)(y0 * Scale)); y < Math.Min(h, (int)Math.Ceiling(y1 * Scale)); y++)
                    for (var x = Math.Max(0, (int)(x0 * Scale)); x < Math.Min(w, (int)Math.Ceiling(x1 * Scale)); x++)
                    {
                        var i = y * w + x;
                        if (seen[i] || i >= drawn.Length || i >= _scan.Length) continue;
                        seen[i] = true;
                        double a = _scan[i], b = drawn[i];
                        (sx, sy, sxx, syy, sxy, n) = (sx + a, sy + b, sxx + a * a, syy + b * b, sxy + a * b, n + 1);
                        (paperA, paperB) = (Math.Max(paperA, a), Math.Max(paperB, b));
                    }
            if (n < 2) return 0;
            var va = sxx - sx * sx / n;
            var vb = syy - sy * sy / n;
            if (va <= 0 || vb <= 0) return 0;
            // Less for ink of another weight: a regular face where the scan is bold covers less of it.
            var (inkScan, inkDrawn) = (paperA * n - sx, paperB * n - sy);
            var weight = inkScan > 0 && inkDrawn > 0 ? Math.Abs(Math.Log(inkDrawn / inkScan)) : 1;
            return (sxy - sx * sy / n) / Math.Sqrt(va * vb) - weight;
        }
    }
}
