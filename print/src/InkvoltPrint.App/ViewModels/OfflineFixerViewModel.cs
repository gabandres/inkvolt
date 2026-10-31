using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Offline;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// "Printer offline? Fix it": a panel on the printer's Overview that runs <see cref="OfflineDiagnosis"/> step by step,
/// shows each result as it comes in, and offers the repairs it found, one button each. Repairs go through
/// <see cref="RepairRunner"/> (as the user first, then one UAC prompt in unpackaged copies, else manual steps); the
/// diagnosis runs again after every repair. Demo mode uses made-up probes and repairs (Demo.cs), never this PC's queues.
/// </summary>
public sealed partial class OfflineFixerViewModel : ObservableObject
{
    private readonly Func<OfflineDevice> _device;
    private readonly IOfflineProbes _probes;
    private readonly IOfflineRepairs _repairs;
    private readonly Action<string> _adoptAddress;
    private CancellationTokenSource? _run;

    /// <param name="device">The printer as it is right now (its address may have changed since the last run).</param>
    /// <param name="adoptAddress">The printer was found at a new address: reconnect there.</param>
    /// <param name="canElevate">Unpackaged copies may ask for administrator permission (<see cref="Features.ElevatedRepairs"/>).</param>
    public OfflineFixerViewModel(Func<OfflineDevice> device, IOfflineProbes probes, IOfflineRepairs repairs, Action<string> adoptAddress, bool canElevate)
    {
        _device = device;
        _probes = probes;
        _repairs = repairs;
        _adoptAddress = adoptAddress;
        CanElevate = canElevate;
        ResetChecks();
    }

    public bool CanElevate { get; }

    public ObservableCollection<FixerCheckViewModel> Checks { get; } = [];
    public ObservableCollection<FixerRepairViewModel> Repairs { get; } = [];

    [ObservableProperty] public partial bool IsOpen { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CheckAgainCommand))]
    public partial bool IsRunning { get; set; }

    [ObservableProperty] public partial string Headline { get; set; } = "Checking…";
    [ObservableProperty] public partial string? Advice { get; set; }

    /// <summary>What the last repair did ("Done: “Office laser” now prints to 192.0.2.23."), kept across the re-check.</summary>
    [ObservableProperty] public partial string? LastResult { get; set; }

    [ObservableProperty] public partial bool LastResultIsError { get; set; }

    [ObservableProperty] public partial OfflineReport? Report { get; set; }

    /// <summary>Microsoft Store copies: say up front that admin-only fixes come as steps.</summary>
    public bool ShowStoreNote => !CanElevate && Repairs.Any(r => r.Repair.AdminOnly && !r.Repair.ManualOnly);

    public bool HasRepairs => Repairs.Count > 0;

    /// <summary>Opens the panel and runs the diagnosis.</summary>
    public Task OpenAsync()
    {
        IsOpen = true;
        LastResult = null;
        return RunAsync();
    }

    [RelayCommand]
    private void Close()
    {
        _run?.Cancel();
        IsOpen = false;
    }

    private bool CanCheckAgain() => !IsRunning;

    [RelayCommand(CanExecute = nameof(CanCheckAgain))]
    private Task CheckAgainAsync() => RunAsync();

    [RelayCommand]
    private static void OpenPrinterSettings() => Shell.Open("ms-settings:printers");

    private void ResetChecks()
    {
        Checks.Clear();
        foreach (var kind in OfflineDiagnosis.StepsFor(_device())) Checks.Add(new FixerCheckViewModel(CheckResult.Waiting(kind)));
    }

    /// <summary>A step's line, when this printer's diagnosis has it (a queue printer has no network steps).</summary>
    private void Show(CheckResult r) => Checks.FirstOrDefault(c => c.Kind == r.Kind)?.Update(r);

    public async Task RunAsync()
    {
        _run?.Cancel();
        var run = _run = new CancellationTokenSource();
        IsRunning = true;
        Headline = "Checking…";
        Advice = null;
        Repairs.Clear();
        OnPropertyChanged(nameof(HasRepairs));
        OnPropertyChanged(nameof(ShowStoreNote));
        ResetChecks();
        var progress = new Progress<CheckResult>(r =>
        {
            if (!run.IsCancellationRequested) Show(r);
        });
        try
        {
            var device = _device();
            var report = await OfflineDiagnosis.RunAsync(device, _probes, progress, ct: run.Token);
            if (run.IsCancellationRequested) return;
            // Progress<T> posts: let the last step's update land before the summary replaces "Checking…".
            await Task.Yield();
            foreach (var c in report.Checks) Show(c);
            // The UUID mDNS answered for is public: two devices claiming it, or the old address still answering, means ask.
            if (report.Found is { } found && (report.Adoption == AdoptDecision.Adopt
                                              || report.Adoption == AdoptDecision.Ask && Prompt.Ask(report.AdoptionQuestion!, $"Use {found.Address}")))
                _adoptAddress(found.Address);
            Report = report;
            foreach (var r in report.Repairs) Repairs.Add(new FixerRepairViewModel(r, this));
            Headline = report.Headline;
            Advice = report.Advice;
            OnPropertyChanged(nameof(HasRepairs));
            OnPropertyChanged(nameof(ShowStoreNote));
            Prompt.Announce($"{report.Headline}. {report.Advice}");
        }
        catch (OperationCanceledException) when (run.IsCancellationRequested) { }
        catch (Exception ex)
        {
            Log.Write($"Offline fixer: {ex}");
            Headline = "The check didn't finish";
            Advice = ex.Message;
        }
        finally
        {
            if (ReferenceEquals(_run, run)) IsRunning = false;
        }
    }

    internal async Task FixAsync(FixerRepairViewModel row)
    {
        var repair = row.Repair;
        var manual = repair.ManualOnly || (!CanElevate && repair.AdminOnly);
        if (!manual && repair.Question is { } question && !Prompt.Ask(question, repair.Confirm)) return;
        row.IsBusy = true;
        row.MessageIsError = false;
        // A repair that may ask for administrator permission can be cancelled while the prompt waits (unanswered, or the PC
        // locked): Cancel stops waiting, a late "Yes" then changes nothing, and the fixer looks again.
        using var cancel = new CancellationTokenSource();
        row.Cancellation = CanElevate && !manual ? cancel : null;
        row.Message = CanElevate && repair.AdminOnly ? "Waiting for permission… Approve the Windows prompt, or Cancel." : "Working…";
        row.Steps = null;
        RepairOutcome outcome;
        try
        {
            outcome = await RepairRunner.RunAsync(repair, _repairs, CanElevate, cancel.Token);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            outcome = RepairRunner.Stopped;
        }
        catch (Exception ex)
        {
            Log.Write($"Offline fix {repair.Kind} failed: {ex}");
            outcome = new RepairOutcome(RepairOutcomeKind.Failed, ex.Message, repair.ManualSteps);
        }
        finally
        {
            row.Cancellation = null;
            row.IsBusy = false;
        }

        switch (outcome.Kind)
        {
            case RepairOutcomeKind.Fixed:
                LastResult = $"Done: {Lower(repair.Title)}.";
                LastResultIsError = false;
                row.Message = null;
                await RunAsync(); // see what's left
                break;
            case RepairOutcomeKind.Stopped:
                LastResult = $"{repair.Title}: {outcome.Message}";
                LastResultIsError = false;
                Prompt.Announce(outcome.Message);
                await RunAsync(); // see where things stand
                break;
            case RepairOutcomeKind.Unknown:
                // Timed out waiting for Windows; it may still be working. Say so and look again rather than call it a failure.
                LastResult = $"{repair.Title}: {outcome.Message}";
                LastResultIsError = true;
                Prompt.Announce(outcome.Message);
                await RunAsync();
                break;
            case RepairOutcomeKind.Manual:
                row.Message = outcome.Message;
                row.Steps = outcome.Steps;
                Prompt.Announce(outcome.Message + " " + string.Join(" ", outcome.Steps));
                break;
            default:
                row.Message = outcome.Message;
                row.MessageIsError = outcome.Kind == RepairOutcomeKind.Failed;
                if (outcome.Kind == RepairOutcomeKind.Failed && outcome.Steps.Count > 0) row.Steps = outcome.Steps;
                Prompt.Announce(outcome.Message);
                break;
        }
    }

    private static string Lower(string s) => s.Length > 1 && char.IsUpper(s[0]) && !char.IsUpper(s[1]) ? char.ToLowerInvariant(s[0]) + s[1..] : s;
}

/// <summary>One step of the diagnosis: a status disc, its title and what was found.</summary>
public sealed partial class FixerCheckViewModel(CheckResult initial) : ObservableObject
{
    public CheckKind Kind { get; } = initial.Kind;
    public string Title { get; } = initial.Title;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusKind), nameof(Glyph), nameof(IsRunning), nameof(AccessibleText))]
    public partial CheckState State { get; set; } = initial.State;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(AccessibleText))]
    public partial string Detail { get; set; } = initial.Detail;

    public void Update(CheckResult r)
    {
        State = r.State;
        Detail = r.Detail;
    }

    /// <summary>For the shared status converters: ok, warning, error, or idle (waiting, running, skipped).</summary>
    public string StatusKind => State switch
    {
        CheckState.Passed => "ok",
        CheckState.Warning => "warning",
        CheckState.Failed => "error",
        _ => "idle",
    };

    public string Glyph => State switch
    {
        CheckState.Passed => "",  // CheckMark
        CheckState.Warning => "", // Warning
        CheckState.Failed => "",  // Cancel
        CheckState.Running => "", // Sync
        CheckState.Skipped => "", // Remove
        _ => "",
    };

    public bool IsRunning => State == CheckState.Running;

    public string AccessibleText => $"{Title}: {State switch
    {
        CheckState.Passed => "OK",
        CheckState.Warning => "warning",
        CheckState.Failed => "problem",
        CheckState.Running => "checking",
        CheckState.Skipped => "skipped",
        _ => "waiting",
    }}. {Detail}";
}

/// <summary>One repair: what it does, a button, and afterwards its result or the steps to do it by hand.</summary>
public sealed partial class FixerRepairViewModel(Repair repair, OfflineFixerViewModel owner) : ObservableObject
{
    public Repair Repair { get; } = repair;
    public string Title => Repair.Title;
    public string Detail => Repair.Detail;

    public string ButtonText => Repair.ManualOnly ? "Show me how"
        : !owner.CanElevate && Repair.AdminOnly ? "Show me how"
        : Repair.Kind switch
        {
            RepairKind.CancelStuckJobs => Repair.JobIds.Count == 1 ? "Cancel job" : "Cancel jobs",
            RepairKind.RestartStuckJobs => "Print again",
            RepairKind.StartSpooler => "Start it",
            RepairKind.RestartSpooler => "Restart it",
            RepairKind.SetUpAgain or RepairKind.RecreateIppQueue => "Set up again",
            _ => "Fix it",
        };

    /// <summary>Shown under the button: it will ask for administrator permission (unpackaged copies).</summary>
    public string? AdminNote => owner.CanElevate && Repair.AdminOnly && !Repair.ManualOnly
        ? "Windows asks for administrator permission."
        : Repair.Kind is RepairKind.ResumeQueue or RepairKind.ClearWorkOffline && owner.CanElevate && !Repair.OnAnotherPc
            ? "May ask for administrator permission if you didn't set this printer up."
            : null;

    public bool IsAlternative => Repair.IsAlternative;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(FixCommand))]
    public partial bool IsBusy { get; set; }

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial bool MessageIsError { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSteps))]
    public partial IReadOnlyList<string>? Steps { get; set; }

    public bool HasSteps => Steps is { Count: > 0 };

    /// <summary>"1. Open Settings…" lines for the manual steps.</summary>
    public string StepsText => Steps is null ? "" : string.Join("\n", Steps.Select((s, i) => $"{i + 1}. {s}"));

    partial void OnStepsChanged(IReadOnlyList<string>? value) => OnPropertyChanged(nameof(StepsText));

    private bool CanFix() => !IsBusy;

    [RelayCommand(CanExecute = nameof(CanFix))]
    private Task FixAsync() => owner.FixAsync(this);

    /// <summary>Set while a repair that may wait on Windows' permission prompt runs: Cancel stops waiting.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanCancel))]
    [NotifyCanExecuteChangedFor(nameof(CancelCommand))]
    public partial CancellationTokenSource? Cancellation { get; set; }

    public bool CanCancel => Cancellation is not null;

    [RelayCommand(CanExecute = nameof(CanCancel))]
    private void Cancel()
    {
        try { Cancellation?.Cancel(); }
        catch (ObjectDisposedException) { } // finished meanwhile
        Message = "Stopping…";
    }
}
