using InkvoltPdf.Core;
using static InkvoltPdf.Core.ConvertCommand;

namespace InkvoltPdf.Tests;

/// <summary>
/// The conversions Explorer asks for, one after another in one copy of the app: each file once, a failure kept to its
/// own file, the rest going on.
/// </summary>
public class ConvertQueueTests
{
    private static Request Word(params string[] files) => new(ExportFormat.Word, files);

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
            queue.Add(new Request(ExportFormat.Word, [.. Enumerable.Range(0, MaxFiles).Select(i => $@"C:\r{round}\{i}.pdf")]));
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

    [Fact]
    public async Task AnAnswerHoldsForTheRunAndANewRunAsksAgain()
    {
        // 500 protected files ask once (ConvertAnswers); the next selection, after the queue was idle, asks again.
        var asked = 0;
        var gate = new TaskCompletionSource();
        ConvertQueue? q = null;
        var queue = q = new ConvertQueue(async (job, _) =>
        {
            await gate.Task;
            if (q!.Answers.ExportProtected is null)
            {
                asked++;
                q.Answers.ExportProtected = true;
            }
            return Saved(job.Pdf);
        });
        queue.Add(Word(@"C:\a.pdf", @"C:\b.pdf"));
        queue.Add(Word(@"C:\c.pdf"));
        gate.SetResult();
        await queue.Idle;
        Assert.Equal(1, asked);
        queue.Add(Word(@"C:\d.pdf"));
        await queue.Idle;
        Assert.Equal(2, asked);
    }

    [Fact]
    public void CancellingAllForgetsTheAnswers()
    {
        var queue = new ConvertQueue((job, _) => new TaskCompletionSource<ConvertOutcome>().Task);
        queue.Add(Word(@"C:\a.pdf", @"C:\b.pdf"));
        queue.Answers.AskPasswords = false;
        queue.CancelAll();
        Assert.True(queue.Answers.AskPasswords);
    }

    [Fact]
    public void NoMoreThanMaxWaitingFilesWait()
    {
        var queue = new ConvertQueue((job, _) => new TaskCompletionSource<ConvertOutcome>().Task); // the first never ends
        Assert.Equal(ConvertQueue.MaxWaiting, queue.Room);
        queue.Add(Word([.. Enumerable.Range(0, 400).Select(i => $@"C:\{i}.pdf")]));
        Assert.Equal(ConvertQueue.MaxWaiting - 400, queue.Room);
        for (var b = 1; b < ConvertQueue.MaxWaiting / 400 + 2; b++)
            queue.Add(Word([.. Enumerable.Range(0, Math.Min(400, queue.Room)).Select(i => $@"C:\{b}-{i}.pdf")]));
        Assert.Equal(0, queue.Room);
    }
}

/// <summary>How a launch reaches the running copy: a conversion launch waits for it rather than converting alongside.</summary>
public class LaunchHandoffTests
{
    private static (LaunchHandoff.Way Way, int Forwards, TimeSpan Waited) Run(bool convert, bool owns, Func<int, bool> forwardsOn, bool slot)
    {
        var forwards = 0;
        var clock = TimeSpan.Zero;
        var way = LaunchHandoff.Find(convert, () => owns, () => forwardsOn(++forwards), () => slot, () => clock, d => clock += d + TimeSpan.FromSeconds(10));
        return (way, forwards, clock);
    }

    [Fact]
    public void TheFirstLaunchOwnsTheSession() => Assert.Equal(LaunchHandoff.Way.Owner, Run(true, owns: true, _ => false, slot: true).Way);

    [Fact]
    public void AnOrdinaryLaunchOpensOnItsOwnWhenTheOwnerDoesntAnswer()
    {
        var (way, forwards, _) = Run(false, owns: false, _ => false, slot: false);
        Assert.Equal((LaunchHandoff.Way.Standalone, 1), (way, forwards));
    }

    [Fact]
    public void AConversionLaunchTriesAgainUntilTheOwnerAnswers()
    {
        var (way, forwards, _) = Run(true, owns: false, n => n == 3, slot: true);
        Assert.Equal((LaunchHandoff.Way.Forwarded, 3), (way, forwards));
    }

    [Fact]
    public void AConversionLaunchConvertsAloneOnlyAfterAMinuteAndOnlyOneAtATime()
    {
        var alone = Run(true, owns: false, _ => false, slot: true);
        Assert.Equal(LaunchHandoff.Way.Standalone, alone.Way);
        Assert.True(alone.Waited >= LaunchHandoff.ConvertPatience);
        Assert.Equal(LaunchHandoff.Way.Dropped, Run(true, owns: false, _ => false, slot: false).Way);
    }
}
