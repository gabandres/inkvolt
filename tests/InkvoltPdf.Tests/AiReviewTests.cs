using System.Net;
using System.Net.Sockets;
using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Regressions from the review of the AI assistant: address checks, keys per endpoint, limits, combine confirmation.</summary>
public class AiReviewTests
{
    private static AiEndpoint Endpoint(string url)
    {
        Assert.True(AiEndpoint.TryParse(url, out var ep, out var error), error);
        return ep!;
    }

    // ── 1. Hosts: what is classified is what is connected to ──

    [Theory]
    [InlineData("http://api\u3002openai\u3002com/v1")] // ideographic full stops: IDNA turns them into dots
    [InlineData("http://api\uFF0Eopenai\uFF0Ecom/v1")] // fullwidth full stops
    [InlineData("https://b\u00FCcher.example/v1")]
    [InlineData("api\u3002openai\u3002com")]
    public void NonAsciiHostsAreRefused(string url)
    {
        Assert.False(AiEndpoint.TryParse(url, out var ep, out var error));
        Assert.Null(ep);
        Assert.Contains("xn--", error);
    }

    [Fact]
    public void PunycodeHostsAreTheInternet() =>
        Assert.Equal(AiReach.Internet, Endpoint("https://xn--bcher-kva.example/v1").Reach);

    [Theory]
    [InlineData("http://localhost:11434/v1", "127.0.0.1", true)]
    [InlineData("http://localhost:11434/v1", "::1", true)]
    [InlineData("http://localhost:11434/v1", "192.168.1.5", false)]
    [InlineData("http://evil.localhost:11434/v1", "203.0.113.7", false)]
    [InlineData("http://nas.local:11434/v1", "192.168.1.5", true)]
    [InlineData("http://nas.local:11434/v1", "fd00::5", true)]
    [InlineData("http://nas.local:11434/v1", "127.0.0.1", true)]
    [InlineData("http://nas.local:11434/v1", "8.8.8.8", false)]
    [InlineData("http://gpu:8000/v1", "2001:db8::1", false)]
    [InlineData("https://api.example.com/v1", "8.8.8.8", true)]
    [InlineData("https://api.example.com/v1", "10.0.0.1", true)]
    public void AddressesMustMatchTheLabel(string url, string ip, bool allowed) =>
        Assert.Equal(allowed, Endpoint(url).Allows(IPAddress.Parse(ip)));

    [Theory]
    [InlineData("http://nas.local:9/v1", "203.0.113.7")]
    [InlineData("http://evil.localhost:9/v1", "192.168.1.5")]
    public async Task ANameThatLeadsOutsideItsLabelIsNotConnectedTo(string url, string resolvesTo)
    {
        var ep = Endpoint(url);
        var asked = new List<string>();
        var handler = AiClient.CreateHandler(ep, resolve: (host, _) =>
        {
            asked.Add(host);
            return Task.FromResult(new[] { IPAddress.Parse(resolvesTo) });
        });
        using var client = new AiClient(ep, "m", "sk-secret", handler);
        var ex = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("private text")]));
        Assert.Contains("nothing was sent", ex.Message);
        Assert.Contains(resolvesTo, ex.Message);
        Assert.Single(asked);
    }

    [Fact]
    public async Task ALocalNameConnectsToTheCheckedAddress()
    {
        // A tiny OpenAI-compatible server on loopback; the name "ollama.localhost" is resolved by the test, to a public
        // address first (skipped) and then loopback, which is the one connected to.
        var listener = new TcpListener(IPAddress.Loopback, 0);
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
            const string body = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\ndata: [DONE]\n\n";
            var response = $"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {Encoding.UTF8.GetByteCount(body)}\r\nConnection: close\r\n\r\n{body}";
            await stream.WriteAsync(Encoding.UTF8.GetBytes(response));
            return request.ToString();
        });
        try
        {
            var ep = Endpoint($"http://ollama.localhost:{port}/v1");
            Assert.Equal(AiReach.ThisPc, ep.Reach);
            var handler = AiClient.CreateHandler(ep, resolve: (_, _) => Task.FromResult(new[] { IPAddress.Parse("203.0.113.9"), IPAddress.Loopback }));
            using var client = new AiClient(ep, "m", null, handler);
            var reply = await client.ChatAsync([AiMessage.User("Q")]);
            Assert.Equal("Hi", reply.Text);
            Assert.StartsWith("POST /v1/chat/completions", await server);
        }
        finally
        {
            listener.Stop();
        }
    }

    // ── 2. Keys belong to the endpoint they were entered for ──

    [Fact]
    public void ChangingTheEndpointDropsTheTypedKeyAndTheRemoval()
    {
        var saved = new Dictionary<string, string> { ["https://api.example.com/v1"] = "sk-saved", ["http://localhost:11434/v1"] = "local-saved" };
        var draft = new AiKeyDraft("https://api.example.com/v1");
        draft.Type("sk-typed");
        Assert.Equal("sk-typed", draft.KeyToUse(saved.GetValueOrDefault));

        Assert.True(draft.EndpointChanged("http://localhost:11434/v1")); // switched to the Ollama preset
        Assert.Null(draft.Typed);
        Assert.Equal("local-saved", draft.KeyToUse(saved.GetValueOrDefault)); // never the cloud key

        draft.RemoveSaved();
        Assert.Null(draft.KeyToUse(saved.GetValueOrDefault));
        Assert.True(draft.EndpointChanged("https://api.example.com/v1"));
        Assert.False(draft.Remove); // removing the local key doesn't carry over
        Assert.Equal("sk-saved", draft.KeyToUse(saved.GetValueOrDefault));

        Assert.False(draft.EndpointChanged("HTTPS://api.example.com/v1"));
        Assert.True(draft.EndpointChanged(null)); // an invalid address: no key at all
        Assert.Null(draft.KeyToUse(saved.GetValueOrDefault));
    }

    [Fact]
    public void KeysAreKeyedByTheNormalizedEndpoint() =>
        Assert.Equal(Endpoint("API.example.com:443/v1/").Key, Endpoint("https://api.example.com/v1/chat/completions").Key);

    // ── 3. Malformed answers end in an error, within limits ──

    [Theory]
    [InlineData("""{"choices":[{"index":"0","delta":{"content":"x"}}]}""")]
    [InlineData("""{"choices":[{"index":1.5,"delta":{"content":"x"}}]}""")]
    [InlineData("""{"choices":[{"index":99999999999,"delta":{"content":"x"}}]}""")]
    public void OddChoiceIndexesAreSkippedNotThrown(string json) => Assert.Equal("", new AiStreamParser().Line("data: " + json));

    [Fact]
    public void AnEndlessEventIsRefused()
    {
        var p = new AiStreamParser();
        var line = "data: " + new string('x', 1 << 20);
        Assert.Throws<AiException>(() =>
        {
            for (var i = 0; i < 10; i++) p.Line(line);
        });
    }

    [Fact]
    public async Task AStreamWithoutLineBreaksIsRefused()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("data: " + new string('x', AiClient.MaxLineChars + 10), Encoding.UTF8, "text/event-stream"),
        }));
        using var client = new AiClient(Endpoint(AiEndpoint.OllamaUrl), "m", null, handler);
        Assert.Contains("too long", (await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]))).Message);
    }

    [Fact]
    public async Task AnOversizedWholeAnswerIsRefusedAndAnErrorBodyCut()
    {
        var huge = new FakeAiHandler((_, _, _) => Task.FromResult(FakeAiHandler.Json(HttpStatusCode.OK,
            """{"choices":[{"message":{"content":" """ + new string('x', AiClient.MaxBodyBytes) + "\"}}]}")));
        using var a = new AiClient(Endpoint(AiEndpoint.OllamaUrl), "m", null, huge);
        Assert.Contains("MB", (await Assert.ThrowsAsync<AiException>(() => a.ChatAsync([AiMessage.User("Q")]))).Message);

        var bigError = new FakeAiHandler((_, _, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)
        {
            Content = new StringContent(new string('e', AiClient.MaxBodyBytes + 100)),
        }));
        using var b = new AiClient(Endpoint(AiEndpoint.OllamaUrl), "m", null, bigError);
        Assert.Contains("500", (await Assert.ThrowsAsync<AiException>(() => b.ChatAsync([AiMessage.User("Q")]))).Message);
    }

    [Fact]
    public async Task ABodyThatBreaksOffIsAnAiError()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized)
        {
            Content = new StreamContent(new BrokenStream()),
        }));
        using var client = new AiClient(Endpoint(AiEndpoint.OllamaUrl), "m", null, handler);
        Assert.Contains("closed before the answer finished", (await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]))).Message);
        using var models = new AiClient(Endpoint(AiEndpoint.OllamaUrl), "m", null, handler);
        await Assert.ThrowsAsync<AiException>(() => models.ListModelsAsync());
    }

    private sealed class BrokenStream : Stream
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
            ValueTask.FromException<int>(new IOException("The connection was reset."));
        public override int Read(byte[] buffer, int offset, int count) => throw new IOException("The connection was reset.");
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

    // ── 4. Combining requests are shown before they go ──

    private static IReadOnlyList<AiChunk> LongChunks() =>
        AiText.Chunk([.. Enumerable.Range(0, 4).Select(i => new AiPageText(i, string.Join(" ", Enumerable.Repeat("Words in a sentence.", 60))))], 400);

    [Fact]
    public async Task CombiningRequestsAreConfirmedWithTheirExactText()
    {
        var chunks = LongChunks();
        var shown = new List<IReadOnlyList<IReadOnlyList<AiMessage>>>();
        var sent = new List<IReadOnlyList<AiMessage>>();
        var result = await AiPrompts.SummarizeAsync(chunks, 400, (m, s, _) =>
        {
            sent.Add(m);
            return Task.FromResult(s.IsFinal ? "Final" : $"Partial {s.Index}");
        }, confirmCombine: (round, _) =>
        {
            shown.Add(round);
            return Task.FromResult(true);
        });
        Assert.Equal("Final", result);
        var round = Assert.Single(shown);
        Assert.Same(round[0], sent[^1]); // exactly what was shown is what went
        Assert.Contains("Partial 1", round[0][1].Content);
    }

    [Fact]
    public async Task DecliningKeepsThePartialSummariesAndSendsNothingMore()
    {
        var chunks = LongChunks();
        var calls = 0;
        var result = await AiPrompts.SummarizeAsync(chunks, 400, (_, s, _) =>
        {
            calls++;
            return Task.FromResult($"Partial {s.Index}");
        }, confirmCombine: (_, _) => Task.FromResult(false));
        Assert.Equal(chunks.Count, calls);
        Assert.Contains("### Pages", result.Replace("### Page ", "### Pages "));
        Assert.Contains("Partial 1", result);
        Assert.Contains($"Partial {chunks.Count}", result);
    }
}
