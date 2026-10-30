using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.History;

/// <summary>
/// What the supplies card shows from a printer's history after a reading: the chart, each supply's line ("About 34 days left ·
/// 1,240 pages since this cartridge went in") and the days left the low-supply alert names.
/// </summary>
public sealed record SupplyHistoryView(SupplyChartData Chart, IReadOnlyDictionary<string, SupplySummary> Summaries)
{
    public static SupplyHistoryView Empty(DateOnly today) => new(new SupplyChartData(today, today, []), new Dictionary<string, SupplySummary>());

    /// <param name="rows">One printer's rows (<see cref="SupplyHistoryStore.Rows"/>).</param>
    public static SupplyHistoryView Of(IReadOnlyList<SupplyRow> rows, DateOnly today) =>
        new(SupplyChartData.Build(rows, today),
            SupplyAnalysis.SummarizeAll(rows, today).ToDictionary(s => SupplyRow.KeyOf(s.Supply, s.Color), StringComparer.Ordinal));

    /// <summary>The supply's line under its level; null for a supply the history has nothing to say about (a waste box, no level).</summary>
    public string? LineFor(Consumable supply) =>
        !supply.IsWaste && Summaries.TryGetValue(SupplyRow.KeyOf(supply), out var s) ? s.Line : null;

    /// <summary>Days left per supply where there is an estimate (for <see cref="Alerts.PrinterSnapshot.DaysLeft"/>).</summary>
    public IReadOnlyDictionary<string, int> DaysLeft =>
        Summaries.Where(kv => kv.Value.Forecast is { State: ForecastState.Estimate, DaysLeft: not null })
            .ToDictionary(kv => kv.Key, kv => kv.Value.Forecast.DaysLeft!.Value, StringComparer.Ordinal);

    /// <summary>
    /// The card's line under the chart when it can't draw yet: why, in plain words. Null when the chart draws, or when no supply
    /// reports a level at all (nothing will ever be drawn: the card says nothing).
    /// </summary>
    public string? ChartNote(IReadOnlyList<Consumable> supplies) =>
        Chart.HasEnoughToDraw ? null
        : supplies.Any(s => !s.IsWaste && s.PercentRemaining is >= 0 and <= 100)
            ? "The level chart fills in as days pass: Inkvolt Print keeps one reading a day on this PC."
            : null;
}
