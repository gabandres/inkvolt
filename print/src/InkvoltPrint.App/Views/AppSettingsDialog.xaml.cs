using System.Windows;
using System.Windows.Controls;

namespace InkvoltPrint.App.Views;

/// <summary>The app's own settings (the printer's are on its Printer settings tab): the theme, applied as it's picked.</summary>
public partial class AppSettingsDialog : Window
{
    private readonly AppState _state;
    private readonly bool _ready;

    private AppSettingsDialog(AppState state)
    {
        InitializeComponent();
        _state = state;
        foreach (var choice in ThemeChoices.Children.OfType<RadioButton>())
            choice.IsChecked = (string)choice.Tag == WindowFrame.Theme;
        _ready = true;
    }

    public static void Open(Window owner, AppState state)
    {
        var dlg = new AppSettingsDialog(state) { Owner = owner.IsLoaded ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }

    private void Theme_Checked(object sender, RoutedEventArgs e)
    {
        if (!_ready || sender is not RadioButton { Tag: string theme }) return;
        WindowFrame.ApplyTheme(theme);
        _state.Theme = theme == "System" ? null : theme;
        _state.Save();
    }
}
