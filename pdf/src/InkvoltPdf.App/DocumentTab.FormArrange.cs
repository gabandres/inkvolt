using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>What Arrange Fields does to several selected fields (FormDesignRules' Aligned, SizedAlike and Spread).</summary>
public enum FieldArrange { AlignLeft, AlignCenter, AlignRight, AlignTop, AlignMiddle, AlignBottom, SameWidth, SameHeight, SameSize, SpaceAcross, SpaceDown }

/// <summary>
/// Prepare Form, roadmap 4.12: a text field's Calculate section (sum, product, average, minimum, maximum of picked fields,
/// or simplified field notation; a custom script kept), the form's calculation order, and several fields (Ctrl+click)
/// aligned, sized alike and spaced evenly. The rules are FormDesignRules' and FormCalculations'; this fills the panel
/// and runs the edits.
/// </summary>
public partial class DocumentTab
{
    private IReadOnlyList<string>? _designSelectAfterMany; // several fields to select once the fields are read again

    private static string[] CalcLabels =>
    [
        Strings.FormDesign_CalcNone, Strings.FormDesign_CalcSum, Strings.FormDesign_CalcProduct, Strings.FormDesign_CalcAverage,
        Strings.FormDesign_CalcMinimum, Strings.FormDesign_CalcMaximum, Strings.FormDesign_CalcNotation,
    ];

    private void InitFormArrange()
    {
        FieldCalcBox.ItemsSource = CalcLabels;
        FieldCalcBox.SelectionChanged += (_, _) =>
        {
            if (_populatingDesign || FieldCalcBox.SelectedIndex is not (>= 0 and var i) || i >= FormDesignRules.CalcKinds.Count) return;
            var kind = FormDesignRules.CalcKinds[i];
            ShowCalcParts(kind);
            // Nothing picked or typed yet: wait for it (an empty notation would be refused).
            if (kind == CalcKind.Notation && FieldCalcNotation.Text.Trim().Length == 0 && FieldCalcFields.SelectedItems.Count == 0) return;
            if (kind is not (CalcKind.None or CalcKind.Notation) && FieldCalcFields.SelectedItems.Count == 0) return;
            ChangeCalculation(kind);
        };
        FieldCalcFields.SelectionChanged += (_, _) =>
        {
            if (_populatingDesign || CalcKindShown() is not { } kind || kind is CalcKind.None or CalcKind.Notation) return;
            ChangeCalculation(kind);
        };
        OnCommit(FieldCalcNotation, () =>
        {
            if (CalcKindShown() == CalcKind.Notation) ChangeCalculation(CalcKind.Notation);
        });
        FieldCalcOrder.Click += (_, _) => _ = EditCalculationOrder();

        foreach (var (button, how) in new (Button, FieldArrange)[]
        {
            (ArrangeLeft, FieldArrange.AlignLeft), (ArrangeCenter, FieldArrange.AlignCenter), (ArrangeRight, FieldArrange.AlignRight),
            (ArrangeTop, FieldArrange.AlignTop), (ArrangeMiddle, FieldArrange.AlignMiddle), (ArrangeBottom, FieldArrange.AlignBottom),
            (ArrangeWidth, FieldArrange.SameWidth), (ArrangeHeight, FieldArrange.SameHeight), (ArrangeBoth, FieldArrange.SameSize),
            (ArrangeAcross, FieldArrange.SpaceAcross), (ArrangeDown, FieldArrange.SpaceDown),
        })
        {
            var h = how;
            button.Click += (_, _) => _ = ArrangeFields(h);
        }
        SeveralDelete.Click += (_, _) => _ = OnDesignAction(DesignAction.Delete);
    }

    private CalcKind? CalcKindShown() =>
        FieldCalcBox.SelectedIndex is >= 0 and var i && i < FormDesignRules.CalcKinds.Count ? FormDesignRules.CalcKinds[i] : null;

    private void ShowCalcParts(CalcKind? kind)
    {
        var list = kind is CalcKind.Sum or CalcKind.Product or CalcKind.Average or CalcKind.Minimum or CalcKind.Maximum;
        FieldCalcFieldsCaption.Visibility = FieldCalcFields.Visibility = list ? Visibility.Visible : Visibility.Collapsed;
        FieldCalcNotationCaption.Visibility = FieldCalcNotation.Visibility = kind == CalcKind.Notation ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ChangeCalculation(CalcKind kind)
    {
        var picked = FieldCalcFields.SelectedItems.Cast<string>().ToList();
        Change(Strings.FormDesign_UndoCalculation, f => FormDesignRules.WithCalculation(f, kind, picked, FieldCalcNotation.Text, Viewer.DesignFields));
    }

    /// <summary>The Calculate section for a text field (called while the panel is being filled).</summary>
    private void ShowCalculation(DesignField f)
    {
        var labels = CalcLabels.ToList();
        var at = FormDesignRules.CalcIndex(f);
        if (at < 0) labels.Add(Strings.FormDesign_CalcCustom);
        FieldCalcBox.ItemsSource = labels;
        FieldCalcBox.SelectedIndex = at >= 0 ? at : labels.Count - 1;
        FieldCalcBox.IsEnabled = at >= 0;
        var sources = FormDesignRules.CalcSources(f, Viewer.DesignFields);
        FieldCalcFields.ItemsSource = sources;
        FieldCalcFields.SelectedItems.Clear();
        foreach (var name in f.Calculation?.Fields ?? [])
            if (sources.Contains(name)) FieldCalcFields.SelectedItems.Add(name);
        if (!FieldCalcNotation.IsKeyboardFocusWithin) SetText(FieldCalcNotation, f.Calculation is { Kind: CalcKind.Notation } n ? n.Notation : "");
        ShowCalcParts(f.Calculation?.Kind);
    }

    /// <summary>Tools › Forms › Calculation Order: the calculated fields in the order they work out, moved up or down.</summary>
    internal async Task EditCalculationOrder()
    {
        if (!Session.IsPdf) return;
        var data = Session.Data;
        var pw = Session.Password;
        IReadOnlyList<string> order;
        try
        {
            order = await Task.Run(() => FormDesign.CalculationOrder(data, pw));
        }
        catch (Exception ex) when (ex is InvalidOperationException or OwnerPasswordRequiredException)
        {
            Notify(ex.Message, error: true);
            return;
        }
        if (_disposed || !ReferenceEquals(data, Session.Data)) return;
        if (order.Count < 2)
        {
            Notify(order.Count == 0 ? Strings.FormDesign_CalcOrderNone : Strings.FormDesign_CalcOrderOne);
            return;
        }
        var picked = DevCalcOrder ?? AskCalculationOrder(order);
        DevCalcOrder = null;
        if (picked is null || picked.SequenceEqual(order)) return;
        _designSelectAfter = Viewer.SelectedDesignField?.Id;
        await RunEdit(Strings.FormDesign_UndoCalcOrder, (d, p) => FormDesign.SetCalculationOrder(d, p, picked), contentOnly: true, quiet: true);
    }

    /// <summary>DevScript's calcorder: the order the dialog would return.</summary>
    internal IReadOnlyList<string>? DevCalcOrder { get; set; }

    private IReadOnlyList<string>? AskCalculationOrder(IReadOnlyList<string> order)
    {
        var dialog = new FormDialog(Window.GetWindow(this), Strings.FormDesign_CalcOrderTitle);
        dialog.AddNote(Strings.FormDesign_CalcOrderNote);
        var items = new System.Collections.ObjectModel.ObservableCollection<string>(order);
        var list = dialog.Add(null, new ListBox { ItemsSource = items, Height = 220, SelectedIndex = 0 });
        System.Windows.Automation.AutomationProperties.SetName(list, Strings.FormDesign_CalcOrderTitle);
        var buttons = dialog.Add(null, new StackPanel { Orientation = Orientation.Horizontal });
        var error = dialog.AddNote("");
        void Move(int step)
        {
            var i = list.SelectedIndex;
            try
            {
                FormDesignRules.MovedInOrder([.. items], i, step); // refuses a move past either end
                items.Move(i, i + step);
                list.SelectedIndex = i + step;
                list.ScrollIntoView(list.SelectedItem);
                error.Text = "";
            }
            catch (DesignRefusal r)
            {
                error.Text = r.Message;
            }
        }
        foreach (var (text, step) in new[] { (Strings.Dialog_MoveUp, -1), (Strings.Dialog_MoveDown, 1) })
        {
            var b = new Button { Content = text, Margin = new Thickness(0, 0, 8, 0) };
            var s = step;
            b.Click += (_, _) => Move(s);
            buttons.Children.Add(b);
        }
        list.PreviewKeyDown += (_, e) =>
        {
            if ((Keyboard.Modifiers & ModifierKeys.Alt) == 0 || e.SystemKey is not (Key.Up or Key.Down)) return;
            Move(e.SystemKey == Key.Up ? -1 : 1);
            e.Handled = true;
        };
        return dialog.ShowModal() ? [.. items] : null;
    }

    // ───────────────────────────── Several fields ─────────────────────────────

    /// <summary>Whether Arrange Fields' <paramref name="how"/> can run: Prepare Form with two fields selected (three to space them).</summary>
    public bool CanArrangeFields(FieldArrange how) =>
        IsDesigningForm && Viewer.SelectedDesignFields.Count >= (how is FieldArrange.SpaceAcross or FieldArrange.SpaceDown ? 3 : 2);

    /// <summary>Lines up, sizes or spaces the selected fields (one undo step), the first one picked staying put
    /// (DevScript's arrange runs it too).</summary>
    internal async Task ArrangeFields(FieldArrange how)
    {
        Viewer.FlushDesignNudge();
        var selected = Viewer.SelectedDesignFields;
        if (!IsDesigningForm || selected.Count == 0 || !DesignIsCurrent()) return;
        var g = Session.Engine.GetPage(selected[0].PageIndex);
        var page = new DesignPage(g.Width, g.Height, Viewer.ViewRotation);
        IReadOnlyList<DesignField> moved;
        try
        {
            moved = how switch
            {
                FieldArrange.AlignLeft => FormDesignRules.Aligned(selected, DesignAlign.Left, page),
                FieldArrange.AlignCenter => FormDesignRules.Aligned(selected, DesignAlign.Center, page),
                FieldArrange.AlignRight => FormDesignRules.Aligned(selected, DesignAlign.Right, page),
                FieldArrange.AlignTop => FormDesignRules.Aligned(selected, DesignAlign.Top, page),
                FieldArrange.AlignMiddle => FormDesignRules.Aligned(selected, DesignAlign.Middle, page),
                FieldArrange.AlignBottom => FormDesignRules.Aligned(selected, DesignAlign.Bottom, page),
                FieldArrange.SameWidth => FormDesignRules.SizedAlike(selected, DesignSameSize.Width, page),
                FieldArrange.SameHeight => FormDesignRules.SizedAlike(selected, DesignSameSize.Height, page),
                FieldArrange.SameSize => FormDesignRules.SizedAlike(selected, DesignSameSize.Both, page),
                FieldArrange.SpaceAcross => FormDesignRules.Spread(selected, DesignSpread.Across, page),
                _ => FormDesignRules.Spread(selected, DesignSpread.Down, page),
            };
        }
        catch (DesignRefusal r)
        {
            Notify(r.Message);
            return;
        }
        if (moved.Count == 0)
        {
            Notify(Strings.FormDesign_ArrangedAlready);
            return;
        }
        var label = how switch
        {
            FieldArrange.SameWidth or FieldArrange.SameHeight or FieldArrange.SameSize => Strings.FormDesign_UndoSize,
            FieldArrange.SpaceAcross or FieldArrange.SpaceDown => Strings.FormDesign_UndoSpace,
            _ => Strings.FormDesign_UndoAlign,
        };
        await UpdateDesignFields(label, moved);
    }

    /// <summary>The panel when several fields are selected.</summary>
    private void ShowSeveral(IReadOnlyList<DesignField> selected)
    {
        var spread = selected.Count >= 3;
        ArrangeAcross.IsEnabled = ArrangeDown.IsEnabled = spread;
        SeveralDelete.IsEnabled = selected.Any(f => !f.Signed);
    }

    internal string DevCalcState()
    {
        var f = Viewer.SelectedDesignField;
        return $"calc: {(f?.Calculation is { } c ? $"{c.Kind} [{string.Join(",", c.Fields)}] '{c.Notation}'" : "none")} box={FieldCalcBox.SelectedItem} " +
               $"order button={FieldCalcOrder.IsVisible} several={FieldSeveral.Visibility}";
    }

    /// <summary>DevScript's calc: picks a calculation in the panel as a person would (kind, then fields or notation).</summary>
    internal void DevSetCalculation(string kind, string arg)
    {
        var k = Enum.Parse<CalcKind>(kind, true);
        if (k == CalcKind.Notation) SetText(FieldCalcNotation, arg);
        FieldCalcBox.SelectedIndex = FormDesignRules.CalcKinds.ToList().IndexOf(k);
        if (k is CalcKind.None or CalcKind.Notation)
        {
            if (k == CalcKind.Notation) ChangeCalculation(k);
            return;
        }
        _populatingDesign = true;
        FieldCalcFields.SelectedItems.Clear();
        foreach (var name in arg.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)) FieldCalcFields.SelectedItems.Add(name);
        _populatingDesign = false;
        ChangeCalculation(k);
    }
}
