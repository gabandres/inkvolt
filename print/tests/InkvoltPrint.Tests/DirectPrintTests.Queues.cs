using System.Text;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Printing.Direct;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Roadmap 2.1's last uses of a Windows queue: Batch print (2.4) a job per file straight to the printer
/// (<see cref="DirectBatchQueue"/>), and job alerts (3.4) on the printer's own job list (<see cref="DirectJobWatch"/>).
/// </summary>
public partial class DirectPrintTests
{
    // ---- batch print ----

    /// <summary>What the fake drawing was given, and whether it reached the point of no return.</summary>
    private sealed record SentJob(string Name, DirectPrintRequest Request, int Drawn, bool Sending);

    /// <summary>
    /// A batch to the printer with <see cref="Caps"/>, its jobs drawn by a fake: <paramref name="act"/> decides, by file name, what
    /// happens once the pages are drawn (throw before or after the point of no return); by default the job goes.
    /// </summary>
    private static (DirectBatchQueue Queue, List<SentJob> Sent) DirectBatch(Func<string, Action, CancellationToken, Task>? act = null,
        Func<byte[], byte[]>? printer = null, IppPrintCaps? caps = null)
    {
        var sent = new List<SentJob>();
        var http = new DeviceHttp("192.0.2.11", new Answering(printer ?? (_ => Printer(b => b.Enums("printer-state", 3).Kw("printer-state-reasons", "none")))));
        var queue = new DirectBatchQueue("Office inkjet", new IppClient(http), new IppCapsCache(_ => Task.FromResult(caps ?? Caps())),
            async (document, job, request, progress, onSending, ct) =>
            {
                var drawn = 0;
                foreach (var page in job.Pages)
                {
                    ct.ThrowIfCancellationRequested();
                    await document.RenderAsync(page, ct);
                    drawn++;
                }
                var sending = false;
                void Send()
                {
                    onSending();
                    sending = true;
                }
                try
                {
                    if (act is null) Send();
                    else await act(job.Name, Send, ct);
                }
                finally
                {
                    lock (sent) sent.Add(new SentJob(job.Name, request, drawn, sending));
                }
            });
        return (queue, sent);
    }

    private static async Task<List<BatchPrintLine>> Lines(BatchFolder folder, IBatchQueue queue, params (string Name, string Text, BatchPrintSettings Settings)[] files)
    {
        var info = await queue.ReadAsync(default);
        var lines = new List<BatchPrintLine>();
        foreach (var (name, text, settings) in files)
        {
            var path = folder.File(name, text);
            lines.Add(new BatchPrintLine(path, settings, await BatchMeasurer.MeasureAsync(path, null, new FakeDocuments(), null, null, default), info));
        }
        return lines;
    }

    [Fact]
    public async Task A_batch_goes_to_the_printer_a_job_per_file_with_its_copies_side_and_paper()
    {
        using var folder = new BatchFolder();
        var (queue, sent) = DirectBatch();
        var info = (await queue.ReadAsync(default))!;
        Assert.Equal("Office inkjet", info.Name);
        Assert.True(info.CanTwoSided);
        Assert.Equal("na_letter_8.5x11in", info.DefaultPaper);
        Assert.Equal(["na_letter_8.5x11in", "iso_a4_210x297mm", "na_index-4x6_4x6in"], info.Papers.Select(p => p.Key)); // letter once, bordered
        Assert.Null(await new DirectBatchQueue("x", new IppClient(new DeviceHttp("192.0.2.11", new Answering(_ => []))),
            new IppCapsCache(_ => Task.FromResult(new IppPrintCaps())), (_, _, _, _, _, _) => Task.CompletedTask).ReadAsync(default)); // no raster format: nothing to print through

        var lines = await Lines(folder, queue,
            ("1 report.pdf", "pages=3", new BatchPrintSettings()),
            ("2 form.pdf", "pages=3", new BatchPrintSettings(Copies: 2, TwoSided: true, Paper: "iso_a4_210x297mm")),
            ("3 photo.jpg", "pages=1", new BatchPrintSettings(Range: "1")));
        var summary = await BatchPrintRunner.RunAsync(lines, queue, new FakeDocuments(), null, null, default);
        Assert.Equal(BatchPrintSummary.Done, summary.ExitCode);
        Assert.Equal(["1 report.pdf", "2 form.pdf", "3 photo.jpg"], sent.Select(s => s.Name));
        Assert.Equal(new DirectPrintRequest(2, true) { PaperName = "iso_a4_210x297mm" }, sent[1].Request);
        Assert.Equal(new DirectPrintRequest(), sent[0].Request); // the printer's default paper
        Assert.Equal([3, 3, 1], sent.Select(s => s.Drawn));
        Assert.Equal([3, 4, 1], summary.Items.Select(i => i.SheetsSent)); // two copies of three pages on both sides: 2 sheets each
        // The plan the drawing will make keeps what was asked: the printer collates the copies itself, on A4, both sides.
        var plan = DirectPrintPlan.Choose(Caps(), sent[1].Request, out _)!;
        Assert.Equal((2, 1, true, "iso_a4_210x297mm"), (plan.Copies, plan.Repeat, plan.TwoSided, plan.Paper.Name));
    }

    [Fact]
    public async Task A_setting_the_printer_cant_keep_fails_that_file_with_nothing_drawn_and_the_rest_print()
    {
        using var folder = new BatchFolder();
        var (queue, sent) = DirectBatch();
        var lines = await Lines(folder, queue,
            ("a.pdf", "pages=1", new BatchPrintSettings()),
            ("b.pdf", "pages=1", new BatchPrintSettings(Paper: "iso_a4_210x297mm")),
            ("c.pdf", "pages=1", new BatchPrintSettings()));
        // The printer's A4 went between the estimate and the print (a tray taken out): the line still lists it.
        var (changed, sentAfter) = DirectBatch(caps: Caps(c => c with { Papers = [.. c.Papers.Where(p => p.Name != "iso_a4_210x297mm")] }));
        var summary = await BatchPrintRunner.RunAsync(lines, changed, new FakeDocuments(), null, null, default);
        Assert.Equal([BatchPrintState.Sent, BatchPrintState.Failed, BatchPrintState.Sent], summary.Items.Select(i => i.State));
        Assert.Contains(Core.CoreStrings.Direct_NoPaper, summary.Items[1].Message);
        Assert.False(summary.Items[1].MayHaveSent);
        Assert.Equal(["a.pdf", "c.pdf"], sentAfter.Select(s => s.Name)); // b was never drawn
        Assert.Null(summary.StoppedAt);
        Assert.Empty(sent);
    }

    [Fact]
    public async Task A_job_the_printer_stopped_stops_the_batch_and_is_never_sent_again()
    {
        using var folder = new BatchFolder();
        var aborted = string.Format(Core.CoreStrings.Direct_AbortedBecause, Core.CoreStrings.Direct_ReasonFormat);
        var (queue, sent) = DirectBatch((name, send, _) =>
        {
            send();
            return name == "b.pdf" ? throw new DirectPrintException(aborted, mayHavePrinted: true) : Task.CompletedTask;
        });
        var lines = await Lines(folder, queue, ("a.pdf", "pages=1", new()), ("b.pdf", "pages=2", new()), ("c.pdf", "pages=1", new()));
        var summary = await BatchPrintRunner.RunAsync(lines, queue, new FakeDocuments(), null, null, default);
        Assert.Equal([BatchPrintState.Sent, BatchPrintState.Failed, BatchPrintState.Stopped], summary.Items.Select(i => i.State));
        Assert.True(summary.Items[1].MayHaveSent);
        Assert.False(summary.Items[1].StillToSend); // Print again leaves it alone
        Assert.True(summary.Items[2].StillToSend);
        Assert.Equal(1, summary.StoppedAt);
        Assert.Contains(aborted + ". ", summary.Text); // a sentence in the summary, as a queue's reason is
        Assert.Equal(BatchPrintSummary.Stopped, summary.ExitCode);

        // Print again: only c goes.
        var again = await BatchPrintRunner.RunAsync([lines[2]], DirectBatch().Queue, new FakeDocuments(), null, null, default);
        Assert.Equal(BatchPrintState.Sent, Assert.Single(again.Items).State);
    }

    [Fact]
    public async Task A_printer_that_refuses_a_job_or_stops_answering_says_whether_it_may_have_it()
    {
        using var folder = new BatchFolder();
        // Refused as it came in (busy): nothing printed, the batch stops and Print again sends it.
        var (busy, _) = DirectBatch((name, send, _) =>
        {
            send();
            return name == "b.pdf" ? throw new DirectPrintException(Core.CoreStrings.Direct_RefusedBusy, mayHavePrinted: false) : Task.CompletedTask;
        });
        var lines = await Lines(folder, busy, ("a.pdf", "pages=1", new()), ("b.pdf", "pages=1", new()), ("c.pdf", "pages=1", new()));
        var summary = await BatchPrintRunner.RunAsync(lines, busy, new FakeDocuments(), null, null, default);
        Assert.Equal([BatchPrintState.Sent, BatchPrintState.Stopped, BatchPrintState.Stopped], summary.Items.Select(i => i.State));
        Assert.True(summary.Items[1].StillToSend);
        Assert.Equal(Core.CoreStrings.Direct_RefusedBusy, summary.StopReason);

        // Refused before anything went (the drawing found fewer pages): that file fails, the batch goes on.
        var (drawn, _) = DirectBatch((name, send, _) =>
            name == "b.pdf" ? throw new DirectPrintException("Fewer pages.", mayHavePrinted: false) : Task.Run(send));
        summary = await BatchPrintRunner.RunAsync(lines, drawn, new FakeDocuments(), null, null, default);
        Assert.Equal([BatchPrintState.Sent, BatchPrintState.Failed, BatchPrintState.Sent], summary.Items.Select(i => i.State));
        Assert.False(summary.Items[1].MayHaveSent);

        // No answer while reading what the printer takes: nothing sent, the batch stops.
        var drew = false;
        var mute = new DirectBatchQueue("x", new IppClient(new DeviceHttp("192.0.2.11", new Answering(_ => Printer(b => b.Enums("printer-state", 3))))),
            new IppCapsCache(_ => Task.FromException<IppPrintCaps>(new HttpRequestException("unreachable"))), (_, _, _, _, _, _) =>
            {
                drew = true;
                return Task.CompletedTask;
            });
        summary = await BatchPrintRunner.RunAsync(lines, mute, new FakeDocuments(), null, null, default);
        Assert.Equal(BatchPrintState.Stopped, summary.Items[0].State);
        Assert.True(summary.Items[0].StillToSend);
        Assert.Equal(Core.CoreStrings.Direct_NotAnswering, summary.StopReason);
        Assert.False(drew);
    }

    [Fact]
    public async Task Stop_sends_nothing_before_the_point_of_no_return_and_never_reads_as_not_sent_after_it()
    {
        using var folder = new BatchFolder();
        using var stop = new CancellationTokenSource();
        var (queue, sent) = DirectBatch(async (name, send, ct) =>
        {
            if (name == "b.pdf") await stop.CancelAsync(); // Stop pressed while b is drawn
            ct.ThrowIfCancellationRequested();
            send();
        });
        var lines = await Lines(folder, queue, ("a.pdf", "pages=1", new()), ("b.pdf", "pages=1", new()), ("c.pdf", "pages=1", new()));
        var summary = await BatchPrintRunner.RunAsync(lines, queue, new FakeDocuments(), null, null, stop.Token);
        Assert.Equal([BatchPrintState.Sent, BatchPrintState.Stopped, BatchPrintState.Stopped], summary.Items.Select(i => i.State));
        Assert.False(sent.Single(s => s.Name == "b.pdf").Sending);
        Assert.Equal(Core.CoreStrings.Batch_YouStopped, summary.StopReason);

        // A drawing that let a stop through after the job went would make it look unsent: it's held as maybe sent instead.
        using var late = new CancellationTokenSource();
        var (leaky, _) = DirectBatch(async (name, send, _) =>
        {
            send();
            if (name != "b.pdf") return;
            await late.CancelAsync();
            throw new OperationCanceledException(late.Token);
        });
        summary = await BatchPrintRunner.RunAsync(lines, leaky, new FakeDocuments(), null, null, late.Token);
        Assert.Equal([BatchPrintState.Sent, BatchPrintState.Failed, BatchPrintState.Stopped], summary.Items.Select(i => i.State));
        Assert.True(summary.Items[1].MayHaveSent);
        Assert.False(summary.Items[1].StillToSend);
    }

    [Fact]
    public async Task A_stopped_printer_or_one_not_taking_jobs_stops_the_batch_before_a_file()
    {
        async Task<string?> Problem(Func<byte[], byte[]> answer) => await DirectBatch(printer: answer).Queue.ProblemAsync(default);

        Assert.Null(await Problem(_ => Printer(b => b.Enums("printer-state", 3).Kw("printer-state-reasons", "toner-low-warning"))));
        Assert.Null(await Problem(_ => Printer(b => b.Enums("printer-state", 4).Kw("printer-state-reasons", "none").Raw(0x22, "printer-is-accepting-jobs", [1]))));
        Assert.Equal(Core.CoreStrings.Status_PaperJam + ".", await Problem(_ => Printer(b => b.Enums("printer-state", 5).Kw("printer-state-reasons", "media-jam-error"))));
        Assert.Equal(Core.CoreStrings.Direct_NotAccepting, await Problem(_ => Printer(b => b.Enums("printer-state", 3).Raw(0x22, "printer-is-accepting-jobs", [0]))));
        Assert.Equal(Core.CoreStrings.Direct_RefusedSignIn, await Problem(_ => Response(0x0401, _ => { })));
        Assert.Equal(Core.CoreStrings.Direct_NotAnswering, await Problem(_ => [1, 2, 3]));
        // The printer's own words, one line and cut short.
        var said = await Problem(_ => Printer(b => b.Enums("printer-state", 5).Kw("printer-state-reasons", "other").Text("printer-state-message", new string('x', 500) + "\r\nsecond line")));
        Assert.True(said!.Length <= 122);
        Assert.DoesNotContain('\n', said);

        using var folder = new BatchFolder();
        var jammed = DirectBatch(printer: _ => Printer(b => b.Enums("printer-state", 5).Kw("printer-state-reasons", "media-jam-error")));
        var lines = await Lines(folder, jammed.Queue, ("a.pdf", "pages=1", new()), ("b.pdf", "pages=1", new()));
        var summary = await BatchPrintRunner.RunAsync(lines, jammed.Queue, new FakeDocuments(), null, null, default);
        Assert.All(summary.Items, i => Assert.Equal(BatchPrintState.Stopped, i.State));
        Assert.Equal(Core.CoreStrings.Status_PaperJam + ".", summary.StopReason);
        Assert.Empty(jammed.Sent);
    }

    // ---- job alerts ----

    private static readonly JobOwner Ana = new("ana", "OFFICE", "ANA-PC");
    private static readonly DateTime Now0 = new(2026, 11, 19, 12, 0, 0, DateTimeKind.Local);

    private static byte[] Date(DateTime local)
    {
        var u = local.ToUniversalTime();
        return [(byte)(u.Year >> 8), (byte)u.Year, (byte)u.Month, (byte)u.Day, (byte)u.Hour, (byte)u.Minute, (byte)u.Second, 0, (byte)'+', 0, 0];
    }

    /// <summary>A Get-Jobs answer: each job its id, state, reasons, owner, and the extras <paramref name="more"/> adds.</summary>
    private static byte[] Jobs(params (int Id, int State, string Reason, Action<B>? More)[] jobs) => Response(0, b =>
    {
        foreach (var (id, state, reason, more) in jobs)
        {
            b.Group(IppCodec.JobTag).Int("job-id", id).Text("job-name", $"C:\\Users\\ana\\job {id}.pdf").Enums("job-state", state)
                .Kw("job-state-reasons", reason).Text("job-originating-user-name", "ana").Int("job-impressions", 4);
            more?.Invoke(b);
        }
    });

    private static readonly byte[] NoJobs = Response(0, _ => { });

    private static AlertTracker JobTracker() => new(new AlertRules { Jobs = true });

    /// <summary>The printer read, then its jobs, as the tray does it once a minute.</summary>
    private static IReadOnlyList<AlertNotice> Observe(AlertTracker t, DirectJobWatch watch, DateTime at, byte[] open, byte[]? ended, string state = "ready")
    {
        var status = new PrinterStatus(state, state, Severity.Info, []);
        t.Observe(new PrinterSnapshot("uuid", "Office inkjet", true, status, []), at);
        return t.ObserveJobs("uuid", "Office inkjet", watch.Read(open, ended), Ana, at);
    }

    [Fact]
    public void A_direct_job_the_printer_gives_up_on_between_two_reads_is_told_once_in_the_printers_words()
    {
        var now = Now0;
        var watch = new DirectJobWatch(() => now);
        var t = JobTracker();
        // Printing, with no creation time from the printer: the key is the moment it was first seen.
        Assert.Empty(Observe(t, watch, now, Jobs((5, 5, "job-printing", null)), NoJobs, "processing"));
        var first = watch.Read(Jobs((5, 5, "job-printing", null)), NoJobs).Jobs.Single();
        Assert.Equal(Now0, first.Submitted);
        Assert.Equal(JobStatus.Printing, first.Status);

        // Gone from the open jobs, aborted among the ended: the same job (one key), failed, for the alert's minute.
        var aborted = Jobs((5, 8, "document-format-error", null));
        var told = new List<AlertNotice>();
        for (var m = 1; m <= 4; m++)
        {
            now = Now0.AddMinutes(m);
            var read = watch.Read(NoJobs, aborted).Jobs.Single();
            Assert.Equal((Now0, JobStatus.Error), (read.Submitted, read.Status));
            told.AddRange(Observe(t, watch, now, NoJobs, aborted));
        }
        var n = Assert.Single(told);
        Assert.Equal(AlertKind.JobFailed, n.Kind);
        Assert.Contains("job 5.pdf", n.Title); // the document's name, not its folder
        Assert.Contains(string.Format(Core.CoreStrings.Direct_AbortedBecause, Core.CoreStrings.Direct_ReasonFormat), n.Body);
        Assert.DoesNotContain("Windows", n.Body);

        // Kept for 15 minutes after it ended, then it leaves.
        now = Now0.AddMinutes(1).Add(DirectJobWatch.EndedKept).AddMinutes(1);
        Assert.Empty(watch.Read(NoJobs, aborted).Jobs);
    }

    [Fact]
    public void Jobs_that_ended_before_the_watch_began_arent_told_and_printed_ones_have_left()
    {
        var now = Now0;
        var watch = new DirectJobWatch(() => now);
        var ended = Jobs(
            (1, 8, "aborted-by-system", null), // no completion time: can't tell how old, left out
            (2, 8, "aborted-by-system", b => b.Raw(0x31, "date-time-at-completed", Date(Now0.AddHours(-3)))),
            (3, 8, "aborted-by-system", b => b.Raw(0x31, "date-time-at-completed", Date(Now0.AddMinutes(-4)))),
            (4, 9, "job-completed-successfully", b => b.Raw(0x31, "date-time-at-completed", Date(Now0.AddMinutes(-1)))),
            (6, 7, "job-canceled-by-user", null));
        Assert.Equal([3], watch.Read(NoJobs, ended).Jobs.Select(j => j.Id));
        now = Now0.AddMinutes(1);
        Assert.Equal([3], watch.Read(NoJobs, ended).Jobs.Select(j => j.Id)); // 1 and 2 stay left out
        // A new job given up on after the watch began, with no time from the printer: told from when it was seen.
        now = Now0.AddMinutes(2);
        var more = Jobs((1, 8, "aborted-by-system", null), (7, 8, "aborted-by-system", null));
        Assert.Equal([7], watch.Read(NoJobs, more).Jobs.Select(j => j.Id));
    }

    [Fact]
    public void A_direct_job_waiting_on_a_ready_printer_is_told_stuck_after_five_minutes()
    {
        var now = Now0;
        var watch = new DirectJobWatch(() => now);
        var t = JobTracker();
        var waiting = Jobs((9, 3, "none", b => b.Raw(0x31, "date-time-at-creation", Date(Now0))));
        var told = new List<AlertNotice>();
        for (var m = 0; m <= 7; m++)
        {
            now = Now0.AddMinutes(m);
            told.AddRange(Observe(t, watch, now, waiting, NoJobs));
        }
        Assert.Equal(AlertKind.JobStuck, Assert.Single(told).Kind);

        // One stopped at the printer (out of paper) is failed, as on a Windows queue.
        var t2 = JobTracker();
        var w2 = new DirectJobWatch(() => now);
        var stopped = Jobs((10, 6, "resources-are-not-ready", null));
        told.Clear();
        for (var m = 0; m <= 3; m++)
        {
            now = Now0.AddMinutes(m);
            told.AddRange(Observe(t2, w2, now, stopped, NoJobs));
        }
        Assert.Equal(AlertKind.JobFailed, Assert.Single(told).Kind);
    }

    [Fact]
    public void Only_your_own_direct_jobs_are_yours_and_a_reused_id_is_a_new_job()
    {
        var now = Now0;
        var watch = new DirectJobWatch(() => now);
        var jobs = watch.Read(Response(0, b => b
            .Group(IppCodec.JobTag).Int("job-id", 1).Enums("job-state", 3).Text("job-originating-user-name", "ana").Text("job-originating-host-name", "ANA-PC.office.lan")
            .Group(IppCodec.JobTag).Int("job-id", 2).Enums("job-state", 3).Text("job-originating-user-name", "ana").Text("job-originating-host-name", "OTHER-PC")
            .Group(IppCodec.JobTag).Int("job-id", 3).Enums("job-state", 3).Text("job-originating-user-name", "ana").Text("job-originating-host-name", "192.0.2.40")
            .Group(IppCodec.JobTag).Int("job-id", 4).Enums("job-state", 3).Text("job-originating-user-name", "ana").Text("job-originating-host-name", "PC\u202Eevil")
            .Group(IppCodec.JobTag).Int("job-id", 5).Enums("job-state", 3).Text("job-originating-user-name", "bob")), null).Jobs;
        Assert.Equal([true, false, true, true, false], jobs.Select(Ana.Owns)); // an address or a name that isn't one says nothing
        Assert.Equal([null, null], jobs.Where(j => j.Id is 3 or 4).Select(j => j.Machine));

        // A printer that restarted counts from 1 again: an id seen given up on and then waiting is a new job.
        Assert.Single(watch.Read(NoJobs, Jobs((8, 8, "aborted-by-system", b => b.Raw(0x31, "date-time-at-completed", Date(Now0))))).Jobs);
        now = Now0.AddMinutes(3);
        var again = watch.Read(Jobs((8, 3, "none", null)), NoJobs).Jobs.Single();
        Assert.Equal(now, again.Submitted);
    }

    [Fact]
    public async Task The_watch_asks_for_open_and_ended_jobs_and_a_printer_that_lists_only_open_ones_still_counts()
    {
        var asked = new List<string>();
        var refuseEnded = false;
        var http = new DeviceHttp("192.0.2.11", new Answering(request =>
        {
            var which = Encoding.ASCII.GetString(request).Contains("not-completed") ? "not-completed" : "completed";
            lock (asked) asked.Add(which);
            return which == "not-completed" ? Jobs((4, 5, "job-printing", null))
                : refuseEnded ? Response(0x040B, _ => { }) : Jobs((3, 8, "aborted-by-system", b => b.Raw(0x31, "date-time-at-completed", Date(DateTime.Now))));
        }));
        var ipp = new IppClient(http);
        var watch = new DirectJobWatch();
        Assert.Equal([3, 4], (await watch.ReadAsync(ipp, "ana")).Jobs.Select(j => j.Id).Order());
        Assert.Equal(["not-completed", "completed"], asked);
        refuseEnded = true;
        Assert.Equal([4], (await watch.ReadAsync(ipp, "ana")).Jobs.Select(j => j.Id));

        // The open jobs refused: the read fails, so the queue isn't taken as empty.
        var refusing = new IppClient(new DeviceHttp("192.0.2.11", new Answering(_ => Response(0x0401, _ => { }))));
        await Assert.ThrowsAsync<DirectPrintException>(() => new DirectJobWatch().ReadAsync(refusing, "ana"));
        var ended = PrinterJobs.GetJobsRequest("ipp://x/", "ana", which: PrinterJobs.Completed);
        Assert.True(ended.AsSpan().IndexOf("completed"u8) >= 0 && ended.AsSpan().IndexOf("not-completed"u8) < 0);
        Assert.True(PrinterJobs.GetJobsRequest("ipp://x/", "ana").AsSpan().IndexOf("not-completed"u8) >= 0); // the card's, as before
    }

    // ---- review: limits, wording, this PC's errors, the job list's memory, a stopped printer ----

    [Fact]
    public async Task A_long_direct_job_is_waited_for_once_sent_but_a_drawing_that_hangs_isnt()
    {
        using var folder = new BatchFolder();
        // A tiny limit stands for 20 pages × 10 copies printing for longer than any limit by pages: once sent, it's the printer's.
        var options = new BatchPrintOptions { SendTimeout = TimeSpan.FromMilliseconds(50), SendTimePerPage = TimeSpan.Zero };
        var (slow, _) = DirectBatch(async (name, send, _) =>
        {
            send();
            await Task.Delay(400);
        });
        var lines = await Lines(folder, slow, ("a.pdf", "pages=1", new()), ("b.pdf", "pages=1", new()));
        var summary = await BatchPrintRunner.RunAsync(lines, slow, new FakeDocuments(), options, null, default);
        Assert.Equal([BatchPrintState.Sent, BatchPrintState.Sent], summary.Items.Select(i => i.State));

        // Before the point of no return the limit holds: a drawing that never ends fails that file, and says nothing of Windows.
        var (hung, sent) = DirectBatch(async (_, _, ct) => await Task.Delay(Timeout.Infinite, ct));
        summary = await BatchPrintRunner.RunAsync(lines, hung, new FakeDocuments(), options, null, default);
        Assert.Equal(BatchPrintState.Failed, summary.Items[0].State);
        Assert.Equal(Core.CoreStrings.Batch_DrawTimeout, summary.Items[0].Message);
        Assert.DoesNotContain("Windows", string.Join(" ", summary.Items.Select(i => i.Message)));

        // The drawing's limit counts the copies (each copy the printer doesn't make is drawn again); a Windows queue's doesn't.
        var job = new BatchPrintJob("x.pdf", [.. Enumerable.Range(1, 20)], 10, false, null, 200);
        var defaults = new BatchPrintOptions();
        Assert.Equal(defaults.SendTimeout + defaults.SendTimePerPage * 200, slow.SendLimit(job, defaults));
        Assert.Equal(defaults.SendTimeout + defaults.SendTimePerPage * 20, ((IBatchQueue)new FakeQueue()).SendLimit(job, defaults));
        Assert.True(slow.EndsOnItsOwnOnceSpooling);
        Assert.False(((IBatchQueue)new FakeQueue()).EndsOnItsOwnOnceSpooling);
    }

    /// <summary>Answers after a while: a printer slower than the batch's patience.</summary>
    private sealed class Slow(TimeSpan delay, Func<byte[], byte[]> answer) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            await Task.Delay(delay, ct);
            var body = await request.Content!.ReadAsByteArrayAsync(ct);
            return new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new ByteArrayContent(answer(body)), RequestMessage = request };
        }
    }

    [Fact]
    public async Task A_printer_slow_to_say_whether_its_ready_is_said_as_the_printer_not_windows()
    {
        using var folder = new BatchFolder();
        var http = new DeviceHttp("192.0.2.11", new Slow(TimeSpan.FromSeconds(3), _ => Printer(b => b.Enums("printer-state", 3))));
        var queue = new DirectBatchQueue("Office inkjet", new IppClient(http), new IppCapsCache(_ => Task.FromResult(Caps())), (_, _, _, _, onSending, _) =>
        {
            onSending();
            return Task.CompletedTask;
        });
        var lines = await Lines(folder, queue, ("a.pdf", "pages=1", new()));
        var summary = await BatchPrintRunner.RunAsync(lines, queue, new FakeDocuments(), new BatchPrintOptions { QueueTimeout = TimeSpan.FromMilliseconds(100) }, null, default);
        Assert.Equal(Core.CoreStrings.Direct_NotAnswering, summary.StopReason);
        Assert.Equal(Core.CoreStrings.Batch_WindowsNoAnswer, ((IBatchQueue)new FakeQueue()).NoAnswer); // a Windows queue's words stay its own
    }

    [Fact]
    public async Task This_pcs_disk_or_drawing_failing_fails_that_file_and_only_the_printers_silence_stops_the_batch()
    {
        using var folder = new BatchFolder();
        var (disk, _) = DirectBatch((name, send, _) => name switch
        {
            "a.pdf" => throw new IOException("There is not enough space on the disk."),
            "b.pdf" => throw new FormatException("A page's picture is damaged."),
            _ => Task.Run(send),
        });
        var lines = await Lines(folder, disk, ("a.pdf", "pages=1", new()), ("b.pdf", "pages=1", new()), ("c.pdf", "pages=1", new()));
        var summary = await BatchPrintRunner.RunAsync(lines, disk, new FakeDocuments(), null, null, default);
        Assert.Equal([BatchPrintState.Failed, BatchPrintState.Failed, BatchPrintState.Sent], summary.Items.Select(i => i.State));
        Assert.All(summary.Items.Take(2), i => Assert.Contains(Core.CoreStrings.Direct_NotDrawn, i.Message));
        Assert.All(summary.Items.Take(2), i => Assert.False(i.MayHaveSent));
        Assert.DoesNotContain("disk", string.Join(" ", summary.Items.Select(i => i.Message))); // no exception text
        Assert.Null(summary.StoppedAt);

        // The printer not answering before anything went (its attributes read again): the batch stops, the file still to send.
        var (silent, _) = DirectBatch((name, _, _) => name == "b.pdf" ? throw DirectPrintException.NoAnswerBeforeSending() : Task.CompletedTask);
        summary = await BatchPrintRunner.RunAsync(lines, silent, new FakeDocuments(), null, null, default);
        Assert.Equal(BatchPrintState.Stopped, summary.Items[1].State);
        Assert.True(summary.Items[1].StillToSend);
        Assert.Equal(Core.CoreStrings.Direct_NotAnswering, summary.StopReason);
    }

    [Fact]
    public void A_job_id_the_printer_uses_again_is_a_new_job_with_its_own_time()
    {
        var now = Now0;
        var watch = new DirectJobWatch(() => now);
        Assert.Equal(Now0, watch.Read(Jobs((5, 5, "job-printing", null)), NoJobs).Jobs.Single().Submitted);
        now = Now0.AddMinutes(1);
        Assert.Empty(watch.Read(NoJobs, NoJobs).Jobs); // printed: it left
        now = Now0.AddMinutes(6);
        var again = watch.Read(Jobs((5, 3, "none", null)), NoJobs).Jobs.Single();
        Assert.Equal(Now0.AddMinutes(6), again.Submitted); // not the old job's: its stuck wait and its alerts are its own

        // A list cut at the limit doesn't say which jobs left: none is forgotten.
        byte[] Waiting(int from) => Jobs([.. Enumerable.Range(from, PrinterJobs.MaxJobs + 5).Select(id => (id, 3, "none", (Action<B>?)null))]);
        now = Now0.AddMinutes(7);
        Assert.Equal(Now0.AddMinutes(7), watch.Read(Waiting(10), NoJobs).Jobs.Single(j => j.Id == 10).Submitted);
        now = Now0.AddMinutes(8);
        Assert.DoesNotContain(watch.Read(Waiting(500), NoJobs).Jobs, j => j.Id == 10); // cut at the limit: job 10 may still be there
        now = Now0.AddMinutes(9);
        Assert.Equal(Now0.AddMinutes(7), watch.Read(Waiting(10), NoJobs).Jobs.Single(j => j.Id == 10).Submitted);
    }

    [Fact]
    public async Task A_first_read_without_the_ended_list_doesnt_make_old_failures_new()
    {
        var calls = 0;
        var http = new DeviceHttp("192.0.2.11", new Answering(request =>
        {
            var ended = Encoding.ASCII.GetString(request).Contains("not-completed") ? false : true;
            if (ended && Interlocked.Increment(ref calls) == 1) return [1, 2]; // the first ended list: unreadable
            return ended ? Jobs((3, 8, "aborted-by-system", null)) : NoJobs; // given up on, no time: from before the watch
        }));
        var watch = new DirectJobWatch();
        var ipp = new IppClient(http);
        Assert.Empty((await watch.ReadAsync(ipp, "ana")).Jobs);
        Assert.Empty((await watch.ReadAsync(ipp, "ana")).Jobs); // the first ended list read: still old
        Assert.Empty((await watch.ReadAsync(ipp, "ana")).Jobs);
    }

    [Fact]
    public async Task A_stopped_printer_is_a_problem_even_with_only_warnings()
    {
        async Task<string?> Problem(Func<byte[], byte[]> answer) => await DirectBatch(printer: answer).Queue.ProblemAsync(default);

        Assert.NotNull(await Problem(_ => Printer(b => b.Enums("printer-state", 5).Kw("printer-state-reasons", "moving-to-paused-warning"))));
        Assert.Equal(Core.CoreStrings.Status_Stopped + ".", await Problem(_ => Printer(b => b.Enums("printer-state", 5).Kw("printer-state-reasons", "toner-low-warning"))));
        Assert.NotNull(await Problem(_ => Printer(b => b.Enums("printer-state", 5).Kw("printer-state-reasons", "none"))));
        Assert.NotNull(await Problem(_ => Printer(b => b.Enums("printer-state", 3).Kw("printer-state-reasons", "paused"))));
        Assert.Null(await Problem(_ => Printer(b => b.Enums("printer-state", 3).Kw("printer-state-reasons", "moving-to-paused"))));
        Assert.Equal(Severity.Error, IppStatusText.DefaultSeverity("paused"));
        Assert.Equal(Severity.Error, IppStatusText.DefaultSeverity("printer-stopped"));
        Assert.Equal(Severity.Warning, IppStatusText.DefaultSeverity("moving-to-paused"));
    }

    // ---- one route decision ----

    private static IppClient Client(Func<byte[], byte[]>? answer = null) => new(new DeviceHttp("192.0.2.11", new Answering(answer ?? (_ => NoJobs))));

    [Fact]
    public async Task Job_alerts_watch_where_the_last_print_went_without_looking_the_queue_up_again()
    {
        var lookups = 0;
        string? queueName = null;
        var chose = false;
        var ipp = Client();
        var router = new PrintRouter(() => { lookups++; return Task.FromResult<string?>(queueName); }, () => ipp, () => chose);
        Assert.Null(router.Last);
        Assert.Equal(PrintRoute.Direct, (await router.ForWatchingAsync()).Route); // none chosen yet: decided once
        Assert.Equal(1, lookups);

        // A queue appears (set up in Windows) after the last print went straight: alerts keep watching the printer until the next decision.
        queueName = "Office inkjet";
        Assert.Equal(PrintRoute.Direct, (await router.ForWatchingAsync()).Route);
        Assert.Equal(1, lookups);
        var print = await router.ChooseAsync(); // the next print (or the queue's change) decides again
        Assert.Equal((PrintRoute.Queue, "Office inkjet"), (print.Route, print.Queue));
        Assert.Equal(PrintRoute.Queue, (await router.ForWatchingAsync()).Route);
        chose = true;
        Assert.Equal(PrintRoute.Direct, (await router.ChooseAsync()).Route);

        // A reconnect makes a new client: alerts read through it.
        var reconnected = Client();
        ipp = reconnected;
        Assert.Same(reconnected, (await router.ForWatchingAsync()).Ipp);

        // The alerts' reader reads the printer's list or the queue, as decided.
        var queueReads = 0;
        var jobs = new RoutedJobQueue(() => { queueReads++; return Task.FromResult<JobQueueState?>(new JobQueueState(false, false, [])); }, router, "ana");
        ipp = Client(request => Encoding.ASCII.GetString(request).Contains("not-completed") ? Jobs((4, 5, "job-printing", null)) : NoJobs);
        Assert.Equal([4], (await jobs.ReadAsync())!.Jobs.Select(j => j.Id));
        chose = false;
        await router.ChooseAsync();
        Assert.Empty((await jobs.ReadAsync())!.Jobs);
        Assert.Equal(1, queueReads);
    }

    [Fact]
    public async Task A_queue_whose_driver_Windows_cant_use_gives_way_to_the_printer_when_it_takes_jobs_straight()
    {
        IppClient? ipp = Client();
        var works = false;
        var asked = new List<string>();
        var router = new PrintRouter(() => Task.FromResult<string?>("Office laser"), () => ipp, () => false,
            queue => { asked.Add(queue); return Task.FromResult(works); });

        // The driver can't be loaded (a Windows update broke it): straight to the printer, the queue still named.
        var broken = await router.ChooseAsync();
        Assert.Equal((PrintRoute.Direct, "Office laser", true), (broken.Route, broken.Queue, broken.QueueBroken));
        Assert.Equal(["Office laser"], asked);

        // The driver works again: back to the queue.
        works = true;
        var mended = await router.ChooseAsync();
        Assert.Equal((PrintRoute.Queue, false), (mended.Route, mended.QueueBroken));

        // The person chose straight to the printer: the driver isn't asked about, and it isn't the driver's doing.
        var chosen = await new PrintRouter(() => Task.FromResult<string?>("Office laser"), () => ipp, () => true,
            _ => throw new InvalidOperationException("not asked")).ChooseAsync();
        Assert.Equal((PrintRoute.Direct, false), (chosen.Route, chosen.QueueBroken));

        // No other way to the printer: the queue it is (printing then says what's wrong with the driver), and it isn't asked.
        ipp = null;
        asked.Clear();
        works = false;
        Assert.Equal(PrintRoute.Queue, (await router.ChooseAsync()).Route);
        Assert.Empty(asked);
    }

    [Fact]
    public async Task The_print_tab_says_pages_go_straight_because_the_queue_driver_isnt_working()
    {
        var works = false;
        var routing = new PrintRouting(() => Task.FromResult<string?>("Office laser"), () => Client(), hasAddress: true, choseDirect: false, _ => { },
            queueWorks: _ => Task.FromResult(works));
        await routing.DecideAsync();
        Assert.Equal((PrintRoute.Direct, PrintRouteNote.DirectQueueBroken), (routing.Route, routing.Note));
        Assert.True(routing.HasQueue);
        works = true;
        await routing.DecideAsync();
        Assert.Equal((PrintRoute.Queue, PrintRouteNote.None), (routing.Route, routing.Note));
    }

    [Fact]
    public async Task A_batch_goes_where_the_router_decides_and_answers_for_that_route()
    {
        using var folder = new BatchFolder();
        string? queueName = "Office inkjet";
        var ipp = Client();
        var windows = new FakeQueue();
        var made = 0;
        var (direct, sentDirect) = DirectBatch();
        var router = new PrintRouter(() => Task.FromResult<string?>(queueName), () => ipp, () => false);
        var routed = new RoutedBatchQueue(windows, router, _ =>
        {
            made++;
            return direct;
        });
        var lines = await Lines(folder, routed, ("a.pdf", "pages=1", new()));
        await BatchPrintRunner.RunAsync(lines, routed, new FakeDocuments(), null, null, default);
        Assert.Single(windows.Sent);
        Assert.Equal(Core.CoreStrings.Batch_WindowsNoAnswer, routed.NoAnswer);
        Assert.False(routed.EndsOnItsOwnOnceSpooling);

        queueName = null; // the queue was removed: straight to the printer
        await BatchPrintRunner.RunAsync(lines, routed, new FakeDocuments(), null, null, default);
        Assert.Single(sentDirect);
        Assert.Single(windows.Sent);
        Assert.Equal(Core.CoreStrings.Direct_NotAnswering, routed.NoAnswer);
        Assert.True(routed.EndsOnItsOwnOnceSpooling);
        Assert.True(made > 0);
    }

    // ---- the command line's printer ----

    private static readonly InkvoltPrinter Inkjet = new("uuid-inkjet", "Office inkjet", "Inkjet 5000", "192.0.2.20", null)
    {
        IppUri = new Uri("http://192.0.2.20:631/ipp/print"),
    };

    [Fact]
    public void The_command_line_prints_straight_to_a_printer_with_no_queue_or_set_to_print_straight()
    {
        var known = new Core.Suite.InkvoltPrinters([Inkjet], new Dictionary<string, string>());
        var ownQueue = new Core.Queues.SpoolerQueue("Inkjet queue", "IP_192.0.2.20", "Microsoft IPP Class Driver", 0, 0, 0);
        var pdf = new Core.Queues.SpoolerQueue("Microsoft Print to PDF", "PORTPROMPT:", "Microsoft Print To PDF", 0, 0, 0);

        // No queue for it: straight, with the pins Inkvolt Print keeps for it.
        var direct = Assert.IsType<BatchPrinterChoice.Direct>(BatchPrinterLookup.Find("office INKJET", [pdf], known));
        Assert.Equal((Inkjet.IppUri, "Office inkjet", Inkjet), (direct.Endpoint, direct.Name, direct.Printer));
        // Its queue: the queue, as the window does; set to print straight: straight.
        Assert.Equal(new BatchPrinterChoice.Queue("Inkjet queue"), BatchPrinterLookup.Find("Office inkjet", [ownQueue, pdf], known));
        Assert.IsType<BatchPrinterChoice.Direct>(BatchPrinterLookup.Find("Office inkjet", [ownQueue], new Core.Suite.InkvoltPrinters([Inkjet], new Dictionary<string, string>()) { PrintDirect = ["UUID-INKJET"] }));
        // Never reached over IPP and no queue: nothing to print through, said before anything is read.
        var never = new Core.Suite.InkvoltPrinters([Inkjet with { IppUri = null }], new Dictionary<string, string>());
        Assert.Contains("hasn't reached it over IPP", Assert.Throws<BatchCommandException>(() => BatchPrinterLookup.Find("Office inkjet", [], never)).Message);
        Assert.Throws<BatchCommandException>(() => BatchPrinterLookup.Find("Microsoft Print to PDF", [pdf], known)); // virtual, as before

        // An address: that printer, straight; ipp is IPP over http on 631, ipps over https.
        var typed = Assert.IsType<BatchPrinterChoice.Direct>(BatchPrinterLookup.Find("ipp://192.0.2.20/ipp/print", [], known));
        Assert.Equal(new Uri("http://192.0.2.20:631/ipp/print"), typed.Endpoint);
        Assert.Same(Inkjet, typed.Printer); // a printer it remembers: its pins
        Assert.Equal(new Uri("https://192.0.2.30:8631/ipp/print"), Assert.IsType<BatchPrinterChoice.Direct>(BatchPrinterLookup.Find("ipps://192.0.2.30:8631/ipp/print", [], known)).Endpoint);
        Assert.Null(Assert.IsType<BatchPrinterChoice.Direct>(BatchPrinterLookup.Find("ipp://192.0.2.31/ipp/print", [], known)).Printer);
        foreach (var hostile in new[] { "http://192.0.2.20/", "ipp://user:secret@192.0.2.20/ipp/print", "ipp://192.0.2.20/ipp/print?x=1", "ipp://", "file://c:/x", "ipp://192.0.2.20/#a" })
            Assert.Throws<BatchCommandException>(() => BatchPrinterLookup.Find(hostile, [], known));
    }

    [Fact]
    public void The_state_file_gives_the_command_line_the_print_straight_choice_and_pins_read_only()
    {
        var known = Core.Suite.InkvoltPrinters.Parse("""
            { "Printers": [ { "Uuid": "uuid-inkjet", "Name": "Office inkjet", "Host": "192.0.2.20", "IppUri": "https://192.0.2.20:631/ipp/print" } ],
              "DirectPrinters": [ "uuid-inkjet", 7, null ],
              "CertificatePins": { "uuid-inkjet:631": "AB12", "uuid-inkjet": "CD34", "other": 5 } }
            """);
        Assert.Equal(["uuid-inkjet"], known.PrintDirect);
        var pins = new ReadOnlyPins(known, "uuid-inkjet");
        Assert.Equal(("AB12", "CD34"), (pins.Get(631), pins.Get(443)));
        Assert.Equal("AB12", pins.SetIfAbsent(631, "FFFF")); // a pin that's there must match
        Assert.Equal("EEEE", pins.SetIfAbsent(8631, "EEEE")); // none: taken this once
        Assert.Null(pins.Get(8631)); // and not kept: the command line writes nothing
        Assert.Empty(Core.Suite.InkvoltPrinters.Parse("""{ "DirectPrinters": "x", "CertificatePins": [] }""").CertificatePins);
    }
}
