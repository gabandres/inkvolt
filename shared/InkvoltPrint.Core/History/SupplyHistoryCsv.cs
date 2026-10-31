using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.History;

/// <summary>
/// The Pro export (roadmap 1.1): one CSV (RFC 4180) of the supply history across all printers, a row per stored row, with the
/// cartridge it belongs to and the pages printed on that cartridge so far. Names come from the printers, so a cell a spreadsheet
/// would run as a formula is quoted with a leading apostrophe.
/// </summary>
public static class SupplyHistoryCsv
{
    private const string Columns = "Printer,Supply,Color,Date,Level %,State,Pages printed,Cartridge seen since,Pages on this cartridge";

    /// <summary>The file's text when the Pro check allows it; null when it doesn't (the caller shows what Pro does and where to get it).</summary>
    public static string? Export(SupplyHistoryStore store, IEnumerable<(string Id, string Name)> printers) =>
        Pro.Allows(ProFeature.SupplyHistoryExport) ? Build(store, printers) : null;

    /// <summary>The file's text.</summary>
    public static string Build(SupplyHistoryStore store, IEnumerable<(string Id, string Name)> printers)
    {
        var csv = new StringBuilder(Columns).Append("\r\n");
        foreach (var (id, name) in printers)
            foreach (var supply in store.Rows(id).GroupBy(r => r.Key))
                foreach (var (row, from, pagesOn) in SupplyAnalysis.Annotate(supply.ToList()).OrderBy(a => a.Row.Day))
                    csv.Append(Cell(name)).Append(',')
                        .Append(Cell(row.Supply)).Append(',')
                        .Append(Cell(row.Color ?? "")).Append(',')
                        .Append(Day(row.Day)).Append(',')
                        .Append(Number(row.Percent)).Append(',')
                        .Append(Cell(row.State)).Append(',')
                        .Append(Number(row.Pages)).Append(',')
                        .Append(Day(from)).Append(',')
                        .Append(Number(pagesOn)).Append("\r\n");
        return csv.ToString();
    }

    private static string Day(DateOnly day) => day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static string Number(int? n) => n?.ToString(CultureInfo.InvariantCulture) ?? "";

    private static string Cell(string text) => Suite.CsvCell.Of(text);
}
