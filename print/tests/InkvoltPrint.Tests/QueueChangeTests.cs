using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>
/// Queue change notices: what a spooler notice means for the printer list (a queue added, deleted or renamed, notices lost)
/// and a burst of them read as one.
/// </summary>
[Collection(Timing.Alone)] // quiet periods: see Timing.Alone
public class QueueChangeTests
{
    [Theory]
    [InlineData(QueueChanges.AddPrinter, 0u, 0u, true)]
    [InlineData(QueueChanges.DeletePrinter, 0u, 0u, true)]
    [InlineData(QueueChanges.SetPrinter, 0u, 1u, true)] // a name, port or driver field changed (the only fields asked for)
    [InlineData(0u, 0u, 2u, true)]
    [InlineData(0u, QueueChanges.InfoDiscarded, 0u, true)] // notices lost: what changed isn't known
    [InlineData(QueueChanges.SetPrinter, 0u, 0u, false)] // nothing asked for changed (a status while printing)
    [InlineData(0u, 0u, 0u, false)]
    [InlineData(0x100u, 0u, 0u, false)] // a job's change
    public void A_notice_means_reading_the_queues_again_only_when_the_list_may_have_changed(uint change, uint flags, uint count, bool relist) =>
        Assert.Equal(relist, QueueChanges.NeedsRelist(change, flags, count));

    [Fact]
    public void The_fields_asked_for_are_name_port_and_driver() =>
        Assert.Equal([QueueChanges.FieldPrinterName, QueueChanges.FieldPortName, QueueChanges.FieldDriverName], QueueChanges.Fields);

    private static async Task<int> Settle(Func<int> count, int expected)
    {
        var limit = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(5));
        while (count() < expected && DateTime.UtcNow < limit) await Task.Delay(10);
        await Task.Delay(Timing.Limit(TimeSpan.FromMilliseconds(400))); // and no more after
        return count();
    }

    [Fact]
    public async Task A_burst_of_notices_reads_the_queues_once()
    {
        var calls = 0;
        using var notices = new QueueChangeNotices(() => Interlocked.Increment(ref calls), TimeSpan.FromMilliseconds(150), TimeSpan.FromSeconds(5));
        for (var i = 0; i < 50; i++) notices.Notice(); // a rename: a delete, an add, field changes, a moment apart
        Assert.Equal(1, await Settle(() => Volatile.Read(ref calls), 1));

        notices.Notice(); // another change later: read again
        Assert.Equal(2, await Settle(() => Volatile.Read(ref calls), 2));
    }

    [Fact]
    public async Task Notices_that_never_stop_still_read_the_queues()
    {
        var calls = 0;
        using var notices = new QueueChangeNotices(() => Interlocked.Increment(ref calls), TimeSpan.FromMilliseconds(300), TimeSpan.FromMilliseconds(400));
        var until = DateTime.UtcNow + TimeSpan.FromSeconds(1.5);
        while (DateTime.UtcNow < until)
        {
            notices.Notice();
            await Task.Delay(50);
        }
        Assert.True(Volatile.Read(ref calls) >= 1, "never read while notices kept coming");
    }

    [Fact]
    public async Task Nothing_is_read_after_the_watch_is_closed()
    {
        var calls = 0;
        var notices = new QueueChangeNotices(() => Interlocked.Increment(ref calls), TimeSpan.FromMilliseconds(100), TimeSpan.FromSeconds(1));
        notices.Notice();
        notices.Dispose();
        notices.Notice();
        await Task.Delay(300);
        Assert.Equal(0, Volatile.Read(ref calls));
    }
}
