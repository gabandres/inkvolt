using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Core.Sheets;

/// <summary>Print a PDF's layouts (roadmap 4.18): as before, several pages per sheet, a booklet, or a poster.</summary>
public enum PdfLayout { Normal, PagesPerSheet, Booklet, Poster }

/// <summary>How a laid-out job's two sides are printed (<see cref="SheetPrint.Route"/>).</summary>
public enum SheetRoute { OneSided, Printer, ByHand, NoBothSides }

/// <summary>What the person chose for Print a PDF's layout.</summary>
/// <param name="PagesPerSheet">2, 4, 6, 9 or 16 (<see cref="PrintSetup.PagesPerSheetChoices"/>).</param>
/// <param name="PosterPercent">The poster's size as a percentage of the page's (<see cref="SheetPrint.PosterPercents"/>).</param>
public sealed record SheetChoice(PdfLayout Layout, int PagesPerSheet = 2, int PosterPercent = 200, bool CutMarks = true);

/// <summary>
/// Inkvolt Print's use of the shared sheet layouts (<see cref="PrintLayout"/>, which Inkvolt PDF prints with too): the setup for a
/// choice, the paper's area, how many sides and sheets a job takes, which backs are drawn upside down, and how sharp a poster's
/// pages are drawn. Lengths in device-independent pixels (96 an inch), the unit the print path uses.
/// </summary>
public static class SheetPrint
{
    /// <summary>Space kept clear on every side of the paper (¼ in), outside any printer's unprintable edge.</summary>
    public const double Margin = 24;

    /// <summary>How much a poster's neighboring sheets repeat of each other (¼ in), for taping or gluing.</summary>
    public const double PosterOverlap = 24;

    /// <summary>A page drawn for printing, at this resolution; a poster's enlarged pages at more (<see cref="RenderDpi"/>).</summary>
    public const int BaseDpi = 300, MaxDpi = 600;

    public static IReadOnlyList<int> PosterPercents { get; } = [150, 200, 300, 400];

    /// <summary>Letter (or A4 where the region is metric), for counting sheets before the printer's paper is known.</summary>
    public static (double Width, double Height) GuessPaper(bool metric) => metric ? (8.27 * 96, 11.69 * 96) : (8.5 * 96, 11 * 96);

    /// <summary>The shared layout's setup for a choice; null for the normal one page per sheet (the print path as before).</summary>
    public static PrintSetup? Setup(SheetChoice choice) => choice.Layout switch
    {
        PdfLayout.PagesPerSheet => new PrintSetup
        {
            Handling = PrintHandling.PagesPerSheet,
            PagesPerSheet = PrintSetup.PagesPerSheetChoices.Contains(choice.PagesPerSheet) ? choice.PagesPerSheet : 2,
        },
        PdfLayout.Booklet => new PrintSetup { Handling = PrintHandling.Booklet },
        PdfLayout.Poster => new PrintSetup
        {
            Handling = PrintHandling.Poster,
            PosterScale = (PosterPercents.Contains(choice.PosterPercent) ? choice.PosterPercent : 200) / 100.0,
            Overlap = PosterOverlap,
            CutMarks = choice.CutMarks,
        },
        _ => null,
    };

    /// <summary>The part of a <paramref name="paperW"/> × <paramref name="paperH"/> sheet pages go on: <see cref="Margin"/> in from each edge.</summary>
    public static Placement Area(double paperW, double paperH) =>
        new(Margin, Margin, Math.Max(1, paperW - 2 * Margin), Math.Max(1, paperH - 2 * Margin));

    /// <summary>The most sides one job prints, copies included: past it Print a PDF says so instead of drawing them all.</summary>
    public const int MaxSides = 1000;

    /// <summary>A page side longer than this (200 in) is counted at it: a file's absurd page size can't make millions of poster tiles.</summary>
    public const double MaxPageSide = 200 * 96;

    /// <summary>The job's sheets on this paper: pages numbered 0… in the order given, each <paramref name="sizes"/>' size (DIPs).</summary>
    public static PrintPlan Plan(IReadOnlyList<(double W, double H)> sizes, double paperW, double paperH, PrintSetup setup) =>
        new([.. Enumerable.Range(0, sizes.Count)], i => Bounded(sizes[i]), Area(paperW, paperH), setup);

    /// <summary>
    /// A page's size as the layout takes it: a side past <see cref="MaxPageSide"/> brings the page down to it, its shape kept, so a
    /// poster's tiles and the drawing of the page agree; a size that isn't a number is a square of that side, a side under 1 is 1.
    /// The print path draws each page at this size (<c>SheetPrinting</c>).
    /// </summary>
    public static (double W, double H) Bounded((double W, double H) s)
    {
        if (!double.IsFinite(s.W) || !double.IsFinite(s.H) || s.W <= 0 || s.H <= 0) return (MaxPageSide, MaxPageSide);
        var k = Math.Min(1, MaxPageSide / Math.Max(s.W, s.H));
        return (Math.Max(1, s.W * k), Math.Max(1, s.H * k));
    }

    /// <summary>
    /// How a job's two sides get printed: one-sided; by the printer; by hand (fronts, the stack put back, backs); or not at all
    /// (<see cref="SheetRoute.NoBothSides"/>: a booklet, or both sides asked, on a printer that can't and with no by-hand offered),
    /// which Print a PDF refuses rather than sending a two-sided job the printer would print on one side.
    /// </summary>
    public static SheetRoute Route(PrintSetup setup, bool asked, bool printerTwoSided, bool byHand) =>
        !TwoSided(setup, asked) ? SheetRoute.OneSided
        : printerTwoSided ? SheetRoute.Printer
        : byHand ? SheetRoute.ByHand
        : SheetRoute.NoBothSides;

    /// <summary>
    /// The document's page number a side shows first (pages per sheet's first cell, a booklet's left page or its only one), for
    /// two-sided by hand's words ("page 7"): <paramref name="numbers"/> are the 1-based pages printed, in the job's order.
    /// </summary>
    public static int PageOnSide(PrintPlan plan, int side, IReadOnlyList<int> numbers)
    {
        if (side < 0 || side >= plan.SheetCount) return 0;
        var pages = plan.Sheet(side).Pages;
        return pages.Count == 0 ? 0 : numbers[Math.Clamp(pages.Min(p => p.Page), 0, numbers.Count - 1)];
    }

    /// <summary>The job is too big to print in one go (<see cref="MaxSides"/>, counted on the guessed paper as <see cref="Count"/> does).</summary>
    public static bool TooMany(PrintSetup setup, IReadOnlyList<(double W, double H)> sizes, (double W, double H) paper, int copies) =>
        Count(setup, sizes, paper, copies, twoSided: false).Sides > MaxSides;

    /// <summary>
    /// Whether the job prints on both sides: a booklet always (it can't be folded otherwise), a poster never (its sheets are
    /// trimmed and joined edge to edge), pages per sheet as asked.
    /// </summary>
    public static bool TwoSided(PrintSetup setup, bool asked) => setup.Handling switch
    {
        PrintHandling.Booklet => true,
        PrintHandling.Poster => false,
        _ => asked,
    };

    /// <summary>
    /// A side drawn upside down: the back of a sheet used turned (a booklet's, or 2 or 6 portrait pages side by side), printed
    /// flipping on the long edge as both a duplexer and two-sided by hand do. Turned a half, it reads the right way up once the
    /// sheet is turned over like a booklet's page (what flipping on the short edge would give, which a printer may not offer).
    /// Backs are the odd sides: every copy starts on a sheet of its own.
    /// </summary>
    public static bool HalfTurned(PrintSheet sheet, int side, bool twoSided) =>
        twoSided && side % 2 == 1 && sheet.Pages.Any(p => p.Turns == 1);

    /// <summary>
    /// The sides one job prints, in order, every copy made here (the ticket asks for one): each copy's sides 0…<paramref name="sides"/>−1,
    /// and on both sides of the paper a copy with an odd count ends on a blank back (−1) so the next starts on a sheet of its own.
    /// </summary>
    public static IReadOnlyList<int> Order(int sides, int copies, bool twoSided)
    {
        copies = Math.Clamp(copies, 1, 999);
        var order = new List<int>();
        for (var c = 0; c < copies && sides > 0; c++)
        {
            order.AddRange(Enumerable.Range(0, sides));
            if (twoSided && sides % 2 == 1 && c < copies - 1) order.Add(-1);
        }
        return order;
    }

    /// <summary>The resolution a job's pages are drawn at: a poster's enlarged pages sharper, up to <see cref="MaxDpi"/>.</summary>
    public static int RenderDpi(PrintSetup? setup) =>
        setup is { Handling: PrintHandling.Poster } ? (int)Math.Clamp(Math.Round(BaseDpi * setup.PosterScale), BaseDpi, MaxDpi) : BaseDpi;

    /// <summary>
    /// How many sides the job prints and on how many sheets of paper, for the summary (the paper guessed:
    /// <see cref="GuessPaper"/>). Copies each start on a sheet of their own.
    /// </summary>
    public static (int Sides, int Sheets) Count(PrintSetup setup, IReadOnlyList<(double W, double H)> sizes, (double W, double H) paper, int copies, bool twoSided)
    {
        if (sizes.Count == 0) return (0, 0);
        copies = Math.Max(1, copies);
        var sides = Plan(sizes, paper.W, paper.H, setup).SheetCount;
        var sheets = TwoSided(setup, twoSided) ? (sides + 1) / 2 : sides;
        return (sides * copies, sheets * copies);
    }
}
