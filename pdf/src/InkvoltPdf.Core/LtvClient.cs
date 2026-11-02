using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;

namespace InkvoltPdf.Core;

/// <summary>What an address is asked for.</summary>
public enum LtvAddressKind
{
    /// <summary>An OCSP responder a certificate names: receives which certificate is being asked about.</summary>
    Ocsp,
    /// <summary>A CRL address a certificate names: a plain download of the issuer's list.</summary>
    Crl,
    /// <summary>The address of a certificate's issuer, as the certificate names it: a plain download of a public certificate.</summary>
    Issuer,
    /// <summary>The timestamp server the person chose: receives a hash, never the document.</summary>
    Timestamp,
}

/// <summary>One request this run made, for the person to read afterwards. Kept in memory only.</summary>
public sealed record LtvContact(LtvAddressKind Kind, string Url, string Outcome);

/// <summary>A server couldn't be used; the message says why, in the person's words.</summary>
public sealed class LtvFetchException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// The one door through which long-term validation goes online, and only when the person asked. Addresses come from
/// certificates in files, so they are hostile: a file must not be able to make the app probe this PC or its network.
/// <list type="bullet">
/// <item>Only http and https, no user names, plain ASCII host names. A timestamp server must be https.</item>
/// <item>Names and addresses of this PC or a local network are refused before anything is sent, and every address a name
/// resolves to is checked when connecting, on the connection actually made, so DNS rebinding and redirects can't get
/// there either.</item>
/// <item>Redirects are followed by hand, a few at most, each checked again, never from https down to http.</item>
/// <item>Bounded: the time of each request, the size of each reply, the number of requests in a run. No proxy (it would
/// connect on our behalf, out of sight of the checks), cookies, credentials or decompression.</item>
/// </list>
/// </summary>
public sealed class LtvClient : IDisposable
{
    public const int MaxOcspReply = RevocationPool.MaxOcspBytes;
    public const int MaxCrlReply = RevocationPool.MaxCrlBytes;
    public const int MaxCertificateReply = RevocationPool.MaxCertBytes;
    public const int MaxTimestampReply = 256 * 1024;
    private const int MaxRedirects = 3;
    private const int MaxRequests = 48;

    private readonly HttpClient _http;
    private readonly TimeSpan _timeout;
    private readonly bool _allowLoopback;
    private readonly bool _allowHttpTimestamp;
    private readonly List<LtvContact> _contacts = [];
    private int _requests;

    /// <summary>What this client asked so far.</summary>
    public IReadOnlyList<LtvContact> Contacts => _contacts;

    public LtvClient() : this(false)
    {
    }

    /// <param name="allowLoopback">Tests and the dev script only: lets this PC's own loopback through (still no other local address).</param>
    /// <param name="timeout">How long one request may take.</param>
    /// <param name="resolve">Tests only: stands in for DNS.</param>
    /// <param name="allowHttpTimestamp">Tests and the dev script only: a local timestamp server without a certificate.</param>
    internal LtvClient(bool allowLoopback, TimeSpan? timeout = null, Func<string, CancellationToken, Task<IPAddress[]>>? resolve = null, bool allowHttpTimestamp = false)
    {
        _allowLoopback = allowLoopback;
        _allowHttpTimestamp = allowHttpTimestamp;
        _timeout = timeout ?? TimeSpan.FromSeconds(15);
        resolve ??= (host, cancel) => Dns.GetHostAddressesAsync(host, cancel);
        _http = new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            UseProxy = false,
            Credentials = null,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = TimeSpan.FromSeconds(8),
            MaxResponseHeadersLength = 32,
            ConnectCallback = async (context, cancel) =>
            {
                var host = context.DnsEndPoint.Host.TrimStart('[').TrimEnd(']');
                var addresses = IPAddress.TryParse(host, out var literal) ? [literal] : await resolve(host, cancel).ConfigureAwait(false);
                if (addresses.Length == 0) throw new SocketException((int)SocketError.HostNotFound);
                // Any local address among the answers refuses the name: which one a connection ends up on can't be left to chance.
                if (addresses.FirstOrDefault(a => !Allowed(a)) is { } local) throw new LtvFetchException($"{host} points at {Describe(local)}, so it wasn't contacted.");
                var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                try
                {
                    await socket.ConnectAsync(addresses, context.DnsEndPoint.Port, cancel).ConfigureAwait(false);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            },
        })
        {
            Timeout = Timeout.InfiniteTimeSpan, // each request has its own limit, reading the reply included
        };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("InkvoltPdf");
    }

    private bool Allowed(IPAddress ip) => IsPublic(ip) || (_allowLoopback && IPAddress.IsLoopback(ip));

    private static string Describe(IPAddress ip) => IPAddress.IsLoopback(ip) ? "this PC" : "an address on a local network";

    /// <summary>
    /// False for this PC, local and link-local networks, carrier NAT, multicast and reserved ranges, and for the IPv6 forms
    /// that carry such an IPv4 address inside.
    /// </summary>
    public static bool IsPublic(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (AiEndpoint.Classify(ip) != AiReach.Internet) return false;
        var b = ip.GetAddressBytes();
        if (ip.AddressFamily == AddressFamily.InterNetwork)
            return !(b[0] == 0 || b[0] >= 224
                     || (b[0] == 192 && b[1] == 0 && b[2] is 0 or 2)
                     || (b[0] == 198 && b[1] is 18 or 19)
                     || (b[0] == 198 && b[1] == 51 && b[2] == 100)
                     || (b[0] == 203 && b[1] == 0 && b[2] == 113));
        if (ip.AddressFamily != AddressFamily.InterNetworkV6) return false;
        if (ip.IsIPv6Multicast || ip.Equals(IPAddress.IPv6None)) return false;
        if (b.AsSpan(0, 12).IndexOfAnyExcept((byte)0) < 0) return false; // ::a.b.c.d
        if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B) return IsPublic(new IPAddress(b[12..16])); // NAT64
        if (b[0] == 0x20 && b[1] == 0x02) return IsPublic(new IPAddress(b[2..6])); // 6to4
        if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00) return false; // Teredo
        if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8) return false; // documentation
        return true;
    }

    /// <summary>Why <paramref name="url"/> won't be contacted, judged from the address as written; null when it may be.</summary>
    public static string? WhyRefused(string url, LtvAddressKind kind, bool allowLoopback = false, bool allowHttpTimestamp = false)
    {
        if (url.Length > 2048 || !Uri.TryCreate(url, UriKind.Absolute, out var u) || u.Host.Length == 0) return "it isn't a web address";
        if (u.Scheme != Uri.UriSchemeHttp && u.Scheme != Uri.UriSchemeHttps) return $"it isn't a web address ({u.Scheme}:)";
        if (kind == LtvAddressKind.Timestamp && u.Scheme != Uri.UriSchemeHttps && !allowHttpTimestamp) return "a timestamp server must use https://";
        if (u.UserInfo.Length > 0) return "it carries a user name or password";
        // HttpClient connects to the IDNA form of a host, in which look-alikes become real dots and letters: only plain ASCII is taken.
        var authorityStart = url.IndexOf("://", StringComparison.Ordinal) + 3;
        var authorityEnd = url.IndexOfAny(['/', '?', '#'], authorityStart);
        if (u.Host.Any(c => c > 0x7E) || url.AsSpan(authorityStart, (authorityEnd < 0 ? url.Length : authorityEnd) - authorityStart).ContainsAnyExceptInRange((char)0x21, (char)0x7E))
            return "its host name isn't plain letters and digits";
        var host = u.Host.TrimStart('[').TrimEnd(']');
        if (IPAddress.TryParse(host, out var ip))
        {
            if (allowLoopback && IPAddress.IsLoopback(ip)) return null;
            return IsPublic(ip) ? null : $"it points at {Describe(ip)}";
        }
        var reach = AiEndpoint.Classify(host);
        if (reach == AiReach.Internet) return null;
        if (reach == AiReach.ThisPc && allowLoopback) return null;
        return reach == AiReach.ThisPc ? "it points at this PC" : "it points at a local network";
    }

    private string? Refused(string url, LtvAddressKind kind) => WhyRefused(url, kind, _allowLoopback, _allowHttpTimestamp);

    /// <summary>This client won't contact <paramref name="url"/>, by the address as written.</summary>
    public bool Refuses(string url, LtvAddressKind kind) => Refused(url, kind) is not null;

    /// <summary>Why this client won't contact <paramref name="url"/>, by the address as written; null when it will.</summary>
    public string? Why(string url, LtvAddressKind kind) => Refused(url, kind);

    public Task<byte[]> GetAsync(string url, LtvAddressKind kind, int maxBytes, CancellationToken cancel = default) =>
        SendAsync(url, kind, null, null, maxBytes, cancel);

    public Task<byte[]> PostAsync(string url, LtvAddressKind kind, string contentType, byte[] body, int maxBytes, CancellationToken cancel = default) =>
        SendAsync(url, kind, contentType, body, maxBytes, cancel);

    /// <summary>The RFC 3161 exchange with a timestamp server: posts the request (a hash only), returns the reply.</summary>
    public Func<byte[], CancellationToken, Task<byte[]>> TimestampSender(string url) => (request, cancel) =>
        PostAsync(url, LtvAddressKind.Timestamp, "application/timestamp-query", request, MaxTimestampReply, cancel);

    private async Task<byte[]> SendAsync(string url, LtvAddressKind kind, string? contentType, byte[]? body, int maxBytes, CancellationToken cancel)
    {
        var first = url;
        try
        {
            for (var hop = 0; ; hop++)
            {
                if (Refused(url, kind) is { } why) throw new LtvFetchException($"{url} wasn't contacted: {why}.");
                if (++_requests > MaxRequests) throw new LtvFetchException("This would take more requests than a check should.");
                using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                limit.CancelAfter(_timeout);
                using var request = new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post, new Uri(url));
                if (body is not null)
                {
                    request.Content = new ByteArrayContent(body);
                    request.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType!);
                }
                using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, limit.Token).ConfigureAwait(false);
                if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
                {
                    if (hop >= MaxRedirects) throw new LtvFetchException($"{Host(first)} redirected too many times.");
                    if (body is not null && (int)response.StatusCode is not (307 or 308)) throw new LtvFetchException($"{Host(first)} answered with a redirect that drops the request.");
                    if (response.Headers.Location is not { } location) throw new LtvFetchException($"{Host(first)} sent a redirect that leads nowhere.");
                    var next = location.IsAbsoluteUri ? location : new Uri(new Uri(url), location);
                    if (new Uri(url).Scheme == Uri.UriSchemeHttps && next.Scheme != Uri.UriSchemeHttps) throw new LtvFetchException($"{Host(first)} redirected from https to an address that isn't.");
                    url = next.AbsoluteUri;
                    continue;
                }
                if (!response.IsSuccessStatusCode) throw new LtvFetchException($"{Host(url)} answered with an error ({(int)response.StatusCode}).");
                if (response.Content.Headers.ContentLength > maxBytes) throw new LtvFetchException($"{Host(url)} sent more than the {maxBytes / 1024} KB allowed.");
                var bytes = await ReadCapped(response, maxBytes, url, limit.Token).ConfigureAwait(false);
                _contacts.Add(new LtvContact(kind, first, $"answered ({bytes.Length:N0} bytes)"));
                return bytes;
            }
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException ex)
        {
            throw Failed(kind, first, new LtvFetchException($"{Host(url)} didn't answer in time.", ex));
        }
        catch (LtvFetchException ex)
        {
            throw Failed(kind, first, ex);
        }
        catch (IOException ex)
        {
            // The connection broke while the reply was being read.
            throw Failed(kind, first, new LtvFetchException($"{Host(url)} stopped answering.", ex));
        }
        catch (HttpRequestException ex)
        {
            // A refusal from the connection's own check arrives wrapped.
            for (Exception? e = ex; e is not null; e = e.InnerException)
                if (e is LtvFetchException refused) throw Failed(kind, first, refused);
            throw Failed(kind, first, new LtvFetchException($"{Host(url)} can't be reached. Check that this PC is online.", ex));
        }
    }

    private LtvFetchException Failed(LtvAddressKind kind, string url, LtvFetchException ex)
    {
        _contacts.Add(new LtvContact(kind, url, ex.Message));
        return ex;
    }

    private static async Task<byte[]> ReadCapped(HttpResponseMessage response, int maxBytes, string url, CancellationToken cancel)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(cancel).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        while (true)
        {
            var n = await stream.ReadAsync(chunk, cancel).ConfigureAwait(false);
            if (n == 0) return buffer.ToArray();
            if (buffer.Length + n > maxBytes) throw new LtvFetchException($"{Host(url)} sent more than the {maxBytes / 1024} KB allowed.");
            buffer.Write(chunk, 0, n);
        }
    }

    internal static string Host(string url) => Uri.TryCreate(url, UriKind.Absolute, out var u) && u.Host.Length > 0 ? u.Host : url;

    public void Dispose() => _http.Dispose();
}
