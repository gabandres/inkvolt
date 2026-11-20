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
        QueueConnection.Network => CoreStrings.Queue_ConnNetwork,
        QueueConnection.Shared => ServerOf(q.Name) is { } server ? string.Format(CoreStrings.Queue_ConnSharedFrom, server) : CoreStrings.Queue_ConnSharedFromAnotherPc,
        QueueConnection.Parallel => CoreStrings.Queue_ConnParallel,
        QueueConnection.Serial => CoreStrings.Queue_ConnSerial,
        _ => CoreStrings.Queue_ConnWindowsPrinter,
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
        q.Name.StartsWith(@"\\", StringComparison.Ordinal) && q.Name[2..].Split('\\') is [{ Length: > 0 } server, { Length: > 0 } share] ? string.Format(CoreStrings.Queue_ShareOnServer, share, server) : q.Name;

    /// <summary>"USB (USB001)", "Network (192.0.2.40)", "Network (WSD)": the connection with the port, for "About this printer".</summary>
    public static string ConnectionDetail(SpoolerQueue q)
    {
        var port = q.PortName.Trim();
        var text = ConnectionText(q);
        return Connection(q) switch
        {
            QueueConnection.Shared => text,
            QueueConnection.Network when port.StartsWith("WSD", StringComparison.OrdinalIgnoreCase) => q.DeviceAddress is { } at ? $"{text} (WSD, {at})" : $"{text} (WSD)",
            QueueConnection.Network when q.PortAddress?.Trim() is { Length: > 0 } address => $"{text} ({address})",
            QueueConnection.Network when Uri.TryCreate(port, UriKind.Absolute, out var u) && u.Host.Length > 0 => $"{text} (IPP, {u.Host})",
            QueueConnection.Network when QueueMatch.HostsIn(port).FirstOrDefault(h => System.Net.IPAddress.TryParse(h, out _)) is { } ip => $"{text} ({ip})",
            _ when port.Length > 0 => $"{text} ({port.TrimEnd(':')})",
            _ => text,
        };
    }

    /// <summary>
    /// Where a queue's printer can be asked over SNMP: a network queue whose port has the printer's address (a Standard TCP/IP
    /// or LPR port, an IPP URL, an address in the port's name), or a WSD queue whose device node is present and says its address
    /// (<see cref="SpoolerQueue.DeviceAddress"/>: a node Windows no longer sees keeps an address DHCP may have given another
    /// device). Null for USB, a WSD queue whose printer isn't there or whose address isn't known, queues shared from another PC
    /// (the address there is the PC's) and the rest. A WSD printer is read only once it says it is this one (<see cref="SameDevice"/>).
    /// </summary>
    public static string? SnmpAddress(SpoolerQueue q)
    {
        if (Connection(q) != QueueConnection.Network) return null;
        var port = q.PortName.Trim();
        if (IsWsd(q)) return q.DevicePresent == true && q.DeviceAddress is { } device && UsableIPv4(device) ? device : null;
        if (q.PortAddress?.Trim() is { Length: > 0 } address && Uri.CheckHostName(address) != UriHostNameType.Unknown) return address;
        if (Uri.TryCreate(port, UriKind.Absolute, out var u) && u.Scheme is "http" or "https" or "ipp" or "ipps" && u.Host.Length > 0) return u.Host;
        var hosts = QueueMatch.HostsIn(port);
        if (hosts.FirstOrDefault(h => System.Net.IPAddress.TryParse(h, out var ip) && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork) is { } v4)
            return v4;
        // A TCP/IP port named after the printer's host name ("IP_printer.example", Windows' default naming).
        return q.PortMonitor is "Standard TCP/IP Port" or "LPR Port" && hosts.FirstOrDefault(h => h.Contains('.')) is { } name ? name : null;
    }

    /// <summary>A queue on a WSD port (Windows' discovered network printers): its port has no address, its device node does.</summary>
    public static bool IsWsd(SpoolerQueue q) =>
        q.PortName.Trim().StartsWith("WSD", StringComparison.OrdinalIgnoreCase) || q.PortMonitor == "WSD Port Monitor";

    /// <summary>
    /// A WSD printer's IPv4 address from the device nodes in its queue's container: the first usable one a WSD node
    /// (<c>SWD\DAFWSDProvider\…</c>) has in PnP-X's IP address property, else the host of its WS-Discovery transport address
    /// (XAddrs, <c>http://192.0.2.30:3911/…</c>) when that is an IPv4 address. Null when none says one (an IPv6-only printer too:
    /// SNMP is asked over IPv4 here). The values are the device's own: 16 nodes and 16 values each are looked at, at most.
    /// </summary>
    public static string? WsdAddress(IEnumerable<(string InstanceId, IReadOnlyList<string> IpAddresses, IReadOnlyList<string> XAddrs)> nodes)
    {
        var wsd = nodes.Where(n => n.InstanceId.StartsWith(@"SWD\DAFWSDProvider\", StringComparison.OrdinalIgnoreCase)).Take(16).ToList();
        return wsd.SelectMany(n => n.IpAddresses.Take(16)).Select(a => a.Trim()).FirstOrDefault(UsableIPv4)
               ?? wsd.SelectMany(n => n.XAddrs.Take(16)).SelectMany(x => x.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(16))
                   .Select(x => x.Length <= 2048 && Uri.TryCreate(x, UriKind.Absolute, out var u) && u.Scheme is "http" or "https" ? u.Host : null)
                   .FirstOrDefault(h => h is not null && UsableIPv4(h));
    }

    /// <summary>
    /// Whether the device that answered SNMP at a WSD queue's address is that queue's printer: the serial numbers agree when both
    /// say one (PnP-X's against prtGeneralSerialNumber); else every model number in its SNMP model (a word with a digit, "M234dw")
    /// is in the device node's model name or the queue's name. False when there's nothing to compare: another device that took
    /// the address by DHCP is never read as this printer.
    /// </summary>
    public static bool SameDevice(SpoolerQueue q, Snmp.SnmpIdentity answered)
    {
        if (q.DeviceSerial?.Trim() is { Length: > 0 } serial && answered.SerialNumber?.Trim() is { Length: > 0 } said)
            return string.Equals(serial, said, StringComparison.OrdinalIgnoreCase);
        var numbers = Words(answered.Model).Where(w => w.Any(char.IsDigit)).ToList();
        if (numbers.Count == 0) return false;
        var mine = Words(q.DeviceModel).Concat(Words(q.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return numbers.All(mine.Contains);

        static string[] Words(string? text) =>
            text is null || text.Length > 512 ? [] : text.Split([' ', '-', '_', '(', ')', ',', ';', '/', '.'], StringSplitOptions.RemoveEmptyEntries);
    }

    /// <summary>
    /// The first word a WSD node (<c>SWD\DAFWSDProvider\…</c>) says in a text property (PnP-X's serial number, model name),
    /// cleaned to one line of 64 characters at most (<see cref="Fleet.FleetText.Clean"/>); null when none says one.
    /// </summary>
    public static string? WsdText(IEnumerable<(string InstanceId, IReadOnlyList<string> Values)> nodes) =>
        nodes.Where(n => n.InstanceId.StartsWith(@"SWD\DAFWSDProvider\", StringComparison.OrdinalIgnoreCase)).Take(16)
            .SelectMany(n => n.Values.Take(4)).Select(v => Fleet.FleetText.Clean(v, 64)).FirstOrDefault(v => v is not null);

    /// <summary>A unicast IPv4 address a printer can have, written plainly: not 0.x, loopback, multicast or broadcast.</summary>
    private static bool UsableIPv4(string text) =>
        text.Length <= 15 && System.Net.IPAddress.TryParse(text, out var ip) && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
        && ip.ToString() == text && ip.GetAddressBytes() is [not (0 or 127 or >= 224), ..];

    /// <summary>The device container Windows gives queues without a device of their own (and some virtual ones): the PC itself.</summary>
    public const string ThisPcContainer = "00000000-0000-0000-ffff-ffffffffffff";

    /// <summary>
    /// Whether to ask Windows if a queue's printer is connected (<see cref="DevicePresence"/>, a PnP query per queue): only for a
    /// real USB or WSD queue with a container of its own that no network printer here stands for, since presence tells nothing
    /// for TCP/IP and IPP queues, and a claimed queue isn't listed.
    /// </summary>
    public static bool NeedsPresence(SpoolerQueue q, InkvoltPrinters known)
    {
        if (q.ContainerId is not { Length: > 0 } container || string.Equals(container, ThisPcContainer, StringComparison.OrdinalIgnoreCase) || IsVirtual(q))
            return false;
        return (Connection(q) == QueueConnection.Usb || IsWsd(q)) && Unclaimed([q], known).Count > 0;
    }

    /// <summary>
    /// Queues renamed in Windows between two listings: old id → the queue under its new name. A queue counts as renamed when its
    /// name is gone, exactly one new name appeared with the same device container (not the PC's) or, without one, the same port.
    /// </summary>
    public static IReadOnlyDictionary<string, SpoolerQueue> Renamed(IReadOnlyList<SpoolerQueue> before, IReadOnlyList<SpoolerQueue> after)
    {
        var oldIds = before.Select(q => IdFor(q.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var newIds = after.Select(q => IdFor(q.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var appeared = after.Where(q => !oldIds.Contains(IdFor(q.Name))).ToList();
        var renamed = new Dictionary<string, SpoolerQueue>(StringComparer.OrdinalIgnoreCase);
        foreach (var gone in before.Where(q => !newIds.Contains(IdFor(q.Name))))
        {
            var container = gone.ContainerId is { Length: > 0 } c && !string.Equals(c, ThisPcContainer, StringComparison.OrdinalIgnoreCase) ? c : null;
            var same = container is not null
                ? appeared.Where(q => string.Equals(q.ContainerId, container, StringComparison.OrdinalIgnoreCase)).ToList()
                : gone.PortName.Trim() is { Length: > 0 } port && !VirtualPorts.Contains(port, StringComparer.OrdinalIgnoreCase)
                    ? appeared.Where(q => string.Equals(q.PortName.Trim(), port, StringComparison.OrdinalIgnoreCase)).ToList()
                    : [];
            if (same is [var only]) renamed[IdFor(gone.Name)] = only;
        }
        return renamed;
    }

    internal static string? ServerOf(string name) =>
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
