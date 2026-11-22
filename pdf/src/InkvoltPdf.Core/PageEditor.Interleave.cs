using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// Interleave: two scans of a stack of two-sided sheets, the fronts and then the backs, put together as front 1, back 1,
/// front 2, back 2… The backs of a stack turned over to be fed again come last page first: <c>reverseBacks</c> puts them
/// back in order. Uneven counts are fine (a back left blank, a missed sheet): what one side has left over follows.
/// </summary>
public static partial class PageEditor
{
    /// <summary>
    /// The page order after interleaving <paramref name="fronts"/> and <paramref name="backs"/> (pages of one document,
    /// each in its order): the interleaved pages take the place of the first of them, the other pages stay as they are.
    /// </summary>
    /// <exception cref="ArgumentException">A side is empty, a page is out of range, or a page is on both sides.</exception>
    public static int[] InterleaveOrder(int pageCount, IReadOnlyList<int> fronts, IReadOnlyList<int> backs, bool reverseBacks)
    {
        if (fronts.Count == 0 || backs.Count == 0) throw new ArgumentException(PdfStrings.Page_InterleaveEmpty, nameof(fronts));
        if (fronts.Concat(backs).Any(p => p < 0 || p >= pageCount)) throw new ArgumentException(PdfStrings.Page_NoneSelected, nameof(fronts));
        var used = fronts.Concat(backs).ToHashSet();
        if (used.Count != fronts.Count + backs.Count) throw new ArgumentException(PdfStrings.Page_InterleaveOverlap, nameof(backs));

        var back = reverseBacks ? backs.Reverse().ToArray() : [.. backs];
        var merged = new List<int>(used.Count);
        for (var i = 0; i < Math.Max(fronts.Count, back.Length); i++)
        {
            if (i < fronts.Count) merged.Add(fronts[i]);
            if (i < back.Length) merged.Add(back[i]);
        }
        var at = used.Min();
        var rest = Enumerable.Range(0, pageCount).Where(p => !used.Contains(p)).ToList();
        rest.InsertRange(rest.Count(p => p < at), merged);
        return [.. rest];
    }

    /// <summary>Interleaves two sets of this document's pages (<see cref="InterleaveOrder"/>), as one edit.</summary>
    public static byte[] Interleave(byte[] data, string? password, IReadOnlyList<int> fronts, IReadOnlyList<int> backs, bool reverseBacks)
    {
        return Edit(data, password, (doc, labels) =>
        {
            ApplyOrder(doc, InterleaveOrder(doc.PageCount, fronts, backs, reverseBacks));
            Relabel(doc, labels, fronts.Concat(backs).Min(), fronts.Count + backs.Count);
        });
    }

    /// <summary>
    /// Page labels after an interleave: the interleaved run (<paramref name="count"/> pages from <paramref name="at"/>)
    /// numbered on from the label its first place had, so no label shows twice; labels that were plain 1, 2, 3 are
    /// dropped (the pages show their numbers anyway). Other pages keep theirs.
    /// </summary>
    private static void Relabel(PdfDocument doc, List<(PdfPage Page, PdfStructure.PageLabel Label)>? labels, int at, int count)
    {
        if (labels is null) return;
        if (labels.Select((l, i) => l.Label == new PdfStructure.PageLabel("D", "", i + 1)).All(plain => plain))
        {
            labels.Clear();
            return;
        }
        var first = labels[Math.Clamp(at, 0, labels.Count - 1)].Label;
        var index = new Dictionary<PdfPage, int>(ReferenceEqualityComparer.Instance);
        for (var i = 0; i < labels.Count; i++) index.TryAdd(labels[i].Page, i);
        for (var k = 0; k < count && at + k < doc.PageCount; k++)
        {
            var label = first with { Number = (int)Math.Min(int.MaxValue, (long)first.Number + k) };
            var page = doc.Pages[at + k];
            if (index.TryGetValue(page, out var i)) labels[i] = (page, label);
            else labels.Add((page, label)); // a back brought in from another file
        }
    }

    /// <summary>
    /// The document's pages are the fronts; the pages of <paramref name="backs"/> (another file, or the backs just
    /// scanned) are brought in with their links, bookmarks and fields, as Insert brings them, and interleaved with them.
    /// </summary>
    public static byte[] InterleaveWith(byte[] data, string? password, PdfSource backs, bool reverseBacks)
    {
        return Edit(data, password, (doc, labels) =>
        {
            using var src = OpenImport(backs.Data, backs.Password);
            if (src.PageCount == 0) throw new ArgumentException(PdfStrings.Page_InterleaveEmpty, nameof(backs));
            var fronts = doc.PageCount;
            var imported = new List<(int, PdfPage)>();
            for (var k = 0; k < src.PageCount; k++) imported.Add((k, doc.Pages.Insert(fronts + k, src.Pages[k])));

            var import = new PdfStructure.Import(doc, src, imported);
            import.FixLinks();
            var outline = PdfStructure.ReadOutline(doc);
            outline.AddRange(import.Outline());
            PdfStructure.WriteOutline(doc, outline);
            import.RegisterFields();
            PdfStructure.DropStrayReferences(doc);
            ApplyOrder(doc, InterleaveOrder(doc.PageCount, [.. Enumerable.Range(0, fronts)], [.. Enumerable.Range(fronts, src.PageCount)], reverseBacks));
            Relabel(doc, labels, 0, doc.PageCount);
        });
    }
}
