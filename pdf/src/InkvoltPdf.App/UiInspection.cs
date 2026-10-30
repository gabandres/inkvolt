using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.App;

/// <summary>
/// Collects every visible interactive control of a window for the UI audit (<see cref="UiAudit"/>: a name a screen
/// reader can say, a target of at least 24 × 24). Dev step <c>a11yaudit</c>; the rules live in Core and are tested there.
/// </summary>
internal static class UiInspection
{
    public static IReadOnlyList<string> Audit(Window window) => UiAudit.Findings(Controls(window));

    public static IEnumerable<UiControl> Controls(Window window)
    {
        foreach (var fe in Descendants(window).OfType<FrameworkElement>())
        {
            if (!fe.IsVisible || fe.ActualWidth <= 0 || fe.ActualHeight <= 0) continue;
            if (fe is not (ButtonBase or TextBoxBase or ComboBox or Slider or TabItem or ListBoxItem or TreeViewItem or PasswordBox)) continue;
            // A control's own template parts (a combo box's toggle, a text box's clear button) are the control's, not targets of their own.
            if (fe.TemplatedParent is Control) continue;
            // A GridView's padding header (the 2 px filler after the last column) is not a target.
            if (fe is GridViewColumnHeader { Role: not GridViewColumnHeaderRole.Normal }) continue;
            yield return new UiControl(fe.GetType().Name, NameOf(fe), fe.ActualWidth, fe.ActualHeight, Where(fe, window));
        }
    }

    /// <summary>What UI Automation reports as the name: AutomationProperties.Name, a label, or the content's text.</summary>
    private static string? NameOf(FrameworkElement fe)
    {
        try { return UIElementAutomationPeer.CreatePeerForElement(fe)?.GetName(); }
        catch (Exception) { return null; }
    }

    /// <summary>The named ancestors, outermost first ("DocCommands › FindBar"), else the window's title.</summary>
    private static string Where(FrameworkElement fe, Window window)
    {
        var names = new List<string>();
        for (DependencyObject? d = fe; d is not null && d != window; d = VisualTreeHelper.GetParent(d) ?? LogicalTreeHelper.GetParent(d))
            if (d != fe && d is FrameworkElement { Name.Length: > 0 } named) names.Insert(0, named.Name);
        if (fe.Name.Length > 0) names.Add(fe.Name);
        return names.Count == 0 ? window.Title : string.Join(" › ", names.Take(4));
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            yield return child;
            foreach (var d in Descendants(child)) yield return d;
        }
    }
}
