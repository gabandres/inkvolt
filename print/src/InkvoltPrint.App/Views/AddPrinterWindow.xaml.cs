using System.Windows;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>Add a printer (sidebar, and the empty printer list's link): see <see cref="AddPrinterViewModel"/>.</summary>
public partial class AddPrinterWindow : Window
{
    private readonly AddPrinterViewModel _vm;

    private AddPrinterWindow(MainViewModel main)
    {
        InitializeComponent();
        MaxHeight = Math.Max(480, SystemParameters.WorkArea.Height - 48); // all of it on a 1080p screen; scrolls on a smaller one
        DataContext = _vm = new AddPrinterViewModel(main);
        _vm.CloseRequested += Close;
        Loaded += (_, _) => _vm.Start();
        Closed += (_, _) => _vm.Dispose();
    }

    public static AddPrinterWindow Create(MainViewModel main) => new(main);

    public static void Open(Window owner, MainViewModel main)
    {
        var dlg = new AddPrinterWindow(main) { Owner = owner.IsLoaded ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }
}
