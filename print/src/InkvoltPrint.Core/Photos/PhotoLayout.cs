using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Core.Photos;

/// <summary>A standard print size, short side first, in inches.</summary>
public sealed record PhotoSize(string Name, double Width, double Height);

public static class PhotoSizes
{
    public static readonly PhotoSize In4x6 = new("4 × 6 in", 4, 6);
    public static readonly PhotoSize In5x7 = new("5 × 7 in", 5, 7);
    public static readonly PhotoSize In8x10 = new("8 × 10 in", 8, 10);
    public static readonly PhotoSize Cm10x15 = new("10 × 15 cm", 100 / 25.4, 150 / 25.4);
    public static readonly PhotoSize Cm13x18 = new("13 × 18 cm", 130 / 25.4, 180 / 25.4);
    public static readonly PhotoSize Wallet = new("Wallet (2.5 × 3.5 in)", 2.5, 3.5);

    public static IReadOnlyList<PhotoSize> All { get; } = [In4x6, In5x7, In8x10, Cm10x15, Cm13x18, Wallet];
}

public enum PhotoLayoutKind
{
    /// <summary>One photo per sheet, as large as the printable area.</summary>
    FullPage,

    /// <summary>Prints at a standard photo size (<see cref="PhotoLayoutOptions.Size"/>), as many per sheet as fit.</summary>
    PrintSize,

    /// <summary>An index: <see cref="PhotoLayoutOptions.PerSheet"/> small whole photos per sheet, each with its file name.</summary>
    ContactSheet,
}

public enum PhotoFit
{
    /// <summary>Covers the whole cell; what doesn't fit is cropped (the crop can be moved and zoomed).</summary>
    Fill,

    /// <summary>Shows the whole photo; white bands where its shape differs from the cell's.</summary>
    Fit,
}

public sealed record PhotoLayoutOptions
{
    public PhotoLayoutKind Kind { get; init; } = PhotoLayoutKind.FullPage;
    public PhotoSize Size { get; init; } = PhotoSizes.In4x6;

    /// <summary>Contact sheet: photos per sheet.</summary>
    public int PerSheet { get; init; } = 12;

    public PhotoFit Fit { get; init; } = PhotoFit.Fill;

    /// <summary>Print sizes: every cell of a sheet holds the same photo (wallets of one portrait); copies count sheets.</summary>
    public bool OnePhotoPerSheet { get; init; }
}

/// <summary>A sheet of paper in inches, with the margins the printer can't print in (all zero: borderless).</summary>
public readonly record struct SheetPaper(double Width, double Height, double Left, double Top, double Right, double Bottom)
{
    public Placement Printable => new(Left, Top, Math.Max(0, Width - Left - Right), Math.Max(0, Height - Top - Bottom));
}

/// <summary>
/// How a photo sits in its cell. <see cref="Zoom"/> ≥ 1 enlarges it beyond fill or fit; <see cref="PanX"/> and <see cref="PanY"/>
/// (−1 … 1) move the visible part to an edge of the photo, in the photo's own frame, so a turned photo keeps its crop.
/// </summary>
public readonly record struct PhotoCrop(double Zoom, double PanX, double PanY)
{
    public const double MaxZoom = 4;
    public static readonly PhotoCrop None = new(1, 0, 0);
    public bool IsNone => Zoom <= 1 && PanX == 0 && PanY == 0;
}

/// <summary>A photo to lay out: its size as it should look (EXIF and the user's turns applied), in pixels.</summary>
public sealed record PhotoInput(double Width, double Height, int Copies, PhotoCrop Crop);

/// <summary>
/// One print on a sheet: <see cref="Cell"/> is its place on the paper; <see cref="Image"/> the box the whole photo is drawn in
/// (larger than the cell when cropped: draw it clipped to the cell); <see cref="Turned"/>: a quarter turn clockwise to suit
/// the cell; <see cref="Caption"/> where the file name goes (contact sheets). Inches, from the paper's top-left corner.
/// </summary>
public sealed record PhotoCell(int Photo, Placement Cell, Placement Image, bool Turned, Placement? Caption = null);

public sealed record PhotoSheet(IReadOnlyList<PhotoCell> Cells);

/// <summary>The cells of one sheet; <see cref="Shrunk"/>: the print size didn't fit in the printable area, so one smaller print.</summary>
public sealed record SheetGrid(IReadOnlyList<Placement> Cells, bool Shrunk);

/// <summary>
/// Photo printing layouts: cells per sheet, fit and fill, turning each photo to its cell's orientation, crop and pan, and the
/// resolution a photo prints at. Pure arithmetic in inches; the app draws the result (preview and print alike).
/// </summary>
public static class PhotoLayout
{
    /// <summary>Space left between prints for cutting them apart, when the sheet has room for it.</summary>
    public const double CutGap = 0.125;

    /// <summary>Below this a print may look soft.</summary>
    public const double LowDpi = 150;

    private const double Epsilon = 1e-9;

    /// <summary>Every sheet to print, in order. Photos without copies are left out; a contact sheet shows each photo once.</summary>
    public static IReadOnlyList<PhotoSheet> Sheets(IReadOnlyList<PhotoInput> photos, PhotoLayoutOptions options, SheetPaper paper)
    {
        if (photos.Count == 0) return [];
        if (options.Kind == PhotoLayoutKind.ContactSheet) return ContactSheets(photos, options, paper);

        var landscape = photos.Count(p => p.Width > p.Height);
        var grid = Grid(options, paper, preferLandscape: landscape > photos.Count - landscape);
        var cells = grid.Cells;
        if (cells.Count == 0) return [];

        // Which photo goes in each print, in order.
        var sheets = new List<PhotoSheet>();
        if (options.Kind == PhotoLayoutKind.PrintSize && options.OnePhotoPerSheet)
        {
            for (var i = 0; i < photos.Count; i++)
                for (var c = 0; c < photos[i].Copies; c++)
                    sheets.Add(new PhotoSheet(cells.Select(cell => Cell(i, photos[i], cell, options.Fit)).ToList()));
            return sheets;
        }
        var prints = new List<int>();
        for (var i = 0; i < photos.Count; i++) prints.AddRange(Enumerable.Repeat(i, Math.Max(0, photos[i].Copies)));
        for (var start = 0; start < prints.Count; start += cells.Count)
            sheets.Add(new PhotoSheet(prints.Skip(start).Take(cells.Count)
                .Select((photo, k) => Cell(photo, photos[photo], cells[k], options.Fit)).ToList()));
        return sheets;
    }

    private static PhotoCell Cell(int index, PhotoInput photo, Placement cell, PhotoFit fit)
    {
        var turned = ShouldTurn(photo.Width, photo.Height, cell.Width, cell.Height);
        return new PhotoCell(index, cell, Place(cell, photo.Width, photo.Height, fit, photo.Crop, turned), turned);
    }

    /// <summary>A landscape photo in a portrait cell (or the reverse) is turned rather than cropped or shrunk; squares never are.</summary>
    public static bool ShouldTurn(double photoW, double photoH, double cellW, double cellH) =>
        photoW != photoH && cellW != cellH && photoW > photoH != cellW > cellH;

    /// <summary>
    /// The cells of one sheet. Full page: the printable area. Print size: as many prints as fit at their real size, in the
    /// orientation that fits more (a tie goes to <paramref name="preferLandscape"/>), centred, with a <see cref="CutGap"/>
    /// between them where there's room; a size larger than the printable area shrinks to it (one per sheet).
    /// </summary>
    public static SheetGrid Grid(PhotoLayoutOptions options, SheetPaper paper, bool preferLandscape)
    {
        var area = paper.Printable;
        if (area.Width <= 0 || area.Height <= 0) return new SheetGrid([], false);
        switch (options.Kind)
        {
            case PhotoLayoutKind.FullPage:
                return new SheetGrid([area], false);
            case PhotoLayoutKind.ContactSheet:
                {
                    var (cols, rows) = ContactGrid(options.PerSheet, area.Width, area.Height);
                    var (w, h) = (area.Width / cols, area.Height / rows);
                    var cells = new List<Placement>(cols * rows);
                    for (var r = 0; r < rows; r++)
                        for (var c = 0; c < cols; c++)
                            cells.Add(new Placement(area.X + c * w, area.Y + r * h, w, h));
                    return new SheetGrid(cells, false);
                }
        }

        var (sw, sh) = (options.Size.Width, options.Size.Height);
        var portrait = Count(sw, sh, area);
        var landscape = Count(sh, sw, area);
        var useLandscape = landscape.Cols * landscape.Rows > portrait.Cols * portrait.Rows
                           || (landscape.Cols * landscape.Rows == portrait.Cols * portrait.Rows && preferLandscape);
        var (cw, ch) = useLandscape ? (sh, sw) : (sw, sh);
        var (nc, nr) = useLandscape ? landscape : portrait;
        if (nc * nr == 0)
        {
            // Doesn't fit at its size: one print, shrunk into the printable area, turned to suit it.
            if (cw > ch != area.Width > area.Height) (cw, ch) = (ch, cw);
            var scale = Math.Min(area.Width / cw, area.Height / ch);
            (cw, ch) = (cw * scale, ch * scale);
            return new SheetGrid([new Placement(area.X + (area.Width - cw) / 2, area.Y + (area.Height - ch) / 2, cw, ch)], true);
        }
        var gapX = nc > 1 ? Math.Min(CutGap, (area.Width - nc * cw) / (nc - 1)) : 0;
        var gapY = nr > 1 ? Math.Min(CutGap, (area.Height - nr * ch) / (nr - 1)) : 0;
        var x0 = area.X + (area.Width - (nc * cw + (nc - 1) * gapX)) / 2;
        var y0 = area.Y + (area.Height - (nr * ch + (nr - 1) * gapY)) / 2;
        var list = new List<Placement>(nc * nr);
        for (var r = 0; r < nr; r++)
            for (var c = 0; c < nc; c++)
                list.Add(new Placement(x0 + c * (cw + gapX), y0 + r * (ch + gapY), cw, ch));
        return new SheetGrid(list, false);
    }

    private static (int Cols, int Rows) Count(double w, double h, Placement area) =>
        ((int)Math.Floor(area.Width / w + Epsilon), (int)Math.Floor(area.Height / h + Epsilon));

    /// <summary>
    /// Columns × rows for <paramref name="perSheet"/> photos on a printable area: the split whose cells come closest to a
    /// photo-and-caption shape (a little wider than tall), so 12 is 3 × 4 on portrait paper and 4 × 3 on landscape.
    /// </summary>
    public static (int Columns, int Rows) ContactGrid(int perSheet, double width, double height)
    {
        perSheet = Math.Clamp(perSheet, 1, 100);
        const double target = 1.2;
        var best = (1, perSheet);
        var bestScore = double.MaxValue;
        for (var cols = 1; cols <= perSheet; cols++)
        {
            if (perSheet % cols != 0) continue;
            var rows = perSheet / cols;
            var score = Math.Abs(Math.Log(width / cols / (height / rows) / target));
            if (score < bestScore - Epsilon) (best, bestScore) = ((cols, rows), score);
        }
        return best;
    }

    /// <summary>Contact sheets: each photo once, whole, as large as its cell allows above a line for its file name.</summary>
    private static IReadOnlyList<PhotoSheet> ContactSheets(IReadOnlyList<PhotoInput> photos, PhotoLayoutOptions options, SheetPaper paper)
    {
        var cells = Grid(options, paper, false).Cells;
        if (cells.Count == 0) return [];
        var sheets = new List<PhotoSheet>();
        for (var start = 0; start < photos.Count; start += cells.Count)
        {
            var list = new List<PhotoCell>();
            for (var k = 0; k < cells.Count && start + k < photos.Count; k++)
            {
                var cell = cells[k];
                var pad = Math.Min(0.06, cell.Width * 0.05);
                var caption = Math.Min(0.22, cell.Height * 0.2);
                var picture = new Placement(cell.X + pad, cell.Y + pad, Math.Max(0, cell.Width - 2 * pad), Math.Max(0, cell.Height - 2 * pad - caption));
                var photo = photos[start + k];
                list.Add(new PhotoCell(start + k, cell, Place(picture, photo.Width, photo.Height, PhotoFit.Fit, PhotoCrop.None, turned: false), false,
                    new Placement(picture.X, picture.Y + picture.Height, picture.Width, caption)));
            }
            sheets.Add(new PhotoSheet(list));
        }
        return sheets;
    }

    /// <summary>
    /// The box a <paramref name="photoW"/> × <paramref name="photoH"/> photo (any units; only its shape counts) is drawn in
    /// for <paramref name="cell"/>: filled or fitted, zoomed, and moved by the crop's pan within what overflows the cell.
    /// <paramref name="turned"/>: the photo is drawn a quarter turn clockwise, so the box is its turned shape.
    /// </summary>
    public static Placement Place(Placement cell, double photoW, double photoH, PhotoFit fit, PhotoCrop crop, bool turned)
    {
        if (photoW <= 0 || photoH <= 0 || cell.Width <= 0 || cell.Height <= 0) return cell;
        var (w, h) = turned ? (photoH, photoW) : (photoW, photoH);
        var scale = fit == PhotoFit.Fill ? Math.Max(cell.Width / w, cell.Height / h) : Math.Min(cell.Width / w, cell.Height / h);
        scale *= Math.Clamp(crop.Zoom, 1, PhotoCrop.MaxZoom);
        (w, h) = (w * scale, h * scale);
        var (panX, panY) = CellPan(crop, turned);
        var overX = Math.Max(0, w - cell.Width);
        var overY = Math.Max(0, h - cell.Height);
        return new Placement(cell.X + (cell.Width - w) / 2 - panX * overX / 2, cell.Y + (cell.Height - h) / 2 - panY * overY / 2, w, h);
    }

    /// <summary>
    /// The crop after dragging the photo by (<paramref name="dx"/>, <paramref name="dy"/>) on the paper (same units as the
    /// cell): the photo follows the pointer until its edge meets the cell's edge.
    /// </summary>
    public static PhotoCrop Drag(Placement cell, double photoW, double photoH, PhotoFit fit, PhotoCrop crop, bool turned, double dx, double dy)
    {
        var image = Place(cell, photoW, photoH, fit, crop, turned);
        var overX = image.Width - cell.Width;
        var overY = image.Height - cell.Height;
        var (panX, panY) = CellPan(crop, turned);
        if (overX > Epsilon) panX = Math.Clamp(panX - 2 * dx / overX, -1, 1);
        if (overY > Epsilon) panY = Math.Clamp(panY - 2 * dy / overY, -1, 1);
        // Back to the photo's own frame (see CellPan).
        return turned ? crop with { PanX = panY, PanY = -panX } : crop with { PanX = panX, PanY = panY };
    }

    /// <summary>
    /// The pan along the cell's axes. A quarter turn clockwise puts the photo's top on the cell's right and its right on the
    /// cell's bottom: the cell's x pan is the photo's −y pan, its y pan the photo's x pan.
    /// </summary>
    private static (double X, double Y) CellPan(PhotoCrop crop, bool turned)
    {
        var (x, y) = (Math.Clamp(crop.PanX, -1, 1), Math.Clamp(crop.PanY, -1, 1));
        return turned ? (-y, x) : (x, y);
    }

    /// <summary>The resolution a photo of <paramref name="pixelW"/> × <paramref name="pixelH"/> prints at in <paramref name="image"/> (inches).</summary>
    public static double Dpi(double pixelW, double pixelH, Placement image, bool turned)
    {
        var (w, h) = turned ? (image.Height, image.Width) : (image.Width, image.Height);
        return w <= 0 || h <= 0 ? 0 : Math.Min(pixelW / w, pixelH / h);
    }

    /// <summary>
    /// The width to decode a <paramref name="pixels"/>-wide photo at for a print <paramref name="inches"/> wide: no more than
    /// <paramref name="maxDpi"/>, since more detail only makes the print job bigger.
    /// </summary>
    public static int DecodeWidth(int pixels, double inches, int maxDpi) =>
        inches <= 0 ? pixels : Math.Min(pixels, (int)Math.Ceiling(inches * maxDpi));
}
