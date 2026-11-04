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
            Prompt.Info(host, Strings.Redact_CheckTitleLower, Strings.Redact_CheckClean + Notes(report));
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
        using (var prompt = new ProgressPrompt(owner, Strings.Redact_CheckProgressTitle, Strings.Redact_LookingPages))
        {
            try
            {
                var progress = new Progress<(int Done, int Total)>(p => prompt.Report(Loc.Format(Strings.Redact_CheckingStep, p.Done, p.Total), (double)p.Done / Math.Max(1, p.Total)));
                report = await Task.Run(() => RedactionCheck.Run(data, password, options, progress, prompt.Token), prompt.Token);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (Exception ex) when (ex is InvalidOperationException or PasswordRequiredException or MuPDFCore.MuPDFException)
            {
                Log.Write($"Redaction check failed: {ex}");
                Prompt.Error(owner, Strings.Redact_CheckCouldntRun, ex.Message);
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
        var dlg = new FormDialog(owner, Strings.Redact_CheckTitle, fixable.Count > 0 ? Loc.Plural(fixable.Count, Strings.Redact_CheckFix_One, Strings.Redact_CheckFix_Many) : Strings.Common_Close, 680);
        if (fixable.Count == 0) dlg.HideCancel();
        else dlg.SetCancelText(Strings.Common_Close);
        dlg.AddNote(Loc.Format(report.Findings.Count == 1 ? Strings.Redact_CheckRecoverIt : Strings.Redact_CheckRecoverEach, report.Summary));

        var list = new StackPanel();
        foreach (var f in report.Findings) list.Children.Add(Row(f));
        var scroll = new ScrollViewer { Content = list, MaxHeight = 380, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 8, 0) };
        AutomationProperties.SetName(scroll, Strings.Redact_WhatWasFound);
        dlg.Add(Strings.Redact_WhatWasFound, scroll, top: 14);

        if (fixable.Count > 0)
        {
            var areas = RedactionCheck.RedactAreas(fixable);
            var items = RedactionCheck.SanitizeItems(fixable);
            var steps = new List<string>();
            if (areas.Count > 0) steps.Add(Loc.Format(areas.Count == 1 ? Strings.Redact_StepRedactOnePage : Strings.Redact_StepRedactPages,
                Loc.Plural(areas.Values.Sum(a => a.Count), Strings.Redact_Areas_One, Strings.Redact_Areas_Many), Loc.Plural(areas.Count, Strings.Redact_Pages_One, Strings.Redact_Pages_Many)));
            if (items.Count > 0)
                steps.Add(Loc.Format(Strings.Redact_StepRemoves, string.Join("; ", SanitizeActions.Kinds.Where(k => items.Contains(k.Item)).Select(k => Lower(k.Label)))));
            if (items.Count > 0 || fixable.Any(f => f.Fix == RedactionFix.Rewrite)) steps.Add(Strings.Redact_StepRewrites);
            dlg.AddNote(Loc.Format(Strings.Redact_FixNote, string.Join("; ", steps)) +
                        (tab.Session.SignedOnOpen ? " " + Strings.Redact_FixSigned : ""));
        }
        if (fixable.Count < report.Findings.Count)
            dlg.AddNote(Strings.Redact_NoFixNote);
        var notes = Notes(report);
        if (notes.Length > 0) dlg.AddNote(notes.Trim());
        dlg.AddFooterButton(Strings.Inventory_CopyReport).Click += (_, _) =>
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
            Text = $"{RedactionCheck.Name(f.Kind)} · {f.Where}", // in every language: only names and values, no words
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var found = new TextBlock { Text = f.Text, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Cascadia Mono, Consolas"), Margin = new Thickness(0, 2, 0, 0) };
        row.Children.Add(found);
        row.Children.Add(new TextBlock { Text = FixText(f), TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.FindResource("Caption") });
        AutomationProperties.SetName(row, $"{RedactionCheck.Name(f.Kind)}, {f.Where}: {f.Text}. {FixText(f)}"); // in every language: only names and values, no words
        row.Focusable = true;
        return row;
    }

    private static string FixText(RedactionFinding f) => f.Fix switch
    {
        RedactionFix.Redact when f.Kind == RedactionLeak.HiddenText => Strings.Redact_FixHiddenText,
        RedactionFix.Redact => Strings.Redact_FixRedact,
        RedactionFix.Sanitize => Loc.Format(Strings.Redact_FixSanitize, Lower(SanitizeActions.Kinds.First(k => k.Item == f.Sanitize).Label)),
        RedactionFix.Rewrite => Strings.Redact_FixRewrite,
        _ => f.Kind switch
        {
            RedactionLeak.StructureTree => Strings.Redact_NoFixTags,
            _ => Strings.Redact_NoFix,
        },
    };

    private static string Notes(RedactionCheckReport report) =>
        string.Concat(report.Notes.Select(n => "\n\n" + n));

    /// <summary>The report as text (Copy Report).</summary>
    internal static string Text(RedactionCheckReport report)
    {
        var sb = new StringBuilder(Strings.Redact_CheckTitleLower + "\n").Append(report.Summary).Append("\n\n");
        foreach (var f in report.Findings)
            sb.Append("- ").Append(RedactionCheck.Name(f.Kind)).Append(" · ").Append(f.Where).Append(": ").Append(f.Text).Append(" (").Append(FixText(f)).Append(")\n");
        foreach (var n in report.Notes) sb.Append('\n').Append(n).Append('\n');
        return sb.ToString();
    }

    private static string Lower(string s) => s.Length == 0 ? s : char.ToLowerInvariant(s[0]) + s[1..];
}
