using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// Print › Batch (roadmap 2.4): a list of PDFs and pictures, each with its own copies, pages, side and paper; the sheets each comes
/// to and in all, before anything prints; sent in order and each file's result listed. All the rules are Core's
/// (<see cref="BatchPrintRunner"/>, <see cref="BatchPrintLine"/>): this keeps the rows, runs them off the UI thread and asks what only a
/// person can answer. Print sends only what hasn't reached the queue, so pressing it again or resuming a stopped batch never prints a
/// file twice. Saved lists, a folder printed as it fills and the results as CSV ask <see cref="Pro.Allows"/>.
/// </summary>
public sealed partial class BatchPrintViewModel(IBatchQueue queue, IBatchDocuments documents, AppState state) : ObservableObject
{
    private const int MaxWatchLines = 200;

    /// <summary>The list's choice meaning no paper of its own.</summary>
    public static BatchPaper DefaultPaper => new("", Strings.Batch_DefaultPaper);

    private BatchQueueInfo? _info;
    private bool _infoRead;
    private CancellationTokenSource? _run, _estimate, _watch;
    private bool _declinedPassword;

    public ObservableCollection<BatchRowViewModel> Rows { get; } = [];
    public ObservableCollection<BatchPaper> Papers { get; } = [DefaultPaper];
    public ObservableCollection<string> WatchLines { get; } = [];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(MoveUpCommand), nameof(MoveDownCommand), nameof(RemoveCommand), nameof(EnterPasswordCommand))]
    public partial BatchRowViewModel? Selected { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsFree), nameof(CanStop))]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand), nameof(AddFilesCommand), nameof(AddFolderCommand), nameof(ClearCommand), nameof(CheckAgainCommand), nameof(StartOverCommand),
        nameof(MoveUpCommand), nameof(MoveDownCommand), nameof(RemoveCommand), nameof(OpenListCommand), nameof(WatchFolderCommand), nameof(EnterPasswordCommand))]
    public partial bool IsSending { get; set; }

    partial void OnIsSendingChanged(bool value)
    {
        foreach (var row in Rows) row.SendingChanged();
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsFree))]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand), nameof(CheckAgainCommand), nameof(StartOverCommand), nameof(EnterPasswordCommand))]
    public partial bool IsEstimating { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PrintCommand))]
    public partial bool QueueBusy { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(WatchFolderCommand), nameof(StopWatchingCommand), nameof(PrintCommand))]
    [NotifyPropertyChangedFor(nameof(IsWatching))]
    public partial string? WatchedFolder { get; set; }

    public bool IsWatching => WatchedFolder is not null;

    /// <summary>Rows can be changed.</summary>
    public bool IsFree => !IsSending && !IsEstimating;

    public bool CanStop => IsSending;

    [ObservableProperty] public partial string? Message { get; set; }
    [ObservableProperty] public partial bool MessageIsError { get; set; }
    [ObservableProperty] public partial string? Progress { get; set; }
    [ObservableProperty] public partial bool CanTwoSided { get; set; } = true;

    // ------------------------------------------------------------------ for all files

    [ObservableProperty] public partial int AllCopies { get; set; } = 1;
    [ObservableProperty] public partial bool AllTwoSided { get; set; }
    [ObservableProperty] public partial BatchPaper AllPaper { get; set; } = DefaultPaper;

    partial void OnAllCopiesChanged(int value)
    {
        var copies = Math.Clamp(value, 1, BatchPrintLimits.MaxCopies);
        if (copies != value)
        {
            AllCopies = copies;
            return;
        }
        foreach (var row in Rows.Where(r => r.Editable)) row.Copies = copies;
    }

    partial void OnAllTwoSidedChanged(bool value)
    {
        foreach (var row in Rows.Where(r => r.Editable)) row.TwoSided = value;
    }

    partial void OnAllPaperChanged(BatchPaper value)
    {
        if (value is null) // the box lost its item for a moment
        {
            AllPaper = DefaultPaper;
            return;
        }
        foreach (var row in Rows.Where(r => r.Editable)) row.Paper = value;
    }

    [RelayCommand] private void MoreCopies() => AllCopies++;
    [RelayCommand] private void FewerCopies() => AllCopies--;

    // ------------------------------------------------------------------ what it comes to

    public bool HasRows => Rows.Count > 0;

    private int StillToSend => Rows.Count(r => r.StillToSend && r.Line is { Problem: null });

    /// <summary>"7 files, 14 sheets in all. 1 left out." The sheets in all count what Print would send now, what's been sent apart.</summary>
    public string EstimateText
    {
        get
        {
            if (Rows.Count == 0) return "";
            var ready = Rows.Where(r => r.StillToSend && r.Line is { Problem: null }).ToList();
            if (ready.Count == 0 && Rows.All(r => r.State == BatchPrintState.Sent)) return string.Format(Strings.Batch_AllSent, Rows.Count);
            var text = new StringBuilder(string.Format(Strings.Batch_Estimate, Files(ready.Count), Sheets(ready.Sum(r => r.Line!.Sheets))));
            var leftOut = Rows.Count(r => r.StillToSend && r.Line is { Problem: not null });
            if (leftOut > 0) text.Append(' ').Append(Plural.Of(leftOut, Strings.Batch_LeftOut_One, Strings.Batch_LeftOut_Many));
            var sent = Rows.Count(r => r.State == BatchPrintState.Sent);
            if (sent > 0) text.Append(' ').Append(Plural.Of(sent, Strings.Batch_SentAlready_One, Strings.Batch_SentAlready_Many));
            return text.ToString();
        }
    }

    /// <summary>"1 file", "7 files".</summary>
    internal static string Files(int n) => Plural.Of(n, Strings.Batch_Files_One, Strings.Batch_Files_Many);

    /// <summary>"1 sheet", "14 sheets".</summary>
    internal static string Sheets(int n) => Plural.Of(n, Strings.Batch_Sheets_One, Strings.Batch_Sheets_Many);

    internal void RowChanged()
    {
        OnPropertyChanged(nameof(EstimateText));
        OnPropertyChanged(nameof(HasRows));
        PrintCommand.NotifyCanExecuteChanged();
        ClearCommand.NotifyCanExecuteChanged();
        StartOverCommand.NotifyCanExecuteChanged();
        ExportResultsCommand.NotifyCanExecuteChanged();
        SaveListCommand.NotifyCanExecuteChanged();
    }

    // ------------------------------------------------------------------ the printer

    /// <summary>The tab came into view: learn what the printer takes, once, off the UI thread.</summary>
    public void Shown()
    {
        if (!_infoRead) _ = ReadQueueAsync();
    }

    /// <summary>The printer's Windows queue was just created or removed.</summary>
    public void QueueChanged()
    {
        _infoRead = false;
        _ = ReadQueueAsync();
    }

    private async Task<BatchQueueInfo?> ReadQueueAsync()
    {
        try
        {
            _info = await queue.ReadAsync(CancellationToken.None);
        }
        catch (Exception ex)
        {
            Log.Write($"Batch: reading the queue: {ex}");
            _info = null;
        }
        _infoRead = _info is not null;
        CanTwoSided = _info?.CanTwoSided ?? true;
        // Only when they differ: taking the selected item out of a box clears its selection.
        if (_info is { } read && !read.Papers.SequenceEqual(Papers.Skip(1)))
        {
            var keep = AllPaper;
            foreach (var extra in Papers.Skip(1).ToList()) Papers.Remove(extra);
            foreach (var paper in read.Papers) Papers.Add(paper);
            AllPaper = Papers.FirstOrDefault(p => p.Key == keep.Key) ?? DefaultPaper;
        }
        foreach (var row in Rows) row.Refresh(_info);
        RowChanged();
        return _info;
    }

    // ------------------------------------------------------------------ the list

    private bool CanChange() => !IsSending;

    private string StartFolder => state.PrintFolder is { } f && Directory.Exists(f) ? f : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

    [RelayCommand(CanExecute = nameof(CanChange))]
    private async Task AddFilesAsync()
    {
        var dialog = new OpenFileDialog
        {
            Title = Strings.Batch_AddFiles,
            Multiselect = true,
            Filter = Strings.Batch_FilterPdfsPictures + "|*.pdf;*.jpg;*.jpeg;*.jpe;*.jfif;*.png;*.bmp;*.dib;*.gif;*.tif;*.tiff;*.heic;*.heif;*.hif;*.webp|" + Strings.Photos_FilterAll + "|*.*",
            InitialDirectory = StartFolder,
        };
        if (dialog.ShowDialog() == true) await AddAsync(dialog.FileNames);
    }

    [RelayCommand(CanExecute = nameof(CanChange))]
    private async Task AddFolderAsync()
    {
        var dialog = new OpenFolderDialog { Title = Strings.Batch_AddFolder, InitialDirectory = StartFolder };
        if (dialog.ShowDialog() == true) await AddAsync([dialog.FolderName]);
    }

    /// <summary>Adds files and folders (drag-and-drop too), each once, then looks at what's new. A folder's files come at its top, in name order.</summary>
    public async Task AddAsync(IReadOnlyList<string> paths)
    {
        if (IsSending)
        {
            SetMessage(Strings.Batch_StillSending, error: true);
            return;
        }
        Shown();
        var (files, leftOut) = await Task.Run(() =>
        {
            var found = BatchPrintFiles.Expand(paths, recursive: false, out var count);
            return (found, count);
        });
        var known = new HashSet<string>(Rows.Select(r => r.Path), StringComparer.OrdinalIgnoreCase);
        var added = 0;
        var repeated = 0;
        var overLimit = 0;
        foreach (var file in files)
        {
            if (!known.Add(file)) repeated++;
            else if (Rows.Count >= BatchPrintLimits.MaxFiles) overLimit++;
            else
            {
                AddRow(file, new BatchPrintSettings(AllCopies, null, AllTwoSided, AllPaper.Key.Length == 0 ? null : AllPaper.Key));
                added++;
            }
        }
        var notes = new List<string>();
        if (repeated > 0) notes.Add(Plural.Of(repeated, Strings.Batch_Repeated_One, Strings.Batch_Repeated_Many));
        if (leftOut > 0) notes.Add(Plural.Of(leftOut, Strings.Batch_NotSupported_One, Strings.Batch_NotSupported_Many));
        if (overLimit > 0) notes.Add(string.Format(Strings.Batch_OverLimit, overLimit, BatchPrintLimits.MaxFiles));
        SetMessage(notes.Count > 0 ? string.Format(Strings.Batch_AddedNotes, added, string.Join(", ", notes)) : null, error: overLimit > 0);
        if (paths.Count > 0 && Path.GetDirectoryName(paths[0]) is { } folder) state.PrintFolder = folder;
        RowChanged();
        await EstimateAsync();
    }

    private BatchRowViewModel AddRow(string path, BatchPrintSettings settings)
    {
        var row = new BatchRowViewModel(this, path, settings, Papers);
        Rows.Add(row);
        return row;
    }

    private bool CanEstimate() => IsFree && Rows.Count > 0;

    /// <summary>Looks at every row again, so what changed on disk shows now; a file that may be in the queue already stays as it is.</summary>
    [RelayCommand(CanExecute = nameof(CanEstimate))]
    private async Task CheckAgainAsync()
    {
        foreach (var row in Rows.Where(r => r.CanCheckAgain)) row.Forget();
        await EstimateAsync();
    }

    /// <summary>Forgets every result, so Print sends the whole list again.</summary>
    [RelayCommand(CanExecute = nameof(CanEstimate))]
    private async Task StartOverAsync()
    {
        var done = Rows.Count(r => !r.StillToSend);
        if (done > 0 && !Prompt.Ask(Plural.Of(done, Strings.Batch_StartOverAsk_One, Strings.Batch_StartOverAsk_Many), Strings.Batch_StartOver)) return;
        foreach (var row in Rows) row.Forget();
        SetMessage(null);
        await EstimateAsync();
    }

    /// <summary>Opens every row not looked at yet, one at a time and off the UI thread.</summary>
    private async Task EstimateAsync()
    {
        if (IsEstimating) return; // the run under way reaches the new rows too
        IsEstimating = true;
        _declinedPassword = false;
        _estimate = new CancellationTokenSource();
        try
        {
            await (_infoRead ? Task.CompletedTask : ReadQueueAsync());
            while (Rows.FirstOrDefault(r => r.Measure is null) is { } row)
            {
                Progress = string.Format(Strings.Batch_LookingAt, BatchPrintText.Clean(row.Name));
                try
                {
                    var measure = await BatchMeasurer.MeasureAsync(row.Path, row.Password, documents, AskPasswordAsync, null, _estimate.Token);
                    row.Measured(measure, _info);
                    RowChanged();
                }
                catch (OperationCanceledException)
                {
                    // The list was cleared while looking; a saved list may have taken its place, so this goes on with what's there.
                    _estimate.Dispose();
                    _estimate = new CancellationTokenSource();
                }
            }
        }
        finally
        {
            Progress = null;
            IsEstimating = false;
            _estimate.Dispose();
            _estimate = null;
            RowChanged();
        }
    }

    /// <summary>The first locked file asks; after "no" the others wait for Enter password…, instead of a window for each.</summary>
    private Task<string?> AskPasswordAsync(string file, bool wrong)
    {
        if (_declinedPassword) return Task.FromResult<string?>(null);
        var dispatcher = Application.Current?.Dispatcher;
        string? Ask()
        {
            var answer = PrintViewModel.AskPdfPassword?.Invoke(file, wrong);
            if (answer is null) _declinedPassword = true;
            return answer;
        }
        return dispatcher is null ? Task.FromResult(Ask()) : dispatcher.InvokeAsync(Ask).Task;
    }

    private bool CanEnterPassword(BatchRowViewModel? row) => IsFree && (row ?? Selected) is { NeedsPassword: true };

    [RelayCommand(CanExecute = nameof(CanEnterPassword))]
    private async Task EnterPasswordAsync(BatchRowViewModel? row)
    {
        if ((row ?? Selected) is not { } locked) return;
        _declinedPassword = false;
        IsEstimating = true;
        try
        {
            locked.Measured(await BatchMeasurer.MeasureAsync(locked.Path, null, documents, AskPasswordAsync, null, CancellationToken.None), _info);
        }
        finally
        {
            IsEstimating = false;
            RowChanged();
        }
    }

    private bool CanMove(BatchRowViewModel? row) => !IsSending && (row ?? Selected) is not null;

    [RelayCommand(CanExecute = nameof(CanMove))]
    private void MoveUp(BatchRowViewModel? row) => Move(row ?? Selected, -1);

    [RelayCommand(CanExecute = nameof(CanMove))]
    private void MoveDown(BatchRowViewModel? row) => Move(row ?? Selected, 1);

    private void Move(BatchRowViewModel? row, int by)
    {
        if (row is null) return;
        var at = Rows.IndexOf(row);
        var to = at + by;
        if (at < 0 || to < 0 || to >= Rows.Count) return;
        Rows.Move(at, to);
        Selected = row;
        Prompt.Announce(string.Format(Strings.Batch_Moved, row.Name, to + 1, Rows.Count));
    }

    [RelayCommand(CanExecute = nameof(CanMove))]
    private void Remove(BatchRowViewModel? row)
    {
        if ((row ?? Selected) is not { } gone) return;
        var at = Rows.IndexOf(gone);
        gone.Password = null;
        Rows.Remove(gone);
        Selected = Rows.Count == 0 ? null : Rows[Math.Min(at, Rows.Count - 1)];
        RowChanged();
    }

    private bool CanClear() => !IsSending && Rows.Count > 0;

    [RelayCommand(CanExecute = nameof(CanClear))]
    private void Clear()
    {
        _estimate?.Cancel();
        foreach (var row in Rows) row.Password = null;
        Rows.Clear();
        SetMessage(null);
        RowChanged();
    }

    // ------------------------------------------------------------------ printing

    private bool CanPrint() => !IsSending && !IsEstimating && !QueueBusy && StillToSend > 0;

    [RelayCommand(CanExecute = nameof(CanPrint))]
    private async Task PrintAsync()
    {
        var info = await ReadQueueAsync();
        if (info is null)
        {
            SetMessage(Strings.Print_NotSetUp, error: true);
            return;
        }
        var rows = Rows.Where(r => r.StillToSend && r.Measure is not null).ToList();
        foreach (var row in rows) row.Refresh(info);
        var sheets = rows.Sum(r => r.Line?.Sheets ?? 0);
        if (sheets > BatchPrintLimits.ConfirmSheets
            && !Prompt.Ask(string.Format(Strings.Batch_ConfirmSheets, Sheets(sheets), BatchPrintText.Clean(info.Name)), Strings.Common_Print))
            return;

        IsSending = true;
        _run = new CancellationTokenSource();
        SetMessage(null);
        try
        {
            foreach (var row in rows) row.Waiting();
            var lines = rows.Select(r => r.Line!).ToList();
            var progress = new Progress<BatchPrintProgress>(p =>
            {
                var row = rows[p.Index];
                if (p.Result is { } result) row.Finished(result);
                else row.Sending(p.Message);
                Progress = p.Result is null ? string.Format(Strings.Batch_FileProgress, p.Index + 1, rows.Count, BatchPrintText.Clean(row.Name), p.Message) : null;
                RowChanged();
            });
            var summary = await Task.Run(() => BatchPrintRunner.RunAsync(lines, queue, documents, null, progress, _run.Token));
            // Progress<T> posts: every result is applied here in case a late one hasn't landed.
            foreach (var result in summary.Items) rows[result.Index].Finished(result);
            SetMessage(summary.Text, error: summary.StoppedAt is not null || summary.Failed > 0);
            Prompt.Announce(summary.Text);
            if (summary.Sent > 0) RatingRequest.NoteSuccess(state);
        }
        catch (Exception ex)
        {
            Log.Write($"Batch failed: {ex}");
            SetMessage(string.Format(Strings.Batch_Stopped, ex.Message), error: true);
        }
        finally
        {
            _run.Dispose();
            _run = null;
            Progress = null;
            IsSending = false;
            RowChanged();
        }
    }

    [RelayCommand]
    private void Stop()
    {
        _run?.Cancel();
        Progress = Strings.Batch_Stopping;
    }

    [RelayCommand]
    private void OpenPrintQueue() => Shell.Open("ms-settings:printers");

    // ------------------------------------------------------------------ Pro

    private static bool ProAllows()
    {
        if (Pro.Allows(ProFeature.BatchPrintAutomation)) return true;
        Views.ProWindow.Open(Application.Current?.MainWindow, ProFeature.BatchPrintAutomation);
        return false;
    }

    private bool HasRowsToSave() => Rows.Count > 0;

    [RelayCommand(CanExecute = nameof(HasRowsToSave))]
    private void SaveList()
    {
        if (!ProAllows()) return;
        var dialog = new SaveFileDialog
        {
            Title = Strings.Batch_SaveList,
            FileName = Strings.Batch_ListFileName + BatchPrintList.Extension,
            Filter = string.Format(Strings.Batch_ListFilter, BatchPrintList.Extension) + $"|*{BatchPrintList.Extension}",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            BatchPrintList.Save(dialog.FileName, Rows.Select(r => new BatchListEntry(r.Path, r.Settings)));
            SetMessage(string.Format(Strings.Batch_ListSaved, Path.GetFileName(dialog.FileName)));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SetMessage(string.Format(Strings.Batch_ListNotSaved, ex.Message), error: true);
        }
    }

    [RelayCommand(CanExecute = nameof(CanChange))]
    private async Task OpenListAsync()
    {
        if (!ProAllows()) return;
        var dialog = new OpenFileDialog
        {
            Title = Strings.Batch_OpenList,
            Filter = string.Format(Strings.Batch_ListFilter, BatchPrintList.Extension) + $"|*{BatchPrintList.Extension}|" + Strings.Photos_FilterAll + "|*.*",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        };
        if (dialog.ShowDialog() == true) await OpenListAsync(dialog.FileName);
    }

    /// <summary>Puts a saved list's files on the list. Prints nothing: every path is shown and estimated first.</summary>
    public async Task OpenListAsync(string path)
    {
        try
        {
            List<BatchListEntry> entries;
            try
            {
                entries = await Task.Run(() => BatchPrintList.Load(path, allowNetwork: false));
            }
            catch (BatchListNetworkException ex)
            {
                if (!Prompt.Ask(string.Format(Strings.Batch_NetworkAsk, ex.Message), Strings.Batch_OpenThem)) return;
                entries = await Task.Run(() => BatchPrintList.Load(path, allowNetwork: true));
            }
            var files = await Task.Run(() => BatchPrintList.Expand(entries));
            if (Rows.Count > 0 && !Prompt.Ask(Strings.Batch_ReplaceAsk, Strings.Batch_Replace)) return;
            Clear();
            foreach (var entry in files) AddRow(entry.Path, entry.Settings);
            RowChanged();
            await EstimateAsync();
        }
        catch (BatchListException ex)
        {
            SetMessage(ex.Message, error: true);
        }
    }

    private bool HasResults() => Rows.Any(r => r.Result is not null);

    [RelayCommand(CanExecute = nameof(HasResults))]
    private void ExportResults()
    {
        var results = Rows.Select((r, i) => r.Result is { } result ? result with { Index = i } : null).OfType<BatchPrintResult>().ToList();
        if (BatchPrintCsv.Export(results) is not { } csv)
        {
            ProAllows();
            return;
        }
        var dialog = new SaveFileDialog
        {
            Title = Strings.Batch_SaveResults,
            FileName = Strings.Batch_ResultsFileName + ".csv",
            Filter = "CSV (*.csv)|*.csv",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        };
        if (dialog.ShowDialog() != true) return;
        try
        {
            File.WriteAllText(dialog.FileName, csv, new UTF8Encoding(true)); // a spreadsheet reads the names right
            SetMessage(string.Format(Strings.Batch_ResultsSaved, Path.GetFileName(dialog.FileName)));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            SetMessage(string.Format(Strings.Batch_ResultsNotSaved, ex.Message), error: true);
        }
    }

    private bool CanWatch() => !IsSending && WatchedFolder is null;

    [RelayCommand(CanExecute = nameof(CanWatch))]
    private async Task WatchFolderAsync()
    {
        if (!ProAllows()) return;
        var dialog = new OpenFolderDialog { Title = Strings.Batch_ChooseWatchFolder, InitialDirectory = StartFolder };
        if (dialog.ShowDialog() == true) await WatchAsync(dialog.FolderName);
    }

    /// <summary>
    /// Prints each file that lands in the folder, with the "for all files" settings, while this runs. Asks first when files are there
    /// already: choosing the wrong folder shouldn't print it. Not started again by itself after a restart.
    /// </summary>
    public async Task WatchAsync(string folder)
    {
        if (WatchedFolder is not null) return;
        var settings = new BatchPrintSettings(AllCopies, null, AllTwoSided, AllPaper.Key.Length == 0 ? null : AllPaper.Key);
        int already;
        try
        {
            already = await Task.Run(() => BatchPrintFolder.ReadyToPrint(folder));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            SetMessage(ex.Message, error: true);
            return;
        }
        if (already > 0 && !Prompt.Ask(Plural.Of(already, Strings.Batch_WatchAsk_One, Strings.Batch_WatchAsk_Many, BatchPrintText.Clean(folder)), Strings.Batch_PrintThem))
            return;

        _watch = new CancellationTokenSource();
        WatchedFolder = folder;
        WatchLines.Clear();
        SetMessage(null);
        var progress = new Progress<BatchFolderProgress>(p =>
        {
            if (p.Waiting is { } waiting) AddWatchLine(string.Format(Strings.Batch_Waiting, waiting));
            if (p.Finished is { } e) AddWatchLine($"{e.Time:HH:mm:ss} {BatchPrintText.Clean(e.FileName)}: {e.Message}");
        });
        try
        {
            var summary = await Task.Run(() => BatchPrintFolder.RunAsync(folder, queue, documents, new BatchFolderOptions { Settings = settings }, progress, _watch.Token));
            SetMessage(Plural.Of(summary.Sent, Strings.Batch_StoppedWatching_One, Strings.Batch_StoppedWatching_Many, Sheets(summary.SheetsSent), summary.Failed)
                + (summary.StopReason is { } why ? " " + why : ""), error: summary.StopReason is not null);
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException)
        {
            SetMessage(ex.Message, error: true);
        }
        catch (Exception ex)
        {
            Log.Write($"Batch folder failed: {ex}");
            SetMessage(string.Format(Strings.Batch_StoppedWatchingError, ex.Message), error: true);
        }
        finally
        {
            _watch.Dispose();
            _watch = null;
            WatchedFolder = null;
        }
    }

    private void AddWatchLine(string line)
    {
        WatchLines.Insert(0, line);
        if (WatchLines.Count > MaxWatchLines) WatchLines.RemoveAt(WatchLines.Count - 1);
    }

    /// <summary>The printer was removed from the list: nothing more goes to it. A job already handed over finishes.</summary>
    public void Stopped()
    {
        _estimate?.Cancel();
        _run?.Cancel();
        _watch?.Cancel();
    }

    private bool Watching() => WatchedFolder is not null;

    [RelayCommand(CanExecute = nameof(Watching))]
    private void StopWatching() => _watch?.Cancel();

    private void SetMessage(string? text, bool error = false)
    {
        Message = text;
        MessageIsError = error;
    }
}

/// <summary>One file on the batch's list.</summary>
public sealed partial class BatchRowViewModel : ObservableObject
{
    private readonly BatchPrintViewModel _owner;

    internal BatchRowViewModel(BatchPrintViewModel owner, string path, BatchPrintSettings settings, ObservableCollection<BatchPaper> papers)
    {
        _owner = owner;
        Path = path;
        Papers = papers;
        _copies = settings.Copies;
        _range = settings.Range ?? "";
        _twoSided = settings.TwoSided;
        _paperKey = settings.Paper;
        _message = Strings.Batch_LookingAtIt;
    }

    private int _copies;
    private string _range;
    private bool _twoSided;
    private string? _paperKey;
    private BatchQueueInfo? _info;
    private string _message;

    public string Path { get; }
    public string Name => System.IO.Path.GetFileName(Path);
    public string Folder => System.IO.Path.GetDirectoryName(Path) ?? "";
    public ObservableCollection<BatchPaper> Papers { get; }

    /// <summary>Only for opening this file; never saved or shown.</summary>
    internal string? Password { get; set; }

    public BatchMeasure? Measure { get; private set; }
    public BatchPrintLine? Line { get; private set; }
    public BatchPrintResult? Result { get; private set; }
    public BatchPrintState State { get; private set; } = BatchPrintState.Waiting;

    /// <summary>Print sends it: it hasn't reached the queue, for sure.</summary>
    public bool StillToSend => Result?.StillToSend ?? true;

    /// <summary>Check again may look at it again: a file that may be in the queue stays as it is, unless the person starts over.</summary>
    public bool CanCheckAgain => Result is not { State: BatchPrintState.Sent } and not { MayHaveSent: true };

    /// <summary>Its settings can be changed: not once it's sent, nor while a batch runs (what's on screen would no longer be what's sent).</summary>
    public bool Editable => StillToSend && !_owner.IsSending;

    /// <summary>The side is offered when the printer has it, and always for a row asking for it, so it can be turned off.</summary>
    public bool ShowTwoSided => _twoSided || _info?.CanTwoSided != false;

    internal void SendingChanged() => OnPropertyChanged(nameof(Editable));
    public bool NeedsPassword => Measure?.State is BatchMeasureState.NeedsPassword or BatchMeasureState.WrongPassword;

    public BatchPrintSettings Settings => new(_copies, string.IsNullOrWhiteSpace(_range) ? null : _range, _twoSided, _paperKey);

    public int Copies
    {
        get => _copies;
        set
        {
            var copies = Math.Clamp(value, 1, BatchPrintLimits.MaxCopies);
            if (SetProperty(ref _copies, copies)) Changed();
            else if (value != copies) OnPropertyChanged();
        }
    }

    public string Range
    {
        get => _range;
        set
        {
            if (SetProperty(ref _range, value ?? "")) Changed();
        }
    }

    public bool TwoSided
    {
        get => _twoSided;
        set
        {
            if (SetProperty(ref _twoSided, value)) Changed();
        }
    }

    public BatchPaper Paper
    {
        // A paper this printer doesn't have (from a list, or another printer's) stays itself: the box is blank and the row says why, never "default".
        get => Papers.FirstOrDefault(p => string.Equals(p.Key, _paperKey ?? "", StringComparison.OrdinalIgnoreCase)) ?? new BatchPaper(_paperKey!, _paperKey!);
        set
        {
            if (value is null) return; // the box lost its item for a moment: the file's paper hasn't changed
            var key = value.Key.Length == 0 ? null : value.Key;
            if (_paperKey == key) return;
            _paperKey = key;
            OnPropertyChanged();
            Changed();
        }
    }

    [RelayCommand]
    private void MoreCopies() => Copies++;

    [RelayCommand]
    private void FewerCopies() => Copies--;

    public string PagesText => Measure is { State: BatchMeasureState.Ready } m ? Plural.Of(m.PageCount, Strings.Batch_Pages_One, Strings.Batch_Pages_Many) : "";

    public string SheetsText => Line is { Problem: null } line ? BatchPrintViewModel.Sheets(line.Sheets) : "";

    /// <summary>What's happening or why not: the row's second line.</summary>
    public string Message => _message;

    public bool IsProblem => State is BatchPrintState.Failed or BatchPrintState.Skipped || Line is { Problem: not null };

    public string StateText => State switch
    {
        BatchPrintState.Sending => Strings.Batch_StateSending,
        BatchPrintState.Sent => Strings.Batch_StateSent,
        BatchPrintState.Failed => Strings.Batch_StateFailed,
        BatchPrintState.Stopped => Strings.Batch_StateNotSent,
        BatchPrintState.Skipped => Strings.Batch_StateLeftOut,
        _ => Measure is null ? Strings.Batch_StateLooking : Line is { Problem: not null } ? Strings.Batch_StateLeftOut : Strings.Batch_StateReady,
    };

    /// <summary>What a screen reader says for the row.</summary>
    public string AccessibleName => $"{Name}, {StateText}{(SheetsText.Length > 0 ? ", " + SheetsText : "")}{(_message.Length > 0 ? ". " + _message : "")}";

    private void Changed()
    {
        // A setting changed since a result: this row is new again, unless it's in the queue.
        if (Result is { StillToSend: true })
        {
            Result = null;
            State = BatchPrintState.Waiting;
        }
        Refresh(_info);
        _owner.RowChanged();
    }

    internal void Measured(BatchMeasure measure, BatchQueueInfo? info)
    {
        Measure = measure;
        Password = measure.Password;
        OnPropertyChanged(nameof(PagesText));
        OnPropertyChanged(nameof(NeedsPassword));
        Refresh(info);
        _owner.EnterPasswordCommand.NotifyCanExecuteChanged();
    }

    /// <summary>What the settings come to now.</summary>
    internal void Refresh(BatchQueueInfo? info)
    {
        _info = info;
        Line = Measure is null ? null : new BatchPrintLine(Path, Settings, Measure, info);
        if (Result is null && State == BatchPrintState.Waiting) _message = Measure is null ? Strings.Batch_LookingAtIt : Line?.Problem ?? "";
        Notify();
    }

    /// <summary>To be looked at again, as if just added. The password stays offered: the file may not have changed.</summary>
    internal void Forget()
    {
        Measure = null;
        Line = null;
        Result = null;
        State = BatchPrintState.Waiting;
        _message = Strings.Batch_LookingAtIt;
        OnPropertyChanged(nameof(PagesText));
        OnPropertyChanged(nameof(NeedsPassword));
        Notify();
    }

    internal void Waiting()
    {
        Result = null;
        State = BatchPrintState.Waiting;
        _message = Line?.Problem ?? "";
        Notify();
    }

    internal void Sending(string message)
    {
        State = BatchPrintState.Sending;
        _message = message;
        Notify();
    }

    internal void Finished(BatchPrintResult result)
    {
        Result = result;
        State = result.State;
        _message = result.Message;
        Notify();
    }

    private void Notify()
    {
        OnPropertyChanged(nameof(Paper));
        OnPropertyChanged(nameof(ShowTwoSided));
        OnPropertyChanged(nameof(SheetsText));
        OnPropertyChanged(nameof(Message));
        OnPropertyChanged(nameof(StateText));
        OnPropertyChanged(nameof(IsProblem));
        OnPropertyChanged(nameof(AccessibleName));
        OnPropertyChanged(nameof(Editable));
    }
}
