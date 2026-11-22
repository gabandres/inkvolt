using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core;
using InkvoltPrint.Core.History;

namespace InkvoltPrint.App.ViewModels;

/// <summary>A month the print log has jobs in, as its picker lists it.</summary>
public sealed record PrintLogMonth(DateOnly Month, string Name)
{
    public override string ToString() => Name;
}

/// <summary>One line of a month's totals: a printer or a person, its jobs and pages (and of those in color, when any are known).</summary>
public sealed record PrintLogTotalRow(string Name, string Jobs, string Pages);

/// <summary>One job of the month: its document, then when, printer, person and what's known of it.</summary>
public sealed record PrintLogRow(string Title, string Detail);

/// <summary>
/// The print log (roadmap 4.9): the month's totals per printer and per person and its jobs, newest first, from the jobs this PC's
/// spooler saw while Inkvolt Print ran (<see cref="PrintLog"/>, kept on this PC only); the switch that turns it off, Clear, and Export
/// as CSV (Inkvolt Pro, <see cref="ProFeature.PrintLogExport"/>). New jobs show as they're logged.
/// </summary>
public sealed partial class PrintLogViewModel : ObservableObject, IDisposable
{
    /// <summary>Jobs listed for a month (all of them are in the totals and the CSV).</summary>
    public const int MaxShown = 200;

    private readonly PrintLogKeeper _keeper;
    private readonly Action<bool> _setOn;
    private IReadOnlyList<PrintLogEntry> _log = [];
    private bool _loading;

    /// <param name="setOn">Turns the log on or off (kept in the settings, the spooler watched or not).</param>
    public PrintLogViewModel(PrintLogKeeper keeper, Action<bool> setOn)
    {
        _keeper = keeper;
        _setOn = setOn;
        keeper.Added += OnAdded;
    }

    public void Dispose() => _keeper.Added -= OnAdded;

    private void OnAdded() => UiThread.Run(() => _ = LoadAsync());

    public ObservableCollection<PrintLogMonth> Months { get; } = [];
    public ObservableCollection<PrintLogTotalRow> ByPrinter { get; } = [];
    public ObservableCollection<PrintLogTotalRow> ByUser { get; } = [];
    public ObservableCollection<PrintLogRow> Jobs { get; } = [];

    [ObservableProperty]
    public partial PrintLogMonth? SelectedMonth { get; set; }

    partial void OnSelectedMonthChanged(PrintLogMonth? value) => ShowMonth();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsEmpty), nameof(HasJobs))]
    public partial bool IsLoaded { get; set; }

    public bool IsEmpty => IsLoaded && _log.Count == 0;

    public bool HasJobs => IsLoaded && _log.Count > 0;

    /// <summary>"Showing the latest 200 of 1,234 jobs this month", when there are more than are listed.</summary>
    [ObservableProperty] public partial string? MoreText { get; set; }

    [ObservableProperty] public partial string? Message { get; set; }

    /// <summary>The log's switch (on by default).</summary>
    public bool IsOn
    {
        get => _keeper.On;
        set
        {
            if (value == _keeper.On) return;
            _setOn(value);
            OnPropertyChanged();
            Message = value ? Strings.PrintLog_TurnedOn : Strings.PrintLog_TurnedOff;
        }
    }

    /// <summary>Reads the log (off the UI thread: the file may hold thousands of jobs) and shows the month picked, or the newest.</summary>
    public async Task LoadAsync()
    {
        if (_loading) return;
        _loading = true;
        try
        {
            var file = _keeper.File;
            _log = await Task.Run(() => file.Read(DateTimeOffset.Now));
            var wanted = SelectedMonth?.Month;
            Months.Clear();
            foreach (var month in PrintLog.Months(_log)) Months.Add(new PrintLogMonth(month, PrintLog.MonthName(month, CultureInfo.CurrentCulture)));
            IsLoaded = true;
            OnPropertyChanged(nameof(IsEmpty));
            OnPropertyChanged(nameof(HasJobs));
            var pick = Months.FirstOrDefault(m => m.Month == wanted) ?? Months.FirstOrDefault();
            if (pick == SelectedMonth) ShowMonth();
            else SelectedMonth = pick;
        }
        finally
        {
            _loading = false;
        }
    }

    private void ShowMonth()
    {
        ByPrinter.Clear();
        ByUser.Clear();
        Jobs.Clear();
        MoreText = null;
        if (SelectedMonth is not { } month) return;
        foreach (var t in PrintLog.ByPrinter(_log, month.Month)) ByPrinter.Add(Row(t));
        foreach (var t in PrintLog.ByUser(_log, month.Month)) ByUser.Add(Row(t));
        var jobs = PrintLog.In(_log, month.Month);
        foreach (var e in jobs.Take(MaxShown)) Jobs.Add(new PrintLogRow(e.Document.Length > 0 ? e.Document : Strings.PrintLog_Untitled, Detail(e)));
        if (jobs.Count > MaxShown) MoreText = string.Format(CultureInfo.CurrentCulture, Strings.PrintLog_More, MaxShown, jobs.Count);
    }

    private static PrintLogTotalRow Row(PrintLogTotal t) => new(t.Name,
        Core.Plural.Of(t.Jobs, Strings.PrintLog_Jobs_One, Strings.PrintLog_Jobs_Many),
        Core.Plural.Of((int)Math.Min(t.Pages, int.MaxValue), Strings.PrintLog_Pages_One, Strings.PrintLog_Pages_Many)
        + (t.ColorPages > 0 ? " " + string.Format(CultureInfo.CurrentCulture, Strings.PrintLog_InColor, t.ColorPages) : ""));

    /// <summary>"Nov 3, 3:42 PM · Office laser · alex · 3 pages × 2 · color".</summary>
    internal static string Detail(PrintLogEntry e)
    {
        var at = e.At.ToLocalTime();
        var parts = new List<string>
        {
            $"{at.ToString(CultureInfo.CurrentCulture.DateTimeFormat.MonthDayPattern, CultureInfo.CurrentCulture)}, {at.ToString("t", CultureInfo.CurrentCulture)}",
        };
        if (e.Printer.Length > 0) parts.Add(e.Printer);
        if (e.User.Length > 0) parts.Add(e.Machine is { Length: > 0 } machine && !string.Equals(machine, Environment.MachineName, StringComparison.OrdinalIgnoreCase)
            ? string.Format(CultureInfo.CurrentCulture, Strings.PrintLog_UserOn, e.User, machine) : e.User);
        if (PrintLog.Detail(e) is { Length: > 0 } detail) parts.Add(detail);
        return string.Join(" · ", parts);
    }

    /// <summary>Export…: the whole log as CSV (Inkvolt Pro; the log and its totals stay free). Written off the UI thread.</summary>
    [RelayCommand]
    private async Task ExportAsync()
    {
        if (!Pro.Allows(ProFeature.PrintLogExport))
        {
            Views.ProWindow.Open(Application.Current?.MainWindow, ProFeature.PrintLogExport);
            return;
        }
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = Strings.PrintLog_ExportTitle,
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            FileName = PrintLog.CsvFileName(DateTimeOffset.Now),
            Filter = Strings.PrintLog_ExportFilter,
            AddExtension = true,
        };
        if (dialog.ShowDialog() != true) return;
        await WriteAsync(dialog.FileName);
    }

    /// <summary>Writes the CSV to <paramref name="path"/> (dev snapshots call this directly).</summary>
    public async Task WriteAsync(string path)
    {
        var log = _log;
        try
        {
            // A byte order mark, so Excel reads the names as UTF-8.
            await Task.Run(() => File.WriteAllText(path, PrintLog.Csv(log), new UTF8Encoding(true)));
            Message = string.Format(CultureInfo.CurrentCulture, Strings.PrintLog_Saved, Path.GetFileName(path));
            Prompt.Announce(Message);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Print log export failed: {ex.Message}");
            Message = null;
            Prompt.Tell(string.Format(CultureInfo.CurrentCulture, Strings.PrintLog_CouldNotSave, ex.Message));
        }
    }

    /// <summary>Clear the log…: every job forgotten, after asking.</summary>
    [RelayCommand]
    private async Task ClearAsync()
    {
        if (!Prompt.Ask(Strings.PrintLog_ClearAsk, Strings.PrintLog_ClearConfirm)) return;
        var file = _keeper.File;
        await Task.Run(file.Clear);
        Log.Write("Print log cleared.");
        Message = Strings.PrintLog_Cleared;
        await LoadAsync();
    }
}
