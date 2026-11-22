using System.Text;
using System.Text.Json;

namespace InkvoltPdf.Core;

/// <summary>Which embeddings API an endpoint speaks.</summary>
public enum EmbedApi
{
    /// <summary>Ollama's own <c>POST /api/embed</c> (<c>{"embeddings":[[…]]}</c>), on the server's root.</summary>
    Ollama,
    /// <summary>The OpenAI-compatible <c>POST {base}/embeddings</c> (<c>{"data":[{"index":0,"embedding":[…]}]}</c>).</summary>
    OpenAi,
}

/// <summary>
/// Embeddings (roadmap 4.21): a model on the user's own endpoint turns text into numbers (a vector) such that texts
/// close in meaning get vectors close in direction. Requests carry the model and the texts only; answers are read as
/// data: every vector the same length, every number finite, one per text, or the answer is refused.
/// </summary>
public static class AiEmbeddings
{
    /// <summary>Most numbers in one vector (the largest common models give 4,096).</summary>
    public const int MaxDimensions = 8192;

    /// <summary>Texts sent in one request.</summary>
    public const int BatchSize = 16;

    /// <summary>The request body, the same for both APIs: the model and the texts, nothing else.</summary>
    public static string RequestJson(string model, IReadOnlyList<string> inputs)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteString("model", model);
            w.WriteStartArray("input");
            foreach (var s in inputs) w.WriteStringValue(s);
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    /// <summary>Where the request goes on <paramref name="endpoint"/>.</summary>
    public static Uri UrlFor(AiEndpoint endpoint, EmbedApi api) =>
        api == EmbedApi.Ollama ? new Uri(endpoint.BaseUrl, "/api/embed") : new Uri(endpoint.Key + "/embeddings");

    /// <summary>The vectors of an answer, one per text asked about, in the order asked.</summary>
    /// <exception cref="AiException">The answer isn't that (another shape, a count or length that doesn't match, a number that isn't one).</exception>
    public static float[][] Parse(string json, EmbedApi api, int count)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw Wrong();
            var vectors = new float[count][];
            if (api == EmbedApi.Ollama)
            {
                if (!root.TryGetProperty("embeddings", out var list) || list.ValueKind != JsonValueKind.Array || list.GetArrayLength() != count) throw Wrong();
                var i = 0;
                foreach (var v in list.EnumerateArray()) vectors[i++] = Vector(v);
            }
            else
            {
                if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array || data.GetArrayLength() != count) throw Wrong();
                var at = 0;
                foreach (var item in data.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("embedding", out var v)) throw Wrong();
                    var index = item.TryGetProperty("index", out var ix) && ix.TryGetInt32(out var n) ? n : at;
                    if (index < 0 || index >= count || vectors[index] is not null) throw Wrong();
                    vectors[index] = Vector(v);
                    at++;
                }
            }
            if (vectors.Any(v => v is null) || vectors.Any(v => v.Length != vectors[0].Length)) throw Wrong();
            return vectors;
        }
        catch (JsonException ex)
        {
            throw new AiException(PdfStrings.Embed_NotEmbeddings, ex);
        }
    }

    private static float[] Vector(JsonElement v)
    {
        if (v.ValueKind != JsonValueKind.Array) throw Wrong();
        var n = v.GetArrayLength();
        if (n == 0 || n > MaxDimensions) throw Wrong();
        var vector = new float[n];
        var i = 0;
        foreach (var x in v.EnumerateArray())
        {
            if (x.ValueKind != JsonValueKind.Number || !x.TryGetDouble(out var d) || !double.IsFinite(d) || Math.Abs(d) > 1e6) throw Wrong();
            vector[i++] = (float)d;
        }
        return vector;
    }

    private static AiException Wrong() => new(PdfStrings.Embed_NotEmbeddings);
}

public sealed partial class AiClient
{
    /// <summary>
    /// The vectors of <paramref name="inputs"/> (at most <see cref="AiEmbeddings.BatchSize"/>) from the model this client was
    /// made for, by <paramref name="api"/>. Sends the model's name and the texts only.
    /// </summary>
    /// <exception cref="AiException">The endpoint refused, failed, or answered something that isn't embeddings.</exception>
    public async Task<float[][]> EmbedAsync(IReadOnlyList<string> inputs, EmbedApi api, CancellationToken cancel = default)
    {
        if (inputs.Count == 0) return [];
        using var request = new HttpRequestMessage(HttpMethod.Post, AiEmbeddings.UrlFor(_endpoint, api))
        {
            Content = new StringContent(AiEmbeddings.RequestJson(_model, inputs), Encoding.UTF8, "application/json"),
        };
        Authorize(request);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(_timeouts.FirstByte);
        using var response = await Send(request, cts, cancel, _timeouts.FirstByte);
        var body = await ReadBody(response, cts, cancel, truncate: !response.IsSuccessStatusCode);
        if (!response.IsSuccessStatusCode)
        {
            var said = AiProtocol.ErrorMessageOf(body);
            // A chat model asked for embeddings: say which kind of model it takes.
            throw new AiException(said?.Contains("embed", StringComparison.OrdinalIgnoreCase) == true || (int)response.StatusCode == 501
                ? Loc.Format(PdfStrings.Embed_NotAnEmbeddingModel, _model, _endpoint.Host, said is null ? "" : Loc.Format(PdfStrings.Ai_ServerSaid, said))
                : AiProtocol.DescribeError((int)response.StatusCode, said, _model, _endpoint)) { Status = (int)response.StatusCode };
        }
        return AiEmbeddings.Parse(body, api, inputs.Count);
    }
}
