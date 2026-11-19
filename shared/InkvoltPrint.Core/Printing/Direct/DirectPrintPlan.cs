using InkvoltPrint.Core.Printing.Raster;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>What a print asks for. Null paper, color, quality or type: the printer's default.</summary>
public sealed record DirectPrintRequest(int Copies = 1, bool TwoSided = false)
{
    /// <summary>A paper by its PWG name (<see cref="DirectPaper.Name"/>), else by <see cref="PaperInches"/>, else the printer's default.</summary>
    public string? PaperName { get; init; }

    /// <summary>A paper by size (portrait or landscape), matched within 2 mm.</summary>
    public (double Width, double Height)? PaperInches { get; init; }

    public bool Borderless { get; init; }

    /// <summary>True color, false black and grey, null the printer's default.</summary>
    public bool? Color { get; init; }

    /// <summary>3 draft, 4 normal, 5 high; null the printer's default.</summary>
    public int? Quality { get; init; }

    /// <summary>A <c>media-type</c> keyword.</summary>
    public string? MediaType { get; init; }

    /// <summary>Only this raster format (the developer check sends each one to a test printer); null: the first the printer takes.</summary>
    public RasterFormat? Format { get; init; }
}

/// <summary>
/// How one job goes to a printer with no driver: the raster format (PWG raster first, then Apple raster, then PCLm, the first
/// the printer both lists and says how to make), its resolution (300 dpi when offered; else the nearest above, drawn at 300
/// and enlarged when it is a multiple), color, the paper with its margins, two-sided and how the back is turned, and copies
/// (the printer's when it makes enough and collates them, else the pages are sent again). <see cref="Choose"/> never changes what was asked
/// quietly: a setting the printer can't keep is a problem, and nothing is sent.
/// </summary>
public sealed record DirectPrintPlan(RasterFormat Format, int Dpi, RasterColor Color, DirectPaper Paper)
{
    public const int PreferredDpi = 300;

    /// <summary>The resolution the pages are drawn at; <see cref="Enlarge"/> makes it <see cref="Dpi"/>.</summary>
    public int RenderDpi => Dpi % PreferredDpi == 0 && Dpi / PreferredDpi is >= 1 and <= 8 ? PreferredDpi : Dpi;

    public int Enlarge => Dpi / RenderDpi;

    public bool TwoSided { get; init; }
    public BackSide Back { get; init; }

    /// <summary>The <c>copies</c> attribute sent (1: not sent).</summary>
    public int Copies { get; init; } = 1;

    /// <summary>How many times the pages go in the document: copies the printer doesn't make itself.</summary>
    public int Repeat { get; init; } = 1;

    /// <summary>The <c>print-color-mode</c> keyword sent, or null.</summary>
    public string? ColorMode { get; init; }

    /// <summary>Sent as RGB but drawn grey: the person asked for grey and the format takes only color.</summary>
    public bool Grey { get; init; }

    public int? Quality { get; init; }
    public string? MediaType { get; init; }
    public int StripHeight { get; init; } = 16;
    public bool RunLength { get; init; }

    public string DocumentFormat => Format switch
    {
        RasterFormat.PwgRaster => IppPrintCaps.PwgRasterType,
        RasterFormat.Urf => IppPrintCaps.UrfType,
        _ => IppPrintCaps.PclmType,
    };

    /// <summary>The raster job for <paramref name="pages"/> pages (one copy's worth, times <see cref="Repeat"/>).</summary>
    public RasterJob Job(int pages) => new(Format, Dpi, Color, Paper.Name, Paper.WidthHmm, Paper.HeightHmm, pages * Repeat)
    {
        Duplex = TwoSided,
        Back = Back,
        Quality = Quality ?? 0,
        MediaType = MediaType,
        StripHeight = StripHeight,
        RunLength = RunLength,
    };

    /// <summary>
    /// Pages in the document for <paramref name="pages"/> pages of one copy: a two-sided copy with an odd count gets a blank
    /// back, so the next copy starts on a new sheet.
    /// </summary>
    public int PagesPerCopy(int pages) => TwoSided && Repeat > 1 && pages % 2 == 1 ? pages + 1 : pages;

    /// <summary>The plan, or the reason in plain words why this printer can't print the request without a driver.</summary>
    public static DirectPrintPlan? Choose(IppPrintCaps caps, DirectPrintRequest request, out string? problem)
    {
        problem = null;
        if (!caps.CanPrint)
        {
            problem = CoreStrings.Direct_NoFormat;
            return null;
        }
        if (request.TwoSided && !caps.TwoSided)
        {
            problem = CoreStrings.Direct_NotTwoSided;
            return null;
        }
        if (request.Copies is < 1 or > 999)
        {
            problem = CoreStrings.Direct_Copies;
            return null;
        }
        var paper = ChoosePaper(caps, request);
        if (paper is null)
        {
            problem = CoreStrings.Direct_NoPaper;
            return null;
        }
        if (request.Quality is { } quality && !caps.Qualities.Contains(quality))
        {
            problem = CoreStrings.Direct_NoQuality;
            return null;
        }
        if (request.MediaType is { } type && !caps.MediaTypes.Contains(type))
        {
            problem = CoreStrings.Direct_NoMediaType;
            return null;
        }
        var wantColor = request.Color ?? caps.ColorByDefault;
        foreach (var format in caps.Formats.Where(f => request.Format is null || f == request.Format))
        {
            var (colors, dpis, back) = format switch
            {
                RasterFormat.PwgRaster => (caps.PwgColors, caps.PwgDpis, caps.PwgBack),
                RasterFormat.Urf => (caps.UrfColors, caps.UrfDpis, caps.UrfBack),
                _ => ((IReadOnlyList<RasterColor>)[RasterColor.Gray8, RasterColor.Rgb8], caps.PclmDpis, caps.PclmBack),
            };
            var color = wantColor && caps.Color && colors.Contains(RasterColor.Rgb8) ? RasterColor.Rgb8
                : colors.Contains(RasterColor.Gray8) ? RasterColor.Gray8 : colors.Contains(RasterColor.Rgb8) ? RasterColor.Rgb8 : (RasterColor?)null;
            if (color is null || ChooseDpi(dpis) is not { } dpi) continue;
            // Grey asked for (or a printer that prints only black) on a format that takes only RGB: the pages are made grey here.
            var grey = color == RasterColor.Rgb8 && !(wantColor && caps.Color);
            // The printer makes the copies only when it collates them; else the pages go again, a copy at a time.
            var printerCopies = request.Copies <= caps.MaxCopies && (request.Copies == 1 || caps.CollatedCopies);
            return new DirectPrintPlan(format, dpi, color.Value, paper)
            {
                TwoSided = request.TwoSided,
                Back = back,
                Copies = printerCopies ? request.Copies : 1,
                Repeat = printerCopies ? 1 : request.Copies,
                Grey = grey,
                ColorMode = caps.Color ? (color == RasterColor.Rgb8 && !grey ? "color" : "monochrome") : null,
                Quality = request.Quality,
                MediaType = request.MediaType,
                StripHeight = caps.PclmStripHeight,
                RunLength = caps.PclmRunLength,
            };
        }
        problem = CoreStrings.Direct_NoFormat;
        return null;
    }

    /// <summary>300 when offered, else the lowest above it, else the highest below it.</summary>
    internal static int? ChooseDpi(IReadOnlyList<int> offered) =>
        offered.Count == 0 ? null : offered.Contains(PreferredDpi) ? PreferredDpi
        : offered.Where(d => d > PreferredDpi).DefaultIfEmpty(offered.Max()).Min();

    private static DirectPaper? ChoosePaper(IppPrintCaps caps, DirectPrintRequest request)
    {
        IEnumerable<DirectPaper> candidates;
        if (request.PaperName is { } name) candidates = caps.Papers.Where(p => p.Name == name);
        else if (request.PaperInches is { } inches)
        {
            var (w, h) = ((int)Math.Round(Math.Min(inches.Width, inches.Height) * 2540), (int)Math.Round(Math.Max(inches.Width, inches.Height) * 2540));
            candidates = caps.Papers.Where(p => Math.Abs(p.WidthHmm - w) <= 200 && Math.Abs(p.HeightHmm - h) <= 200);
        }
        else if (caps.DefaultPaper is { } d)
            candidates = caps.Papers.Where(p => IppPrintCaps.Same(p, d)).Prepend(d);
        else
            candidates = caps.Papers.Where(p => p.Name is "na_letter_8.5x11in" or "iso_a4_210x297mm").Concat(caps.Papers);
        var list = candidates.ToList();
        var defaultSource = caps.DefaultPaper?.Source;
        return request.Borderless
            ? list.FirstOrDefault(p => p.Borderless)
            : list.Where(p => !p.Borderless).OrderBy(p => p.Source == defaultSource ? 0 : 1).FirstOrDefault() ?? list.FirstOrDefault();
    }
}
