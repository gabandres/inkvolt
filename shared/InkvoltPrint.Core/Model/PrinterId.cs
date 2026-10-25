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
    public static DeviceIdentity Identify(string id, string host, IEnumerable<string?> reported) => Identify(id, [], host, reported);

    /// <summary>
    /// <see cref="Identify(string, string, IEnumerable{string?})"/>, also accepting <paramref name="accepted"/>: UUIDs the user
    /// confirmed are this printer's ("This is my printer", after a repair or reset gave it a new one).
    /// </summary>
    public static DeviceIdentity Identify(string id, IEnumerable<string> accepted, string host, IEnumerable<string?> reported)
    {
        if (string.Equals(id, FromHost(host), StringComparison.OrdinalIgnoreCase)) return DeviceIdentity.Unknown;
        var uuids = Valid(reported, host);
        if (uuids.Count == 0) return DeviceIdentity.Unknown;
        var known = accepted.Append(id).Select(k => Normalize(k, host)).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return uuids.Any(known.Contains) ? DeviceIdentity.Same : DeviceIdentity.Different;
    }

    /// <summary>The real UUIDs among <paramref name="reported"/>, normalised (blank and malformed ones left out).</summary>
    public static IReadOnlyList<string> Valid(IEnumerable<string?> reported, string host) =>
        reported.Where(u => !string.IsNullOrWhiteSpace(u)).Select(u => Normalize(u, host)).Where(u => u != FromHost(host))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    /// <summary>
    /// mDNS announces a known printer at <c>new</c> address while it's used at another (perhaps typed by the user). Move when
    /// the new address answers with the printer's UUID; never when it answers as another device. When the new address can't
    /// tell (no answer, or no UUID), keep the address in use only if it answers as the same kind of device (its model matches
    /// the announced one, or nothing was announced); otherwise move, as discovery always did.
    /// </summary>
    public static bool ShouldMove(DeviceIdentity atNew, bool currentAnswers, string? currentModel, string? announcedModel) => atNew switch
    {
        DeviceIdentity.Same => true,
        DeviceIdentity.Different => false,
        _ => !(currentAnswers && SameKind(currentModel, announcedModel)),
    };

    /// <summary>Same model, loosely: case, spaces and punctuation ignored, and one name may extend the other ("M234dw" / "MFP M234dw").</summary>
    public static bool SameKind(string? model, string? announced)
    {
        if (string.IsNullOrWhiteSpace(announced)) return true; // nothing to compare against: the answering device stands
        if (string.IsNullOrWhiteSpace(model)) return false;
        static string Key(string s) => new(s.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
        var (a, b) = (Key(model), Key(announced));
        return a.Length > 0 && b.Length > 0 && (a.Contains(b) || b.Contains(a));
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
