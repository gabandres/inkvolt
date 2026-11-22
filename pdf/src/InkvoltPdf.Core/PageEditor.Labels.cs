namespace InkvoltPdf.Core;

public static partial class PageEditor
{
    /// <summary>
    /// One edit of the page labels (<see cref="PageLabels"/>): <paramref name="change"/> gets each page's label (plain
    /// numbers when there are none) and the page count, and returns the labels to write, or null for none. Labels that
    /// are plain numbers from 1 on every page are written as none.
    /// </summary>
    internal static byte[] EditLabels(byte[] data, string? password, Func<List<PdfStructure.PageLabel>, int, List<PdfStructure.PageLabel>?> change)
    {
        return Edit(data, password, doc =>
        {
            var labels = PdfStructure.ReadLabels(doc)?.Select(l => l.Label).ToList()
                         ?? [.. Enumerable.Range(0, doc.PageCount).Select(i => new PdfStructure.PageLabel("D", "", i + 1))];
            var changed = change(labels, doc.PageCount);
            var plain = changed is null || changed.Select((l, i) => l == new PdfStructure.PageLabel("D", "", i + 1)).All(x => x);
            if (plain) doc.Internals.Catalog.Elements.Remove("/PageLabels");
            else PdfStructure.WriteRanges(doc, changed!);
        });
    }
}
