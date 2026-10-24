using System.ComponentModel;
using System.IO;
using System.Windows;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

public partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

    private MainViewModel? Vm => DataContext as MainViewModel;

    private void About_Click(object sender, RoutedEventArgs e) => AboutDialog.Open(this);

    /// <summary>Scanned pages live only in memory until saved: don't let a stray click on X throw them away.</summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        if (Vm?.PrintersWithUnsavedScans is { Count: > 0 } printers)
        {
            var pages = printers.Sum(p => p.Scan!.Pages.Count);
            if (!ConfirmDialog.Ask(this, $"You have {pages} scanned page{(pages == 1 ? "" : "s")} that you haven't saved. Close Inkvolt Print anyway?",
                    "Close without saving"))
            {
                e.Cancel = true;
                if (Vm.Selected is { Scan: not null } sel && sel.Scan.HasUnsavedPages) sel.SelectedSection = PrinterViewModel.ScanSection;
                else Vm.Selected = printers[0];
            }
        }
        base.OnClosing(e);
    }

    /// <summary>
    /// The printer menu is one shared instance; point it at the item it was opened on, so "Remove" can never act on
    /// a different printer than the one right-clicked (or focused, for Shift+F10).
    /// </summary>
    private void Printers_ContextMenuOpening(object sender, System.Windows.Controls.ContextMenuEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source
            && System.Windows.Controls.ItemsControl.ContainerFromElement((System.Windows.Controls.ItemsControl)sender, source)
                is System.Windows.Controls.ListBoxItem { ContextMenu: { } menu } item)
        {
            menu.DataContext = item.DataContext;
            menu.PlacementTarget = item;
        }
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
