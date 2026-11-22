using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// Turning a picture or a paragraph to any angle (roadmap 4.22), about the middle of its box. A picture gets the turn in
/// front of its own placement (as a move does); a paragraph's show operators are each drawn again from a text matrix
/// turned the same way (its glyphs, spacing and kerning as they were), and the text position put back where each left it,
/// so the rest of the page draws where it did. One save, so one undo step.
/// </summary>
public static partial class ContentEditor
{
    /// <summary>Turns a picture <paramref name="degrees"/> clockwise (as the page shows) about the middle of its box.</summary>
    public static byte[] RotateImage(byte[] data, string? password, PageImage image, double degrees)
    {
        degrees = Turn(degrees);
        if (Math.Abs(degrees) < 0.01) return data;
        if (!double.IsFinite(degrees)) throw new ArgumentOutOfRangeException(nameof(degrees));
        return EditImage(data, password, image, (doc, page, found, op, ctm, ops, content) =>
            [Placing(ops, op, TurnMatrix(page, ctm, new PointD(found.Box.CenterX, found.Box.CenterY), degrees), content)]);
    }

    /// <summary>
    /// Turns a paragraph <paramref name="degrees"/> clockwise (as the page shows) about the middle of its box, its
    /// pictures with it. Its text isn't rewritten: each show operator is drawn as it was, from a turned text matrix.
    /// </summary>
    /// <exception cref="ContentEditException">The paragraph can't be edited, or the page changed.</exception>
    public static byte[] RotateParagraph(byte[] data, string? password, TextParagraph paragraph, double degrees)
    {
        if (paragraph.Blocked is { } why0) throw new ContentEditException(Loc.Format(PdfStrings.Edit_ParagraphCantBeEdited, why0));
        degrees = Turn(degrees);
        if (!double.IsFinite(degrees)) throw new ArgumentOutOfRangeException(nameof(degrees));
        if (Math.Abs(degrees) < 0.01) return data;
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, PdfStrings.Doc_CantEdit);
        var page = PageOf(doc, paragraph.PageIndex);
        var streams = Streams(page);
        var ops = ContentLexer.Parse(streams.Bytes);
        var walk = Walk(page, paragraph.PageIndex, ops, default);
        var now = new List<TextRun>();
        foreach (var run in paragraph.Runs.Concat(paragraph.Spaces))
        {
            var found = walk.Content.Runs.FirstOrDefault(r => r.Id == run.Id && r.Text == run.Text)
                        ?? walk.Content.Runs.Where(r => r.Text == run.Text && Near(r.Box, run.Box)).MinBy(r => Math.Abs(r.Box.X - run.Box.X) + Math.Abs(r.Box.Y - run.Box.Y));
            if (found is { Blocked: { } why }) throw new ContentEditException(Loc.Format(PdfStrings.Edit_TextCantBeEdited, why));
            if (found?.Info is null || now.Any(r => r.Id == found.Id) || found.Info.Columns > 1)
                throw new ContentEditException(PdfStrings.Edit_PageChangedParagraph);
            now.Add(found);
        }
        if (now.Count == 0) throw new ContentEditException(PdfStrings.Edit_PageChangedParagraph);
        var anchor = now[0];
        if (now.Any(r => !FormPlace.SameDrawing(r.Info!.Form, anchor.Info!.Form)))
            throw new ContentEditException(PdfStrings.Edit_PageChangedParagraph);
        var target = TargetOf(doc, page, streams, ops, walk, anchor);
        var center = new PointD(paragraph.Box.CenterX, paragraph.Box.CenterY);
        var turn = PageTurnInUser(page, center, degrees);

        var edits = new List<(int Start, int End, string Text)>();
        foreach (var run in now)
        {
            var info = run.Info!;
            var op = target.OpOf(run);
            var inv = info.Ctm.Invert() ?? throw new ContentEditException(PdfStrings.Edit_TextSquashed);
            // Drawn at Tm × CTM; turned, at Tm × CTM × turn: the text matrix that gives that under the same CTM.
            var tm = info.Tm.Times(info.Ctm).Times(turn).Times(inv);
            var sb = new StringBuilder(NextLine(op, run));
            sb.Append(tm.Write()).Append(" Tm ").Append(ShowOnly(op, target.Bytes)).Append(' ').Append(BackAfter(run));
            edits.Add((op.Start, op.End, sb.ToString()));
        }
        if (paragraph.Pictures.Count > 0)
        {
            if (target.Form is not null) throw new ContentEditException(PdfStrings.Edit_PageChangedParagraph);
            foreach (var pic in paragraph.Pictures)
            {
                var found = walk.Content.Images.FirstOrDefault(im => im.Id == pic.Image.Id && Near(im.Box, pic.Image.Box));
                if (found is null || found.Blocked is not null || !walk.ImageCtm.TryGetValue(found.Id, out var ctm) || found.Id < 0 || found.Id >= ops.Count)
                    throw new ContentEditException(PdfStrings.Edit_PageChangedParagraph);
                edits.Add(Placing(ops, ops[found.Id], TurnMatrix(page, ctm, center, degrees), streams.Bytes));
            }
        }
        WriteTarget(doc, page, target, edits);
        return PdfObj.Save(doc);
    }

    /// <summary>A show operator's drawing alone, as Tj or TJ (' and " leave their line step and spacing to <see cref="NextLine"/>).</summary>
    private static string ShowOnly(COp op, byte[] content)
    {
        if (op.Name is "Tj" or "TJ") return Encoding.Latin1.GetString(content, op.Start, op.End - op.Start);
        var text = op.Operands[^1];
        return Encoding.Latin1.GetString(content, text.Start, text.End - text.Start) + (text.Kind == CKind.Array ? " TJ" : " Tj");
    }

    /// <summary>A turn of <paramref name="degrees"/> clockwise about a page point, in the page's user space.</summary>
    private static Mat PageTurnInUser(PdfPage page, PointD center, double degrees)
    {
        var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
        // Page space is y-down: this turns clockwise as the page shows.
        var d = new Mat(cos, sin, -sin, cos, center.X - center.X * cos + center.Y * sin, center.Y - center.X * sin - center.Y * cos);
        var p2u = PageToUser(page);
        var u2p = p2u.Invert() ?? throw new ContentEditException(PdfStrings.Edit_PageSizeUnreadable);
        return u2p.Times(d).Times(p2u);
    }

    /// <summary>The matrix that, put before a picture drawn at <paramref name="ctm"/>, turns it about a page point.</summary>
    private static Mat TurnMatrix(PdfPage page, Mat ctm, PointD center, double degrees)
    {
        var inv = ctm.Invert() ?? throw new ContentEditException(PdfStrings.Edit_PictureSquashed);
        return ctm.Times(PageTurnInUser(page, center, degrees)).Times(inv);
    }

    /// <summary>The direction a picture's own x axis takes on the page: degrees clockwise from left-to-right.</summary>
    private static double ImageAngle(PdfPage page, Mat ctm)
    {
        var (x0, y0) = ctm.Apply(0, 0);
        var (x1, y1) = ctm.Apply(1, 0);
        var a = PdfObj.ToPage(page, x0, y0);
        var b = PdfObj.ToPage(page, x1, y1);
        return Math.Abs(b.X - a.X) < 1e-9 && Math.Abs(b.Y - a.Y) < 1e-9 ? 0 : Math.Round(Turn(Math.Atan2(b.Y - a.Y, b.X - a.X) * 180 / Math.PI), 6);
    }
}
