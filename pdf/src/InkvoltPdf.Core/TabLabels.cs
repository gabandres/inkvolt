namespace InkvoltPdf.Core;

/// <summary>
/// The captions of open tabs. A tab shows its file name, or the document's title when the file asks for it; when two
/// tabs would read the same, each gets what tells it apart: its file name when the title isn't that, else (or when the
/// file names clash too) its folder ("report.pdf · 2026").
/// </summary>
public static class TabLabels
{
    public static string[] For(IReadOnlyList<(string Title, string? Path)> tabs)
    {
        var labels = tabs.Select(t => t.Title).ToArray();
        foreach (var group in Enumerable.Range(0, tabs.Count).GroupBy(i => tabs[i].Title, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
        {
            var members = group.ToList();
            string? Name(int i) => tabs[i].Path is { } p ? System.IO.Path.GetFileName(p) : null;
            string? Folder(int i) => tabs[i].Path is { } p ? System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(p)) : null;
            foreach (var i in members)
            {
                var hints = new List<string>();
                if (Name(i) is { } name && !name.Equals(tabs[i].Title, StringComparison.OrdinalIgnoreCase)) hints.Add(name);
                var nameTellsApart = hints.Count > 0 && members.Count(j => string.Equals(Name(j), Name(i), StringComparison.OrdinalIgnoreCase)) == 1;
                if (!nameTellsApart && Folder(i) is { Length: > 0 } folder) hints.Add(folder);
                if (hints.Count > 0) labels[i] = string.Join(" · ", [tabs[i].Title, .. hints]);
            }
        }
        return labels;
    }
}
