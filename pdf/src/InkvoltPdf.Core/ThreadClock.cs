using System.Runtime.InteropServices;

namespace InkvoltPdf.Core;

/// <summary>
/// The processor time the calling thread has used (user and kernel): what a script's time limit counts, so a busy PC
/// (other programs, parallel tests) doesn't stop a script that would finish in time on an idle one. Windows updates it at
/// the scheduler's tick (about 16 ms), fine for limits of hundreds of milliseconds. Off Windows, the wall clock.
/// </summary>
internal static partial class ThreadClock
{
    private static readonly System.Diagnostics.Stopwatch Wall = System.Diagnostics.Stopwatch.StartNew();

    public static TimeSpan Now()
    {
        if (OperatingSystem.IsWindows() && GetThreadTimes(GetCurrentThread(), out _, out _, out var kernel, out var user))
            return TimeSpan.FromTicks(kernel + user); // both in 100 ns units, as TimeSpan's ticks
        return Wall.Elapsed;
    }

    /// <summary>A stopwatch on <see cref="Now"/>; each start-stop span must run on one thread (the span's own time is read there).</summary>
    public sealed class Stopwatch
    {
        private TimeSpan _total, _since;

        public bool IsRunning { get; private set; }

        public TimeSpan Elapsed => IsRunning ? _total + (Now() - _since) : _total;

        public long ElapsedMilliseconds => (long)Elapsed.TotalMilliseconds;

        public void Start()
        {
            if (IsRunning) return;
            _since = Now();
            IsRunning = true;
        }

        public void Stop()
        {
            if (!IsRunning) return;
            _total += Now() - _since;
            IsRunning = false;
        }

        public void Reset()
        {
            _total = TimeSpan.Zero;
            IsRunning = false;
        }

        public void Restart()
        {
            Reset();
            Start();
        }
    }

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr GetCurrentThread();

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetThreadTimes(IntPtr thread, out long creation, out long exit, out long kernel, out long user);
}
