using System.IO;
using System.Windows;
using System.Windows.Controls;
using PrintDesk.App.ViewModels;

namespace PrintDesk.App.Views;

public partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

    private MainViewModel? Vm => DataContext as MainViewModel;

    /// <summary>Settings are read from the printer only when the tab is first opened.</summary>
    private void Tabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (e.OriginalSource is TabControl { SelectedItem: TabItem { Tag: "settings", Content: SettingsViewModel s } }
            && !s.IsLoaded && s.LoadCommand.CanExecute(null))
            s.LoadCommand.Execute(null);
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
        if (DroppedPdf(e) is { } path && Vm?.Selected is { } printer && File.Exists(path))
            await printer.OpenPdfAsync(path);
    }
}
