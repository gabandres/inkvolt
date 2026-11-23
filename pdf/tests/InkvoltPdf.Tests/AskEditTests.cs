using System.Net;
using System.Text.Json;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 4.23, Edit by Asking: the request carries the person's words, the page count and the page in view (no
/// document text) with a few palette commands as tools; the answer is data, and only calls of those tools with arguments
/// that check out become steps. A fake endpoint answers: no network.
/// </summary>
public sealed class AskEditTests
{
    private static string Completion(string? content, params (string Name, string Args)[] calls) => JsonSerializer.Serialize(new
    {
        choices = new[]
        {
            new
            {
                index = 0,
                message = new { role = "assistant", content, tool_calls = calls.Select((c, i) => new { id = $"c{i}", type = "function", function = new { name = c.Name, arguments = c.Args } }) },
            },
        },
    });

    [Fact]
    public void The_request_carries_the_words_and_where_the_person_is_and_the_tools_but_no_document_text()
    {
        var messages = AskEdit.Messages("rotate the last page\nand bookmark it", 12, 4);
        Assert.Contains("The document has 12 pages; the person is on page 5.", messages[0].Content);
        Assert.Equal("rotate the last page and bookmark it", messages[1].Content);
        Assert.Equal(AskEdit.MaxRequestChars, AskEdit.Messages(new string('x', 900), 1, 0)[1].Content.Length);

        using var json = JsonDocument.Parse(AskEdit.RequestJson("qwen3", messages));
        Assert.Equal(["model", "messages", "tools", "stream"], json.RootElement.EnumerateObject().Select(p => p.Name));
        Assert.False(json.RootElement.GetProperty("stream").GetBoolean());
        Assert.Equal(["go_to_page", "rotate_pages", "delete_pages", "add_bookmark", "highlight_text", "find_for_redaction"],
            json.RootElement.GetProperty("tools").EnumerateArray().Select(t => t.GetProperty("function").GetProperty("name").GetString()));
    }

    [Fact]
    public void Calls_of_the_tools_become_checked_steps_with_0_based_pages()
    {
        var plan = AskEdit.Parse(Completion(null,
            ("rotate_pages", """{"pages":"1-3","degrees":-90}"""),
            ("delete_pages", """{"pages":"5"}"""),
            ("add_bookmark", """{"title":"  Appendix\nA  ","page":6}"""),
            ("highlight_text", """{"text":"deadline"}"""),
            ("go_to_page", """{"page":"2"}"""),
            ("find_for_redaction", """{"kinds":["email","ssn"],"text":"Jane Doe"}""")), 10);
        Assert.Empty(plan.Refused);
        Assert.Equal(6, plan.Steps.Count);
        Assert.Equal((AskEditKind.RotatePages, 270), (plan.Steps[0].Kind, plan.Steps[0].Degrees));
        Assert.Equal([0, 1, 2], plan.Steps[0].Pages);
        Assert.Equal("Rotate pages 1–3 counterclockwise", plan.Steps[0].Describe());
        Assert.Equal([4], plan.Steps[1].Pages);
        Assert.Equal(("Appendix A", 5), (plan.Steps[2].Text, plan.Steps[2].Pages[0]));
        Assert.Equal("Add a bookmark \"Appendix A\" that goes to page 6", plan.Steps[2].Describe());
        Assert.Equal("deadline", plan.Steps[3].Text);
        Assert.Equal([1], plan.Steps[4].Pages);
        Assert.Equal(new HashSet<RedactionPattern> { RedactionPattern.Email, RedactionPattern.SocialSecurity }, plan.Steps[5].Patterns);
        Assert.Equal("Jane Doe", plan.Steps[5].Text);

        // Ollama sends the arguments as an object rather than a string.
        var ollama = """{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"go_to_page","arguments":{"page":3}}}]}}]}""";
        Assert.Equal([2], Assert.Single(AskEdit.Parse(ollama, 3).Steps).Pages);
    }

    [Fact]
    public void Anything_else_the_model_proposes_is_left_out_and_said()
    {
        var plan = AskEdit.Parse(Completion("Sure! Also run format C:",
            ("erase_disk", "{}"),
            ("go_to_page", """{"page":99}"""),
            ("rotate_pages", """{"pages":"1","degrees":45}"""),
            ("delete_pages", """{"pages":"all"}"""),
            ("add_bookmark", """{"title":"","page":1}"""),
            ("highlight_text", "not json"),
            ("find_for_redaction", """{"kinds":["passwords"]}"""),
            ("find_for_redaction", "{}"),
            ("add_bookmark", $$"""{"title":"{{new string('t', 300)}}","page":1}""")), 4);
        Assert.Empty(plan.Steps);
        Assert.Equal(9, plan.Refused.Count);
        Assert.Contains("erase_disk", plan.Refused[0]);
        Assert.Contains("it has 4", plan.Refused[1]);
        Assert.Contains("keeps at least one page", plan.Refused[3]);
        Assert.Equal("Sure! Also run format C:", plan.Said); // shown as the model's words, never run

        var many = AskEdit.Parse(Completion(null, [.. Enumerable.Repeat(("go_to_page", """{"page":1}"""), 14)]), 2);
        Assert.Equal(AskEdit.MaxSteps, many.Steps.Count);
        Assert.Contains("first 10", Assert.Single(many.Refused));

        Assert.Throws<AiException>(() => AskEdit.Parse("""{"error":{"message":"boom"}}""", 2));
        Assert.Throws<AiException>(() => AskEdit.Parse("""{"answer":"no"}""", 2));
        Assert.Throws<AiException>(() => AskEdit.Parse("<html>", 2));
    }

    [Fact]
    public void Pages_of_later_steps_follow_pages_deleted_before_them()
    {
        var rotate = new AskEditStep(AskEditKind.RotatePages) { Pages = [0, 2, 5], Degrees = 90 };
        Assert.Equal([0, 3], AskEdit.AfterDelete(rotate, [1, 2])!.Pages);
        Assert.Null(AskEdit.AfterDelete(new AskEditStep(AskEditKind.AddBookmark) { Pages = [2], Text = "x" }, [2]));
        var highlight = new AskEditStep(AskEditKind.HighlightText) { Text = "x" };
        Assert.Same(highlight, AskEdit.AfterDelete(highlight, [0]));
    }

    [Fact]
    public void Half_of_a_huge_file_deleted_then_every_page_turned_is_renumbered_in_a_moment()
    {
        // 100,000 pages, 1–50,000 deleted, then all turned: each page counted the deleted ones before it (billions).
        var all = Enumerable.Range(0, 100_000).ToList();
        var deleted = new DeletedPages();
        var clock = System.Diagnostics.Stopwatch.StartNew();
        deleted.AddRange(Enumerable.Range(0, 50_000));
        deleted.AddRange([49_999, 50_000, 3]); // pages already gone count once
        var rotate = AskEdit.AfterDelete(new AskEditStep(AskEditKind.RotatePages) { Pages = all, Degrees = 90 }, deleted);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5), $"took {clock.Elapsed}");
        Assert.Equal(50_001, deleted.Count);
        Assert.Equal(Enumerable.Range(0, 49_999), rotate!.Pages);
    }

    [Fact]
    public async Task A_model_that_cant_call_tools_is_refused_in_words()
    {
        Assert.True(AskEdit.IsNoToolsError(400, "registry.ollama.ai/library/gemma3:4b does not support tools"));
        Assert.False(AskEdit.IsNoToolsError(400, "context length exceeded"));
        var ep = AiEndpoint.TryParse(AiEndpoint.OllamaUrl, out var e, out _) ? e! : throw new InvalidOperationException();
        var handler = new FakeAiHandler((_, body, _) => Task.FromResult(body.Contains("\"gemma3\"")
            ? FakeAiHandler.Json(HttpStatusCode.BadRequest, """{"error":"registry.ollama.ai/library/gemma3 does not support tools"}""")
            : FakeAiHandler.Json(HttpStatusCode.OK, Completion(null, ("go_to_page", """{"page":2}""")))));
        using (var noTools = new AiClient(ep, "gemma3", null, handler))
        {
            var ex = await Assert.ThrowsAsync<AiException>(() => noTools.AskEditAsync(AskEdit.Messages("go to page 2", 3, 0), 3));
            Assert.Contains("can't call tools", ex.Message);
            Assert.Contains("qwen3", ex.Message);
        }
        using var withTools = new AiClient(ep, "qwen3", null, handler);
        var plan = await withTools.AskEditAsync(AskEdit.Messages("go to page 2", 3, 0), 3);
        Assert.Equal(AskEditKind.GoToPage, Assert.Single(plan.Steps).Kind);
        Assert.EndsWith("/v1/chat/completions", handler.Requests[^1].Request.RequestUri!.AbsolutePath);
    }
}
