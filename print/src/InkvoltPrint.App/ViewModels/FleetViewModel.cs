using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.Offline;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// The Fleet page (roadmap 2.6): every printer on the list, most trouble first. It reads no printer: each one's own loop keeps its
/// view model current (a printer that hangs or vanishes holds up only that loop), and while the page is shown it looks at them
/// every two seconds. The supply history's last word for a printer that hasn't answered is read off the UI thread, once. Pro: Export
/// (CSV or JSON) and Fix all, through <see cref="Pro.Allows"/>; without the licence the Pro window says what they do.
/// </summary>
public sealed partial class FleetViewModel : ObservableObject
{
    private readonly MainViewModel _main;
    private readonly PcEnvironment _pc;
    private readonly DispatcherTimer _timer;
    private readonly Dictionary<string, FleetLastKnown?> _known = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _asked = new(StringComparer.OrdinalIgnoreCase);
    private IReadOnlyList<FleetPrinter> _printers = [];
    private CancellationTokenSource? _fixing;

    public FleetViewModel(MainViewModel main, PcEnvironment pc)
    {
        _main = main;
        _pc = pc;
        _timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(2) };
        _timer.Tick += (_, _) =>
        {
            if (Application.Current?.MainWindow is { IsVisible: true }) Refresh(); // not while the window is in the notification area
        };
    }

    public ObservableCollection<FleetRowViewModel> Rows { get; } = [];

    [ObservableProperty] public partial string Summary { get; set; } = "";

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(FixAllCommand), nameof(StopFixingCommand))]
    public partial bool IsFixing { get; set; }

    /// <summary>What the last Fix all did, a line each.</summary>
    public ObservableCollection<FixAllStep> FixSteps { get; } = [];

    /// <summary>What it left for each printer's own fixer.</summary>
    public ObservableCollection<string> FixLeft { get; } = [];

    [ObservableProperty] public partial string? FixSummary { get; set; }

    /// <summary>What the last export said, beside the button.</summary>
    [ObservableProperty] public partial string? ExportMessage { get; set; }

    /// <summary>The page came on screen: looks at the printers now and every two seconds.</summary>
    public void Show()
    {
        Refresh();
        _timer.Start();
    }

    /// <summary>The page went: nothing runs for it.</summary>
    public void Hide() => _timer.Stop();

    /// <summary>The rows as the printers stand now. In place, so a keyboard user's focus stays on its row when the order changes.</summary>
    public void Refresh()
    {
        var printers = _main.Printers.ToList();
        foreach (var p in printers.Where(p => !p.IsOnline && !_asked.Contains(p.Uuid))) AskHistory(p.Uuid);
        _printers = printers.Select(p => FleetPrinter.Of(p.FleetFacts(_known.GetValueOrDefault(p.Uuid)))).ToList();
        var now = DateTimeOffset.Now;
        var rows = FleetPage.Rows(_printers, now);
        for (var i = 0; i < rows.Count; i++)
        {
            var id = rows[i].Printer.Id;
            var at = i;
            while (at < Rows.Count && !string.Equals(Rows[at].Id, id, StringComparison.OrdinalIgnoreCase)) at++;
            if (at == Rows.Count) Rows.Insert(i, new FleetRowViewModel(id, rows[i], this));
            else
            {
                if (at != i) Rows.Move(at, i);
                // Unchanged words leave the row's visuals alone: nothing is rebuilt every two seconds.
                if (Rows[i].Row.AccessibleText != rows[i].AccessibleText) Rows[i].Row = rows[i];
            }
        }
        while (Rows.Count > rows.Count) Rows.RemoveAt(Rows.Count - 1);
        Summary = FleetPage.Summary(_printers);
    }

    private void AskHistory(string id)
    {
        _asked.Add(id);
        var history = _pc.History;
        _ = Task.Run(() => FleetLastKnown.From(history.Rows(id))).ContinueWith(t =>
        {
            if (t.IsCompletedSuccessfully) _known[id] = t.Result;
            else Log.Write($"Fleet page: the supply history wasn't read: {t.Exception?.GetBaseException().Message}");
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private PrinterViewModel? Find(string id) => _main.Printers.FirstOrDefault(p => string.Equals(p.Uuid, id, StringComparison.OrdinalIgnoreCase));

    /// <summary>A row's Open: that printer's page.</summary>
    internal void Open(string id)
    {
        if (Find(id) is { } printer) _main.ShowPrinter(printer);
    }

    /// <summary>A row's Fix it…: that printer's fixer on its page.</summary>
    internal async Task FixAsync(string id)
    {
        if (Find(id) is not { CanFix: true } printer) return;
        Open(id);
        await printer.OpenFixerCommand.ExecuteAsync(null);
    }

    internal bool CanFix(string id) => Find(id)?.CanFix == true;

    // ---------------------------------------------------------------- Pro

    /// <summary>Export…: the list as it stands, as CSV or JSON. Written off the UI thread: the folder may be a slow network share.</summary>
    [RelayCommand]
    private async Task ExportAsync()
    {
        if (!FleetExport.Allowed)
        {
            Views.ProWindow.Open(Application.Current?.MainWindow, ProFeature.FleetExport);
            return;
        }
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export the fleet",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            FileName = $"Fleet {DateTime.Now:yyyy-MM-dd}",
            Filter = "CSV file (*.csv)|*.csv|JSON file (*.json)|*.json",
            AddExtension = true,
        };
        if (dialog.ShowDialog() != true) return;
        await WriteAsync(dialog.FileName);
    }

    /// <summary>Writes the list to <paramref name="path"/>, JSON by its extension, else CSV (dev snapshots call this directly).</summary>
    public async Task WriteAsync(string path)
    {
        Refresh();
        var printers = _printers;
        var now = DateTimeOffset.Now;
        var who = Diagnostics.Identity.Current;
        var json = string.Equals(Path.GetExtension(path), ".json", StringComparison.OrdinalIgnoreCase);
        try
        {
            await Task.Run(() =>
            {
                // A byte order mark for the CSV, so Excel reads the names as UTF-8; the JSON is plain ASCII.
                if (json) File.WriteAllText(path, FleetExport.Json(printers, [], now, who), new UTF8Encoding(false));
                else File.WriteAllText(path, FleetExport.Csv(printers, now, who), new UTF8Encoding(true));
            });
            ExportMessage = $"Saved {Path.GetFileName(path)}.";
            Prompt.Announce(ExportMessage);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Fleet export failed: {ex.Message}");
            ExportMessage = null;
            Prompt.Tell($"Could not save the fleet: {ex.Message}");
        }
    }

    private bool CanFixAll() => !IsFixing;

    /// <summary>Fix all: the fixer's safe repairs over every queue, each confirmed (<see cref="FleetFixAll"/>). The window stays free.</summary>
    [RelayCommand(CanExecute = nameof(CanFixAll))]
    private async Task FixAllAsync()
    {
        if (!Pro.Allows(ProFeature.FleetExport))
        {
            Views.ProWindow.Open(Application.Current?.MainWindow, ProFeature.FleetExport);
            return;
        }
        IsFixing = true;
        FixSteps.Clear();
        FixLeft.Clear();
        FixSummary = "Looking at every queue…";
        using var stop = _fixing = new CancellationTokenSource();
        var dispatcher = Dispatcher.CurrentDispatcher;
        var devices = _main.Printers.Select(p => p.FleetFixDevice).OfType<OfflineDevice>().ToList();
        var probes = _pc.OfflineProbes;
        var repairs = _pc.OfflineRepairs(() => Task.FromResult<string?>("Fix all doesn't set printers up again.")); // not a safe repair: never asked for
        var progress = new Progress<FixAllStep>(FixSteps.Add);
        try
        {
            var report = await Task.Run(() => FleetFixAll.RunAsync(devices, probes, repairs, Features.ElevatedRepairs,
                r => dispatcher.InvokeAsync(() => Prompt.Ask(r.Question!, r.Confirm)).Task, progress, ct: stop.Token), CancellationToken.None);
            await Task.Yield(); // the last line's Progress post lands first
            foreach (var line in report.Left) FixLeft.Add(line);
            FixSummary = report.Summary;
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
            FixSummary = "Stopped: the rest wasn't changed.";
        }
        catch (Exception ex)
        {
            Log.Write($"Fix all: {ex}");
            FixSummary = $"Fix all didn't finish: {ex.Message}";
        }
        finally
        {
            _fixing = null;
            IsFixing = false;
        }
        Prompt.Announce(FixSummary);
        Refresh();
    }

    private bool CanStopFixing() => IsFixing;

    [RelayCommand(CanExecute = nameof(CanStopFixing))]
    private void StopFixing()
    {
        try { _fixing?.Cancel(); }
        catch (ObjectDisposedException) { } // finished meanwhile
    }
}

/// <summary>One row of the Fleet page: its words (<see cref="FleetRow"/>) and what can be done from it.</summary>
public sealed partial class FleetRowViewModel(string id, FleetRow row, FleetViewModel owner) : ObservableObject
{
    public string Id { get; } = id;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(StatusKind), nameof(CanFix), nameof(Supplies))]
    public partial FleetRow Row { get; set; } = row;

    /// <summary>For the status dot: as on the printer list.</summary>
    public string StatusKind => Row.Printer.Trouble switch
    {
        FleetTrouble.Error => "error",
        FleetTrouble.Warning => "warning",
        FleetTrouble.Offline => "offline",
        FleetTrouble.Unknown => "connecting",
        _ => "ok",
    };

    public IReadOnlyList<FleetSupplyView> Supplies => Row.Supplies.Select(s => new FleetSupplyView(s)).ToList();

    /// <summary>
    /// Fix it… shows where the fixer can help: a printer that can't be reached or is in error, and a queue printer with any trouble
    /// (a paused queue reads as a warning). Low ink on a network printer isn't something it fixes.
    /// </summary>
    public bool CanFix => (Row.Printer.Trouble is FleetTrouble.Error or FleetTrouble.Offline
                           || (Row.Printer.Trouble == FleetTrouble.Warning && Row.Printer.Kind == FleetKind.Queue)) && owner.CanFix(Id);

    public string OpenName => $"Open {Row.Printer.Name}";
    public string FixName => $"Fix {Row.Printer.Name}";

    [RelayCommand]
    private void Open() => owner.Open(Id);

    [RelayCommand]
    private Task FixAsync() => owner.FixAsync(Id);
}

/// <summary>One supply on a row, for its bar and swatch.</summary>
public sealed record FleetSupplyView(FleetSupplyRow Supply)
{
    public string Text => Supply.Text;
    public bool HasLevel => Supply.Level is not null;
    public double Level => Supply.Level ?? 0;
    public string? Color => Supply.Color;

    /// <summary>For the bar's color: as on the supplies card.</summary>
    public string LevelKind => Supply.Level == 0 ? "empty" : Supply.IsLow ? "low" : "ok";
}
