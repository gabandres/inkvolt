using System.Text;
using System.Text.Json;

namespace InkvoltPdf.Core;

/// <summary>What an Edit by Asking step does: one of a small set of the command palette's commands, each undoable or harmless.</summary>
public enum AskEditKind { GoToPage, RotatePages, DeletePages, AddBookmark, HighlightText, FindForRedaction }

/// <summary>
/// One step the model proposed, checked: its pages (0-based, in range), and its other arguments within their limits. It
/// runs only when the person ticks it and presses Run.
/// </summary>
public sealed record AskEditStep(AskEditKind Kind)
{
    public IReadOnlyList<int> Pages { get; init; } = [];
    public int Degrees { get; init; }
    public string Text { get; init; } = "";
    public IReadOnlySet<RedactionPattern> Patterns { get; init; } = new HashSet<RedactionPattern>();

    /// <summary>What the step does, in the interface's language, as the person sees it before it runs.</summary>
    public string Describe() => Kind switch
    {
        AskEditKind.GoToPage => Loc.Format(PdfStrings.AskEdit_GoToPage, Pages[0] + 1),
        AskEditKind.RotatePages => Loc.Format(Degrees switch { 90 => PdfStrings.AskEdit_RotateRight, 270 => PdfStrings.AskEdit_RotateLeft, _ => PdfStrings.AskEdit_Rotate180 },
            AiText.PagesText(Pages)),
        AskEditKind.DeletePages => Loc.Format(PdfStrings.AskEdit_Delete, AiText.PagesText(Pages)),
        AskEditKind.AddBookmark => Loc.Format(PdfStrings.AskEdit_Bookmark, Text, Pages[0] + 1),
        AskEditKind.HighlightText => Loc.Format(PdfStrings.AskEdit_Highlight, Text),
        _ => Loc.Format(PdfStrings.AskEdit_Redact, string.Join(", ", Patterns.Select(RedactionPatterns.Name).Concat(Text.Length > 0 ? [$"\"{Text}\""] : []))),
    };
}

/// <summary>What the model answered: the steps it proposed that check out, what it proposed that doesn't (said why), and its words when it called nothing.</summary>
public sealed record AskEditPlan(IReadOnlyList<AskEditStep> Steps, IReadOnlyList<string> Refused, string? Said);

/// <summary>
/// Edit by Asking (roadmap 4.23, free): the user's own endpoint, with tool calling, maps a request in the person's words
/// onto a few of the command palette's commands (go to a page, rotate or delete pages, add a bookmark, highlight a word or
/// phrase, find pattern matches for redaction's review list). The request sends the person's words, the page count and the
/// current page: no document text. The answer is data: only calls of these tools with arguments that check out become
/// steps; nothing runs from the model's text, every step is shown and runs only on the person's click, and each edit is one
/// undo step. A model that can't call tools is refused with a word on which can.
/// </summary>
public static class AskEdit
{
    /// <summary>Most steps taken from one answer (the rest are said to be left out).</summary>
    public const int MaxSteps = 10;

    /// <summary>Longest request, bookmark title and text to highlight or find.</summary>
    public const int MaxRequestChars = 500, MaxTitleChars = 120, MaxTextChars = 200;

    public const string SystemPrompt =
        "You turn a person's request about the PDF they have open into calls of the tools you are given, in the order to do them. " +
        "Use only those tools; page numbers start at 1. Page numbers always mean the pages as they are now, before any of the steps. " +
        "If the request can't be done with these tools, call none and say so in one short sentence. Never invent text to add.";

    /// <summary>Kinds a redaction step can look for, by the names the tool offers.</summary>
    private static readonly Dictionary<string, RedactionPattern> PatternNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["email"] = RedactionPattern.Email, ["phone"] = RedactionPattern.Phone, ["ssn"] = RedactionPattern.SocialSecurity,
        ["card"] = RedactionPattern.PaymentCard, ["date"] = RedactionPattern.Date, ["iban"] = RedactionPattern.Iban,
        ["ip"] = RedactionPattern.IpAddress, ["zip"] = RedactionPattern.ZipCode,
    };

    /// <summary>The messages: the instructions, where the person is (page count and page), and their request. No document text.</summary>
    public static IReadOnlyList<AiMessage> Messages(string request, int pageCount, int currentPage)
    {
        var text = request.Trim().ReplaceLineEndings(" ");
        if (text.Length > MaxRequestChars) text = text[..MaxRequestChars];
        return
        [
            AiMessage.System($"{SystemPrompt}\n\nThe document has {pageCount} {(pageCount == 1 ? "page" : "pages")}; the person is on page {Math.Clamp(currentPage, 0, Math.Max(0, pageCount - 1)) + 1}."),
            AiMessage.User(text),
        ];
    }

    /// <summary>The request body: model, messages, the tools, not streamed. Nothing else.</summary>
    public static string RequestJson(string model, IReadOnlyList<AiMessage> messages)
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
                w.WriteString("content", m.Content);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WritePropertyName("tools");
            using (var tools = JsonDocument.Parse(ToolsJson)) tools.RootElement.WriteTo(w);
            w.WriteBoolean("stream", false);
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    /// <summary>The tools as the OpenAI-compatible API takes them (shown in the send window as they go).</summary>
    public const string ToolsJson = """
        [
          {"type":"function","function":{"name":"go_to_page","description":"Show a page.","parameters":{"type":"object","properties":{"page":{"type":"integer","description":"Page number, from 1."}},"required":["page"]}}},
          {"type":"function","function":{"name":"rotate_pages","description":"Turn pages a quarter turn clockwise (90), half a turn (180) or a quarter turn counterclockwise (270).","parameters":{"type":"object","properties":{"pages":{"type":"string","description":"Pages such as \"1-3, 5\" or \"all\"."},"degrees":{"type":"integer","enum":[90,180,270]}},"required":["pages","degrees"]}}},
          {"type":"function","function":{"name":"delete_pages","description":"Delete pages.","parameters":{"type":"object","properties":{"pages":{"type":"string","description":"Pages such as \"1-3, 5\"."}},"required":["pages"]}}},
          {"type":"function","function":{"name":"add_bookmark","description":"Add a bookmark that goes to a page.","parameters":{"type":"object","properties":{"title":{"type":"string"},"page":{"type":"integer","description":"Page number, from 1."}},"required":["title","page"]}}},
          {"type":"function","function":{"name":"highlight_text","description":"Highlight every place a word or phrase appears.","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}},
          {"type":"function","function":{"name":"find_for_redaction","description":"Find things to redact and list them for the person to review: kinds of data, or a word or phrase.","parameters":{"type":"object","properties":{"kinds":{"type":"array","items":{"type":"string","enum":["email","phone","ssn","card","date","iban","ip","zip"]}},"text":{"type":"string"}}}}}
        ]
        """;

    /// <summary>
    /// Reads a chat completion's tool calls into steps for a document of <paramref name="pageCount"/> pages. A call of
    /// another tool, with arguments that aren't JSON, pages out of range or other values out of their limits is refused
    /// and said; past <see cref="MaxSteps"/> steps the rest are left out and said.
    /// </summary>
    /// <exception cref="AiException">The answer isn't a chat completion.</exception>
    public static AskEditPlan Parse(string json, int pageCount)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (JsonException ex)
        {
            throw new AiException(PdfStrings.Ai_NotJson, ex);
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (AiProtocol.ErrorMessageOf(root) is { } error && root.TryGetProperty("error", out _))
                throw new AiException(Loc.Format(PdfStrings.Ai_ModelError, error));
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array ||
                choices.GetArrayLength() == 0 || choices[0].ValueKind != JsonValueKind.Object || !choices[0].TryGetProperty("message", out var message) ||
                message.ValueKind != JsonValueKind.Object)
                throw new AiException(PdfStrings.Ai_NotChatCompletion);
            var said = message.TryGetProperty("content", out var c) && c.ValueKind == JsonValueKind.String ? AiText.WithoutThinking(c.GetString()!, out _).Trim() : null;
            var steps = new List<AskEditStep>();
            var refused = new List<string>();
            if (message.TryGetProperty("tool_calls", out var calls) && calls.ValueKind == JsonValueKind.Array)
            {
                foreach (var call in calls.EnumerateArray())
                {
                    if (steps.Count >= MaxSteps)
                    {
                        refused.Add(Loc.Format(PdfStrings.AskEdit_TooMany, MaxSteps));
                        break;
                    }
                    var (step, why) = Read(call, pageCount);
                    if (step is not null) steps.Add(step);
                    else refused.Add(why!);
                }
            }
            return new AskEditPlan(steps, refused, string.IsNullOrEmpty(said) ? null : AiProtocol.Shorten(said, 600));
        }
    }

    private static (AskEditStep? Step, string? Why) Read(JsonElement call, int pageCount)
    {
        if (call.ValueKind != JsonValueKind.Object || !call.TryGetProperty("function", out var f) || f.ValueKind != JsonValueKind.Object ||
            !f.TryGetProperty("name", out var n) || n.ValueKind != JsonValueKind.String)
            return (null, PdfStrings.AskEdit_NotACall);
        var name = n.GetString()!;
        var shown = AiProtocol.Shorten(name, 40);
        JsonDocument? owned = null;
        try
        {
            // Arguments come as a JSON string (OpenAI) or an object (Ollama).
            JsonElement args;
            if (!f.TryGetProperty("arguments", out var a)) args = default;
            else if (a.ValueKind == JsonValueKind.String)
            {
                try
                {
                    owned = JsonDocument.Parse(a.GetString()!.Length == 0 ? "{}" : a.GetString()!);
                }
                catch (JsonException)
                {
                    return (null, Loc.Format(PdfStrings.AskEdit_BadArguments, shown));
                }
                args = owned.RootElement;
            }
            else args = a;
            if (args.ValueKind is not (JsonValueKind.Object or JsonValueKind.Undefined)) return (null, Loc.Format(PdfStrings.AskEdit_BadArguments, shown));

            string? Str(string key) => args.ValueKind == JsonValueKind.Object && args.TryGetProperty(key, out var v)
                ? v.ValueKind switch { JsonValueKind.String => v.GetString(), JsonValueKind.Number => v.GetRawText(), _ => null } : null;
            int? Int(string key) => Str(key) is { } s && int.TryParse(s.Trim(), out var i) ? i : null;
            int? Page() => Int("page") is { } p && p >= 1 && p <= pageCount ? p - 1 : null;
            int[]? Pages()
            {
                var s = Str("pages")?.Trim();
                if (string.IsNullOrEmpty(s)) return null;
                if (s.Equals("all", StringComparison.OrdinalIgnoreCase)) return [.. Enumerable.Range(0, pageCount)];
                return PageRange.TryParse(s, pageCount, out var pages, out _) && pages.Length > 0 ? pages : null;
            }
            string? Words(string key, int max) => Str(key) is { } s && Clean(s) is { Length: > 0 } t && t.Length <= max ? t : null;

            switch (name)
            {
                case "go_to_page":
                    return Page() is { } go ? (new AskEditStep(AskEditKind.GoToPage) { Pages = [go] }, null) : (null, Loc.Format(PdfStrings.AskEdit_NoSuchPage, shown, pageCount));
                case "rotate_pages":
                {
                    if (Pages() is not { } pages) return (null, Loc.Format(PdfStrings.AskEdit_NoSuchPage, shown, pageCount));
                    var degrees = Int("degrees") is { } d ? ((d % 360) + 360) % 360 : -1;
                    return degrees is 90 or 180 or 270 ? (new AskEditStep(AskEditKind.RotatePages) { Pages = pages, Degrees = degrees }, null) : (null, Loc.Format(PdfStrings.AskEdit_BadArguments, shown));
                }
                case "delete_pages":
                {
                    if (Pages() is not { } pages) return (null, Loc.Format(PdfStrings.AskEdit_NoSuchPage, shown, pageCount));
                    return pages.Length >= pageCount ? (null, PdfStrings.AskEdit_NotAllPages) : (new AskEditStep(AskEditKind.DeletePages) { Pages = pages }, null);
                }
                case "add_bookmark":
                {
                    if (Page() is not { } page) return (null, Loc.Format(PdfStrings.AskEdit_NoSuchPage, shown, pageCount));
                    return Words("title", MaxTitleChars) is { } title ? (new AskEditStep(AskEditKind.AddBookmark) { Pages = [page], Text = title }, null) : (null, Loc.Format(PdfStrings.AskEdit_BadArguments, shown));
                }
                case "highlight_text":
                    return Words("text", MaxTextChars) is { } text ? (new AskEditStep(AskEditKind.HighlightText) { Text = text }, null) : (null, Loc.Format(PdfStrings.AskEdit_BadArguments, shown));
                case "find_for_redaction":
                {
                    var kinds = new HashSet<RedactionPattern>();
                    if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty("kinds", out var k))
                    {
                        if (k.ValueKind != JsonValueKind.Array) return (null, Loc.Format(PdfStrings.AskEdit_BadArguments, shown));
                        foreach (var item in k.EnumerateArray())
                        {
                            if (item.ValueKind != JsonValueKind.String || !PatternNames.TryGetValue(item.GetString()!, out var pattern))
                                return (null, Loc.Format(PdfStrings.AskEdit_BadArguments, shown));
                            kinds.Add(pattern);
                        }
                    }
                    var phrase = Str("text") is { } raw && raw.Trim().Length > 0 ? Words("text", MaxTextChars) : "";
                    if (phrase is null || (kinds.Count == 0 && phrase.Length == 0)) return (null, Loc.Format(PdfStrings.AskEdit_BadArguments, shown));
                    return (new AskEditStep(AskEditKind.FindForRedaction) { Patterns = kinds, Text = phrase }, null);
                }
                default:
                    return (null, Loc.Format(PdfStrings.AskEdit_UnknownTool, shown));
            }
        }
        finally
        {
            owned?.Dispose();
        }
    }

    /// <summary>Text from the model as one line without control characters, trimmed.</summary>
    private static string Clean(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s) sb.Append(char.IsControl(ch) || char.GetUnicodeCategory(ch) is System.Globalization.UnicodeCategory.LineSeparator or System.Globalization.UnicodeCategory.ParagraphSeparator ? ' ' : ch);
        return sb.ToString().Trim();
    }

    /// <summary>
    /// A step's pages once <paramref name="deleted"/> (0-based, of the document as it was asked about) are gone: each page
    /// after them moves up. Null when every page the step needs went (it is then left out and said).
    /// </summary>
    public static AskEditStep? AfterDelete(AskEditStep step, IReadOnlyCollection<int> deleted)
    {
        if (deleted.Count == 0 || step.Pages.Count == 0) return step;
        var gone = deleted.ToHashSet();
        var kept = step.Pages.Where(p => !gone.Contains(p)).Select(p => p - deleted.Count(d => d < p)).ToList();
        if (kept.Count == 0) return null;
        return step with { Pages = kept };
    }

    /// <summary>True when the server's refusal says the model can't call tools (Ollama: "… does not support tools").</summary>
    public static bool IsNoToolsError(int status, string? serverMessage) =>
        status is 400 or 404 or 422 or 500 && serverMessage is { } m && m.Contains("tool", StringComparison.OrdinalIgnoreCase) &&
        (m.Contains("support", StringComparison.OrdinalIgnoreCase) || m.Contains("not allowed", StringComparison.OrdinalIgnoreCase) || m.Contains("unknown", StringComparison.OrdinalIgnoreCase));
}

public sealed partial class AiClient
{
    /// <summary>
    /// One chat request with the Edit by Asking tools, not streamed; its answer read into checked steps. A model that
    /// can't call tools is said so, in words.
    /// </summary>
    /// <exception cref="AiException">The endpoint refused, failed, or the model can't call tools.</exception>
    public async Task<AskEditPlan> AskEditAsync(IReadOnlyList<AiMessage> messages, int pageCount, CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint.ChatUrl)
        {
            Content = new StringContent(AskEdit.RequestJson(_model, messages), Encoding.UTF8, "application/json"),
        };
        Authorize(request);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(_timeouts.FirstByte);
        using var response = await Send(request, cts, cancel, _timeouts.FirstByte);
        var body = await ReadBody(response, cts, cancel, truncate: !response.IsSuccessStatusCode);
        if (!response.IsSuccessStatusCode)
        {
            var said = AiProtocol.ErrorMessageOf(body);
            throw new AiException(AskEdit.IsNoToolsError((int)response.StatusCode, said)
                ? Loc.Format(PdfStrings.AskEdit_NoTools, _model, _endpoint.Host)
                : AiProtocol.DescribeError((int)response.StatusCode, said, _model, _endpoint)) { Status = (int)response.StatusCode };
        }
        return AskEdit.Parse(body, pageCount);
    }
}
