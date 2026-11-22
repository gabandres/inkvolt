using System.Windows;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>Recent scans (roadmap 4.15): the window over <see cref="RecentScansViewModel"/>, from the Scan tab's Recent scans… link.</summary>
public partial class RecentScansDialog : Window
{
    private RecentScansDialog(RecentScansViewModel model)
    {
        InitializeComponent();
        DataContext = model;
        Scroller.MaxHeight = SystemParameters.WorkArea.Height * 0.6;
        model.CloseRequested += Close;
        Closed += (_, _) => model.CloseRequested -= Close;
    }

    /// <summary>The window, its list read (the snapshot shows it without blocking).</summary>
    public static RecentScansDialog Create(RecentScansViewModel model)
    {
        var dlg = new RecentScansDialog(model);
        _ = LoadAsync(model);
        return dlg;
    }

    public static void Open(Window? owner, RecentScansViewModel model)
    {
        var dlg = Create(model);
        dlg.Owner = owner is { IsLoaded: true, IsVisible: true } ? owner : null;
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }

    private static async Task LoadAsync(RecentScansViewModel model)
    {
        try
        {
            await model.LoadAsync();
        }
        catch (Exception ex) // fire and forget: never unobserved
        {
            Log.Write($"Recent scans not read: {ex.Message}");
        }
    }
}
