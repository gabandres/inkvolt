using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>One piece of a page in the reading order panel: its number, what it is, the start of its text.</summary>
public sealed class ReadingOrderItem(int index, int number, TagBlock block)
{
    private static readonly Brush Normal = Freeze(Color.FromRgb(0x00, 0x67, 0xC0));
    private static readonly Brush Warn = Freeze(Color.FromRgb(0xC4, 0x2B, 0x1C));

    /// <summary>The block's index in the plan.</summary>
    public int Index { get; } = index;
    public TagBlock Block { get; } = block;
    public int Number { get; } = number;

    public bool NeedsAlt => Block.Kind == TagBlockKind.Figure && !Block.Decorative && string.IsNullOrWhiteSpace(Block.Alt);

    public string Kind => Block.Kind switch
    {
        TagBlockKind.Heading => $"Heading {Block.Level}",
        TagBlockKind.List => $"List ({Block.Items.Count} {(Block.Items.Count == 1 ? "item" : "items")}{(Block.Items.Any(i => i.Level > 0) ? ", nested" : "")})",
        TagBlockKind.Table => $"Table ({Block.Rows.Count} {(Block.Rows.Count == 1 ? "row" : "rows")}{(Block.HeaderRow ? ", column headers" : "")}{(Block.HeaderColumn ? ", row headers" : "")})",
        TagBlockKind.Caption => "Caption",
        TagBlockKind.Note => "Footnote",
        TagBlockKind.Contents => $"Table of contents ({Block.Items.Count} {(Block.Items.Count == 1 ? "entry" : "entries")})",
        TagBlockKind.Formula => "Formula",
        TagBlockKind.Figure when Block.Decorative => "Picture (decorative)",
        TagBlockKind.Figure => NeedsAlt ? "Picture: needs alternate text" : "Picture",
        _ => Block.Lang is { } lang ? $"Paragraph ({lang})" : "Paragraph",
    } + (Block.ReadWith is null ? "" : $" · from page {Block.Page + 1}");

    public string Preview => Block.Kind is TagBlockKind.Figure or TagBlockKind.Formula ? Block.Alt ?? Block.Text : Block.Text.Replace('\n', ' ');

    public Brush Badge => NeedsAlt ? Warn : Normal;

    /// <summary>What a screen reader says for the item.</summary>
    public string Spoken => $"{Number}. {Kind}. {(Preview.Length > 120 ? Preview[..120] : Preview)}";

    private static Brush Freeze(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}

/// <summary>
/// Review › Reading Order and Alt Text: the plan Make Accessible writes (<see cref="AutoTag"/>), page by page, as a list
/// in reading order and as numbered boxes on the page. A piece moves by drag or Alt+Up/Down, and to the page before or
/// after with Alt+Page Up/Down (read there, its content staying where it is); a picture gets its alternate text typed,
/// marked decorative, or suggested by the user's own AI model (after the usual "what is sent, where" window), a formula
/// how it is read. Everything works from the keyboard: Page Up/Down shows the page before or after, Enter or F2 goes to
/// the selected piece's alternate text and Esc back to the list. Apply changes writes the tags again as one undo step.
/// </summary>
public partial class DocumentTab
{
    private TagPlan? _tagPlan;
    /// <summary>The document the plan was made for (or written into); another one makes it stale.</summary>
    private byte[]? _tagPlanFor;
    /// <summary>The plan is in the document as it is now (nothing to apply).</summary>
    private bool _tagPlanWritten;
    /// <summary>The person has confirmed the plan's title and language (Make Accessible's window).</summary>
    private bool _tagPlanConfirmed;
    private bool _roUpdating;
    private Point? _roDragStart;
    private CancellationTokenSource? _roSuggest;
    /// <summary>The piece to select when the list next fills (after a move to another page turned the viewer there).</summary>
    private int? _roSelect;

    private void InitReadingOrder()
    {
        ReadingOrderRail.Click += (_, _) =>
        {
            if (_pane == NavPaneKind.ReadingOrder) TogglePane(NavPaneKind.ReadingOrder);
            else _ = ShowReadingOrderAsync();
        };
        RoUp.Click += (_, _) => MoveSelected(-1);
        RoDown.Click += (_, _) => MoveSelected(1);
        RoPageBefore.Click += (_, _) => MoveSelectedToPage(-1);
        RoPageAfter.Click += (_, _) => MoveSelectedToPage(1);
        RoApply.Click += (_, _) => _ = ApplyReadingOrderAsync();
        RoSuggest.Click += (_, _) => _ = SuggestAltAsync();
        RoList.SelectionChanged += (_, _) =>
        {
            if (_roUpdating) return;
            ShowSelectedPiece();
            if (RoList.SelectedItem is ReadingOrderItem item) Viewer.Flash(item.Block.Page, item.Block.Box);
        };
        RoList.PreviewKeyDown += (_, e) =>
        {
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            switch (Keyboard.Modifiers, key)
            {
                case (ModifierKeys.Alt, Key.Up or Key.Down):
                    MoveSelected(key == Key.Up ? -1 : 1);
                    break;
                case (ModifierKeys.Alt, Key.PageUp or Key.PageDown):
                    MoveSelectedToPage(key == Key.PageUp ? -1 : 1);
                    break;
                case (ModifierKeys.None, Key.PageUp or Key.PageDown):
                    ShowReadingPage(Viewer.CurrentPage + (key == Key.PageUp ? -1 : 1));
                    break;
                case (ModifierKeys.None, Key.Enter or Key.F2) when RoFigure.Visibility == Visibility.Visible:
                    (RoAlt.IsEnabled ? (UIElement)RoAlt : RoDecorative).Focus();
                    break;
                default:
                    return;
            }
            e.Handled = true;
        };
        // Esc in the alternate text (or its buttons) goes back to the piece in the list.
        RoFigure.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape || Keyboard.Modifiers != ModifierKeys.None) return;
            FocusSelectedPiece();
            e.Handled = true;
        };
        RoList.PreviewMouseLeftButtonDown += (_, e) => _roDragStart = e.GetPosition(RoList);
        RoList.PreviewMouseMove += (_, e) =>
        {
            if (_roDragStart is not { } start || e.LeftButton != MouseButtonState.Pressed || RoList.SelectedItem is not ReadingOrderItem item) return;
            var at = e.GetPosition(RoList);
            if (Math.Abs(at.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            _roDragStart = null;
            DragDrop.DoDragDrop(RoList, item, DragDropEffects.Move);
        };
        RoList.Drop += (_, e) =>
        {
            if (e.Data.GetData(typeof(ReadingOrderItem)) is not ReadingOrderItem dragged || _tagPlan is null) return;
            var target = (e.OriginalSource as DependencyObject) is { } d ? ItemsControl.ContainerFromElement(RoList, d) as ListBoxItem : null;
            if (target?.DataContext is not ReadingOrderItem over || over.Index == dragged.Index || !MayFixOrder()) return;
            SetPlan(AutoTag.Move(_tagPlan, dragged.Index, over.Index - dragged.Index), select: over.Index);
            e.Handled = true;
        };
        RoAlt.TextChanged += (_, _) =>
        {
            if (_roUpdating || RoList.SelectedItem is not ReadingOrderItem { Block.Kind: TagBlockKind.Figure or TagBlockKind.Formula } item || _tagPlan is null) return;
            var text = RoAlt.Text;
            SetPlan(AutoTag.With(_tagPlan, item.Index, b => b with { Alt = text }), select: item.Index, keepFigureEditor: true);
        };
        RoDecorative.Click += (_, _) =>
        {
            if (RoList.SelectedItem is not ReadingOrderItem { Block.Kind: TagBlockKind.Figure } item || _tagPlan is null) return;
            var decorative = RoDecorative.IsChecked == true;
            SetPlan(AutoTag.With(_tagPlan, item.Index, b => b with { Decorative = decorative }), select: item.Index);
        };
        Viewer.CurrentPageChanged += (_, _) =>
        {
            if (_pane == NavPaneKind.ReadingOrder && _tagPlan is not null) FillReadingOrder();
        };
        Session.ContentChanged += (_, _) =>
        {
            // Another edit (or undo) since: the plan's places may not match the pages any more.
            if (_tagPlan is null || ReferenceEquals(Session.Data, _tagPlanFor)) return;
            _tagPlanWritten = false;
            if (_pane == NavPaneKind.ReadingOrder) FillReadingOrder();
        };
    }

    /// <summary>The plan is for the document as it is now.</summary>
    private bool PlanCurrent => _tagPlan is not null && ReferenceEquals(Session.Data, _tagPlanFor);

    /// <summary>Opens the panel: the plan written last, else one read from the pages now (written with Apply).</summary>
    public async Task ShowReadingOrderAsync()
    {
        if (!Session.IsPdf || !await SettleAsync()) return;
        if (!PlanCurrent)
        {
            if (Window.GetWindow(this) is not { } owner || await AccessibleActions.PlanAsync(owner, this) is not { } plan) return;
            _tagPlan = plan;
            _tagPlanFor = Session.Data;
            _tagPlanWritten = false;
            _tagPlanConfirmed = false;
        }
        ShowPane(NavPaneKind.ReadingOrder);
        _ = Dispatcher.BeginInvoke(() => RoList.Focus(), System.Windows.Threading.DispatcherPriority.Input);
    }

    /// <summary>After Make Accessible wrote <paramref name="plan"/>: the panel shows it.</summary>
    internal void ShowWrittenPlan(TagPlan plan)
    {
        _tagPlan = plan;
        _tagPlanFor = Session.Data;
        _tagPlanWritten = true;
        _tagPlanConfirmed = true;
        ReadingOrderRail.Visibility = Visibility.Visible;
        ShowPane(NavPaneKind.ReadingOrder);
    }

    private void ReadingOrderShown(bool shown)
    {
        if (!shown)
        {
            Viewer.ClearReadingOrder();
            return;
        }
        ReadingOrderRail.Visibility = Visibility.Visible;
        FillReadingOrder();
    }

    private void SetPlan(TagPlan plan, int select, bool keepFigureEditor = false)
    {
        _tagPlan = plan;
        _tagPlanWritten = false;
        FillReadingOrder(select, keepFigureEditor);
    }

    /// <summary>The list for the current page, the boxes on every page, the summary and the buttons.</summary>
    private void FillReadingOrder(int? select = null, bool keepFigureEditor = false)
    {
        if (_tagPlan is not { } plan) return;
        var stale = !ReferenceEquals(Session.Data, _tagPlanFor);
        var page = Math.Clamp(Viewer.CurrentPage, 0, Math.Max(0, plan.Pages - 1));
        var items = new List<ReadingOrderItem>();
        var boxes = new List<ReadingOrderBox>();
        var numbers = new Dictionary<int, int>();
        var selected = select ?? _roSelect ?? (RoList.SelectedItem as ReadingOrderItem)?.Index;
        var written = AutoTag.EvenHeadings(plan.Blocks); // heading levels as they are written
        var readElsewhere = 0;
        for (var i = 0; i < plan.Blocks.Count; i++)
        {
            // Numbered among the pieces read with its page (a piece moved to another page is numbered there; its box
            // stays where its content is).
            var b = written[i];
            var reading = AutoTag.ReadingPage(b);
            var n = numbers[reading] = numbers.GetValueOrDefault(reading) + 1;
            var item = new ReadingOrderItem(i, n, b);
            if (reading == page)
            {
                items.Add(item);
                if (i == _roSelect) _roSelect = null; // shown: done waiting for the viewer to turn
            }
            else if (b.Page == page) readElsewhere++;
            if (!stale) boxes.Add(new ReadingOrderBox(b.Page, b.Box, n, i == selected, item.NeedsAlt));
        }
        _roUpdating = true;
        try
        {
            RoList.ItemsSource = items;
            RoList.SelectedItem = items.FirstOrDefault(x => x.Index == selected);
            if (!keepFigureEditor) ShowSelectedPiece();
        }
        finally
        {
            _roUpdating = false;
        }
        Viewer.SetReadingOrder(boxes);
        var missing = plan.FiguresWithoutAlt;
        RoSummary.Text = stale
            ? "The document changed since this reading order was made. Choose Make Accessible again to read it anew."
            : $"{items.Count} {(items.Count == 1 ? "piece" : "pieces")} on page {page + 1}, in the order a screen reader reads them. " +
              (readElsewhere == 0 ? "" : $"{readElsewhere} {(readElsewhere == 1 ? "piece here is" : "pieces here are")} read with another page. ") +
              (missing == 0 ? "Every picture has alternate text or is decorative." : $"{missing} {(missing == 1 ? "picture needs" : "pictures need")} alternate text.") +
              (_tagPlanWritten ? " The document is tagged this way." : " Apply changes to tag the document this way.");
        RoUp.IsEnabled = RoDown.IsEnabled = RoList.IsEnabled = RoFigure.IsEnabled = !stale;
        RoPageBefore.IsEnabled = !stale && page > 0;
        RoPageAfter.IsEnabled = !stale && page < plan.Pages - 1;
        RoApply.IsEnabled = !stale && !_tagPlanWritten;
        UpdatePaneDetail();
    }

    private void ShowSelectedPiece()
    {
        // A picture's alternate text (or decorative), a formula's (what a screen reader says for it: its text to begin with).
        var figure = RoList.SelectedItem is ReadingOrderItem { Block.Kind: TagBlockKind.Figure or TagBlockKind.Formula } item ? item : null;
        RoFigure.Visibility = figure is null ? Visibility.Collapsed : Visibility.Visible;
        if (figure is null) return;
        var formula = figure.Block.Kind == TagBlockKind.Formula;
        var was = _roUpdating;
        _roUpdating = true;
        RoAlt.Text = figure.Block.Alt ?? (formula ? figure.Block.Text : "");
        RoAlt.IsEnabled = !figure.Block.Decorative;
        RoDecorative.IsChecked = figure.Block.Decorative;
        RoDecorative.Visibility = RoSuggest.Visibility = formula ? Visibility.Collapsed : Visibility.Visible;
        RoAltLabel.Text = formula ? $"How formula {figure.Number} is read" : $"Alternate text for picture {figure.Number}";
        _roUpdating = was;
    }

    /// <summary>Dev script: Alt+Up (-1) or Alt+Down (1) on the selected piece.</summary>
    internal void RoMove(int by) => MoveSelected(by);

    /// <summary>Dev script: Alt+Page Up (-1) or Alt+Page Down (1) on the selected piece.</summary>
    internal void RoMoveToPage(int by) => MoveSelectedToPage(by);

    /// <summary>Dev script: Page Up (-1) or Page Down (1) in the list.</summary>
    internal void RoShowPage(int by) => ShowReadingPage(Viewer.CurrentPage + by);

    /// <summary>Reads the selected piece with the page before (-1: after its last piece) or after (1: before its first), and shows that page.</summary>
    private void MoveSelectedToPage(int by)
    {
        if (_tagPlan is null || RoList.SelectedItem is not ReadingOrderItem item || !MayFixOrder()) return;
        var moved = AutoTag.MoveToPage(_tagPlan, item.Index, by);
        if (ReferenceEquals(moved, _tagPlan)) return;
        var block = moved.Blocks.First(b => b.Box == item.Block.Box && b.Page == item.Block.Page && b.Kind == item.Block.Kind);
        var index = moved.Blocks.ToList().IndexOf(block);
        var page = AutoTag.ReadingPage(block);
        SetPlan(moved, select: index);
        _roSelect = index;
        if (Viewer.CurrentPage != page) Viewer.GoToPage(page);
        FillReadingOrder(select: index);
        FocusSelectedPiece();
        var item2 = RoList.SelectedItem as ReadingOrderItem;
        AiActions.Announce(RoList, $"Read with page {page + 1}, place {item2?.Number}");
    }

    /// <summary>Shows another page's pieces (keyboard: Page Up/Down in the list), the first one selected.</summary>
    private void ShowReadingPage(int page)
    {
        if (_tagPlan is not { } plan || page < 0 || page >= plan.Pages || page == Viewer.CurrentPage) return;
        _roSelect = plan.Blocks.ToList().FindIndex(b => AutoTag.ReadingPage(b) == page) is var first and >= 0 ? first : null;
        Viewer.GoToPage(page);
        FillReadingOrder();
        FocusSelectedPiece();
        AiActions.Announce(RoList, $"Page {page + 1}: {RoList.Items.Count} {(RoList.Items.Count == 1 ? "piece" : "pieces")}");
    }

    /// <summary>Keyboard focus on the selected piece in the list (its row, so arrows and Alt+arrows go on from there).</summary>
    private void FocusSelectedPiece()
    {
        if (RoList.SelectedItem is null && RoList.Items.Count > 0) RoList.SelectedIndex = 0;
        RoList.UpdateLayout();
        if (RoList.SelectedItem is not null && RoList.ItemContainerGenerator.ContainerFromItem(RoList.SelectedItem) is ListBoxItem c) c.Focus();
        else RoList.Focus();
    }

    /// <summary>Fixing the reading order is Pro (<see cref="ProFeature.ReadingOrder"/>); looking at it and its alternate text stays free.</summary>
    private bool MayFixOrder() => Window.GetWindow(this) is { } owner && ProGate.Check(owner, ProFeature.ReadingOrder);

    private void MoveSelected(int by)
    {
        if (_tagPlan is null || RoList.SelectedItem is not ReadingOrderItem item || !MayFixOrder()) return;
        var moved = AutoTag.Move(_tagPlan, item.Index, by);
        if (ReferenceEquals(moved, _tagPlan)) return;
        SetPlan(moved, select: item.Index + Math.Sign(by));
        if (RoList.ItemContainerGenerator.ContainerFromItem(RoList.SelectedItem) is ListBoxItem c) c.Focus();
        AiActions.Announce(RoList, $"Moved to place {(RoList.SelectedItem as ReadingOrderItem)?.Number}");
    }

    /// <summary>Writes the tags from the plan as it is now (title and language asked first when they never were).</summary>
    private async Task ApplyReadingOrderAsync()
    {
        if (_tagPlan is not { } plan || !PlanCurrent || Window.GetWindow(this) is not MainWindow host || !ProGate.Check(host, ProFeature.ReadingOrder)) return;
        await AccessibleActions.WriteAsync(host, this, plan, ask: !_tagPlanConfirmed);
    }

    private void SetAltQuietly(string text)
    {
        var was = _roUpdating;
        _roUpdating = true;
        RoAlt.Text = text;
        _roUpdating = was;
    }

    /// <summary>Asks the user's own AI model for the selected picture's alternate text (after the "what is sent, where" window).</summary>
    private async Task SuggestAltAsync()
    {
        if (_tagPlan is not { } plan || RoList.SelectedItem is not ReadingOrderItem { Block.Kind: TagBlockKind.Figure } item ||
            Window.GetWindow(this) is not { } owner) return;
        if (AiService.Current(out var problem) is not { } config)
        {
            if (!AiActions.ShowSettings(owner, (problem is null ? "" : problem + " ") +
                    "Alternate text suggestions use your own AI model: one that reads pictures (a vision model such as llava or gemma3 in Ollama, or a cloud model)."))
                return;
            if (AiService.Current(out _) is not { } now) return;
            config = now;
        }
        byte[] png;
        try
        {
            png = await Task.Run(() => AutoTag.FigurePng(Session.Engine, item.Block.Page, item.Block.Box));
        }
        catch (Exception ex) when (ex is InvalidOperationException or MuPDFCore.MuPDFException)
        {
            Notify("The picture couldn't be rendered to send.", error: true);
            return;
        }
        var messages = AiPrompts.AltText(png, AutoTag.NearbyText(plan, item.Index), plan.Language, item.Block.Page);
        var outgoing = new AiOutgoing([messages], $"picture {item.Number} of page {item.Block.Page + 1} (as an image) and the text near it", null);
        var restricted = await AiActions.IsCopyRestrictedAsync(Session);
        if (!AiActions.ConfirmSend(owner, config, outgoing, restricted, title: "Suggest alternate text?")) return;

        _roSuggest?.Cancel();
        using var cts = _roSuggest = new CancellationTokenSource();
        RoSuggest.IsEnabled = false;
        RoAlt.IsReadOnly = true;
        var before = RoAlt.Text;
        SetAltQuietly("Asking your AI model…");
        Log.Write($"AI: alternate text, 1 picture ({png.Length:N0} bytes) to {config.Endpoint.Host}"); // never the content
        try
        {
            config = await AiService.ResolveAsync(config, cts.Token);
            using var client = AiService.CreateClient(config);
            var reply = await client.ChatAsync(messages, null, cts.Token);
            var alt = AiPrompts.CleanAltText(AiText.WithoutThinking(reply.Text, out _));
            RoAlt.IsReadOnly = false;
            SetAltQuietly(before);
            if (alt.Length > 0) RoAlt.Text = alt; // goes into the plan through TextChanged
            if (alt.Length == 0) Notify("The model sent no text. Type the alternate text, or try another model.", error: true);
            else AiActions.Announce(RoAlt, "Suggested alternate text: " + alt);
            RoAlt.Focus();
            RoAlt.SelectAll();
        }
        catch (OperationCanceledException)
        {
            RoAlt.IsReadOnly = false;
            SetAltQuietly(before);
        }
        catch (Exception ex) when (ex is AiException or System.Net.Http.HttpRequestException or System.IO.IOException)
        {
            RoAlt.IsReadOnly = false;
            SetAltQuietly(before);
            Log.Write($"AI: alternate text failed: {ex.GetType().Name}");
            Prompt.Error(owner, "No suggestion", ex is AiException ? ex.Message : AiClient.DescribeConnectionFailure(config.Endpoint, ex));
        }
        finally
        {
            RoSuggest.IsEnabled = true;
            if (ReferenceEquals(_roSuggest, cts)) _roSuggest = null;
        }
    }
}
