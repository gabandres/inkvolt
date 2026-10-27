using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Check Redaction… (any PDF) and the check that follows Apply Redactions (<see cref="DocumentTab.ApplyRedactions"/>):
/// <see cref="RedactionCheck"/> runs off the UI thread, then a report lists each thing found, where, and how it can be
/// fixed; Fix redacts the areas, sanitizes the kinds that hold leftovers and rewrites the file, then checks again.
/// </summary>
public static class RedactionCheckActions
{
    public static async Task Check(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        if (await Run(tab, new RedactionCheckOptions()) is not { } report) return;
        if (report.IsClean)
        {
            Prompt.Info(host, "Redaction check", "Nothing recoverable was found: no text under boxes, highlights or redaction marks, no " +
                                                 "pictures under dark boxes, no text that doesn't show, and no earlier versions with text the pages no longer show." +
                                                 Notes(report));
            return;
        }
        await Show(tab, report, new RedactionCheckOptions());
    }

    /// <summary>The check with a progress window (Cancel stops it); null when cancelled, failed or the document changed meanwhile.</summary>
    internal static async Task<RedactionCheckReport?> Run(DocumentTab tab, RedactionCheckOptions options)
    {
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var owner = Window.GetWindow(tab);
        RedactionCheckReport report;
        using (var prompt = new ProgressPrompt(owner, "Check redaction", "Looking at the pages…"))
        {
            try
            {
                var progress = new Progress<(int Done, int Total)>(p => prompt.Report($"Checking: step {p.Done:N0} of {p.Total:N0}…", (double)p.Done / Math.Max(1, p.Total)));
                report = await Task.Run(() => RedactionCheck.Run(data, password, options, progress, prompt.Token), prompt.Token);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex) when (ex is InvalidOperationException or PasswordRequiredException or MuPDFCore.MuPDFException)
            {
                Log.Write($"Redaction check failed: {ex}");
                Prompt.Error(owner, "The redaction check couldn't run", ex.Message);
                return null;
            }
        }
        return tab.IsDisposed || !ReferenceEquals(data, tab.Session.Data) ? null : report;
    }

    /// <summary>The report. Fix (when something can be fixed) fixes it and checks again.</summary>
    /// <param name="options">What the check knew (the redacted text), for checking again after the fix.</param>
    internal static async Task Show(DocumentTab tab, RedactionCheckReport report, RedactionCheckOptions options)
    {
        if (Window.GetWindow(tab) is not { } owner) return;
        var fixable = report.Findings.Where(f => f.Fix != RedactionFix.None).ToList();
        var dlg = new FormDialog(owner, "Redaction Check", fixable.Count > 0 ? $"Fix {Count(fixable.Count, "thing", "things")}" : "Close", 680);
        if (fixable.Count == 0) dlg.HideCancel();
        else dlg.SetCancelText("Close");
        dlg.AddNote(report.Summary + (report.Findings.Count == 1 ? " It" : " Each") + " can be recovered from the file: copied, searched, or read with other tools.");

        var list = new StackPanel();
        foreach (var f in report.Findings) list.Children.Add(Row(f));
        var scroll = new ScrollViewer { Content = list, MaxHeight = 380, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 8, 0) };
        AutomationProperties.SetName(scroll, "What was found");
        dlg.Add("What was found", scroll, top: 14);

        if (fixable.Count > 0)
        {
            var areas = RedactionCheck.RedactAreas(fixable);
            var items = RedactionCheck.SanitizeItems(fixable);
            var steps = new List<string>();
            if (areas.Count > 0) steps.Add($"redacts {Count(areas.Values.Sum(a => a.Count), "area", "areas")} on {Count(areas.Count, "page", "pages")} ({(areas.Count == 1 ? "it becomes an image" : "they become images")})");
            if (items.Count > 0)
                steps.Add("removes " + string.Join("; ", SanitizeActions.Kinds.Where(k => items.Contains(k.Item)).Select(k => Lower(k.Label))));
            if (items.Count > 0 || fixable.Any(f => f.Fix == RedactionFix.Rewrite)) steps.Add("rewrites the file as one version (earlier versions and unused data go)");
            dlg.AddNote($"Fix {string.Join("; ", steps)}, then checks again. You can undo it until you save." +
                        (tab.Session.SignedOnOpen ? " This document is digitally signed: fixing rewrites it, so its signatures will no longer verify." : ""));
        }
        if (fixable.Count < report.Findings.Count)
            dlg.AddNote("What has no fix here (tags, data the document still uses) can be removed by redacting the page it belongs to, or by " +
                        "printing the document to a new PDF.");
        var notes = Notes(report);
        if (notes.Length > 0) dlg.AddNote(notes.Trim());
        dlg.AddFooterButton("Copy Report").Click += (_, _) =>
        {
            try
            {
                Clipboard.SetText(Text(report));
            }
            catch (System.Runtime.InteropServices.COMException)
            {
                // the clipboard is busy: nothing copied
            }
        };
        if (!dlg.ShowModal() || fixable.Count == 0) return;
        await tab.FixRedactionLeftovers(fixable, options);
    }

    private static FrameworkElement Row(RedactionFinding f)
    {
        var row = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        row.Children.Add(new TextBlock
        {
            Text = $"{RedactionCheck.Name(f.Kind)} · {f.Where}",
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var found = new TextBlock { Text = f.Text, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Cascadia Mono, Consolas"), Margin = new Thickness(0, 2, 0, 0) };
        row.Children.Add(found);
        row.Children.Add(new TextBlock { Text = FixText(f), TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.FindResource("Caption") });
        AutomationProperties.SetName(row, $"{RedactionCheck.Name(f.Kind)}, {f.Where}: {f.Text}. {FixText(f)}");
        row.Focusable = true;
        return row;
    }

    private static string FixText(RedactionFinding f) => f.Fix switch
    {
        RedactionFix.Redact when f.Kind == RedactionLeak.HiddenText => "Fix: the page is drawn again as an image, without what doesn't show (nothing is blacked out).",
        RedactionFix.Redact => "Fix: redact this area.",
        RedactionFix.Sanitize => $"Fix: Sanitize removes {Lower(SanitizeActions.Kinds.First(k => k.Item == f.Sanitize).Label)}.",
        RedactionFix.Rewrite => "Fix: rewrite the file as one version.",
        _ => f.Kind switch
        {
            RedactionLeak.StructureTree => "No fix here: tags stay through Sanitize. Redacting the page they describe drops its part of them.",
            _ => "No fix here.",
        },
    };

    private static string Notes(RedactionCheckReport report) =>
        string.Concat(report.Notes.Select(n => "\n\n" + n));

    /// <summary>The report as text (Copy Report).</summary>
    internal static string Text(RedactionCheckReport report)
    {
        var sb = new StringBuilder("Redaction check\n").Append(report.Summary).Append("\n\n");
        foreach (var f in report.Findings)
            sb.Append("- ").Append(RedactionCheck.Name(f.Kind)).Append(" · ").Append(f.Where).Append(": ").Append(f.Text).Append(" (").Append(FixText(f)).Append(")\n");
        foreach (var n in report.Notes) sb.Append('\n').Append(n).Append('\n');
        return sb.ToString();
    }

    private static string Lower(string s) => s.Length == 0 ? s : char.ToLowerInvariant(s[0]) + s[1..];

    private static string Count(int n, string one, string many) => n == 1 ? $"1 {one}" : $"{n:N0} {many}";
}
