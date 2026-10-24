using System.Globalization;
using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>The kinds of form field the form designer places.</summary>
public enum DesignFieldKind { Text, CheckBox, Radio, ComboBox, ListBox, Signature, Button }

/// <summary>What a push button does: reset the form, print, nothing, or an action Inkvolt PDF keeps as it is.</summary>
public enum FieldButtonAction { None, ResetForm, Print, Other }

/// <summary>
/// One widget of a form field as the form designer shows and edits it (page space: points, top-left origin, rotation
/// applied). Field-wide properties (name, tooltip, flags, default, options, format) are the same on every widget of a
/// field; a radio button's <see cref="Name"/> is its group's.
/// </summary>
public sealed record DesignField
{
    /// <summary>The widget's /NM, else its position ("p&lt;page&gt;:&lt;index&gt;", valid for the bytes it was read from).</summary>
    public string Id { get; init; } = "";

    /// <summary>The fully qualified field name ("address.city" puts the field under a parent "address").</summary>
    public string Name { get; init; } = "";

    public DesignFieldKind Kind { get; init; }
    public int PageIndex { get; init; }
    public RectD Rect { get; init; }
    public string Tooltip { get; init; } = "";
    public bool Required { get; init; }
    public bool ReadOnly { get; init; }

    /// <summary>Text and choice fields: the value a reset restores (and the field starts with). Check box: its export
    /// value when checked by default, else empty. Radio: the export value of the group's default button, or empty.</summary>
    public string DefaultValue { get; init; } = "";

    /// <summary>Text size in points; 0 = fit the box (auto).</summary>
    public double FontSize { get; init; }

    public AnnotColor TextColor { get; init; }

    /// <summary>Border color; null = no border.</summary>
    public AnnotColor? BorderColor { get; init; }

    /// <summary>Background color; null = transparent.</summary>
    public AnnotColor? FillColor { get; init; }

    /// <summary>Text alignment: 0 = left, 1 = centered, 2 = right.</summary>
    public int Alignment { get; init; }

    public bool Multiline { get; init; }

    /// <summary>Text fields: the most characters it takes; 0 = no limit.</summary>
    public int MaxLength { get; init; }

    /// <summary>Text fields: an Acrobat number, percent, date or special format (AFNumber_Format …), or null.</summary>
    public FieldFormat? Format { get; init; }

    /// <summary>The field has a format script that isn't one of the Acrobat built-ins: <see cref="Format"/> can't change it.</summary>
    public bool CustomFormat { get; init; }

    /// <summary>Combo and list boxes: the choices (export values).</summary>
    public IReadOnlyList<string> Options { get; init; } = [];

    /// <summary>Combo and list boxes: the text shown for each choice, parallel to <see cref="Options"/> (empty: the
    /// export values themselves). Written as [export display] pairs where they differ.</summary>
    public IReadOnlyList<string> OptionLabels { get; init; } = [];

    /// <summary>The text shown for each choice (<see cref="OptionLabels"/>, else the export values).</summary>
    public IReadOnlyList<string> ShownOptions => OptionLabels.Count == Options.Count ? OptionLabels : Options;

    /// <summary>Combo box: the user may type a value of their own.</summary>
    public bool Editable { get; init; }

    /// <summary>List box: several choices may be selected.</summary>
    public bool MultiSelect { get; init; }

    /// <summary>Check box or radio button: the value it stands for when on (its "on" appearance state).</summary>
    public string ExportValue { get; init; } = "Yes";

    /// <summary>Push buttons: what clicking does.</summary>
    public FieldButtonAction Action { get; init; }

    /// <summary>Push buttons: the label on the button.</summary>
    public string Caption { get; init; } = "";

    /// <summary>A signature field that has been signed: it can't be moved, changed or deleted.</summary>
    public bool Signed { get; init; }

    /// <summary>Position in the page's fill (Tab) order, 0-based, as <see cref="FormEditor.Read"/> orders it.</summary>
    public int TabIndex { get; init; }

    /// <summary>A name for lists and screen readers: "Text field Name", "Radio button Gender (Female)".</summary>
    public string Describe() => $"{KindName(Kind)} {Name}{(Kind == DesignFieldKind.Radio ? $" ({ExportValue})" : "")}";

    public static string KindName(DesignFieldKind kind) => kind switch
    {
        DesignFieldKind.Text => "Text field",
        DesignFieldKind.CheckBox => "Check box",
        DesignFieldKind.Radio => "Radio button",
        DesignFieldKind.ComboBox => "Dropdown",
        DesignFieldKind.ListBox => "List box",
        DesignFieldKind.Signature => "Signature field",
        _ => "Button",
    };
}

/// <summary>
/// Form authoring: adds, changes, moves, deletes and orders AcroForm fields. Every field gets real appearance streams
/// (text, choice and button faces drawn the way <see cref="FormEditor"/> draws filled values, check boxes and radio
/// buttons with their on and off states), a /DA and the form's /DR fonts, so it shows and fills in viewers that ignore
/// NeedAppearances. Names are fully qualified: "a.b" sits under a parent field "a"; radio buttons with the same name are
/// the kids of one group. Edits go through <see cref="PdfObj.Save"/>, so signed files are appended to and encrypted
/// files keep their protection.
/// </summary>
public static class FormDesign
{
    private const int FfReadOnly = 1, FfRequired = 2, FfMultiline = 1 << 12, FfNoToggleToOff = 1 << 14, FfRadio = 1 << 15,
        FfPushButton = 1 << 16, FfCombo = 1 << 17, FfEdit = 1 << 18, FfMultiSelect = 1 << 21;

    private const int MaxNameLength = 120;

    // ───────────────────────────── Reading ─────────────────────────────

    /// <summary>Every widget of every form field, page by page in each page's /Annots order.</summary>
    public static IReadOnlyList<DesignField> Read(byte[] data, string? password)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, "This PDF's form can't be read");
        return ReadIn(doc);
    }

    private static List<DesignField> ReadIn(PdfDocument doc)
    {
        var acro = PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"]);
        var fields = new List<FormEditor.Field>();
        FormEditor.Collect(doc, acro, fields);
        var fieldOf = FieldOf(fields);
        var list = new List<DesignField>();
        for (var p = 0; p < doc.PageCount; p++)
        {
            if (PdfObj.Array(doc.Pages[p].Elements["/Annots"]) is not { } annots) continue;
            var onPage = new List<DesignField>();
            for (var i = 0; i < annots.Elements.Count; i++)
                if (PdfObj.Dict(annots.Elements[i]) is { } a && fieldOf.TryGetValue(a, out var f) && Describe(doc, acro, f, a, p, i) is { } d)
                    onPage.Add(d);
            list.AddRange(WithTabOrder(onPage, PdfObj.Name(doc.Pages[p].Elements["/Tabs"])));
        }
        return list;
    }

    /// <summary>The fill order the way <see cref="FormEditor"/> follows it: annotation order for /Tabs /A, /W and /S
    /// (structure order is approximated by the annotation order), columns for /C, rows otherwise.</summary>
    private static IEnumerable<DesignField> WithTabOrder(List<DesignField> onPage, string? tabs)
    {
        IEnumerable<(DesignField F, int I)> items = onPage.Select((f, i) => (f, i));
        var ordered = tabs switch
        {
            "A" or "W" or "S" => items.ToList(),
            "C" => [.. items.OrderBy(x => Math.Round(x.F.Rect.X / 6)).ThenBy(x => x.F.Rect.Y).ThenBy(x => x.I)],
            _ => [.. items.OrderBy(x => Math.Round(x.F.Rect.Y / 6)).ThenBy(x => x.F.Rect.X).ThenBy(x => x.I)],
        };
        var rank = new int[onPage.Count];
        for (var k = 0; k < ordered.Count; k++) rank[ordered[k].I] = k;
        return onPage.Select((f, i) => f with { TabIndex = rank[i] });
    }

    private static Dictionary<PdfDictionary, FormEditor.Field> FieldOf(List<FormEditor.Field> fields)
    {
        var map = new Dictionary<PdfDictionary, FormEditor.Field>(ReferenceEqualityComparer.Instance);
        foreach (var f in fields)
            foreach (var w in f.Widgets)
                map.TryAdd(w, f);
        return map;
    }

    private static DesignFieldKind? KindOf(FormEditor.Field f) => f.Type switch
    {
        "/Tx" => DesignFieldKind.Text,
        "/Ch" => (f.Flags & FfCombo) != 0 ? DesignFieldKind.ComboBox : DesignFieldKind.ListBox,
        "/Sig" => DesignFieldKind.Signature,
        "/Btn" when (f.Flags & FfPushButton) != 0 => DesignFieldKind.Button,
        "/Btn" when (f.Flags & FfRadio) != 0 => DesignFieldKind.Radio,
        "/Btn" => DesignFieldKind.CheckBox,
        _ => null,
    };

    private static DesignField? Describe(PdfDocument doc, PdfDictionary? acro, FormEditor.Field f, PdfDictionary w, int page, int index)
    {
        if (KindOf(f) is not { } kind || PdfObj.Array(w.Elements["/Rect"]) is not { Elements.Count: >= 4 } r) return null;
        var rect = PdfObj.RectToPage(doc.Pages[page], r);
        if (rect.IsEmpty) return null;
        var da = DefaultAppearance.Parse(DaOf(acro, f, w));
        var mk = PdfObj.Dict(w.Elements["/MK"]);
        var formatScript = Script(f, w, "/F");
        var format = kind == DesignFieldKind.Text ? FormScripts.ParseFormat(formatScript) : null;
        var (exports, labels) = FormEditor.ReadOptions(FormEditor.Inherited(f.Dict, "/Opt"));
        var dv = PdfObj.Resolve(FormEditor.Inherited(f.Dict, "/DV")) switch
        {
            PdfString s => s.Value,
            PdfName n => n.Value.TrimStart('/'),
            PdfArray a => string.Join('\n', a.Elements.Select(PdfObj.Str).OfType<string>()),
            _ => "",
        };
        if (kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio && dv == "Off") dv = "";
        return new DesignField
        {
            Id = Annotations.IdOf(w, page, index),
            Name = f.Name,
            Kind = kind,
            PageIndex = page,
            Rect = rect,
            Tooltip = PdfObj.Str(FormEditor.Inherited(f.Dict, "/TU")) ?? "",
            Required = (f.Flags & FfRequired) != 0,
            ReadOnly = (f.Flags & FfReadOnly) != 0,
            DefaultValue = dv,
            FontSize = da.Size,
            TextColor = ToRgb(da.Color.C),
            BorderColor = ColorOf(mk?.Elements["/BC"]),
            FillColor = ColorOf(mk?.Elements["/BG"]),
            Alignment = Math.Clamp(PdfObj.Int(w.Elements["/Q"]) ?? PdfObj.Int(FormEditor.Inherited(f.Dict, "/Q")) ?? PdfObj.Int(acro?.Elements["/Q"]) ?? 0, 0, 2),
            Multiline = kind == DesignFieldKind.Text && (f.Flags & FfMultiline) != 0,
            MaxLength = kind == DesignFieldKind.Text ? Math.Max(0, PdfObj.Int(FormEditor.Inherited(f.Dict, "/MaxLen")) ?? 0) : 0,
            Format = format,
            CustomFormat = format is null && !string.IsNullOrWhiteSpace(formatScript),
            Options = kind is DesignFieldKind.ComboBox or DesignFieldKind.ListBox ? exports : [],
            OptionLabels = kind is DesignFieldKind.ComboBox or DesignFieldKind.ListBox && !labels.SequenceEqual(exports) ? labels : [],
            Editable = kind == DesignFieldKind.ComboBox && (f.Flags & FfEdit) != 0,
            MultiSelect = kind == DesignFieldKind.ListBox && (f.Flags & FfMultiSelect) != 0,
            ExportValue = kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio ? FormEditor.OnStateOf(w) ?? "Yes" : "",
            Action = kind == DesignFieldKind.Button ? ActionOf(w) : FieldButtonAction.None,
            Caption = kind == DesignFieldKind.Button ? PdfObj.Str(mk?.Elements["/CA"]) ?? "" : "",
            Signed = kind == DesignFieldKind.Signature && PdfObj.Dict(FormEditor.Inherited(f.Dict, "/V")) is not null,
        };
    }

    private static string DaOf(PdfDictionary? acro, FormEditor.Field f, PdfDictionary w) =>
        PdfObj.Str(w.Elements["/DA"]) ?? PdfObj.Str(FormEditor.Inherited(f.Dict, "/DA")) ?? PdfObj.Str(acro?.Elements["/DA"]) ?? "/Helv 0 Tf 0 g";

    /// <summary>The JavaScript of a widget's or its field's additional action (/AA /F, /K), if any.</summary>
    private static string? Script(FormEditor.Field f, PdfDictionary w, string key)
    {
        foreach (var holder in new[] { w, f.Dict })
            if (PdfObj.Dict(PdfObj.Dict(holder.Elements["/AA"])?.Elements[key]) is { } action && PdfObj.Name(action.Elements["/S"]) == "JavaScript")
                return PdfObj.Text(action.Elements["/JS"]);
        return null;
    }

    private static FieldButtonAction ActionOf(PdfDictionary w)
    {
        if (PdfObj.Dict(w.Elements["/A"]) is not { } a) return w.Elements.ContainsKey("/AA") ? FieldButtonAction.Other : FieldButtonAction.None;
        return PdfObj.Name(a.Elements["/S"]) switch
        {
            "ResetForm" when !a.Elements.ContainsKey("/Fields") && !a.Elements.ContainsKey("/Next") => FieldButtonAction.ResetForm,
            "Named" when PdfObj.Name(a.Elements["/N"]) == "Print" && !a.Elements.ContainsKey("/Next") => FieldButtonAction.Print,
            _ => FieldButtonAction.Other,
        };
    }

    private static AnnotColor ToRgb(double[] c) => c.Length switch
    {
        1 => new AnnotColor(c[0], c[0], c[0]),
        3 => new AnnotColor(c[0], c[1], c[2]),
        4 => new AnnotColor((1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])),
        _ => default,
    };

    private static AnnotColor? ColorOf(PdfItem? item) =>
        PdfColorValue.From(PdfObj.Array(item)) is { } c ? ToRgb(c.C) : null;

    // ───────────────────────────── Names ─────────────────────────────

    /// <summary>Why <paramref name="name"/> can't be a field name, or null when it can.</summary>
    public static string? NameProblem(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "Type a name for the field.";
        if (name.Length > MaxNameLength) return $"Use at most {MaxNameLength} characters.";
        if (name.Any(char.IsControl)) return "A field name can't contain tabs or line breaks.";
        if (name.Split('.').Any(s => s.Trim().Length == 0 || s.Trim() != s))
            return "Dots separate the parts of a name (\"address.city\"): a name can't start or end with one, have two in a row, or spaces around one.";
        return null;
    }

    /// <summary>Why a check box or radio button can't have <paramref name="value"/> as its export value, or null.</summary>
    public static string? ExportValueProblem(string value)
    {
        if (value.Length == 0) return "Type the value the button stands for when it's on.";
        if (value == "Off") return "\"Off\" means not selected; choose another value.";
        if (value.Length > 60 || !value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.'))
            return "Use letters, digits, '-', '_' and '.' only (at most 60).";
        return null;
    }

    /// <summary>
    /// Why a field of <paramref name="kind"/> can't be named <paramref name="name"/> among <paramref name="existing"/>
    /// (name and kind of every other field), or null. A radio button may take the name of a radio group: it joins it.
    /// </summary>
    public static string? NameClash(IEnumerable<(string Name, DesignFieldKind Kind)> existing, string name, DesignFieldKind kind)
    {
        if (NameProblem(name) is { } problem) return problem;
        foreach (var (other, otherKind) in existing)
        {
            if (other == name)
            {
                if (kind == DesignFieldKind.Radio && otherKind == DesignFieldKind.Radio) continue;
                return $"Another field is already named \"{name}\".";
            }
            if (other.StartsWith(name + ".", StringComparison.Ordinal)) return $"\"{name}\" already groups other fields (such as \"{other}\").";
            if (name.StartsWith(other + ".", StringComparison.Ordinal)) return $"\"{other}\" is a field, so it can't hold \"{name}\".";
        }
        return null;
    }

    /// <summary><paramref name="baseName"/> if no field has it yet, else "baseName_2", "baseName_3", …</summary>
    public static string UniqueName(IEnumerable<string> existing, string baseName)
    {
        var free = NameCheck(existing);
        bool Free(string n) => free(n);
        if (Free(baseName)) return baseName;
        for (var i = 2; ; i++)
            if (Free($"{baseName}_{i}")) return $"{baseName}_{i}";
    }

    /// <summary>The next numbered name for a new field of <paramref name="kind"/>: "Text1", "Check Box2", "Group1" …</summary>
    public static string NextName(IEnumerable<string> existing, DesignFieldKind kind)
    {
        var prefix = kind switch
        {
            DesignFieldKind.Text => "Text",
            DesignFieldKind.CheckBox => "Check Box",
            DesignFieldKind.Radio => "Group",
            DesignFieldKind.ComboBox => "Dropdown",
            DesignFieldKind.ListBox => "List Box",
            DesignFieldKind.Signature => "Signature",
            _ => "Button",
        };
        var free = NameCheck(existing);
        for (var i = 1; ; i++)
            if (free(prefix + i)) return prefix + i;
    }

    /// <summary>
    /// Whether a name is free among <paramref name="existing"/>: not taken, not a group of taken names ("a" when "a.b"
    /// is), and not under a taken field ("a.b" when "a" is). Each check costs the name's length, not the field count.
    /// </summary>
    private static Func<string, bool> NameCheck(IEnumerable<string> existing)
    {
        var taken = existing.ToHashSet(StringComparer.Ordinal);
        var groups = new HashSet<string>(StringComparer.Ordinal);
        foreach (var t in taken)
            for (var dot = t.IndexOf('.'); dot > 0; dot = t.IndexOf('.', dot + 1))
                groups.Add(t[..dot]);
        return n =>
        {
            if (taken.Contains(n) || groups.Contains(n)) return false;
            for (var dot = n.IndexOf('.'); dot > 0; dot = n.IndexOf('.', dot + 1))
                if (taken.Contains(n[..dot])) return false;
            return true;
        };
    }

    /// <summary>
    /// A new field of <paramref name="kind"/> over <paramref name="rect"/> with the designer's defaults (thin gray border,
    /// automatic text size; check boxes and radio buttons black, push buttons gray with a caption) and a fresh id.
    /// <paramref name="name"/> null: the next numbered name.
    /// </summary>
    public static DesignField NewField(DesignFieldKind kind, int pageIndex, RectD rect, IEnumerable<string> existingNames, string? name = null)
    {
        var names = existingNames.ToList();
        return new DesignField
        {
            Id = Annotations.NewId(),
            Name = name is null ? NextName(names, kind) : UniqueName(names, name),
            Kind = kind,
            PageIndex = pageIndex,
            Rect = rect,
            BorderColor = kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio ? new AnnotColor(0, 0, 0) : new AnnotColor(0.45, 0.45, 0.45),
            FillColor = kind == DesignFieldKind.Button ? new AnnotColor(0.85, 0.85, 0.85) : null,
            Alignment = kind == DesignFieldKind.Button ? 1 : 0,
            Options = kind is DesignFieldKind.ComboBox or DesignFieldKind.ListBox ? ["Option 1", "Option 2", "Option 3"] : [],
            ExportValue = kind == DesignFieldKind.Radio ? "Choice1" : "Yes",
            Action = kind == DesignFieldKind.Button ? FieldButtonAction.ResetForm : FieldButtonAction.None,
            Caption = kind == DesignFieldKind.Button ? "Reset" : "",
        };
    }

    /// <summary>
    /// A copy of <paramref name="field"/> moved by (<paramref name="dx"/>, <paramref name="dy"/>) with a new id: a radio
    /// button stays in its group with the next free export value ("Choice2"), any other field gets a new name.
    /// </summary>
    public static DesignField Duplicate(DesignField field, IReadOnlyList<DesignField> existing, double dx, double dy)
    {
        var copy = field with { Id = Annotations.NewId(), Rect = field.Rect with { X = field.Rect.X + dx, Y = field.Rect.Y + dy }, Signed = false };
        if (field.Kind == DesignFieldKind.Radio)
        {
            var values = existing.Where(f => f.Kind == DesignFieldKind.Radio && f.Name == field.Name).Select(f => f.ExportValue).ToHashSet(StringComparer.Ordinal);
            var stem = field.ExportValue.TrimEnd("0123456789".ToCharArray());
            if (stem.Length == 0) stem = "Choice";
            var n = 2;
            while (values.Contains(stem + n)) n++;
            return copy with { ExportValue = stem + n };
        }
        return copy with { Name = UniqueName(existing.Select(f => f.Name), field.Name) };
    }

    // ───────────────────────────── Editing ─────────────────────────────

    /// <summary>
    /// Adds fields (one undo step for the lot). Each gets <see cref="DesignField.Id"/> as its /NM (a new one when
    /// empty). Throws <see cref="ArgumentException"/> for a name or value that can't be used.
    /// </summary>
    public static byte[] Add(byte[] data, string? password, IReadOnlyList<DesignField> fields)
    {
        if (fields.Count == 0) return data;
        using var doc = Open(data, password);
        var acro = EnsureAcroForm(doc);
        foreach (var spec in fields)
        {
            Validate(doc, spec);
            var all = Fields(doc, acro);
            if (NameClash(all.Where(f => KindOf(f) is not null).Select(f => (f.Name, KindOf(f)!.Value)), spec.Name, spec.Kind) is { } clash)
                throw new ArgumentException(clash);
            var page = doc.Pages[spec.PageIndex];
            var w = new PdfDictionary(doc);
            w.Elements["/Type"] = new PdfName("/Annot");
            w.Elements["/Subtype"] = new PdfName("/Widget");
            w.Elements["/NM"] = new PdfString(spec.Id.Length > 0 ? spec.Id : Annotations.NewId());
            w.Elements["/F"] = new PdfInteger(4); // print
            w.Elements["/P"] = page.Reference!;
            var mk = new PdfDictionary(doc);
            var rot = ((page.Rotate % 360) + 360) % 360;
            if (rot != 0) mk.Elements["/R"] = new PdfInteger(rot); // upright on the turned page, as Acrobat does
            w.Elements["/MK"] = mk;
            var bs = new PdfDictionary(doc);
            bs.Elements["/W"] = new PdfInteger(1);
            bs.Elements["/S"] = new PdfName("/S");
            w.Elements["/BS"] = bs;
            doc.Internals.AddObject(w);
            PdfObj.Annots(doc, page).Elements.Add(w.Reference!);

            PdfDictionary field;
            if (spec.Kind == DesignFieldKind.Radio)
            {
                field = RadioGroup(doc, acro, all, spec.Name);
                w.Elements["/Parent"] = field.Reference!;
                KidsOf(doc, field).Elements.Add(w.Reference!);
            }
            else
            {
                field = w;
                w.Elements["/FT"] = new PdfName(spec.Kind switch
                {
                    DesignFieldKind.Text => "/Tx",
                    DesignFieldKind.ComboBox or DesignFieldKind.ListBox => "/Ch",
                    DesignFieldKind.Signature => "/Sig",
                    _ => "/Btn",
                });
                var flags = spec.Kind switch
                {
                    DesignFieldKind.Button => FfPushButton,
                    DesignFieldKind.ComboBox => FfCombo,
                    _ => 0,
                };
                if (flags != 0) w.Elements["/Ff"] = new PdfInteger(flags);
                Attach(doc, acro, w, spec.Name);
            }
            Apply(doc, acro, field, w, spec, isNew: true);
        }
        return PdfObj.Save(doc);
    }

    /// <summary>
    /// Changes fields to match <paramref name="changes"/> (matched by <see cref="DesignField.Id"/>): placement, name
    /// (a radio button renamed moves to that group), and properties. Widgets without an /NM get one, reported through
    /// <paramref name="newIds"/> (old id → new id). Signed signature fields can't be changed.
    /// </summary>
    public static byte[] Update(byte[] data, string? password, IReadOnlyList<DesignField> changes, IDictionary<string, string>? newIds = null)
    {
        if (changes.Count == 0) return data;
        using var doc = Open(data, password);
        var acro = EnsureAcroForm(doc);
        // Find every widget first: positional ids ("p0:3") refer to the document as it was read.
        var targets = changes.Select(c => (Spec: c, Found: Annotations.Find(doc, c.Id) ?? throw new InvalidOperationException("That field is no longer in the document."))).ToList();
        foreach (var (change, (page, w)) in targets)
        {
            var spec = change;
            var all = Fields(doc, acro);
            var f = all.FirstOrDefault(x => x.Widgets.Any(k => ReferenceEquals(k, w))) ?? throw new InvalidOperationException("That isn't a form field.");
            var kind = KindOf(f) ?? throw new InvalidOperationException("That kind of field can't be edited.");
            if (kind == DesignFieldKind.Signature && PdfObj.Dict(FormEditor.Inherited(f.Dict, "/V")) is not null)
                throw new InvalidOperationException("A signed signature field can't be changed.");
            if (kind != spec.Kind && !(kind is DesignFieldKind.ComboBox or DesignFieldKind.ListBox && spec.Kind is DesignFieldKind.ComboBox or DesignFieldKind.ListBox))
                throw new InvalidOperationException("A field can't change its kind.");
            var index = PdfObj.Array(doc.Pages[page].Elements["/Annots"])!.Elements.Select(PdfObj.Dict).ToList().FindIndex(a => ReferenceEquals(a, w));
            Validate(doc, spec with { PageIndex = page }, Describe(doc, acro, f, w, page, index));
            if (PdfObj.Str(w.Elements["/NM"]) is not { Length: > 0 })
            {
                var id = Annotations.NewId();
                w.Elements["/NM"] = new PdfString(id);
                newIds?.Add(spec.Id, id);
            }

            var field = f.Dict;
            if (spec.Name != f.Name)
            {
                var others = all.Where(x => x != f && KindOf(x) is not null).Select(x => (x.Name, KindOf(x)!.Value));
                if (NameClash(others, spec.Name, spec.Kind) is { } clash) throw new ArgumentException(clash);
                if (kind == DesignFieldKind.Radio && f.Widgets.Count > 1)
                {
                    // This button leaves its group for the named one (created if needed); the group keeps the others.
                    RemoveKid(doc, acro, f.Dict, w);
                    field = RadioGroup(doc, acro, all.Where(x => x != f).ToList(), spec.Name, like: f.Dict);
                    w.Elements["/Parent"] = field.Reference!;
                    KidsOf(doc, field).Elements.Add(w.Reference!);
                }
                else if (kind == DesignFieldKind.Radio && all.FirstOrDefault(x => x != f && x.Name == spec.Name && KindOf(x) == DesignFieldKind.Radio) is { } target)
                {
                    // The group's only button joins another group: the old group goes.
                    RemoveKid(doc, acro, f.Dict, w);
                    field = target.Dict;
                    w.Elements["/Parent"] = field.Reference!;
                    KidsOf(doc, field).Elements.Add(w.Reference!);
                }
                else
                {
                    Detach(doc, acro, f.Dict);
                    Attach(doc, acro, f.Dict, spec.Name);
                }
            }
            var joined = !ReferenceEquals(field, f.Dict);
            if (joined)
            {
                // A button that changes groups doesn't bring its old group's default: the new group keeps its own, and
                // a new group starts with this button as default only when it was the old one's.
                var keep = PdfObj.Name(field.Elements["/DV"]) is { } dv && dv != "Off" ? dv : spec.DefaultValue == spec.ExportValue && field.Elements["/DV"] is null && KidsOf(doc, field).Elements.Count == 1 ? spec.ExportValue : "";
                spec = spec with { DefaultValue = keep };
            }
            Apply(doc, acro, field, w, spec with { PageIndex = page }, isNew: false, joined);
        }
        return PdfObj.Save(doc);
    }

    /// <summary>Deletes the widgets <paramref name="ids"/>, and each field left without widgets (and parents left empty).</summary>
    public static byte[] Delete(byte[] data, string? password, IReadOnlyList<string> ids)
    {
        if (ids.Count == 0) return data;
        using var doc = Open(data, password);
        var acro = EnsureAcroForm(doc);
        var targets = ids.Select(id => Annotations.Find(doc, id) ?? throw new InvalidOperationException("That field is no longer in the document.")).ToList();
        foreach (var (page, w) in targets)
        {
            var f = Fields(doc, acro).FirstOrDefault(x => x.Widgets.Any(k => ReferenceEquals(k, w)));
            if (f is not null && f.Type == "/Sig" && PdfObj.Dict(FormEditor.Inherited(f.Dict, "/V")) is not null)
                throw new InvalidOperationException("A signed signature field can't be deleted.");
            var annots = PdfObj.Annots(doc, doc.Pages[page]);
            for (var i = annots.Elements.Count - 1; i >= 0; i--)
                if (ReferenceEquals(PdfObj.Dict(annots.Elements[i]), w)) annots.Elements.RemoveAt(i);
            if (f is null) continue;
            if (ReferenceEquals(f.Dict, w))
            {
                Detach(doc, acro, w);
                RemoveFromCalculationOrder(acro, w);
            }
            else RemoveKid(doc, acro, f.Dict, w); // the field goes (from /CO too) with its last widget
        }
        SignedEdits.NoteRemoval();
        return PdfObj.Save(doc);
    }

    /// <summary>
    /// Sets the fill (Tab) order of page <paramref name="pageIndex"/>'s fields: the widgets <paramref name="ids"/> in
    /// that order (others keep their places), with the page's /Tabs set to widget order (/W), which Acrobat and
    /// <see cref="FormEditor"/> follow. Widgets without an /NM get one (their positional id would change), reported
    /// through <paramref name="newIds"/>.
    /// </summary>
    public static byte[] SetTabOrder(byte[] data, string? password, int pageIndex, IReadOnlyList<string> ids, IDictionary<string, string>? newIds = null)
    {
        using var doc = Open(data, password);
        if (pageIndex < 0 || pageIndex >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(pageIndex));
        var page = doc.Pages[pageIndex];
        if (PdfObj.Array(page.Elements["/Annots"]) is null) return data;
        var annots = PdfObj.Annots(doc, page);
        var slots = new List<int>();
        var byId = new Dictionary<string, PdfItem>(StringComparer.Ordinal);
        for (var i = 0; i < annots.Elements.Count; i++)
        {
            if (PdfObj.Dict(annots.Elements[i]) is not { } a || Annotations.IdOf(a, pageIndex, i) is not { } id || !ids.Contains(id)) continue;
            slots.Add(i);
            byId[id] = annots.Elements[i];
            if (PdfObj.Str(a.Elements["/NM"]) is not { Length: > 0 })
            {
                var nm = Annotations.NewId();
                a.Elements["/NM"] = new PdfString(nm);
                newIds?.Add(id, nm);
            }
        }
        var ordered = ids.Where(byId.ContainsKey).Distinct().Select(id => byId[id]).ToList();
        for (var k = 0; k < slots.Count && k < ordered.Count; k++) annots.Elements[slots[k]] = ordered[k];
        page.Elements["/Tabs"] = new PdfName("/W");
        return PdfObj.Save(doc);
    }

    // ───────────────────────────── Internals ─────────────────────────────

    private static PdfDocument Open(byte[] data, string? password) => PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited");

    /// <summary>
    /// Checks what a new field sets, or what an edit changes (<paramref name="old"/>: the field as it is): a field the
    /// form came with may keep a name, value or size Inkvolt PDF wouldn't make, and still be moved.
    /// </summary>
    private static void Validate(PdfDocument doc, DesignField spec, DesignField? old = null)
    {
        if (spec.PageIndex < 0 || spec.PageIndex >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(spec), "That page isn't in the document.");
        var resized = old is null || Math.Abs(old.Rect.Width - spec.Rect.Width) > 0.01 || Math.Abs(old.Rect.Height - spec.Rect.Height) > 0.01;
        if (resized && (spec.Rect.Width < 4 || spec.Rect.Height < 4)) throw new ArgumentException("A field needs to be at least 4 points wide and high.");
        if (old is null && NameProblem(spec.Name) is { } problem) throw new ArgumentException(problem);
        if (spec.Kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio && spec.ExportValue != old?.ExportValue && ExportValueProblem(spec.ExportValue) is { } bad)
            throw new ArgumentException(bad);
        if (spec.Kind is DesignFieldKind.ComboBox or DesignFieldKind.ListBox && !spec.Options.SequenceEqual(old?.Options ?? []) && spec.Options.Any(o => o.Length == 0))
            throw new ArgumentException("A choice can't be empty.");
        if (spec.OptionLabels.Count > 0 && spec.OptionLabels.Count != spec.Options.Count)
            throw new ArgumentException("Each choice needs its own text.");
    }

    private static List<FormEditor.Field> Fields(PdfDocument doc, PdfDictionary acro)
    {
        var list = new List<FormEditor.Field>();
        FormEditor.Collect(doc, acro, list);
        return list;
    }

    /// <summary>The catalog's /AcroForm (made if missing) with /Fields, /DR fonts and /DA; a hybrid form's XFA goes, since
    /// XFA viewers would show the old form without the new fields.</summary>
    private static PdfDictionary EnsureAcroForm(PdfDocument doc)
    {
        var catalog = doc.Internals.Catalog;
        if (PdfObj.Dict(catalog.Elements["/AcroForm"]) is not { } acro)
        {
            acro = new PdfDictionary(doc);
            doc.Internals.AddObject(acro);
            catalog.Elements["/AcroForm"] = acro.Reference!;
        }
        if (PdfObj.Array(acro.Elements["/Fields"]) is null) acro.Elements["/Fields"] = new PdfArray(doc);
        FormEditor.EnsureDefaultFonts(doc, acro);
        acro.Elements.Remove("/XFA");
        catalog.Elements.Remove("/NeedsRendering");
        return acro;
    }

    private static PdfArray KidsOf(PdfDocument doc, PdfDictionary node)
    {
        if (PdfObj.Array(node.Elements["/Kids"]) is { } kids) return kids;
        var made = new PdfArray(doc);
        node.Elements["/Kids"] = made;
        return made;
    }

    /// <summary>The radio group named <paramref name="name"/>, or a new one (copying <paramref name="like"/>'s flags and tooltip).</summary>
    private static PdfDictionary RadioGroup(PdfDocument doc, PdfDictionary acro, List<FormEditor.Field> all, string name, PdfDictionary? like = null)
    {
        if (all.FirstOrDefault(x => x.Name == name && KindOf(x) == DesignFieldKind.Radio) is { } existing) return existing.Dict;
        var g = new PdfDictionary(doc);
        g.Elements["/FT"] = new PdfName("/Btn");
        g.Elements["/Ff"] = new PdfInteger(like is null ? FfRadio | FfNoToggleToOff : PdfObj.Int(FormEditor.Inherited(like, "/Ff")) ?? FfRadio | FfNoToggleToOff);
        g.Elements["/Kids"] = new PdfArray(doc);
        g.Elements["/V"] = new PdfName("/Off");
        if (like is not null && PdfObj.Str(FormEditor.Inherited(like, "/TU")) is { } tu) g.Elements["/TU"] = PdfObj.MakeString(tu);
        doc.Internals.AddObject(g);
        Attach(doc, acro, g, name);
        return g;
    }

    /// <summary>Puts a terminal field under the parent fields its name's leading parts name (made when missing).</summary>
    private static void Attach(PdfDocument doc, PdfDictionary acro, PdfDictionary node, string fullName)
    {
        var parts = fullName.Split('.');
        var siblings = PdfObj.Array(acro.Elements["/Fields"])!;
        PdfDictionary? parent = null;
        foreach (var part in parts[..^1])
        {
            var next = siblings.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()
                .FirstOrDefault(d => PdfObj.Str(d.Elements["/T"]) == part && IsGroupNode(d));
            if (next is null)
            {
                next = new PdfDictionary(doc);
                next.Elements["/T"] = PdfObj.MakeString(part);
                next.Elements["/Kids"] = new PdfArray(doc);
                if (parent is not null) next.Elements["/Parent"] = parent.Reference!;
                doc.Internals.AddObject(next);
                siblings.Elements.Add(next.Reference!);
            }
            parent = next;
            siblings = KidsOf(doc, next);
        }
        node.Elements["/T"] = PdfObj.MakeString(parts[^1]);
        if (parent is null) node.Elements.Remove("/Parent");
        else node.Elements["/Parent"] = parent.Reference!;
        siblings.Elements.Add(node.Reference is { } r ? r : node);
    }

    /// <summary>A non-terminal field: its kids are fields (named), not widgets.</summary>
    private static bool IsGroupNode(PdfDictionary d) =>
        PdfObj.Array(d.Elements["/Kids"]) is { } kids && !d.Elements.ContainsKey("/FT") && !d.Elements.ContainsKey("/Rect")
        && (kids.Elements.Count == 0 || kids.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Any(k => k.Elements.ContainsKey("/T")));

    /// <summary>Takes a field out of its parent's /Kids (or /Fields), then removes parents left empty.</summary>
    private static void Detach(PdfDocument doc, PdfDictionary acro, PdfDictionary node)
    {
        var guard = 0;
        while (guard++ < 64)
        {
            var parent = PdfObj.Dict(node.Elements["/Parent"]);
            var holder = parent is null ? PdfObj.Array(acro.Elements["/Fields"]) : PdfObj.Array(parent.Elements["/Kids"]);
            if (holder is not null)
                for (var i = holder.Elements.Count - 1; i >= 0; i--)
                    if (ReferenceEquals(PdfObj.Dict(holder.Elements[i]), node)) holder.Elements.RemoveAt(i);
            node.Elements.Remove("/Parent");
            if (parent is null || holder is null || holder.Elements.Count > 0 || parent.Elements.ContainsKey("/Rect")) return;
            node = parent; // an empty parent goes too
        }
    }

    /// <summary>Removes widget <paramref name="w"/> from field <paramref name="field"/>'s kids; a field left with none goes.</summary>
    private static void RemoveKid(PdfDocument doc, PdfDictionary acro, PdfDictionary field, PdfDictionary w)
    {
        if (PdfObj.Array(field.Elements["/Kids"]) is { } kids)
            for (var i = kids.Elements.Count - 1; i >= 0; i--)
                if (ReferenceEquals(PdfObj.Dict(kids.Elements[i]), w)) kids.Elements.RemoveAt(i);
        w.Elements.Remove("/Parent");
        if (PdfObj.Array(field.Elements["/Kids"]) is not { Elements.Count: > 0 })
        {
            Detach(doc, acro, field);
            RemoveFromCalculationOrder(acro, field);
        }
        else
        {
            // The value and default may have been the button that left: then they name no button of the group.
            var states = PdfObj.Array(field.Elements["/Kids"])!.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Select(FormEditor.OnStateOf).ToHashSet();
            if (PdfObj.Name(field.Elements["/DV"]) is { } dv && dv != "Off" && !states.Contains(dv)) field.Elements.Remove("/DV");
            if (PdfObj.Name(field.Elements["/V"]) is { } v && v != "Off" && !states.Contains(v)) field.Elements["/V"] = new PdfName("/Off");
        }
    }

    /// <summary>Refuses a radio button value another button of its group already stands for (they'd turn on together).</summary>
    private static void RequireFreeValue(PdfDictionary group, PdfDictionary w, DesignField spec)
    {
        if (ReferenceEquals(group, w) || PdfObj.Array(group.Elements["/Kids"]) is not { } kids) return;
        if (kids.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Any(k => !ReferenceEquals(k, w) && FormEditor.OnStateOf(k) == spec.ExportValue))
            throw new ArgumentException($"Another button of \"{spec.Name}\" already stands for \"{spec.ExportValue}\": give this one a value of its own.");
    }

    /// <summary>
    /// Whether two /DA strings mean the same: font, size and color (gray, RGB or CMYK compared as RGB). For check boxes
    /// and radio buttons only the color counts (their symbol's font and size are the face's business).
    /// </summary>
    internal static bool SameAppearance(string a, string b, bool colorOnly = false)
    {
        var x = DefaultAppearance.Parse(a);
        var y = DefaultAppearance.Parse(b);
        var (cx, cy) = (ToRgb(x.Color.C), ToRgb(y.Color.C));
        var sameColor = Math.Abs(cx.R - cy.R) < 0.005 && Math.Abs(cx.G - cy.G) < 0.005 && Math.Abs(cx.B - cy.B) < 0.005;
        return colorOnly ? sameColor : sameColor && x.FontName == y.FontName && Math.Abs(x.Size - y.Size) < 0.01;
    }

    private static void RemoveFromCalculationOrder(PdfDictionary acro, PdfDictionary field)
    {
        if (PdfObj.Array(acro.Elements["/CO"]) is not { } co) return;
        for (var i = co.Elements.Count - 1; i >= 0; i--)
            if (ReferenceEquals(PdfObj.Dict(co.Elements[i]), field)) co.Elements.RemoveAt(i);
    }

    /// <summary>Writes <paramref name="spec"/>'s properties into the field and the widget, then redraws what they change.</summary>
    /// <param name="joined">The widget (a radio button) just moved into <paramref name="field"/> from another group.</param>
    private static void Apply(PdfDocument doc, PdfDictionary acro, PdfDictionary field, PdfDictionary w, DesignField spec, bool isNew, bool joined = false)
    {
        var page = doc.Pages[spec.PageIndex];
        var oldRect = PdfObj.Array(w.Elements["/Rect"]) is { Elements.Count: >= 4 } r0 ? PdfObj.RectToPage(page, r0) : default;
        var (x1, y1, x2, y2) = TextStamps.FromPageSpace(page, spec.Rect);
        w.Elements["/Rect"] = PdfObj.Reals(doc, x1, y1, x2, y2);
        var resized = isNew || Math.Abs(oldRect.Width - spec.Rect.Width) > 0.01 || Math.Abs(oldRect.Height - spec.Rect.Height) > 0.01;

        // Field-wide: tooltip, flags, length, alignment, options, default.
        if (spec.Tooltip.Length > 0) field.Elements["/TU"] = PdfObj.MakeString(spec.Tooltip);
        else field.Elements.Remove("/TU");
        var flags = PdfObj.Int(FormEditor.Inherited(field, "/Ff")) ?? 0;
        flags = Set(flags, FfReadOnly, spec.ReadOnly);
        flags = Set(flags, FfRequired, spec.Required);
        switch (spec.Kind)
        {
            case DesignFieldKind.Text:
                flags = Set(flags, FfMultiline, spec.Multiline);
                break;
            case DesignFieldKind.ComboBox or DesignFieldKind.ListBox:
                flags = Set(flags, FfCombo, spec.Kind == DesignFieldKind.ComboBox);
                flags = Set(flags, FfEdit, spec.Kind == DesignFieldKind.ComboBox && spec.Editable);
                flags = Set(flags, FfMultiSelect, spec.Kind == DesignFieldKind.ListBox && spec.MultiSelect);
                break;
        }
        if (flags != 0 || field.Elements.ContainsKey("/Ff")) field.Elements["/Ff"] = new PdfInteger(flags);
        if (spec.Kind == DesignFieldKind.Text && spec.MaxLength > 0) field.Elements["/MaxLen"] = new PdfInteger(spec.MaxLength);
        else field.Elements.Remove("/MaxLen");
        if (spec.Kind is DesignFieldKind.Text or DesignFieldKind.ComboBox or DesignFieldKind.ListBox or DesignFieldKind.Button)
        {
            field.Elements["/Q"] = new PdfInteger(Math.Clamp(spec.Alignment, 0, 2));
            if (!ReferenceEquals(field, w)) w.Elements.Remove("/Q");
        }

        var colorsChanged = !isNew && (ColorOf(PdfObj.Dict(w.Elements["/MK"])?.Elements["/BC"]) != spec.BorderColor || ColorOf(PdfObj.Dict(w.Elements["/MK"])?.Elements["/BG"]) != spec.FillColor);
        var mk = PdfObj.Dict(w.Elements["/MK"]);
        if (mk is null)
        {
            mk = new PdfDictionary(doc);
            w.Elements["/MK"] = mk;
        }
        SetColor(doc, mk, "/BC", spec.BorderColor);
        SetColor(doc, mk, "/BG", spec.FillColor);
        if (spec.BorderColor is not null && PdfObj.Dict(w.Elements["/BS"]) is null && !w.Elements.ContainsKey("/Border"))
        {
            var bs = new PdfDictionary(doc);
            bs.Elements["/W"] = new PdfInteger(1);
            bs.Elements["/S"] = new PdfName("/S");
            w.Elements["/BS"] = bs;
        }

        // /DA: keep the font the field names, set its size and color.
        var oldDa = PdfObj.Str(w.Elements["/DA"]) ?? PdfObj.Str(FormEditor.Inherited(field, "/DA")) ?? PdfObj.Str(acro.Elements["/DA"]);
        var font = oldDa is null ? "/Helv" : DefaultAppearance.Parse(oldDa).FontName;
        if (PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(acro.Elements["/DR"])?.Elements["/Font"])?.Elements[font]) is null) font = "/Helv";
        var da = $"{font} {PdfObj.F(Math.Clamp(spec.FontSize, 0, 200))} Tf {Rgb(spec.TextColor)} rg";
        if (spec.Kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio) da = $"/ZaDb 0 Tf {Rgb(spec.TextColor)} rg";
        // Compared parsed: "0 g" and "0 0 0 rg" are the same black, and a field's own DA stays as written when it means the same.
        var daChanged = oldDa is null || !SameAppearance(oldDa, da, spec.Kind is DesignFieldKind.CheckBox or DesignFieldKind.Radio);
        if (daChanged || isNew)
        {
            field.Elements["/DA"] = new PdfString(da);
            if (!ReferenceEquals(field, w) && w.Elements.ContainsKey("/DA")) w.Elements["/DA"] = new PdfString(da);
        }

        var captionChanged = false;
        switch (spec.Kind)
        {
            case DesignFieldKind.Text:
                SetFormat(doc, field, w, spec);
                SetDefault(field, spec.DefaultValue.Length > 0 ? PdfObj.MakeString(spec.DefaultValue) : null, isNew);
                break;
            case DesignFieldKind.ComboBox or DesignFieldKind.ListBox:
            {
                var (exports, labels) = FormEditor.ReadOptions(FormEditor.Inherited(field, "/Opt"));
                var shown = spec.ShownOptions;
                var optionsChanged = isNew || !exports.SequenceEqual(spec.Options) || !labels.SequenceEqual(shown);
                if (optionsChanged)
                    field.Elements["/Opt"] = new PdfArray(doc, [.. spec.Options.Select((o, i) => shown[i].Length == 0 || shown[i] == o
                        ? (PdfItem)PdfObj.MakeString(o)
                        : new PdfArray(doc, PdfObj.MakeString(o), PdfObj.MakeString(shown[i])))]);
                var dv = spec.DefaultValue.Length > 0 && spec.Options.Contains(spec.DefaultValue) ? spec.DefaultValue : "";
                var changed = SetDefault(field, dv.Length > 0 ? PdfObj.MakeString(dv) : null, isNew);
                if (changed || optionsChanged)
                {
                    if (dv.Length > 0) field.Elements["/I"] = new PdfArray(doc, new PdfInteger(spec.Options.ToList().IndexOf(dv)));
                    else field.Elements.Remove("/I");
                }
                break;
            }
            case DesignFieldKind.Button:
                captionChanged = (PdfObj.Str(mk.Elements["/CA"]) ?? "") != spec.Caption;
                if (spec.Caption.Length > 0) mk.Elements["/CA"] = PdfObj.MakeString(spec.Caption);
                else mk.Elements.Remove("/CA");
                SetAction(doc, w, spec.Action);
                break;
        }

        // Appearances.
        switch (spec.Kind)
        {
            case DesignFieldKind.Text or DesignFieldKind.ComboBox or DesignFieldKind.ListBox or DesignFieldKind.Signature or DesignFieldKind.Button:
            {
                var fields = Fields(doc, acro);
                var f = fields.FirstOrDefault(x => ReferenceEquals(x.Dict, field));
                if (spec.Kind is DesignFieldKind.Text or DesignFieldKind.ComboBox or DesignFieldKind.ListBox && f is not null)
                    FormEditor.WriteAppearances(doc, acro, f);
                // A button with an icon (/MK /I) keeps its faces (normal, down, rollover): only its rect moves.
                else if ((isNew || resized || colorsChanged || daChanged || captionChanged) && PdfObj.Dict(mk.Elements["/I"]) is null)
                    StaticFace(doc, w, spec);
                break;
            }
            case DesignFieldKind.CheckBox or DesignFieldKind.Radio:
            {
                var oldState = FormEditor.OnStateOf(w);
                if (spec.Kind == DesignFieldKind.Radio && (isNew || joined || oldState != spec.ExportValue))
                    RequireFreeValue(field, w, spec);
                if (isNew || resized || colorsChanged || daChanged || oldState != spec.ExportValue)
                    ButtonFaces(doc, w, spec.Kind == DesignFieldKind.Radio, spec.ExportValue, spec.TextColor);
                SetButtonDefault(doc, field, w, spec, oldState, isNew);
                break;
            }
        }
    }

    private static int Set(int flags, int bit, bool on) => on ? flags | bit : flags & ~bit;

    private static string Rgb(AnnotColor c) => $"{PdfObj.F(c.R)} {PdfObj.F(c.G)} {PdfObj.F(c.B)}";

    private static void SetColor(PdfDocument doc, PdfDictionary mk, string key, AnnotColor? c)
    {
        if (c is { } v) mk.Elements[key] = PdfObj.Reals(doc, v.R, v.G, v.B);
        else mk.Elements.Remove(key);
    }

    /// <summary>Sets /DV, and /V along with it (a designer's default is what the form starts with). True if it changed.</summary>
    private static bool SetDefault(PdfDictionary field, PdfItem? value, bool isNew)
    {
        var old = PdfObj.Resolve(field.Elements["/DV"]);
        var same = (old, value) switch
        {
            (null, null) => true,
            (PdfString a, PdfString b) => a.Value == b.Value,
            (PdfName a, PdfName b) => a.Value == b.Value,
            _ => false,
        };
        if (same && !isNew) return false;
        if (value is null)
        {
            field.Elements.Remove("/DV");
            field.Elements.Remove("/V");
        }
        else
        {
            field.Elements["/DV"] = value;
            field.Elements["/V"] = value is PdfString s ? PdfObj.MakeString(s.Value) : new PdfName(((PdfName)value).Value);
        }
        field.Elements.Remove("/RV");
        return true;
    }

    /// <summary>Check box: on by default when the default is its export value. Radio: the group's default button.</summary>
    private static void SetButtonDefault(PdfDocument doc, PdfDictionary field, PdfDictionary w, DesignField spec, string? oldState, bool isNew)
    {
        var state = spec.ExportValue;
        // A renamed state carries the value along.
        if (oldState is not null && oldState != state)
            foreach (var key in new[] { "/V", "/DV" })
                if (PdfObj.Name(field.Elements[key]) == oldState) field.Elements[key] = new PdfName("/" + state);
        var dvName = spec.Kind == DesignFieldKind.CheckBox
            ? spec.DefaultValue.Length > 0 && spec.DefaultValue != "Off" ? state : null
            : spec.DefaultValue.Length > 0 && spec.DefaultValue != "Off" ? spec.DefaultValue : null;
        // A radio default must be the value of a button in the group (this one's new value included).
        if (dvName is not null && spec.Kind == DesignFieldKind.Radio && dvName != state && !ReferenceEquals(field, w)
            && !(PdfObj.Array(field.Elements["/Kids"])?.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Any(k => !ReferenceEquals(k, w) && FormEditor.OnStateOf(k) == dvName) ?? false))
            dvName = null;
        var oldDv = PdfObj.Name(field.Elements["/DV"]);
        if (isNew || oldDv != dvName)
        {
            if (dvName is null) field.Elements.Remove("/DV");
            else field.Elements["/DV"] = new PdfName("/" + dvName);
            field.Elements["/V"] = new PdfName("/" + (dvName ?? "Off"));
        }
        // Each widget shows the field's value.
        var value = PdfObj.Name(field.Elements["/V"]) ?? "Off";
        IEnumerable<PdfDictionary> widgets = PdfObj.Array(field.Elements["/Kids"]) is { } kids && !ReferenceEquals(field, w)
            ? kids.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()
            : [w];
        foreach (var k in widgets)
            k.Elements["/AS"] = new PdfName("/" + (FormEditor.OnStateOf(k) == value ? value : "Off"));
        _ = doc;
    }

    private static void SetFormat(PdfDocument doc, PdfDictionary field, PdfDictionary w, DesignField spec)
    {
        var aa = PdfObj.Dict(field.Elements["/AA"]);
        var current = FormScripts.ParseFormat(aa is null ? null : PdfObj.Text(PdfObj.Dict(aa.Elements["/F"])?.Elements["/JS"]));
        var custom = current is null && PdfObj.Dict(aa?.Elements["/F"]) is not null;
        if (custom || current == spec.Format) return; // a script of the form's own, or nothing to change
        if (PdfObj.Dict(PdfObj.Dict(w.Elements["/AA"])?.Elements["/F"]) is not null && !ReferenceEquals(field, w)) return;
        if (spec.Format is not { } fmt)
        {
            aa?.Elements.Remove("/F");
            aa?.Elements.Remove("/K");
            if (aa is { Elements.Count: 0 }) field.Elements.Remove("/AA");
            return;
        }
        if (aa is null)
        {
            aa = new PdfDictionary(doc);
            field.Elements["/AA"] = aa;
        }
        var (format, keystroke) = FormatScripts(fmt);
        aa.Elements["/F"] = JavaScript(doc, format);
        aa.Elements["/K"] = JavaScript(doc, keystroke);
    }

    private static PdfDictionary JavaScript(PdfDocument doc, string js)
    {
        var a = new PdfDictionary(doc);
        a.Elements["/S"] = new PdfName("/JavaScript");
        a.Elements["/JS"] = PdfObj.MakeString(js);
        return a;
    }

    /// <summary>The Acrobat format and keystroke scripts for <paramref name="f"/> (AFNumber_Format and its keystroke …).</summary>
    public static (string Format, string Keystroke) FormatScripts(FieldFormat f)
    {
        static string Q(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        var inv = CultureInfo.InvariantCulture;
        return f.Kind switch
        {
            FieldFormatKind.Number => (
                string.Create(inv, $"AFNumber_Format({f.Decimals}, {f.SeparatorStyle}, {f.NegativeStyle}, 0, {Q(f.Currency)}, {(f.CurrencyPrepend ? "true" : "false")});"),
                string.Create(inv, $"AFNumber_Keystroke({f.Decimals}, {f.SeparatorStyle}, {f.NegativeStyle}, 0, {Q(f.Currency)}, {(f.CurrencyPrepend ? "true" : "false")});")),
            FieldFormatKind.Percent => (
                string.Create(inv, $"AFPercent_Format({f.Decimals}, {f.SeparatorStyle});"),
                string.Create(inv, $"AFPercent_Keystroke({f.Decimals}, {f.SeparatorStyle});")),
            FieldFormatKind.Date => ($"AFDate_FormatEx({Q(f.DatePattern)});", $"AFDate_KeystrokeEx({Q(f.DatePattern)});"),
            _ => (string.Create(inv, $"AFSpecial_Format({f.Special});"), string.Create(inv, $"AFSpecial_Keystroke({f.Special});")),
        };
    }

    private static void SetAction(PdfDocument doc, PdfDictionary w, FieldButtonAction action)
    {
        if (action == FieldButtonAction.Other) return; // the form's own action stays
        if (action == FieldButtonAction.None)
        {
            w.Elements.Remove("/A");
            return;
        }
        var a = new PdfDictionary(doc);
        a.Elements["/Type"] = new PdfName("/Action");
        if (action == FieldButtonAction.ResetForm) a.Elements["/S"] = new PdfName("/ResetForm");
        else
        {
            a.Elements["/S"] = new PdfName("/Named");
            a.Elements["/N"] = new PdfName("/Print");
        }
        w.Elements["/A"] = a;
        // A push button highlights by pushing in (as Acrobat's default).
        w.Elements["/H"] = new PdfName("/P");
    }

    /// <summary>Push buttons and unsigned signature fields: background, border and caption, through the text field painter.</summary>
    private static void StaticFace(PdfDocument doc, PdfDictionary w, DesignField spec)
    {
        // Auto size: a caption sized like a label (at most 12 pt), not as tall as the button.
        var size = spec.FontSize > 0 ? spec.FontSize : Math.Clamp((Math.Min(spec.Rect.Width, spec.Rect.Height) - 6) * 0.7, 4, 12);
        var look = new FieldLook
        {
            Da = $"/Helv {PdfObj.F(size)} Tf {Rgb(spec.TextColor)} rg",
            Quadding = 1,
            Text = spec.Kind == DesignFieldKind.Button ? spec.Caption : "",
        };
        if (FieldAppearance.Build(doc, w, look) is not { } face) return;
        var ap = new PdfDictionary(doc);
        ap.Elements["/N"] = face.Reference!;
        w.Elements["/AP"] = ap;
    }

    /// <summary>
    /// A check box's or radio button's on and off faces (and pressed ones): background and border (a circle for radio
    /// buttons), and when on, the /MK /CA ZapfDingbats symbol (✔ for check boxes) or a dot for radio buttons.
    /// </summary>
    private static void ButtonFaces(PdfDocument doc, PdfDictionary w, bool radio, string state, AnnotColor mark)
    {
        if (PdfObj.Array(w.Elements["/Rect"]) is not { Elements.Count: >= 4 } r) return;
        var rw = Math.Abs(PdfObj.Num(r, 2) - PdfObj.Num(r, 0));
        var rh = Math.Abs(PdfObj.Num(r, 3) - PdfObj.Num(r, 1));
        if (rw <= 0 || rh <= 0) return;
        var mk = PdfObj.Dict(w.Elements["/MK"])!;
        var rot = (((PdfObj.Int(mk.Elements["/R"]) ?? 0) % 360) + 360) % 360;
        var (wd, ht) = rot is 90 or 270 ? (rh, rw) : (rw, rh);
        var bg = PdfColorValue.From(PdfObj.Array(mk.Elements["/BG"]));
        var bc = PdfColorValue.From(PdfObj.Array(mk.Elements["/BC"]));
        var bs = PdfObj.Dict(w.Elements["/BS"]);
        var bw = bs?.Elements.ContainsKey("/W") == true ? PdfObj.Num(bs.Elements["/W"], 1) : 1;
        var glyph = PdfObj.Str(mk.Elements["/CA"]) is { Length: 1 } ca ? ca[0] : radio ? 'l' : '4';
        if (!mk.Elements.ContainsKey("/CA")) mk.Elements["/CA"] = new PdfString(glyph.ToString());

        string Frame(bool down)
        {
            var sb = new StringBuilder();
            var cx = wd / 2;
            var cy = ht / 2;
            var rad = Math.Min(wd, ht) / 2;
            var fill = down ? new PdfColorValue([0.75]) : bg;
            if (radio)
            {
                if (fill is { } f) sb.Append($"q {f.Fill} {Circle(cx, cy, rad)} f Q\n");
                if (bc is { } b && bw > 0) sb.Append($"q {b.Stroke} {PdfObj.F(bw)} w {Circle(cx, cy, rad - bw / 2)} s Q\n");
            }
            else
            {
                if (fill is { } f) sb.Append($"q {f.Fill} 0 0 {PdfObj.F(wd)} {PdfObj.F(ht)} re f Q\n");
                if (bc is { } b && bw > 0) sb.Append($"q {b.Stroke} {PdfObj.F(bw)} w {PdfObj.F(bw / 2)} {PdfObj.F(bw / 2)} {PdfObj.F(wd - bw)} {PdfObj.F(ht - bw)} re S Q\n");
            }
            return sb.ToString();
        }

        string Mark()
        {
            var color = $"{Rgb(mark)} rg";
            var inner = Math.Min(wd, ht) - 2 * bw;
            if (radio && glyph == 'l')
                return $"q {color} {Circle(wd / 2, ht / 2, Math.Max(0.5, inner * 0.27))} f Q\n";
            var size = Math.Max(1, inner * 0.8);
            var advance = ZapfWidth(glyph) * size;
            var x = (wd - advance) / 2;
            var y = (ht - size * 0.7) / 2; // ZapfDingbats symbols stand about 0.7 em tall on the baseline
            return $"q BT {color} /ZaDb {PdfObj.F(size)} Tf {PdfObj.F(x)} {PdfObj.F(y)} Td ({WinAnsi.Literal(glyph.ToString())}) Tj ET Q\n";
        }

        PdfArray? Matrix() => rot switch
        {
            90 => new PdfArray(doc, new PdfInteger(0), new PdfInteger(1), new PdfInteger(-1), new PdfInteger(0), new PdfReal(rh), new PdfInteger(0)),
            180 => new PdfArray(doc, new PdfInteger(-1), new PdfInteger(0), new PdfInteger(0), new PdfInteger(-1), new PdfReal(rw), new PdfReal(rh)),
            270 => new PdfArray(doc, new PdfInteger(0), new PdfInteger(-1), new PdfInteger(1), new PdfInteger(0), new PdfInteger(0), new PdfReal(rw)),
            _ => null,
        };

        PdfDictionary Face(string content, bool withFont)
        {
            PdfDictionary? res = null;
            if (withFont)
            {
                var fonts = new PdfDictionary(doc);
                fonts.Elements["/ZaDb"] = FontResources.Standard(doc, "ZapfDingbats");
                res = new PdfDictionary(doc);
                res.Elements["/Font"] = fonts;
            }
            return PdfObj.FormXObject(doc, Encoding.Latin1.GetBytes(content), 0, 0, wd, ht, res, Matrix());
        }

        var usesFont = !(radio && glyph == 'l');
        PdfDictionary States(bool down)
        {
            var d = new PdfDictionary(doc);
            d.Elements["/" + state] = Face(Frame(down) + Mark(), usesFont).Reference!;
            d.Elements["/Off"] = Face(Frame(down), false).Reference!;
            return d;
        }
        var ap = new PdfDictionary(doc);
        ap.Elements["/N"] = States(false);
        ap.Elements["/D"] = States(true);
        w.Elements["/AP"] = ap;
        if (PdfObj.Name(w.Elements["/AS"]) is not { } shown || shown != state) w.Elements["/AS"] = new PdfName("/Off");
    }

    /// <summary>A circle path (four Bézier arcs) centered on (cx, cy).</summary>
    private static string Circle(double cx, double cy, double r)
    {
        const double k = 0.5523;
        string P(double x, double y) => $"{PdfObj.F(x)} {PdfObj.F(y)}";
        return $"{P(cx + r, cy)} m {P(cx + r, cy + r * k)} {P(cx + r * k, cy + r)} {P(cx, cy + r)} c "
             + $"{P(cx - r * k, cy + r)} {P(cx - r, cy + r * k)} {P(cx - r, cy)} c "
             + $"{P(cx - r, cy - r * k)} {P(cx - r * k, cy - r)} {P(cx, cy - r)} c "
             + $"{P(cx + r * k, cy - r)} {P(cx + r, cy - r * k)} {P(cx + r, cy)} c h";
    }

    /// <summary>Advance widths (em) of the ZapfDingbats symbols Acrobat offers for check boxes and radio buttons.</summary>
    private static double ZapfWidth(char c) => c switch
    {
        '4' => 0.846, // check
        '8' => 0.838, // cross
        'l' => 0.791, // circle
        'n' => 0.761, // square
        'u' => 0.759, // diamond
        'H' => 0.816, // star
        _ => 0.8,
    };
}
