using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Review › What's in This PDF… (also from Document Properties and the Sanitize dialog): <see cref="DocumentInventory"/>
/// runs off the UI thread, then one report lists, by section, everything the file carries besides its pages and what it
/// does when opened; addresses reached without a click are marked. Save Report writes it as a web page or JSON; Sanitize
/// opens Sanitize Document. Nothing in the file is contacted.
/// </summary>
public static class InventoryActions
{
    /// <param name="host">The main window, to offer Sanitize; null from the Sanitize and Properties dialogs (no Sanitize button).</param>
    public static async Task Show(Window owner, DocumentTab tab, MainWindow? host)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        if (await Run(owner, tab) is not { } report) return;

        var sanitizable = host is not null && !report.Counts.IsClean;
        var dlg = new FormDialog(owner, "What's in This PDF", sanitizable ? "Sanitize…" : "Close", 720);
        if (sanitizable) dlg.SetCancelText("Close");
        else dlg.HideCancel();
        dlg.AddNote(report.Summary + " Nothing in the file was opened or contacted to make this report.");

        int? goTo = null;
        var list = new StackPanel();
        foreach (var section in Enum.GetValues<InventorySection>())
        {
            var items = report.In(section).ToList();
            if (items.Count == 0) continue;
            var heading = new TextBlock
            {
                Text = $"{DocumentInventory.Title(section)} ({items.Count:N0})",
                FontWeight = FontWeights.SemiBold,
                FontSize = 15,
                Margin = new Thickness(0, list.Children.Count == 0 ? 0 : 12, 0, 6),
            };
            AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
            list.Children.Add(heading);
            foreach (var i in items) list.Children.Add(Row(i, page =>
            {
                goTo = page;
                dlg.DialogResult = false;
            }));
        }
        if (list.Children.Count > 0)
        {
            var scroll = new ScrollViewer { Content = list, MaxHeight = 440, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 8, 0) };
            AutomationProperties.SetName(scroll, "What the file carries");
            dlg.Add(null, scroll, top: 14);
        }
        foreach (var note in report.Notes) dlg.AddNote(note);

        dlg.AddFooterButton("Save Report…").Click += (_, _) => SaveReport(dlg, tab, report);
        dlg.AddFooterButton("Copy Report").Click += (_, _) =>
        {
            try
            {
                Clipboard.SetText(Text(report, tab.Session.DisplayName));
            }
            catch (System.Runtime.InteropServices.COMException)
            {
                // the clipboard is busy: nothing copied
            }
        };
        var sanitize = dlg.ShowModal();
        if (goTo is { } p && !tab.IsDisposed) tab.PageView.GoToPage(p);
        else if (sanitize && sanitizable) await SanitizeActions.Sanitize(host!, tab);
    }

    /// <summary>The report with a progress window (Cancel stops it); null when cancelled, failed or the document changed meanwhile.</summary>
    internal static async Task<InventoryReport?> Run(Window owner, DocumentTab tab)
    {
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        InventoryReport report;
        using (var prompt = new ProgressPrompt(owner, "What's in this PDF", "Looking through the file…"))
        {
            try
            {
                var progress = new Progress<(int Done, int Total)>(p => prompt.Report($"Looking at the pages: step {p.Done:N0} of {p.Total:N0}…", (double)p.Done / Math.Max(1, p.Total)));
                report = await Task.Run(() => DocumentInventory.Run(data, password, progress, prompt.Token), prompt.Token);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex) when (ex is InvalidOperationException or PasswordRequiredException or OwnerPasswordRequiredException or MuPDFCore.MuPDFException)
            {
                Log.Write($"Inventory failed: {ex}");
                Prompt.Error(owner, "This document couldn't be looked through", ex.Message);
                return null;
            }
        }
        return tab.IsDisposed || !ReferenceEquals(data, tab.Session.Data) ? null : report;
    }

    private static FrameworkElement Row(InventoryItem i, Action<int> goTo)
    {
        var row = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        var head = new TextBlock { TextWrapping = TextWrapping.Wrap };
        head.Inlines.Add(new Run(i.What) { FontWeight = FontWeights.SemiBold });
        head.Inlines.Add(new Run($" · {i.Where}"));
        if (i.WithoutClick) head.Inlines.Add(new Run(" · no click needed") { FontWeight = FontWeights.SemiBold });
        if (i.Page >= 0)
        {
            var link = new Hyperlink(new Run($"Go to page {i.Page + 1}"));
            link.Click += (_, _) => goTo(i.Page);
            head.Inlines.Add(new Run("  "));
            head.Inlines.Add(link);
        }
        row.Children.Add(head);
        row.Children.Add(new TextBlock { Text = i.Detail, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Cascadia Mono, Consolas"), Margin = new Thickness(0, 2, 0, 0) });
        var caption = Caption(i);
        if (caption.Length > 0) row.Children.Add(new TextBlock { Text = caption, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.FindResource("Caption") });
        AutomationProperties.SetName(row, $"{i.What}, {i.Where}{(i.WithoutClick ? ", no click needed" : "")}: {i.Detail}. {caption}");
        row.Focusable = true;
        return row;
    }

    private static string Caption(InventoryItem i)
    {
        var parts = new List<string>();
        if (i.Calls.Count > 0) parts.Add($"It {string.Join(", ", i.Calls)}.");
        if (i.RemovedBy is not null || i.Section == InventorySection.EarlierVersions) parts.Add("Sanitize removes it.");
        else if (i.Section is InventorySection.Hidden or InventorySection.Redaction) parts.Add("Redacting its area removes it.");
        return string.Join(" ", parts);
    }

    private static void SaveReport(Window owner, DocumentTab tab, InventoryReport report)
    {
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName) + " contents";
        if (CommentFileActions.PickSave(owner, "Save the report", "Web page (*.html)|*.html|JSON (*.json)|*.json", name + ".html",
                tab.Session.FilePath is { } p ? Path.GetDirectoryName(p) : null) is not { } path) return;
        try
        {
            var text = Path.GetExtension(path).Equals(".json", StringComparison.OrdinalIgnoreCase)
                ? InventoryReportFiles.Json(report, tab.Session.DisplayName, DateTime.Now)
                : InventoryReportFiles.Html(report, tab.Session.DisplayName, DateTime.Now);
            File.WriteAllText(path, text, new UTF8Encoding(false));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(owner, "The report couldn't be saved", ex.Message);
        }
    }

    /// <summary>The report as text (Copy Report).</summary>
    internal static string Text(InventoryReport report, string fileName)
    {
        var sb = new StringBuilder("What's in this PDF: ").Append(fileName).Append('\n').Append(report.Summary).Append('\n');
        foreach (var section in Enum.GetValues<InventorySection>())
        {
            var items = report.In(section).ToList();
            if (items.Count == 0) continue;
            sb.Append('\n').Append(DocumentInventory.Title(section)).Append('\n');
            foreach (var i in items)
            {
                sb.Append("- ").Append(i.What).Append(" · ").Append(i.Where).Append(i.WithoutClick ? " (no click needed)" : "").Append(": ").Append(i.Detail.Replace('\n', ' '));
                if (i.Calls.Count > 0) sb.Append(" [it ").Append(string.Join(", ", i.Calls)).Append(']');
                sb.Append('\n');
            }
        }
        foreach (var n in report.Notes) sb.Append('\n').Append(n).Append('\n');
        return sb.ToString();
    }
}
