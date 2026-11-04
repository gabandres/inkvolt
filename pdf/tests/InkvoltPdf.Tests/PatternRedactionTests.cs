using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// One Redact Patterns run after its hits were chosen (<see cref="PatternRedaction"/>), as the review dialog (reviewed) and
/// Batch (unattended) run it: the redaction with the redacted pages' text back, the read-back, the check and its verdict.
/// </summary>
public sealed class PatternRedactionTests : IDisposable
{
    private const string Font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>";
    private static readonly RedactionPatternOptions Ssn = new() { Patterns = new HashSet<RedactionPattern> { RedactionPattern.SocialSecurity } };
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-pattern-run-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    /// <summary>A text page with two numbers on it, and a second page drawing <paramref name="second"/>; <paramref name="title"/> the file's.</summary>
    private static byte[] TwoNumbers(string second = "BT /F1 14 Tf 72 700 Td (Nothing to find) Tj ET", string title = "Untitled") => Core2Pdf.Build(
    [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 7 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        Core2Pdf.Stream("BT /F1 14 Tf 72 700 Td (First 111-22-3333 here) Tj ET\nBT /F1 14 Tf 72 640 Td (Second 444-55-6666 there) Tj ET"),
        Font,
        $"<< /Title ({title}) >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 8 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        Core2Pdf.Stream(second),
    ], "/Info 6 0 R");

    private static RedactionSearchResult Find(byte[] data, RedactionPatternOptions options, ITextRecognizer? ocr = null)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        return RedactionSearch.Find(engine, options, ocr);
    }

    private static string Text(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return engine.GetText(0).Text;
    }

    private static (PatternRedactionOutcome Outcome, byte[] Result) Run(byte[] data, PatternRedactionMode mode, ITextRecognizer? ocr = null,
        RedactionPatternOptions? options = null, Func<RedactionMatch, bool>? accept = null)
    {
        options ??= Ssn;
        var found = Find(data, options, ocr);
        accept ??= _ => true;
        var run = new PatternRedaction("file.pdf", options, found, [.. found.Hits.Where(accept)], [.. found.Hits.Where(h => !accept(h))], mode, ocr);
        var result = run.Redact(data, null).Data;
        return (run.Verify(result, null, data), result);
    }

    [Fact]
    public void ReviewedASkippedHitIsKeptAndNeitherLookedForNorFoundAgain()
    {
        var data = TwoNumbers();
        var (outcome, result) = Run(data, PatternRedactionMode.Reviewed, accept: h => h.Normalized == "111-22-3333");

        Assert.Equal(PatternRedactionVerdict.Passed, outcome.Verdict);
        Assert.Equal([RedactionOutcome.Removed, RedactionOutcome.Kept], outcome.Report.Removals.Select(r => r.Outcome));
        Assert.Null(outcome.Report.Failure);
        // The check knows what was kept, the areas and the file before (the full check).
        Assert.Contains("444-55-6666", outcome.CheckOptions.Kept);
        Assert.DoesNotContain("444-55-6666", outcome.CheckOptions.Values);
        Assert.Contains("111-22-3333", outcome.CheckOptions.Values);
        Assert.NotNull(outcome.CheckOptions.Areas);
        Assert.Same(data, outcome.CheckOptions.Original);
        Assert.False(outcome.CheckOptions.ValuesOnly);
        Assert.DoesNotContain("111-22-3333", Text(result));
    }

    [Fact]
    public void UnattendedLooksForWhatThisRunAndEarlierOnesRemovedOnly()
    {
        var data = TwoNumbers();
        var found = Find(data, Ssn);
        var run = new PatternRedaction("file.pdf", Ssn, found, found.Hits, [], PatternRedactionMode.Unattended, null) { EarlierValues = ["Earlier value"] };
        var options = run.CheckOptions(data);
        Assert.True(options.ValuesOnly);
        Assert.Equal(["Earlier value", "111-22-3333", "444-55-6666"], options.Values.Distinct()); // each as it reads and as written
        Assert.Null(options.Areas);
    }

    [Fact]
    public void TheDriftCaseARedactedScanKeepsItsTextInBothModes()
    {
        foreach (var mode in new[] { PatternRedactionMode.Reviewed, PatternRedactionMode.Unattended })
        {
            var reader = new PlantedReader();
            var scan = RedactionCorpusTests.OneScan(reader, out _);
            var (outcome, result) = Run(scan, mode, reader);
            Assert.True(outcome.Verdict == PatternRedactionVerdict.Passed, $"{mode}: {outcome.Verdict} {outcome.Check?.Summary}");
            var text = Text(result);
            Assert.Contains("heading", text); // searchable again
            Assert.DoesNotContain("111-22-3333", text);
            Assert.Equal(RedactionOutcome.Removed, Assert.Single(outcome.Report.Removals).Outcome);
            Assert.Equal(RedactionLookReason.ScanReadByOcr, Assert.Single(outcome.Report.Looks).Reason);
        }
    }

    [Fact]
    public async Task TheDriftCaseBatchRedactedScansStaySearchable()
    {
        var reader = new PlantedReader();
        var path = Path.Combine(_root, "scan.pdf");
        File.WriteAllBytes(path, RedactionCorpusTests.OneScan(reader, out _));
        var plan = new BatchPlan { Steps = [new RedactPatternsStep(Ssn)], OutputFolder = Path.Combine(_root, "out") };
        var summary = await BatchRunner.RunAsync([new BatchFile(path)], plan, new BatchHost { Ocr = new PageRecognizer(reader) }, null, default);
        var item = Assert.Single(summary.Items);
        Assert.True(item.State == BatchItemState.Done, $"{item.State}: {item.Message}");
        var output = File.ReadAllBytes(item.Outputs.Single());
        var text = Text(output);
        Assert.Contains("A heading that reads well", text);
        Assert.DoesNotContain("111-22-3333", text);
        Assert.Equal("en-US", TextLayer.Words(output, null)[0].Language);
    }

    /// <summary>Reads the value wherever it is handed a picture, as if no black box were there.</summary>
    private sealed class ReadsItAnyway : ITextRecognizer
    {
        public string Language => "en-US";

        public string LanguageName => "English";

        public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default) =>
            [new("111-22-3333", width * 0.2, height * 0.4, width * 0.3, height * 0.02, 0)];
    }

    [Fact]
    public void AHitStillThereFailsBothUnattendedStoppingThere()
    {
        var reader = new PlantedReader();
        var scan = RedactionCorpusTests.OneScan(reader, out _);
        var unattended = Run(scan, PatternRedactionMode.Unattended, new ReadsItAnyway()).Outcome;
        Assert.Equal(PatternRedactionVerdict.StillThere, unattended.Verdict);
        Assert.NotEmpty(unattended.StillThere);
        Assert.Null(unattended.Check);
        Assert.Contains(unattended.Report.Removals, r => r.Outcome == RedactionOutcome.StillThere);

        var reviewed = Run(scan, PatternRedactionMode.Reviewed, new ReadsItAnyway()).Outcome;
        Assert.Equal(PatternRedactionVerdict.StillThere, reviewed.Verdict);
        Assert.NotNull(reviewed.Check); // the person sees the rest of the check too
    }

    [Fact]
    public void WhatWasRemovedLeftElsewhereInTheFileFailsBoth()
    {
        var data = TwoNumbers(title: "Case 111-22-3333");
        foreach (var mode in new[] { PatternRedactionMode.Reviewed, PatternRedactionMode.Unattended })
        {
            var outcome = Run(data, mode).Outcome;
            Assert.True(outcome.Verdict == PatternRedactionVerdict.LeftInFile, $"{mode}: {outcome.Verdict}");
            Assert.Contains(outcome.Check!.Findings, f => f.Kind == RedactionLeak.Metadata);
        }
    }

    [Fact]
    public void ACoverTheFileCameWithIsForThePersonNotAFailure()
    {
        // Text under a black box elsewhere on the page: the full check finds it, the person's to fix; Batch's check doesn't look.
        var data = TwoNumbers("BT /F1 14 Tf 72 500 Td (Covered words under a box) Tj ET 0 0 0 rg 66 490 260 26 re f");
        var reviewed = Run(data, PatternRedactionMode.Reviewed, accept: h => h.Normalized == "111-22-3333").Outcome;
        Assert.Equal(PatternRedactionVerdict.Passed, reviewed.Verdict);
        Assert.Contains(reviewed.Check!.Findings, f => !RedactionCheck.IsLeftover(f.Kind));

        var unattended = Run(data, PatternRedactionMode.Unattended).Outcome;
        Assert.Equal(PatternRedactionVerdict.Passed, unattended.Verdict);
        Assert.True(unattended.Check!.IsClean);
    }
}
