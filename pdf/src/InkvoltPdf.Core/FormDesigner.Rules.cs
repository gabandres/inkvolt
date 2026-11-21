using System.Globalization;

namespace InkvoltPdf.Core;

/// <summary>A property change the panel refused, with what to say.</summary>
public sealed class DesignRefusal(string message) : Exception(message);

/// <summary>
/// The properties panel's and the field commands' rules (ADR 1: here so they are tested; <c>DocumentTab.FormDesign</c>
/// fills the panel and runs the edits; the Mac's <c>FormDesignRules</c> is the spec): what each list offers and which
/// entry a field's value is, what a typed value does to a field, and which fields an action makes. The lists' labels stay
/// with the app (its <c>Strings</c>), parallel to the lists here.
/// </summary>
public static class FormDesignRules
{
    /// <summary>The format list (the first: none), parallel to the panel's labels.</summary>
    public static IReadOnlyList<FieldFormat?> Formats { get; } =
    [
        null,
        new FieldFormat(FieldFormatKind.Number, 2),
        new FieldFormat(FieldFormatKind.Number, 0),
        new FieldFormat(FieldFormatKind.Number, 2, Currency: "$", CurrencyPrepend: true),
        new FieldFormat(FieldFormatKind.Percent, 2),
        new FieldFormat(FieldFormatKind.Date, DatePattern: "mm/dd/yyyy"),
        new FieldFormat(FieldFormatKind.Date, DatePattern: "dd/mm/yyyy"),
        new FieldFormat(FieldFormatKind.Date, DatePattern: "yyyy-mm-dd"),
        new FieldFormat(FieldFormatKind.Special, Special: 0),
        new FieldFormat(FieldFormatKind.Special, Special: 1),
        new FieldFormat(FieldFormatKind.Special, Special: 2),
        new FieldFormat(FieldFormatKind.Special, Special: 3),
    ];

    /// <summary>Border colors (the first: none), parallel to the panel's labels.</summary>
    public static IReadOnlyList<AnnotColor?> BorderColors { get; } =
        [null, new AnnotColor(0, 0, 0), new AnnotColor(0.45, 0.45, 0.45), new AnnotColor(0.1, 0.35, 0.8), new AnnotColor(0.8, 0.1, 0.1)];

    /// <summary>Fill colors (the first: none), parallel to the panel's labels.</summary>
    public static IReadOnlyList<AnnotColor?> FillColors { get; } =
        [null, new AnnotColor(1, 1, 1), new AnnotColor(0.85, 0.85, 0.85), new AnnotColor(0.88, 0.93, 1), new AnnotColor(1, 0.98, 0.8)];

    /// <summary>What a suggestion can be made (text, multi-line text, check box …), parallel to the panel's labels.</summary>
    public static IReadOnlyList<(DesignFieldKind Kind, bool Multiline)> SuggestionKinds { get; } =
    [
        (DesignFieldKind.Text, false), (DesignFieldKind.Text, true), (DesignFieldKind.CheckBox, false), (DesignFieldKind.Radio, false),
        (DesignFieldKind.ComboBox, false), (DesignFieldKind.ListBox, false), (DesignFieldKind.Signature, false),
    ];

    /// <summary>The entry of <see cref="Formats"/> a field has, or -1 when it has another format or a script of its own
    /// (the list then shows one more entry, "kept").</summary>
    public static int FormatIndex(DesignField f)
    {
        if (f.CustomFormat) return -1;
        for (var i = 0; i < Formats.Count; i++)
            if (Formats[i] == f.Format) return i;
        return -1;
    }

    /// <summary>The index in <paramref name="choices"/> of a color (within 0.02 each), or -1 when it is none of them ("Custom").</summary>
    public static int ColorIndex(IReadOnlyList<AnnotColor?> choices, AnnotColor? color)
    {
        static bool Near(AnnotColor? a, AnnotColor? b) =>
            a is null ? b is null : b is { } v && Math.Abs(a.Value.R - v.R) < 0.02 && Math.Abs(a.Value.G - v.G) < 0.02 && Math.Abs(a.Value.B - v.B) < 0.02;
        for (var i = 0; i < choices.Count; i++)
            if (Near(choices[i], color)) return i;
        return -1;
    }

    /// <summary>The entry of <see cref="SuggestionKinds"/> a suggestion is.</summary>
    public static int SuggestionKindIndex(FieldSuggestion s)
    {
        for (var i = 0; i < SuggestionKinds.Count; i++)
            if (SuggestionKinds[i].Kind == s.Kind && SuggestionKinds[i].Multiline == s.Multiline) return i;
        return -1;
    }

    /// <summary>A push button's entry in the action list: nothing, reset, print, or (only when it has one) its own.</summary>
    public static int ButtonActionIndex(FieldButtonAction action) => action switch
    {
        FieldButtonAction.ResetForm => 1,
        FieldButtonAction.Print => 2,
        FieldButtonAction.Other => 3,
        _ => 0,
    };

    /// <summary>The action picked from the list; null for the button's own (kept, it can't be picked anew).</summary>
    public static FieldButtonAction? ButtonActionAt(int index) => index switch
    {
        0 => FieldButtonAction.None,
        1 => FieldButtonAction.ResetForm,
        2 => FieldButtonAction.Print,
        _ => null,
    };

    // ───────────────────────────── Fields the commands make ─────────────────────────────

    /// <summary>
    /// The field a drag or click with a field tool makes. A radio button drawn with a radio button selected joins its
    /// group; a text field drawn 36 pt tall or more is multi-line.
    /// </summary>
    public static DesignField PlacedField(DesignPlacement p, IReadOnlyList<DesignField> fields, DesignField? selected)
    {
        var f = p.Kind == DesignFieldKind.Radio && selected is { Kind: DesignFieldKind.Radio } sel
            ? FormDesign.Duplicate(sel, fields, 0, 0) with { PageIndex = p.PageIndex, Rect = p.Rect, DefaultValue = sel.DefaultValue }
            : FormDesign.NewField(p.Kind, p.PageIndex, p.Rect, fields.Select(x => x.Name));
        return p.Kind == DesignFieldKind.Text && p.Rect.Height >= 36 ? f with { Multiline = true } : f;
    }

    /// <summary>A copy of <paramref name="f"/> beside it: below it if that stays on the page, else to its right.</summary>
    public static DesignField Duplicated(DesignField f, IReadOnlyList<DesignField> fields, double pageWidth, double pageHeight)
    {
        var below = f.Rect.Bottom + 8 + f.Rect.Height <= pageHeight;
        return FormDesign.Duplicate(f, fields, below ? 0 : Math.Min(f.Rect.Width + 8, Math.Max(0, pageWidth - f.Rect.Right)), below ? f.Rect.Height + 8 : 0);
    }

    /// <summary>Suggestions as fields, named uniquely; radio buttons with one name are one group, each with its own value.</summary>
    public static IReadOnlyList<DesignField> AcceptedFields(IReadOnlyList<FieldSuggestion> picked, IReadOnlyList<DesignField> fields)
    {
        var names = fields.Select(f => f.Name).ToList();
        var result = new List<DesignField>();
        foreach (var s in picked)
        {
            var f = FormDesign.NewField(s.Kind, s.PageIndex, s.Rect, names, s.Name) with { Multiline = s.Multiline };
            if (s.Kind == DesignFieldKind.Radio)
            {
                var group = fields.Where(x => x.Kind == DesignFieldKind.Radio && x.Name == s.Name).Concat(result.Where(x => x.Name == s.Name)).ToList();
                var n = group.Count + 1;
                while (group.Any(x => x.ExportValue == $"Choice{n}")) n++;
                f = f with { Name = s.Name, ExportValue = $"Choice{n}" };
            }
            names.Add(f.Name);
            result.Add(f);
        }
        return result;
    }

    /// <summary>The field to select once <paramref name="f"/> is gone: the next in fill order (positional ids shift, so
    /// only one with its own id).</summary>
    public static string? NextField(DesignField f, IReadOnlyList<DesignField> order)
    {
        var i = order.ToList().FindIndex(x => x.Id == f.Id);
        return order.Skip(i + 1).Concat(order.Take(Math.Max(0, i))).FirstOrDefault(x => x.Id != f.Id && !IsPositionalId(x.Id))?.Id;
    }

    /// <summary>An id made from the widget's position ("p0:3"), which changes when the page's /Annots do.</summary>
    public static bool IsPositionalId(string id) => System.Text.RegularExpressions.Regex.IsMatch(id, @"^p\d+:\d+$");

    /// <summary>The page's ids in fill order with <paramref name="f"/> swapped with its neighbor; refused when it is
    /// already at that end.</summary>
    public static IReadOnlyList<string> TabOrder(DesignField f, int step, IReadOnlyList<DesignField> fields)
    {
        var onPage = fields.Where(x => x.PageIndex == f.PageIndex).OrderBy(x => x.TabIndex).ToList();
        var i = onPage.FindIndex(x => x.Id == f.Id);
        var j = i + step;
        if (i < 0 || j < 0 || j >= onPage.Count) throw new DesignRefusal(step < 0 ? PdfStrings.Form_AlreadyFirst : PdfStrings.Form_AlreadyLast);
        (onPage[i], onPage[j]) = (onPage[j], onPage[i]);
        return [.. onPage.Select(x => x.Id)];
    }

    /// <summary>Suggestions still worth showing: without those a field now covers (30% of the smaller).</summary>
    public static IReadOnlyList<FieldSuggestion> StillSuggested(IReadOnlyList<FieldSuggestion> suggestions, IReadOnlyList<DesignField> fields) =>
        [.. suggestions.Where(s => !fields.Any(f => f.PageIndex == s.PageIndex && Overlap(f.Rect, s.Rect) > 0.3))];

    private static double Overlap(RectD a, RectD b)
    {
        var i = a.Intersect(b);
        return i.IsEmpty ? 0 : i.Width * i.Height / Math.Max(1e-6, Math.Min(a.Width * a.Height, b.Width * b.Height));
    }

    // ───────────────────────────── What a typed value does ─────────────────────────────

    /// <summary>The name typed for <paramref name="f"/> (trimmed), checked against the other fields (a radio button's group
    /// doesn't clash with it); the same name changes nothing.</summary>
    public static DesignField Renamed(DesignField f, string typed, IReadOnlyList<DesignField> fields)
    {
        var name = typed.Trim();
        if (name == f.Name) return f;
        var others = fields.Where(o => o.Id != f.Id && !(f.Kind == DesignFieldKind.Radio && o.Name == f.Name)).Select(o => (o.Name, o.Kind));
        return FormDesign.NameClash(others, name, f.Kind) is { } problem ? throw new DesignRefusal(problem) : f with { Name = name };
    }

    /// <summary>The most characters typed: a whole number up to 100,000 (nothing: no limit).</summary>
    public static DesignField WithMaxLength(DesignField f, string typed)
    {
        var text = typed.Trim();
        if (text.Length == 0) return f with { MaxLength = 0 };
        return int.TryParse(text, NumberStyles.None, CultureInfo.CurrentCulture, out var n) && n is >= 0 and <= 100_000
            ? f with { MaxLength = n }
            : throw new DesignRefusal(PdfStrings.Form_MaxLengthInvalid);
    }

    /// <summary>The value typed for a check box or radio button; a radio button that was the group's default stays it.</summary>
    public static DesignField WithExportValue(DesignField f, string typed, IReadOnlyList<DesignField> fields)
    {
        var v = typed.Trim();
        if (v == f.ExportValue) return f;
        if (FormDesign.ExportValueProblem(v) is { } problem) throw new DesignRefusal(problem);
        if (f.Kind == DesignFieldKind.Radio && fields.Any(o => o.Id != f.Id && o.Kind == DesignFieldKind.Radio && o.Name == f.Name && o.ExportValue == v))
            throw new DesignRefusal(Loc.Format(PdfStrings.Form_ValueTaken, f.Name, v));
        return f with { ExportValue = v, DefaultValue = f.Kind == DesignFieldKind.Radio && f.DefaultValue == f.ExportValue ? v : f.DefaultValue };
    }

    /// <summary>
    /// The options editor's lines: "Shown text" (the value is the same), or "Shown text = value" (Acrobat's item and
    /// export value). Repeated values keep their first line.
    /// </summary>
    public static (List<string> Options, List<string> Labels) ParseChoices(string text)
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

    /// <summary>The options editor's text for a field's choices (see <see cref="ParseChoices"/>), a line each.</summary>
    public static string ChoicesText(DesignField f) =>
        string.Join(Environment.NewLine, f.Options.Select((o, i) => f.ShownOptions[i] == o ? o : $"{f.ShownOptions[i]} = {o}"));

    /// <summary>The choices typed: at least one; the default stays only if it is still a choice.</summary>
    public static DesignField WithChoices(DesignField f, string typed)
    {
        var (options, labels) = ParseChoices(typed);
        if (options.SequenceEqual(f.Options) && labels.SequenceEqual(f.ShownOptions)) return f;
        if (options.Count == 0) throw new DesignRefusal(PdfStrings.Form_NoChoices);
        return f with
        {
            Options = options,
            OptionLabels = labels.SequenceEqual(options) ? [] : labels,
            DefaultValue = options.Contains(f.DefaultValue) ? f.DefaultValue : "",
        };
    }

    /// <summary>"Checked (or selected) by default" turned on or off; turning off a radio button that isn't the default
    /// leaves the group's default.</summary>
    public static DesignField WithDefaultOn(DesignField f, bool on) => f with
    {
        DefaultValue = on ? f.ExportValue : f.Kind == DesignFieldKind.Radio && f.DefaultValue != f.ExportValue ? f.DefaultValue : "",
    };

    /// <summary>The default picked from a choice field's list: 0 none, else that choice.</summary>
    public static DesignField WithDefaultChoice(DesignField f, int index) =>
        f with { DefaultValue = index <= 0 ? "" : f.Options.ElementAtOrDefault(index - 1) ?? "" };

    /// <summary>The default's entry in a choice field's list (0: none).</summary>
    public static int DefaultChoiceIndex(DesignField f) => f.Options.ToList().IndexOf(f.DefaultValue) + 1;

    /// <summary>
    /// The text size typed: "Auto" (or <paramref name="autoLabel"/>, the list's word for it) or nothing is automatic; a
    /// number from 0 to 200 ("12", "12 pt"); null when it isn't one (nothing changes).
    /// </summary>
    public static double? ParseSize(string typed, string autoLabel = "Auto")
    {
        var text = typed.Trim();
        if (text.Length == 0 || text.Equals(autoLabel, StringComparison.OrdinalIgnoreCase) || text.Equals("Auto", StringComparison.OrdinalIgnoreCase)) return 0;
        return double.TryParse(text.TrimEnd('p', 't', ' '), NumberStyles.Float, CultureInfo.CurrentCulture, out var size) && size is >= 0 and <= 200 ? size : null;
    }

    /// <summary>The change is one worth writing: the fields differ, comparing the choices as they show.</summary>
    public static bool Differs(DesignField a, DesignField b) =>
        !(a with { Options = b.Options, OptionLabels = b.OptionLabels } == b && a.Options.SequenceEqual(b.Options) && a.ShownOptions.SequenceEqual(b.ShownOptions));
}
