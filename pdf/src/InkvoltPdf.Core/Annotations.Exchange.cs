using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

public static partial class Annotations
{
    /// <summary>
    /// Adds a reply to a comment: a note bound to it (/IRT, reply type R) at its top-left corner, drawn as the note icon,
    /// as Acrobat makes them. Replies list under their comment and travel with it (export, import, summary).
    /// </summary>
    public static byte[] AddReply(byte[] data, string? password, string parentId, string text, string author, string? id = null)
    {
        using var doc = OpenForEdit(data, password);
        var (p, parent) = Find(doc, parentId) ?? throw new InvalidOperationException("That comment no longer exists.");
        if (parent.Reference is null) throw new InvalidOperationException("That comment can't be replied to.");
        var page = doc.Pages[p];
        var r = PdfObj.Array(parent.Elements["/Rect"]);
        double x = r is null ? 0 : Math.Min(PdfObj.Num(r, 0), PdfObj.Num(r, 2)), top = r is null ? 20 : Math.Max(PdfObj.Num(r, 1), PdfObj.Num(r, 3));
        var color = ColorOf(PdfObj.Array(parent.Elements["/C"])) ?? AnnotColor.Yellow;
        var annot = NewAnnot(doc, page, "Text", x, top - 20, x + 20, top, id, text, author, color);
        annot.Elements["/IRT"] = parent.Reference;
        annot.Elements["/RT"] = new PdfName("/R");
        annot.Elements["/Name"] = new PdfName("/Comment");
        annot.Elements["/F"] = new PdfInteger(FlagPrint | 8 | 16); // no zoom, no rotate: stays an icon
        SetAppearance(doc, annot, NoteAppearance(doc, page, color));
        return PdfObj.Save(doc);
    }

    /// <summary>
    /// Gives an imported annotation that came without an appearance (XFDF, CSV) the one Inkvolt PDF would draw for it:
    /// drawings from their geometry and style, text markups from their quads, notes their icon, stamps their design (a
    /// built-in one by /Name, else the name in a frame). Kinds it doesn't draw are left to the viewer. /M stays as it was.
    /// </summary>
    internal static void MakeAppearance(PdfDocument doc, PdfPage page, PdfDictionary annot)
    {
        var e = annot.Elements;
        var subtype = PdfObj.Name(e["/Subtype"]) ?? "";
        var modified = e["/M"];
        var color = ColorOf(PdfObj.Array(e["/C"]));
        try
        {
            if (IsDrawing(annot, subtype))
            {
                if (Describe(page, annot, subtype) is not { } d) return;
                Validate(subtype, d.Geometry, d.Style);
                Apply(doc, page, annot, subtype, d.Geometry, d.Style);
            }
            else if (Enum.TryParse<TextMarkupKind>(subtype, out var markup))
            {
                var quads = new List<Quad>();
                if (PdfObj.Array(e["/QuadPoints"]) is { } qp)
                    for (var k = 0; k + 7 < qp.Elements.Count && quads.Count < MaxPoints; k += 8)
                        quads.Add(new Quad((PdfObj.Num(qp, k), PdfObj.Num(qp, k + 1)), (PdfObj.Num(qp, k + 2), PdfObj.Num(qp, k + 3)),
                            (PdfObj.Num(qp, k + 4), PdfObj.Num(qp, k + 5)), (PdfObj.Num(qp, k + 6), PdfObj.Num(qp, k + 7))));
                if (quads.Count == 0) return;
                var (form, _, _, _, _) = MarkupAppearance(doc, markup, quads, color ?? AnnotColor.Yellow);
                SetAppearance(doc, annot, form);
            }
            else if (subtype == "Text") SetAppearance(doc, annot, NoteAppearance(doc, page, color ?? AnnotColor.Yellow));
            else if (subtype == "Stamp" && PdfObj.Array(e["/Rect"]) is { Elements.Count: 4 } r)
            {
                var name = PdfObj.Name(e["/Name"]) ?? "Draft";
                var design = RubberStamps.DesignOf(annot)
                    ?? RubberStamps.BuiltIn.FirstOrDefault(b => b.Name.Equals(name.TrimStart('#').Replace("Stamp", "", StringComparison.Ordinal), StringComparison.OrdinalIgnoreCase))
                    ?? new StampDesign(name, name, name.TrimStart('#').ToUpperInvariant(), null, color ?? StampDesign.Blue);
                var w = Math.Abs(PdfObj.Num(r, 2) - PdfObj.Num(r, 0));
                var h = Math.Abs(PdfObj.Num(r, 3) - PdfObj.Num(r, 1));
                if (w < 1 || h < 1) return;
                var (ops, resources) = RubberStamps.Appearance(doc, design, w, h);
                SetAppearance(doc, annot, PdfObj.FormXObject(doc, ops, 0, 0, w, h, resources));
            }
        }
        catch (ArgumentException)
        {
            // Geometry or style it can't draw: the annotation stays without an appearance (viewers draw their own).
        }
        finally
        {
            if (modified is null) e.Remove("/M");
            else e["/M"] = modified;
        }
    }
}
