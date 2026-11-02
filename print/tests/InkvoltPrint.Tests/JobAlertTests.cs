using System.Text.Json;
using System.Xml.Linq;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>
/// Job notifications (roadmap 3.4): <see cref="AlertTracker.ObserveJobs"/> on the demo queue's made-up jobs and the demo fixer's stuck
/// job, on a fake clock; the document's name as a toast shows it; what's kept across a restart.
/// </summary>
public class JobAlertTests
{
    private const string Laser = DemoFleet.LaserUuid, PrinterName = "Office laser";
    private static readonly JobOwner Me = new("gabri", "OFFICE", "GABRI-PC");
    private static readonly DateTimeOffset T0 = new(2026, 10, 24, 12, 0, 0, TimeSpan.FromHours(-4));
    private static readonly DateTime Submitted = new(2026, 10, 24, 15, 30, 0, DateTimeKind.Utc);

    private static readonly PrinterStatus Ready = new("ready", "Ready", Severity.Info, []);
    private static readonly PrinterStatus Printing = new("processing", "Printing", Severity.Info, []);

    private static AlertTracker Tracker(AlertRules? rules = null) => new(rules ?? new AlertRules { Jobs = true });

    private static QueueJob Job(int id = 7, JobStatus status = JobStatus.Printing, int printed = 0, string name = "Report.pdf", string owner = "gabri", DateTime? submitted = null, int pages = 10) =>
        new(id, name, pages, printed, status, submitted ?? Submitted, owner);

    private static JobQueueState Queue(params QueueJob[] jobs) => new(false, false, jobs);

    /// <summary>The printer read, then its queue, at one moment: as the tray does it, a minute apart.</summary>
    private static IReadOnlyList<AlertNotice> Read(AlertTracker t, DateTimeOffset at, JobQueueState? queue, PrinterStatus? status = null, bool reachable = true)
    {
        var fromPrinter = t.Observe(new PrinterSnapshot(Laser, PrinterName, reachable, reachable ? status ?? Ready : null, []), at);
        return [.. fromPrinter, .. t.ObserveJobs(Laser, PrinterName, queue, Me, at)];
    }

    /// <summary>Reads every minute from <paramref name="from"/> for <paramref name="minutes"/>; every notice told.</summary>
    private static List<AlertNotice> Minutes(AlertTracker t, DateTimeOffset from, int minutes, JobQueueState? queue, PrinterStatus? status = null)
    {
        var told = new List<AlertNotice>();
        for (var i = 0; i <= minutes; i++) told.AddRange(Read(t, from.AddMinutes(i), queue, status));
        return told;
    }

    // ---------------------------------------------------------------- off by default

    [Fact]
    public void Job_alerts_are_off_by_default()
    {
        var t = new AlertTracker(new AlertRules());
        Assert.False(t.Rules.Jobs);
        Assert.Empty(Minutes(t, T0, 20, Queue(Job(status: JobStatus.Error))));
        Assert.Empty(t.Shown());
    }

    [Fact]
    public void Alerts_off_or_paused_drop_a_job_alert_and_it_stays_told()
    {
        var off = Tracker(new AlertRules { Jobs = true, Enabled = false });
        Assert.Empty(Minutes(off, T0, 3, Queue(Job(status: JobStatus.Error))));
        off.Rules = off.Rules with { Enabled = true };
        Assert.Empty(Minutes(off, T0.AddMinutes(4), 3, Queue(Job(status: JobStatus.Error))));

        var paused = Tracker();
        paused.PausedUntil = T0.AddMinutes(10);
        Assert.Empty(Minutes(paused, T0, 3, Queue(Job(status: JobStatus.Error))));
        Assert.Empty(Minutes(paused, T0.AddMinutes(11), 3, Queue(Job(status: JobStatus.Error))));
    }

    [Fact]
    public void Quiet_hours_hold_a_job_alert_and_drop_it_if_the_job_recovered()
    {
        var rules = new AlertRules { Jobs = true, Quiet = new QuietHours(new TimeOnly(22, 0), new TimeOnly(7, 0)) };
        var night = new DateTimeOffset(2026, 10, 24, 23, 0, 0, T0.Offset);
        var t = Tracker(rules);
        Assert.Empty(Minutes(t, night, 4, Queue(Job(status: JobStatus.Error))));
        var n = Assert.Single(t.Release(night.AddHours(8.5)));
        Assert.Equal(AlertKind.JobFailed, n.Kind);

        var u = Tracker(rules);
        Assert.Empty(Minutes(u, night, 4, Queue(Job(status: JobStatus.Error))));
        Assert.Empty(Minutes(u, night.AddMinutes(5), 2, Queue(Job(status: JobStatus.Printing, printed: 3))));
        Assert.Empty(u.Release(night.AddHours(8.5)));
    }

    // ---------------------------------------------------------------- failed

    [Fact]
    public void A_failed_job_is_told_once_naming_the_document_and_the_printer()
    {
        var t = Tracker();
        Assert.Empty(Read(t, T0, Queue(Job(status: JobStatus.Error | JobStatus.Printing)))); // could be someone at the printer right now
        var n = Assert.Single(Read(t, T0.AddMinutes(1), Queue(Job(status: JobStatus.Error | JobStatus.Printing))));
        Assert.Equal(AlertKind.JobFailed, n.Kind);
        Assert.Equal(AlertLevel.Error, n.Level);
        Assert.Contains("Report.pdf", n.Title);
        Assert.Contains(PrinterName, n.Body);
        Assert.Equal(PrinterName, n.PrinterName);
        Assert.Equal(Laser, n.Uuid);
        Assert.NotNull(n.JobKey);
        Assert.Empty(Minutes(t, T0.AddMinutes(2), 60, Queue(Job(status: JobStatus.Error | JobStatus.Printing))));
    }

    [Fact]
    public void An_error_gone_before_the_hold_was_nothing()
    {
        var t = Tracker();
        Assert.Empty(Read(t, T0, Queue(Job(status: JobStatus.Error))));
        Assert.Empty(Read(t, T0.AddSeconds(30), Queue(Job(status: JobStatus.Printing, printed: 1))));
        Assert.Empty(Read(t, T0.AddMinutes(1), Queue(Job(status: JobStatus.Printing, printed: 2))));
    }

    [Theory]
    [InlineData(JobStatus.Error, true)]
    [InlineData(JobStatus.Error | JobStatus.Printing, true)]
    [InlineData(JobStatus.Error | JobStatus.PaperOut, true)]
    [InlineData(JobStatus.Error | JobStatus.Offline, true)]
    [InlineData(JobStatus.Blocked, true)]
    [InlineData(JobStatus.UserIntervention, true)]
    [InlineData(JobStatus.Error | JobStatus.Printing | JobStatus.Retained, true)] // what the real spooler read, on a queue with a dead TCP port
    [InlineData(JobStatus.Error | JobStatus.Retained, true)]
    [InlineData(JobStatus.Printing | JobStatus.Retained, false)]
    [InlineData(JobStatus.Retained, false)]
    [InlineData(JobStatus.Error | JobStatus.Deleting, false)] // being cancelled
    [InlineData(JobStatus.Error | JobStatus.Deleted, false)]
    [InlineData(JobStatus.Error | JobStatus.Printed, false)]
    [InlineData(JobStatus.Error | JobStatus.Paused, false)] // paused by hand
    [InlineData(JobStatus.PaperOut, false)] // the printer's state: its own alert says so
    [InlineData(JobStatus.Offline, false)]
    [InlineData(JobStatus.Paused, false)]
    [InlineData(JobStatus.None, false)]
    [InlineData(JobStatus.Printing, false)]
    public void What_counts_as_failed(JobStatus status, bool failed) => Assert.Equal(failed, JobRules.IsFailed(status));

    [Fact]
    public void A_failure_in_a_paused_queue_or_on_a_printer_that_isnt_ready_is_still_told()
    {
        var paused = Tracker();
        Assert.Single(Minutes(paused, T0, 2, new JobQueueState(true, false, [Job(status: JobStatus.Error)])));
        var offline = Tracker();
        Assert.Single(Minutes(offline, T0, 2, Queue(Job(status: JobStatus.Error)), new PrinterStatus("offline", "Offline", Severity.Error, [])));
    }

    // ---------------------------------------------------------------- stuck

    [Fact]
    public void A_job_that_doesnt_move_for_five_minutes_on_a_ready_printer_is_told_once()
    {
        var t = Tracker();
        var queue = Queue(Job(printed: 3));
        Assert.Empty(Minutes(t, T0, 4, queue));
        Assert.Equal(T0.AddMinutes(5), t.PendingUntil(Laser)); // asks for a printer read then
        var n = Assert.Single(Read(t, T0.AddMinutes(5), queue));
        Assert.Equal(AlertKind.JobStuck, n.Kind);
        Assert.Equal(AlertLevel.Warning, n.Level);
        Assert.Contains("Report.pdf", n.Title);
        Assert.Contains(PrinterName, n.Body);
        Assert.Contains("5 minutes", n.Body);
        Assert.Null(t.PendingUntil(Laser));
        Assert.Empty(Minutes(t, T0.AddMinutes(6), 120, queue));
    }

    [Fact]
    public void A_job_printing_fine_for_hours_is_not_stuck()
    {
        var t = Tracker();
        for (var i = 0; i < 240; i++)
            Assert.Empty(Read(t, T0.AddMinutes(i), Queue(Job(printed: i / 2, pages: 1000))));
    }

    [Theory]
    [InlineData("processing")]
    [InlineData("printing")]
    public void A_hung_job_while_the_printer_says_its_printing_is_told_after_the_longer_wait_in_honest_words(string code)
    {
        var t = Tracker();
        var printing = new PrinterStatus(code, "Printing", Severity.Info, []);
        var queue = Queue(Job(printed: 0, pages: 0));
        Assert.Empty(Minutes(t, T0, 14, queue, printing));
        Assert.Equal(T0.AddMinutes(15), t.PendingUntil(Laser));
        var n = Assert.Single(Read(t, T0.AddMinutes(15), queue, printing));
        Assert.Equal(AlertKind.JobStuck, n.Kind);
        Assert.Equal("“Report.pdf” may be stuck", n.Title);
        Assert.Contains("hasn't moved for 15 minutes and may be stuck", n.Body);
        Assert.Contains("says it's printing", n.Body);
        Assert.Empty(Minutes(t, T0.AddMinutes(16), 180, queue, printing)); // no progress: the same episode
    }

    [Fact]
    public void A_slow_job_that_moves_stays_silent_while_the_printer_says_its_printing()
    {
        var pages = Tracker();
        for (var i = 0; i < 300; i++)
            Assert.Empty(Read(pages, T0.AddMinutes(i), Queue(Job(printed: i / 14, pages: 1000)), Printing)); // a page every 14 minutes

        var bytes = Tracker();
        for (var i = 0; i < 300; i++)
            Assert.Empty(Read(bytes, T0.AddMinutes(i), Queue(Job(printed: 0, pages: 0) with { Bytes = 1000 + i / 14 }), Printing)); // no page counts, its size still growing
    }

    [Fact]
    public void A_job_with_pages_reported_and_moving_isnt_stuck_on_a_ready_printer_either()
    {
        var t = Tracker();
        for (var i = 0; i < 120; i++) Assert.Empty(Read(t, T0.AddMinutes(i), Queue(Job(printed: i / 4, pages: 1000))));
    }

    [Fact]
    public void A_printer_that_starts_printing_gets_the_longer_wait_from_the_last_movement_and_one_going_ready_the_shorter()
    {
        var t = Tracker();
        var queue = Queue(Job());
        Assert.Empty(Minutes(t, T0, 3, queue)); // ready
        Assert.Empty(Minutes(t, T0.AddMinutes(4), 10, queue, Printing)); // 14 minutes still
        Assert.Single(Read(t, T0.AddMinutes(15), queue, Printing));

        var u = Tracker();
        Assert.Empty(Minutes(u, T0, 7, queue, Printing));
        Assert.Empty(Minutes(u, T0.AddMinutes(8), 4, queue)); // ready for 4 minutes: printing wasn't being ready
        Assert.Contains("is ready", Assert.Single(Read(u, T0.AddMinutes(13), queue)).Body);
    }

    [Fact]
    public void A_printer_flipping_between_ready_and_printing_still_tells_a_job_that_never_moves()
    {
        var t = Tracker();
        var told = new List<AlertNotice>();
        for (var i = 0; i < 60; i++) told.AddRange(Read(t, T0.AddMinutes(i), Queue(Job()), i % 4 == 3 ? Printing : Ready));
        Assert.Contains("may be stuck", Assert.Single(told).Body);
    }

    [Fact]
    public void A_job_waiting_behind_someone_elses_long_job_is_not_stuck()
    {
        var t = Tracker();
        for (var i = 0; i < 120; i++)
            Assert.Empty(Read(t, T0.AddMinutes(i), Queue(
                Job(1, JobStatus.Printing, printed: i / 2, owner: "alex", name: "Their big file.pdf", submitted: Submitted.AddMinutes(-5), pages: 1000),
                Job(2, JobStatus.None, name: "Mine.pdf"))));
    }

    [Fact]
    public void Someone_elses_job_that_finishes_starts_my_wait_again()
    {
        var t = Tracker();
        var theirs = Job(1, JobStatus.Printing, owner: "alex", submitted: Submitted.AddMinutes(-5));
        var mine = Job(2, JobStatus.None);
        Assert.Empty(Minutes(t, T0, 3, Queue(theirs, mine)));
        Assert.Empty(Minutes(t, T0.AddMinutes(4), 3, Queue(mine)));
        Assert.Single(Minutes(t, T0.AddMinutes(8), 2, Queue(mine))); // five minutes after the other job left
    }

    [Fact]
    public void New_jobs_arriving_behind_it_arent_progress()
    {
        var t = Tracker();
        var mine = Job(2, JobStatus.Printing);
        var told = new List<AlertNotice>();
        for (var i = 0; i <= 5; i++)
            told.AddRange(Read(t, T0.AddMinutes(i), Queue([mine, .. Enumerable.Range(0, i).Select(n => Job(100 + n, JobStatus.None, owner: "alex", submitted: Submitted.AddMinutes(n + 1)))])));
        Assert.Equal("“Report.pdf” isn't moving", Assert.Single(told).Title);
    }

    [Fact]
    public void Only_my_first_job_is_told_stuck_the_next_gets_its_own_wait_once_that_one_is_gone()
    {
        var t = Tracker();
        var first = Job(1, JobStatus.Printing, name: "First.pdf");
        var second = Job(2, JobStatus.None, name: "Second.pdf", submitted: Submitted.AddMinutes(1));
        Assert.Contains("First.pdf", Assert.Single(Minutes(t, T0, 30, Queue(first, second))).Title);
        Assert.Empty(Minutes(t, T0.AddMinutes(31), 4, Queue(second))); // first cancelled: the queue moved
        Assert.Contains("Second.pdf", Assert.Single(Minutes(t, T0.AddMinutes(36), 0, Queue(second))).Title);
    }

    [Fact]
    public void A_failed_first_job_stands_for_the_ones_behind_it()
    {
        var t = Tracker();
        var failed = Job(1, JobStatus.Error, name: "First.pdf");
        var second = Job(2, JobStatus.None, name: "Second.pdf", submitted: Submitted.AddMinutes(1));
        Assert.Contains("First.pdf", Assert.Single(Minutes(t, T0, 30, Queue(failed, second))).Title);
    }

    [Fact]
    public void A_queue_paused_on_purpose_holds_no_stuck_job_and_gets_the_full_wait_once_resumed()
    {
        var t = Tracker();
        Assert.Empty(Minutes(t, T0, 30, new JobQueueState(true, false, [Job()])));
        Assert.Null(t.PendingUntil(Laser));
        Assert.Empty(Minutes(t, T0.AddMinutes(31), 4, Queue(Job())));
        Assert.Single(Minutes(t, T0.AddMinutes(36), 0, Queue(Job())));
    }

    [Fact]
    public void Use_Printer_Offline_holds_no_stuck_job() =>
        Assert.Empty(Minutes(Tracker(), T0, 30, new JobQueueState(false, true, [Job()])));

    [Fact]
    public void A_job_paused_by_hand_is_not_stuck() => Assert.Empty(Minutes(Tracker(), T0, 30, Queue(Job(status: JobStatus.Paused))));

    [Fact]
    public void A_job_still_being_written_by_the_app_printing_it_is_not_stuck() =>
        Assert.Empty(Minutes(Tracker(), T0, 30, Queue(Job(status: JobStatus.Spooling, pages: 0))));

    [Fact]
    public void The_real_spoolers_sequence_on_a_dead_port_tells_one_failure()
    {
        // As read from a real queue on a TCP port nothing answers at: waiting, then Printing | Retained, then an error on the job and on the queue.
        var t = Tracker();
        var failed = new PrinterStatus("error", "Printer error", Severity.Error, [new PrinterAlert("error", Severity.Error, "Printer error")]);
        Assert.Empty(Read(t, T0, Queue(Job(status: JobStatus.None, pages: 1))));
        Assert.Empty(Read(t, T0.AddSeconds(30), Queue(Job(status: JobStatus.Printing | JobStatus.Retained, pages: 1))));
        Assert.DoesNotContain(Read(t, T0.AddSeconds(90), Queue(Job(status: JobStatus.Error | JobStatus.Printing | JobStatus.Retained, pages: 1)), failed), n => n.JobKey is not null);
        var told = Minutes(t, T0.AddSeconds(150), 30, Queue(Job(status: JobStatus.Error | JobStatus.Printing | JobStatus.Retained, pages: 1)), failed);
        var n = Assert.Single(told, n => n.JobKey is not null);
        Assert.Equal(AlertKind.JobFailed, n.Kind);
    }

    [Fact]
    public void A_job_saying_printing_and_retained_is_still_a_job_that_should_move()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 6, Queue(Job(status: JobStatus.Printing | JobStatus.Retained))));
    }

    [Theory]
    [InlineData(JobStatus.Printed)]
    [InlineData(JobStatus.Printed | JobStatus.Retained)]
    [InlineData(JobStatus.Retained)]
    [InlineData(JobStatus.Completed)]
    [InlineData(JobStatus.Deleting)]
    public void A_job_on_its_way_out_is_not_stuck(JobStatus status) => Assert.Empty(Minutes(Tracker(), T0, 30, Queue(Job(status: status))));

    [Theory]
    [InlineData("offline", Severity.Error)]
    [InlineData("warmingUp", Severity.Info)]
    [InlineData("initializing", Severity.Info)]
    [InlineData("paused", Severity.Warning)]
    [InlineData("unknown", Severity.Warning)]
    [InlineData("unavailable", Severity.Warning)]
    public void A_printer_that_isnt_ready_holds_no_stuck_job(string code, Severity severity) =>
        Assert.Empty(Minutes(Tracker(), T0, 30, Queue(Job()), new PrinterStatus(code, code, severity, [])));

    [Theory]
    [InlineData("jamInPrinter", Severity.Error)]
    [InlineData("manuallyFeed", Severity.Warning)]
    [InlineData("manual-feed", Severity.Warning)]
    public void A_ready_code_with_a_problem_or_a_manual_feed_isnt_ready(string id, Severity severity) =>
        Assert.DoesNotContain(Minutes(Tracker(), T0, 30, Queue(Job()), new PrinterStatus("ready", "Ready", severity, [new PrinterAlert(id, severity, "Text")])), n => n.JobKey is not null);

    [Fact]
    public void A_low_toner_warning_doesnt_stop_a_printer_being_ready() =>
        Assert.Single(Minutes(Tracker(), T0, 6, Queue(Job()), new PrinterStatus("ready", "Ready", Severity.Warning, [new PrinterAlert("cartridgeLow", Severity.Warning, "Toner low")])));

    [Theory]
    [InlineData("ready")]
    [InlineData("idle")]
    [InlineData("inPowerSave")]
    public void A_printer_idle_or_asleep_is_ready(string code) =>
        Assert.Single(Minutes(Tracker(), T0, 6, Queue(Job()), new PrinterStatus(code, code, Severity.Info, [])));

    [Theory]
    [InlineData(JobStatus.PaperOut)]
    [InlineData(JobStatus.Offline)]
    [InlineData(JobStatus.Printing | JobStatus.PaperOut)]
    public void The_spooler_saying_the_printer_cant_take_it_holds_no_stuck_job(JobStatus status) =>
        Assert.Empty(Minutes(Tracker(), T0, 30, Queue(Job(status: status))));

    [Fact]
    public void A_printer_that_stops_being_ready_starts_the_wait_again()
    {
        var t = Tracker();
        Assert.Empty(Minutes(t, T0, 3, Queue(Job())));
        // Between two queue reads the printer printed a page: the queue read hasn't seen it, the printer's own read has.
        t.Observe(new PrinterSnapshot(Laser, PrinterName, true, Printing, []), T0.AddMinutes(3.5));
        Assert.Empty(Minutes(t, T0.AddMinutes(4), 4, Queue(Job())));
        Assert.Single(Read(t, T0.AddMinutes(9), Queue(Job())));
    }

    [Fact]
    public void A_printer_never_read_or_not_answering_or_with_an_unusable_reply_isnt_known_to_be_ready()
    {
        var never = Tracker();
        for (var i = 0; i < 30; i++) Assert.Empty(never.ObserveJobs(Laser, PrinterName, Queue(Job()), Me, T0.AddMinutes(i)));

        var off = Tracker();
        for (var i = 0; i < 30; i++) Assert.DoesNotContain(Read(off, T0.AddMinutes(i), Queue(Job()), reachable: false), n => n.JobKey is not null);

        var unusable = Tracker();
        for (var i = 0; i < 30; i++)
        {
            unusable.Observe(new PrinterSnapshot(Laser, PrinterName, true, null, []), T0.AddMinutes(i));
            Assert.Empty(unusable.ObserveJobs(Laser, PrinterName, Queue(Job()), Me, T0.AddMinutes(i)));
        }
    }

    [Fact]
    public void Ready_has_to_be_what_the_printer_says_after_the_wait_not_minutes_before()
    {
        var t = Tracker();
        t.Observe(new PrinterSnapshot(Laser, PrinterName, true, Ready, []), T0);
        for (var i = 0; i <= 20; i++) Assert.Empty(t.ObserveJobs(Laser, PrinterName, Queue(Job()), Me, T0.AddMinutes(i)));
        Assert.Equal(T0.AddMinutes(5), t.PendingUntil(Laser));
        t.Observe(new PrinterSnapshot(Laser, PrinterName, true, Ready, []), T0.AddMinutes(20.5));
        Assert.Single(t.ObserveJobs(Laser, PrinterName, Queue(Job()), Me, T0.AddMinutes(21)));
    }

    [Fact]
    public void The_time_the_pc_slept_doesnt_count_as_waiting()
    {
        var t = Tracker();
        Assert.Empty(Minutes(t, T0, 3, Queue(Job())));
        Assert.Empty(Read(t, T0.AddHours(8), Queue(Job()))); // woke up: a gap says nothing
        Assert.Empty(Minutes(t, T0.AddHours(8).AddMinutes(1), 3, Queue(Job())));
        Assert.Single(Read(t, T0.AddHours(8).AddMinutes(5), Queue(Job())));
    }

    [Fact]
    public void Waking_up_starts_the_waits_and_the_failure_hold_again()
    {
        var t = Tracker();
        Assert.Empty(Read(t, T0, Queue(Job(status: JobStatus.Error))));
        t.ResetPending();
        Assert.Empty(Read(t, T0.AddSeconds(90), Queue(Job(status: JobStatus.Error))));
        Assert.Single(Read(t, T0.AddSeconds(150), Queue(Job(status: JobStatus.Error))));
    }

    [Fact]
    public void A_job_first_seen_late_gets_the_full_wait_whenever_it_was_submitted()
    {
        var t = Tracker();
        var old = Job(submitted: Submitted.AddDays(-2));
        Assert.Empty(Minutes(t, T0, 4, Queue(old)));
        Assert.Single(Read(t, T0.AddMinutes(5), Queue(old)));
    }

    // ---------------------------------------------------------------- one per job

    [Fact]
    public void Stuck_recovered_and_stuck_again_is_told_again_after_real_progress()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 6, Queue(Job(printed: 1))));
        Assert.Empty(Minutes(t, T0.AddMinutes(7), 2, Queue(Job(printed: 2)))); // it moved
        Assert.Empty(Minutes(t, T0.AddMinutes(10), 1, Queue(Job(printed: 2)))); // the wait runs from the movement
        Assert.Single(Read(t, T0.AddMinutes(12), Queue(Job(printed: 2))));
        Assert.Empty(Minutes(t, T0.AddMinutes(13), 60, Queue(Job(printed: 2)))); // the same episode, however long
    }

    [Fact]
    public void Flicker_is_not_progress_and_doesnt_hide_a_hung_job()
    {
        // A state going back and forth, a count going down and up again: never past what was already seen.
        JobStatus Flip(int i) => i % 2 == 0 ? JobStatus.Printing : JobStatus.None;
        int Wobble(int i) => i % 2 == 0 ? 3 : 2;
        var t = Tracker();
        for (var i = 0; i < 5; i++) Assert.Empty(Read(t, T0.AddMinutes(i), Queue(Job(status: Flip(i), printed: Wobble(i)))));
        Assert.Single(Read(t, T0.AddMinutes(5), Queue(Job(status: Flip(5), printed: Wobble(5)))));
        for (var i = 6; i < 120; i++) Assert.Empty(Read(t, T0.AddMinutes(i), Queue(Job(status: Flip(i), printed: Wobble(i)))));
    }

    [Fact]
    public void A_flapping_job_with_real_progress_each_time_is_told_three_times_at_most()
    {
        var t = Tracker();
        var told = new List<AlertNotice>();
        for (var round = 0; round < 10; round++)
            told.AddRange(Minutes(t, T0.AddMinutes(round * 7), 6, Queue(Job(printed: round))));
        Assert.Equal(3, told.Count);
        Assert.All(told, n => Assert.Equal(AlertKind.JobStuck, n.Kind));
    }

    [Fact]
    public void The_cap_is_one_setting_and_so_are_the_waits()
    {
        var rules = new AlertRules { Jobs = true, JobMaxStuckAlerts = 1, JobStuckAfter = TimeSpan.FromMinutes(2), JobHungAfter = TimeSpan.FromMinutes(4) };
        var t = Tracker(rules);
        var n = Assert.Single(Minutes(t, T0, 3, Queue(Job(printed: 0))));
        Assert.Contains("2 minutes", n.Body);
        Assert.Empty(Minutes(t, T0.AddMinutes(4), 30, Queue(Job(printed: 1))));
        var u = Tracker(rules);
        Assert.Contains("4 minutes", Assert.Single(Minutes(u, T0, 5, Queue(Job()), Printing)).Body);
        var defaults = new AlertRules();
        Assert.Equal((5.0, 15.0, 3), (defaults.JobStuckAfter.TotalMinutes, defaults.JobHungAfter.TotalMinutes, defaults.JobMaxStuckAlerts));
    }

    [Fact]
    public void The_same_episode_doesnt_tell_again_across_a_restart_and_progress_while_away_does()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 6, Queue(Job(printed: 3))));

        var same = new AlertTracker(t.Rules, t.Shown());
        Assert.Empty(Minutes(same, T0.AddDays(1), 60, Queue(Job(printed: 3))));

        var moved = new AlertTracker(t.Rules, t.Shown());
        Assert.Single(Minutes(moved, T0.AddDays(1), 30, Queue(Job(printed: 4)))); // it went on while the app was closed, then stopped
    }

    [Fact]
    public void The_cap_survives_a_restart()
    {
        var t = Tracker();
        var told = 0;
        for (var round = 0; round < 3; round++)
        {
            told += Minutes(t, T0.AddDays(round), 6, Queue(Job(printed: round))).Count;
            t = new AlertTracker(t.Rules, t.Shown());
        }
        Assert.Equal(3, told);
        Assert.Empty(Minutes(t, T0.AddDays(5), 30, Queue(Job(printed: 50))));
    }

    [Fact]
    public void A_restarted_job_starts_again_its_pages_count_as_moving_and_it_may_be_told_again()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 6, Queue(Job(printed: 5))));
        // Someone restarted it: the count starts over, below where it had been.
        var told = new List<AlertNotice>();
        told.AddRange(Read(t, T0.AddMinutes(7), Queue(Job(status: JobStatus.Printing | JobStatus.Restarted, printed: 0))));
        for (var i = 1; i <= 4; i++) told.AddRange(Minutes(t, T0.AddMinutes(7 + i * 4), 3, Queue(Job(status: JobStatus.Printing | JobStatus.Restarted, printed: i))));
        Assert.Empty(told);
        Assert.Single(Minutes(t, T0.AddMinutes(30), 6, Queue(Job(status: JobStatus.Printing | JobStatus.Restarted, printed: 4))));
    }

    [Fact]
    public void Failed_is_once_per_job_and_told_even_after_stuck()
    {
        var t = Tracker();
        Assert.Equal(AlertKind.JobStuck, Assert.Single(Minutes(t, T0, 6, Queue(Job()))).Kind);
        Assert.Equal(AlertKind.JobFailed, Assert.Single(Minutes(t, T0.AddMinutes(7), 10, Queue(Job(status: JobStatus.Error)))).Kind);
        Assert.Empty(Minutes(t, T0.AddMinutes(18), 2, Queue(Job(status: JobStatus.Printing))));
        Assert.Empty(Minutes(t, T0.AddMinutes(21), 30, Queue(Job(status: JobStatus.Error))));
    }

    [Fact]
    public void After_a_failure_stuck_needs_real_progress_too()
    {
        var t = Tracker();
        Assert.Equal(AlertKind.JobFailed, Assert.Single(Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error | JobStatus.Printing)))).Kind);
        Assert.Empty(Minutes(t, T0.AddMinutes(4), 30, Queue(Job()))); // the error went, the job didn't move
        Assert.Equal(AlertKind.JobStuck, Assert.Single(Minutes(t, T0.AddMinutes(35), 6, Queue(Job(printed: 1)))).Kind);
    }

    [Fact]
    public void A_resubmitted_job_is_a_new_job_and_may_fail_again()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(9, JobStatus.Error))));
        Assert.Single(Minutes(t, T0.AddMinutes(4), 3, Queue(Job(10, JobStatus.Error, submitted: Submitted.AddMinutes(4)))));
    }

    [Fact]
    public void A_pause_ends_the_episode_without_using_up_the_cap()
    {
        var t = Tracker();
        t.PausedUntil = T0.AddMinutes(10);
        Assert.Empty(Minutes(t, T0, 6, Queue(Job(printed: 1))));
        Assert.Empty(Minutes(t, T0.AddMinutes(11), 20, Queue(Job(printed: 1)))); // still the one nobody was told about: it stays quiet
        var told = 0;
        for (var round = 2; round < 10; round++) told += Minutes(t, T0.AddHours(round), 6, Queue(Job(printed: round))).Count;
        Assert.Equal(3, told);
    }

    [Fact]
    public void A_restart_doesnt_tell_again_and_keeps_no_document_name()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error, name: "Secret merger plan.pdf"))));
        var remembered = t.Shown();

        // state.json holds these: the job's id and time, nothing about the document or who printed it.
        var saved = JsonSerializer.Serialize(remembered);
        Assert.DoesNotContain("Secret", saved);
        Assert.DoesNotContain("merger", saved);
        Assert.DoesNotContain("gabri", saved);
        Assert.Matches(@"^Job\|7\|\d+\|1\|0\|\d+\|\d+\|\d+\|\d+\|\d+$", Assert.Single(remembered[Laser]));

        var next = new AlertTracker(new AlertRules { Jobs = true }, remembered);
        Assert.Empty(Minutes(next, T0.AddDays(1), 30, Queue(Job(status: JobStatus.Error, name: "Secret merger plan.pdf"))));
        Assert.Single(next.Shown()[Laser]);
    }

    [Fact]
    public void A_remembered_job_that_turns_out_to_be_gone_is_forgotten_after_the_clear_hold()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error))));
        var next = new AlertTracker(new AlertRules { Jobs = true }, t.Shown());
        Assert.Empty(Minutes(next, T0.AddDays(1), 9, Queue()));
        Assert.Single(next.Shown()[Laser]);
        Assert.Empty(Minutes(next, T0.AddDays(1).AddMinutes(10), 1, Queue()));
        Assert.Empty(next.Shown());
    }

    [Fact]
    public void A_job_a_read_missed_for_a_moment_isnt_told_again()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error))));
        Assert.Empty(Read(t, T0.AddMinutes(4), Queue()));
        Assert.Empty(Minutes(t, T0.AddMinutes(5), 5, Queue(Job(status: JobStatus.Error))));
    }

    [Fact]
    public void A_job_id_the_spooler_used_again_is_a_new_job()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(7, JobStatus.Error, name: "First.pdf"))));
        // Gone, and at once a new job under the same id. Not even a read in between saw the queue without it.
        var again = Job(7, JobStatus.Error, name: "Second.pdf", submitted: Submitted.AddHours(2));
        var told = Minutes(t, T0.AddMinutes(4), 3, Queue(again));
        Assert.Contains("Second.pdf", Assert.Single(told).Title);
        Assert.Empty(Minutes(t, T0.AddMinutes(8), 10, Queue(again)));
        // Across a restart too.
        var next = new AlertTracker(new AlertRules { Jobs = true }, t.Shown());
        Assert.Empty(Minutes(next, T0.AddDays(1), 3, Queue(again)));
        Assert.Single(Minutes(next, T0.AddDays(1).AddMinutes(4), 3, Queue(Job(7, JobStatus.Error, name: "Third.pdf", submitted: Submitted.AddHours(5)))));
    }

    [Fact]
    public void A_job_whose_name_changes_while_it_spools_is_the_same_job()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error, name: "Print job"))));
        Assert.Empty(Minutes(t, T0.AddMinutes(4), 5, Queue(Job(status: JobStatus.Error, name: "Report.pdf"))));
    }

    [Fact]
    public void Turning_alerts_off_and_on_keeps_what_a_job_was_told()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error))));
        var fresh = new AlertTracker(t.Rules, t.ShownJobs()); // as the tray starts over when alerts are turned on
        Assert.Empty(Minutes(fresh, T0.AddMinutes(4), 5, Queue(Job(status: JobStatus.Error))));
    }

    [Fact]
    public void Remembered_job_keys_that_make_no_sense_are_ignored_and_bounded()
    {
        var keys = new List<string> { "Job|", "Job|x|y", "Job|7", "Job|7|1", "Job|7|1|2", "Job|-1|5|0|0|0|0|0|0|0", "Job||", "Job|7|99999999999999999999999|0|0|0|0|0|0|0", "Job|7|1|0|0|0|0|0|x|0", "Job|7|1|0|-1|0|0|0|0|0", "Job|7|1|0|0|0|0|0|0|0|0" };
        Assert.Empty(new AlertTracker(new AlertRules { Jobs = true }, new Dictionary<string, IReadOnlyList<string>> { [Laser] = keys }).Shown());
        var many = Enumerable.Range(0, 5000).Select(i => $"Job|{i}|{i}|1|0|0|0|0|0|0").ToList();
        Assert.InRange(new AlertTracker(new AlertRules { Jobs = true }, new Dictionary<string, IReadOnlyList<string>> { [Laser] = many }).Shown()[Laser].Count, 1, 256);
    }

    [Fact]
    public void A_queue_that_went_away_tells_nothing_and_holds_nothing()
    {
        var t = Tracker();
        Assert.Empty(Read(t, T0, Queue(Job(status: JobStatus.Error))));
        Assert.Empty(Minutes(t, T0.AddMinutes(1), 10, null));
        Assert.Null(t.PendingUntil(Laser));
        Assert.Empty(t.Shown());
    }

    [Fact]
    public void Removing_the_printer_forgets_its_jobs()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error))));
        t.Forget(Laser);
        Assert.Empty(t.Shown());
    }

    [Fact]
    public void Jobs_dont_color_the_tray_icon()
    {
        var t = Tracker();
        Assert.Single(Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error))));
        Assert.Equal(AlertLevel.Ok, t.Level(Laser));
        Assert.Equal(AlertLevel.Ok, t.Overall);
        Assert.Null(t.Problem(Laser));
    }

    [Fact]
    public void The_printers_own_alerts_still_work_beside_job_alerts()
    {
        var t = Tracker();
        var jam = new PrinterStatus("stopped", "Paper jam", Severity.Error, [new PrinterAlert("media-jam", Severity.Error, "Paper jam")]);
        var told = Minutes(t, T0, 3, Queue(Job(status: JobStatus.Error)), jam);
        Assert.Equal([AlertKind.PaperJam, AlertKind.JobFailed], told.Select(n => n.Kind).Order());
    }

    // ---------------------------------------------------------------- your own

    [Theory]
    [InlineData("gabri", null, true)]
    [InlineData("GABRI", null, true)]
    [InlineData(" gabri ", null, true)]
    [InlineData(@"OFFICE\gabri", null, true)]
    [InlineData(@"office\Gabri", null, true)]
    [InlineData(@"\\OFFICE\gabri", null, false)] // not a domain this PC is in
    [InlineData(@"HOME\gabri", null, false)] // same name, someone else's domain
    [InlineData("alex", null, false)]
    [InlineData("gabri2", null, false)]
    [InlineData("gab", null, false)]
    [InlineData("", null, false)]
    [InlineData("   ", null, false)]
    [InlineData("gabri", @"\\GABRI-PC", true)]
    [InlineData("gabri", @"\\gabri-pc", true)]
    [InlineData("gabri", @"\\GABRI-PC.office.lan", true)]
    [InlineData("gabri", "", true)]
    [InlineData("gabri", @"\\FRONT-DESK", false)] // the same user name on another PC sharing the printer
    [InlineData("gabri", @"\\10.0.0.5", false)] // can't tell: not ours to name
    public void Whose_job_it_is(string owner, string? machine, bool mine) =>
        Assert.Equal(mine, Me.Owns(Job(owner: owner) with { Machine = machine }));

    [Fact]
    public void A_user_name_or_machine_this_pc_doesnt_know_is_never_a_match_by_accident()
    {
        Assert.False(new JobOwner("", "OFFICE", "PC").Owns(Job(owner: "")));
        Assert.False(new JobOwner(null, null, null).Owns(Job(owner: "gabri")));
        Assert.True(new JobOwner("gabri", null, null).Owns(Job(owner: @"OFFICE\gabri") with { Machine = @"\\PC" })); // nothing here to compare with
    }

    [Fact]
    public void A_long_pc_name_matches_windows_short_name_for_it() =>
        Assert.True(new JobOwner("gabri", null, "ACCOUNTING-WORK").Owns(Job() with { Machine = @"\\ACCOUNTING-WORKSTATION.corp" }));

    [Fact]
    public void Other_peoples_jobs_on_a_shared_queue_never_raise_one()
    {
        var t = Tracker();
        var theirs = new[]
        {
            Job(1, JobStatus.Error, owner: "alex", name: "Their secret.pdf"),
            Job(2, JobStatus.Printing, owner: @"HOME\gabri", name: "Their other.pdf", submitted: Submitted.AddMinutes(1)),
            Job(3, JobStatus.None, name: "Same name other PC.pdf", submitted: Submitted.AddMinutes(2)) with { Machine = @"\\FRONT-DESK" },
            Job(4, JobStatus.None, owner: "", name: "No owner.pdf", submitted: Submitted.AddMinutes(3)),
        };
        Assert.Empty(Minutes(t, T0, 60, Queue(theirs)));
        Assert.Empty(t.Shown());
        Assert.Null(t.PendingUntil(Laser));
    }

    [Fact]
    public void Someone_elses_failed_job_ahead_of_mine_makes_mine_stuck_not_theirs_told()
    {
        var t = Tracker();
        var told = Minutes(t, T0, 10, Queue(Job(1, JobStatus.Error, owner: "alex", name: "Theirs.pdf"), Job(2, JobStatus.None, name: "Mine.pdf", submitted: Submitted.AddMinutes(1))));
        var n = Assert.Single(told);
        Assert.Equal(AlertKind.JobStuck, n.Kind);
        Assert.Contains("Mine.pdf", n.Title);
        Assert.DoesNotContain("Theirs", n.Title + n.Body);
    }

    // ---------------------------------------------------------------- the demo's made-up jobs

    private static readonly DateTime DemoNow = new(2026, 10, 24, 12, 0, 0, DateTimeKind.Local);

    [Fact]
    public void The_demo_queue_printing_along_raises_nothing()
    {
        var t = Tracker();
        var jobs = DemoFleet.CardJobs("gabri", DemoNow);
        for (var i = 0; i < 8; i++)
        {
            // As the demo's card moves it on, a page each read.
            var moved = jobs.Select(j => j.Id == 11 ? j with { PagesPrinted = j.PagesPrinted + i } : j).ToArray();
            Assert.Empty(Read(t, T0.AddMinutes(i), Queue(moved)));
        }
    }

    [Fact]
    public void The_demo_queue_frozen_raises_one_for_my_first_job_only()
    {
        var t = Tracker();
        var told = Minutes(t, T0, 30, Queue([.. DemoFleet.CardJobs("gabri", DemoNow)]));
        var n = Assert.Single(told);
        Assert.Equal(AlertKind.JobStuck, n.Kind);
        Assert.Contains("Quarterly report.pdf", n.Title);
    }

    [Fact]
    public void The_demo_alexs_job_alone_raises_nothing()
    {
        var alex = DemoFleet.CardJobs("gabri", DemoNow).Single(j => j.Owner == "alex");
        Assert.Empty(Minutes(Tracker(), T0, 30, Queue(alex)));
        Assert.Empty(Minutes(Tracker(), T0, 30, Queue(alex with { Status = JobStatus.Error })));
    }

    [Fact]
    public void The_demo_fixers_stuck_job_raises_one_naming_the_document_and_the_printer()
    {
        // Its queue has Use Printer Offline on and the printer doesn't answer, as in the demo: the job's own error still tells.
        var t = Tracker();
        var queue = new JobQueueState(false, true, [DemoFleet.OfficeStuckJob("gabri", DemoNow)]);
        var told = new List<AlertNotice>();
        for (var i = 0; i < 60; i++)
        {
            t.Observe(new PrinterSnapshot(DemoFleet.OfficeUuid, "Demo office laser", false, null, null), T0.AddMinutes(i));
            told.AddRange(t.ObserveJobs(DemoFleet.OfficeUuid, "Demo office laser", queue, Me, T0.AddMinutes(i)));
        }
        var n = Assert.Single(told);
        Assert.Equal(AlertKind.JobFailed, n.Kind);
        Assert.Contains("Invoice 1043.pdf", n.Title);
        Assert.Contains("Demo office laser", n.Body);
        var toast = XDocument.Parse(AlertToasts.Xml([n])).Root!;
        Assert.Equal(["Open the queue", "Pause alerts"], toast.Element("actions")!.Elements("action").Select(a => a.Attribute("content")!.Value));
    }

    [Fact]
    public void The_demo_fixers_stuck_job_held_by_someone_else_raises_nothing()
    {
        var job = DemoFleet.FrontDeskStuckJob("alex", DemoNow);
        Assert.Empty(Minutes(Tracker(), T0, 30, new JobQueueState(false, false, [job])));
    }

    // ---------------------------------------------------------------- the document's name

    private static AlertNotice Failed(string name, string printer = PrinterName)
    {
        var t = Tracker();
        Assert.Empty(t.ObserveJobs(Laser, printer, Queue(Job(status: JobStatus.Error, name: name)), Me, T0));
        return Assert.Single(t.ObserveJobs(Laser, printer, Queue(Job(status: JobStatus.Error, name: name)), Me, T0.AddMinutes(1)));
    }

    public static TheoryData<string> Hostile => new()
    {
        "<script>alert(1)</script>.pdf",
        "</text><action content=\"Run\" arguments=\"x\"/><text>.pdf",
        "a&b&amp;c\"'.pdf",
        "]]><!--.pdf",
        "\u0001\u0002\u0008\u000b\u000c\u001f bell\u0007.pdf",
        "\ud83d lone high.pdf",
        "lone low \ude00.pdf",
        "\uffff\ufffe not chars.pdf",
        "line one\r\nFake second line\nthird.pdf",
        "evil\u202egnp.exe",
        "zero\u200bwidth\u200d\ufeff.pdf",
        "para\u2028sep\u2029.pdf",
        "{toast.binding}.pdf",
        "%TEMP%\\$(calc).pdf",
    };

    [Theory]
    [MemberData(nameof(Hostile))]
    public void A_hostile_document_name_makes_a_well_formed_toast_with_only_our_buttons(string name)
    {
        var n = Failed(name);
        var toast = XDocument.Parse(AlertToasts.Xml([n])).Root!;
        Assert.Equal(["Open the queue", "Pause alerts"], toast.Element("actions")!.Elements("action").Select(a => a.Attribute("content")!.Value));
        Assert.Equal($"queue:{Laser}", toast.Attribute("launch")!.Value);
        var texts = toast.Element("visual")!.Element("binding")!.Elements("text").ToList();
        Assert.Equal(3, texts.Count);
        Assert.Equal(n.Title, texts[0].Value);
        Assert.All(n.Title, c => Assert.False(char.IsControl(c) || c is '\u202e' or '\u200b' or '\u200d' or '\ufeff' or '\u2028' or '\u2029', $"U+{(int)c:X4} left in the title"));
        // No half a pair, whatever came in.
        for (var i = 0; i < n.Title.Length; i++)
            if (char.IsSurrogate(n.Title[i]))
            {
                Assert.True(char.IsHighSurrogate(n.Title[i]) && i + 1 < n.Title.Length && char.IsLowSurrogate(n.Title[i + 1]));
                i++;
            }
    }

    [Fact]
    public void Markup_shows_as_the_text_it_is()
    {
        var n = Failed("<b>Report</b> & co.pdf");
        Assert.Contains("<b>Report</b> & co.pdf", n.Title);
        Assert.Contains("<b>Report</b> &amp; co.pdf".Replace("<", "&lt;").Replace(">", "&gt;"), AlertToasts.Xml([n]));
    }

    [Fact]
    public void A_very_long_name_is_cut_to_fit_a_balloons_title()
    {
        var n = Failed(new string('x', 100_000) + ".pdf");
        Assert.True(n.Title.Length <= 63, n.Title);
        Assert.Contains("…", n.Title);
    }

    [Fact]
    public void Cutting_never_splits_a_character()
    {
        // Emoji (a surrogate pair) and an accent as its own mark, around the cut.
        foreach (var name in new[] { new string('a', AlertText.MaxDocument - 2) + "😀😀😀😀", new string('a', AlertText.MaxDocument - 2) + "e\u0301e\u0301e\u0301" })
        {
            var shown = AlertText.Document(name);
            Assert.True(shown.Length <= AlertText.MaxDocument);
            Assert.EndsWith("…", shown);
            Assert.False(char.IsHighSurrogate(shown[^2]));
            Assert.NotEqual('e', shown[^2]);
        }
    }

    [Theory]
    [InlineData(null, "Untitled")]
    [InlineData("", "Untitled")]
    [InlineData("    ", "Untitled")]
    [InlineData("\u0001\u0002\u200b", "Untitled")]
    [InlineData("Report.pdf", "Report.pdf")]
    [InlineData("  Two   spaces  .pdf ", "Two spaces .pdf")]
    [InlineData(@"C:\Users\gabri\Taxes\2026\return.pdf", "return.pdf")]
    [InlineData(@"\\server\share\Payroll\march.xlsx", "march.xlsx")]
    [InlineData("C:/Users/gabri/return.pdf", "return.pdf")]
    [InlineData("https://bank.example/statements/oct.pdf?token=abc123#page=2", "oct.pdf")]
    [InlineData("https://bank.example/", "bank.example")]
    [InlineData("Microsoft Word - Budget: draft/2.docx", "Microsoft Word - Budget: draft/2.docx")] // a title, not a path
    [InlineData("Ñandú año 2026.pdf", "Ñandú año 2026.pdf")]
    [InlineData("報告書.pdf", "報告書.pdf")]
    public void What_a_notification_calls_a_document(string? name, string shown) => Assert.Equal(shown, AlertText.Document(name));

    [Fact]
    public void A_hostile_printer_name_is_made_safe_too()
    {
        var n = Failed("Report.pdf", "Front\u0007 desk\r\n<inkjet>\u202e" + new string('y', 500));
        Assert.DoesNotContain(n.PrinterName, c => c is '\u0007' or '\r' or '\n' or '\u202e');
        Assert.True(n.PrinterName.Length <= AlertText.MaxPrinter);
        Assert.Equal(n.PrinterName, XDocument.Parse(AlertToasts.Xml([n])).Root!.Element("visual")!.Element("binding")!.Elements("text").Last().Value);
    }

    [Fact]
    public void A_printers_alert_with_a_control_character_in_its_name_still_makes_a_toast()
    {
        var notice = new AlertNotice("urn:uuid:a", "Bad\u0001name", AlertKind.PaperJam, "Paper\u0002 jam", "Clear\ud83d it.");
        Assert.Equal("Badname", XDocument.Parse(AlertToasts.Xml([notice])).Root!.Element("visual")!.Element("binding")!.Elements("text").Last().Value);
    }

    // ---------------------------------------------------------------- toasts

    private static AlertNotice JobNotice(string key, string title = "“Report.pdf” didn't print") =>
        new(Laser, PrinterName, AlertKind.JobFailed, title, $"{PrinterName}: Error.") { JobKey = key };

    private static readonly AlertNotice Jam = new(Laser, PrinterName, AlertKind.PaperJam, "Paper jam", "Clear it.");

    [Fact]
    public void A_job_gets_a_toast_of_its_own_beside_the_printers_alert_and_neither_replaces_the_other()
    {
        var a = JobNotice("Job|1|1");
        var b = JobNotice("Job|2|2");
        var toasts = AlertToasts.PerPrinter([a, Jam, b]);
        Assert.Equal(3, toasts.Count);
        Assert.Equal([Jam], toasts[0]);
        Assert.Equal([a], toasts[1]);
        Assert.Equal([b], toasts[2]);
        var tags = toasts.Select(AlertToasts.Tag).ToList();
        Assert.Equal(3, tags.Distinct().Count());
        Assert.All(tags, tag => Assert.InRange(tag.Length, 1, 16));
        Assert.Equal(AlertToasts.Tag(Laser), tags[0]); // the printer's tag as before
    }

    [Fact]
    public void Many_jobs_from_one_printer_at_once_share_a_toast()
    {
        var jobs = Enumerable.Range(1, 12).Select(i => JobNotice($"Job|{i}|{i}", $"“File {i}.pdf” didn't print")).ToList();
        var toast = Assert.Single(AlertToasts.PerPrinter(jobs));
        var (title, text) = AlertToasts.Text(toast);
        Assert.Equal("12 print jobs need attention", title);
        Assert.Equal(4, text.Split('\n').Length);
        Assert.Contains("and 9 more", text);
        var xml = XDocument.Parse(AlertToasts.Xml(toast)).Root!;
        Assert.Equal("Open the queue", xml.Element("actions")!.Elements("action").First().Attribute("content")!.Value);
        Assert.Equal(PrinterName, xml.Element("visual")!.Element("binding")!.Elements("text").Last().Value);
    }

    [Theory]
    [InlineData("queue:urn:uuid:aaaa-1", ToastAction.OpenQueue, "urn:uuid:aaaa-1")]
    [InlineData("open:urn:uuid:aaaa-1", ToastAction.OpenPrinter, "urn:uuid:aaaa-1")]
    public void A_clicks_arguments_say_open_the_queue(string arguments, ToastAction action, string uuid) =>
        Assert.Equal((action, uuid), AlertToasts.ParseArguments(arguments));

    [Fact]
    public void Queue_arguments_with_nothing_after_them_are_nothing() => Assert.Null(AlertToasts.ParseArguments("queue:"));

    [Fact]
    public void The_document_never_travels_in_a_toasts_arguments()
    {
        var n = Failed("Secret merger plan.pdf");
        var toast = XDocument.Parse(AlertToasts.Xml([n])).Root!;
        Assert.DoesNotContain("Secret", toast.Attribute("launch")!.Value);
        Assert.All(toast.Element("actions")!.Elements("action"), a => Assert.DoesNotContain("Secret", a.Attribute("arguments")!.Value));
        Assert.DoesNotContain("Secret", AlertToasts.Tag([n]));
        Assert.DoesNotContain("Secret", n.JobKey);
    }

    // ---------------------------------------------------------------- bits used by the reader

    [Fact]
    public void A_queue_reads_paused_and_use_printer_offline_from_the_spoolers_bits()
    {
        var q = new SpoolerQueue("Q", "USB001", null, SpoolerFlags.StatusPaused, SpoolerFlags.AttributeWorkOffline, 0);
        var state = JobQueueState.Of(q, []);
        Assert.True(state.Paused);
        Assert.True(state.WorkOffline);
        var running = JobQueueState.Of(new SpoolerQueue("Q", "USB001", null, 0, 0, 0), []);
        Assert.False(running.Paused);
        Assert.False(running.WorkOffline);
    }

    [Fact]
    public void A_job_key_is_the_same_whatever_the_time_zone_the_time_is_read_in()
    {
        var job = Job();
        Assert.Equal(JobRules.Key(job), JobRules.Key(job with { Submitted = job.Submitted.ToLocalTime() }));
        Assert.NotEqual(JobRules.Key(job), JobRules.Key(job with { Submitted = job.Submitted.AddMilliseconds(1) }));
        Assert.True(JobRules.IsKey(JobRules.Key(job)));
    }
}
