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
    /// /QuadPoints (and a note's popup) shift; the appearance follows /Rect, so it looks the same where it lands. Replies
    /// (and replies to them) come along. A move by nothing gives the same bytes back.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">The move isn't a finite number.</exception>
    /// <exception cref="InvalidOperationException">There is no such comment, or it is another kind.</exception>
    public static byte[] Move(byte[] data, string? password, string id, double dx, double dy)
    {
        if (!double.IsFinite(dx) || !double.IsFinite(dy) || Math.Abs(dx) > MaxMove || Math.Abs(dy) > MaxMove)
            throw new ArgumentOutOfRangeException(nameof(dx), PdfStrings.Annot_PositionNotNumber);
        using var doc = OpenForEdit(data, password);
        var (p, annot) = Find(doc, id) ?? throw new InvalidOperationException(PdfStrings.Annot_Gone);
        CheckMovable(annot);
        if (dx == 0 && dy == 0) return data;
        var page = doc.Pages[p];
        var o = PdfObj.ToPdf(page, 0, 0);
        var d = PdfObj.ToPdf(page, dx, dy);
        double vx = d.X - o.X, vy = d.Y - o.Y;

        void ShiftArray(PdfDictionary dict, string key)
        {
            if (PdfObj.Array(dict.Elements[key]) is not { } arr || arr.Elements.Count < 2) return;
            var values = new double[arr.Elements.Count];
            for (var i = 0; i < values.Length; i++) values[i] = PdfObj.Num(arr, i) + (i % 2 == 0 ? vx : vy);
            dict.Elements[key] = PdfObj.Reals(doc, values);
        }
        void Shift(PdfDictionary a)
        {
            ShiftArray(a, "/Rect");
            ShiftArray(a, "/QuadPoints");
            if (PdfObj.Dict(a.Elements["/Popup"]) is { } popup) ShiftArray(popup, "/Rect");
        }

        Shift(annot);
        annot.Elements["/M"] = PdfObj.DateString(DateTimeOffset.Now);
        // Replies sit on their comment (and replies to them on theirs): they come along.
        var replies = new List<PdfDictionary>();
        if (PdfObj.Array(page.Elements["/Annots"]) is { } annots)
            foreach (var item in annots.Elements)
                if (PdfObj.Dict(item) is { } r && PdfObj.Name(r.Elements["/Subtype"]) == "Text" && PdfObj.Dict(r.Elements["/IRT"]) is not null)
                    replies.Add(r);
        var moved = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance) { annot };
        var parents = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance) { annot };
        while (parents.Count > 0)
        {
            var next = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
            foreach (var r in replies)
                if (PdfObj.Dict(r.Elements["/IRT"]) is { } irt && parents.Contains(irt) && moved.Add(r))
                {
                    Shift(r);
                    next.Add(r);
                }
            parents = next;
        }
        return PdfObj.Save(doc);
    }

    /// <summary>Recolors a note or a text mark: /C and its appearance, drawn again in <paramref name="color"/>.</summary>
    /// <exception cref="ArgumentOutOfRangeException">A component isn't a number from 0 to 1.</exception>
    /// <exception cref="InvalidOperationException">There is no such comment, or it is another kind.</exception>
    public static byte[] SetColor(byte[] data, string? password, string id, AnnotColor color)
    {
        if (!InUnit(color.R) || !InUnit(color.G) || !InUnit(color.B))
            throw new ArgumentOutOfRangeException(nameof(color), PdfStrings.Annot_StyleInvalid);
        using var doc = OpenForEdit(data, password);
        var (p, annot) = Find(doc, id) ?? throw new InvalidOperationException(PdfStrings.Annot_Gone);
        CheckMovable(annot);
        var page = doc.Pages[p];
        var subtype = PdfObj.Name(annot.Elements["/Subtype"]) ?? "";
        annot.Elements["/C"] = PdfObj.Reals(doc, color.R, color.G, color.B);
        annot.Elements["/M"] = PdfObj.DateString(DateTimeOffset.Now);
        if (subtype == "Text")
        {
            SetAppearance(doc, annot, NoteAppearance(doc, page, color));
        }
        else if (Enum.TryParse<TextMarkupKind>(subtype, out var kind) && PdfObj.Array(annot.Elements["/QuadPoints"]) is { } qp && qp.Elements.Count >= 8)
        {
            var quads = new List<Quad>();
            for (var k = 0; k + 7 < qp.Elements.Count && quads.Count < MaxQuads; k += 8)
                quads.Add(new Quad((PdfObj.Num(qp, k), PdfObj.Num(qp, k + 1)), (PdfObj.Num(qp, k + 2), PdfObj.Num(qp, k + 3)),
                    (PdfObj.Num(qp, k + 4), PdfObj.Num(qp, k + 5)), (PdfObj.Num(qp, k + 6), PdfObj.Num(qp, k + 7))));
            if (quads.SelectMany(q => new[] { q.UL.X, q.UL.Y, q.UR.X, q.UR.Y, q.LL.X, q.LL.Y, q.LR.X, q.LR.Y }).All(double.IsFinite))
            {
                var (form, x1, y1, x2, y2) = MarkupAppearance(doc, kind, quads, color);
                annot.Elements["/Rect"] = PdfObj.Reals(doc, x1, y1, x2, y2);
                SetAppearance(doc, annot, form);
            }
        }
        return PdfObj.Save(doc);

        static bool InUnit(double v) => double.IsFinite(v) && v is >= 0 and <= 1;
    }

    /// <summary>The farthest a move goes in one step (points): beyond any page (PDF's largest is 14,400 pt a side).</summary>
    private const double MaxMove = 1_000_000;

    /// <summary>The most marked lines a text mark's appearance is drawn again for (a hostile file can list millions).</summary>
    internal const int MaxQuads = 20_000;

    private static void CheckMovable(PdfDictionary a)
    {
        var subtype = PdfObj.Name(a.Elements["/Subtype"]) ?? "";
        if (subtype != "Text" && !MarkupSubtypes.Contains(subtype)) throw new InvalidOperationException(PdfStrings.Annot_CantMoveThisWay);
    }
}
