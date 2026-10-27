using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>Where a merge's forms go and what they are called.</summary>
public sealed record FormMergeOptions
{
    public required string OutputFolder { get; init; }

    /// <summary>The file name of each form (without .pdf): Batch's tokens (&lt;&lt;name&gt;&gt; the form's name,
    /// &lt;&lt;n&gt;&gt; the row's number, &lt;&lt;n:3&gt;&gt; padded, &lt;&lt;date&gt;&gt;) and any column of the CSV
    /// (&lt;&lt;Last name&gt;&gt;: that row's value; Batch's tokens win over columns of the same name).</summary>
    public string NameTemplate { get; init; } = DefaultTemplate;

    /// <summary>A name that is taken gets a number ("form (2).pdf"); with false, files of the same name are replaced.</summary>
    public bool NeverOverwrite { get; init; } = true;

    /// <summary>The forms are flattened: values become part of the page and can't be changed.</summary>
    public bool Flatten { get; init; }

    /// <summary>For &lt;&lt;date&gt;&gt; in names.</summary>
    public DateTime Date { get; init; } = DateTime.Now;

    public const string DefaultTemplate = "<<name>> <<n:3>>";
}

/// <summary>A row of a merge.</summary>
/// <param name="Row">Its number among the data rows (from 1; the header isn't counted).</param>
/// <param name="File">The form made (null when the row failed).</param>
/// <param name="Problems">Why it failed: each value refused, with its field and why.</param>
public sealed record FormMergeRow(int Row, string? File, IReadOnlyList<string> Problems);

/// <param name="UnknownColumns">Columns no field of the form has (their values are left out).</param>
public sealed record FormMergeReport(int Rows, IReadOnlyList<FormMergeRow> Made, IReadOnlyList<FormMergeRow> Failed, IReadOnlyList<string> UnknownColumns, bool Stopped)
{
    /// <summary>"198 forms made, 2 rows failed."</summary>
    public string Text =>
        $"{FormDataFiles.Number(Made.Count)} form{(Made.Count == 1 ? "" : "s")} made" +
        (Failed.Count > 0 ? $", {FormDataFiles.Number(Failed.Count)} row{(Failed.Count == 1 ? "" : "s")} failed" : "") +
        (Stopped ? ", stopped before the end" : "") + ".";

    /// <summary>The report as CSV: a line per failed row (row, problems), then the unknown columns.</summary>
    public byte[] Csv()
    {
        var rows = new List<IReadOnlyList<string>> { new[] { "Row", "Result", "File", "Problems" } };
        foreach (var r in Made.Concat(Failed).OrderBy(r => r.Row))
            rows.Add([r.Row.ToString(System.Globalization.CultureInfo.InvariantCulture), r.File is null ? "Failed" : "Made", r.File ?? "", string.Join("\n", r.Problems)]);
        foreach (var c in UnknownColumns) rows.Add(["", "Column left out", "", $"\"{c}\" isn't a field of the form"]);
        return Core.Csv.Write(rows);
    }
}

/// <summary>
/// A merge (Forms › Fill Forms from CSV…, <c>inkvoltpdf --fill</c>): a CSV whose header names the form's fields and
/// whose every row fills one copy of the form, saved in a folder under a name made from a pattern (the row's number,
/// any column). Each row's values are checked against their fields and then run through the form's scripts; a row with
/// a value refused (not one of the choices, too long, required but empty, refused by a validate script) is not saved
/// and is reported with every problem it has. Columns that aren't fields are reported once and left out.
/// </summary>
public static partial class FormMerge
{
    [GeneratedRegex(@"<<\s*([^<>:]+?)\s*(?::([^<>]*))?>>", RegexOptions.CultureInvariant)]
    private static partial Regex Token();

    private static readonly HashSet<string> BatchTokens = new(["name", "n", "date", "folder"], StringComparer.OrdinalIgnoreCase);

    /// <summary>A name Batch's tokens use (name, n, date, folder): a column called so can't be put in a file name.</summary>
    public static bool IsBatchToken(string column) => BatchTokens.Contains(column.Trim());

    /// <summary>What is wrong with a name pattern for the given columns, or null.</summary>
    public static string? ValidateTemplate(string template, IEnumerable<string> columns)
    {
        if (BatchNames.Validate(template) is { } error) return error;
        var known = new HashSet<string>(columns, StringComparer.OrdinalIgnoreCase);
        foreach (Match m in Token().Matches(template))
        {
            var name = m.Groups[1].Value;
            if (!BatchTokens.Contains(name) && !known.Contains(name)) return $"<<{name}>> is neither a column of the CSV nor <<name>>, <<n>> or <<date>>.";
        }
        return null;
    }

    /// <summary>The columns of a CSV (its header), to offer them for the name pattern.</summary>
    /// <exception cref="InvalidDataException">The file can't be read as CSV.</exception>
    public static IReadOnlyList<string> Columns(byte[] csv) => FormDataFiles.ReadTable(csv).Header;

    /// <param name="formPath">The form's path (its name is &lt;&lt;name&gt;&gt;; it is never overwritten).</param>
    /// <param name="progress">Rows done so far, and how many there are.</param>
    /// <exception cref="InvalidDataException">The CSV can't be read, or the name pattern names a column it doesn't have.</exception>
    /// <exception cref="InvalidOperationException">The PDF has no fillable form.</exception>
    public static FormMergeReport Run(byte[] form, string? password, byte[] csv, string formPath, FormMergeOptions options,
        IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        var (header, rows) = FormDataFiles.ReadTable(csv);
        if (ValidateTemplate(options.NameTemplate, header) is { } templateError) throw new InvalidDataException(templateError);
        var fields = FormEditor.DataFields(form, password);
        if (fields.Count == 0) throw new InvalidOperationException("This PDF has no form fields with data.");
        var names = fields.Select(f => f.Name).ToHashSet(StringComparer.Ordinal);
        var unknown = header.Where(h => h.Length > 0 && !names.Contains(h)).ToList();
        var outputs = new OutputNames(!options.NeverOverwrite, [formPath]);

        var made = new List<FormMergeRow>();
        var failed = new List<FormMergeRow>();
        var stopped = false;
        for (var i = 0; i < rows.Count; i++)
        {
            if (cancel.IsCancellationRequested)
            {
                stopped = true;
                break;
            }
            var number = i + 1;
            var values = FormDataFiles.Row(header, rows[i]);
            foreach (var u in unknown) values.Remove(u);
            try
            {
                var (good, _, rejected) = FormDataFiles.Check(fields, values);
                var problems = rejected.Select(r => r.Message).ToList();
                byte[] filled = form;
                if (problems.Count == 0 && good.Count > 0)
                {
                    var result = FormEditor.Fill(form, password, good);
                    problems.AddRange(result.Rejected.Select(r => r.Message.Length > 0 ? $"{r.FieldName}: {r.Message}" : $"{r.FieldName}: refused by the form"));
                    filled = result.Data;
                }
                if (problems.Count > 0)
                {
                    failed.Add(new FormMergeRow(number, null, problems));
                    continue;
                }
                if (options.Flatten) filled = SignedEdits.Run(() => Flattener.Flatten(filled, password), allowRewrite: true).Data;
                var name = FileName(options.NameTemplate, header, rows[i], formPath, number, options.Date) + ".pdf";
                var path = outputs.Place(options.OutputFolder, name, temp => File.WriteAllBytes(temp, filled));
                made.Add(new FormMergeRow(number, path, []));
            }
            catch (Exception ex) when (ex is InvalidOperationException or IOException or UnauthorizedAccessException or ArgumentException)
            {
                failed.Add(new FormMergeRow(number, null, [ex.Message]));
            }
            finally
            {
                progress?.Report((number, rows.Count));
            }
        }
        return new FormMergeReport(rows.Count, made, failed, unknown, stopped);
    }

    /// <summary>A row's file name: its columns put in first, then Batch's tokens; made a valid Windows name.</summary>
    internal static string FileName(string template, List<string> header, List<string> row, string formPath, int number, DateTime date)
    {
        var withColumns = Token().Replace(template, m =>
        {
            var name = m.Groups[1].Value;
            if (BatchTokens.Contains(name)) return m.Value;
            var col = header.FindIndex(h => h.Equals(name, StringComparison.OrdinalIgnoreCase));
            var value = col >= 0 && col < row.Count ? row[col] : "";
            return value.Replace('<', '_').Replace('>', '_').Replace('\n', ' ').Replace('\r', ' ').Trim();
        });
        return BatchNames.Expand(withColumns, formPath, number, date);
    }
}
