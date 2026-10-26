namespace InkvoltPrint.Core.Discovery;

/// <summary>
/// What an address typed into Add a printer means: the printer's host and, when it names an IPP printer of its own (an
/// <c>ipp://</c> or <c>ipps://</c> URL, or a port given), the IPP URL to ask first. A plain web address (the printer's web
/// page) is just its host. <see cref="Error"/> says why it isn't an address.
/// </summary>
public sealed record PrinterAddress(string? Host, Uri? Ipp, string? Error)
{
    /// <summary>IPP Everywhere's path, for a host and port given without one.</summary>
    private const string IppPath = "/ipp/print";

    public static PrinterAddress Parse(string? typed)
    {
        var text = typed?.Trim() ?? "";
        if (text.Length == 0) return Fail("Type the printer's IP address or name.");
        if (text.Contains("://", StringComparison.Ordinal))
        {
            if (!Uri.TryCreate(text, UriKind.Absolute, out var url) || url.Host.Length == 0) return Fail($"\"{text}\" is not a valid address.");
            return url.Scheme switch
            {
                "ipp" => FromIpp(url, Uri.UriSchemeHttp),
                "ipps" => FromIpp(url, Uri.UriSchemeHttps),
                // The printer's web page: its host. On a port of its own, it's the IPP server there.
                "http" or "https" when url.IsDefaultPort => new PrinterAddress(url.Host, null, null),
                "http" or "https" => new PrinterAddress(url.Host, IppUrl(url.Scheme, url.Host, url.Port, url.AbsolutePath), null),
                _ => Fail("Use the printer's IP address or name (or an http, https, ipp or ipps address)."),
            };
        }
        if (!Uri.TryCreate("http://" + text, UriKind.Absolute, out var hostPort) || hostPort.Host.Length == 0
            || hostPort.AbsolutePath != "/" || hostPort.Query.Length > 0 || Uri.CheckHostName(hostPort.Host) == UriHostNameType.Unknown)
            return Fail($"\"{text}\" is not a valid address.");
        // host:port names the printer's IPP server; a bare host keeps its spelling (Windows names are shown as typed).
        return hostPort.IsDefaultPort
            ? new PrinterAddress(text.StartsWith('[') ? hostPort.Host : text, null, null)
            : new PrinterAddress(hostPort.Host, IppUrl(Uri.UriSchemeHttp, hostPort.Host, hostPort.Port, "/"), null);
    }

    // ipp:// is IPP over http, ipps:// over https; both default to port 631 (RFC 8010 §4, RFC 7472).
    private static PrinterAddress FromIpp(Uri url, string scheme) =>
        new(url.Host, IppUrl(scheme, url.Host, url.IsDefaultPort || url.Port < 0 ? 631 : url.Port, url.AbsolutePath), null);

    private static Uri IppUrl(string scheme, string host, int port, string path) =>
        new UriBuilder(scheme, host.Trim('[', ']'), port, path is "" or "/" ? IppPath : path).Uri;

    private static PrinterAddress Fail(string why) => new(null, null, why);
}
