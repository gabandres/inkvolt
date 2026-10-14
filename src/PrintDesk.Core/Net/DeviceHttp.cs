using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Text;

namespace PrintDesk.Core.Net;

/// <summary>
/// One HTTP client per printer. Timeouts are per request (never shared mutable state), and
/// self-signed certificates are accepted only for this printer's host, never process-wide.
/// </summary>
public sealed class DeviceHttp : IDisposable
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(5);

    private readonly HttpClient _client;
    private string? _basicAuth;

    public DeviceHttp(string host, HttpMessageHandler? handler = null)
    {
        Host = host;
        HttpBase = new UriBuilder(Uri.UriSchemeHttp, host).Uri;
        HttpsBase = new UriBuilder(Uri.UriSchemeHttps, host).Uri;
        _client = new HttpClient(handler ?? CreateHandler(host), disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
        _client.DefaultRequestHeaders.ExpectContinue = false;
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
        CancellationToken ct = default, HttpCompletionOption completion = HttpCompletionOption.ResponseContentRead)
    {
        if (_basicAuth is not null && request.RequestUri?.Scheme == Uri.UriSchemeHttps)
            request.Headers.Authorization = new AuthenticationHeaderValue("Basic", _basicAuth);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? DefaultTimeout);
        try
        {
            return await _client.SendAsync(request, completion, cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TimeoutException($"{request.Method} {request.RequestUri} timed out");
        }
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
            await SafeReadAsync(resp).ConfigureAwait(false));
    }

    private static async Task<string?> SafeReadAsync(HttpResponseMessage resp)
    {
        try { var s = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); return s.Length > 300 ? s[..300] : s; }
        catch { return null; }
    }

    private static SocketsHttpHandler CreateHandler(string host) => new()
    {
        ConnectTimeout = TimeSpan.FromSeconds(3),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        MaxConnectionsPerServer = 4,
        AllowAutoRedirect = false,
        UseProxy = false,
        AutomaticDecompression = DecompressionMethods.None,
        SslOptions = new SslClientAuthenticationOptions
        {
            // Printers ship self-signed certs. Accept them for this printer only.
            RemoteCertificateValidationCallback = (sender, _, _, errors) =>
                errors == SslPolicyErrors.None || string.Equals(TargetHost(sender), host, StringComparison.OrdinalIgnoreCase),
        },
    };

    private static string? TargetHost(object sender) => sender is SslStream s ? s.TargetHostName : null;

    public void Dispose() => _client.Dispose();
}

public sealed class DeviceHttpException(HttpStatusCode status, HttpMethod? method, Uri? uri, string? body)
    : Exception($"{method} {uri?.PathAndQuery} returned {(int)status} {status}")
{
    public HttpStatusCode Status { get; } = status;
    public string? Body { get; } = body;
}
