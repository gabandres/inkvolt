using System.Globalization;
using System.Text;
using System.Text.Json;

namespace InkvoltPdf.Core;

public enum FormDataFormat { Xfdf, Fdf, Csv, Json }

/// <param name="Data">The filled document (the original bytes when nothing changed).</param>
/// <param name="Filled">Values that went in.</param>
/// <param name="Unknown">Names in the file that no field of the form has.</param>
/// <param name="Rejected">Values refused: not one of a field's choices, too long, read-only, or refused by the form's own scripts.</param>
/// <param name="Notes">Anything else (a CSV with more rows than the one used).</param>
public sealed record FormDataImport(byte[] Data, int Filled, IReadOnlyList<string> Unknown, IReadOnlyList<FieldRejection> Rejected, IReadOnlyList<string> Notes);

/// <summary>
/// Form data in and out (roadmap 1.4): a form's values exported as XFDF, FDF (what Acrobat reads and writes), CSV (a
/// header row of field names and a row of values) or JSON (<c>{"fields": {"name": "value", "list": ["a", "b"]}}</c>),
/// and imported from any of them. Every field type travels: text (several lines kept), check boxes and radio buttons
/// (their export value, "Off" when off), combo boxes and list boxes (several choices: an array in JSON, values in XFDF,
/// lines in a CSV cell). Imported values are checked against their fields first (<see cref="FormEditor.CheckValue"/>),
/// then filled through the form's own scripts (<see cref="FormEditor.Fill(byte[], string?, IReadOnlyDictionary{string, string})"/>),
/// which may refuse some too. Many rows of a CSV make many forms: <see cref="FormMerge"/>.
/// </summary>
public static class FormDataFiles
{
    /// <summary>Largest data file read.</summary>
    public const int MaxFileBytes = 16 * 1024 * 1024;

    public static string Extension(FormDataFormat format) => format switch
    {
        FormDataFormat.Xfdf => ".xfdf",
        FormDataFormat.Fdf => ".fdf",
        FormDataFormat.Json => ".json",
        _ => ".csv",
    };

    public static FormDataFormat? FormatOf(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".xfdf" or ".xml" => FormDataFormat.Xfdf,
        ".fdf" => FormDataFormat.Fdf,
        ".json" => FormDataFormat.Json,
        ".csv" or ".txt" => FormDataFormat.Csv,
        _ => null,
    };

    /// <exception cref="InvalidOperationException">The PDF has no fillable form.</exception>
    public static byte[] Export(byte[] data, string? password, FormDataFormat format, string? pdfFileName = null)
    {
        var fields = FormEditor.DataFields(data, password);
        if (fields.Count == 0) throw new InvalidOperationException("This PDF has no form fields with data.");
        switch (format)
        {
            case FormDataFormat.Csv:
                return Csv.Write([fields.Select(f => f.Name).ToList(), fields.Select(f => f.Value).ToList()]);
            case FormDataFormat.Json:
            {
                using var ms = new MemoryStream();
                using (var w = new Utf8JsonWriter(ms, new JsonWriterOptions { Indented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
                {
                    w.WriteStartObject();
                    w.WriteStartObject("fields");
                    foreach (var f in fields)
                    {
                        if (f.MultiSelect)
                        {
                            w.WriteStartArray(f.Name);
                            foreach (var v in f.Value.Split('\n', StringSplitOptions.RemoveEmptyEntries)) w.WriteStringValue(v);
                            w.WriteEndArray();
                        }
                        else w.WriteString(f.Name, f.Value);
                    }
                    w.WriteEndObject();
                    w.WriteEndObject();
                }
                return ms.ToArray();
            }
            default:
            {
                var entries = fields.Select(f => new FormData.Entry(f.Name,
                    f.MultiSelect ? f.Value.Split('\n', StringSplitOptions.RemoveEmptyEntries) : [f.Value],
                    f.Kind is FormFieldKind.CheckBox or FormFieldKind.Radio)).ToList();
                return format == FormDataFormat.Xfdf ? FormData.Xfdf(entries, pdfFileName) : FormData.Fdf(entries, pdfFileName);
            }
        }
    }

    /// <summary>Fills the form from a data file (XFDF, FDF, JSON or CSV, told apart by their content; a CSV's first row).</summary>
    /// <exception cref="InvalidDataException">The file isn't form data, is damaged, too big, or carries a DTD.</exception>
    /// <exception cref="InvalidOperationException">The PDF has no fillable form.</exception>
    public static FormDataImport Import(byte[] data, string? password, byte[] file, IFormActionHost? host = null)
    {
        var notes = new List<string>();
        Dictionary<string, string> values;
        if (Sniff(file) == FormDataFormat.Csv)
        {
            var (header, rows) = ReadTable(file);
            if (rows.Count == 0) throw new InvalidDataException("The CSV has field names but no row of values.");
            if (rows.Count > 1) notes.Add($"The file has {rows.Count:N0} rows of values: the first was filled in. Fill Forms from CSV makes a form for each row.");
            values = Row(header, rows[0]);
        }
        else values = ReadValues(file);
        return Fill(data, password, values, notes, host);
    }

    internal static FormDataImport Fill(byte[] data, string? password, IReadOnlyDictionary<string, string> values, List<string> notes, IFormActionHost? host = null)
    {
        var fields = FormEditor.DataFields(data, password);
        if (fields.Count == 0) throw new InvalidOperationException("This PDF has no form fields with data.");
        var (good, unknown, rejected) = Check(fields, values);
        if (good.Count == 0) return new FormDataImport(data, 0, unknown, rejected, notes);
        var result = FormEditor.Fill(data, password, good, host);
        rejected.AddRange(result.Rejected);
        var filled = good.Keys.Count(k => !result.Rejected.Any(r => r.FieldName == k));
        return new FormDataImport(result.Data, filled, unknown, rejected, notes);
    }

    /// <summary>The values that fit their fields, the names no field has, and the values refused (with why).</summary>
    internal static (Dictionary<string, string> Good, List<string> Unknown, List<FieldRejection> Rejected) Check(
        IReadOnlyList<FormDataField> fields, IReadOnlyDictionary<string, string> values)
    {
        var byName = fields.ToDictionary(f => f.Name, StringComparer.Ordinal);
        var good = new Dictionary<string, string>(StringComparer.Ordinal);
        var unknown = new List<string>();
        var rejected = new List<FieldRejection>();
        foreach (var (name, raw) in values)
        {
            if (!byName.TryGetValue(name, out var f))
            {
                unknown.Add(name);
                continue;
            }
            var (value, problem) = FormEditor.CheckValue(f, raw);
            if (problem is not null) rejected.Add(new FieldRejection(name, $"{name}: {problem}"));
            else if (value is not null) good[name] = value;
        }
        return (good, unknown, rejected);
    }

    /// <summary>Full field name → value (several values joined by '\n') from XFDF, FDF or JSON.</summary>
    /// <exception cref="InvalidDataException">The file isn't one of them, is damaged, too big, or carries a DTD.</exception>
    public static Dictionary<string, string> ReadValues(byte[] file)
    {
        if (file.Length == 0) throw new InvalidDataException("The file is empty.");
        if (file.Length > MaxFileBytes) throw new InvalidDataException($"The file is larger than {MaxFileBytes >> 20} MB, the most Inkvolt PDF reads as form data.");
        switch (Sniff(file))
        {
            case FormDataFormat.Json:
                return ReadJson(file);
            case FormDataFormat.Csv:
            {
                var (header, rows) = ReadTable(file);
                return rows.Count == 0 ? [] : Row(header, rows[0]);
            }
            default:
            {
                var head = Encoding.UTF8.GetString(file, 0, Math.Min(file.Length, 4096));
                if (head.Contains("<!DOCTYPE", StringComparison.OrdinalIgnoreCase) || head.Contains("<!ENTITY", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The file has a DTD (<!DOCTYPE>), which Inkvolt PDF doesn't read: it could make the file read other files or grow without end.");
                var parsed = FormData.Parse(file) ?? throw new InvalidDataException("The file isn't XFDF, FDF, JSON or CSV form data, or it is damaged.");
                return parsed.ToDictionary(kv => kv.Key, kv => string.Join('\n', kv.Value), StringComparer.Ordinal);
            }
        }
    }

    /// <summary>What a data file is, from its first bytes: XML is XFDF, %FDF is FDF, { or [ is JSON, anything else CSV.</summary>
    public static FormDataFormat Sniff(byte[] file)
    {
        var start = file.Length >= 3 && file[0] == 0xEF && file[1] == 0xBB && file[2] == 0xBF ? 3 : 0;
        while (start < file.Length && file[start] is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n') start++;
        if (start >= file.Length) return FormDataFormat.Csv;
        return file[start] switch
        {
            (byte)'<' => FormDataFormat.Xfdf,
            (byte)'{' or (byte)'[' => FormDataFormat.Json,
            _ => file.AsSpan(start).StartsWith("%FDF"u8) ? FormDataFormat.Fdf : FormDataFormat.Csv,
        };
    }

    private static Dictionary<string, string> ReadJson(byte[] file)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(file, new JsonDocumentOptions { MaxDepth = 64, CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        }
        catch (JsonException ex)
        {
            throw new InvalidDataException($"The JSON file can't be read: {ex.Message}", ex);
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("fields", out var f) && f.ValueKind == JsonValueKind.Object) root = f;
            if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException("The JSON file should hold an object of field names and values: {\"fields\": {\"name\": \"value\"}}.");
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            Walk(root, null);
            return result;

            void Walk(JsonElement obj, string? parent)
            {
                foreach (var p in obj.EnumerateObject())
                {
                    var name = parent is null ? p.Name : $"{parent}.{p.Name}";
                    switch (p.Value.ValueKind)
                    {
                        case JsonValueKind.Object:
                            Walk(p.Value, name);
                            break;
                        case JsonValueKind.Array:
                            result[name] = string.Join('\n', p.Value.EnumerateArray().Select(Scalar).OfType<string>());
                            break;
                        default:
                            if (Scalar(p.Value) is { } v) result[name] = v;
                            break;
                    }
                }
            }

            static string? Scalar(JsonElement e) => e.ValueKind switch
            {
                JsonValueKind.String => e.GetString(),
                JsonValueKind.Number => e.GetRawText(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => null,
            };
        }
    }

    /// <summary>A CSV's header (field names) and its rows of values.</summary>
    /// <exception cref="InvalidDataException">Too big, too many rows, empty, or a header that names a column twice.</exception>
    internal static (List<string> Header, List<List<string>> Rows) ReadTable(byte[] file)
    {
        if (file.Length > Csv.MaxBytes) throw new InvalidDataException($"The file is larger than {Csv.MaxBytes >> 20} MB.");
        var rows = Csv.Read(Csv.Decode(file));
        if (rows.Count == 0) throw new InvalidDataException("The CSV file is empty.");
        var header = rows[0].Select(h => h.Trim()).ToList();
        var twice = header.Where(h => h.Length > 0).GroupBy(h => h, StringComparer.Ordinal).FirstOrDefault(g => g.Count() > 1);
        if (twice is not null) throw new InvalidDataException($"The column \"{twice.Key}\" is in the CSV twice.");
        return (header, rows.Skip(1).ToList());
    }

    /// <summary>A row's values by column name (empty column names left out; missing cells are empty).</summary>
    internal static Dictionary<string, string> Row(List<string> header, List<string> row)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var i = 0; i < header.Count; i++)
            if (header[i].Length > 0) values[header[i]] = i < row.Count ? row[i] : "";
        return values;
    }

    internal static string Number(int n) => n.ToString("N0", CultureInfo.InvariantCulture);
}
