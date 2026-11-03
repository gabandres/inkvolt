using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Core.Offline;

/// <summary>Everything the fixer found, and what it can repair.</summary>
public sealed record OfflineReport(
    OfflineDevice Device,
    SpoolerState Spooler,
    Rediscovery? Found,
    Reachability? Reach,
    IReadOnlyList<CheckResult> Checks,
    IReadOnlyList<MatchedQueue> Queues,
    IReadOnlyList<Repair> Repairs)
{
    /// <summary>mDNS found the printer at a different address than the one Inkvolt Print had.</summary>
    public bool Moved => Found is not null && !string.Equals(Found.Address, Device.Host, StringComparison.OrdinalIgnoreCase);

    /// <summary>The printer moved, but something still answers at the address Inkvolt Print had (another device took it, or this isn't the printer that moved).</summary>
    public bool OldAddressAnswers { get; init; }

    /// <summary>
    /// What to do with the new address: nothing (it didn't move), use it, or ask first. The UUID mDNS answered for is
    /// public, so when more than one device announces it, or the old address still answers, the user decides.
    /// </summary>
    public AdoptDecision Adoption => !Moved ? AdoptDecision.None
        : Found!.IsAmbiguous || OldAddressAnswers ? AdoptDecision.Ask
        : AdoptDecision.Adopt;

    /// <summary>The question for <see cref="AdoptDecision.Ask"/>.</summary>
    public string? AdoptionQuestion => Adoption == AdoptDecision.Ask
        ? OfflineDiagnosis.Caution(this) + string.Format(CoreStrings.Offline_AdoptQuestion, Found!.Address, Device.Name)
        : null;

    public bool Answers => Reach?.Answers == true;

    /// <summary>A queue printer's queue wasn't among Windows' printers: it was removed or renamed (not merely unreadable).</summary>
    public bool QueueGone { get; init; }

    /// <summary>A queue printer's queue couldn't be read this time.</summary>
    public bool QueueUnread { get; init; }

    public string Headline => Spooler == SpoolerState.Stopped ? CoreStrings.Offline_SpoolerStopped
        : Repairs.Count(r => !r.IsAlternative) is var n and > 0 ? Plural.Of(n, CoreStrings.Offline_FoundToFix_One, CoreStrings.Offline_FoundToFix_Many)
        : Device.QueueOnly ? QueueHeadline
        : !Answers ? CoreStrings.Offline_NotAnswering
        : Queues.Count == 0 ? CoreStrings.Offline_NoWindowsPrinter
        : CoreStrings.Offline_NoProblems;

    private string QueueHeadline => QueueGone ? CoreStrings.Offline_QueueGoneHeadline
        : QueueUnread ? CoreStrings.Offline_QueueUnreadHeadline
        : Queues.Any(m => m.Queue.ReportsOffline) ? CoreStrings.Offline_QueueOfflineHeadline
        : Queues.Any(m => m.Queue.ReportsError) ? CoreStrings.Offline_QueueErrorHeadline
        : CoreStrings.Offline_NoProblems;

    private string QueueAdvice => Repairs.Count > 0 ? CoreStrings.Offline_FixEach
        : QueueGone ? CoreStrings.Offline_QueueGoneAdvice
        : QueueUnread ? CoreStrings.Offline_QueueUnreadAdvice
        : Queues.Any(m => m.Queue.ReportsOffline || m.Queue.ReportsError)
            ? CoreStrings.Offline_QueueOfflineAdvice
            : CoreStrings.Offline_QueueReadyAdvice;

    public string Advice => Spooler == SpoolerState.Stopped ? CoreStrings.Offline_SpoolerStoppedAdvice
        : Device.QueueOnly ? QueueAdvice
        : Repairs.Count > 0 && Answers ? CoreStrings.Offline_FixEach
        : Repairs.Count > 0 ? CoreStrings.Offline_FixListedNotAnswering
        : !Answers ? CoreStrings.Offline_NotAnsweringAdvice
        : Queues.Count == 0 ? CoreStrings.Offline_SetUpAdvice
        : CoreStrings.Offline_AllReadyAdvice;
}

public enum AdoptDecision { None, Adopt, Ask }

/// <summary>
/// The "printer offline" fixer's diagnosis, step by step: the Print Spooler service; a fresh mDNS look-up by UUID (DHCP
/// often hands the printer a new address); whether it answers there; which Windows queues print to it and where their
/// ports point; whether those queues are paused, set to "Use Printer Offline" or hold stuck jobs. Each step is reported
/// as it starts and ends, then the repairs are planned from what was found (<see cref="Plan"/>).
/// </summary>
public static class OfflineDiagnosis
{
    /// <summary>A job still "cancelling" after this long is stuck in the spooler; only restarting the spooler clears it.</summary>
    public static readonly TimeSpan StuckDeleting = TimeSpan.FromMinutes(2);

    /// <summary>How long a queue printer's fixer waits for Windows to say how the queue is: a print server that's off makes it wait far longer.</summary>
    public static readonly TimeSpan QueueReadLimit = TimeSpan.FromSeconds(10);

    /// <summary>The steps a printer's diagnosis has, in order: a queue printer has no network steps.</summary>
    public static IReadOnlyList<CheckKind> StepsFor(OfflineDevice device) =>
        device.QueueOnly ? [CheckKind.Spooler, CheckKind.Queues, CheckKind.QueueState] : Enum.GetValues<CheckKind>();

    public static async Task<OfflineReport> RunAsync(OfflineDevice device, IOfflineProbes probes, IProgress<CheckResult>? progress = null,
        DateTime? now = null, CancellationToken ct = default, TimeSpan? queueReadLimit = null)
    {
        if (device.QueueOnly) return await RunQueueAsync(device, probes, progress, now ?? DateTime.Now, queueReadLimit ?? QueueReadLimit, ct).ConfigureAwait(false);

        var checks = new Dictionary<CheckKind, CheckResult>();
        void Report(CheckResult r)
        {
            checks[r.Kind] = r;
            progress?.Report(r);
        }
        void Start(CheckKind kind) => Report(new(kind, CheckState.Running, CheckResult.TitleOf(kind)));

        // 1. Windows' printing service: without it nothing else on the Windows side can be read or fixed.
        Start(CheckKind.Spooler);
        var spooler = await Probe(() => probes.SpoolerAsync(ct), SpoolerState.Unknown, ct).ConfigureAwait(false);
        Report(SpoolerCheck(spooler));

        // 2. Where is it now? mDNS by UUID, since the router may have given it a new address.
        Start(CheckKind.Network);
        Rediscovery? found = null;
        string? lookupError = null;
        try { found = (await probes.RediscoverAsync(device.Uuid, ct).ConfigureAwait(false))?.Cleaned(); }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { lookupError = ex.Message; }
        // Moved: does anything still answer at the old address? Then the new one isn't used without asking.
        var oldAnswers = false;
        if (found is not null && device.Host is { } oldHost && !string.Equals(found.Address, oldHost, StringComparison.OrdinalIgnoreCase))
            oldAnswers = (await Probe(() => probes.ReachAsync(oldHost, ct), new Reachability(oldHost, false, []), ct).ConfigureAwait(false)).Answers;
        Report(NetworkCheck(device, found, oldAnswers, lookupError));

        // 3. Does it answer there?
        var address = found?.Address ?? device.Host;
        Reachability? reach = null;
        if (address is null)
        {
            Report(new(CheckKind.Connection, CheckState.Skipped, CheckResult.TitleOf(CheckKind.Connection), CoreStrings.Offline_AddressUnknown));
        }
        else
        {
            Start(CheckKind.Connection);
            reach = await Probe(() => probes.ReachAsync(address, ct), new Reachability(address, false, []), ct).ConfigureAwait(false);
            Report(ConnectionCheck(reach));
        }

        // 4 and 5. Windows' queues for it, and their state.
        IReadOnlyList<MatchedQueue> matched = [];
        if (spooler == SpoolerState.Stopped)
        {
            var why = CoreStrings.Offline_NeedsSpooler;
            Report(new(CheckKind.Queues, CheckState.Skipped, CheckResult.TitleOf(CheckKind.Queues), why));
            Report(new(CheckKind.QueueState, CheckState.Skipped, CheckResult.TitleOf(CheckKind.QueueState), why));
        }
        else
        {
            Start(CheckKind.Queues);
            IReadOnlyList<QueueFacts>? queues = null;
            string? queueError = null;
            try { queues = await probes.QueuesAsync(ct).ConfigureAwait(false); }
            catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { queueError = ex.Message; }
            if (queues is null)
            {
                Report(new(CheckKind.Queues, CheckState.Warning, CheckResult.TitleOf(CheckKind.Queues), string.Format(CoreStrings.Offline_CouldntReadPrinters, queueError)));
                Report(new(CheckKind.QueueState, CheckState.Skipped, CheckResult.TitleOf(CheckKind.QueueState)));
            }
            else
            {
                matched = await MatchAsync(device, found, address, queues, probes, ct).ConfigureAwait(false);
                Report(QueuesCheck(matched));
                Start(CheckKind.QueueState);
                Report(QueueStateCheck(matched, now ?? DateTime.Now));
            }
        }

        var caution = Caution(device, found, oldAnswers);
        var repairs = Plan(device, spooler, found, reach, matched, now ?? DateTime.Now, caution.Length > 0 ? caution : null);
        var ordered = Enum.GetValues<CheckKind>().Select(k => checks.GetValueOrDefault(k) ?? CheckResult.Waiting(k)).ToList();
        return new OfflineReport(device, spooler, found, reach, ordered, matched, repairs) { OldAddressAnswers = oldAnswers };
    }

    /// <summary>
    /// A printer known only by its Windows queue: the Print Spooler service, then that queue by its exact name (never another
    /// queue of the same model), then whether it's paused, set to "Use Printer Offline" or holds stuck jobs. Windows' answers are
    /// waited for only so long: a queue that doesn't answer reads as unknown, not as gone.
    /// </summary>
    private static async Task<OfflineReport> RunQueueAsync(OfflineDevice device, IOfflineProbes probes, IProgress<CheckResult>? progress, DateTime now,
        TimeSpan limit, CancellationToken ct)
    {
        var queueName = device.StoredQueueName ?? throw new ArgumentException("A queue printer has a queue name.", nameof(device));
        var checks = new Dictionary<CheckKind, CheckResult>();
        void Report(CheckResult r)
        {
            checks[r.Kind] = r;
            progress?.Report(r);
        }
        void Start(CheckKind kind) => Report(new(kind, CheckState.Running, CheckResult.TitleOf(kind)));

        Start(CheckKind.Spooler);
        var spooler = await Probe(() => probes.SpoolerAsync(ct).WaitAsync(limit, ct), SpoolerState.Unknown, ct).ConfigureAwait(false);
        Report(SpoolerCheck(spooler));

        IReadOnlyList<MatchedQueue> matched = [];
        bool gone = false, unread = false;
        if (spooler == SpoolerState.Stopped)
        {
            var why = CoreStrings.Offline_NeedsSpooler;
            Report(new(CheckKind.Queues, CheckState.Skipped, CheckResult.TitleOf(CheckKind.Queues), why));
            Report(new(CheckKind.QueueState, CheckState.Skipped, CheckResult.TitleOf(CheckKind.QueueState), why));
        }
        else
        {
            Start(CheckKind.Queues);
            QueueFacts? queue = null;
            string? error = null;
            try { queue = await probes.QueueAsync(queueName, ct).WaitAsync(limit, ct).ConfigureAwait(false); }
            catch (TimeoutException) { error = CoreStrings.Offline_WindowsNoAnswer; }
            catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { error = ex.Message; }
            if (error is not null)
            {
                unread = true;
                Report(new(CheckKind.Queues, CheckState.Warning, CheckResult.TitleOf(CheckKind.Queues), string.Format(CoreStrings.Offline_CouldntReadQueue, queueName, error)));
                Report(new(CheckKind.QueueState, CheckState.Skipped, CheckResult.TitleOf(CheckKind.QueueState)));
            }
            else if (queue is null)
            {
                gone = true;
                Report(new(CheckKind.Queues, CheckState.Failed, CheckResult.TitleOf(CheckKind.Queues), string.Format(CoreStrings.Offline_QueueGone, queueName)));
                Report(new(CheckKind.QueueState, CheckState.Skipped, CheckResult.TitleOf(CheckKind.QueueState)));
            }
            else
            {
                matched = [new MatchedQueue(queue, MatchReason.Stored, PortIsStale: false)];
                Report(QueuesCheck(matched));
                Start(CheckKind.QueueState);
                Report(QueueStateCheck(matched, now));
            }
        }

        var repairs = Plan(device, spooler, null, null, matched, now);
        var ordered = StepsFor(device).Select(k => checks.GetValueOrDefault(k) ?? CheckResult.Waiting(k)).ToList();
        return new OfflineReport(device, spooler, null, null, ordered, matched, repairs) { QueueGone = gone, QueueUnread = unread };
    }

    internal static string Caution(OfflineReport r) => Caution(r.Device, r.Found, r.OldAddressAnswers);

    /// <summary>Why the new address isn't certain ("" when it is), as the start of a question.</summary>
    private static string Caution(OfflineDevice device, Rediscovery? found, bool oldAnswers)
    {
        if (found is null) return "";
        var parts = "";
        if (found.IsAmbiguous)
            parts += string.Format(CoreStrings.Offline_CautionAmbiguous, Reachability.Join(found.Addresses.Distinct(StringComparer.OrdinalIgnoreCase).ToList())) + " ";
        if (oldAnswers) parts += string.Format(CoreStrings.Offline_CautionOldAnswers, device.Host) + " ";
        return parts;
    }

    private static async Task<T> Probe<T>(Func<Task<T>> probe, T fallback, CancellationToken ct)
    {
        try { return await probe().ConfigureAwait(false); }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { return fallback; }
    }

    private static CheckResult SpoolerCheck(SpoolerState s) => new(CheckKind.Spooler, s switch
    {
        SpoolerState.Running => CheckState.Passed,
        SpoolerState.Stopped => CheckState.Failed,
        _ => CheckState.Warning,
    }, CheckResult.TitleOf(CheckKind.Spooler), s switch
    {
        SpoolerState.Running => CoreStrings.Offline_SpoolerRunning,
        SpoolerState.Stopped => CoreStrings.Offline_SpoolerStoppedDetail,
        SpoolerState.Changing => CoreStrings.Offline_SpoolerChanging,
        _ => CoreStrings.Offline_CouldntCheck,
    });

    private static CheckResult NetworkCheck(OfflineDevice device, Rediscovery? found, bool oldAnswers, string? error)
    {
        var title = CheckResult.TitleOf(CheckKind.Network);
        if (found is null)
            return new(CheckKind.Network, CheckState.Warning, title, error is not null
                ? string.Format(CoreStrings.Offline_CouldntLook, error)
                : CoreStrings.Offline_NotAnnounced);
        if (device.Host is null || string.Equals(found.Address, device.Host, StringComparison.OrdinalIgnoreCase))
            return new(CheckKind.Network, CheckState.Passed, title, string.Format(CoreStrings.Offline_FoundSame, found.Address));
        var caution = Caution(device, found, oldAnswers);
        if (caution.Length > 0)
            return new(CheckKind.Network, CheckState.Warning, title,
                string.Format(CoreStrings.Offline_FoundAsk, found.Address, device.Host, caution));
        return new(CheckKind.Network, CheckState.Warning, title,
            string.Format(CoreStrings.Offline_FoundNew, found.Address, device.Host));
    }

    private static CheckResult ConnectionCheck(Reachability r)
    {
        var title = CheckResult.TitleOf(CheckKind.Connection);
        if (r.Answers) return new(CheckKind.Connection, CheckState.Passed, title, string.Format(CoreStrings.Offline_AnswersAt, r.Host, r.PortsText));
        if (r.Ping)
            return new(CheckKind.Connection, CheckState.Failed, title,
                string.Format(CoreStrings.Offline_PingOnly, r.Host));
        return new(CheckKind.Connection, CheckState.Failed, title,
            string.Format(CoreStrings.Offline_NoAnswerAt, r.Host));
    }

    private static CheckResult QueuesCheck(IReadOnlyList<MatchedQueue> matched)
    {
        var title = CheckResult.TitleOf(CheckKind.Queues);
        if (matched.Count == 0)
            return new(CheckKind.Queues, CheckState.Warning, title, CoreStrings.Offline_NoQueues);
        var lines = matched.Select(m => string.Format((m.PortIsStale, m.Reason == MatchReason.Name) switch
        {
            (false, false) => CoreStrings.Offline_QueueLine,
            (true, false) => CoreStrings.Offline_QueueLineStale,
            (false, true) => CoreStrings.Offline_QueueLineByName,
            (true, true) => CoreStrings.Offline_QueueLineStaleByName,
        }, m.Queue.Name, m.PortText));
        return new(CheckKind.Queues, matched.Any(m => m.PortIsStale) ? CheckState.Failed : CheckState.Passed, title, string.Join("\n", lines));
    }

    private static CheckResult QueueStateCheck(IReadOnlyList<MatchedQueue> matched, DateTime now)
    {
        var title = CheckResult.TitleOf(CheckKind.QueueState);
        if (matched.Count == 0) return new(CheckKind.QueueState, CheckState.Skipped, title, CoreStrings.Offline_NoQueueToCheck);
        var lines = new List<string>();
        var failed = false;
        foreach (var m in matched)
        {
            var q = m.Queue;
            var problems = new List<string>();
            if (q.Paused) problems.Add(CoreStrings.Offline_ProblemPaused);
            if (q.WorkOffline) problems.Add(CoreStrings.Offline_ProblemWorkOffline);
            var stuck = StuckJobs(q).Count + DeletingJobs(q, now).Count;
            if (stuck > 0) problems.Add(Plural.Of(stuck, CoreStrings.Offline_ProblemStuck_One, CoreStrings.Offline_ProblemStuck_Many));
            failed |= problems.Count > 0;
            if (q.ReportsOffline && !q.WorkOffline) problems.Add(CoreStrings.Offline_ProblemShowsOffline);
            else if (q.ReportsError) problems.Add(CoreStrings.Offline_ProblemShowsError);
            if (problems.Count > 0) lines.Add(string.Format(CoreStrings.Offline_QueueProblems, q.Name, Reachability.Join(problems)));
        }
        if (lines.Count == 0) return new(CheckKind.QueueState, CheckState.Passed, title, CoreStrings.Offline_QueueStateOk);
        return new(CheckKind.QueueState, failed ? CheckState.Failed : CheckState.Warning, title, string.Join("\n", lines));
    }

    /// <summary>
    /// The queues that print to this printer, in order of certainty: its PnP container is the printer's UUID; it's the
    /// queue Inkvolt Print stored for it; its port's host is one of the printer's addresses (current, new or earlier) or
    /// its network name; finally a TCP/IP or IPP-URL queue whose name starts with the printer's model or name, unless its
    /// port points at an address where something else answers (then it's another printer of the same model).
    /// </summary>
    internal static async Task<IReadOnlyList<MatchedQueue>> MatchAsync(OfflineDevice device, Rediscovery? found, string? address,
        IReadOnlyList<QueueFacts> queues, IOfflineProbes probes, CancellationToken ct)
    {
        var uuid = NormalizeUuid(device.Uuid);
        var hosts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var h in new[] { device.Host, found?.Address, found?.HostName }.Concat(device.PreviousHosts))
            if (h is { Length: > 0 }) hosts.Add(h);

        var result = new List<MatchedQueue>();
        foreach (var q in queues)
        {
            var host = PortHost(q.Port);
            MatchReason? reason =
                uuid is not null && NormalizeUuid(q.ContainerId) == uuid ? MatchReason.Container
                : device.StoredQueueName is { } stored && string.Equals(stored, q.Name, StringComparison.OrdinalIgnoreCase) ? MatchReason.Stored
                : host is not null && hosts.Contains(host) ? MatchReason.Address
                : q.Port.Kind is PortKind.TcpIp or PortKind.IppUrl && (StartsWithWord(q.Name, device.Model) || StartsWithWord(q.Name, device.Name))
                    ? MatchReason.Name
                : null;
            if (reason is not { } r) continue;
            var stale = IsStale(q.Port, address, found?.HostName);
            if (r == MatchReason.Name && stale && host is not null)
            {
                // Same model name, another address: only ours if nothing answers there.
                var there = await Probe(() => probes.ReachAsync(host, ct), new Reachability(host, false, []), ct).ConfigureAwait(false);
                if (there.Answers) continue;
            }
            result.Add(new MatchedQueue(q, r, stale));
        }
        return result;
    }

    /// <summary>
    /// The queues known to print to this printer, asking nothing of the network: <see cref="MatchAsync"/> without its match by
    /// name, which only a look at the address could settle. For repairs made without looking at each printer in turn (Fix all).
    /// </summary>
    public static IReadOnlyList<MatchedQueue> OwnQueues(OfflineDevice device, IReadOnlyList<QueueFacts> queues)
    {
        var uuid = NormalizeUuid(device.Uuid);
        var hosts = new HashSet<string>(device.PreviousHosts, StringComparer.OrdinalIgnoreCase);
        if (device.Host is { Length: > 0 } now) hosts.Add(now);
        var result = new List<MatchedQueue>();
        foreach (var q in queues)
        {
            MatchReason? reason =
                uuid is not null && NormalizeUuid(q.ContainerId) == uuid ? MatchReason.Container
                : device.StoredQueueName is { } stored && string.Equals(stored, q.Name, StringComparison.OrdinalIgnoreCase) ? MatchReason.Stored
                : PortHost(q.Port) is { } host && hosts.Contains(host) ? MatchReason.Address
                : null;
            if (reason is { } r) result.Add(new MatchedQueue(q, r, PortIsStale: false));
        }
        return result;
    }

    /// <summary>The port's fixed address points somewhere other than where the printer is now.</summary>
    internal static bool IsStale(QueuePort port, string? address, string? hostName)
    {
        if (address is null || port.Kind is not (PortKind.TcpIp or PortKind.IppUrl) || PortHost(port) is not { } host) return false;
        if (string.Equals(host, address, StringComparison.OrdinalIgnoreCase)) return false;
        if (hostName is not null && string.Equals(host.TrimEnd('.'), hostName.TrimEnd('.'), StringComparison.OrdinalIgnoreCase)) return false;
        // A DNS name other than the printer's own: it may well follow the printer; only addresses are known to be stale.
        return port.Kind == PortKind.IppUrl ? Uri.CheckHostName(host) is UriHostNameType.IPv4 or UriHostNameType.IPv6 : port.HostIsAddress;
    }

    private static string? PortHost(QueuePort port) => port.Kind switch
    {
        PortKind.TcpIp => port.Host,
        PortKind.IppUrl => port.Url?.Host ?? port.Host,
        _ => null,
    };

    /// <summary>Problem jobs (error, offline, out of paper, blocked, needs attention): cancel or restart them.</summary>
    internal static IReadOnlyList<QueueJob> StuckJobs(QueueFacts q) =>
        q.Jobs.Where(j => QueueJobText.IsProblem(j.Status) && !j.Status.HasFlag(JobStatus.Deleting)).ToList();

    /// <summary>Jobs that have been "cancelling" for minutes: the spooler is stuck on them.</summary>
    internal static IReadOnlyList<QueueJob> DeletingJobs(QueueFacts q, DateTime now) =>
        q.Jobs.Where(j => j.Status.HasFlag(JobStatus.Deleting) && now - j.Submitted > StuckDeleting).ToList();

    /// <summary>What can be repaired, in the order to do it: service first, then each queue's port, state and jobs.</summary>
    /// <param name="caution">Why the new address isn't certain (two devices announce the UUID, the old address still
    /// answers): put in front of the question every port repair asks.</param>
    public static IReadOnlyList<Repair> Plan(OfflineDevice device, SpoolerState spooler, Rediscovery? found, Reachability? reach,
        IReadOnlyList<MatchedQueue> queues, DateTime now, string? caution = null)
    {
        var list = new List<Repair>();
        if (spooler == SpoolerState.Stopped)
        {
            list.Add(new Repair(RepairKind.StartSpooler, CoreStrings.Offline_StartSpooler, CoreStrings.Offline_StartSpoolerDetail)
            {
                AdminOnly = true,
                ManualSteps = ManualSteps.For(RepairKind.StartSpooler),
            });
            return list;
        }

        var answers = reach?.Answers == true;
        // mDNS seeing it is good evidence on its own (a sleeping printer may not accept connections for a moment).
        var target = found?.Address ?? (answers ? reach!.Host : null);
        var restartSpooler = false;
        foreach (var m in queues)
        {
            var q = m.Queue;
            var name = q.Name;
            var onAnotherPc = name.StartsWith(@"\\", StringComparison.Ordinal);
            if (q.Paused)
                list.Add(new Repair(RepairKind.ResumeQueue, string.Format(CoreStrings.Offline_Resume, name), CoreStrings.Offline_ResumeDetail)
                {
                    Queue = name,
                    OnAnotherPc = onAnotherPc,
                    Question = string.Format(CoreStrings.Offline_ResumeQuestion, name),
                    Confirm = CoreStrings.Offline_ResumeConfirm,
                    ManualSteps = ManualSteps.For(RepairKind.ResumeQueue, name),
                });
            if (q.WorkOffline)
                list.Add(new Repair(RepairKind.ClearWorkOffline, string.Format(CoreStrings.Offline_WorkOffline, name),
                    CoreStrings.Offline_WorkOfflineDetail)
                {
                    Queue = name,
                    OnAnotherPc = onAnotherPc,
                    Question = string.Format(CoreStrings.Offline_WorkOfflineQuestion, name),
                    Confirm = CoreStrings.Offline_WorkOfflineConfirm,
                    ManualSteps = ManualSteps.For(RepairKind.ClearWorkOffline, name),
                });

            if (m.PortIsStale && target is not null)
                AddPortRepairs(list, m, target, found?.HostName, caution);
            else if (!m.PortIsStale && answers && q.ReportsOffline && !q.WorkOffline && !q.Paused)
            {
                // It answers, the port is right, yet Windows says offline.
                if (q.Port.Kind == PortKind.DeviceId && device.CanPair)
                    list.Add(new Repair(RepairKind.SetUpAgain, string.Format(CoreStrings.Offline_SetUpAgain, name),
                        CoreStrings.Offline_SetUpAgainDetail)
                    {
                        Queue = name,
                        Question = string.Format(CoreStrings.Offline_SetUpAgainQuestion, name),
                        Confirm = CoreStrings.Offline_SetUpAgainConfirm,
                        ManualSteps = ManualSteps.For(RepairKind.SetUpAgain, name),
                    });
                else if (q.Port is { Kind: PortKind.TcpIp, Snmp: true })
                    list.Add(new Repair(RepairKind.TurnOffSnmp, string.Format(CoreStrings.Offline_TurnOffSnmp, name),
                        CoreStrings.Offline_TurnOffSnmpDetail)
                    {
                        Queue = name,
                        ManualOnly = true,
                        ManualSteps = ManualSteps.For(RepairKind.TurnOffSnmp, name),
                    });
                else
                    restartSpooler = true;
            }

            var stuck = StuckJobs(q);
            if (stuck.Count > 0)
            {
                var what = stuck.Count == 1 ? $"“{stuck[0].Name}”"
                    : string.Format(CoreStrings.Offline_StuckJobsNamed, stuck.Count, string.Join(", ", stuck.Take(3).Select(j => $"“{j.Name}”")) + (stuck.Count > 3 ? "…" : ""));
                var ids = stuck.Select(j => j.Id).ToList();
                list.Add(new Repair(RepairKind.CancelStuckJobs, Plural.Of(stuck.Count, CoreStrings.Offline_CancelStuck_One, CoreStrings.Offline_CancelStuck_Many, name),
                    Capital(string.Format(stuck.Count == 1 ? CoreStrings.Offline_StuckDetail_One : CoreStrings.Offline_StuckDetail_Many, what)))
                {
                    Queue = name,
                    OnAnotherPc = onAnotherPc,
                    JobIds = ids,
                    Question = string.Format(stuck.Count == 1 ? CoreStrings.Offline_CancelStuckQuestion_One : CoreStrings.Offline_CancelStuckQuestion_Many, what, name),
                    Confirm = stuck.Count == 1 ? CoreStrings.Offline_CancelJob : CoreStrings.Offline_CancelJobs,
                    ManualSteps = ManualSteps.For(RepairKind.CancelStuckJobs, name),
                });
                if (answers || target is not null || device.QueueOnly) // a queue printer has nothing else to go by
                    list.Add(new Repair(RepairKind.RestartStuckJobs, stuck.Count == 1 ? CoreStrings.Offline_PrintAgainAlt_One : CoreStrings.Offline_PrintAgainAlt_Many,
                        CoreStrings.Offline_PrintAgainDetail)
                    {
                        Queue = name,
                        OnAnotherPc = onAnotherPc,
                        JobIds = ids,
                        IsAlternative = true,
                        Question = string.Format(CoreStrings.Offline_PrintAgainQuestion, what, name),
                        Confirm = CoreStrings.Offline_PrintAgainConfirm,
                        ManualSteps = ManualSteps.For(RepairKind.RestartStuckJobs, name),
                    });
            }
            restartSpooler |= DeletingJobs(q, now).Count > 0;
        }

        if (restartSpooler)
            list.Add(new Repair(RepairKind.RestartSpooler, CoreStrings.Offline_RestartSpooler,
                CoreStrings.Offline_RestartSpoolerDetail)
            {
                AdminOnly = true,
                Question = CoreStrings.Offline_RestartSpoolerQuestion,
                Confirm = CoreStrings.Offline_RestartSpoolerConfirm,
                ManualSteps = ManualSteps.For(RepairKind.RestartSpooler),
            });
        return list;
    }

    /// <summary>
    /// Port repairs always ask first, naming the address that will be used, before Windows' permission prompt (which shows
    /// only "Windows PowerShell"): the address came from the network.
    /// </summary>
    private static void AddPortRepairs(List<Repair> list, MatchedQueue m, string target, string? hostName, string? caution)
    {
        var q = m.Queue;
        var name = q.Name;
        var old = PortHost(q.Port);
        var byName = (m.Reason == MatchReason.Name
            ? string.Format(CoreStrings.Offline_SameModelName, name, old) + " "
            : "") + caution;
        if (q.Port.Kind == PortKind.IppUrl && q.Port.Url is { } url)
        {
            var newUrl = new UriBuilder(url) { Host = target }.Uri;
            list.Add(new Repair(RepairKind.RecreateIppQueue, string.Format(CoreStrings.Offline_RecreateAt, name, target),
                string.Format(CoreStrings.Offline_RecreateDetail, old, newUrl.AbsoluteUri))
            {
                Queue = name,
                TargetUrl = newUrl,
                AdminOnly = true,
                Question = byName + string.Format(CoreStrings.Offline_RecreateQuestion, name, newUrl.AbsoluteUri),
                Confirm = CoreStrings.Offline_SetUpAgainConfirm,
                ManualSteps = ManualSteps.For(RepairKind.RecreateIppQueue, name, url: newUrl),
            });
            return;
        }

        list.Add(new Repair(RepairKind.PointPortAt, string.Format(CoreStrings.Offline_PointAt, name, target),
            string.Format(CoreStrings.Offline_PointAtDetail, old, target))
        {
            Queue = name,
            Target = target,
            PortNumber = q.Port.PortNumber,
            AdminOnly = true,
            // LPR ports need the printer's LPR queue name too; the wizard asks for it.
            ManualOnly = q.Port.Lpr,
            Question = byName + string.Format(CoreStrings.Offline_PointAtQuestion, name, target),
            ManualSteps = ManualSteps.For(RepairKind.PointPortAt, name, target),
        });
        if (hostName is { Length: > 0 } && !q.Port.Lpr)
            list.Add(new Repair(RepairKind.PointPortAt, string.Format(CoreStrings.Offline_PointAtNameAlt, hostName),
                CoreStrings.Offline_PointAtNameDetail)
            {
                Queue = name,
                Target = hostName,
                PortNumber = q.Port.PortNumber,
                AdminOnly = true,
                IsAlternative = true,
                Question = byName + string.Format(CoreStrings.Offline_PointAtNameQuestion, name, hostName),
                ManualSteps = ManualSteps.For(RepairKind.PointPortAt, name, hostName),
            });
    }

    private static string Capital(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

    private static string? NormalizeUuid(string? uuid)
    {
        var raw = uuid?.Trim().Trim('{', '}');
        if (raw is not null && raw.StartsWith("urn:uuid:", StringComparison.OrdinalIgnoreCase)) raw = raw[9..];
        return Guid.TryParse(raw, out var g) ? g.ToString("D") : null;
    }

    /// <summary>"<paramref name="prefix"/>" starts <paramref name="text"/> and ends there or at a non-alphanumeric character.</summary>
    private static bool StartsWithWord(string text, string? prefix) =>
        prefix is { Length: > 0 } && text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) &&
        (text.Length == prefix.Length || !char.IsLetterOrDigit(text[prefix.Length]));
}
