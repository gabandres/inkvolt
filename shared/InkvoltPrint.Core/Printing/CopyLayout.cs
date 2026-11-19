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

    /// <summary>
    /// A copied page centred on the paper, turned to the paper's orientation as it prints: at its own size (only pages
    /// larger than the paper shrink to fit), or enlarged or shrunk to fill the paper.
    /// </summary>
    public static PagePlacement Page(double pageW, double pageH, double paperW, double paperH, PageSizing sizing = PageSizing.ActualSize) =>
        PageFit.Place(pageW, pageH, paperW, paperH, sizing);

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

    /// <summary>Pages per side of paper a page copy offers: one, 2-up and 4-up.</summary>
    public static IReadOnlyList<int> PagesPerSheetChoices { get; } = [1, 2, 4];

    /// <summary>Space kept clear around the pages of a 2-up or 4-up side (¼ in at 96 per inch), and between them (⅛ in).</summary>
    public const double NUpMargin = 24, NUpGap = 12;

    /// <summary>The page indices printed on each side of paper, in reading order: pages 0–1 on the first side of a 2-up copy, and so on.</summary>
    public static IReadOnlyList<int[]> Sides(int pageCount, int pagesPerSheet)
    {
        Check(pagesPerSheet);
        var sides = new List<int[]>();
        for (var first = 0; first < pageCount; first += pagesPerSheet)
            sides.Add(Enumerable.Range(first, Math.Min(pagesPerSheet, pageCount - first)).ToArray());
        return sides;
    }

    /// <summary>
    /// The sides one print job holds, in order (−1: a blank back), and the copy count for the print ticket. Collated
    /// (or one copy): each side once, the queue making the copies (1 2 3, 1 2 3). Uncollated: each sheet repeated here,
    /// one copy on the ticket (1 1, 2 2, 3 3), so it doesn't depend on a driver honouring the ticket's collation; on
    /// two-sided paper a sheet is a side and its back, an odd last side getting a blank back so copies don't share a sheet.
    /// </summary>
    public static (IReadOnlyList<int> Sides, int TicketCopies) Order(int sideCount, int copies, bool collate, bool twoSided)
    {
        copies = Math.Max(1, copies);
        if (collate || copies == 1 || sideCount <= 0) return (Enumerable.Range(0, Math.Max(0, sideCount)).ToList(), copies);
        var order = new List<int>();
        var perSheet = twoSided ? 2 : 1;
        for (var first = 0; first < sideCount; first += perSheet)
            for (var copy = 0; copy < copies; copy++)
            {
                order.Add(first);
                if (twoSided) order.Add(first + 1 < sideCount ? first + 1 : -1);
            }
        return (order, 1);
    }

    /// <summary>Sheets of paper a page copy uses: its sides (pages per sheet), on one or both sides of the paper, times the copies.</summary>
    public static int Sheets(int pageCount, int pagesPerSheet, int copies, bool twoSided)
    {
        var sides = Sides(pageCount, pagesPerSheet).Count;
        return (twoSided ? (sides + 1) / 2 : sides) * Math.Max(1, copies);
    }

    /// <summary>
    /// Where each page of one side goes. One page per sheet: centred and sized per <paramref name="sizing"/>, as a plain copy.
    /// 2-up: two cells, one above the other on portrait paper (beside each other on landscape paper); 4-up: two by two, in
    /// reading order. Each page sits in its cell as on its own sheet (<see cref="PageFit.Place"/>: turned a quarter when the
    /// cell's orientation differs, so 2-up portrait pages read as a landscape sheet), inside a margin all round.
    /// </summary>
    public static IReadOnlyList<PagePlacement> NUp(IReadOnlyList<(double W, double H)> pages, int pagesPerSheet, double paperW, double paperH,
        PageSizing sizing = PageSizing.ActualSize)
    {
        Check(pagesPerSheet);
        if (pagesPerSheet == 1) return [.. pages.Take(1).Select(p => PageFit.Place(p.W, p.H, paperW, paperH, sizing))];
        var (cols, rows) = pagesPerSheet == 4 ? (2, 2) : paperW > paperH ? (2, 1) : (1, 2);
        var cellW = Math.Max(1, (paperW - 2 * NUpMargin - (cols - 1) * NUpGap) / cols);
        var cellH = Math.Max(1, (paperH - 2 * NUpMargin - (rows - 1) * NUpGap) / rows);
        var placed = new List<PagePlacement>();
        for (var i = 0; i < Math.Min(pages.Count, pagesPerSheet); i++)
        {
            var (x, y) = (NUpMargin + i % cols * (cellW + NUpGap), NUpMargin + i / cols * (cellH + NUpGap));
            var (at, rotated) = PageFit.Place(pages[i].W, pages[i].H, cellW, cellH, sizing);
            placed.Add(new PagePlacement(at with { X = at.X + x, Y = at.Y + y }, rotated));
        }
        return placed;
    }

    private static void Check(int pagesPerSheet)
    {
        if (!PagesPerSheetChoices.Contains(pagesPerSheet))
            throw new ArgumentOutOfRangeException(nameof(pagesPerSheet), pagesPerSheet, "1, 2 or 4 pages per sheet.");
    }
}
