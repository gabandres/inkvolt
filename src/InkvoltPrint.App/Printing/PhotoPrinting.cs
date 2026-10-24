using System.Globalization;
using System.Printing;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Core.Photos;

namespace InkvoltPrint.App.Printing;

/// <summary>A photo as it will print: the picture, the user's quarter turns (negative: left), copies and crop.</summary>
public sealed record PhotoJobPhoto(PhotoSource Source, int UserTurns, int Copies, PhotoCrop Crop)
{
    /// <summary>Quarter turns clockwise from the stored pixels: EXIF orientation, then the user's.</summary>
    public int Turns => ExifOrientation.Turns(Source.Orientation, UserTurns);

    public bool Mirror => ExifOrientation.Transform(Source.Orientation).Mirror;

    /// <summary>For <see cref="PhotoLayout"/>: the size as it looks (turns applied).</summary>
    public PhotoInput Input
    {
        get
        {
            var (w, h) = ExifOrientation.Oriented(Source.PixelWidth, Source.PixelHeight, Source.Orientation, UserTurns);
            return new PhotoInput(w, h, Copies, Crop);
        }
    }
}

/// <summary>A paper size the queue offers. <see cref="Media"/> goes into the print ticket (null in demo mode).</summary>
public sealed record PaperChoice(string Key, string Label, double WidthIn, double HeightIn, PageMediaSize? Media)
{
    public override string ToString() => Label;
}

/// <summary>What the printer's Windows queue offers for photos: paper sizes, paper types, quality and color, with its defaults.</summary>
public sealed record PhotoQueueOptions(
    IReadOnlyList<PaperChoice> Papers, string? DefaultPaper,
    IReadOnlyList<Option<string>> MediaTypes, string? DefaultMediaType,
    IReadOnlyList<Option<string>> Qualities, string? DefaultQuality,
    IReadOnlyList<Option<string>> Colors, string? DefaultColor);

/// <summary>For one paper size: whether the queue prints borderless on it, and its printable area (margins, inches).</summary>
public sealed record PaperSetup(bool CanBorderless, SheetPaper Paper);

/// <summary>The choices for one photo job (Print Schema names; null: the queue's default).</summary>
public sealed record PhotoJobSettings(PaperChoice? Paper, string? MediaType, string? Quality, string? Color, bool Borderless);

/// <summary>
/// Photo printing through the printer's Windows queue (the same XPS path as PDFs and copies, <see cref="QueuePrinter"/>):
/// the options its driver exposes (PrintCapabilities), a ticket with paper size, paper type, borderless, quality and color,
/// and sheets drawn by <see cref="PhotoDrawing"/>, the same drawing as the preview.
/// </summary>
public static class PhotoPrinting
{
    /// <summary>Pictures are sent at up to this resolution: more detail only makes the job bigger.</summary>
    public const int PrintDpi = 300;

    /// <summary>The queue's photo options. Asks the driver, which can take seconds: call off the UI thread.</summary>
    public static PhotoQueueOptions ReadOptions(string queueName)
    {
        using var server = new LocalPrintServer();
        using var queue = new PrintQueue(server, queueName);
        var caps = queue.GetPrintCapabilities();
        var ticket = queue.DefaultPrintTicket;
        var papers = caps.PageMediaSizeCapability
            .Where(m => m.Width is > 0 && m.Height is > 0)
            .Select(Paper)
            .DistinctBy(p => p.Label)
            .ToList();
        var defaultPaper = ticket.PageMediaSize is { Width: > 0, Height: > 0 } d ? papers.FirstOrDefault(p => p.Label == Paper(d).Label)?.Key : null;
        return new PhotoQueueOptions(
            papers, defaultPaper,
            Names(caps.PageMediaTypeCapability, PageMediaType.Unknown, PhotoPaperText.MediaType), Name(ticket.PageMediaType, PageMediaType.Unknown),
            Names(caps.OutputQualityCapability, OutputQuality.Unknown, PhotoPaperText.Quality), Name(ticket.OutputQuality, OutputQuality.Unknown),
            Names(caps.OutputColorCapability, OutputColor.Unknown, PhotoPaperText.Color), Name(ticket.OutputColor, OutputColor.Unknown));
    }

    private static PaperChoice Paper(PageMediaSize m)
    {
        var (w, h) = (m.Width!.Value / 96, m.Height!.Value / 96);
        var name = m.PageMediaSizeName?.ToString();
        return new PaperChoice(name is null or "Unknown" ? string.Create(CultureInfo.InvariantCulture, $"{w:0.###}x{h:0.###}") : name,
            PhotoPaperText.Paper(name, w, h), w, h, m);
    }

    private static List<Option<string>> Names<T>(IEnumerable<T> values, T unknown, Func<string, string> label) where T : struct, Enum =>
        values.Where(v => !v.Equals(unknown)).Distinct().Select(v => new Option<string>(v.ToString(), label(v.ToString()))).ToList();

    private static string? Name<T>(T? value, T unknown) where T : struct, Enum => value is { } v && !v.Equals(unknown) ? v.ToString() : null;

    /// <summary>Borderless support and printable area for the chosen paper. Asks the driver: call off the UI thread.</summary>
    public static PaperSetup ReadPaper(string queueName, PhotoJobSettings settings)
    {
        using var server = new LocalPrintServer();
        using var queue = new PrintQueue(server, queueName);
        var ticket = Ticket(queue, settings with { Borderless = false });
        var caps = queue.GetPrintCapabilities(ticket);
        var borderless = caps.PageBorderlessCapability.Contains(PageBorderless.Borderless);
        return new PaperSetup(borderless, SheetOf(ticket, caps.PageImageableArea, borderless: false));
    }

    /// <summary>The paper in inches with the margins the driver reports (none for borderless; ¼ in when it reports none).</summary>
    private static SheetPaper SheetOf(PrintTicket ticket, PageImageableArea? area, bool borderless)
    {
        var w = (ticket.PageMediaSize?.Width ?? 816) / 96;
        var h = (ticket.PageMediaSize?.Height ?? 1056) / 96;
        if (borderless) return new SheetPaper(w, h, 0, 0, 0, 0);
        if (area is null || area.ExtentWidth <= 0 || area.ExtentHeight <= 0) return new SheetPaper(w, h, 0.25, 0.25, 0.25, 0.25);
        var (left, top) = (area.OriginWidth / 96, area.OriginHeight / 96);
        return new SheetPaper(w, h, left, top, Math.Max(0, w - left - area.ExtentWidth / 96), Math.Max(0, h - top - area.ExtentHeight / 96));
    }

    private static PrintTicket Ticket(PrintQueue queue, PhotoJobSettings settings)
    {
        var ticket = queue.DefaultPrintTicket.Clone();
        ticket.CopyCount = 1; // copies are laid out on the sheets
        ticket.Duplexing = Duplexing.OneSided;
        ticket.PageOrientation = PageOrientation.Portrait;
        if (settings.Paper?.Media is { } media) ticket.PageMediaSize = media;
        if (Enum.TryParse<PageMediaType>(settings.MediaType, out var type)) ticket.PageMediaType = type;
        if (Enum.TryParse<OutputQuality>(settings.Quality, out var quality)) ticket.OutputQuality = quality;
        if (Enum.TryParse<OutputColor>(settings.Color, out var color)) ticket.OutputColor = color;
        ticket.PageBorderless = settings.Borderless ? PageBorderless.Borderless : PageBorderless.None;
        return queue.MergeAndValidatePrintTicket(queue.DefaultPrintTicket, ticket).ValidatedPrintTicket;
    }

    /// <summary>
    /// Lays the photos out on the paper the validated ticket names (its printable area as the driver reports it) and spools
    /// them as one job. Returns the number of sheets.
    /// </summary>
    public static async Task<int> PrintAsync(string queueName, PhotoJobSettings settings, IReadOnlyList<PhotoJobPhoto> photos,
        PhotoLayoutOptions layout, string jobName)
    {
        var sheets = 0;
        await QueuePrinter.SpoolAsync(queueName, jobName, queue => Ticket(queue, settings), (queue, ticket, paperDips) =>
        {
            var borderless = ticket.PageBorderless == PageBorderless.Borderless;
            var paper = SheetOf(ticket, borderless ? null : queue.GetPrintCapabilities(ticket).PageImageableArea, borderless);
            var laidOut = PhotoLayout.Sheets(photos.Select(p => p.Input).ToList(), layout, paper);
            sheets = laidOut.Count;
            return new PhotoPaginator(laidOut, photos, paperDips);
        });
        return sheets;
    }

    /// <summary>The job's pages. Each sheet's pictures are decoded when the serializer asks for it, at no more than <see cref="PrintDpi"/>.</summary>
    internal sealed class PhotoPaginator(IReadOnlyList<PhotoSheet> sheets, IReadOnlyList<PhotoJobPhoto> photos, Size paper) : DocumentPaginator
    {
        private Dictionary<(int Photo, int Width), BitmapSource?> _last = [];

        public override bool IsPageCountValid => true;
        public override int PageCount => sheets.Count;
        public override Size PageSize { get => paper; set { } }
        public override IDocumentPaginatorSource? Source => null;

        public override DocumentPage GetPage(int pageNumber)
        {
            var sheet = sheets[pageNumber];
            // Repeated photos (copies, one photo per sheet) reuse the previous page's decode.
            var widths = new Dictionary<int, int>();
            foreach (var cell in sheet.Cells)
            {
                var photo = photos[cell.Photo];
                var turns = photo.Turns + (cell.Turned ? 1 : 0);
                var inches = turns % 2 == 1 ? cell.Image.Height : cell.Image.Width;
                var width = PhotoLayout.DecodeWidth(photo.Source.PixelWidth, inches, PrintDpi);
                widths[cell.Photo] = Math.Max(widths.GetValueOrDefault(cell.Photo), width);
            }
            var bitmaps = new Dictionary<(int, int), BitmapSource?>();
            foreach (var (photo, width) in widths)
                bitmaps[(photo, width)] = _last.TryGetValue((photo, width), out var known) ? known : Load(photos[photo].Source, width);
            _last = bitmaps;

            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.DrawRectangle(Brushes.White, null, new Rect(paper));
                PhotoDrawing.DrawSheet(dc, sheet, photos, i => bitmaps.GetValueOrDefault((i, widths[i])), 96, 1);
            }
            return new DocumentPage(visual, paper, new Rect(paper), new Rect(paper));
        }

        private static BitmapSource? Load(PhotoSource source, int width)
        {
            try { return PhotoFiles.ForPrint(source, width); }
            catch (Exception ex)
            {
                // The file went away or changed since it was added: that print stays blank rather than failing the whole job.
                Log.Write($"Photo print: {source.Name}: {ex.Message}");
                return null;
            }
        }
    }
}

/// <summary>Draws a laid-out sheet: each picture turned (EXIF, user, cell) and clipped to its cell, and contact-sheet names.</summary>
public static class PhotoDrawing
{
    private static readonly Brush CaptionBrush = Frozen(new SolidColorBrush(Color.FromRgb(0x44, 0x48, 0x4E)));
    private static readonly Brush MissingBrush = Frozen(new SolidColorBrush(Color.FromRgb(0xE6, 0xE8, 0xEB)));
    private static readonly Typeface CaptionFace = new("Segoe UI");

    private static Brush Frozen(Brush b)
    {
        b.Freeze();
        return b;
    }

    /// <param name="unit">Drawing units per inch (96 for DIPs).</param>
    /// <param name="pixelsPerDip">For the captions' text (1 when printing).</param>
    public static void DrawSheet(DrawingContext dc, PhotoSheet sheet, IReadOnlyList<PhotoJobPhoto> photos, Func<int, BitmapSource?> bitmap,
        double unit, double pixelsPerDip)
    {
        foreach (var cell in sheet.Cells)
        {
            var photo = photos[cell.Photo];
            var clip = Scale(cell.Cell, unit);
            dc.PushClip(new RectangleGeometry(clip));
            if (bitmap(cell.Photo) is { } image) DrawPhoto(dc, image, Scale(cell.Image, unit), photo.Turns + (cell.Turned ? 1 : 0), photo.Mirror);
            else dc.DrawRectangle(MissingBrush, null, Scale(cell.Image, unit));
            dc.Pop();
            if (cell.Caption is { } caption) DrawCaption(dc, photo.Source.Name, Scale(caption, unit), pixelsPerDip);
        }
    }

    /// <summary>
    /// <paramref name="image"/> (stored pixels) mirrored when EXIF says so, turned <paramref name="turns"/> quarter turns
    /// clockwise and stretched so its turned shape fills <paramref name="box"/>.
    /// </summary>
    public static void DrawPhoto(DrawingContext dc, ImageSource image, Rect box, int turns, bool mirror)
    {
        turns = (turns % 4 + 4) % 4;
        var (w, h) = turns % 2 == 1 ? (box.Height, box.Width) : (box.Width, box.Height);
        dc.PushTransform(new TranslateTransform(box.X + box.Width / 2, box.Y + box.Height / 2));
        dc.PushTransform(new RotateTransform(turns * 90));
        dc.PushTransform(new ScaleTransform(mirror ? -1 : 1, 1));
        dc.DrawImage(image, new Rect(-w / 2, -h / 2, w, h));
        dc.Pop();
        dc.Pop();
        dc.Pop();
    }

    private static void DrawCaption(DrawingContext dc, string text, Rect area, double pixelsPerDip)
    {
        if (area.Width < 4 || area.Height < 2) return;
        var size = Math.Max(1, area.Height * 0.55);
        var formatted = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, CaptionFace, size, CaptionBrush, pixelsPerDip)
        {
            MaxTextWidth = area.Width,
            MaxLineCount = 1,
            Trimming = TextTrimming.CharacterEllipsis,
            TextAlignment = TextAlignment.Center,
        };
        dc.DrawText(formatted, new Point(area.X, area.Y + (area.Height - formatted.Height) / 2));
    }

    public static Rect Scale(InkvoltPrint.Core.Printing.Placement p, double unit) => new(p.X * unit, p.Y * unit, p.Width * unit, p.Height * unit);
}
