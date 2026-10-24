using System.Globalization;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

public class PrintQueueTests
{
    [Theory]
    [InlineData(JobStatus.None, "Waiting")]
    [InlineData(JobStatus.Spooling, "Preparing")]
    [InlineData(JobStatus.Printing, "Printing")]
    [InlineData(JobStatus.Printing | JobStatus.PaperOut, "Out of paper")]
    [InlineData(JobStatus.Printing | JobStatus.Offline | JobStatus.Error, "Printer offline")]
    [InlineData(JobStatus.Paused, "Paused")]
    [InlineData(JobStatus.Printing | JobStatus.Deleting, "Cancelling")]
    [InlineData(JobStatus.Printed | JobStatus.Retained, "Printed")]
    [InlineData(JobStatus.Error, "Error")]
    public void Status_words_pick_the_most_important_bit(JobStatus status, string expected) =>
        Assert.Equal(expected, QueueJobText.Status(status));

    [Fact]
    public void Status_bits_match_the_spooler_values()
    {
        // System.Printing.PrintJobStatus / JOB_STATUS_*: the app casts the spooler's value straight across.
        Assert.Equal(0x10, (int)JobStatus.Printing);
        Assert.Equal(0x40, (int)JobStatus.PaperOut);
        Assert.Equal(0x400, (int)JobStatus.UserIntervention);
        Assert.Equal(0x2000, (int)JobStatus.Retained);
    }

    [Theory]
    [InlineData(0, 0, JobStatus.Spooling, "")]
    [InlineData(1, 0, JobStatus.None, "1 page")]
    [InlineData(12, 0, JobStatus.None, "12 pages")]
    [InlineData(12, 3, JobStatus.Printing, "Page 4 of 12")]
    [InlineData(12, 12, JobStatus.Printing, "12 pages")]
    public void Pages_text(int pages, int printed, JobStatus status, string expected) =>
        Assert.Equal(expected, QueueJobText.Pages(pages, printed, status));

    [Fact]
    public void Submitted_shows_the_date_only_for_older_jobs()
    {
        var now = new DateTime(2026, 10, 24, 15, 0, 0);
        var c = CultureInfo.InvariantCulture;

        Assert.Equal("09:05", QueueJobText.Submitted(new DateTime(2026, 10, 24, 9, 5, 0), now, c));
        Assert.Equal("October 23, 22:40", QueueJobText.Submitted(new DateTime(2026, 10, 23, 22, 40, 0), now, c));
    }

    [Theory]
    [InlineData("gabri", "gabri", true)]
    [InlineData("GABRI", "gabri", true)]
    [InlineData(@"OFFICE\gabri", "gabri", true)]
    [InlineData("alex", "gabri", false)]
    [InlineData("", "gabri", false)]
    public void Owner_match(string owner, string user, bool mine) => Assert.Equal(mine, QueueJobText.IsOwner(owner, user));

    [Fact]
    public void Summary_and_order()
    {
        var t = new DateTime(2026, 10, 24, 12, 0, 0);
        var jobs = QueueJobText.Order(
        [
            new QueueJob(7, "b", 1, 0, JobStatus.None, t.AddMinutes(1), "me"),
            new QueueJob(5, "a", 3, 1, JobStatus.Printing, t, "me"),
            new QueueJob(9, "c", 2, 0, JobStatus.None, t.AddMinutes(1), "alex"),
        ]);

        Assert.Equal([5, 7, 9], jobs.Select(j => j.Id));
        Assert.Equal("3 jobs, 1 printing", QueueJobText.Summary(jobs));
        Assert.Equal("1 job", QueueJobText.Summary([jobs[0]]));
        Assert.Equal("Nothing waiting to print", QueueJobText.Summary([]));
        Assert.True(QueueJobText.IsProblem(JobStatus.Printing | JobStatus.PaperOut));
        Assert.False(QueueJobText.IsProblem(JobStatus.Printing));
    }
}
