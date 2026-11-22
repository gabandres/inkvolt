using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Authentication;
using InkvoltPrint.Core.Capture;
using InkvoltPrint.Core.Sharing;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Server.Kestrel.Https;

namespace InkvoltPrint.Sharing;

/// <summary>
/// The phone scan page's HTTPS server (roadmap 4.6), with scanner sharing's rules (<see cref="KestrelShareHost"/>): HTTP/1.1 over
/// TLS 1.2 or 1.3 with the share's certificate; a connection from a device <see cref="PhoneListen.AllowPeer"/> refuses is closed
/// before TLS; a few connections per device, a dozen in all; small request lines and headers; a body (a photo) read only when the
/// <see cref="PhoneSession"/> asks for it, at most what it allows, and refused by its declared length before a byte is read. Every
/// request goes to the session, which names no file and lists nothing. No logging of devices. Disposing closes the port at once.
/// </summary>
public sealed class KestrelPhoneHost : IPhoneHost
{
    /// <summary>Connections at once, all devices together, and from one device (a phone's browser opens a few).</summary>
    public const int MaxConnections = 12, MaxConnectionsPerPeer = 6;

    public async Task<IShareListener> StartAsync(PhoneListen listen, CancellationToken ct)
    {
        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions { ApplicationName = typeof(KestrelPhoneHost).Assembly.GetName().Name });
        ListenOptions? endpoint = null;
        var perPeer = new ConcurrentDictionary<IPAddress, int>();
        builder.WebHost.UseKestrelCore().ConfigureKestrel(o =>
        {
            o.AddServerHeader = false;
            o.AllowSynchronousIO = false;
            var limits = o.Limits;
            limits.MaxConcurrentConnections = MaxConnections;
            limits.MaxConcurrentUpgradedConnections = 0;
            limits.MaxRequestBodySize = PhotoInput.MaxBytes;
            limits.MaxRequestBufferSize = 64 * 1024;
            limits.MaxRequestHeaderCount = 40;
            limits.MaxRequestHeadersTotalSize = 16 * 1024;
            limits.MaxRequestLineSize = 2 * 1024;
            limits.KeepAliveTimeout = TimeSpan.FromSeconds(60);
            limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15);
            limits.MinRequestBodyDataRate = new MinDataRate(bytesPerSecond: 1024, gracePeriod: TimeSpan.FromSeconds(10));
            o.Listen(listen.Address, listen.Port, lo =>
            {
                endpoint = lo;
                lo.Protocols = HttpProtocols.Http1;
                // Before TLS: a device that may not connect gets nothing, not even the certificate.
                lo.Use(next => async connection =>
                {
                    if (connection.RemoteEndPoint is not IPEndPoint { Address: var peer } || connection.LocalEndPoint is not IPEndPoint { Address: var local }
                        || !listen.AllowPeer(peer, local)) return;
                    var key = SharePeers.Normal(peer);
                    if (perPeer.AddOrUpdate(key, 1, (_, n) => n + 1) > MaxConnectionsPerPeer)
                    {
                        Leave(perPeer, key);
                        return;
                    }
                    try
                    {
                        await next(connection).ConfigureAwait(false);
                    }
                    finally
                    {
                        Leave(perPeer, key);
                    }
                });
                lo.UseHttps(new HttpsConnectionAdapterOptions
                {
                    ServerCertificate = listen.Certificate,
                    SslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    ClientCertificateMode = ClientCertificateMode.NoCertificate,
                    HandshakeTimeout = TimeSpan.FromSeconds(10),
                });
            });
        });
        var app = builder.Build();
        app.Run(context => HandleAsync(context, listen));
        try
        {
            await app.StartAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            await app.DisposeAsync().ConfigureAwait(false);
            if (ex is IOException { InnerException: AddressInUseException } or AddressInUseException)
                throw new SocketException((int)SocketError.AddressAlreadyInUse);
            throw;
        }
        return new Listener(app, endpoint?.IPEndPoint?.Port ?? listen.Port);
    }

    private static void Leave(ConcurrentDictionary<IPAddress, int> perPeer, IPAddress key)
    {
        while (perPeer.TryGetValue(key, out var n))
        {
            if (n <= 1 ? perPeer.TryRemove(new KeyValuePair<IPAddress, int>(key, n)) : perPeer.TryUpdate(key, n - 1, n)) return;
        }
    }

    private static async Task HandleAsync(HttpContext context, PhoneListen listen)
    {
        var request = context.Request;
        var response = context.Response;
        if (context.Connection.RemoteIpAddress is not { } peer || context.Connection.LocalIpAddress is not { } local || !listen.AllowPeer(peer, local))
        {
            context.Abort();
            return;
        }
        var bodyRead = false;
        try
        {
            var cookie = request.Cookies.TryGetValue(PhoneSession.CookieName, out var value) ? value : null;
            var fromPage = request.Headers[PhoneSession.PageHeader] == "1";
            async Task<byte[]?> ReadBody(int max, CancellationToken token)
            {
                bodyRead = true;
                if (request.ContentLength is { } declared && declared > max) return null;
                using var kept = new MemoryStream();
                var buffer = new byte[81920];
                int n;
                while ((n = await request.Body.ReadAsync(buffer, token).ConfigureAwait(false)) > 0)
                {
                    if (kept.Length + n > max) return null;
                    kept.Write(buffer, 0, n);
                }
                return kept.ToArray();
            }
            var reply = await listen.Session.HandleAsync(new PhoneRequest(request.Method, request.Path.Value ?? "/", peer, cookie, fromPage), ReadBody,
                context.RequestAborted).ConfigureAwait(false);
            response.StatusCode = reply.Status;
            var headers = response.Headers;
            headers.CacheControl = "no-store";
            headers.XContentTypeOptions = "nosniff";
            headers.XFrameOptions = "DENY";
            headers["Referrer-Policy"] = "no-referrer";
            if (reply.ContentSecurityPolicy is { } csp) headers.ContentSecurityPolicy = csp;
            if (reply.SetCookie is { } setCookie) headers.SetCookie = setCookie;
            if (reply.RetryAfterSeconds is { } seconds) headers.RetryAfter = seconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
            // A body not read (refused before it, or too long) isn't taken as the next request: the connection closes after the answer.
            if (!bodyRead && (request.ContentLength > 0 || request.Headers.TransferEncoding.Count > 0) || reply.Status == StatusCodes.Status413PayloadTooLarge) headers.Connection = "close";
            if (reply.Body is { } bytes && !HttpMethods.IsHead(request.Method))
            {
                response.ContentType = reply.ContentType;
                response.ContentLength = bytes.Length;
                await response.Body.WriteAsync(bytes, context.RequestAborted).ConfigureAwait(false);
            }
            else response.ContentLength = 0;
        }
        catch (Microsoft.AspNetCore.Http.BadHttpRequestException ex)
        {
            if (response.HasStarted) return;
            response.StatusCode = ex.StatusCode;
            response.Headers.Connection = "close";
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            // The phone went away, or the scan ended.
        }
    }

    private sealed class Listener(WebApplication app, int port) : IShareListener
    {
        private int _disposed;

        public int Port { get; } = port;

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            try
            {
                await app.StopAsync(limit.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Cut off: what's left closes with the app below.
            }
            await app.DisposeAsync().ConfigureAwait(false);
        }
    }
}
