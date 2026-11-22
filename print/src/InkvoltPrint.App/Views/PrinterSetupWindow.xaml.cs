using System.Windows;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>Set up a new printer's Wi-Fi (roadmap 4.17): the window over <see cref="PrinterSetupViewModel"/>, from Add a printer and the palette.</summary>
public partial class PrinterSetupWindow : Window
{
    private readonly PrinterSetupViewModel _model;

    private PrinterSetupWindow(PrinterSetupViewModel model)
    {
        InitializeComponent();
        _model = model;
        DataContext = model;
        model.CloseRequested += Close;
        // Closing while on the printer's network goes back first (the window stays responsive, showing it): never leave the PC there.
        Closing += (_, e) => e.Cancel = !model.MayClose(Close);
        Closed += (_, _) => model.CloseRequested -= Close;
    }

    public PrinterSetupViewModel Model => _model;

    /// <summary>The window, looking for the printers' networks at once (read only).</summary>
    public static PrinterSetupWindow Create(MainViewModel main, PcEnvironment pc)
    {
        var model = new PrinterSetupViewModel(main, pc);
        var dlg = new PrinterSetupWindow(model);
        _ = model.LookAsync();
        return dlg;
    }

    public static void Open(Window? owner, MainViewModel main, PcEnvironment pc)
    {
        var dlg = Create(main, pc);
        dlg.Owner = owner is { IsLoaded: true, IsVisible: true } ? owner : null;
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }
}
