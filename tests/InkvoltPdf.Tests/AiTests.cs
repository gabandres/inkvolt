using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class AiEndpointTests
{
    [Theory]
    [InlineData("localhost", AiReach.ThisPc)]
    [InlineData("LOCALHOST.", AiReach.ThisPc)]
    [InlineData("ollama.localhost", AiReach.ThisPc)]
    [InlineData("127.0.0.1", AiReach.ThisPc)]
    [InlineData("127.8.9.10", AiReach.ThisPc)]
    [InlineData("[::1]", AiReach.ThisPc)]
    [InlineData("::ffff:127.0.0.1", AiReach.ThisPc)]
    [InlineData("10.1.2.3", AiReach.LocalNetwork)]
    [InlineData("172.16.0.1", AiReach.LocalNetwork)]
    [InlineData("172.31.255.255", AiReach.LocalNetwork)]
    [InlineData("192.168.1.20", AiReach.LocalNetwork)]
    [InlineData("169.254.10.10", AiReach.LocalNetwork)]
    [InlineData("100.100.1.1", AiReach.LocalNetwork)]
    [InlineData("::ffff:192.168.0.9", AiReach.LocalNetwork)]
    [InlineData("fd12:3456::1", AiReach.LocalNetwork)]
    [InlineData("fe80::1", AiReach.LocalNetwork)]
    [InlineData("nas.local", AiReach.LocalNetwork)]
    [InlineData("gpu-box", AiReach.LocalNetwork)]
    [InlineData("router.lan", AiReach.LocalNetwork)]
    [InlineData("pc.home.arpa", AiReach.LocalNetwork)]
    [InlineData("172.32.0.1", AiReach.Internet)]
    [InlineData("192.0.2.10", AiReach.Internet)]
    [InlineData("8.8.8.8", AiReach.Internet)]
    [InlineData("2001:db8::1", AiReach.Internet)]
    [InlineData("api.example.com", AiReach.Internet)]
    [InlineData("local.example.com", AiReach.Internet)]
    [InlineData("localhost.example.com", AiReach.Internet)]
    public void ClassifiesHosts(string host, AiReach expected) => Assert.Equal(expected, AiEndpoint.Classify(host));

    [Theory]
    [InlineData("http://localhost:11434/v1", "http://localhost:11434/v1", AiReach.ThisPc)]
    [InlineData("localhost:11434", "http://localhost:11434/v1", AiReach.ThisPc)]
    [InlineData("http://localhost:1234/v1/", "http://localhost:1234/v1", AiReach.ThisPc)]
    [InlineData("http://192.168.1.10:8080", "http://192.168.1.10:8080/v1", AiReach.LocalNetwork)]
    [InlineData("api.example.com", "https://api.example.com/v1", AiReach.Internet)]
    [InlineData("api.example.com:8443/openai/v1", "https://api.example.com:8443/openai/v1", AiReach.Internet)]
    [InlineData("https://api.example.com/v1/chat/completions", "https://api.example.com/v1", AiReach.Internet)]
    [InlineData("https://api.example.com/v1/models", "https://api.example.com/v1", AiReach.Internet)]
    [InlineData("  https://API.Example.com/v1  ", "https://api.example.com/v1", AiReach.Internet)]
    public void ParsesBaseUrls(string text, string expected, AiReach reach)
    {
        Assert.True(AiEndpoint.TryParse(text, out var ep, out var error), error);
        Assert.Equal(expected, ep!.Key);
        Assert.Equal(reach, ep.Reach);
        Assert.Equal(expected + "/chat/completions", ep.ChatUrl.AbsoluteUri);
        Assert.Equal(expected + "/models", ep.ModelsUrl.AbsoluteUri);
    }

    [Theory]
    [InlineData("", "address")]
    [InlineData("http://api.example.com/v1", "https://")]
    [InlineData("http://8.8.8.8:11434/v1", "https://")]
    [InlineData("https://me:secret@api.example.com/v1", "API key")]
    [InlineData("https://api.example.com/v1?key=1", "?")]
    [InlineData("ftp://files.example.com", "https://")]
    [InlineData("http://", "web address")]
    public void RefusesBadOrUnsafeUrls(string text, string mention)
    {
        Assert.False(AiEndpoint.TryParse(text, out var ep, out var error));
        Assert.Null(ep);
        Assert.Contains(mention, error);
    }

    [Fact]
    public void DescribesWhereTextGoes()
    {
        Assert.True(AiEndpoint.TryParse(AiEndpoint.OllamaUrl, out var local, out _));
        Assert.Equal("Stays on this PC", local!.ReachText);
        Assert.Equal("Ollama", local.ServerName);
        Assert.True(AiEndpoint.TryParse(AiEndpoint.LmStudioUrl, out var lm, out _));
        Assert.Equal("LM Studio", lm!.ServerName);
        Assert.True(AiEndpoint.TryParse("http://nas.local:11434/v1", out var lan, out _));
        Assert.Equal("Stays on your network (nas.local:11434)", lan!.ReachText);
        Assert.Null(lan.ServerName);
        Assert.True(AiEndpoint.TryParse("https://api.example.com/v1", out var cloud, out _));
        Assert.Equal("Leaves this PC: sent to api.example.com", cloud!.ReachText);
    }
}

public class AiProtocolTests
{
    private static AiEndpoint Endpoint(string url = AiEndpoint.OllamaUrl)
    {
        Assert.True(AiEndpoint.TryParse(url, out var ep, out _));
        return ep!;
    }

    [Fact]
    public void RequestCarriesOnlyModelMessagesAndStream()
    {
        var json = AiProtocol.ChatRequestJson("llama3.2", [AiMessage.System("Be brief."), AiMessage.User("Say \"hi\"\nplease")]);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        Assert.Equal(["model", "messages", "stream"], root.EnumerateObject().Select(p => p.Name));
        Assert.Equal("llama3.2", root.GetProperty("model").GetString());
        Assert.True(root.GetProperty("stream").GetBoolean());
        var messages = root.GetProperty("messages").EnumerateArray().ToList();
        Assert.Equal("system", messages[0].GetProperty("role").GetString());
        Assert.Equal("Say \"hi\"\nplease", messages[1].GetProperty("content").GetString());
    }

    [Fact]
    public void ParsesModelLists()
    {
        Assert.Equal(["gemma3:4b", "llama3.2:latest"],
            AiProtocol.ParseModels("""{"object":"list","data":[{"id":"llama3.2:latest","object":"model"},{"id":"gemma3:4b"},{"id":""},{"x":1}]}"""));
        Assert.Empty(AiProtocol.ParseModels("""{"data":[]}"""));
        Assert.Throws<AiException>(() => AiProtocol.ParseModels("""{"models":[]}"""));
        Assert.Throws<AiException>(() => AiProtocol.ParseModels("<html>"));
    }

    [Theory]
    [InlineData("""{"error":{"message":"model \"x\" not found, try pulling it first","type":"api_error"}}""", "model \"x\" not found, try pulling it first")]
    [InlineData("""{"error":"bad key"}""", "bad key")]
    [InlineData("""{"detail":"Not Found"}""", "Not Found")]
    [InlineData("plain text failure", "plain text failure")]
    [InlineData("<html><body>502</body></html>", null)]
    [InlineData("", null)]
    public void ReadsServerErrors(string body, string? expected) => Assert.Equal(expected, AiProtocol.ErrorMessageOf(body));

    [Fact]
    public void WordsHttpErrorsForTheUser()
    {
        var ollama = Endpoint();
        Assert.Contains("API key", AiProtocol.DescribeError(401, null, "m", ollama));
        var missing = AiProtocol.DescribeError(404, "model \"phi4\" not found, try pulling it first", "phi4", ollama);
        Assert.Contains("ollama pull phi4", missing);
        Assert.Contains("not found", missing);
        var cloud = Endpoint("https://api.example.com/v1");
        Assert.DoesNotContain("ollama", AiProtocol.DescribeError(404, "The model `x` does not exist", "x", cloud), StringComparison.OrdinalIgnoreCase);
        Assert.Contains("/v1", AiProtocol.DescribeError(404, null, "x", cloud));
        Assert.Contains("fewer pages", AiProtocol.DescribeError(400, "This model's maximum context length is 8192 tokens", "x", cloud));
        Assert.Contains("429", AiProtocol.DescribeError(429, null, "x", cloud));
        Assert.Contains("500", AiProtocol.DescribeError(500, null, "x", cloud));
    }

    [Fact]
    public void ParsesAStreamedAnswer()
    {
        var p = new AiStreamParser();
        var text = new StringBuilder();
        foreach (var line in new[]
                 {
                     ": keep-alive",
                     """data: {"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}""", "",
                     """data: {"id":"1","choices":[{"index":0,"delta":{"content":"Hello"}}]}""", "",
                     """data:{"id":"1","choices":[{"index":0,"delta":{"content":", world"}}]}""", "",
                     "event: ping", "id: 7",
                     """data: {"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}""", "",
                     "data: [DONE]", "",
                     """data: {"choices":[{"delta":{"content":"after done"}}]}""",
                 })
            text.Append(p.Line(line));
        text.Append(p.End());
        Assert.Equal("Hello, world", text.ToString());
        Assert.True(p.Done);
        Assert.Equal("stop", p.FinishReason);
    }

    [Fact]
    public void JoinsJsonSplitOverDataLines()
    {
        // The first line alone isn't JSON, so it waits; together they are.
        var p = new AiStreamParser();
        Assert.Equal("", p.Line("""data: {"choices":[{"delta":"""));
        Assert.Equal("joined", p.Line("""data: {"content":"joined"}}]}"""));
        Assert.Equal("", p.Line(""));
    }

    [Fact]
    public void ReadsPlainJsonLinesAndSkipsOtherChoices()
    {
        var p = new AiStreamParser();
        Assert.Equal("a", p.Line("""{"choices":[{"index":0,"delta":{"content":"a"}},{"index":1,"delta":{"content":"b"}}]}"""));
        Assert.Equal("", p.Line("""{"choices":[{"index":0,"delta":{"reasoning_content":"thinking"}}]}"""));
        Assert.Equal("len", p.Line("""data: {"choices":[{"index":0,"delta":{"content":"len"},"finish_reason":"length"}]}"""));
        Assert.Equal("length", p.FinishReason);
    }

    [Fact]
    public void StreamErrorsThrow()
    {
        var p = new AiStreamParser();
        var ex = Assert.Throws<AiException>(() => p.Line("""data: {"error":{"message":"out of memory"}}"""));
        Assert.Contains("out of memory", ex.Message);
        var q = new AiStreamParser();
        q.Line("data: not json at all");
        Assert.Throws<AiException>(() => q.Line(""));
    }

    [Fact]
    public void ParsesAWholeAnswer()
    {
        var (text, reason) = AiStreamParser.ParseWhole("""{"choices":[{"index":0,"message":{"role":"assistant","content":"Done."},"finish_reason":"stop"}]}""");
        Assert.Equal("Done.", text);
        Assert.Equal("stop", reason);
        Assert.Throws<AiException>(() => AiStreamParser.ParseWhole("""{"object":"list"}"""));
        Assert.Throws<AiException>(() => AiStreamParser.ParseWhole("oops"));
    }
}

/// <summary>An HTTP handler that answers from a function and records the requests; no network.</summary>
internal sealed class FakeAiHandler(Func<HttpRequestMessage, string, CancellationToken, Task<HttpResponseMessage>> answer) : HttpMessageHandler
{
    public List<(HttpRequestMessage Request, string Body)> Requests { get; } = [];

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
        Requests.Add((request, body));
        return await answer(request, body, cancellationToken);
    }

    public static HttpResponseMessage Sse(params string[] pieces)
    {
        var sb = new StringBuilder();
        sb.Append(": ping\n\n");
        foreach (var piece in pieces)
            sb.Append("data: ").Append(JsonSerializer.Serialize(new { choices = new[] { new { index = 0, delta = new { content = piece } } } })).Append("\n\n");
        sb.Append("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(sb.ToString(), Encoding.UTF8, "text/event-stream") };
    }

    public static HttpResponseMessage Json(HttpStatusCode status, string json) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
}

/// <summary>A response body that sends <paramref name="first"/> and then nothing, until cancelled.</summary>
internal sealed class StallingStream(string first) : Stream
{
    private readonly byte[] _first = Encoding.UTF8.GetBytes(first);
    private int _pos;

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (_pos < _first.Length)
        {
            var n = Math.Min(buffer.Length, _first.Length - _pos);
            _first.AsMemory(_pos, n).CopyTo(buffer);
            _pos += n;
            return n;
        }
        await Task.Delay(Timeout.Infinite, cancellationToken);
        return 0;
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

public class AiClientTests
{
    private static AiEndpoint Endpoint(string url = AiEndpoint.OllamaUrl)
    {
        Assert.True(AiEndpoint.TryParse(url, out var ep, out _));
        return ep!;
    }

    [Fact]
    public async Task StreamsAChatAnswer()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(FakeAiHandler.Sse("The ", "answer", " [p. 2].")));
        using var client = new AiClient(Endpoint(), "llama3.2", apiKey: null, handler);
        var pieces = new List<string>();
        var reply = await client.ChatAsync([AiMessage.User("Q?")], pieces.Add);

        Assert.Equal("The answer [p. 2].", reply.Text);
        Assert.Equal(["The ", "answer", " [p. 2]."], pieces);
        Assert.Equal("stop", reply.FinishReason);
        Assert.False(reply.WasCutOff);
        var (request, body) = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("http://localhost:11434/v1/chat/completions", request.RequestUri!.AbsoluteUri);
        Assert.Null(request.Headers.Authorization);
        Assert.Contains("\"stream\":true", body);
        Assert.Contains("\"model\":\"llama3.2\"", body);
    }

    [Fact]
    public async Task SendsTheKeyOnlyAsABearerToken()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(FakeAiHandler.Sse("ok")));
        using var client = new AiClient(Endpoint("https://api.example.com/v1"), "m", " sk-test ", handler);
        await client.ChatAsync([AiMessage.User("Q")]);
        var (request, body) = handler.Requests[0];
        Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
        Assert.Equal("sk-test", request.Headers.Authorization.Parameter);
        Assert.DoesNotContain("sk-test", body);
        Assert.False(request.Headers.Contains("Cookie"));
    }

    [Fact]
    public async Task TakesAWholeJsonAnswer()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(FakeAiHandler.Json(HttpStatusCode.OK,
            """{"choices":[{"index":0,"message":{"role":"assistant","content":"All at once"},"finish_reason":"length"}]}""")));
        using var client = new AiClient(Endpoint(), "m", null, handler);
        var reply = await client.ChatAsync([AiMessage.User("Q")]);
        Assert.Equal("All at once", reply.Text);
        Assert.True(reply.WasCutOff);
    }

    [Fact]
    public async Task ExplainsHttpErrors()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(FakeAiHandler.Json(HttpStatusCode.NotFound,
            """{"error":{"message":"model \"phi4\" not found, try pulling it first"}}""")));
        using var client = new AiClient(Endpoint(), "phi4", null, handler);
        var ex = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]));
        Assert.Contains("ollama pull phi4", ex.Message);

        var denied = new FakeAiHandler((_, _, _) => Task.FromResult(FakeAiHandler.Json(HttpStatusCode.Unauthorized, """{"error":{"message":"Incorrect API key"}}""")));
        using var cloud = new AiClient(Endpoint("https://api.example.com/v1"), "m", "bad", denied);
        var ex2 = await Assert.ThrowsAsync<AiException>(() => cloud.ChatAsync([AiMessage.User("Q")]));
        Assert.Contains("API key", ex2.Message);
        Assert.DoesNotContain("bad", ex2.Message.Replace("Incorrect API key", ""));
    }

    [Fact]
    public async Task RefusesRedirects()
    {
        var handler = new FakeAiHandler((_, _, _) =>
        {
            var r = new HttpResponseMessage(HttpStatusCode.TemporaryRedirect);
            r.Headers.Location = new Uri("https://elsewhere.example.net/v1/chat/completions");
            return Task.FromResult(r);
        });
        using var client = new AiClient(Endpoint("https://api.example.com/v1"), "m", null, handler);
        var ex = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]));
        Assert.Contains("elsewhere.example.net", ex.Message);
        Assert.Single(handler.Requests);
    }

    [Theory]
    [InlineData(AiEndpoint.OllamaUrl, "Is Ollama running?")]
    [InlineData(AiEndpoint.LmStudioUrl, "LM Studio")]
    [InlineData("http://192.168.1.50:8000/v1", "Is the server running")]
    public async Task ExplainsRefusedConnections(string url, string hint)
    {
        var handler = new FakeAiHandler((_, _, _) => throw new HttpRequestException(HttpRequestError.ConnectionError, "No connection could be made",
            new SocketException((int)SocketError.ConnectionRefused)));
        using var client = new AiClient(Endpoint(url), "m", null, handler);
        var ex = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]));
        Assert.Contains(hint, ex.Message);
    }

    [Fact]
    public async Task ExplainsUnknownHostsAndCertificates()
    {
        var dns = new FakeAiHandler((_, _, _) => throw new HttpRequestException(HttpRequestError.NameResolutionError, "No such host", new SocketException((int)SocketError.HostNotFound)));
        using var a = new AiClient(Endpoint("https://api.example.com/v1"), "m", null, dns);
        Assert.Contains("Couldn't find api.example.com", (await Assert.ThrowsAsync<AiException>(() => a.ChatAsync([AiMessage.User("Q")]))).Message);
        var tls = new FakeAiHandler((_, _, _) => throw new HttpRequestException(HttpRequestError.SecureConnectionError, "SSL failed"));
        using var b = new AiClient(Endpoint("https://api.example.com/v1"), "m", null, tls);
        Assert.Contains("secure connection", (await Assert.ThrowsAsync<AiException>(() => b.ChatAsync([AiMessage.User("Q")]))).Message);
    }

    [Fact]
    public async Task CancellingStops()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StreamContent(new StallingStream("data: {\"choices\":[{\"delta\":{\"content\":\"Hal\"}}]}\n\n")) { Headers = { ContentType = new("text/event-stream") } },
        }));
        using var client = new AiClient(Endpoint(), "m", null, handler);
        using var cts = new CancellationTokenSource();
        var got = new List<string>();
        var task = client.ChatAsync([AiMessage.User("Q")], s => { got.Add(s); cts.Cancel(); }, cts.Token);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.Equal(["Hal"], got);
    }

    [Fact]
    public async Task GivesUpOnAStalledStream()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StreamContent(new StallingStream("data: {\"choices\":[{\"delta\":{\"content\":\"Hal\"}}]}\n\n")) { Headers = { ContentType = new("text/event-stream") } },
        }));
        using var client = new AiClient(Endpoint(), "m", null, handler, new AiTimeouts(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(200)));
        var ex = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]));
        Assert.Contains("stopped answering", ex.Message);
    }

    [Fact]
    public async Task TimesOutWaitingForTheFirstByte()
    {
        var handler = new FakeAiHandler(async (_, _, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            return new HttpResponseMessage(HttpStatusCode.OK);
        });
        using var client = new AiClient(Endpoint(), "m", null, handler, new AiTimeouts(TimeSpan.FromSeconds(1), TimeSpan.FromMilliseconds(200), TimeSpan.FromSeconds(1)));
        var ex = await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]));
        Assert.Contains("didn't answer", ex.Message);
        Assert.Contains("loading", ex.Message);
    }

    [Fact]
    public async Task EmptyStreamIsAnError()
    {
        var handler = new FakeAiHandler((_, _, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("", Encoding.UTF8, "text/event-stream") }));
        using var client = new AiClient(Endpoint(), "m", null, handler);
        await Assert.ThrowsAsync<AiException>(() => client.ChatAsync([AiMessage.User("Q")]));
    }

    [Fact]
    public async Task ListsModels()
    {
        var handler = new FakeAiHandler((r, _, _) => Task.FromResult(r.RequestUri!.AbsolutePath == "/v1/models"
            ? FakeAiHandler.Json(HttpStatusCode.OK, """{"data":[{"id":"qwen3:8b"},{"id":"llama3.2"}]}""")
            : FakeAiHandler.Json(HttpStatusCode.NotFound, "{}")));
        using var client = new AiClient(Endpoint(), "", null, handler);
        Assert.Equal(["llama3.2", "qwen3:8b"], await client.ListModelsAsync());
        Assert.Equal(HttpMethod.Get, handler.Requests[0].Request.Method);

        var none = new FakeAiHandler((_, _, _) => Task.FromResult(FakeAiHandler.Json(HttpStatusCode.NotFound, "{}")));
        using var c2 = new AiClient(Endpoint(), "", null, none);
        Assert.Empty(await c2.ListModelsAsync());
    }

    [Fact]
    public void LocalEndpointsSkipTheProxyAndNothingRedirects()
    {
        using var local = AiClient.CreateHandler(Endpoint());
        Assert.False(local.UseProxy);
        Assert.False(local.AllowAutoRedirect);
        Assert.False(local.UseCookies);
        using var cloud = AiClient.CreateHandler(Endpoint("https://api.example.com/v1"));
        Assert.True(cloud.UseProxy);
        Assert.False(cloud.AllowAutoRedirect);
    }
}

public class AiTextTests
{
    private static AiPageText[] Pages(params string[] texts) => [.. texts.Select((t, i) => new AiPageText(i, t))];

    [Fact]
    public void PagesThatFitShareOneChunk()
    {
        var chunks = AiText.Chunk(Pages("First page.", "", "Third   page.\n\n\n\nMore."), 1000);
        var c = Assert.Single(chunks);
        Assert.Equal(0, c.FirstPage);
        Assert.Equal(2, c.LastPage);
        Assert.Equal("[Page 1]\nFirst page.\n\n[Page 3]\nThird page.\n\nMore.", c.Text);
        Assert.Equal("pages 1–3", c.PagesText);
    }

    [Fact]
    public void LongTextIsCutAtBreaksWithinTheLimit()
    {
        var para = string.Join(" ", Enumerable.Repeat("Some words make a sentence.", 40)); // ~1100 chars
        var pages = Pages(para, para, para);
        var chunks = AiText.Chunk(pages, 500);
        Assert.True(chunks.Count >= 6);
        Assert.All(chunks, c => Assert.True(c.Text.Length <= 500, $"{c.Text.Length}"));
        Assert.All(chunks, c => Assert.StartsWith("[Page ", c.Text));
        Assert.All(chunks, c => Assert.EndsWith(".", c.Text)); // cut after a sentence
        // Nothing lost: every word comes through once.
        var words = chunks.Sum(c => c.Text.Split(' ', '\n').Count(w => w == "sentence."));
        Assert.Equal(120, words);
    }

    [Fact]
    public void CutsDontSplitSurrogatePairs()
    {
        var emoji = string.Concat(Enumerable.Repeat("😀", 300));
        foreach (var piece in AiText.Pieces(emoji, 101))
        {
            Assert.False(char.IsHighSurrogate(piece[^1]));
            Assert.False(char.IsLowSurrogate(piece[0]));
        }
    }

    [Fact]
    public void FindsPageCitations()
    {
        const string answer = "Rent is due monthly [p. 2]. Fees [pp. 3-4] and [page 5] apply (p. 1); see [p. 99] and [p.7].";
        var cites = AiText.Citations(answer, 10);
        Assert.Equal([1, 2, 4, 0, 6], cites.Select(c => c.Page));
        Assert.Equal("[p. 2]", answer.Substring(cites[0].Start, cites[0].Length));
        Assert.Equal("[pp. 3-4]", answer.Substring(cites[1].Start, cites[1].Length));
        Assert.Empty(AiText.Citations("Paragraph [3] and [p. 0].", 10));
    }

    [Fact]
    public void HidesReasoning()
    {
        Assert.Equal("", AiText.WithoutThinking("<think>Let me see", out var thinking));
        Assert.True(thinking);
        Assert.Equal("Answer.", AiText.WithoutThinking("  <think>hmm\n</think>\n\nAnswer.", out thinking));
        Assert.False(thinking);
        Assert.Equal("No tags", AiText.WithoutThinking("No tags", out thinking));
    }

    [Fact]
    public void BudgetGrowsWithTheContext()
    {
        Assert.True(AiText.InputChars(2048) >= 1500);
        Assert.True(AiText.InputChars(8192) > AiText.InputChars(4096));
        Assert.True(AiText.InputChars(4096) / 3 + 2048 / 2 < 4096); // the text plus room for the answer fits
        Assert.Equal(3, AiText.EstimateTokens("123456789012"));
        Assert.Equal("pages 1–3, 5", AiText.PagesText([0, 1, 2, 4]));
        Assert.Equal("page 4", AiText.PagesText([3]));
    }
}

public class AiPromptTests
{
    private static AiPageText[] Pages(params string[] texts) => [.. texts.Select((t, i) => new AiPageText(i, t))];

    [Fact]
    public async Task ShortDocumentsAreSummarizedInOneRequest()
    {
        var chunks = AiText.Chunk(Pages("Alpha.", "Beta."), 10_000);
        var calls = new List<(IReadOnlyList<AiMessage> Messages, AiStep Step)>();
        var result = await AiPrompts.SummarizeAsync(chunks, 10_000, (m, s, _) =>
        {
            calls.Add((m, s));
            return Task.FromResult("Summary [p. 1]");
        });
        Assert.Equal("Summary [p. 1]", result);
        var call = Assert.Single(calls);
        Assert.True(call.Step.IsFinal);
        Assert.Equal("system", call.Messages[0].Role);
        Assert.Contains("[p. N]", call.Messages[0].Content);
        Assert.Contains("[Page 2]\nBeta.", call.Messages[1].Content);
    }

    [Fact]
    public async Task LongDocumentsAreMappedThenCombined()
    {
        var page = string.Join(" ", Enumerable.Repeat("Words in a sentence.", 60));
        var chunks = AiText.Chunk(Pages(page, page, page, page), 1500);
        Assert.True(chunks.Count >= 4);
        var steps = new List<AiStep>();
        var result = await AiPrompts.SummarizeAsync(chunks, 1500, (m, s, _) =>
        {
            steps.Add(s);
            return Task.FromResult(s.IsFinal ? "Final" : $"Part summary {s.Index}");
        });
        Assert.Equal("Final", result);
        Assert.Equal(chunks.Count + 1, steps.Count);
        Assert.Single(steps, s => s.IsFinal);
        Assert.True(steps[^1].IsFinal);
        Assert.Equal(Enumerable.Range(1, steps.Count), steps.Select(s => s.Index));
    }

    [Fact]
    public async Task LongPartialSummariesAreCombinedInRounds()
    {
        var page = string.Join(" ", Enumerable.Repeat("Words in a sentence.", 60));
        var chunks = AiText.Chunk(Pages(page, page, page, page, page, page), 1500);
        var combine = 0;
        var result = await AiPrompts.SummarizeAsync(chunks, 1500, (m, s, _) =>
        {
            if (m[1].Content.StartsWith("These are summaries", StringComparison.Ordinal)) combine++;
            return Task.FromResult(s.IsFinal ? "Final" : new string('x', 600)); // wordy parts: three don't fit one request
        });
        Assert.Equal("Final", result);
        Assert.True(combine >= 2);
    }

    [Fact]
    public async Task EmptyTextIsRefusedAndCancelStops()
    {
        await Assert.ThrowsAsync<AiException>(() => AiPrompts.SummarizeAsync([], 1000, (_, _, _) => Task.FromResult("")));
        var page = string.Join(" ", Enumerable.Repeat("Words in a sentence.", 60));
        var chunks = AiText.Chunk(Pages(page, page, page), 1500);
        using var cts = new CancellationTokenSource();
        var calls = 0;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => AiPrompts.SummarizeAsync(chunks, 1500, (_, _, _) =>
        {
            calls++;
            cts.Cancel();
            return Task.FromResult("s");
        }, cts.Token));
        Assert.Equal(1, calls);
    }

    [Fact]
    public void AskSendsTheWholeTextWhenItFits()
    {
        var r = AiPrompts.Ask("What is due?", [new AiTurn("Who signs?", "The tenant [p. 1].")], Pages("Lease between A and B.", "Rent is due monthly."), 10_000);
        Assert.False(r.Trimmed);
        Assert.Equal([0, 1], r.Pages);
        Assert.Equal(["system", "user", "assistant", "user"], r.Messages.Select(m => m.Role));
        Assert.Contains("[Page 2]\nRent is due monthly.", r.Messages[0].Content);
        Assert.Equal("What is due?", r.Messages[^1].Content);
    }

    [Fact]
    public void AskPicksTheRelatedPartsOfALongDocument()
    {
        var filler = string.Join(" ", Enumerable.Repeat("General background about the company and its history.", 40));
        var pages = Pages(filler, filler, "The security deposit is two months of rent, returned within 30 days.", filler, filler);
        var r = AiPrompts.Ask("How much is the security deposit?", [], pages, 3000);
        Assert.True(r.Trimmed);
        Assert.Contains(2, r.Pages);
        Assert.Contains("security deposit is two months", r.Messages[0].Content);
        Assert.True(r.Messages.Sum(m => m.Content.Length) < 3000 + AiPrompts.AskSystem.Length + 200);
        Assert.Contains("most related", r.Messages[0].Content);
    }

    [Fact]
    public void AskDropsTheOldestTurnsFirst()
    {
        var history = Enumerable.Range(1, 30).Select(i => new AiTurn($"Question {i}?", new string('a', 200))).ToList();
        var r = AiPrompts.Ask("Last?", history, Pages("Text."), 3000);
        var questions = r.Messages.Where(m => m.Role == "user").Select(m => m.Content).ToList();
        Assert.Equal("Last?", questions[^1]);
        Assert.Contains("Question 30?", questions);
        Assert.DoesNotContain("Question 1?", questions);
    }

    [Fact]
    public void ExplainQuotesTheSelection()
    {
        var m = AiPrompts.Explain("  Force   majeure clause ", 4, 5000);
        Assert.Contains("page 5", m[1].Content);
        Assert.Contains("Force majeure clause", m[1].Content);
        Assert.Throws<AiException>(() => AiPrompts.Explain(new string('x', 6000), 0, 5000));
        Assert.Throws<AiException>(() => AiPrompts.Explain("   ", 0, 5000));
    }

    [Fact]
    public void CopyRestrictionIsReadFromThePermissions()
    {
        // The app asks before sending text of a PDF whose permissions forbid copying (DocumentTab.Ai / AiActions).
        var pdf = PdfSecurity.Protect(ExportTestPdf.Make(), null, null, "owner-pw", new PdfPermissions(Copy: false));
        Assert.False(PdfSecurity.ReadSecurity(pdf, null).Permissions.Copy);
        Assert.False(PdfSecurity.IsOpenPassword(pdf, "owner-pw"));
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } dir)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, "ai-no-copy.pdf"), pdf);
        }
    }

    [Fact]
    public void PreviewShowsEveryRequestAndRole()
    {
        var preview = AiPrompts.Preview([[AiMessage.System("S1"), AiMessage.User("U1")], [AiMessage.User("U2")]]);
        Assert.Contains("Request 1 of 2", preview);
        Assert.Contains("── system ──\nS1", preview);
        Assert.Contains("── user ──\nU2", preview);
        Assert.DoesNotContain("Request", AiPrompts.Preview([[AiMessage.User("only")]]));
    }
}
