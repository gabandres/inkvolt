using InkvoltPrint.Core.Offline;

namespace InkvoltPrint.Core.Fleet;

/// <summary>How one repair of Fix all went.</summary>
public enum FixAllKind
{
    Fixed,

    /// <summary>The person said no: nothing was done.</summary>
    Declined,

    /// <summary>Windows refused and Inkvolt Print can't ask for more: <see cref="FixAllStep.Steps"/> say how by hand.</summary>
    Manual,

    Failed,

    /// <summary>The person turned down Windows' permission prompt, or stopped waiting for it.</summary>
    Cancelled,

    /// <summary>Windows hadn't finished when Inkvolt Print stopped waiting.</summary>
    Unknown,

    /// <summary>The queue went (renamed, removed) while the question was open: nothing was done.</summary>
    Gone,

    /// <summary>Something else fixed it while the question was open: nothing was done.</summary>
    AlreadyFine,
}

/// <summary>One line of Fix all's result.</summary>
public sealed record FixAllStep(string Queue, string Title, FixAllKind Kind, string Message)
{
    public IReadOnlyList<string> Steps { get; init; } = [];
}

/// <summary>What Fix all did, what it left to each printer's own fixer, and why it stopped early if it did.</summary>
public sealed record FixAllReport(IReadOnlyList<FixAllStep> Steps, IReadOnlyList<string> Left)
{
    /// <summary>No licence: nothing was looked at or done (the caller shows what Pro does and where to get it).</summary>
    public bool Locked { get; init; }

    public string? Stopped { get; init; }

    /// <summary>"Fixed 2, 1 you said no to, 1 to do by hand." for the page and a screen reader.</summary>
    public string Summary
    {
        get
        {
            if (Locked) return Pro.Locked(ProFeature.FleetExport);
            if (Stopped is { } why && Steps.Count == 0) return why;
            if (Steps.Count == 0) return Left.Count > 0 ? "No safe repair to make. What's left needs each printer's own Fix it…" : "Every queue is fine: nothing to fix.";
            int Count(FixAllKind k) => Steps.Count(s => s.Kind == k);
            var parts = new List<string>();
            if (Count(FixAllKind.Fixed) is var done and > 0) parts.Add($"Fixed {done}");
            if (Count(FixAllKind.Declined) is var no and > 0) parts.Add($"{no} you said no to");
            if (Count(FixAllKind.Manual) is var manual and > 0) parts.Add($"{manual} to do by hand");
            if (Count(FixAllKind.Failed) + Count(FixAllKind.Unknown) is var failed and > 0) parts.Add($"{failed} didn't work");
            if (Count(FixAllKind.Cancelled) is var cancelled and > 0) parts.Add($"{cancelled} cancelled");
            if (Count(FixAllKind.Gone) + Count(FixAllKind.AlreadyFine) is var moot and > 0) parts.Add($"{moot} no longer needed");
            return string.Join(", ", parts) + "." + (Stopped is { } s ? $" {s}" : "");
        }
    }
}

/// <summary>
/// Fix all (Inkvolt Pro): the fixer's safe repairs (<see cref="Repair.IsSafe"/>: resume, turn off Use Printer Offline) over every
/// printer's Windows queues, each confirmed by name. No network step and no port change. A queue printer counts only its own queue
/// by exact name, a network printer only queues known to be its own (its container, the queue Inkvolt Print made for it, the address
/// in the port; never one that merely has its model's name). Windows' answers are waited for only so long. After each yes the queue is
/// read again, since the question may have been open for minutes: one that went or got fixed meanwhile is left alone. One refusal
/// or failure doesn't stop the rest. Cancelling stuck jobs, ports and the spooler aren't safe: they're named in
/// <see cref="FixAllReport.Left"/>, for the printer's own fixer.
/// </summary>
public static class FleetFixAll
{
    public static async Task<FixAllReport> RunAsync(IReadOnlyList<OfflineDevice> devices, IOfflineProbes probes, IOfflineRepairs repairs, bool canElevate,
        Func<Repair, Task<bool>> confirm, IProgress<FixAllStep>? progress = null, DateTime? now = null, TimeSpan? limit = null, CancellationToken ct = default)
    {
        if (!Pro.Allows(ProFeature.FleetExport)) return new FixAllReport([], []) { Locked = true };
        var wait = limit ?? OfflineDiagnosis.QueueReadLimit;
        var when = now ?? DateTime.Now;
        var left = new List<string>();
        var spooler = SpoolerState.Unknown;
        try { spooler = await probes.SpoolerAsync(ct).WaitAsync(wait, ct).ConfigureAwait(false); }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { } // the queue reads will say
        if (spooler == SpoolerState.Stopped)
            return new FixAllReport([], []) { Stopped = "The Print Spooler service isn't running. A printer's Fix it… can start it." };

        // What's wrong, first: nothing is asked while the rest is still being read.
        var safe = new List<Repair>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        IReadOnlyList<QueueFacts>? all = null;
        foreach (var device in devices)
        {
            ct.ThrowIfCancellationRequested();
            IReadOnlyList<MatchedQueue> own;
            try
            {
                if (device.QueueOnly)
                    own = await probes.QueueAsync(device.StoredQueueName ?? "", ct).WaitAsync(wait, ct).ConfigureAwait(false) is { } queue
                        ? [new MatchedQueue(queue, MatchReason.Stored, false)] : [];
                else
                    own = OfflineDiagnosis.OwnQueues(device, all ??= await probes.QueuesAsync(ct).WaitAsync(wait, ct).ConfigureAwait(false));
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
            {
                left.Add($"Couldn't read “{device.StoredQueueName ?? device.Name}”: {(ex is TimeoutException ? "Windows didn't answer in time." : ex.Message)}");
                continue;
            }
            foreach (var match in own.Where(m => seen.Add(m.Queue.Name)))
                foreach (var repair in OfflineDiagnosis.Plan(device with { QueueOnly = true }, spooler, null, null, [match], when))
                {
                    if (repair.IsSafe) safe.Add(repair);
                    else if (!repair.IsAlternative) left.Add(repair.Title);
                }
        }

        var steps = new List<FixAllStep>();
        foreach (var repair in safe)
        {
            if (ct.IsCancellationRequested) return new FixAllReport(steps, left) { Stopped = "Stopped: the rest wasn't changed." };
            var step = await OneAsync(repair, probes, repairs, canElevate, confirm, wait, ct).ConfigureAwait(false);
            if (step is null) return new FixAllReport(steps, left) { Stopped = "Stopped: the rest wasn't changed." };
            steps.Add(step);
            progress?.Report(step);
        }
        return new FixAllReport(steps, left);
    }

    /// <summary>One repair: asked, looked at again, done. Null when stopped.</summary>
    private static async Task<FixAllStep?> OneAsync(Repair repair, IOfflineProbes probes, IOfflineRepairs repairs, bool canElevate, Func<Repair, Task<bool>> confirm, TimeSpan wait,
        CancellationToken ct)
    {
        var queue = repair.Queue ?? "";
        if (!await confirm(repair).ConfigureAwait(false))
            return ct.IsCancellationRequested ? null : new FixAllStep(queue, repair.Title, FixAllKind.Declined, "You said no: not changed.");
        if (ct.IsCancellationRequested) return null;
        try
        {
            var now = await probes.QueueAsync(queue, ct).WaitAsync(wait, ct).ConfigureAwait(false);
            if (now is null) return new FixAllStep(queue, repair.Title, FixAllKind.Gone, $"Windows no longer has a printer called “{queue}”: nothing changed.");
            if (repair.Kind == RepairKind.ResumeQueue ? !now.Paused : !now.WorkOffline)
                return new FixAllStep(queue, repair.Title, FixAllKind.AlreadyFine, "Already fixed: nothing more to do.");
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            return new FixAllStep(queue, repair.Title, FixAllKind.Failed, $"Couldn't check it first, so it wasn't changed: {(ex is TimeoutException ? "Windows didn't answer in time." : ex.Message)}");
        }
        catch (OperationCanceledException)
        {
            return null;
        }

        RepairOutcome outcome;
        try
        {
            outcome = await RepairRunner.RunAsync(repair, repairs, canElevate, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception ex)
        {
            return new FixAllStep(queue, repair.Title, FixAllKind.Failed, ex.Message) { Steps = repair.ManualSteps };
        }
        return new FixAllStep(queue, repair.Title, outcome.Kind switch
        {
            RepairOutcomeKind.Fixed => FixAllKind.Fixed,
            RepairOutcomeKind.Manual => FixAllKind.Manual,
            RepairOutcomeKind.Failed => FixAllKind.Failed,
            RepairOutcomeKind.Unknown => FixAllKind.Unknown,
            _ => FixAllKind.Cancelled,
        }, outcome.Message) { Steps = outcome.Steps };
    }
}
