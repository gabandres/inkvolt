using System.IO;
using System.Windows;
using Microsoft.Win32;
using InkvoltPrint.App.Presets;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>"Manage presets": edits a copy; Save replaces the presets, Cancel (Esc) leaves them as they were.</summary>
public partial class ScanPresetsDialog : Window
{
    private ScanPresetsDialog(ScanPresetsViewModel vm)
    {
        InitializeComponent();
        DataContext = vm;
        vm.PickFolder = start =>
        {
            var dlg = new OpenFolderDialog { Title = "Save scans to", InitialDirectory = start is not null && Directory.Exists(start) ? start : "" };
            return dlg.ShowDialog(this) == true ? dlg.FolderName : null;
        };
        Loaded += (_, _) => List.Focus();
    }

    private ScanPresetsViewModel Vm => (ScanPresetsViewModel)DataContext;

    /// <summary>The editor for <paramref name="library"/>; sync folders are looked up when it opens (local settings only).</summary>
    public static ScanPresetsDialog Create(ScanPresetLibrary library, string printerName) =>
        new(new ScanPresetsViewModel(library, library.IsDemo ? ScanPresetLibrary.DemoSyncFolders : ScanPresetLibrary.FindSyncFolders(), printerName));

    public static void Open(Window? owner, ScanPresetLibrary library, string printerName)
    {
        var dlg = Create(library, printerName);
        dlg.Owner = owner is { IsLoaded: true } ? owner : null;
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (Vm.Save()) DialogResult = true;
    }
}
