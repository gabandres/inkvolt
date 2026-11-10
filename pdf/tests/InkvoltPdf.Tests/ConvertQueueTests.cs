using InkvoltPdf.Core;
using static InkvoltPdf.Core.ConvertCommand;

namespace InkvoltPdf.Tests;

/// <summary>
/// The conversions Explorer asks for, one after another in one copy of the app: each file once, a failure kept to its
/// own file, the rest going on.
/// </summary>
public class ConvertQueueTests
{
    private static Request Word(params string[] files) => new(ExportFormat.Word, files, 0);

    private static ConvertOutcome Saved(string pdf) => ConvertOutcome.Saved(Path.ChangeExtension(pdf, ".docx"), inDocuments: false, notes: null);

    [Fact]
    public async Task EachFileIsConvertedOnceInOrder()
    {
        var order = new List<string>();
        var queue = new ConvertQueue((job, _) =>
        {
            order.Add(job.Pdf);
            return Task.FromResult(Saved(job.Pdf));
        });
        queue.Add(Word(@"C:\a.pdf", @"C:\b.pdf", @"C:\c.pdf"));
        await queue.Idle;
        Assert.Equal([@"C:\a.pdf", @"C:\b.pdf", @"C:\c.pdf"], order);
        Assert.All(queue.Jobs, j => Assert.Equal(ConvertResult.Saved, j.Outcome?.Result));
        Assert.All(queue.Jobs, j => Assert.Equal(ConvertJob.States.Done, j.State));
    }

    [Fact]
    public async Task OneRunsAtATime()
    {
        var running = 0;
        var most = 0;
        var queue = new ConvertQueue(async (job, _) =>
        {
            most = Math.Max(most, ++running);
            await Task.Delay(5);
            running--;
            return Saved(job.Pdf);
        });
        queue.Add(Word(@"C:\a.pdf", @"C:\b.pdf"));
        queue.Add(Word(@"C:\c.pdf")); // another launch while the first ones run
        await queue.Idle;
        Assert.Equal(1, most);
        Assert.Equal(3, queue.Jobs.Count);
    }

    [Fact]
    public async Task AFailureStaysWithItsFileAndTheRestGoOn()
    {
        var queue = new ConvertQueue((job, _) => job.Pdf switch
        {
            @"C:\damaged.pdf" => throw new InvalidOperationException("cannot find startxref"),
            @"C:\locked.pdf" => Task.FromResult(ConvertOutcome.Failed(ConvertResult.NotOpened, "a password is needed")),
            _ => Task.FromResult(Saved(job.Pdf)),
        });
        queue.Add(Word(@"C:\damaged.pdf", @"C:\locked.pdf", @"C:\fine.pdf"));
        await queue.Idle;
        var j = queue.Jobs;
        Assert.Equal(ConvertResult.Failed, j[0].Outcome?.Result);
        Assert.Equal("cannot find startxref", j[0].Outcome?.Message);
        Assert.Equal(ConvertResult.NotOpened, j[1].Outcome?.Result);
        Assert.Equal(ConvertResult.Saved, j[2].Outcome?.Result);
    }

    [Fact]
    public async Task AFileAlreadyWaitingIsNotAddedTwice()
    {
        var gate = new TaskCompletionSource();
        var seen = new List<string>();
        var queue = new ConvertQueue(async (job, _) =>
        {
            seen.Add(job.Pdf);
            await gate.Task;
            return Saved(job.Pdf);
        });
        var first = queue.Add(Word(@"C:\a.pdf", @"C:\b.pdf"));
        var again = queue.Add(Word(@"c:\A.pdf", @"C:\b.pdf", @"C:\c.pdf")); // a double-click on the verb
        Assert.Equal(2, first.Count);
        Assert.Equal([@"C:\c.pdf"], again.Select(j => j.Pdf));
        gate.SetResult();
        await queue.Idle;
        Assert.Equal([@"C:\a.pdf", @"C:\b.pdf", @"C:\c.pdf"], seen);

        // Done, it can be converted again (a second copy, "name (2).docx").
        Assert.Single(queue.Add(Word(@"C:\a.pdf")));
        await queue.Idle;
        Assert.Equal(4, seen.Count);
    }

    [Fact]
    public async Task CancellingStopsTheRunningOneAndThoseWaiting()
    {
        var started = new TaskCompletionSource();
        var queue = new ConvertQueue(async (job, cancel) =>
        {
            started.TrySetResult();
            await Task.Delay(Timeout.Infinite, cancel);
            return Saved(job.Pdf);
        });
        queue.Add(Word(@"C:\a.pdf", @"C:\b.pdf"));
        await started.Task;
        queue.CancelAll();
        await queue.Idle;
        Assert.All(queue.Jobs, j => Assert.Equal(ConvertResult.Cancelled, j.Outcome?.Result));
    }

    [Fact]
    public async Task EveryChangeIsReported()
    {
        var changes = new List<(string, ConvertJob.States)>();
        var queue = new ConvertQueue((job, _) => Task.FromResult(Saved(job.Pdf)));
        queue.Changed += j => changes.Add((j.Pdf, j.State));
        queue.Add(Word(@"C:\a.pdf"));
        await queue.Idle;
        Assert.Equal([(@"C:\a.pdf", ConvertJob.States.Waiting), (@"C:\a.pdf", ConvertJob.States.Converting), (@"C:\a.pdf", ConvertJob.States.Done)], changes);
    }

    [Fact]
    public async Task TheLastOneDoneLeavesTheQueueIdleAlready()
    {
        // The conversions window turns Cancel into Close when the last one ends: busy must be false by then.
        var busyAtEnd = new List<bool>();
        var queue = new ConvertQueue(async (job, _) =>
        {
            await Task.Yield();
            return Saved(job.Pdf);
        });
        queue.Changed += j => { if (j.State == ConvertJob.States.Done) busyAtEnd.Add(queue.IsBusy); };
        queue.Add(Word(@"C:\a.pdf", @"C:\b.pdf"));
        await queue.Idle;
        Assert.Equal([true, false], busyAtEnd);
    }

    [Fact]
    public async Task TheListIsBounded()
    {
        var queue = new ConvertQueue((job, _) => Task.FromResult(Saved(job.Pdf)));
        for (var round = 0; round < 3; round++)
        {
            queue.Add(new Request(ExportFormat.Word, [.. Enumerable.Range(0, MaxFiles).Select(i => $@"C:\r{round}\{i}.pdf")], 0));
            await queue.Idle;
        }
        Assert.True(queue.Jobs.Count <= ConvertQueue.MaxListed, $"{queue.Jobs.Count} listed");
        Assert.Equal(@$"C:\r2\{MaxFiles - 1}.pdf", queue.Jobs[^1].Pdf); // the oldest finished ones go first
    }

    [Fact]
    public async Task IdleIsDoneWithNothingQueued()
    {
        var queue = new ConvertQueue((job, _) => Task.FromResult(Saved(job.Pdf)));
        await queue.Idle.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(queue.IsBusy);
    }
}
