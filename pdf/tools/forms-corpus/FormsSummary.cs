using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.FormsCorpus;

/// <summary>The run's pass rate and its failures grouped by signature, each group with its smallest example.</summary>
public static class FormsSummary
{
    /// <summary>A failure's group: its kind, plus for exceptions the exception's signature and for value problems the
    /// field kind and format ("Text number").</summary>
    public static string Group(Failure f) => f.Kind switch
    {
        "read-exception" or "fill-exception" or "reopen-exception" or "harness-exception" or "crash" or "mupdf-cannot-read-saved" => $"{f.Kind}: {f.Detail}",
        "hang" or "field-not-found" or "pdfjs-cannot-read-filled" => f.Kind + (f.Kind == "field-not-found" ? " (" + Regex.Match(f.Detail, @"a (\w+) field").Groups[1].Value + ")" : ""),
        "value-rejected-by-script" => f.Kind,
        _ => $"{f.Kind}: {Regex.Match(f.Detail, @"^[\w]+(?: [\w:/\-,. ]*?)?(?=[:(]|$)").Value.Trim()}",
    };

    public static string Markdown(IReadOnlyList<FormReport> reports, Func<string, string?> pdfOf)
    {
        var sb = new StringBuilder();
        var run = reports.Where(r => r.Status != "skip").ToList();
        var passed = run.Count(r => r.Status == "pass");
        sb.AppendLine($"Forms run: {run.Count}; passed: {passed} ({(run.Count == 0 ? 0 : 100.0 * passed / run.Count):0.#}%); failed: {run.Count - passed}.");
        sb.AppendLine($"Fields (Inkvolt): {run.Sum(r => r.Fields)}; filled: {run.Sum(r => r.Filled)}; pdf.js lists: {run.Where(r => r.PdfJsFields >= 0).Sum(r => r.PdfJsFields)}.");
        foreach (var g in reports.Where(r => r.Status == "skip").GroupBy(r => r.Skip))
            sb.AppendLine($"Skipped, {g.Key}: {g.Count()} ({string.Join(", ", g.Select(r => r.Name).Take(8))}{(g.Count() > 8 ? ", …" : "")})");
        var calcNotes = run.Count(r => r.Notes.Any(n => n.StartsWith("calc-not-updated", StringComparison.Ordinal)));
        var calcForms = run.Count(r => r.Notes.Any(n => n.StartsWith("calculated fields", StringComparison.Ordinal)));
        sb.AppendLine($"Calculated fields: {calcForms} forms have them; in {calcNotes} none changed after filling (note only).");
        sb.AppendLine();
        sb.AppendLine("| Group | Forms | Failures | Smallest example (form · field · detail) |");
        sb.AppendLine("|---|---:|---:|---|");
        var groups = run.SelectMany(r => r.Failures.Select(f => (Report: r, Failure: f, Group: Group(f))))
            .GroupBy(x => x.Group)
            .OrderByDescending(g => g.Select(x => x.Report.Name).Distinct().Count()).ThenBy(g => g.Key);
        foreach (var g in groups)
        {
            var forms = g.Select(x => x.Report.Name).Distinct().ToList();
            var smallest = g.OrderBy(x => Size(pdfOf(x.Report.Name))).ThenBy(x => x.Report.Fields).First();
            sb.AppendLine($"| {Cell(g.Key)} | {forms.Count} | {g.Count()} | {Cell(smallest.Report.Name)} · `{Cell(smallest.Failure.Field)}` · {Cell(smallest.Failure.Detail)} |");
        }
        sb.AppendLine();
        sb.AppendLine("Forms per group:");
        foreach (var g in groups)
            sb.AppendLine($"- {g.Key}: {string.Join(", ", g.Select(x => x.Report.Name).Distinct().Order())}");
        return sb.ToString();
    }

    /// <summary>The failure groups of each failing form: what baseline.json holds.</summary>
    public static SortedDictionary<string, List<string>> Baseline(IEnumerable<FormReport> reports) =>
        new(reports.Where(r => r.Status == "fail").ToDictionary(r => r.Name, r => r.Failures.Select(Group).Distinct().Order().ToList()), StringComparer.Ordinal);

    /// <summary>
    /// What got worse than the baseline: a form that fails with a group it didn't have (a form that passed and now
    /// fails included). Forms that fail less, or were skipped, aren't regressions.
    /// </summary>
    public static List<string> Regressions(IEnumerable<FormReport> reports, IReadOnlyDictionary<string, List<string>> baseline)
    {
        var found = new List<string>();
        foreach (var r in reports.Where(r => r.Status == "fail"))
        {
            var known = baseline.TryGetValue(r.Name, out var groups) ? groups : [];
            foreach (var f in r.Failures.Where(f => !known.Contains(Group(f))).GroupBy(Group))
                found.Add($"{r.Name}: {g(f.Key)} ({f.Count()}x, e.g. {f.First().Field}: {f.First().Detail})");
        }
        return found;

        static string g(string s) => s.Length > 140 ? s[..140] + "…" : s;
    }

    private static long Size(string? path) => path is not null && File.Exists(path) ? new FileInfo(path).Length : long.MaxValue;

    private static string Cell(string s) => s.Replace("|", "\\|").Replace("\n", " ");
}
