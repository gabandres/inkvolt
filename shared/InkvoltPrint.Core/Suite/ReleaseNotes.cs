namespace InkvoltPrint.Core.Suite;

/// <summary>One version's entry in an app's WHATS-NEW.md.</summary>
public sealed record ReleaseNote(Version Version, IReadOnlyList<string> Items);

/// <summary>
/// What's New in both apps: each app embeds a WHATS-NEW.md ("## 1.1.0" headings, "- " items; a heading that isn't a version,
/// such as "## Next", is notes for a release still to come and never shown). After an update the app shows, once, the
/// entries newer than the version it last ran as; a new install shows nothing.
/// </summary>
public static class ReleaseNotes
{
    /// <summary>The versioned entries, newest first.</summary>
    public static IReadOnlyList<ReleaseNote> Parse(string markdown)
    {
        var notes = new List<ReleaseNote>();
        List<string>? items = null;
        foreach (var raw in markdown.ReplaceLineEndings("\n").Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                items = null;
                if (Normalize(line[3..].Trim()) is { } version) notes.Add(new(version, items = []));
            }
            else if (line.StartsWith('#')) items = null;
            else if (items is null || line.Length == 0) continue;
            else if (line.StartsWith("- ", StringComparison.Ordinal)) items.Add(line[2..].Trim());
            else if (items.Count > 0) items[^1] += " " + line; // a wrapped item
        }
        return [.. notes.Where(n => n.Items.Count > 0).OrderByDescending(n => n.Version)];
    }

    /// <summary>
    /// The entries to show on this start: those after <paramref name="lastSeen"/> up to <paramref name="current"/>. Without a
    /// readable <paramref name="lastSeen"/> (updated from a version that didn't keep it) just the current version's.
    /// </summary>
    public static IReadOnlyList<ReleaseNote> Since(IReadOnlyList<ReleaseNote> notes, string? lastSeen, Version current, bool newInstall)
    {
        if (newInstall) return [];
        var now = Normalize(current);
        return Normalize(lastSeen) is { } seen
            ? [.. notes.Where(n => n.Version > seen && n.Version <= now)]
            : [.. notes.Where(n => n.Version == now)];
    }

    public static string Format(IEnumerable<ReleaseNote> notes) =>
        string.Join(Environment.NewLine + Environment.NewLine,
            notes.Select(n => string.Join(Environment.NewLine, n.Items.Select(i => "• " + i).Prepend($"Version {n.Version}"))));

    /// <summary>"1.0.3", "1.0.3.0" → 1.0.3 (the Store's fourth number is always 0).</summary>
    public static Version? Normalize(string? text) => Version.TryParse(text, out var v) ? Normalize(v) : null;

    private static Version Normalize(Version v) => new(v.Major, v.Minor, Math.Max(v.Build, 0));
}
