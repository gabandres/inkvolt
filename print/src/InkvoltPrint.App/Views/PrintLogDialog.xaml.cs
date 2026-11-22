using System.Windows;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>The print log (roadmap 4.9): the window over <see cref="PrintLogViewModel"/>, from the sidebar's Print log link and the palette.</summary>
public partial class PrintLogDialog : Window
{
    private PrintLogDialog(PrintLogViewModel model)
    {
        InitializeComponent();
        DataContext = model;
        Scroller.MaxHeight = SystemParameters.WorkArea.Height * 0.35;
        Closed += (_, _) => model.Dispose();
    }

    /// <summary>The window, its log read (the snapshot shows it without blocking).</summary>
    public static PrintLogDialog Create(MainViewModel main)
    {
        var model = new PrintLogViewModel(main.PrintLog, main.SetPrintLogOn);
        var dlg = new PrintLogDialog(model);
        _ = LoadAsync(model);
        return dlg;
    }

    public static void Open(Window? owner, MainViewModel main)
    {
        var dlg = Create(main);
        dlg.Owner = owner is { IsLoaded: true, IsVisible: true } ? owner : null;
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }

    private static async Task LoadAsync(PrintLogViewModel model)
    {
        try
        {
            await model.LoadAsync();
        }
        catch (Exception ex) // fire and forget: never unobserved
        {
            Log.Write($"Print log not read: {ex.Message}");
        }
    }
}
