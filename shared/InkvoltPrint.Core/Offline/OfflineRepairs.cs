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
    public string Confirm { get; init; } = "Fix it";

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
    private const string Printers = "Open Settings › Bluetooth & devices › Printers & scanners";

    public static IReadOnlyList<string> For(RepairKind kind, string? queue = null, string? target = null, Uri? url = null)
    {
        var q = queue is null ? "the printer" : $"“{queue}”";
        return kind switch
        {
            RepairKind.StartSpooler or RepairKind.RestartSpooler =>
            [
                "Press Windows+R, type services.msc and press Enter.",
                $"Find Print Spooler, right-click it and choose {(kind == RepairKind.StartSpooler ? "Start" : "Restart")} (Windows asks for an administrator).",
            ],
            RepairKind.ResumeQueue => [$"{Printers}, select {q}, then Open print queue.", "In the queue window, open the Printer menu and untick Pause Printing."],
            RepairKind.ClearWorkOffline => [$"{Printers}, select {q}, then Open print queue.", "In the queue window, open the Printer menu and untick Use Printer Offline."],
            RepairKind.PointPortAt =>
            [
                $"{Printers}, select {q}, then Printer properties › Ports.",
                "Choose Add Port… › Standard TCP/IP Port › New Port…, then Next.",
                $"Enter {target ?? "the printer's address"} as the printer name or IP address and finish the wizard.",
                "Back on the Ports tab, make sure the new port is ticked, then choose Apply.",
            ],
            RepairKind.RecreateIppQueue =>
            [
                $"{Printers}, select {q} and choose Remove.",
                "Choose Add device, then Add manually › Add a printer using an IP address or hostname.",
                $"Pick IPP Device and enter {url?.AbsoluteUri ?? "the printer's address"}.",
            ],
            RepairKind.SetUpAgain => [$"{Printers}, select {q} and choose Remove.", "Back in Inkvolt Print, choose Set up."],
            RepairKind.CancelStuckJobs => [$"{Printers}, select {q}, then Open print queue.", "Right-click each stuck job and choose Cancel. Other people's jobs need an administrator."],
            RepairKind.RestartStuckJobs => [$"{Printers}, select {q}, then Open print queue.", "Right-click each stuck job and choose Restart."],
            RepairKind.TurnOffSnmp =>
            [
                $"{Printers}, select {q}, then Printer properties › Ports.",
                "Select the ticked port and choose Configure Port… (Windows asks for an administrator).",
                "Untick SNMP Status Enabled, then choose OK and Apply.",
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
        if (repair.ManualOnly) return new(RepairOutcomeKind.Manual, "Do this in Windows:", repair.ManualSteps);
        var doneAsUser = 0; // jobs the user-level pass already changed, before any permission prompt
        if (!repair.AdminOnly)
        {
            var user = await repairs.AsUserAsync(repair, ct).ConfigureAwait(false);
            switch (user.Result)
            {
                case AttemptResult.Done: return RepairOutcome.Fixed("Done.");
                case AttemptResult.Failed: return new(RepairOutcomeKind.Failed, user.Message ?? "Windows couldn't do it.", repair.ManualSteps);
                case AttemptResult.Cancelled: return new(RepairOutcomeKind.Cancelled, user.Message ?? "Cancelled.", []);
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
                "Windows refused: the PC sharing this printer decides who may change it. Do it there, or ask whoever looks after it:",
                repair.ManualSteps);
        if (!canElevate)
            return new(RepairOutcomeKind.Manual,
                "Windows needs an administrator for this, and the Microsoft Store version of Inkvolt Print doesn't ask for that. Do it in Windows:",
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
            AttemptResult.Done => RepairOutcome.Fixed("Done."),
            AttemptResult.Cancelled => new(RepairOutcomeKind.Cancelled,
                AlreadyDone(repair.Kind, doneAsUser) + "Cancelled: Windows needs administrator permission for " +
                (doneAsUser > 0 ? $"the other {Jobs(repair.JobIds.Count)}." : "this."), []),
            AttemptResult.Stopped => StoppedAfter(repair.Kind, doneAsUser, repair.JobIds.Count),
            AttemptResult.Unknown => Unknown,
            _ => new(RepairOutcomeKind.Failed, admin.Message ?? "Windows couldn't do it.", repair.ManualSteps),
        };
    }

    /// <summary>The user stopped waiting (Cancel) while Windows' permission prompt was unanswered, before anything was done.</summary>
    public static readonly RepairOutcome Stopped = StoppedAfter(RepairKind.CancelStuckJobs, 0, 0);

    /// <summary>
    /// Stopped waiting for the prompt: says what the user-level pass already did (jobs Windows let the user cancel or restart),
    /// and that the rest wasn't touched.
    /// </summary>
    public static RepairOutcome StoppedAfter(RepairKind kind, int doneAsUser, int left) => new(RepairOutcomeKind.Stopped,
        doneAsUser == 0
            ? "Stopped waiting for Windows' permission, so nothing was changed. If the prompt is still open, answering it now does nothing."
            : AlreadyDone(kind, doneAsUser) +
              $"Stopped waiting for Windows' permission for the other {Jobs(left)}, so they weren't changed. If the prompt is still open, answering it now does nothing.",
        []);

    private static string AlreadyDone(RepairKind kind, int n) =>
        n == 0 ? "" : $"{Capital(Jobs(n))} {(n == 1 ? "was" : "were")} {(kind == RepairKind.RestartStuckJobs ? "restarted" : "cancelled")} " +
                      "without administrator permission. ";

    private static string Jobs(int n) => n == 1 ? "1 job" : $"{n} jobs";

    private static string Capital(string s) => char.ToUpperInvariant(s[0]) + s[1..];

    private static readonly RepairOutcome Unknown = new(RepairOutcomeKind.Unknown,
        "Windows hasn't finished yet, so whether it worked isn't known. Checking again; if it still shows the problem, try again in a minute.", []);
}
