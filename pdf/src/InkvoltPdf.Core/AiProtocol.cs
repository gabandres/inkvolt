using System.Text;
using System.Text.Json;

namespace InkvoltPdf.Core;

/// <summary>One chat message: role "system", "user" or "assistant".</summary>
public sealed record AiMessage(string Role, string Content)
{
    /// <summary>Pictures sent with the text (PNG), for a vision model: alternate text for a figure.</summary>
    public IReadOnlyList<byte[]> Images { get; init; } = [];

    public static AiMessage System(string content) => new("system", content);
    public static AiMessage User(string content) => new("user", content);
    public static AiMessage Assistant(string content) => new("assistant", content);
}

/// <summary>A failure talking to the AI endpoint, with a message meant for the user.</summary>
public sealed class AiException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// The OpenAI-compatible chat API (<c>POST {base}/chat/completions</c>, <c>GET {base}/models</c>) that Ollama, LM Studio,
/// llama.cpp, vLLM and the cloud providers share: request bodies, model lists, and error messages worded for the user.
/// </summary>
public static class AiProtocol
{
    /// <summary>
    /// The request body: model, messages and stream, nothing else (no user id, no metadata), plus the answer's limit
    /// (<c>max_tokens</c>) when given: only for servers known to honour it (Ollama maps it to num_predict), since some
    /// cloud models refuse it.
    /// </summary>
    public static string ChatRequestJson(string model, IReadOnlyList<AiMessage> messages, bool stream = true, int? maxTokens = null)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteString("model", model);
            w.WriteStartArray("messages");
            foreach (var m in messages)
            {
                w.WriteStartObject();
                w.WriteString("role", m.Role);
                if (m.Images.Count == 0) w.WriteString("content", m.Content);
                else
                {
                    // Text and pictures as content parts (the OpenAI vision format Ollama and LM Studio accept too).
                    w.WriteStartArray("content");
                    w.WriteStartObject();
                    w.WriteString("type", "text");
                    w.WriteString("text", m.Content);
                    w.WriteEndObject();
                    foreach (var png in m.Images)
                    {
                        w.WriteStartObject();
                        w.WriteString("type", "image_url");
                        w.WriteStartObject("image_url");
                        w.WriteString("url", "data:image/png;base64," + Convert.ToBase64String(png));
                        w.WriteEndObject();
                        w.WriteEndObject();
                    }
                    w.WriteEndArray();
                }
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteBoolean("stream", stream);
            if (maxTokens is { } max) w.WriteNumber("max_tokens", max);
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    /// <summary>The model ids of a <c>/models</c> answer (<c>{"data":[{"id":…}]}</c>), sorted; empty when it has none.</summary>
    /// <exception cref="AiException">The answer isn't a model list.</exception>
    public static IReadOnlyList<string> ParseModels(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
                throw new AiException("The endpoint's model list isn't in the OpenAI format. Type the model's name instead.");
            var ids = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var m in data.EnumerateArray())
                if (m.ValueKind == JsonValueKind.Object && m.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String && id.GetString() is { Length: > 0 } s)
                    ids.Add(s);
            return [.. ids];
        }
        catch (JsonException ex)
        {
            throw new AiException("The endpoint's model list isn't JSON. Is the address right (it usually ends in /v1)?", ex);
        }
    }

    /// <summary>The server's own error text from an error body (<c>{"error":{"message":…}}</c>, <c>{"error":"…"}</c>, <c>{"detail":…}</c>), or null.</summary>
    public static string? ErrorMessageOf(string? body)
    {
        if (string.IsNullOrWhiteSpace(body)) return null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            return ErrorMessageOf(doc.RootElement);
        }
        catch (JsonException)
        {
            var text = body.Trim();
            return text.StartsWith('<') ? null : Shorten(text, 300); // an HTML error page says nothing useful
        }
    }

    internal static string? ErrorMessageOf(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) return null;
        foreach (var name in new[] { "error", "detail", "message" })
        {
            if (!root.TryGetProperty(name, out var e)) continue;
            if (e.ValueKind == JsonValueKind.String) return Shorten(e.GetString()!, 300);
            if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String)
                return Shorten(m.GetString()!, 300);
        }
        return null;
    }

    /// <summary>
    /// Ollama's <c>/api/ps</c>: the context length the running model was loaded with, or null when that model isn't
    /// loaded (or the answer doesn't say). "llama3.2" and "llama3.2:latest" are the same model.
    /// </summary>
    public static int? OllamaLoadedContext(string json, string model)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("models", out var models) || models.ValueKind != JsonValueKind.Array) return null;
            foreach (var m in models.EnumerateArray())
            {
                if (m.ValueKind != JsonValueKind.Object) continue;
                var names = new[] { "name", "model" }.Select(n => m.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null);
                if (!names.Any(n => n is not null && SameModel(n, model))) continue;
                if (m.TryGetProperty("context_length", out var ctx) && ctx.ValueKind == JsonValueKind.Number && ctx.TryGetInt32(out var n2) && n2 > 0) return n2;
            }
        }
        catch (JsonException)
        {
        }
        return null;
    }

    /// <summary>
    /// Ollama's <c>/api/show</c>: the model's own <c>num_ctx</c> parameter (set in its Modelfile; it overrides the server's
    /// default) and the context it was trained for (<c>model_info</c>'s "…context_length"), each null when absent.
    /// </summary>
    public static (int? NumCtx, int? Trained) OllamaShowContext(string json)
    {
        int? numCtx = null, trained = null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return (null, null);
            if (root.TryGetProperty("parameters", out var p) && p.ValueKind == JsonValueKind.String &&
                System.Text.RegularExpressions.Regex.Match(p.GetString()!, @"(?m)^\s*num_ctx\s+(\d+)") is { Success: true } m &&
                int.TryParse(m.Groups[1].Value, out var n) && n > 0)
                numCtx = n;
            if (root.TryGetProperty("model_info", out var info) && info.ValueKind == JsonValueKind.Object)
                foreach (var prop in info.EnumerateObject())
                    if (prop.Name.EndsWith(".context_length", StringComparison.Ordinal) && prop.Value.ValueKind == JsonValueKind.Number &&
                        prop.Value.TryGetInt32(out var t) && t > 0)
                        trained = t;
        }
        catch (JsonException)
        {
        }
        return (numCtx, trained);
    }

    private static bool SameModel(string a, string b)
    {
        static string Norm(string s) => (s.Contains(':') ? s : s + ":latest").ToLowerInvariant();
        return Norm(a.Trim()) == Norm(b.Trim());
    }

    /// <summary>What an HTTP error status means for the user, with the server's own message when it gives one.</summary>
    public static string DescribeError(int status, string? serverMessage, string model, AiEndpoint endpoint)
    {
        var said = string.IsNullOrWhiteSpace(serverMessage) ? "" : $" The server said: \"{serverMessage.Trim()}\"";
        var mentionsModel = serverMessage?.Contains("model", StringComparison.OrdinalIgnoreCase) == true;
        var mentionsContext = serverMessage is { } m && (m.Contains("context", StringComparison.OrdinalIgnoreCase) || m.Contains("too long", StringComparison.OrdinalIgnoreCase) || m.Contains("tokens", StringComparison.OrdinalIgnoreCase));
        return status switch
        {
            401 or 403 => $"{endpoint.Host} refused the request ({status}): check the API key in Settings › AI assistant.{said}",
            404 when mentionsModel =>
                $"The model \"{model}\" isn't available at {endpoint.Host} (404). Pick another one in Settings › AI assistant" +
                (endpoint.ServerName == "Ollama" ? $", or download it with: ollama pull {model}." : ".") + said,
            404 => $"Nothing answers at {endpoint.ChatUrl} (404). Check the endpoint address in Settings › AI assistant (it usually ends in /v1).{said}",
            400 or 413 when mentionsContext => $"The text is too long for the model.{said} Choose fewer pages, or a smaller context size in Settings › AI assistant.",
            400 when mentionsModel => $"{endpoint.Host} doesn't accept the model \"{model}\".{said}",
            429 => $"{endpoint.Host} is limiting requests (429): wait a moment, or check your plan's quota.{said}",
            >= 500 => $"{endpoint.Host} had a problem answering ({status}).{said}",
            _ => $"{endpoint.Host} refused the request ({status}).{said}",
        };
    }

    public static string Shorten(string text, int max) => text.Length <= max ? text : text[..(max - 1)] + "…";
}

/// <summary>
/// Reads a streamed chat answer: server-sent events, one <c>data: {json}</c> chunk per line (a JSON value split over
/// several data lines is joined, as the SSE format allows), <c>data: [DONE]</c> at the end, comments and other fields
/// ignored. Also takes a plain JSON line, for servers that skip the <c>data:</c> prefix.
/// </summary>
public sealed class AiStreamParser
{
    private readonly StringBuilder _data = new();

    /// <summary>Most characters held for one event while its data lines are joined.</summary>
    public const int MaxEventChars = 4 << 20;

    /// <summary>True after <c>[DONE]</c>.</summary>
    public bool Done { get; private set; }

    /// <summary>Why the model stopped ("stop", "length"…), once it says so.</summary>
    public string? FinishReason { get; private set; }

    /// <summary>True when any chunk was read (the stream wasn't empty).</summary>
    public bool SawData { get; private set; }

    /// <summary>Feeds one line (without its line break); returns the answer text it adds, or "".</summary>
    /// <exception cref="AiException">The stream carries an error, or a chunk that isn't JSON.</exception>
    public string Line(string line)
    {
        if (Done) return "";
        if (line.Length == 0) return Flush(strict: true);
        if (line[0] == ':') return ""; // comment / keep-alive
        string payload;
        if (line.StartsWith("data:", StringComparison.Ordinal))
            payload = line.Length > 5 && line[5] == ' ' ? line[6..] : line[5..];
        else if (line.TrimStart().StartsWith('{'))
            payload = line;
        else
            return ""; // event:, id:, retry:
        if (payload.Trim() == "[DONE]")
        {
            _data.Clear();
            Done = true;
            return "";
        }
        if (_data.Length + payload.Length > MaxEventChars)
        {
            _data.Clear();
            throw new AiException("The endpoint sent a streamed chunk too large to be part of an answer.");
        }
        if (_data.Length > 0) _data.Append('\n');
        _data.Append(payload);
        return Flush(strict: false);
    }

    /// <summary>Call at the end of the stream: reads what is left.</summary>
    public string End() => Flush(strict: true);

    private string Flush(bool strict)
    {
        if (_data.Length == 0) return "";
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(_data.ToString());
        }
        catch (JsonException ex)
        {
            if (!strict) return ""; // more data lines may follow
            _data.Clear();
            throw new AiException("The endpoint sent an answer Inkvolt PDF can't read (not OpenAI-compatible streaming).", ex);
        }
        _data.Clear();
        SawData = true;
        using (doc) return Chunk(doc.RootElement);
    }

    private string Chunk(JsonElement root)
    {
        if (AiProtocol.ErrorMessageOf(root) is { } error && root.TryGetProperty("error", out _))
            throw new AiException($"The model stopped with an error: \"{error}\"");
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array)
            return "";
        var sb = new StringBuilder();
        foreach (var c in choices.EnumerateArray())
        {
            if (c.ValueKind != JsonValueKind.Object) continue;
            if (c.TryGetProperty("index", out var i) && !(i.ValueKind == JsonValueKind.Number && i.TryGetInt32(out var index) && index == 0)) continue; // only the first choice
            if (c.TryGetProperty("delta", out var d) && d.ValueKind == JsonValueKind.Object && d.TryGetProperty("content", out var dc) && dc.ValueKind == JsonValueKind.String)
                sb.Append(dc.GetString());
            else if (c.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.Object && m.TryGetProperty("content", out var mc) && mc.ValueKind == JsonValueKind.String)
                sb.Append(mc.GetString());
            else if (c.TryGetProperty("text", out var t) && t.ValueKind == JsonValueKind.String)
                sb.Append(t.GetString());
            if (c.TryGetProperty("finish_reason", out var f) && f.ValueKind == JsonValueKind.String) FinishReason = f.GetString();
        }
        return sb.ToString();
    }

    /// <summary>The text and finish reason of a whole (not streamed) answer, for servers that ignore <c>"stream": true</c>.</summary>
    /// <exception cref="AiException">It isn't a chat completion.</exception>
    public static (string Text, string? FinishReason) ParseWhole(string json)
    {
        var p = new AiStreamParser();
        try
        {
            using var doc = JsonDocument.Parse(json);
            var text = p.Chunk(doc.RootElement);
            if (!doc.RootElement.TryGetProperty("choices", out _))
                throw new AiException("The endpoint's answer isn't an OpenAI-compatible chat completion.");
            return (text, p.FinishReason);
        }
        catch (JsonException ex)
        {
            throw new AiException("The endpoint sent an answer Inkvolt PDF can't read (not JSON).", ex);
        }
    }
}
