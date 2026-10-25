using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>What a measurement measures: a straight distance, the length of a path, or the area a path encloses.</summary>
public enum MeasureKind { Distance, Perimeter, Area }

/// <summary>Lengths and areas of page-space paths (points; any y direction).</summary>
public static class MeasureGeometry
{
    /// <summary>The length of the path through <paramref name="points"/> (with <paramref name="closed"/>, back to the start too).</summary>
    public static double Length(IReadOnlyList<PointD> points, bool closed = false)
    {
        double sum = 0;
        for (var i = 1; i < points.Count; i++) sum += Distance(points[i - 1], points[i]);
        if (closed && points.Count > 2) sum += Distance(points[^1], points[0]);
        return sum;
    }

    public static double Distance(PointD a, PointD b) => Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));

    /// <summary>The area enclosed by the polygon through <paramref name="points"/> (shoelace formula; any winding).</summary>
    public static double Area(IReadOnlyList<PointD> points)
    {
        if (points.Count < 3) return 0;
        double twice = 0;
        for (var i = 0; i < points.Count; i++)
        {
            var (a, b) = (points[i], points[(i + 1) % points.Count]);
            twice += a.X * b.Y - b.X * a.Y;
        }
        return Math.Abs(twice) / 2;
    }

    /// <summary>The polygon's centroid (where an area label goes); the points' middle when it has no area.</summary>
    public static PointD Centroid(IReadOnlyList<PointD> points)
    {
        if (points.Count == 0) return default;
        double twice = 0, cx = 0, cy = 0;
        for (var i = 0; i < points.Count && points.Count >= 3; i++)
        {
            var (a, b) = (points[i], points[(i + 1) % points.Count]);
            var cross = a.X * b.Y - b.X * a.Y;
            twice += cross;
            cx += (a.X + b.X) * cross;
            cy += (a.Y + b.Y) * cross;
        }
        if (Math.Abs(twice) < 1e-9)
        {
            double minX = points.Min(p => p.X), maxX = points.Max(p => p.X), minY = points.Min(p => p.Y), maxY = points.Max(p => p.Y);
            return new PointD((minX + maxX) / 2, (minY + maxY) / 2);
        }
        return new PointD(cx / (3 * twice), cy / (3 * twice));
    }
}

/// <summary>
/// A drawing scale: how many real units one PDF point stands for, the unit, and the ratio as people write it
/// ("1 in = 10 ft"). <see cref="Decimals"/> is how many decimals values show.
/// </summary>
public sealed record MeasureScale(double PerPoint, string Unit, string Ratio, int Decimals = 2)
{
    /// <summary>
    /// Points per unit of the page's user space (its /UserUnit; 1 normally): page coordinates are multiplied by it
    /// before <see cref="PerPoint"/> applies, so a drawing on a page with /UserUnit 2 measures true.
    /// </summary>
    public double UserUnit { get; init; } = 1;

    /// <summary>Real units per unit of page coordinates (what a PDF's /X /C conversion factor is).</summary>
    public double PerUnit => PerPoint * UserUnit;

    /// <summary>Points per unit (1 in = 72 pt).</summary>
    private static readonly Dictionary<string, double> PointsPer = new(StringComparer.Ordinal)
    {
        ["pt"] = 1, ["in"] = 72, ["ft"] = 72 * 12, ["yd"] = 72 * 36, ["mi"] = 72 * 63360,
        ["mm"] = 72 / 25.4, ["cm"] = 72 / 2.54, ["m"] = 72 / 0.0254, ["km"] = 72 / 0.0000254,
    };

    /// <summary>The units a scale can use, in the order the dialogs list them.</summary>
    public static readonly IReadOnlyList<string> Units = ["in", "ft", "yd", "mi", "mm", "cm", "m", "km", "pt"];

    /// <summary>Real size: 1 in on the page is 1 in.</summary>
    public static readonly MeasureScale Default = From(1, "in", 1, "in");

    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary><paramref name="docValue"/> <paramref name="docUnit"/> on the page = <paramref name="realValue"/> <paramref name="realUnit"/>.</summary>
    /// <exception cref="ArgumentException">A value isn't positive or a unit isn't one of <see cref="Units"/>.</exception>
    public static MeasureScale From(double docValue, string docUnit, double realValue, string realUnit, int decimals = 2)
    {
        if (!(docValue > 0) || !(realValue > 0) || !double.IsFinite(docValue) || !double.IsFinite(realValue))
            throw new ArgumentException("Both lengths of a scale must be more than 0.");
        if (!PointsPer.TryGetValue(docUnit, out var per) || !PointsPer.ContainsKey(realUnit))
            throw new ArgumentException($"Units are {string.Join(", ", Units)}.");
        return new MeasureScale(realValue / (docValue * per), realUnit, $"{N(docValue)} {docUnit} = {N(realValue)} {realUnit}", Math.Clamp(decimals, 0, 6));
    }

    /// <summary>The scale that makes a line <paramref name="measuredPoints"/> long on the page <paramref name="realLength"/> long.</summary>
    /// <exception cref="ArgumentException">A length isn't positive, or the unit isn't known.</exception>
    public static MeasureScale Calibrate(double measuredPoints, double realLength, string unit, int decimals = 2)
    {
        if (!(measuredPoints > 0) || !(realLength > 0)) throw new ArgumentException("Both lengths must be more than 0.");
        if (!PointsPer.ContainsKey(unit)) throw new ArgumentException($"Units are {string.Join(", ", Units)}.");
        var perPoint = realLength / measuredPoints;
        return new MeasureScale(perPoint, unit, $"1 in = {N(72 * perPoint)} {unit}", Math.Clamp(decimals, 0, 6));
    }

    private static string N(double v) => Math.Round(v, 4).ToString("0.####", Inv);

    private static readonly Regex RatioPattern = new(@"^\s*(?<dv>\d+(?:\.\d+)?(?:\s*/\s*\d+(?:\.\d+)?)?)\s*(?<du>[a-z]+)\s*=\s*(?<rv>-?\d+(?:\.\d+)?(?:\s*/\s*\d+(?:\.\d+)?)?)\s*(?<ru>[a-z]+)\s*$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly Regex ColonPattern = new(@"^\s*(?<dv>\d+(?:\.\d+)?)\s*:\s*(?<rv>\d+(?:\.\d+)?)\s*(?<ru>[a-z]+)\s*$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>"1 in = 10 ft", "1/4 in = 1 ft", "1:100 m" (1 on the page is 100 real: the same unit on both sides).</summary>
    public static bool TryParse(string text, out MeasureScale? scale)
    {
        scale = null;
        try
        {
            if (RatioPattern.Match(text) is { Success: true } m)
            {
                scale = From(Number(m.Groups["dv"].Value), m.Groups["du"].Value.ToLowerInvariant(), Number(m.Groups["rv"].Value), m.Groups["ru"].Value.ToLowerInvariant());
                return true;
            }
            if (ColonPattern.Match(text) is { Success: true } c)
            {
                var unit = c.Groups["ru"].Value.ToLowerInvariant();
                scale = From(Number(c.Groups["dv"].Value), unit, Number(c.Groups["rv"].Value), unit) with
                {
                    Ratio = $"{c.Groups["dv"].Value}:{c.Groups["rv"].Value} {unit}",
                };
                return true;
            }
        }
        catch (ArgumentException)
        {
        }
        return false;

        static double Number(string s)
        {
            var parts = s.Split('/');
            var v = double.Parse(parts[0].Trim(), Inv);
            return parts.Length == 2 ? v / double.Parse(parts[1].Trim(), Inv) : v;
        }
    }

    public string AreaUnit => "sq " + Unit;

    /// <summary>The real length (distance, perimeter: the path as drawn) or area of a page-space path.</summary>
    public double Value(MeasureKind kind, IReadOnlyList<PointD> points) => kind switch
    {
        MeasureKind.Area => MeasureGeometry.Area(points) * PerUnit * PerUnit,
        _ => MeasureGeometry.Length(points) * PerUnit,
    };

    /// <summary>"12.50 ft", "1,000.00 sq ft".</summary>
    public string Format(MeasureKind kind, IReadOnlyList<PointD> points) => FormatValue(kind, Value(kind, points));

    public string FormatValue(MeasureKind kind, double value) =>
        $"{value.ToString("N" + Decimals, Inv)} {(kind == MeasureKind.Area ? AreaUnit : Unit)}";
}

/// <summary>A measurement annotation on a page.</summary>
public sealed record MeasurementInfo(string? Id, MeasureKind Kind, IReadOnlyList<PointD> Points, MeasureScale Scale, double Value, string Text);

/// <summary>
/// Measurements in the PDF's own terms (ISO 32000-1 12.9): a scale is a rectilinear measure dictionary (/Measure /RL:
/// /R the ratio, /X the number format with the conversion factor /C from points and the unit /U, /D distance and /A area
/// formats), kept by a page in its viewports (/VP, each with a /BBox; where viewports overlap, the last one listed applies)
/// and by each measurement. Measurements are Line, PolyLine and Polygon annotations with /IT LineDimension,
/// PolyLineDimension or PolygonDimension, their value as /Contents and drawn as a label in the appearance; they redraw
/// with a new value when reshaped (see <see cref="Annotations"/>). Acrobat reads and keeps them as measurements.
/// </summary>
public static class Measurements
{
    /// <summary>The /Name of the viewport Inkvolt PDF writes for a page's scale (replaced when the scale is set again).</summary>
    public const string ViewportName = "Inkvolt PDF scale";

    public static AnnotStyle DefaultStyle(MeasureKind kind) => new()
    {
        Color = new AnnotColor(0.8, 0.1, 0.1),
        Width = 1,
        StartEnding = kind == MeasureKind.Distance ? LineEnding.Butt : LineEnding.None,
        EndEnding = kind == MeasureKind.Distance ? LineEnding.Butt : LineEnding.None,
    };

    public static string Subtype(MeasureKind kind) => kind switch
    {
        MeasureKind.Distance => "Line",
        MeasureKind.Perimeter => "PolyLine",
        _ => "Polygon",
    };

    /// <summary>The scale the page's viewports give at <paramref name="at"/> (page space), or null when none does.</summary>
    public static MeasureScale? PageScale(byte[] data, string? password, int pageIndex, PointD at)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
        if (pageIndex < 0 || pageIndex >= doc.PageCount) return null;
        return PageScale(doc.Pages[pageIndex], at);
    }

    /// <summary>
    /// The scaled areas of every page (page space), in the order a lookup goes: where they overlap the last one listed
    /// applies (see <see cref="ScaleAt"/>). Read once per document version, then looked up while the pointer moves.
    /// </summary>
    public static Dictionary<int, IReadOnlyList<(RectD Area, MeasureScale Scale)>> Viewports(byte[] data, string? password)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
        var all = new Dictionary<int, IReadOnlyList<(RectD, MeasureScale)>>();
        for (var i = 0; i < doc.PageCount; i++)
        {
            var page = doc.Pages[i];
            if (PdfObj.Array(page.Elements["/VP"]) is not { } vps) continue;
            var list = new List<(RectD, MeasureScale)>();
            foreach (var vp in vps.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
                if (PdfObj.Array(vp.Elements["/BBox"]) is { Elements.Count: 4 } b && PdfObj.Dict(vp.Elements["/Measure"]) is { } m && ScaleOf(m, PageMarks.UserUnit(page)) is { } s)
                    list.Add((FormEditor.ToPageSpace(page, Math.Min(PdfObj.Num(b, 0), PdfObj.Num(b, 2)), Math.Min(PdfObj.Num(b, 1), PdfObj.Num(b, 3)),
                        Math.Max(PdfObj.Num(b, 0), PdfObj.Num(b, 2)), Math.Max(PdfObj.Num(b, 1), PdfObj.Num(b, 3))), s));
            if (list.Count > 0) all[i] = list;
        }
        return all;
    }

    /// <summary>The /UserUnit of every page that has one other than 1 (points per unit of its coordinates).</summary>
    public static Dictionary<int, double> UserUnits(byte[] data, string? password)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
        var units = new Dictionary<int, double>();
        for (var i = 0; i < doc.PageCount; i++)
            if (PageMarks.UserUnit(doc.Pages[i]) is var u && u != 1) units[i] = u;
        return units;
    }

    /// <summary>The scale at <paramref name="at"/> among <paramref name="viewports"/> (page space; the last that contains it), else null.</summary>
    public static MeasureScale? ScaleAt(IReadOnlyList<(RectD Area, MeasureScale Scale)>? viewports, PointD at) =>
        viewports?.LastOrDefault(v => at.X >= v.Area.X - 0.01 && at.X <= v.Area.Right + 0.01 && at.Y >= v.Area.Y - 0.01 && at.Y <= v.Area.Bottom + 0.01).Scale;

    internal static MeasureScale? PageScale(PdfPage page, PointD at)
    {
        if (PdfObj.Array(page.Elements["/VP"]) is not { } vps) return null;
        var (x, y) = PdfObj.ToPdf(page, at.X, at.Y);
        MeasureScale? found = null;
        foreach (var vp in vps.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
        {
            if (PdfObj.Array(vp.Elements["/BBox"]) is not { Elements.Count: 4 } b) continue;
            double x1 = Math.Min(PdfObj.Num(b, 0), PdfObj.Num(b, 2)), x2 = Math.Max(PdfObj.Num(b, 0), PdfObj.Num(b, 2));
            double y1 = Math.Min(PdfObj.Num(b, 1), PdfObj.Num(b, 3)), y2 = Math.Max(PdfObj.Num(b, 1), PdfObj.Num(b, 3));
            if (x < x1 || x > x2 || y < y1 || y > y2) continue;
            if (PdfObj.Dict(vp.Elements["/Measure"]) is { } m && ScaleOf(m, PageMarks.UserUnit(page)) is { } s) found = s;
        }
        return found;
    }

    /// <summary>
    /// Sets (or with null removes) the scale of <paramref name="pages"/>: a viewport over the whole page, replacing any
    /// other viewport that covers the whole page, and listed first so the document's viewports for parts of the page
    /// (details at other scales) keep applying inside their areas.
    /// </summary>
    public static byte[] SetPageScale(byte[] data, string? password, IReadOnlyCollection<int> pages, MeasureScale? scale)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited");
        foreach (var i in pages.Distinct())
        {
            if (i < 0 || i >= doc.PageCount) continue;
            var page = doc.Pages[i];
            var vps = PdfObj.Array(page.Elements["/VP"]) ?? new PdfArray(doc);
            var media = page.MediaBox;
            bool WholePage(PdfDictionary? vp) =>
                PdfObj.Array(vp?.Elements["/BBox"]) is { Elements.Count: 4 } b &&
                Math.Min(PdfObj.Num(b, 0), PdfObj.Num(b, 2)) <= media.X1 + 1 && Math.Max(PdfObj.Num(b, 0), PdfObj.Num(b, 2)) >= media.X2 - 1 &&
                Math.Min(PdfObj.Num(b, 1), PdfObj.Num(b, 3)) <= media.Y1 + 1 && Math.Max(PdfObj.Num(b, 1), PdfObj.Num(b, 3)) >= media.Y2 - 1;
            for (var k = vps.Elements.Count - 1; k >= 0; k--)
                if (PdfObj.Dict(vps.Elements[k]) is var vp && (vp is null || PdfObj.Text(vp.Elements["/Name"]) == ViewportName || WholePage(vp)))
                    vps.Elements.RemoveAt(k);
            if (scale is not null)
            {
                var box = page.MediaBox;
                var vp = new PdfDictionary(doc);
                vp.Elements["/Type"] = new PdfName("/Viewport");
                vp.Elements["/BBox"] = PdfObj.Reals(doc, box.X1, box.Y1, box.X2, box.Y2);
                vp.Elements["/Name"] = new PdfString(ViewportName);
                vp.Elements["/Measure"] = MeasureDict(doc, scale with { UserUnit = PageMarks.UserUnit(page) });
                vps.Elements.Insert(0, vp);
            }
            if (vps.Elements.Count == 0) page.Elements.Remove("/VP");
            else page.Elements["/VP"] = vps;
        }
        return PdfObj.Save(doc);
    }

    /// <summary>Adds a measurement through <paramref name="points"/> (page space) at <paramref name="scale"/>, labeled with its value.</summary>
    /// <exception cref="ArgumentException">Too few points for <paramref name="kind"/>.</exception>
    public static byte[] Add(byte[] data, string? password, int pageIndex, MeasureKind kind, IReadOnlyList<PointD> points, MeasureScale scale,
        string author, string? id = null, AnnotStyle? style = null) =>
        Annotations.AddMeasurement(data, password, pageIndex, Subtype(kind), [.. points], style ?? DefaultStyle(kind), author, id, scale);

    /// <summary>The measurements on a page (annotations with a rectilinear measure), with their values.</summary>
    public static IReadOnlyList<MeasurementInfo> Read(byte[] data, string? password, int pageIndex)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
        if (pageIndex < 0 || pageIndex >= doc.PageCount) return [];
        var page = doc.Pages[pageIndex];
        var list = new List<MeasurementInfo>();
        foreach (var a in PdfObj.Array(page.Elements["/Annots"])?.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>() ?? [])
        {
            if (PdfObj.Dict(a.Elements["/Measure"]) is not { } m || ScaleOf(m, PageMarks.UserUnit(page)) is not { } scale) continue;
            if (KindOf(PdfObj.Name(a.Elements["/Subtype"])) is not { } kind) continue;
            var pts = Points(page, PdfObj.Array(a.Elements[kind == MeasureKind.Distance ? "/L" : "/Vertices"]));
            if (pts.Count < (kind == MeasureKind.Area ? 3 : 2)) continue;
            var value = scale.Value(kind, pts);
            list.Add(new MeasurementInfo(PdfObj.Text(a.Elements["/NM"]), kind, pts, scale, value, scale.FormatValue(kind, value)));
        }
        return list;
    }

    internal static MeasureKind? KindOf(string? subtype) => subtype switch
    {
        "Line" => MeasureKind.Distance,
        "PolyLine" => MeasureKind.Perimeter,
        "Polygon" => MeasureKind.Area,
        _ => null,
    };

    private static List<PointD> Points(PdfPage page, PdfArray? flat)
    {
        var pts = new List<PointD>();
        if (flat is null) return pts;
        for (var i = 0; i + 1 < flat.Elements.Count; i += 2)
        {
            var (x, y) = PdfObj.ToPage(page, PdfObj.Num(flat, i), PdfObj.Num(flat, i + 1));
            pts.Add(new PointD(x, y));
        }
        return pts;
    }

    /// <summary>A rectilinear measure dictionary for <paramref name="scale"/> (X: points to the unit; D and A in that unit).</summary>
    internal static PdfDictionary MeasureDict(PdfDocument doc, MeasureScale scale)
    {
        PdfArray Format(string unit, double factor)
        {
            var nf = new PdfDictionary(doc);
            nf.Elements["/Type"] = new PdfName("/NumberFormat");
            nf.Elements["/U"] = new PdfString(unit);
            nf.Elements["/C"] = new PdfReal(factor);
            nf.Elements["/F"] = new PdfName("/D");
            nf.Elements["/D"] = new PdfInteger((int)Math.Pow(10, scale.Decimals));
            nf.Elements["/RT"] = new PdfString("");
            nf.Elements["/SS"] = new PdfString("");
            return new PdfArray(doc, nf);
        }
        var m = new PdfDictionary(doc);
        m.Elements["/Type"] = new PdfName("/Measure");
        m.Elements["/Subtype"] = new PdfName("/RL");
        m.Elements["/R"] = new PdfString(scale.Ratio);
        m.Elements["/X"] = Format(scale.Unit, scale.PerUnit); // from the page's user space units
        m.Elements["/D"] = Format(scale.Unit, 1);
        m.Elements["/A"] = Format(scale.AreaUnit, 1);
        return m;
    }

    /// <summary>
    /// The scale of a rectilinear measure dictionary on a page with <paramref name="userUnit"/> (null for geospatial ones
    /// or without a conversion factor). /X /C converts from user space units, so per point it is /C ÷ /UserUnit.
    /// </summary>
    internal static MeasureScale? ScaleOf(PdfDictionary measure, double userUnit)
    {
        if (PdfObj.Name(measure.Elements["/Subtype"]) is { } st && st != "RL") return null;
        if (PdfObj.Dict(PdfObj.Array(measure.Elements["/X"])?.Elements.FirstOrDefault()) is not { } x) return null;
        var c = PdfObj.Num(x.Elements["/C"], double.NaN);
        if (!(c > 0) || !double.IsFinite(c)) return null;
        var unit = PdfObj.Text(x.Elements["/U"]) is { Length: > 0 } u ? u.Trim() : "units";
        var d = PdfObj.Num(x.Elements["/D"], 100);
        var decimals = d >= 1 ? Math.Clamp((int)Math.Round(Math.Log10(d)), 0, 6) : 2;
        var perPoint = c / userUnit;
        var ratio = PdfObj.Text(measure.Elements["/R"]) is { Length: > 0 } r ? r.Trim() : $"1 pt = {perPoint.ToString("0.######", CultureInfo.InvariantCulture)} {unit}";
        // /C is written with a few digits: when the ratio says the same, take its exact value.
        if (MeasureScale.TryParse(ratio, out var exact) && exact!.Unit == unit && Math.Abs(exact.PerPoint - perPoint) <= perPoint * 1e-4) perPoint = exact.PerPoint;
        return new MeasureScale(perPoint, unit, ratio, decimals) { UserUnit = userUnit };
    }

    // ───────────── the label in a measurement's appearance ─────────────

    /// <summary>
    /// The value label of a measurement (<paramref name="points"/> page space): its drawing operators (Helvetica under
    /// /Helv, upright as the page is shown) and the corners it covers (PDF space), or null when the annotation isn't one.
    /// </summary>
    internal static (string Ops, List<(double X, double Y)> Corners, string Text, MeasureKind Kind)? Label(PdfPage page, PdfDictionary annot, string subtype,
        IReadOnlyList<PointD> points, AnnotStyle style)
    {
        if (PdfObj.Dict(annot.Elements["/Measure"]) is not { } m || ScaleOf(m, PageMarks.UserUnit(page)) is not { } scale || KindOf(subtype) is not { } kind) return null;
        var text = scale.Format(kind, points);
        const double size = 9;
        var width = StdFont.Helvetica.Measure(text) * size;
        PointD center;
        switch (kind)
        {
            case MeasureKind.Distance:
            {
                var (a, b) = (points[0], points[^1]);
                var len = Math.Max(1e-6, MeasureGeometry.Distance(a, b));
                var (dx, dy) = ((b.X - a.X) / len, (b.Y - a.Y) / len);
                var (nx, ny) = (dy, -dx); // a normal; take the one pointing up the page as shown
                if (ny > 0 || Math.Abs(ny) < 1e-9 && nx < 0) (nx, ny) = (-nx, -ny);
                var reach = size * 0.8 + style.Width + Math.Abs(nx) * width / 2;
                center = new PointD((a.X + b.X) / 2 + nx * reach, (a.Y + b.Y) / 2 + ny * reach);
                break;
            }
            case MeasureKind.Perimeter:
                center = new PointD(points[^1].X + width / 2 + 6, points[^1].Y - size);
                break;
            default:
                center = MeasureGeometry.Centroid(points);
                break;
        }
        var left = center.X - width / 2;
        var baseline = center.Y + size * 0.35;
        var corners = new List<(double X, double Y)>
        {
            PdfObj.ToPdf(page, left - 2, center.Y - size * 0.75), PdfObj.ToPdf(page, left + width + 2, center.Y - size * 0.75),
            PdfObj.ToPdf(page, left - 2, center.Y + size * 0.6), PdfObj.ToPdf(page, left + width + 2, center.Y + size * 0.6),
        };
        var (bx, by) = PdfObj.ToPdf(page, left, baseline);
        var rot = (((page.Rotate % 360) + 360) % 360) * Math.PI / 180;
        var (cos, sin) = (Math.Round(Math.Cos(rot), 6), Math.Round(Math.Sin(rot), 6));
        var c = style.Color ?? AnnotStyle.Black;
        var ops = new StringBuilder();
        // A white backing, so the value reads over drawings and pictures.
        var (tl, tr, bl, br) = (corners[0], corners[1], corners[2], corners[3]);
        ops.Append(CultureInfo.InvariantCulture,
            $"q 1 1 1 rg {PdfObj.F(tl.X)} {PdfObj.F(tl.Y)} m {PdfObj.F(tr.X)} {PdfObj.F(tr.Y)} l {PdfObj.F(br.X)} {PdfObj.F(br.Y)} l {PdfObj.F(bl.X)} {PdfObj.F(bl.Y)} l h f Q\n");
        ops.Append(CultureInfo.InvariantCulture,
            $"BT {PdfObj.F(c.R)} {PdfObj.F(c.G)} {PdfObj.F(c.B)} rg /Helv {PdfObj.F(size)} Tf {PdfObj.F(cos)} {PdfObj.F(sin)} {PdfObj.F(-sin)} {PdfObj.F(cos)} {PdfObj.F(bx)} {PdfObj.F(by)} Tm ({WinAnsi.Literal(text)}) Tj ET\n");
        return (ops.ToString(), corners, text, kind);
    }

    internal static PdfDictionary LabelResources(PdfDocument doc)
    {
        var fonts = new PdfDictionary(doc);
        fonts.Elements["/Helv"] = FontResources.Standard(doc, "Helvetica");
        var res = new PdfDictionary(doc);
        res.Elements["/Font"] = fonts;
        return res;
    }
}
