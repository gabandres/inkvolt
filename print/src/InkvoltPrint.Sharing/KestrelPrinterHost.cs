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

    /// <summary>Request bodies held in memory at once, all connections together, when the listen brings no budget of its own (<see cref="PrinterListen.Budget"/>, which queued documents share).</summary>
    public const long MaxBytesInFlight = 160L * 1024 * 1024;

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
            limits.MinRequestBodyDataRate = new MinDataRate(bytesPerSecond: 32 * 1024, gracePeriod: TimeSpan.FromSeconds(5));
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
        var budget = listen.Budget ?? new ShareBudget(MaxBytesInFlight);
        app.Run(context => HandleAsync(context, listen, budget));
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

    private static async Task HandleAsync(HttpContext context, PrinterListen listen, ShareBudget budget)
    {
        var request = context.Request;
        var response = context.Response;
        if (context.Connection.RemoteIpAddress is not { } peer || context.Connection.LocalIpAddress is not { } local || !listen.AllowPeer(peer, local))
        {
            context.Abort();
            return;
        }
        var path = request.Path.Value ?? "/";
        var authority = request.Host.HasValue ? request.Host.Value : null;
        using var kept = new BodyBuffer(budget, listen.MaxBodyBytes);
        try
        {
            byte[] body = [];
            if (HttpMethods.IsPost(request.Method))
            {
                if (!string.Equals(request.ContentType?.Split(';')[0].Trim(), "application/ipp", StringComparison.OrdinalIgnoreCase))
                {
                    Refuse(response, StatusCodes.Status415UnsupportedMediaType);
                    return;
                }
                if (request.ContentLength > listen.MaxBodyBytes)
                {
                    Refuse(response, StatusCodes.Status413PayloadTooLarge);
                    return;
                }
                // The head first (the request's attributes): a busy printer or a document past the limit is refused before the rest is
                // read. A body of a known length is read into one array of that length, held against the budget all documents share
                // (a queued job keeps its document there until it ends) and handed on as it is; one sent in chunks grows from small.
                var within = request.ContentLength is not { } length || kept.Reserve(length);
                var ended = false;
                if (within) (ended, within) = await kept.ReadAsync(request.Body, listen.HeadBytes, context.RequestAborted).ConfigureAwait(false);
                if (within && listen.Precheck?.Invoke(new ShareRequest(request.Method, path, kept.Head(listen.HeadBytes), peer, authority), request.ContentLength) is { } early)
                {
                    response.Headers.Connection = "close"; // the rest of the body is never read as a request
                    await WriteAsync(response, early, context.RequestAborted).ConfigureAwait(false);
                    return;
                }
                if (within && !ended) (_, within) = await kept.ReadAsync(request.Body, listen.MaxBodyBytes, context.RequestAborted).ConfigureAwait(false);
                if (!within || kept.Exact() is not { } exact)
                {
                    // Several large documents at once: try again in a moment.
                    response.Headers.RetryAfter = "10";
                    Refuse(response, StatusCodes.Status503ServiceUnavailable);
                    return;
                }
                body = exact;
            }
            else if (!HttpMethods.IsGet(request.Method))
            {
                Refuse(response, StatusCodes.Status405MethodNotAllowed);
                return;
            }
            var reply = await listen.Handle(new ShareRequest(request.Method, path, body, peer, authority), context.RequestAborted).ConfigureAwait(false);
            await WriteAsync(response, reply, context.RequestAborted).ConfigureAwait(false);
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

    private static void Refuse(HttpResponse response, int status)
    {
        response.StatusCode = status;
        response.Headers.Connection = "close";
        response.ContentLength = 0;
    }

    private static async Task WriteAsync(HttpResponse response, ShareReply reply, CancellationToken ct)
    {
        response.StatusCode = reply.Status;
        response.Headers.CacheControl = "no-store";
        if (reply.Body is { } bytes)
        {
            response.ContentType = reply.ContentType;
            response.ContentLength = bytes.Length;
            await response.Body.WriteAsync(bytes, ct).ConfigureAwait(false);
        }
        else response.ContentLength = 0;
    }

    /// <summary>
    /// One request's body in memory, its bytes held against the shared budget while the request lasts: reserved whole when its length
    /// is known (one array, handed on with no copy), else grown from 64 KB as it comes. Disposing gives the bytes back (a job keeps its own
    /// claim on its document, <see cref="SharedPrinter"/>).
    /// </summary>
    private sealed class BodyBuffer(ShareBudget budget, long max) : IDisposable
    {
        private byte[] _data = [];
        private int _length;
        private long _held;

        /// <summary>Room for exactly <paramref name="capacity"/> bytes; false past the budget (or the most a body may be).</summary>
        public bool Reserve(long capacity)
        {
            if (capacity <= _data.Length) return true;
            if (capacity > max || capacity > Array.MaxLength || !budget.TryTake(capacity)) return false;
            var data = new byte[capacity];
            _data.AsSpan(0, _length).CopyTo(data);
            budget.Release(_held);
            (_data, _held) = (data, capacity);
            return true;
        }

        /// <summary>Reads until it holds <paramref name="upTo"/> bytes or the body ends. Ended: the body ended. Within: the budget allowed it.</summary>
        public async Task<(bool Ended, bool Within)> ReadAsync(Stream body, long upTo, CancellationToken ct)
        {
            while (_length < upTo)
            {
                if (_length == _data.Length && !Reserve(Math.Min(Math.Max(64 * 1024, (long)_data.Length * 2), max))) return (false, false);
                var n = await body.ReadAsync(_data.AsMemory(_length, (int)Math.Min(_data.Length - _length, upTo - _length)), ct).ConfigureAwait(false);
                if (n == 0) return (true, true);
                _length += n;
            }
            return (false, true);
        }

        /// <summary>The first bytes read (the attributes), for the early check.</summary>
        public byte[] Head(int most) => _data[..Math.Min(_length, most)];

        /// <summary>The body as one array of its length: the array itself when it was reserved whole; null when a copy won't fit the budget.</summary>
        public byte[]? Exact()
        {
            if (_length == _data.Length) return _data;
            if (!budget.TryTake(_length)) return null;
            var exact = _data[.._length];
            budget.Release(_held);
            (_data, _held) = (exact, _length);
            return exact;
        }

        public void Dispose()
        {
            budget.Release(_held);
            _held = 0;
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
