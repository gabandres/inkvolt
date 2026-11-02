using System.Globalization;

namespace InkvoltPdf.Core;

/// <summary>What happened to one thing the search found.</summary>
public enum RedactionOutcome
{
    /// <summary>Taken out of the result.</summary>
    Removed,

    /// <summary>The person chose to keep it.</summary>
    Kept,

    /// <summary>Found again after applying: the file fails.</summary>
    StillThere,

    /// <summary>The file failed, so no result was saved.</summary>
    NotSaved,
}

/// <param name="Page">0-based.</param>
/// <param name="Masked">The value with too little left to tell what it was (<see cref="RedactionReport.Mask"/>).</param>
public sealed record RedactionRemoval(int Page, RedactionPattern Pattern, string Masked, RedactionOutcome Outcome)
{
    public string OutcomeText => RedactionReport.OutcomeText(Outcome);

    public string PatternName => RedactionPatterns.Name(Pattern);
}

/// <summary>What was done to one file. It holds no unmasked value at any point: it is built only from <see cref="RedactionReport.Mask"/>.</summary>
/// <param name="Failure">Why the file failed (no value in it), or null.</param>
public sealed record RedactionFileReport(string File, IReadOnlyList<RedactionRemoval> Removals, IReadOnlyList<RedactionLook> Looks, string? Failure)
{
    /// <summary>"Removed 4; 1 kept; look at pages 3 and 5 by hand."</summary>
    public string Summary
    {
        get
        {
            var parts = new List<string>();
            int Count(RedactionOutcome o) => Removals.Count(r => r.Outcome == o);
            if (Failure is not null) parts.Add(Failure);
            if (Count(RedactionOutcome.Removed) is > 0 and var removed) parts.Add($"{removed:N0} removed");
            if (Count(RedactionOutcome.Kept) is > 0 and var kept) parts.Add($"{kept:N0} kept");
            if (Count(RedactionOutcome.NotSaved) is > 0 and var unsaved) parts.Add($"{unsaved:N0} found, not saved");
            if (Removals.Count == 0 && Failure is null) parts.Add("nothing found");
            if (Looks.Count > 0) parts.Add($"look by hand at {RedactionReport.Pages(Looks.Select(l => l.Page))}");
            return string.Join("; ", parts);
        }
    }

    public RedactionFileReport WithoutResult(string failure) => this with
    {
        Failure = failure,
        Removals = [.. Removals.Select(r => r.Outcome == RedactionOutcome.Removed ? r with { Outcome = RedactionOutcome.NotSaved } : r)],
    };
}

/// <summary>
/// The removal report: per file the page, pattern and a masked value of each removal, and the pages to look at by hand.
/// A masked value keeps at most the last two digits of a long number: a Social Security number's last four are themselves
/// used to prove who someone is, and anything short (a date, a ZIP code, a name, an address) would be all but given away
/// by any part of it, or by its length, so those keep nothing. A phrase and a custom pattern never appear, only their kind.
/// </summary>
public sealed class RedactionReport(IReadOnlyList<RedactionFileReport> files)
{
    public IReadOnlyList<RedactionFileReport> Files { get; } = files;

    public bool HasFailures => Files.Any(f => f.Failure is not null);

    public bool HasLooks => Files.Any(f => f.Looks.Count > 0);

    public int Count(RedactionOutcome outcome) => Files.Sum(f => f.Removals.Count(r => r.Outcome == outcome));

    /// <summary>What is left of a value in a report.</summary>
    public static string Mask(RedactionPattern pattern, string value)
    {
        var digits = string.Concat(value.Where(char.IsAsciiDigit));
        var tail = digits.Length >= 9 ? digits[^2..] : "";
        return pattern switch
        {
            RedactionPattern.SocialSecurity when tail.Length > 0 => $"***-**-**{tail}",
            RedactionPattern.PaymentCard when tail.Length > 0 => $"**** **** **** **{tail}",
            RedactionPattern.Phone when tail.Length > 0 => $"***-***-**{tail}",
            RedactionPattern.Iban when tail.Length > 0 => $"**** **** **{tail}",
            RedactionPattern.Email => "***@***",
            RedactionPattern.Date => "**/**/****",
            RedactionPattern.IpAddress => "***.***",
            _ => "***",
        };
    }

    /// <summary>What a match looks like in a report.</summary>
    public static RedactionRemoval Row(RedactionMatch match, RedactionOutcome outcome) =>
        new(match.Page, match.Pattern, Mask(match.Pattern, match.Normalized), outcome);

    public static string OutcomeText(RedactionOutcome outcome) => outcome switch
    {
        RedactionOutcome.Removed => "Removed",
        RedactionOutcome.Kept => "Kept by you",
        RedactionOutcome.StillThere => "Still in the file",
        _ => "Found, file not saved",
    };

    /// <summary>"page 3", "pages 3, 5 and 8", "12 pages".</summary>
    public static string Pages(IEnumerable<int> pages)
    {
        var list = pages.Distinct().Order().Select(p => (p + 1).ToString(CultureInfo.CurrentCulture)).ToList();
        return list.Count switch
        {
            0 => "no pages",
            1 => $"page {list[0]}",
            <= 6 => $"pages {string.Join(", ", list.Take(list.Count - 1))} and {list[^1]}",
            _ => $"{list.Count:N0} pages",
        };
    }

    /// <summary>The report as CSV: one row per removal, per page to look at, and per file's result.</summary>
    public byte[] ToCsv()
    {
        var rows = new List<IReadOnlyList<string>> { new[] { "File", "Page", "What", "Masked value", "Result" } };
        foreach (var file in Files)
        {
            var name = Cell(file.File);
            rows.Add([name, "", "Result for this file", "", Cell(file.Failure is null ? "Checked: " + file.Summary : "Failed: " + file.Summary)]);
            foreach (var r in file.Removals) rows.Add([name, Number(r.Page), r.PatternName, Cell(r.Masked), r.OutcomeText]);
            foreach (var look in file.Looks) rows.Add([name, Number(look.Page), Cell(look.Text), "", "Look by hand"]);
        }
        return Csv.Write(rows);

        static string Number(int page) => (page + 1).ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// A cell that can't run as a spreadsheet formula, whatever a crafted file name holds: control characters go, and an
    /// apostrophe goes in front of one starting (after any spaces) with what starts a formula, wide forms included.
    /// </summary>
    internal static string Cell(string value)
    {
        var clean = string.Concat(value.Where(c => !char.IsControl(c) && char.GetUnicodeCategory(c) != UnicodeCategory.Format));
        var first = clean.TrimStart();
        return first.Length > 0 && first[0] is '=' or '+' or '-' or '@' or '|' or '%' or '＝' or '＋' or '－' or '＠' ? "'" + clean : clean;
    }
}
