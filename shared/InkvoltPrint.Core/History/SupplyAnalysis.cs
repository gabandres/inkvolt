using System.Globalization;

namespace InkvoltPrint.Core.History;

public enum ForecastState
{
    /// <summary>The supply never reported a level.</summary>
    NoLevel,

    /// <summary>Too few days of this cartridge in the last 30 (a new cartridge, a new printer, no reading for a month).</summary>
    NotEnoughData,

    /// <summary>The level isn't falling: nothing to divide by.</summary>
    Steady,

    Estimate,
    Empty,
}

/// <summary>How long a supply should last, or why that can't be said yet.</summary>
/// <param name="DaysLeft">The estimate in days; null also for <see cref="ForecastState.Estimate"/> beyond <see cref="SupplyAnalysis.LongestEstimate"/>.</param>
/// <param name="MoreDays">For <see cref="ForecastState.NotEnoughData"/>: days of readings still needed.</param>
public sealed record SupplyForecast(ForecastState State, int? DaysLeft = null, int MoreDays = 0)
{
    public string? Text => State switch
    {
        ForecastState.NotEnoughData => $"Not enough history for days left yet (about {MoreDays} more {Days(MoreDays)})",
        ForecastState.Steady => "Level steady, so no estimate of days left",
        ForecastState.Estimate => DaysLeft switch
        {
            null => "More than two years left",
            0 => "Could run out any day",
            { } n => $"About {n.ToString("N0", CultureInfo.CurrentCulture)} {Days(n)} left",
        },
        _ => null,
    };

    private static string Days(int n) => n == 1 ? "day" : "days";
}

/// <summary>One cartridge as the history saw it.</summary>
/// <param name="From">The first row counted as this cartridge.</param>
/// <param name="To">Its last row.</param>
/// <param name="Pages">
/// Pages printed on it: the page count from its first row to the next cartridge's first row, or for the one in the printer to the
/// latest row. Null when the printer gives no count, or the count went backwards (a replaced formatter board).
/// </param>
/// <param name="SeenGoingIn">The change to it was seen; false for the cartridge already in when the history started.</param>
public sealed record CartridgeStint(DateOnly From, DateOnly To, int FirstPercent, int LastPercent, int? Pages, bool SeenGoingIn);

/// <summary>What one supply's rows say.</summary>
public sealed record SupplySummary(string Supply, string? Color, IReadOnlyList<CartridgeStint> Cartridges, SupplyForecast Forecast)
{
    /// <summary>The days a cartridge change was seen.</summary>
    public IReadOnlyList<DateOnly> ChangeDates => Cartridges.Where(c => c.SeenGoingIn).Select(c => c.From).ToList();

    public int? PagesOnCurrent => Cartridges.Count > 0 ? Cartridges[^1].Pages : null;

    /// <summary>The supplies card's line ("About 34 days left · 1,240 pages since this cartridge went in"); null when there's nothing to say.</summary>
    public string? Line
    {
        get
        {
            var pages = PagesOnCurrent is { } n
                ? $"{n.ToString("N0", CultureInfo.CurrentCulture)} {(n == 1 ? "page" : "pages")} since {(Cartridges[^1].SeenGoingIn ? "this cartridge went in" : "Inkvolt Print started keeping track")}"
                : null;
            return string.Join(" · ", new[] { Forecast.Text, pages }.OfType<string>()) is { Length: > 0 } line ? line : null;
        }
    }
}

/// <summary>
/// Works out cartridges, pages per cartridge and days left from a supply's rows. The method, in full:
/// <list type="bullet">
/// <item><b>A change of cartridge</b> is a level at least <see cref="ChangeJump"/> points above the last known one (a wobble of a few
/// points around a threshold isn't one, and an unknown level in between doesn't count as anything). To the day: one row a day.</item>
/// <item><b>Days left</b> is a straight line (least squares, by calendar day, so days with no rows don't bend it) through this
/// cartridge's known levels in the last <see cref="WindowDays"/> days. It needs <see cref="MinReadings"/> readings spanning
/// <see cref="MinSpanDays"/> days, else "not enough history". A slope under <see cref="SteadyPerDay"/> points a day is "steady". The
/// estimate is the latest level over that slope, less the days since that reading; past <see cref="LongestEstimate"/> days it
/// says "more than two years" rather than a number nobody should plan on.</item>
/// <item><b>Pages</b> come from the printer's lifetime count, so on a color printer a color cartridge's figure counts every page
/// printed while it was in, not only pages that used it.</item>
/// </list>
/// </summary>
public static class SupplyAnalysis
{
    public const int ChangeJump = 20, WindowDays = 30, MinReadings = 3, MinSpanDays = 7, LongestEstimate = 730;
    public const double SteadyPerDay = 0.02;

    /// <summary>Every supply in the rows, in the order first seen.</summary>
    public static IReadOnlyList<SupplySummary> SummarizeAll(IReadOnlyList<SupplyRow> rows, DateOnly today) =>
        rows.GroupBy(r => r.Key).Select(g => Summarize(g.ToList(), today)).ToList();

    /// <param name="rows">One supply's rows, oldest first.</param>
    public static SupplySummary Summarize(IReadOnlyList<SupplyRow> rows, DateOnly today)
    {
        var stints = Stints(rows);
        var cartridges = stints.Select((s, i) => new CartridgeStint(s.Rows[0].Day, s.Rows[^1].Day, s.FirstPercent, s.LastPercent,
            PagesOn(s.Rows, i + 1 < stints.Count ? stints[i + 1].Rows : null), s.SeenGoingIn)).ToList();
        return new SupplySummary(rows.Count > 0 ? rows[0].Supply : "", rows.Count > 0 ? rows[0].Color : null, cartridges,
            stints.Count == 0 ? new SupplyForecast(ForecastState.NoLevel) : Forecast(stints[^1].Rows, today));
    }

    /// <summary>The first day of the cartridge each row belongs to, and the pages printed on it up to that row (the export's columns).</summary>
    internal static IEnumerable<(SupplyRow Row, DateOnly CartridgeFrom, int? PagesOnCartridge)> Annotate(IReadOnlyList<SupplyRow> rows)
    {
        var stints = Stints(rows);
        if (stints.Count == 0) // never a level: the rows still count, as one unknown cartridge
            stints = rows.Count == 0 ? [] : [new Stint(rows.ToList(), 0, 0, false)];
        foreach (var stint in stints)
        {
            var start = stint.Rows.FirstOrDefault(r => r.Pages is not null)?.Pages;
            foreach (var row in stint.Rows)
                yield return (row, stint.Rows[0].Day, row.Pages is { } p && start is { } s && p >= s ? p - s : null);
        }
    }

    internal sealed record Stint(List<SupplyRow> Rows, int FirstPercent, int LastPercent, bool SeenGoingIn);

    /// <summary>The rows split at each change of cartridge. Rows before the first known level join the first cartridge; no known level at all: none.</summary>
    internal static List<Stint> Stints(IReadOnlyList<SupplyRow> rows)
    {
        var stints = new List<Stint>();
        var current = new List<SupplyRow>();
        int? first = null, last = null;
        var seen = false;
        foreach (var row in rows)
        {
            if (row.Percent is { } p && last is { } before && p - before >= ChangeJump)
            {
                stints.Add(new Stint(current, first!.Value, before, seen));
                current = [];
                (first, seen) = (p, true);
            }
            current.Add(row);
            if (row.Percent is { } known)
            {
                first ??= known;
                last = known;
            }
        }
        if (first is { } f && last is { } l) stints.Add(new Stint(current, f, l, seen));
        return stints;
    }

    private static int? PagesOn(List<SupplyRow> rows, List<SupplyRow>? next)
    {
        var start = rows.FirstOrDefault(r => r.Pages is not null)?.Pages;
        var end = next?.FirstOrDefault(r => r.Pages is not null)?.Pages ?? rows.LastOrDefault(r => r.Pages is not null)?.Pages;
        return start is { } s && end is { } e && e >= s ? e - s : null;
    }

    private static SupplyForecast Forecast(List<SupplyRow> cartridge, DateOnly today)
    {
        var known = cartridge.Where(r => r.Percent is not null).ToList();
        if (known[^1].Percent == 0) return new SupplyForecast(ForecastState.Empty);
        var oldest = today.AddDays(-WindowDays);
        var window = known.Where(r => r.Day >= oldest && r.Day <= today).ToList();
        var span = window.Count == 0 ? 0 : window[^1].Day.DayNumber - window[0].Day.DayNumber;
        if (window.Count < MinReadings || span < MinSpanDays)
            return new SupplyForecast(ForecastState.NotEnoughData, MoreDays: Math.Max(MinSpanDays - span, MinReadings - window.Count));

        // Least squares by calendar day; x from the window's first row, so the numbers stay small.
        var x0 = window[0].Day.DayNumber;
        double n = window.Count, sx = 0, sy = 0, sxy = 0, sxx = 0;
        foreach (var r in window)
        {
            double x = r.Day.DayNumber - x0, y = r.Percent!.Value;
            sx += x;
            sy += y;
            sxy += x * y;
            sxx += x * x;
        }
        var perDay = -(n * sxy - sx * sy) / (n * sxx - sx * sx);
        if (perDay < SteadyPerDay) return new SupplyForecast(ForecastState.Steady);

        var left = window[^1].Percent!.Value / perDay - (today.DayNumber - window[^1].Day.DayNumber);
        return new SupplyForecast(ForecastState.Estimate, left > LongestEstimate ? null : (int)Math.Max(0, Math.Round(left)));
    }
}

/// <summary>A point on the chart: a stored row with a level, unchanged.</summary>
public sealed record ChartPoint(DateOnly Day, int Percent);

/// <summary>
/// One supply on the chart. A new segment starts at a change of cartridge (a mark, not a line climbing to it) and after a row with no
/// level (nothing is drawn for it). Days with no row at all (the PC off, the printer away) stay joined: the level did go from one
/// to the other.
/// </summary>
public sealed record ChartLine(string Supply, string? Color, IReadOnlyList<IReadOnlyList<ChartPoint>> Segments, IReadOnlyList<DateOnly> Changes);

/// <summary>What the supplies card's chart draws: the stored rows of the last <see cref="Days"/> days, nothing resampled or smoothed.</summary>
public sealed record SupplyChartData(DateOnly From, DateOnly To, IReadOnlyList<ChartLine> Lines)
{
    public const int Days = 366;

    /// <summary>Some supply has two readings on different days: a line to draw. Otherwise the card says the chart fills in as days pass.</summary>
    public bool HasEnoughToDraw => Lines.Any(l => l.Segments.SelectMany(s => s).Select(p => p.Day).Distinct().Count() >= 2);

    public static SupplyChartData Build(IReadOnlyList<SupplyRow> rows, DateOnly today)
    {
        var oldest = today.AddDays(-Days);
        var shown = rows.Where(r => r.Day >= oldest && r.Day <= today).ToList();
        var lines = new List<ChartLine>();
        foreach (var supply in rows.GroupBy(r => r.Key))
        {
            var segments = new List<IReadOnlyList<ChartPoint>>();
            var changes = new List<DateOnly>();
            foreach (var stint in SupplyAnalysis.Stints(supply.ToList()))
            {
                if (stint.SeenGoingIn && stint.Rows[0].Day >= oldest) changes.Add(stint.Rows[0].Day);
                var segment = new List<ChartPoint>();
                foreach (var row in stint.Rows.Where(r => r.Day >= oldest && r.Day <= today))
                {
                    if (row.Percent is { } p)
                    {
                        segment.Add(new ChartPoint(row.Day, p));
                        continue;
                    }
                    if (segment.Count > 0) segments.Add(segment);
                    segment = [];
                }
                if (segment.Count > 0) segments.Add(segment);
            }
            if (segments.Count > 0) lines.Add(new ChartLine(supply.First().Supply, supply.First().Color, segments, changes));
        }
        return new SupplyChartData(shown.Count > 0 ? shown[0].Day : today, today, lines);
    }
}
