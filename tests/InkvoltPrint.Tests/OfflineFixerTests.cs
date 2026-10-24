using InkvoltPrint.Core.Offline;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

public class OfflineFixerTests
{
    private const string Uuid = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b";
    private const string OldIp = "192.0.2.12", NewIp = "192.0.2.23";
    private static readonly DateTime Now = new(2026, 10, 24, 12, 0, 0);

    private static OfflineDevice Device(string? host = OldIp) => new(Uuid, "Office laser", "Example Laser 400", host);

    private static QueueFacts TcpQueue(string name, string host, bool snmp = false) =>
        new(name, new QueuePort($"IP_{host}", PortKind.TcpIp) { Host = host, Snmp = snmp });

    private static QueueFacts PairedQueue(string name, string? container = Uuid) =>
        new(name, new QueuePort("WSD-0000", PortKind.DeviceId)) { ContainerId = container };

    private sealed class FakeProbes : IOfflineProbes
    {
        public SpoolerState Spooler = SpoolerState.Running;
        public Rediscovery? Found;
        public HashSet<string> Answering = new(StringComparer.OrdinalIgnoreCase);
        public List<QueueFacts> Queues = [];
        public int QueueReads;
        public List<string> Reached = [];
        public Exception? LookupFails;

        public Task<SpoolerState> SpoolerAsync(CancellationToken ct) => Task.FromResult(Spooler);

        public Task<Rediscovery?> RediscoverAsync(string uuid, CancellationToken ct) =>
            LookupFails is { } ex ? Task.FromException<Rediscovery?>(ex) : Task.FromResult(uuid == Uuid ? Found : null);

        public Task<Reachability> ReachAsync(string host, CancellationToken ct)
        {
            Reached.Add(host);
            return Task.FromResult(new Reachability(host, Answering.Contains(host), Answering.Contains(host) ? [631, 9100, 80] : []));
        }

        public Task<IReadOnlyList<QueueFacts>> QueuesAsync(CancellationToken ct)
        {
            QueueReads++;
            return Task.FromResult<IReadOnlyList<QueueFacts>>(Queues);
        }
    }

    private static Task<OfflineReport> Run(FakeProbes probes, OfflineDevice? device = null, IProgress<CheckResult>? progress = null) =>
        OfflineDiagnosis.RunAsync(device ?? Device(), probes, progress, Now);

    private static CheckResult Check(OfflineReport r, CheckKind kind) => r.Checks.Single(c => c.Kind == kind);

    [Fact]
    public async Task New_address_from_dhcp_points_the_tcpip_port_at_it()
    {
        var probes = new FakeProbes
        {
            Found = new Rediscovery(NewIp, "NPIEXAMPLE.local"),
            Answering = { NewIp },
            Queues = [TcpQueue("Office laser", OldIp), TcpQueue("Someone else's", "192.0.2.99")],
        };
        var report = await Run(probes);

        Assert.True(report.Moved);
        Assert.Equal(CheckState.Warning, Check(report, CheckKind.Network).State);
        Assert.Contains(NewIp, Check(report, CheckKind.Network).Detail);
        Assert.Equal(CheckState.Passed, Check(report, CheckKind.Connection).State);
        Assert.Equal(NewIp, Assert.Single(probes.Reached)); // the new address is the one tried
        var queue = Assert.Single(report.Queues);
        Assert.Equal(MatchReason.Address, queue.Reason);
        Assert.True(queue.PortIsStale);
        Assert.Equal(CheckState.Failed, Check(report, CheckKind.Queues).State);

        var point = report.Repairs[0];
        Assert.Equal(RepairKind.PointPortAt, point.Kind);
        Assert.Equal(NewIp, point.Target);
        Assert.Equal("Office laser", point.Queue);
        Assert.True(point.AdminOnly);
        Assert.False(point.IsAlternative);
        Assert.Null(point.Question); // matched by address: no doubt it's this printer
        Assert.Contains(point.ManualSteps, s => s.Contains(NewIp));
        var byName = report.Repairs[1];
        Assert.Equal(("NPIEXAMPLE.local", true), (byName.Target, byName.IsAlternative));
        Assert.Equal("Found one thing to fix", report.Headline);
    }

    [Fact]
    public async Task Each_step_reports_running_then_its_result_in_order()
    {
        var seen = new List<CheckResult>();
        var probes = new FakeProbes { Found = new Rediscovery(OldIp, null), Answering = { OldIp }, Queues = [PairedQueue("Office laser")] };
        var report = await Run(probes, progress: new SyncProgress(seen.Add));

        Assert.Equal(10, seen.Count);
        var kinds = Enum.GetValues<CheckKind>();
        for (var i = 0; i < kinds.Length; i++)
        {
            Assert.Equal((kinds[i], CheckState.Running), (seen[2 * i].Kind, seen[2 * i].State));
            Assert.Equal(kinds[i], seen[2 * i + 1].Kind);
            Assert.NotEqual(CheckState.Running, seen[2 * i + 1].State);
        }
        Assert.All(report.Checks, c => Assert.Equal(CheckState.Passed, c.State));
        Assert.Empty(report.Repairs);
        Assert.Equal("No problems found", report.Headline);
    }

    private sealed class SyncProgress(Action<CheckResult> report) : IProgress<CheckResult>
    {
        public void Report(CheckResult value) => report(value);
    }

    [Fact]
    public async Task Stopped_spooler_offers_only_starting_it_and_skips_the_queues()
    {
        var probes = new FakeProbes { Spooler = SpoolerState.Stopped, Answering = { OldIp } };
        var report = await Run(probes);

        Assert.Equal(0, probes.QueueReads);
        Assert.Equal(CheckState.Failed, Check(report, CheckKind.Spooler).State);
        Assert.Equal(CheckState.Skipped, Check(report, CheckKind.Queues).State);
        Assert.Equal(CheckState.Skipped, Check(report, CheckKind.QueueState).State);
        var start = Assert.Single(report.Repairs);
        Assert.Equal(RepairKind.StartSpooler, start.Kind);
        Assert.True(start.AdminOnly);
        Assert.Equal("The Print Spooler service isn't running", report.Headline);
    }

    [Fact]
    public async Task Paused_and_work_offline_queue_can_be_fixed_as_the_user()
    {
        var probes = new FakeProbes
        {
            Answering = { OldIp },
            Queues = [PairedQueue("Office laser") with { Paused = true, WorkOffline = true, ReportsOffline = true }],
        };
        var report = await Run(probes, Device() with { CanPair = true });

        Assert.Equal([RepairKind.ResumeQueue, RepairKind.ClearWorkOffline], report.Repairs.Select(r => r.Kind));
        Assert.All(report.Repairs, r => Assert.False(r.AdminOnly));
        Assert.Contains("paused", Check(report, CheckKind.QueueState).Detail);
        Assert.Contains("Use Printer Offline", Check(report, CheckKind.QueueState).Detail);
        Assert.Equal(CheckState.Failed, Check(report, CheckKind.QueueState).State);
        Assert.Equal(MatchReason.Container, report.Queues[0].Reason);
    }

    [Fact]
    public async Task Queue_matched_only_by_model_name_is_skipped_when_its_old_address_answers()
    {
        var probes = new FakeProbes
        {
            Found = new Rediscovery(NewIp, null),
            Answering = { NewIp, "192.0.2.50" },
            Queues = [TcpQueue("Example Laser 400 (upstairs)", "192.0.2.50"), TcpQueue("Example Laser 400", "192.0.2.51"), TcpQueue("Example Laser 4000", "192.0.2.52")],
        };
        var report = await Run(probes);

        var q = Assert.Single(report.Queues); // 400 (upstairs) answers at its own address; 4000 is another model
        Assert.Equal(("Example Laser 400", MatchReason.Name), (q.Queue.Name, q.Reason));
        Assert.Contains("matched by its name", Check(report, CheckKind.Queues).Detail);
        var point = Assert.Single(report.Repairs);
        Assert.NotNull(point.Question); // ask: same model name isn't proof
        Assert.Contains("192.0.2.51", point.Question);
    }

    [Fact]
    public async Task Previous_address_and_stored_queue_name_match_too()
    {
        var probes = new FakeProbes
        {
            Answering = { NewIp },
            Queues = [TcpQueue("Front desk", "192.0.2.5"), new QueueFacts("Made by Inkvolt", new QueuePort("http://192.0.2.6:631/ipp/print", PortKind.IppUrl)
                { Url = new Uri("http://192.0.2.6:631/ipp/print") })],
        };
        var device = Device(NewIp) with { PreviousHosts = ["192.0.2.5"], StoredQueueName = "made by inkvolt" };
        var report = await Run(probes, device);

        Assert.Equal([MatchReason.Address, MatchReason.Stored], report.Queues.Select(q => q.Reason));
        Assert.All(report.Queues, q => Assert.True(q.PortIsStale));
        Assert.Equal([RepairKind.PointPortAt, RepairKind.RecreateIppQueue], report.Repairs.Select(r => r.Kind));
        var ipp = report.Repairs[1];
        Assert.Equal($"http://{NewIp}:631/ipp/print", ipp.TargetUrl!.AbsoluteUri); // port and path kept
        Assert.True(ipp.AdminOnly);
    }

    [Fact]
    public async Task Printer_answers_but_windows_says_offline()
    {
        var probes = new FakeProbes
        {
            Answering = { OldIp },
            Queues = [PairedQueue("Paired") with { ReportsOffline = true }],
        };
        var paired = await Run(probes, Device() with { CanPair = true });
        var setUp = Assert.Single(paired.Repairs);
        Assert.Equal(RepairKind.SetUpAgain, setUp.Kind);
        Assert.NotNull(setUp.Question);
        Assert.Equal(CheckState.Warning, Check(paired, CheckKind.QueueState).State);

        probes.Queues = [TcpQueue("With SNMP", OldIp, snmp: true) with { ReportsOffline = true }];
        var snmp = Assert.Single((await Run(probes)).Repairs);
        Assert.Equal(RepairKind.TurnOffSnmp, snmp.Kind);
        Assert.True(snmp.ManualOnly);

        probes.Queues = [TcpQueue("Plain", OldIp) with { ReportsOffline = true }];
        Assert.Equal(RepairKind.RestartSpooler, Assert.Single((await Run(probes)).Repairs).Kind);
    }

    [Fact]
    public async Task Stuck_jobs_can_be_cancelled_or_restarted_and_long_cancelling_ones_need_the_spooler()
    {
        var probes = new FakeProbes
        {
            Answering = { OldIp },
            Queues =
            [
                PairedQueue("Office laser") with
                {
                    Jobs =
                    [
                        new QueueJob(7, "Report.pdf", 3, 0, JobStatus.Error | JobStatus.Printing, Now.AddMinutes(-20), "me"),
                        new QueueJob(8, "Label.pdf", 1, 0, JobStatus.None, Now.AddMinutes(-19), "me"),
                        new QueueJob(9, "Old.pdf", 1, 0, JobStatus.Deleting, Now.AddMinutes(-10), "me"),
                        new QueueJob(10, "Just cancelled.pdf", 1, 0, JobStatus.Deleting, Now.AddSeconds(-20), "me"),
                    ],
                },
            ],
        };
        var report = await Run(probes);

        Assert.Equal([RepairKind.CancelStuckJobs, RepairKind.RestartStuckJobs, RepairKind.RestartSpooler], report.Repairs.Select(r => r.Kind));
        Assert.Equal([7], report.Repairs[0].JobIds);
        Assert.Contains("Report.pdf", report.Repairs[0].Question);
        Assert.True(report.Repairs[1].IsAlternative);
        Assert.NotNull(report.Repairs[2].Question); // stops all printing: ask
        Assert.Contains("2 stuck jobs", Check(report, CheckKind.QueueState).Detail);
        Assert.Equal("Found 2 things to fix", report.Headline); // the restart-instead alternative isn't counted
    }

    [Fact]
    public async Task Printer_that_doesnt_answer_gets_no_port_change_and_plain_advice()
    {
        var probes = new FakeProbes { Queues = [TcpQueue("Office laser", OldIp)] };
        var report = await Run(probes);

        Assert.Equal(CheckState.Warning, Check(report, CheckKind.Network).State);
        Assert.Equal(CheckState.Failed, Check(report, CheckKind.Connection).State);
        Assert.False(report.Queues[0].PortIsStale);
        Assert.Empty(report.Repairs);
        Assert.Equal("The printer isn't answering", report.Headline);
        Assert.Contains("switched on", report.Advice);
    }

    [Fact]
    public async Task Ping_alone_is_not_the_printer_answering()
    {
        var probes = new PingOnly();
        var report = await OfflineDiagnosis.RunAsync(Device(), probes, null, Now);
        Assert.False(report.Answers);
        Assert.Contains("answers ping", Check(report, CheckKind.Connection).Detail);
    }

    private sealed class PingOnly : IOfflineProbes
    {
        public Task<SpoolerState> SpoolerAsync(CancellationToken ct) => Task.FromResult(SpoolerState.Running);
        public Task<Rediscovery?> RediscoverAsync(string uuid, CancellationToken ct) => Task.FromResult<Rediscovery?>(null);
        public Task<Reachability> ReachAsync(string host, CancellationToken ct) => Task.FromResult(new Reachability(host, true, []));
        public Task<IReadOnlyList<QueueFacts>> QueuesAsync(CancellationToken ct) => throw new InvalidOperationException("spooler busy");
    }

    [Fact]
    public async Task Failing_probes_become_warnings_not_exceptions()
    {
        var probes = new FakeProbes { LookupFails = new InvalidOperationException("watcher failed") };
        var report = await Run(probes);
        Assert.Contains("watcher failed", Check(report, CheckKind.Network).Detail);

        var noQueues = await OfflineDiagnosis.RunAsync(Device(), new PingOnly(), null, Now);
        Assert.Equal(CheckState.Warning, Check(noQueues, CheckKind.Queues).State);
        Assert.Contains("spooler busy", Check(noQueues, CheckKind.Queues).Detail);
    }

    [Fact]
    public async Task Cancellation_is_not_swallowed()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            OfflineDiagnosis.RunAsync(Device(), new CancelledProbes(), null, Now, cts.Token));
    }

    private sealed class CancelledProbes : IOfflineProbes
    {
        public Task<SpoolerState> SpoolerAsync(CancellationToken ct) => Task.FromCanceled<SpoolerState>(ct);
        public Task<Rediscovery?> RediscoverAsync(string uuid, CancellationToken ct) => Task.FromCanceled<Rediscovery?>(ct);
        public Task<Reachability> ReachAsync(string host, CancellationToken ct) => Task.FromCanceled<Reachability>(ct);
        public Task<IReadOnlyList<QueueFacts>> QueuesAsync(CancellationToken ct) => Task.FromCanceled<IReadOnlyList<QueueFacts>>(ct);
    }

    [Theory]
    [InlineData(PortKind.TcpIp, OldIp, NewIp, null, true)]
    [InlineData(PortKind.TcpIp, NewIp, NewIp, null, false)]
    [InlineData(PortKind.TcpIp, "npiexample.local", NewIp, "NPIEXAMPLE.local", false)] // already follows the printer
    [InlineData(PortKind.TcpIp, "printer.example.com", NewIp, null, false)]             // a DNS name may follow it too
    [InlineData(PortKind.TcpIp, OldIp, null, null, false)]                              // nowhere better to point it
    [InlineData(PortKind.DeviceId, null, NewIp, null, false)]
    public void Stale_ports(PortKind kind, string? host, string? address, string? hostName, bool stale) =>
        Assert.Equal(stale, OfflineDiagnosis.IsStale(new QueuePort("p", kind) { Host = host }, address, hostName));

    private sealed class FakeRepairs(AttemptResult asUser, AttemptResult elevated) : IOfflineRepairs
    {
        public int UserCalls, AdminCalls;

        public Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct)
        {
            UserCalls++;
            return Task.FromResult(new Attempt(asUser, "user said no"));
        }

        public Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct)
        {
            AdminCalls++;
            return Task.FromResult(new Attempt(elevated, "script failed"));
        }
    }

    private static readonly Repair Resume = new(RepairKind.ResumeQueue, "Resume", "") { Queue = "q", ManualSteps = ManualSteps.For(RepairKind.ResumeQueue, "q") };

    [Fact]
    public async Task Repairs_try_as_the_user_first_and_elevate_only_when_refused()
    {
        var ok = new FakeRepairs(AttemptResult.Done, AttemptResult.Done);
        Assert.Equal(RepairOutcomeKind.Fixed, (await RepairRunner.RunAsync(Resume, ok, canElevate: true)).Kind);
        Assert.Equal((1, 0), (ok.UserCalls, ok.AdminCalls));

        var denied = new FakeRepairs(AttemptResult.AccessDenied, AttemptResult.Done);
        Assert.Equal(RepairOutcomeKind.Fixed, (await RepairRunner.RunAsync(Resume, denied, canElevate: true)).Kind);
        Assert.Equal((1, 1), (denied.UserCalls, denied.AdminCalls));

        var failed = new FakeRepairs(AttemptResult.Failed, AttemptResult.Done);
        var outcome = await RepairRunner.RunAsync(Resume, failed, canElevate: true);
        Assert.Equal((RepairOutcomeKind.Failed, "user said no"), (outcome.Kind, outcome.Message));
        Assert.Equal(0, failed.AdminCalls); // a real failure isn't retried with more rights
    }

    [Fact]
    public async Task Packaged_copies_never_elevate_and_show_the_steps()
    {
        var denied = new FakeRepairs(AttemptResult.AccessDenied, AttemptResult.Done);
        var outcome = await RepairRunner.RunAsync(Resume, denied, canElevate: false);
        Assert.Equal(RepairOutcomeKind.Manual, outcome.Kind);
        Assert.Equal(Resume.ManualSteps, outcome.Steps);
        Assert.Equal(0, denied.AdminCalls);
        Assert.Contains("Microsoft Store", outcome.Message);
    }

    [Fact]
    public async Task Admin_only_and_manual_only_repairs()
    {
        var port = new Repair(RepairKind.PointPortAt, "Point", "") { AdminOnly = true, Target = NewIp };
        var r = new FakeRepairs(AttemptResult.Done, AttemptResult.Cancelled);
        var outcome = await RepairRunner.RunAsync(port, r, canElevate: true);
        Assert.Equal(RepairOutcomeKind.Cancelled, outcome.Kind);
        Assert.Equal((0, 1), (r.UserCalls, r.AdminCalls)); // ports always need an administrator: no pointless first try

        var snmp = new Repair(RepairKind.TurnOffSnmp, "SNMP", "") { ManualOnly = true, ManualSteps = ManualSteps.For(RepairKind.TurnOffSnmp, "q") };
        var none = new FakeRepairs(AttemptResult.Done, AttemptResult.Done);
        var manual = await RepairRunner.RunAsync(snmp, none, canElevate: true);
        Assert.Equal(RepairOutcomeKind.Manual, manual.Kind);
        Assert.Contains(manual.Steps, s => s.Contains("SNMP Status Enabled"));
        Assert.Equal((0, 0), (none.UserCalls, none.AdminCalls));
    }

    [Fact]
    public void Manual_steps_name_the_queue_and_target()
    {
        Assert.Contains(ManualSteps.For(RepairKind.PointPortAt, "Office laser", NewIp), s => s.Contains(NewIp));
        Assert.Contains(ManualSteps.For(RepairKind.ResumeQueue, "Office laser"), s => s.Contains("“Office laser”"));
        Assert.Contains(ManualSteps.For(RepairKind.RecreateIppQueue, "q", url: new Uri($"http://{NewIp}:631/ipp/print")), s => s.Contains($"http://{NewIp}:631/ipp/print"));
        Assert.All(Enum.GetValues<RepairKind>(), k => Assert.NotEmpty(ManualSteps.For(k, "q", NewIp)));
    }

    [Fact]
    public void Reachability_names_the_ports_that_answered()
    {
        Assert.Equal("IPP, raw printing (port 9100) and its web page", new Reachability(NewIp, true, [631, 9100, 80, 443]).PortsText);
        Assert.False(new Reachability(NewIp, true, []).Answers);
    }
}
