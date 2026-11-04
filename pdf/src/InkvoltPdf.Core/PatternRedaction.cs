using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>Who chose a Redact Patterns run's hits, which decides what verifies it and what fails it.</summary>
public enum PatternRedactionMode
{
    /// <summary>
    /// A person chose each hit (Review › Redact by Pattern). The read-back reads again by recognition only the redacted
    /// pages left without text (the text layer just laid back holds what the recognizer reads there); the check is the full
    /// one, knowing what was kept, the areas and the document before; only leftovers of what was removed fail the run. The
    /// check's other findings (covers and hidden layers the file came with) are for the person to fix.
    /// </summary>
    Reviewed,

    /// <summary>
    /// Nobody chose (Batch): every hit goes. The recognizer reads every redacted page again; a hit still there ends the run
    /// there. The check looks only for the values removed (by this run and the file's earlier ones) and for what the patterns
    /// read outside the pages, and anything it finds fails the file: nobody is there to judge a finding. The full check is
    /// the plan's own Check Redaction action.
    /// </summary>
    Unattended,
}

/// <summary>Whether a run's redaction holds, the first reason it doesn't when it doesn't.</summary>
public enum PatternRedactionVerdict
{
    Passed,

    /// <summary>Read back, a hit that was removed is still on its page (<see cref="PatternRedactionOutcome.StillThere"/>).</summary>
    StillThere,

    /// <summary>The check found what was removed elsewhere in the file (unattended: found anything).</summary>
    LeftInFile,

    /// <summary>The check couldn't look for everything (<see cref="RedactionCheckReport.Notes"/> say why): it isn't clean.</summary>
    Incomplete,
}

/// <param name="Report">The removal report: each accepted hit removed, each skipped one kept, each found again still there; with the search's pages to look at by hand. No failure in it: the caller says it in its words.</param>
/// <param name="Check">The redaction check; null when the run ended at the read-back (unattended).</param>
public sealed record PatternRedactionOutcome(PatternRedactionVerdict Verdict, RedactionFileReport Report, IReadOnlyList<RedactionMatch> StillThere,
    RedactionCheckReport? Check, RedactionCheckOptions CheckOptions);

/// <summary>
/// One Redact Patterns run after its hits were chosen: the accepted hits' areas (and any marked by hand) blacked out with the
/// redacted pages' text recognized again (<see cref="Redact"/>, run as one edit the caller's way), then the result read back
/// and searched again, the redaction check, its verdict and the removal report (<see cref="Verify"/>). The review dialog
/// and Batch only choose the hits; what checks them is <see cref="PatternRedactionMode"/>'s.
/// </summary>
/// <param name="file">The file's name in the report.</param>
/// <param name="found">The search the hits come from (its pages to look at by hand go in the report).</param>
/// <param name="ocr">The recognizer of the search: reads the redacted pages into text and back. Null: no text layer, and the
/// read-back doesn't look past the pages' text.</param>
public sealed class PatternRedaction(string file, RedactionPatternOptions patterns, RedactionSearchResult found,
    IReadOnlyList<RedactionMatch> accepted, IReadOnlyList<RedactionMatch> skipped, PatternRedactionMode mode, ITextRecognizer? ocr)
{
    private IReadOnlyDictionary<int, IReadOnlyList<RectD>>? _areas;

    public IReadOnlyList<RedactionMatch> Accepted => accepted;

    public IReadOnlyList<RedactionMatch> Skipped => skipped;

    /// <summary>Areas redacted with the hits that no pattern found (marked by hand, a page looked at by hand), page space.</summary>
    public IReadOnlyList<(int Page, RectD Rect)> Marked { get; init; } = [];

    /// <summary>What <see cref="Verify"/>'s read-back found again (kept when the check after it stops), else none.</summary>
    public IReadOnlyList<RedactionMatch> StillThere { get; private set; } = [];

    /// <summary>Values removed from the file before this run (an earlier Redact Patterns action of a batch): looked for again.</summary>
    public IReadOnlyList<string> EarlierValues { get; init; } = [];

    /// <summary>What is blacked out, per page: each accepted hit's boxes (<see cref="RedactionSearch.Areas"/>) and <see cref="Marked"/>.</summary>
    public IReadOnlyDictionary<int, IReadOnlyList<RectD>> Areas => _areas ??= RedactionSearch.Areas(accepted)
        .Select(kv => (kv.Key, Rects: kv.Value.AsEnumerable()))
        .Concat(Marked.GroupBy(m => m.Page).Select(g => (g.Key, Rects: g.Select(m => m.Rect))))
        .GroupBy(x => x.Key)
        .ToDictionary(g => g.Key, g => (IReadOnlyList<RectD>)[.. g.SelectMany(x => x.Rects).Distinct()]);

    /// <summary>The edit: <see cref="Areas"/> blacked out, the redacted pages' text recognized again (<see cref="Redaction.ApplyWithText"/>).</summary>
    public RedactedData Redact(byte[] data, string? password, IProgress<(int Done, int Total)>? progress = null, CancellationToken skipText = default) =>
        Redaction.ApplyWithText(data, password, Areas, ocr, progress, skipText);

    /// <summary>What the check is told (see <see cref="PatternRedactionMode"/>).</summary>
    /// <param name="before">The document before the redaction.</param>
    public RedactionCheckOptions CheckOptions(byte[]? before)
    {
        var kept = RedactionSearch.Values(skipped);
        var keptKeys = new HashSet<string>(kept, StringComparer.OrdinalIgnoreCase);
        var removed = RedactionSearch.SoughtValues(accepted).Where(v => !keptKeys.Contains(v));
        return mode == PatternRedactionMode.Reviewed
            ? new RedactionCheckOptions { Values = [.. removed], Kept = kept, Areas = Areas, Original = before, Patterns = patterns }
            : new RedactionCheckOptions { Values = [.. EarlierValues, .. removed], Kept = kept, Patterns = patterns, ValuesOnly = true };
    }

    /// <summary>The removal report (<paramref name="stillThere"/> added as still there).</summary>
    public RedactionFileReport Report(IEnumerable<RedactionMatch>? stillThere = null) => new(file,
        [
            .. accepted.Select(h => RedactionReport.Row(h, RedactionOutcome.Removed)),
            .. skipped.Select(h => RedactionReport.Row(h, RedactionOutcome.Kept)),
            .. (stillThere ?? []).Select(h => RedactionReport.Row(h, RedactionOutcome.StillThere)),
        ], found.Looks, null);

    /// <summary>
    /// Reads <paramref name="redacted"/> (<see cref="Redact"/>'s result) back and searches it again, then runs the redaction
    /// check, on the calling thread. Nothing redacted (no areas): only the check. Skipped hits found again don't count: they
    /// were kept.
    /// </summary>
    /// <param name="before">The document before the redaction (the check's <see cref="RedactionCheckOptions.Original"/>).</param>
    /// <param name="readBack">(pages searched, pages) of the read-back.</param>
    /// <param name="checking">Called as the check starts.</param>
    /// <exception cref="TimeoutException">A pattern took too long.</exception>
    /// <exception cref="TooManyHitsException">The read-back found more than can be listed.</exception>
    public PatternRedactionOutcome Verify(byte[] redacted, string? password, byte[]? before, IProgress<(int Done, int Total)>? readBack = null,
        Action? checking = null, CancellationToken cancel = default)
    {
        List<RedactionMatch> still = [];
        if (Areas.Count > 0)
        {
            var reread = mode == PatternRedactionMode.Reviewed ? WithoutText(redacted, password, Areas.Keys) : Areas.Keys.ToHashSet();
            still = RedactionSearch.ReadBack(redacted, password, patterns, ocr, reread, skipped, readBack, cancel);
        }
        StillThere = still;
        var options = CheckOptions(before);
        if (still.Count > 0 && mode == PatternRedactionMode.Unattended)
            return new PatternRedactionOutcome(PatternRedactionVerdict.StillThere, Report(still), still, null, options);

        checking?.Invoke();
        var check = RedactionCheck.Run(redacted, password, options, null, cancel);
        var left = mode == PatternRedactionMode.Reviewed ? check.Findings.Any(f => RedactionCheck.IsLeftover(f.Kind)) : !check.IsClean;
        var verdict = still.Count > 0 ? PatternRedactionVerdict.StillThere
            : left ? PatternRedactionVerdict.LeftInFile
            : check.Incomplete ? PatternRedactionVerdict.Incomplete
            : PatternRedactionVerdict.Passed;
        return new PatternRedactionOutcome(verdict, Report(still), still, check, options);
    }

    /// <summary>The pages of <paramref name="pages"/> without any text (none recognized, or reading it was skipped).</summary>
    private static HashSet<int> WithoutText(byte[] data, string? password, IEnumerable<int> pages)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
        return [.. pages.Where(p => p < engine.PageCount && !TextLayer.HasText(engine, p))];
    }
}
