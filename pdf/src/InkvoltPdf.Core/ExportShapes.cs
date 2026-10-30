namespace InkvoltPdf.Core;

public enum ExportShapeKind { Line, Rectangle, Ellipse }

/// <summary>
/// A simple shape a page draws (page space): a line along its box, a rectangle or an ellipse. <see cref="Fill"/> and
/// <see cref="Stroke"/>: its colors (0xRRGGBB), null for none. <see cref="StrokeWidth"/>: in points. A stroked shape's box
/// runs along the middle of its outline.
/// </summary>
public sealed record ExportShape(ExportShapeKind Kind, RectD Box, uint? Fill, uint? Stroke, double StrokeWidth);

/// <summary>A path a page draws, as the PDF reader gives it: only its bounds, whether it is stroked, and its color (0xRRGGBB).</summary>
public readonly record struct ExportPath(RectD Box, bool Stroked, uint Color);

/// <summary>
/// Tells which of a page's vector paths are simple shapes. The reader gives a path's bounds and no more, so what it draws
/// decides: a thin path is a line, and a wider one is looked at in a rendering of the page (its corners and edges) for a
/// rectangle or an ellipse. Everything else (a triangle, a rounded box, a dashed or see-through one) stays as it looks:
/// its area becomes a picture, unless text lies on it (the picture would double the text).
/// </summary>
internal static class ExportShapes
{
    private const double Thin = 3;   // as DocLayout: a path this thin (pt) is a rule
    private const double MinLine = 4; // shorter rules are specks
    private const int LineAlpha = 64;  // a thin outline's pixels at the rendering's scale

    /// <summary>A page rendered on a transparent background: straight RGBA, <paramref name="Scale"/> pixels per point.</summary>
    public readonly record struct Raster(byte[] Rgba, int Width, int Height, double Scale)
    {
        public (byte R, byte G, byte B, byte A) At(double x, double y)
        {
            var px = Math.Clamp((int)Math.Floor(x * Scale), 0, Width - 1);
            var py = Math.Clamp((int)Math.Floor(y * Scale), 0, Height - 1);
            var i = (py * Width + px) * 4;
            return (Rgba[i], Rgba[i + 1], Rgba[i + 2], Rgba[i + 3]);
        }

        /// <summary>The point shows this color, opaque (or, by <paramref name="minAlpha"/>, partly: a thin line covers only part of its pixels).</summary>
        public bool Is(double x, double y, uint color, int minAlpha = 240)
        {
            var (r, g, b, a) = At(x, y);
            return a >= minAlpha && Math.Abs(r - (int)((color >> 16) & 255)) <= 16 && Math.Abs(g - (int)((color >> 8) & 255)) <= 16 && Math.Abs(b - (int)(color & 255)) <= 16;
        }

        /// <summary><see cref="Is"/> at the point or a pixel beside it: the outline found is only as exact as the pixels.</summary>
        public bool Near(double x, double y, uint color, int minAlpha)
        {
            var step = 1 / Scale;
            for (var dy = -1; dy <= 1; dy++)
            for (var dx = -1; dx <= 1; dx++)
                if (Is(x + dx * step, y + dy * step, color, minAlpha)) return true;
            return false;
        }

        /// <summary>The point's opaque color, or null where it is see-through.</summary>
        public uint? Opaque(double x, double y)
        {
            var (r, g, b, a) = At(x, y);
            return a >= 250 ? (uint)r << 16 | (uint)g << 8 | b : null;
        }
    }

    /// <summary>A rendering is needed: some path is wider than a line.</summary>
    public static bool NeedsRaster(IEnumerable<ExportPath> paths) => paths.Any(p => Usable(p.Box) && !IsThin(p.Box));

    /// <summary>
    /// The page's shapes in the order it draws them, and the areas to keep as pictures. <paramref name="raster"/>: the page,
    /// when a path needs looking at; <paramref name="lines"/> and <paramref name="pictures"/>: what the page already gives
    /// as text and pictures.
    /// </summary>
    public static (List<ExportShape> Shapes, List<RectD> Pictures) Read(IEnumerable<ExportPath> paths, Raster? raster,
        IReadOnlyList<ExportLine> lines, IReadOnlyList<RectD> pictures, double width, double height)
    {
        var shapes = new List<ExportShape>();
        var others = new List<RectD>();
        foreach (var path in paths)
        {
            var box = path.Box;
            if (!Usable(box)) continue;
            if (IsThin(box))
            {
                if (Math.Max(box.Width, box.Height) >= MinLine)
                    shapes.Add(new ExportShape(ExportShapeKind.Line, box, null, path.Color, Math.Max(0.25, Math.Min(box.Width, box.Height))));
                continue;
            }
            var shape = raster is { } r ? (path.Stroked ? Outline(r, path) : Filled(r, path)) : null;
            if (shape is null) others.Add(box.Intersect(new RectD(0, 0, width, height)));
            // A white sheet under the whole page draws nothing a slide doesn't already show.
            else if (!(shape.Fill == 0xFFFFFF && box.Width * box.Height >= 0.85 * width * height)) shapes.Add(shape);
        }
        return (shapes, KeptAsPictures(others, lines, pictures));
    }

    private static bool Usable(RectD b) => double.IsFinite(b.Width) && double.IsFinite(b.Height) && b.Width >= 0 && b.Height >= 0;

    private static bool IsThin(RectD b) => b.Width <= Thin || b.Height <= Thin;

    /// <summary>A filled rectangle or ellipse (the edges are looked at, not the middle: a label may lie there).</summary>
    private static ExportShape? Filled(Raster r, ExportPath path)
    {
        var b = path.Box;
        // Close enough to a corner that a small circle's corners lie outside it.
        var inset = Math.Min(1.5, 0.12 * Math.Min(b.Width, b.Height));
        // The path's own color, unless the rendering shows it differently (a blend, a pattern): that is what shows.
        var edge = 0.2 * Math.Min(b.Width, b.Height);
        if (r.Opaque(b.X + edge, b.CenterY) is not { } shown) return null;
        var color = r.Is(b.X + edge, b.CenterY, path.Color) ? path.Color : shown;
        double l = b.X + inset, t = b.Y + inset, right = b.Right - inset, bottom = b.Bottom - inset;
        if (!(r.Is(b.CenterX, b.Y + edge, color) && r.Is(b.Right - edge, b.CenterY, color) && r.Is(b.CenterX, b.Bottom - edge, color))) return null;
        if (r.Is(l, t, color) && r.Is(right, t, color) && r.Is(right, bottom, color) && r.Is(l, bottom, color))
            return new ExportShape(ExportShapeKind.Rectangle, b, color, null, 0);
        return OnEllipse(r, b, 0.8, color) && !OnEllipse(r, b, 1.08, color) && !r.Is(l, t, color)
            ? new ExportShape(ExportShapeKind.Ellipse, b, color, null, 0) : null;
    }

    /// <summary>All four diagonal points at <paramref name="at"/> times the ellipse's radius show the color.</summary>
    private static bool OnEllipse(Raster r, RectD b, double at, uint color, bool outline = false)
    {
        var (dx, dy) = (b.Width / 2 * at * Math.Sqrt(0.5), b.Height / 2 * at * Math.Sqrt(0.5));
        bool On(double x, double y) => outline ? r.Near(x, y, color, LineAlpha) : r.Is(x, y, color);
        return On(b.CenterX - dx, b.CenterY - dy) && On(b.CenterX + dx, b.CenterY - dy) && On(b.CenterX - dx, b.CenterY + dy) && On(b.CenterX + dx, b.CenterY + dy);
    }

    /// <summary>
    /// An outlined rectangle or ellipse. A stroked path's bounds leave room for mitered corners, so the outline is found
    /// first, walking in from each side.
    /// </summary>
    private static ExportShape? Outline(Raster r, ExportPath path)
    {
        var (b, color) = (path.Box, path.Color);
        var step = 1 / r.Scale;
        double? Walk(double x, double y, double dx, double dy, double max)
        {
            for (double d = 0; d <= max; d += step)
                if (r.Is(x + dx * d, y + dy * d, color, LineAlpha)) return d;
            return null;
        }
        if (Walk(b.X, b.CenterY, 1, 0, b.Width / 2) is not { } l || Walk(b.Right, b.CenterY, -1, 0, b.Width / 2) is not { } right
            || Walk(b.CenterX, b.Y, 0, 1, b.Height / 2) is not { } t || Walk(b.CenterX, b.Bottom, 0, -1, b.Height / 2) is not { } bottom) return null;
        // How thick: from the outer edge to where the color stops.
        var thick = 0.0;
        while (thick < b.Width / 2 && r.Is(b.X + l + thick, b.CenterY, color, LineAlpha)) thick += step;
        thick = Math.Max(0.25, thick);
        var mid = RectD.FromEdges(b.X + l + thick / 2, b.Y + t + thick / 2, b.Right - right - thick / 2, b.Bottom - bottom - thick / 2);
        if (mid.Width <= 0 || mid.Height <= 0) return null;
        bool Corner(double x, double y) => r.Is(x, y, color, LineAlpha);
        if (Corner(mid.X, mid.Y) && Corner(mid.Right, mid.Y) && Corner(mid.Right, mid.Bottom) && Corner(mid.X, mid.Bottom))
        {
            // Outlines only: a dashed line passes through the corners and the walks too, so the sides must be whole.
            for (var k = 0.125; k < 1; k += 0.125)
                if (!r.Is(mid.X + mid.Width * k, mid.Y, color, LineAlpha) || !r.Is(mid.X, mid.Y + mid.Height * k, color, LineAlpha)) return null;
            return new ExportShape(ExportShapeKind.Rectangle, mid, null, color, thick);
        }
        return OnEllipse(r, mid, 1, color, outline: true) && !Corner(mid.X, mid.Y)
            ? new ExportShape(ExportShapeKind.Ellipse, mid, null, color, thick) : null;
    }

    /// <summary>The paths that are no simple shape, joined where they touch; not where text lies on them or a picture already shows them.</summary>
    private static List<RectD> KeptAsPictures(List<RectD> others, IReadOnlyList<ExportLine> lines, IReadOnlyList<RectD> pictures)
    {
        var areas = others.Where(b => b.Width >= 3 && b.Height >= 3).ToList();
        for (var merged = true; merged;)
        {
            merged = false;
            for (var i = 0; i < areas.Count && !merged; i++)
            for (var j = i + 1; j < areas.Count && !merged; j++)
            {
                if (areas[i].Inflate(2).Intersect(areas[j]).IsEmpty) continue;
                areas[i] = areas[i].Union(areas[j]);
                areas.RemoveAt(j);
                merged = true;
            }
        }
        return [.. areas.Where(a =>
            !lines.Any(l => a.Contains(l.Box.CenterX, l.Box.CenterY)) &&
            !pictures.Any(p => p.Inflate(1).Contains(a.CenterX, a.CenterY)))];
    }
}
