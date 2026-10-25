using System.ComponentModel;
using System.Runtime.InteropServices;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Windows.Offline;
using Windows.Devices.Enumeration;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// The print queues installed on this PC (read only: winspool as the signed-in user, plus each queue's PnP container from the
/// device interface list), for listing printers that network discovery doesn't reach: USB, WSD, older network, shared.
/// </summary>
public static class InstalledQueues
{
    /// <summary>
    /// How long one queue's details may take: a printer shared from a PC that's off makes winspool wait for RPC to time out
    /// (tens of seconds), and a stuck spooler never answers. Past this the queue reads as unreachable for now.
    /// </summary>
    private static readonly TimeSpan ReadLimit = TimeSpan.FromSeconds(5);

    private static readonly TimedCalls<string, (SpoolerQueue? Queue, int Error)> Reads = new(ReadLimit);
    private static readonly TimedCalls<int, (IReadOnlyList<(string Name, uint Attributes)>, Dictionary<string, string?>)> Lists = new(TimeSpan.FromSeconds(10));
    private static readonly Dictionary<string, SpoolerQueue> LastRead = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<string, bool?> Presence = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Lock Gate = new();

    /// <summary>
    /// Every queue with its port monitor and PnP container. Empty when the Print Spooler doesn't answer. A queue whose details
    /// don't come in time (shared from a PC that's off) is listed as it was last read, or by name only, rather than holding up the
    /// rest. Whether the printer behind a queue is connected is asked only for those <paramref name="needsPresence"/> picks
    /// (<see cref="QueueKinds.NeedsPresence"/>); the queues' status reads use that answer until the next list.
    /// </summary>
    public static async Task<IReadOnlyList<SpoolerQueue>> ListAsync(Func<SpoolerQueue, bool>? needsPresence = null)
    {
        var (answered, listed) = await Lists.RunAsync(0, () =>
        {
            try
            {
                var names = Winspool.QueueNames();
                var ports = Winspool.Ports().GroupBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(g => g.Key, g => g.First().Monitor, StringComparer.OrdinalIgnoreCase);
                return (names, ports);
            }
            catch (Win32Exception ex)
            {
                System.Diagnostics.Trace.WriteLine($"queues: {ex.Message}"); // spooler stopped: no queues to show
                return ([], new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase));
            }
        });
        if (!answered)
        {
            lock (Gate) return LastRead.Values.ToList(); // the spooler doesn't answer: the queues as last read (their status says so)
        }
        var (names, monitors) = listed;
        if (names.Count == 0) return [];

        var details = await Task.WhenAll(names.Select(async n => (n.Name, n.Attributes, Read: await Reads.RunAsync(n.Name, () => Winspool.Queue(n.Name)))));
        var queues = new List<SpoolerQueue>(names.Count);
        lock (Gate)
        {
            foreach (var (name, attributes, (got, (queue, error))) in details)
            {
                if (got && queue is not null) LastRead[name] = queue;
                else if (got && SpoolerStatus.IsRemoved(error))
                {
                    LastRead.Remove(name);
                    continue; // removed between the two calls
                }
                queues.Add(got && queue is not null ? queue
                    : LastRead.GetValueOrDefault(name) ?? new SpoolerQueue(name, "", null, SpoolerFlags.StatusServerUnknown, attributes, 0));
            }
            foreach (var gone in LastRead.Keys.Except(names.Select(n => n.Name), StringComparer.OrdinalIgnoreCase).ToList()) LastRead.Remove(gone);
        }

        IReadOnlyList<WindowsQueue> devices;
        try { devices = await QueueFinder.ListAsync(); }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            System.Diagnostics.Trace.WriteLine($"queue containers: {ex.Message}");
            devices = [];
        }
        var list = await Task.WhenAll(queues.Select(async q =>
        {
            var container = devices.FirstOrDefault(d => string.Equals(d.Name, q.Name, StringComparison.OrdinalIgnoreCase))?.ContainerId;
            var monitor = monitors.GetValueOrDefault(q.PortName);
            // A Standard TCP/IP port may be named anything: its printer's address (for SNMP) comes from the port monitor.
            var tcp = monitor == "Standard TCP/IP Port" && !QueueKinds.IsVirtual(q) ? await Task.Run(() => TcpPort(q.PortName)) : null;
            var found = q with { PortMonitor = monitor, ContainerId = container, PortAddress = tcp?.Host, PortCommunity = tcp?.Community };
            if (container is null || needsPresence?.Invoke(found) != true) return found;
            var present = await DevicePresentAsync(container);
            lock (Gate) Presence[container] = present;
            return found with { DevicePresent = present };
        }));
        return list;
    }

    /// <summary>
    /// One queue now, within <see cref="ReadLimit"/>: (true, the queue or the Win32 error) when winspool answered in time, (false, …)
    /// when it didn't. A read still running from before is waited on rather than started again.
    /// </summary>
    internal static Task<(bool Answered, (SpoolerQueue? Queue, int Error) Read)> ReadAsync(string name, CancellationToken ct) =>
        Reads.RunAsync(name, () => Winspool.Queue(name), ct);

    /// <summary>Whether the printer in <paramref name="containerId"/> was connected at the last list (null: not asked, or can't tell).</summary>
    internal static bool? LastPresence(string? containerId)
    {
        if (containerId is null) return null;
        lock (Gate) return Presence.GetValueOrDefault(containerId);
    }

    private static (string? Host, string? Community)? TcpPort(string port)
    {
        try { return Winspool.TcpPortConfig(port); }
        catch (Exception ex) when (ex is Win32Exception or ExternalException)
        {
            System.Diagnostics.Trace.WriteLine($"tcp/ip port: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Whether Windows sees the printer behind a queue: its USB or WSD device nodes in the queue's container are present
    /// (<see cref="QueueKinds.DevicePresence"/>). Null when that can't be told.
    /// </summary>
    internal static async Task<bool?> DevicePresentAsync(string? containerId)
    {
        if (containerId is null || string.Equals(containerId, QueueKinds.ThisPcContainer, StringComparison.OrdinalIgnoreCase)) return null;
        try
        {
            const string present = "System.Devices.Present", instance = "System.Devices.DeviceInstanceId";
            var nodes = await DeviceInformation.FindAllAsync($"System.Devices.ContainerId:=\"{{{containerId}}}\"", [present, instance], DeviceInformationKind.Device);
            return QueueKinds.DevicePresence(nodes.Select(n => (n.Properties.TryGetValue(instance, out var id) ? id as string ?? "" : "",
                n.Properties.TryGetValue(present, out var p) && p is true)));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            System.Diagnostics.Trace.WriteLine($"queue device presence: {ex.Message}");
            return null;
        }
    }
}

/// <summary>
/// A queue printer's status as Windows and its driver report it (the spooler's status bits; no supply levels). Whether a USB or
/// WSD printer is connected comes from the last queue list (every 30 s), not a device query on every read.
/// </summary>
public sealed class SpoolerStatusSource(SpoolerQueue listed) : IQueueStatusSource
{
    public string Origin => "Windows and the printer's driver";

    public bool HasSupplyLevels => false;

    public async Task<QueueStatusRead?> ReadAsync(CancellationToken ct)
    {
        var (answered, (q, error)) = await InstalledQueues.ReadAsync(listed.Name, ct);
        if (!answered) return QueueStatusRead.From(SpoolerStatus.Unreadable(listed, 0)); // no answer in time: not current any more
        if (q is null) return SpoolerStatus.IsRemoved(error) ? null : QueueStatusRead.From(SpoolerStatus.Unreadable(listed, error));
        return QueueStatusRead.From(SpoolerStatus.Describe(q with
        {
            PortMonitor = listed.PortMonitor, ContainerId = listed.ContainerId, DevicePresent = InstalledQueues.LastPresence(listed.ContainerId),
        }));
    }
}
