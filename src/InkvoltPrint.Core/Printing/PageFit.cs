namespace InkvoltPrint.Core.Printing;

/// <summary>How a PDF page is sized on the paper.</summary>
public enum PageSizing
{
    /// <summary>Print at the page's own size; only pages larger than the paper shrink to fit.</summary>
    ActualSize,

    /// <summary>Shrink or enlarge every page to fill the paper.</summary>
    FitToPaper,
}

/// <summary>Where a page goes on the paper (its box after turning) and whether it's turned a quarter clockwise to get there.</summary>
public readonly record struct PagePlacement(Placement At, bool Rotated);

public static class PageFit
{
    /// <summary>
    /// A page on the paper the way it prints: a landscape page on portrait paper (or the reverse) is turned a quarter
    /// rather than shrunk, then sized per <paramref name="sizing"/> and centred. Printing and the copy preview both use it.
    /// </summary>
    public static PagePlacement Place(double pageW, double pageH, double paperW, double paperH, PageSizing sizing)
    {
        var rotated = pageW > pageH != paperW > paperH;
        var (w, h) = rotated ? (pageH, pageW) : (pageW, pageH);
        var scale = Scale(w, h, paperW, paperH, sizing);
        (w, h) = (w * scale, h * scale);
        return new PagePlacement(new Placement((paperW - w) / 2, (paperH - h) / 2, w, h), rotated);
    }

    /// <summary>
    /// The factor that sizes a page (already turned to the paper's orientation) on the paper, keeping its proportions.
    /// Any units, as long as page and paper use the same ones.
    /// </summary>
    public static double Scale(double pageW, double pageH, double paperW, double paperH, PageSizing sizing)
    {
        if (pageW <= 0 || pageH <= 0) return 1;
        var fit = Math.Min(paperW / pageW, paperH / pageH);
        if (sizing == PageSizing.ActualSize || (fit > 1 && fit < 1.03)) return Math.Min(1, fit); // same paper size: actual size
        return fit;
    }
}
