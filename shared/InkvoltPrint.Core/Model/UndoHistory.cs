namespace InkvoltPrint.Core.Model;

/// <summary>
/// Undo for the scan review: each change (delete, turn, crop, move, a file start, a separator) records what it was, in
/// words ("Delete page 3"), and how to put it back. Newest first; the oldest go after <see cref="Limit"/>. Reversing a
/// step must not record a new one (the review sets the old values directly, not through its commands).
/// </summary>
public sealed class UndoHistory
{
    public const int Limit = 50;

    private readonly LinkedList<(string What, Action Reverse)> _steps = new();

    /// <summary>Raised after every record, undo and clear (the Undo button's state and tooltip follow it).</summary>
    public event EventHandler? Changed;

    public bool CanUndo => _steps.Count > 0;

    public int Count => _steps.Count;

    /// <summary>What Undo would reverse next ("Delete page 3"), or null.</summary>
    public string? Next => _steps.First?.Value.What;

    public void Record(string what, Action reverse)
    {
        _steps.AddFirst((what, reverse));
        while (_steps.Count > Limit) _steps.RemoveLast();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Reverses the newest step; returns what it was, or null when there is nothing to undo.</summary>
    public string? Undo()
    {
        if (_steps.First is not { } first) return null;
        _steps.RemoveFirst();
        first.Value.Reverse();
        Changed?.Invoke(this, EventArgs.Empty);
        return first.Value.What;
    }

    public void Clear()
    {
        if (_steps.Count == 0) return;
        _steps.Clear();
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
