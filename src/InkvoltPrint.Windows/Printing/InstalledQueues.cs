using System.ComponentModel;
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
    /// <summary>Every queue with its port monitor and PnP container. Empty when the Print Spooler doesn't answer.</summary>
    public static async Task<IReadOnlyList<SpoolerQueue>> ListAsync()
    {
        var (queues, monitors) = await Task.Run(() =>
        {
            try
            {
                var list = Winspool.Queues();
                var ports = Winspool.Ports().GroupBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(g => g.Key, g => g.First().Monitor, StringComparer.OrdinalIgnoreCase);
                return (list, ports);
            }
            catch (Win32Exception ex)
            {
                System.Diagnostics.Trace.WriteLine($"queues: {ex.Message}"); // spooler stopped: no queues to show
                return ((IReadOnlyList<SpoolerQueue>)[], new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase));
            }
        });
        if (queues.Count == 0) return queues;
        IReadOnlyList<WindowsQueue> devices;
        try { devices = await QueueFinder.ListAsync(); }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            System.Diagnostics.Trace.WriteLine($"queue containers: {ex.Message}");
            devices = [];
        }
        var list = new List<SpoolerQueue>(queues.Count);
        foreach (var q in queues)
        {
            var container = devices.FirstOrDefault(d => string.Equals(d.Name, q.Name, StringComparison.OrdinalIgnoreCase))?.ContainerId;
            list.Add(q with
            {
                PortMonitor = monitors.GetValueOrDefault(q.PortName),
                ContainerId = container,
                DevicePresent = QueueKinds.IsVirtual(q) ? null : await DevicePresentAsync(container),
            });
        }
        return list;
    }

    // Queues without a device of their own (and some virtual ones) share the PC's container: thousands of nodes, none theirs.
    private const string ThisPcContainer = "00000000-0000-0000-ffff-ffffffffffff";

    /// <summary>
    /// Whether Windows sees the printer behind a queue: its USB or WSD device nodes in the queue's container are present
    /// (<see cref="QueueKinds.DevicePresence"/>). Null when that can't be told.
    /// </summary>
    internal static async Task<bool?> DevicePresentAsync(string? containerId)
    {
        if (containerId is null || string.Equals(containerId, ThisPcContainer, StringComparison.OrdinalIgnoreCase)) return null;
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

/// <summary>A queue printer's status as Windows and its driver report it (the spooler's status bits; no supply levels).</summary>
public sealed class SpoolerStatusSource(SpoolerQueue listed) : IQueueStatusSource
{
    public string Origin => "Windows and the printer's driver";

    public bool HasSupplyLevels => false;

    public async Task<QueueStatusRead?> ReadAsync(CancellationToken ct)
    {
        if (await Task.Run(() => Winspool.Queue(listed.Name), ct) is not { } q) return null;
        var present = await InstalledQueues.DevicePresentAsync(listed.ContainerId);
        return QueueStatusRead.From(SpoolerStatus.Describe(q with { PortMonitor = listed.PortMonitor, ContainerId = listed.ContainerId, DevicePresent = present }));
    }
}
