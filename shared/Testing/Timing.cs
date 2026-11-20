namespace Inkvolt.Testing;

/// <summary>
/// Time in tests, for both test projects (linked into each). GitHub's runners are shared and slower than a desk PC, and
/// both test projects run at once there: a limit sized for this PC fails there about one run in two. A test that measures
/// time takes its limit through <see cref="Limit"/>, so CI gets one factor instead of numbers scattered per test; one
/// that cancels after a delay uses <see cref="CancelAfter"/>.
/// </summary>
public static class Timing
{
    /// <summary>On a GitHub Actions runner (the Mac's ScanCorpus.runs reads the same variable).</summary>
    public static readonly bool OnCi = Environment.GetEnvironmentVariable("GITHUB_ACTIONS") is not null;

    /// <summary>How much slower a time limit may be on CI.</summary>
    public const int CiFactor = 4;

    /// <summary>A limit sized for this PC, made <see cref="CiFactor"/> times longer on CI.</summary>
    public static TimeSpan Limit(TimeSpan local) => OnCi ? local * CiFactor : local;

    /// <summary>
    /// The collection of test classes that run alone, after the parallel ones (xUnit runs a collection that disables
    /// parallelization by itself once the others are done): those that hold a deadline a starved thread pool overruns, and
    /// those that check a file is let go, which a child another test starts meanwhile would inherit (Process.Start passes
    /// on every inheritable handle, MuPDF's to a file open in place among them).
    /// </summary>
    public const string Alone = "Alone";

    /// <summary>How much longer than its processor-time limit <see cref="Within{T}"/> waits on the wall for work that uses none.</summary>
    public const int WallFactor = 3;

    /// <summary>
    /// <paramref name="work"/> on a thread of its own, given <see cref="Limit"/>(<paramref name="local"/>) of that thread's
    /// processor time, so a loop without end fails the test instead of blocking the run; work that waits without using the
    /// processor (a deadlock) is given up after <see cref="WallFactor"/> times that on the wall. Not <c>Task.Run</c> and not
    /// the wall's clock: with the test suites and other work running beside it, the pool kept the work from starting and
    /// the wall's minute went by in some 4 s of the work's own (exponential page trees, a shape check, export tags).
    /// </summary>
    /// <exception cref="TimeoutException">It ran past its limit.</exception>
    public static async Task<T> Within<T>(Func<T> work, TimeSpan local)
    {
        var limit = Limit(local);
        var handle = IntPtr.Zero;
        var task = Task.Factory.StartNew(() =>
        {
            if (OperatingSystem.IsWindows()) Volatile.Write(ref handle, OpenThread(ThreadQueryLimitedInformation, false, GetCurrentThreadId()));
            return work();
        }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        var wall = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            while (!task.IsCompleted)
            {
                await Task.WhenAny(task, Task.Delay(100)).ConfigureAwait(false);
                if (task.IsCompleted) break;
                var used = Volatile.Read(ref handle) is var h && h != IntPtr.Zero && GetThreadTimes(h, out _, out _, out var kernel, out var user)
                    ? TimeSpan.FromTicks(kernel + user)
                    : TimeSpan.Zero;
                if (used > limit || wall.Elapsed > limit * WallFactor)
                    throw new TimeoutException($"{used.TotalSeconds:0.#} s of processor time, {wall.Elapsed.TotalSeconds:0} s in all (limit {limit.TotalSeconds:0} s)");
            }
            return await task.ConfigureAwait(false);
        }
        finally
        {
            // The thread may run on after a timeout; its handle is no longer looked at.
            if (Interlocked.Exchange(ref handle, IntPtr.Zero) is var h && h != IntPtr.Zero) CloseHandle(h);
        }
    }

    private const int ThreadQueryLimitedInformation = 0x0800;

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenThread(int access, bool inherit, uint threadId);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetThreadTimes(IntPtr thread, out long creation, out long exit, out long kernel, out long user);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    /// <summary>
    /// A source cancelled after <paramref name="delay"/> by a thread of its own. <c>new CancellationTokenSource(delay)</c>
    /// and <c>CancelAfter</c> fire from a thread-pool timer, and work that fills the pool (Parallel.For) holds that
    /// timer back until it has finished: the work then runs to its end and the test sees no cancellation.
    /// </summary>
    public static CancellationTokenSource CancelAfter(TimeSpan delay)
    {
        var source = new CancellationTokenSource();
        new Thread(() =>
        {
            Thread.Sleep(delay);
            try { source.Cancel(); }
            catch (ObjectDisposedException) { } // the test finished first
        }) { IsBackground = true, Name = "Timing.CancelAfter" }.Start();
        return source;
    }
}

/// <summary>See <see cref="Timing.Alone"/>.</summary>
[Xunit.CollectionDefinition(Timing.Alone, DisableParallelization = true)]
public sealed class AloneCollection;
