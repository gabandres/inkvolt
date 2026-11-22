using System.Globalization;
using System.Text;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.History;

/// <summary>How a logged job left the queue.</summary>
public enum PrintLogOutcome
{
    /// <summary>The spooler said it printed (sent all of it to the printer).</summary>
    Printed,

    /// <summary>Cancelled before it printed (by someone, or the app that printed it).</summary>
    Cancelled,

    /// <summary>It left the queue without saying either (the spooler restarted, or it went between two notices).</summary>
    Left,
}

/// <summary>
/// One job this PC's spooler saw (roadmap 4.9): when it was submitted, the queue, the document's name, who printed it and from where,
/// its pages and copies as the spooler counted them, and color and two-sided when the job's settings said (null: not known). Kept on
/// this PC only (<see cref="PrintLogFile"/>); nothing is sent.
/// </summary>
/// <param name="Pages">The document's pages (the spooler's total pages).</param>
/// <param name="Printed">The pages the spooler counted as printed, copies included; 0 when it counted none.</param>
public sealed record PrintLogEntry(DateTimeOffset At, string Printer, string Document, string User, int Pages, int Copies = 1, bool? Color = null,
    bool? TwoSided = null, PrintLogOutcome Outcome = PrintLogOutcome.Printed, string? Machine = null, int Printed = 0)
{
    /// <summary>
    /// What the month's totals count: the pages the spooler counted as printed, copies included, or (a driver that counts none) pages
    /// times copies; a cancelled job counts none.
    /// </summary>
    public long TotalPages => Outcome == PrintLogOutcome.Cancelled ? 0 : Printed > 0 ? Printed : (long)Pages * Math.Max(1, Copies);

    /// <summary>The month it belongs to, in this PC's time.</summary>
    public DateOnly Month => new(At.LocalDateTime.Year, At.LocalDateTime.Month, 1);
}

/// <summary>One line of a month's totals: a printer or a person, its jobs, pages (pages × copies) and of those the pages known to be in color.</summary>
public sealed record PrintLogTotal(string Name, int Jobs, long Pages, long ColorPages);

/// <summary>
/// The print log (print/GLOSSARY.md, "print log"): the jobs this PC's spooler saw while Inkvolt Print ran, newest last, with month
/// totals per printer and per person and a CSV of it. A log on one PC, of what passed through its spooler: not the quotas, release or
/// accounting of print/ROADMAP.md "Not doing". Bounded: <see cref="MaxEntries"/> jobs and <see cref="KeepMonths"/> months, names
/// cut to <see cref="MaxText"/>. What's read back from the file, and every name the spooler hands over (a document's name comes from
/// whatever printed it), is hostile input: cleaned to one line of visible characters (<see cref="AlertText.Clean"/>).
/// </summary>
public static class PrintLog
{
    public const int MaxEntries = 10_000, KeepMonths = 13, MaxText = 128, MaxPages = 1_000_000, MaxCopies = 9_999;

    /// <summary><paramref name="entry"/> added (cleaned), with the jobs past <see cref="MaxEntries"/> or older than <see cref="KeepMonths"/> dropped.</summary>
    public static List<PrintLogEntry> Add(IReadOnlyList<PrintLogEntry> log, PrintLogEntry entry, DateTimeOffset now)
    {
        var list = new List<PrintLogEntry>(log);
        if (Clean(entry) is { } clean) list.Add(clean);
        return Trim(list, now);
    }

    /// <summary>Oldest first, only the last <see cref="MaxEntries"/>, none older than <see cref="KeepMonths"/> months before <paramref name="now"/>.</summary>
    public static List<PrintLogEntry> Trim(List<PrintLogEntry> list, DateTimeOffset now)
    {
        list.RemoveAll(e => !InRange(e, now));
        if (list.Count > MaxEntries) list.RemoveRange(0, list.Count - MaxEntries);
        return list;
    }

    /// <summary>
    /// Whether a job is kept at <paramref name=now/>: none older than <see cref="KeepMonths"/> months, and none dated more than a day
    /// ahead (a clock set wrong, or an edited file): it would stay for ever.
    /// </summary>
    public static bool InRange(PrintLogEntry e, DateTimeOffset now) => e.At >= now.AddMonths(-KeepMonths) && e.At <= now.AddDays(1);

    /// <summary>An entry as kept: names cleaned and cut, counts bounded; null for one that isn't a job (no time, a date past now's year).</summary>
    public static PrintLogEntry? Clean(PrintLogEntry? e)
    {
        if (e is null || e.At.Year is < 2000 or > 9000) return null;
        var outcome = Enum.IsDefined(e.Outcome) ? e.Outcome : PrintLogOutcome.Left;
        var machine = Text(e.Machine).TrimStart('\\');
        return new PrintLogEntry(e.At, Text(e.Printer), Text(e.Document), Text(e.User), Math.Clamp(e.Pages, 0, MaxPages), Math.Clamp(e.Copies, 1, MaxCopies),
            e.Color, e.TwoSided, outcome, machine.Length == 0 ? null : machine, Math.Clamp(e.Printed, 0, MaxPages));
    }

    /// <summary>One line of visible characters, at most <see cref="MaxText"/>.</summary>
    public static string Text(string? text) => AlertText.Clean(text, MaxText);

    /// <summary>The months with jobs, newest first.</summary>
    public static IReadOnlyList<DateOnly> Months(IEnumerable<PrintLogEntry> log) => [.. log.Select(e => e.Month).Distinct().OrderDescending()];

    /// <summary>A month's jobs, newest first.</summary>
    public static IReadOnlyList<PrintLogEntry> In(IEnumerable<PrintLogEntry> log, DateOnly month) =>
        [.. log.Where(e => e.Month == month).OrderByDescending(e => e.At)];

    /// <summary>A month's totals per printer, most pages first.</summary>
    public static IReadOnlyList<PrintLogTotal> ByPrinter(IEnumerable<PrintLogEntry> log, DateOnly month) => Totals(log, month, e => e.Printer);

    /// <summary>A month's totals per person (the user name the job came with), most pages first.</summary>
    public static IReadOnlyList<PrintLogTotal> ByUser(IEnumerable<PrintLogEntry> log, DateOnly month) => Totals(log, month, e => e.User);

    private static IReadOnlyList<PrintLogTotal> Totals(IEnumerable<PrintLogEntry> log, DateOnly month, Func<PrintLogEntry, string> key) =>
        [.. log.Where(e => e.Month == month && e.Outcome != PrintLogOutcome.Cancelled)
            .GroupBy(e => key(e).Length == 0 ? CoreStrings.PrintLog_Unknown : key(e), StringComparer.OrdinalIgnoreCase)
            .Select(g => new PrintLogTotal(g.First() is var first && key(first).Length > 0 ? key(first) : g.Key, g.Count(), g.Sum(e => e.TotalPages),
                g.Where(e => e.Color == true).Sum(e => e.TotalPages)))
            .OrderByDescending(t => t.Pages).ThenBy(t => t.Name, StringComparer.CurrentCultureIgnoreCase)];

    /// <summary>
    /// The log as CSV (RFC 4180, a header line, oldest first): time in ISO 8601 with its offset, printer, document, user, computer,
    /// pages, copies, total pages, color and two-sided (yes, no or empty when not known), and how it ended. Every name is one cell a
    /// spreadsheet won't run (<see cref="CsvCell"/>).
    /// </summary>
    public static string Csv(IEnumerable<PrintLogEntry> log)
    {
        var csv = new StringBuilder("time,printer,document,user,computer,pages,copies,total_pages,color,two_sided,outcome\r\n");
        foreach (var e in log.OrderBy(e => e.At))
        {
            csv.Append(e.At.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture)).Append(',')
                .Append(CsvCell.Of(e.Printer)).Append(',')
                .Append(CsvCell.Of(e.Document)).Append(',')
                .Append(CsvCell.Of(e.User)).Append(',')
                .Append(CsvCell.Of(e.Machine ?? "")).Append(',')
                .Append(e.Pages.ToString(CultureInfo.InvariantCulture)).Append(',')
                .Append(e.Copies.ToString(CultureInfo.InvariantCulture)).Append(',')
                .Append(e.TotalPages.ToString(CultureInfo.InvariantCulture)).Append(',')
                .Append(YesNo(e.Color)).Append(',')
                .Append(YesNo(e.TwoSided)).Append(',')
                .Append(e.Outcome switch { PrintLogOutcome.Printed => "printed", PrintLogOutcome.Cancelled => "cancelled", _ => "left" })
                .Append("\r\n");
        }
        return csv.ToString();
    }

    private static string YesNo(bool? value) => value switch { true => "yes", false => "no", null => "" };

    /// <summary>A file name for the CSV: "Print log 2026-11-22.csv".</summary>
    public static string CsvFileName(DateTimeOffset now) => string.Format(CultureInfo.InvariantCulture, CoreStrings.PrintLog_CsvFileName, now.LocalDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));

    /// <summary>A month as the list names it: "November 2026".</summary>
    public static string MonthName(DateOnly month, CultureInfo culture)
    {
        var text = month.ToString(culture.DateTimeFormat.YearMonthPattern, culture);
        return text.Length > 0 ? char.ToUpper(text[0], culture) + text[1..] : text;
    }

    /// <summary>
    /// Demo mode's log: about three months of made-up jobs on the demo's two printers and the PDF printer, by three made-up people, the
    /// same every run for a given day (no real name, document or computer).
    /// </summary>
    public static IReadOnlyList<PrintLogEntry> Demo(DateTimeOffset now)
    {
        string[] printers = ["Demo office laser", "Demo photo inkjet", "Microsoft Print to PDF"];
        string[] users = ["demo", "alex", "sam"];
        string[] documents = ["Quarterly report.pdf", "Invoice 1042.pdf", "Boarding pass", "Lesson plan.docx", "Photo.jpg", "Budget.xlsx", "Recipe", "Letter.docx"];
        var random = new Random(now.LocalDateTime.DayOfYear);
        var list = new List<PrintLogEntry>();
        var start = now.AddDays(-80);
        for (var at = start; at < now.AddHours(-1); at = at.AddHours(6 + random.Next(30)))
        {
            var printer = random.Next(10) switch { < 6 => 0, < 9 => 1, _ => 2 };
            var pages = 1 + random.Next(printer == 1 ? 3 : 12);
            var copies = random.Next(8) == 0 ? 2 : 1;
            var outcome = random.Next(20) == 0 ? PrintLogOutcome.Cancelled : PrintLogOutcome.Printed;
            list.Add(new PrintLogEntry(at, printers[printer], documents[random.Next(documents.Length)], users[random.Next(users.Length)], pages, copies,
                Color: printer switch { 0 => false, 1 => true, _ => null }, TwoSided: printer switch { 0 => random.Next(2) == 0, 1 => false, _ => null },
                Outcome: outcome, Machine: "DEMO-PC", Printed: outcome == PrintLogOutcome.Printed ? pages * copies : 0));
        }
        return list;
    }

    /// <summary>What a job's line says after its name: "3 pages × 2 · color · two-sided · cancelled" (only what's known).</summary>
    public static string Detail(PrintLogEntry e)
    {
        var parts = new List<string>();
        if (e.Pages > 0)
            parts.Add(Plural.Of(e.Pages, CoreStrings.Status_JobPages_One, CoreStrings.Status_JobPages_Many) + (e.Copies > 1 ? $" × {e.Copies}" : ""));
        if (e.Color is { } color) parts.Add(color ? CoreStrings.PrintLog_Color : CoreStrings.PrintLog_BlackAndWhite);
        if (e.TwoSided is { } twoSided) parts.Add(twoSided ? CoreStrings.PrintLog_TwoSided : CoreStrings.PrintLog_OneSided);
        if (e.Outcome == PrintLogOutcome.Cancelled) parts.Add(CoreStrings.PrintLog_Cancelled);
        return string.Join(" · ", parts);
    }
}
