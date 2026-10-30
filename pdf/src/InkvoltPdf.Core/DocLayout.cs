using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>Bullet: a bulleted item (the bullet becomes Word's own). Marker: "1." / "a)" kept as typed, with a hanging indent.</summary>
public enum ListKind { None, Bullet, Marker }

/// <summary>A piece of a laid-out page, in reading order.</summary>
public abstract record DocBlock(RectD Box);

/// <summary>
/// A paragraph: its lines joined into runs (hyphenated line ends rejoined). Indent and FirstLine are in points from the
/// left of the column it sits in; HeadingLevel 1-6 (0: body text).
/// </summary>
public sealed record DocParagraph(IReadOnlyList<ExportSpan> Runs, RectD Box) : DocBlock(Box)
{
    public string Text => string.Concat(Runs.Select(r => r.Text));
    public double Size { get; init; }
    public int LineCount { get; init; } = 1;
    public int HeadingLevel { get; init; }
    public ListKind List { get; init; }
    public TextAlign Align { get; init; }
    public double Indent { get; init; }
    public double FirstLine { get; init; }
    public bool AllBold => Runs.Where(r => !string.IsNullOrWhiteSpace(r.Text)).All(r => r.Bold);

    /// <summary>Where each tab in the text goes, in order (points from the left of the column).</summary>
    public IReadOnlyList<DocTab> Tabs { get; init; } = [];

    /// <summary>The distance from one line's top to the next's in the PDF (0 for one line).</summary>
    public double LinePitch { get; init; }

    /// <summary>Space above and below (points), as the page leaves it; null: the writer's usual spacing.</summary>
    public double? SpaceBefore { get; init; }
    public double? SpaceAfter { get; init; }

    /// <summary>Where its runs are on the page as shown, in reading order (only from <see cref="DocLayout.AnalyzeForTags"/>).</summary>
    public IReadOnlyList<RectD> Sources { get; init; } = [];
}

/// <summary>
/// A tab stop: its position (points from the left of the column), whether text ends there (a leader up to it) or starts
/// there, and what fills the space before it: '.', '_', '-' or nothing ('\0').
/// </summary>
public sealed record DocTab(double Position, bool Right, char Leader);

/// <summary>A table cell: its paragraphs, and any pictures in it (icons, logos).</summary>
public sealed record DocCell(IReadOnlyList<DocParagraph> Paragraphs, int ColSpan = 1)
{
    public IReadOnlyList<DocPicture> Pictures { get; init; } = [];
    public string Text => string.Join("\n", Paragraphs.Select(p => p.Text));
}

/// <summary>A table: rows of cells (a cell may span columns), column widths in points, drawn with lines or not.</summary>
public sealed record DocTable(IReadOnlyList<IReadOnlyList<DocCell>> Rows, IReadOnlyList<double> ColumnWidths, bool Ruled, RectD Box) : DocBlock(Box)
{
    /// <summary>Each row's height on the page (points), when its rules give it; null: as tall as the text needs.</summary>
    public IReadOnlyList<double>? RowHeights { get; init; }
}

public sealed record DocPicture(ExportImage Image, RectD Box) : DocBlock(Box);

/// <summary>A running header or footer: rows, each with parts at the left, middle or right of the page; pictures (a logo) too.</summary>
public sealed record DocRunning(IReadOnlyList<DocRunningRow> Rows)
{
    public IReadOnlyList<(TextAlign Zone, ExportImage Image)> Pictures { get; init; } = [];

    /// <summary>The pages (0-based) that showed any of it; others (a cover page) get none.</summary>
    public IReadOnlySet<int> OnPages { get; init; } = new HashSet<int>();
}

/// <summary>One row of a running header or footer; a part's text may hold <see cref="DocLayout.PageField"/>.</summary>
public sealed record DocRunningRow(IReadOnlyList<(TextAlign Zone, ExportSpan Span)> Parts);

public sealed record DocLayoutResult(IReadOnlyList<DocPage> Pages, DocRunning? Header, DocRunning? Footer);

/// <summary>A page laid out for export. Content: the area its text and pictures cover.</summary>
public sealed record DocPage(double Width, double Height, RectD Content, IReadOnlyList<DocBlock> Blocks, bool FromOcr = false);

/// <summary>
/// Turns what a page shows (positioned lines, pictures, rules) into a flow of paragraphs, headings, list items, tables and
/// pictures in reading order. Columns are found by recursive XY-cut (whitespace gutters, then gaps between bands);
/// tables from ruled grids, or from text aligned in columns over several rows; headings from font sizes larger than
/// the document's body text.
/// </summary>
internal static partial class DocLayout
{
    private const double Thin = 3; // a path this thin (pt) is a rule

    /// <summary>Marks where a running header or footer shows the page number.</summary>
    public const char PageField = '\uE000';

    public static IReadOnlyList<DocPage> Analyze(IReadOnlyList<ExportPage> pages) => AnalyzeDocument(pages).Pages;

    /// <summary>The laid-out pages, with lines repeated at the top or bottom of most pages taken out as a running header and footer.</summary>
    public static DocLayoutResult AnalyzeDocument(IReadOnlyList<ExportPage> pages)
    {
        var (stripped, header, footer) = Running(pages);
        var upright = stripped.Select(Upright).ToList();
        var body = BodySize(upright);
        var laid = upright.Select(p => LayOut(p, body)).ToList();
        laid = AssignHeadings(laid, body);
        return new DocLayoutResult(Dehyphenate(laid, upright), header, footer);
    }

    /// <summary>
    /// <see cref="AnalyzeDocument"/> for tagging: each paragraph and picture also says where it is on the page as shown
    /// (<see cref="DocParagraph.Sources"/>, <see cref="ExportImage.PageBox"/>), whatever turning a page for layout did, and
    /// <paramref name="pages"/>' running headers and footers come back as boxes on each page.
    /// </summary>
    public static (DocLayoutResult Layout, IReadOnlyList<IReadOnlyList<RectD>> Running) AnalyzeForTags(IReadOnlyList<ExportPage> pages)
    {
        var marked = pages.Select(p => p with
        {
            Lines = [.. p.Lines.Select(l => l with { Spans = [.. l.Spans.Select(s => s with { PageBox = s.Box })] })],
            // The writer's Ref tells a repeated logo: without its bytes, the same size at the same place.
            Images = [.. p.Images.Select(i => i with { PageBox = i.Box, Ref = $"{i.PixelWidth}x{i.PixelHeight}" })],
        }).ToList();
        var (stripped, header, footer) = Running(marked);
        var running = marked.Select((p, i) => (IReadOnlyList<RectD>)
            [.. p.Lines.Except(stripped[i].Lines, ReferenceEqualityComparer.Instance).OfType<ExportLine>().Select(l => l.Box),
             .. p.Images.Except(stripped[i].Images, ReferenceEqualityComparer.Instance).OfType<ExportImage>().Select(x => x.Box)]).ToList();
        var upright = stripped.Select(Upright).ToList();
        var body = BodySize(upright);
        var laid = AssignHeadings([.. upright.Select(p => LayOut(p, body))], body);
        return (new DocLayoutResult(Dehyphenate(laid, upright), header, footer), running);
    }

    /// <summary>
    /// A page whose text mostly reads sideways (a landscape table set on a portrait page) turned so that it reads left
    /// to right; it then exports as a landscape page.
    /// </summary>
    public static ExportPage Upright(ExportPage page)
    {
        var counts = new int[4];
        foreach (var l in page.Lines) counts[l.Reads] += l.Text.Count(c => !char.IsWhiteSpace(c));
        var total = counts.Sum();
        var turn = Enumerable.Range(1, 3).MaxBy(t => counts[t]);
        return total > 0 && counts[turn] > 0.6 * total ? page.Turned(turn) : page;
    }

    /// <summary>The size most of the document's characters have (11 when it has no text).</summary>
    public static double BodySize(IEnumerable<ExportPage> pages)
    {
        var counts = new Dictionary<double, int>();
        foreach (var p in pages)
        foreach (var l in p.Lines.Where(l => !l.Sideways))
        foreach (var s in l.Spans)
        {
            var n = s.Text.Count(c => !char.IsWhiteSpace(c));
            if (n == 0) continue;
            var key = Math.Round(s.Size * 2) / 2;
            counts[key] = counts.GetValueOrDefault(key) + n;
        }
        return counts.Count == 0 ? 11 : counts.MaxBy(kv => kv.Value).Key;
    }

    /// <summary>
    /// Thin paths become rules; outlined boxes give their four edges (cell borders are often drawn as rectangles). MuPDF
    /// bounds an outlined box with room for mitered corners (up to the miter limit times the line width, some 11 pt for a
    /// 1 pt frame), so a frame's edges stand off the rules drawn inside it: when rules inside reach equally close to both
    /// sides, the frame is taken in by that much all round.
    /// </summary>
    public static IReadOnlyList<RectD> RulesFromPaths(IEnumerable<(RectD Box, bool Stroked)> paths)
    {
        var rules = new List<RectD>();
        var list = paths.Where(p => p.Box.Width >= 0 && p.Box.Height >= 0 && double.IsFinite(p.Box.Width) && double.IsFinite(p.Box.Height)).ToList();
        var thin = list.Where(p => p.Box.Width <= Thin || p.Box.Height <= Thin).Select(p => p.Box).ToList();
        foreach (var (box, stroked) in list)
        {
            var b = box;
            if (b.Width <= Thin || b.Height <= Thin)
            {
                if (Math.Max(b.Width, b.Height) >= 4) rules.Add(b);
            }
            else if (stroked)
            {
                if (FramePadding(b, thin) is { } pad) b = b.Inflate(-pad);
                rules.Add(new RectD(b.X, b.Y, b.Width, 0));
                rules.Add(new RectD(b.X, b.Bottom, b.Width, 0));
                rules.Add(new RectD(b.X, b.Y, 0, b.Height));
                rules.Add(new RectD(b.Right, b.Y, 0, b.Height));
            }
        }
        return rules;
    }

    /// <summary>
    /// How far an outlined box's bounds stand off the frame actually drawn: the rules inside it that run across (or down)
    /// it end the same distance (0.5 to 15 pt) short of both sides, two of them at least and all alike. Null otherwise.
    /// </summary>
    private static double? FramePadding(RectD box, List<RectD> thin)
    {
        var pads = new List<double>();
        foreach (var r in thin)
        {
            double a, b;
            if (r.Height <= Thin && r.Width > 0.5 * box.Width && r.CenterY > box.Y && r.CenterY < box.Bottom)
                (a, b) = (r.X - box.X, box.Right - r.Right);
            else if (r.Width <= Thin && r.Height > 0.5 * box.Height && r.CenterX > box.X && r.CenterX < box.Right)
                (a, b) = (r.Y - box.Y, box.Bottom - r.Bottom);
            else continue;
            if (a is >= 0.5 and <= 15 && b is >= 0.5 and <= 15 && Math.Abs(a - b) <= 2.5) pads.Add((a + b) / 2);
        }
        // Two rules at least (a single line inset in a box may be inset on purpose).
        if (pads.Count < 2) return null;
        pads.Sort();
        if (pads[^1] - pads[0] > 2.5) return null;
        var pad = pads[pads.Count / 2];
        return pad < Math.Min(box.Width, box.Height) / 4 ? pad : null;
    }

    // ---- one page ----

    /// <summary>
    /// Whether a picture goes into the export: not a page-size one behind text (a scan under its own OCR text, or a
    /// background), which would repeat the text as a picture.
    /// </summary>
    public static bool Keeps(ExportPage page, ExportImage image) =>
        !(page.HasText && image.Box.Width * image.Box.Height >= 0.85 * page.Width * page.Height);

    /// <summary>An element being ordered: a line, or a finished block (table, picture). Column: where it sits, once known.</summary>
    private sealed class Item(RectD box, ExportLine? line, DocBlock? block)
    {
        public RectD Box { get; } = box;
        public ExportLine? Line { get; } = line;
        public DocBlock? Block { get; } = block;
        public RectD? Column { get; set; }
    }

    public static DocPage LayOut(ExportPage page, double body)
    {
        var lines = page.Lines.Where(l => !l.Sideways && l.Text.Any(c => !char.IsWhiteSpace(c))).ToList();
        if (page.FromOcr) lines = SnapOcrSizes(lines);
        lines = MergeRows(lines, [.. page.Rules.Where(r => r.Width <= Thin && r.Height > 6)]);

        var items = new List<Item>();
        var images = page.Images.Where(i => Keeps(page, i)).ToList();
        foreach (var grid in Grids(page.Rules))
            if (TableFromGrid(grid, lines, images, body) is { } t) items.Add(new Item(t.Box, null, t));
        items.AddRange(images.Select(img => new Item(img.Box, null, new DocPicture(img, img.Box))));
        items.AddRange(lines.Select(l => new Item(l.Box, l, null)));
        var sideways = page.Lines.Where(l => l.Sideways && l.Text.Any(c => !char.IsWhiteSpace(c))).ToList();
        if (items.Count == 0 && sideways.Count == 0) return new DocPage(page.Width, page.Height, default, [], page.FromOcr);

        var all = items.Select(i => i.Box).Concat(sideways.Select(l => l.Box)).ToList();
        var content = all.Aggregate((a, b) => a.Union(b));
        var ordered = Order(items, body, 0);
        foreach (var i in ordered) i.Column ??= content;
        var blocks = MergeTables(Flow(ordered, body), body);
        // Sideways text (a rotated label, a margin stamp, a turned table on a mostly upright page): each direction's lines
        // are laid out in their own turned frame, so they read as paragraphs, and go in where they start on the page.
        foreach (var group in sideways.GroupBy(l => l.Reads))
        {
            var top = group.Min(l => l.Box.Y);
            var turned = new ExportPage(page.Width, page.Height, [.. group], [], []).Turned(group.Key);
            var at = blocks.FindIndex(b => b.Box.Y > top);
            var inserted = LayOut(turned, body).Blocks.Select(b => b with { Box = new RectD(b.Box.X, top, b.Box.Width, 0) }).ToList();
            if (at < 0) blocks.AddRange(inserted);
            else blocks.InsertRange(at, inserted);
        }
        return new DocPage(page.Width, page.Height, content, Spaced(blocks), page.FromOcr);
    }

    /// <summary>Word's line height for one line of type (single spacing), as a share of the size.</summary>
    private const double WordLine = 1.17;

    /// <summary>
    /// The space the page leaves above each paragraph, so the export keeps its vertical layout (a form's rows, a gap before
    /// a signature): from the line before's top, one Word line per line it had, the rest as space before; after a table
    /// or picture, the gap under it. A paragraph before a table keeps the gap under it as space after (a table has no
    /// space of its own). The first block, and one placed higher than the block before (a new column), get none. The
    /// gap is measured from the paragraph before's last line, so its line spacing doesn't add to it.
    /// </summary>
    private static List<DocBlock> Spaced(List<DocBlock> blocks)
    {
        var result = new List<DocBlock>(blocks.Count);
        for (var i = 0; i < blocks.Count; i++)
        {
            var b = blocks[i];
            if (b is DocParagraph p)
            {
                var before = 0.0;
                if (i > 0)
                {
                    var prev = blocks[i - 1];
                    // From the top of the paragraph before's last line (its line spacing is its own, not a gap).
                    before = prev is DocParagraph q
                        ? p.Box.Y - (q.Box.Y + (q.LineCount - 1) * q.LinePitch) - WordLine * q.Size
                        : p.Box.Y - prev.Box.Bottom;
                    // Sideways text placed where it starts has no height: no gap to measure.
                    if (prev.Box.Height <= 0 || p.Box.Height <= 0) before = 0;
                }
                var after = i + 1 < blocks.Count && blocks[i + 1] is DocTable t && t.Box.Y >= p.Box.Bottom
                    ? Math.Min(200, t.Box.Y - p.Box.Bottom) : 0;
                b = p with { SpaceBefore = Math.Clamp(before, 0, 200), SpaceAfter = after };
            }
            result.Add(b);
        }
        return result;
    }

    /// <summary>OCR sizes are estimates: those within a fifth of the page's usual size are taken as that size.</summary>
    private static List<ExportLine> SnapOcrSizes(List<ExportLine> lines)
    {
        if (lines.Count == 0) return lines;
        var sizes = lines.Select(l => l.Size).Order().ToList();
        var usual = sizes[sizes.Count / 2];
        return [.. lines.Select(l => Math.Abs(l.Size - usual) <= 0.2 * usual
            ? l with { Spans = [.. l.Spans.Select(s => s with { Size = usual })] }
            : l)];
    }

    /// <summary>
    /// Joins pieces of one visual line that MuPDF split (a bullet and its text, words spread by justification): same row,
    /// close together. A lone list marker joins its text even across a wide gap. Not across one of
    /// <paramref name="verticals"/> (a table's rule between two cells).
    /// </summary>
    private static List<ExportLine> MergeRows(List<ExportLine> lines, List<RectD> verticals)
    {
        var sorted = lines.OrderBy(l => l.Box.X).ToList();
        var result = new List<ExportLine>();
        // Lines by the height of their middle (8 pt bands), so each looks only at nearby rows, not the whole page.
        var bands = new Dictionary<int, List<int>>();
        foreach (var line in sorted)
        {
            var merged = false;
            var band = (int)Math.Floor(line.Box.CenterY / 8);
            foreach (var k in Enumerable.Range(band - 2, 5).SelectMany(b => bands.GetValueOrDefault(b) ?? []).OrderDescending())
            {
                var prev = result[k];
                var overlap = Math.Min(prev.Box.Bottom, line.Box.Bottom) - Math.Max(prev.Box.Y, line.Box.Y);
                if (overlap < 0.6 * Math.Min(prev.Box.Height, line.Box.Height)) continue;
                var gap = line.Box.X - prev.Box.Right;
                var size = Math.Max(prev.Size, line.Size);
                var maxGap = IsMarkerOnly(prev.Text) ? 4 * size : 1.2 * size;
                if (gap < -1 || gap > maxGap) continue;
                var cy = (prev.Box.CenterY + line.Box.CenterY) / 2;
                if (verticals.Any(v => v.CenterX >= prev.Box.Right - 1 && v.CenterX <= line.Box.X + 1 && v.Y <= cy && v.Bottom >= cy)) continue;
                // Two numbers apart are two table columns, not one line.
                if (gap > 0.8 * size && ExportLine.NumberLike(prev.Text) && ExportLine.NumberLike(line.Text)) continue;
                result[k] = Join(prev, line);
                merged = true;
                break;
            }
            if (merged) continue;
            if (!bands.TryGetValue(band, out var list)) bands[band] = list = [];
            list.Add(result.Count);
            result.Add(line);
        }
        result.Sort((a, b) => a.Box.Y != b.Box.Y ? a.Box.Y.CompareTo(b.Box.Y) : a.Box.X.CompareTo(b.Box.X));
        return result;

        static ExportLine Join(ExportLine a, ExportLine b)
        {
            var spans = a.Spans.ToList();
            // Pieces that touch are one word split by MuPDF (at a capital's accent: "PREDICACIÓ" "N"): no space between.
            var touching = b.Box.X - a.Box.Right < 0.15 * Math.Max(a.Size, b.Size);
            var needsSpace = !touching && !char.IsWhiteSpace(a.Text.LastOrDefault(' ')) && !char.IsWhiteSpace(b.Text.FirstOrDefault(' '));
            if (needsSpace) spans[^1] = spans[^1] with { Text = spans[^1].Text + " " };
            spans.AddRange(b.Spans);
            return ExportLine.Of(spans);
        }
    }

    // ---- reading order (XY-cut) ----

    private static List<Item> Order(List<Item> items, double body, int depth)
    {
        if (items.Count <= 1 || depth > 200) return Sorted(items);
        List<List<Item>>? columns = null;
        if (!SingleRow(items))
        {
            var gutters = Gaps(items, i => (i.Box.X, i.Box.Right), Math.Max(8, 0.9 * body));
            if (gutters.Count > 0)
            {
                var pieces = Split(items, gutters, i => i.Box.CenterX);
                if (pieces.Count > 1)
                {
                    if (UnruledTable(pieces, body) is { } table)
                        return [new Item(table.Box, null, table)];
                    columns = FormRows(pieces) ? null : pieces;
                    if (columns is not null && ReadAsColumns(pieces, body))
                    {
                        // Text under the columns that sits in one of them only (a list after a two-column part) comes after both.
                        var below = TextUnderColumns(items, pieces, body);
                        if (below is null) return Columns(pieces);
                        var parts = Split(items, [below.Value], i => i.Box.CenterY);
                        return [.. parts.SelectMany(p => Order(p, body, depth + 1))];
                    }
                }
            }
        }
        var bands = Gaps(items, i => (i.Box.Y, i.Box.Bottom), 0.5);
        if (bands.Count > 0)
        {
            // Cut at the widest gaps only (a title's gap, not every line's), then look for columns in each band again.
            var widest = bands.Max(g => g.End - g.Start);
            var cuts = bands.Where(g => g.End - g.Start >= 0.8 * widest).ToList();
            var parts = Split(items, cuts, i => i.Box.CenterY);
            if (parts.Count > 1) return [.. parts.SelectMany(p => Order(p, body, depth + 1))];
        }
        return columns is null ? Sorted(items) : Columns(columns);

        List<Item> Columns(List<List<Item>> pieces)
        {
            var result = new List<Item>();
            foreach (var piece in pieces)
            {
                var bounds = piece.Select(i => i.Box).Aggregate((a, b) => a.Union(b));
                var sub = Order(piece, body, depth + 1);
                foreach (var i in sub) i.Column ??= bounds;
                result.AddRange(sub);
            }
            return result;
        }
    }

    /// <summary>
    /// Pieces side by side that line up row for row and fill in a form (a fill-in line in each, with its label under it:
    /// "Signature ......" beside "Date ......"): read across, row by row, not one piece after the other.
    /// </summary>
    private static bool FormRows(List<List<Item>> pieces)
    {
        if (pieces.Any(p => p.Any(i => i.Line is null))) return false;
        var lines = pieces.SelectMany((p, k) => p.Select(i => (Line: i.Line!, Col: k))).ToList();
        if (!lines.Any(x => x.Line.Text.Any(ExportGlyphs.IsLeader))) return false;
        return Rows(lines).All(r => r.Select(x => x.Col).Distinct().Count() >= 2);
    }

    /// <summary>
    /// A gap across the whole region below which only one of the pieces has anything, while above it two or more do:
    /// the columns end there and what follows is read after all of them.
    /// </summary>
    private static (double Start, double End)? TextUnderColumns(List<Item> items, List<List<Item>> pieces, double body)
    {
        foreach (var gap in Gaps(items, i => (i.Box.Y, i.Box.Bottom), 0.5 * body))
        {
            var above = pieces.Count(p => p.Any(i => i.Box.CenterY < gap.Start));
            var under = pieces.Count(p => p.Any(i => i.Box.CenterY > gap.End));
            if (above >= 2 && under == 1) return gap;
        }
        return null;
    }

    /// <summary>
    /// Pieces side by side read as columns unless one has a tall empty stretch (three lines or more) where another has
    /// something: then they are blocks stacked down the page that happen to leave a gutter between them (a table's
    /// numbers beside headings and short lines), and the page is cut across first.
    /// </summary>
    private static bool ReadAsColumns(List<List<Item>> pieces, double body)
    {
        for (var k = 0; k < pieces.Count; k++)
        {
            var spans = pieces[k].Select(i => (i.Box.Y, i.Box.Bottom)).OrderBy(s => s.Y).ToList();
            var reach = spans[0].Bottom;
            foreach (var (y, bottom) in spans.Skip(1))
            {
                var (top, end) = (reach, y);
                if (end - top > 3 * body && pieces.Where((_, j) => j != k).Any(p => p.Any(i => i.Box.CenterY > top && i.Box.CenterY < end)))
                    return false;
                reach = Math.Max(reach, bottom);
            }
        }
        return true;
    }

    private static List<Item> Sorted(List<Item> items) =>
        [.. items.OrderBy(i => Math.Round(i.Box.Y)).ThenBy(i => i.Box.X)];

    /// <summary>Every element shares one horizontal band (one row of text): nothing to split into columns.</summary>
    private static bool SingleRow(List<Item> items) => items.Max(i => i.Box.Y) < items.Min(i => i.Box.Bottom);

    /// <summary>Gaps of at least <paramref name="min"/> between the elements' extents along one axis (inner gaps only).</summary>
    private static List<(double Start, double End)> Gaps(List<Item> items, Func<Item, (double, double)> extent, double min)
    {
        var spans = items.Select(extent).OrderBy(s => s.Item1).ToList();
        var gaps = new List<(double, double)>();
        var reach = spans[0].Item2;
        foreach (var (start, end) in spans.Skip(1))
        {
            if (start - reach >= min) gaps.Add((reach, start));
            reach = Math.Max(reach, end);
        }
        return gaps;
    }

    private static List<List<Item>> Split(List<Item> items, List<(double Start, double End)> gaps, Func<Item, double> center)
    {
        var parts = new List<Item>[gaps.Count + 1];
        for (var i = 0; i < parts.Length; i++) parts[i] = [];
        foreach (var item in items)
        {
            var c = center(item);
            var k = 0;
            while (k < gaps.Count && c > gaps[k].Start) k++;
            parts[k].Add(item);
        }
        return [.. parts.Where(p => p.Count > 0)];
    }

    // ---- tables from aligned text ----

    /// <summary>
    /// Pieces side by side whose lines line up row by row (at least three rows, or two with three or more columns) form a
    /// table, unless they read as text columns (wide, filled lines).
    /// </summary>
    private static DocTable? UnruledTable(List<List<Item>> pieces, double body)
    {
        if (pieces.Any(p => p.Any(i => i.Line is null))) return null;
        var bounds = pieces.Select(p => p.Select(i => i.Box).Aggregate((a, b) => a.Union(b))).ToList();
        var prose = pieces.Select((p, k) => IsProse(p, bounds[k].Width, body)).ToList();
        if (pieces.Count == 2 ? prose.Any(x => x) : prose.Count(x => x) >= 2) return null;

        var rows = Rows(pieces.SelectMany((p, k) => p.Select(i => (Line: i.Line!, Col: k))).ToList());
        var aligned = rows.Count(r => r.Select(x => x.Col).Distinct().Count() >= 2);
        if (rows.Count < 2 || aligned < (pieces.Count == 2 ? 3 : 2) || aligned < 0.6 * rows.Count) return null;

        // Column edges: halfway across each gutter.
        var edges = new List<double> { bounds[0].X };
        for (var k = 1; k < bounds.Count; k++) edges.Add((bounds[k - 1].Right + bounds[k].X) / 2);
        edges.Add(bounds[^1].Right);
        var cols = pieces.Count;

        var cells = new List<List<List<ExportLine>>>();
        RectD? prevBox = null;
        foreach (var row in rows)
        {
            var box = row.Select(x => x.Line.Box).Aggregate((a, b) => a.Union(b));
            var filled = row.Select(x => x.Col).Distinct().ToList();
            // A row with only a wrapped cell's next line (first column empty, right under the row before) continues that row.
            if (cells.Count > 0 && !filled.Contains(0) && filled.Count <= Math.Max(1, cols / 2) && cells[^1][0].Count > 0
                && prevBox is { } pb && box.Y - pb.Bottom < 0.6 * body)
            {
                foreach (var (line, col) in row) cells[^1][col].Add(line);
                prevBox = pb.Union(box);
                continue;
            }
            var r = Enumerable.Range(0, cols).Select(_ => new List<ExportLine>()).ToList();
            foreach (var (line, col) in row) r[col].Add(line);
            cells.Add(r);
            prevBox = box;
        }
        // Most cells hold something, and not too many columns: chart labels and scattered words don't make a table.
        var filledCells = cells.Sum(r => r.Count(c => c.Count > 0));
        if (cols > MaxTableColumns || filledCells < 0.5 * cells.Count * cols) return null;
        var tableBox = bounds.Aggregate((a, b) => a.Union(b));
        var docRows = cells.Select(r => (IReadOnlyList<DocCell>)[.. r.Select((ls, k) =>
            new DocCell(CellParagraphs(ls, new RectD(edges[k], tableBox.Y, edges[k + 1] - edges[k], tableBox.Height), body)))]).ToList();
        var widths = Enumerable.Range(0, cols).Select(k => edges[k + 1] - edges[k]).ToList();
        return new DocTable(docRows, widths, false, tableBox);
    }

    private static bool IsProse(List<Item> piece, double width, double body)
    {
        if (piece.Count < 3 || width < 10 * body) return false;
        var widths = piece.Select(i => i.Box.Width).Order().ToList();
        return widths[widths.Count / 2] >= 0.6 * width;
    }

    /// <summary>Lines grouped into rows: a line whose middle falls within a row's height joins it.</summary>
    private static List<List<(ExportLine Line, int Col)>> Rows(List<(ExportLine Line, int Col)> lines)
    {
        var rows = new List<(double Top, double Bottom, List<(ExportLine, int)> Members)>();
        foreach (var x in lines.OrderBy(x => x.Line.Box.CenterY))
        {
            var cy = x.Line.Box.CenterY;
            if (rows.Count > 0 && cy >= rows[^1].Top && cy <= rows[^1].Bottom)
            {
                var r = rows[^1];
                r.Members.Add(x);
                rows[^1] = (Math.Min(r.Top, x.Line.Box.Y), Math.Max(r.Bottom, x.Line.Box.Bottom), r.Members);
            }
            else rows.Add((x.Line.Box.Y, x.Line.Box.Bottom, [x]));
        }
        return [.. rows.Select(r => r.Members)];
    }

    /// <summary>
    /// Tables without lines that follow one another with the same columns (a long table cut where its row groups leave a
    /// gap) are one table.
    /// </summary>
    private static List<DocBlock> MergeTables(List<DocBlock> blocks, double body)
    {
        for (var i = blocks.Count - 2; i >= 0; i--)
        {
            if (blocks[i] is not DocTable { Ruled: false } a || blocks[i + 1] is not DocTable { Ruled: false } b) continue;
            if (a.ColumnWidths.Count != b.ColumnWidths.Count || b.Box.Y < a.Box.Bottom - 1 || b.Box.Y - a.Box.Bottom > 4 * body) continue;
            double Edge(DocTable t, int k) => t.Box.X + t.ColumnWidths.Take(k).Sum();
            if (Enumerable.Range(0, a.ColumnWidths.Count + 1).Any(k => Math.Abs(Edge(a, k) - Edge(b, k)) > Math.Max(18, 1.5 * body))) continue;
            blocks[i] = new DocTable([.. a.Rows, .. b.Rows], a.ColumnWidths, false, a.Box.Union(b.Box));
            blocks.RemoveAt(i + 1);
        }
        return blocks;
    }

    /// <summary>More columns than this is a scatter of words (chart labels), not a table.</summary>
    private const int MaxTableColumns = 20;

    // ---- figures drawn with vectors ----

    /// <summary>
    /// Areas of a page drawn with many vector paths and holding little text: charts and diagrams, exported as a picture
    /// rather than read as text and tables. A figure is a cluster of at least 10 paths (touching or within 4 pt), over
    /// 40 x 40 pt, whose text lines cover less than a fifth of it and hold at most 80 words (400 when they are short
    /// labels, four words a line or fewer: a diagram), and that isn't a ruled table
    /// (a grid with text in at least half its cells). Paths covering half the page or more (backgrounds, frames) don't
    /// count. Labels just outside the paths (within 6 pt) belong to the figure.
    /// </summary>
    public static IReadOnlyList<RectD> FigureRegions(IReadOnlyList<(RectD Box, bool Stroked)> paths, IReadOnlyList<ExportLine> lines,
        double width, double height)
    {
        const double near = 4;
        var items = paths.Where(p => p.Box.Width >= 0 && p.Box.Height >= 0 && double.IsFinite(p.Box.Width) && double.IsFinite(p.Box.Height)
                                     && p.Box.Width * p.Box.Height < 0.5 * width * height)
            .OrderBy(p => p.Box.X).ToList();
        if (items.Count < 10) return [];
        var parent = Enumerable.Range(0, items.Count).ToArray();
        int Find(int i) => parent[i] == i ? i : parent[i] = Find(parent[i]);
        for (var i = 0; i < items.Count; i++)
        {
            var a = items[i].Box;
            for (var j = i + 1; j < items.Count && items[j].Box.X <= a.Right + near; j++)
            {
                var b = items[j].Box;
                if (b.Y <= a.Bottom + near && a.Y <= b.Bottom + near) parent[Find(j)] = Find(i);
            }
        }
        var clusters = Enumerable.Range(0, items.Count).GroupBy(Find)
            .Where(g => g.Count() >= 10)
            .Select(g => (Paths: g.Select(i => items[i]).ToList(), Box: g.Select(i => items[i].Box).Aggregate((x, y) => x.Union(y))))
            .ToList();
        // Clusters whose areas overlap are one figure (a legend inside a plot, bars beside axes).
        for (var merged = true; merged;)
        {
            merged = false;
            for (var i = 0; i < clusters.Count && !merged; i++)
            for (var j = i + 1; j < clusters.Count && !merged; j++)
            {
                if (clusters[i].Box.Intersect(clusters[j].Box).IsEmpty) continue;
                clusters[i] = ([.. clusters[i].Paths, .. clusters[j].Paths], clusters[i].Box.Union(clusters[j].Box));
                clusters.RemoveAt(j);
                merged = true;
            }
        }
        var figures = new List<RectD>();
        foreach (var (clusterPaths, box) in clusters)
        {
            if (box.Width < 40 || box.Height < 40) continue;
            var around = box.Inflate(6);
            var inside = lines.Where(l => around.Contains(l.Box.CenterX, l.Box.CenterY)).ToList();
            var textArea = inside.Sum(l => l.Box.Width * l.Box.Height);
            var wordCount = inside.Sum(l => Letters().Matches(l.Text).Count + l.Text.Count(char.IsDigit) / 4);
            // Labels are short; a form or a text box has sentences.
            var labels = inside.Count > 0 && wordCount <= 4.0 * inside.Count;
            if (textArea >= 0.2 * box.Width * box.Height || wordCount > (labels ? 400 : 80)) continue;
            if (IsRuledTable(clusterPaths, inside) || RowsOfText(inside) || IsFormGrid(clusterPaths, box)) continue;
            // The labels around the drawing go with it.
            var region = inside.Aggregate(box, (r, l) => r.Union(l.Box)).Intersect(new RectD(0, 0, width, height));
            if (!region.IsEmpty) figures.Add(region);
        }
        return figures;
    }

    /// <summary>
    /// The text is set in rows of pieces side by side, three or more, or two with words (four rows at least, and most of
    /// them): a table, even one whose lines don't form a grid. A chart's labels are alone on their row (a legend) or
    /// numbers (the ticks of axes side by side).
    /// </summary>
    private static bool RowsOfText(List<ExportLine> lines)
    {
        var rows = Rows([.. lines.Where(l => !l.Sideways).Select(l => (l, 0))]);
        var multi = rows.Count(r => r.Count >= 3 || (r.Count == 2 && r.Any(x => x.Line.Text.Count(char.IsLetter) >= 2)));
        return multi >= 4 && multi >= 0.5 * rows.Count;
    }

    /// <summary>
    /// The paths are only rules and outlined boxes that no rule crosses, in a grid covering most of the cluster:
    /// a form's boxes (a table to fill in, mostly empty), not a chart (bars are filled, gridlines cross a data line).
    /// </summary>
    private static bool IsFormGrid(List<(RectD Box, bool Stroked)> paths, RectD cluster)
    {
        if (!paths.All(p => p.Stroked || p.Box.Width <= Thin || p.Box.Height <= Thin)) return false;
        var thin = paths.Where(p => p.Box.Width <= Thin || p.Box.Height <= Thin).Select(p => p.Box).ToList();
        foreach (var g in Grids(RulesFromPaths(paths)))
        {
            if ((g.Xs[^1] - g.Xs[0]) * (g.Ys[^1] - g.Ys[0]) < 0.5 * cluster.Width * cluster.Height) continue;
            // Each outlined shape holds the rules that reach it (a frame, a cell); a chart's gridlines run through its data
            // line's bounds and out the other side.
            var boxes = paths.Where(p => p.Box.Width > Thin && p.Box.Height > Thin).Select(p =>
                FramePadding(p.Box, thin) is { } pad ? p.Box.Inflate(-pad) : p.Box);
            static bool Crossed(RectD b, List<RectD> rules) => rules.Any(r =>
                r.Height <= Thin
                    ? r.CenterY > b.Y + 3 && r.CenterY < b.Bottom - 3 && (r.X < b.X - 3 && r.Right > b.X + 3 || r.X < b.Right - 3 && r.Right > b.Right + 3)
                    : r.CenterX > b.X + 3 && r.CenterX < b.Right - 3 && (r.Y < b.Y - 3 && r.Bottom > b.Y + 3 || r.Y < b.Bottom - 3 && r.Bottom > b.Bottom + 3));
            if (!boxes.Any(b => Crossed(b, thin))) return true;
        }
        return false;
    }

    /// <summary>The paths draw a grid with text in at least half its cells.</summary>
    private static bool IsRuledTable(List<(RectD Box, bool Stroked)> paths, List<ExportLine> lines)
    {
        foreach (var grid in Grids(RulesFromPaths(paths)))
        {
            int rows = grid.Ys.Count - 1, cols = grid.Xs.Count - 1;
            var filled = lines.Select(l => (R: grid.Ys.FindLastIndex(y => y <= l.Box.CenterY), C: grid.Xs.FindLastIndex(x => x <= l.Box.CenterX)))
                .Where(rc => rc.R >= 0 && rc.R < rows && rc.C >= 0 && rc.C < cols).Distinct().Count();
            if (filled >= 0.5 * rows * cols) return true;
        }
        return false;
    }

    // ---- tables from ruled grids ----

    private sealed record Grid(List<double> Xs, List<double> Ys, List<RectD> Verticals);

    /// <summary>Grids of crossing horizontal and vertical rules with at least two columns.</summary>
    private static List<Grid> Grids(IReadOnlyList<RectD> rules)
    {
        const double tol = 2.5;
        var h = rules.Where(r => r.Height <= Thin && r.Width > 6).ToList();
        var v = rules.Where(r => r.Width <= Thin && r.Height > 6).ToList();
        if (h.Count < 2 || v.Count < 3 || h.Count + v.Count > 3000) return [];

        // Union-find over rules that cross or touch.
        var parent = Enumerable.Range(0, h.Count + v.Count).ToArray();
        int Find(int i) => parent[i] == i ? i : parent[i] = Find(parent[i]);
        for (var a = 0; a < h.Count; a++)
        for (var b = 0; b < v.Count; b++)
        {
            var (hy, vx) = (h[a].CenterY, v[b].CenterX);
            if (vx >= h[a].X - tol && vx <= h[a].Right + tol && hy >= v[b].Y - tol && hy <= v[b].Bottom + tol)
                parent[Find(a)] = Find(h.Count + b);
        }
        var grids = new List<Grid>();
        foreach (var group in Enumerable.Range(0, h.Count + v.Count).GroupBy(Find))
        {
            var hs = group.Where(i => i < h.Count).Select(i => h[i]).ToList();
            var vs = group.Where(i => i >= h.Count).Select(i => v[i - h.Count]).ToList();
            if (hs.Count < 2 || vs.Count < 3) continue;
            var xs = Cluster(vs.Select(r => r.CenterX), tol);
            var ys = Cluster(hs.Select(r => r.CenterY), tol);
            if (xs.Count >= 3 && ys.Count >= 2) grids.Add(new Grid(xs, ys, vs));
        }
        return grids;
    }

    private static List<double> Cluster(IEnumerable<double> values, double tol)
    {
        var result = new List<double>();
        var group = new List<double>();
        foreach (var x in values.Order())
        {
            if (group.Count > 0 && x - group[^1] > tol)
            {
                result.Add(group.Average());
                group.Clear();
            }
            group.Add(x);
        }
        if (group.Count > 0) result.Add(group.Average());
        return result;
    }

    /// <summary>
    /// The table a grid draws, with the lines and pictures inside it (removed from <paramref name="lines"/> and
    /// <paramref name="images"/>). Cells without a rule between them in a row are merged. Null when fewer than two cells
    /// hold something, or none holds text (a box around a paragraph, an empty form grid).
    /// </summary>
    private static DocTable? TableFromGrid(Grid grid, List<ExportLine> lines, List<ExportImage> images, double body)
    {
        var (xs, ys) = (grid.Xs, grid.Ys);
        int rows = ys.Count - 1, cols = xs.Count - 1;
        var bounds = RectD.FromEdges(xs[0], ys[0], xs[^1], ys[^1]);
        // start[r][c]: the column where the merged cell holding (r, c) starts.
        var start = new int[rows][];
        for (var r = 0; r < rows; r++)
        {
            start[r] = new int[cols];
            for (var c = 1; c < cols; c++)
            {
                var (top, bottom) = (ys[r], ys[r + 1]);
                var ruled = grid.Verticals.Any(v => Math.Abs(v.CenterX - xs[c]) <= 2.5
                    && Math.Min(v.Bottom, bottom) - Math.Max(v.Y, top) >= 0.6 * (bottom - top));
                start[r][c] = ruled ? c : start[r][c - 1];
            }
        }
        (int, int)? CellAt(RectD box)
        {
            var (cx, cy) = (box.CenterX, box.CenterY);
            if (!bounds.Contains(cx, cy)) return null;
            var r = Math.Clamp(ys.FindLastIndex(y => y <= cy), 0, rows - 1);
            var c = Math.Clamp(xs.FindLastIndex(x => x <= cx), 0, cols - 1);
            return (r, start[r][c]);
        }
        var content = new Dictionary<(int, int), List<ExportLine>>();
        var used = new List<ExportLine>();
        foreach (var line in lines)
        {
            if (CellAt(line.Box) is not { } key) continue;
            if (!content.TryGetValue(key, out var list)) content[key] = list = [];
            list.Add(line);
            used.Add(line);
        }
        var pictures = new Dictionary<(int, int), List<DocPicture>>();
        var usedImages = new List<ExportImage>();
        foreach (var img in images)
        {
            // A picture inside one cell (an icon), not one the grid is drawn over.
            if (CellAt(img.Box) is not { } key || img.Box.Width > bounds.Width / 2 || img.Box.Height > bounds.Height / 2) continue;
            if (!pictures.TryGetValue(key, out var list)) pictures[key] = list = [];
            list.Add(new DocPicture(img, img.Box));
            usedImages.Add(img);
        }
        // A third of the cells at least hold something (a form's grid of empty boxes isn't a table to rebuild).
        var cellCount = start.Sum(row => row.Select((s, c) => s == c ? 1 : 0).Sum());
        var filled = content.Keys.Union(pictures.Keys).Count();
        if (content.Count == 0 || filled < 2 || filled < cellCount / 3.0) return null;
        foreach (var l in used) lines.Remove(l);
        foreach (var i in usedImages) images.Remove(i);

        var docRows = new List<IReadOnlyList<DocCell>>();
        for (var r = 0; r < rows; r++)
        {
            var row = new List<DocCell>();
            for (var c = 0; c < cols;)
            {
                var span = 1;
                while (c + span < cols && start[r][c + span] == c) span++;
                var cell = RectD.FromEdges(xs[c], ys[r], xs[c + span], ys[r + 1]);
                row.Add(new DocCell(content.TryGetValue((r, c), out var ls) ? CellParagraphs(ls, cell, body) : [], span)
                {
                    Pictures = pictures.TryGetValue((r, c), out var pics) ? pics : [],
                });
                c += span;
            }
            docRows.Add(row);
        }
        return new DocTable(docRows, [.. Enumerable.Range(0, cols).Select(c => xs[c + 1] - xs[c])], true, bounds)
        {
            RowHeights = [.. Enumerable.Range(0, rows).Select(r => ys[r + 1] - ys[r])],
        };
    }

    private static List<DocParagraph> CellParagraphs(List<ExportLine> lines, RectD cell, double body)
    {
        var items = lines.OrderBy(l => Math.Round(l.Box.Y)).ThenBy(l => l.Box.X).Select(l => new Item(l.Box, l, null) { Column = cell }).ToList();
        return [.. Spaced(Flow(items, body)).OfType<DocParagraph>()];
    }

    // ---- paragraphs ----

    /// <summary>Lines in reading order joined into paragraphs; tables and pictures pass through.</summary>
    private static List<DocBlock> Flow(List<Item> ordered, double body)
    {
        ordered = JoinRows(ordered);
        var blocks = new List<DocBlock>();
        var cur = new List<ExportLine>();
        RectD column = default;
        // Where the text of each column ends on the right: its longest line (justified text reaches it on every line).
        var textRight = ordered.Where(i => i.Line is not null).GroupBy(i => i.Column ?? i.Box)
            .ToDictionary(g => g.Key, g => g.Max(i => i.Box.Right));
        var blockRight = BlockRights(ordered, textRight);
        void Flush()
        {
            if (cur.Count > 0) blocks.Add(Paragraph(cur, column, body));
            cur = [];
        }
        foreach (var item in ordered)
        {
            if (item.Block is { } b)
            {
                Flush();
                blocks.Add(b);
                continue;
            }
            var line = item.Line!;
            if (cur.Count > 0 && Continues(cur, line, column, blockRight.GetValueOrDefault(cur[^1], textRight.GetValueOrDefault(column, column.Right)))) cur.Add(line);
            else
            {
                Flush();
                cur.Add(line);
                column = item.Column ?? line.Box;
            }
        }
        Flush();
        return blocks;
    }

    /// <summary>
    /// Pieces of text side by side on one row of a column (a form's labels under their fill-in lines, choices with their
    /// boxes, a label and its value) as one line, a tab before each piece after the first: they export as one paragraph
    /// with tab stops where the pieces started, instead of a staircase of paragraphs. Not two pieces of prose (several
    /// words each, both wide): blocks of text side by side stay apart.
    /// </summary>
    private static List<Item> JoinRows(List<Item> ordered)
    {
        var result = new List<Item>(ordered.Count);
        for (var i = 0; i < ordered.Count;)
        {
            var item = ordered[i];
            if (item.Line is null)
            {
                result.Add(item);
                i++;
                continue;
            }
            var group = new List<Item> { item };
            double top = item.Box.Y, bottom = item.Box.Bottom;
            var j = i + 1;
            for (; j < ordered.Count; j++)
            {
                var next = ordered[j];
                if (next.Line is null || next.Column != item.Column || next.Box.CenterY < top || next.Box.CenterY > bottom) break;
                group.Add(next);
                (top, bottom) = (Math.Min(top, next.Box.Y), Math.Max(bottom, next.Box.Bottom));
            }
            group.Sort((a, b) => a.Box.X.CompareTo(b.Box.X));
            var width = (item.Column ?? item.Box).Width;
            var overlapping = group.Zip(group.Skip(1)).Any(p => p.Second.Box.X < p.First.Box.Right - 1);
            var prose = group.Count(g => g.Box.Width >= 0.3 * width && Letters().Matches(g.Line!.Text).Count >= 4
                                          && !g.Line.Text.Any(ExportGlyphs.IsLeader) && InParagraph(ordered, g, group)) >= 2;
            if (group.Count == 1 || overlapping || prose)
            {
                result.AddRange(ordered.Skip(i).Take(j - i));
                i = j;
                continue;
            }
            var spans = new List<ExportSpan>(group[0].Line!.Spans);
            foreach (var g in group.Skip(1))
            {
                var first = g.Line!.Spans[0];
                spans.Add(first with { Text = "\t", Box = new RectD(g.Box.X, g.Box.Y, 0, g.Box.Height) });
                spans.AddRange(g.Line.Spans);
            }
            var line = ExportLine.Of(spans);
            result.Add(new Item(line.Box, line, null) { Column = item.Column });
            i = j;
        }
        return result;
    }

    /// <summary>A line of the same size right above or below the piece, under it: the piece is a line of a paragraph.</summary>
    private static bool InParagraph(List<Item> ordered, Item piece, List<Item> row) => ordered.Any(o =>
            o.Line is { } l && !row.Contains(o) && Math.Abs(l.Size - piece.Line!.Size) <= 0.12 * piece.Line.Size
            && Math.Min(o.Box.Right, piece.Box.Right) - Math.Max(o.Box.X, piece.Box.X) > 0.5 * Math.Min(o.Box.Width, piece.Box.Width)
            && Math.Max(o.Box.Y - piece.Box.Bottom, piece.Box.Y - o.Box.Bottom) is var gap && gap > -0.5 * l.Size && gap < 0.65 * l.Size);

    /// <summary>A line laid out with tabs (pieces of a row, a leader): it is a paragraph of its own.</summary>
    private static bool Tabbed(ExportLine line) => line.Text.Any(c => c == '\t' || ExportGlyphs.IsLeader(c));

    /// <summary>
    /// Where each line's block of text ends on the right. A block is a run of lines one under the other, close together
    /// and starting about level; when most of its lines reach the same right edge (justified or filled text, such as an
    /// indented abstract or quote) that edge is the block's own, else the column's (short lines: an address).
    /// </summary>
    private static Dictionary<ExportLine, double> BlockRights(List<Item> ordered, Dictionary<RectD, double> textRight)
    {
        var result = new Dictionary<ExportLine, double>(ReferenceEqualityComparer.Instance);
        var block = new List<ExportLine>();
        RectD? blockColumn = null;
        void Close()
        {
            if (block.Count == 0) return;
            var column = blockColumn ?? block[0].Box;
            var right = textRight.GetValueOrDefault(column, column.Right);
            if (block.Count >= 3)
            {
                var max = block.Max(l => l.Box.Right);
                var size = block[0].Size;
                var reach = block.Take(block.Count - 1).Count(l => l.Box.Right >= max - 2 * size);
                if (reach >= 2 && reach >= 0.6 * (block.Count - 1)) right = max;
            }
            foreach (var l in block) result[l] = right;
            block.Clear();
        }
        foreach (var item in ordered)
        {
            if (item.Line is not { } line)
            {
                Close();
                continue;
            }
            if (block.Count > 0)
            {
                var prev = block[^1];
                var size = Math.Max(1, prev.Size);
                if (item.Column != blockColumn || line.Box.Y < prev.Box.Y + 0.5 * prev.Box.Height
                    || line.Box.Y - prev.Box.Bottom > size || Math.Abs(line.Box.X - prev.Box.X) > 3 * size)
                    Close();
            }
            if (block.Count == 0) blockColumn = item.Column;
            block.Add(line);
        }
        Close();
        return result;
    }

    /// <summary>
    /// Whether <paramref name="line"/> carries on the paragraph so far (rather than starting a new one).
    /// <paramref name="textRight"/>: where the column's lines end at the most.
    /// </summary>
    private static bool Continues(List<ExportLine> cur, ExportLine line, RectD column, double textRight)
    {
        var prev = cur[^1];
        var size = prev.Size;
        if (Tabbed(prev) || Tabbed(line)) return false;
        if (Math.Abs(size - line.Size) > Math.Max(1, 0.12 * size)) return false;
        if (ListMarker(line.Text) is not null) return false;
        if (line.Box.Y < prev.Box.Y + 0.5 * prev.Box.Height) return false;          // not below
        if (line.Box.X > prev.Box.Right || line.Box.Right < prev.Box.X) return false; // not under it
        var gap = line.Box.Y - prev.Box.Bottom;
        if (gap > 0.65 * size) return false;
        if (cur.Count >= 2 && gap > cur[1].Box.Y - cur[0].Box.Bottom + 0.35 * size) return false;
        if (IsBold(prev) && !IsBold(line)) return false; // a bold line over plain text: a heading or label
        // The line before ended short: its last word was followed by room for this line's first word (an address, a
        // paragraph's last line). Word widths are estimated from the line's average character width.
        var text = line.Text.TrimStart();
        var charWidth = line.Box.Width / Math.Max(1, line.Text.Length);
        var firstWord = text.IndexOf(' ') is var sp and > 0 ? sp : text.Length;
        if (prev.Box.Right + (firstWord + 1) * charWidth < textRight - 0.5 * size) return false;
        var marker = ListMarker(cur[0].Text) is not null;
        if (marker) return line.Box.X >= cur[0].Box.X - 1 && line.Box.X <= cur[0].Box.X + 4 * size;
        var left = cur.Count == 1 ? Math.Min(prev.Box.X, line.Box.X) : cur.Skip(1).Min(l => l.Box.X);
        return line.Box.X <= left + 1.2 * size;

        static bool IsBold(ExportLine l) => l.Spans.Where(s => !string.IsNullOrWhiteSpace(s.Text)).All(s => s.Bold);
    }

    private static DocParagraph Paragraph(List<ExportLine> lines, RectD column, double body)
    {
        var runs = new List<ExportSpan>();
        var tabs = new List<DocTab>();
        foreach (var line in lines)
        {
            // Tabs between a row's pieces start text where the piece did; a leader is a tab filled up to where it ended
            // (a right stop), or, with text after it in the same piece ("Signature ____ Date ____"), up to where that
            // text starts (a left stop), so the text stays where it was and the rule keeps its length. A number after it
            // (a page number after dots) ends at the right edge as it did.
            var spans = line.Spans.Select((sp, k) =>
            {
                if (sp.Text == "\t") tabs.Add(new DocTab(sp.Box.X - column.X, false, '\0'));
                else if (sp.Text.Length == 1 && ExportGlyphs.IsLeader(sp.Text[0]))
                {
                    var fill = sp.Text[0] switch { ExportGlyphs.LineLeader => '_', ExportGlyphs.DashLeader => '-', _ => '.' };
                    // What follows: text, a row's next piece (a tab) or another leader end the rule where it ended.
                    var next = line.Spans.Skip(k + 1).FirstOrDefault(n => n.Text == "\t" || !string.IsNullOrWhiteSpace(n.Text));
                    tabs.Add(next is null || next.Text == "\t" || ExportGlyphs.IsLeader(next.Text[0]) || ExportLine.NumberLike(next.Text)
                        ? new DocTab(sp.Box.Right - column.X, true, fill)
                        : new DocTab(next.Box.X - column.X, false, fill));
                    return sp with { Text = "\t" };
                }
                return sp;
            }).ToList();
            if (runs.Count > 0)
            {
                var last = runs[^1].Text.TrimEnd();
                var next = line.Text.TrimStart();
                if (last.Length >= 2 && last[^1] == SoftHyphen && char.IsLetter(last[^2]))
                    runs[^1] = runs[^1] with { Text = last[..^1] };                // a hyphenation point: "educa­" + "tion"
                else if (last.Length >= 2 && last[^1] == '-' && char.IsLetter(last[^2]) && next.Length > 0 && char.IsLower(next[0]))
                    runs[^1] = runs[^1] with { Text = last[..^1] + LineHyphen };   // "exam-" + "ple": Dehyphenate decides
                else if (!char.IsWhiteSpace(runs[^1].Text.LastOrDefault(' ')))
                    runs[^1] = runs[^1] with { Text = runs[^1].Text + " " };
            }
            foreach (var s in spans) Add(runs, s);
        }
        // Soft hyphens inside a line are invisible break points: not text.
        for (var i = 0; i < runs.Count; i++)
            if (runs[i].Text.Contains(SoftHyphen)) runs[i] = runs[i] with { Text = runs[i].Text.Replace(SoftHyphen.ToString(), "") };
        // Trim the ends (spaces only: a leader at the end is a tab that stays).
        static bool Blank(ExportSpan r) => r.Text.All(c => c != '\t' && char.IsWhiteSpace(c));
        while (runs.Count > 0 && Blank(runs[0])) runs.RemoveAt(0);
        while (runs.Count > 0 && Blank(runs[^1])) runs.RemoveAt(runs.Count - 1);
        if (runs.Count > 0)
        {
            runs[0] = runs[0] with { Text = runs[0].Text.TrimStart(Spaces) };
            runs[^1] = runs[^1] with { Text = runs[^1].Text.TrimEnd(Spaces) };
        }

        var box = lines.Select(l => l.Box).Aggregate((a, b) => a.Union(b));
        var size = WeightedSize(runs, lines[0].Size);
        var list = ListKind.None;
        var marker = ListMarker(lines[0].Text);
        if (marker is { } m)
        {
            list = m.Bullet ? ListKind.Bullet : ListKind.Marker;
            if (m.Bullet) StripMarker(runs);
        }

        var first = lines[0].Box.X - column.X;
        var rest = lines.Count > 1 ? lines.Skip(1).Min(l => l.Box.X) - column.X : first;
        var align = TextAlign.Left;
        if (list == ListKind.None && column.Width > 0 && tabs.Count == 0)
        {
            var tol = Math.Max(3, 0.03 * column.Width);
            if (lines.All(l => Math.Abs(l.Box.CenterX - column.CenterX) <= tol) && first > 2 * size) align = TextAlign.Center;
            else if (lines.All(l => Math.Abs(l.Box.Right - column.Right) <= 3) && first > 0.4 * column.Width) align = TextAlign.Right;
        }
        double indent = 0, firstLine = 0;
        if (align == TextAlign.Left)
        {
            if (list != ListKind.None)
            {
                indent = Math.Max(0, first);
            }
            else
            {
                indent = Math.Max(0, Math.Min(first, rest));
                firstLine = lines.Count > 1 ? first - rest : 0;
                if (Math.Abs(firstLine) < 0.5 * size) firstLine = 0;
                if (indent < 0.5 * size) indent = 0;
            }
        }
        return new DocParagraph(runs, box)
        {
            Size = size, LineCount = lines.Count, List = list, Align = align, Indent = indent, FirstLine = firstLine, Tabs = tabs,
            LinePitch = lines.Count > 1 ? (lines[^1].Box.Y - lines[0].Box.Y) / (lines.Count - 1) : 0,
            Sources = [.. lines.SelectMany(l => l.Spans).Where(s => s.PageBox is not null).Select(s => s.PageBox!.Value)],
        };
    }

    /// <summary>Whitespace to trim at a paragraph's ends: all but the tab (a leader or a row's piece may end it).</summary>
    private static readonly char[] Spaces = [' ', '\u00A0', '\u2002', '\u2003', '\u2009', '\u202F', '\r', '\n'];

    private static void Add(List<ExportSpan> runs, ExportSpan s)
    {
        if (s.Text.Length == 0) return;
        if (runs.Count > 0 && (runs[^1].SameLook(s) || string.IsNullOrWhiteSpace(s.Text)))
            runs[^1] = runs[^1] with { Text = runs[^1].Text + s.Text, Box = runs[^1].Box.Union(s.Box) };
        else runs.Add(s);
    }

    private static double WeightedSize(List<ExportSpan> runs, double fallback)
    {
        var groups = runs.Where(r => r.Text.Any(c => !char.IsWhiteSpace(c)))
            .GroupBy(r => Math.Round(r.Size * 2) / 2).Select(g => (Size: g.Key, N: g.Sum(r => r.Text.Length))).ToList();
        return groups.Count == 0 ? fallback : groups.MaxBy(g => g.N).Size;
    }

    /// <summary>Removes a leading bullet character and the spaces after it (Word draws its own bullet).</summary>
    private static void StripMarker(List<ExportSpan> runs)
    {
        var removed = false;
        while (runs.Count > 0)
        {
            var t = runs[0].Text.TrimStart();
            if (!removed && t.Length > 0 && Bullets.Contains(t[0]))
            {
                t = t[1..];
                removed = true;
            }
            t = t.TrimStart();
            if (t.Length > 0)
            {
                runs[0] = runs[0] with { Text = t };
                return;
            }
            runs.RemoveAt(0);
        }
    }

    private const string Bullets = "•◦▪▫‣⁃●○■□►▶➢❖✓✔–—-*·";

    /// <summary>The list marker a line starts with, if any: a bullet, or a number/letter followed by "." or ")".</summary>
    public static (bool Bullet, string Marker)? ListMarker(string text)
    {
        var t = text.TrimStart();
        if (t.Length >= 2 && Bullets.Contains(t[0]) && (char.IsWhiteSpace(t[1]) || t[0] is '•' or '●' or '▪' or '■' or ''))
        {
            var rest = t[1..].TrimStart();
            if (rest.Length > 0 && !Bullets.Contains(rest[0])) return (true, t[..1]);
            return null;
        }
        var m = NumberMarker().Match(t);
        return m.Success ? (false, m.Groups["m"].Value) : null;
    }

    /// <summary>Whether the text is only a list marker ("•", "1.", "a)"), so the item's text is a separate line beside it.</summary>
    private static bool IsMarkerOnly(string text)
    {
        var t = text.Trim();
        return t.Length is > 0 and <= 5 && ((t.Length == 1 && Bullets.Contains(t[0])) || NumberMarker().IsMatch(t + " X"));
    }

    // "1." "a)" "(iv)" "7.2.1." before any text, or "8.1" before a capital (not "3.5 percent").
    [GeneratedRegex(@"^(?<m>\(?(?:\d{1,3}|[a-zA-Z]|[ivxIVX]{1,5})[.)]|\d{1,3}(?:\.\d{1,3})+\.)\s+\S|^(?<m>\d{1,3}(?:\.\d{1,3})+)\s+\p{Lu}")]
    private static partial Regex NumberMarker();

    // ---- running headers and footers ----

    /// <summary>
    /// Lines in the top or bottom tenth of the page that repeat (digits and roman numerals aside) on at least half the
    /// pages, two at least, with no other page text on their row: taken off the pages and returned as header and footer
    /// rows. A number that changes from page
    /// to page becomes <see cref="PageField"/>.
    /// </summary>
    private static (List<ExportPage> Pages, DocRunning? Header, DocRunning? Footer) Running(IReadOnlyList<ExportPage> pages)
    {
        if (pages.Count < 2) return ([.. pages], null, null);
        var seen = new Dictionary<(bool Top, string Key), List<(int Page, ExportLine Line)>>();
        var seenPictures = new Dictionary<(bool Top, string Key), List<(int Page, ExportImage Image)>>();
        for (var i = 0; i < pages.Count; i++)
        {
            var page = pages[i];
            foreach (var line in page.Lines)
            {
                if (line.Sideways || string.IsNullOrWhiteSpace(line.Text)) continue;
                var top = line.Box.Bottom <= page.Height * 0.12;
                if (!top && line.Box.Y < page.Height * 0.88) continue;
                var key = (top, RunningKey().Replace(line.Text.Trim(), "#"));
                if (!seen.TryGetValue(key, out var list)) seen[key] = list = [];
                if (list.Count == 0 || list[^1].Page != i) list.Add((i, line));
            }
            // The same picture (a logo) in the same place; the writer stores equal pictures once, so they share a Ref.
            foreach (var img in page.Images)
            {
                if (img.Ref is null) continue;
                var top = img.Box.Bottom <= page.Height * 0.12;
                if (!top && img.Box.Y < page.Height * 0.88) continue;
                var key = (top, $"{img.Ref}@{Math.Round(img.Box.X / 4)},{Math.Round(img.Box.Y / 4)},{Math.Round(img.Box.Width / 4)}");
                if (!seenPictures.TryGetValue(key, out var list)) seenPictures[key] = list = [];
                if (list.Count == 0 || list[^1].Page != i) list.Add((i, img));
            }
        }
        var need = Math.Max(2, (int)Math.Ceiling(pages.Count / 2.0));
        var running = seen.Where(kv => kv.Value.Count >= need).ToDictionary(kv => kv.Key, kv => kv.Value);
        // A line with page text beside it on its row (an item number at the top of a form) is part of the page.
        // Lines repeated on two pages or more (a chapter title on odd pages, the book's on even ones) are header-like too.
        var candidates = seen.Values.Where(v => v.Count >= 2).SelectMany(v => v).Select(x => x.Line).ToHashSet(ReferenceEqualityComparer.Instance);
        bool Alone(int page, ExportLine line) => !pages[page].Lines.Any(o =>
            !ReferenceEquals(o, line) && !o.Sideways && !string.IsNullOrWhiteSpace(o.Text) && !candidates.Contains(o)
            && Math.Min(o.Box.Bottom, line.Box.Bottom) - Math.Max(o.Box.Y, line.Box.Y) > 0.5 * Math.Min(o.Box.Height, line.Box.Height));
        running = running.Select(kv => (kv.Key, Value: kv.Value.Where(x => Alone(x.Page, x.Line)).ToList()))
            .Where(kv => kv.Value.Count >= need).ToDictionary(kv => kv.Key, kv => kv.Value);
        var runningPictures = seenPictures.Where(kv => kv.Value.Count >= need).ToDictionary(kv => kv.Key, kv => kv.Value);
        if (running.Count == 0 && runningPictures.Count == 0) return ([.. pages], null, null);

        var drop = running.Values.SelectMany(v => v).Select(x => (object)x.Line)
            .Concat(runningPictures.Values.SelectMany(v => v).Select(x => (object)x.Image))
            .ToHashSet(ReferenceEqualityComparer.Instance);
        var stripped = pages.Select(p => p.Lines.Any(drop.Contains) || p.Images.Any(drop.Contains)
            ? p with { Lines = [.. p.Lines.Where(l => !drop.Contains(l))], Images = [.. p.Images.Where(i => !drop.Contains(i))] }
            : p).ToList();
        return (stripped, Rows(true), Rows(false));

        static TextAlign Zone(RectD box, double width) =>
            box.CenterX < width * 0.36 ? TextAlign.Left : box.CenterX > width * 0.64 ? TextAlign.Right : TextAlign.Center;

        DocRunning? Rows(bool top)
        {
            var groups = running.Where(kv => kv.Key.Top == top).Select(kv => kv.Value).ToList();
            List<(TextAlign, ExportImage)> pictures = [.. runningPictures.Where(kv => kv.Key.Top == top)
                .Select(kv => (Page: kv.Value[0].Page, kv.Value[0].Image)).OrderBy(x => x.Image.Box.X)
                .Select(x => (Zone(x.Image.Box, pages[x.Page].Width), x.Image))];
            var onPages = groups.SelectMany(g => g.Select(x => x.Page))
                .Concat(runningPictures.Where(kv => kv.Key.Top == top).SelectMany(kv => kv.Value.Select(x => x.Page))).ToHashSet();
            if (groups.Count == 0) return pictures.Count == 0 ? null : new DocRunning([]) { Pictures = pictures, OnPages = onPages };
            // Shown as on the first page that has them; numbers that differ between two occurrences are the page number.
            var first = groups.Min(g => g[0].Page);
            var lines = groups.Where(g => g[0].Page == first).Select(g =>
            {
                var line = g[0].Line;
                var text = line.Text.Trim();
                if (g.Count > 1)
                {
                    var a = RunningKey().Matches(text);
                    var b = RunningKey().Matches(g[1].Line.Text.Trim());
                    for (var k = Math.Min(a.Count, b.Count) - 1; k >= 0; k--)
                        if (a[k].Value != b[k].Value) text = text[..a[k].Index] + PageField + text[(a[k].Index + a[k].Length)..];
                }
                var look = line.Spans.FirstOrDefault(s => !string.IsNullOrWhiteSpace(s.Text)) ?? line.Spans[0];
                return (Line: line, Span: look with { Text = text, Box = line.Box });
            }).OrderBy(x => x.Line.Box.Y).ToList();
            var width = pages[first].Width;
            var rows = new List<DocRunningRow>();
            foreach (var (line, span) in lines)
            {
                var zone = Zone(line.Box, width);
                if (rows.Count > 0 && rows[^1].Parts[^1].Span.Box is var prev && line.Box.Y < prev.Bottom && line.Box.Bottom > prev.Y)
                    rows[^1] = new DocRunningRow([.. rows[^1].Parts, (zone, span)]);
                else rows.Add(new DocRunningRow([(zone, span)]));
            }
            return new DocRunning([.. rows.Select(r => new DocRunningRow([.. r.Parts.OrderBy(p => p.Span.Box.X)]))])
            {
                Pictures = pictures, OnPages = onPages,
            };
        }
    }

    [GeneratedRegex(@"\d+|\b[IVXLCDM]+\b|\b[ivxlcdm]+\b")]
    private static partial Regex RunningKey();

    // ---- headings ----

    /// <summary>
    /// Paragraphs in larger type than the body text (short ones: a heading is at most three lines) become headings: the
    /// largest size used for one is level 1, the next level 2, and so on (sizes within 0.75 pt count as one).
    /// </summary>
    private const char SoftHyphen = '­';

    /// <summary>Stands for a hyphen at the end of a line, before a lowercase letter, until <see cref="Dehyphenate"/> decides.</summary>
    private const char LineHyphen = '';

    /// <summary>
    /// Settles each hyphen that ended a line before a lowercase word: kept ("equivalence-adjusted") when the document
    /// hyphenates with soft hyphens (so a hard one is real), or when both halves are words the document uses and the
    /// joined word isn't; otherwise dropped ("exam-" + "ple" → "example"). The document's words leave out each line's
    /// first word and a hyphenated last word, which may be halves.
    /// </summary>
    private static List<DocPage> Dehyphenate(List<DocPage> pages, IReadOnlyList<ExportPage> source)
    {
        var soft = false;
        var words = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in source.SelectMany(p => p.Lines))
        {
            var text = line.Text;
            if (text.Contains(SoftHyphen)) soft = true;
            var tokens = Letters().Matches(text);
            var end = text.TrimEnd();
            var last = end.EndsWith('-') || end.EndsWith(SoftHyphen) ? tokens.Count - 1 : tokens.Count;
            for (var i = 1; i < last; i++) words.Add(tokens[i].Value);
        }
        DocParagraph Fix(DocParagraph p)
        {
            if (!p.Runs.Any(r => r.Text.Contains(LineHyphen))) return p;
            var text = p.Text;
            var keep = new Queue<bool>();
            for (var i = text.IndexOf(LineHyphen); i >= 0; i = text.IndexOf(LineHyphen, i + 1))
            {
                var a = i;
                while (a > 0 && char.IsLetter(text[a - 1])) a--;
                var b = i + 1;
                while (b < text.Length && char.IsLetter(text[b])) b++;
                var (left, right) = (text[a..i], text[(i + 1)..b]);
                keep.Enqueue(soft || (!words.Contains(left + right) && words.Contains(left) && words.Contains(right)));
            }
            var runs = p.Runs.Select(r =>
            {
                if (!r.Text.Contains(LineHyphen)) return r;
                var sb = new System.Text.StringBuilder();
                foreach (var c in r.Text)
                {
                    if (c != LineHyphen) sb.Append(c);
                    else if (keep.Dequeue()) sb.Append('-');
                }
                return r with { Text = sb.ToString() };
            }).ToList();
            return p with { Runs = runs };
        }
        DocBlock FixBlock(DocBlock b) => b switch
        {
            DocParagraph p => Fix(p),
            DocTable t => t with { Rows = [.. t.Rows.Select(r => (IReadOnlyList<DocCell>)[.. r.Select(c => c with { Paragraphs = [.. c.Paragraphs.Select(Fix)] })])] },
            _ => b,
        };
        return [.. pages.Select(pg => pg with { Blocks = [.. pg.Blocks.Select(FixBlock)] })];
    }

    [GeneratedRegex(@"\p{L}+")]
    private static partial Regex Letters();

    private static List<DocPage> AssignHeadings(List<DocPage> pages, double body)
    {
        static bool Candidate(DocParagraph p, double body) =>
            p.Size >= body * 1.15 && p.Size >= body + 1 && p.LineCount <= 3 && p.List == ListKind.None
            && p.Text.Trim().Length is > 0 and <= 200;
        var sizes = pages.SelectMany(p => p.Blocks.OfType<DocParagraph>()).Where(p => Candidate(p, body))
            .Select(p => p.Size).Distinct().OrderDescending().ToList();
        if (sizes.Count == 0) return pages;
        var levels = new List<double>();
        foreach (var s in sizes)
            if (levels.Count == 0 || levels[^1] - s > 0.75) levels.Add(s);
        int Level(double size)
        {
            var i = levels.FindIndex(l => size >= l - 0.75);
            return Math.Min(6, (i < 0 ? levels.Count - 1 : i) + 1);
        }
        return [.. pages.Select(page => page with
        {
            Blocks = [.. page.Blocks.Select(b => b is DocParagraph p && Candidate(p, body) ? p with { HeadingLevel = Level(p.Size) } : b)],
        })];
    }
}
