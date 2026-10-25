namespace InkvoltPrint.Core.Presets;

/// <summary>
/// The files of a batch a preset save already wrote before it failed part-way (file 2 of 3, say), so pressing Save again
/// writes only the rest: a file counts as saved while it is made of the very same pages, in the same order. Forgotten when
/// the pages change and once a save completes (saving again on purpose then writes everything again).
/// </summary>
public sealed class SavedParts<T> where T : class
{
    private readonly List<(T[] Pages, IReadOnlyList<string> Paths)> _saved = [];

    public int Count => _saved.Count;

    /// <summary>Where this file's pages were saved, or null when they weren't.</summary>
    public IReadOnlyList<string>? Find(IReadOnlyList<T> pages) =>
        _saved.FirstOrDefault(s => s.Pages.SequenceEqual(pages, ReferenceEqualityComparer.Instance)).Paths;

    public void Add(IReadOnlyList<T> pages, IReadOnlyList<string> paths) => _saved.Add(([.. pages], paths));

    public void Clear() => _saved.Clear();
}

/// <summary>
/// <c>{n}</c> for each file of a batch: the preset's counter when it could be reserved, else counting on from the last number
/// given (the preset was deleted while its pages were on screen), so no two files of one save share a number.
/// </summary>
public sealed class PartNumbers(int next)
{
    /// <param name="reserved">What <c>ScanPresets.Reserve</c> gave for this file; null when the preset is gone.</param>
    public int Take(int? reserved)
    {
        var n = reserved ?? next;
        next = n + 1;
        return n;
    }
}
