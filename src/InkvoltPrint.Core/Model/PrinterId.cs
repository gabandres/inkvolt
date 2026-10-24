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

    // The salt keeps the app's pre-rename name on purpose: changing it would change the id of every printer added by
    // address, orphaning its saved queue, certificate pin and password.
    private static string FromHost(string host) =>
        new Guid(MD5.HashData(Encoding.UTF8.GetBytes("printdesk-host:" + host.Trim().ToLowerInvariant()))).ToString("D");

    /// <summary>Safe file name for per-printer caches (never contains path characters).</summary>
    public static string FileName(string uuid) =>
        Guid.TryParse(uuid, out var g) ? g.ToString("N") : Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(uuid)))[..32];
}
