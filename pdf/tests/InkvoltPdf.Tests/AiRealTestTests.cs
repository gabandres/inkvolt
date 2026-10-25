using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Regressions from running the AI assistant against a real Ollama: context size, combine rounds, loopback, wording, estimates.</summary>
public class AiRealTestTests
{
    private static AiEndpoint Endpoint(string url = AiEndpoint.OllamaUrl)
    {
        Assert.True(AiEndpoint.TryParse(url, out var ep, out var error), error);
        return ep!;
    }

    // ── 1. Ollama's real context ──

    [Fact]
    public void ReadsTheLoadedContextFromApiPs()
    {
        const string ps = """{"models":[{"name":"llama3.2:latest","model":"llama3.2:latest","context_length":8192},{"name":"qwen2.5:1.5b","model":"qwen2.5:1.5b","context_length":4096}]}""";
        Assert.Equal(4096, AiProtocol.OllamaLoadedContext(ps, "qwen2.5:1.5b"));
        Assert.Equal(8192, AiProtocol.OllamaLoadedContext(ps, "llama3.2")); // ":latest" is implied
        Assert.Null(AiProtocol.OllamaLoadedContext(ps, "gemma3:4b")); // not loaded
        Assert.Null(AiProtocol.OllamaLoadedContext("""{"models":[{"name":"qwen2.5:1.5b"}]}""", "qwen2.5:1.5b")); // older Ollama: no field
        Assert.Null(AiProtocol.OllamaLoadedContext("not json", "x"));
    }

    [Fact]
    public void ReadsNumCtxAndTheTrainedContextFromApiShow()
    {
        const string show = """{"parameters":"stop \"<|im_end|>\"\nnum_ctx 16384\ntemperature 0.7","model_info":{"general.architecture":"qwen2","qwen2.context_length":32768}}""";
        Assert.Equal((16384, 32768), AiProtocol.OllamaShowContext(show));
        Assert.Equal(((int?)null, 131072), AiProtocol.OllamaShowContext("""{"model_info":{"llama.context_length":131072}}"""));
        Assert.Equal(((int?)null, (int?)null), AiProtocol.OllamaShowContext("{}"));
    }

    private static FakeAiHandler Ollama(string? ps, string? show, List<(string Path, string Body)>? seen = null) => new((r, body, _) =>
    {
        seen?.Add((r.RequestUri!.AbsolutePath, body));
        var json = r.RequestUri!.AbsolutePath switch { "/api/ps" => ps, "/api/show" => show, _ => null };
        return Task.FromResult(json is null ? FakeAiHandler.Json(HttpStatusCode.NotFound, "{}") : FakeAiHandler.Json(HttpStatusCode.OK, json));
    });

    [Fact]
    public async Task AsksOllamaForTheContextOnTheSameServer()
    {
        var seen = new List<(string Path, string Body)>();
        using var client = new AiClient(Endpoint(), "qwen2.5:1.5b", null,
            Ollama("""{"models":[{"name":"qwen2.5:1.5b","context_length":4096}]}""", """{"model_info":{"qwen2.context_length":32768}}""", seen));
        var (context, source) = await client.OllamaContextAsync();
        Assert.Equal(4096, context);
        Assert.Contains("loaded", source);
        Assert.Equal(["/api/ps", "/api/show"], seen.Select(s => s.Path));
        Assert.Equal("""{"model":"qwen2.5:1.5b"}""", seen[1].Body); // only the model's name
    }

    [Fact]
    public async Task FallsBackToNumCtxCapsAtTheTrainedContextAndElseSaysNothing()
    {
        using var notLoaded = new AiClient(Endpoint(), "m", null, Ollama("""{"models":[]}""", """{"parameters":"num_ctx 8192"}"""));
        Assert.Equal(8192, (await notLoaded.OllamaContextAsync()).Context);

        using var capped = new AiClient(Endpoint(), "m", null, Ollama("""{"models":[{"name":"m","context_length":65536}]}""", """{"model_info":{"x.context_length":2048}}"""));
        Assert.Equal(2048, (await capped.OllamaContextAsync()).Context);

        using var silent = new AiClient(Endpoint(), "m", null, Ollama(null, null));
        Assert.Null((await silent.OllamaContextAsync()).Context);

        var down = new FakeAiHandler((_, _, _) => throw new HttpRequestException(HttpRequestError.ConnectionError, "refused", new SocketException((int)SocketError.ConnectionRefused)));
        using var off = new AiClient(Endpoint(), "m", null, down);
        Assert.Null((await off.OllamaContextAsync()).Context);
    }

    [Fact]
    public async Task TheAnswerLimitIsSentOnlyWhenSet()
    {
        var bodies = new List<string>();
        var handler = new FakeAiHandler((_, body, _) =>
        {
            bodies.Add(body);
            return Task.FromResult(FakeAiHandler.Sse("ok"));
        });
        using (var ollama = new AiClient(Endpoint(), "m", null, handler) { MaxAnswerTokens = 1024 })
            await ollama.ChatAsync([AiMessage.User("Q")]);
        using (var other = new AiClient(Endpoint("https://api.example.com/v1"), "m", null, handler))
            await other.ChatAsync([AiMessage.User("Q")]);
        Assert.Equal(1024, JsonDocument.Parse(bodies[0]).RootElement.GetProperty("max_tokens").GetInt32());
        Assert.False(JsonDocument.Parse(bodies[1]).RootElement.TryGetProperty("max_tokens", out _));
    }

    [Theory]
    [InlineData(2048)]
    [InlineData(4096)]
    [InlineData(8192)]
    public void ARequestAtTheBudgetFitsTheContextEvenForTables(int context)
    {
        // A page of figures, the kind that made qwen2.5 use ~1.8 characters per token: chunked to the budget, a request
        // (instructions, chunk, answer room) stays under the context even at 1.5 characters per token.
        var table = string.Join("\n", Enumerable.Range(0, 400).Select(i => $"{i * 1250:N0} {i * 37.5:0.00} {i % 7 * 12.25:0.00}%"));
        var chunks = AiText.Chunk([new AiPageText(0, table)], AiText.InputTokens(context));
        foreach (var request in AiPrompts.SummaryRequests(chunks))
        {
            var realTokens = request.Sum(m => m.Content.Length) / 1.5;
            Assert.True(realTokens + AiText.AnswerTokens(context) <= context, $"{realTokens:0} + {AiText.AnswerTokens(context)} > {context}");
        }
    }

    // ── 2. Combine rounds: never an empty confirmation, and a true count ──

    [Fact]
    public async Task ARoundThatSendsNothingAsksNothingAndProgressCountsRealRequests()
    {
        var page = string.Join(" ", Enumerable.Repeat("Words in a sentence.", 60));
        var chunks = AiText.Chunk([.. Enumerable.Range(0, 4).Select(i => new AiPageText(i, page))], 400);
        var steps = new List<AiStep>();
        var confirms = new List<int>();
        var first = true;
        await AiPrompts.SummarizeAsync(chunks, 400, (_, s, _) =>
        {
            steps.Add(s);
            // The partial summaries are each too long to pair up at first: the round sends nothing and they are shortened.
            return Task.FromResult(s.IsFinal ? "Final" : first && s.Index <= chunks.Count ? new string('x', 1400) : "short");
        }, confirmCombine: (round, _) =>
        {
            confirms.Add(round.Count);
            first = false;
            return Task.FromResult(true);
        });
        Assert.All(confirms, n => Assert.True(n > 0));
        Assert.Equal(Enumerable.Range(1, steps.Count), steps.Select(s => s.Index));
        Assert.Equal(steps.Count, steps[^1].Total); // "(n of n)" at the end: the total counted only real requests
        Assert.True(steps[^1].IsFinal);
    }

    // ── 3. Loopback: presets on 127.0.0.1, and both addresses of "localhost" tried at once ──

    [Fact]
    public void PresetsUseIpv4Loopback()
    {
        Assert.Equal("127.0.0.1:11434", Endpoint(AiEndpoint.OllamaUrl).Host);
        Assert.Equal("127.0.0.1:1234", Endpoint(AiEndpoint.LmStudioUrl).Host);
        Assert.Equal("Ollama", Endpoint(AiEndpoint.OllamaUrl).ServerName);
    }

    [Fact]
    public async Task LocalhostConnectsWithoutWaitingForARefusedIpv6()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0); // IPv4 only, as Ollama listens
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var server = Task.Run(async () =>
        {
            using var socket = await listener.AcceptTcpClientAsync();
            var stream = socket.GetStream();
            var buffer = new byte[65536];
            var request = new StringBuilder();
            while (!request.ToString().Contains("\r\n\r\n", StringComparison.Ordinal))
                request.Append(Encoding.UTF8.GetString(buffer, 0, await stream.ReadAsync(buffer)));
            const string body = """{"data":[{"id":"qwen2.5:1.5b"}]}""";
            await stream.WriteAsync(Encoding.UTF8.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n{body}"));
        });
        try
        {
            var ep = Endpoint($"http://localhost:{port}/v1");
            var handler = AiClient.CreateHandler(ep, resolve: (_, _) => Task.FromResult(new[] { IPAddress.IPv6Loopback, IPAddress.Loopback }));
            using var client = new AiClient(ep, "m", null, handler);
            var watch = Stopwatch.StartNew();
            Assert.Equal(["qwen2.5:1.5b"], await client.ListModelsAsync());
            Assert.True(watch.ElapsedMilliseconds < 1500, $"{watch.ElapsedMilliseconds} ms"); // one after the other took ~2 s
            await server;
        }
        finally
        {
            listener.Stop();
        }
    }

    // ── 4. A server that dies: user wording, partial answer kept ──

    [Fact]
    public async Task AServerThatClosesBeforeAnsweringIsSaidPlainly()
    {
        var handler = new FakeAiHandler((_, _, _) => throw new HttpRequestException(HttpRequestError.ResponseEnded, "An error occurred while sending the request."));
        using var client = new AiClient(Endpoint(), "m", null, handler);
        var ex = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]));
        Assert.Equal("The connection to 127.0.0.1:11434 closed before the answer finished: did Ollama stop or crash?", ex.Message);
    }

    [Fact]
    public async Task AServerThatDiesMidAnswerKeepsWhatArrived()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StreamContent(new DyingStream("data: {\"choices\":[{\"delta\":{\"content\":\"Half an\"}}]}\n\n")) { Headers = { ContentType = new("text/event-stream") } },
        }));
        using var client = new AiClient(Endpoint("https://api.example.com/v1"), "m", null, handler);
        var got = new StringBuilder();
        var ex = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")], s => got.Append(s)));
        Assert.Equal("Half an", got.ToString());
        Assert.Equal("The connection to api.example.com closed before the answer finished.", ex.Message);
        Assert.DoesNotContain("..", ex.Message);
        Assert.DoesNotContain("transport", ex.Message);
    }

    /// <summary>Sends <paramref name="first"/>, then fails as a reset connection does.</summary>
    private sealed class DyingStream(string first) : Stream
    {
        private readonly byte[] _first = Encoding.UTF8.GetBytes(first);
        private bool _sent;

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (_sent)
                return ValueTask.FromException<int>(new IOException("Unable to read data from the transport connection: An existing connection was forcibly closed by the remote host..",
                    new SocketException((int)SocketError.ConnectionReset)));
            _sent = true;
            _first.CopyTo(buffer);
            return ValueTask.FromResult(_first.Length);
        }

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    // ── 5. Estimates: cautious for figures ──

    [Fact]
    public void FiguresCountAboutATokenPerCharacter()
    {
        const string figures = "12,345.67 8,910.11 23.5% $1,200";
        Assert.True(AiText.EstimateTokens(figures) >= figures.Length / 1.5, $"{AiText.EstimateTokens(figures)}");
        const string prose = "The quick brown fox jumps over the lazy dog, and then it rests in the shade.";
        Assert.InRange(AiText.EstimateTokens(prose), prose.Length / 4, prose.Length / 2.5);
        Assert.Equal(12, AiText.EstimateTokens("123456789012"));
        Assert.Equal(4, AiText.EstimateTokens("日本語文"));
    }
}
