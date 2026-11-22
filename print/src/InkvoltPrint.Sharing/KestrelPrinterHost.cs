using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using InkvoltPrint.Core.Sharing;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;

namespace InkvoltPrint.Sharing;

/// <summary>
/// The shared printers' IPP server (roadmap 4.10): Kestrel, HTTP/1.1 in the clear as IPP printers speak it (<c>ipp://</c>), on the port
/// <see cref="PrinterListen"/> names. As the shared scanner's server (<see cref="KestrelShareHost"/>): a device
/// <see cref="PrinterListen.AllowPeer"/> refuses is closed before a byte is read, each device holds a few connections and the server a few
/// dozen, headers are small and slow requests time out. A body may be a whole document, so it's bounded by
/// <see cref="PrinterListen.MaxBodyBytes"/> (chunked or not: Kestrel stops one past it) and must arrive at a minimum rate; only POST with
/// <c>application/ipp</c> is read. Every request goes to <see cref="PrinterListen.Handle"/>; nothing names a file. No logging of devices.
/// </summary>
public sealed class KestrelPrinterHost : IPrinterShareHost
{
    public const int MaxConnections = 32, MaxConnectionsPerPeer = 8;

    public async Task<IShareListener> StartAsync(PrinterListen listen, CancellationToken ct)
    {
        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions { ApplicationName = typeof(KestrelPrinterHost).Assembly.GetName().Name });
        ListenOptions? endpoint = null;
        var perPeer = new ConcurrentDictionary<IPAddress, int>();
        builder.WebHost.UseKestrelCore().ConfigureKestrel(o =>
        {
            o.AddServerHeader = false;
            o.AllowSynchronousIO = false;
            var limits = o.Limits;
            limits.MaxConcurrentConnections = MaxConnections;
            limits.MaxConcurrentUpgradedConnections = 0;
            limits.MaxRequestBodySize = listen.MaxBodyBytes;
            limits.MaxRequestBufferSize = 1024 * 1024;
            limits.MaxRequestHeaderCount = 32;
            limits.MaxRequestHeadersTotalSize = 16 * 1024;
            limits.MaxRequestLineSize = 4 * 1024;
            limits.KeepAliveTimeout = TimeSpan.FromSeconds(60);
            limits.RequestHeadersTimeout = TimeSpan.FromSeconds(15);
            limits.MinRequestBodyDataRate = new MinDataRate(bytesPerSecond: 4096, gracePeriod: TimeSpan.FromSeconds(10));
            o.Listen(listen.Address, listen.Port, lo =>
            {
                endpoint = lo;
                lo.Protocols = HttpProtocols.Http1;
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

    private static async Task HandleAsync(HttpContext context, PrinterListen listen)
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
            if (HttpMethods.IsPost(request.Method))
            {
                if (!string.Equals(request.ContentType?.Split(';')[0].Trim(), "application/ipp", StringComparison.OrdinalIgnoreCase))
                {
                    response.StatusCode = StatusCodes.Status415UnsupportedMediaType;
                    response.Headers.Connection = "close";
                    response.ContentLength = 0;
                    return;
                }
                if (request.ContentLength > listen.MaxBodyBytes)
                {
                    response.StatusCode = StatusCodes.Status413PayloadTooLarge;
                    response.Headers.Connection = "close";
                    response.ContentLength = 0;
                    return;
                }
                using var kept = new MemoryStream(request.ContentLength is { } length and > 0 ? (int)Math.Min(length, listen.MaxBodyBytes) : 64 * 1024);
                await request.Body.CopyToAsync(kept, context.RequestAborted).ConfigureAwait(false); // Kestrel stops it past MaxRequestBodySize
                body = kept.ToArray();
            }
            else if (!HttpMethods.IsGet(request.Method))
            {
                response.StatusCode = StatusCodes.Status405MethodNotAllowed;
                response.ContentLength = 0;
                return;
            }
            var authority = request.Host.HasValue ? request.Host.Value : null;
            var reply = await listen.Handle(new ShareRequest(request.Method, request.Path.Value ?? "/", body, peer, authority), context.RequestAborted).ConfigureAwait(false);
            response.StatusCode = reply.Status;
            response.Headers.CacheControl = "no-store";
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
            // The device went away, or sharing stopped.
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
