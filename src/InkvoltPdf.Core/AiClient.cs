using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>A finished answer: its text and why the model stopped ("length" = cut off by the model's limit).</summary>
public sealed record AiReply(string Text, string? FinishReason)
{
    public bool WasCutOff => FinishReason == "length";
}

/// <summary>
/// How long to wait. Local models can take a while to load before the first word (<see cref="FirstByte"/>); after that
/// a stream that goes quiet for <see cref="Idle"/> is given up.
/// </summary>
public sealed record AiTimeouts(TimeSpan Connect, TimeSpan FirstByte, TimeSpan Idle)
{
    public static readonly AiTimeouts Default = new(TimeSpan.FromSeconds(10), TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(2));
}

/// <summary>
/// Talks to one OpenAI-compatible endpoint the user configured. Sends only what it is given (the messages and the model
/// name, plus the API key as a bearer token when there is one); no telemetry, cookies or redirects. Errors come out as
/// <see cref="AiException"/> worded for the user; cancelling throws <see cref="OperationCanceledException"/>.
/// </summary>
public sealed class AiClient : IDisposable
{
    private readonly HttpClient _http;
    private readonly AiEndpoint _endpoint;
    private readonly string _model;
    private readonly string? _apiKey;
    private readonly AiTimeouts _timeouts;

    /// <param name="handler">For tests; by default <see cref="CreateHandler"/>.</param>
    public AiClient(AiEndpoint endpoint, string model, string? apiKey, HttpMessageHandler? handler = null, AiTimeouts? timeouts = null)
    {
        _endpoint = endpoint;
        _model = model;
        _apiKey = string.IsNullOrWhiteSpace(apiKey) ? null : apiKey.Trim();
        _timeouts = timeouts ?? AiTimeouts.Default;
        _http = new HttpClient(handler ?? CreateHandler(endpoint, _timeouts), disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>Longest line of a streamed answer, largest whole body read, longest answer kept.</summary>
    public const int MaxLineChars = 1 << 20, MaxBodyBytes = 8 << 20, MaxAnswerChars = 4 << 20;

    /// <summary>
    /// The connection settings: no redirects (they could take the text somewhere else), no cookies. Requests to this PC or
    /// the network never go through a proxy, and connect only to an address in the endpoint's range
    /// (<see cref="AiEndpoint.Allows"/>): the name is resolved here and the checked address is the one connected to, so
    /// neither a name that resolves elsewhere nor DNS rebinding can take the text off the PC or network. Internet
    /// endpoints use the Windows proxy setting, as browsers do.
    /// </summary>
    /// <param name="resolve">For tests: name resolution (by default <see cref="Dns.GetHostAddressesAsync(string, CancellationToken)"/>).</param>
    public static SocketsHttpHandler CreateHandler(AiEndpoint endpoint, AiTimeouts? timeouts = null,
        Func<string, CancellationToken, Task<IPAddress[]>>? resolve = null) => new()
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        UseProxy = endpoint.Reach == AiReach.Internet,
        ConnectTimeout = (timeouts ?? AiTimeouts.Default).Connect,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
        ConnectCallback = (context, cancel) => Connect(endpoint, context.DnsEndPoint, resolve ?? Dns.GetHostAddressesAsync, cancel),
    };

    private static async ValueTask<Stream> Connect(AiEndpoint endpoint, DnsEndPoint target, Func<string, CancellationToken, Task<IPAddress[]>> resolve,
        CancellationToken cancel)
    {
        var host = target.Host.Trim('[', ']');
        var resolved = IPAddress.TryParse(host, out var literal) ? [literal] : await resolve(host, cancel);
        var allowed = resolved.Where(endpoint.Allows).ToArray();
        if (allowed.Length == 0)
            throw new AiAddressException(resolved.Length == 0
                ? $"Couldn't find {host}. Check the address, and that this PC is online."
                : $"{host} leads to {resolved[0]}, outside {(endpoint.Reach == AiReach.ThisPc ? "this PC" : "your network")}, so nothing was sent. " +
                  "If the endpoint is on the internet, enter its public https:// address.");
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(allowed, target.Port, cancel);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    /// <summary>The models the endpoint offers (<c>GET /models</c>). Empty when it doesn't list them (404).</summary>
    public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, _endpoint.ModelsUrl);
        Authorize(request);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(TimeSpan.FromSeconds(20));
        using var response = await Send(request, cts, cancel, TimeSpan.FromSeconds(20));
        var body = await ReadBody(response, cts, cancel, truncate: !response.IsSuccessStatusCode);
        if (response.StatusCode == HttpStatusCode.NotFound) return [];
        if (!response.IsSuccessStatusCode)
            throw new AiException(AiProtocol.DescribeError((int)response.StatusCode, AiProtocol.ErrorMessageOf(body), _model, _endpoint));
        return AiProtocol.ParseModels(body);
    }

    /// <summary>Sends one chat request and streams the answer, calling <paramref name="onText"/> with each piece as it arrives.</summary>
    public async Task<AiReply> ChatAsync(IReadOnlyList<AiMessage> messages, Action<string>? onText = null, CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint.ChatUrl)
        {
            Content = new StringContent(AiProtocol.ChatRequestJson(_model, messages), Encoding.UTF8, "application/json"),
        };
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        Authorize(request);

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(_timeouts.FirstByte);
        using var response = await Send(request, cts, cancel, _timeouts.FirstByte);
        if (!response.IsSuccessStatusCode)
        {
            var body = await ReadBody(response, cts, cancel, truncate: true);
            throw new AiException(AiProtocol.DescribeError((int)response.StatusCode, AiProtocol.ErrorMessageOf(body), _model, _endpoint));
        }

        var mediaType = response.Content.Headers.ContentType?.MediaType ?? "";
        if (mediaType.Contains("json", StringComparison.OrdinalIgnoreCase) && !mediaType.Contains("ndjson", StringComparison.OrdinalIgnoreCase))
        {
            // The server ignored "stream": the whole answer comes at once.
            var (whole, reason) = AiStreamParser.ParseWhole(await ReadBody(response, cts, cancel));
            onText?.Invoke(whole);
            return new AiReply(whole, reason);
        }

        var parser = new AiStreamParser();
        var text = new StringBuilder();
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cts.Token);
            var reader = new LineReader(stream);
            while (!parser.Done)
            {
                cts.CancelAfter(_timeouts.Idle);
                var line = await reader.ReadLineAsync(cts.Token);
                if (line is null) break;
                var piece = parser.Line(line);
                if (piece.Length == 0) continue;
                if (text.Length + piece.Length > MaxAnswerChars)
                    throw new AiException($"The answer from {_endpoint.Host} grew far longer than an answer should; it was stopped.");
                text.Append(piece);
                onText?.Invoke(piece);
            }
            var rest = parser.End();
            if (rest.Length > 0)
            {
                text.Append(rest);
                onText?.Invoke(rest);
            }
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new AiException($"{_endpoint.Host} stopped answering (nothing for {_timeouts.Idle.TotalSeconds:0} seconds).");
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException && !cancel.IsCancellationRequested)
        {
            throw new AiException($"The connection to {_endpoint.Host} broke off during the answer: {ex.Message}", ex);
        }
        if (!parser.SawData) throw new AiException($"{_endpoint.Host} answered with an empty stream. Is the model name right?");
        return new AiReply(text.ToString(), parser.FinishReason);
    }

    private void Authorize(HttpRequestMessage request)
    {
        if (_apiKey is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
    }

    private async Task<HttpResponseMessage> Send(HttpRequestMessage request, CancellationTokenSource cts, CancellationToken cancel, TimeSpan wait)
    {
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new AiException($"{_endpoint.Host} didn't answer within {Describe(wait)}." +
                                  (_endpoint.Reach == AiReach.ThisPc ? " A large model may still be loading: try again in a moment." : ""));
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or SocketException && !cancel.IsCancellationRequested)
        {
            throw new AiException(DescribeConnectionFailure(_endpoint, ex), ex);
        }
        var status = (int)response.StatusCode;
        if (status is >= 300 and < 400)
        {
            var to = response.Headers.Location is { } loc ? new Uri(_endpoint.BaseUrl, loc) : null;
            response.Dispose();
            throw new AiException($"{_endpoint.Host} redirects to {(to is null ? "another address" : to.GetLeftPart(UriPartial.Path))}. " +
                                  "Inkvolt PDF doesn't follow redirects: enter that address in Settings › AI assistant if you trust it.");
        }
        return response;
    }

    /// <summary>
    /// Reads a whole (not streamed) body, at most <see cref="MaxBodyBytes"/>: an error body is cut there
    /// (<paramref name="truncate"/>), an answer that long is refused.
    /// </summary>
    private async Task<string> ReadBody(HttpResponseMessage response, CancellationTokenSource cts, CancellationToken cancel, bool truncate = false)
    {
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cts.Token);
            using var ms = new MemoryStream();
            var buffer = new byte[16384];
            int n;
            while ((n = await stream.ReadAsync(buffer, cts.Token)) > 0)
            {
                if (ms.Length + n > MaxBodyBytes)
                {
                    if (!truncate) throw new AiException($"{_endpoint.Host} sent more than {MaxBodyBytes >> 20} MB in one answer; it was stopped.");
                    ms.Write(buffer, 0, (int)(MaxBodyBytes - ms.Length));
                    break;
                }
                ms.Write(buffer, 0, n);
            }
            return Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new AiException("The endpoint took too long to send its answer.");
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException && !cancel.IsCancellationRequested)
        {
            throw new AiException($"The connection to {_endpoint.Host} broke off: {ex.Message}", ex);
        }
    }

    /// <summary>Reads UTF-8 lines (LF or CRLF) of at most <see cref="MaxLineChars"/>, so a stream without line breaks can't fill memory.</summary>
    private sealed class LineReader(Stream stream)
    {
        private readonly Decoder _decoder = Encoding.UTF8.GetDecoder();
        private readonly byte[] _bytes = new byte[8192];
        private readonly char[] _chars = new char[Encoding.UTF8.GetMaxCharCount(8192)];
        private readonly StringBuilder _line = new();
        private int _pos, _count;
        private bool _ended;

        public async Task<string?> ReadLineAsync(CancellationToken cancel)
        {
            while (true)
            {
                for (; _pos < _count; _pos++)
                {
                    var c = _chars[_pos];
                    if (c == '\n')
                    {
                        _pos++;
                        return Take();
                    }
                    if (_line.Length >= MaxLineChars) throw new AiException("The endpoint sent a line too long to be part of a streamed answer.");
                    _line.Append(c);
                }
                if (_ended) return _line.Length > 0 ? Take() : null;
                var n = await stream.ReadAsync(_bytes, cancel);
                _ended = n == 0;
                _count = _decoder.GetChars(_bytes, 0, n, _chars, 0, flush: _ended);
                _pos = 0;
            }
        }

        private string Take()
        {
            if (_line.Length > 0 && _line[^1] == '\r') _line.Length--;
            var s = _line.ToString();
            _line.Clear();
            return s;
        }
    }

    /// <summary>"Couldn't connect to localhost:11434. Is Ollama running?" and the like.</summary>
    public static string DescribeConnectionFailure(AiEndpoint endpoint, Exception ex)
    {
        if (FindInner<AiAddressException>(ex) is { } refused) return refused.Message;
        var socket = FindInner<SocketException>(ex);
        if (socket?.SocketErrorCode == SocketError.TimedOut || FindInner<TimeoutException>(ex) is not null)
            return $"{endpoint.Host} didn't respond. Check the address, the network and any firewall.";
        if ((ex as HttpRequestException)?.HttpRequestError == HttpRequestError.NameResolutionError || socket?.SocketErrorCode is SocketError.HostNotFound or SocketError.NoData)
            return $"Couldn't find {endpoint.BaseUrl.Host}. Check the address, and that this PC is online.";
        if ((ex as HttpRequestException)?.HttpRequestError == HttpRequestError.SecureConnectionError || FindInner<AuthenticationException>(ex) is not null)
            return $"Couldn't make a secure connection to {endpoint.Host}: its certificate isn't trusted by Windows, or it doesn't speak https.";
        if (socket?.SocketErrorCode == SocketError.ConnectionRefused || (ex as HttpRequestException)?.HttpRequestError == HttpRequestError.ConnectionError)
            return $"Couldn't connect to {endpoint.Host}: nothing is listening there. " + endpoint.ServerName switch
            {
                "Ollama" => "Is Ollama running? Start it (or run: ollama serve) and try again.",
                "LM Studio" => "Is LM Studio's local server running? Start it in LM Studio (Developer › Start server) and try again.",
                _ => "Is the server running, and is the port right?",
            };
        return $"Couldn't reach {endpoint.Host}: {ex.Message}";
    }

    private static T? FindInner<T>(Exception? ex) where T : Exception
    {
        for (; ex is not null; ex = ex.InnerException)
            if (ex is T t) return t;
        return null;
    }

    private static string Describe(TimeSpan t) => t.TotalMinutes >= 1 ? $"{t.TotalMinutes:0} minute{(t.TotalMinutes >= 2 ? "s" : "")}" : $"{t.TotalSeconds:0} seconds";

    public void Dispose() => _http.Dispose();
}

/// <summary>A name led to an address outside the endpoint's range (or to none); no connection was made.</summary>
public sealed class AiAddressException(string message) : IOException(message);
