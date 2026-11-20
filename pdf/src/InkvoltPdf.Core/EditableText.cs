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
/// words carry none (<see cref="FontMatch"/>): the scan's class (serif, sans serif or monospaced) from the common
/// families, then of every installed family of that class whose glyphs' proportions fit the words' boxes, the one whose
/// words, drawn small at the scan's size, look most like the scan's; each paragraph then takes the face of that family
/// (regular, bold, italic, bold italic) that looks most like it, and a heading the face of any family short-listed. Each
/// paragraph is drawn in its ink's colour. Each line takes the size and baseline its words' boxes give in its face, each
/// word starts where the scan has it. Lines of a paragraph get one size, a steady line step and their left edges lined up,
/// as 2.1 groups a paragraph. The scan is covered behind each line with the paper's own colour (or left showing), and the
/// invisible layer goes.
/// </summary>
public static class EditableText
{
    /// <summary>More recognized words than this on a page is a crafted layer: only this many are made text.</summary>
    public const int MaxWords = 20_000;

    /// <summary>What a recognized word's box misses of its ink at each edge (points): half a pixel at 300 dpi, the resolution Recognize Text reads at.</summary>
    internal const double EdgeLoss = 0.12;

    /// <summary>A family whose measures miss the words by more than this (<see cref="Misfit"/>) isn't compared by look.</summary>
    internal const double MaxMisfit = 0.2;

    /// <summary>The most headings a page compares the short-listed faces with.</summary>
    public const int MaxHeadings = 6;

    /// <summary>A recognized word longer than this (characters) is no word: left out.</summary>
    public const int MaxWordLength = 200;

    /// <summary>A font file larger than this (a CJK collection) isn't tried: its look is no Latin text's.</summary>
    internal const long MaxFontFile = 4_000_000;

    /// <summary>
    /// How much more like the scan another family must look than a common one to be chosen: print is mostly set in the
    /// common families, and at 150 dpi faces of one design (Times New Roman, Baskerville) look alike within this.
    /// </summary>
    internal const double CommonFirst = 0.03;

    /// <summary>A page's family is judged on the words that look most like it, this share of them: a page's italic or bold words look like no regular face.</summary>
    internal const double FamilyShare = 0.6;

    /// <summary>Of the installed families of the scan's class, at most this many are measured (the common ones first).</summary>
    internal const int MaxCandidates = 24;

    /// <summary>A face's style.</summary>
    [Flags]
    internal enum Style { Regular = 0, Bold = 1, Italic = 2, BoldItalic = 3 }

    /// <summary>An installed family: its name, its name in the PDF ("TimesNewRoman"), class and each face's file.</summary>
    internal sealed record Family(string Name, string Pdf, StandInFonts.Kind Kind, string Regular, string? Bold, string? Italic, string? BoldItalic, bool Common)
    {
        public string? File(Style style) => style switch
        {
            Style.Bold => Bold,
            Style.Italic => Italic,
            Style.BoldItalic => BoldItalic,
            _ => Regular,
        };
    }

    /// <summary>Every installed family to match against, the common ones first (file sizes checked, not the files read).</summary>
    internal static IReadOnlyList<Family> Families => FamiliesOnce.Value;

    private static readonly Lazy<List<Family>> FamiliesOnce = new(() =>
        [.. StandInFonts.AllFamilies()
            .Where(f => SystemFonts.Size(f.Regular) is { } size && size <= MaxFontFile)
            .Select(f => new Family(f.Name, new string([.. f.Name.Where(char.IsAsciiLetterOrDigit)]), f.Kind, f.Regular, f.Bold, f.Italic, f.BoldItalic, f.Common))]);

    /// <summary>The families a page with no picture to compare with is measured against: the common ones.</summary>
    private static IEnumerable<Family> Common => Families.Where(f => f.Common);

    private static readonly ConcurrentDictionary<(Family Family, Style Style), TrueTypeFont?> Loaded = new();

    /// <summary>An installed face under its family's PDF name ("TimesNewRoman", "ArialBoldItalic"), loaded once for the run; null when the family hasn't the style.</summary>
    internal static TrueTypeFont? Face(Family family, Style style) =>
        Loaded.GetOrAdd((family, style), key => key.Family.File(key.Style) is { } file && SystemFonts.Size(file) is { } size && size <= MaxFontFile
                                                && SystemFonts.Get(file) is { } font
            ? TrueTypeFont.Load(key.Family.Pdf + (key.Style == Style.Regular ? "" : key.Style.ToString()), font.Bytes)
            : null);

    /// <summary>A face's name as people know it ("Times New Roman Bold Italic").</summary>
    internal static string NameOf(Family family, Style style) => family.Name + style switch
    {
        Style.Bold => " Bold",
        Style.Italic => " Italic",
        Style.BoldItalic => " Bold Italic",
        _ => "",
    };

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
        var papers = new Dictionary<int, (double R, double G, double B)[]>();
        var match = new FontMatch(cancel);
        using (var engine = PdfEngine.Open(data, InputFileTypes.PDF, password))
            for (var i = 0; i < chosen.Count; i++)
            {
                cancel.ThrowIfCancellationRequested();
                progress?.Report((i, chosen.Count));
                var page = chosen[i];
                var look = new ScanLook(engine, page, match, cancel);
                if (Plan(layers[page].Words, look) is not { Lines.Count: > 0 } plan) continue;
                plans[page] = plan;
                // The paper behind each line, from the page as it shows.
                if (!keepScan) papers[page] = [.. plan.Lines.Select(l => look.Paper(Cover(l, Shape(l, plan.FaceOf(l)), plan.FaceOf(l))))];
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
    /// the page's top left), size (points), baseline, face and colour, in frame coordinates.
    /// </summary>
    internal sealed class PlanLine(List<PlanWord> words, double angle)
    {
        public List<PlanWord> Words { get; } = words;
        public double Angle { get; } = angle;
        public double Size { get; set; }
        public double Baseline { get; set; }
        public Style Style { get; set; }
        public bool Bold => Style.HasFlag(Style.Bold);
        public bool Italic => Style.HasFlag(Style.Italic);
        /// <summary>A family of its own (a heading set apart from the page's text); null: the page's.</summary>
        public Family? Family { get; set; }
        /// <summary>Its ink's colour (0 to 1 each); black unless its paragraph's ink is clearly another.</summary>
        public (double R, double G, double B) Color { get; set; }
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

        /// <summary>The style a line is drawn in: its own when its family has that face, else regular.</summary>
        public Style StyleOf(PlanLine line) => Face(FamilyOf(line), line.Style) is not null ? line.Style : Style.Regular;

        public TrueTypeFont FaceOf(PlanLine line) => Face(FamilyOf(line), StyleOf(line))!;

        /// <summary>The face a line is drawn in, as people know it ("Times New Roman Bold").</summary>
        public string NameOf(PlanLine line) => EditableText.NameOf(FamilyOf(line), StyleOf(line));
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
    /// best chosen, each line's size and baseline measured, its paragraph's lines made alike, then each paragraph's face
    /// and colour taken from the scan (<paramref name="look"/>; without it, by measure among the common families, regular
    /// and black). Null when no installed family is there to write in.
    /// </summary>
    internal static PagePlan? Plan(IReadOnlyList<OcrWord> recognized, ScanLook? look = null)
    {
        _inks = [];
        try
        {
            return Planned(recognized, look);
        }
        finally
        {
            _inks = null;
        }
    }

    private static PagePlan? Planned(IReadOnlyList<OcrWord> recognized, ScanLook? look)
    {
        var words = recognized.Where(w => w.Text.Trim() is { Length: > 0 and <= MaxWordLength } && w.Rect.Width > 0 && w.Rect.Height > 0
                                          && double.IsFinite(w.Angle) && double.IsFinite(w.Rect.X) && double.IsFinite(w.Rect.Y)).Take(MaxWords).ToList();
        if (words.Count == 0) return null;
        var lines = new List<PlanLine>();
        foreach (var (angle, group) in ByAngle(words)) lines.AddRange(LinesOf(group, angle));
        if (lines.Count == 0) return null;

        // Do the boxes hold each word's own ink, or the line's height for every word? Words in one line all as tall: the line's.
        var lineBoxes = LineBoxes(lines);
        var family = Choose(lines, lineBoxes, look);
        if (family is null) return null;
        var regular = Face(family, Style.Regular)!;
        foreach (var line in lines) Measure(line, regular, lineBoxes);
        var plan = new PagePlan(family, lines);
        var paragraphs = Paragraphs(plan);
        if (look is null) return plan;

        // Each paragraph in the face of the family that looks most like it (bold, italic), a heading (a line on its own a
        // sixth bigger than the body text or more, the first few on the page) in that of any family short-listed; each in
        // its ink's colour. The faces' words are drawn together, once for the page.
        var inParagraphs = paragraphs.Where(p => p.Count >= 2).SelectMany(p => p).Select(l => l.Size).ToList();
        var bodySize = Median(inParagraphs.Count > 0 ? inParagraphs : [.. lines.Select(l => l.Size)]);
        var headings = paragraphs.Where(p => p.Count == 1 && p[0].Size >= 1.15 * bodySize && p[0].Words.Sum(w => w.Text.Count(char.IsLetter)) >= 6).Take(MaxHeadings).ToHashSet();
        var samples = paragraphs.ToDictionary(p => p, p => SampleOf(p, 10));
        List<(Family Family, Style Style)> FacesOf(IEnumerable<Family> families) =>
            [.. families.SelectMany(f => new[] { Style.Regular, Style.Bold, Style.Italic, Style.BoldItalic }.Select(s => (f, s))).Where(x => Face(x.Item1, x.Item2) is not null)];
        var bodyFaces = FacesOf([family]);
        var headingFaces = FacesOf(look.Match.HeadingFamilies(family));
        look.Draw([.. bodyFaces.SelectMany(x => samples.Where(kv => !headings.Contains(kv.Key)).SelectMany(kv => kv.Value).Select(s => (Face(x.Family, x.Style)!, s.Word.Text))),
                   .. headingFaces.SelectMany(x => headings.SelectMany(h => samples[h]).Select(s => (Face(x.Family, x.Style)!, s.Word.Text)))]);
        foreach (var p in paragraphs)
        {
            var sample = samples[p];
            // A paragraph of a word or two says too little to change its face (a heading may).
            if (sample.Count >= 3 || headings.Contains(p) && sample.Count > 0)
            {
                double Score((Family Family, Style Style) x) => look.Resemblance(Face(x.Family, x.Style)!, sample);
                var mine = Score((family, Style.Regular));
                var best = (headings.Contains(p) ? headingFaces : bodyFaces).Select(x => (Face: x, Score: Score(x))).MaxBy(x => x.Score);
                if (best.Score > mine + 0.03 && (best.Face.Family != family || best.Face.Style != Style.Regular))
                {
                    foreach (var l in p)
                    {
                        l.Family = best.Face.Family == family ? null : best.Face.Family;
                        l.Style = best.Face.Style;
                        Measure(l, plan.FaceOf(l), lineBoxes);
                    }
                    Regularize(p);
                }
            }
            var color = look.InkColor(p);
            foreach (var l in p) l.Color = color;
        }
        return plan;
    }

    /// <summary>Up to <paramref name="count"/> words of three letters or more of <paramref name="lines"/>, spread over them.</summary>
    internal static List<(PlanLine Line, PlanWord Word)> SampleOf(IEnumerable<PlanLine> lines, int count)
    {
        var all = lines.SelectMany(l => l.Words.Where(w => w.Text.Count(char.IsLetter) >= 3).Select(w => (Line: l, Word: w))).ToList();
        var n = Math.Min(count, all.Count);
        return [.. Enumerable.Range(0, n).Select(i => all[i * all.Count / n])];
    }

    /// <summary>
    /// Words of about one angle (within half a degree of the next, round the circle: an upside-down page's words read at
    /// 179.9° and −179.9° are one direction), each group with its middle angle.
    /// </summary>
    internal static List<(double Angle, List<OcrWord> Words)> ByAngle(List<OcrWord> words)
    {
        var sorted = words.OrderBy(w => Angles.Wrap(w.Angle)).ToList();
        var groups = new List<List<OcrWord>> { new() { sorted[0] } };
        foreach (var w in sorted.Skip(1))
        {
            if (Angles.Wrap(w.Angle) - Angles.Wrap(groups[^1][^1].Angle) > 0.5) groups.Add([]);
            groups[^1].Add(w);
        }
        // The last group and the first meet across ±180°.
        if (groups.Count > 1 && Math.Abs(Angles.Difference(groups[0][0].Angle, groups[^1][^1].Angle)) <= 0.5)
        {
            groups[0].InsertRange(0, groups[^1]);
            groups.RemoveAt(groups.Count - 1);
        }
        return [.. groups.Select(g =>
        {
            // The middle angle, measured from the group's first so the values don't jump at ±180°.
            var first = g[0].Angle;
            var middle = g.Select(w => first + Angles.Difference(w.Angle, first)).Order().ElementAt(g.Count / 2);
            return (Angles.Wrap(middle), g);
        })];
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
            var j = i + 1;
            // A word whose middle is within 0.4 of a word's usual height of the band's first words' middle joins it (a word
            // with ascenders, one with descenders and one of x-height alone sit about a quarter of that apart). The usual
            // height, not the band's: a word read too tall (two lines' ink in its box) doesn't swallow the next line.
            var bandMid = (framed[i].Top + framed[i].Bottom) / 2;
            var usual = framed[i].Height;
            for (; j < framed.Count; j++)
            {
                var mid = (framed[j].Top + framed[j].Bottom) / 2;
                // Its first words' median height (a crafted band of thousands isn't sorted again for each).
                if (band.Count < 16) usual = band.Select(w => w.Height).Append(framed[j].Height).Order().ElementAt(band.Count / 2);
                if (mid - bandMid > 0.4 * usual) break;
                band.Add(framed[j]);
                if (band.Count <= 3) bandMid = band.Average(w => (w.Top + w.Bottom) / 2);
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
    /// The installed family the page's text is set in. Without a picture, by measure (<see cref="Misfit"/>) among the
    /// common families. With one (<paramref name="look"/>): the scan's class from how the common serif, sans serif and
    /// monospaced families look against it; of that class's installed families (the common ones first, at most
    /// <see cref="MaxCandidates"/>), those whose measures fit (a box's height and width are a few percent off, as much as
    /// faces differ, so measure only rules out faces far off), the eight closest by measure compared by look. The best four
    /// are kept for the document's next pages, which compare only those.
    /// </summary>
    private static Family? Choose(List<PlanLine> lines, bool lineBoxes, ScanLook? look)
    {
        var measured = lines.Where(l => l.Words.Count >= 3).Take(8).ToList();
        if (measured.Count == 0) measured = lines;
        if (look is null)
            return Common.Where(f => Face(f, Style.Regular) is not null)
                .Select(f => (Family: f, Score: Misfit(measured, Face(f, Style.Regular)!, lineBoxes, 3))).MinBy(r => r.Score).Family;

        var sample = SampleOf(lines, ScanLook.Samples);
        if (sample.Count == 0) return look.Match.Shortlist?[0] ?? Common.FirstOrDefault(f => Face(f, Style.Regular) is not null);
        List<Family> Ranked(IEnumerable<Family> families)
        {
            var faces = families.Where(f => Face(f, Style.Regular) is not null).ToList();
            look.Draw([.. faces.SelectMany(f => sample.Select(s => (Face(f, Style.Regular)!, s.Word.Text)))]);
            return [.. faces.OrderByDescending(f => look.Resemblance(Face(f, Style.Regular)!, sample, FamilyShare) + (f.Common ? CommonFirst : 0))];
        }
        if (look.Match.Shortlist is { } kept) return Ranked(kept).FirstOrDefault();

        var representatives = new[] { StandInFonts.Kind.Serif, StandInFonts.Kind.Sans, StandInFonts.Kind.Mono }
            .Select(k => Common.FirstOrDefault(f => f.Kind == k && Face(f, Style.Regular) is not null)).OfType<Family>().ToList();
        if (representatives.Count == 0) return null;
        var kind = Ranked(representatives)[0].Kind;
        var candidates = Families.Where(f => f.Kind == kind).Take(MaxCandidates)
            .Select(f => (Family: f, Font: Face(f, Style.Regular))).Where(x => x.Font is not null)
            .Select(x => (x.Family, Score: Misfit(measured, x.Font!, lineBoxes, 3))).Where(x => x.Score <= MaxMisfit)
            .OrderBy(x => x.Score).Take(8).Select(x => x.Family).ToList();
        var ranked = candidates.Count > 0 ? Ranked(candidates) : Ranked(representatives.Where(f => f.Kind == kind));
        look.Match.Keep([.. ranked.Take(4)], representatives);
        return ranked.FirstOrDefault();
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
    /// Lines one under the other in the same look (size within 15%, a step of 0.9 to 2.5 sizes, steady, left edges or a
    /// first-line indent lined up) are a paragraph; its lines take one size, an even step and one left edge where they are
    /// near it, as Edit Text &amp; Images then reads them as one paragraph. The paragraphs, in the order found.
    /// </summary>
    private static List<List<PlanLine>> Paragraphs(PagePlan plan)
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
                    if (last.Style != line.Style || Math.Abs(last.Size - line.Size) > 0.15 * size) continue;
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
            foreach (var l in paragraphs[i]) l.Paragraph = i;
            Regularize(paragraphs[i]);
        }
        return paragraphs;
    }

    /// <summary>A paragraph's lines given one size, an even step and one left edge (and its first too unless indented).</summary>
    private static void Regularize(List<PlanLine> p)
    {
        if (p.Count < 2) return;
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
        var lefts = p.Skip(1).Select(l => l.Left).Order().ToList();
        var edge = lefts[lefts.Count / 2];
        foreach (var l in p)
            if (Math.Abs(l.Left - edge) <= 0.6 * size) l.Words[0].Pen = edge;
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

        ops.Append("BT 0 Tr 0 Tc 0 Tw 100 Tz 0 Ts\n");
        for (var i = 0; i < plan.Lines.Count; i++)
        {
            var line = plan.Lines[i];
            var (cr, cg, cb) = line.Color;
            ops.Append(CultureInfo.InvariantCulture, $"{PdfObj.F(cr)} {PdfObj.F(cg)} {PdfObj.F(cb)} rg ");
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
    /// What one Make Text Editable run keeps across its pages: each word drawn in each face (once, at
    /// <see cref="Em"/> pixels to the em), and the families short-listed on the first page with enough words, which the
    /// next pages compare alone.
    /// </summary>
    internal sealed class FontMatch(CancellationToken cancel)
    {
        /// <summary>The size words are drawn at to compare (pixels to the em).</summary>
        public const double Em = 40;

        /// <summary>The widest word drawn (pixels): a longer one is no word to compare.</summary>
        public const double MaxWidth = 2000;

        /// <summary>A word drawn: grey pixels around its ink, the ink's box in them.</summary>
        internal sealed record Drawn(byte[] Pixels, int Width, int Height, double InkLeft, double InkTop, double InkWidth, double InkHeight);

        private readonly Dictionary<(TrueTypeFont Font, string Text), Drawn?> _drawn = [];

        public List<Family>? Shortlist { get; private set; }

        private List<Family> _representatives = [];

        /// <summary>How many pictures were drawn (for the speed measure).</summary>
        public int Renders { get; private set; }

        public void Keep(List<Family> shortlist, List<Family> representatives)
        {
            Shortlist = shortlist;
            _representatives = representatives;
        }

        /// <summary>The families a heading may be set in: the short list, and the common serif, sans serif and monospaced.</summary>
        public IEnumerable<Family> HeadingFamilies(Family page) => new[] { page }.Concat(Shortlist ?? []).Concat(_representatives).Distinct();

        public Drawn? Get(TrueTypeFont font, string text) => _drawn.GetValueOrDefault((font, text));

        /// <summary>Draws every (face, word) not drawn yet, all on one picture: one render however many faces.</summary>
        public void Draw(IEnumerable<(TrueTypeFont Font, string Text)> wanted)
        {
            var missing = wanted.Distinct().Where(x => !_drawn.ContainsKey(x)).ToList();
            if (missing.Count == 0) return;
            const double pad = 8, rowHeight = 64, baselineAt = 46, pageWidth = 2400;
            var placed = new List<((TrueTypeFont Font, string Text) Key, Ink Ink, double X, double Baseline)>();
            double x = pad, row = 0;
            foreach (var key in missing)
            {
                var ink = InkOf(key.Text, key.Font);
                var width = (Math.Max(0, ink.Right) - Math.Min(0, ink.Left)) * Em + 2 * pad;
                if (ink.Missing || ink.Width <= 0 || width > MaxWidth)
                {
                    _drawn[key] = null;
                    continue;
                }
                if (x + width > pageWidth && x > pad) (x, row) = (pad, row + 1);
                placed.Add((key, ink, x - Math.Min(0, ink.Left) * Em, row * rowHeight + baselineAt));
                x += width;
            }
            if (placed.Count == 0) return;
            var height = (row + 1) * rowHeight + pad;

            using var doc = new PdfDocument();
            var p = doc.AddPage();
            p.Width = PdfSharp.Drawing.XUnit.FromPoint(pageWidth);
            p.Height = PdfSharp.Drawing.XUnit.FromPoint(height);
            var writer = new CidFontWriter("/F");
            var ops = new StringBuilder("0 g BT\n");
            foreach (var (key, _, px, baseline) in placed)
            {
                ops.Append(CultureInfo.InvariantCulture, $"1 0 0 1 {PdfObj.F(px)} {PdfObj.F(height - baseline)} Tm ");
                writer.Emit(ops, TextShaper.Shape(key.Text, key.Font, visualOrder: true), Em);
                ops.Append('\n');
            }
            ops.Append("ET\n");
            var resources = new PdfDictionary(doc);
            resources.Elements["/Font"] = writer.BuildFonts(doc);
            p.Elements["/Resources"] = resources;
            p.Elements["/Contents"] = PdfObj.AddStream(doc, Encoding.ASCII.GetBytes(ops.ToString())).Reference!;
            using var set = PdfEngine.Open(PdfObj.Save(doc), InputFileTypes.PDF, null);
            var image = set.Render(0, 1, null, cancel, annotations: false);
            Renders++;
            foreach (var (key, ink, px, baseline) in placed)
            {
                // The ink's box, a pixel around it.
                var (x0, x1) = ((int)Math.Floor(px + ink.Left * Em) - 1, (int)Math.Ceiling(px + ink.Right * Em) + 1);
                var (y0, y1) = ((int)Math.Floor(baseline - ink.Top * Em) - 1, (int)Math.Ceiling(baseline - ink.Bottom * Em) + 1);
                (x0, x1, y0, y1) = (Math.Clamp(x0, 0, image.Width), Math.Clamp(x1, 0, image.Width), Math.Clamp(y0, 0, image.Height), Math.Clamp(y1, 0, image.Height));
                var (w, h) = (x1 - x0, y1 - y0);
                if (w <= 0 || h <= 0)
                {
                    _drawn[key] = null;
                    continue;
                }
                var px2 = new byte[w * h];
                for (var y = 0; y < h; y++)
                    for (var xx = 0; xx < w; xx++)
                    {
                        var o = (y0 + y) * image.Stride + (x0 + xx) * 3;
                        px2[y * w + xx] = (byte)((image.Pixels[o] * 29 + image.Pixels[o + 1] * 150 + image.Pixels[o + 2] * 77) >> 8);
                    }
                _drawn[key] = new Drawn(px2, w, h, px + ink.Left * Em - x0, baseline - ink.Top * Em - y0, ink.Width * Em, ink.Height * Em);
            }
        }
    }

    /// <summary>
    /// A scanned page as it shows, drawn at about 150 dpi: its words compared with the same words drawn in a face
    /// (<see cref="Resemblance"/>), its ink's colour and its paper's.
    /// </summary>
    internal sealed class ScanLook(PdfEngine engine, int page, FontMatch match, CancellationToken cancel)
    {
        /// <summary>The words compared to choose the page's family (spread over the page).</summary>
        public const int Samples = 40;

        /// <summary>A word compared is brought to this height (pixels), with this much room around it.</summary>
        private const int CanvasHeight = 20, PadX = 3, PadY = 6;

        public FontMatch Match { get; } = match;

        private RenderedImage? _image;
        private double _scale;

        private RenderedImage Image
        {
            get
            {
                if (_image is not null) return _image;
                var g = engine.GetPage(page);
                _scale = Math.Min(150 / 72.0, Math.Sqrt(6_000_000 / Math.Max(1, g.Width * g.Height)));
                return _image = engine.Render(page, _scale, null, cancel, annotations: false);
            }
        }

        /// <summary>Draws (once for the run) what the next comparisons need.</summary>
        public void Draw(IEnumerable<(TrueTypeFont Font, string Text)> wanted) => Match.Draw(wanted);

        /// <summary>The scan's grey at a page point (bilinear; white off the page).</summary>
        private double GrayAt(double x, double y)
        {
            var img = Image;
            var (sx, sy) = (x * _scale - 0.5, y * _scale - 0.5);
            if (!(sx > -1 && sy > -1 && sx < img.Width && sy < img.Height)) return 255;
            var (x0, y0) = ((int)Math.Floor(sx), (int)Math.Floor(sy));
            var (fx, fy) = (sx - x0, sy - y0);
            double At(int a, int b)
            {
                if (a < 0 || b < 0 || a >= img.Width || b >= img.Height) return 255;
                var o = b * img.Stride + a * 3;
                return (img.Pixels[o] * 29 + img.Pixels[o + 1] * 150 + img.Pixels[o + 2] * 77) / 256.0;
            }
            return (At(x0, y0) * (1 - fx) + At(x0 + 1, y0) * fx) * (1 - fy) + (At(x0, y0 + 1) * (1 - fx) + At(x0 + 1, y0 + 1) * fx) * fy;
        }

        /// <summary>
        /// How much <paramref name="sample"/>'s words drawn in <paramref name="font"/> look like the scan's: each word's scan
        /// and its drawing brought to one height (the drawing scaled to the scan word's width, centred on its height, so a face
        /// with other proportions, slant or serifs shows), Pearson's correlation between them less how far the ink each covers
        /// differs (|ln| of the ratio: another weight); the mean over the words, or over the best <paramref name="share"/> of
        /// them (a page's family is judged on its words in that family's look, not on the italic or bold ones among them).
        /// Words not drawn (<see cref="Draw"/> first) aren't counted; −1 when none is.
        /// </summary>
        public double Resemblance(TrueTypeFont font, IReadOnlyList<(PlanLine Line, PlanWord Word)> sample, double share = 1)
        {
            var scores = new List<double>(sample.Count);
            foreach (var (line, word) in sample)
            {
                if (Match.Get(font, word.Text) is not { } d || word.Width <= 0 || word.Height <= 0) continue;
                var (scan, cw, paper) = Canvas(line, word);
                var k = cw / d.InkWidth;
                var (w, h) = (cw + 2 * PadX, CanvasHeight + 2 * PadY);
                double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0, inkScan = 0, inkDrawn = 0;
                var n = w * h;
                for (var j = 0; j < h; j++)
                    for (var i = 0; i < w; i++)
                    {
                        var ix = (i + 0.5 - PadX) / k + d.InkLeft - 0.5;
                        var iy = (j + 0.5 - (PadY + CanvasHeight / 2.0)) / k + d.InkTop + d.InkHeight / 2 - 0.5;
                        var b = Bilinear(d.Pixels, d.Width, d.Height, ix, iy);
                        var a = scan[j * w + i];
                        (sx, sy, sxx, syy, sxy) = (sx + a, sy + b, sxx + a * a, syy + b * b, sxy + a * b);
                        (inkScan, inkDrawn) = (inkScan + paper - a, inkDrawn + 255 - b);
                    }
                var va = sxx - sx * sx / n;
                var vb = syy - sy * sy / n;
                if (va <= 0 || vb <= 0) continue;
                var weight = inkScan > 0 && inkDrawn > 0 ? Math.Abs(Math.Log(inkDrawn / inkScan)) : 1;
                scores.Add((sxy - sx * sy / n) / Math.Sqrt(va * vb) - weight);
            }
            if (scores.Count == 0) return -1;
            return scores.OrderDescending().Take(Math.Max(1, (int)Math.Ceiling(scores.Count * share))).Average();
        }

        private readonly Dictionary<PlanWord, (double[] Pixels, int Width, double Paper)> _canvases = new(ReferenceEqualityComparer.Instance);

        /// <summary>A scan word brought to <see cref="CanvasHeight"/> (once a page, whatever the faces it is compared with), its width and its paper's grey.</summary>
        private (double[] Pixels, int Width, double Paper) Canvas(PlanLine line, PlanWord word)
        {
            if (_canvases.TryGetValue(word, out var known)) return known;
            var cw = Math.Clamp((int)Math.Round(CanvasHeight * word.Width / word.Height), 4, 240);
            var (w, h) = (cw + 2 * PadX, CanvasHeight + 2 * PadY);
            var scan = new double[w * h];
            var paper = 0.0;
            for (var j = 0; j < h; j++)
                for (var i = 0; i < w; i++)
                {
                    var fx = word.Left + (i + 0.5 - PadX) * word.Width / cw;
                    var fy = word.Top + (j + 0.5 - PadY) * word.Height / CanvasHeight;
                    var (px, py) = ToPage(line.Angle, fx, fy);
                    paper = Math.Max(paper, scan[j * w + i] = GrayAt(px, py));
                }
            return _canvases[word] = (scan, cw, paper);
        }

        private static double Bilinear(byte[] px, int w, int h, double x, double y)
        {
            var (x0, y0) = ((int)Math.Floor(x), (int)Math.Floor(y));
            var (fx, fy) = (x - x0, y - y0);
            double At(int a, int b) => a < 0 || b < 0 || a >= w || b >= h ? 255 : px[b * w + a];
            return (At(x0, y0) * (1 - fx) + At(x0 + 1, y0) * fx) * (1 - fy) + (At(x0, y0 + 1) * (1 - fx) + At(x0 + 1, y0 + 1) * fx) * fy;
        }

        /// <summary>The pixels inside a polygon's bounding box on the page, by lightness: per level, how many and their summed R, G, B.</summary>
        private void Collect(IEnumerable<(double X, double Y)> corners, long[] count, double[] r, double[] g, double[] b)
        {
            var img = Image;
            var list = corners.ToList();
            var (x0, x1) = ((int)Math.Floor(list.Min(c => c.X) * _scale), (int)Math.Ceiling(list.Max(c => c.X) * _scale));
            var (y0, y1) = ((int)Math.Floor(list.Min(c => c.Y) * _scale), (int)Math.Ceiling(list.Max(c => c.Y) * _scale));
            (x0, x1, y0, y1) = (Math.Clamp(x0, 0, img.Width), Math.Clamp(x1, 0, img.Width), Math.Clamp(y0, 0, img.Height), Math.Clamp(y1, 0, img.Height));
            for (var y = y0; y < y1; y++)
                for (var x = x0; x < x1; x++)
                {
                    var o = y * img.Stride + x * 3;
                    int bb = img.Pixels[o], gg = img.Pixels[o + 1], rr = img.Pixels[o + 2];
                    var light = (bb * 29 + gg * 150 + rr * 77) >> 8;
                    count[light]++;
                    (r[light], g[light], b[light]) = (r[light] + rr, g[light] + gg, b[light] + bb);
                }
        }

        /// <summary>The mean colour (0 to 1) of the lightest (<paramref name="lightest"/>) or darkest share of what was collected; null for nothing.</summary>
        private static (double R, double G, double B)? Mean(long[] count, double[] r, double[] g, double[] b, double share, bool lightest)
        {
            var total = count.Sum();
            if (total == 0) return null;
            var want = Math.Max(1, (long)(total * share));
            double n = 0, sr = 0, sg = 0, sb = 0;
            for (var k = 0; k < 256 && n < want; k++)
            {
                var level = lightest ? 255 - k : k;
                if (count[level] == 0) continue;
                // A level only partly needed counts in proportion.
                var take = Math.Min(count[level], want - (long)n) / (double)count[level];
                (n, sr, sg, sb) = (n + count[level] * take, sr + r[level] * take, sg + g[level] * take, sb + b[level] * take);
            }
            return (sr / n / 255, sg / n / 255, sb / n / 255);
        }

        /// <summary>The paper's colour behind a line (the corners of what covers it): the lightest 15% of what is under it, averaged; nearly white is white.</summary>
        public (double R, double G, double B) Paper(IEnumerable<(double X, double Y)> corners)
        {
            var (count, r, g, b) = (new long[256], new double[256], new double[256], new double[256]);
            Collect(corners, count, r, g, b);
            if (Mean(count, r, g, b, 0.15, lightest: true) is not var (pr, pg, pb)) return (1, 1, 1);
            return Math.Min(pr, Math.Min(pg, pb)) >= 0.96 ? (1, 1, 1) : (Math.Round(pr, 3), Math.Round(pg, 3), Math.Round(pb, 3));
        }

        /// <summary>
        /// A paragraph's ink colour: the darkest tenth of what is inside its words' boxes, averaged. Ink with little colour
        /// in it (a scan's black or grey print) is black; a clear colour (blue, red) is kept, rounded to a twentieth.
        /// </summary>
        public (double R, double G, double B) InkColor(IReadOnlyList<PlanLine> lines)
        {
            var (count, sr, sg, sb) = (new long[256], new double[256], new double[256], new double[256]);
            foreach (var line in lines)
                foreach (var w in line.Words.Take(20))
                    Collect(new[] { (w.Left, w.Top), (w.Right, w.Top), (w.Right, w.Bottom), (w.Left, w.Bottom) }.Select(c => ToPage(line.Angle, c.Item1, c.Item2)), count, sr, sg, sb);
            if (Mean(count, sr, sg, sb, 0.1, lightest: false) is not var (r, g, b)) return (0, 0, 0);
            var chroma = Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b));
            static double Round(double v) => Math.Round(v * 20) / 20;
            if (chroma < 0.15)
            {
                // Grey print: black when dark (a scan's black is never quite black), else its grey.
                var l = (r + g + b) / 3;
                return l < 0.35 ? (0, 0, 0) : (Round(l), Round(l), Round(l));
            }
            return (Round(r), Round(g), Round(b));
        }
    }
}
