using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>A form field <see cref="FieldDetection"/> proposes: where, what kind, and a name taken from its label.</summary>
/// <param name="Source">What it was found from: "underscores", "line", "box", "square" or "box character".</param>
public sealed record FieldSuggestion(int PageIndex, RectD Rect, DesignFieldKind Kind, string Name, bool Multiline, string Source);

/// <summary>
/// Proposes form fields from what a page shows: runs of underscores ("Name: ______") and ruled lines become text fields
/// (signature fields when their label says "signature"), empty boxes become text fields (multi-line when tall), and small
/// squares (drawn, or ☐ characters) become check boxes. Each is named after the text beside it (left, else above or
/// below; right of a check box). Boxes holding text, lines underlining text, page frames and places already holding a
/// field are skipped. Pure geometry over the page's text and <see cref="VectorShapes"/>.
/// </summary>
public static class FieldDetection
{
    private static readonly char[] BoxGlyphs = ['☐', '□', '❏', '❐', '❑', '❒', '▢', '◻', '⬜'];

    private readonly record struct Ch(char C, RectD Box, int Line);

    /// <summary>
    /// Suggestions for <paramref name="pages"/> of an open document (its text from <paramref name="engine"/>, its shapes
    /// from <paramref name="data"/>), skipping places <paramref name="existing"/> fields cover; names are unique across them.
    /// </summary>
    public static IReadOnlyList<FieldSuggestion> Suggest(PdfEngine engine, byte[] data, string? password, IEnumerable<int> pages,
        IReadOnlyList<DesignField> existing, CancellationToken cancel = default, IProgress<(int Done, int Total)>? progress = null)
    {
        var names = existing.Select(f => f.Name).ToList();
        var result = new List<FieldSuggestion>();
        using var doc = PdfObj.Open(data, password, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import, "This PDF's pages can't be read");
        var list = pages.ToList();
        var done = 0;
        foreach (var p in list)
        {
            cancel.ThrowIfCancellationRequested();
            progress?.Report((done++, list.Count));
            var g = engine.GetPage(p);
            var found = Suggest(p, g.Width, g.Height, engine.GetText(p, cache: false, cancel), VectorShapes.Read(doc, p, cancel),
                [.. existing.Where(f => f.PageIndex == p).Select(f => f.Rect)], names, cancel);
            names.AddRange(found.Select(s => s.Name));
            result.AddRange(found);
        }
        return result;
    }

    /// <summary>Suggestions for one page, in reading order, named uniquely among <paramref name="existingNames"/> and each other.</summary>
    public static IReadOnlyList<FieldSuggestion> Suggest(int pageIndex, double pageWidth, double pageHeight, PageText text,
        IReadOnlyList<PageShape> shapes, IReadOnlyList<RectD> existingFields, IEnumerable<string> existingNames, CancellationToken cancel = default)
    {
        var chars = new CharIndex(Chars(text));
        var found = new List<(RectD Rect, DesignFieldKind Kind, string Label, bool Multiline, string Source)>();
        var captions = new HashSet<string>(StringComparer.Ordinal); // labels read right of their field (their first words count)

        // Boxes first: they decide which rules are only their edges.
        var boxes = Boxes(shapes, pageWidth, pageHeight, cancel);
        var boxGrid = new RectGrid();
        foreach (var b in boxes)
        {
            cancel.ThrowIfCancellationRequested();
            boxGrid.Add(b);
            if (chars.Near(b).Any(c => !char.IsWhiteSpace(c.C) && b.Inflate(-1).Contains(c.Box.CenterX, c.Box.CenterY))) continue; // holds text
            if (IsSquare(b))
                found.Add((b, DesignFieldKind.CheckBox, Caption(LabelRight(chars, b)) ?? LabelLeft(chars, b, 120) ?? "", false, "square"));
            else if (b.Height >= 10 && b.Width >= 24 && b.Height <= Math.Min(400, pageHeight * 0.6))
            {
                var label = LabelLeft(chars, b, 150) ?? LabelAbove(chars, b) ?? "";
                found.Add((b, KindFor(label), label, b.Height >= 36, "box"));
            }
        }

        // ☐ characters.
        foreach (var c in chars.All.Where(c => BoxGlyphs.Contains(c.C)))
        {
            cancel.ThrowIfCancellationRequested();
            var side = Math.Max(6, Math.Min(c.Box.Width, c.Box.Height) * 0.9);
            var r = new RectD(c.Box.CenterX - side / 2, c.Box.CenterY - side / 2, side, side);
            found.Add((r, DesignFieldKind.CheckBox, Caption(LabelRight(chars, r)) ?? LabelLeft(chars, r, 120) ?? "", false, "box character"));
        }

        // Runs of underscores: a field on the run, named after the text before it on the line.
        var all = chars.All;
        for (var i = 0; i < all.Count; i++)
        {
            if (all[i].C != '_') continue;
            cancel.ThrowIfCancellationRequested();
            var j = i;
            while (j + 1 < all.Count && all[j + 1].C == '_' && all[j + 1].Line == all[i].Line) j++;
            if (j - i + 1 >= 3)
            {
                var run = all[i].Box;
                for (var k = i + 1; k <= j; k++) run = run.Union(all[k].Box);
                // The rule of an underscore lies near the baseline; character boxes end at the descender or, with
                // some embedded fonts, above the baseline: reach a little below the box either way.
                var bottom = run.Bottom + run.Height * 0.3;
                var height = Math.Clamp(run.Height * 1.3, 12, 24);
                var r = RectD.FromEdges(run.X, bottom - height, run.Right, bottom);
                var label = TextBefore(all, i) ?? LabelBelow(chars, r) ?? LabelAbove(chars, r) ?? "";
                found.Add((r, KindFor(label), label, false, "underscores"));
            }
            i = j;
        }

        // Ruled lines: a field standing on the line.
        foreach (var line in Rules(shapes, cancel))
        {
            if (line.Width < 30) continue;
            if (boxGrid.Near(line.Inflate(2)).Any(b => OnEdge(line, b))) continue;
            // Underlined text, or a rule just below a line of text: not a blank to fill.
            var above = chars.Near(RectD.FromEdges(line.X, line.Y - 24, line.Right, line.Y + 2))
                .Where(c => !char.IsWhiteSpace(c.C) && c.Box.Right > line.X && c.Box.X < line.Right && c.Box.Bottom <= line.Y + 2 && c.Box.Bottom > line.Y - 24).ToList();
            var covered = above.Where(c => c.Box.Bottom > line.Y - 6).Sum(c => Math.Min(c.Box.Right, line.Right) - Math.Max(c.Box.X, line.X));
            if (covered > line.Width * 0.2) continue;
            var free = above.Count == 0 ? 24 : line.Y - above.Max(c => c.Box.Bottom);
            var height = Math.Min(20, free - 2);
            if (height < 9) continue;
            var r = RectD.FromEdges(line.X, line.Y - height, line.Right, line.Y);
            var left = LabelLeft(chars, r, 90);
            if (left is null && line.Width > pageWidth * 0.75) continue; // a separator across the page
            var label = left ?? LabelBelow(chars, r) ?? "";
            found.Add((r, KindFor(label), label, false, "line"));
        }

        string? Caption(string? label)
        {
            if (label is not null) captions.Add(label);
            return label;
        }

        // Drop what overlaps an existing field or an earlier suggestion (boxes win over the rules and runs inside them).
        var taken = new RectGrid();
        foreach (var e in existingFields) taken.Add(e);
        var kept = new List<(RectD Rect, DesignFieldKind Kind, string Label, bool Multiline, string Source)>();
        foreach (var s in found)
        {
            cancel.ThrowIfCancellationRequested();
            if (taken.Near(s.Rect).Any(k => Overlaps(k, s.Rect, 0.3))) continue;
            taken.Add(s.Rect);
            kept.Add(s);
        }

        var names = existingNames.ToList();
        var result = new List<FieldSuggestion>();
        foreach (var s in kept.OrderBy(k => Math.Round(k.Rect.Y / 6)).ThenBy(k => k.Rect.X))
        {
            var clean = CleanLabel(s.Label, captions.Contains(s.Label));
            var name = clean.Length > 0 ? FormDesign.UniqueName(names, clean) : FormDesign.NextName(names, s.Kind);
            names.Add(name);
            result.Add(new FieldSuggestion(pageIndex, s.Rect, s.Kind, name, s.Multiline, s.Source));
        }
        return result;
    }

    /// <summary>
    /// A field name from a label: "1. Date of birth (dd/mm):" → "Date of birth"; dots (which nest names) and stray
    /// punctuation go. A long label keeps the five words nearest the field: its last words, or with
    /// <paramref name="leading"/> (a caption right of the field) its first.
    /// </summary>
    public static string CleanLabel(string label, bool leading = false)
    {
        // "(mm/dd/yyyy)" and list numbering ("1.", "b)") aren't part of the name.
        label = Regex.Replace(label, @"\([^)]*\)?", " ");
        label = Regex.Replace(label, @"^\s*(\d+|[A-Za-z]|[ivxIVX]+)[.)]\s+", "");
        var sb = new StringBuilder();
        foreach (var c in label)
        {
            if (char.IsLetterOrDigit(c) || c is '-' or '\'' or '/' or '&' or '#') sb.Append(c);
            else if (char.IsWhiteSpace(c) || c is '.' or ',' or '_' or '(' or ')') sb.Append(' ');
        }
        var words = sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // The words nearest the field: at most five (a long instruction sentence makes a poor name).
        var name = string.Join(' ', leading ? words.Take(5) : words.TakeLast(5)).Trim('-', '/', '&', '\'', '#', ' ');
        return name.Length > 40 ? name[..40].TrimEnd() : name;
    }

    private static DesignFieldKind KindFor(string label) =>
        label.Contains("signature", StringComparison.OrdinalIgnoreCase) || label.Contains("sign here", StringComparison.OrdinalIgnoreCase)
            ? DesignFieldKind.Signature : DesignFieldKind.Text;

    private static List<Ch> Chars(PageText text)
    {
        var list = new List<Ch>(text.Text.Length);
        var line = 0;
        for (var i = 0; i < text.Text.Length; i++)
        {
            var c = text.Text[i];
            if (c == '\n')
            {
                line++;
                continue;
            }
            var box = text.BoxAt(i);
            if (box.Width <= 0 && box.Height <= 0) continue;
            list.Add(new Ch(c, box, line));
        }
        return list;
    }

    /// <summary>Distinct boxes, without page frames and without boxes that hold other boxes (tables, panels).</summary>
    private static List<RectD> Boxes(IReadOnlyList<PageShape> shapes, double pageWidth, double pageHeight, CancellationToken cancel)
    {
        var all = new List<RectD>();
        var grid = new RectGrid();
        foreach (var s in shapes)
        {
            cancel.ThrowIfCancellationRequested();
            if (s.IsLine) continue;
            var b = s.Box;
            if (b.Width * b.Height > pageWidth * pageHeight * 0.4 || b.Width > pageWidth * 0.95) continue;
            if (b.Width < 5 || b.Height < 5) continue;
            if (grid.Near(b.Inflate(1)).Any(a => Same(a, b))) continue;
            grid.Add(b);
            all.Add(b);
        }
        var result = new List<RectD>();
        foreach (var b in all)
        {
            cancel.ThrowIfCancellationRequested();
            if (!grid.Near(b).Any(o => !Same(o, b) && Inside(o, b))) result.Add(b);
        }
        return result;
    }

    private static IEnumerable<RectD> Rules(IReadOnlyList<PageShape> shapes, CancellationToken cancel)
    {
        var seen = new RectGrid();
        foreach (var s in shapes)
        {
            cancel.ThrowIfCancellationRequested();
            if (!s.IsLine || seen.Near(s.Box.Inflate(1.5)).Any(r => Math.Abs(r.X - s.Box.X) < 1 && Math.Abs(r.Right - s.Box.Right) < 1 && Math.Abs(r.Y - s.Box.Y) < 1.5)) continue;
            seen.Add(s.Box);
            yield return s.Box;
        }
    }

    private static bool IsSquare(RectD b) =>
        b.Width is >= 5 and <= 24 && b.Height is >= 5 and <= 24 && Math.Abs(b.Width - b.Height) <= Math.Max(1.5, 0.15 * Math.Max(b.Width, b.Height));

    private static bool Same(RectD a, RectD b) =>
        Math.Abs(a.X - b.X) < 1 && Math.Abs(a.Y - b.Y) < 1 && Math.Abs(a.Right - b.Right) < 1 && Math.Abs(a.Bottom - b.Bottom) < 1;

    /// <summary><paramref name="inner"/> lies within <paramref name="outer"/>.</summary>
    private static bool Inside(RectD inner, RectD outer) =>
        inner.X >= outer.X - 0.5 && inner.Right <= outer.Right + 0.5 && inner.Y >= outer.Y - 0.5 && inner.Bottom <= outer.Bottom + 0.5;

    /// <summary>A rule that is the top or bottom edge of a box (or a line across its inside, as in a comb).</summary>
    private static bool OnEdge(RectD line, RectD box) =>
        line.X >= box.X - 2 && line.Right <= box.Right + 2 && line.Y >= box.Y - 2 && line.Bottom <= box.Bottom + 2;

    private static bool Overlaps(RectD a, RectD b, double share)
    {
        var i = a.Intersect(b);
        if (i.IsEmpty) return false;
        var area = i.Width * i.Height;
        return area > share * Math.Min(a.Width * a.Height, b.Width * b.Height);
    }

    /// <summary>Text on the same line before character <paramref name="index"/> (back to the previous run of underscores).</summary>
    private static string? TextBefore(IReadOnlyList<Ch> chars, int index)
    {
        var line = chars[index].Line;
        var start = index;
        while (start > 0 && chars[start - 1].Line == line && chars[start - 1].C != '_') start--;
        var s = new string([.. chars.Skip(start).Take(index - start).Select(c => c.C)]).Trim();
        return s.Length > 0 ? s : null;
    }

    /// <summary>Words on the same row ending at most <paramref name="reach"/> points left of <paramref name="r"/>.</summary>
    private static string? LabelLeft(CharIndex chars, RectD r, double reach)
    {
        var row = chars.Near(RectD.FromEdges(r.X - reach, r.Y, r.X + 2, r.Bottom)).Where(c => c.Box.Right <= r.X + 2 && c.Box.Right > r.X - reach && VerticalOverlap(c.Box, r) > Math.Min(c.Box.Height, r.Height) * 0.5).ToList();
        if (row.Count == 0) return null;
        // Only the stretch nearest the field: stop at a wide gap.
        var ordered = row.OrderByDescending(c => c.Box.X).ToList();
        var taken = new List<Ch> { ordered[0] };
        foreach (var c in ordered.Skip(1))
        {
            if (taken[^1].Box.X - c.Box.Right > Math.Max(12, c.Box.Height * 1.5)) break;
            taken.Add(c);
        }
        if (r.X - ordered[0].Box.Right > reach) return null;
        return Join(taken.OrderBy(c => c.Box.X));
    }

    /// <summary>Words on the same row starting just right of <paramref name="r"/> (a check box's caption).</summary>
    private static string? LabelRight(CharIndex chars, RectD r)
    {
        var row = chars.Near(RectD.FromEdges(r.Right - 1, r.Y, r.Right + 200, r.Bottom)).Where(c => c.Box.X >= r.Right - 1 && c.Box.X < r.Right + 200 && VerticalOverlap(c.Box, r) > Math.Min(c.Box.Height, r.Height) * 0.4)
            .OrderBy(c => c.Box.X).ToList();
        if (row.Count == 0 || row[0].Box.X - r.Right > 30) return null;
        var taken = new List<Ch> { row[0] };
        foreach (var c in row.Skip(1))
        {
            if (c.Box.X - taken[^1].Box.Right > Math.Max(12, c.Box.Height * 1.5) || BoxGlyphs.Contains(c.C)) break;
            taken.Add(c);
        }
        return Join(taken);
    }

    /// <summary>The line of text just above <paramref name="r"/> (within 20 points), over its left part.</summary>
    private static string? LabelAbove(CharIndex chars, RectD r)
    {
        var near = chars.Near(RectD.FromEdges(r.X - 4, r.Y - 20, r.Right, r.Y + 2)).Where(c => c.Box.Bottom <= r.Y + 2 && c.Box.Bottom > r.Y - 20 && c.Box.Right > r.X - 4 && c.Box.X < r.Right).ToList();
        if (near.Count == 0) return null;
        var line = near.MaxBy(c => c.Box.Bottom).Line;
        return Join(near.Where(c => c.Line == line).OrderBy(c => c.Box.X));
    }

    /// <summary>A caption just below <paramref name="r"/> (within 16 points), as under a signature line.</summary>
    private static string? LabelBelow(CharIndex chars, RectD r)
    {
        var near = chars.Near(RectD.FromEdges(r.X, r.Bottom - 1, r.Right, r.Bottom + 16)).Where(c => c.Box.Y >= r.Bottom - 1 && c.Box.Y < r.Bottom + 16 && c.Box.Right > r.X && c.Box.X < r.Right).ToList();
        if (near.Count == 0) return null;
        var line = near.MinBy(c => c.Box.Y).Line;
        return Join(near.Where(c => c.Line == line).OrderBy(c => c.Box.X));
    }

    private static double VerticalOverlap(RectD a, RectD b) => Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Y, b.Y);

    private static string? Join(IEnumerable<Ch> chars)
    {
        var s = new string([.. chars.Select(c => c.C)]).Trim();
        return s.Length > 0 ? s : null;
    }
    /// <summary>The page's characters with a <see cref="RectGrid"/> over their boxes.</summary>
    private sealed class CharIndex
    {
        private readonly RectGrid _grid = new();

        public CharIndex(List<Ch> chars)
        {
            All = chars;
            foreach (var c in chars) _grid.Add(c.Box);
        }

        public IReadOnlyList<Ch> All { get; }

        /// <summary>The characters whose boxes touch <paramref name="region"/>, in text order.</summary>
        public IEnumerable<Ch> Near(RectD region) => _grid.NearIndices(region).Select(i => All[i]);
    }
}

/// <summary>
/// Rectangles bucketed in a uniform grid, so "which boxes touch this region" costs the boxes nearby instead of all of
/// them. Boxes spanning more than a few hundred cells go into one list every query looks at.
/// </summary>
internal sealed class RectGrid(double cell = 48)
{
    private const int MaxCells = 256;
    private readonly List<RectD> _rects = [];
    private readonly Dictionary<(int, int), List<int>> _cells = [];
    private readonly List<int> _large = [];

    public int Count => _rects.Count;

    public void Add(RectD r)
    {
        var i = _rects.Count;
        _rects.Add(r);
        var (x0, y0, x1, y1) = Span(r);
        if ((long)(x1 - x0 + 1) * (y1 - y0 + 1) > MaxCells)
        {
            _large.Add(i);
            return;
        }
        for (var x = x0; x <= x1; x++)
            for (var y = y0; y <= y1; y++)
            {
                if (!_cells.TryGetValue((x, y), out var list)) _cells[(x, y)] = list = [];
                list.Add(i);
            }
    }

    /// <summary>Indices (in the order added) of the rectangles touching <paramref name="region"/>.</summary>
    public IEnumerable<int> NearIndices(RectD region)
    {
        var (x0, y0, x1, y1) = Span(region);
        var hits = new SortedSet<int>(_large);
        if ((long)(x1 - x0 + 1) * (y1 - y0 + 1) > _cells.Count)
        {
            foreach (var list in _cells.Values) hits.UnionWith(list);
        }
        else
        {
            for (var x = x0; x <= x1; x++)
                for (var y = y0; y <= y1; y++)
                    if (_cells.TryGetValue((x, y), out var list)) hits.UnionWith(list);
        }
        foreach (var i in hits)
            if (Touches(_rects[i], region)) yield return i;
    }

    public IEnumerable<RectD> Near(RectD region) => NearIndices(region).Select(i => _rects[i]);

    private static bool Touches(RectD a, RectD b) => a.X <= b.Right && a.Right >= b.X && a.Y <= b.Bottom && a.Bottom >= b.Y;

    private (int X0, int Y0, int X1, int Y1) Span(RectD r)
    {
        static int C(double v, double size) => (int)Math.Floor(Math.Clamp(v, -1e6, 1e6) / size);
        return (C(r.X, cell), C(r.Y, cell), C(r.Right, cell), C(r.Bottom, cell));
    }
}

