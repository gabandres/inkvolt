using System.Windows;
using System.Windows.Controls;
using PrintDesk.App.ViewModels;

namespace PrintDesk.App.Views;

public partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

    /// <summary>Settings are read from the printer only when the tab is first opened.</summary>
    private void Tabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (e.OriginalSource is TabControl { SelectedItem: TabItem { Tag: "settings", Content: SettingsViewModel s } }
            && !s.IsLoaded && s.LoadCommand.CanExecute(null))
            s.LoadCommand.Execute(null);
    }
}
