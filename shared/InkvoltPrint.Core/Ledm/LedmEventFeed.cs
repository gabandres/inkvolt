using System.Runtime.CompilerServices;
using System.Threading.Channels;

namespace InkvoltPrint.Core.Ledm;

/// <summary>One read of the printer's EventTable: its events, or (<paramref name="Answered"/> false) the printer stopped answering.</summary>
public sealed record LedmEventTable(IReadOnlyList<LedmEvent> Events, bool Answered);

/// <summary>
/// One connection's EventTable long poll, shared: the poll runs while anyone watches (the printer monitor, Scan to Computer) and
/// stops when the last one leaves, so a printer never holds two long polls from this PC. Each watcher gets the last table at
/// once (its starting point), then every table after it; one that falls behind keeps the newest few (a table holds the latest
/// event of each kind, so the newest says all). The poll ending (the tree lists no EventTable) ends every watcher.
/// </summary>
public sealed class LedmEventFeed(Func<CancellationToken, IAsyncEnumerable<LedmEventTable>> poll)
{
    private const int Backlog = 8;

    private readonly Lock _gate = new();
    private readonly List<Channel<LedmEventTable>> _watchers = [];
    private CancellationTokenSource? _pump;
    private LedmEventTable? _last;

    /// <summary>Long polls running now (tests: one per connection, however many watch).</summary>
    public int Polls
    {
        get { lock (_gate) return _pump is null ? 0 : 1; }
    }

    public async IAsyncEnumerable<LedmEventTable> SubscribeAsync([EnumeratorCancellation] CancellationToken ct = default)
    {
        var channel = Channel.CreateBounded<LedmEventTable>(new BoundedChannelOptions(Backlog) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
        lock (_gate)
        {
            _watchers.Add(channel);
            if (_last is { } last) channel.Writer.TryWrite(last);
            if (_pump is null)
            {
                var pump = _pump = new CancellationTokenSource();
                _ = Task.Run(() => PumpAsync(pump));
            }
        }
        try
        {
            await foreach (var table in channel.Reader.ReadAllAsync(ct).ConfigureAwait(false)) yield return table;
        }
        finally
        {
            CancellationTokenSource? stop = null;
            lock (_gate)
            {
                _watchers.Remove(channel);
                if (_watchers.Count == 0 && _pump is { } pump)
                {
                    stop = pump;
                    _pump = null;
                    _last = null;
                }
            }
            stop?.Cancel();
        }
    }

    private async Task PumpAsync(CancellationTokenSource pump)
    {
        try
        {
            await foreach (var table in poll(pump.Token).ConfigureAwait(false))
                lock (_gate)
                {
                    if (_pump != pump) return; // stopped: everyone left
                    _last = table;
                    foreach (var w in _watchers) w.Writer.TryWrite(table);
                }
        }
        catch (Exception)
        {
            // Stopped (everyone left), or the poll failed in a way it doesn't retry: as when it ends, the watchers end and the
            // next one starts it again.
        }
        finally
        {
            lock (_gate)
                if (_pump == pump)
                {
                    _pump = null;
                    _last = null;
                    foreach (var w in _watchers) w.Writer.TryComplete();
                    _watchers.Clear();
                }
        }
    }
}
