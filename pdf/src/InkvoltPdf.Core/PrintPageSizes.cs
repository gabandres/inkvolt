using InkvoltPrint.Core.Sheets;
using Placement = InkvoltPrint.Core.Printing.Placement;

namespace InkvoltPdf.Core;

/// <summary>
/// A PDF page's size as Print's layout takes it, in DIPs, bounded as Inkvolt Print bounds it (<see cref="SheetPrint.Bounded"/>):
/// a side past 200 in brings the page down to it, its shape kept, so a file's absurd MediaBox can't make millions of poster
/// tiles or sheets. The part of a page a placed piece shows is in that bounded size; <see cref="Shown"/> takes it back to
/// the page's own points to render.
/// </summary>
public static class PrintPageSizes
{
    /// <summary>The page's size for the layout (DIPs, bounded).</summary>
    public static (double W, double H) Of(PageGeometry page) => SheetPrint.Bounded((page.Width * 96 / 72, page.Height * 96 / 72));

    /// <summary>Each page's size for the layout (DIPs, bounded), by 0-based index.</summary>
    public static Func<int, (double W, double H)> Of(PdfEngine engine) => p => Of(engine.GetPage(p));

    /// <summary>The part of <paramref name="page"/> a placed piece shows (<paramref name="source"/>, in the layout's DIPs; null the whole page), in the page's points.</summary>
    public static RectD Shown(PageGeometry page, Placement? source)
    {
        if (source is not { } s) return new RectD(0, 0, page.Width, page.Height);
        var (w, h) = Of(page);
        var kx = double.IsFinite(page.Width) && page.Width > 0 ? page.Width / w : 0.75;
        var ky = double.IsFinite(page.Height) && page.Height > 0 ? page.Height / h : 0.75;
        return new RectD(s.X * kx, s.Y * ky, s.Width * kx, s.Height * ky);
    }
}
