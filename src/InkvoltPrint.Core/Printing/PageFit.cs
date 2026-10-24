namespace InkvoltPrint.Core.Printing;

/// <summary>How a PDF page is sized on the paper.</summary>
public enum PageSizing
{
    /// <summary>Print at the page's own size; only pages larger than the paper shrink to fit.</summary>
    ActualSize,

    /// <summary>Shrink or enlarge every page to fill the paper.</summary>
    FitToPaper,
}

public static class PageFit
{
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
