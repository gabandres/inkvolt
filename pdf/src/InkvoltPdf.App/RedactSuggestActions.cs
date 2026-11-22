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
    private static RedactSuggestPlan _last = new(SuggestKinds.Names | SuggestKinds.Organizations | SuggestKinds.Addresses | SuggestKinds.AccountNumbers, null, true, []);

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

        var terms = RedactionTerms.Load(TermsPath);
        var useTerms = dlg.AddCheck(Loc.Plural(terms.Count, Strings.Redact_SuggestUseList_One, Strings.Redact_SuggestUseList_Many), current.UseTerms);
        dlg.AddFooterButton(Strings.Redact_SuggestEditList).Click += (_, _) =>
        {
            if (EditTerms(dlg) is not { } saved) return;
            useTerms.Content = Loc.Plural(saved.Count, Strings.Redact_SuggestUseList_One, Strings.Redact_SuggestUseList_Many);
            if (saved.Count > 0) useTerms.IsChecked = true;
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

    /// <summary>The names and terms list, one per line, edited and kept on this PC; the saved list, or null when cancelled.</summary>
    internal static List<string>? EditTerms(Window owner)
    {
        var dlg = new FormDialog(owner, Strings.Redact_TermsTitle, Strings.Common_Save, 480);
        dlg.AddNote(Strings.Redact_TermsNote);
        var box = dlg.AddText(Strings.Redact_TermsLabel, string.Join("\r\n", RedactionTerms.Load(TermsPath)));
        box.AcceptsReturn = true;
        box.TextWrapping = TextWrapping.NoWrap;
        box.MinHeight = 200;
        box.MaxHeight = 360;
        box.VerticalContentAlignment = VerticalAlignment.Top;
        box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        box.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        if (!dlg.ShowModal()) return null;
        var terms = RedactionTerms.Parse(box.Text);
        try
        {
            RedactionTerms.Save(TermsPath, terms);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"The redaction terms list wasn't saved: {ex.GetType().Name}");
            Prompt.Error(owner, Strings.Redact_TermsTitle, Strings.Redact_TermsNotSaved);
            return null;
        }
        return terms;
    }
}
