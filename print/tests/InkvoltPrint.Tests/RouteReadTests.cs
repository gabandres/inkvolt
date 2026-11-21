using InkvoltPrint.Core.Printing.Direct;

namespace InkvoltPrint.Tests;

/// <summary>
/// What a tab reads of its printer's route (<see cref="RouteRead"/>): two-sided on Print and Copy, Print photos' options, a batch's
/// queue. Read once asked, again after a change of route only if it was asked, and again when the route changed during a read.
/// </summary>
public class RouteReadTests
{
    /// <summary>A read the test ends (<see cref="Finish"/>), counting reads and the route each was started on.</summary>
    private sealed class Reads
    {
        private TaskCompletionSource<bool>? _pending;
        public readonly List<string> Started = [];
        public string Route = "queue";
        public bool Waits;
        public bool Answers = true;

        public RouteRead For() => new(Read);

        private Task<bool> Read()
        {
            Started.Add(Route);
            if (!Waits) return Task.FromResult(Answers);
            _pending = new TaskCompletionSource<bool>();
            return _pending.Task;
        }

        public void Finish() => _pending!.SetResult(Answers);
    }

    [Fact]
    public async Task Nothing_is_read_until_asked_and_then_once()
    {
        var reads = new Reads();
        var read = reads.For();
        read.RouteChanged(); // a tab never shown reads nothing
        Assert.Empty(reads.Started);
        await read.AskAsync();
        await read.AskAsync();
        Assert.Single(reads.Started);
        Assert.True(read.IsRead);
    }

    [Fact]
    public async Task Once_asked_a_change_of_route_reads_again_at_once()
    {
        var reads = new Reads();
        var read = reads.For();
        await read.AskAsync();
        reads.Route = "direct";
        read.RouteChanged();
        Assert.Equal(["queue", "direct"], reads.Started);
        Assert.True(read.IsRead);
        await read.AskAsync();
        Assert.Equal(2, reads.Started.Count);
    }

    [Fact]
    public async Task A_change_during_a_read_reads_again_when_it_ends()
    {
        var reads = new Reads { Waits = true };
        var read = reads.For();
        var asked = read.AskAsync();
        Assert.True(read.IsReading);
        reads.Route = "direct";
        read.RouteChanged(); // the read under way is the old route's
        Assert.Single(reads.Started); // one read at a time
        Assert.Same(asked, read.AskAsync()); // asking meanwhile waits for the same reads

        reads.Finish(); // the old route's answer: not kept as read, read again
        Assert.Equal(["queue", "direct"], reads.Started);
        Assert.False(read.IsRead);
        reads.Finish();
        await asked;
        Assert.True(read.IsRead);
        Assert.False(read.IsReading);
    }

    [Fact]
    public async Task A_read_without_an_answer_is_asked_again()
    {
        var reads = new Reads { Answers = false }; // no queue yet, say
        var read = reads.For();
        await read.AskAsync();
        Assert.False(read.IsRead);
        reads.Answers = true;
        await read.AskAsync();
        Assert.Equal(2, reads.Started.Count);
        Assert.True(read.IsRead);
    }
}
