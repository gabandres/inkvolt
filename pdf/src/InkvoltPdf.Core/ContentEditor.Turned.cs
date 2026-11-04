namespace InkvoltPdf.Core;

/// <summary>
/// Paragraphs in turned text (roadmap 2.1): a page's runs of one direction are turned upright about the page's origin
/// (the paragraph's own frame), grouped and laid out there as upright text is, and the result turned back onto the page.
/// The writing needs nothing more: a line's start on the page goes back into the run's own text space (see
/// <c>WriteParagraph</c>), which already runs in its direction.
/// </summary>
public static partial class ContentEditor
{
    /// <summary>How many directions of turned text a page is grouped in at most (the ones with the most runs).</summary>
    private const int MaxDirections = 16;

    /// <summary>
    /// The directions of a page's turned text, degrees clockwise (as <see cref="TextRun.Angle"/>): runs within half a
    /// degree of each other are one direction; a direction needs at least two runs to make a paragraph of more than
    /// one run.
    /// </summary>
    private static List<double> TurnedAngles(PageContent content)
    {
        var angles = content.Runs
            .Where(r => r.Reach is not null && r.Text.Trim().Length > 0 && r.FontSize > 0.5 && Math.Abs(Turn(r.Angle)) >= 0.5)
            .Select(r => (Turn(r.Angle) + 360) % 360) // 0 to 360, so that 180° and -180° are together
            .Order().ToList();
        var groups = new List<List<double>>();
        foreach (var a in angles)
        {
            if (groups.Count > 0 && a - groups[^1][0] < 0.5) groups[^1].Add(a);
            else groups.Add([a]);
        }
        return [.. groups.Where(g => g.Count >= 2).OrderByDescending(g => g.Count).Take(MaxDirections).Select(g => Turn(g[g.Count / 2]))];
    }

    /// <summary>An angle as -180 (excluded) to 180 degrees.</summary>
    internal static double Turn(double degrees)
    {
        var a = degrees % 360;
        if (a > 180) a -= 360;
        else if (a <= -180) a += 360;
        return a;
    }

    /// <summary>A page point in a frame turned <paramref name="angle"/> (the frame's x axis along that direction).</summary>
    internal static PointD ToFrame(PointD p, double angle)
    {
        var (sin, cos) = Math.SinCos(angle * Math.PI / 180);
        return new PointD(p.X * cos + p.Y * sin, -p.X * sin + p.Y * cos);
    }

    /// <summary>A point of a frame turned <paramref name="angle"/> back on the page.</summary>
    internal static PointD FromFrame(PointD p, double angle) => ToFrame(p, -angle);

    /// <summary>A rectangle's bounding box once turned by <paramref name="angle"/> (<see cref="ToFrame"/>).</summary>
    private static RectD Turned(RectD r, double angle)
    {
        double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
        foreach (var c in new[] { new PointD(r.X, r.Y), new PointD(r.Right, r.Y), new PointD(r.Right, r.Bottom), new PointD(r.X, r.Bottom) })
        {
            var t = ToFrame(c, angle);
            (minX, minY, maxX, maxY) = (Math.Min(minX, t.X), Math.Min(minY, t.Y), Math.Max(maxX, t.X), Math.Max(maxY, t.Y));
        }
        return RectD.FromEdges(minX, minY, maxX, maxY);
    }

    /// <summary>
    /// The page's content in the frame of <paramref name="angle"/>: its runs of that direction upright, with their own
    /// boxes there; every other run and picture as the bounding box of where it is (what a paragraph runs into, or what
    /// sits on its lines). A run of that direction that is mirrored or slanted has no box there and takes no part.
    /// Each run in the frame leads back to the page's.
    /// </summary>
    private static (PageContent Framed, Dictionary<TextRun, TextRun> Page) Framed(PageContent content, double angle)
    {
        var page = new Dictionary<TextRun, TextRun>(ReferenceEqualityComparer.Instance);
        var runs = new List<TextRun>(content.Runs.Count);
        foreach (var r in content.Runs)
        {
            var rel = Turn(r.Angle - angle);
            var origin = ToFrame(r.Origin, angle);
            TextRun f;
            if (Math.Abs(rel) < 0.5 && r.Reach is { } reach)
                f = r with
                {
                    Box = RectD.FromEdges(origin.X - reach.Back, origin.Y - reach.Above, origin.X + reach.Along, origin.Y + reach.Below),
                    Origin = origin,
                    Angle = rel,
                };
            // Not upright in any frame: never grouped (NaN is no angle), still something on the lines.
            else f = r with { Box = Turned(r.Box, angle), Origin = origin, Angle = Math.Abs(rel) < 0.5 ? double.NaN : rel };
            page[f] = r;
            runs.Add(f);
        }
        var images = content.Images.Select(i => i with { Box = Turned(i.Box, angle) }).ToList();
        return (new PageContent(runs, images), page);
    }

    /// <summary>A paragraph grouped in the frame of <paramref name="angle"/>, on the page: its own runs, its boxes' bounding boxes, the frame kept.</summary>
    private static TextParagraph Turned(TextParagraph framed, double angle, Dictionary<TextRun, TextRun> page) => framed with
    {
        Runs = [.. framed.Runs.Select(r => page[r])],
        Spaces = [.. framed.Spaces.Select(r => page[r])],
        Lines = [.. framed.Lines.Select(l => Turned(l, -angle))],
        Box = Turned(framed.Box, -angle),
        Below = framed.Below is { } b ? Turned(b, -angle) : null,
        Angle = angle,
        Upright = framed,
    };

    /// <summary>A layout made in a turned paragraph's frame, on the page: its lines' starts turned back, its box and what it runs into as bounding boxes.</summary>
    private static ParagraphLayout OnPage(ParagraphLayout layout, TextParagraph p)
    {
        var check = layout.Check with
        {
            Box = Turned(layout.Check.Box, -p.Angle),
            Overlaps = layout.Check.Overlaps is null ? null : p.Below,
        };
        return layout with
        {
            Lines = [.. layout.Lines.Select(l => (FromFrame(l.Origin, p.Angle), l.Parts))],
            Check = check,
        };
    }

    /// <summary>Whether a page point is inside a paragraph's box (a turned one's in its own direction).</summary>
    internal static bool Holds(TextParagraph p, double x, double y)
    {
        if (p.Upright is not { } u) return p.Box.Contains(x, y);
        var f = ToFrame(new PointD(x, y), p.Angle);
        return u.Box.Contains(f.X, f.Y);
    }
}
