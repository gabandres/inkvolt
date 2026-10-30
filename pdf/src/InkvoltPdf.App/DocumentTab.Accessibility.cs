using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>One failure in the Accessibility pane's list.</summary>
public sealed class A11yItem(AccessibilityFinding finding)
{
    public AccessibilityFinding Finding { get; } = finding;
    public string Title => Finding.Element == Finding.Where ? $"{Finding.Condition} · {Finding.Where}" : $"{Finding.Condition} · {Finding.Where} · {Finding.Element}";
    public string Problem => Finding.Count > 1 && !Finding.Problem.Contains(Finding.Count.ToString(), StringComparison.Ordinal) ? $"{Finding.Problem} ({Finding.Count} times)" : Finding.Problem;
    public string Fix => "Fix: " + Finding.Fix;

    /// <summary>What a screen reader says for the item.</summary>
    public string Spoken => $"Condition {Finding.Condition}, {Finding.Where}, {Finding.Element}. {Problem} {Fix}";
}

/// <summary>One of the person's checks in the Accessibility pane (ticks are kept per tab and go into the saved report).</summary>
public sealed class A11yCheckItem(HumanCheck check, HashSet<string> done)
{
    public string Question => check.Question;
    public string How => check.How;

    public bool Done
    {
        get => done.Contains(check.Id);
        set
        {
            if (value) done.Add(check.Id);
            else done.Remove(check.Id);
        }
    }
}

/// <summary>
/// Review › Accessibility Check…: the PDF/UA-1 machine checks (<see cref="AccessibilityCheck"/>) run off the UI thread, then
/// the Accessibility pane lists what fails (choosing one scrolls to it and outlines it), keeps the person's checklist, and
/// saves the report as a web page (<see cref="AccessibilityReportHtml"/>).
/// </summary>
public partial class DocumentTab
{
    private AccessibilityReport? _a11yReport;
    private DateTime _a11yCheckedAt;
    private readonly HashSet<string> _a11yDone = new(StringComparer.Ordinal);

    /// <summary>The last accessibility check's report (null: none yet).</summary>
    public AccessibilityReport? AccessibilityReport => _a11yReport;

    private void InitAccessibility()
    {
        AccessibilityRail.Click += (_, _) => TogglePane(NavPaneKind.Accessibility);
        A11yRecheck.Click += (_, _) => _ = CheckAccessibilityAsync();
        A11ySave.Click += (_, _) => SaveAccessibilityReport();
        A11yList.SelectionChanged += (_, _) =>
        {
            if (A11yList.SelectedItem is A11yItem item) GoToFinding(item.Finding);
        };
        A11yChecklist.ItemsSource = AccessibilityCheck.HumanChecks.Select(c => new A11yCheckItem(c, _a11yDone)).ToList();
    }

    /// <summary>Runs the check with a progress window (Cancel stops it) and shows the pane. False when it didn't run.</summary>
    public async Task<bool> CheckAccessibilityAsync()
    {
        if (!Session.IsPdf || !await SettleAsync()) return false;
        var data = Session.Data;
        var password = Session.Password;
        var owner = Window.GetWindow(this);
        AccessibilityReport report;
        using (var prompt = new ProgressPrompt(owner, "Accessibility Check", "Reading the tags…"))
        {
            try
            {
                var progress = new Progress<(int Done, int Total)>(p => prompt.Report($"Checking page {p.Done:N0} of {p.Total:N0}…", (double)p.Done / Math.Max(1, p.Total)));
                report = await Task.Run(() => AccessibilityCheck.Run(data, password, progress, prompt.Token), prompt.Token);
            }
            catch (OperationCanceledException)
            {
                return false;
            }
            catch (Exception ex) when (ex is InvalidOperationException or PasswordRequiredException)
            {
                Log.Write($"Accessibility check failed: {ex}");
                Prompt.Error(owner, "The accessibility check couldn't run", ex.Message);
                return false;
            }
        }
        if (IsDisposed || !ReferenceEquals(data, Session.Data)) return false;
        Log.Write($"Accessibility check: {(report.Passed ? "passes" : $"fails {string.Join(' ', report.FailedConditions)}")}");
        ShowAccessibility(report, DateTime.Now);
        return true;
    }

    private void ShowAccessibility(AccessibilityReport report, DateTime checkedAt)
    {
        _a11yReport = report;
        _a11yCheckedAt = checkedAt;
        AccessibilityRail.Visibility = Visibility.Visible;
        var notes = report.Notes.Count == 0 ? "" : " Not checked: " + string.Join(" ", report.Notes);
        A11ySummary.Text = (report.Passed ? "Passes the machine checks of PDF/UA-1. " : "") + report.Summary + notes;
        A11yList.ItemsSource = report.Failures.Select(f => new A11yItem(f)).ToList();
        A11yNone.Visibility = report.Passed ? Visibility.Visible : Visibility.Collapsed;
        A11yList.Visibility = report.Passed ? Visibility.Collapsed : Visibility.Visible;
        A11yFailuresTab.Header = report.Passed ? "Fails (none)" : $"Fails ({report.Failures.Count})";
        A11yTabs.SelectedItem = report.Passed ? A11yPersonTab : A11yFailuresTab;
        ShowPane(NavPaneKind.Accessibility);
        // Keyboard and screen-reader users land on the result.
        Dispatcher.BeginInvoke(() =>
        {
            if (!report.Passed && A11yList.Items.Count > 0) A11yList.Focus();
            else A11yRecheck.Focus();
        }, System.Windows.Threading.DispatcherPriority.Input);
    }

    /// <summary>Scrolls to the page and outlines the element (a document-wide finding has no place).</summary>
    private void GoToFinding(AccessibilityFinding f)
    {
        if (f.Page < 0 || f.Page >= Viewer.PageCount) return;
        if (f.Box.IsEmpty) Viewer.GoToPage(f.Page);
        else Viewer.Flash(f.Page, f.Box);
    }

    private void SaveAccessibilityReport()
    {
        if (_a11yReport is not { } report || Window.GetWindow(this) is not { } owner) return;
        var name = Path.GetFileNameWithoutExtension(Session.DisplayName) + " accessibility.html";
        if (CommentFileActions.PickSave(owner, "Save Accessibility Report", "Web page (*.html)|*.html", name, Path.GetDirectoryName(Session.FilePath)) is not { } path) return;
        try
        {
            File.WriteAllText(path, AccessibilityReportHtml.Write(report, Session.DisplayName, _a11yCheckedAt, _a11yDone), new UTF8Encoding(false));
            Log.Write($"Accessibility report saved to {Log.Name(path)}");
            Notify($"Report saved: {Path.GetFileName(path)}", "Open", () =>
            {
                try
                {
                    Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
                }
                catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
                {
                    Prompt.Error(owner, "Can't open the report", ex.Message);
                }
            });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(owner, "Can't save the report", ex.Message);
        }
    }

    // ───────────────────────────── dev script ─────────────────────────────

    /// <summary><c>a11y</c>: runs the check without the progress window and shows the pane.</summary>
    internal async Task<AccessibilityReport> DevCheckAccessibility()
    {
        var report = await Task.Run(() => AccessibilityCheck.Run(Session.Data, Session.Password));
        ShowAccessibility(report, DateTime.Now);
        return report;
    }
}
