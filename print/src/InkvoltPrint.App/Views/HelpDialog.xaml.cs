using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>Help (F1, the sidebar's "Help and shortcuts"): the keyboard shortcuts, finding a printer, What's New, Report a problem, the log, Inkvolt Pro.</summary>
public partial class HelpDialog : Window
{
    /// <summary>Key → what it does, as the Help window lists them (in the interface's language, read each time).</summary>
    public static (string Keys, string Action)[] ShortcutList =>
    [
        ("F1", Strings.Help_KeyF1),
        ("Ctrl+K", Strings.Help_KeyCommands),
        ("Ctrl+1 … Ctrl+9", Strings.Help_KeyPresets),
        ("Shift+F10", Strings.Help_KeyMenu),
        (Strings.Help_KeysAltShiftArrows, Strings.Help_KeyMovePage),
        ("S", Strings.Help_KeySplit),
        ("Delete", Strings.Help_KeyDelete),
        ("Alt+Up, Alt+Down", Strings.Help_KeyBatchMove),
        ("Ctrl+Z", Strings.Help_KeyUndo),
        ("Ctrl+R, Ctrl+L", Strings.Help_KeyTurn),
        ("Ctrl+S", Strings.Help_KeySavePdf),
        (Strings.Help_KeysPlusMinus, Strings.Help_KeyCopies),
        ("Esc", Strings.Help_KeyEsc),
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

    private void Report_Click(object sender, RoutedEventArgs e) => ReportProblemDialog.Open(this, AppHelp.Report(_vm), _vm.Selected);

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
