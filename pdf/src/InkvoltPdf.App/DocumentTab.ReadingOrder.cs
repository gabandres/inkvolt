using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Review › Reading Order and Alt Text: the plan Make Accessible writes (<see cref="AutoTag"/>), page by page, as a list
/// in reading order and as numbered boxes on the page. A piece moves by drag or Alt+Up/Down, and to the page before or
/// after with Alt+Page Up/Down (read there, its content staying where it is); a picture gets its alternate text typed,
/// marked decorative, or suggested by the user's own AI model (after the usual "what is sent, where" window), a formula
/// how it is read. Everything works from the keyboard: Page Up/Down shows the page before or after, Enter or F2 goes to
/// the selected piece's alternate text and Esc back to the list. Apply changes writes the tags again as one undo step.
/// What the panel shows and what each action does to the plan is Core's <see cref="ReadingOrderPane"/>; this file turns
/// clicks, keys and drags into its inputs and shows what it says.
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
                    ShowReadingPage(key == Key.PageUp ? -1 : 1);
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
            if (target?.DataContext is not ReadingOrderItem over || over.Index == dragged.Index || !MayFix(ReadingOrderEdit.Drop)) return;
            SetPlan(ReadingOrderPane.Dropped(_tagPlan, dragged.Index, over.Index), select: over.Index);
            e.Handled = true;
        };
        RoAlt.TextChanged += (_, _) =>
        {
            if (_roUpdating || RoList.SelectedItem is not ReadingOrderItem item || _tagPlan is null) return;
            var plan = ReadingOrderPane.WithAlt(_tagPlan, item.Index, RoAlt.Text);
            if (!ReferenceEquals(plan, _tagPlan)) SetPlan(plan, select: item.Index, keepFigureEditor: true);
        };
        RoKind.SelectionChanged += (_, _) =>
        {
            if (_roUpdating || RoKind.SelectedItem is not PieceKind kind) return;
            ChangeSelectedKind(kind);
        };
        RoDecorative.Click += (_, _) =>
        {
            if (RoList.SelectedItem is not ReadingOrderItem item || _tagPlan is null) return;
            var plan = ReadingOrderPane.WithDecorative(_tagPlan, item.Index, RoDecorative.IsChecked == true);
            if (!ReferenceEquals(plan, _tagPlan)) SetPlan(plan, select: item.Index);
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

    /// <summary>The list for the current page, the boxes on every page, the summary and the buttons (<see cref="ReadingOrderPane.State"/>).</summary>
    private void FillReadingOrder(int? select = null, bool keepFigureEditor = false)
    {
        if (_tagPlan is not { } plan) return;
        var stale = !ReferenceEquals(Session.Data, _tagPlanFor);
        var selected = select ?? _roSelect ?? (RoList.SelectedItem as ReadingOrderItem)?.Index;
        var s = ReadingOrderPane.State(plan, Viewer.CurrentPage, selected, stale, _tagPlanWritten);
        if (_roSelect is { } waiting && s.Items.Any(x => x.Index == waiting)) _roSelect = null; // shown: done waiting for the viewer to turn
        _roUpdating = true;
        try
        {
            RoList.ItemsSource = s.Items;
            RoList.SelectedItem = s.Items.FirstOrDefault(x => x.Index == selected);
            if (!keepFigureEditor) ShowSelectedPiece();
        }
        finally
        {
            _roUpdating = false;
        }
        Viewer.SetReadingOrder(s.Boxes);
        RoSummary.Text = s.Summary;
        RoUp.IsEnabled = RoDown.IsEnabled = RoList.IsEnabled = RoFigure.IsEnabled = RoPiece.IsEnabled = s.Editable;
        RoPageBefore.IsEnabled = s.CanMoveToPageBefore;
        RoPageAfter.IsEnabled = s.CanMoveToPageAfter;
        RoApply.IsEnabled = s.CanApply;
        UpdatePaneDetail();
    }

    /// <summary>Makes the selected piece another kind (a Pro fix, as moving it is), keeps it selected and says what it is now.</summary>
    private void ChangeSelectedKind(PieceKind kind)
    {
        if (_tagPlan is null || RoList.SelectedItem is not ReadingOrderItem item) return;
        if (!MayFix(ReadingOrderEdit.Kind))
        {
            ShowSelectedPiece(); // the list goes back to the kind it is
            return;
        }
        var plan = ReadingOrderPane.WithKind(_tagPlan, item.Index, kind);
        if (ReferenceEquals(plan, _tagPlan)) return;
        SetPlan(plan, select: item.Index);
        AiActions.Announce(RoKind, ReadingOrderPane.KindChanged(item.Number, kind.Label));
    }

    /// <summary>Dev script: makes the selected piece <paramref name="kind"/> ("heading 2", "paragraph", "figure"…) as the kind list does.</summary>
    internal void RoSetKind(string kind)
    {
        var parts = kind.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || !Enum.TryParse<TagBlockKind>(parts[0] == "picture" ? "Figure" : parts[0], ignoreCase: true, out var k)) return;
        var level = parts.Length > 1 && int.TryParse(parts[1], out var l) ? l : k == TagBlockKind.Heading ? 1 : 0;
        if (RoKind.Items.OfType<PieceKind>().FirstOrDefault(x => x.Kind == k && x.Level == level) is { } choice) RoKind.SelectedItem = choice;
    }

    /// <summary>The selected piece's kind, to change it, and a picture's or formula's alternate text (<see cref="ReadingOrderPane.Piece"/>).</summary>
    private void ShowSelectedPiece()
    {
        var piece = RoList.SelectedItem is ReadingOrderItem selected ? ReadingOrderPane.Piece(selected) : null;
        RoPiece.Visibility = piece is null ? Visibility.Collapsed : Visibility.Visible;
        RoFigure.Visibility = piece is { HasAlt: true } ? Visibility.Visible : Visibility.Collapsed;
        if (piece is null) return;
        var was = _roUpdating;
        _roUpdating = true;
        RoKind.ItemsSource = piece.Kinds;
        RoKind.SelectedItem = piece.CurrentKind is { } current ? piece.Kinds[current] : null;
        if (piece.HasAlt)
        {
            RoAlt.Text = piece.AltText;
            RoAlt.IsEnabled = piece.AltEditable;
            RoDecorative.IsChecked = piece.Decorative;
            RoDecorative.Visibility = RoSuggest.Visibility = piece.OffersDecorative ? Visibility.Visible : Visibility.Collapsed;
            RoAltLabel.Text = piece.AltLabel;
        }
        _roUpdating = was;
    }

    /// <summary>Dev script: Alt+Up (-1) or Alt+Down (1) on the selected piece.</summary>
    internal void RoMove(int by) => MoveSelected(by);

    /// <summary>Dev script: Alt+Page Up (-1) or Alt+Page Down (1) on the selected piece.</summary>
    internal void RoMoveToPage(int by) => MoveSelectedToPage(by);

    /// <summary>Dev script: Page Up (-1) or Page Down (1) in the list.</summary>
    internal void RoShowPage(int by) => ShowReadingPage(by);

    /// <summary>Reads the selected piece with the page before (-1: after its last piece) or after (1: before its first), and shows that page.</summary>
    private void MoveSelectedToPage(int by)
    {
        if (_tagPlan is null || RoList.SelectedItem is not ReadingOrderItem item || !MayFix(ReadingOrderEdit.MoveToPage)) return;
        if (ReadingOrderPane.MovedToPage(_tagPlan, item.Index, by) is not { } moved) return;
        SetPlan(moved.Plan, select: moved.Index);
        _roSelect = moved.Index;
        if (Viewer.CurrentPage != moved.Page) Viewer.GoToPage(moved.Page);
        FillReadingOrder(select: moved.Index);
        FocusSelectedPiece();
        AiActions.Announce(RoList, ReadingOrderPane.ReadWith(moved.Page, (RoList.SelectedItem as ReadingOrderItem)?.Number));
    }

    /// <summary>Shows the page before (-1) or after (1) in the list (keyboard: Page Up/Down), its first piece selected.</summary>
    private void ShowReadingPage(int by)
    {
        if (_tagPlan is not { } plan || ReadingOrderPane.PageShown(plan, Viewer.CurrentPage, by) is not { } page) return;
        _roSelect = ReadingOrderPane.FirstPiece(plan, page);
        Viewer.GoToPage(page);
        FillReadingOrder();
        FocusSelectedPiece();
        AiActions.Announce(RoList, ReadingOrderPane.PagePieces(RoList.Items.Count, page));
    }

    /// <summary>Keyboard focus on the selected piece in the list (its row, so arrows and Alt+arrows go on from there).</summary>
    private void FocusSelectedPiece()
    {
        if (RoList.SelectedItem is null && RoList.Items.Count > 0) RoList.SelectedIndex = 0;
        RoList.UpdateLayout();
        if (RoList.SelectedItem is not null && RoList.ItemContainerGenerator.ContainerFromItem(RoList.SelectedItem) is ListBoxItem c) c.Focus();
        else RoList.Focus();
    }

    /// <summary>Whether <paramref name="edit"/> may run: the panel's fixes are Pro (<see cref="ReadingOrderPane.IsFix"/>, the Pro window asks); looking at it and its alternate text stays free.</summary>
    private bool MayFix(ReadingOrderEdit edit) =>
        !ReadingOrderPane.IsFix(edit) || (Window.GetWindow(this) is { } owner && ProGate.Check(owner, ProFeature.ReadingOrder));

    private void MoveSelected(int by)
    {
        if (_tagPlan is null || RoList.SelectedItem is not ReadingOrderItem item || !MayFix(ReadingOrderEdit.Move)) return;
        if (ReadingOrderPane.Moved(_tagPlan, item.Index, by) is not { } moved) return;
        SetPlan(moved.Plan, select: moved.Index);
        if (RoList.ItemContainerGenerator.ContainerFromItem(RoList.SelectedItem) is ListBoxItem c) c.Focus();
        AiActions.Announce(RoList, ReadingOrderPane.MovedTo((RoList.SelectedItem as ReadingOrderItem)?.Number));
    }

    /// <summary>Writes the tags from the plan as it is now (title and language asked first when they never were).</summary>
    private async Task ApplyReadingOrderAsync()
    {
        if (_tagPlan is not { } plan || !PlanCurrent || Window.GetWindow(this) is not MainWindow host || !MayFix(ReadingOrderEdit.Apply)) return;
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
                    Strings.ReadingOrder_AiSettingsNote))
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
            Notify(Strings.ReadingOrder_RenderFailed, error: true);
            return;
        }
        var messages = AiPrompts.AltText(png, AutoTag.NearbyText(plan, item.Index), plan.Language, item.Block.Page);
        var outgoing = new AiOutgoing([messages], Loc.Format(Strings.ReadingOrder_AiWhat, item.Number, item.Block.Page + 1), null);
        var restricted = await AiActions.IsCopyRestrictedAsync(Session);
        if (!AiActions.ConfirmSend(owner, config, outgoing, restricted, title: Strings.ReadingOrder_SuggestTitle)) return;

        _roSuggest?.Cancel();
        using var cts = _roSuggest = new CancellationTokenSource();
        RoSuggest.IsEnabled = false;
        RoAlt.IsReadOnly = true;
        var before = RoAlt.Text;
        SetAltQuietly(Strings.ReadingOrder_Asking);
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
            if (alt.Length == 0) Notify(Strings.ReadingOrder_NoText, error: true);
            else AiActions.Announce(RoAlt, Loc.Format(Strings.ReadingOrder_Suggested, alt));
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
            Prompt.Error(owner, Strings.ReadingOrder_NoSuggestion, ex is AiException ? ex.Message : AiClient.DescribeConnectionFailure(config.Endpoint, ex));
        }
        finally
        {
            RoSuggest.IsEnabled = true;
            if (ReferenceEquals(_roSuggest, cts)) _roSuggest = null;
        }
    }
}
