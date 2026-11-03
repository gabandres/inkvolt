using System.Diagnostics;
using System.Text;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>A temporary folder of made-up files. A file's text says what the fake engine makes of it: <c>pages=3;password=x;hang;drawfail=2</c>.</summary>
internal sealed class BatchFolder : IDisposable
{
    public string Root { get; } = Directory.CreateTempSubdirectory("inkvolt-batch-").FullName;

    public string File(string name, string text = "pages=1")
    {
        var path = Path.Combine(Root, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        System.IO.File.WriteAllText(path, text);
        return path;
    }

    public void Dispose()
    {
        try { Directory.Delete(Root, recursive: true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>Opens files as the real engines do: held, fingerprinted, then read; the file's text stands for what's in it.</summary>
internal sealed class FakeDocuments : IBatchDocuments
{
    public List<(string Name, string? Password)> Opened { get; } = [];

    public async Task<IBatchDocument> OpenAsync(string path, string? password, CancellationToken ct)
    {
        lock (Opened) Opened.Add((Path.GetFileName(path), password));
        var held = await BatchHeldFile.OpenAsync(path, ct);
        try
        {
            using var reader = new StreamReader(held.Stream, leaveOpen: true);
            var text = await reader.ReadToEndAsync(ct);
            held.Stream.Position = 0;
            var fields = text.Split(';').Select(f => f.Split('=', 2)).ToDictionary(f => f[0], f => f.ElementAtOrDefault(1) ?? "");
            if (fields.ContainsKey("hang")) await Task.Delay(Timeout.Infinite, ct);
            if (fields.TryGetValue("password", out var needed) && password != needed) throw new BatchPasswordException();
            if (fields.ContainsKey("damaged")) throw new BatchFileException("This file is damaged.");
            return new FakeDocument(held, int.Parse(fields.GetValueOrDefault("pages", "1")), int.Parse(fields.GetValueOrDefault("drawfail", "0")), fields.ContainsKey("hangdraw"));
        }
        catch
        {
            held.Dispose();
            throw;
        }
    }

    private sealed class FakeDocument(BatchHeldFile held, int pages, int drawFail, bool hangDraw) : IBatchDocument
    {
        public BatchFingerprint Fingerprint => held.Fingerprint;
        public int PageCount => pages;
        public PageSizing Sizing => PageSizing.ActualSize;

        public async Task<BatchPrintPage> RenderAsync(int page, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            if (hangDraw) await Task.Delay(Timeout.Infinite, ct);
            if (page == drawFail) throw new BatchFileException($"Page {page} can't be drawn.");
            return new BatchPrintPage([0xFF, 0xD8, 0xFF, 0xD9], 8.5, 11);
        }

        public void Dispose() => held.Dispose();
    }
}

/// <summary>A queue that records what it's sent: it draws every page first, as the real one does, and counts what it drew.</summary>
internal sealed class FakeQueue : IBatchQueue
{
    public static readonly IReadOnlyList<BatchPaper> Papers = [new("NorthAmericaLetter", "Letter"), new("ISOA4", "A4")];

    public List<BatchPrintJob> Sent { get; } = [];
    public bool CanTwoSided { get; init; } = true;
    public Func<int, string?>? ProblemBefore { get; init; } // by how many jobs were sent
    public Func<BatchPrintJob, Exception?>? FailOn { get; init; }
    public Func<BatchPrintJob, int>? SheetsOverride { get; init; }
    public Action<BatchPrintJob>? BeforeSpooling { get; set; }
    public Action<BatchPrintJob>? AfterSent { get; set; }
    public bool HangSpooling { get; init; }
    public bool NoQueue { get; init; }

    public Task<BatchQueueInfo?> ReadAsync(CancellationToken ct) =>
        Task.FromResult(NoQueue ? null : (BatchQueueInfo?)new BatchQueueInfo("Test queue", Papers, "NorthAmericaLetter", CanTwoSided));

    public Task<string?> ProblemAsync(CancellationToken ct) => Task.FromResult(ProblemBefore?.Invoke(Sent.Count));

    public async Task<BatchReceipt> SendAsync(IBatchDocument document, BatchPrintJob job, IProgress<string>? progress, Action? onSpooling, CancellationToken ct)
    {
        var drawn = 0;
        foreach (var page in job.Pages)
        {
            ct.ThrowIfCancellationRequested();
            await document.RenderAsync(page, ct);
            drawn++;
        }
        if (FailOn?.Invoke(job) is { } failure) throw failure;
        BeforeSpooling?.Invoke(job);
        ct.ThrowIfCancellationRequested();
        onSpooling?.Invoke();
        if (HangSpooling) await Task.Delay(Timeout.Infinite, CancellationToken.None);
        lock (Sent) Sent.Add(job);
        AfterSent?.Invoke(job);
        return new BatchReceipt(drawn, SheetsOverride?.Invoke(job) ?? BatchPrintSettings.Sheets(drawn, job.Copies, job.TwoSided));
    }
}

[Collection(Timing.Alone)] // open and send deadlines the healthy files must meet too: see Timing.Alone
public class BatchPrintTests
{
    private static readonly BatchQueueInfo Info = new("Test queue", FakeQueue.Papers, "NorthAmericaLetter", CanTwoSided: true);

    private static async Task<BatchPrintLine> Line(string path, BatchPrintSettings? settings = null, IBatchDocuments? documents = null, string? password = null, BatchQueueInfo? info = null) =>
        new(path, settings ?? new BatchPrintSettings(), await BatchMeasurer.MeasureAsync(path, password, documents ?? new FakeDocuments(), null, null, default), info ?? Info);

    private static Task<BatchPrintSummary> Run(IEnumerable<BatchPrintLine> lines, IBatchQueue queue, CancellationToken ct = default, BatchPrintOptions? options = null, IProgress<BatchPrintProgress>? progress = null) =>
        BatchPrintRunner.RunAsync(lines.ToList(), queue, new FakeDocuments(), options, progress, ct);

    // ------------------------------------------------------------------ the estimate

    [Theory]
    [InlineData(3, 1, false, 3)]
    [InlineData(3, 2, false, 6)]
    [InlineData(3, 1, true, 2)]
    [InlineData(3, 2, true, 4)]
    [InlineData(4, 1, true, 2)]
    [InlineData(1, 1, true, 1)]
    [InlineData(5000, 99, false, 495000)]
    public void Sheets_are_pages_per_side_times_copies(int pages, int copies, bool twoSided, int sheets) =>
        Assert.Equal(sheets, BatchPrintSettings.Sheets(pages, copies, twoSided));

    [Fact]
    public async Task A_range_is_read_against_the_file_and_counts_only_its_pages()
    {
        using var f = new BatchFolder();
        var line = await Line(f.File("a.pdf", "pages=10"), new BatchPrintSettings(2, "2-4, 9"));
        Assert.Null(line.Problem);
        Assert.Equal([2, 3, 4, 9], line.Pages);
        Assert.Equal(8, line.Sheets);
    }

    [Theory]
    [InlineData("11")]
    [InlineData("0-3")]
    [InlineData("two")]
    [InlineData("1-99999999")]
    public async Task A_range_the_file_doesnt_have_is_said_and_never_becomes_all_pages(string range)
    {
        using var f = new BatchFolder();
        var line = await Line(f.File("a.pdf", "pages=10"), new BatchPrintSettings(1, range));
        Assert.Contains("can't be printed", line.Problem);
        Assert.Empty(line.Pages);
        Assert.Equal(0, line.Sheets);
    }

    [Fact]
    public async Task A_paper_or_side_the_printer_doesnt_have_is_said_not_changed_quietly()
    {
        using var f = new BatchFolder();
        var path = f.File("a.pdf");
        Assert.Contains("A5", (await Line(path, new BatchPrintSettings(Paper: "A5"))).Problem);
        Assert.Null((await Line(path, new BatchPrintSettings(Paper: "isoa4"))).Problem);
        Assert.Contains("two-sided", (await Line(path, new BatchPrintSettings(TwoSided: true), info: Info with { CanTwoSided = false })).Problem);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(100)]
    [InlineData(-1)]
    public async Task Copies_out_of_bounds_are_refused(int copies)
    {
        using var f = new BatchFolder();
        Assert.Contains("Copies", (await Line(f.File("a.pdf"), new BatchPrintSettings(copies))).Problem);
    }

    [Theory]
    [InlineData(0, 100, true)]
    [InlineData(100, 0, true)]
    [InlineData(20_000, 20_000, true)]
    [InlineData(15_000, 15_000, false)]
    public void A_picture_claiming_a_huge_size_is_refused_before_decoding(long width, long height, bool refused) =>
        Assert.Equal(refused, BatchPrintLimits.PictureProblem(width, height) is not null);

    [Fact]
    public async Task A_file_of_too_many_pages_is_left_out()
    {
        using var f = new BatchFolder();
        var line = await Line(f.File("a.pdf", $"pages={BatchPrintLimits.MaxPages + 1}"));
        Assert.Equal(BatchMeasureState.Problem, line.Measure.State);
        Assert.Contains("at most", line.Problem);
        Assert.Equal(BatchMeasureState.Problem, (await Line(f.File("none.pdf", "pages=0"))).Measure.State);
    }

    [Fact]
    public async Task An_empty_file_a_folder_and_a_missing_file_read_as_problems_in_words()
    {
        using var f = new BatchFolder();
        Assert.Contains("empty", (await Line(f.File("a.pdf", ""))).Problem);
        Assert.Contains("gone", (await Line(Path.Combine(f.Root, "missing.pdf"))).Problem);
        Assert.Contains("damaged", (await Line(f.File("b.pdf", "damaged"))).Problem);
    }

    // ------------------------------------------------------------------ passwords

    [Fact]
    public async Task A_locked_pdf_asks_and_the_right_password_opens_it()
    {
        using var f = new BatchFolder();
        var asked = new List<(string, bool)>();
        var measure = await BatchMeasurer.MeasureAsync(f.File("locked.pdf", "pages=3;password=right"), null, new FakeDocuments(), (name, wrong) =>
        {
            asked.Add((name, wrong));
            return Task.FromResult<string?>("right");
        }, null, default);
        Assert.Equal(BatchMeasureState.Ready, measure.State);
        Assert.Equal(3, measure.PageCount);
        Assert.Equal("right", measure.Password);
        Assert.Equal([("locked.pdf", false)], asked);
        Assert.DoesNotContain("right", measure.ToString());
        Assert.DoesNotContain("right", new BatchPrintLine("locked.pdf", new BatchPrintSettings(), measure, Info).ToString());
    }

    [Fact]
    public async Task A_wrong_password_stops_asking_after_three_tries()
    {
        using var f = new BatchFolder();
        var asked = new List<bool>();
        var measure = await BatchMeasurer.MeasureAsync(f.File("locked.pdf", "password=right"), null, new FakeDocuments(), (_, wrong) =>
        {
            asked.Add(wrong);
            return Task.FromResult<string?>("nope");
        }, null, default);
        Assert.Equal(BatchMeasureState.WrongPassword, measure.State);
        Assert.Equal([false, true, true], asked);
        Assert.Null(measure.Password);
    }

    [Fact]
    public async Task Declining_the_password_leaves_the_file_out()
    {
        using var f = new BatchFolder();
        var measure = await BatchMeasurer.MeasureAsync(f.File("locked.pdf", "password=right"), null, new FakeDocuments(), (_, _) => Task.FromResult<string?>(null), null, default);
        Assert.Equal(BatchMeasureState.NeedsPassword, measure.State);
    }

    [Fact]
    public async Task With_nobody_to_ask_a_password_is_tried_once_and_only_on_a_file_that_asks()
    {
        using var f = new BatchFolder();
        var documents = new FakeDocuments();
        Assert.Equal(BatchMeasureState.NeedsPassword, (await Line(f.File("locked.pdf", "password=right"), documents: documents)).Measure.State);
        documents.Opened.Clear();
        Assert.Equal(BatchMeasureState.WrongPassword, (await Line(f.File("locked.pdf", "password=right"), documents: documents, password: "nope")).Measure.State);
        Assert.Equal([("locked.pdf", (string?)null), ("locked.pdf", "nope")], documents.Opened);

        documents.Opened.Clear();
        var open = await Line(f.File("open.pdf"), documents: documents, password: "secret");
        Assert.Null(open.Problem);
        Assert.Null(open.Measure.Password);
        Assert.Equal([("open.pdf", (string?)null)], documents.Opened); // a file that doesn't ask never sees it
    }

    [Fact]
    public async Task A_file_that_hangs_the_engine_is_given_up_on_and_the_next_one_reads()
    {
        using var f = new BatchFolder();
        var options = new BatchPrintOptions { OpenTimeout = Timing.Limit(TimeSpan.FromMilliseconds(500)) }; // ok.pdf must open within it too
        var measure = await BatchMeasurer.MeasureAsync(f.File("hang.pdf", "hang"), null, new FakeDocuments(), null, options, default);
        Assert.Equal(BatchMeasureState.Problem, measure.State);
        Assert.Contains("too long", measure.Problem);
        Assert.Equal(BatchMeasureState.Ready, (await BatchMeasurer.MeasureAsync(f.File("ok.pdf"), null, new FakeDocuments(), null, options, default)).State);
    }

    // ------------------------------------------------------------------ the run

    [Fact]
    public async Task Fifty_files_print_in_order_with_the_estimated_sheet_count()
    {
        using var f = new BatchFolder();
        var lines = new List<BatchPrintLine>();
        var kinds = new[] { ".pdf", ".jpg", ".png", ".tif" };
        var documents = new FakeDocuments();
        var expected = new List<string>();
        var random = new Random(24);
        for (var i = 0; i < 49; i++)
        {
            var name = $"file {i:00}{kinds[i % 4]}";
            var settings = new BatchPrintSettings(random.Next(1, 4), null, i % 3 == 0, i % 5 == 0 ? "ISOA4" : null);
            lines.Add(await Line(f.File(name, $"pages={1 + i % 7}"), settings, documents));
            expected.Add(name);
        }
        var locked = await BatchMeasurer.MeasureAsync(f.File("locked.pdf", "pages=5;password=open sesame"), null, documents, (_, _) => Task.FromResult<string?>("open sesame"), null, default);
        lines.Insert(20, new BatchPrintLine(Path.Combine(f.Root, "locked.pdf"), new BatchPrintSettings(), locked, Info));
        expected.Insert(20, "locked.pdf");

        var queue = new FakeQueue();
        var summary = await BatchPrintRunner.RunAsync(lines, queue, documents, null, null, default);

        Assert.Equal(50, summary.Sent);
        Assert.Equal(expected, queue.Sent.Select(j => j.Name));
        Assert.Equal(lines.Sum(l => l.Sheets), summary.SheetsSent);
        Assert.Equal(lines.Select(l => l.Sheets), summary.Items.Select(r => r.SheetsSent));
        Assert.Equal(lines.Select(l => l.Sheets), queue.Sent.Select(j => j.Sheets));
        Assert.Equal(BatchPrintSummary.Done, summary.ExitCode);
        Assert.Equal(5, queue.Sent[20].Pages.Count);
    }

    [Fact]
    public async Task A_file_that_vanishes_after_the_estimate_is_listed_and_the_batch_goes_on()
    {
        using var f = new BatchFolder();
        var (a, b, c) = (f.File("a.pdf"), f.File("b.pdf"), f.File("c.pdf"));
        var lines = new[] { await Line(a), await Line(b), await Line(c) };
        File.Delete(b);
        var queue = new FakeQueue();
        var summary = await Run(lines, queue);
        Assert.Equal(["a.pdf", "c.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Equal(BatchPrintState.Failed, summary.Items[1].State);
        Assert.Contains("gone", summary.Items[1].Message);
        Assert.Equal(0, summary.Items[1].SheetsSent);
        Assert.Equal(BatchPrintSummary.SomeFailed, summary.ExitCode);
        Assert.Null(summary.StoppedAt);
    }

    [Fact]
    public async Task A_file_that_changes_after_the_estimate_isnt_printed()
    {
        using var f = new BatchFolder();
        var (a, b) = (f.File("a.pdf", "pages=2"), f.File("b.pdf", "pages=2"));
        var lines = new[] { await Line(a), await Line(b) };
        File.WriteAllText(a, "pages=200");
        File.WriteAllText(b, "pages=2 "); // the same page count, other bytes: what would print isn't what was seen
        var queue = new FakeQueue();
        var summary = await Run(lines, queue);
        Assert.Empty(queue.Sent);
        Assert.All(summary.Items, r => Assert.Equal(BatchPrintState.Failed, r.State));
        Assert.Contains("2 pages then, 200 now", summary.Items[0].Message);
        Assert.Contains("changed", summary.Items[1].Message);
    }

    [Fact]
    public async Task A_file_cant_change_or_vanish_while_its_being_sent()
    {
        using var f = new BatchFolder();
        var a = f.File("a.pdf");
        var line = await Line(a);
        Exception? write = null, delete = null, rename = null;
        var queue = new FakeQueue
        {
            BeforeSpooling = _ =>
            {
                write = Record.Exception(() => File.WriteAllText(a, "pages=200"));
                delete = Record.Exception(() => File.Delete(a));
                rename = Record.Exception(() => File.Move(a, a + ".moved"));
            },
        };
        var summary = await Run([line], queue);
        Assert.Equal(1, summary.Sent);
        Assert.IsType<IOException>(write);
        Assert.NotNull(delete);
        Assert.NotNull(rename);
        Assert.Equal("pages=1", File.ReadAllText(a));
    }

    [Fact]
    public async Task A_page_that_cant_be_drawn_sends_nothing_for_that_file()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("bad.pdf", "pages=4;drawfail=3")), await Line(f.File("good.pdf")) };
        var queue = new FakeQueue();
        var summary = await Run(lines, queue);
        Assert.Equal(["good.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Contains("Page 3", summary.Items[0].Message);
        Assert.Equal(BatchPrintState.Failed, summary.Items[0].State);
    }

    [Fact]
    public async Task A_line_with_a_problem_is_skipped_with_its_reason_and_the_batch_goes_on()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("a.pdf", "pages=2"), new BatchPrintSettings(Range: "5")), await Line(f.File("locked.pdf", "password=x")), await Line(f.File("b.pdf")) };
        var queue = new FakeQueue();
        var summary = await Run(lines, queue);
        Assert.Equal(["b.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Equal(BatchPrintState.Skipped, summary.Items[0].State);
        Assert.Equal(BatchPrintState.Skipped, summary.Items[1].State);
        Assert.Contains("password", summary.Items[1].Message);
        Assert.Equal(BatchPrintSummary.SomeFailed, summary.ExitCode);
        Assert.Equal("1 sent (1 sheet), 2 skipped.", summary.Text);
    }

    [Fact]
    public async Task A_printer_with_a_problem_stops_the_batch_and_it_says_where()
    {
        using var f = new BatchFolder();
        var lines = new List<BatchPrintLine>();
        for (var i = 1; i <= 10; i++) lines.Add(await Line(f.File($"f{i}.pdf")));
        var queue = new FakeQueue { ProblemBefore = sent => sent == 6 ? "Paper jam" : null };
        var summary = await Run(lines, queue);
        Assert.Equal(6, queue.Sent.Count);
        Assert.Equal(6, summary.StoppedAt);
        Assert.Equal("Stopped at file 7 of 10 (f7.pdf): Paper jam 6 sent (6 sheets), 4 not sent.", summary.Text);
        Assert.Equal(BatchPrintSummary.Stopped, summary.ExitCode);
        Assert.All(summary.Items.Skip(6), r => Assert.Equal(BatchPrintState.Stopped, r.State));
    }

    [Fact]
    public async Task A_queue_that_fails_stops_the_batch_and_only_a_sure_failure_reads_as_not_sent()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("a.pdf")), await Line(f.File("b.pdf")), await Line(f.File("c.pdf")) };

        var sure = await Run(lines, new FakeQueue { FailOn = j => j.Name == "b.pdf" ? new BatchQueueException("The queue is gone.", mayHaveSent: false) : null });
        Assert.Equal(1, sure.StoppedAt);
        Assert.Equal(BatchPrintState.Stopped, sure.Items[1].State);

        var unsure = await Run(lines, new FakeQueue { FailOn = j => j.Name == "b.pdf" ? new BatchQueueException("The spooler stopped.", mayHaveSent: true) : null });
        Assert.Equal(1, unsure.StoppedAt);
        Assert.Equal(BatchPrintState.Failed, unsure.Items[1].State);
        Assert.Contains("check the queue", unsure.Items[1].Message);
        Assert.Equal(BatchPrintState.Stopped, unsure.Items[2].State);

        var strange = await Run(lines, new FakeQueue { FailOn = j => j.Name == "a.pdf" ? new InvalidOperationException("Driver said no.") : null });
        Assert.Equal(0, strange.StoppedAt);
        Assert.Contains("check the queue", strange.Items[0].Message);
    }

    [Fact]
    public async Task A_setting_the_driver_wont_keep_fails_only_that_file()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("a.pdf")), await Line(f.File("b.pdf")) };
        var queue = new FakeQueue { FailOn = j => j.Name == "a.pdf" ? new BatchSettingRefusedException("The driver wouldn't keep the paper.") : null };
        var summary = await Run(lines, queue);
        Assert.Equal(["b.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Equal(BatchPrintState.Failed, summary.Items[0].State);
        Assert.Contains("Not printed", summary.Items[0].Message);
    }

    [Fact]
    public async Task Stop_between_files_sends_nothing_more_and_says_where()
    {
        using var f = new BatchFolder();
        var lines = new List<BatchPrintLine>();
        for (var i = 1; i <= 5; i++) lines.Add(await Line(f.File($"f{i}.pdf")));
        using var stop = new CancellationTokenSource();
        var queue = new FakeQueue();
        queue.AfterSent = j =>
        {
            if (j.Name == "f2.pdf") stop.Cancel(); // while the second is being handed over: it finishes
        };
        var summary = await Run(lines, queue, stop.Token);
        Assert.Equal(["f1.pdf", "f2.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Equal(2, summary.StoppedAt);
        Assert.Contains("You stopped", summary.Text);
        Assert.Contains("file 3 of 5 (f3.pdf)", summary.Text);
        Assert.Equal(BatchPrintSummary.Stopped, summary.ExitCode);
    }

    [Fact]
    public async Task Stop_while_a_file_is_being_drawn_sends_nothing_for_it()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("a.pdf")), await Line(f.File("b.pdf")) };
        using var stop = new CancellationTokenSource();
        var queue = new FakeQueue();
        queue.BeforeSpooling = _ => stop.Cancel();
        var summary = await Run(lines, queue, stop.Token);
        Assert.Empty(queue.Sent);
        Assert.Equal(0, summary.StoppedAt);
        Assert.Equal(BatchPrintState.Stopped, summary.Items[0].State);
    }

    [Fact]
    public async Task A_drawing_that_hangs_is_given_up_on_and_the_next_file_prints()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("hang.pdf", "pages=2;hangdraw")), await Line(f.File("b.pdf")) };
        var queue = new FakeQueue();
        var summary = await Run(lines, queue, options: new BatchPrintOptions { SendTimeout = Timing.Limit(TimeSpan.FromMilliseconds(500)), SendTimePerPage = TimeSpan.Zero });
        Assert.Equal(["b.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Equal(BatchPrintState.Failed, summary.Items[0].State);
        Assert.Contains("too long", summary.Items[0].Message);
        Assert.Null(summary.StoppedAt);
    }

    [Fact]
    public async Task A_spooler_that_hangs_stops_the_batch_as_the_job_may_be_there()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("a.pdf")), await Line(f.File("b.pdf")) };
        var queue = new FakeQueue { HangSpooling = true };
        var summary = await Run(lines, queue, options: new BatchPrintOptions { SendTimeout = Timing.Limit(TimeSpan.FromMilliseconds(500)), SendTimePerPage = TimeSpan.Zero });
        Assert.Equal(0, summary.StoppedAt);
        Assert.Equal(BatchPrintState.Failed, summary.Items[0].State);
        Assert.Contains("check the queue", summary.Items[0].Message);
        Assert.Equal(BatchPrintState.Stopped, summary.Items[1].State);
    }

    [Fact]
    public async Task A_job_that_comes_to_more_sheets_than_the_estimate_stops_the_batch()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("a.pdf")), await Line(f.File("b.pdf")) };
        var queue = new FakeQueue { SheetsOverride = _ => 2 };
        var summary = await Run(lines, queue);
        Assert.Single(queue.Sent);
        Assert.Equal(0, summary.StoppedAt);
        Assert.Contains("more than the 1 estimated", summary.Items[0].Message);
    }

    [Fact]
    public async Task The_job_carries_the_range_copies_side_and_paper_of_its_line_and_no_password()
    {
        using var f = new BatchFolder();
        var path = f.File("a.pdf", "pages=9;password=x");
        var line = new BatchPrintLine(path, new BatchPrintSettings(3, "2,4-5", true, "ISOA4"),
            await BatchMeasurer.MeasureAsync(path, "x", new FakeDocuments(), null, null, default), Info);
        var queue = new FakeQueue();
        await Run([line], queue);
        var job = Assert.Single(queue.Sent);
        Assert.Equal([2, 4, 5], job.Pages);
        Assert.Equal((3, true, "ISOA4", 6), (job.Copies, job.TwoSided, job.Paper, job.Sheets));
        Assert.DoesNotContain("\"x\"", job.ToString());
    }

    [Fact]
    public async Task Resuming_a_stopped_batch_sends_only_what_wasnt_sent_so_nothing_prints_twice()
    {
        using var f = new BatchFolder();
        var lines = new List<BatchPrintLine>();
        for (var i = 1; i <= 6; i++) lines.Add(await Line(f.File($"f{i}.pdf")));
        var problem = true;
        var queue = new FakeQueue { ProblemBefore = sent => problem && sent == 2 ? "Paper jam" : null };
        var first = await Run(lines, queue);
        problem = false;
        var again = first.Items.Where(r => r.StillToSend).Select(r => lines[r.Index]).ToList();
        var second = await Run(again, queue);
        Assert.Equal(lines.Select(l => l.Name), queue.Sent.Select(j => j.Name));
        Assert.Equal(4, second.Sent);
        Assert.DoesNotContain(second.Items, r => r.StillToSend);
    }

    [Fact]
    public async Task A_file_that_may_have_reached_the_queue_isnt_sent_again_by_itself()
    {
        using var f = new BatchFolder();
        var lines = new[] { await Line(f.File("a.pdf")), await Line(f.File("b.pdf")), await Line(f.File("c.pdf", "pages=2"), new BatchPrintSettings(Range: "9")) };
        var summary = await Run(lines, new FakeQueue { FailOn = j => j.Name == "b.pdf" ? new BatchQueueException("The spooler stopped.", true) : null });
        Assert.False(summary.Items[0].StillToSend); // sent
        Assert.False(summary.Items[0].MayHaveSent);
        Assert.False(summary.Items[1].StillToSend);
        Assert.True(summary.Items[1].MayHaveSent);
        Assert.True(summary.Items[2].StillToSend); // skipped: checked again when it's sent

        var changed = await Run([await Line(f.File("d.pdf"))], new FakeQueue { FailOn = _ => new BatchSettingRefusedException("No.") });
        Assert.False(changed.Items[0].MayHaveSent); // refused before anything was sent
    }

    // ------------------------------------------------------------------ what the driver kept

    [Fact]
    public void A_ticket_that_doesnt_keep_what_was_asked_is_refused()
    {
        (double, double) letter = (816, 1056), a4 = (793.7, 1122.5);
        Assert.Null(BatchTicketCheck.Problem(2, true, letter, 2, true, letter));
        Assert.Null(BatchTicketCheck.Problem(1, false, null, 1, null, a4));
        Assert.Null(BatchTicketCheck.Problem(1, false, null, null, false, letter));
        Assert.Contains("two-sided", BatchTicketCheck.Problem(1, true, null, 1, false, letter));
        Assert.Contains("two-sided", BatchTicketCheck.Problem(1, true, null, 1, null, letter));
        Assert.Contains("one-sided", BatchTicketCheck.Problem(1, false, null, 1, true, letter));
        Assert.Contains("paper", BatchTicketCheck.Problem(1, false, a4, 1, false, letter));
        Assert.Contains("paper", BatchTicketCheck.Problem(1, false, a4, 1, false, null));
        Assert.Contains("3 copies", BatchTicketCheck.Problem(5, false, null, 3, false, letter));
        Assert.Contains("1 copy", BatchTicketCheck.Problem(5, false, null, 1, false, letter));
    }

    // ------------------------------------------------------------------ a folder's files

    [Fact]
    public void A_folder_comes_in_explorers_order_each_file_once()
    {
        using var f = new BatchFolder();
        foreach (var name in new[] { "page 10.pdf", "page 2.pdf", "Page 1.jpg", "notes.txt", "scan.TIF", "~$draft.pdf", "a.png" }) f.File(name);
        var hidden = f.File("hidden.pdf");
        File.SetAttributes(hidden, FileAttributes.Hidden);
        f.File(@"sub\below.pdf");

        var files = BatchPrintFiles.Expand([f.Root, Path.Combine(f.Root, "page 2.pdf")], recursive: false, out var leftOut);
        Assert.Equal(["a.png", "Page 1.jpg", "page 2.pdf", "page 10.pdf", "scan.TIF"], files.Select(Path.GetFileName));
        Assert.Equal(0, leftOut);

        var below = BatchPrintFiles.Expand([f.Root], recursive: true, out _);
        Assert.Contains(Path.Combine(f.Root, "sub", "below.pdf"), below);
        Assert.Equal(6, below.Count);
    }

    [Fact]
    public void What_isnt_printable_is_counted_as_left_out()
    {
        using var f = new BatchFolder();
        var files = BatchPrintFiles.Expand([f.File("notes.txt"), Path.Combine(f.Root, "gone.pdf"), f.File("a.pdf")], false, out var leftOut);
        Assert.Equal(["a.pdf"], files.Select(Path.GetFileName));
        Assert.Equal(2, leftOut);
    }

    [Theory]
    [InlineData("a2", "a10", -1)]
    [InlineData("a010", "a10", -1)]
    [InlineData("B", "a", 1)]
    [InlineData("file", "file 1", -1)]
    [InlineData("a", "a", 0)]
    [InlineData("99999999999999999999999", "100000000000000000000000", -1)]
    public void Natural_order_compares_numbers_as_numbers(string a, string b, int sign) =>
        Assert.Equal(sign, Math.Sign(NaturalOrder.Instance.Compare(a, b)));

    // ------------------------------------------------------------------ the results as CSV

    private static BatchPrintResult Result(string name, string message = "Sent to the queue: 1 sheet.") =>
        new(0, Path.Combine(@"C:\Docs", name), BatchPrintState.Sent, message, 1, 2, true, "ISOA4", 1, 1, new DateTime(2026, 10, 31, 9, 5, 0));

    [Fact]
    public void The_csv_has_a_row_per_file()
    {
        var csv = BatchPrintCsv.Build([Result("a, b.pdf")]);
        var rows = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.StartsWith("Order,File,Folder,Result,Details,Pages,Copies,Two-sided,Paper,Sheets estimated,Sheets sent,Time", rows[0]);
        Assert.Equal(@"1,""a, b.pdf"",C:\Docs,Sent,Sent to the queue: 1 sheet.,1,2,Yes,ISOA4,1,1,2026-10-31 09:05:00", rows[1]);
    }

    [Theory]
    [InlineData("=HYPERLINK(1).pdf")]
    [InlineData("+1.pdf")]
    [InlineData("-1.pdf")]
    [InlineData("@SUM(1).pdf")]
    [InlineData(" =1+1.pdf")]
    [InlineData("\t=1+1.pdf")]
    [InlineData("\uFF1D1+1.pdf")]
    public void A_file_name_that_is_a_formula_stays_words(string name)
    {
        var cell = BatchPrintCsv.Build([Result(name)]).Split("\r\n")[1].Split(',')[1];
        Assert.StartsWith("'", cell.TrimStart('"'));
    }

    [Theory]
    [InlineData("=cmd|' /C calc'!A0")]
    [InlineData("\r=1")]
    public void A_cell_is_never_a_formula_whatever_the_message(string message)
    {
        var cell = CsvCell.Of(message);
        Assert.StartsWith("'", cell.TrimStart('"'));
    }

    [Fact]
    public void Plain_text_and_quotes_are_left_as_rfc_4180_has_them()
    {
        Assert.Equal("report.pdf", CsvCell.Of("report.pdf"));
        Assert.Equal("\"say \"\"hi\"\", ok\"", CsvCell.Of("say \"hi\", ok"));
        Assert.Equal("", CsvCell.Of(""));
    }
}

/// <summary>Saved lists: what they hold, and every path they may not use.</summary>
public class BatchPrintListTests
{
    private const string Folder = @"C:\Lists";

    private static string? Check(string? raw, out string? server) => BatchPrintList.CheckPath(raw, Folder, out server, out _);

    [Theory]
    [InlineData(@"\\?\C:\Windows\win.ini")]
    [InlineData(@"\\.\PhysicalDrive0")]
    [InlineData(@"\\.\NUL")]
    [InlineData(@"\??\C:\a.pdf")]
    [InlineData(@"C:\a.pdf:hidden")]
    [InlineData(@"C:a.pdf")]
    [InlineData(@"\a.pdf")]
    [InlineData(@"http://example.com/a.pdf")]
    [InlineData(@"file:///C:/a.pdf")]
    [InlineData(@"..\secret.pdf")]
    [InlineData(@"sub\..\..\secret.pdf")]
    [InlineData(@"..\Lists2\a.pdf")]
    [InlineData(@"C:\docs\NUL.pdf")]
    [InlineData(@"COM1.pdf")]
    [InlineData(@"C:\docs\con\a.pdf")]
    [InlineData(@"LPT1")]
    [InlineData(@"a?.pdf")]
    [InlineData(@"a*.pdf")]
    [InlineData("a\u0007.pdf")]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(null)]
    public void A_path_a_list_may_not_use_is_refused_without_touching_anything(string? raw) =>
        Assert.Null(Check(raw, out _));

    [Theory]
    [InlineData(@"a.pdf", @"C:\Lists\a.pdf")]
    [InlineData(@"sub\b.jpg", @"C:\Lists\sub\b.jpg")]
    [InlineData(@"sub/b.jpg", @"C:\Lists\sub\b.jpg")]
    [InlineData(@"sub\..\c.pdf", @"C:\Lists\c.pdf")]
    [InlineData(@"D:\Docs\a.pdf", @"D:\Docs\a.pdf")]
    [InlineData(@"D:/Docs/a.pdf", @"D:\Docs\a.pdf")]
    public void A_relative_path_is_from_the_lists_folder_and_a_full_one_stays(string raw, string full)
    {
        Assert.Equal(full, Check(raw, out var server));
        Assert.Null(server);
    }

    [Theory]
    [InlineData(@"\\server\share\a.pdf", "server")]
    [InlineData(@"//server/share/a.pdf", "server")]
    public void Another_computers_path_is_named(string raw, string name)
    {
        Assert.NotNull(Check(raw, out var server));
        Assert.Equal(name, server);
    }

    private static string WriteList(BatchFolder f, string json, string name = "list.inkvoltlist") => f.File(name, json);

    [Fact]
    public void A_list_needs_a_yes_to_reach_another_computer_and_says_which()
    {
        using var f = new BatchFolder();
        var list = WriteList(f, """{ "version": 1, "files": [ { "path": "\\\\files01\\share\\a.pdf" }, { "path": "b.pdf" } ] }""");
        var ex = Assert.Throws<BatchListNetworkException>(() => BatchPrintList.Load(list, allowNetwork: false));
        Assert.Equal(["files01"], ex.Servers);
        Assert.Equal(2, BatchPrintList.Load(list, allowNetwork: true).Count);
    }

    [Fact]
    public void A_saved_list_reads_back_the_same_and_has_no_password()
    {
        using var f = new BatchFolder();
        var path = Path.Combine(f.Root, "saved" + BatchPrintList.Extension);
        BatchListEntry[] entries =
        [
            new(Path.Combine(f.Root, "a.pdf"), new BatchPrintSettings(3, "1-2", true, "ISOA4")),
            new(Path.Combine(f.Root, "b.png"), new BatchPrintSettings()),
        ];
        BatchPrintList.Save(path, entries);
        Assert.Equal(entries, BatchPrintList.Load(path, false));
        Assert.False(File.Exists(path + ".tmp"));
        Assert.DoesNotContain("password", File.ReadAllText(path), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void A_hand_written_list_takes_defaults_comments_and_a_trailing_comma()
    {
        using var f = new BatchFolder();
        var list = WriteList(f, """
            // monthly statements
            { "Version": 1, "defaults": { "copies": 2, "twoSided": true, "paper": "ISOA4" },
              "files": [ { "path": "a.pdf" }, { "path": "b.pdf", "copies": 1, "twoSided": false, "paper": "NorthAmericaLetter", "range": "2" }, ] }
            """);
        var entries = BatchPrintList.Load(list, false);
        Assert.Equal(new BatchPrintSettings(2, null, true, "ISOA4"), entries[0].Settings);
        Assert.Equal(new BatchPrintSettings(1, "2", false, "NorthAmericaLetter"), entries[1].Settings);
    }

    [Theory]
    [InlineData("""{ "version": 1, "files": [ { "path": "a.pdf", "copies": 9999 } ] }""", "copies")]
    [InlineData("""{ "version": 1, "files": [ { "path": "a.pdf", "copies": 0 } ] }""", "copies")]
    [InlineData("""{ "version": 1, "defaults": { "copies": 500 }, "files": [ { "path": "a.pdf" } ] }""", "copies")]
    [InlineData("""{ "version": 2, "files": [] }""", "newer")]
    [InlineData("""{ "files": [] }""", "version")]
    [InlineData("""{ "version": 1 }""", "no files")]
    [InlineData("""{ "version": 1, "files": [ { "copies": 2 } ] }""", "Line 1")]
    [InlineData("""{ "version": 1, "files": [ { "path": "..\\..\\x.pdf" } ] }""", "leaves")]
    [InlineData("""{ "version": 1, "files": [ { "path": 5 } ] }""", "damaged")]
    [InlineData("""not json""", "damaged")]
    [InlineData("""[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]""", "damaged")]
    [InlineData("""null""", "empty")]
    public void A_bad_list_is_refused_and_says_why(string json, string word)
    {
        using var f = new BatchFolder();
        var ex = Assert.Throws<BatchListException>(() => BatchPrintList.Load(WriteList(f, json), false));
        Assert.Contains(word, ex.Message);
    }

    [Fact]
    public void A_list_too_long_or_too_large_is_refused()
    {
        using var f = new BatchFolder();
        var lines = string.Join(",", Enumerable.Repeat("""{"path":"a.pdf"}""", BatchPrintLimits.MaxFiles + 1));
        Assert.Contains("at most", Assert.Throws<BatchListException>(() => BatchPrintList.Load(WriteList(f, $$"""{"version":1,"files":[{{lines}}]}"""), false)).Message);
        var huge = WriteList(f, new string(' ', (4 << 20) + 1), "huge.inkvoltlist");
        Assert.Contains("too large", Assert.Throws<BatchListException>(() => BatchPrintList.Load(huge, false)).Message);
        Assert.Contains("no list file", Assert.Throws<BatchListException>(() => BatchPrintList.Load(Path.Combine(f.Root, "none"), false)).Message);
    }

    [Fact]
    public void A_folder_line_becomes_its_files_with_the_lines_settings_and_a_missing_file_stays_to_read_as_gone()
    {
        using var f = new BatchFolder();
        f.File(@"in\b 10.pdf");
        f.File(@"in\b 2.pdf");
        var settings = new BatchPrintSettings(2);
        var expanded = BatchPrintList.Expand([new(Path.Combine(f.Root, "in"), settings), new(Path.Combine(f.Root, "gone.pdf"), settings)]);
        Assert.Equal(["b 2.pdf", "b 10.pdf", "gone.pdf"], expanded.Select(e => Path.GetFileName(e.Path)));
        Assert.All(expanded, e => Assert.Equal(settings, e.Settings));
    }

    [Fact]
    public void A_line_naming_something_else_refuses_the_list()
    {
        using var f = new BatchFolder();
        var ex = Assert.Throws<BatchListException>(() => BatchPrintList.Expand([new(f.File("secrets.txt"), new BatchPrintSettings())]));
        Assert.Contains("neither", ex.Message);
    }

    [Fact]
    public async Task A_link_in_a_list_or_a_folder_isnt_followed()
    {
        using var f = new BatchFolder();
        var target = f.File("real.pdf");
        var link = Path.Combine(f.Root, "in", "link.pdf");
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        try
        {
            File.CreateSymbolicLink(link, target);
        }
        catch (IOException)
        {
            return; // this Windows doesn't let this user make links
        }
        catch (UnauthorizedAccessException)
        {
            return;
        }
        Assert.Empty(BatchPrintFiles.ListFolder(Path.GetDirectoryName(link)!, false));
        var ex = await Assert.ThrowsAsync<BatchFileException>(() => BatchHeldFile.OpenAsync(link, default));
        Assert.Contains("link", ex.Message);
    }

    [Fact]
    public void A_list_a_windows_tool_wrote_with_a_byte_order_mark_reads()
    {
        using var f = new BatchFolder();
        const string json = """{ "version": 1, "files": [{ "path": "a.pdf", "copies": 2 }] }""";
        foreach (var encoding in new Encoding[] { new UTF8Encoding(true), Encoding.Unicode, Encoding.BigEndianUnicode })
        {
            var path = Path.Combine(f.Root, "list.inkvoltlist");
            File.WriteAllBytes(path, [.. encoding.GetPreamble(), .. encoding.GetBytes(json)]);
            Assert.Equal(2, Assert.Single(BatchPrintList.Load(path, false)).Settings.Copies);
        }
    }

    [Fact]
    public void A_list_of_broken_text_is_refused_in_words()
    {
        using var f = new BatchFolder();
        var path = Path.Combine(f.Root, "bytes.inkvoltlist");
        File.WriteAllBytes(path, [.. """{ "version": 1, "files": [{ "path": "a"""u8.ToArray(), 0xFF, 0xFE, .. """.pdf" }] }"""u8.ToArray()]);
        Assert.Throws<BatchListException>(() => BatchPrintList.Load(path, false));
    }

    private static bool Junction(string link, string target)
    {
        using var mklink = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", ["/c", "mklink", "/J", link, target])
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
        })!;
        mklink.WaitForExit();
        return mklink.ExitCode == 0 && Directory.Exists(link);
    }

    [Fact]
    public void A_recursive_folder_doesnt_follow_a_junction_out_of_it_or_round_in_a_loop()
    {
        using var f = new BatchFolder();
        var own = f.File(@"in\sub\own.pdf");
        f.File(@"secret\payroll.pdf");
        var folder = Path.Combine(f.Root, "in");
        if (!Junction(Path.Combine(folder, "out"), Path.Combine(f.Root, "secret")) || !Junction(Path.Combine(folder, "sub", "loop"), folder)) return;
        Assert.Equal([own], BatchPrintFiles.ListFolder(folder, recursive: true));
    }
}

/// <summary>A folder printed as it fills.</summary>
[Collection(Timing.Alone)] // quiet periods and polling: see Timing.Alone
public class BatchPrintFolderTests
{
    private static readonly BatchFolderOptions Fast = new()
    {
        Once = true,
        PollInterval = TimeSpan.FromMilliseconds(10),
        QuietPeriod = TimeSpan.FromMilliseconds(50),
    };

    private static Task<BatchFolderSummary> Run(BatchFolder f, FakeQueue queue, BatchFolderOptions? options = null, IProgress<BatchFolderProgress>? progress = null, CancellationToken ct = default) =>
        BatchPrintFolder.RunAsync(f.Root, queue, new FakeDocuments(), options ?? Fast, progress, ct);

    private static string[] In(BatchFolder f, string sub) => Directory.GetFiles(Path.Combine(f.Root, sub)).Select(Path.GetFileName).Order().ToArray()!;

    [Fact]
    public async Task Files_print_in_name_order_once_and_move_to_done()
    {
        using var f = new BatchFolder();
        f.File("b 10.pdf", "pages=2");
        f.File("b 2.pdf");
        f.File("a.jpg");
        f.File("notes.txt");
        var queue = new FakeQueue();
        var summary = await Run(f, queue);
        Assert.Equal(["a.jpg", "b 2.pdf", "b 10.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Equal((3, 0, 4), (summary.Sent, summary.Failed, summary.SheetsSent));
        Assert.Equal(["a.jpg", "b 10.pdf", "b 2.pdf"], In(f, "done"));
        Assert.True(File.Exists(Path.Combine(f.Root, "notes.txt")));
        Assert.Empty(In(f, "working"));
        Assert.Equal(3, File.ReadAllLines(Path.Combine(f.Root, BatchPrintFolder.LogName)).Length);
    }

    [Fact]
    public async Task A_restart_prints_nothing_twice()
    {
        using var f = new BatchFolder();
        f.File("a.pdf");
        var queue = new FakeQueue();
        await Run(f, queue);
        await Run(f, queue);
        Assert.Single(queue.Sent);
        Assert.Equal(["a.pdf"], In(f, "done"));
    }

    [Fact]
    public async Task A_file_left_working_by_a_crash_goes_to_failed_and_never_prints_by_itself()
    {
        using var f = new BatchFolder();
        f.File(@"working\sent before the crash.pdf");
        var queue = new FakeQueue();
        var entries = new List<BatchFolderEntry>();
        var summary = await Run(f, queue, progress: new Direct<BatchFolderProgress>(p =>
        {
            if (p.Finished is { } e) entries.Add(e);
        }));
        Assert.Empty(queue.Sent);
        Assert.Equal(1, summary.Failed);
        Assert.Equal(["sent before the crash.pdf"], In(f, "failed"));
        Assert.Contains("may have printed", entries[0].Message);
    }

    [Fact]
    public async Task A_file_someone_is_still_writing_isnt_taken()
    {
        using var f = new BatchFolder();
        var path = f.File("slow copy.pdf");
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
        {
            var queue = new FakeQueue();
            await Run(f, queue);
            Assert.Empty(queue.Sent);
            Assert.True(File.Exists(path));
        }
        var after = new FakeQueue();
        await Run(f, after);
        Assert.Single(after.Sent);
    }

    [Fact]
    public async Task A_file_still_growing_waits_until_it_has_stopped()
    {
        using var f = new BatchFolder();
        var path = f.File("growing.pdf");
        using var stop = new CancellationTokenSource();
        var queue = new FakeQueue();
        // The writes come every 50 ms for a second, far inside the quiet period, so a stalled timer on a busy runner
        // (CI's Task.Delay(100) took past 400 ms) can't open a quiet gap between two of them.
        var options = Fast with { Once = false, QuietPeriod = TimeSpan.FromSeconds(2) };
        var run = Run(f, queue, options, ct: stop.Token);
        var writing = Stopwatch.StartNew();
        while (writing.Elapsed < TimeSpan.FromSeconds(1))
        {
            await Task.Delay(50);
            File.AppendAllText(path, " ");
            Assert.Empty(queue.Sent);
        }
        for (var i = 0; i < 750 && queue.Sent.Count == 0; i++) await Task.Delay(20);
        Assert.Single(queue.Sent);
        await stop.CancelAsync();
        await run;
    }

    public static TheoryData<string, byte[]> CutOff => new()
    {
        { "half.pdf", Encoding.ASCII.GetBytes("%PDF-1.4\n1 0 obj\n<<>>\nendobj\n") },
        { "half.jpg", [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 1, 2, 3, 4] },
        { "half.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] },
        { "tiny.pdf", [0x25] },
    };

    [Theory]
    [MemberData(nameof(CutOff))]
    public async Task A_file_that_stops_short_of_its_end_waits_then_fails_and_never_prints(string name, byte[] bytes)
    {
        using var f = new BatchFolder();
        var path = Path.Combine(f.Root, name);
        File.WriteAllBytes(path, bytes);
        var queue = new FakeQueue();
        await Run(f, queue);
        Assert.Empty(queue.Sent);
        Assert.True(File.Exists(path)); // still there for when the rest arrives

        using var stop = new CancellationTokenSource();
        var options = Fast with { Once = false, CutOffLimit = TimeSpan.FromMilliseconds(100) };
        var run = Run(f, queue, options, ct: stop.Token);
        for (var i = 0; i < 300 && !File.Exists(Path.Combine(f.Root, "failed", name)); i++) await Task.Delay(20);
        await stop.CancelAsync();
        var summary = await run;
        Assert.Empty(queue.Sent);
        Assert.Equal(1, summary.Failed);
        Assert.Equal([name], In(f, "failed"));
    }

    [Fact]
    public void Whole_files_read_as_whole()
    {
        using var f = new BatchFolder();
        Assert.True(BatchPrintFolder.LooksWhole(new MemoryStream(BatchPrintSamples.Pdf(2, "x"))));
        Assert.True(BatchPrintFolder.LooksWhole(new MemoryStream(BatchPrintSamples.Jpeg(16, 16))));
        Assert.True(BatchPrintFolder.LooksWhole(new MemoryStream(BatchPrintSamples.Png(4, 4))));
        Assert.True(BatchPrintFolder.LooksWhole(new MemoryStream(BatchPrintSamples.Tiff(2, 4, 4))));
    }

    [Fact]
    public async Task A_second_watcher_is_refused()
    {
        using var f = new BatchFolder();
        using var stop = new CancellationTokenSource();
        var run = Run(f, new FakeQueue(), Fast with { Once = false }, ct: stop.Token);
        await Task.Delay(50);
        await Assert.ThrowsAsync<BatchFolderBusyException>(() => Run(f, new FakeQueue()));
        await stop.CancelAsync();
        await run;
    }

    [Fact]
    public async Task A_folder_inkvolt_pdf_watches_is_refused_too()
    {
        // Both apps use "working", and each takes what's left there as interrupted: they must not share a folder.
        using var f = new BatchFolder();
        using var held = DropFolder.Lock(f.Root, DropFolder.LockName);
        Assert.NotNull(held);
        await Assert.ThrowsAsync<BatchFolderBusyException>(() => Run(f, new FakeQueue()));
        Assert.Equal(".inkvolt-watch.lock", DropFolder.LockName); // the name Inkvolt PDF already used: an older copy of it still sees the lock
    }

    [Fact]
    public async Task A_file_that_needs_a_password_goes_to_failed_with_nobody_asked()
    {
        using var f = new BatchFolder();
        f.File("locked.pdf", "password=x");
        f.File("open.pdf");
        var queue = new FakeQueue();
        var summary = await Run(f, queue);
        Assert.Equal(["open.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Equal((1, 1), (summary.Sent, summary.Failed));
        Assert.Equal(["locked.pdf"], In(f, "failed"));
        Assert.Contains("password", File.ReadAllText(Path.Combine(f.Root, BatchPrintFolder.LogName)));
    }

    [Fact]
    public async Task A_given_password_opens_a_locked_file_once()
    {
        using var f = new BatchFolder();
        f.File("locked.pdf", "pages=3;password=x");
        var queue = new FakeQueue();
        var summary = await Run(f, queue, Fast with { Password = "x" });
        Assert.Equal(3, summary.SheetsSent);
    }

    [Fact]
    public async Task A_file_over_the_runs_sheets_fails_and_one_that_would_pass_them_waits_in_the_folder()
    {
        using var f = new BatchFolder();
        f.File("1 big.pdf", "pages=50");
        f.File("2 fits.pdf", "pages=8");
        f.File("3 passes.pdf", "pages=8");
        var queue = new FakeQueue();
        var summary = await Run(f, queue, Fast with { MaxSheets = 10 });
        Assert.Equal(["2 fits.pdf"], queue.Sent.Select(j => j.Name));
        Assert.Equal(["1 big.pdf"], In(f, "failed"));
        Assert.True(File.Exists(Path.Combine(f.Root, "3 passes.pdf")));
        Assert.Contains("10", summary.StopReason);
    }

    [Fact]
    public async Task While_the_printer_has_a_problem_files_stay_in_the_folder_and_print_after()
    {
        using var f = new BatchFolder();
        f.File("a.pdf");
        var problem = "Paper jam";
        var said = new List<string?>();
        var queue = new FakeQueue { ProblemBefore = _ => problem };
        var once = await Run(f, queue, progress: new Direct<BatchFolderProgress>(p => said.Add(p.Waiting)));
        Assert.Equal("Paper jam", once.StopReason);
        Assert.Empty(queue.Sent);
        Assert.True(File.Exists(Path.Combine(f.Root, "a.pdf")));
        Assert.Contains("Paper jam", said);

        using var stop = new CancellationTokenSource();
        var run = Run(f, queue, Fast with { Once = false }, ct: stop.Token);
        await Task.Delay(200);
        Assert.Empty(queue.Sent);
        problem = null!;
        for (var i = 0; i < 300 && queue.Sent.Count == 0; i++) await Task.Delay(20);
        Assert.Single(queue.Sent);
        await stop.CancelAsync();
        await run;
    }

    [Fact]
    public async Task A_queue_that_fails_for_sure_puts_the_file_back_and_one_that_may_have_sent_doesnt()
    {
        using var f = new BatchFolder();
        f.File("a.pdf");
        var sure = await Run(f, new FakeQueue { FailOn = _ => new BatchQueueException("The queue is gone.", false) });
        Assert.Equal(0, sure.Failed);
        Assert.True(File.Exists(Path.Combine(f.Root, "a.pdf")));

        var unsure = await Run(f, new FakeQueue { FailOn = _ => new BatchQueueException("The spooler stopped.", true) });
        Assert.Equal(1, unsure.Failed);
        Assert.Equal(["a.pdf"], In(f, "failed"));
        Assert.Contains("check the queue", File.ReadAllText(Path.Combine(f.Root, BatchPrintFolder.LogName)));
    }

    [Fact]
    public async Task Stop_while_a_file_is_being_drawn_puts_it_back_for_next_time()
    {
        using var f = new BatchFolder();
        f.File("a.pdf");
        using var stop = new CancellationTokenSource();
        var queue = new FakeQueue();
        queue.BeforeSpooling = _ => stop.Cancel();
        await Run(f, queue, Fast with { Once = false }, ct: stop.Token);
        Assert.Empty(queue.Sent);
        Assert.True(File.Exists(Path.Combine(f.Root, "a.pdf")));
        Assert.Empty(In(f, "working"));
    }

    [Fact]
    public async Task A_name_with_control_characters_doesnt_break_the_log()
    {
        Assert.Equal("a b", BatchPrintText.Clean("a\u001bb"));
        var entry = new BatchFolderEntry(new DateTime(2026, 10, 31), "a\tb.pdf", BatchPrintState.Sent, "x\ny", 1, null);
        Assert.Equal(5, entry.LogLine.Split('\t').Length);
        await Task.CompletedTask;
    }

    [Theory]
    [InlineData("=1+1.pdf", "'=1+1.pdf")]
    [InlineData("@SUM(A1).pdf", "'@SUM(A1).pdf")]
    [InlineData("plain, name.pdf", "plain, name.pdf")]
    public void The_log_for_a_spreadsheet_cant_run_a_file_name_as_a_formula(string name, string logged)
    {
        var line = new BatchFolderEntry(new DateTime(2026, 11, 1), name, BatchPrintState.Sent, "=2+2", 1, null).LogLine.Split('\t');
        Assert.Equal(logged, line[2]);
        Assert.Equal("'=2+2", line[3]);
    }

    [Fact]
    public async Task A_log_that_cant_be_written_stops_nothing_and_loses_no_count()
    {
        using var f = new BatchFolder();
        f.File("a.pdf");
        f.File("b.pdf");
        var log = f.File(BatchPrintFolder.LogName, "");
        File.SetAttributes(log, FileAttributes.ReadOnly);
        var queue = new FakeQueue();
        try
        {
            var summary = await Run(f, queue, Fast with { Once = true });
            Assert.Equal(2, summary.Sent);
            Assert.Equal(2, queue.Sent.Count);
        }
        finally
        {
            File.SetAttributes(log, FileAttributes.Normal);
        }
    }

    [Fact]
    public void Existing_files_are_counted_before_a_watch_starts()
    {
        using var f = new BatchFolder();
        f.File("a.pdf");
        f.File("b.jpg");
        f.File("c.txt");
        Assert.Equal(2, BatchPrintFolder.ReadyToPrint(f.Root));
    }

    private sealed class Direct<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}

/// <summary><c>inkvoltprint print</c>, run in-process: lines, exit codes the same as Inkvolt PDF's, nothing sent when something's wrong.</summary>
[Collection("Pro")]
public class BatchPrintCommandLineTests : IDisposable
{
    private sealed class Host(FakeQueue queue, IBatchDocuments? documents = null) : IBatchPrintHost
    {
        public IBatchDocuments Documents { get; } = documents ?? new FakeDocuments();

        public Task<IBatchQueue> FindPrinterAsync(string name, CancellationToken ct) =>
            name == "Office laser" ? Task.FromResult<IBatchQueue>(queue) : throw new BatchCommandException($"There is no printer \"{name}\".");
    }

    private readonly BatchFolder _f = new();
    private readonly StringWriter _out = new(), _err = new();
    private readonly FakeQueue _queue = new();

    public BatchPrintCommandLineTests() => Pro.Enforced = false;

    public void Dispose()
    {
        Pro.Enforced = false;
        _f.Dispose();
    }

    private Task<int> Run(string[] args, Func<string, string?>? env = null, FakeQueue? queue = null, CancellationToken ct = default) =>
        BatchPrintCommandLine.RunAsync(args, _out, _err, new Host(queue ?? _queue), ct, env ?? (_ => null), null, TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(10));

    private string List(params string[] files)
    {
        var list = Path.Combine(_f.Root, "list" + BatchPrintList.Extension);
        BatchPrintList.Save(list, files.Select(p => new BatchListEntry(p, new BatchPrintSettings())));
        return list;
    }

    [Fact]
    public void Its_exit_codes_are_inkvolt_pdfs()
    {
        // InkvoltPdf.Core.BatchCommandLine: Done = 0, SomeFailed = 1, Wrong = 2, Stopped = 3
        Assert.Equal((0, 1, 2, 3), (BatchPrintSummary.Done, BatchPrintSummary.SomeFailed, BatchPrintSummary.Wrong, BatchPrintSummary.Stopped));
    }

    [Fact]
    public void Only_print_is_a_command()
    {
        Assert.True(BatchPrintCommandLine.IsCommand(["print", "--list", "x"]));
        Assert.True(BatchPrintCommandLine.IsCommand(["PRINT"]));
        Assert.False(BatchPrintCommandLine.IsCommand([]));
        Assert.False(BatchPrintCommandLine.IsCommand(["report.pdf"]));
        Assert.False(BatchPrintCommandLine.IsCommand(["--demo", "print"]));
    }

    [Fact]
    public async Task A_list_prints_in_order_and_exits_0()
    {
        var list = List(_f.File("b.pdf", "pages=2"), _f.File("a.pdf"));
        Assert.Equal(0, await Run(["print", "--list", list, "--printer", "Office laser"]));
        Assert.Equal(["b.pdf", "a.pdf"], _queue.Sent.Select(j => j.Name));
        var text = _out.ToString();
        Assert.Contains("Estimate: 2 files, 3 sheets on Test queue.", text);
        Assert.Contains("2 sent (3 sheets).", text);
    }

    [Fact]
    public async Task A_file_that_fails_exits_1_and_the_rest_still_print()
    {
        var gone = Path.Combine(_f.Root, "gone.pdf");
        var list = List(gone, _f.File("a.pdf"));
        Assert.Equal(1, await Run(["print", "--list", list, "--printer", "Office laser"]));
        Assert.Equal(["a.pdf"], _queue.Sent.Select(j => j.Name));
        Assert.Contains("gone.pdf", _err.ToString());
    }

    [Theory]
    [InlineData]
    [InlineData("--printer", "Office laser")]
    [InlineData("a.pdf")]
    [InlineData("--list", "a", "--watch", "b", "--printer", "Office laser")]
    [InlineData("--list", "a", "--printer", "Office laser", "--copies", "2")]
    [InlineData("a.pdf", "--printer", "Office laser", "--copies", "100")]
    [InlineData("a.pdf", "--printer", "Office laser", "--max-sheets", "none")]
    [InlineData("a.pdf", "--printer", "Office laser", "--once")]
    [InlineData("a.pdf", "--printer")]
    [InlineData("a.pdf", "--printer", "Office laser", "--nonsense")]
    public async Task A_wrong_command_line_exits_2_with_nothing_sent(params string[] rest)
    {
        Assert.Equal(2, await Run(["print", .. rest]));
        Assert.Empty(_queue.Sent);
        Assert.Contains("--help", _err.ToString());
    }

    [Fact]
    public async Task Help_exits_0()
    {
        Assert.Equal(0, await Run(["print", "--help"]));
        Assert.Contains("Exit codes", _out.ToString());
    }

    [Fact]
    public async Task An_unknown_printer_a_bad_list_or_missing_input_exits_2()
    {
        var list = List(_f.File("a.pdf"));
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Nobody"]));
        Assert.Contains("no printer", _err.ToString());
        Assert.Equal(2, await Run(["print", "--list", _f.File("bad.inkvoltlist", "nonsense"), "--printer", "Office laser"]));
        Assert.Equal(2, await Run(["print", "--list", Path.Combine(_f.Root, "none"), "--printer", "Office laser"]));
        Assert.Equal(2, await Run(["print", Path.Combine(_f.Root, "none.pdf"), "--printer", "Office laser"]));
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser"], queue: new FakeQueue { NoQueue = true }));
        Assert.Empty(_queue.Sent);
    }

    [Fact]
    public async Task A_list_reaching_another_computer_exits_2_until_allowed_and_the_disk_isnt_touched()
    {
        var list = _f.File("net.inkvoltlist", """{ "version": 1, "files": [ { "path": "\\\\files01\\share\\a.pdf" } ] }""");
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser"]));
        Assert.Contains("files01", _err.ToString());
        Assert.Contains("--allow-network", _err.ToString());
    }

    [Fact]
    public async Task Over_max_sheets_exits_2_before_the_first_sheet()
    {
        var list = List(_f.File("a.pdf", "pages=60"), _f.File("b.pdf", "pages=50"));
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser", "--max-sheets", "100"]));
        Assert.Empty(_queue.Sent);
        Assert.Contains("110 sheets", _err.ToString());
        Assert.Equal(0, await Run(["print", "--list", list, "--printer", "Office laser", "--max-sheets", "110"]));
        Assert.Equal(2, _queue.Sent.Count);
    }

    [Fact]
    public async Task The_default_max_sheets_stops_a_runaway_list()
    {
        var list = _f.File("many.inkvoltlist", $$"""{ "version": 1, "files": [ { "path": "{{_f.File("a.pdf", "pages=600").Replace(@"\", @"\\")}}" } ] }""");
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser"]));
        Assert.Empty(_queue.Sent);
    }

    [Fact]
    public async Task A_dry_run_only_estimates()
    {
        var list = List(_f.File("a.pdf", "pages=4"));
        Assert.Equal(0, await Run(["print", "--list", list, "--printer", "Office laser", "--dry-run"]));
        Assert.Empty(_queue.Sent);
        Assert.Contains("4 sheets", _out.ToString());
    }

    [Fact]
    public async Task A_locked_file_uses_the_variable_once_and_is_skipped_without_it()
    {
        var path = _f.File("locked.pdf", "pages=2;password=right");
        var list = List(path, _f.File("open.pdf"));
        Assert.Equal(1, await Run(["print", "--list", list, "--printer", "Office laser"]));
        Assert.Equal(["open.pdf"], _queue.Sent.Select(j => j.Name));

        _queue.Sent.Clear();
        Assert.Equal(1, await Run(["print", "--list", list, "--printer", "Office laser"], name => name == BatchPrintCommandLine.PasswordVariable ? "wrong" : null));
        Assert.Equal(["open.pdf"], _queue.Sent.Select(j => j.Name));

        _queue.Sent.Clear();
        Assert.Equal(0, await Run(["print", "--list", list, "--printer", "Office laser"], name => name == BatchPrintCommandLine.PasswordVariable ? "right" : null));
        Assert.Equal(["locked.pdf", "open.pdf"], _queue.Sent.Select(j => j.Name));
        Assert.DoesNotContain("right", _out.ToString());
    }

    [Fact]
    public async Task A_printer_problem_exits_3_and_says_where()
    {
        var list = List(_f.File("a.pdf"), _f.File("b.pdf"));
        var queue = new FakeQueue { ProblemBefore = sent => sent == 1 ? "Paper jam" : null };
        Assert.Equal(3, await Run(["print", "--list", list, "--printer", "Office laser"], queue: queue));
        Assert.Contains("Stopped at file 2 of 2 (b.pdf): Paper jam", _out.ToString());
    }

    [Fact]
    public async Task Stopping_exits_3()
    {
        var list = List(_f.File("a.pdf"), _f.File("b.pdf"));
        using var stop = new CancellationTokenSource();
        var queue = new FakeQueue();
        queue.AfterSent = _ => stop.Cancel();
        Assert.Equal(3, await Run(["print", "--list", list, "--printer", "Office laser"], queue: queue, ct: stop.Token));
        Assert.Single(queue.Sent);

        using var already = new CancellationTokenSource();
        await already.CancelAsync();
        Assert.Equal(3, await Run(["print", "--list", list, "--printer", "Office laser"], ct: already.Token));
    }

    [Fact]
    public async Task The_report_is_a_csv_of_each_file_and_a_bad_report_path_exits_2_first()
    {
        var name = "=1+1.pdf";
        var list = List(_f.File(name), Path.Combine(_f.Root, "gone.pdf"));
        var report = Path.Combine(_f.Root, "results.csv");
        Assert.Equal(1, await Run(["print", "--list", list, "--printer", "Office laser", "--report", report]));
        var rows = File.ReadAllLines(report);
        Assert.Equal(3, rows.Length);
        Assert.Contains("'=1+1.pdf,", rows[1]);
        Assert.Contains("Sent,", rows[1]);
        Assert.Contains("Skipped,", rows[2]);

        _queue.Sent.Clear();
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser", "--report", Path.Combine(_f.Root, "no folder", "r.csv")]));
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser", "--report", Path.Combine(_f.Root, "r.exe")]));
        Assert.Empty(_queue.Sent);
    }

    [Fact]
    public async Task Files_given_directly_print_with_the_settings_given()
    {
        _f.File(@"in\b 10.pdf");
        _f.File(@"in\b 2.pdf");
        Assert.Equal(0, await Run(["print", Path.Combine(_f.Root, "in"), "--printer", "Office laser", "--copies", "2", "--two-sided", "--paper", "ISOA4"]));
        Assert.Equal(["b 2.pdf", "b 10.pdf"], _queue.Sent.Select(j => j.Name));
        Assert.All(_queue.Sent, j => Assert.Equal((2, true, "ISOA4"), (j.Copies, j.TwoSided, j.Paper)));
    }

    [Fact]
    public async Task A_setting_the_printer_doesnt_have_skips_the_files_rather_than_changing_it()
    {
        var a = _f.File("a.pdf");
        Assert.Equal(1, await Run(["print", a, "--printer", "Office laser", "--paper", "Tabloid"]));
        Assert.Empty(_queue.Sent);
        Assert.Contains("Tabloid", _err.ToString());
    }

    [Fact]
    public async Task Control_characters_in_a_name_dont_reach_the_terminal()
    {
        var list = _f.File("esc.inkvoltlist", """{ "version": 1, "files": [] }""");
        Assert.Equal("a [31mred.pdf", BatchPrintText.Clean("a\u001b[31mred.pdf"));
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser"]));
    }

    [Fact]
    public async Task Without_pro_it_says_so_and_exits_2_with_nothing_sent()
    {
        Pro.Store = new MemoryProStore();
        Pro.Enforced = true;
        var list = List(_f.File("a.pdf"));
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser"]));
        Assert.Empty(_queue.Sent);
        Assert.Contains("Inkvolt Pro", _err.ToString());
        Assert.Null(BatchPrintCsv.Export([]));
        Pro.Enforced = false;
        Assert.NotNull(BatchPrintCsv.Export([]));
    }

    [Fact]
    public async Task Watch_once_handles_whats_there_and_a_locked_folder_exits_2()
    {
        _f.File("a.pdf");
        _f.File("locked.pdf", "password=x");
        Assert.Equal(1, await Run(["print", "--watch", _f.Root, "--printer", "Office laser", "--once"]));
        Assert.Equal(["a.pdf"], _queue.Sent.Select(j => j.Name));
        Assert.Equal(2, await Run(["print", "--watch", Path.Combine(_f.Root, "none"), "--printer", "Office laser", "--once"]));
        Assert.Equal(2, await Run(["print", "--watch", _f.Root, "--printer", "Office laser", "--paper", "Tabloid", "--once"]));

        using var stop = new CancellationTokenSource();
        var watching = BatchPrintFolder.RunAsync(_f.Root, new FakeQueue(), new FakeDocuments(), new BatchFolderOptions { PollInterval = TimeSpan.FromMilliseconds(10) }, null, stop.Token);
        await Task.Delay(50);
        Assert.Equal(2, await Run(["print", "--watch", _f.Root, "--printer", "Office laser", "--once"]));
        Assert.Contains("already watched", _err.ToString());
        await stop.CancelAsync();
        await watching;
    }

    [Fact]
    public async Task Watch_stops_at_max_sheets_with_exit_3()
    {
        _f.File("1.pdf", "pages=3");
        _f.File("2.pdf", "pages=3");
        Assert.Equal(3, await Run(["print", "--watch", _f.Root, "--printer", "Office laser", "--once", "--max-sheets", "4"]));
        Assert.Single(_queue.Sent);
        Assert.True(File.Exists(Path.Combine(_f.Root, "2.pdf")));
    }

    [Fact]
    public async Task A_file_given_that_cant_be_printed_exits_2_with_nothing_sent()
    {
        var pdf = _f.File("a.pdf");
        var notes = _f.File("notes.docx");
        Assert.Equal(2, await Run(["print", pdf, notes, "--printer", "Office laser"]));
        Assert.Empty(_queue.Sent);
        Assert.Contains("notes.docx", _err.ToString());
    }

    [Theory]
    [InlineData("""{ "version": 1, "files": [null] }""")]
    [InlineData("""{ "version": 1, "files": [{ "path": "a.pdf" }, null] }""")]
    public async Task A_list_with_an_empty_line_is_refused_not_a_crash(string json)
    {
        _f.File("a.pdf");
        var list = _f.File("bad.inkvoltlist", json);
        Assert.Equal(2, await Run(["print", "--list", list, "--printer", "Office laser"]));
        Assert.Empty(_queue.Sent);
    }

    [Fact]
    public async Task Stopping_a_watch_once_with_files_left_exits_3()
    {
        _f.File("a.pdf");
        _f.File("b.pdf");
        using var stop = new CancellationTokenSource();
        var queue = new FakeQueue { AfterSent = _ => stop.Cancel() };
        Assert.Equal(3, await Run(["print", "--watch", _f.Root, "--printer", "Office laser", "--once"], queue: queue, ct: stop.Token));
        Assert.Single(queue.Sent);
        Assert.True(File.Exists(Path.Combine(_f.Root, "b.pdf")));
    }
}
