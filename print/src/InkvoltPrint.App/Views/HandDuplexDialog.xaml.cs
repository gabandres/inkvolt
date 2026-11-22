using System.Windows;
using System.Windows.Controls;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App.Views;

/// <summary>
/// The prompt between two-sided by hand's fronts and backs (roadmap 4.2): the steps for the way up the sheets came out, as
/// <see cref="HandDuplexPlan.Reload"/> says them (set the last sheet aside, put the stack back as it is or turned over like a page,
/// the sheets with a blank back), the face chosen first being the printer's (or the person's last answer).
/// </summary>
public partial class HandDuplexDialog : Window
{
    private readonly HandDuplexPlan _plan;

    private HandDuplexDialog(HandDuplexPlan plan, OutputFace face)
    {
        InitializeComponent();
        _plan = plan;
        Heading.Text = Core.Plural.Of(plan.Sheets, Strings.Hand_Heading_One, Strings.Hand_Heading_Many);
        (face == OutputFace.Up ? Up : Down).IsChecked = true;
        Show(face);
    }

    /// <summary>The face the person confirmed, or null when they chose not to print the backs.</summary>
    public static OutputFace? Ask(Window? owner, HandDuplexPlan plan, OutputFace face)
    {
        var dlg = new HandDuplexDialog(plan, face) { Owner = owner is { IsLoaded: true, IsVisible: true } ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        return dlg.ShowDialog() == true ? dlg.Chosen : null;
    }

    /// <summary>For the developer snapshot (<c>--dialog hand-duplex</c>): five pages and two copies, shown without blocking.</summary>
    internal static HandDuplexDialog Preview(OutputFace face) => new(HandDuplexPlan.For([0, 1, 2, 3, 4], copies: 2), face);

    private OutputFace Chosen => Up.IsChecked == true ? OutputFace.Up : OutputFace.Down;

    private void Face_Changed(object sender, RoutedEventArgs e)
    {
        if (IsInitialized && _plan is not null) Show(Chosen);
    }

    private void Show(OutputFace face)
    {
        var reload = _plan.Reload(face);
        var back = reload.Sheets - (reload.SetAside ? 1 : 0);
        var steps = new List<string>();
        if (reload.SetAside && reload.LastPage is { } last) steps.Add(string.Format(Strings.Hand_SetAside, last));
        steps.Add(reload.TurnOver
            ? Core.Plural.Of(back, Strings.Hand_StepUp_One, Strings.Hand_StepUp_Many)
            : Core.Plural.Of(back, Strings.Hand_StepDown_One, Strings.Hand_StepDown_Many));
        if (reload.BlankBacks > 0) steps.Add(Core.Plural.Of(reload.BlankBacks, Strings.Hand_BlankBacks_One, Strings.Hand_BlankBacks_Many));
        Steps.Children.Clear();
        for (var i = 0; i < steps.Count; i++)
        {
            var row = new DockPanel { Margin = new Thickness(0, i == 0 ? 0 : 8, 0, 0) };
            var number = new TextBlock { Text = $"{i + 1}.", Width = 22, FontWeight = FontWeights.SemiBold };
            DockPanel.SetDock(number, Dock.Left);
            row.Children.Add(number);
            row.Children.Add(new TextBlock { Text = steps[i], TextWrapping = TextWrapping.Wrap });
            Steps.Children.Add(row);
        }
    }

    private void PrintBacks_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
