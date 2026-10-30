using System.Globalization;
using System.Text;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.History;

/// <summary>
/// One supply's state on one day. <see cref="Pages"/> is the printer's lifetime page count that day (a printer that reports one);
/// <see cref="Percent"/> is null when the printer gave no level (SNMP's and IPP's -1, -2, -3 arrive as null).
/// </summary>
public sealed record SupplyRow(DateOnly Day, string Supply, string? Color, int? Percent, string State, int? Pages)
{
    public string Key => KeyOf(Supply, Color);

    public static string KeyOf(string supply, string? color) => $"{supply}|{color}";

    /// <summary>The key a reading's supply is kept under.</summary>
    public static string KeyOf(Consumable supply) => KeyOf(SupplyHistoryStore.Clean(supply.Name, SupplyHistoryStore.MaxName), SupplyHistoryStore.CleanColor(supply.ColorCode));
}

/// <summary>
/// Supply history kept on this PC: for each printer one small text file beside <c>state.json</c>, one row a day per supply, the
/// day's last reading winning (ink and toner only: a waste box has no level to follow). A row holds the date, the supply's name
/// and color, its level and state, and the printer's page count: no serial number, address, document or user, and nothing is
/// ever sent. Bounded: <see cref="MaxDays"/> per printer, <see cref="MaxSupplies"/> per printer and names cut to
/// <see cref="MaxName"/> (what a printer reports is not trusted), <see cref="MaxPrinters"/> files. A reading that lost a part
/// keeps what the day already knew. Never throws for a file it can't read or write: the history is a nicety.
/// </summary>
/// <param name="folder">Where the files live; null keeps everything in memory (demo mode).</param>
/// <param name="firstReading">Called once when a printer with no history gives its first reading (demo mode's made-up year).</param>
public sealed class SupplyHistoryStore(string? folder, Action<SupplyHistoryStore, string, IReadOnlyList<Consumable>, int?, DateOnly>? firstReading = null,
    Action<string>? log = null)
{
    /// <summary>About three years.</summary>
    public const int MaxDays = 1100;

    public const int MaxSupplies = 16, MaxName = 64, MaxPrinters = 64;
    private const int MaxState = 24, MaxFileBytes = 4 * 1024 * 1024;
    private const string Header = "#inkvolt-supply-history 1";

    private readonly Lock _gate = new();
    private readonly Dictionary<string, List<SupplyRow>> _rows = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _seeded = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>This printer's rows, oldest first.</summary>
    public IReadOnlyList<SupplyRow> Rows(string printerId)
    {
        lock (_gate) return Load(printerId).ToList();
    }

    /// <summary>Takes in one reading. True when a row was added or changed (and saved).</summary>
    public bool Record(string printerId, IReadOnlyList<Consumable> supplies, int? pages, DateOnly today)
    {
        lock (_gate)
        {
            var rows = Load(printerId);
            if (rows.Count == 0 && firstReading is not null && _seeded.Add(printerId))
            {
                firstReading(this, printerId, supplies, pages, today);
                rows = Load(printerId);
            }
            var changed = false;
            foreach (var s in supplies)
            {
                if (s.IsWaste) continue;
                var name = Clean(s.Name, MaxName);
                if (name.Length == 0) continue;
                var row = new SupplyRow(today, name, CleanColor(s.ColorCode), InRange(s.PercentRemaining), Clean(s.State, MaxState), pages is >= 0 ? pages : null);
                var at = rows.FindLastIndex(r => r.Day == today && r.Key == row.Key);
                if (at >= 0)
                {
                    var merged = row with { Percent = row.Percent ?? rows[at].Percent, Pages = row.Pages ?? rows[at].Pages };
                    if (merged == rows[at]) continue;
                    rows[at] = merged;
                }
                else
                {
                    if (rows.Select(r => r.Key).Distinct().Count() >= MaxSupplies && rows.All(r => r.Key != row.Key)) continue;
                    rows.Add(row);
                }
                changed = true;
            }
            if (!changed) return false;
            Tidy(rows);
            Save(printerId, rows);
            return true;
        }
    }

    /// <summary>Puts rows in as they are, replacing what the printer had (demo mode's made-up year, tests).</summary>
    public void Import(string printerId, IEnumerable<SupplyRow> rows)
    {
        lock (_gate)
        {
            var list = rows.ToList();
            Tidy(list);
            _rows[printerId] = list;
            Save(printerId, list);
        }
    }

    /// <summary>The printer was removed from the app: its history goes with it.</summary>
    public void Forget(string printerId)
    {
        lock (_gate)
        {
            _rows.Remove(printerId);
            if (PathOf(printerId) is not { } path) return;
            try { File.Delete(path); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { log?.Invoke($"Supply history not removed: {ex.Message}"); }
        }
    }

    /// <summary>An older non-GUID id was normalised: the history moves with it.</summary>
    public void Rename(string oldId, string newId)
    {
        lock (_gate)
        {
            var rows = Load(oldId);
            if (rows.Count == 0) return;
            Forget(oldId);
            _rows[newId] = rows;
            Save(newId, rows);
        }
    }

    private static int? InRange(int? percent) => percent is >= 0 and <= 100 ? percent : null;

    /// <summary>Oldest first (a clock put back can bring a day out of order), and no older than <see cref="MaxDays"/> before the newest.</summary>
    private static void Tidy(List<SupplyRow> rows)
    {
        if (rows.Count == 0) return;
        for (var i = 1; i < rows.Count; i++)
            if (rows[i].Day < rows[i - 1].Day)
            {
                var sorted = rows.OrderBy(r => r.Day).ToList(); // stable: a day's supplies stay in order
                rows.Clear();
                rows.AddRange(sorted);
                break;
            }
        var oldest = rows[^1].Day.AddDays(-MaxDays);
        rows.RemoveAll(r => r.Day < oldest);
    }

    private List<SupplyRow> Load(string printerId)
    {
        if (_rows.TryGetValue(printerId, out var known)) return known;
        var rows = new List<SupplyRow>();
        _rows[printerId] = rows;
        if (PathOf(printerId) is not { } path) return rows;
        try
        {
            if (!File.Exists(path)) return rows;
            if (new FileInfo(path).Length > MaxFileBytes)
            {
                log?.Invoke("Supply history file too large, starting it again");
                return rows;
            }
            foreach (var line in File.ReadLines(path, Encoding.UTF8))
                if (Parse(line) is { } row
                    && (rows.Any(r => r.Key == row.Key) || rows.Select(r => r.Key).Distinct().Count() < MaxSupplies))
                    rows.Add(row);
            Tidy(rows);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"Supply history not read: {ex.Message}");
        }
        return rows;
    }

    private void Save(string printerId, List<SupplyRow> rows)
    {
        if (PathOf(printerId) is not { } path) return;
        try
        {
            Directory.CreateDirectory(folder!);
            var isNew = !File.Exists(path);
            var text = new StringBuilder(Header).Append('\n');
            foreach (var r in rows) text.Append(Format(r)).Append('\n');
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, text.ToString(), new UTF8Encoding(false));
            File.Move(tmp, path, overwrite: true);
            if (isNew) DropOldest(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"Supply history not saved: {ex.Message}");
        }
    }

    /// <summary>The files beyond <see cref="MaxPrinters"/> that were written longest ago go (printers long since gone); never the one just made.</summary>
    private void DropOldest(string keep)
    {
        var files = Directory.GetFiles(folder!, "*.tsv").Where(f => !string.Equals(f, keep, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(File.GetLastWriteTimeUtc).Skip(MaxPrinters - 1);
        foreach (var file in files) File.Delete(file);
    }

    private string? PathOf(string printerId) => folder is null ? null : Path.Combine(folder, $"{PrinterId.FileName(printerId)}.tsv");

    private static string Format(SupplyRow r) => string.Join('\t',
        r.Day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), r.Supply, r.Color ?? "",
        r.Percent?.ToString(CultureInfo.InvariantCulture) ?? "", r.State, r.Pages?.ToString(CultureInfo.InvariantCulture) ?? "");

    /// <summary>A row from its line; null for anything else (a header, a damaged line). A value out of range counts as not reported.</summary>
    private static SupplyRow? Parse(string line)
    {
        var cells = line.Split('\t');
        if (cells.Length != 6 || cells[1].Length == 0
            || !DateOnly.TryParseExact(cells[0], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day)) return null;
        var percent = int.TryParse(cells[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out var p) ? InRange(p) : null;
        int? pages = int.TryParse(cells[5], NumberStyles.Integer, CultureInfo.InvariantCulture, out var c) && c >= 0 ? c : null;
        return new SupplyRow(day, Clean(cells[1], MaxName), CleanColor(cells[2]), percent, Clean(cells[4], MaxState), pages);
    }

    /// <summary>What a printer reports, fit for one cell: no control characters (tabs, line ends), cut to length.</summary>
    internal static string Clean(string? text, int max)
    {
        var clean = new string((text ?? "").Where(c => !char.IsControl(c)).ToArray()).Trim();
        return clean.Length <= max ? clean : clean[..max];
    }

    /// <summary>K, C, M, Y or #RRGGBB as the readers give it; empty counts as none.</summary>
    internal static string? CleanColor(string? color) => Clean(color, 7) is { Length: > 0 } c ? c : null;
}
