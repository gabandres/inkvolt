using System.Windows;
using System.Windows.Controls;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App.Views;

/// <summary>What's New: once after an update (App), and from Help any time. The notes are WHATS-NEW.md, embedded.</summary>
public partial class WhatsNewDialog : Window
{
    private WhatsNewDialog(IReadOnlyList<ReleaseNote> notes)
    {
        InitializeComponent();
        Scroller.MaxHeight = SystemParameters.WorkArea.Height * 0.6;
        if (notes.Count == 0) Entries.Children.Add(new TextBlock { Text = "No release notes in this build.", TextWrapping = TextWrapping.Wrap });
        foreach (var note in notes)
        {
            Entries.Children.Add(new TextBlock
            {
                Text = $"Version {note.Version}", Style = (Style)FindResource("CardTitle"),
                Margin = new Thickness(0, Entries.Children.Count == 0 ? 0 : 16, 0, 6),
            });
            foreach (var item in note.Items)
            {
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
                var bullet = new TextBlock { Text = "•", Margin = new Thickness(0, 0, 8, 0) };
                DockPanel.SetDock(bullet, Dock.Left);
                row.Children.Add(bullet);
                row.Children.Add(new TextBlock { Text = item, TextWrapping = TextWrapping.Wrap });
                Entries.Children.Add(row);
            }
        }
    }

    public static WhatsNewDialog Create(IReadOnlyList<ReleaseNote> notes) => new(notes);

    public static void Open(Window? owner, IReadOnlyList<ReleaseNote> notes)
    {
        var dlg = new WhatsNewDialog(notes) { Owner = owner is { IsLoaded: true, IsVisible: true } ? owner : null };
        if (dlg.Owner is null) dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        dlg.ShowDialog();
    }
}
