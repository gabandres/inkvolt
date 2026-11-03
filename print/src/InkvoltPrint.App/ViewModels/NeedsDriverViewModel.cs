using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.ViewModels;

/// <summary>
/// A USB printer on the printer list that is plugged in but can't be printed to (<see cref="NeedsDriver"/>), and its page: what's
/// wrong in plain words and what to do, step by step (the maker's driver page, Windows Update's optional updates, Settings), "Set it
/// up" once a driver is installed. The app installs and downloads nothing itself.
/// </summary>
public sealed partial class NeedsDriverViewModel : ObservableObject
{
    private readonly INeedsDriverPc _pc;

    public NeedsDriverViewModel(NeedsDriverPrinter printer, bool protectedPrint, INeedsDriverPc pc)
    {
        _pc = pc;
        Printer = printer;
        ProtectedPrintNote = NeedsDriverText.ProtectedPrint(protectedPrint);
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Id), nameof(Name), nameof(ListStatus), nameof(Headline), nameof(Where), nameof(StepGetDriver), nameof(MakerButton),
        nameof(IsNoDriver), nameof(IsNotSetUp), nameof(SetUpNote), nameof(CanSetUp))]
    public partial NeedsDriverPrinter Printer { get; set; }

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

    public string WhyMakersDriver => NeedsDriverText.WhyMakersDriver;
    public string StepPlugIn => NeedsDriverText.StepPlugIn;
    public string StepInstall => NeedsDriverText.StepInstall;
    public string ProtectedPrintTitle => NeedsDriverText.ProtectedPrintTitle;
    public string CheckWindowsButton => NeedsDriverText.CheckWindowsButton;
    public string CheckWindowsNote => NeedsDriverText.CheckWindowsNote;
    public string AddInWindowsButton => NeedsDriverText.AddInWindowsButton;
    public string AddInWindowsNote => NeedsDriverText.AddInWindowsNote;
    public string SetUpButton => NeedsDriverText.SetUpButton;
    public string StepsTitle => NeedsDriverText.StepsTitle;
    public string OtherWaysTitle => NeedsDriverText.OtherWaysTitle;

    /// <summary>A new read of the same printer: its stage or driver may have moved on.</summary>
    public void Update(NeedsDriverPrinter printer, bool protectedPrint)
    {
        if (printer != Printer) Printer = printer;
        ProtectedPrintNote = NeedsDriverText.ProtectedPrint(protectedPrint);
    }

    [RelayCommand]
    private void OpenMakerPage() => Open(DriverHelp.PageFor(Printer).AbsoluteUri);

    [RelayCommand]
    private void CheckWindows() => Open(DriverHelp.WindowsOptionalUpdates);

    [RelayCommand]
    private void AddInWindows() => Open(DriverHelp.WindowsPrinters);

    private void Open(string target)
    {
        Result = _pc.Open(target) ? null : NeedsDriverText.Demo;
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
}
