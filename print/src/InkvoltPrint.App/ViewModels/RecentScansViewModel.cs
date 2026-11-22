using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Presets;
using InkvoltPrint.Core.History;

namespace InkvoltPrint.App.ViewModels;

/// <summary>One line of the recent scans: the scan, its name and when, how many pages, from which scanner and preset.</summary>
public sealed record RecentScanRow(RecentScan Scan, string Title, string Detail);

/// <summary>
/// Recent scans (roadmap 4.15): the last saves (<see cref="RecentScans"/>, kept in the settings on this PC only), each with Open,
/// Show in folder, Email again and Print. The list is checked against the disk when shown: a file deleted or moved drops out.
/// Print hands the files to the printer the list was opened from (<paramref name="print"/>): a PDF to Print a PDF, several to
/// Batch, pictures to Print photos.
/// </summary>
/// <param name="opensOtherApps">False on the demo's made-up PC: the mail app isn't started, the line says what would happen.</param>
/// <param name="print">Prints a scan on this printer (the window closes first); null where this printer can't print.</param>
public sealed partial class RecentScansViewModel(AppState state, bool opensOtherApps, Func<RecentScan, Task>? print) : ObservableObject
{
    public ObservableCollection<RecentScanRow> Items { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsEmpty))]
    public partial bool IsLoaded { get; set; }

    public bool IsEmpty => IsLoaded && Items.Count == 0;

    [ObservableProperty] public partial string? Message { get; set; }

    public bool CanPrint => print is not null;

    /// <summary>Asks the window to close (before Print moves to the Print or Photos tab).</summary>
    public event Action? CloseRequested;

    /// <summary>
    /// Reads the kept list, finds the files gone from the disk (off the UI thread: a share may be slow) and drops only those from the
    /// list as it is by then, so a scan saved meanwhile stays.
    /// </summary>
    public async Task LoadAsync()
    {
        var files = state.GetRecentScans().SelectMany(s => s.Files).ToList();
        var gone = await Task.Run(() => files.Where(f => !Exists(f)).ToHashSet(StringComparer.OrdinalIgnoreCase));
        Show(state.DropMissingRecentFiles(gone));

        static bool Exists(string path)
        {
            try { return File.Exists(path); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { return false; }
        }
    }

    private void Show(IReadOnlyList<RecentScan> list)
    {
        Items.Clear();
        var now = DateTimeOffset.Now;
        foreach (var scan in list) Items.Add(new RecentScanRow(scan, Title(scan), Detail(scan, now)));
        IsLoaded = true;
        OnPropertyChanged(nameof(IsEmpty));
    }

    /// <summary>"Receipt 0042.pdf", or "Receipt 0042.pdf and 2 more" for a batch or a set of pictures.</summary>
    internal static string Title(RecentScan scan) =>
        scan.Files.Count > 1 ? Core.Plural.Of(scan.Files.Count - 1, Strings.Recent_AndMore_One, Strings.Recent_AndMore_Many, scan.Name) : scan.Name;

    /// <summary>"Today, 3:42 PM · 3 pages · Demo laser · Receipts".</summary>
    internal static string Detail(RecentScan scan, DateTimeOffset now)
    {
        var at = scan.SavedAt.ToLocalTime();
        var time = at.ToString("t", CultureInfo.CurrentCulture);
        var parts = new List<string>
        {
            RecentScans.Day(scan.SavedAt, now) switch
            {
                RecentScanDay.Today => string.Format(Strings.Recent_Today, time),
                RecentScanDay.Yesterday => string.Format(Strings.Recent_Yesterday, time),
                _ => at.ToString("g", CultureInfo.CurrentCulture),
            },
        };
        if (scan.Pages > 0) parts.Add(Core.Plural.Of(scan.Pages, Strings.Print_Pages_One, Strings.Print_Pages_Many));
        if (scan.Printer is { } printer) parts.Add(printer);
        if (scan.Preset is { } preset) parts.Add(preset);
        return string.Join(" · ", parts);
    }

    [RelayCommand]
    private void Open(RecentScanRow? row)
    {
        if (row is null) return;
        if (!opensOtherApps)
        {
            Message = string.Format(Strings.Recent_DemoOpen, row.Scan.Name);
            return;
        }
        Shell.Open(row.Scan.Files[0]);
    }

    [RelayCommand]
    private void ShowInFolder(RecentScanRow? row)
    {
        if (row is null) return;
        if (!opensOtherApps)
        {
            Message = string.Format(Strings.Recent_DemoOpen, row.Scan.Name);
            return;
        }
        Shell.ShowInFolder(row.Scan.Files[0]);
    }

    /// <summary>Hands the files to the mail app again (<see cref="MailHandoff"/>): nothing is sent by Inkvolt Print.</summary>
    [RelayCommand]
    private async Task EmailAsync(RecentScanRow? row)
    {
        if (row is null) return;
        if (!opensOtherApps)
        {
            Message = Strings.Mail_DemoNote;
            return;
        }
        Message = Strings.Mail_Opening;
        var files = row.Scan.Files;
        Message = await MailHandoff.SendAsync(files, Path.GetFileNameWithoutExtension(files[0])) switch
        {
            MailHandoff.Result.Attached => Strings.Mail_Attached,
            MailHandoff.Result.Cancelled => Strings.Mail_Cancelled,
            _ => files.Count == 1 ? Strings.Mail_AttachByHandOne : string.Format(Strings.Mail_AttachByHandMany, files.Count),
        };
    }

    [RelayCommand]
    private async Task PrintAsync(RecentScanRow? row)
    {
        if (row is null || print is null) return;
        CloseRequested?.Invoke();
        await print(row.Scan);
    }

    [RelayCommand]
    private void Remove(RecentScanRow? row)
    {
        if (row is null) return;
        Show(state.RemoveRecentScan(row.Scan));
        Message = string.Format(Strings.Recent_Removed, row.Scan.Name);
    }

    [RelayCommand]
    private void Clear()
    {
        if (Items.Count == 0 || !Prompt.Ask(Strings.Recent_ClearAsk, Strings.Recent_Clear)) return;
        state.ClearRecentScans();
        Show([]);
    }
}
