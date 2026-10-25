using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Core.Queues;

/// <summary>What an entry on the printer list is.</summary>
public enum ListedKind
{
    /// <summary>Found on the network or added by address.</summary>
    Network,

    /// <summary>Known only by its Windows queue (USB, WSD, shared from another PC…).</summary>
    Queue,

    /// <summary>A scanner Windows has a driver for (WIA) that belongs to no printer on the list.</summary>
    Scanner,
}

/// <summary>An entry on the printer list, as <see cref="PrinterList"/> sees it.</summary>
/// <param name="Id">The printer's UUID (or id from its address), <see cref="QueueKinds.IdFor"/> or <see cref="PrinterList.ScannerIdFor"/>.</param>
public sealed record ListedPrinter(string Id, ListedKind Kind, string Name, string? Model = null, string? Host = null, Uri? EsclRoot = null)
{
    /// <summary>A queue printer's queue.</summary>
    public SpoolerQueue? Queue { get; init; }

    /// <summary>
    /// It would take a Windows scanner: a queue printer, or a network printer that answered without eSCL (one not connected yet
    /// may well have it).
    /// </summary>
    public bool WantsWindowsScanner { get; init; }

    /// <summary>Scanned pages not saved yet: a scanner on its own with them stays on the list.</summary>
    public bool HasUnsavedScans { get; init; }

    /// <summary>A network printer's other UUIDs ("This is my printer"): its Windows queues may carry them.</summary>
    public IReadOnlyList<string> AcceptedUuids { get; init; } = [];

    /// <summary>The Windows queue Inkvolt Print created for a network printer (added by address).</summary>
    public string? QueueName { get; init; }

    public static ListedPrinter ForQueue(SpoolerQueue q) =>
        new(QueueKinds.IdFor(q.Name), ListedKind.Queue, QueueKinds.DisplayName(q), q.DriverName) { Queue = q, WantsWindowsScanner = true };

    public static ListedPrinter ForScanner(WiaDeviceInfo d) => new(PrinterList.ScannerIdFor(d.Id), ListedKind.Scanner, d.Name, d.Description);
}

/// <summary>What <see cref="PrinterList.Reconcile"/> works from: the list now, and what Windows and the user say.</summary>
/// <param name="Queues">Windows' queues; null: leave the queue printers as they are (only the scanners are looked at).</param>
/// <param name="SweepDone">Discovery's first sweep is over: network queues may be listed (a printer it finds would take their place).</param>
/// <param name="Scanners">Windows' scanners (WIA); null: not read yet.</param>
/// <param name="Forgotten">Ids the user removed from the list.</param>
public sealed record PrinterListInput(IReadOnlyList<ListedPrinter> Listed, string? Selected, IReadOnlyList<SpoolerQueue>? Queues, bool SweepDone,
    IReadOnlyList<WiaDeviceInfo>? Scanners, IReadOnlyCollection<string> Forgotten)
{
    /// <summary>Queues renamed in Windows since the last listing: old id → the queue now (<see cref="QueueKinds.Renamed"/>).</summary>
    public IReadOnlyDictionary<string, SpoolerQueue>? Renamed { get; init; }

    /// <summary>A queue printer to select once it's listed (chosen last time, or renamed while selected).</summary>
    public string? WantedQueue { get; init; }

    /// <summary>A scanner on its own to select once it's listed (chosen last time).</summary>
    public string? WantedScanner { get; init; }
}

/// <summary>How the list changes: the caller removes, adds and selects in this order.</summary>
public sealed record PrinterListChange(IReadOnlyList<string> Removed, IReadOnlyList<SpoolerQueue> AddedQueues, IReadOnlyList<WiaDeviceInfo> AddedScanners,
    string? Selected, IReadOnlyList<string> Forget, IReadOnlyList<string> Unforget)
{
    /// <summary>Each printer's Windows scanner (null: none, or let go of it), for every entry that isn't a scanner itself; null when scanners weren't read.</summary>
    public IReadOnlyDictionary<string, WiaDeviceInfo?>? WindowsScanners { get; init; }

    /// <summary>The queue still waited for, to select once it's listed.</summary>
    public string? WantedQueue { get; init; }

    public bool Changes => Removed.Count > 0 || AddedQueues.Count > 0 || AddedScanners.Count > 0;
}

/// <summary>
/// The printer list module: which entries the list has besides network printers, which is selected, and what the user's
/// hidden list gains or loses. Queue printers follow Windows' real queues that no network printer here stands for; Windows'
/// scanners go to the printer they belong to when it would take one, else are listed on their own; entries the user removed
/// stay hidden until Windows no longer has them. Pure: the caller makes and drops its entries as the change says.
/// </summary>
public static class PrinterList
{
    private const string ScannerIdPrefix = "windows-scanner:";

    /// <summary>The id a scanner listed on its own goes by: never a UUID or a queue's id.</summary>
    public static string ScannerIdFor(string deviceId) => ScannerIdPrefix + deviceId.Trim().ToLowerInvariant();

    public static bool IsScannerId(string? id) => id?.StartsWith(ScannerIdPrefix, StringComparison.Ordinal) == true;

    /// <summary>The network printers on the list, as queue matching sees them (accepted UUIDs count as theirs too, without a name).</summary>
    public static InkvoltPrinters Claims(IEnumerable<ListedPrinter> listed)
    {
        var list = new List<InkvoltPrinter>();
        var queueNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in listed.Where(p => p.Kind == ListedKind.Network))
        {
            list.Add(new InkvoltPrinter(p.Id, p.Name, p.Model, p.Host ?? "", p.EsclRoot));
            list.AddRange(p.AcceptedUuids.Select(u => new InkvoltPrinter(u, "", null, "", null)));
            if (p.QueueName is { } q) queueNames[p.Id] = q;
        }
        return new InkvoltPrinters(list, queueNames);
    }

    public static PrinterListChange Reconcile(PrinterListInput input)
    {
        var list = input.Listed.ToList();
        var selected = input.Selected;
        var wantedQueue = input.WantedQueue;
        var forgotten = new HashSet<string>(input.Forgotten, StringComparer.OrdinalIgnoreCase);
        var removed = new List<string>();
        var forget = new List<string>();
        var unforget = new List<string>();
        var addedQueues = new List<SpoolerQueue>();
        var addedScanners = new List<WiaDeviceInfo>();
        bool Listed(string id) => list.Any(p => string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase));
        string? First() => list.FirstOrDefault()?.Id;

        if (input.Queues is { } queues)
        {
            var claims = Claims(list);
            // A hidden queue renamed in Windows stays hidden under its new name.
            foreach (var (oldId, now) in input.Renamed ?? new Dictionary<string, SpoolerQueue>())
                if (forgotten.Contains(oldId) && forgotten.Add(QueueKinds.IdFor(now.Name)))
                    forget.Add(QueueKinds.IdFor(now.Name));
            var wanted = QueueKinds.Unclaimed(queues, claims)
                .Where(q => input.SweepDone || QueueKinds.Connection(q) != QueueConnection.Network)
                .Where(q => !forgotten.Contains(QueueKinds.IdFor(q.Name)))
                .DistinctBy(q => QueueKinds.IdFor(q.Name)).ToList();
            var ids = wanted.Select(q => QueueKinds.IdFor(q.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var gone in list.Where(p => p.Kind == ListedKind.Queue && !ids.Contains(p.Id)).ToList())
            {
                list.Remove(gone);
                removed.Add(gone.Id);
                if (!string.Equals(selected, gone.Id, StringComparison.OrdinalIgnoreCase)) continue;
                if (input.Renamed?.GetValueOrDefault(gone.Id) is { } to)
                {
                    wantedQueue = QueueKinds.IdFor(to.Name); // selected again under its new name, below
                    selected = null;
                }
                else // the network printer that now stands for it, else the first
                    selected = (gone.Queue is { } q && QueueMatch.Match(new QueueInfo(q.Name, q.PortName, q.ContainerId), claims) is { } owner
                        && list.FirstOrDefault(p => string.Equals(p.Id, owner.Uuid, StringComparison.OrdinalIgnoreCase)) is { } standsFor
                        ? standsFor.Id : null) ?? First();
            }
            foreach (var q in wanted)
            {
                var id = QueueKinds.IdFor(q.Name);
                if (Listed(id)) continue;
                list.Add(ListedPrinter.ForQueue(q));
                addedQueues.Add(q);
                if (selected is null || string.Equals(id, wantedQueue, StringComparison.OrdinalIgnoreCase)) selected = id;
            }
            selected ??= First(); // a renamed queue that's hidden isn't listed again
            if (queues.Count > 0)
            {
                if (input.SweepDone) wantedQueue = null; // a network queue chosen last time is listed after the sweep
                // Hidden queues come back once Windows no longer has them (set up again later, they show again).
                var present = queues.Select(q => QueueKinds.IdFor(q.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
                unforget.AddRange(forgotten.Where(f => QueueKinds.IsQueueId(f) && !present.Contains(f)));
            }
        }

        IReadOnlyDictionary<string, WiaDeviceInfo?>? windowsScanners = null;
        if (input.Scanners is { } scanners)
        {
            var owners = Owners(scanners, list);
            var given = new Dictionary<string, WiaDeviceInfo>(StringComparer.OrdinalIgnoreCase);
            foreach (var (device, owner) in owners)
                if (owner is { WantsWindowsScanner: true }) given.TryAdd(owner.Id, device);
            windowsScanners = list.Where(p => p.Kind != ListedKind.Scanner)
                .ToDictionary(p => p.Id, p => given.GetValueOrDefault(p.Id), StringComparer.OrdinalIgnoreCase);

            var wanted = owners.Where(o => o.Owner is null).Select(o => o.Device)
                .Where(d => !forgotten.Contains(ScannerIdFor(d.Id)))
                .DistinctBy(d => ScannerIdFor(d.Id)).ToList();
            var ids = wanted.Select(d => ScannerIdFor(d.Id)).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var gone in list.Where(p => p.Kind == ListedKind.Scanner && !ids.Contains(p.Id) && !p.HasUnsavedScans).ToList())
            {
                list.Remove(gone);
                removed.Add(gone.Id);
                if (string.Equals(selected, gone.Id, StringComparison.OrdinalIgnoreCase))
                    selected = owners.FirstOrDefault(o => ScannerIdFor(o.Device.Id) == gone.Id).Owner?.Id ?? First();
            }
            foreach (var d in wanted)
            {
                var id = ScannerIdFor(d.Id);
                if (Listed(id)) continue;
                list.Add(ListedPrinter.ForScanner(d));
                addedScanners.Add(d);
                if (selected is null || string.Equals(id, input.WantedScanner, StringComparison.OrdinalIgnoreCase)) selected = id;
            }
            var present = scanners.Select(d => ScannerIdFor(d.Id)).ToHashSet(StringComparer.OrdinalIgnoreCase);
            unforget.AddRange(forgotten.Where(f => IsScannerId(f) && !present.Contains(f)));
        }

        return new PrinterListChange(removed, addedQueues, addedScanners, selected, forget, unforget)
            { WindowsScanners = windowsScanners, WantedQueue = wantedQueue };
    }

    /// <summary>
    /// What goes with a printer the user removes from the list, so none of it shows up again as an entry of its own: its id, a
    /// network printer's own Windows queues, and the Windows scanner that belongs to it.
    /// </summary>
    public static IReadOnlyList<string> HiddenWith(ListedPrinter removed, IReadOnlyList<ListedPrinter> listed, IReadOnlyList<SpoolerQueue> queues,
        IReadOnlyList<WiaDeviceInfo> scanners)
    {
        IEnumerable<string> hidden = removed.Kind != ListedKind.Network ? [removed.Id]
            : QueueKinds.Unclaimed(queues, InkvoltPrinters.Empty)
                .Where(q => QueueMatch.Match(new QueueInfo(q.Name, q.PortName, q.ContainerId), Claims([removed])) is not null)
                .Select(q => QueueKinds.IdFor(q.Name)).Prepend(removed.Id);
        return hidden.Concat(Owners(scanners, listed).Where(o => o.Owner?.Id == removed.Id).Select(o => ScannerIdFor(o.Device.Id)))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>
    /// Which printer on the list each scanner belongs to (<see cref="WiaMatch.Assign"/>); null for one no printer claims, and for
    /// a second one matching a printer that already takes one through Windows (listed on its own instead).
    /// </summary>
    private static List<(WiaDeviceInfo Device, ListedPrinter? Owner)> Owners(IReadOnlyList<WiaDeviceInfo> scanners, IReadOnlyList<ListedPrinter> listed)
    {
        var printers = listed.Where(p => p.Kind != ListedKind.Scanner).ToList();
        ListedPrinter? ById(string id) => printers.FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase));
        return WiaMatch.Assign(scanners, printers.Select(Target).ToList(), id => ById(id)?.WantsWindowsScanner == true)
            .Select(a => (a.Device, a.Owner is null ? null : ById(a.Owner))).ToList();
    }

    /// <summary>A printer as WIA matching sees it: its names (and its queue's and driver's) and addresses.</summary>
    private static ScanTarget Target(ListedPrinter p) => new(p.Id,
        new[] { p.Name, p.Model, p.Queue?.Name, p.Queue?.DriverName }.OfType<string>().Where(n => n.Length > 0).ToList(),
        new[] { p.Host, p.Queue?.PortAddress }.OfType<string>().Where(h => h.Length > 0).ToList());
}
