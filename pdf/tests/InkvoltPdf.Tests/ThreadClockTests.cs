using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Script time limits count the thread's processor time, so a busy PC doesn't stop a script that would finish.</summary>
public class ThreadClockTests
{
    [Fact]
    public void WaitingCostsNoTimeAndWorkDoes()
    {
        var watch = new ThreadClock.Stopwatch();
        watch.Start();
        Thread.Sleep(400); // the thread waits, as it does while other programs have the processor
        Assert.True(watch.Elapsed < TimeSpan.FromMilliseconds(150), $"waiting counted {watch.Elapsed}");

        // Work until the clock has counted 20 ms of it, not for a fixed wall time: on a loaded PC the thread may get little of
        // 300 ms. A clock that counted no work would run out the half minute.
        var wall = System.Diagnostics.Stopwatch.StartNew();
        var x = 0L;
        while (watch.Elapsed <= TimeSpan.FromMilliseconds(20) && wall.Elapsed < TimeSpan.FromSeconds(30)) x += Environment.TickCount64 & 1;
        Assert.True(watch.Elapsed > TimeSpan.FromMilliseconds(20), $"work counted only {watch.Elapsed} in {wall.Elapsed} ({x})");

        watch.Stop();
        var stopped = watch.Elapsed;
        var until = wall.ElapsedMilliseconds + 150;
        while (wall.ElapsedMilliseconds < until) x += Environment.TickCount64 & 1;
        Assert.Equal(stopped, watch.Elapsed);
    }
}
