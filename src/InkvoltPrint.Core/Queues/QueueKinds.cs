using System.Text.RegularExpressions;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Queues;

/// <summary>
/// Which Windows queues are printers Inkvolt Print lists on their own: real printers (USB, WSD, TCP/IP, IPP, shared from another
/// PC, parallel or serial) that no network-discovered or remembered printer already stands for. Virtual printers (Print to PDF,
/// XPS, OneNote, fax, "Send To", PDF writers, print to file, remote-desktop redirected printers) are left out.
/// </summary>
public static partial class QueueKinds
{
    private const string IdPrefix = "windows-queue:";

    /// <summary>The id a queue printer goes by in Inkvolt Print (selection, alerts, hidden list): never a UUID, so never mixed up with a device.</summary>
    public static string IdFor(string queueName) => IdPrefix + queueName.Trim().ToLowerInvariant();

    public static bool IsQueueId(string? id) => id?.StartsWith(IdPrefix, StringComparison.Ordinal) == true;

    private static readonly string[] VirtualPorts = ["PORTPROMPT:", "FILE:", "NUL:", "NUL", "XPSPORT:", "SHRFAX:"];

    // Driver or queue names that only virtual printers use ("XPS" alone isn't one: some real printers have XPS drivers). "pdf" covers Microsoft Print to PDF, Adobe PDF, CutePDF, PDF24,
    // PDFCreator, Foxit, Nitro and the like; no printer driver has it in its name.
    private static readonly string[] VirtualWords = ["pdf", "onenote", "fax", "send to", "snagit", "remote desktop easy print",
        "virtual print", "document writer", "image writer"];

    public static bool IsVirtual(SpoolerQueue q)
    {
        if ((q.Attributes & (SpoolerFlags.AttributeFax | SpoolerFlags.AttributeTerminalServer)) != 0) return true;
        var port = q.PortName.Trim();
        if (VirtualPorts.Contains(port, StringComparer.OrdinalIgnoreCase)) return true;
        if (TerminalServerPort().IsMatch(port) || q.Name.Contains("(redirected", StringComparison.OrdinalIgnoreCase)) return true;
        if (string.Equals(q.PortMonitor, "Virtual Monitor", StringComparison.OrdinalIgnoreCase)) return true; // Windows 11 virtual print (PSA) queues
        return VirtualWords.Any(w => q.Name.Contains(w, StringComparison.OrdinalIgnoreCase)
                                     || q.DriverName?.Contains(w, StringComparison.OrdinalIgnoreCase) == true);
    }

    public static QueueConnection Connection(SpoolerQueue q)
    {
        if ((q.Attributes & SpoolerFlags.AttributeNetwork) != 0 || q.Name.StartsWith(@"\\", StringComparison.Ordinal)) return QueueConnection.Shared;
        var port = q.PortName.Trim();
        if (UsbPort().IsMatch(port) || q.PortMonitor?.Contains("USB", StringComparison.OrdinalIgnoreCase) == true) return QueueConnection.Usb;
        if (port.StartsWith("WSD", StringComparison.OrdinalIgnoreCase) || port.StartsWith("IP_", StringComparison.OrdinalIgnoreCase)
            || q.PortMonitor is "Standard TCP/IP Port" or "WSD Port Monitor" or "LPR Port"
            || Uri.TryCreate(port, UriKind.Absolute, out var u) && u.Scheme is "http" or "https" or "ipp" or "ipps"
            || QueueMatch.HostsIn(port).Any(h => System.Net.IPAddress.TryParse(h, out _)))
            return QueueConnection.Network;
        if (port.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) return QueueConnection.Parallel;
        if (port.StartsWith("COM", StringComparison.OrdinalIgnoreCase)) return QueueConnection.Serial;
        return QueueConnection.Other;
    }

    /// <summary>"USB", "Network", "Shared from print-server"…: how the PC reaches it, in a word or two.</summary>
    public static string ConnectionText(SpoolerQueue q) => Connection(q) switch
    {
        QueueConnection.Usb => "USB",
        QueueConnection.Network => "Network",
        QueueConnection.Shared => ServerOf(q.Name) is { } server ? $"Shared from {server}" : "Shared from another PC",
        QueueConnection.Parallel => "Parallel port",
        QueueConnection.Serial => "Serial port",
        _ => "Windows printer",
    };

    /// <summary>
    /// Whether the printer behind a queue is connected, from the device nodes in the queue's PnP container (instance id, present):
    /// USB printers (<c>USBPRINT\…</c>) and WSD devices (<c>SWD\DAFWSDProvider\…</c>) are present only while Windows sees them.
    /// True when one of those is present, false when there are some and none is, null when there are none (IPP and TCP/IP queues:
    /// their nodes stay present whether or not the printer answers).
    /// </summary>
    public static bool? DevicePresence(IEnumerable<(string InstanceId, bool Present)> nodes)
    {
        var physical = nodes.Where(n => n.InstanceId.StartsWith(@"USBPRINT\", StringComparison.OrdinalIgnoreCase)
                                        || n.InstanceId.StartsWith(@"SWD\DAFWSDProvider\", StringComparison.OrdinalIgnoreCase)).ToList();
        return physical.Count == 0 ? null : physical.Any(n => n.Present);
    }

    /// <summary>The name to show: the queue's, or for a printer shared from another PC "Front desk on print-server", as Windows says it.</summary>
    public static string DisplayName(SpoolerQueue q) =>
        q.Name.StartsWith(@"\\", StringComparison.Ordinal) && q.Name[2..].Split('\\') is [{ Length: > 0 } server, { Length: > 0 } share] ? $"{share} on {server}" : q.Name;

    /// <summary>"USB (USB001)", "Network (192.0.2.40)", "Network (WSD)": the connection with the port, for "About this printer".</summary>
    public static string ConnectionDetail(SpoolerQueue q)
    {
        var port = q.PortName.Trim();
        var text = ConnectionText(q);
        return Connection(q) switch
        {
            QueueConnection.Shared => text,
            QueueConnection.Network when port.StartsWith("WSD", StringComparison.OrdinalIgnoreCase) => $"{text} (WSD)",
            QueueConnection.Network when Uri.TryCreate(port, UriKind.Absolute, out var u) && u.Host.Length > 0 => $"{text} (IPP, {u.Host})",
            QueueConnection.Network when QueueMatch.HostsIn(port).FirstOrDefault(h => System.Net.IPAddress.TryParse(h, out _)) is { } ip => $"{text} ({ip})",
            _ when port.Length > 0 => $"{text} ({port.TrimEnd(':')})",
            _ => text,
        };
    }

    private static string? ServerOf(string name) =>
        name.StartsWith(@"\\", StringComparison.Ordinal) && name[2..].Split('\\') is [{ Length: > 0 } server, ..] ? server : null;

    /// <summary>
    /// The real printers among <paramref name="queues"/> that none of <paramref name="known"/> already stands for (matched as
    /// Inkvolt PDF matches queues: stored association, device container, address in the port, an unambiguous name).
    /// </summary>
    public static IReadOnlyList<SpoolerQueue> Unclaimed(IEnumerable<SpoolerQueue> queues, InkvoltPrinters known) =>
        queues.Where(q => !IsVirtual(q) && QueueMatch.Match(new QueueInfo(q.Name, q.PortName, q.ContainerId), known) is null).ToList();

    [GeneratedRegex(@"^(USB|DOT4)", RegexOptions.IgnoreCase)]
    private static partial Regex UsbPort();

    [GeneratedRegex(@"^TS\d+$", RegexOptions.IgnoreCase)]
    private static partial Regex TerminalServerPort();
}
