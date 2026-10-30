namespace InkvoltPdf.Core;

/// <summary>
/// Settings that take effect as they are changed, as Windows 11's do, with one way back: the value each setting had
/// when the Settings window opened, so "Undo changes" puts every changed one back at once (Reset to defaults included).
/// A setting changed and then changed back counts as unchanged.
/// </summary>
public sealed class SettingsSession
{
    private readonly Dictionary<string, object?> _original;
    private readonly Dictionary<string, object?> _current;
    private readonly List<string> _order = [];

    public SettingsSession(IEnumerable<KeyValuePair<string, object?>> atOpen)
    {
        _original = new Dictionary<string, object?>(atOpen);
        _current = new Dictionary<string, object?>(_original);
    }

    /// <summary>A setting took a new value (already applied by the caller).</summary>
    public void Set(string key, object? value)
    {
        if (!_original.ContainsKey(key)) throw new ArgumentException($"Unknown setting: {key}", nameof(key));
        _current[key] = value;
        _order.Remove(key);
        if (!Equals(_original[key], value)) _order.Add(key);
    }

    public object? Original(string key) => _original[key];

    /// <summary>The settings that differ from when the window opened, the most recently changed last.</summary>
    public IReadOnlyList<string> Changed => _order;

    public bool HasChanges => _order.Count > 0;

    /// <summary>What Undo changes would do, in words; null with nothing changed.</summary>
    public string? Summary => _order.Count switch
    {
        0 => null,
        1 => "1 setting changed since Settings opened",
        var n => $"{n} settings changed since Settings opened",
    };

    /// <summary>The changed settings with the values they had when the window opened; the session is unchanged after.</summary>
    public IReadOnlyList<KeyValuePair<string, object?>> Revert()
    {
        var back = _order.Select(k => new KeyValuePair<string, object?>(k, _original[k])).ToList();
        foreach (var (k, v) in back) _current[k] = v;
        _order.Clear();
        return back;
    }
}
