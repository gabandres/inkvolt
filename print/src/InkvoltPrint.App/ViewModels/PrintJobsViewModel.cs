using System.Collections.ObjectModel;
using System.Globalization;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The printer's Windows queue on the Overview: its jobs, refreshed every few seconds only while the card is on screen
/// (Overview shown, printer selected, window not minimized), with Cancel for the user's own jobs and Cancel all.
/// </summary>
public sealed partial class PrintJobsViewModel(IPrintJobs source) : ObservableObject
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(3);

    private readonly RefreshGate _gate = new();
    private CancellationTokenSource? _poll;

    public ObservableCollection<PrintJobViewModel> Jobs { get; } = [];

    /// <summary>False until the first read, and when the printer has no Windows queue.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsEmpty), nameof(NoQueue))]
    public partial bool HasQueue { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NoQueue))]
    public partial bool IsLoaded { get; set; }

    /// <summary>The queue couldn't be read several times in a row (the Print Spooler service stopped, say); still retrying.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NoQueue), nameof(ShowFixLink))]
    public partial string? LoadError { get; set; }

    /// <summary>A job is stuck (error, offline, out of paper…): the card offers the offline fixer.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowFixLink))]
    public partial bool HasProblem { get; set; }

    /// <summary>"Fix printing problems…" on the card: a stuck job, or a queue that can't be read (spooler stopped).</summary>
    public bool ShowFixLink => CanFix && (HasProblem || LoadError is not null);

    /// <summary>The printer has the offline fixer (network printers); a queue printer's card offers Windows' queue instead.</summary>
    public bool CanFix { get; set; } = true;

    [ObservableProperty] public partial string Summary { get; set; } = "";
    [ObservableProperty] public partial string? Message { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CancelAllCommand))]
    public partial bool CanCancelAll { get; set; }

    public bool IsEmpty => HasQueue && Jobs.Count == 0;
    public bool NoQueue => IsLoaded && !HasQueue && LoadError is null;

    /// <summary>The printer's Windows queue was set up, re-created or removed.</summary>
    public void QueueChanged() => source.QueueChanged();

    /// <summary>Starts or stops the refresh loop; called whenever the card's visibility may have changed.</summary>
    public void SetVisible(bool visible)
    {
        if (visible == _poll is not null) return;
        if (!visible)
        {
            _poll!.Cancel();
            _poll = null;
            return;
        }
        _poll = new CancellationTokenSource();
        _ = PollAsync(_poll.Token);
    }

    private async Task PollAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(Interval);
        try
        {
            do
            {
                // Minimized: nobody is looking, skip the spooler call (the timer itself is free).
                if (Application.Current?.MainWindow?.WindowState != WindowState.Minimized) await RefreshAsync();
            } while (await timer.WaitForNextTickAsync(ct));
        }
        catch (OperationCanceledException) { }
    }

    public async Task RefreshAsync()
    {
        // The poll and the re-read after a cancel can overlap: only the latest read started may apply its list.
        var ticket = _gate.Begin();
        IReadOnlyList<QueueJob>? jobs;
        try
        {
            jobs = await source.ListAsync();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Trace.WriteLine($"print queue: {ex.Message}"); // the spooler restarting; next tick tries again
            if (_gate.Failed(ticket))
            {
                // Still failing: say so rather than keep the card hidden (or showing a list that's going stale).
                LoadError = "Windows' print queue isn't answering. If the Print Spooler service is stopped, start it (or restart the PC); trying again every few seconds.";
                IsLoaded = true;
                HasQueue = false;
                Jobs.Clear();
                CanCancelAll = false;
                HasProblem = false;
                Summary = "";
            }
            return;
        }
        if (!_gate.Succeeded(ticket)) return; // a newer read started meanwhile; its list wins
        LoadError = null;
        IsLoaded = true;
        HasQueue = jobs is not null;
        Apply(jobs ?? []);
    }

    /// <summary>Updates rows in place (no flicker, no lost focus), adds new jobs, drops finished ones.</summary>
    private void Apply(IReadOnlyList<QueueJob> jobs)
    {
        var now = DateTime.Now;
        for (var i = Jobs.Count - 1; i >= 0; i--)
            if (jobs.All(j => j.Id != Jobs[i].Id)) Jobs.RemoveAt(i);
        for (var i = 0; i < jobs.Count; i++)
        {
            var existing = Jobs.FirstOrDefault(j => j.Id == jobs[i].Id);
            if (existing is null) Jobs.Insert(Math.Min(i, Jobs.Count), new PrintJobViewModel(jobs[i], now, this));
            else
            {
                existing.Update(jobs[i], now);
                var at = Jobs.IndexOf(existing);
                if (at != i && i < Jobs.Count) Jobs.Move(at, i);
            }
        }
        Summary = QueueJobText.Summary(jobs);
        CanCancelAll = Jobs.Any(j => j.IsMine && !j.IsCancelling);
        HasProblem = Jobs.Any(j => j.IsProblem);
        OnPropertyChanged(nameof(IsEmpty));
    }

    internal async Task CancelAsync(PrintJobViewModel job)
    {
        Message = null;
        try
        {
            await source.CancelAsync(job.Id);
        }
        catch (PrintJobCancelException ex)
        {
            Message = $"\"{job.Name}\": {ex.Message}";
        }
        catch (Exception ex)
        {
            // Finding the queue (PnP, spooler) can fail in its own ways; never let one reach the global error dialog.
            Log.Write($"Cancel print job failed: {ex}");
            Message = $"\"{job.Name}\" couldn't be cancelled: {ex.Message}";
        }
        finally
        {
            await RefreshAsync();
        }
    }

    [RelayCommand(CanExecute = nameof(CanCancelAll))]
    private async Task CancelAllAsync()
    {
        var mine = Jobs.Where(j => j.IsMine && !j.IsCancelling).ToList();
        if (mine.Count == 0) return;
        var others = Jobs.Count - mine.Count;
        var question = mine.Count == 1 ? $"Cancel \"{mine[0].Name}\"?" : $"Cancel your {mine.Count} print jobs?";
        if (others > 0) question += $" {(others == 1 ? "1 job" : $"{others} jobs")} from other people stay in the queue.";
        if (!Prompt.Ask(question, "Cancel jobs")) return;
        Message = null;
        var failed = 0;
        try
        {
            foreach (var job in mine)
            {
                try { await source.CancelAsync(job.Id); }
                catch (PrintJobCancelException) { failed++; }
            }
            if (failed > 0) Message = $"{failed} of {mine.Count} jobs couldn't be cancelled. They may have just finished.";
        }
        catch (Exception ex)
        {
            Log.Write($"Cancel all print jobs failed: {ex}");
            Message = $"The jobs couldn't be cancelled: {ex.Message}";
        }
        finally
        {
            await RefreshAsync();
        }
    }

    [RelayCommand]
    private void OpenWindowsQueue() => Shell.Open("ms-settings:printers");
}

public sealed partial class PrintJobViewModel : ObservableObject
{
    private readonly PrintJobsViewModel _owner;

    public PrintJobViewModel(QueueJob job, DateTime now, PrintJobsViewModel owner)
    {
        _owner = owner;
        Id = job.Id;
        Update(job, now);
    }

    public int Id { get; }

    [ObservableProperty] public partial string Name { get; set; } = "";
    [ObservableProperty] public partial string Status { get; set; } = "";
    [ObservableProperty] public partial bool IsProblem { get; set; }
    [ObservableProperty] public partial string Details { get; set; } = "";
    [ObservableProperty] public partial string Owner { get; set; } = "";

    /// <summary>The user's own job: they can cancel it without an administrator.</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CancelCommand))]
    public partial bool IsMine { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(CancelCommand))]
    public partial bool IsCancelling { get; set; }

    public void Update(QueueJob job, DateTime now)
    {
        Name = job.Name.Length > 0 ? job.Name : "Untitled";
        Status = QueueJobText.Status(job.Status);
        IsProblem = QueueJobText.IsProblem(job.Status);
        IsMine = QueueJobText.IsOwner(job.Owner, Environment.UserName);
        IsCancelling = job.Status.HasFlag(JobStatus.Deleting) || job.Status.HasFlag(JobStatus.Deleted);
        Owner = job.Owner;
        // "Page 2 of 3  ·  10:42  ·  alex" (owner only when it's someone else).
        Details = string.Join("  ·  ", new[]
        {
            QueueJobText.Pages(job.Pages, job.PagesPrinted, job.Status),
            QueueJobText.Submitted(job.Submitted, now, CultureInfo.CurrentCulture),
            IsMine ? "" : job.Owner,
        }.Where(s => s.Length > 0));
    }

    private bool CanCancel() => IsMine && !IsCancelling;

    [RelayCommand(CanExecute = nameof(CanCancel))]
    private Task CancelAsync() => _owner.CancelAsync(this);
}
