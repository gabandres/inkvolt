using System.Globalization;
using System.Text;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Printing;

/// <summary>
/// A batch's results as one CSV (RFC 4180, roadmap 2.4, Pro), a row per file in the list's order. File names come from outside,
/// so a cell a spreadsheet would run as a formula starts with an apostrophe (<see cref="CsvCell"/>).
/// </summary>
public static class BatchPrintCsv
{
    private const string Columns = "Order,File,Folder,Result,Details,Pages,Copies,Two-sided,Paper,Sheets estimated,Sheets sent,Time";

    /// <summary>The file's text when the Pro check allows it; null when it doesn't (the caller shows what Pro does and where to get it).</summary>
    public static string? Export(IEnumerable<BatchPrintResult> results) => Pro.Allows(ProFeature.BatchPrintAutomation) ? Build(results) : null;

    public static string Build(IEnumerable<BatchPrintResult> results)
    {
        var csv = new StringBuilder(Columns).Append("\r\n");
        foreach (var r in results)
            csv.Append((r.Index + 1).ToString(CultureInfo.InvariantCulture)).Append(',')
                .Append(CsvCell.Of(r.Name)).Append(',')
                .Append(CsvCell.Of(Path.GetDirectoryName(r.Path) ?? "")).Append(',')
                .Append(r.State.ToString()).Append(',')
                .Append(CsvCell.Of(r.Message)).Append(',')
                .Append(r.Pages.ToString(CultureInfo.InvariantCulture)).Append(',')
                .Append(r.Copies.ToString(CultureInfo.InvariantCulture)).Append(',')
                .Append(r.TwoSided ? "Yes" : "No").Append(',')
                .Append(CsvCell.Of(r.Paper ?? "")).Append(',')
                .Append(r.SheetsEstimated.ToString(CultureInfo.InvariantCulture)).Append(',')
                .Append(r.SheetsSent.ToString(CultureInfo.InvariantCulture)).Append(',')
                .Append(r.Time.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)).Append("\r\n");
        return csv.ToString();
    }
}
