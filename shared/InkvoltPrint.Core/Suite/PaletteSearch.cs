namespace InkvoltPrint.Core.Suite;

/// <summary>
/// How both apps' command palettes (Ctrl+K) match what is typed: every word must appear in the entry's category or
/// name; a name starting with a word ranks first, then a word starting a word, then a word inside one. Entries that
/// aren't commands (recent files) rank a little lower than commands on a tie.
/// </summary>
public static class PaletteSearch
{
    /// <summary>0 when a word is missing; otherwise higher is better.</summary>
    public static int Score(string name, string category, IReadOnlyList<string> words, bool isCommand = true)
    {
        var hay = $"{category} {name}";
        var score = 0;
        foreach (var w in words)
        {
            var at = hay.IndexOf(w, StringComparison.CurrentCultureIgnoreCase);
            if (at < 0) return 0;
            score += name.StartsWith(w, StringComparison.CurrentCultureIgnoreCase) ? 30 : at == 0 || hay[at - 1] == ' ' ? 20 : 10;
        }
        return score + (isCommand ? 5 : 0);
    }

    /// <summary>
    /// The entries matching <paramref name="query"/>, best first (the list's order on a tie), at most
    /// <paramref name="max"/>; with nothing typed, the first <paramref name="max"/> for which
    /// <paramref name="showWhenEmpty"/> holds.
    /// </summary>
    public static List<T> Filter<T>(IEnumerable<T> items, string query, Func<T, string> name, Func<T, string> category,
        Func<T, bool>? isCommand = null, Func<T, bool>? showWhenEmpty = null, int max = 60)
    {
        var q = query.Trim();
        if (q.Length == 0) return [.. items.Where(i => showWhenEmpty?.Invoke(i) ?? true).Take(max)];
        var words = q.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return [.. items
            .Select(i => (Item: i, Score: Score(name(i), category(i), words, isCommand?.Invoke(i) ?? true)))
            .Where(x => x.Score > 0)
            .OrderByDescending(x => x.Score)
            .Select(x => x.Item)
            .Take(max)];
    }
}
