using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>Help (F1, the sidebar's "Help and shortcuts"): the keyboard shortcuts, finding a printer, What's New, Report a problem, the log, Inkvolt Pro.</summary>
public partial class HelpDialog : Window
{
    /// <summary>Key → what it does, as the Help window lists them.</summary>
    public static readonly (string Keys, string Action)[] ShortcutList =
    [
        ("F1", "This help"),
        ("Ctrl+K", "Commands: run any command, show a printer or scan with a preset by typing its name"),
        ("Ctrl+1 … Ctrl+9", "Scan with the first nine scan presets"),
        ("Shift+F10", "The menu of the printer or page in focus"),
        ("Alt+Shift+arrows", "Scan review: move the page earlier or later"),
        ("S", "Scan review: start a new file at this page"),
        ("Delete", "Scan review, Photos: delete or remove the one in focus"),
        ("Ctrl+Z", "Scan review: undo the last change to the pages (a deleted page comes back)"),
        ("Ctrl+R, Ctrl+L", "Scan review, Photos: turn right or left"),
        ("Ctrl+S", "Scan review: save as PDF"),
        ("+ and −", "Photos: one more or one fewer copy"),
        ("Esc", "Close a dialog"),
    ];

    private readonly MainViewModel _vm;

    private HelpDialog(MainViewModel vm)
    {
        InitializeComponent();
        _vm = vm;
        var muted = (Brush)FindResource("TextFillColorSecondaryBrush");
        foreach (var (keys, action) in ShortcutList)
        {
            var row = Shortcuts.RowDefinitions.Count;
            Shortcuts.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var key = new TextBlock { Text = keys, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 12, 6) };
            var what = new TextBlock { Text = action, TextWrapping = TextWrapping.Wrap, Foreground = muted, Margin = new Thickness(0, 0, 0, 6) };
            Grid.SetRow(key, row);
            Grid.SetRow(what, row);
            Grid.SetColumn(what, 1);
            Shortcuts.Children.Add(key);
            Shortcuts.Children.Add(what);
        }
    }

    public static HelpDialog Create(MainViewModel vm) => new(vm);

    public static void Open(Window owner, MainViewModel vm)
    {
        var dlg = new HelpDialog(vm) { Owner = owner.IsLoaded ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }

    private void WhatsNew_Click(object sender, RoutedEventArgs e) => WhatsNewDialog.Open(this, AppHelp.Notes());

    private void Report_Click(object sender, RoutedEventArgs e) => ReportProblemDialog.Open(this, AppHelp.Report(_vm));

    private void Pro_Click(object sender, RoutedEventArgs e)
    {
        Close(); // Help is modal; the Pro window stays open over the main window
        ProWindow.Open(Owner);
    }

    private void LogFolder_Click(object sender, RoutedEventArgs e)
    {
        var folder = Path.GetDirectoryName(Log.FilePath)!;
        Directory.CreateDirectory(folder);
        Shell.Open(folder);
    }
}
