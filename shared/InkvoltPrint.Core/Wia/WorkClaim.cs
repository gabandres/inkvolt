namespace InkvoltPrint.Core.Wia;

/// <summary>
/// Who gets what a <see cref="WorkThread"/> call makes when its caller may stop waiting (a timeout): the caller while it waits;
/// once it has given up (<see cref="Abandon"/>), nobody, and the thing is undone there and then on the thread that made it. Used
/// for a scanner's button registration, which must never be left running unowned (it would start scans nobody asked for).
/// </summary>
public sealed class WorkClaim<T>(Action<T> undo) where T : class
{
    private readonly Lock _gate = new();
    private bool _abandoned;
    private T? _delivered;

    /// <summary>On the work's thread, with what it made: handed to the caller, or (given up on meanwhile) undone at once and null.</summary>
    public T? Deliver(T made)
    {
        lock (_gate)
        {
            if (!_abandoned)
            {
                _delivered = made;
                return made;
            }
        }
        undo(made);
        return null;
    }

    /// <summary>The caller gives up. What was delivered just before (the caller then undoes it), or null: nothing yet, and nothing kept later.</summary>
    public T? Abandon()
    {
        lock (_gate)
        {
            _abandoned = true;
            return _delivered;
        }
    }
}
