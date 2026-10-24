using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Discovery;

/// <summary>One DNS-SD service a printer advertises (<c>_ipp._tcp</c>, <c>_ipps._tcp</c>, <c>_uscan._tcp</c>, <c>_uscans._tcp</c>).</summary>
public sealed record DnssdService(string? Service, string? Uuid, string? HostName, string? IPv4, int? Port, IReadOnlyDictionary<string, string> Txt);

/// <summary>
/// How a printer's DNS-SD services are joined into one printer, and where its IPP and eSCL endpoints are. IPP Everywhere
/// and Mopria printers publish a <c>UUID</c> TXT key on every service; some leave it out of one of them.
/// </summary>
public static class DnssdJoin
{
    /// <summary>
    /// The printer id a service belongs to: its UUID; without one, the UUID another service on the same host publishes.
    /// Null when neither has one: such a printer is left out until a sibling shows up (giving it an address-derived id
    /// now would leave a duplicate once the UUID arrives); it can still be added by address.
    /// </summary>
    public static string? Key(DnssdService s, IEnumerable<DnssdService> all)
    {
        if (PrinterId.IsValid(Clean(s.Uuid))) return PrinterId.Normalize(s.Uuid, "");
        var sibling = all.FirstOrDefault(o => PrinterId.IsValid(Clean(o.Uuid)) && SameHost(o, s));
        return sibling is null ? null : PrinterId.Normalize(sibling.Uuid, "");
    }

    /// <summary>
    /// The IPP printer URL from an <c>_ipp</c>/<c>_ipps</c> service: its port (631 by default) and the <c>rp</c> TXT resource
    /// path (<c>ipp/print</c> by default, as IPP Everywhere requires). https for <c>_ipps</c>. Null for a path that tries to
    /// leave the root or carries a query.
    /// </summary>
    public static Uri? IppUri(DnssdService s, string host)
    {
        var rp = s.Txt.TryGetValue("rp", out var v) ? v.Trim('/') : "ipp/print";
        if (!SafePath(rp)) return null;
        var https = s.Service == "_ipps._tcp";
        return new UriBuilder(https ? Uri.UriSchemeHttps : Uri.UriSchemeHttp, host, s.Port ?? 631, rp).Uri;
    }

    /// <summary>The eSCL root from a <c>_uscan</c>/<c>_uscans</c> service: its port and the <c>rs</c> TXT path (<c>eSCL</c> by default).</summary>
    public static Uri? EsclRoot(DnssdService s, string host)
    {
        var rs = s.Txt.TryGetValue("rs", out var v) ? v.Trim('/') : "eSCL";
        if (!SafePath(rs)) return null;
        var https = s.Service == "_uscans._tcp";
        var scheme = https ? Uri.UriSchemeHttps : Uri.UriSchemeHttp;
        return new UriBuilder(scheme, host, s.Port ?? (https ? 443 : 80), rs.Length == 0 ? "" : rs + "/").Uri;
    }

    private static bool SafePath(string path) =>
        !path.Split('/').Any(seg => seg is ".." or ".") && path.IndexOfAny(['?', '#', '\\', ':']) < 0;

    private static string? Clean(string? uuid)
    {
        var raw = uuid?.Trim().Trim('{', '}');
        return raw is not null && raw.StartsWith("urn:uuid:", StringComparison.OrdinalIgnoreCase) ? raw[9..] : raw;
    }

    private static bool SameHost(DnssdService a, DnssdService b) =>
        (a.HostName is not null && string.Equals(a.HostName, b.HostName, StringComparison.OrdinalIgnoreCase))
        || (a.IPv4 is not null && a.IPv4 == b.IPv4);
}
