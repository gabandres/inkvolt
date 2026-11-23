using System.Globalization;
using System.Security.Cryptography;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>Which way a guide or snap line runs in page space: at a page x (a line down the page) or a page y (across it).</summary>
public enum GuideAxis { X, Y }

/// <summary>A guide on a page: a line at <see cref="At"/> points from the page's left (<see cref="GuideAxis.X"/>) or top.</summary>
public sealed record Guide(int Page, GuideAxis Axis, double At);

/// <summary>A line something snapped to (page space), for the view to show while it holds.</summary>
public readonly record struct SnapLine(GuideAxis Axis, double At);

/// <summary>The unit the rulers count in: its name and how many PDF points one of it is.</summary>
public sealed record RulerUnit(string Name, double PointsPer)
{
    public static readonly RulerUnit Inches = new("in", 72);
    public static readonly RulerUnit Millimeters = new("mm", 72 / 25.4);
    public static readonly RulerUnit Centimeters = new("cm", 72 / 2.54);
    public static readonly RulerUnit Points = new("pt", 1);

    /// <summary>The units Ruler Units goes through ("auto" first: the page's measurement scale, else the region's).</summary>
    public static readonly IReadOnlyList<string> Choices = ["auto", "in", "mm", "cm", "pt"];

    /// <summary>
    /// The unit for a setting (<see cref="Choices"/>): a fixed one, or "auto": the page's measurement scale when it has one
    /// (the rulers count real units, as Measure does), else inches where the region isn't metric and millimeters where it is.
    /// </summary>
    public static RulerUnit For(string setting, MeasureScale? pageScale, bool metric) => setting switch
    {
        "in" => Inches,
        "mm" => Millimeters,
        "cm" => Centimeters,
        "pt" => Points,
        _ when pageScale is { } s && s != MeasureScale.Default && s.PerUnit > 0 && double.IsFinite(s.PerUnit) => new RulerUnit(s.Unit, 1 / s.PerUnit),
        _ => metric ? Millimeters : Inches,
    };
}

/// <summary>A tick of a ruler: where (points from the page's top-left as shown), how long (0: labelled, 1: half, 2: small), its label.</summary>
public readonly record struct RulerTick(double At, int Level, string? Label);

/// <summary>
/// Rulers, guides, a grid and snapping (roadmap 4.19): what the rulers mark, where a guide dragged from a ruler lands,
/// and what a point or box snaps to. The view (<c>PageViewer.Layout</c>) draws them and passes the pointer in (ADR 1).
/// </summary>
public static class LayoutAids
{
    /// <summary>The fewest pixels between two labelled ticks.</summary>
    public const double MinLabelGap = 60;

    /// <summary>How near (pixels) a pointer must come to a guide, grid line or edge to snap to it.</summary>
    public const double SnapPixels = 6;

    /// <summary>
    /// The ticks of a ruler from <paramref name="from"/> to <paramref name="to"/> points along the page as shown (0: its
    /// top or left edge), at <paramref name="pixelsPerPoint"/>: labelled every 1, 2 or 5 × 10ⁿ units, as many as fit
    /// <see cref="MinLabelGap"/> apart, halves and tenths (or fifths, quarters) between them where there is room.
    /// </summary>
    public static IReadOnlyList<RulerTick> Ticks(double from, double to, double pixelsPerPoint, RulerUnit unit, CultureInfo? culture = null)
    {
        if (!(pixelsPerPoint > 0) || !(unit.PointsPer > 0) || !double.IsFinite(from) || !double.IsFinite(to) || to <= from) return [];
        culture ??= CultureInfo.CurrentCulture;
        var pixelsPerUnit = pixelsPerPoint * unit.PointsPer;
        var step = NiceStep(MinLabelGap / pixelsPerUnit);
        // Between labels: tenths, fifths or halves, whichever leaves at least 5 pixels apart.
        var divisions = new[] { 10, 5, 2, 1 }.First(d => step * pixelsPerUnit / d >= 5 || d == 1);
        var minor = step / divisions;
        var first = Math.Floor(from / unit.PointsPer / minor);
        var last = Math.Ceiling(to / unit.PointsPer / minor);
        if (last - first > 20_000) return [];
        var ticks = new List<RulerTick>();
        var decimals = Math.Max(0, (int)Math.Ceiling(-Math.Log10(step) - 1e-9));
        for (var k = first; k <= last; k++)
        {
            var units = k * minor;
            var at = units * unit.PointsPer;
            if (at < from - 1e-9 || at > to + 1e-9) continue;
            var i = (long)Math.Round(k) % divisions;
            if (i < 0) i += divisions;
            var level = i == 0 ? 0 : divisions % 2 == 0 && i == divisions / 2 ? 1 : 2;
            ticks.Add(new RulerTick(at, level, level == 0 ? Math.Round(units, decimals).ToString("0." + new string('#', Math.Max(1, decimals)), culture) : null));
        }
        return ticks;
    }

    /// <summary>The smallest 1, 2 or 5 × 10ⁿ at least <paramref name="atLeast"/>.</summary>
    public static double NiceStep(double atLeast)
    {
        if (!(atLeast > 0) || !double.IsFinite(atLeast)) return 1;
        var p = Math.Pow(10, Math.Floor(Math.Log10(atLeast)));
        foreach (var m in new[] { 1.0, 2, 5, 10 })
            if (m * p >= atLeast * (1 - 1e-9)) return m * p;
        return 10 * p;
    }

    /// <summary>
    /// The guide a drag from a ruler makes: from the top ruler a line across the screen, from the left one a line down it,
    /// at <paramref name="viewPos"/> points from the page's top or left as shown; in page space that is a y or an x,
    /// depending on the view's turn. Null when it is off the page.
    /// </summary>
    public static Guide? FromRuler(int page, bool topRuler, double viewPos, double pageWidth, double pageHeight, int viewRotation)
    {
        var (vw, vh) = RotatedView.Size(pageWidth, pageHeight, viewRotation);
        if (viewPos < 0 || viewPos > (topRuler ? vh : vw)) return null;
        // A point on the line as shown, turned back to page space; the line runs along the page's x or y.
        var (x, y) = RotatedView.FromView(topRuler ? 0 : viewPos, topRuler ? viewPos : 0, pageWidth, pageHeight, viewRotation);
        var acrossScreen = topRuler;
        var turnedQuarter = viewRotation is 90 or 270;
        return acrossScreen != turnedQuarter ? new Guide(page, GuideAxis.Y, y) : new Guide(page, GuideAxis.X, x);
    }

    /// <summary>Whether a guide runs across the screen (else down it) at the view's turn.</summary>
    public static bool AcrossScreen(GuideAxis axis, int viewRotation) => (axis == GuideAxis.Y) != (viewRotation is 90 or 270);

    /// <summary>The grid's lines on a page (page space, from its top-left): every <paramref name="step"/> points; none when too dense.</summary>
    public static (IReadOnlyList<double> Xs, IReadOnlyList<double> Ys) Grid(double pageWidth, double pageHeight, double step)
    {
        if (!(step >= 1) || pageWidth / step > 2000 || pageHeight / step > 2000) return ([], []);
        var xs = new List<double>();
        var ys = new List<double>();
        for (var x = step; x < pageWidth - 1e-6; x += step) xs.Add(x);
        for (var y = step; y < pageHeight - 1e-6; y += step) ys.Add(y);
        return (xs, ys);
    }

    /// <summary>The grid steps offered (points): ¼ in, ½ in, 1 in, 5 mm, 1 cm, 10 pt and 18 pt.</summary>
    public static readonly IReadOnlyList<double> GridSteps = [18, 36, 72, 72 / 25.4 * 5, 72 / 2.54, 10];
}

/// <summary>The guides of a document while it is open (never written into the PDF): kept per page, in page space.</summary>
public sealed class PageGuides
{
    /// <summary>The most guides a page keeps.</summary>
    public const int MaxPerPage = 200;

    private readonly List<Guide> _guides = [];

    /// <summary>Bumped on every change, so a view knows to draw again.</summary>
    public int Version { get; private set; }

    public IReadOnlyList<Guide> All => _guides;

    public IReadOnlyList<Guide> On(int page) => [.. _guides.Where(g => g.Page == page)];

    /// <summary>Adds a guide, kept on the page (a page's guides past <see cref="MaxPerPage"/> are refused: false).</summary>
    public bool Add(Guide g, double pageWidth, double pageHeight)
    {
        if (!double.IsFinite(g.At) || _guides.Count(x => x.Page == g.Page) >= MaxPerPage) return false;
        _guides.Add(g with { At = Math.Clamp(g.At, 0, g.Axis == GuideAxis.X ? pageWidth : pageHeight) });
        Version++;
        return true;
    }

    public bool Remove(Guide g)
    {
        var i = _guides.IndexOf(g);
        if (i < 0) return false;
        _guides.RemoveAt(i);
        Version++;
        return true;
    }

    /// <summary>A guide moved to <paramref name="at"/>; off the page (dragged back onto the ruler) it goes.</summary>
    public Guide? Move(Guide g, double at, double pageWidth, double pageHeight)
    {
        var i = _guides.IndexOf(g);
        if (i < 0) return null;
        var max = g.Axis == GuideAxis.X ? pageWidth : pageHeight;
        if (!double.IsFinite(at) || at < 0 || at > max)
        {
            _guides.RemoveAt(i);
            Version++;
            return null;
        }
        _guides[i] = g with { At = at };
        Version++;
        return _guides[i];
    }

    /// <summary>Clears one page's guides, or every page's (null).</summary>
    public int Clear(int? page = null)
    {
        var n = _guides.RemoveAll(g => page is null || g.Page == page);
        if (n > 0) Version++;
        return n;
    }

    /// <summary>The guide nearest a page point, within <paramref name="reach"/> points; null: none.</summary>
    public Guide? At(int page, PointD p, double reach) =>
        _guides.Where(g => g.Page == page && Math.Abs((g.Axis == GuideAxis.X ? p.X : p.Y) - g.At) <= reach)
            .MinBy(g => Math.Abs((g.Axis == GuideAxis.X ? p.X : p.Y) - g.At));

    /// <summary>
    /// Each page's identity for its guides (roadmap 4.19): its boxes, its turn and its own content as stored. Annotations,
    /// form fields and the document's other pages don't change it; moving the page keeps it, turning, resizing, cropping
    /// or replacing the page (or editing its text) changes it. A content stream several pages share is hashed once (each
    /// stream's digest goes into its page's).
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired (checked before each page and stream).</exception>
    public static IReadOnlyList<string> Keys(byte[] data, string? password, CancellationToken cancel = default)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, PdfStrings.Doc_PagesCantBeRead);
        var keys = new List<string>(doc.PageCount);
        var digests = new Dictionary<int, byte[]>(); // by object number, streams being indirect
        for (var i = 0; i < doc.PageCount; i++)
        {
            cancel.ThrowIfCancellationRequested();
            var page = doc.Pages[i];
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            void Add(PdfItem? item)
            {
                var number = item is PdfReference r ? r.ObjectNumber : (int?)null;
                if (number is { } n && digests.TryGetValue(n, out var known))
                {
                    hash.AppendData(known);
                    return;
                }
                if (PdfObj.Dict(item) is not { Stream: { } st }) return;
                cancel.ThrowIfCancellationRequested();
                var digest = SHA256.HashData(st.Value ?? []);
                if (number is { } m) digests[m] = digest;
                hash.AppendData(digest);
            }
            var contents = page.Elements["/Contents"];
            if (PdfObj.Array(contents) is { } parts) foreach (var part in parts.Elements) Add(part);
            else Add(contents);
            var crop = PdfObj.Array(page.Elements["/CropBox"]);
            keys.Add(string.Create(CultureInfo.InvariantCulture,
                $"{page.Rotate}|{page.Width.Point},{page.Height.Point}|{string.Join(',', crop?.Elements.Select(e => PdfObj.Num(e)) ?? [])}|{Convert.ToHexString(hash.GetHashAndReset())}"));
        }
        return keys;
    }

    /// <summary>
    /// The pages changed (<paramref name="before"/> and <paramref name="after"/>: <see cref="Keys"/> of the document
    /// before and after): each page's guides follow the page to where it is now (of several alike, the nearest); a page
    /// that isn't there any more takes its guides with it. Returns how many guides went.
    /// </summary>
    public int Remap(IReadOnlyList<string> before, IReadOnlyList<string> after)
    {
        var moved = new List<Guide>();
        var gone = 0;
        foreach (var g in _guides)
        {
            if (g.Page < 0 || g.Page >= before.Count)
            {
                gone++;
                continue;
            }
            var key = before[g.Page];
            var to = Enumerable.Range(0, after.Count).Where(j => after[j] == key).DefaultIfEmpty(-1).MinBy(j => j < 0 ? int.MaxValue : Math.Abs(j - g.Page));
            if (to < 0) gone++;
            else moved.Add(g with { Page = to });
        }
        if (gone == 0 && moved.SequenceEqual(_guides)) return 0;
        _guides.Clear();
        _guides.AddRange(moved);
        Version++;
        return gone;
    }

    /// <summary>Pages moved, added or deleted with no way to tell which (their keys couldn't be read): the guides go.</summary>
    public void PagesChanged() => Clear();
}

/// <summary>
/// What a point or box snaps to on one page: lines at page x's and y's (guides, other objects' edges and centers) and a
/// grid every <see cref="GridStep"/> points, within <see cref="Reach"/> points. Each axis snaps on its own, to the nearest.
/// <see cref="Lines"/>: what the last call snapped to, for the view to show.
/// </summary>
public sealed class Snapper(IReadOnlyList<double> xs, IReadOnlyList<double> ys, double gridStep, double reach)
{
    public double GridStep { get; } = gridStep;
    public double Reach { get; } = reach;
    public IReadOnlyList<SnapLine> Lines { get; private set; } = [];

    /// <summary>
    /// What snapping takes on a page: guides (if <paramref name="guides"/> is on), the grid (if a step is given) and the
    /// left, middle and right (top, middle, bottom) of the <paramref name="objects"/> (fields, comments, stamps), within
    /// <paramref name="reach"/> points; null when there is nothing to snap to.
    /// </summary>
    public static Snapper? For(IEnumerable<Guide>? guides, IEnumerable<RectD>? objects, double gridStep, double reach)
    {
        var xs = new List<double>();
        var ys = new List<double>();
        foreach (var g in guides ?? [])
            (g.Axis == GuideAxis.X ? xs : ys).Add(g.At);
        foreach (var r in (objects ?? []).Take(2000))
        {
            if (r.IsEmpty) continue;
            xs.AddRange([r.X, r.CenterX, r.Right]);
            ys.AddRange([r.Y, r.CenterY, r.Bottom]);
        }
        return xs.Count == 0 && ys.Count == 0 && !(gridStep >= 1) || !(reach > 0) ? null : new Snapper(xs, ys, gridStep >= 1 ? gridStep : 0, reach);
    }

    /// <summary>The nearest line to <paramref name="v"/> on one axis within reach (null: none).</summary>
    private double? Nearest(double v, GuideAxis axis)
    {
        double? best = null;
        var bestD = Reach;
        foreach (var t in axis == GuideAxis.X ? xs : ys)
            if (Math.Abs(t - v) is var d && d <= bestD)
                (best, bestD) = (t, d);
        if (GridStep > 0)
        {
            var g = Math.Round(v / GridStep) * GridStep;
            if (Math.Abs(g - v) is var d && d < bestD) best = g;
        }
        return best;
    }

    /// <summary>A point snapped on each axis to the nearest line within reach.</summary>
    public PointD Point(PointD p)
    {
        var lines = new List<SnapLine>();
        var x = Nearest(p.X, GuideAxis.X);
        var y = Nearest(p.Y, GuideAxis.Y);
        if (x is { } sx) lines.Add(new SnapLine(GuideAxis.X, sx));
        if (y is { } sy) lines.Add(new SnapLine(GuideAxis.Y, sy));
        Lines = lines;
        return new PointD(x ?? p.X, y ?? p.Y);
    }

    /// <summary>A box moved (its size kept) so its nearest edge or center on each axis lies on a line within reach.</summary>
    public RectD Move(RectD r)
    {
        var lines = new List<SnapLine>();
        var dx = Shift([r.X, r.CenterX, r.Right], GuideAxis.X, lines);
        var dy = Shift([r.Y, r.CenterY, r.Bottom], GuideAxis.Y, lines);
        Lines = lines;
        return r with { X = r.X + dx, Y = r.Y + dy };
    }

    private double Shift(double[] candidates, GuideAxis axis, List<SnapLine> lines)
    {
        double? best = null;
        double at = 0;
        foreach (var c in candidates)
            if (Nearest(c, axis) is { } t && (best is null || Math.Abs(t - c) < Math.Abs(best.Value)))
                (best, at) = (t - c, t);
        if (best is null) return 0;
        lines.Add(new SnapLine(axis, at));
        return best.Value;
    }

    /// <summary>A box resized: the edges that moved from <paramref name="before"/> snap to lines within reach (no smaller than <paramref name="min"/>).</summary>
    public RectD Resize(RectD before, RectD r, double min = 1)
    {
        var lines = new List<SnapLine>();
        double l = r.X, t = r.Y, right = r.Right, b = r.Bottom;
        double? Edge(double v, double was, GuideAxis axis) => Math.Abs(v - was) < 1e-9 ? null : Nearest(v, axis);
        // Each edge's line is shown only when the snap is taken (not when it would leave the box too small).
        if (Edge(l, before.X, GuideAxis.X) is { } nl && right - nl >= min) lines.Add(new SnapLine(GuideAxis.X, l = nl));
        if (Edge(right, before.Right, GuideAxis.X) is { } nr && nr - l >= min) lines.Add(new SnapLine(GuideAxis.X, right = nr));
        if (Edge(t, before.Y, GuideAxis.Y) is { } nt && b - nt >= min) lines.Add(new SnapLine(GuideAxis.Y, t = nt));
        if (Edge(b, before.Bottom, GuideAxis.Y) is { } nb && nb - t >= min) lines.Add(new SnapLine(GuideAxis.Y, b = nb));
        Lines = lines;
        return RectD.FromEdges(l, t, right, b);
    }
}
