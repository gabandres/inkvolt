using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Suggest Redactions… (Pro): what the user's AI assistant should look for (names, organizations, addresses,
/// account numbers, a description), the user's names and terms list, and the pages; then
/// <see cref="DocumentTab.SuggestRedactions"/>. While the assistant is off, only the list is searched; nothing is sent.
/// </summary>
public static class RedactSuggestActions
{
    /// <summary>Where the names and terms list is kept on this PC.</summary>
    internal static string TermsPath => Path.Combine(AppPaths.DataDirectory, "redaction-terms.txt");

    /// <summary>The last choices, offered again next time (until the app closes). Nothing is chosen for the assistant at first.</summary>
    private static RedactSuggestPlan _last = new(SuggestKinds.None, null, true, []);

    public static async Task Suggest(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !ProGate.Check(host, ProFeature.RedactionSuggestions)) return;
        if (Ask(host, tab, _last) is not { } plan || !await tab.SettleAsync()) return;
        _last = plan with { Pages = [] };
        await tab.SuggestRedactions(plan);
    }

    /// <summary>The dialog; null when cancelled.</summary>
    internal static RedactSuggestPlan? Ask(Window owner, DocumentTab tab, RedactSuggestPlan current)
    {
        var config = AiService.Current(out _);
        var dlg = new FormDialog(owner, Strings.Redact_SuggestTitle, Strings.Redact_Find, 560);
        var where = dlg.AddNote(config is not null
            ? Loc.Format(Strings.Redact_SuggestNoteAi, config.Model, config.Endpoint.ReachText)
            : Strings.Redact_SuggestNoteNoAi);
        if (config is { Endpoint.Reach: AiReach.Internet }) where.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var kinds = new List<(SuggestKinds Kind, CheckBox Box)>();
        foreach (var (kind, text) in new[]
                 {
                     (SuggestKinds.Names, Strings.Redact_SuggestNames), (SuggestKinds.Organizations, Strings.Redact_SuggestOrganizations),
                     (SuggestKinds.Addresses, Strings.Redact_SuggestAddresses), (SuggestKinds.AccountNumbers, Strings.Redact_SuggestAccounts),
                 })
        {
            var box = new CheckBox
            {
                Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
                IsChecked = config is not null && current.Kinds.HasFlag(kind),
                IsEnabled = config is not null,
                Margin = new Thickness(0, 4, 12, 4),
            };
            AutomationProperties.SetName(box, text);
            if (kinds.Count % 2 == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(box, kinds.Count / 2);
            Grid.SetColumn(box, kinds.Count % 2);
            grid.Children.Add(box);
            kinds.Add((kind, box));
        }
        dlg.Add(Strings.Redact_SuggestLookFor, grid, top: 14);
        var described = dlg.AddText(Strings.Redact_SuggestDescribe, current.Description ?? "");
        described.IsEnabled = config is not null;
        described.MaxLength = RedactionSuggestions.MaxDescription;
        described.ToolTip = Strings.Redact_SuggestDescribeTip;

        var file = RedactionTerms.Read(TermsPath);
        var useTerms = dlg.AddCheck(Loc.Plural(file.Terms.Count, Strings.Redact_SuggestUseList_One, Strings.Redact_SuggestUseList_Many), current.UseTerms);
        // A list read short says so: a term it can't use must never look searched.
        var listNote = dlg.AddNote(ListProblem(file) ?? "");
        listNote.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
        listNote.Visibility = listNote.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        dlg.AddFooterButton(Strings.Redact_SuggestEditList).Click += (_, _) =>
        {
            if (EditTerms(dlg) is not { } saved) return;
            useTerms.Content = Loc.Plural(saved.Terms.Count, Strings.Redact_SuggestUseList_One, Strings.Redact_SuggestUseList_Many);
            listNote.Text = ListProblem(saved) ?? "";
            listNote.Visibility = listNote.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (saved.Terms.Count > 0) useTerms.IsChecked = true;
        };
        var range = dlg.AddRange(tab);
        range.SelectAll(); // what to keep private is usually on every page
        dlg.AddNote(Strings.Redact_SuggestReviewNote);

        int[] pages = [];
        dlg.Validate(() =>
        {
            if (!range.TryGet(out pages, out var error)) return error;
            var asksAi = kinds.Any(k => k.Box.IsChecked == true) || RedactionSuggestions.CleanDescription(described.Text).Length > 0;
            if (!asksAi && !(useTerms.IsChecked == true && RedactionTerms.Load(TermsPath).Count > 0))
                return config is null ? Strings.Redact_SuggestNeedList : Strings.Redact_SuggestNeedSomething;
            return null;
        });
        if (!dlg.ShowModal()) return null;
        var chosen = kinds.Where(k => k.Box.IsChecked == true).Aggregate(SuggestKinds.None, (a, k) => a | k.Kind);
        return new RedactSuggestPlan(config is null ? SuggestKinds.None : chosen, config is null ? null : described.Text, useTerms.IsChecked == true, pages);
    }

    /// <summary>What a list read short is missing, in words; null when it was read whole.</summary>
    internal static string? ListProblem(RedactionTermsFile file) =>
        file.TooLarge ? Loc.Format(Strings.Redact_TermsTooLarge, RedactionTerms.MaxBytes / (1 << 20))
        : file.LeftOut > 0 ? Loc.Plural(file.LeftOut, Strings.Redact_TermsLeftOut_One, Strings.Redact_TermsLeftOut_Many)
        : null;

    /// <summary>
    /// The names and terms list, one per line, edited and kept on this PC as written; the saved list, or null when
    /// cancelled. A list that can't be kept whole (a line too long, too many) isn't saved: the dialog says why.
    /// </summary>
    internal static RedactionTermsFile? EditTerms(Window owner)
    {
        var dlg = new FormDialog(owner, Strings.Redact_TermsTitle, Strings.Common_Save, 480);
        dlg.AddNote(Strings.Redact_TermsNote);
        var file = RedactionTerms.Read(TermsPath);
        if (ListProblem(file) is { } problem) dlg.AddNote(problem).SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
        var box = dlg.AddText(Strings.Redact_TermsLabel, file.Text);
        box.AcceptsReturn = true;
        box.TextWrapping = TextWrapping.NoWrap;
        box.MinHeight = 200;
        box.MaxHeight = 360;
        box.VerticalContentAlignment = VerticalAlignment.Top;
        box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        box.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        dlg.Validate(() => RedactionTerms.Check(box.Text));
        if (!dlg.ShowModal()) return null;
        try
        {
            RedactionTerms.SaveText(TermsPath, box.Text);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"The redaction terms list wasn't saved: {ex.GetType().Name}");
            Prompt.Error(owner, Strings.Redact_TermsTitle, Strings.Redact_TermsNotSaved);
            return null;
        }
        return RedactionTerms.Read(TermsPath);
    }
}
