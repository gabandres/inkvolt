using Windows.Devices.Enumeration;

namespace PrintDesk.Windows.Printing;

public sealed record WindowsQueue(string Name, string? ContainerId);

/// <summary>Maps a printer (by UUID) to its installed Windows print queue.</summary>
public static class QueueFinder
{
    // GUID_DEVINTERFACE for print queues
    private const string PrintQueueInterface = "{0ecef634-6ef0-472a-8085-5ad023ecbccd}";

    public static async Task<IReadOnlyList<WindowsQueue>> ListAsync()
    {
        var found = await DeviceInformation.FindAllAsync(
            $"System.Devices.InterfaceClassGuid:=\"{PrintQueueInterface}\"",
            ["System.Devices.ContainerId"], DeviceInformationKind.DeviceInterface);
        return found
            .Select(d => new WindowsQueue(d.Name, d.Properties.TryGetValue("System.Devices.ContainerId", out var c) && c is Guid g ? g.ToString("D") : null))
            .ToList();
    }

    /// <summary>The queue whose PnP container is this printer. Windows uses the printer UUID as the container for IPP/WSD queues.</summary>
    public static async Task<string?> FindQueueNameAsync(string printerUuid) =>
        (await ListAsync()).FirstOrDefault(q => string.Equals(q.ContainerId, printerUuid.Trim('{', '}'), StringComparison.OrdinalIgnoreCase))?.Name;
}
