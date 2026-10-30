using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.History;

/// <summary>
/// Demo mode's made-up year behind a printer's first reading, so <c>--demo</c> and <c>--snapshot</c> show the chart: each supply
/// falling at its own pace with a little day-to-day noise, a change of cartridge whenever the level would pass 100% going back, a
/// week the printer was away, and the page count rising with it (only for a printer that reports one). It ends at the reading itself,
/// and is the same every run for the same reading.
/// </summary>
public static class DemoSupplyHistory
{
    private const int Days = 365;

    /// <summary>For <see cref="SupplyHistoryStore"/>'s first-reading hook.</summary>
    public static void Seed(SupplyHistoryStore store, string printerId, IReadOnlyList<Consumable> supplies, int? pages, DateOnly today)
    {
        var rows = new List<SupplyRow>();
        var random = new Random(StableHash(printerId));
        // About a third of the printer's count printed over the year, so a young printer's count stays well above zero.
        var perDayPages = pages is { } total ? Math.Clamp(total / 3.0 / Days, 0.3, 40) : 0;
        var counts = new int?[Days + 1];
        counts[0] = pages;
        for (var back = 1; back <= Days; back++)
            counts[back] = counts[back - 1] is { } n
                ? Math.Max(0, n - (random.Next(6) == 0 ? 0 : (int)Math.Round(perDayPages * (0.4 + 1.2 * random.NextDouble()))))
                : null;

        foreach (var s in supplies.Where(s => !s.IsWaste && s.PercentRemaining is not null))
        {
            var name = SupplyHistoryStore.Clean(s.Name, SupplyHistoryStore.MaxName);
            var color = SupplyHistoryStore.CleanColor(s.ColorCode);
            var perDay = 0.22 + random.NextDouble() * 0.28;
            var level = (double)s.PercentRemaining!.Value;
            for (var back = 1; back <= Days; back++)
            {
                level += perDay;
                if (level > 97 + random.Next(4)) // going back past a full cartridge: the one before ran down to a few percent
                {
                    level = 4 + random.Next(9);
                    perDay = 0.22 + random.NextDouble() * 0.28;
                }
                if (back is >= 120 and < 127) continue; // the printer was away that week
                var shown = Math.Clamp((int)Math.Round(level + (random.Next(5) == 0 ? random.Next(3) - 1 : 0)), 0, 100);
                rows.Add(new SupplyRow(today.AddDays(-back), name, color, shown, shown <= 15 ? "low" : "ok", counts[back]));
            }
        }
        store.Import(printerId, rows.OrderBy(r => r.Day));
    }

    /// <summary>The same number for the same id in every run (string.GetHashCode isn't).</summary>
    private static int StableHash(string text)
    {
        var hash = 17;
        foreach (var c in text) hash = unchecked(hash * 31 + c);
        return hash;
    }
}
