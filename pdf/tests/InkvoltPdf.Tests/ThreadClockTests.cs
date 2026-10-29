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

        var wall = System.Diagnostics.Stopwatch.StartNew();
        var x = 0L;
        while (wall.ElapsedMilliseconds < 300) x += Environment.TickCount64 & 1;
        Assert.True(watch.Elapsed > TimeSpan.FromMilliseconds(20), $"work counted only {watch.Elapsed} ({x})");

        watch.Stop();
        var stopped = watch.Elapsed;
        while (wall.ElapsedMilliseconds < 450) x += Environment.TickCount64 & 1;
        Assert.Equal(stopped, watch.Elapsed);
    }
}
