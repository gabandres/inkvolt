using System.Security.Cryptography;
using System.Text;

namespace InkvoltPrint.Core.Model;

/// <summary>
/// Printer identities arrive from the network (mDNS TXT, HTTP replies), so they are untrusted text. Everything the
/// app stores or builds paths from is normalised to a GUID here.
/// </summary>
public static class PrinterId
{
    /// <summary>The printer's UUID if it is one; otherwise a stable GUID derived from its address.</summary>
    public static string Normalize(string? uuid, string host)
    {
        var raw = uuid?.Trim().Trim('{', '}');
        if (raw is not null && raw.StartsWith("urn:uuid:", StringComparison.OrdinalIgnoreCase)) raw = raw[9..];
        return Guid.TryParse(raw, out var g) ? g.ToString("D") : FromHost(host);
    }

    public static bool IsValid(string? uuid) => Guid.TryParse(uuid, out _);

    /// <summary>
    /// Whether the device answering at <paramref name="host"/> is the printer known as <paramref name="id"/>, from the UUIDs it
    /// reports (<see cref="Probe.ProbeResult.ReportedUuids"/>). Same when any of them is the id; Different when it reports
    /// UUIDs and none is; Unknown when it reports none, or the id was made from the address (a printer without a UUID).
    /// </summary>
    public static DeviceIdentity Identify(string id, string host, IEnumerable<string?> reported)
    {
        if (string.Equals(id, FromHost(host), StringComparison.OrdinalIgnoreCase)) return DeviceIdentity.Unknown;
        var uuids = reported.Where(u => !string.IsNullOrWhiteSpace(u)).Select(u => Normalize(u, host)).Where(u => u != FromHost(host)).ToList();
        if (uuids.Count == 0) return DeviceIdentity.Unknown;
        return uuids.Contains(Normalize(id, host), StringComparer.OrdinalIgnoreCase) ? DeviceIdentity.Same : DeviceIdentity.Different;
    }

    // The salt keeps the app's pre-rename name on purpose: changing it would change the id of every printer added by
    // address, orphaning its saved queue, certificate pin and password.
    private static string FromHost(string host) =>
        new Guid(MD5.HashData(Encoding.UTF8.GetBytes("printdesk-host:" + host.Trim().ToLowerInvariant()))).ToString("D");

    /// <summary>Safe file name for per-printer caches (never contains path characters).</summary>
    public static string FileName(string uuid) =>
        Guid.TryParse(uuid, out var g) ? g.ToString("N") : Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(uuid)))[..32];
}

/// <summary>Who answers at a remembered printer's address.</summary>
public enum DeviceIdentity
{
    /// <summary>The printer reports no UUID (or was remembered without one): can't tell.</summary>
    Unknown,

    /// <summary>It reports the remembered UUID.</summary>
    Same,

    /// <summary>It reports other UUIDs only: another device has the address.</summary>
    Different,
}
