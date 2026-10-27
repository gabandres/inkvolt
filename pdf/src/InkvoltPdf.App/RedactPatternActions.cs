using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using InkvoltPdf.Core;
using PageRange = InkvoltPdf.Core.PageRange;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Redact by Pattern: what to look for (the built-in kinds, the user's words and phrases, the user's own
/// regular expression) and on which pages; the matches are marked for redaction (<see cref="DocumentTab.MarkPatternMatches"/>)
/// to be checked and applied like any other marks. Batch's Redact Patterns action asks the same, without pages.
/// </summary>
public static class RedactPatternActions
{
    /// <summary>The last choices, offered again next time (until the app closes).</summary>
    private static RedactionPatternOptions _last = new();

    public static async Task Find(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || Ask(host, _last, tab) is not { } options || !await tab.SettleAsync()) return;
        _last = options with { Pages = null };
        await tab.MarkPatternMatches(options);
    }

    /// <summary>The dialog. With a tab it searches that document (and asks for pages); without, it sets up a batch action.
    /// Null when cancelled.</summary>
    internal static RedactionPatternOptions? Ask(Window owner, RedactionPatternOptions current, DocumentTab? tab)
    {
        var dlg = new FormDialog(owner, "Redact by Pattern", tab is not null ? "Find and Mark" : "OK", 580);
        dlg.AddNote(tab is not null
            ? "Finds text by its pattern and marks every match for redaction. Nothing is removed yet: check the marks, click any you " +
              "want to keep to unmark it, then apply them."
            : "Finds text by its pattern in each file and redacts every match at once. Pages with matches become images, as when " +
              "you apply redactions in a document; add Recognize Text (OCR) after this action to keep them searchable.");

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
        dlg.Add("Look for", grid);
        dlg.AddNote("Point at a kind to see what it matches. Card numbers and IBANs count only when their check digits are right; " +
                    "ZIP codes match any five-digit number, so they are off unless you choose them.");

        var phrases = dlg.Add("Your words and phrases (one per line)", new TextBox
        {
            Text = string.Join(Environment.NewLine, current.Phrases),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 56,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        }, top: 16);
        AutomationProperties.SetName(phrases, "Your words and phrases, one per line");

        var expression = dlg.Add("Your own pattern (a regular expression; optional)", new TextBox
        {
            Text = current.Expression ?? "",
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        }, top: 16);
        AutomationProperties.SetName(expression, "Your own pattern, a regular expression");
        const string expressionHint = @"For example CASE-\d{4} finds CASE-0412. Line breaks read as spaces.";
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
        var whole = new CheckBox { Content = "Whole words only", IsChecked = current.WholeWord, Margin = new Thickness(0, 0, 24, 0) };
        var matchCase = new CheckBox { Content = "Match case", IsChecked = current.MatchCase, ToolTip = "For your words and your pattern" };
        var options = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        options.Children.Add(whole);
        options.Children.Add(matchCase);
        dlg.Add(null, options);

        // Pages: all, or a range ("1-3, 5, 8-"), on one row.
        RadioButton? allPages = null;
        TextBox? rangeText = null;
        if (tab is not null)
        {
            allPages = new RadioButton { Content = "All pages", IsChecked = true, VerticalAlignment = VerticalAlignment.Center, MinWidth = 0, Margin = new Thickness(0, 0, 24, 0) };
            var someRadio = new RadioButton { Content = "Pages:", VerticalAlignment = VerticalAlignment.Center, MinWidth = 0 };
            var someText = rangeText = new TextBox { Width = 120, Margin = new Thickness(8, 0, 0, 0), Text = PageRange.Format(Enumerable.Range(0, tab.PageView.PageCount)) };
            AutomationProperties.SetName(someText, "Pages to search");
            someText.GotFocus += (_, _) => someRadio.IsChecked = true;
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(allPages);
            row.Children.Add(someRadio);
            row.Children.Add(someText);
            row.Children.Add(new TextBlock
            {
                Text = $"e.g. 1-3, 5, 8- (of {tab.PageView.PageCount})",
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 0, 0),
                Style = (Style)Application.Current.FindResource("Caption"),
            });
            dlg.Add("Pages", row, top: 16);
        }

        RedactionPatternOptions Options() => new()
        {
            Patterns = checks.Where(c => c.Box.IsChecked == true).Select(c => c.Pattern).ToHashSet(),
            Phrases = [.. phrases.Text.Split('\n').Select(p => p.Trim()).Where(p => p.Length > 0)],
            WholeWord = whole.IsChecked == true,
            MatchCase = matchCase.IsChecked == true,
            Expression = string.IsNullOrWhiteSpace(expression.Text) ? null : expression.Text,
        };
        int[]? pages = null;
        dlg.Validate(() =>
        {
            if (RedactionPatterns.ValidateExpression(expression.Text) is { } error) return error;
            if (Options().IsEmpty) return "Choose something to look for: a kind of text, a word or phrase, or your own pattern.";
            pages = null;
            if (tab is null || allPages!.IsChecked == true) return null;
            if (!PageRange.TryParse(rangeText!.Text, tab.PageView.PageCount, out var chosen, out var rangeError)) return rangeError;
            pages = chosen;
            return null;
        });
        if (!dlg.ShowModal()) return null;
        return Options() with { Pages = pages };
    }

    /// <summary>The line under the batch action's name.</summary>
    internal static string Describe(RedactionPatternOptions options)
    {
        var kinds = RedactionPatterns.BuiltIn.Where(options.Patterns.Contains).ToList();
        var parts = new List<string>();
        if (kinds.Count == RedactionPatterns.BuiltIn.Count) parts.Add("Every kind of text");
        else if (kinds.Count == RedactionPatterns.Defaults.Count && kinds.All(RedactionPatterns.Defaults.Contains)) parts.Add("Every kind of text but ZIP codes");
        else if (kinds.Count > 0) parts.Add(string.Join(", ", kinds.Select(RedactionPatterns.Name)));
        var phrases = options.Phrases.Count(p => !string.IsNullOrWhiteSpace(p));
        if (phrases > 0) parts.Add(phrases == 1 ? "1 word or phrase" : $"{phrases} words and phrases");
        if (!string.IsNullOrEmpty(options.Expression)) parts.Add("your pattern");
        var what = string.Join("; ", parts);
        return what.Length == 0 ? "" : char.ToUpperInvariant(what[0]) + what[1..] + "; pages with matches become images";
    }
}
