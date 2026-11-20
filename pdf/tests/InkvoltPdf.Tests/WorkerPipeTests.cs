using System.Diagnostics;
using System.IO.Pipes;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// A worker's pipe (<see cref="WorkerPipe"/>) is read and written without the thread pool: with the pool starved, as a
/// loaded test run or the app's renders leave it, a worker's answer sat unread for minutes. Alone: the test starves the
/// pool on purpose, which the tests running beside it would feel.
/// </summary>
[Collection(Timing.Alone)]
public sealed class WorkerPipeTests
{
    /// <summary>A pipe this process connects to itself, from a thread of its own (the "worker" is this process).</summary>
    private static (WorkerPipe Pipe, NamedPipeClientStream Client) Connected()
    {
        var name = FindWorkers.NewPipeName();
        var pipe = FindWorkers.NewPipe(name);
        var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.None);
        var connecting = new Thread(() => client.Connect(10_000));
        connecting.Start();
        using (var me = Process.GetCurrentProcess()) FindWorkers.AwaitConnection(pipe, me, 10_000, CancellationToken.None);
        connecting.Join();
        return (pipe, client);
    }

    [Fact]
    public void AnAnswerIsReadWhileThePoolIsStarved()
    {
        var (pipe, client) = Connected();
        using var _ = pipe;
        using var __ = client;
        // Far more blocked work than the pool has threads: it adds a thread or two a second, so a read finished on a pool
        // thread waits behind all of them.
        // Never disposed: a blocker that starts after the test has ended must find it set, not gone (an exception on a pool
        // thread ends the test host).
        var release = new ManualResetEventSlim();
        var blockers = Environment.ProcessorCount * 4 + 200;
        for (var i = 0; i < blockers; i++) ThreadPool.UnsafeQueueUserWorkItem(_ => release.Wait(TimeSpan.FromMinutes(2)), null);
        try
        {
            var buffer = new byte[4];
            var reader = new Thread(() =>
            {
                Thread.Sleep(200); // the read is waiting first
                client.Write([1, 2, 3, 4]);
            });
            reader.Start();
            var took = Stopwatch.StartNew();
            pipe.ReadExactly(buffer, Timing.Limit(TimeSpan.FromSeconds(5)));
            Assert.Equal([1, 2, 3, 4], buffer);
            pipe.Write([5, 6]); // and written so, while the pool is still starved
            var back = new byte[2];
            client.ReadExactly(back);
            Assert.Equal([5, 6], back);
            Assert.True(took.Elapsed < Timing.Limit(TimeSpan.FromSeconds(5)), $"{took.Elapsed}");
            reader.Join();
        }
        finally
        {
            release.Set();
        }
    }

    [Fact]
    public void AReadGivesUpAtItsLimitAndAWorkerGoneIsTheEnd()
    {
        var (pipe, client) = Connected();
        using var _ = pipe;
        var took = Stopwatch.StartNew();
        Assert.Throws<TimeoutException>(() => pipe.ReadExactly(new byte[4], TimeSpan.FromMilliseconds(300)));
        Assert.True(took.Elapsed >= TimeSpan.FromMilliseconds(250), $"{took.Elapsed}");
        client.Write([1, 2]);
        client.Dispose();
        Assert.Throws<EndOfStreamException>(() => pipe.ReadExactly(new byte[4], TimeSpan.FromSeconds(10)));
        Assert.Equal(0, pipe.Read(new byte[4]));
    }

    [Fact]
    public void AWorkerThatNeverConnectsIsGivenUpOn()
    {
        using var pipe = FindWorkers.NewPipe(FindWorkers.NewPipeName());
        using var me = Process.GetCurrentProcess();
        var took = Stopwatch.StartNew();
        Assert.Throws<InvalidOperationException>(() => FindWorkers.AwaitConnection(pipe, me, 300, CancellationToken.None));
        Assert.True(took.Elapsed < Timing.Limit(TimeSpan.FromSeconds(5)), $"{took.Elapsed}");
        using var ended = new CancellationTokenSource();
        ended.Cancel();
        Assert.Throws<InvalidOperationException>(() => FindWorkers.AwaitConnection(pipe, me, 10_000, ended.Token));
    }

    [Fact]
    public void AReadUnderWayEndsWhenThePipeIsClosed()
    {
        var (pipe, client) = Connected();
        using var _ = client;
        Exception? failed = null;
        var reader = new Thread(() => failed = Record.Exception(() => pipe.ReadExactly(new byte[4], TimeSpan.FromMinutes(5))));
        reader.Start();
        Thread.Sleep(200);
        pipe.Dispose();
        Assert.True(reader.Join(Timing.Limit(TimeSpan.FromSeconds(5))), "the read still waits");
        Assert.True(failed is IOException or ObjectDisposedException, failed?.ToString());
    }
}
