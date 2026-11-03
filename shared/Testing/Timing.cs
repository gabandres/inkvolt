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
