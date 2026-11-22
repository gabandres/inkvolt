using System.Windows;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>Add a printer (sidebar, and the empty printer list's link): see <see cref="AddPrinterViewModel"/>.</summary>
public partial class AddPrinterWindow : Window
{
    private readonly AddPrinterViewModel _vm;

    private readonly MainViewModel _main;

    private AddPrinterWindow(MainViewModel main)
    {
        InitializeComponent();
        _main = main;
        MaxHeight = Math.Max(480, SystemParameters.WorkArea.Height - 48); // all of it on a 1080p screen; scrolls on a smaller one
        DataContext = _vm = new AddPrinterViewModel(main);
        _vm.ReadSnmpAccess = SnmpFields.Read;
        _vm.CloseRequested += Close;
        Loaded += (_, _) => _vm.Start();
        Closed += (_, _) => _vm.Dispose();
    }

    public static AddPrinterWindow Create(MainViewModel main) => new(main);

    /// <summary>Set up a new printer's Wi-Fi (roadmap 4.17); back here, the network is searched again for it.</summary>
    private void SetUpNew_Click(object sender, RoutedEventArgs e)
    {
        PrinterSetupWindow.Open(this, _main, _main.Pc);
        if (_vm.SearchCommand.CanExecute(null)) _vm.SearchCommand.Execute(null);
    }

    public static void Open(Window owner, MainViewModel main)
    {
        var dlg = new AddPrinterWindow(main) { Owner = owner.IsLoaded ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }
}
