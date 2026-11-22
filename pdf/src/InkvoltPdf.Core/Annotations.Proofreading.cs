using System.Text;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>What a proofreading mark asks for: text put in at a caret, or the struck-out text replaced.</summary>
public enum ProofMarkKind { InsertText, ReplaceText }

/// <summary>
/// Proofreading marks as Acrobat makes them (roadmap 4.17). Insert Text is a /Caret annotation at the insertion point,
/// the text to insert as its contents. Replace Text is a /Caret after the struck-out words, the new text as its
/// contents, and a /StrikeOut over them bound to it as one group (/IRT the caret, /RT /Group): viewers list the pair as
/// one comment, and deleting or moving the caret takes the strike-out along (<see cref="ThreadOf"/>). Both are blue,
/// with their own appearance, so every viewer draws them alike.
/// </summary>
public static partial class Annotations
{
    /// <summary>The blue Acrobat gives its text edits.</summary>
    public static readonly AnnotColor ProofBlue = new(0, 0, 1);

    /// <summary>The caret's subject (Acrobat's words, which other viewers read).</summary>
    internal const string InsertedTextSubject = "Inserted Text", CrossOutSubject = "Cross-Out";

    /// <summary>The longest text a proofreading mark carries (what a paste or a tampered call can give).</summary>
    public const int MaxProofText = 20_000;

    /// <summary>
    /// The insertion point before character <paramref name="caret"/> of the page's text (after the last one at its end), as a
    /// zero-width box as tall as its line (page space); null where the text has no box there.
    /// </summary>
    public static RectD? CaretAt(PageText text, int caret)
    {
        caret = Math.Clamp(caret, 0, text.Text.Length);
        if (caret < text.Text.Length && text.Text[caret] != '\n' && text.GetRects(caret, caret + 1) is [var r, ..])
            return new RectD(r.X, r.Y, 0, r.Height);
        if (caret > 0 && text.GetRects(caret - 1, caret) is [var l, ..])
            return new RectD(l.Right, l.Y, 0, l.Height);
        return null;
    }

    /// <summary>
    /// Adds an Insert Text mark: a caret at <paramref name="at"/> (page space: its left edge is the insertion point, its
    /// height the line's, as <see cref="CaretAt"/> gives), <paramref name="text"/> the words to insert.
    /// </summary>
    /// <exception cref="ArgumentException">No text, or too much.</exception>
    public static byte[] AddInsertText(byte[] data, string? password, int pageIndex, RectD at, string text, string author, string? id = null)
    {
        text = CheckProofText(text);
        using var doc = OpenForEdit(data, password);
        AddCaretIn(doc, pageIndex, at, text, author, id);
        return PdfObj.Save(doc);
    }

    /// <summary>
    /// Adds a Replace Text mark: the words on <paramref name="lineRects"/> (page space, one box per line, as
    /// <see cref="PageText.GetRects"/> gives) struck out, and a caret after the last one carrying <paramref name="text"/>,
    /// the two grouped. <paramref name="id"/> names the caret (the comment the Comments pane lists).
    /// </summary>
    /// <exception cref="ArgumentException">No words to strike out, no text, or too much.</exception>
    public static byte[] AddReplaceText(byte[] data, string? password, int pageIndex, IReadOnlyList<RectD> lineRects, string text, string author, string? id = null)
    {
        text = CheckProofText(text);
        var lines = lineRects.Where(r => !r.IsEmpty).ToList();
        if (lines.Count == 0) throw new ArgumentException(PdfStrings.Annot_NoTextToMark, nameof(lineRects));
        using var doc = OpenForEdit(data, password);
        var last = lines[^1];
        var caret = AddCaretIn(doc, pageIndex, new RectD(last.Right, last.Y, 0, last.Height), text, author, id);
        var strikeId = NewId();
        AddTextMarkupIn(doc, pageIndex, TextMarkupKind.StrikeOut, lines, ProofBlue, null, author, strikeId);
        var (_, strike) = Find(doc, strikeId)!.Value;
        strike.Elements["/IRT"] = caret.Reference!;
        strike.Elements["/RT"] = new PdfName("/Group");
        strike.Elements["/Subj"] = PdfObj.MakeString(CrossOutSubject);
        return PdfObj.Save(doc);
    }

    /// <summary>
    /// What a caret is: Replace Text when a strike-out is grouped with it (its id in <paramref name="replaced"/>, from
    /// <see cref="ReplacedCarets"/>), else Insert Text; null for any other comment.
    /// </summary>
    public static ProofMarkKind? ProofKindOf(AnnotationInfo a, IReadOnlySet<string> replaced) =>
        a.Kind != AnnotationKind.Caret ? null : replaced.Contains(a.Id) ? ProofMarkKind.ReplaceText : ProofMarkKind.InsertText;

    /// <summary>The ids of the carets a strike-out is grouped with: Replace Text marks (for <see cref="ProofKindOf"/>), in one pass.</summary>
    public static HashSet<string> ReplacedCarets(IEnumerable<AnnotationInfo> all) =>
        [.. all.Where(o => o.Grouped && o.Kind == AnnotationKind.StrikeOut && o.ReplyTo is not null).Select(o => o.ReplyTo!)];

    /// <summary>
    /// True for a comment that is part of another's group (/RT /Group) whose head is among <paramref name="ids"/>: the
    /// lists show the head only, as one comment.
    /// </summary>
    public static bool IsGroupMember(AnnotationInfo a, IReadOnlySet<string> ids) =>
        a.Grouped && a.ReplyTo is { } head && head != a.Id && ids.Contains(head);

    /// <summary>The comment <paramref name="a"/> is part of: its group's head when it is a member (/RT /Group), else itself.
    /// A chain of groups is climbed a few steps at most; one that loops stops.</summary>
    public static AnnotationInfo GroupHead(AnnotationInfo a, IEnumerable<AnnotationInfo> all)
    {
        var byId = new Dictionary<string, AnnotationInfo>(StringComparer.Ordinal);
        foreach (var x in all) byId.TryAdd(x.Id, x);
        var head = a;
        for (var hops = 0; hops < MaxGroupHops && head.Grouped && head.ReplyTo is { } to && byId.TryGetValue(to, out var up) && up.Id != head.Id; hops++)
            head = up;
        return head;
    }

    /// <summary>The most steps from a group's member to its head (a hostile file can chain or loop them).</summary>
    internal const int MaxGroupHops = 16;

    /// <summary><see cref="GroupHead"/> on the document itself: what a delete or a move takes as one comment.</summary>
    internal static PdfDictionary GroupHeadIn(PdfDictionary annot)
    {
        var head = annot;
        for (var hops = 0; hops < MaxGroupHops && PdfObj.Name(head.Elements["/RT"]) == "Group" && PdfObj.Dict(head.Elements["/IRT"]) is { } up
                           && !ReferenceEquals(up, head) && !ReferenceEquals(up, annot); hops++)
            head = up;
        return head;
    }

    private static string CheckProofText(string text)
    {
        text = text.Replace("\r\n", "\n").Trim();
        if (text.Length == 0) throw new ArgumentException(PdfStrings.Annot_NoProofText, nameof(text));
        if (text.Length > MaxProofText) throw new ArgumentException(Loc.Format(PdfStrings.Annot_ProofTextTooLong, MaxProofText), nameof(text));
        return text;
    }

    /// <summary>A caret at <paramref name="at"/>'s left edge, under the line, pointing up into it.</summary>
    private static PdfDictionary AddCaretIn(PdfDocument doc, int pageIndex, RectD at, string text, string author, string? id)
    {
        if (pageIndex < 0 || pageIndex >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(pageIndex));
        if (!double.IsFinite(at.X) || !double.IsFinite(at.Y) || !double.IsFinite(at.Height) || at.Height <= 0)
            throw new ArgumentException(PdfStrings.Annot_NoTextToMark, nameof(at));
        var page = doc.Pages[pageIndex];
        var (x1, y1, x2, y2, form) = CaretAppearance(doc, page, at, ProofBlue);
        var annot = NewAnnot(doc, page, "Caret", x1, y1, x2, y2, id, text, author, ProofBlue);
        annot.Elements["/Subj"] = PdfObj.MakeString(InsertedTextSubject);
        annot.Elements["/Sy"] = new PdfName("/None");
        annot.Elements["/RD"] = PdfObj.Reals(doc, 0, 0, 0, 0);
        SetAppearance(doc, annot, form);
        return annot;
    }

    /// <summary>
    /// The caret's shape (a filled chevron, its tip at the baseline) in PDF space, upright as the page is shown, with the
    /// rectangle it covers.
    /// </summary>
    private static (double X1, double Y1, double X2, double Y2, PdfDictionary Form) CaretAppearance(PdfDocument doc, PdfPage page, RectD at, AnnotColor color)
    {
        var h = Math.Clamp(at.Height, 4, 72);
        double w = h * 0.55, x = at.X, tipY = at.Bottom - h * 0.3, baseY = at.Bottom + h * 0.2, notch = at.Bottom + h * 0.08;
        (double X, double Y)[] shape =
        [
            PdfObj.ToPdf(page, x, tipY), PdfObj.ToPdf(page, x + w / 2, baseY), PdfObj.ToPdf(page, x, notch), PdfObj.ToPdf(page, x - w / 2, baseY),
        ];
        double x1 = shape.Min(p => p.X) - 1, y1 = shape.Min(p => p.Y) - 1, x2 = shape.Max(p => p.X) + 1, y2 = shape.Max(p => p.Y) + 1;
        var ops = new StringBuilder($"{PdfObj.F(color.R)} {PdfObj.F(color.G)} {PdfObj.F(color.B)} rg ");
        for (var i = 0; i < shape.Length; i++) ops.Append($"{PdfObj.F(shape[i].X)} {PdfObj.F(shape[i].Y)} {(i == 0 ? "m" : "l")} ");
        ops.Append("h f\n");
        return (x1, y1, x2, y2, PdfObj.FormXObject(doc, Encoding.Latin1.GetBytes(ops.ToString()), x1, y1, x2, y2, new PdfDictionary(doc)));
    }

    /// <summary>An imported caret's appearance from its rectangle (XFDF carries none): the chevron filling its lower part.</summary>
    private static void CaretFromRect(PdfDocument doc, PdfPage page, PdfDictionary annot, AnnotColor color)
    {
        if (PdfObj.Array(annot.Elements["/Rect"]) is not { Elements.Count: 4 } r) return;
        var box = PdfObj.RectToPage(page, r);
        if (box.IsEmpty || !double.IsFinite(box.Width) || !double.IsFinite(box.Height)) return;
        // The rectangle Acrobat gives a caret is the chevron's own: its tip a third of the way down, its base at the bottom.
        var h = box.Height / 0.5;
        var at = new RectD(box.CenterX, box.Bottom - 0.2 * h - h, 0, h);
        var (_, _, _, _, form) = CaretAppearance(doc, page, at, color);
        SetAppearance(doc, annot, form);
    }
}
