using System.Text.RegularExpressions;

namespace PrintDesk.Core.Suite;

/// <summary>A Windows print queue as another app sees it: its name, port and PnP container (when known).</summary>
public sealed record QueueInfo(string Name, string? PortName = null, string? ContainerId = null);

/// <summary>Finds the PrintDesk printer behind a Windows print queue.</summary>
public static partial class QueueMatch
{
    /// <summary>
    /// In order of certainty: the queue PrintDesk created for a printer (its stored association); the queue's PnP container
    /// (Windows uses the printer UUID for IPP/WSD queues); the printer's address in the port name (IP ports, IPP URLs);
    /// finally the queue name when exactly one remembered printer's name or model starts it ("HP LaserJet MFP M234dw (95BE5B)").
    /// Null when nothing matches or the name is ambiguous.
    /// </summary>
    public static DeskPrinter? Match(QueueInfo queue, DeskPrinters known)
    {
        var printers = known.Printers;
        if (printers.Count == 0 || string.IsNullOrWhiteSpace(queue.Name)) return null;

        foreach (var (uuid, name) in known.QueueNames)
            if (string.Equals(name, queue.Name, StringComparison.OrdinalIgnoreCase) && ByUuid(printers, uuid) is { } stored)
                return stored;

        if (queue.ContainerId is { Length: > 0 } container && ByUuid(printers, container) is { } byContainer)
            return byContainer;

        if (queue.PortName is { Length: > 0 } port)
        {
            var hosts = HostsIn(port);
            var byHost = printers.Where(p => hosts.Contains(p.Host) || (p.EsclRoot is { } e && hosts.Contains(e.Host))).ToList();
            if (byHost.Count == 1) return byHost[0];
        }

        var byName = printers.Where(p => StartsWithWord(queue.Name, p.Name) || (p.Model is { Length: > 0 } m && StartsWithWord(queue.Name, m))).ToList();
        return byName.Count == 1 ? byName[0] : null;
    }

    private static DeskPrinter? ByUuid(IReadOnlyList<DeskPrinter> printers, string uuid)
    {
        var id = Normalize(uuid);
        return id is null ? null : printers.FirstOrDefault(p => Normalize(p.Uuid) == id);
    }

    private static string? Normalize(string uuid)
    {
        var raw = uuid.Trim().Trim('{', '}');
        if (raw.StartsWith("urn:uuid:", StringComparison.OrdinalIgnoreCase)) raw = raw[9..];
        return Guid.TryParse(raw, out var g) ? g.ToString("D") : null;
    }

    /// <summary>Host names and IPv4 addresses mentioned in a port name: "IP_192.168.1.5", "192.168.1.5_1", "http://host:631/ipp/print".</summary>
    internal static HashSet<string> HostsIn(string port)
    {
        var hosts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (Uri.TryCreate(port, UriKind.Absolute, out var uri) && uri.Host.Length > 0 && !uri.IsFile) hosts.Add(uri.Host);
        foreach (Match m in Ipv4().Matches(port)) hosts.Add(m.Value);
        var bare = port.Trim();
        if (bare.StartsWith("IP_", StringComparison.OrdinalIgnoreCase)) bare = bare[3..];
        if (Uri.CheckHostName(bare) is UriHostNameType.Dns or UriHostNameType.IPv4) hosts.Add(bare);
        return hosts;
    }

    /// <summary>"<paramref name="prefix"/>" starts <paramref name="text"/> and ends there or at a non-alphanumeric character.</summary>
    private static bool StartsWithWord(string text, string prefix) =>
        prefix.Length > 0 && text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
        (text.Length == prefix.Length || !char.IsLetterOrDigit(text[prefix.Length]));

    [GeneratedRegex(@"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")]
    private static partial Regex Ipv4();
}
