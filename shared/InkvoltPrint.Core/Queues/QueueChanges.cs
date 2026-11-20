namespace InkvoltPrint.Core.Queues;

/// <summary>
/// What the spooler's change notices mean for the printer list (winspool's <c>FindFirstPrinterChangeNotification</c> on the
/// local server, asked for queues added and deleted and for the name, port and driver fields of each): a notice that a queue was
/// added, deleted or renamed (or moved to another port or driver), or that notices were lost, means the queues are read again.
/// A queue's status changing isn't asked for, so printing doesn't make the list read again.
/// </summary>
public static class QueueChanges
{
    /// <summary>winspool.h: PRINTER_CHANGE_ADD_PRINTER, PRINTER_CHANGE_SET_PRINTER, PRINTER_CHANGE_DELETE_PRINTER.</summary>
    public const uint AddPrinter = 0x1, SetPrinter = 0x2, DeletePrinter = 0x4;

    /// <summary>winspool.h PRINTER_NOTIFY_FIELD_*: the fields asked for, those that tell a queue apart in the list.</summary>
    public const ushort FieldPrinterName = 0x01, FieldPortName = 0x03, FieldDriverName = 0x04;

    /// <summary>The fields the notices are asked for (PRINTER_NOTIFY_TYPE).</summary>
    public static readonly ushort[] Fields = [FieldPrinterName, FieldPortName, FieldDriverName];

    /// <summary>PRINTER_NOTIFY_INFO_DISCARDED: the spooler dropped notices (too many): what changed isn't known.</summary>
    public const uint InfoDiscarded = 0x1;

    /// <summary>
    /// Whether one notice means reading the queues again: a queue added or deleted, one of <see cref="Fields"/> changed (the
    /// notice's info lists any), or notices lost. <paramref name="infoCount"/> and <paramref name="infoFlags"/> are the notice's
    /// PRINTER_NOTIFY_INFO's (0 when it had none).
    /// </summary>
    public static bool NeedsRelist(uint change, uint infoFlags, uint infoCount) =>
        (change & (AddPrinter | DeletePrinter)) != 0 || (infoFlags & InfoDiscarded) != 0 || infoCount > 0;
}

/// <summary>
/// Turns a burst of change notices into one read of the queues: <see cref="Notice"/> as each comes, <c>changed</c> once things
/// have been quiet for <paramref name="quiet"/> (a rename is a delete and an add, or several field changes, a moment apart; read
/// between them it would look like a queue removed), and at the latest <paramref name="longest"/> after the first of a burst
/// that doesn't stop. Thread-safe: notices come on the watcher's own thread.
/// </summary>
public sealed class QueueChangeNotices(Action changed, TimeSpan quiet, TimeSpan longest) : IDisposable
{
    private readonly Lock _gate = new();
    private Timer? _timer;
    private DateTime _first;
    private bool _disposed;

    /// <summary>A notice came: <c>changed</c> is called once it's quiet.</summary>
    public void Notice()
    {
        lock (_gate)
        {
            if (_disposed) return;
            var now = DateTime.UtcNow;
            if (_timer is null)
            {
                _first = now;
                _timer = new Timer(_ => Fire(), null, quiet, Timeout.InfiniteTimeSpan);
                return;
            }
            // Pushed back while it stays under the longest wait.
            var due = TimeSpan.FromTicks(Math.Min(quiet.Ticks, Math.Max(0, (_first + longest - now).Ticks)));
            _timer.Change(due, Timeout.InfiniteTimeSpan);
        }
    }

    private void Fire()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _timer?.Dispose();
            _timer = null;
        }
        changed();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
            _timer?.Dispose();
            _timer = null;
        }
    }
}
