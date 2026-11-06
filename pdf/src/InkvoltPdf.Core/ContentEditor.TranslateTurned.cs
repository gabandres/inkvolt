namespace InkvoltPdf.Core;

/// <summary>
/// A quarter turn of a page for its turned text in a translated copy (a table set sideways, a landscape page's text on a
/// portrait page): the frame <see cref="ExportPage.Turned"/> uses, where text of that direction reads left to right and
/// the page's box starts at (0, 0), so a table's rows and columns are found there as on an upright page and the room a
/// paragraph has is worked out the same way. <see cref="Turn"/>: quarter turns clockwise the text reads in (1 top to
/// bottom, 2 upside down, 3 bottom to top, as <see cref="ExportLine.Turn"/>).
/// </summary>
internal sealed record TranslationFrame(int Turn, double PageWidth, double PageHeight)
{
    /// <summary>The direction of the frame's text on the page, as <see cref="TextRun.Angle"/>.</summary>
    public double Angle => Turn switch { 1 => 90, 2 => 180, _ => -90 };

    /// <summary>The page's size in the frame.</summary>
    public double Width => Turn == 2 ? PageWidth : PageHeight;

    public double Height => Turn == 2 ? PageHeight : PageWidth;

    // ContentEditor.ToFrame turns about the page's origin; this moves the turned page back to (0, 0).
    private PointD Offset => Turn switch { 1 => new(0, PageWidth), 2 => new(PageWidth, PageHeight), _ => new(PageHeight, 0) };

    public PointD In(PointD p)
    {
        var t = ContentEditor.ToFrame(p, Angle);
        return new PointD(t.X + Offset.X, t.Y + Offset.Y);
    }

    public PointD Out(PointD p) => ContentEditor.FromFrame(new PointD(p.X - Offset.X, p.Y - Offset.Y), Angle);

    public RectD In(RectD r) => Box(r, In);

    public RectD Out(RectD r) => Box(r, Out);

    private static RectD Box(RectD r, Func<PointD, PointD> map)
    {
        var a = map(new PointD(r.X, r.Y));
        var b = map(new PointD(r.Right, r.Bottom));
        return RectD.FromEdges(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
    }
}

/// <summary>A page's text of one quarter turn in its frame (<see cref="TranslationFrame"/>), the table cells found there, and each run there's run on the page.</summary>
internal sealed record TurnedPart(TranslationFrame Frame, PageContent Content, IReadOnlyList<RectD> Cells, IReadOnlyDictionary<TextRun, TextRun> Page);

public static partial class ContentEditor
{
    /// <summary>
    /// A page's turned text a translated copy rewrites: each quarter turn its runs read in (within half a degree; text at
    /// another angle, mirrored or slanted stays and is named), in its frame with the cells <paramref name="cells"/> found
    /// there (by quarter turn, in the frame). In the frame the direction's runs are upright with their own boxes, every
    /// other run is in the way where it is (no angle, so never grouped there), and each run's clip is turned too.
    /// </summary>
    internal static List<TurnedPart> TurnedParts(PageContent content, double pageWidth, double pageHeight, IReadOnlyDictionary<int, IReadOnlyList<RectD>>? cells)
    {
        var parts = new List<TurnedPart>();
        for (var turn = 1; turn <= 3; turn++)
        {
            var frame = new TranslationFrame(turn, pageWidth, pageHeight);
            var mine = new HashSet<TextRun>(content.Runs.Where(r => r.Reach is not null && r.Text.Trim().Length > 0 && r.FontSize > 0.5 && Math.Abs(Turn(r.Angle - frame.Angle)) < 0.5),
                ReferenceEqualityComparer.Instance);
            if (mine.Count == 0) continue;
            var (framed, onPage) = Framed(content, frame.Angle, mine);
            // Framed turns about the page's origin: moved so the page starts at (0, 0), as ExportPage.Turned does.
            var o = frame.In(new PointD(0, 0));
            RectD Moved(RectD b) => new(b.X + o.X, b.Y + o.Y, b.Width, b.Height);
            var page = new Dictionary<TextRun, TextRun>(ReferenceEqualityComparer.Instance);
            var runs = new List<TextRun>(framed.Runs.Count);
            foreach (var r in framed.Runs)
            {
                var moved = r with
                {
                    Box = Moved(r.Box),
                    Origin = new PointD(r.Origin.X + o.X, r.Origin.Y + o.Y),
                    Info = r.Info is { Clip: { } clip } info ? info with { Clip = frame.In(clip) } : r.Info,
                };
                page[moved] = onPage[r];
                runs.Add(moved);
            }
            var images = framed.Images.Select(i => i with { Box = Moved(i.Box) }).ToList();
            parts.Add(new TurnedPart(frame, new PageContent(runs, images), cells?.GetValueOrDefault(turn) ?? [], page));
        }
        return parts;
    }

    /// <summary>A paragraph grouped in a turned part's frame, on the page: its runs the page's (same order), its boxes turned back, the frame's paragraph kept as <see cref="TextParagraph.Upright"/>.</summary>
    private static TextParagraph OnPage(TextParagraph framed, TurnedPart part) => framed with
    {
        Runs = [.. framed.Runs.Select(r => part.Page[r])],
        Spaces = [.. framed.Spaces.Select(r => part.Page[r])],
        Lines = [.. framed.Lines.Select(part.Frame.Out)],
        Box = part.Frame.Out(framed.Box),
        Below = framed.Below is { } b ? part.Frame.Out(b) : null,
        Angle = part.Frame.Angle,
        Upright = framed,
    };

    /// <summary>New lines by the run they are written at, from a turned part's frame onto the page: the page's runs, the lines' starts turned back.</summary>
    private static Dictionary<TextRun, List<(PointD Origin, List<Part> Parts)>> OnPage(Dictionary<TextRun, List<(PointD Origin, List<Part> Parts)>> lines, TurnedPart part)
    {
        var result = new Dictionary<TextRun, List<(PointD, List<Part>)>>(ReferenceEqualityComparer.Instance);
        foreach (var (run, list) in lines) result[part.Page[run]] = [.. list.Select(l => (part.Frame.Out(l.Origin), l.Parts))];
        return result;
    }
}
