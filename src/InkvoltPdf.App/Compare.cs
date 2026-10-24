using System.IO;
using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>One side of a comparison: a PDF's bytes as they are now, with the password that opens them.</summary>
internal sealed record CompareSide(string Name, byte[] Data, string? Password);

/// <summary>File › Compare Files…: pick the original and the changed PDF (open tabs, the saved copy of a tab, or files), then compare.</summary>
internal static class Comparing
{
    /// <summary>A choice in the pickers: an open tab as it is now, the saved file behind an open tab, or a file.</summary>
    private sealed record Choice(string Label, DocumentTab? Tab, string? Path, bool Saved = false)
    {
        public override string ToString() => Label;
    }

    public static async Task Start(MainWindow host)
    {
        var choices = new List<Choice>();
        var active = host.ActiveTab;
        foreach (var t in host.OpenTabs.Where(t => t.Session.IsPdf && !t.IsDisposed))
        {
            var unsaved = t.Session.IsDirty || t.HasPendingEdits;
            choices.Add(new Choice(unsaved ? $"{t.Session.DisplayName} (open, with unsaved changes)" : $"{t.Session.DisplayName} (open)", t, null));
            if (unsaved && t.Session.FilePath is { } path && File.Exists(path))
                choices.Add(new Choice($"{t.Session.DisplayName} (as saved on disk)", t, path, Saved: true));
        }

        // Recent files that aren't open, for the other side.
        foreach (var path in AppSettings.Current.RecentFiles.Where(p => p.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)).Take(10))
        {
            if (choices.Exists(c => c.Tab?.Session.FilePath is { } open && string.Equals(open, path, StringComparison.OrdinalIgnoreCase)) || !File.Exists(path)) continue;
            choices.Add(new Choice($"{Path.GetFileName(path)} (recent)", null, path));
        }

        var dlg = new FormDialog(host, "Compare Files", "Compare", 520);
        dlg.AddNote("Shows what changed from the original to the changed version: text side by side with the differences " +
                    "highlighted, or the pages overlaid to spot changes in drawings and scans.");
        var original = Picker(dlg, host, "Original (older version)", choices);
        var changed = Picker(dlg, host, "Changed (newer version)", choices);
        var swap = new Button { Content = "Swap", Padding = new Thickness(12, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        swap.Click += (_, _) => (original.SelectedItem, changed.SelectedItem) = (changed.SelectedItem, original.SelectedItem);
        System.Windows.Automation.AutomationProperties.SetName(swap, "Swap original and changed");
        dlg.Add(null, swap);

        // An open document with unsaved changes: compare them against its saved file. Otherwise the open document is
        // the changed one, and another open tab (if any) the original.
        if (active is not null && choices.FirstOrDefault(c => c.Tab == active && c.Saved) is { } saved)
        {
            original.SelectedItem = saved;
            changed.SelectedItem = choices.First(c => c.Tab == active && !c.Saved);
        }
        else if (active is not null && choices.FirstOrDefault(c => c.Tab == active) is { } current)
        {
            changed.SelectedItem = current;
            original.SelectedItem = choices.FirstOrDefault(c => c.Tab != active && !c.Saved);
        }

        dlg.Validate(() =>
        {
            if (original.SelectedItem is null) return "Choose the original: an open document or a file (Browse…).";
            if (changed.SelectedItem is null) return "Choose the changed version: an open document or a file (Browse…).";
            return original.SelectedItem == changed.SelectedItem ? "Choose two different documents." : null;
        });
        if (!dlg.ShowModal()) return;

        // An open document's latest change (a field being typed, a drawing being written) goes in first, as for Save.
        foreach (var c in new[] { (Choice)original.SelectedItem!, (Choice)changed.SelectedItem! })
            if (c.Tab is { IsDisposed: false } t && !c.Saved) await t.FlushPendingEditsAsync();

        if (Load(host, (Choice)original.SelectedItem!) is not { } oldSide || Load(host, (Choice)changed.SelectedItem!) is not { } newSide) return;
        CompareWindow.Open(host, oldSide, newSide);
    }

    private static ComboBox Picker(FormDialog dlg, Window owner, string label, List<Choice> choices)
    {
        var combo = new ComboBox { ItemsSource = choices, MinWidth = 340 };
        System.Windows.Automation.AutomationProperties.SetName(combo, label);
        var browse = new Button { Content = "Browse…", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(browse, $"Browse for the {label.Split(' ')[0].ToLowerInvariant()} file");
        browse.Click += (_, _) =>
        {
            if (PdfFiles.PickPdf(owner, $"{label.Split(' ')[0]} file") is not { } path) return;
            var existing = choices.FirstOrDefault(c => c.Path is not null && !c.Saved && string.Equals(c.Path, path, StringComparison.OrdinalIgnoreCase));
            if (existing is null)
            {
                existing = new Choice(Path.GetFileName(path), null, path);
                choices.Add(existing);
                foreach (var c in FindCombos(dlg)) c.Items.Refresh();
            }
            combo.SelectedItem = existing;
        };
        var row = new DockPanel();
        DockPanel.SetDock(browse, Dock.Right);
        row.Children.Add(browse);
        row.Children.Add(combo);
        dlg.Add(label, row);
        return combo;
    }

    private static IEnumerable<ComboBox> FindCombos(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is ComboBox c) yield return c;
            foreach (var d in FindCombos(child)) yield return d;
        }
    }

    /// <summary>The bytes to compare. Null (after saying why) when a file can't be read or its password isn't given.</summary>
    private static CompareSide? Load(Window owner, Choice choice)
    {
        if (choice.Tab is { } tab && !choice.Saved)
        {
            if (tab.IsDisposed)
            {
                Prompt.Info(owner, "That document was closed", "Choose it again from a file.");
                return null;
            }
            return new CompareSide(tab.Session.DisplayName, tab.Session.Data, tab.Session.Password);
        }
        var path = choice.Path!;
        if (choice.Saved && choice.Tab is { } t)
        {
            // The saved file usually opens with the tab's password; if not, ask.
            try
            {
                var data = File.ReadAllBytes(path);
                using (PdfEngine.Open(data, MuPDFCore.InputFileTypes.PDF, t.Session.Password)) { }
                return new CompareSide($"{t.Session.DisplayName} (saved)", data, t.Session.Password);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or PasswordRequiredException or MuPDFCore.MuPDFException or InvalidOperationException)
            {
                // fall through to the prompting loader
            }
        }
        return PdfFiles.LoadForImport(owner, path) is { } source
            ? new CompareSide(choice.Saved ? $"{source.Name} (saved)" : source.Name, source.Data, source.Password)
            : null;
    }
}
