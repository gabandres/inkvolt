using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace InkvoltPrint.Core.Net;

/// <summary>
/// One HTTP client per printer. Timeouts are per request (never shared mutable state), and
/// self-signed certificates are accepted only for this printer's host, never process-wide.
/// </summary>
public sealed class DeviceHttp : IDisposable
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(5);

    private readonly HttpClient _client;
    private readonly bool _ownTransport;
    private readonly ICertificatePin? _pin;
    private readonly Dictionary<int, HttpClient> _tls = [];
    private string? _basicAuth;

    public DeviceHttp(string host, HttpMessageHandler? handler = null, ICertificatePin? pin = null)
    {
        Host = host;
        _pin = pin;
        _ownTransport = handler is not null;
        HttpBase = new UriBuilder(Uri.UriSchemeHttp, host).Uri;
        HttpsBase = new UriBuilder(Uri.UriSchemeHttps, host).Uri;
        _client = NewClient(handler ?? CreateHandler(host, (c, e) => ValidateCertificate(c, e, HttpsBase.Port)));
    }

    private static HttpClient NewClient(HttpMessageHandler handler)
    {
        var client = new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.ExpectContinue = false;
        return client;
    }

    /// <summary>
    /// HTTPS gets one client per port, so each handshake is checked against that port's pin (the TLS callback can't tell
    /// ports apart). Plain HTTP and replaced transports (demo, tests) use the one client.
    /// </summary>
    private HttpClient ClientFor(Uri? uri)
    {
        if (_ownTransport || uri is not { Scheme: "https" }) return _client;
        lock (_tls)
        {
            if (!_tls.TryGetValue(uri.Port, out var client))
            {
                var port = uri.Port;
                _tls[port] = client = NewClient(CreateHandler(Host, (c, e) => ValidateCertificate(c, e, port)));
            }
            return client;
        }
    }

    public string Host { get; }
    public Uri HttpBase { get; }
    public Uri HttpsBase { get; }
    public bool HasCredentials => _basicAuth is not null;

    /// <summary>EWS admin credentials. Only ever sent over HTTPS.</summary>
    public void SetCredentials(string user, string password) =>
        _basicAuth = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{user}:{password}"));

    public void ClearCredentials() => _basicAuth = null;

    public Uri Http(string path) => new(HttpBase, path);
    public Uri Https(string path) => new(HttpsBase, path);

    public async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, TimeSpan? timeout = null,
        CancellationToken ct = default, HttpCompletionOption completion = HttpCompletionOption.ResponseContentRead) =>
        await SendAsync(ClientFor(request.RequestUri), request, timeout, ct, completion).ConfigureAwait(false);

    private async Task<HttpResponseMessage> SendAsync(HttpClient client, HttpRequestMessage request, TimeSpan? timeout,
        CancellationToken ct, HttpCompletionOption completion)
    {
        // The admin password belongs to the web server (HTTPS on 443), never to another TLS port such as IPPS on 631.
        if (_basicAuth is not null && request.RequestUri is { Scheme: "https" } target && target.Port == HttpsBase.Port)
            request.Headers.Authorization = new AuthenticationHeaderValue("Basic", _basicAuth);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? DefaultTimeout);
        try
        {
            return await client.SendAsync(request, completion, cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException($"{request.Method} {request.RequestUri} timed out");
        }
    }

    /// <summary>
    /// A request that changes something on the printer and must never arrive twice (a maintenance POST: a second cleaning
    /// uses ink twice). .NET's connection pool resends a request on its own when a connection closes before any answer
    /// (seen on loopback for bodiless requests, also on fresh connections, up to three more times). So this one gets a
    /// handler of its own that never pools (<c>Connection: close</c>, no connection lifetime) and opens exactly one
    /// connection: a second connect, which only a resend would need, fails before anything is written. Same certificate
    /// checks and credentials rule as <see cref="SendAsync"/>; the response is read in full before the handler goes away.
    /// A replaced transport (demo, tests) gets the request as is, marked <c>Connection: close</c>.
    /// </summary>
    public async Task<HttpResponseMessage> SendOnceAsync(HttpRequestMessage request, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        request.Headers.ConnectionClose = true;
        if (_ownTransport) return await SendAsync(request, timeout, ct).ConfigureAwait(false);
        var port = request.RequestUri?.Port ?? HttpsBase.Port;
        var handler = CreateHandler(Host, (c, e) => ValidateCertificate(c, e, port));
        handler.PooledConnectionLifetime = TimeSpan.Zero;
        handler.MaxConnectionsPerServer = 1;
        var connects = 0;
        handler.ConnectCallback = async (context, token) =>
        {
            if (Interlocked.Increment(ref connects) > 1)
                throw new InvalidOperationException("Not sent again: a request that changes the printer goes out once.");
            var socket = new System.Net.Sockets.Socket(System.Net.Sockets.SocketType.Stream, System.Net.Sockets.ProtocolType.Tcp) { NoDelay = true };
            try
            {
                await socket.ConnectAsync(context.DnsEndPoint, token).ConfigureAwait(false);
                return new System.Net.Sockets.NetworkStream(socket, ownsSocket: true);
            }
            catch
            {
                socket.Dispose();
                throw;
            }
        };
        using var once = NewClient(handler);
        return await SendAsync(once, request, timeout, ct, HttpCompletionOption.ResponseContentRead).ConfigureAwait(false);
    }

    public async Task<HttpResponseMessage> GetAsync(Uri uri, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, uri);
        return await SendAsync(req, timeout, ct).ConfigureAwait(false);
    }

    /// <summary>GET returning the body, or null on 404. Other failures throw.</summary>
    public async Task<byte[]?> GetBytesOrNullAsync(Uri uri, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        using var resp = await GetAsync(uri, timeout, ct).ConfigureAwait(false);
        if (resp.StatusCode == HttpStatusCode.NotFound) return null;
        await EnsureSuccessAsync(resp).ConfigureAwait(false);
        return await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
    }

    public static async Task EnsureSuccessAsync(HttpResponseMessage resp)
    {
        if (resp.IsSuccessStatusCode) return;
        throw new DeviceHttpException(resp.StatusCode, resp.RequestMessage?.Method, resp.RequestMessage?.RequestUri,
            await SafeReadAsync(resp).ConfigureAwait(false), resp.Headers.Location);
    }

    private static async Task<string?> SafeReadAsync(HttpResponseMessage resp)
    {
        try { var s = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); return s.Length > 300 ? s[..300] : s; }
        catch { return null; }
    }

    /// <summary>
    /// Printers use self-signed certificates, so CA validation is meaningless. Instead the first certificate seen
    /// for a printer is remembered (trust on first use) and any later different certificate is refused, so a
    /// machine impersonating the printer on the LAN can't collect the admin password. Pins are per port: a printer
    /// may use one certificate for its web server (443) and another for IPPS (631).
    /// </summary>
    internal bool ValidateCertificate(X509Certificate? cert, SslPolicyErrors errors, int port = 443)
    {
        if (cert is null) return false;
        if (_pin is null) return true; // unpinned probe: never carries credentials
        var thumb = Convert.ToHexString(SHA256.HashData(cert.GetRawCertData()));
        var known = _pin.Get(port);
        if (known is null)
        {
            // Two first handshakes can race: whichever pin is stored first wins, and both are checked against it.
            known = _pin.SetIfAbsent(port, thumb);
        }
        if (string.Equals(known, thumb, StringComparison.OrdinalIgnoreCase)) return true;
        CertificateChanged = true;
        return false;
    }

    /// <summary>True after a connection was refused because the printer's certificate no longer matches the pin.</summary>
    public bool CertificateChanged { get; private set; }

    /// <summary>Call after the pin was cleared on purpose (the user chose to trust the new certificate).</summary>
    public void ResetCertificateChanged() => CertificateChanged = false;

    private static SocketsHttpHandler CreateHandler(string host, Func<X509Certificate?, SslPolicyErrors, bool> validate) => new()
    {
        ConnectTimeout = TimeSpan.FromSeconds(3),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        MaxConnectionsPerServer = 4,
        AllowAutoRedirect = false,
        UseProxy = false,
        AutomaticDecompression = DecompressionMethods.None,
        SslOptions = new SslClientAuthenticationOptions
        {
            RemoteCertificateValidationCallback = (sender, cert, _, errors) =>
                string.Equals(TargetHost(sender), host, StringComparison.OrdinalIgnoreCase) && validate(cert, errors),
        },
    };

    /// <summary>
    /// The network as an unpinned connection reaches it (any certificate the printer at <paramref name="host"/> shows, for
    /// that host only), for a caller that wraps it: <see cref="Recording.PrinterRecorder"/> sees every reply this way. Never
    /// used with credentials.
    /// </summary>
    public static HttpMessageHandler NetworkHandler(string host) => CreateHandler(host, (cert, _) => cert is not null);

    private static string? TargetHost(object sender) => sender is SslStream s ? s.TargetHostName : null;

    public void Dispose()
    {
        _client.Dispose();
        lock (_tls)
        {
            foreach (var c in _tls.Values) c.Dispose();
            _tls.Clear();
        }
    }
}

/// <summary>Remembered certificate fingerprints for one printer, one per TLS port.</summary>
public interface ICertificatePin
{
    string? Get(int port);

    /// <summary>Stores the fingerprint for <paramref name="port"/> unless one is already stored; returns the stored value.</summary>
    string SetIfAbsent(int port, string sha256Hex);
}

/// <summary>Where a printer's pin for a port is stored.</summary>
public static class CertificatePinKey
{
    /// <summary>
    /// The printer id for 443 (pins stored before they were per port were all for the web server on 443, so they stay
    /// valid), <c>id:port</c> for any other port.
    /// </summary>
    public static string For(string printerId, int port) => port == 443 ? printerId : $"{printerId}:{port}";

    /// <summary>The stored key is one of <paramref name="printerId"/>'s pins (any port).</summary>
    public static bool Belongs(string key, string printerId) =>
        string.Equals(key, printerId, StringComparison.OrdinalIgnoreCase) || key.StartsWith(printerId + ":", StringComparison.OrdinalIgnoreCase);
}

public sealed class DeviceHttpException(HttpStatusCode status, HttpMethod? method, Uri? uri, string? body, Uri? location = null)
    : Exception($"{method} {uri?.PathAndQuery} returned {(int)status} {status}")
{
    public HttpStatusCode Status { get; } = status;
    public string? Body { get; } = body;

    /// <summary>A redirect's <c>Location</c> (redirects aren't followed), as the printer sent it.</summary>
    public Uri? Location { get; } = location;
}
