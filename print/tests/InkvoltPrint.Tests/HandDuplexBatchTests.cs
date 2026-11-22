using InkvoltPrint.Core;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

/// <summary>
/// Batch print on both sides by hand (roadmap 4.2): on a printer that can't print both sides, each two-sided file goes as its fronts,
/// the reload prompt (<see cref="BatchPrintOptions.TurnStack"/>), then its backs (page 0: a blank side), and stopping at the prompt
/// stops the batch there.
/// </summary>
public class HandDuplexBatchTests
{
    private static readonly BatchQueueInfo OneSided = new("Test queue", FakeQueue.Papers, "NorthAmericaLetter", CanTwoSided: false);

    /// <summary>Records each job's pages; a page 0 is drawn as nothing (a blank side), as the app's queues draw it.</summary>
    private sealed class Queue : IBatchQueue
    {
        public List<BatchPrintJob> Sent { get; } = [];

        public Task<BatchQueueInfo?> ReadAsync(CancellationToken ct) => Task.FromResult<BatchQueueInfo?>(OneSided);

        public Task<string?> ProblemAsync(CancellationToken ct) => Task.FromResult<string?>(null);

        public async Task<BatchReceipt> SendAsync(IBatchDocument document, BatchPrintJob job, IProgress<string>? progress, Action? onSpooling, CancellationToken ct)
        {
            foreach (var page in job.Pages.Where(p => p > 0)) await document.RenderAsync(page, ct);
            onSpooling?.Invoke();
            Sent.Add(job);
            return new BatchReceipt(job.Pages.Count, BatchPrintSettings.Sheets(job.Pages.Count, job.Copies, job.TwoSided));
        }
    }

    private static async Task<BatchPrintLine> Line(BatchFolder folder, string name, int pages, int copies = 1, bool byHand = true)
    {
        var path = folder.File(name, $"pages={pages}");
        var measure = await BatchMeasurer.MeasureAsync(path, null, new FakeDocuments(), null, null, default);
        return new BatchPrintLine(path, new BatchPrintSettings(copies, TwoSided: true), measure, OneSided, byHand);
    }

    [Fact]
    public async Task Fronts_then_the_prompt_then_the_backs_last_sheet_first()
    {
        using var folder = new BatchFolder();
        var queue = new Queue();
        var asked = new List<(string Name, int Sheets)>();
        var options = new BatchPrintOptions
        {
            TurnStack = (name, plan, _) =>
            {
                asked.Add((name, plan.Sheets));
                Assert.Single(queue.Sent); // the fronts went first
                return Task.FromResult<OutputFace?>(OutputFace.Down);
            },
        };
        var line = await Line(folder, "report.pdf", 5);
        Assert.Null(line.Problem);
        Assert.True(line.ByHand);
        Assert.Equal(3, line.Sheets);
        var summary = await BatchPrintRunner.RunAsync([line], queue, new FakeDocuments(), options, null, default);
        Assert.Equal([("report.pdf", 3)], asked);
        Assert.Equal([1, 3, 5], queue.Sent[0].Pages);
        Assert.Equal([4, 2], queue.Sent[1].Pages); // page 5's sheet set aside
        Assert.All(queue.Sent, j => Assert.False(j.TwoSided));
        Assert.All(queue.Sent, j => Assert.Equal(1, j.Copies));
        var result = Assert.Single(summary.Items);
        Assert.Equal(BatchPrintState.Sent, result.State);
        Assert.Equal(3, result.SheetsSent);
    }

    [Fact]
    public async Task Copies_of_an_odd_file_send_a_blank_side_between_them_face_up_in_order()
    {
        using var folder = new BatchFolder();
        var queue = new Queue();
        var options = new BatchPrintOptions { TurnStack = (_, _, _) => Task.FromResult<OutputFace?>(OutputFace.Up) };
        await BatchPrintRunner.RunAsync([await Line(folder, "a.pdf", 3, copies: 2)], queue, new FakeDocuments(), options, null, default);
        Assert.Equal([1, 3, 1, 3], queue.Sent[0].Pages);
        Assert.Equal([2, 0, 2], queue.Sent[1].Pages);
    }

    [Fact]
    public async Task Stopping_at_the_prompt_stops_the_batch_after_the_fronts()
    {
        using var folder = new BatchFolder();
        var queue = new Queue();
        var options = new BatchPrintOptions { TurnStack = (_, _, _) => Task.FromResult<OutputFace?>(null) };
        var summary = await BatchPrintRunner.RunAsync([await Line(folder, "a.pdf", 4), await Line(folder, "b.pdf", 2)], queue, new FakeDocuments(), options, null, default);
        Assert.Single(queue.Sent); // a.pdf's fronts only
        Assert.Equal(BatchPrintState.Stopped, summary.Items[0].State);
        Assert.Equal(CoreStrings.Batch_BacksNotPrinted, summary.Items[0].Message);
        Assert.Equal(BatchPrintState.Stopped, summary.Items[1].State);
        Assert.NotNull(summary.StoppedAt);
    }

    [Fact]
    public async Task One_page_needs_no_prompt_and_nobody_to_ask_refuses_as_before()
    {
        using var folder = new BatchFolder();
        var queue = new Queue();
        var asked = 0;
        var options = new BatchPrintOptions { TurnStack = (_, _, _) => { asked++; return Task.FromResult<OutputFace?>(OutputFace.Down); } };
        await BatchPrintRunner.RunAsync([await Line(folder, "one.pdf", 1)], queue, new FakeDocuments(), options, null, default);
        Assert.Equal(0, asked);
        Assert.Equal([1], Assert.Single(queue.Sent).Pages);

        // The command line and a watched folder have nobody to put the stack back: two-sided on a one-sided printer is refused.
        Assert.Equal(CoreStrings.Batch_NoTwoSided, (await Line(folder, "cli.pdf", 4, byHand: false)).Problem);
        var noAsk = new Queue();
        var summary = await BatchPrintRunner.RunAsync([await Line(folder, "x.pdf", 4)], noAsk, new FakeDocuments(), null, null, default);
        Assert.Empty(noAsk.Sent);
        Assert.Equal(BatchPrintState.Skipped, summary.Items[0].State);
    }
}
