using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>A page's text as sent to the model (<paramref name="Page"/> is 0-based).</summary>
public sealed record AiPageText(int Page, string Text);

/// <summary>Consecutive pages' text that fits one request, each page headed by its "[Page N]" marker.</summary>
public sealed record AiChunk(int FirstPage, int LastPage, string Text)
{
    /// <summary>"page 3" or "pages 3–7" (1-based).</summary>
    public string PagesText => AiText.PagesText(FirstPage, LastPage);
}

/// <summary>A "[p. N]" citation in an answer: where it is and the page it names (0-based).</summary>
public sealed record AiCitation(int Start, int Length, int Page);

/// <summary>Text handling for the AI assistant: size estimates, the context budget, chunking, page citations.</summary>
public static partial class AiText
{
    /// <summary>Context sizes offered in Settings (tokens).</summary>
    public static readonly int[] ContextSizes = [2048, 4096, 8192, 16384, 32768, 65536, 131072];

    public const int DefaultContextTokens = 8192;

    /// <summary>A rough token count: about 4 characters per token for English text (other scripts use more tokens).</summary>
    public static int EstimateTokens(string text) => (text.Length + 3) / 4;

    /// <summary>The tokens of a whole request: the messages' text plus a few per message for the chat format.</summary>
    public static int EstimateTokens(IEnumerable<AiMessage> messages) => messages.Sum(m => EstimateTokens(m.Content) + 4);

    /// <summary>
    /// How many characters of document text one request may carry for a model reading <paramref name="contextTokens"/>:
    /// the context minus room for the answer and the instructions, at a cautious 3 characters per token.
    /// </summary>
    public static int InputChars(int contextTokens)
    {
        contextTokens = Math.Max(contextTokens, 1024);
        var answer = Math.Min(2048, contextTokens / 4);
        return Math.Max(1500, (contextTokens - answer - 400) * 3);
    }

    /// <summary>"[Page 3]": the marker before each page's text, which the model cites as [p. 3].</summary>
    public static string PageMarker(int page) => $"[Page {page + 1}]";

    /// <summary>"page 3" or "pages 3–7" (1-based).</summary>
    public static string PagesText(int first, int last) => first == last ? $"page {first + 1}" : $"pages {first + 1}–{last + 1}";

    /// <summary>"pages 1–3, 5" for a set of 0-based pages.</summary>
    public static string PagesText(IEnumerable<int> pages)
    {
        var list = pages.Distinct().Order().ToList();
        return list.Count == 1 ? $"page {list[0] + 1}" : $"pages {PageRange.Format(list).Replace("-", "–")}";
    }

    /// <summary>Tidies extracted text: trims lines, collapses runs of spaces and of blank lines.</summary>
    public static string Clean(string text)
    {
        var sb = new StringBuilder(text.Length);
        var blank = 0;
        foreach (var raw in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = Spaces().Replace(raw, " ").Trim();
            if (line.Length == 0)
            {
                blank++;
                continue;
            }
            if (sb.Length > 0) sb.Append(blank > 0 ? "\n\n" : "\n");
            blank = 0;
            sb.Append(line);
        }
        return sb.ToString();
    }

    /// <summary>
    /// Splits pages into chunks of at most <paramref name="maxChars"/> characters, whole pages where they fit, each page
    /// headed by its marker. A page longer than a chunk is cut at a paragraph, line, sentence or word break (its pieces
    /// keep the page's marker). Pages without text are left out.
    /// </summary>
    public static IReadOnlyList<AiChunk> Chunk(IReadOnlyList<AiPageText> pages, int maxChars)
    {
        maxChars = Math.Max(maxChars, 200);
        var chunks = new List<AiChunk>();
        var sb = new StringBuilder();
        int first = -1, last = -1;

        void Close()
        {
            if (sb.Length == 0) return;
            chunks.Add(new AiChunk(first, last, sb.ToString()));
            sb.Clear();
            first = last = -1;
        }

        foreach (var p in pages)
        {
            var text = Clean(p.Text);
            if (text.Length == 0) continue;
            var marker = PageMarker(p.Page);
            foreach (var piece in Pieces(text, maxChars - marker.Length - 2))
            {
                var block = $"{marker}\n{piece}";
                if (sb.Length > 0 && sb.Length + 2 + block.Length > maxChars) Close();
                if (sb.Length > 0) sb.Append("\n\n");
                sb.Append(block);
                if (first < 0) first = p.Page;
                last = p.Page;
            }
        }
        Close();
        return chunks;
    }

    /// <summary>Cuts text into pieces of at most <paramref name="max"/> characters at the nicest break available.</summary>
    internal static IEnumerable<string> Pieces(string text, int max)
    {
        max = Math.Max(max, 50);
        while (text.Length > max)
        {
            var cut = BreakBefore(text, max);
            yield return text[..cut].TrimEnd();
            text = text[cut..].TrimStart();
        }
        if (text.Length > 0) yield return text;
    }

    private static int BreakBefore(string text, int max)
    {
        var floor = max / 2; // don't make tiny pieces just to break nicely
        foreach (var sep in new[] { "\n\n", "\n", ". ", "? ", "! ", "; ", " " })
        {
            var i = text.LastIndexOf(sep, max - 1, max - floor, StringComparison.Ordinal);
            if (i > 0) return i + sep.Length;
        }
        // No break at all (a long run of letters, or CJK text without spaces): cut, but not inside a surrogate pair.
        return char.IsHighSurrogate(text[max - 1]) ? max - 1 : max;
    }

    /// <summary>The "[p. N]" style citations in an answer that name a page of the document (others are left as text).</summary>
    public static IReadOnlyList<AiCitation> Citations(string text, int pageCount)
    {
        var list = new List<AiCitation>();
        foreach (Match m in CitationPattern().Matches(text))
            if (int.TryParse(m.Groups["n"].Value, out var n) && n >= 1 && n <= pageCount)
                list.Add(new AiCitation(m.Index, m.Length, n - 1));
        return list;
    }

    /// <summary>
    /// The answer without a reasoning model's "&lt;think&gt;…&lt;/think&gt;" part. <paramref name="thinking"/> is true while
    /// that part is still open (streaming), when nothing is shown yet.
    /// </summary>
    public static string WithoutThinking(string text, out bool thinking)
    {
        thinking = false;
        var start = text.TrimStart();
        if (!start.StartsWith("<think>", StringComparison.OrdinalIgnoreCase)) return text;
        var end = start.IndexOf("</think>", StringComparison.OrdinalIgnoreCase);
        if (end < 0)
        {
            thinking = true;
            return "";
        }
        return start[(end + "</think>".Length)..].TrimStart();
    }

    [GeneratedRegex(@"[ \t ]+")]
    private static partial Regex Spaces();

    // [p. 3], [p 3], [pp. 3-4], [page 3], [pages 3–5, 7], (p. 3): the first page is the link.
    [GeneratedRegex(@"[\[(](?:pp?\.?|pages?)\s*(?<n>\d{1,5})(?:\s*[-–—,]\s*\d{1,5})*[\])]", RegexOptions.IgnoreCase)]
    private static partial Regex CitationPattern();
}
