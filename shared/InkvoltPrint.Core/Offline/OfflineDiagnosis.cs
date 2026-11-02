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
        ? $"{OfflineDiagnosis.Caution(this)}Use {Found!.Address} for {Device.Name}? Choose this only if that's the printer's address " +
          "(its control panel or a network configuration page shows it)."
        : null;

    public bool Answers => Reach?.Answers == true;

    /// <summary>A queue printer's queue wasn't among Windows' printers: it was removed or renamed (not merely unreadable).</summary>
    public bool QueueGone { get; init; }

    /// <summary>A queue printer's queue couldn't be read this time.</summary>
    public bool QueueUnread { get; init; }

    public string Headline => Spooler == SpoolerState.Stopped ? "The Print Spooler service isn't running"
        : Repairs.Count(r => !r.IsAlternative) is var n and > 0 ? $"Found {(n == 1 ? "one thing" : $"{n} things")} to fix"
        : Device.QueueOnly ? QueueHeadline
        : !Answers ? "The printer isn't answering"
        : Queues.Count == 0 ? "The printer answers, but Windows has no printer for it"
        : "No problems found";

    private string QueueHeadline => QueueGone ? "Windows no longer has this printer"
        : QueueUnread ? "Windows didn't say how this printer is"
        : Queues.Any(m => m.Queue.ReportsOffline) ? "Windows shows this printer offline"
        : Queues.Any(m => m.Queue.ReportsError) ? "Windows shows an error on this printer"
        : "No problems found";

    private string QueueAdvice => Repairs.Count > 0 ? "Fix each one below, then check again."
        : QueueGone ? "It was probably removed or renamed in Settings › Printers & scanners. Inkvolt Print lists what Windows has."
        : QueueUnread ? "Check again in a moment. If this printer is shared from another PC, check that the PC is on."
        : Queues.Any(m => m.Queue.ReportsOffline || m.Queue.ReportsError)
            ? "Check that it's turned on and connected: its USB cable, or the PC sharing it. Inkvolt Print can't reach this printer itself, only what Windows reports."
            : "Windows' printer is ready, not paused and with no stuck jobs. If a job still won't print, turn the printer off and on, then try again.";

    public string Advice => Spooler == SpoolerState.Stopped ? "Nothing on this PC can print until Windows' printing service runs again."
        : Device.QueueOnly ? QueueAdvice
        : Repairs.Count > 0 && Answers ? "Fix each one below, then check again."
        : Repairs.Count > 0 ? "Fix what's listed below. The printer itself isn't answering yet: check that it's on and connected to the same network as this PC."
        : !Answers ? "Check that it's switched on and awake, and connected to the same Wi-Fi or network as this PC (its control panel or a " +
                     "network configuration page shows its address). Turning the printer off and on, then the router, fixes most of these."
        : Queues.Count == 0 ? "Use Set up at the top of the page so every app can print to it."
        : "The printer answers and Windows' printer for it is ready. If a job still won't print, turn the printer off and on, then try again.";
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
            Report(new(CheckKind.Connection, CheckState.Skipped, CheckResult.TitleOf(CheckKind.Connection), "Its address isn't known."));
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
            const string why = "Needs the Print Spooler service.";
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
                Report(new(CheckKind.Queues, CheckState.Warning, CheckResult.TitleOf(CheckKind.Queues), $"Couldn't read Windows' printers: {queueError}"));
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
            const string why = "Needs the Print Spooler service.";
            Report(new(CheckKind.Queues, CheckState.Skipped, CheckResult.TitleOf(CheckKind.Queues), why));
            Report(new(CheckKind.QueueState, CheckState.Skipped, CheckResult.TitleOf(CheckKind.QueueState), why));
        }
        else
        {
            Start(CheckKind.Queues);
            QueueFacts? queue = null;
            string? error = null;
            try { queue = await probes.QueueAsync(queueName, ct).WaitAsync(limit, ct).ConfigureAwait(false); }
            catch (TimeoutException) { error = "Windows didn't answer in time."; }
            catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { error = ex.Message; }
            if (error is not null)
            {
                unread = true;
                Report(new(CheckKind.Queues, CheckState.Warning, CheckResult.TitleOf(CheckKind.Queues), $"Couldn't read “{queueName}”: {error}"));
                Report(new(CheckKind.QueueState, CheckState.Skipped, CheckResult.TitleOf(CheckKind.QueueState)));
            }
            else if (queue is null)
            {
                gone = true;
                Report(new(CheckKind.Queues, CheckState.Failed, CheckResult.TitleOf(CheckKind.Queues), $"Windows no longer has a printer called “{queueName}”."));
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
            parts += $"More than one device announces this printer's ID: {Reachability.Join(found.Addresses.Distinct(StringComparer.OrdinalIgnoreCase).ToList())}. ";
        if (oldAnswers) parts += $"Something still answers at its old address, {device.Host}. ";
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
        SpoolerState.Running => "Running.",
        SpoolerState.Stopped => "Stopped: nothing on this PC can print until it runs.",
        SpoolerState.Changing => "Starting or stopping right now.",
        _ => "Couldn't check it.",
    });

    private static CheckResult NetworkCheck(OfflineDevice device, Rediscovery? found, bool oldAnswers, string? error)
    {
        var title = CheckResult.TitleOf(CheckKind.Network);
        if (found is null)
            return new(CheckKind.Network, CheckState.Warning, title, error is not null
                ? $"Couldn't look for it: {error}"
                : "It didn't announce itself on the network. It may be off or asleep, on another network, or not announce itself at all.");
        if (device.Host is null || string.Equals(found.Address, device.Host, StringComparison.OrdinalIgnoreCase))
            return new(CheckKind.Network, CheckState.Passed, title, $"Found at {found.Address}, the address Inkvolt Print uses.");
        var caution = Caution(device, found, oldAnswers);
        if (caution.Length > 0)
            return new(CheckKind.Network, CheckState.Warning, title,
                $"Found at {found.Address} (it was {device.Host}). {caution}Inkvolt Print asks before using the new address.");
        return new(CheckKind.Network, CheckState.Warning, title,
            $"Found at a new address, {found.Address} (it was {device.Host}). The router gave it a new one; Inkvolt Print uses the new address now.");
    }

    private static CheckResult ConnectionCheck(Reachability r)
    {
        var title = CheckResult.TitleOf(CheckKind.Connection);
        if (r.Answers) return new(CheckKind.Connection, CheckState.Passed, title, $"Answers at {r.Host}: {r.PortsText}.");
        if (r.Ping)
            return new(CheckKind.Connection, CheckState.Failed, title,
                $"Something at {r.Host} answers ping, but no printing port is open. Another device may have that address now.");
        return new(CheckKind.Connection, CheckState.Failed, title,
            $"No answer at {r.Host}. Check that it's switched on and awake, and on the same network as this PC.");
    }

    private static CheckResult QueuesCheck(IReadOnlyList<MatchedQueue> matched)
    {
        var title = CheckResult.TitleOf(CheckKind.Queues);
        if (matched.Count == 0)
            return new(CheckKind.Queues, CheckState.Warning, title, "None: Windows has no printer for this device yet.");
        var lines = matched.Select(m => $"“{m.Queue.Name}”: {m.PortText}" +
                                        (m.PortIsStale ? ", an old address" : "") +
                                        (m.Reason == MatchReason.Name ? " (matched by its name)" : ""));
        return new(CheckKind.Queues, matched.Any(m => m.PortIsStale) ? CheckState.Failed : CheckState.Passed, title, string.Join("\n", lines));
    }

    private static CheckResult QueueStateCheck(IReadOnlyList<MatchedQueue> matched, DateTime now)
    {
        var title = CheckResult.TitleOf(CheckKind.QueueState);
        if (matched.Count == 0) return new(CheckKind.QueueState, CheckState.Skipped, title, "No Windows printer to check.");
        var lines = new List<string>();
        var failed = false;
        foreach (var m in matched)
        {
            var q = m.Queue;
            var problems = new List<string>();
            if (q.Paused) problems.Add("paused");
            if (q.WorkOffline) problems.Add("set to Use Printer Offline");
            var stuck = StuckJobs(q).Count + DeletingJobs(q, now).Count;
            if (stuck > 0) problems.Add(stuck == 1 ? "1 stuck job" : $"{stuck} stuck jobs");
            failed |= problems.Count > 0;
            if (q.ReportsOffline && !q.WorkOffline) problems.Add("Windows shows it offline");
            else if (q.ReportsError) problems.Add("Windows shows an error");
            if (problems.Count > 0) lines.Add($"“{q.Name}”: {Reachability.Join(problems)}.");
        }
        if (lines.Count == 0) return new(CheckKind.QueueState, CheckState.Passed, title, "Not paused or offline, no stuck jobs.");
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
            list.Add(new Repair(RepairKind.StartSpooler, "Start the Print Spooler service", "Windows' printing service isn't running, so nothing can print.")
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
                list.Add(new Repair(RepairKind.ResumeQueue, $"Resume “{name}”", "Printing is paused in Windows, so jobs wait in the queue.")
                {
                    Queue = name,
                    OnAnotherPc = onAnotherPc,
                    Question = $"Resume “{name}”? Jobs waiting in its queue start printing.",
                    Confirm = "Resume",
                    ManualSteps = ManualSteps.For(RepairKind.ResumeQueue, name),
                });
            if (q.WorkOffline)
                list.Add(new Repair(RepairKind.ClearWorkOffline, $"Turn off “Use Printer Offline” for “{name}”",
                    "Windows was told to keep jobs for this printer instead of sending them.")
                {
                    Queue = name,
                    OnAnotherPc = onAnotherPc,
                    Question = $"Turn off “Use Printer Offline” for “{name}”? Jobs Windows is holding for it go to the printer.",
                    Confirm = "Turn it off",
                    ManualSteps = ManualSteps.For(RepairKind.ClearWorkOffline, name),
                });

            if (m.PortIsStale && target is not null)
                AddPortRepairs(list, m, target, found?.HostName, caution);
            else if (!m.PortIsStale && answers && q.ReportsOffline && !q.WorkOffline && !q.Paused)
            {
                // It answers, the port is right, yet Windows says offline.
                if (q.Port.Kind == PortKind.DeviceId && device.CanPair)
                    list.Add(new Repair(RepairKind.SetUpAgain, $"Set up “{name}” again",
                        "The printer answers, but Windows still shows it offline. Removing it and setting it up again makes Windows find it afresh (about 30 seconds).")
                    {
                        Queue = name,
                        Question = $"Remove “{name}” from Windows and set it up again? Its printing preferences go back to the defaults.",
                        Confirm = "Set up again",
                        ManualSteps = ManualSteps.For(RepairKind.SetUpAgain, name),
                    });
                else if (q.Port is { Kind: PortKind.TcpIp, Snmp: true })
                    list.Add(new Repair(RepairKind.TurnOffSnmp, $"Turn off SNMP status for “{name}”",
                        "The printer answers, but Windows also asks it for its status over SNMP and shows it offline when that gets no reply.")
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
                var what = stuck.Count == 1 ? $"“{stuck[0].Name}”" : $"{stuck.Count} jobs ({string.Join(", ", stuck.Take(3).Select(j => $"“{j.Name}”"))}{(stuck.Count > 3 ? "…" : "")})";
                var ids = stuck.Select(j => j.Id).ToList();
                list.Add(new Repair(RepairKind.CancelStuckJobs, stuck.Count == 1 ? $"Cancel the stuck job in “{name}”" : $"Cancel {stuck.Count} stuck jobs in “{name}”",
                    stuck.Count == 1 ? $"{Capital(what)} is stuck and holds up everything after it." : $"{Capital(what)} are stuck and hold up everything after them.")
                {
                    Queue = name,
                    OnAnotherPc = onAnotherPc,
                    JobIds = ids,
                    Question = $"Cancel {what} in “{name}”? {(stuck.Count == 1 ? "It" : "They")} won't print.",
                    Confirm = stuck.Count == 1 ? "Cancel job" : "Cancel jobs",
                    ManualSteps = ManualSteps.For(RepairKind.CancelStuckJobs, name),
                });
                if (answers || target is not null || device.QueueOnly) // a queue printer has nothing else to go by
                    list.Add(new Repair(RepairKind.RestartStuckJobs, stuck.Count == 1 ? "Or print it again from the start" : "Or print them again from the start",
                        "Sends the stuck job to the printer again from its first page.")
                    {
                        Queue = name,
                        OnAnotherPc = onAnotherPc,
                        JobIds = ids,
                        IsAlternative = true,
                        Question = $"Print {what} in “{name}” again from the first page?",
                        Confirm = "Print again",
                        ManualSteps = ManualSteps.For(RepairKind.RestartStuckJobs, name),
                    });
            }
            restartSpooler |= DeletingJobs(q, now).Count > 0;
        }

        if (restartSpooler)
            list.Add(new Repair(RepairKind.RestartSpooler, "Restart the Print Spooler service",
                "Clears jobs stuck while cancelling and makes Windows check its printers again.")
            {
                AdminOnly = true,
                Question = "Restarting the Print Spooler stops anything printing on this PC right now, for every printer. Restart it?",
                Confirm = "Restart",
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
            ? $"“{name}” has the same model name as this printer, but prints to {old}. Is it for this printer? "
            : "") + caution;
        if (q.Port.Kind == PortKind.IppUrl && q.Port.Url is { } url)
        {
            var newUrl = new UriBuilder(url) { Host = target }.Uri;
            list.Add(new Repair(RepairKind.RecreateIppQueue, $"Set up “{name}” again at {target}",
                $"It was added by address and still prints to {old}. Inkvolt Print adds it again at {newUrl.AbsoluteUri} with the same name, " +
                "then removes the old one. Its printing preferences go back to the defaults.")
            {
                Queue = name,
                TargetUrl = newUrl,
                AdminOnly = true,
                Question = byName + $"Set “{name}” up again at {newUrl.AbsoluteUri}?",
                Confirm = "Set up again",
                ManualSteps = ManualSteps.For(RepairKind.RecreateIppQueue, name, url: newUrl),
            });
            return;
        }

        list.Add(new Repair(RepairKind.PointPortAt, $"Point “{name}” at {target}",
            $"Its port still sends jobs to {old}, the printer's old address. Inkvolt Print adds a port for {target} and switches the printer to it.")
        {
            Queue = name,
            Target = target,
            PortNumber = q.Port.PortNumber,
            AdminOnly = true,
            // LPR ports need the printer's LPR queue name too; the wizard asks for it.
            ManualOnly = q.Port.Lpr,
            Question = byName + $"Point “{name}” at {target}? Its print jobs go to {target} from now on.",
            ManualSteps = ManualSteps.For(RepairKind.PointPortAt, name, target),
        });
        if (hostName is { Length: > 0 } && !q.Port.Lpr)
            list.Add(new Repair(RepairKind.PointPortAt, $"Or point it at {hostName}",
                "The printer's network name, which follows it when the router gives it a new address.")
            {
                Queue = name,
                Target = hostName,
                PortNumber = q.Port.PortNumber,
                AdminOnly = true,
                IsAlternative = true,
                Question = byName + $"Point “{name}” at {hostName}? Its print jobs go to whichever address that name has.",
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
