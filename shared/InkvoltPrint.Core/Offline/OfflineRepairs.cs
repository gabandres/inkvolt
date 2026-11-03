namespace InkvoltPrint.Core.Offline;

public enum RepairKind
{
    StartSpooler,
    RestartSpooler,
    ResumeQueue,
    ClearWorkOffline,

    /// <summary>Point a Standard TCP/IP queue at the printer's current address (or its network name): new port, queue moved to it.</summary>
    PointPortAt,

    /// <summary>Queue added by IPP URL at the old address: add one at the new URL under the same name, then remove the old one.</summary>
    RecreateIppQueue,

    /// <summary>Remove and set up again by pairing (WSD/IPP queues Windows set up from discovery). No administrator needed.</summary>
    SetUpAgain,

    CancelStuckJobs,
    RestartStuckJobs,

    /// <summary>Turn off "SNMP Status Enabled" on a TCP/IP port. Shown as steps only.</summary>
    TurnOffSnmp,
}

/// <summary>Something the fixer offers to repair, with the steps to do it by hand when Inkvolt Print can't (packaged copies).</summary>
public sealed record Repair(RepairKind Kind, string Title, string Detail)
{
    public string? Queue { get; init; }

    /// <summary><see cref="RepairKind.PointPortAt"/>: the address or host name the port should use.</summary>
    public string? Target { get; init; }

    /// <summary><see cref="RepairKind.PointPortAt"/>: the raw port to keep (9100 by default).</summary>
    public int PortNumber { get; init; } = 9100;

    /// <summary><see cref="RepairKind.RecreateIppQueue"/>: the printer's IPP URL at its new address.</summary>
    public Uri? TargetUrl { get; init; }

    public IReadOnlyList<int> JobIds { get; init; } = [];

    /// <summary>Asked before doing it (cancelling jobs, restarting the spooler).</summary>
    public string? Question { get; init; }

    /// <summary>Confirm-button wording for <see cref="Question"/>.</summary>
    public string Confirm { get; init; } = CoreStrings.Offline_FixIt;

    /// <summary>Windows never lets a standard user do this (services, ports, adding printers by URL): go straight to elevation.</summary>
    public bool AdminOnly { get; init; }

    /// <summary>Inkvolt Print doesn't do it itself; it only shows the steps.</summary>
    public bool ManualOnly { get; init; }

    /// <summary>Another way to fix the same thing (pointing a port at the network name instead of the address).</summary>
    public bool IsAlternative { get; init; }

    /// <summary>
    /// A printer shared from another PC: that PC decides who may change it, so an administrator of this one gets no further and
    /// no permission prompt is shown for it.
    /// </summary>
    public bool OnAnotherPc { get; init; }

    /// <summary>
    /// What Fix all may do (each confirmed): it loses nothing, moves no job elsewhere and interrupts no other printer. Cancelling
    /// jobs, printing them again, ports, setting up again and the spooler stay on each printer's own fixer.
    /// </summary>
    public bool IsSafe => Kind is RepairKind.ResumeQueue or RepairKind.ClearWorkOffline && !ManualOnly;

    public IReadOnlyList<string> ManualSteps { get; init; } = [];
}

/// <summary>Manual steps for each repair, in Windows 11's wording, for packaged copies and anything Windows refuses.</summary>
public static class ManualSteps
{
    public static IReadOnlyList<string> For(RepairKind kind, string? queue = null, string? target = null, Uri? url = null)
    {
        var q = queue is null ? CoreStrings.Offline_StepThePrinter : $"“{queue}”";
        var openQueue = string.Format(CoreStrings.Offline_StepOpenQueue, q);
        return kind switch
        {
            RepairKind.StartSpooler or RepairKind.RestartSpooler =>
            [
                CoreStrings.Offline_StepServices,
                kind == RepairKind.StartSpooler ? CoreStrings.Offline_StepStartSpooler : CoreStrings.Offline_StepRestartSpooler,
            ],
            RepairKind.ResumeQueue => [openQueue, CoreStrings.Offline_StepUntickPause],
            RepairKind.ClearWorkOffline => [openQueue, CoreStrings.Offline_StepUntickOffline],
            RepairKind.PointPortAt =>
            [
                string.Format(CoreStrings.Offline_StepPorts, q),
                CoreStrings.Offline_StepAddPort,
                string.Format(CoreStrings.Offline_StepEnterAddress, target ?? CoreStrings.Offline_StepPrinterAddress),
                CoreStrings.Offline_StepApplyPort,
            ],
            RepairKind.RecreateIppQueue =>
            [
                string.Format(CoreStrings.Offline_StepRemove, q),
                CoreStrings.Offline_StepAddByAddress,
                string.Format(CoreStrings.Offline_StepIppDevice, url?.AbsoluteUri ?? CoreStrings.Offline_StepPrinterAddress),
            ],
            RepairKind.SetUpAgain => [string.Format(CoreStrings.Offline_StepRemove, q), CoreStrings.Offline_StepSetUp],
            RepairKind.CancelStuckJobs => [openQueue, CoreStrings.Offline_StepCancelJobs],
            RepairKind.RestartStuckJobs => [openQueue, CoreStrings.Offline_StepRestartJobs],
            RepairKind.TurnOffSnmp =>
            [
                string.Format(CoreStrings.Offline_StepPorts, q),
                CoreStrings.Offline_StepConfigurePort,
                CoreStrings.Offline_StepUntickSnmp,
            ],
            _ => [],
        };
    }
}

public enum AttemptResult
{
    Done,
    AccessDenied,
    Cancelled,
    Failed,

    /// <summary>Windows hadn't finished when Inkvolt Print stopped waiting; it may still be doing it.</summary>
    Unknown,

    /// <summary>The user stopped waiting for the permission prompt before it was answered: nothing ran.</summary>
    Stopped,
}

/// <summary>How one try at a repair went. <see cref="Message"/> says why it failed (shown to the user).</summary>
public sealed record Attempt(AttemptResult Result, string? Message = null)
{
    /// <summary>Jobs Windows refused to change for the user (someone else's): the only ones an elevated retry needs to touch.</summary>
    public IReadOnlyList<int>? DeniedJobIds { get; init; }

    public static readonly Attempt Done = new(AttemptResult.Done);
    public static readonly Attempt Denied = new(AttemptResult.AccessDenied);
}

/// <summary>Carries out repairs. The Windows implementation is in InkvoltPrint.Windows; demo mode and tests use fakes.</summary>
public interface IOfflineRepairs
{
    /// <summary>Tries as the signed-in user, without elevation: <see cref="AttemptResult.AccessDenied"/> when Windows refuses.</summary>
    Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct);

    /// <summary>One UAC prompt. <see cref="AttemptResult.Cancelled"/> when the user declines it.</summary>
    Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct);
}

public enum RepairOutcomeKind { Fixed, Cancelled, Manual, Failed, Unknown, Stopped }

/// <summary>Result of <see cref="RepairRunner"/>; <see cref="Steps"/> is set when the user has to do it by hand.</summary>
public sealed record RepairOutcome(RepairOutcomeKind Kind, string Message, IReadOnlyList<string> Steps)
{
    public static RepairOutcome Fixed(string message) => new(RepairOutcomeKind.Fixed, message, []);
}

/// <summary>
/// The order every repair follows: as the user first (Windows lets the person who set a printer up pause, resume and
/// take it offline, and anyone cancel or restart their own jobs), then one UAC prompt when that's allowed (unpackaged
/// copies), else the manual steps (Microsoft Store copies never elevate).
/// </summary>
public static class RepairRunner
{
    public static async Task<RepairOutcome> RunAsync(Repair repair, IOfflineRepairs repairs, bool canElevate, CancellationToken ct = default)
    {
        if (repair.ManualOnly) return new(RepairOutcomeKind.Manual, CoreStrings.Offline_DoThisInWindows, repair.ManualSteps);
        var doneAsUser = 0; // jobs the user-level pass already changed, before any permission prompt
        if (!repair.AdminOnly)
        {
            var user = await repairs.AsUserAsync(repair, ct).ConfigureAwait(false);
            switch (user.Result)
            {
                case AttemptResult.Done: return RepairOutcome.Fixed(CoreStrings.Offline_Done);
                case AttemptResult.Failed: return new(RepairOutcomeKind.Failed, user.Message ?? CoreStrings.Offline_WindowsCouldnt, repair.ManualSteps);
                case AttemptResult.Cancelled: return new(RepairOutcomeKind.Cancelled, user.Message ?? CoreStrings.Offline_Cancelled, []);
                case AttemptResult.Unknown: return Unknown;
            }
            // Jobs the user could change are done; only the refused ones go to the administrator.
            if (user.DeniedJobIds is { Count: > 0 } denied)
            {
                doneAsUser = repair.JobIds.Count(id => !denied.Contains(id));
                repair = repair with { JobIds = denied };
            }
        }
        if (repair.OnAnotherPc)
            return new(RepairOutcomeKind.Manual,
                CoreStrings.Offline_RefusedOtherPc,
                repair.ManualSteps);
        if (!canElevate)
            return new(RepairOutcomeKind.Manual,
                CoreStrings.Offline_StoreNoAdmin,
                repair.ManualSteps);
        Attempt admin;
        try
        {
            admin = await repairs.ElevatedAsync(repair, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            admin = new Attempt(AttemptResult.Stopped); // stopped before the prompt even showed
        }
        return admin.Result switch
        {
            AttemptResult.Done => RepairOutcome.Fixed(CoreStrings.Offline_Done),
            AttemptResult.Cancelled => new(RepairOutcomeKind.Cancelled,
                AlreadyDone(repair.Kind, doneAsUser) + (doneAsUser > 0
                    ? Plural.Of(repair.JobIds.Count, CoreStrings.Offline_CancelledNeedAdminOther_One, CoreStrings.Offline_CancelledNeedAdminOther_Many)
                    : CoreStrings.Offline_CancelledNeedAdmin), []),
            AttemptResult.Stopped => StoppedAfter(repair.Kind, doneAsUser, repair.JobIds.Count),
            AttemptResult.Unknown => Unknown,
            _ => new(RepairOutcomeKind.Failed, admin.Message ?? CoreStrings.Offline_WindowsCouldnt, repair.ManualSteps),
        };
    }

    /// <summary>The user stopped waiting (Cancel) while Windows' permission prompt was unanswered, before anything was done.</summary>
    public static RepairOutcome Stopped => StoppedAfter(RepairKind.CancelStuckJobs, 0, 0);

    /// <summary>
    /// Stopped waiting for the prompt: says what the user-level pass already did (jobs Windows let the user cancel or restart),
    /// and that the rest wasn't touched.
    /// </summary>
    public static RepairOutcome StoppedAfter(RepairKind kind, int doneAsUser, int left) => new(RepairOutcomeKind.Stopped,
        doneAsUser == 0
            ? CoreStrings.Offline_StoppedNothingChanged
            : AlreadyDone(kind, doneAsUser) +
              Plural.Of(left, CoreStrings.Offline_StoppedOther_One, CoreStrings.Offline_StoppedOther_Many),
        []);

    private static string AlreadyDone(RepairKind kind, int n) =>
        n == 0 ? "" : (kind == RepairKind.RestartStuckJobs
            ? Plural.Of(n, CoreStrings.Offline_RestartedAsUser_One, CoreStrings.Offline_RestartedAsUser_Many)
            : Plural.Of(n, CoreStrings.Offline_CancelledAsUser_One, CoreStrings.Offline_CancelledAsUser_Many)) + " ";

    private static RepairOutcome Unknown => new(RepairOutcomeKind.Unknown, CoreStrings.Offline_NotFinished, []);
}
