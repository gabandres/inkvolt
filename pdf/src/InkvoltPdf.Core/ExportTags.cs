namespace InkvoltPdf.Core;

/// <summary>
/// What an export takes from a PDF's tags and catalog: its language and the alternate text of its figures. Best effort: a
/// file that can't be read here has neither, and the export goes on.
/// </summary>
internal sealed record ExportTags(string? Language, IReadOnlyList<(int Page, RectD? Box, string Alt)> Figures)
{
    public static readonly ExportTags None = new(null, []);

    public static ExportTags Read(byte[]? data, string? password)
    {
        if (data is null) return None;
        try
        {
            using var doc = PdfObj.Open(data, password, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
            var lang = PdfObj.Text(doc.Internals.Catalog.Elements["/Lang"])?.Trim();
            return new ExportTags(lang, AutoTag.FigureAlts(doc));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return None;
        }
    }

    /// <summary>
    /// The page with its figures' text on its pictures: the tag whose box covers a picture, then tags without a box (they
    /// say only which page) in drawing order when as many pictures are left.
    /// </summary>
    public ExportPage OnPictures(ExportPage page, int number)
    {
        if (page.Images.Count == 0 || Figures.Count == 0) return page;
        var here = Figures.Where(f => f.Page == number).ToList();
        if (here.Count == 0) return page;
        var images = page.Images.ToList();
        var taken = new bool[images.Count];
        foreach (var (_, box, alt) in here)
        {
            if (box is not { } b) continue;
            for (var i = 0; i < images.Count; i++)
            {
                var overlap = b.Intersect(images[i].Box);
                var smaller = Math.Min(b.Width * b.Height, images[i].Box.Width * images[i].Box.Height);
                if (taken[i] || overlap.IsEmpty || overlap.Width * overlap.Height <= 0.5 * smaller) continue;
                images[i] = images[i] with { Alt = alt };
                taken[i] = true;
                break;
            }
        }
        var boxless = here.Where(f => f.Box is null).Select(f => f.Alt).ToList();
        var left = Enumerable.Range(0, images.Count).Where(i => !taken[i]).ToList();
        if (boxless.Count > 0 && boxless.Count == left.Count)
            for (var k = 0; k < left.Count; k++) images[left[k]] = images[left[k]] with { Alt = boxless[k] };
        return page with { Images = images };
    }
}
