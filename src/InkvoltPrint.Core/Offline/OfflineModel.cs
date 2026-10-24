using System.Net;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Core.Offline;

/// <summary>The printer the "printer offline" fixer looks at, as Inkvolt Print knows it.</summary>
/// <param name="Uuid">The printer's UUID (its DNS-SD <c>UUID</c>, also the PnP container of Windows' IPP/WSD queues).</param>
/// <param name="Host">The address Inkvolt Print last used for it.</param>
public sealed record OfflineDevice(string Uuid, string Name, string? Model, string? Host)
{
    /// <summary>Addresses it had before (DHCP moved it): a Windows queue whose port still points at one of them is this printer's.</summary>
    public IReadOnlyList<string> PreviousHosts { get; init; } = [];

    /// <summary>The Windows queue Inkvolt Print created or found for it, if any.</summary>
    public string? StoredQueueName { get; init; }

    /// <summary>Windows sees the printer's association endpoint, so its queue can be set up again by pairing (no admin).</summary>
    public bool CanPair { get; init; }
}

public enum SpoolerState { Running, Stopped, Changing, Unknown }

/// <summary>The printer as a fresh mDNS (DNS-SD) look-up by its UUID found it.</summary>
/// <param name="HostName">Its mDNS host name (<c>NPI123456.local</c>), which follows the printer when its address changes.</param>
public sealed record Rediscovery(string Address, string? HostName);

/// <summary>What answered at an address: ping, and which of the printing / web ports accepted a connection.</summary>
public sealed record Reachability(string Host, bool Ping, IReadOnlyList<int> OpenPorts)
{
    /// <summary>The ports tried: IPP, raw printing (JetDirect), the web page (HTTP, HTTPS).</summary>
    public static readonly IReadOnlyList<int> Ports = [631, 9100, 80, 443];

    /// <summary>A printing or web port accepted a connection. Ping alone isn't enough: another device may hold the address.</summary>
    public bool Answers => OpenPorts.Count > 0;

    /// <summary>"IPP, raw printing and its web page".</summary>
    public string PortsText => Join(OpenPorts.Select(p => p switch
    {
        631 => "IPP",
        9100 => "raw printing (port 9100)",
        80 or 443 => "its web page",
        _ => $"port {p}",
    }).Distinct().ToList());

    internal static string Join(IReadOnlyList<string> parts) => parts.Count switch
    {
        0 => "",
        1 => parts[0],
        _ => string.Join(", ", parts.Take(parts.Count - 1)) + " and " + parts[^1],
    };
}

/// <summary>How a Windows queue reaches its printer.</summary>
public enum PortKind
{
    /// <summary>Standard TCP/IP port: a fixed host name or IP address. Goes stale when DHCP gives the printer a new address.</summary>
    TcpIp,

    /// <summary>WSD or IPP port of a queue Windows set up by discovery: Windows finds the device by its ID, not its address.</summary>
    DeviceId,

    /// <summary>An IPP queue added by URL (<c>Add-Printer -IppURL</c>, "Add a printer using an IP address or hostname"): fixed address.</summary>
    IppUrl,

    /// <summary>USB, file, virtual printers and anything else.</summary>
    Other,
}

public sealed record QueuePort(string Name, PortKind Kind)
{
    /// <summary>TCP/IP: the port's host name or IP address; IPP URL: the URL's host. Null for other ports.</summary>
    public string? Host { get; init; }

    /// <summary>TCP/IP: the raw port (9100 by default).</summary>
    public int PortNumber { get; init; } = 9100;

    /// <summary>TCP/IP port that prints over LPR (515) rather than raw.</summary>
    public bool Lpr { get; init; }

    /// <summary>TCP/IP port with "SNMP Status Enabled": Windows marks the queue offline when the printer doesn't answer SNMP.</summary>
    public bool Snmp { get; init; }

    /// <summary>IPP URL ports: the URL.</summary>
    public Uri? Url { get; init; }

    public bool HostIsAddress => Host is not null && IPAddress.TryParse(Host, out _);
}

/// <summary>A Windows print queue and its state, as the spooler reports it.</summary>
public sealed record QueueFacts(string Name, QueuePort Port)
{
    /// <summary>PnP container (Windows uses the printer UUID for IPP/WSD queues).</summary>
    public string? ContainerId { get; init; }

    /// <summary>Pause Printing is on.</summary>
    public bool Paused { get; init; }

    /// <summary>"Use Printer Offline" is on: jobs wait in the queue until it's turned off.</summary>
    public bool WorkOffline { get; init; }

    /// <summary>The spooler or port monitor marks the queue offline.</summary>
    public bool ReportsOffline { get; init; }

    public bool ReportsError { get; init; }

    public IReadOnlyList<QueueJob> Jobs { get; init; } = [];
}

/// <summary>
/// What the fixer needs from the PC and the network. The Windows implementation lives in InkvoltPrint.Windows; tests
/// and demo mode use fakes. Each call may throw; the diagnosis reports a failed probe as "couldn't check".
/// </summary>
public interface IOfflineProbes
{
    Task<SpoolerState> SpoolerAsync(CancellationToken ct);

    /// <summary>Looks for the printer on the network by its UUID (fresh mDNS query); null when it doesn't show up in time.</summary>
    Task<Rediscovery?> RediscoverAsync(string uuid, CancellationToken ct);

    Task<Reachability> ReachAsync(string host, CancellationToken ct);

    /// <summary>Every local print queue, with its port, state and jobs.</summary>
    Task<IReadOnlyList<QueueFacts>> QueuesAsync(CancellationToken ct);
}

public enum CheckKind { Spooler, Network, Connection, Queues, QueueState }

public enum CheckState { Waiting, Running, Passed, Warning, Failed, Skipped }

/// <summary>One line of the diagnosis as it runs: "Print Spooler service · Running".</summary>
public sealed record CheckResult(CheckKind Kind, CheckState State, string Title, string Detail = "")
{
    public static string TitleOf(CheckKind kind) => kind switch
    {
        CheckKind.Spooler => "Print Spooler service",
        CheckKind.Network => "Printer on the network",
        CheckKind.Connection => "Printer answers",
        CheckKind.Queues => "Windows printers for this device",
        _ => "Paused, offline or stuck jobs",
    };

    public static CheckResult Waiting(CheckKind kind) => new(kind, CheckState.Waiting, TitleOf(kind));
}

public enum MatchReason { Container, Stored, Address, Name }

/// <summary>A Windows queue that prints to this printer, why it was matched, and whether its port points somewhere else.</summary>
public sealed record MatchedQueue(QueueFacts Queue, MatchReason Reason, bool PortIsStale)
{
    /// <summary>"Standard TCP/IP port to 192.0.2.12", "WSD/IPP port (Windows finds it by its ID)".</summary>
    public string PortText => Queue.Port.Kind switch
    {
        PortKind.TcpIp => $"Standard TCP/IP port to {Queue.Port.Host ?? Queue.Port.Name}{(Queue.Port.Lpr ? " (LPR)" : "")}",
        PortKind.DeviceId => "WSD/IPP port (Windows finds the printer by its ID)",
        PortKind.IppUrl => $"IPP port to {Queue.Port.Url?.Host ?? Queue.Port.Host ?? Queue.Port.Name}",
        _ => $"port {Queue.Port.Name}",
    };
}
