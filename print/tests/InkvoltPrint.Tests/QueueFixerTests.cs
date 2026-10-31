using InkvoltPrint.Core.Offline;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

/// <summary>
/// The offline fixer on a printer known only by its Windows queue (roadmap 2.6): the spooler, that one queue, its state; no
/// network step, no port repair, and nothing done to any other queue.
/// </summary>
public class QueueFixerTests
{
    private const string Name = "Example USB laser";
    private static readonly DateTime Now = new(2026, 10, 31, 12, 0, 0);

    private static OfflineDevice Device(string queue = Name) => OfflineDevice.ForQueue(queue, queue, "Example Laser 2100");

    private static QueueFacts Queue(string name = Name) => new(name, new QueuePort("USB001", PortKind.Other));

    private static QueueJob Job(int id, JobStatus status, string name = "Report.pdf", int minutesAgo = 10) =>
        new(id, name, 2, 0, status, Now.AddMinutes(-minutesAgo), "someone");

    /// <summary>Fails the test if the fixer takes a network step.</summary>
    private sealed class FakeProbes(params QueueFacts[] queues) : IOfflineProbes
    {
        public SpoolerState Spooler = SpoolerState.Running;
        public Exception? ReadFails;
        public bool Hangs;
        public List<string> Asked = [];

        public Task<SpoolerState> SpoolerAsync(CancellationToken ct) => Task.FromResult(Spooler);

        public Task<Rediscovery?> RediscoverAsync(string uuid, CancellationToken ct) => throw new InvalidOperationException("no network step on a queue printer");

        public Task<Reachability> ReachAsync(string host, CancellationToken ct) => throw new InvalidOperationException("no network step on a queue printer");

        public async Task<IReadOnlyList<QueueFacts>> QueuesAsync(CancellationToken ct)
        {
            Asked.Add("all");
            if (Hangs) await new TaskCompletionSource().Task; // never answers, and takes no notice of a cancel
            if (ReadFails is { } ex) throw ex;
            return queues;
        }
    }

    private static Task<OfflineReport> Run(FakeProbes probes, OfflineDevice? device = null, IProgress<CheckResult>? progress = null) =>
        OfflineDiagnosis.RunAsync(device ?? Device(), probes, progress, Now);

    private sealed class Immediately(List<CheckResult> seen) : IProgress<CheckResult>
    {
        public void Report(CheckResult value) => seen.Add(value);
    }

    [Fact]
    public async Task The_diagnosis_runs_spooler_then_the_queue_then_its_state_with_no_network_step()
    {
        var seen = new List<CheckResult>();
        var report = await Run(new FakeProbes(Queue() with { Paused = true }), progress: new Immediately(seen));

        Assert.Equal(
        [
            (CheckKind.Spooler, CheckState.Running), (CheckKind.Spooler, CheckState.Passed),
            (CheckKind.Queues, CheckState.Running), (CheckKind.Queues, CheckState.Passed),
            (CheckKind.QueueState, CheckState.Running), (CheckKind.QueueState, CheckState.Failed),
        ], seen.Select(c => (c.Kind, c.State)));
        Assert.Equal([CheckKind.Spooler, CheckKind.Queues, CheckKind.QueueState], report.Checks.Select(c => c.Kind));
        Assert.Null(report.Found);
        Assert.Null(report.Reach);
        Assert.Equal(AdoptDecision.None, report.Adoption);
    }

    [Fact]
    public async Task A_stopped_spooler_comes_first_and_leaves_the_queue_alone()
    {
        var probes = new FakeProbes(Queue() with { Paused = true }) { Spooler = SpoolerState.Stopped };
        var report = await Run(probes);

        Assert.Empty(probes.Asked);
        var repair = Assert.Single(report.Repairs);
        Assert.Equal(RepairKind.StartSpooler, repair.Kind);
        Assert.Equal(CheckState.Skipped, report.Checks.Single(c => c.Kind == CheckKind.Queues).State);
        Assert.Equal("The Print Spooler service isn't running", report.Headline);
    }

    [Fact]
    public async Task Repairs_come_in_the_fixers_order_each_with_a_question()
    {
        var queue = Queue() with { Paused = true, WorkOffline = true, Jobs = [Job(7, JobStatus.Error)] };
        var report = await Run(new FakeProbes(queue));

        Assert.Equal([RepairKind.ResumeQueue, RepairKind.ClearWorkOffline, RepairKind.CancelStuckJobs, RepairKind.RestartStuckJobs],
            report.Repairs.Select(r => r.Kind));
        Assert.All(report.Repairs, r => Assert.Equal(Name, r.Queue));
        Assert.All(report.Repairs, r => Assert.Contains(Name, r.Question));
        Assert.True(report.Repairs[3].IsAlternative);
        Assert.Equal("Found 3 things to fix", report.Headline);
    }

    [Fact]
    public async Task Only_resuming_and_turning_off_use_printer_offline_count_as_safe()
    {
        var queue = Queue() with { Paused = true, WorkOffline = true, Jobs = [Job(7, JobStatus.Error), Job(8, JobStatus.Deleting)] };
        var report = await Run(new FakeProbes(queue));

        Assert.Equal([RepairKind.ResumeQueue, RepairKind.ClearWorkOffline], report.Repairs.Where(r => r.IsSafe).Select(r => r.Kind));
        Assert.Contains(report.Repairs, r => r.Kind == RepairKind.RestartSpooler); // a job stuck cancelling: found, not safe
    }

    [Theory]
    [InlineData("Example USB laser 2")]        // the name starts the same
    [InlineData("Example")]
    [InlineData("Example Laser 2100")]         // the driver's model: the network fixer's by-name match would take it
    [InlineData("Example Laser 2100 PCL6")]
    public async Task No_other_queue_is_matched_or_repaired(string other)
    {
        var report = await Run(new FakeProbes(Queue(other) with { Paused = true }, Queue() with { WorkOffline = true }));

        var matched = Assert.Single(report.Queues);
        Assert.Equal(Name, matched.Queue.Name);
        Assert.All(report.Repairs, r => Assert.Equal(Name, r.Queue));
        Assert.DoesNotContain(report.Repairs, r => r.Kind == RepairKind.ResumeQueue);
    }

    [Fact]
    public async Task A_queue_windows_no_longer_has_says_so_and_offers_nothing()
    {
        var report = await Run(new FakeProbes(Queue("Another printer") with { Paused = true }));

        Assert.Empty(report.Repairs);
        Assert.Empty(report.Queues);
        Assert.Equal(CheckState.Failed, report.Checks.Single(c => c.Kind == CheckKind.Queues).State);
        Assert.Contains("no longer", report.Headline);
        Assert.DoesNotContain("Set up", report.Advice);
    }

    [Fact]
    public async Task A_queue_that_cant_be_read_is_not_called_gone()
    {
        var report = await Run(new FakeProbes(Queue()) { ReadFails = new InvalidOperationException("RPC server unavailable") });

        Assert.Empty(report.Repairs);
        var check = report.Checks.Single(c => c.Kind == CheckKind.Queues);
        Assert.Equal(CheckState.Warning, check.State);
        Assert.Contains("RPC server unavailable", check.Detail);
        Assert.DoesNotContain("no longer", report.Headline);
    }

    [Fact]
    public async Task A_read_that_hangs_ends_with_a_warning_instead_of_holding_the_fixer()
    {
        var limit = OfflineDiagnosis.QueueReadLimit;
        var read = OfflineDiagnosis.RunAsync(Device(), new FakeProbes(Queue()) { Hangs = true }, null, Now, queueReadLimit: TimeSpan.FromMilliseconds(100));

        var report = await read.WaitAsync(TimeSpan.FromSeconds(15));

        Assert.True(limit >= TimeSpan.FromSeconds(5));
        Assert.Empty(report.Repairs);
        Assert.Equal(CheckState.Warning, report.Checks.Single(c => c.Kind == CheckKind.Queues).State);
    }

    [Fact]
    public async Task Windows_showing_it_offline_is_a_warning_and_points_at_the_printer_not_the_network()
    {
        var report = await Run(new FakeProbes(Queue() with { ReportsOffline = true }), Device() with { CanPair = true });

        Assert.Empty(report.Repairs); // no set up again, no port repair
        Assert.Equal(CheckState.Warning, report.Checks.Single(c => c.Kind == CheckKind.QueueState).State);
        Assert.Equal("Windows shows this printer offline", report.Headline);
        Assert.Contains("turned on", report.Advice);
    }

    [Fact]
    public async Task A_healthy_queue_has_nothing_to_fix()
    {
        var report = await Run(new FakeProbes(Queue()));

        Assert.Empty(report.Repairs);
        Assert.Equal("No problems found", report.Headline);
        Assert.DoesNotContain("answers", report.Advice);
    }

    [Fact]
    public async Task A_job_stuck_cancelling_offers_restarting_the_spooler_with_a_question()
    {
        var report = await Run(new FakeProbes(Queue() with { Jobs = [Job(9, JobStatus.Deleting, minutesAgo: 30)] }));

        var repair = Assert.Single(report.Repairs);
        Assert.Equal(RepairKind.RestartSpooler, repair.Kind);
        Assert.NotNull(repair.Question);
    }

    // ------------------------------------------------------------------ shared from another PC

    private const string Shared = @"\\front-desk\Laser";

    private sealed class FakeRepairs : IOfflineRepairs
    {
        public AttemptResult AsUser = AttemptResult.AccessDenied;
        public List<string> Calls = [];

        public Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct)
        {
            Calls.Add($"user:{repair.Kind}:{repair.Queue}");
            return Task.FromResult(new Attempt(AsUser));
        }

        public Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct)
        {
            Calls.Add($"admin:{repair.Kind}:{repair.Queue}");
            return Task.FromResult(Attempt.Done);
        }
    }

    [Fact]
    public async Task A_printer_shared_from_another_pc_is_never_elevated_here()
    {
        var report = await Run(new FakeProbes(Queue(Shared) with { Paused = true }), Device(Shared));
        var repair = Assert.Single(report.Repairs);
        var repairs = new FakeRepairs();

        var outcome = await RepairRunner.RunAsync(repair, repairs, canElevate: true);

        Assert.Equal([$"user:ResumeQueue:{Shared}"], repairs.Calls); // an administrator of this PC is nobody on the other one
        Assert.Equal(RepairOutcomeKind.Manual, outcome.Kind);
        Assert.Contains("PC sharing", outcome.Message);
        Assert.NotEmpty(outcome.Steps);
    }

    [Fact]
    public async Task A_local_queue_refused_as_the_user_asks_for_permission_only_when_it_may()
    {
        var report = await Run(new FakeProbes(Queue() with { Paused = true }));
        var repair = Assert.Single(report.Repairs);

        var elevates = new FakeRepairs();
        Assert.Equal(RepairOutcomeKind.Fixed, (await RepairRunner.RunAsync(repair, elevates, canElevate: true)).Kind);
        Assert.Equal([$"user:ResumeQueue:{Name}", $"admin:ResumeQueue:{Name}"], elevates.Calls);

        var store = new FakeRepairs();
        var outcome = await RepairRunner.RunAsync(repair, store, canElevate: false);
        Assert.Equal(RepairOutcomeKind.Manual, outcome.Kind);
        Assert.Equal([$"user:ResumeQueue:{Name}"], store.Calls);
    }
}
