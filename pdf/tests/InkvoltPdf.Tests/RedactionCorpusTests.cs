using System.Diagnostics;
using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 1.1's test: the corpus finds 100% and leaves 0 after applying; what OCR can't read is never reported clean.</summary>
public sealed class RedactionCorpusTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-redact-corpus-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private static string Plain(string s) => string.Concat(s.Where(c => !char.IsWhiteSpace(c) && c != '-'));

    private static void FindsAll(IReadOnlyList<RedactionMatch> hits)
    {
        var missing = RedactionCorpus.Values
            .Where(v => !hits.Any(h => h.Page == v.Page && h.Pattern == v.Kind && Plain(h.Normalized) == Plain(v.Value)))
            .Select(v => $"page {v.Page + 1}: {v.Kind} {v.Value}").ToList();
        Assert.True(missing.Count == 0, "Not found: " + string.Join("; ", missing) + "\nFound: " +
                                        string.Join("; ", hits.Select(h => $"{h.Page + 1}:{h.Pattern}:{h.Normalized}")));
    }

    private static byte[] ApplyAndReadBack(byte[] data, string? password, PlantedReader reader, out RedactionSearchResult found, out List<RedactionMatch> left)
    {
        using (var engine = PdfEngine.Open(data, InputFileTypes.PDF, password))
            found = RedactionSearch.Find(engine, RedactionCorpus.Search, reader);
        FindsAll(found.Hits);
        var areas = RedactionSearch.Areas(found.Hits);
        var result = Redaction.Apply(data, password, areas);
        left = RedactionSearch.ReadBack(result, password, RedactionCorpus.Search, reader, areas.Keys.ToHashSet(), []);
        return result;
    }

    [Fact]
    public void FindsEveryPlantedValueAndLeavesNoneAfterApplying()
    {
        var data = RedactionCorpus.Make(out var reader);
        var result = ApplyAndReadBack(data, null, reader, out var found, out var left);
        Assert.True(left.Count == 0, "Still there: " + string.Join("; ", left.Select(h => $"{h.Page + 1}:{h.Pattern}:{h.Normalized}")));

        // Nothing of any planted value is in the pages' text or the file, and each hit's place is black.
        using var engine = PdfEngine.Open(result, InputFileTypes.PDF, null);
        for (var p = 0; p < engine.PageCount; p++)
        {
            var text = Plain(engine.GetText(p).Text);
            foreach (var v in RedactionCorpus.Values) Assert.DoesNotContain(Plain(v.Value), text);
        }
        var report = RedactionCheck.Run(result, null, new RedactionCheckOptions { Values = RedactionSearch.Values(found.Hits), Patterns = RedactionCorpus.Search, ValuesOnly = true });
        Assert.True(report.IsClean, report.Summary);
        Assert.False(report.Incomplete);
        foreach (var hit in found.Hits)
            foreach (var r in hit.Rects)
                Assert.True(Core2Pdf.Ink(result, hit.Page, r.Inflate(-1)) > 0.9, $"page {hit.Page + 1} {hit.Pattern} blacked out");
    }

    [Fact]
    public void TheEncryptedCopyTooAndItStaysEncrypted()
    {
        var plain = RedactionCorpus.Make(out var reader);
        var data = RedactionCorpus.Encrypted(plain);
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(data, InputFileTypes.PDF, null));
        var result = KeptProtection.Run(RedactionCorpus.Password, false, () => ApplyAndReadBack(data, RedactionCorpus.Password, reader, out _, out var left) is var r && left.Count == 0 ? r : throw new InvalidOperationException("left"));
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(result, InputFileTypes.PDF, null));
    }

    [Fact]
    public async Task BatchFindsAllLeavesNoneReportsMaskedAndKeepsThePassword()
    {
        var plain = RedactionCorpus.Make(out var reader);
        var (a, b) = (Path.Combine(_root, "plain.pdf"), Path.Combine(_root, "locked.pdf"));
        File.WriteAllBytes(a, plain);
        File.WriteAllBytes(b, RedactionCorpus.Encrypted(plain));
        var plan = new BatchPlan { Steps = [new RedactPatternsStep(RedactionCorpus.Search)], OutputFolder = Path.Combine(_root, "out") };
        var asked = new List<string>();
        var host = new BatchHost
        {
            Recognizer = reader,
            AskPassword = (request, _) =>
            {
                asked.Add(Path.GetFileName(request.File.Path));
                return Task.FromResult<string?>(RedactionCorpus.Password);
            },
        };
        var summary = await BatchRunner.RunAsync([new BatchFile(a), new BatchFile(b)], plan, host, null, default);
        Assert.All(summary.Items, i => Assert.True(i.State == BatchItemState.Done, $"{i.File.Path}: {i.State}: {i.Message}"));
        Assert.Equal(["locked.pdf"], asked);

        using (var engine = PdfEngine.Open(File.ReadAllBytes(summary.Items[0].Outputs.Single()), InputFileTypes.PDF, null))
            for (var p = 0; p < engine.PageCount; p++)
                foreach (var v in RedactionCorpus.Values)
                    Assert.DoesNotContain(Plain(v.Value), Plain(engine.GetText(p).Text));
        var locked = File.ReadAllBytes(summary.Items[1].Outputs.Single());
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(locked, InputFileTypes.PDF, null));

        // The report: per file, page, pattern, masked value; every scan listed to look at; no value anywhere in it.
        Assert.NotNull(summary.RedactionReportPath);
        var csv = File.ReadAllText(summary.RedactionReportPath!, Encoding.UTF8);
        foreach (var v in RedactionCorpus.Values)
        {
            Assert.DoesNotContain(v.Value, csv);
            Assert.DoesNotContain(Plain(v.Value), Plain(csv));
        }
        var rows = Csv.Read(csv);
        Assert.Equal(["File", "Page", "What", "Masked value", "Result"], rows[0]);
        Assert.Contains(rows, r => r[0].EndsWith("plain.pdf", StringComparison.Ordinal) && r[1] == "1" && r[2] == "US Social Security numbers" && r[3] == "***-**-**89" && r[4] == "Removed");
        Assert.Contains(rows, r => r[0].EndsWith("locked.pdf", StringComparison.Ordinal) && r[1] == "1" && r[2] == "US Social Security numbers" && r[4] == "Removed");
        foreach (var page in RedactionCorpus.ScanPages)
            Assert.Contains(rows, r => r[0].EndsWith("plain.pdf", StringComparison.Ordinal) && r[1] == (page + 1).ToString() && r[4] == "Look by hand");
        Assert.DoesNotContain(summary.Items[0].Notes, n => n.Contains("clean", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(summary.Items[0].Notes, n => n.StartsWith("Look by hand at", StringComparison.Ordinal));
    }

    // ───────────── what OCR can't read ─────────────

    private static byte[] OneScan(PlantedReader reader, out RectD dropped)
    {
        var source = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 14 Tf 72 700 Td (A heading that reads well) Tj ET\nBT /F1 14 Tf 72 640 Td (SSN 111-22-3333 on this line) Tj ET\nBT /F1 14 Tf 72 580 Td (A closing line of words) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]);
        using var engine = PdfEngine.Open(source, InputFileTypes.PDF, null);
        var image = engine.Render(0, 150.0 / 72);
        var gray = InkvoltPrint.Core.Imaging.ScanCleanup.ToGray(image.Pixels, image.Width, image.Height);
        var text = engine.GetText(0);
        reader.Plant(612, 792, text);
        var (s, e) = text.Find("111-22-3333", true, false).Single();
        dropped = text.GetRects(s, e).Single();
        return RedactionCorpus.ImagePdf(gray, image.Width, image.Height, 612, 792);
    }

    [Fact]
    public void AValueOcrCantReadIsFlaggedNeverPassedAsClean()
    {
        var reader = new PlantedReader();
        var scan = OneScan(reader, out var value);
        foreach (var word in new[] { "SSN", "111-22-3333", "on", "this", "line" }) reader.Dropped.Add(word);
        using var engine = PdfEngine.Open(scan, InputFileTypes.PDF, null);
        var found = RedactionSearch.Find(engine, new RedactionPatternOptions(), reader);

        Assert.Empty(found.Hits); // OCR can't see it, so the search can't either
        var look = Assert.Single(found.Looks);
        Assert.Equal(RedactionLookReason.ScanReadByOcr, look.Reason);
        Assert.Contains("read by text recognition", look.Text);
        Assert.Contains(look.Unread, u => !u.Intersect(value).IsEmpty); // and the place it is in is named
        Assert.True(reader.PlacesRead > 0); // after trying that place on its own
    }

    [Fact]
    public void AScanOcrReadsWellIsStillAPageToLookAt()
    {
        var reader = new PlantedReader();
        var scan = OneScan(reader, out _);
        using var engine = PdfEngine.Open(scan, InputFileTypes.PDF, null);
        var found = RedactionSearch.Find(engine, new RedactionPatternOptions(), reader);
        Assert.Equal(["111-22-3333"], found.Hits.Select(h => h.Normalized));
        Assert.True(found.Hits[0].FromOcr);
        Assert.Equal(RedactionLookReason.ScanReadByOcr, Assert.Single(found.Looks).Reason);
    }

    [Fact]
    public void ALineDroppedOnTheWholePageComesBackWhenItsPlaceIsReadAlone()
    {
        var reader = new PlantedReader { ReadsPlacesAlone = true };
        var scan = OneScan(reader, out var value);
        reader.Dropped.Add("111-22-3333");
        using var engine = PdfEngine.Open(scan, InputFileTypes.PDF, null);
        var found = RedactionSearch.Find(engine, new RedactionPatternOptions(), reader);
        Assert.Equal(["111-22-3333"], found.Hits.Select(h => h.Normalized));
        Assert.Contains(found.Hits[0].Rects, r => !r.Intersect(value).IsEmpty);
    }

    [Fact]
    public void AScanWithoutARecognizerIsNotSearchedAndSaysSo()
    {
        var reader = new PlantedReader();
        var scan = OneScan(reader, out _);
        using var engine = PdfEngine.Open(scan, InputFileTypes.PDF, null);
        var found = RedactionSearch.Find(engine, new RedactionPatternOptions());
        Assert.Empty(found.Hits);
        Assert.Equal([0], found.UnreadScans);
    }

    private sealed class BrokenReader : InkvoltPrint.Core.Imaging.ITextRecognizer
    {
        public string Language => "en-US";

        public string LanguageName => "English";

        public IReadOnlyList<InkvoltPrint.Core.Imaging.RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default) =>
            throw new System.Runtime.InteropServices.COMException("the engine gave up");
    }

    [Fact]
    public void ARecognizerThatFailsLeavesTheScanNotReadNotClean()
    {
        var scan = OneScan(new PlantedReader(), out _);
        using var engine = PdfEngine.Open(scan, InputFileTypes.PDF, null);
        var found = RedactionSearch.Find(engine, new RedactionPatternOptions(), new BrokenReader());
        Assert.Equal([0], found.UnreadScans);
    }

    [Fact]
    public void AVeryFaintScanIsntTakenForABlankPage()
    {
        var w = 200;
        var h = 260;
        var faint = Enumerable.Repeat((byte)240, w * h).ToArray();
        using var engine = PdfEngine.Open(RedactionCorpus.ImagePdf(faint, w, h, 612, 792), InputFileTypes.PDF, null);
        Assert.Equal([0], RedactionSearch.Find(engine, new RedactionPatternOptions()).UnreadScans);
    }

    [Fact]
    public void ABlankPageNeedsNoLook()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ]);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        Assert.Empty(RedactionSearch.Find(engine, new RedactionPatternOptions()).Looks);
    }

    [Fact]
    public void KeepingAHundredThousandHitsDoesntStallTheReadBack()
    {
        var lines = Enumerable.Range(0, 200).Select(l => string.Join(' ', Enumerable.Repeat("555-201-3434", 40)));
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 6000 4000] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream(string.Concat(lines.Select((l, i) => $"BT /F1 9 Tf 10 {3900 - i * 12} Td ({l}) Tj ET\n"))),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var clock = Stopwatch.StartNew();
        var hits = RedactionSearch.Find(engine, new RedactionPatternOptions()).Hits;
        Assert.Equal(8000, hits.Count);
        Assert.Empty(RedactionSearch.ReadBack(pdf, null, new RedactionPatternOptions(), null, new HashSet<int>(), hits));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(60), $"took {clock.Elapsed}");
    }

    [Fact]
    public async Task BatchFailsAFileWithAScanItCantRead()
    {
        var reader = new PlantedReader();
        var path = Path.Combine(_root, "scan.pdf");
        File.WriteAllBytes(path, OneScan(reader, out _));
        var plan = new BatchPlan { Steps = [new RedactPatternsStep(new RedactionPatternOptions())], OutputFolder = Path.Combine(_root, "out") };
        var summary = await BatchRunner.RunAsync([new BatchFile(path)], plan, new BatchHost(), null, default);
        var item = Assert.Single(summary.Items);
        Assert.Equal(BatchItemState.Failed, item.State);
        Assert.Contains("is a scan", item.Message);
        Assert.Empty(item.Outputs);
    }

    [Fact]
    public async Task BatchFailsAFileWhenAHitIsStillThereAfterApplying()
    {
        // A recognizer that reads the value wherever it was read before, as if the black box had missed it.
        var inner = new PlantedReader();
        var path = Path.Combine(_root, "scan.pdf");
        File.WriteAllBytes(path, OneScan(inner, out _));
        var plan = new BatchPlan { Steps = [new RedactPatternsStep(new RedactionPatternOptions())], OutputFolder = Path.Combine(_root, "out") };
        var summary = await BatchRunner.RunAsync([new BatchFile(path)], plan, new BatchHost { Recognizer = new AlwaysReads() }, null, default);
        var item = Assert.Single(summary.Items);
        Assert.Equal(BatchItemState.Failed, item.State);
        Assert.Contains("still there", item.Message);
        Assert.Empty(item.Outputs);
        Assert.Contains(item.Redaction!.Removals, r => r.Outcome == RedactionOutcome.StillThere);
        Assert.DoesNotContain(item.Redaction.Removals, r => r.Outcome == RedactionOutcome.Removed);
        Assert.DoesNotContain("111-22-3333", File.ReadAllText(summary.RedactionReportPath!));
    }

    private sealed class AlwaysReads : InkvoltPrint.Core.Imaging.ITextRecognizer
    {
        public string Language => "en-US";

        public string LanguageName => "English";

        public IReadOnlyList<InkvoltPrint.Core.Imaging.RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default) =>
            [new("111-22-3333", width * 0.2, height * 0.4, width * 0.3, height * 0.02, 0)];
    }

    [Fact]
    public async Task ASignedFileIsntExportedUnredacted()
    {
        var signed = Path.Combine(_root, "signed.pdf");
        File.WriteAllBytes(signed, Core2SignatureTests.Signed());
        var plan = new BatchPlan { Steps = [new RedactPatternsStep(new RedactionPatternOptions()), new ExportStep(BatchExportFormat.Text)], OutputFolder = Path.Combine(_root, "out") };
        var summary = await BatchRunner.RunAsync([new BatchFile(signed)], plan, new BatchHost(), null, default);
        var item = Assert.Single(summary.Items);
        Assert.Equal(BatchItemState.Skipped, item.State);
        Assert.Empty(item.Outputs);
    }

    [Fact]
    public void AnExportBeforeRedactionIsRefused()
    {
        var plan = new BatchPlan { Steps = [new ExportStep(BatchExportFormat.Text), new RedactPatternsStep(new RedactionPatternOptions())], OutputFolder = Path.Combine(_root, "out") };
        Assert.Contains("before exports", plan.Validate(false));
    }

    /// <summary>Opt-in: INKVOLTPDF_REDACT_CORPUS names a folder to write the corpus into, for driving the real app over it.</summary>
    [Fact]
    public void WritesTheCorpusWhenAsked()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_REDACT_CORPUS") is { Length: > 0 } folder) RedactionCorpus.Save(folder);
    }

    // ───────────── an ordinary file ─────────────

    [Fact]
    public void AnOrdinaryTextPageWithRulesIsntFlaggedOrRecognized()
    {
        var page = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 12 Tf 72 700 Td (Plain words in a plain line of text) Tj ET\n1 w 72 690 m 540 690 l S\n72 600 468 80 re S\nBT /F1 12 Tf 80 640 Td (Inside a ruled box) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]);
        using var engine = PdfEngine.Open(page, InputFileTypes.PDF, null);
        var found = RedactionSearch.Find(engine, new RedactionPatternOptions(), new CountingReader());
        Assert.Empty(found.Looks);
    }

    private sealed class CountingReader : InkvoltPrint.Core.Imaging.ITextRecognizer
    {
        public string Language => "en-US";

        public string LanguageName => "English";

        public IReadOnlyList<InkvoltPrint.Core.Imaging.RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default) =>
            throw new InvalidOperationException("A plain text page shouldn't be recognized.");
    }

    [Fact]
    public void TextDrawnAsShapesCountsAsInkNothingRead()
    {
        // Blocks a person reads as a word, no text in the file (a font turned into shapes).
        var shapes = new StringBuilder();
        for (var i = 0; i < 14; i++) shapes.Append($"{72 + i * 9} 700 6 10 re f\n");
        var page = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 12 Tf 72 650 Td (Some real text too) Tj ET\n" + shapes),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]);
        using var engine = PdfEngine.Open(page, InputFileTypes.PDF, null);
        var found = RedactionSearch.Find(engine, new RedactionPatternOptions());
        var look = Assert.Single(found.Looks);
        Assert.Equal(RedactionLookReason.PicturesNotRead, look.Reason);
        Assert.Single(look.Unread);
    }

    // ───────────── how recognition's slips read ─────────────

    private static PageText Words(params string[] words)
    {
        var list = words.Select((w, i) => new OcrWord(w, new RectD(50 + i * 80, 100, 70, 12))).ToList();
        return RedactionSearch.OcrPageText(list);
    }

    [Theory]
    [InlineData(RedactionPattern.SocialSecurity, "l23-45-6789")] // l for 1
    [InlineData(RedactionPattern.SocialSecurity, "123 - 45 - 6789")] // spaces round the dashes
    [InlineData(RedactionPattern.PaymentCard, "4111 1lll 1111 1111")]
    [InlineData(RedactionPattern.PaymentCard, "4111 1111 1111 1112")] // one digit misread: the check digit fails, it still counts
    [InlineData(RedactionPattern.Email, "jane.doe @ example.com")]
    public void SlipsOfARecognizerStillCount(RedactionPattern kind, string read)
    {
        var options = new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern> { kind } };
        Assert.Single(RedactionPatterns.FindOnPage(Words(read.Split(' ')), 0, options, null, lenient: true));
        Assert.Empty(RedactionPatterns.FindOnPage(Words(read.Split(' ')), 0, options, null)); // a page's own text isn't read so kindly
    }

    [Fact]
    public void AHitOnARecognizedWordCoversTheWholeWord()
    {
        // "SSN:111-22-3333," read as one word: its place within the word isn't known, so all of it goes.
        var text = RedactionSearch.OcrPageText([new OcrWord("SSN:111-22-3333,", new RectD(100, 100, 120, 12))]);
        var hit = Assert.Single(RedactionPatterns.FindOnPage(text, 0, new RedactionPatternOptions(), null, lenient: true));
        Assert.Equal(100, hit.Rects[0].X, 3);
        Assert.Equal(220, hit.Rects[0].Right, 3);
    }

    [Fact]
    public void WordsAtAnAngleStayOnTheirLine()
    {
        // A sideways line: each word further down the page.
        var words = new[] { "SSN", "111-22-3333", "here" }.Select((w, i) => new OcrWord(w, new RectD(300 - 35, 100 + i * 80 + 30, 70, 12), 90)).ToList();
        Assert.Equal("SSN 111-22-3333 here", RedactionSearch.OcrPageText(words).Text);
    }

    // ───────────── attacks ─────────────

    private static PageText Lines(params string[] lines) =>
        new([.. lines.Select((line, l) => line.Select((c, i) => (c.ToString(), new RectD(10 + 6 * i, 20 + 14 * l, 6, 12))).ToList())]);

    [Fact]
    public void HugeHitCountsStopRatherThanGrindAndNothingIsPartial()
    {
        // 200,000 phone numbers on one page: finding them mustn't be quadratic, and the search says it stopped.
        var line = string.Join(' ', Enumerable.Repeat("555-201-3434", 200_000));
        var clock = Stopwatch.StartNew();
        Assert.Throws<TooManyHitsException>(() => RedactionPatterns.Find(Lines(line), 0, new RedactionPatternOptions()));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(60), $"took {clock.Elapsed}");
    }

    [Fact]
    public void ManyHitsUnderTheLimitAreFastEnough()
    {
        var line = string.Join(' ', Enumerable.Repeat("555-201-3434", 20_000));
        var clock = Stopwatch.StartNew();
        Assert.Equal(20_000, RedactionPatterns.Find(Lines(line), 0, new RedactionPatternOptions()).Count);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(30), $"took {clock.Elapsed}");
    }

    [Fact]
    public void AnExpressionThatKeepsJustUnderItsTimeoutCantRunForever()
    {
        var saved = RedactionPatterns.PageBudget;
        RedactionPatterns.PageBudget = TimeSpan.FromSeconds(1);
        try
        {
            // Each match costs real time (under the timeout per call), so only the page's budget stops it.
            var text = Lines(string.Join(' ', Enumerable.Repeat(new string('x', 21) + "! xxy", 400)));
            var options = new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>(), Expression = @"(x+x+)+y" };
            var clock = Stopwatch.StartNew();
            Assert.Throws<TimeoutException>(() => RedactionPatterns.Find(text, 0, options));
            Assert.True(clock.Elapsed < TimeSpan.FromSeconds(60), $"took {clock.Elapsed}");
        }
        finally
        {
            RedactionPatterns.PageBudget = saved;
        }
    }

    [Theory]
    [InlineData(@"(a{1000}){1000}{1000}")]
    [InlineData(@"((a+)+)+$")]
    [InlineData(@"(\w+\s?)*$")]
    [InlineData(@"(?<=(a+)+)b")]
    public void CatastrophicExpressionsEndInAnErrorNotAHang(string expression)
    {
        var options = new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>(), Expression = expression };
        var clock = Stopwatch.StartNew();
        try
        {
            RedactionPatterns.Find(Lines(new string('a', 5000) + "!"), 0, options);
        }
        catch (Exception ex) when (ex is TimeoutException or ArgumentException)
        {
            // told, and nothing passes as clean
        }
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(60), $"took {clock.Elapsed}");
    }

    [Theory]
    [InlineData("123​-45-6789")] // zero-width space
    [InlineData("123-45­-6789")] // soft hyphen
    [InlineData("１２３-４５-６７８９")] // wide digits
    [InlineData("123-45‮-6789")] // bidirectional override
    public void InvisibleAndWideCharactersDontHideANumber(string text)
    {
        var hits = RedactionPatterns.Find(Lines($"SSN {text} here"), 0, new RedactionPatternOptions());
        Assert.Single(hits);
    }

    [Fact]
    public void ADashStartingTheNextLineKeepsTheNumberWhole()
    {
        var hits = RedactionPatterns.Find(Lines("SSN 123-45", "-6789 here"), 0, new RedactionPatternOptions());
        Assert.Equal("123-45-6789", Assert.Single(hits).Normalized);
    }

    [Fact]
    public void TextWithoutABoxStillTakesItsPage()
    {
        var empty = new RectD(10, 10, 0, 0);
        var text = new PageText([[.. "123-45-6789".Select(c => (c.ToString(), empty))]]);
        var hit = Assert.Single(RedactionPatterns.Find(text, 0, new RedactionPatternOptions()));
        Assert.False(hit.Rects[0].IsEmpty);
    }

    [Fact]
    public void HostileContextIsMadeHarmlessToShow()
    {
        var hit = Assert.Single(RedactionPatterns.Find(Lines("‮evil\u0007 text 123-45-6789 ‭more\u0001 words"), 0, new RedactionPatternOptions()));
        Assert.Equal("evil text ", hit.Before);
        Assert.Equal(" more words", hit.After);
    }

    [Fact]
    public void AHiddenPageTextOverAPictureDoesntVouchForIt()
    {
        // Invisible text boxes a whole page tall can't vouch for the ink under them.
        var data = RedactionCorpus.Make(out var reader);
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var layered = RedactionSearch.Find(engine, new RedactionPatternOptions { Pages = [8] }, reader);
        Assert.Contains(layered.Hits, h => h.Normalized == "321-54-9876");
    }

    [Fact]
    public void PatternsFindWhatNoPageShows()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Annots [6 0 R] /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 12 Tf 72 700 Td (Nothing private on this page) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Call 555-201-3434 or mail hidden@example.org) >>",
        ]);
        var report = RedactionCheck.Run(pdf, null, new RedactionCheckOptions { Patterns = new RedactionPatternOptions(), ValuesOnly = true });
        Assert.False(report.IsClean);
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.Annotation);
    }

    [Fact]
    public void WhatThePersonKeptIsntReportedLeft()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 12 Tf 72 700 Td (Mail kept@example.org today) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]);
        var kept = new[] { "kept@example.org" };
        Assert.False(RedactionCheck.Run(pdf, null, new RedactionCheckOptions { Values = kept, ValuesOnly = true }).IsClean);
        Assert.True(RedactionCheck.Run(pdf, null, new RedactionCheckOptions { Values = kept, Kept = kept, ValuesOnly = true }).IsClean);

        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var hits = RedactionSearch.Find(engine, new RedactionPatternOptions()).Hits;
        Assert.Single(hits);
        Assert.Single(RedactionSearch.ReadBack(pdf, null, new RedactionPatternOptions(), null, new HashSet<int>(), []));
        Assert.Empty(RedactionSearch.ReadBack(pdf, null, new RedactionPatternOptions(), null, new HashSet<int>(), hits));
    }

    [Fact]
    public void ManyValuesAreLookedForOrTheCheckSaysItCouldnt()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 12 Tf 72 700 Td (A plain value here) Tj ET\n"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]);
        var values = Enumerable.Range(1000, 800).Select(i => $"value-number-{i}-{new string('x', 150)}").ToList();
        var report = RedactionCheck.Run(pdf, null, new RedactionCheckOptions { Values = values, ValuesOnly = true });
        Assert.True(report.Incomplete);
        Assert.Contains(report.Notes, n => n.Contains("first 500"));

        // A few hundred numbers are more than one search can hold (the check used to stop with an error): each is still found.
        var numbers = Enumerable.Range(0, 400).Select(i => $"{100 + i}-55-{1000 + i}").Append("Plain value").ToList();
        var found = RedactionCheck.Run(pdf, null, new RedactionCheckOptions { Values = numbers, ValuesOnly = true });
        Assert.False(found.Incomplete);
        Assert.Contains(found.Findings, f => f.Kind == RedactionLeak.PageText);
    }
}
