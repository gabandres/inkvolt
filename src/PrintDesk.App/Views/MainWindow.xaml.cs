using System.ComponentModel;
using System.IO;
using System.Windows;
using PrintDesk.App.ViewModels;

namespace PrintDesk.App.Views;

public partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

    private MainViewModel? Vm => DataContext as MainViewModel;

    /// <summary>Scanned pages live only in memory until saved: don't let a stray click on X throw them away.</summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        if (Vm?.PrintersWithUnsavedScans is { Count: > 0 } printers)
        {
            var pages = printers.Sum(p => p.Scan!.Pages.Count);
            if (!ConfirmDialog.Ask(this, $"You have {pages} scanned page{(pages == 1 ? "" : "s")} that you haven't saved. Close PrintDesk anyway?",
                    "Close without saving"))
            {
                e.Cancel = true;
                if (Vm.Selected is { Scan: not null } sel && sel.Scan.HasUnsavedPages) sel.SelectedSection = PrinterViewModel.ScanSection;
                else Vm.Selected = printers[0];
            }
        }
        base.OnClosing(e);
    }

    private static string? DroppedPdf(DragEventArgs e) =>
        e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files
        && files[0].EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ? files[0] : null;

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = DroppedPdf(e) is not null && Vm?.Selected is not null ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    /// <summary>Drop a PDF anywhere on the window: it opens in the selected printer's Print section.</summary>
    private async void Window_Drop(object sender, DragEventArgs e)
    {
        try
        {
            if (DroppedPdf(e) is { } path && Vm?.Selected is { } printer && File.Exists(path))
                await printer.OpenPdfAsync(path);
        }
        catch (Exception ex)
        {
            Log.Write($"Drop failed: {ex}"); // async void: never let it escape
        }
    }
}
