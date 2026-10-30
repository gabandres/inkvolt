namespace InkvoltPrint.Core.Suite;

/// <summary>
/// Splits a dialog's message into the heading a person reads first (and the window's title, for Alt+Tab and screen
/// readers) and the explanation under it, as the Windows dialog guidance lays them out: the question is the heading,
/// the rest is the body.
/// </summary>
public static class DialogText
{
    /// <summary>
    /// The heading is the first question in the first paragraph ("Remove X from Inkvolt Print?"), else its first
    /// sentence; everything else is the body (null when there is nothing else).
    /// </summary>
    public static (string Heading, string? Body) Split(string message)
    {
        var text = message.Replace("\r\n", "\n").Trim();
        if (text.Length == 0) return ("", null);
        var paragraphs = text.Split("\n\n", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var sentences = Sentences(paragraphs[0]);
        var at = sentences.FindIndex(s => s.EndsWith('?'));
        if (at < 0) at = 0;
        var heading = sentences[at];
        var rest = new List<string>();
        var before = string.Join(' ', sentences.Take(at));
        var after = string.Join(' ', sentences.Skip(at + 1));
        var first = string.Join(' ', new[] { before, after }.Where(s => s.Length > 0));
        if (first.Length > 0) rest.Add(first);
        rest.AddRange(paragraphs.Skip(1));
        return (heading, rest.Count == 0 ? null : string.Join("\n\n", rest));
    }

    /// <summary>Sentences of one paragraph: split after ". ", "? " or "! " (a line break counts as a space).</summary>
    private static List<string> Sentences(string paragraph)
    {
        var flat = paragraph.Replace('\n', ' ');
        var result = new List<string>();
        var start = 0;
        for (var i = 0; i < flat.Length; i++)
        {
            if (flat[i] is not ('.' or '?' or '!')) continue;
            // The end of a sentence: punctuation followed by a space (or the end), not "1.5" or "e.g."
            if (i + 1 < flat.Length && flat[i + 1] != ' ') continue;
            if (flat[i] == '.' && i >= 1 && i + 1 < flat.Length && IsAbbreviation(flat, i)) continue;
            var s = flat[start..(i + 1)].Trim();
            if (s.Length > 0) result.Add(s);
            start = i + 1;
        }
        var tail = flat[start..].Trim();
        if (tail.Length > 0) result.Add(tail);
        return result.Count == 0 ? [flat.Trim()] : result;
    }

    /// <summary>"e.g." and "i.e." (a dot after a single letter that itself follows a dot).</summary>
    private static bool IsAbbreviation(string s, int dot) =>
        dot >= 3 && s[dot - 2] == '.' && char.IsLetter(s[dot - 1]) && char.IsLetter(s[dot - 3]);
}
