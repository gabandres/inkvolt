using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>A form field as form data sees it (export, import, merge): one per field name.</summary>
/// <param name="Value">Its value as exported: a check box or radio's export value ("Off" when off), a multi-select
/// list's choices joined by '\n'.</param>
/// <param name="Options">Choice fields: the export values; check boxes and radios: their on states and export values.</param>
/// <param name="Labels">Choice fields: the display texts.</param>
public sealed record FormDataField(string Name, FormFieldKind Kind, string Value, IReadOnlyList<string> Options, IReadOnlyList<string> Labels,
    int MaxLength, bool Required, bool ReadOnly, bool MultiSelect, bool Editable);

public static partial class FormEditor
{
    /// <summary>The fields that hold data (not push buttons or signatures), in the form's order, each name once.</summary>
    public static IReadOnlyList<FormDataField> DataFields(byte[] data, string? password)
    {
        using var doc = Open(data, password, PdfDocumentOpenMode.Import);
        var acro = PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"]);
        var fields = new List<Field>();
        Collect(doc, acro, fields);
        var result = new List<FormDataField>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var f in fields)
        {
            if (f.Type is not ("/Tx" or "/Ch" or "/Btn") || f.Type == "/Btn" && (f.Flags & FfPushButton) != 0 || !seen.Add(f.Name)) continue;
            var kind = f.Type switch
            {
                "/Tx" => FormFieldKind.Text,
                "/Ch" => FormFieldKind.Choice,
                _ when (f.Flags & FfRadio) != 0 => FormFieldKind.Radio,
                _ => FormFieldKind.CheckBox,
            };
            List<string> options, labels = [];
            if (kind == FormFieldKind.Choice) (options, labels) = ReadOptions(Inherited(f.Dict, "/Opt"));
            else if (kind == FormFieldKind.Text) options = [];
            else options = [.. f.Widgets.Select(OnStateOf).OfType<string>().Concat(ButtonOptions(f) ?? []).Distinct()];
            result.Add(new FormDataField(f.Name, kind, ExportValueOf(f), options, labels,
                PdfObj.Int(Inherited(f.Dict, "/MaxLen")) ?? 0,
                (f.Flags & FfRequired) != 0,
                (f.Flags & FfReadOnly) != 0,
                kind == FormFieldKind.Choice && (f.Flags & FfMultiSelect) != 0,
                kind == FormFieldKind.Choice && (f.Flags & FfEdit) != 0));
        }
        return result;
    }

    /// <summary>
    /// A value from a data file checked against its field, before it is filled in: the value to set (a check box's
    /// TRUE, Yes, 1 or X become its on state; FALSE, No, 0 "Off"), or why it can't go in (not one of the choices, too
    /// long, empty for a required field, read-only).
    /// </summary>
    public static (string? Value, string? Problem) CheckValue(FormDataField f, string value)
    {
        value = value.Replace("\r\n", "\n");
        if (f.ReadOnly) return value == f.Value ? (null, null) : (null, "it is read-only");
        if (f.Required && value.Trim().Length == 0 && f.Kind is not (FormFieldKind.CheckBox or FormFieldKind.Radio)) return (null, "it is required, and the value is empty");
        switch (f.Kind)
        {
            case FormFieldKind.Text:
                return f.MaxLength > 0 && value.Length > f.MaxLength ? (null, $"it takes at most {f.MaxLength} characters ({value.Length} given)") : (value, null);
            case FormFieldKind.Choice:
            {
                var parts = f.MultiSelect ? value.Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList() : value.Length == 0 ? [] : [value];
                if (!f.MultiSelect && parts.Count == 0) return ("", null);
                if (f.Editable) return (value, null);
                foreach (var p in parts)
                    if (!f.Options.Contains(p) && !f.Labels.Contains(p))
                        return (null, $"\"{Short(p)}\" isn't one of its choices ({string.Join(", ", f.Options.Take(8).Select(o => Short(o)))}{(f.Options.Count > 8 ? ", …" : "")})");
                return (value, null);
            }
            default:
            {
                var trimmed = value.Trim();
                if (trimmed.Length == 0 || trimmed is "Off" or "off" or "OFF") return ("Off", null);
                if (f.Options.FirstOrDefault(o => o.Equals(trimmed, StringComparison.Ordinal)) is { } exact) return (exact, null);
                if (f.Options.FirstOrDefault(o => o.Equals(trimmed, StringComparison.OrdinalIgnoreCase)) is { } loose) return (loose, null);
                var on = f.Options.FirstOrDefault();
                if (f.Kind == FormFieldKind.CheckBox && on is not null)
                {
                    if (trimmed.ToLowerInvariant() is "true" or "yes" or "1" or "x" or "on" or "checked") return (on, null);
                    if (trimmed.ToLowerInvariant() is "false" or "no" or "0" or "unchecked") return ("Off", null);
                }
                return (null, $"\"{Short(trimmed)}\" isn't one of its states ({string.Join(", ", f.Options.Append("Off"))})");
            }
        }

        static string Short(string s) => s.Length <= 40 ? s : s[..40] + "…";
    }
}
