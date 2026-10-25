using System.Globalization;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Prepare Form: the field tools bar, the properties panel and field suggestions, around the page view's
/// <see cref="ViewerTool.PrepareForm"/> mode. Every change is one edit through <see cref="DocumentTab.TryEdit"/> (undo,
/// signed files appended to with a warning, protected files kept protected).
/// </summary>
public partial class DocumentTab
{
    private byte[]? _designData;          // the bytes the shown fields were read from (their positional ids refer to them)
    private int _designLoad;
    private bool _populatingDesign;
    private string? _designSelectAfter;   // select this field once the fields are read again
    private int _suggestionPages = -1;    // the page count the suggestions were found with

    private static readonly (string Label, FieldFormat? Format)[] Formats =
    [
        ("None", null),
        ("Number (1,234.56)", new FieldFormat(FieldFormatKind.Number, 2)),
        ("Whole number (1,234)", new FieldFormat(FieldFormatKind.Number, 0)),
        ("Currency ($1,234.56)", new FieldFormat(FieldFormatKind.Number, 2, Currency: "$", CurrencyPrepend: true)),
        ("Percent (12.50%)", new FieldFormat(FieldFormatKind.Percent, 2)),
        ("Date (mm/dd/yyyy)", new FieldFormat(FieldFormatKind.Date, DatePattern: "mm/dd/yyyy")),
        ("Date (dd/mm/yyyy)", new FieldFormat(FieldFormatKind.Date, DatePattern: "dd/mm/yyyy")),
        ("Date (yyyy-mm-dd)", new FieldFormat(FieldFormatKind.Date, DatePattern: "yyyy-mm-dd")),
        ("ZIP code", new FieldFormat(FieldFormatKind.Special, Special: 0)),
        ("ZIP+4", new FieldFormat(FieldFormatKind.Special, Special: 1)),
        ("Phone number", new FieldFormat(FieldFormatKind.Special, Special: 2)),
        ("Social Security number", new FieldFormat(FieldFormatKind.Special, Special: 3)),
    ];

    private static readonly (string Label, AnnotColor? Color)[] BorderColors =
        [("None", null), ("Black", new(0, 0, 0)), ("Gray", new(0.45, 0.45, 0.45)), ("Blue", new(0.1, 0.35, 0.8)), ("Red", new(0.8, 0.1, 0.1))];

    private static readonly (string Label, AnnotColor? Color)[] FillColors =
        [("None", null), ("White", new(1, 1, 1)), ("Light gray", new(0.85, 0.85, 0.85)), ("Light blue", new(0.88, 0.93, 1)), ("Light yellow", new(1, 0.98, 0.8))];

    private static readonly string[] Sizes = ["Auto", "8", "9", "10", "11", "12", "14", "16", "18", "24"];

    private static readonly (string Label, DesignFieldKind Kind, bool Multiline)[] SuggestionKinds =
    [
        ("Text field", DesignFieldKind.Text, false), ("Multi-line text field", DesignFieldKind.Text, true), ("Check box", DesignFieldKind.CheckBox, false),
        ("Radio button", DesignFieldKind.Radio, false), ("Dropdown", DesignFieldKind.ComboBox, false), ("List box", DesignFieldKind.ListBox, false),
        ("Signature field", DesignFieldKind.Signature, false),
    ];

    private (ToggleButton Button, DesignFieldKind? Kind)[] DesignTools =>
    [
        (DesignSelectTool, null), (DesignTextTool, DesignFieldKind.Text), (DesignCheckTool, DesignFieldKind.CheckBox), (DesignRadioTool, DesignFieldKind.Radio),
        (DesignComboTool, DesignFieldKind.ComboBox), (DesignListTool, DesignFieldKind.ListBox), (DesignSignatureTool, DesignFieldKind.Signature),
        (DesignButtonTool, DesignFieldKind.Button),
    ];

    private void InitFormDesign()
    {
        foreach (var (button, kind) in DesignTools)
        {
            var k = kind;
            button.Click += (_, _) =>
            {
                Viewer.DesignKind = k;
                Viewer.Focus();
            };
        }
        DesignDetect.Click += (_, _) => _ = DetectFields();
        DesignTabNumbers.Click += (_, _) => Viewer.ShowTabOrder = DesignTabNumbers.IsChecked == true;
        DesignDone.Click += (_, _) => _ = SetFormDesign(false);
        Viewer.ToolChanged += (_, _) => UpdateFormDesignUi();
        Viewer.DesignSelectionChanged += (_, _) => ShowDesignSelection();
        Viewer.DesignFieldDrawn += (_, p) => _ = AddDrawnField(p);
        Viewer.DesignFieldMoved += (_, f) => _ = UpdateDesignFields("Move field", [f]);
        Viewer.DesignActionRequested += (_, a) => _ = OnDesignAction(a);

        FieldFormatBox.ItemsSource = Formats.Select(f => f.Label).ToList();
        FieldActionBox.ItemsSource = new[] { "Nothing", "Reset the form", "Print" };
        FieldSizeBox.ItemsSource = Sizes;
        FieldAlignBox.ItemsSource = new[] { "Left", "Center", "Right" };
        SuggestionKindBox.ItemsSource = SuggestionKinds.Select(k => k.Label).ToList();

        // Text boxes apply on Enter (single-line ones) and when focus leaves; lists and check boxes when they change.
        OnCommit(FieldNameBox, () => Change("Rename field", f =>
        {
            var name = FieldNameBox.Text.Trim();
            if (name == f.Name) return f;
            var others = Viewer.DesignFields.Where(o => o.Id != f.Id && !(f.Kind == DesignFieldKind.Radio && o.Name == f.Name)).Select(o => (o.Name, o.Kind));
            return FormDesign.NameClash(others, name, f.Kind) is { } problem ? Refuse(problem) : f with { Name = name };
        }));
        OnCommit(FieldTooltipBox, () => Change("Change tooltip", f => f with { Tooltip = FieldTooltipBox.Text.Trim() }));
        OnCommit(FieldMaxLenBox, () => Change("Change length limit", f =>
            int.TryParse(FieldMaxLenBox.Text.Trim(), NumberStyles.None, CultureInfo.CurrentCulture, out var n) && n is >= 0 and <= 100_000
                ? f with { MaxLength = n }
                : FieldMaxLenBox.Text.Trim().Length == 0 ? f with { MaxLength = 0 } : Refuse("Type the most characters as a whole number (0: no limit).")));
        OnCommit(FieldExportBox, () => Change("Change value", f =>
        {
            var v = FieldExportBox.Text.Trim();
            if (v == f.ExportValue) return f;
            if (FormDesign.ExportValueProblem(v) is { } problem) return Refuse(problem);
            if (f.Kind == DesignFieldKind.Radio && Viewer.DesignFields.Any(o => o.Id != f.Id && o.Kind == DesignFieldKind.Radio && o.Name == f.Name && o.ExportValue == v))
                return Refuse($"Another button of \"{f.Name}\" already stands for \"{v}\": give this one a value of its own.");
            // A radio button that was the group's default stays it.
            return f with { ExportValue = v, DefaultValue = f.Kind == DesignFieldKind.Radio && f.DefaultValue == f.ExportValue ? v : f.DefaultValue };
        }));
        OnCommit(FieldCaptionBox, () => Change("Change label", f => f with { Caption = FieldCaptionBox.Text }));
        OnCommit(FieldDefaultBox, () => Change("Change default", f => f with { DefaultValue = FieldDefaultBox.Text }));
        OnCommit(FieldOptionsBox, () => Change("Change choices", f =>
        {
            var (options, labels) = ParseChoices(FieldOptionsBox.Text);
            if (options.SequenceEqual(f.Options) && labels.SequenceEqual(f.ShownOptions)) return f;
            if (options.Count == 0) return Refuse("Type at least one choice.");
            return f with
            {
                Options = options,
                OptionLabels = labels.SequenceEqual(options) ? [] : labels,
                DefaultValue = options.Contains(f.DefaultValue) ? f.DefaultValue : "",
            };
        }), enterCommits: false);
        OnCommit(SuggestionNameBox, () =>
        {
            if (Viewer.SelectedSuggestion is not { } s) return;
            var name = SuggestionNameBox.Text.Trim();
            if (name == s.Name || name.Length == 0) return;
            ReplaceSuggestion(s, s with { Name = name });
        });

        FieldRequiredBox.Click += (_, _) => Change("Change required", f => f with { Required = FieldRequiredBox.IsChecked == true });
        FieldReadOnlyBox.Click += (_, _) => Change("Change read-only", f => f with { ReadOnly = FieldReadOnlyBox.IsChecked == true });
        FieldMultilineBox.Click += (_, _) => Change("Change multi-line", f => f with { Multiline = FieldMultilineBox.IsChecked == true });
        FieldEditableBox.Click += (_, _) => Change("Change dropdown", f => f with { Editable = FieldEditableBox.IsChecked == true });
        FieldMultiSelectBox.Click += (_, _) => Change("Change list box", f => f with { MultiSelect = FieldMultiSelectBox.IsChecked == true });
        FieldDefaultCheck.Click += (_, _) => Change("Change default", f => f with
        {
            DefaultValue = FieldDefaultCheck.IsChecked == true ? f.ExportValue : f.Kind == DesignFieldKind.Radio && f.DefaultValue != f.ExportValue ? f.DefaultValue : "",
        });
        FieldFormatBox.SelectionChanged += (_, _) =>
        {
            if (FieldFormatBox.SelectedIndex is var i && i >= 0 && i < Formats.Length)
                Change("Change format", f => f with { Format = Formats[i].Format });
        };
        FieldActionBox.SelectionChanged += (_, _) =>
        {
            if (FieldActionBox.SelectedIndex is >= 0 and var i && i < 3)
                Change("Change button action", f => f with { Action = i switch { 1 => FieldButtonAction.ResetForm, 2 => FieldButtonAction.Print, _ => FieldButtonAction.None } });
        };
        FieldDefaultChoice.SelectionChanged += (_, _) =>
        {
            if (FieldDefaultChoice.SelectedIndex is >= 0 and var i)
                Change("Change default", f => f with { DefaultValue = i == 0 ? "" : f.Options.ElementAtOrDefault(i - 1) ?? "" });
        };
        FieldAlignBox.SelectionChanged += (_, _) =>
        {
            if (FieldAlignBox.SelectedIndex is >= 0 and var i) Change("Change alignment", f => f with { Alignment = i });
        };
        FieldBorderBox.SelectionChanged += (_, _) =>
        {
            if (FieldBorderBox.SelectedIndex is >= 0 and var i && i < BorderColors.Length) Change("Change border", f => f with { BorderColor = BorderColors[i].Color });
        };
        FieldFillBox.SelectionChanged += (_, _) =>
        {
            if (FieldFillBox.SelectedIndex is >= 0 and var i && i < FillColors.Length) Change("Change fill", f => f with { FillColor = FillColors[i].Color });
        };
        FieldSizeBox.SelectionChanged += (_, _) =>
        {
            if (FieldSizeBox.SelectedItem is string text) ChangeSize(text);
        };
        FieldSizeBox.LostKeyboardFocus += (_, _) => ChangeSize(FieldSizeBox.Text);
        FieldSizeBox.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            ChangeSize(FieldSizeBox.Text);
            e.Handled = true;
        };
        SuggestionKindBox.SelectionChanged += (_, _) =>
        {
            if (_populatingDesign || Viewer.SelectedSuggestion is not { } s || SuggestionKindBox.SelectedIndex is not (>= 0 and var i)) return;
            var (_, kind, multiline) = SuggestionKinds[i];
            ReplaceSuggestion(s, s with { Kind = kind, Multiline = multiline });
        };

        FieldDuplicate.Click += (_, _) => _ = OnDesignAction(DesignAction.Duplicate);
        FieldDelete.Click += (_, _) => _ = OnDesignAction(DesignAction.Delete);
        FieldEarlier.Click += (_, _) => _ = MoveInTabOrder(-1);
        FieldLater.Click += (_, _) => _ = MoveInTabOrder(1);
        SuggestionAccept.Click += (_, _) => _ = OnDesignAction(DesignAction.Accept);
        SuggestionReject.Click += (_, _) => _ = OnDesignAction(DesignAction.Reject);
        SuggestionAcceptAll.Click += (_, _) => _ = AcceptSuggestions([.. Viewer.Suggestions]);
        SuggestionRejectAll.Click += (_, _) =>
        {
            Viewer.SetSuggestions([]);
            Viewer.Focus();
        };
        // Esc in the panel goes back to the page (and the field stays selected).
        FieldPanel.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape || e.OriginalSource is ComboBox { IsDropDownOpen: true }) return;
            Viewer.Focus();
            e.Handled = true;
        };
    }

    public bool IsDesigningForm => Viewer.IsDesigningForm;

    /// <summary>Enters (asks about a hybrid XFA form first) or leaves Prepare Form. False when it didn't enter.</summary>
    public async Task<bool> SetFormDesign(bool on)
    {
        if (!on)
        {
            if (IsDesigningForm) Viewer.Tool = ViewerTool.Hand;
            return true;
        }
        if (IsDesigningForm) return true;
        if (!Session.IsPdf)
        {
            Notify("Forms can be prepared in PDF files only.");
            return false;
        }
        if (IsOrganizing) SetOrganizing(false);
        var data = Session.Data;
        var pw = Session.Password;
        var (hasXfa, xfaOnly) = await Task.Run(() =>
        {
            try
            {
                return FormEditor.HasXfa(data, pw);
            }
            catch (Exception ex) when (ex is InvalidOperationException or OwnerPasswordRequiredException)
            {
                return (false, false);
            }
        });
        if (_disposed) return false;
        var owner = Window.GetWindow(this);
        if (xfaOnly)
        {
            Prompt.Info(owner, "This form uses XFA", "Its fields are an XFA form, which Inkvolt PDF can't edit. Adobe Acrobat (Pro) can convert or edit it.");
            return false;
        }
        if (hasXfa && !Prompt.Confirm(owner, "Edit this form's fields?",
                "This form also carries an XFA version, which Adobe Acrobat shows instead of the fields. Changing the fields here removes the XFA version, so every viewer shows the fields as you prepare them.",
                "Edit fields"))
            return false;
        Viewer.Tool = ViewerTool.PrepareForm;
        Viewer.Focus();
        return true;
    }

    /// <summary>Prepare Form › Detect Fields from a menu: enters the mode first.</summary>
    public async Task DetectFieldsCommand()
    {
        if (!await SetFormDesign(true)) return;
        await LoadFormDesignAsync();
        await DetectFields();
    }

    private void UpdateFormDesignUi()
    {
        var on = IsDesigningForm;
        var vis = on ? Visibility.Visible : Visibility.Collapsed;
        if (FormDesignBar.Visibility != vis)
        {
            FormDesignBar.Visibility = FieldPanel.Visibility = vis;
            // The pages make room for the bar and the panel rather than lying under them.
            Viewer.Margin = on ? new Thickness(0, 52, FieldPanel.Width + 28, 0) : default;
            if (on)
            {
                FormBar.Visibility = Visibility.Collapsed; // "click a field to fill it" doesn't apply here
                _ = LoadFormDesignAsync();
            }
            else
            {
                Viewer.SetSuggestions([]);
                Viewer.ShowTabOrder = false;
                DesignTabNumbers.IsChecked = false;
                _ = LoadAnnotationsAsync(); // the fill bar and fields as they are now
            }
        }
        foreach (var (button, kind) in DesignTools) button.IsChecked = on && Viewer.DesignKind == kind;
    }

    /// <summary>Reads the fields for Prepare Form off the UI thread (the latest request wins).</summary>
    private async Task LoadFormDesignAsync()
    {
        if (!IsDesigningForm) return;
        var ticket = ++_designLoad;
        var data = Session.Data;
        var pw = Session.Password;
        IReadOnlyList<DesignField> fields;
        try
        {
            fields = await Task.Run(() => FormDesign.Read(data, pw));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log.Write($"Reading form fields for Prepare Form failed: {ex.Message}");
            fields = [];
        }
        if (ticket != _designLoad || _disposed || !ReferenceEquals(data, Session.Data)) return;
        _designData = data;
        if (_suggestionPages >= 0 && _suggestionPages != Viewer.PageCount) Viewer.SetSuggestions([]); // pages moved: they'd be in the wrong places
        else if (Viewer.Suggestions.Count > 0)
            Viewer.SetSuggestions([.. Viewer.Suggestions.Where(s => !fields.Any(f => f.PageIndex == s.PageIndex && Overlap(f.Rect, s.Rect) > 0.3))]);
        Viewer.SetDesignFields(fields);
        if (_designSelectAfter is { } id)
        {
            _designSelectAfter = null;
            if (fields.Any(f => f.Id == id)) Viewer.SelectDesignField(id);
        }
        ShowDesignSelection();
    }

    private static double Overlap(RectD a, RectD b)
    {
        var i = a.Intersect(b);
        return i.IsEmpty ? 0 : i.Width * i.Height / Math.Max(1e-6, Math.Min(a.Width * a.Height, b.Width * b.Height));
    }

    private bool DesignIsCurrent()
    {
        if (ReferenceEquals(_designData, Session.Data)) return true;
        Notify("The fields are still being refreshed after the last change. Try again in a moment.");
        _ = LoadFormDesignAsync();
        return false;
    }

    // ───────────────────────────── Edits ─────────────────────────────

    private async Task AddDrawnField(DesignPlacement p)
    {
        if (!DesignIsCurrent()) return;
        var all = Viewer.DesignFields;
        DesignField f;
        if (p.Kind == DesignFieldKind.Radio && Viewer.SelectedDesignField is { Kind: DesignFieldKind.Radio } sel)
            f = FormDesign.Duplicate(sel, all, 0, 0) with { PageIndex = p.PageIndex, Rect = p.Rect, DefaultValue = sel.DefaultValue }; // joins its group
        else
            f = FormDesign.NewField(p.Kind, p.PageIndex, p.Rect, all.Select(x => x.Name));
        if (p.Kind == DesignFieldKind.Text && p.Rect.Height >= 36) f = f with { Multiline = true };
        Viewer.DesignKind = null; // back to selecting: the new field's properties show
        await AddFields($"Add {DesignField.KindName(p.Kind).ToLowerInvariant()}", [f], f.Id);
    }

    private async Task<bool> AddFields(string label, IReadOnlyList<DesignField> fields, string? select)
    {
        _designSelectAfter = select;
        var ok = await RunEdit(label, (d, pw) => FormDesign.Add(d, pw, fields), contentOnly: true);
        if (!ok) _designSelectAfter = null;
        return ok;
    }

    private async Task<bool> UpdateDesignFields(string label, IReadOnlyList<DesignField> changes)
    {
        if (!DesignIsCurrent()) return false;
        var selected = Viewer.SelectedDesignField?.Id;
        var newIds = new Dictionary<string, string>();
        _designSelectAfter = selected;
        var outcome = await TryEdit(label, (d, pw) =>
        {
            newIds.Clear();
            return FormDesign.Update(d, pw, changes, newIds);
        }, contentOnly: true, quiet: true);
        if (selected is not null && newIds.TryGetValue(selected, out var renamed)) _designSelectAfter = renamed;
        if (outcome is EditOutcome.Done or EditOutcome.NoChange) return true;
        // Not made: show the fields as the document has them (a dragged field goes back).
        _designSelectAfter = null;
        Viewer.SetDesignFields([.. Viewer.DesignFields]);
        ShowDesignSelection();
        return false;
    }

    private async Task OnDesignAction(DesignAction action)
    {
        Viewer.FlushDesignNudge();
        var f = Viewer.SelectedDesignField;
        var s = Viewer.SelectedSuggestion;
        switch (action)
        {
            case DesignAction.Properties when f is not null:
                FieldNameBox.Focus();
                FieldNameBox.SelectAll();
                break;
            case DesignAction.Delete when f is { Signed: false } && DesignIsCurrent():
            {
                var next = NextFieldAfter(f);
                _designSelectAfter = next;
                if (!await RunEdit($"Delete {DesignField.KindName(f.Kind).ToLowerInvariant()}", (d, pw) => FormDesign.Delete(d, pw, [f.Id]), contentOnly: true))
                    _designSelectAfter = null;
                break;
            }
            case DesignAction.Duplicate when f is { Signed: false } && DesignIsCurrent():
            {
                var g = Session.Engine.GetPage(f.PageIndex);
                var below = f.Rect.Bottom + 8 + f.Rect.Height <= g.Height;
                var copy = FormDesign.Duplicate(f, Viewer.DesignFields, below ? 0 : Math.Min(f.Rect.Width + 8, Math.Max(0, g.Width - f.Rect.Right)), below ? f.Rect.Height + 8 : 0);
                await AddFields($"Duplicate {DesignField.KindName(f.Kind).ToLowerInvariant()}", [copy], copy.Id);
                break;
            }
            case DesignAction.Accept when s is not null:
                await AcceptSuggestions([s]);
                break;
            case DesignAction.Reject when s is not null:
            {
                var i = Viewer.SelectedSuggestionIndex;
                var rest = Viewer.Suggestions.Where(x => !ReferenceEquals(x, s)).ToList();
                Viewer.SetSuggestions(rest);
                if (rest.Count > 0) Viewer.SelectSuggestion(Math.Min(i, rest.Count - 1), reveal: true);
                break;
            }
        }
    }

    /// <summary>The field to select once <paramref name="f"/> is gone: the next in fill order (positional ids shift, so
    /// only one with its own id).</summary>
    private string? NextFieldAfter(DesignField f)
    {
        var order = Viewer.DesignFields.ToList();
        var i = order.FindIndex(x => x.Id == f.Id);
        var next = order.Skip(i + 1).Concat(order.Take(Math.Max(0, i))).FirstOrDefault(x => x.Id != f.Id && !IsPositionalId(x.Id));
        return next?.Id;
    }

    private static bool IsPositionalId(string id) => System.Text.RegularExpressions.Regex.IsMatch(id, @"^p\d+:\d+$");

    /// <summary>Adds suggestions as fields (one undo step), named uniquely, and drops them from the list.</summary>
    private async Task AcceptSuggestions(IReadOnlyList<FieldSuggestion> picked)
    {
        if (picked.Count == 0 || !DesignIsCurrent()) return;
        var names = Viewer.DesignFields.Select(f => f.Name).ToList();
        var fields = new List<DesignField>();
        foreach (var s in picked)
        {
            var f = FormDesign.NewField(s.Kind, s.PageIndex, s.Rect, names, s.Name) with { Multiline = s.Multiline };
            if (s.Kind == DesignFieldKind.Radio)
            {
                // Radio buttons with one name are one group: each gets its own value.
                var group = Viewer.DesignFields.Where(x => x.Kind == DesignFieldKind.Radio && x.Name == s.Name).Concat(fields.Where(x => x.Name == s.Name)).ToList();
                var n = group.Count + 1;
                while (group.Any(x => x.ExportValue == $"Choice{n}")) n++;
                f = f with { Name = s.Name, ExportValue = $"Choice{n}" };
            }
            names.Add(f.Name);
            fields.Add(f);
        }
        var index = Viewer.SelectedSuggestionIndex;
        var label = fields.Count == 1 ? $"Add {DesignField.KindName(fields[0].Kind).ToLowerInvariant()}" : $"Add {fields.Count} fields";
        if (!await RunEdit(label, (d, pw) => FormDesign.Add(d, pw, fields), contentOnly: true)) return;
        var rest = Viewer.Suggestions.Where(x => !picked.Contains(x)).ToList();
        Viewer.SetSuggestions(rest);
        // Reviewing one by one: go on with the next suggestion.
        if (rest.Count > 0 && picked.Count == 1) Viewer.SelectSuggestion(Math.Clamp(index, 0, rest.Count - 1), reveal: true);
        else if (picked.Count == 1) _designSelectAfter = fields[0].Id;
    }

    private void ReplaceSuggestion(FieldSuggestion old, FieldSuggestion updated)
    {
        var list = Viewer.Suggestions.ToList();
        var i = list.IndexOf(old);
        if (i < 0) return;
        list[i] = updated;
        Viewer.SetSuggestions(list);
        Viewer.SelectSuggestion(i);
    }

    /// <summary>Looks for fields on every page (in the background) and shows what it finds as suggestions.</summary>
    private async Task DetectFields()
    {
        if (!IsDesigningForm || IsBusy || !DesignIsCurrent()) return;
        var engine = Session.Engine;
        var data = Session.Data;
        var pw = Session.Password;
        var existing = Viewer.DesignFields;
        var pages = Enumerable.Range(0, engine.PageCount).ToList();
        IReadOnlyList<FieldSuggestion> found;
        using (BeginBusy(null))
        using (var prompt = new ProgressPrompt(Window.GetWindow(this), "Detect Fields", "Looking for fields…"))
        {
            var progress = new Progress<(int Done, int Total)>(p => prompt.Report($"Looking at page {p.Done + 1:N0} of {p.Total:N0}…", (double)p.Done / p.Total));
            var token = prompt.Token;
            try
            {
                found = await Task.Run(() => FieldDetection.Suggest(engine, data, pw, pages, existing, token, progress), token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex) when (ex is ObjectDisposedException or InvalidOperationException)
            {
                Log.Write($"Detect fields failed: {ex}");
                Notify("Couldn't look for fields: the document changed meanwhile. Try again.", error: true);
                return;
            }
        }
        if (_disposed || !IsDesigningForm || !ReferenceEquals(data, Session.Data)) return;
        _suggestionPages = Viewer.PageCount;
        Viewer.SetSuggestions(found);
        if (found.Count == 0)
        {
            Notify("No fields found. Inkvolt PDF looks for lines to write on, empty boxes, small squares and runs of underscores.");
            return;
        }
        // Start on the current page's first suggestion, else the first one.
        var first = Math.Max(0, found.ToList().FindIndex(s => s.PageIndex >= Viewer.CurrentPage));
        Viewer.SelectSuggestion(first, reveal: true);
        Viewer.Focus();
        Notify($"Found {found.Count} possible field{(found.Count == 1 ? "" : "s")} (dashed): Enter adds one, Del skips it, or add them all from the panel.");
    }

    private async Task MoveInTabOrder(int step)
    {
        if (Viewer.SelectedDesignField is not { } f || !DesignIsCurrent()) return;
        var onPage = Viewer.DesignFields.Where(x => x.PageIndex == f.PageIndex).OrderBy(x => x.TabIndex).ToList();
        var i = onPage.FindIndex(x => x.Id == f.Id);
        var j = i + step;
        if (i < 0 || j < 0 || j >= onPage.Count)
        {
            Notify(step < 0 ? "This field is already filled first on its page." : "This field is already filled last on its page.");
            return;
        }
        (onPage[i], onPage[j]) = (onPage[j], onPage[i]);
        var ids = onPage.Select(x => x.Id).ToList();
        var newIds = new Dictionary<string, string>();
        _designSelectAfter = f.Id;
        var ok = await RunEdit("Change tab order", (d, pw) =>
        {
            newIds.Clear();
            return FormDesign.SetTabOrder(d, pw, f.PageIndex, ids, newIds);
        }, contentOnly: true, quiet: true);
        if (ok && newIds.TryGetValue(f.Id, out var renamed)) _designSelectAfter = renamed;
        if (!ok) _designSelectAfter = null;
        DesignTabNumbers.IsChecked = Viewer.ShowTabOrder = true;
    }

    // ───────────────────────────── Properties panel ─────────────────────────────

    private void OnCommit(TextBox box, Action commit, bool enterCommits = true)
    {
        box.LostKeyboardFocus += (_, _) => commit();
        if (!enterCommits) return;
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            commit();
            e.Handled = true;
        };
    }

    private static DesignField? Refuse(string message) => throw new DesignRefusal(message);

    private sealed class DesignRefusal(string message) : Exception(message);

    /// <summary>Applies one property change of the selected field as an edit (nothing when it changes nothing).</summary>
    private void Change(string label, Func<DesignField, DesignField?> change)
    {
        if (_populatingDesign || Viewer.SelectedDesignField is not { } f || f.Signed) return;
        DesignField? updated;
        try
        {
            updated = change(f);
        }
        catch (DesignRefusal r)
        {
            FieldPanelError.Text = r.Message;
            FieldPanelError.Visibility = Visibility.Visible;
            Announce(r.Message);
            return;
        }
        FieldPanelError.Visibility = Visibility.Collapsed;
        if (updated is null || Same(updated, f)) return;
        _ = UpdateDesignFields(label, [updated]);
    }

    private static bool Same(DesignField a, DesignField b) =>
        a with { Options = b.Options, OptionLabels = b.OptionLabels } == b && a.Options.SequenceEqual(b.Options) && a.ShownOptions.SequenceEqual(b.ShownOptions);

    /// <summary>
    /// The options editor's lines: "Shown text" (the value is the same), or "Shown text = value" (Acrobat's item and
    /// export value). Repeated values keep their first line.
    /// </summary>
    internal static (List<string> Options, List<string> Labels) ParseChoices(string text)
    {
        var options = new List<string>();
        var labels = new List<string>();
        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            var at = line.LastIndexOf(" = ", StringComparison.Ordinal);
            var (label, value) = at > 0 ? (line[..at].Trim(), line[(at + 3)..].Trim()) : (line, line);
            if (value.Length == 0) value = label;
            if (options.Contains(value)) continue;
            options.Add(value);
            labels.Add(label);
        }
        return (options, labels);
    }

    /// <summary>The options editor's text for a field's choices (see <see cref="ParseChoices"/>).</summary>
    internal static string ChoicesText(DesignField f) =>
        string.Join(Environment.NewLine, f.Options.Select((o, i) => f.ShownOptions[i] == o ? o : $"{f.ShownOptions[i]} = {o}"));

    private void ChangeSize(string text)
    {
        text = text.Trim();
        double size;
        if (text.Length == 0 || text.Equals("Auto", StringComparison.OrdinalIgnoreCase)) size = 0;
        else if (!double.TryParse(text.TrimEnd('p', 't', ' '), NumberStyles.Float, CultureInfo.CurrentCulture, out size) || size is < 0 or > 200) return;
        Change("Change text size", f => f with { FontSize = size });
    }

    /// <summary>Fills the panel from the selection: a field's properties, a suggestion, or the hint.</summary>
    private void ShowDesignSelection()
    {
        if (!IsDesigningForm) return;
        _populatingDesign = true;
        try
        {
            var f = Viewer.SelectedDesignField;
            var s = f is null ? Viewer.SelectedSuggestion : null;
            var count = Viewer.Suggestions.Count;
            FieldProps.Visibility = f is not null ? Visibility.Visible : Visibility.Collapsed;
            SuggestionProps.Visibility = s is not null ? Visibility.Visible : Visibility.Collapsed;
            SuggestionAll.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
            FieldPanelHint.Visibility = f is null && s is null ? Visibility.Visible : Visibility.Collapsed;
            FieldPanelError.Visibility = Visibility.Collapsed;
            SuggestionCount.Text = $"{count} suggested field{(count == 1 ? "" : "s")} (dashed on the page).";
            var title = f is not null ? $"{DesignField.KindName(f.Kind)} · page {f.PageIndex + 1}{(f.Signed ? " · signed" : "")}"
                : s is not null ? $"Suggested {DesignField.KindName(s.Kind).ToLowerInvariant()} · page {s.PageIndex + 1}"
                : "Prepare Form";
            var changed = FieldPanelTitle.Text != title;
            FieldPanelTitle.Text = title;
            if (f is not null) ShowField(f);
            if (s is not null)
            {
                SetText(SuggestionNameBox, s.Name);
                SuggestionKindBox.SelectedIndex = Array.FindIndex(SuggestionKinds, k => k.Kind == s.Kind && k.Multiline == s.Multiline);
                SuggestionSource.Text = "Found from " + s.Source switch
                {
                    "underscores" => "a run of underscores.",
                    "line" => "a line to write on.",
                    "box" => "an empty box.",
                    "square" => "a small square.",
                    _ => "a box character.",
                };
            }
            if (changed || f is not null || s is not null)
                Announce(f is not null ? $"{f.Describe()} selected, page {f.PageIndex + 1}" : s is not null ? $"Suggested {DesignField.KindName(s.Kind).ToLowerInvariant()} {s.Name}, page {s.PageIndex + 1}" : title);
        }
        finally
        {
            _populatingDesign = false;
        }
    }

    private void ShowField(DesignField f)
    {
        var text = f.Kind == DesignFieldKind.Text;
        var choice = f.Kind is DesignFieldKind.ComboBox or DesignFieldKind.ListBox;
        var onOff = f.Kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio;
        var button = f.Kind == DesignFieldKind.Button;
        FieldProps.IsEnabled = !f.Signed;
        SetText(FieldNameBox, f.Name);
        SetText(FieldTooltipBox, f.Tooltip);
        FieldRequiredBox.IsChecked = f.Required;
        FieldReadOnlyBox.IsChecked = f.ReadOnly;
        FieldRequiredBox.Visibility = button ? Visibility.Collapsed : Visibility.Visible;

        FieldTextGroup.Visibility = text ? Visibility.Visible : Visibility.Collapsed;
        if (text)
        {
            FieldMultilineBox.IsChecked = f.Multiline;
            SetText(FieldMaxLenBox, f.MaxLength.ToString(CultureInfo.CurrentCulture));
            var formats = Formats.Select(x => x.Label).ToList();
            var at = Array.FindIndex(Formats, x => x.Format == f.Format);
            if (f.CustomFormat) formats.Add("Custom script (kept)");
            else if (at < 0) formats.Add($"Other ({f.Format!.Kind.ToString().ToLowerInvariant()}, kept)");
            FieldFormatBox.ItemsSource = formats;
            FieldFormatBox.SelectedIndex = at >= 0 && !f.CustomFormat ? at : formats.Count - 1;
            FieldFormatBox.IsEnabled = !f.CustomFormat;
        }
        FieldOptionsGroup.Visibility = choice ? Visibility.Visible : Visibility.Collapsed;
        if (choice)
        {
            SetText(FieldOptionsBox, ChoicesText(f));
            FieldEditableBox.Visibility = f.Kind == DesignFieldKind.ComboBox ? Visibility.Visible : Visibility.Collapsed;
            FieldMultiSelectBox.Visibility = f.Kind == DesignFieldKind.ListBox ? Visibility.Visible : Visibility.Collapsed;
            FieldEditableBox.IsChecked = f.Editable;
            FieldMultiSelectBox.IsChecked = f.MultiSelect;
        }
        FieldExportGroup.Visibility = onOff ? Visibility.Visible : Visibility.Collapsed;
        if (onOff) SetText(FieldExportBox, f.ExportValue);
        FieldButtonGroup.Visibility = button ? Visibility.Visible : Visibility.Collapsed;
        if (button)
        {
            SetText(FieldCaptionBox, f.Caption);
            FieldActionBox.ItemsSource = f.Action == FieldButtonAction.Other
                ? new[] { "Nothing", "Reset the form", "Print", "The form's own action (kept)" }
                : new[] { "Nothing", "Reset the form", "Print" };
            FieldActionBox.SelectedIndex = f.Action switch { FieldButtonAction.ResetForm => 1, FieldButtonAction.Print => 2, FieldButtonAction.Other => 3, _ => 0 };
        }

        FieldDefaultGroup.Visibility = text || choice ? Visibility.Visible : Visibility.Collapsed;
        FieldDefaultBox.Visibility = text ? Visibility.Visible : Visibility.Collapsed;
        FieldDefaultChoice.Visibility = choice ? Visibility.Visible : Visibility.Collapsed;
        if (text) SetText(FieldDefaultBox, f.DefaultValue);
        if (choice)
        {
            FieldDefaultChoice.ItemsSource = f.ShownOptions.Prepend("(none)").ToList();
            FieldDefaultChoice.SelectedIndex = f.Options.ToList().IndexOf(f.DefaultValue) + 1;
        }
        FieldDefaultCheck.Visibility = onOff ? Visibility.Visible : Visibility.Collapsed;
        FieldDefaultCheck.IsChecked = onOff && f.DefaultValue.Length > 0 && f.DefaultValue == f.ExportValue;
        FieldDefaultCheck.Content = f.Kind == DesignFieldKind.Radio ? "Selected by default" : "Checked by default";

        var hasText = !onOff && f.Kind != DesignFieldKind.Signature;
        FieldSizeBox.IsEnabled = hasText;
        FieldAlignBox.IsEnabled = hasText;
        if (!FieldSizeBox.IsKeyboardFocusWithin) FieldSizeBox.Text = f.FontSize <= 0 ? "Auto" : f.FontSize.ToString("0.#", CultureInfo.CurrentCulture);
        FieldAlignBox.SelectedIndex = Math.Clamp(f.Alignment, 0, 2);
        SelectColor(FieldBorderBox, BorderColors, f.BorderColor);
        SelectColor(FieldFillBox, FillColors, f.FillColor);
        FieldDuplicate.IsEnabled = FieldDelete.IsEnabled = !f.Signed;
    }

    private static void SelectColor(ComboBox box, (string Label, AnnotColor? Color)[] choices, AnnotColor? color)
    {
        static bool Near(AnnotColor? a, AnnotColor? b) => a is null ? b is null : b is { } v && Math.Abs(a.Value.R - v.R) < 0.02 && Math.Abs(a.Value.G - v.G) < 0.02 && Math.Abs(a.Value.B - v.B) < 0.02;
        var labels = choices.Select(c => c.Label).ToList();
        var at = Array.FindIndex(choices, c => Near(c.Color, color));
        if (at < 0) labels.Add("Custom (kept)");
        box.ItemsSource = labels;
        box.SelectedIndex = at >= 0 ? at : labels.Count - 1;
    }

    private static void SetText(TextBox box, string text)
    {
        if (box.Text != text) box.Text = text;
    }

    /// <summary>Speaks <paramref name="message"/> through the panel's title (a polite live region).</summary>
    private void Announce(string message)
    {
        System.Windows.Automation.AutomationProperties.SetName(FieldPanelTitle, message);
        UIElementAutomationPeer.CreatePeerForElement(FieldPanelTitle)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    // ───────────────────────────── Dev entries ─────────────────────────────

    internal string DevDesignState()
    {
        var f = Viewer.SelectedDesignField;
        var s = Viewer.SelectedSuggestion;
        return $"designing={IsDesigningForm} kind={Viewer.DesignKind?.ToString() ?? "select"} fields={Viewer.DesignFields.Count} suggestions={Viewer.Suggestions.Count} " +
               $"selected={(f is not null ? $"{f.Describe()} {f.Rect.X:0},{f.Rect.Y:0} {f.Rect.Width:0}x{f.Rect.Height:0}" : s is not null ? $"suggestion {s.Name} ({s.Kind})" : "-")} " +
               $"panel='{FieldPanelTitle.Text}' error='{(FieldPanelError.Visibility == Visibility.Visible ? FieldPanelError.Text : "")}'";
    }

    internal string DevDesignFields() => string.Join("; ", Viewer.DesignFields.Select(f => $"{f.Describe()} p{f.PageIndex + 1} {f.Rect.X:0},{f.Rect.Y:0} {f.Rect.Width:0}x{f.Rect.Height:0} tab {f.TabIndex + 1}"));

    internal string DevSuggestions() => string.Join("; ", Viewer.Suggestions.Select(s => $"{s.Name} ({s.Kind}{(s.Multiline ? ", multi-line" : "")}, {s.Source}) p{s.PageIndex + 1} {s.Rect.X:0},{s.Rect.Y:0} {s.Rect.Width:0}x{s.Rect.Height:0}"));

    internal Task DevDetect() => DetectFields();

    internal Task DevAcceptAll() => AcceptSuggestions([.. Viewer.Suggestions]);

    /// <summary>Sets a property in the panel as if typed or picked: name, tooltip, default, options (| between), format index, required, size.</summary>
    internal void DevSetProperty(string name, string value)
    {
        switch (name)
        {
            case "name": FieldNameBox.Text = value; FieldNameBox.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice, 0, FieldNameBox, null) { RoutedEvent = LostKeyboardFocusEvent }); break;
            case "tooltip": FieldTooltipBox.Text = value; FieldTooltipBox.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice, 0, FieldTooltipBox, null) { RoutedEvent = LostKeyboardFocusEvent }); break;
            case "default": FieldDefaultBox.Text = value; FieldDefaultBox.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice, 0, FieldDefaultBox, null) { RoutedEvent = LostKeyboardFocusEvent }); break;
            case "options": FieldOptionsBox.Text = value.Replace("|", Environment.NewLine); FieldOptionsBox.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice, 0, FieldOptionsBox, null) { RoutedEvent = LostKeyboardFocusEvent }); break;
            case "format": FieldFormatBox.SelectedIndex = int.Parse(value, CultureInfo.InvariantCulture); break;
            case "required": FieldRequiredBox.IsChecked = value == "on"; FieldRequiredBox.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); break;
            case "size": ChangeSize(value); break;
            case "fill": FieldFillBox.SelectedIndex = int.Parse(value, CultureInfo.InvariantCulture); break;
        }
    }
}
