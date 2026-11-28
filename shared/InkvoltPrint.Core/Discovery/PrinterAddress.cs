using System.Net;
using System.Net.Sockets;

namespace InkvoltPrint.Core.Discovery;

/// <summary>
/// What an address typed into Add a printer means: the printer's host and, when it names an IPP printer of its own (an
/// <c>ipp://</c> or <c>ipps://</c> URL, or a port given), the IPP URL to ask first. A plain web address (the printer's web
/// page) is just its host; one on a port of its own (<c>http://host:8080/</c>) is also where its web server is (<see cref="Web"/>:
/// HP's LEDM and CDM, its pages), as well as an IPP server to try. <see cref="Error"/> says why it isn't an address.
/// A link-local IPv6 address keeps its zone (the network interface after "%", typed "%25" as RFC 6874 has it, or "%" as
/// ipconfig shows it): the host is <c>fe80::1%12</c>, and the URLs made from it hold the zone where .NET keeps one
/// (<see cref="Uri.IdnHost"/>, what a connection uses; .NET's <see cref="Uri.Host"/> and AbsoluteUri drop it), written
/// "%25" by <see cref="UrlText"/> (as the Mac's <c>PrinterAddress.urlHost</c>).
/// </summary>
public sealed record PrinterAddress(string? Host, Uri? Ipp, string? Error)
{
    /// <summary>The printer's web server when it isn't on port 80 or 443 (<see cref="WebRoot"/>); null otherwise.</summary>
    public Uri? Web { get; init; }

    /// <summary>
    /// A web address's scheme and port as the root of a printer's web server on <paramref name="host"/>, when that port isn't
    /// the scheme's default; null for a default port, another scheme or anything that isn't a web address. Only the scheme and
    /// port are taken: a printer's web server is on the printer, whatever host a link or announcement names.
    /// </summary>
    public static Uri? WebRoot(Uri? url, string host) =>
        url is { IsAbsoluteUri: true, Scheme: "http" or "https" } && !url.IsDefaultPort && url.Port is > 0 and <= 65535
        && BuilderHost(host) is { } h && (h.Contains('%') || Uri.CheckHostName(h) != UriHostNameType.Unknown)
            ? new UriBuilder(url.Scheme, h, url.Port, "/").Uri : null;

    // ── IPv6 zones ──

    /// <summary>The longest zone kept: an interface's name or number is far shorter.</summary>
    private const int MaxZone = 64;

    /// <summary>
    /// A host as <see cref="UriBuilder"/> takes it: brackets off an IPv6 literal, its zone (when valid) raw after "%", so the
    /// URL keeps it (<see cref="Uri.IdnHost"/>); null for a zone that isn't one or a host no URL can hold.
    /// </summary>
    public static string? BuilderHost(string host)
    {
        var bare = host.Length > 1 && host[0] == '[' && host[^1] == ']' ? host[1..^1] : host;
        var (address, zone, hasZone) = SplitZone(bare);
        if (hasZone) return zone is null || !IsIpv6(address) ? null : $"{address}%{zone}";
        return Uri.TryCreate($"http://{(IsIpv6(bare) ? $"[{bare}]" : bare)}/", UriKind.Absolute, out var url) && url.AbsolutePath == "/" ? bare : null;
    }

    /// <summary>
    /// "fe80::1%25en0", "fe80::1%en0" or "fe80::1%12": the address and its zone, "%25" read as RFC 6874's escaped "%" when
    /// something follows it. "%25" alone is interface 25, as ipconfig shows an interface's number (the owner's call: an empty
    /// zone escaped is nothing anyone types; "%2512" stays the escaped form of interface 12). The zone is null when it is empty, too long, or holds a character outside RFC 6874's unreserved ones (letters,
    /// digits, "-", ".", "_", "~").
    /// </summary>
    private static (string Address, string? Zone, bool HasZone) SplitZone(string host)
    {
        var pct = host.IndexOf('%');
        if (pct < 0) return (host, null, false);
        var zone = host[(pct + 1)..];
        if (zone.Length > 2 && zone.StartsWith("25", StringComparison.Ordinal))
        {
            try
            {
                zone = Uri.UnescapeDataString(zone[2..]);
            }
            catch (UriFormatException)
            {
                zone = "";
            }
        }
        var valid = zone.Length is > 0 and <= MaxZone && zone.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '.' or '_' or '~');
        return (host[..pct], valid ? zone : null, true);
    }

    private static bool IsIpv6(string address) => IPAddress.TryParse(address, out var ip) && ip.AddressFamily == AddressFamily.InterNetworkV6;

    /// <summary>
    /// A host as a URL writes it: an IPv6 address in brackets, its zone "%25" (<c>[fe80::1%25en0]</c>); other hosts as
    /// they are. Null for a zone that isn't one.
    /// </summary>
    public static string? UrlHost(string host)
    {
        var bare = host.Length > 1 && host[0] == '[' && host[^1] == ']' ? host[1..^1] : host;
        var (address, zone, hasZone) = SplitZone(bare);
        if (hasZone) return zone is null || !IsIpv6(address) ? null : $"[{address}%25{zone}]";
        return IsIpv6(bare) ? $"[{bare}]" : host;
    }

    /// <summary>
    /// The host a URL names with the zone .NET keeps for it (<c>fe80::1%en0</c>; the brackets of an IPv6 address without
    /// one, as <see cref="Uri.Host"/>); null for a zone that isn't one.
    /// </summary>
    public static string? HostOf(Uri url)
    {
        var idn = url.IdnHost;
        if (!idn.Contains('%')) return url.Host;
        var (address, zone, _) = SplitZone(idn);
        return zone is null || !IsIpv6(address) ? null : $"{address}%{zone}";
    }

    /// <summary>A URL as text, an IPv6 zone written "%25" (<c>http://[fe80::1%25en0]:631/ipp/print</c>): what is kept or shown.</summary>
    public static string UrlText(Uri url) =>
        url.IdnHost.Contains('%') && HostOf(url) is { } zoned && UrlHost(zoned) is { } written
            ? url.AbsoluteUri.Replace(url.Host, written, StringComparison.Ordinal) : url.AbsoluteUri;

    /// <summary>
    /// A URL kept as <see cref="UrlText"/> wrote it, read back with its zone where .NET keeps it; null when it isn't one,
    /// or its zone isn't one.
    /// </summary>
    public static Uri? ReadUrl(string? text)
    {
        if (!Uri.TryCreate(text, UriKind.Absolute, out var url)) return null;
        if (!url.IdnHost.Contains('%')) return url;
        return HostOf(url) is { } zoned ? new UriBuilder(url) { Host = zoned }.Uri : null;
    }

    /// <summary>
    /// The IPP URL a Windows queue is made from for a printer added by address on <paramref name="host"/> (Add-Printer's
    /// <c>-IppURL</c>, or Settings' "Add a printer using an IP address or hostname"): the one it answered on, when that is over
    /// http on the same host (its port and path kept); IPP Everywhere's on 631 otherwise. An IPv6 zone is kept on both.
    /// </summary>
    public static Uri SetupUrl(Uri? known, string host) =>
        known is { IsAbsoluteUri: true, Scheme: "http" } && HostOf(known) is { } knownHost
        && BuilderHost(knownHost) is { } a && BuilderHost(host) is { } b && string.Equals(a, b, StringComparison.OrdinalIgnoreCase)
            ? known : IppUrl(Uri.UriSchemeHttp, host, 631, "/");

    /// <summary>
    /// The http(s) form Windows' <c>Add-Printer -IppURL</c> takes: ipp → http, ipps → https (RFC 7472), on 631 unless another
    /// port is given; an IPv6 zone kept (<see cref="UriBuilder"/> made from a URL drops it).
    /// </summary>
    public static Uri HttpForm(Uri ippUrl)
    {
        var scheme = ippUrl.Scheme switch { "ipp" => Uri.UriSchemeHttp, "ipps" => Uri.UriSchemeHttps, _ => null };
        if (scheme is null) return ippUrl;
        var http = new UriBuilder(ippUrl) { Scheme = scheme, Port = ippUrl.IsDefaultPort || ippUrl.Port < 0 ? 631 : ippUrl.Port };
        if (ippUrl.IdnHost.Contains('%') && HostOf(ippUrl) is { } zoned) http.Host = zoned;
        return http.Uri;
    }

    /// <summary>IPP Everywhere's path, for a host and port given without one.</summary>
    private const string IppPath = "/ipp/print";

    public static PrinterAddress Parse(string? typed)
    {
        var text = typed?.Trim() ?? "";
        if (text.Length == 0) return Fail(CoreStrings.Net_TypeAddress);
        if (text.Contains("://", StringComparison.Ordinal))
        {
            if (!Uri.TryCreate(text, UriKind.Absolute, out var url) || url.Host.Length == 0) return Fail(string.Format(CoreStrings.Net_NotValidAddress, text));
            if (HostOf(url) is not { } host) return Fail(string.Format(CoreStrings.Net_NotValidAddress, text)); // a zone that isn't one
            return url.Scheme switch
            {
                "ipp" => FromIpp(url, host, Uri.UriSchemeHttp),
                "ipps" => FromIpp(url, host, Uri.UriSchemeHttps),
                // The printer's web page: its host. On a port of its own, it's the IPP server there.
                "http" or "https" when url.IsDefaultPort => new PrinterAddress(host, null, null),
                // Port 631 or a path under /ipp/ names the IPP server (IPP Everywhere's), not the web server: no web root there.
                "http" or "https" => new PrinterAddress(host, IppUrl(url.Scheme, host, url.Port, url.AbsolutePath), null)
                {
                    Web = url.Port == 631 || url.AbsolutePath.StartsWith("/ipp/", StringComparison.OrdinalIgnoreCase) || url.AbsolutePath == "/ipp"
                        ? null : WebRoot(url, host),
                },
                _ => Fail(CoreStrings.Net_UseAddress),
            };
        }
        if (!Uri.TryCreate("http://" + text, UriKind.Absolute, out var hostPort) || hostPort.Host.Length == 0
            || hostPort.AbsolutePath != "/" || hostPort.Query.Length > 0 || Uri.CheckHostName(hostPort.Host) == UriHostNameType.Unknown
            || HostOf(hostPort) is not { } typedHost)
            return Fail(string.Format(CoreStrings.Net_NotValidAddress, text));
        // host:port names the printer's IPP server; a bare host keeps its spelling (Windows names are shown as typed).
        return hostPort.IsDefaultPort
            ? new PrinterAddress(text.StartsWith('[') ? typedHost : text, null, null)
            : new PrinterAddress(typedHost, IppUrl(Uri.UriSchemeHttp, typedHost, hostPort.Port, "/"), null);
    }

    // ipp:// is IPP over http, ipps:// over https; both default to port 631 (RFC 8010 §4, RFC 7472).
    private static PrinterAddress FromIpp(Uri url, string host, string scheme) =>
        new(host, IppUrl(scheme, host, url.IsDefaultPort || url.Port < 0 ? 631 : url.Port, url.AbsolutePath), null);

    private static Uri IppUrl(string scheme, string host, int port, string path) =>
        new UriBuilder(scheme, BuilderHost(host) ?? host.Trim('[', ']'), port, path is "" or "/" ? IppPath : path).Uri;

    private static PrinterAddress Fail(string why) => new(null, null, why);
}
