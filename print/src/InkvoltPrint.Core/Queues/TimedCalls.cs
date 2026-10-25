namespace InkvoltPrint.Core.Queues;

/// <summary>
/// Blocking calls that may hang (winspool waits for RPC to time out on a print server that's off, and forever on a stuck spooler)
/// run on the thread pool with a time limit: after <paramref name="timeout"/> the caller gets no answer and goes on. A call for
/// the same key that hasn't answered anyone yet is waited on again instead of started a second time, so a hung call never ties
/// up more threads, and a slow one's answer goes to the next caller.
/// </summary>
public sealed class TimedCalls<TKey, T>(TimeSpan timeout) where TKey : notnull
{
    private readonly Dictionary<TKey, Task<T>> _pending = new();
    private readonly Lock _gate = new();

    /// <summary>(true, the result) when <paramref name="call"/> returned in time; (false, default) when it didn't. Its exceptions propagate.</summary>
    public async Task<(bool Answered, T? Value)> RunAsync(TKey key, Func<T> call, CancellationToken ct = default)
    {
        Task<T> task;
        lock (_gate)
        {
            if (!_pending.TryGetValue(key, out task!)) _pending[key] = task = Task.Run(call, CancellationToken.None);
        }
        try
        {
            var value = await task.WaitAsync(timeout, ct).ConfigureAwait(false);
            Done(key, task);
            return (true, value);
        }
        catch (TimeoutException) when (!task.IsCompleted)
        {
            return (false, default);
        }
        catch (Exception) when (task.IsFaulted || task.IsCanceled)
        {
            Done(key, task);
            throw;
        }
    }

    private void Done(TKey key, Task<T> task)
    {
        lock (_gate)
            if (_pending.TryGetValue(key, out var t) && t == task) _pending.Remove(key);
    }
}
