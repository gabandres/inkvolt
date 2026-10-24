using InkvoltPrint.Core.Escl;

namespace InkvoltPrint.Core.Printing;

/// <summary>Where an image goes on the paper, in the paper's units (left, top, width, height).</summary>
public readonly record struct Placement(double X, double Y, double Width, double Height);

/// <summary>
/// Copying (scan, then print what was scanned): page placement at actual size, and the ID card copy layout, front on
/// the top half and back on the bottom half of one sheet. Units are whatever the caller uses for both page and paper.
/// </summary>
public static class CopyLayout
{
    /// <summary>
    /// One side of an ID card is scanned from the glass's top-left corner (the scanner's reference corner): 4.5 × 3 in,
    /// in eSCL's 1/300 in. An ID-1 card is 3.37 × 2.13 in, so there's room for a card placed a little off the corner.
    /// </summary>
    public const int IdCardScanWidth = 1350, IdCardScanHeight = 900;

    /// <summary>Space kept clear around each half, so a side never runs into the printer's unprintable edge (¼ in at 96 per inch).</summary>
    public const double IdCardMargin = 24;

    /// <summary>A scanned page's size in inches, from its pixel size and the resolution it was scanned at.</summary>
    public static (double Width, double Height) Inches(int widthPx, int heightPx, int dpi) =>
        dpi <= 0 ? (0, 0) : (widthPx / (double)dpi, heightPx / (double)dpi);

    /// <summary>The ID card scan region on this scanner's glass: the corner area, clamped to what the glass allows.</summary>
    public static ScanRequest IdCardRequest(ScanColor color, int dpi) =>
        new(ScanSource.Platen, color, dpi, Width: IdCardScanWidth, Height: IdCardScanHeight);

    /// <summary>A copied page centred on the paper at its own size; only pages larger than the paper shrink to fit.</summary>
    public static Placement Page(double pageW, double pageH, double paperW, double paperH)
    {
        var scale = PageFit.Scale(pageW, pageH, paperW, paperH, PageSizing.ActualSize);
        var (w, h) = (pageW * scale, pageH * scale);
        return new Placement((paperW - w) / 2, (paperH - h) / 2, w, h);
    }

    /// <summary>
    /// ID card copy: <paramref name="front"/> centred in the top half, <paramref name="back"/> in the bottom half, both at
    /// actual size. A side larger than its half (minus <paramref name="margin"/> all round) shrinks to fit; both sides
    /// then use the same scale, so the copy's two halves always match.
    /// </summary>
    public static (Placement Front, Placement Back) IdCard(double paperW, double paperH, (double W, double H) front, (double W, double H) back,
        double margin = IdCardMargin)
    {
        var halfH = paperH / 2;
        var boxW = Math.Max(1, paperW - 2 * margin);
        var boxH = Math.Max(1, halfH - 2 * margin);
        var scale = Math.Min(
            PageFit.Scale(front.W, front.H, boxW, boxH, PageSizing.ActualSize),
            PageFit.Scale(back.W, back.H, boxW, boxH, PageSizing.ActualSize));
        Placement In(double top, (double W, double H) side)
        {
            var (w, h) = (side.W * scale, side.H * scale);
            return new Placement((paperW - w) / 2, top + (halfH - h) / 2, w, h);
        }
        return (In(0, front), In(halfH, back));
    }
}
