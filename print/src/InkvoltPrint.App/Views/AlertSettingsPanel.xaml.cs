using System.Windows.Controls;

namespace InkvoltPrint.App.Views;

/// <summary>The notification area and alerts part of Settings (its data: an AlertSettingsViewModel).</summary>
public partial class AlertSettingsPanel : UserControl
{
    public AlertSettingsPanel() => InitializeComponent();

    public void FocusFirst() => EnabledBox.Focus();
}
