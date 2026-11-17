using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// Moving and recoloring sticky notes and text marks in place (drawings have <see cref="Annotations.UpdateGeometry"/> and
/// <see cref="Annotations.UpdateStyle"/>): the annotation keeps its id, text, author and replies. The Mac's
/// <c>AnnotationMoves</c>; a signed file takes them as appended changes, like every other comment edit.
/// </summary>
public static partial class Annotations
{
    private static readonly HashSet<string> MarkupSubtypes = ["Highlight", "Underline", "StrikeOut", "Squiggly"];

    /// <summary>A sticky note or a text mark (highlight, underline, strike-out, squiggly): what <see cref="Move"/> and <see cref="SetColor"/> take.</summary>
    public static bool MovesInPlace(AnnotationInfo a) => a.Subtype == "Text" || MarkupSubtypes.Contains(a.Subtype);

    /// <summary>
    /// Moves a note or a text mark by (<paramref name="dx"/>, <paramref name="dy"/>) page points on its page. Its /Rect and
    /// /QuadPoints (and its popup) shift; the appearance follows /Rect, so it looks the same where it lands. Its replies of
    /// any kind (and replies to them) and their popups come along (<see cref="ThreadOf"/>, what a delete removes). A move by
    /// nothing gives the same bytes back.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">The move isn't a finite number.</exception>
    /// <exception cref="InvalidOperationException">There is no such comment, or it is another kind.</exception>
    public static byte[] Move(byte[] data, string? password, string id, double dx, double dy)
    {
        CheckPosition(dx, dy, nameof(dx));
        using var doc = OpenForEdit(data, password);
        var (p, annot) = Find(doc, id) ?? throw new InvalidOperationException(PdfStrings.Annot_Gone);
        CheckMovable(annot);
        if (dx == 0 && dy == 0) return data;
        MoveIn(doc, p, annot, dx, dy);
        return PdfObj.Save(doc);
    }

    /// <summary>
    /// Moves a note or a text mark so that its frame's top-left corner (page space) is at (<paramref name="x"/>,
    /// <paramref name="y"/>): a note's icon, a text mark's marked lines together (<see cref="DrawingGeometry.OfComment"/>'s
    /// bounds). Worked out from where the document has it when the edit runs, so an earlier move that never happened
    /// (cancelled, refused) isn't counted. Already there: the same bytes back.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">The place isn't a finite number.</exception>
    /// <exception cref="InvalidOperationException">There is no such comment, or it is another kind.</exception>
    public static byte[] MoveTo(byte[] data, string? password, string id, double x, double y)
    {
        CheckPosition(x, y, nameof(x));
        using var doc = OpenForEdit(data, password);
        var (p, annot) = Find(doc, id) ?? throw new InvalidOperationException(PdfStrings.Annot_Gone);
        CheckMovable(annot);
        var page = doc.Pages[p];
        var frame = FrameOf(page, annot);
        double dx = x - frame.X, dy = y - frame.Y;
        if (!double.IsFinite(dx) || !double.IsFinite(dy)) throw new ArgumentOutOfRangeException(nameof(x), PdfStrings.Annot_PositionNotNumber);
        if (Math.Abs(dx) < 1e-6 && Math.Abs(dy) < 1e-6) return data;
        MoveIn(doc, p, annot, dx, dy);
        return PdfObj.Save(doc);
    }

    /// <summary>Where a note or a text mark is (page space): its marked lines' bounds, else its /Rect.</summary>
    private static RectD FrameOf(PdfPage page, PdfDictionary annot)
    {
        var quads = QuadRectsOf(page, annot);
        if (quads.Count > 0)
            return RectD.FromEdges(quads.Min(q => q.X), quads.Min(q => q.Y), quads.Max(q => q.Right), quads.Max(q => q.Bottom));
        return PdfObj.Array(annot.Elements["/Rect"]) is { } r ? PdfObj.RectToPage(page, r) : default;
    }

    private static void CheckPosition(double a, double b, string name)
    {
        if (!double.IsFinite(a) || !double.IsFinite(b) || Math.Abs(a) > MaxMove || Math.Abs(b) > MaxMove)
            throw new ArgumentOutOfRangeException(name, PdfStrings.Annot_PositionNotNumber);
    }

    private static void MoveIn(PdfDocument doc, int p, PdfDictionary annot, double dx, double dy)
    {
        var page = doc.Pages[p];
        var o = PdfObj.ToPdf(page, 0, 0);
        var d = PdfObj.ToPdf(page, dx, dy);
        double vx = d.X - o.X, vy = d.Y - o.Y;

        // Every point an annotation of any kind keeps: its box, marked lines, line ends, vertices, ink and callout line.
        PdfArray? Shifted(PdfArray arr)
        {
            if (arr.Elements.Count < 2) return null;
            var values = new double[arr.Elements.Count];
            for (var i = 0; i < values.Length; i++) values[i] = PdfObj.Num(arr, i) + (i % 2 == 0 ? vx : vy);
            return PdfObj.Reals(doc, values);
        }
        void Shift(PdfDictionary a)
        {
            foreach (var key in (string[])["/Rect", "/QuadPoints", "/L", "/Vertices", "/CL"])
                if (PdfObj.Array(a.Elements[key]) is { } arr && Shifted(arr) is { } moved) a.Elements[key] = moved;
            if (PdfObj.Array(a.Elements["/InkList"]) is { } ink)
                for (var i = 0; i < ink.Elements.Count; i++)
                    if (PdfObj.Array(ink.Elements[i]) is { } stroke && Shifted(stroke) is { } moved) ink.Elements[i] = moved;
        }

        // The comment, its replies and their popups; one listed on another page stays where it is.
        var elsewhere = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        for (var q = 0; q < doc.PageCount; q++)
            if (q != p && PdfObj.Array(doc.Pages[q].Elements["/Annots"]) is { } others)
                foreach (var item in others.Elements)
                    if (PdfObj.Dict(item) is { } a) elsewhere.Add(a);
        foreach (var a in ThreadOf(doc, annot))
            if (!elsewhere.Contains(a)) Shift(a);
        annot.Elements["/M"] = PdfObj.DateString(DateTimeOffset.Now);
    }

    /// <summary>
    /// Recolors a note or a text mark: /C and its look, drawn again in <paramref name="color"/>. A note's replies that sit
    /// on it as notes take the color too (their bubbles cover it). A mark of more lines than <see cref="MaxQuads"/> is
    /// refused rather than drawn short.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">A component isn't a number from 0 to 1.</exception>
    /// <exception cref="InvalidOperationException">There is no such comment, it is another kind, or it marks too many lines.</exception>
    public static byte[] SetColor(byte[] data, string? password, string id, AnnotColor color)
    {
        if (!InUnit(color.R) || !InUnit(color.G) || !InUnit(color.B))
            throw new ArgumentOutOfRangeException(nameof(color), PdfStrings.Annot_StyleInvalid);
        using var doc = OpenForEdit(data, password);
        var (p, annot) = Find(doc, id) ?? throw new InvalidOperationException(PdfStrings.Annot_Gone);
        CheckMovable(annot);
        var page = doc.Pages[p];
        if (!RedrawComment(doc, page, annot, color, fitRect: true)) throw new InvalidOperationException(PdfStrings.Annot_TooManyLines);
        annot.Elements["/C"] = PdfObj.Reals(doc, color.R, color.G, color.B);
        annot.Elements["/M"] = PdfObj.DateString(DateTimeOffset.Now);
        if (PdfObj.Name(annot.Elements["/Subtype"]) == "Text")
        {
            var onPage = PdfObj.Array(page.Elements["/Annots"])?.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()
                .ToHashSet(ReferenceEqualityComparer.Instance) ?? [];
            foreach (var reply in ThreadOf(doc, annot))
                if (!ReferenceEquals(reply, annot) && onPage.Contains(reply) && PdfObj.Name(reply.Elements["/Subtype"]) == "Text")
                {
                    reply.Elements["/C"] = PdfObj.Reals(doc, color.R, color.G, color.B);
                    RedrawComment(doc, page, reply, color, fitRect: false);
                }
        }
        return PdfObj.Save(doc);

        static bool InUnit(double v) => double.IsFinite(v) && v is >= 0 and <= 1;
    }

    /// <summary>
    /// Draws a note's or a text mark's look again in <paramref name="color"/> from its own entries (what
    /// <see cref="SetColor"/>, after setting /C, and an import without an appearance share): a mark from its /QuadPoints (with
    /// <paramref name="fitRect"/>, /Rect becomes what the marks cover); a note Inkvolt's bubble when its icon (/Name) is the
    /// Comment one or none, else no appearance, so viewers draw that icon in /C (MuPDF and Acrobat do), and another
    /// app's key, help or paragraph icon stays one. False, and nothing drawn, for a mark of more than
    /// <see cref="MaxQuads"/> lines; a mark with no line or a corner that isn't a number keeps its look.
    /// </summary>
    internal static bool RedrawComment(PdfDocument doc, PdfPage page, PdfDictionary annot, AnnotColor color, bool fitRect)
    {
        var e = annot.Elements;
        var subtype = PdfObj.Name(e["/Subtype"]) ?? "";
        if (subtype == "Text")
        {
            if (PdfObj.Name(e["/Name"]) is null or "Comment") SetAppearance(doc, annot, NoteAppearance(doc, page, color));
            else e.Remove("/AP");
            return true;
        }
        if (!Enum.TryParse<TextMarkupKind>(subtype, out var kind)) return true;
        var qp = PdfObj.Array(e["/QuadPoints"]);
        if (qp is not null && qp.Elements.Count / 8 > MaxQuads) return false;
        if (qp is null || qp.Elements.Count < 8) return true;
        var quads = new List<Quad>();
        for (var k = 0; k + 7 < qp.Elements.Count; k += 8)
            quads.Add(new Quad((PdfObj.Num(qp, k), PdfObj.Num(qp, k + 1)), (PdfObj.Num(qp, k + 2), PdfObj.Num(qp, k + 3)),
                (PdfObj.Num(qp, k + 4), PdfObj.Num(qp, k + 5)), (PdfObj.Num(qp, k + 6), PdfObj.Num(qp, k + 7))));
        if (!quads.SelectMany(q => new[] { q.UL.X, q.UL.Y, q.UR.X, q.UR.Y, q.LL.X, q.LL.Y, q.LR.X, q.LR.Y }).All(double.IsFinite)) return true;
        var (form, x1, y1, x2, y2) = MarkupAppearance(doc, kind, quads, color);
        if (fitRect) e["/Rect"] = PdfObj.Reals(doc, x1, y1, x2, y2);
        SetAppearance(doc, annot, form);
        return true;
    }

    /// <summary>The farthest a move goes in one step (points): beyond any page (PDF's largest is 14,400 pt a side).</summary>
    private const double MaxMove = 1_000_000;

    /// <summary>The most marked lines a text mark is drawn for (a hostile file can list millions).</summary>
    internal const int MaxQuads = 20_000;

    private static void CheckMovable(PdfDictionary a)
    {
        var subtype = PdfObj.Name(a.Elements["/Subtype"]) ?? "";
        if (subtype != "Text" && !MarkupSubtypes.Contains(subtype)) throw new InvalidOperationException(PdfStrings.Annot_CantMoveThisWay);
    }
}
