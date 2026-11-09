using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// A group of the command bar as Fluent's split button: the body (icon and label) runs the group's main job at once
/// (<see cref="CommandBarLayout.Entry.Main"/> with <see cref="CommandBarLayout.RunAtOnce"/>: Convert saves name.docx, Fill
/// &amp; Sign places your signature), the arrow drops the flyout of its commands. Both are tab stops with names of their
/// own, so a screen reader hears "Convert: Word (.docx)" and "Convert: more commands"; Enter or Space runs the body,
/// Alt+Down (on either part) or the arrow opens the flyout. The body shows checked while the group's tool is in use.
/// </summary>
public sealed class BarGroupButton : StackPanel
{
    public CommandBarLayout.Entry Group { get; }

    /// <summary>Runs the main job (its <see cref="ButtonBase.Command"/>, with <see cref="CommandBarLayout.RunAtOnce"/>).</summary>
    public ToggleButton Body { get; }

    /// <summary>Drops the flyout; checked while it is open.</summary>
    public ToggleButton Arrow { get; }

    /// <summary>The body's icon: the group's own, or the tool of the group in use.</summary>
    public TextBlock Icon { get; }

    /// <summary>Asks for the group's flyout under the whole button (the arrow, Alt+Down).</summary>
    public event Action<BarGroupButton>? FlyoutRequested;

    public BarGroupButton(CommandBarLayout.Entry group, RoutedUICommand main)
    {
        Group = group;
        Tag = group.Id;
        Orientation = Orientation.Horizontal;
        var label = group.Label ?? group.Id;

        Icon = new TextBlock { Text = group.Glyph ?? group.Main.Glyph, FontSize = 15 };
        Icon.SetResourceReference(StyleProperty, "Icon");
        var text = new TextBlock { Text = label, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        ToolbarPanel.SetIsLabel(text, true);
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(Icon);
        content.Children.Add(text);
        Body = new ToggleButton { Content = content, Command = main, CommandParameter = CommandBarLayout.RunAtOnce };
        Body.SetResourceReference(StyleProperty, "SplitBodyButton");

        var job = (group.Main.Title ?? main.Text).Replace("_", "", StringComparison.Ordinal).TrimEnd('…');
        var name = Loc.Format(Strings.Main_BarMainTip, label, job);
        AutomationProperties.SetName(Body, name);
        AutomationProperties.SetHelpText(Body, group.Main.Description);
        var tip = Cmd.GestureText(main) is { } gesture ? $"{name} ({gesture})" : name;
        // One click runs with the defaults where the menus open a window of options ("…"); Shift+click opens it.
        Body.ToolTip = group.Main.AtOnce && main.Text.EndsWith('…') ? tip + "\n" + Strings.Main_BarShiftTip : tip;

        Arrow = new ToggleButton { Content = "" };
        Arrow.SetResourceReference(StyleProperty, "SplitArrowButton");
        var more = Loc.Format(Strings.Main_BarMoreTip, label);
        AutomationProperties.SetName(Arrow, more);
        Arrow.ToolTip = more;
        Arrow.Click += (_, _) => FlyoutRequested?.Invoke(this);

        Children.Add(Body);
        Children.Add(Arrow);
        PreviewKeyDown += (_, e) =>
        {
            // Alt+Down, as a split button or a combo box opens its list.
            if (e.Key == Key.System && e.SystemKey == Key.Down)
            {
                e.Handled = true;
                FlyoutRequested?.Invoke(this);
            }
        };
    }
}
