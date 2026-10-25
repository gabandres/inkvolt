using System.Collections.Concurrent;

namespace InkvoltPrint.Core.Wia;

/// <summary>
/// One background thread running queued calls in order (a single-threaded apartment for COM objects like WIA's, which must be
/// used on the thread that made them). A caller that cancels stops waiting at once, and its call is skipped if it hasn't
/// started. A call that is running when its caller gives up (a driver that hangs, a page still coming after Cancel) makes the
/// thread <see cref="IsStuck"/>: like <see cref="Queues.TimedCalls{TKey,T}"/> with a hung call, nothing more is queued behind it
/// (new calls fail at once with <see cref="WorkThreadStuckException"/>) until it returns, so a hung driver never piles up work.
/// </summary>
public sealed class WorkThread
{
    private readonly BlockingCollection<Action> _work = [];
    private readonly Lock _gate = new();
    private bool _stuck;

    public WorkThread(string name, bool singleThreadedApartment)
    {
        var thread = new Thread(() =>
        {
            foreach (var action in _work.GetConsumingEnumerable()) action();
        }) { IsBackground = true, Name = name };
        if (singleThreadedApartment && OperatingSystem.IsWindows()) thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    /// <summary>A call is running that its caller stopped waiting for.</summary>
    public bool IsStuck
    {
        get { lock (_gate) return _stuck; }
    }

    public Task<T> RunAsync<T>(Func<T> work, CancellationToken ct)
    {
        if (ct.IsCancellationRequested) return Task.FromCanceled<T>(ct);
        lock (_gate)
            if (_stuck) return Task.FromException<T>(new WorkThreadStuckException());
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var waiting = ct.Register(() => tcs.TrySetCanceled(ct));
        _work.Add(() =>
        {
            if (ct.IsCancellationRequested)
            {
                waiting.Dispose();
                tcs.TrySetCanceled(ct); // given up on before it started: never run
                return;
            }
            var abandoned = ct.Register(() =>
            {
                lock (_gate) _stuck = true;
            });
            try
            {
                tcs.TrySetResult(work());
            }
            catch (Exception ex)
            {
                tcs.TrySetException(ex);
            }
            finally
            {
                abandoned.Dispose(); // waits for the callback if it's running, so it can't set the flag after this
                lock (_gate) _stuck = false;
                waiting.Dispose();
            }
        });
        return tcs.Task;
    }
}

/// <summary>The thread is still running a call its caller gave up on; nothing more is sent to it until that returns.</summary>
public sealed class WorkThreadStuckException() : TimeoutException("An earlier call hasn't returned yet.");
