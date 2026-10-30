using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>One step of a multi-request job: which request it is, of how many known so far, and whether it is the last.</summary>
public sealed record AiStep(int Index, int Total, bool IsFinal, string What);

/// <summary>A question asked earlier in the conversation and its answer (sent again so follow-ups make sense).</summary>
public sealed record AiTurn(string Question, string Answer);

/// <summary>A chat request about the document: its messages and the pages whose text it carries.</summary>
public sealed record AiAskRequest(IReadOnlyList<AiMessage> Messages, IReadOnlyList<int> Pages, bool Trimmed);

/// <summary>
/// The prompts of the AI assistant's uses (summarize, ask about the document, explain a selection), built only from
/// the text the user picked. Every prompt asks the model to cite pages as [p. N] from the "[Page N]" markers, which the
/// answer view links to the pages.
/// </summary>
public static partial class AiPrompts
{
    public const string SummarySystem =
        "You summarize documents for the reader. Use only the text you are given. Write in the language of the text. " +
        "The text marks where each page starts with [Page N]; after each point, cite the page it comes from as [p. N]. " +
        "If the text is empty or unreadable, say so instead of guessing.";

    public const string AskSystem =
        "You answer questions about a document, using only the document text below. If the answer isn't in it, say so. " +
        "The text marks where each page starts with [Page N]; cite the pages you rely on as [p. N]. " +
        "Answer in the language of the question.";

    public const string ExplainSystem =
        "You explain passages from a document in plain words for the reader: what it says, and any terms a reader may not " +
        "know. Be concise. Use only the passage and general knowledge, and say when something can't be told from the passage. " +
        "Answer in the language of the passage.";

    public const string AltTextSystem =
        "You write alternate text for pictures in documents, for people who use screen readers. Say what the picture shows " +
        "and what it means in the document, in one or two plain sentences (at most 250 characters). Don't start with " +
        "\"Image of\" or \"Picture of\". For a chart, give its kind and main finding. Write in the document's language. " +
        "Answer with the alternate text only.";

    /// <summary>The request for a figure's alternate text: the picture, and the text around it on its page for context.</summary>
    public static IReadOnlyList<AiMessage> AltText(byte[] png, string nearby, string? language, int page)
    {
        var context = AiText.Clean(nearby);
        if (context.Length > 1500) context = context[..1500];
        var lang = string.IsNullOrEmpty(language) ? "" : $" The document's language is {language}.";
        var text = $"Write the alternate text for this picture on page {page + 1}.{lang}" +
                   (context.Length > 0 ? $"\n\nText near it on the page:\n\"\"\"\n{context}\n\"\"\"" : "");
        return [AiMessage.System(AltTextSystem), AiMessage.User(text) with { Images = [png] }];
    }

    /// <summary>A model's answer as alternate text: one paragraph, without quotes or a leading label, at most 250 characters (whole words).</summary>
    public static string CleanAltText(string answer)
    {
        var s = string.Join(' ', answer.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim().Trim('"', '“', '”', '\'');
        foreach (var label in new[] { "Alternate text:", "Alt text:", "Alt:" })
            if (s.StartsWith(label, StringComparison.OrdinalIgnoreCase)) s = s[label.Length..].Trim().Trim('"', '“', '”');
        if (s.Length <= 250) return s;
        var cut = s.LastIndexOf(' ', 250);
        return (cut > 150 ? s[..cut] : s[..250]).TrimEnd(',', ';', ':') + "…";
    }

    /// <summary>The first requests of a summary: one for the whole text when it fits, else one per chunk (the map step).</summary>
    public static IReadOnlyList<IReadOnlyList<AiMessage>> SummaryRequests(IReadOnlyList<AiChunk> chunks)
    {
        if (chunks.Count == 1)
            return [[AiMessage.System(SummarySystem), AiMessage.User($"Summarize this document text ({chunks[0].PagesText}): a short overview, then the key points.\n\n{chunks[0].Text}")]];
        return [.. chunks.Select((c, i) => (IReadOnlyList<AiMessage>)
            [AiMessage.System(SummarySystem), AiMessage.User($"This is part {i + 1} of {chunks.Count} of one document ({c.PagesText}). Summarize this part in a few bullet points.\n\n{c.Text}")])];
    }

    /// <summary>The request that combines partial summaries (the reduce step).</summary>
    public static IReadOnlyList<AiMessage> CombineRequest(IReadOnlyList<(AiChunk Part, string Summary)> parts, bool final)
    {
        var sb = new StringBuilder(final
            ? "These are summaries of consecutive parts of one document. Combine them into one summary: a short overview, then the key points. Keep the [p. N] citations.\n"
            : "These are summaries of consecutive parts of one document. Combine them into one shorter summary of these parts, as bullet points. Keep the [p. N] citations.\n");
        foreach (var (part, summary) in parts) sb.Append($"\n### {Capital(part.PagesText)}\n{summary.Trim()}\n");
        return [AiMessage.System(SummarySystem), AiMessage.User(sb.ToString())];
    }

    /// <summary>
    /// Summarizes <paramref name="chunks"/>: one request when the text fits, else map-reduce (each chunk summarized, then
    /// the partial summaries combined, in rounds while they don't fit one request). <paramref name="ask"/> sends one
    /// request; the last one (<see cref="AiStep.IsFinal"/>) is the answer the user sees. Before each combining round,
    /// <paramref name="confirmCombine"/> gets that round's requests exactly as they will be sent (they carry the model's
    /// own partial summaries); when it declines, nothing more is sent and the answer is the partial summaries as they are.
    /// </summary>
    public static async Task<string> SummarizeAsync(IReadOnlyList<AiChunk> chunks, int inputTokens,
        Func<IReadOnlyList<AiMessage>, AiStep, CancellationToken, Task<string>> ask, CancellationToken cancel = default,
        Func<IReadOnlyList<IReadOnlyList<AiMessage>>, CancellationToken, Task<bool>>? confirmCombine = null)
    {
        if (chunks.Count == 0) throw new AiException("These pages have no text to summarize. Scanned pages need Recognize Text (OCR) first.");
        var first = SummaryRequests(chunks);
        if (first.Count == 1) return await ask(first[0], new AiStep(1, 1, true, $"Summarizing {chunks[0].PagesText}"), cancel);

        var done = 0;
        var total = chunks.Count + 1; // grows if the summaries need more than one combining round
        var parts = new List<(AiChunk Part, string Summary)>();
        for (var i = 0; i < chunks.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            var summary = await ask(first[i], new AiStep(++done, total, false, $"Summarizing part {i + 1} of {chunks.Count} ({chunks[i].PagesText})"), cancel);
            parts.Add((chunks[i], summary));
        }

        while (true)
        {
            cancel.ThrowIfCancellationRequested();
            var groups = Group(parts, inputTokens);
            var round = groups.Count == 1
                ? [CombineRequest(parts, final: true)]
                : groups.Where(g => g.Count > 1).Select(g => CombineRequest(g, final: false)).ToList();
            // A round where every summary is alone in its group sends nothing: no question, straight to shortening them.
            if (round.Count > 0 && confirmCombine is not null && !await confirmCombine(round, cancel)) return PartsAsAnswer(parts);
            if (groups.Count == 1)
                return await ask(round[0], new AiStep(++done, total, true, "Combining the parts into one summary"), cancel);
            total += round.Count; // the requests this round really makes (the final combine is already counted)
            var next = new List<(AiChunk Part, string Summary)>();
            var r = 0;
            foreach (var g in groups)
            {
                var span = new AiChunk(g[0].Part.FirstPage, g[^1].Part.LastPage, "");
                var summary = g.Count == 1 ? g[0].Summary
                    : await ask(round[r++], new AiStep(++done, total, false, $"Combining the summaries of {span.PagesText}"), cancel);
                next.Add((span, summary));
            }
            if (next.Count >= parts.Count) // no progress: the summaries alone are too long; keep the start of each
                next = [.. next.Select(p => (p.Part, AiText.Truncate(p.Summary, Math.Max(60, inputTokens / (next.Count + 1)))))];
            parts = next;
        }
    }

    /// <summary>The partial summaries, each under its pages, when they aren't to be combined.</summary>
    private static string PartsAsAnswer(List<(AiChunk Part, string Summary)> parts) =>
        string.Join("\n\n", parts.Select(p => $"### {Capital(p.Part.PagesText)}\n{p.Summary.Trim()}"));

    /// <summary>Consecutive partial summaries grouped so each group fits one request.</summary>
    private static List<List<(AiChunk Part, string Summary)>> Group(List<(AiChunk Part, string Summary)> parts, int inputTokens)
    {
        var groups = new List<List<(AiChunk, string)>>();
        var current = new List<(AiChunk, string)>();
        var size = 0;
        foreach (var p in parts)
        {
            var len = AiText.EstimateTokens(p.Summary) + 12; // plus its "### Pages …" heading
            if (current.Count > 0 && size + len > inputTokens)
            {
                groups.Add(current);
                current = [];
                size = 0;
            }
            current.Add(p);
            size += len;
        }
        if (current.Count > 0) groups.Add(current);
        return groups;
    }

    /// <summary>
    /// A question about the document. The pages' text goes in the system message, whole when it fits; else only the parts
    /// that share the most words with the question (and the earlier questions), in page order, so the request fits
    /// <paramref name="inputTokens"/>. Earlier turns are kept, oldest dropped first, within a third of the budget.
    /// </summary>
    public static AiAskRequest Ask(string question, IReadOnlyList<AiTurn> history, IReadOnlyList<AiPageText> pages, int inputTokens)
    {
        question = question.Trim();
        var turns = new List<AiTurn>();
        var historySize = 0;
        foreach (var t in history.Reverse())
        {
            var len = AiText.EstimateTokens(t.Question) + AiText.EstimateTokens(t.Answer) + 8;
            if (historySize + len > inputTokens / 3) break;
            turns.Insert(0, t);
            historySize += len;
        }

        var room = Math.Max(150, inputTokens - historySize - AiText.EstimateTokens(question));
        var all = AiText.Chunk(pages, Math.Max(room / 6, 150)); // small pieces, so relevant ones can be picked
        var whole = all.Sum(c => AiText.EstimateTokens(c.Text) + 1);
        List<AiChunk> chosen;
        var trimmed = false;
        if (whole <= room) chosen = [.. all];
        else
        {
            trimmed = true;
            var words = Words(string.Join(' ', turns.Select(t => t.Question).Append(question)));
            var picked = new List<(AiChunk Chunk, int Index)>();
            var size = 0;
            foreach (var x in all.Select((c, i) => (c, i, score: Score(c.Text, words))).OrderByDescending(x => x.score).ThenBy(x => x.i))
            {
                var tokens = AiText.EstimateTokens(x.c.Text) + 1;
                if (size + tokens > room) continue;
                picked.Add((x.c, x.i));
                size += tokens;
            }
            chosen = [.. picked.OrderBy(p => p.Index).Select(p => p.Chunk)]; // back in reading order
        }

        var included = chosen.SelectMany(c => Enumerable.Range(c.FirstPage, c.LastPage - c.FirstPage + 1)).Distinct().Order().ToList();
        var scope = included.Count == 0 ? "(the chosen pages have no text)"
            : trimmed ? $"Excerpts from {AiText.PagesText(included)} (the parts most related to the question):"
            : $"Text of {AiText.PagesText(included)}:";
        var messages = new List<AiMessage> { AiMessage.System($"{AskSystem}\n\n{scope}\n\n{string.Join("\n\n", chosen.Select(c => c.Text))}") };
        foreach (var t in turns)
        {
            messages.Add(AiMessage.User(t.Question));
            messages.Add(AiMessage.Assistant(t.Answer));
        }
        messages.Add(AiMessage.User(question));
        return new AiAskRequest(messages, included, trimmed);
    }

    /// <summary>"Explain this passage" for a selection on <paramref name="page"/> (0-based).</summary>
    /// <exception cref="AiException">The selection is longer than one request can carry.</exception>
    public static IReadOnlyList<AiMessage> Explain(string selection, int page, int inputTokens)
    {
        var text = AiText.Clean(selection);
        if (text.Length == 0) throw new AiException("The selection has no text to explain.");
        if (AiText.EstimateTokens(text) is var tokens && tokens > inputTokens)
            throw new AiException($"The selection is too long to explain at once (about {tokens:N0} tokens; the model's context leaves room for about {inputTokens:N0}). " +
                                  "Select less, or use Summarize for whole pages.");
        return [AiMessage.System(ExplainSystem), AiMessage.User($"Explain this passage from page {page + 1}:\n\n\"\"\"\n{text}\n\"\"\"")];
    }

    /// <summary>The requests exactly as sent (roles and text), for the "what will be sent" preview.</summary>
    public static string Preview(IReadOnlyList<IReadOnlyList<AiMessage>> requests)
    {
        var sb = new StringBuilder();
        for (var r = 0; r < requests.Count; r++)
        {
            if (requests.Count > 1) sb.Append($"══════ Request {r + 1} of {requests.Count} ══════\n");
            foreach (var m in requests[r])
            {
                sb.Append($"── {m.Role} ──\n{m.Content}\n");
                foreach (var png in m.Images) sb.Append($"[a picture: PNG, {PngSize(png)}, {png.Length / 1024.0:0.#} KB]\n");
                sb.Append('\n');
            }
        }
        return sb.ToString().TrimEnd() + "\n";
    }

    private static string PngSize(byte[] png) => png.Length >= 24
        ? $"{System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(16))} × {System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(20))} pixels"
        : "?";

    private static string Capital(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

    private static HashSet<string> Words(string text) =>
        [.. WordPattern().Matches(text.ToLowerInvariant()).Select(m => m.Value).Where(w => w.Length >= 3 && !StopWords.Contains(w))];

    private static double Score(string text, HashSet<string> words)
    {
        if (words.Count == 0) return 0;
        var counts = new Dictionary<string, int>();
        foreach (Match m in WordPattern().Matches(text.ToLowerInvariant()))
            if (words.Contains(m.Value)) counts[m.Value] = counts.GetValueOrDefault(m.Value) + 1;
        // Distinct words matter most; repeats add a little (log-scaled), per character so long pieces don't win by size.
        return counts.Count * 10 + counts.Values.Sum(c => Math.Log(1 + c)) - text.Length / 100_000.0;
    }

    private static readonly HashSet<string> StopWords =
    [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "has", "have", "her", "his", "how", "its",
        "may", "our", "out", "she", "that", "their", "them", "then", "there", "these", "they", "this", "was", "what",
        "when", "where", "which", "who", "why", "will", "with", "would", "does", "did", "from", "about", "into", "than",
        "document", "page", "pages", "tell", "say", "says", "said", "please",
    ];

    [GeneratedRegex(@"\p{L}[\p{L}\p{Mn}\p{Nd}'’-]*|\p{Nd}+")]
    private static partial Regex WordPattern();
}
