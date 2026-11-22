using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;

namespace InkvoltPdf.Core;

/// <summary>
/// Replace Pages: pages of this document swapped, one for one, for pages of another PDF (a corrected page, a signed
/// page scanned back). Bookmarks, links, named destinations and the opening view that led to a replaced page lead to the
/// page that took its place; the replaced page's own comments, links and fields go with it, and the new page brings
/// its own, as Insert brings them. Each new page keeps the replaced page's label.
/// </summary>
public static partial class PageEditor
{
    /// <param name="pages">The pages replaced (this document), in the order <paramref name="sourcePages"/> replace them.</param>
    /// <param name="sourcePages">The pages of <paramref name="source"/> that take their places, as many as <paramref name="pages"/>.</param>
    /// <exception cref="ArgumentException">The counts differ, a page is out of range or named twice.</exception>
    public static byte[] Replace(byte[] data, string? password, IReadOnlyList<int> pages, PdfSource source, IReadOnlyList<int> sourcePages)
    {
        if (pages.Count == 0 || pages.Count != sourcePages.Count) throw new ArgumentException(PdfStrings.Page_ReplaceCount, nameof(sourcePages));
        if (pages.Distinct().Count() != pages.Count) throw new ArgumentException(PdfStrings.Page_ReplaceCount, nameof(pages));
        return Edit(data, password, (doc, labels) =>
        {
            using var src = OpenImport(source.Data, source.Password);
            if (pages.Any(p => p < 0 || p >= doc.PageCount) || sourcePages.Any(p => p < 0 || p >= src.PageCount))
                throw new ArgumentException(PdfStrings.Page_NoneSelected, nameof(pages));

            var old = pages.Select(p => doc.Pages[p]).ToArray();
            var imported = new List<(int, PdfPage)>();
            var map = new Dictionary<PdfObjectID, PdfPage>();
            // Each new page goes right after the page it replaces, the last first, so the indices before it hold.
            foreach (var k in Enumerable.Range(0, pages.Count).OrderByDescending(k => pages[k]))
            {
                var added = doc.Pages.Insert(pages[k] + 1, src.Pages[sourcePages[k]]);
                imported.Add((sourcePages[k], added));
                map[old[k].ReferenceNotNull.ObjectID] = added;
                if (labels is not null) labels.Add((added, labels[pages[k]].Label)); // the label it replaces
            }

            var import = new PdfStructure.Import(doc, src, imported);
            import.FixLinks();
            import.RegisterFields();
            RetargetDestinations(doc, map);
            var at = old.Select(page => Enumerable.Range(0, doc.PageCount).First(i => ReferenceEquals(doc.Pages[i], page))).ToList();
            PdfStructure.RemovePages(doc, at);
            SignedEdits.NoteRemoval();
        });
    }

    /// <summary>
    /// Points every explicit destination ([page /XYZ …], [page /Fit] …) that leads to a page in <paramref name="map"/>
    /// at the page it maps to: in bookmarks, links, actions, named destinations, the opening view, wherever the document
    /// holds one. Each object is looked at once.
    /// </summary>
    internal static void RetargetDestinations(PdfDocument doc, IReadOnlyDictionary<PdfObjectID, PdfPage> map)
    {
        var seen = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
        var todo = new Stack<PdfObject>();
        void Push(PdfItem? item)
        {
            if (PdfObj.Resolve(item) is PdfObject o and (PdfArray or PdfDictionary) && seen.Add(o)) todo.Push(o);
        }
        Push(doc.Internals.Catalog);
        for (var i = 0; i < doc.PageCount; i++) Push(doc.Pages[i]);
        while (todo.TryPop(out var next))
        {
            if (next is PdfArray a)
            {
                if (a.Elements.Count >= 2 && a.Elements[0] is PdfReference first && map.TryGetValue(first.ObjectID, out var to)
                    && PdfObj.Resolve(a.Elements[1]) is PdfName)
                    a.Elements[0] = to.ReferenceNotNull;
                foreach (var e in a.Elements) Push(e);
            }
            else if (next is PdfDictionary d)
            {
                foreach (var key in d.Elements.Keys)
                    if (key != "/Parent") Push(d.Elements[key]);
            }
        }
    }
}
