using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Authentication;
using InkvoltPrint.Core.Sharing;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.AspNetCore.Server.Kestrel.Https;

namespace InkvoltPrint.Sharing;

/// <summary>
/// The shared scanner's HTTPS server (roadmap 3.1): Kestrel, HTTP/1.1 over TLS 1.2 or 1.3 only, with the share's certificate. A
/// connection from a device <see cref="ShareListen.AllowPeer"/> refuses is closed before TLS starts; each device may hold a few
/// connections, the server a few dozen; request lines, headers and bodies are small and bounded (a ScanSettings is the only body
/// read, at most <see cref="ShareXml.MaxSettingsBytes"/>); slow requests time out. Every request goes to the
/// <see cref="SharedScanner"/>, which names no file and reads nothing from this PC. No logging: nothing about the devices is kept.
/// Disposing the listener closes the port at once and ends the connections under way within a second.
/// </summary>
public sealed class KestrelShareHost : IShareHost
{
    /// <summary>Connections at once, all devices together, and from one device.</summary>
    public const int MaxConnections = 32, MaxConnectionsPerPeer = 8;

    public async Task<IShareListener> StartAsync(ShareListen listen, CancellationToken ct)
    {
        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions { ApplicationName = typeof(KestrelShareHost).Assembly.GetName().Name });
        ListenOptions? endpoint = null;
        var perPeer = new ConcurrentDictionary<IPAddress, int>();
        builder.WebHost.UseKestrelCore().ConfigureKestrel(o =>
        {
            o.AddServerHeader = false;
            o.AllowSynchronousIO = false;
            var limits = o.Limits;
            limits.MaxConcurrentConnections = MaxConnections;
            limits.MaxConcurrentUpgradedConnections = 0;
            limits.MaxRequestBodySize = ShareXml.MaxSettingsBytes;
            limits.MaxRequestBufferSize = 64 * 1024;
            limits.MaxRequestHeaderCount = 32;
            limits.MaxRequestHeadersTotalSize = 16 * 1024;
            limits.MaxRequestLineSize = 4 * 1024;
            limits.KeepAliveTimeout = TimeSpan.FromSeconds(60);
            limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15);
            o.Listen(listen.Address, listen.Port, lo =>
            {
                endpoint = lo;
                lo.Protocols = HttpProtocols.Http1;
                // Before TLS: a device that may not connect gets nothing, not even the certificate.
                lo.Use(next => async connection =>
                {
                    // Who it is, and where it came in: the address of this PC it reached says which interface (and network) it's on.
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

    private static async Task HandleAsync(HttpContext context, ShareListen listen)
    {
        var request = context.Request;
        var response = context.Response;
        if (context.Connection.RemoteIpAddress is not { } peer || context.Connection.LocalIpAddress is not { } local || !listen.AllowPeer(peer, local))
        {
            context.Abort();
            return;
        }
        try
        {
            byte[] body = [];
            if (HttpMethods.IsPost(request.Method) || HttpMethods.IsPut(request.Method))
            {
                if (request.ContentLength > ShareXml.MaxSettingsBytes)
                {
                    // Not read: the connection closes after the answer, so the rest of the body is never taken as a request.
                    response.StatusCode = StatusCodes.Status413PayloadTooLarge;
                    response.Headers.Connection = "close";
                    response.ContentLength = 0;
                    return;
                }
                using var kept = new MemoryStream();
                await request.Body.CopyToAsync(kept, context.RequestAborted).ConfigureAwait(false); // Kestrel stops it past MaxRequestBodySize
                body = kept.ToArray();
            }
            var authority = request.Host.HasValue ? request.Host.Value : null;
            var reply = await listen.Scanner.HandleAsync(new ShareRequest(request.Method, request.Path.Value ?? "/", body, peer, authority), context.RequestAborted)
                .ConfigureAwait(false);
            response.StatusCode = reply.Status;
            response.Headers.CacheControl = "no-store";
            if (reply.Location is { } location) response.Headers.Location = location;
            if (reply.RetryAfterSeconds is { } seconds) response.Headers.RetryAfter = seconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (reply.Body is { } bytes)
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
            // The device went away, or the share stopped.
        }
    }

    private sealed class Listener(WebApplication app, int port) : IShareListener
    {
        private int _disposed;

        public int Port { get; } = port;

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            // Stopping closes the listening socket first; requests still under way get a second, then their connections are cut.
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
