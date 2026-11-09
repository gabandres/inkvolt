using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Drivers;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// A USB printer or scanner on the printer list that is plugged in but has no working driver (<see cref="NeedsDriver"/>), and its
/// page: what's wrong in plain words and what to do. "Get the driver" (<see cref="IDriverGetter"/>) finds the maker's own download for
/// this model and PC, downloads and checks it, shows what it found, and runs it only on the user's click; then Windows is asked to
/// look for the device again and whether it has it now is checked. Otherwise the steps by hand (the maker's page, Windows Update's
/// optional updates, Settings), and "Set it up" once a printer's driver is installed.
/// </summary>
public sealed partial class NeedsDriverViewModel : ObservableObject
{
    private readonly INeedsDriverPc _pc;
    private readonly Func<NeedsDriverPrinter, CancellationToken, Task<bool>> _isThere;
    private Uri? _modelPage;

    public NeedsDriverViewModel(NeedsDriverPrinter printer, bool protectedPrint, INeedsDriverPc pc, Func<NeedsDriverPrinter, CancellationToken, Task<bool>>? isThere = null)
    {
        _pc = pc;
        _isThere = isThere ?? ((_, _) => Task.FromResult(false));
        Printer = printer;
        ProtectedPrintNote = printer.IsScanner ? null : NeedsDriverText.ProtectedPrint(protectedPrint);
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Id), nameof(Name), nameof(ListStatus), nameof(Headline), nameof(Where), nameof(StepGetDriver), nameof(MakerButton),
        nameof(IsNoDriver), nameof(IsNotSetUp), nameof(SetUpNote), nameof(CanSetUp), nameof(CanGetDriver), nameof(GetDriverNote), nameof(WhyMakersDriver),
        nameof(CheckWindowsNote), nameof(ScanTabLine), nameof(IsScanner), nameof(Steps))]
    public partial NeedsDriverPrinter Printer { get; set; }

    /// <summary>Plugged in now: false once a read of the PC's devices no longer has it (kept on the list mid-way through Get the driver).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Steps))]
    public partial bool IsPresent { get; set; } = true;

    /// <summary>"What to do", numbered (<see cref="DriverSteps"/>).</summary>
    public IReadOnlyList<DriverStep> Steps => DriverSteps.For(Printer, IsPresent, CanGetDriver ? _pc.Drivers.Mode : null);

    /// <summary>Shown only while Windows protected print mode is on (it keeps makers' drivers out).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowProtectedPrint))]
    public partial string? ProtectedPrintNote { get; set; }

    /// <summary>What the last button did, when there's something to say (set up, or demo mode's "nothing opened").</summary>
    [ObservableProperty]
    public partial string? Result { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SetUpCommand))]
    public partial bool IsSettingUp { get; set; }

    public string Id => Printer.Id;
    public string Name => Printer.Name;
    public bool IsScanner => Printer.IsScanner;

    /// <summary>Its icon: a scanner's (Segoe's Scan), else a printer's.</summary>
    public string Glyph => IsScanner ? "" : "";
    public string ListStatus => NeedsDriverText.ListStatus(Printer);
    public string Headline => NeedsDriverText.Headline(Printer);
    public string Where => NeedsDriverText.Where(Printer);
    public string StepGetDriver => NeedsDriverText.StepGetDriver(Printer);
    public string MakerButton => NeedsDriverText.MakerButton(Printer);
    public bool IsNoDriver => Printer.Stage == DriverStage.NoDriver;
    public bool IsNotSetUp => Printer.Stage == DriverStage.NotSetUp;
    public string SetUpNote => NeedsDriverText.SetUpNote(Printer);
    public bool CanSetUp => IsNotSetUp && Printer.Driver is not null && Printer.Port is not null;
    public bool ShowProtectedPrint => ProtectedPrintNote is not null;
    public string ScanTabLine => NeedsDriverText.ScanTabLine(Printer);

    public string WhyMakersDriver => NeedsDriverText.WhyMakersDriver(Printer);
    public string ProtectedPrintTitle => NeedsDriverText.ProtectedPrintTitle;
    public string CheckWindowsButton => NeedsDriverText.CheckWindowsButton;
    public string CheckWindowsNote => NeedsDriverText.CheckWindowsNoteFor(Printer);
    public string AddInWindowsButton => NeedsDriverText.AddInWindowsButton;
    public string AddInWindowsNote => NeedsDriverText.AddInWindowsNote;
    public string SetUpButton => NeedsDriverText.SetUpButton;
    public string StepsTitle => NeedsDriverText.StepsTitle;
    public string OtherWaysTitle => NeedsDriverText.OtherWaysTitle;

    /// <summary>A new read of the same printer: its stage or driver may have moved on.</summary>
    public void Update(NeedsDriverPrinter printer, bool protectedPrint)
    {
        if (printer != Printer) Printer = printer;
        IsPresent = true;
        ProtectedPrintNote = printer.IsScanner ? null : NeedsDriverText.ProtectedPrint(protectedPrint);
    }

    [RelayCommand]
    private void OpenMakerPage() => Open(DriverHelp.PageFor(Printer, _modelPage).AbsoluteUri);

    [RelayCommand]
    private void CheckWindows() => Open(DriverHelp.WindowsOptionalUpdates);

    [RelayCommand]
    private void AddInWindows() => Open(DriverHelp.WindowsPrinters);

    private void Open(string target)
    {
        Result = _pc.Open(target) ? null : NeedsDriverText.DemoFor(Printer);
    }

    private bool CanRunSetUp() => !IsSettingUp;

    [RelayCommand(CanExecute = nameof(CanRunSetUp))]
    private async Task SetUpAsync()
    {
        IsSettingUp = true;
        Result = null;
        try
        {
            var done = await _pc.SetUpAsync(Printer);
            Result = done.Message;
            Log.Write($"[{Printer.Name}] set up: {done.Outcome}");
            if (done.Outcome == UsbSetUpOutcome.NeedsAdmin) _pc.OpenAddPrinter();
            if (done.Outcome == UsbSetUpOutcome.Done) SetUpDone?.Invoke();
        }
        finally
        {
            IsSettingUp = false;
        }
    }

    /// <summary>Its queue was made: the list reads Windows' queues again (it becomes a queue printer).</summary>
    public event Action? SetUpDone;

    // ---------------------------------------------------------------- get the driver

    /// <summary>The button shows for a device with no driver whose maker's downloads Inkvolt Print looks up (Epson).</summary>
    public bool CanGetDriver => IsNoDriver && _pc.Drivers.LooksUp(Printer);

    public string GetDriverButton => DriverText.Button;
    public string GetDriverNote => DriverText.Note(Printer, _pc.Drivers.Mode);
    public string InstallButton => DriverText.InstallButton;
    public string DontInstallButton => DriverText.CancelButton;
    public string InstallNote => DriverText.InstallNote;

    /// <summary>What it's doing now ("Looking on Epson's website…", "Downloading… 12.3 MB"); null when idle.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsGettingDriver))]
    [NotifyCanExecuteChangedFor(nameof(GetDriverCommand), nameof(InstallDriverCommand), nameof(DiscardDriverCommand))]
    public partial string? DriverProgress { get; set; }

    public bool IsGettingDriver => DriverProgress is not null;

    /// <summary>A checked download waiting for the user's click.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowConfirm), nameof(FoundTitle), nameof(Facts), nameof(ShowGetDriverButton))]
    [NotifyCanExecuteChangedFor(nameof(GetDriverCommand), nameof(InstallDriverCommand), nameof(DiscardDriverCommand))]
    public partial DriverReady? Ready { get; set; }

    public bool ShowConfirm => Ready is not null;

    public bool ShowGetDriverButton => Ready is null && Offered is null;
    public string FoundTitle => DriverText.FoundTitle(Printer);
    public string Facts => Ready is { } r ? DriverText.Facts(r) : "";

    /// <summary>How "Get the driver" ended, when there's something to say.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowDriverResult))]
    public partial string? DriverResult { get; set; }

    public bool ShowDriverResult => DriverResult is not null;

    /// <summary>The driver went in and Windows has the device: the list reads Windows again, a scanner is shown in the Scan tab.</summary>
    public event Action<NeedsDriverViewModel>? DriverInstalled;

    private bool CanStartGetDriver() => DriverProgress is null && Ready is null && !IsWaitingForInstall;

    /// <summary>A Store copy: it finds the download and opens the maker's link; it never downloads or runs anything itself.</summary>
    public bool OpensLink => _pc.Drivers.Mode == DriverMode.OpenLink;

    [RelayCommand(CanExecute = nameof(CanStartGetDriver))]
    private async Task GetDriverAsync()
    {
        DriverResult = null;
        Offered = null;
        var device = Printer;
        try
        {
            DriverProgress = DriverText.Looking(device);
            var found = await _pc.Drivers.FindAsync(device, CancellationToken.None);
            _modelPage = found.Page ?? found.Offer?.Page ?? _modelPage;
            if (found.Offer is not { } offer)
            {
                Log.Write($"[{device.Name}] get the driver: {DriverText.EnglishNoOffer(device, found)}");
                DriverResult = DriverText.Unavailable(device, found);
                return;
            }
            if (OpensLink)
            {
                Log.Write($"[{device.Name}] driver found (link only): {offer.Title} {offer.Version} at {offer.Download.Host}");
                Offered = offer;
                return;
            }
            DriverProgress = DriverText.Downloading(0);
            var progress = new Progress<long>(bytes => { if (DriverProgress is not null) DriverProgress = DriverText.Downloading(bytes); });
            var got = await _pc.Drivers.DownloadAsync(offer, device, progress, CancellationToken.None);
            if (got.Ready is not { } ready)
            {
                Log.Write($"[{device.Name}] get the driver from {offer.Download.Host}: {DriverText.EnglishRefused(got)}");
                DriverResult = DriverText.Refused(device, got);
                return;
            }
            Log.Write($"[{device.Name}] driver found: {DriverText.EnglishFacts(ready)}");
            Ready = ready;
        }
        catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException or System.Net.Http.HttpRequestException)
        {
            Log.Write($"[{device.Name}] get the driver failed: {ex.Message}");
            DriverResult = DriverText.Refused(device, new DriverDownload(null));
        }
        finally
        {
            DriverProgress = null;
        }
    }

    private bool HasReady() => Ready is not null && DriverProgress is null;

    [RelayCommand(CanExecute = nameof(HasReady))]
    private async Task InstallDriverAsync()
    {
        if (Ready is not { } ready) return;
        var device = Printer;
        DriverProgress = DriverText.Installing;
        try
        {
            if (device.IsMadeUp)
            {
                DriverResult = DriverText.Demo;
                return;
            }
            var done = await _pc.Drivers.InstallAsync(ready, ct => _isThere(device, ct), CancellationToken.None);
            Log.Write(DriverText.LogLine(device, done));
            DriverResult = DriverText.Outcome(device, done);
            if (done.Outcome == InstallOutcome.Done) DriverInstalled?.Invoke(this);
        }
        catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception
                                       or InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            // DriverFlow says these itself; anything that still gets here is said the same way, never a crash.
            Log.Write($"[{device.Name}] driver install failed: {ex.GetType().Name}: {ex.Message}");
            DriverResult = DriverText.Outcome(device, new InstallResult(InstallOutcome.CouldntStart));
        }
        finally
        {
            Ready = null;
            DriverProgress = null;
        }
    }

    [RelayCommand(CanExecute = nameof(HasReady))]
    private void DiscardDriver()
    {
        if (Ready is { } ready) _pc.Drivers.Discard(ready);
        Ready = null;
    }

    // ---------------------------------------------------------------- a Store copy: the maker's link, then watching for the device

    /// <summary>The download found, shown with the maker's link (a Store copy).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowOffered), nameof(OfferFacts), nameof(ShowGetDriverButton))]
    [NotifyCanExecuteChangedFor(nameof(GetDriverCommand))]
    public partial DriverOffer? Offered { get; set; }

    public bool ShowOffered => Offered is not null;
    public string OfferFacts => Offered is { } o ? DriverText.OfferFacts(o) : "";
    public string FoundTitleLink => DriverText.FoundTitleLink(Printer);
    public string OpenLinkButton => DriverText.OpenLinkButton(Printer);
    public string OpenLinkNote => DriverText.OpenLinkNote(Printer);
    public string LookAgainButton => DriverText.LookAgainButton;

    /// <summary>The link was opened: the page watches for the device (the list's PnP and WIA reads call <see cref="CheckAgainAsync"/>).</summary>
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(GetDriverCommand))]
    public partial bool IsWaitingForInstall { get; set; }

    private bool _checking;

    [RelayCommand]
    private void OpenLink()
    {
        if (Offered is not { } offer) return;
        if (_pc.Drivers.LinkFor(offer, Printer) is not { } link)
        {
            DriverResult = DriverText.Refused(Printer, new DriverDownload(null, Refusal.Fetch, FetchProblem.NotMakersSite));
            return;
        }
        if (!_pc.Open(link.AbsoluteUri))
        {
            DriverResult = NeedsDriverText.DemoFor(Printer);
            return;
        }
        Log.Write($"[{Printer.Name}] driver link opened in the browser ({link.Host}); watching for the device");
        IsWaitingForInstall = true;
        DriverResult = DriverText.Waiting;
    }

    [RelayCommand]
    private async Task LookAgainAsync()
    {
        if (_checking) return;
        _checking = true;
        var device = Printer;
        DriverProgress = DriverText.LookingAgain;
        try
        {
            var there = await _pc.Drivers.LookAgainAsync(ct => _isThere(device, ct), CancellationToken.None);
            if (there) Found(device);
            else DriverResult = DriverText.NotYet(device);
        }
        finally
        {
            DriverProgress = null;
            _checking = false;
        }
    }

    /// <summary>While waiting for the user's install, a change Windows reported (PnP, WIA): is the device there now?</summary>
    public async Task CheckAgainAsync()
    {
        if (!IsWaitingForInstall || _checking) return;
        _checking = true;
        var device = Printer;
        try
        {
            // A failed read (WIA not answering while its service restarts) is "not yet": it never ends the list's loop that calls this.
            if (await DriverFlow.IsThereNowAsync(ct => _isThere(device, ct), CancellationToken.None)) Found(device);
        }
        finally
        {
            _checking = false;
        }
    }

    private void Found(NeedsDriverPrinter device)
    {
        IsWaitingForInstall = false;
        Offered = null;
        DriverResult = DriverText.FoundIt(device);
        Log.Write($"[{device.Name}] driver installed by the user: found");
        DriverInstalled?.Invoke(this);
    }
}
