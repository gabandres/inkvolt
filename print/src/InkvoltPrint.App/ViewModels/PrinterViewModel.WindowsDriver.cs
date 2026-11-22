using System.Collections.ObjectModel;
using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Windows.Queues;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// Ready for Windows' new driver (roadmap 4.5): which driver this printer's Windows queue uses, whether the printer answers IPP and
/// eSCL, whether it prints and scans under protected print mode (<see cref="DriverReadiness"/>), and Set up with Windows' driver,
/// which adds a queue on Windows' IPP class driver beside the old one and never removes the old one.
/// </summary>
public sealed partial class PrinterViewModel
{
    /// <summary>The About card's lines for Windows' new driver: the driver, what the printer answers, print and scan readiness.</summary>
    public ObservableCollection<InfoRow> DriverRows { get; } = [];

    [ObservableProperty] public partial Readiness? DriverReadinessNow { get; set; }

    /// <summary>A scanner reached only through its Windows driver: it won't work under protected print mode.</summary>
    [ObservableProperty] public partial string? ScanDriverWarning { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SetUpWindowsDriverCommand))]
    public partial bool OffersWindowsDriver { get; set; }

    [ObservableProperty] public partial string? WindowsDriverMessage { get; set; }

    private int _readinessGeneration;

    /// <summary>Reads the queue's driver and assesses the printer again: after a connection, a queue found or made, a scanner attached.</summary>
    internal async Task RefreshReadinessAsync()
    {
        var generation = ++_readinessGeneration;
        try
        {
            var queue = WindowsQueue?.Name ?? await FindQueueAsync();
            var driver = queue is null ? null : await _pc.QueueDriverAsync(queue, WindowsQueue);
            if (generation != _readinessGeneration) return;
            var connection = _monitor?.Connection;
            var readiness = DriverReadiness.Assess(driver, connection?.Probe.Ipp, asked: connection is not null, answersEscl: connection?.Scanner is not null,
                windowsScanner: _wiaDevice is { IsEscl: false });
            ShowReadiness(readiness, driver);
        }
        catch (Exception ex) // fire and forget: never unobserved
        {
            Log.Write($"[{Name}] driver readiness not read: {ex.Message}");
        }
    }

    private void ShowReadiness(Readiness r, QueueDriverInfo? driver)
    {
        DriverReadinessNow = r;
        var driverText = r.Driver switch
        {
            QueueDriver.None => Strings.Ready_DriverNone,
            QueueDriver.WindowsIpp => Strings.Ready_DriverWindows,
            QueueDriver.Microsoft => string.Format(Strings.Ready_DriverMicrosoft, Core.Fleet.FleetText.Clean(driver?.Name, 64)),
            QueueDriver.MakerV4 => string.Format(Strings.Ready_DriverMakerV4, Core.Fleet.FleetText.Clean(driver?.Name, 64)),
            QueueDriver.MakerV3 => string.Format(Strings.Ready_DriverMakerV3, Core.Fleet.FleetText.Clean(driver?.Name, 64)),
            _ => string.Format(Strings.Ready_DriverMaker, Core.Fleet.FleetText.Clean(driver?.Name, 64)),
        };
        var answers = new List<string>();
        if (r.AnswersIpp) answers.Add(r.Mopria ? Strings.Ready_IppMopria : "IPP");
        if (r.AnswersEscl) answers.Add(r.MopriaScan ? Strings.Ready_EsclMopria : "eSCL");
        var print = r.Print switch
        {
            PrintReadiness.Ready => Strings.Ready_PrintReady,
            PrintReadiness.CanMove when r.Driver == QueueDriver.None => Strings.Ready_PrintCanSetUp,
            PrintReadiness.CanMove => Strings.Ready_PrintCanMove,
            PrintReadiness.NotReady => Strings.Ready_PrintNotReady,
            _ => Strings.Ready_PrintNotKnown,
        };
        var asked = _monitor?.Connection is not null;
        Sync(DriverRows, new InfoRow?[]
        {
            new(Strings.Ready_DriverLabel, driverText),
            asked ? new(Strings.Ready_AnswersLabel, answers.Count > 0 ? string.Join(", ", answers) : Strings.Ready_AnswersNeither) : null,
            new(Strings.Ready_ProtectedLabel, print),
        }.OfType<InfoRow>().ToList());
        ScanDriverWarning = r.Scan == ScanReadiness.DriverOnly ? Strings.Ready_ScanDriverOnly : null;
        OffersWindowsDriver = r.OffersSetUp && Host is not null;
    }

    private bool CanSetUpWindowsDriver() => OffersWindowsDriver && !IsInstalling;

    /// <summary>
    /// Adds a queue on Windows' IPP class driver from the printer's IPP address, named "(Windows driver)", beside the old queue, which
    /// stays: one UAC prompt in an unpackaged copy; a packaged copy copies the address and opens Windows Settings, as Set up does.
    /// </summary>
    [RelayCommand(CanExecute = nameof(CanSetUpWindowsDriver))]
    private async Task SetUpWindowsDriverAsync()
    {
        if (Host is null) return;
        var url = IppUrl.AbsoluteUri;
        if (_pc.IsDemo)
        {
            WindowsDriverMessage = string.Format(Strings.Ready_DemoSetUp, DriverReadiness.NewQueueName(Name, Strings.Ready_QueueMarker));
            return;
        }
        if (!Features.ElevatedQueueSetup)
        {
            try { System.Windows.Clipboard.SetText(url); }
            catch (Exception ex) { Trace.WriteLine($"[{Name}] clipboard: {ex.Message}"); } // the message shows the address too
            Shell.Open("ms-settings:printers");
            WindowsDriverMessage = string.Format(Strings.Ready_SetUpInSettings, url);
            return;
        }
        IsInstalling = true;
        SetUpWindowsDriverCommand.NotifyCanExecuteChanged();
        WindowsDriverMessage = Strings.Printer_SettingUpAdmin;
        try
        {
            var name = IppQueueInstaller.SafeQueueName(DriverReadiness.NewQueueName(Name, Strings.Ready_QueueMarker));
            var result = await IppQueueInstaller.InstallAsync(name, IppUrl);
            WindowsDriverMessage = result.Outcome is InstallOutcome.Installed or InstallOutcome.AlreadyInstalled
                ? string.Format(Strings.Ready_SetUpDone, name)
                : result.Message;
        }
        catch (Exception ex)
        {
            Log.Write($"[{Name}] set up with Windows' driver failed: {ex}");
            WindowsDriverMessage = Strings.Printer_SetupFailed; // the details are in the log
        }
        finally
        {
            IsInstalling = false;
            SetUpWindowsDriverCommand.NotifyCanExecuteChanged();
        }
    }
}
