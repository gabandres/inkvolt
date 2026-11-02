using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using InkvoltPrint.App.ViewModels;

namespace InkvoltPrint.App.Views;

/// <summary>The Fleet page. The rows' Open and Enter go to that printer's page.</summary>
public partial class FleetView : UserControl
{
    public FleetView()
    {
        InitializeComponent();
        Rows.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter || Rows.SelectedItem is not FleetRowViewModel row) return;
            row.OpenCommand.Execute(null);
            e.Handled = true;
        };
        Rows.MouseDoubleClick += (_, e) =>
        {
            if (e.OriginalSource is not DependencyObject d || ItemsControl.ContainerFromElement(Rows, d) is not ListBoxItem { DataContext: FleetRowViewModel row }) return;
            row.OpenCommand.Execute(null);
        };
    }

    /// <summary>The page just opened by keyboard: focus goes to its first row, not back to whatever opened it.</summary>
    public void FocusList()
    {
        Rows.SelectedIndex = Rows.Items.Count > 0 ? Math.Max(Rows.SelectedIndex, 0) : -1;
        Rows.UpdateLayout();
        if ((Rows.ItemContainerGenerator.ContainerFromIndex(Math.Max(Rows.SelectedIndex, 0)) as ListBoxItem) is { } item) item.Focus();
        else Rows.Focus();
    }
}
