using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>A line of Find &amp; Replace's list: a match, its page and the words around it, ticked to be replaced.</summary>
internal sealed class ReplaceRow(ReplaceMatch match, string where) : INotifyPropertyChanged
{
    private bool _accepted = match.Blocked is null;

    public event PropertyChangedEventHandler? PropertyChanged;

    public ReplaceMatch Match { get; } = match;

    public string Where { get; } = where;

    public string Before => Match.Before;

    public string Found => Match.Found;

    public string After => Match.After;

    /// <summary>Why it can't be replaced (its paragraph can't be edited); empty when it can.</summary>
    public string Note => Match.Blocked is { } why ? Loc.Format(PdfStrings.Edit_ParagraphCantBeEdited, why) : "";

    public Visibility NoteVisibility => Match.Blocked is null ? Visibility.Collapsed : Visibility.Visible;

    public bool CanReplace => Match.Blocked is null;

    /// <summary>What the check box does, for a screen reader.</summary>
    public string Spoken => Loc.Format(Strings.Replace_Spoken, Where, Before + Found + After);

    public bool Accepted
    {
        get => _accepted;
        set
        {
            if (_accepted == value || !CanReplace) return;
            _accepted = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Accepted)));
        }
    }
}

/// <summary>
/// Find &amp; Replace (roadmap 4.2): what to find and what to put instead, match case and whole words, and every match listed
/// with its page and the words around it as it is typed (a long document is searched off the UI thread, page by page).
/// Replace changes the selected match at once and finds again; Replace All (the dialog's OK) the ones left ticked, after
/// it closes. Enter searches; it never replaces.
/// </summary>
internal sealed class ReplaceDialog
{
    private readonly FormDialog _dialog;
    private readonly DocumentTab _tab;
    private readonly TextBox _find;
    private readonly TextBox _with;
    private readonly CheckBox _case = new() { Content = Strings.Tab_MatchCase, Margin = new Thickness(0, 0, 16, 0) };
    private readonly CheckBox _whole = new() { Content = Strings.Tab_WholeWordsOnly };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 6) };
    private readonly ListBox _list = new() { Height = 300 };
    private readonly Button _replace;
    private readonly DispatcherTimer _typing = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private List<ReplaceRow> _rows = [];
    private CancellationTokenSource? _search;
    private bool _busy;

    /// <summary>The dialog on the screen, for the developer script.</summary>
    internal static ReplaceDialog? Open { get; private set; }

    private ReplaceDialog(Window owner, DocumentTab tab)
    {
        _tab = tab;
        _dialog = new FormDialog(owner, Strings.Replace_Title, Strings.Replace_All, 640);
        _dialog.SetCancelText(Strings.Common_Close); // a Replace made meanwhile stays (Undo takes it back)
        _find = _dialog.AddText(Strings.Replace_Find, tab.LastReplaceQuery.Find);
        _with = _dialog.AddText(Strings.Replace_With, tab.LastReplaceWith);
        _case.IsChecked = tab.LastReplaceQuery.MatchCase;
        _whole.IsChecked = tab.LastReplaceQuery.WholeWord;
        _dialog.Add(null, new StackPanel { Orientation = Orientation.Horizontal, Children = { _case, _whole } });
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        _status.Text = Strings.Replace_TypeToFind;
        _dialog.Add(null, _status);

        _list.ItemTemplate = (DataTemplate)XamlReader.Parse(
            "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
            "<DockPanel Margin='0,3,4,3'>" +
            "<CheckBox DockPanel.Dock='Left' IsChecked='{Binding Accepted, Mode=TwoWay}' IsEnabled='{Binding CanReplace, Mode=OneTime}' " +
            "AutomationProperties.Name='{Binding Spoken, Mode=OneTime}' VerticalAlignment='Top' MinWidth='0' Margin='0,0,8,0' />" +
            "<StackPanel>" +
            "<TextBlock Text='{Binding Where, Mode=OneTime}' FontWeight='SemiBold' />" +
            "<TextBlock TextWrapping='Wrap' Foreground='{DynamicResource TextFillColorSecondaryBrush}'><Run Text='{Binding Before, Mode=OneTime}' />" +
            "<Run Text='{Binding Found, Mode=OneTime}' FontWeight='Bold' Foreground='{DynamicResource TextFillColorPrimaryBrush}' /><Run Text='{Binding After, Mode=OneTime}' /></TextBlock>" +
            "<TextBlock Text='{Binding Note, Mode=OneTime}' Visibility='{Binding NoteVisibility, Mode=OneTime}' TextWrapping='Wrap' Foreground='{DynamicResource SystemFillColorCautionBrush}' />" +
            "</StackPanel></DockPanel></DataTemplate>");
        ScrollViewer.SetHorizontalScrollBarVisibility(_list, ScrollBarVisibility.Disabled);
        VirtualizingPanel.SetIsVirtualizing(_list, true);
        VirtualizingPanel.SetVirtualizationMode(_list, VirtualizationMode.Recycling);
        AutomationProperties.SetName(_list, Strings.Replace_Matches);
        _list.SelectionChanged += (_, _) =>
        {
            if (_list.SelectedItem is not ReplaceRow row) return;
            _list.ScrollIntoView(row);
            _tab.PageView.GoToPage(row.Match.PageIndex, row.Match.Box.Y);
            UpdateButtons();
        };
        // Space ticks or unticks the line, wherever the focus is in it.
        _list.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Space || _list.SelectedItem is not ReplaceRow row) return;
            row.Accepted = !row.Accepted;
            e.Handled = true;
        };
        _dialog.Add(null, _list, top: 0);

        _replace = _dialog.AddFooterButton(Strings.Replace_Replace);
        _replace.ToolTip = Strings.Replace_ReplaceTip;
        _replace.Click += (_, _) => _ = ReplaceSelected();

        _typing.Tick += (_, _) =>
        {
            _typing.Stop();
            _ = Search();
        };
        _find.TextChanged += (_, _) => Restart();
        _case.Click += (_, _) => Restart();
        _whole.Click += (_, _) => Restart();
        _with.TextChanged += (_, _) => _tab.LastReplaceWith = _with.Text;
        // Enter searches at once (the dialog's OK, Replace All, is a click or Alt+its key away, never a stray Enter).
        foreach (var box in new[] { _find, _with })
            box.PreviewKeyDown += (_, e) =>
            {
                if (e.Key != Key.Enter) return;
                _typing.Stop();
                _ = Search();
                e.Handled = true;
            };
        _dialog.Validate(() => _busy ? Strings.Replace_StillWorking : _rows.Any(r => r.Accepted) ? null : Strings.Replace_NothingTicked);
        _dialog.Closed += (_, _) =>
        {
            _typing.Stop();
            _search?.Cancel();
        };
        UpdateButtons();
    }

    /// <summary>The matches to replace (ticked) and the text to put instead, or null when the dialog was closed.</summary>
    public static (IReadOnlyList<ReplaceMatch> Matches, string With)? Show(Window owner, DocumentTab tab)
    {
        var dialog = new ReplaceDialog(owner, tab);
        Open = dialog;
        try
        {
            dialog._dialog.Loaded += (_, _) =>
            {
                if (dialog._find.Text.Length > 0) _ = dialog.Search();
            };
            if (!dialog._dialog.ShowModal()) return null;
            return ([.. dialog._rows.Where(r => r.Accepted).Select(r => r.Match)], dialog._with.Text);
        }
        finally
        {
            Open = null;
        }
    }

    private ReplaceQuery Query => new(_find.Text, _case.IsChecked == true, _whole.IsChecked == true);

    private void Restart()
    {
        _typing.Stop();
        _typing.Start();
    }

    /// <summary>Finds the matches again (the previous search, if still running, is dropped).</summary>
    private async Task Search(int select = 0)
    {
        _search?.Cancel();
        var cts = _search = new CancellationTokenSource();
        var query = Query;
        _tab.LastReplaceQuery = query;
        if (query.Find.Length == 0)
        {
            Show([], Strings.Replace_TypeToFind, select);
            return;
        }
        var pages = _tab.PageView.PageCount;
        _status.Text = Loc.Format(Strings.Replace_Searching, 1, pages);
        var progress = new Progress<int>(page =>
        {
            if (!cts.IsCancellationRequested) _status.Text = Loc.Format(Strings.Replace_Searching, page, pages);
        });
        ReplaceFound found;
        try
        {
            found = await _tab.FindForReplace(query, progress, cts.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log.Write($"Find & Replace failed: {ex}");
            if (!cts.IsCancellationRequested) Show([], Strings.Replace_CantSearch, select);
            return;
        }
        if (cts.IsCancellationRequested) return;
        var status = found.Matches.Count == 0 ? Strings.Replace_None
            : Loc.Plural(found.Matches.Count, Strings.Replace_Found_One, Strings.Replace_Found_Many,
                Loc.Plural(found.Pages, Strings.Replace_Pages_One, Strings.Replace_Pages_Many));
        if (found.CutShort) status += " " + Loc.Format(Strings.Replace_CutShort, TextReplace.MaxMatches);
        if (found.Matches.Any(m => m.Blocked is not null)) status += " " + Strings.Replace_SomeBlocked;
        Show(found.Matches, status, select);
    }

    private void Show(IReadOnlyList<ReplaceMatch> matches, string status, int select)
    {
        _rows = [.. matches.Select(m => new ReplaceRow(m, Loc.Format(Strings.Viewer_PageN, _tab.PageLabel(m.PageIndex))))];
        foreach (var row in _rows) row.PropertyChanged += (_, _) => UpdateButtons();
        _list.ItemsSource = _rows;
        _status.Text = status;
        if (_rows.Count > 0) _list.SelectedIndex = Math.Clamp(select, 0, _rows.Count - 1);
        UpdateButtons();
    }

    private void UpdateButtons()
    {
        var ticked = _rows.Count(r => r.Accepted);
        _dialog.SetOkText(ticked > 1 ? Loc.Format(Strings.Replace_AllN, ticked) : Strings.Replace_All);
        _replace.IsEnabled = !_busy && _list.SelectedItem is ReplaceRow { CanReplace: true };
    }

    /// <summary>Replace: the selected match now (one undo step), then the list found again, on the next match.</summary>
    private async Task ReplaceSelected()
    {
        if (_busy || _list.SelectedItem is not ReplaceRow { CanReplace: true } row) return;
        var at = _list.SelectedIndex;
        _busy = true;
        UpdateButtons();
        try
        {
            await _tab.ReplaceMatches([row.Match], _with.Text, all: false);
        }
        finally
        {
            _busy = false;
        }
        if (!_dialog.IsVisible) return;
        await Search(at);
        _list.Focus();
    }

    // ───────────────────────────── for the developer script ─────────────────────────────

    internal async Task DevSearch(string find, bool matchCase, bool wholeWord, string with)
    {
        _find.Text = find;
        _with.Text = with;
        _case.IsChecked = matchCase;
        _whole.IsChecked = wholeWord;
        _typing.Stop();
        await Search();
    }

    internal string DevState() =>
        $"replace: '{_status.Text}' rows={_rows.Count} ticked={_rows.Count(r => r.Accepted)} selected={_list.SelectedIndex} replaceEnabled={_replace.IsEnabled}" +
        string.Concat(_rows.Take(12).Select((r, i) => $"\n  {i}: {r.Where} [{(r.Accepted ? "x" : " ")}] {r.Before}<{r.Found}>{r.After}{(r.Note.Length > 0 ? " — " + r.Note : "")}"));

    internal void DevSelect(int index) => _list.SelectedIndex = index;

    internal void DevToggle(int index) => _rows[index].Accepted = !_rows[index].Accepted;

    internal Task DevReplace() => ReplaceSelected();

    internal void DevReplaceAll() => _dialog.DialogResult = true;

    internal Window Window => _dialog;
}
