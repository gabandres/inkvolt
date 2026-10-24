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

    /// <summary>
    /// The connection settings: no redirects (they could take the text somewhere else), no cookies. Requests to this PC or
    /// the network never go through a proxy; internet endpoints use the Windows proxy setting, as browsers do.
    /// </summary>
    public static SocketsHttpHandler CreateHandler(AiEndpoint endpoint, AiTimeouts? timeouts = null) => new()
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        UseProxy = endpoint.Reach == AiReach.Internet,
        ConnectTimeout = (timeouts ?? AiTimeouts.Default).Connect,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
    };

    /// <summary>The models the endpoint offers (<c>GET /models</c>). Empty when it doesn't list them (404).</summary>
    public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, _endpoint.ModelsUrl);
        Authorize(request);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(TimeSpan.FromSeconds(20));
        using var response = await Send(request, cts, cancel, TimeSpan.FromSeconds(20));
        var body = await ReadBody(response, cts, cancel);
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
            var body = await ReadBody(response, cts, cancel);
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
            using var reader = new StreamReader(stream, Encoding.UTF8);
            while (!parser.Done)
            {
                cts.CancelAfter(_timeouts.Idle);
                var line = await reader.ReadLineAsync(cts.Token);
                if (line is null) break;
                var piece = parser.Line(line);
                if (piece.Length == 0) continue;
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
        catch (HttpRequestException ex) when (!cancel.IsCancellationRequested)
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

    private static async Task<string> ReadBody(HttpResponseMessage response, CancellationTokenSource cts, CancellationToken cancel)
    {
        try
        {
            var bytes = await response.Content.ReadAsByteArrayAsync(cts.Token);
            return Encoding.UTF8.GetString(bytes, 0, Math.Min(bytes.Length, 1 << 20));
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new AiException("The endpoint took too long to send its answer.");
        }
    }

    /// <summary>"Couldn't connect to localhost:11434. Is Ollama running?" and the like.</summary>
    public static string DescribeConnectionFailure(AiEndpoint endpoint, HttpRequestException ex)
    {
        var socket = FindInner<SocketException>(ex);
        if (socket?.SocketErrorCode == SocketError.TimedOut || FindInner<TimeoutException>(ex) is not null)
            return $"{endpoint.Host} didn't respond. Check the address, the network and any firewall.";
        if (ex.HttpRequestError == HttpRequestError.NameResolutionError || socket?.SocketErrorCode is SocketError.HostNotFound or SocketError.NoData)
            return $"Couldn't find {endpoint.BaseUrl.Host}. Check the address, and that this PC is online.";
        if (ex.HttpRequestError == HttpRequestError.SecureConnectionError || FindInner<AuthenticationException>(ex) is not null)
            return $"Couldn't make a secure connection to {endpoint.Host}: its certificate isn't trusted by Windows, or it doesn't speak https.";
        if (socket?.SocketErrorCode == SocketError.ConnectionRefused || ex.HttpRequestError == HttpRequestError.ConnectionError)
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
