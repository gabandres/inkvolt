namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// One thing a tab reads of where its printer's jobs go (Print's and Copy's two-sided check, Print photos' paper options, a batch's
/// queue), kept in step with the print routing (<see cref="PrintRouting"/>). Read when the tab asks (<see cref="AskAsync"/>), once;
/// after a change of route (<see cref="RouteChanged"/>) read again only if it was asked for, so a tab never shown reads nothing.
/// One read at a time: a change during a read reads again when it ends, so the last read is always the current route's.
/// </summary>
/// <param name="read">
/// Reads and keeps what it read; true when that counts as read (false: no answer yet, asked again next time). Catches its own
/// failures. Continues on the caller's context: the app's tabs read on the dispatcher.
/// </param>
public sealed class RouteRead(Func<Task<bool>> read)
{
    private int _route, _readFor = -1;
    private bool _asked;
    private Task? _reading;

    /// <summary>Read for the current route.</summary>
    public bool IsRead => _readFor == _route && _reading is null;

    /// <summary>A read is under way.</summary>
    public bool IsReading => _reading is not null;

    /// <summary>The tab wants it: read now unless it's read for the current route; a read under way is waited for.</summary>
    public Task AskAsync()
    {
        _asked = true;
        if (_reading is { } running) return running;
        return _readFor == _route ? Task.CompletedTask : Start();
    }

    /// <summary>The route or the queue changed: what was read is stale, and read again now if it was asked for.</summary>
    public void RouteChanged()
    {
        _route++;
        if (_asked && _reading is null) _ = Start();
    }

    private Task Start()
    {
        var run = RunAsync();
        _reading = run.IsCompleted ? null : run; // a read that finished at once has already cleared it
        return run;
    }

    private async Task RunAsync()
    {
        try
        {
            while (true)
            {
                var route = _route;
                var done = await read();
                if (route != _route) continue; // the route changed meanwhile: read for the new one
                if (done) _readFor = route;
                return;
            }
        }
        finally
        {
            _reading = null;
        }
    }
}
