using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// View › Customize Command Bar… (the Mac's Customize Toolbar…): the bar's entries and <see cref="CommandBarLayout.Extras"/>
/// in a list, each ticked when it shows, in the bar's order; Move Up / Move Down (Alt+Up / Alt+Down) reorder, Reset to
/// defaults goes back to the bar as it comes. The rules (what is known, the separators) are <see cref="CommandBarLayout"/>'s.
/// </summary>
internal static class BarCustomizeDialog
{
    public static CommandBarLayout.Arrangement? Ask(Window owner, CommandBarLayout.Arrangement current, Func<string, string> nameOf)
    {
        var dlg = new FormDialog(owner, Strings.Bar_CustomizeTitle, Strings.Common_Save);
        dlg.AddNote(Strings.Bar_CustomizeNote);
        var list = new ListBox { MinHeight = 120, MaxHeight = 480 };
        VirtualizingPanel.SetIsVirtualizing(list, false); // every row's check box exists (the developer script ticks them)
        // Rows as tall as a check box, so the whole bar fits without scrolling.
        var row = new Style(typeof(ListBoxItem), (Style?)list.TryFindResource(typeof(ListBoxItem)) ?? (Style?)Application.Current.TryFindResource(typeof(ListBoxItem)));
        row.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10, 0, 10, 0)));
        row.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 34.0));
        row.Setters.Add(new Setter(FrameworkElement.HeightProperty, 36.0));
        list.ItemContainerStyle = row;
        AutomationProperties.SetName(list, Strings.Bar_CustomizeList);

        CheckBox Row(string id, bool shown)
        {
            var box = new CheckBox { Content = nameOf(id), IsChecked = shown, Tag = id };
            AutomationProperties.SetName(box, nameOf(id));
            return box;
        }
        void Fill(CommandBarLayout.Arrangement a)
        {
            list.Items.Clear();
            foreach (var id in a.Shown) list.Items.Add(Row(id, true));
            foreach (var id in a.Hidden) list.Items.Add(Row(id, false));
            list.SelectedIndex = 0;
        }
        Fill(current);
        dlg.Add(null, list);

        var up = new Button { Content = Strings.Bar_MoveUp, MinWidth = 96, Margin = new Thickness(0, 0, 8, 0) };
        var down = new Button { Content = Strings.Bar_MoveDown, MinWidth = 96 };
        void Move(int by)
        {
            var i = list.SelectedIndex;
            var to = i + by;
            if (i < 0 || to < 0 || to >= list.Items.Count) return;
            var item = list.Items[i];
            list.Items.RemoveAt(i);
            list.Items.Insert(to, item);
            list.SelectedIndex = to;
            list.ScrollIntoView(item);
            (list.ItemContainerGenerator.ContainerFromIndex(to) as ListBoxItem)?.Focus();
        }
        void Enable()
        {
            up.IsEnabled = list.SelectedIndex > 0;
            down.IsEnabled = list.SelectedIndex >= 0 && list.SelectedIndex < list.Items.Count - 1;
        }
        up.Click += (_, _) => Move(-1);
        down.Click += (_, _) => Move(1);
        list.SelectionChanged += (_, _) => Enable();
        list.PreviewKeyDown += (_, e) =>
        {
            if (Keyboard.Modifiers != ModifierKeys.Alt || e.SystemKey is not (Key.Up or Key.Down)) return;
            Move(e.SystemKey == Key.Up ? -1 : 1);
            e.Handled = true;
        };
        Enable();
        dlg.Add(null, new StackPanel { Orientation = Orientation.Horizontal, Children = { up, down } });
        dlg.AddFooterButton(Strings.Settings_ResetDefaults).Click += (_, _) => Fill(CommandBarLayout.Arrange(null));

        if (!dlg.ShowModal()) return null;
        var rows = list.Items.OfType<CheckBox>().ToList();
        return new CommandBarLayout.Arrangement(
            [.. rows.Where(r => r.IsChecked == true).Select(r => (string)r.Tag)],
            [.. rows.Where(r => r.IsChecked != true).Select(r => (string)r.Tag)]);
    }
}
