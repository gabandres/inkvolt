using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using InkvoltPdf.Core;
using PageRange = InkvoltPdf.Core.PageRange;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Redact by Pattern: what to look for (the built-in kinds, the user's words and phrases, the user's own regular
/// expression, a set saved on this PC) and on which pages; then <see cref="DocumentTab.RedactByPattern"/> lists what was
/// found to accept or skip, applies it, reads the result back and reports. Batch's Redact Patterns action asks the same,
/// without pages.
/// </summary>
public static class RedactPatternActions
{
    /// <summary>The last choices, offered again next time (until the app closes).</summary>
    private static RedactionPatternOptions _last = new();

    public static async Task Find(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || Ask(host, _last, tab) is not { } options || !await tab.SettleAsync()) return;
        _last = options with { Pages = null };
        await tab.RedactByPattern(options);
    }

    /// <summary>Where saved pattern sets live on this PC.</summary>
    internal static string SetsFolder => Path.Combine(AppPaths.DataDirectory, "redaction-patterns");

    /// <summary>The dialog. With a tab it searches that document (and asks for pages); without, it sets up a batch action.
    /// Null when cancelled.</summary>
    internal static RedactionPatternOptions? Ask(Window owner, RedactionPatternOptions current, DocumentTab? tab)
    {
        var dlg = new FormDialog(owner, Strings.Redact_PatternTitle, tab is not null ? Strings.Redact_Find : Strings.Common_OK, 580);
        dlg.AddNote(tab is not null
            ? Strings.Redact_PatternNoteTab
            : Strings.Redact_PatternNoteBatch);
        dlg.AddNote(Strings.Redact_OcrMisreads);

        // A saved set fills in the choices below.
        var (sets, setProblems) = RedactionPatternSets.List(SetsFolder);
        var setChoice = new ComboBox { MinWidth = 280 };
        var saveSet = new Button { Content = Strings.Redact_SaveSetAs, Margin = new Thickness(8, 0, 0, 0) };
        var deleteSet = new Button { Content = Strings.Common_Delete, Margin = new Thickness(8, 0, 0, 0), IsEnabled = false };
        var setRow = new StackPanel { Orientation = Orientation.Horizontal };
        setRow.Children.Add(setChoice);
        setRow.Children.Add(saveSet);
        setRow.Children.Add(deleteSet);
        AutomationProperties.SetName(setChoice, Strings.Redact_SavedSet);
        dlg.Add(Strings.Redact_SavedSet, setRow, top: 16);
        var setNote = dlg.AddNote(Strings.Redact_SavedSetNote);
        if (setProblems.Count > 0)
        {
            setNote.Text = string.Join(" ", setProblems.Take(3));
            setNote.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
        }

        // The kinds in two columns, what each matches in its tooltip, so the dialog fits a small screen.
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var checks = new List<(RedactionPattern Pattern, CheckBox Box)>();
        foreach (var pattern in RedactionPatterns.BuiltIn)
        {
            var example = RedactionPatterns.Example(pattern);
            var box = new CheckBox
            {
                Content = new TextBlock { Text = RedactionPatterns.Name(pattern), TextWrapping = TextWrapping.Wrap },
                IsChecked = current.Patterns.Contains(pattern),
                ToolTip = example,
                Margin = new Thickness(0, 4, 12, 4),
            };
            AutomationProperties.SetName(box, RedactionPatterns.Name(pattern));
            AutomationProperties.SetHelpText(box, example);
            if (checks.Count % 2 == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(box, checks.Count / 2);
            Grid.SetColumn(box, checks.Count % 2);
            grid.Children.Add(box);
            checks.Add((pattern, box));
        }
        dlg.Add(Strings.Redact_LookFor, grid);
        dlg.AddNote(Strings.Redact_KindsNote);

        var phrases = dlg.Add(Strings.Redact_PhrasesLabel, new TextBox
        {
            Text = string.Join(Environment.NewLine, current.Phrases),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 56,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        }, top: 16);
        AutomationProperties.SetName(phrases, Strings.Redact_PhrasesName);

        var expression = dlg.Add(Strings.Redact_ExpressionLabel, new TextBox
        {
            Text = current.Expression ?? "",
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        }, top: 16);
        AutomationProperties.SetName(expression, Strings.Redact_ExpressionName);
        var expressionHint = Strings.Redact_ExpressionHint;
        var expressionNote = dlg.AddNote(expressionHint);
        AutomationProperties.SetLiveSetting(expressionNote, AutomationLiveSetting.Polite);
        expression.TextChanged += (_, _) =>
        {
            var error = RedactionPatterns.ValidateExpression(expression.Text);
            expressionNote.Text = error ?? expressionHint;
            if (error is null) expressionNote.ClearValue(TextBlock.ForegroundProperty);
            else expressionNote.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
            AutomationProperties.SetHelpText(expression, error ?? "");
            UIElementAutomationPeer.CreatePeerForElement(expressionNote)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        };
        var whole = new CheckBox { Content = Strings.Redact_WholeWords, IsChecked = current.WholeWord, Margin = new Thickness(0, 0, 24, 0) };
        var matchCase = new CheckBox { Content = Strings.Redact_MatchCase, IsChecked = current.MatchCase, ToolTip = Strings.Redact_MatchCaseTip };
        var options = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        options.Children.Add(whole);
        options.Children.Add(matchCase);
        dlg.Add(null, options);

        // Pages: all, or a range ("1-3, 5, 8-"), on one row.
        RadioButton? allPages = null;
        TextBox? rangeText = null;
        if (tab is not null)
        {
            allPages = new RadioButton { Content = Strings.Common_AllPages, IsChecked = true, VerticalAlignment = VerticalAlignment.Center, MinWidth = 0, Margin = new Thickness(0, 0, 24, 0) };
            var someRadio = new RadioButton { Content = Strings.Dialog_PagesColon, VerticalAlignment = VerticalAlignment.Center, MinWidth = 0 };
            var someText = rangeText = new TextBox { Width = 120, Margin = new Thickness(8, 0, 0, 0), Text = PageRange.Format(Enumerable.Range(0, tab.PageView.PageCount)) };
            AutomationProperties.SetName(someText, Strings.Redact_PagesToSearch);
            someText.GotFocus += (_, _) => someRadio.IsChecked = true;
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(allPages);
            row.Children.Add(someRadio);
            row.Children.Add(someText);
            row.Children.Add(new TextBlock
            {
                Text = Loc.Format(Strings.Redact_PagesHint, tab.PageView.PageCount),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 0, 0),
                Style = (Style)Application.Current.FindResource("Caption"),
            });
            dlg.Add(Strings.Common_Pages, row, top: 16);
        }

        RedactionPatternOptions Options() => new()
        {
            Patterns = checks.Where(c => c.Box.IsChecked == true).Select(c => c.Pattern).ToHashSet(),
            Phrases = [.. phrases.Text.Split('\n').Select(p => p.Trim()).Where(p => p.Length > 0)],
            WholeWord = whole.IsChecked == true,
            MatchCase = matchCase.IsChecked == true,
            Expression = string.IsNullOrWhiteSpace(expression.Text) ? null : expression.Text,
        };

        void ShowSets(string? select)
        {
            var names = new List<string> { Strings.Common_None };
            names.AddRange(sets.Select(s => s.Name));
            setChoice.ItemsSource = names;
            setChoice.SelectedIndex = Math.Max(0, select is null ? 0 : names.IndexOf(select));
        }
        var loading = false;
        setChoice.SelectionChanged += (_, _) =>
        {
            deleteSet.IsEnabled = setChoice.SelectedIndex > 0;
            if (loading || setChoice.SelectedIndex <= 0) return;
            if (!ProGate.Check(dlg, ProFeature.PatternRedaction))
            {
                setChoice.SelectedIndex = 0;
                return;
            }
            var chosen = sets[setChoice.SelectedIndex - 1].Options;
            foreach (var (pattern, box) in checks) box.IsChecked = chosen.Patterns.Contains(pattern);
            phrases.Text = string.Join(Environment.NewLine, chosen.Phrases);
            expression.Text = chosen.Expression ?? "";
            whole.IsChecked = chosen.WholeWord;
            matchCase.IsChecked = chosen.MatchCase;
        };
        saveSet.Click += (_, _) =>
        {
            if (!ProGate.Check(dlg, ProFeature.PatternRedaction)) return;
            var ask = new FormDialog(dlg, Strings.Redact_SaveSetTitle, Strings.Common_Save, 440);
            var name = ask.AddText(Strings.Sign_Name, setChoice.SelectedIndex > 0 ? (string)setChoice.SelectedItem : "");
            ask.AddNote(Strings.Redact_SaveSetNote);
            ask.Validate(() =>
            {
                if (RedactionPatternSets.CleanName(name.Text).Length == 0) return Strings.Redact_NameSet;
                try
                {
                    RedactionPatternSets.Save(new RedactionPatternSet(name.Text, Options()), SetsFolder);
                    return null;
                }
                catch (Exception ex) when (ex is RedactionPatternSetException or IOException or UnauthorizedAccessException)
                {
                    return ex.Message;
                }
            });
            if (!ask.ShowModal()) return;
            (sets, _) = RedactionPatternSets.List(SetsFolder);
            loading = true;
            ShowSets(RedactionPatternSets.CleanName(name.Text));
            loading = false;
        };
        deleteSet.Click += (_, _) =>
        {
            if (setChoice.SelectedIndex <= 0) return;
            var name = sets[setChoice.SelectedIndex - 1].Name;
            if (!Prompt.Confirm(dlg, Loc.Format(Strings.Redact_DeleteSet, name), Strings.Redact_DeleteSetBody, Strings.Common_Delete, warning: true)) return;
            RedactionPatternSets.Delete(name, SetsFolder);
            (sets, _) = RedactionPatternSets.List(SetsFolder);
            loading = true;
            ShowSets(null);
            loading = false;
        };
        loading = true;
        ShowSets(current.SetName);
        loading = false;

        int[]? pages = null;
        dlg.Validate(() =>
        {
            if (RedactionPatterns.Validate(Options()) is { } error) return error;
            if (Options().IsEmpty) return Strings.Redact_ChooseSomething;
            if (Options().Expression is not null && !ProGate.Check(dlg, ProFeature.PatternRedaction)) return Pro.Locked(ProFeature.PatternRedaction);
            pages = null;
            if (tab is null || allPages!.IsChecked == true) return null;
            if (!PageRange.TryParse(rangeText!.Text, tab.PageView.PageCount, out var chosen, out var rangeError)) return rangeError;
            pages = chosen;
            return null;
        });
        if (!dlg.ShowModal()) return null;
        // The set's name stays only while what it holds is what will run.
        var set = setChoice.SelectedIndex > 0 ? sets[setChoice.SelectedIndex - 1] : null;
        var final = Options();
        var same = set is not null && final.Patterns.SetEquals(set.Options.Patterns) && final.Phrases.SequenceEqual(set.Options.Phrases)
                   && final.WholeWord == set.Options.WholeWord && final.MatchCase == set.Options.MatchCase && final.Expression == set.Options.Expression;
        return final with { Pages = pages, SetName = same ? set!.Name : null };
    }

    /// <summary>The line under the batch action's name.</summary>
    internal static string Describe(RedactionPatternOptions options)
    {
        var kinds = RedactionPatterns.BuiltIn.Where(options.Patterns.Contains).ToList();
        var parts = new List<string>();
        if (options.SetName is { } name) parts.Add(Loc.Format(Strings.Redact_DescSet, name));
        else if (kinds.Count == RedactionPatterns.BuiltIn.Count) parts.Add(Strings.Redact_DescEvery);
        else if (kinds.Count == RedactionPatterns.Defaults.Count && kinds.All(RedactionPatterns.Defaults.Contains)) parts.Add(Strings.Redact_DescEveryButZip);
        else if (kinds.Count > 0) parts.Add(string.Join(", ", kinds.Select(RedactionPatterns.Name)));
        var phrases = options.Phrases.Count(p => !string.IsNullOrWhiteSpace(p));
        if (options.SetName is null && phrases > 0) parts.Add(Loc.Plural(phrases, Strings.Redact_DescPhrases_One, Strings.Redact_DescPhrases_Many));
        if (options.SetName is null && !string.IsNullOrEmpty(options.Expression)) parts.Add(Strings.Redact_DescYourPattern);
        var what = string.Join("; ", parts);
        return what.Length == 0 ? "" : Loc.Format(Strings.Redact_DescImages, char.ToUpperInvariant(what[0]) + what[1..]);
    }
}
