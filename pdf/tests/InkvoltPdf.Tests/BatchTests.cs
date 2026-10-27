using MuPDFCore;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public sealed class BatchTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-batch-").FullName;
    private static readonly DateTime When = new(2026, 10, 24, 9, 30, 0);

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private string Put(string relative, byte[] bytes)
    {
        var path = Path.Combine(_root, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private string Out => Path.Combine(_root, "out");

    private BatchPlan Plan(params BatchStep[] steps) => new() { Steps = steps, OutputFolder = Out, Date = When };

    private static Task<BatchSummary> Run(IEnumerable<string> paths, BatchPlan plan, BatchHost? host = null, IProgress<BatchProgress>? progress = null,
        CancellationToken cancel = default) =>
        BatchRunner.RunAsync([.. paths.Select(p => new BatchFile(p))], plan, host ?? new BatchHost(), progress, cancel);

    private static string Text(byte[] pdf, string? password = null, int page = 0)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, password);
        return engine.GetText(page).Text;
    }

    // ───────────── names and files ─────────────

    [Fact]
    public void NameTemplatesExpandAndStayValidFileNames()
    {
        Assert.Equal("report", BatchNames.Expand("<<name>>", @"C:\in\report.pdf", 1, When));
        Assert.Equal("report (signed) 007 2026-10-24 in", BatchNames.Expand("<<NAME>> (signed) <<n:3>> <<date>> <<folder>>", @"C:\in\report.pdf", 7, When));
        Assert.Equal("2026_10", BatchNames.Expand("<<date:yyyy/MM>>", @"C:\in\a.pdf", 1, When)); // a separator can't make a subfolder
        Assert.Equal("a_b_c", BatchNames.Expand("a:b?c", @"C:\in\x.pdf", 1, When));
        Assert.Equal("x", BatchNames.Expand("   ", @"C:\in\x.pdf", 1, When)); // empty: the original name
        Assert.Equal("_CON", BatchNames.Expand("CON", @"C:\in\x.pdf", 1, When)); // a device name can't be a file name
        Assert.Equal("x", BatchNames.Expand("<<name>>...", @"C:\in\x.pdf", 1, When)); // Windows drops trailing dots
        Assert.Equal("__other__ x", BatchNames.Expand("<<other>> <<name>>", @"C:\in\x.pdf", 1, When));
        Assert.True(BatchNames.Expand(new string('a', 400), @"C:\in\x.pdf", 1, When).Length <= BatchNames.MaxLength);
        Assert.Null(BatchNames.Validate("<<name>> small"));
        Assert.NotNull(BatchNames.Validate(""));
    }

    [Fact]
    public void FoldersExpandToTheirPdfsAndImages()
    {
        var a = Put("in/a.pdf", TestPdf.Make(1));
        Put("in/b.PNG", TestImages.Png(4, 4, (_, _) => (255, 0, 0, 255)));
        Put("in/notes.txt", [1, 2, 3]);
        Put("in/sub/c.pdf", TestPdf.Make(1));
        Put("in/sub/deeper/d.jpg", TestImages.Jpeg(8, 8));
        Put("out/old.pdf", TestPdf.Make(1)); // the output folder isn't read back in

        var top = BatchFiles.Expand([Path.Combine(_root, "in")], recursive: false);
        Assert.Equal(["a.pdf", "b.PNG"], top.Select(f => Path.GetFileName(f.Path)));
        Assert.All(top, f => Assert.Equal("", f.RelativeFolder));

        var all = BatchFiles.Expand([Path.Combine(_root, "in"), a, Path.Combine(_root, "in", "sub", "c.pdf")], recursive: true);
        Assert.Equal(["a.pdf", "b.PNG", "c.pdf", "d.jpg"], all.Select(f => Path.GetFileName(f.Path))); // no duplicates
        Assert.Equal(Path.Combine("sub", "deeper"), all.Single(f => f.Path.EndsWith("d.jpg")).RelativeFolder);
        Assert.True(all[1].IsImage);
        Assert.False(all[0].IsImage);

        var whole = BatchFiles.Expand([_root], recursive: true, excludeFolder: Out);
        Assert.DoesNotContain(whole, f => f.Path.Contains("old.pdf"));
    }

    [Fact]
    public void PlansAreCheckedBeforeRunning()
    {
        Assert.NotNull(Plan().Validate(ocrAvailable: true)); // no actions
        Assert.Null(Plan(new RotateStep(90)).Validate(ocrAvailable: true));
        Assert.NotNull((Plan(new RotateStep(90)) with { OutputFolder = "" }).Validate(true));
        Assert.NotNull((Plan(new RotateStep(90)) with { OutputFolder = "relative" }).Validate(true));
        // Protecting comes after the other changes (they would need its password); exports may follow it.
        var protect = new ProtectStep("open", "owner", PdfPermissions.All);
        Assert.NotNull(Plan(protect, new RotateStep(90)).Validate(true));
        Assert.Null(Plan(new RotateStep(90), protect, new ExportStep(BatchExportFormat.Text)).Validate(true));
        Assert.NotNull(Plan(protect, new ProtectStep("a", "b", PdfPermissions.All)).Validate(true));
        Assert.NotNull(Plan(new ExportStep(BatchExportFormat.Text), new ExportStep(BatchExportFormat.Text)).Validate(true));
        Assert.NotNull(Plan(new OcrStep()).Validate(ocrAvailable: false));
        Assert.NotNull(Plan(new ProtectStep(null, null, PdfPermissions.All)).Validate(true)); // no password at all
        Assert.DoesNotContain("open", protect.ToString()); // passwords never reach a log through ToString
    }

    [Fact]
    public void WeightedGateKeepsTheBudget()
    {
        var gate = new WeightedGate(100);
        Assert.True(gate.TryEnter(60));
        Assert.False(gate.TryEnter(60));
        Assert.True(gate.TryEnter(40));
        gate.Release(60);
        Assert.True(gate.TryEnter(50));
        // A job larger than the whole budget still runs, alone.
        var big = new WeightedGate(100);
        Assert.True(big.TryEnter(500));
        Assert.False(big.TryEnter(1));
        big.Release(500);
        Assert.True(big.TryEnter(1));
    }

    // ───────────── running ─────────────

    [Fact]
    public async Task EachFileGetsTheActionsInOrderAndASeparateResult()
    {
        var files = new[] { Put("in/one.pdf", TestPdf.Make(2, "first")), Put("in/two.pdf", TestPdf.Make(1, "second")) };
        var plan = Plan(new RotateStep(90), new WatermarkStep(new WatermarkOptions { Text = "DRAFT" }), new ExportStep(BatchExportFormat.Text));
        var seen = new List<BatchProgress>();
        var summary = await Run(files, plan, progress: new SyncProgress<BatchProgress>(seen.Add));

        Assert.Equal(2, summary.Done);
        Assert.Equal(0, summary.Failed);
        var one = File.ReadAllBytes(Path.Combine(Out, "one.pdf"));
        using (var engine = PdfEngine.Open(one, InputFileTypes.PDF, null))
        {
            Assert.Equal(2, engine.PageCount);
            Assert.True(engine.GetPage(0).Width > engine.GetPage(0).Height); // turned: shown landscape
            Assert.Contains("DRAFT", engine.GetText(1).Text);
        }
        Assert.Contains("Page 1 second", File.ReadAllText(Path.Combine(Out, "two.txt")));
        Assert.Contains("DRAFT", File.ReadAllText(Path.Combine(Out, "one.txt"))); // the export sees the earlier steps
        Assert.Equal([Path.Combine(Out, "one.pdf"), Path.Combine(Out, "one.txt")], summary.Items[0].Outputs);
        // Originals untouched.
        Assert.Equal(TestPdf.Make(2, "first").Length, new FileInfo(files[0]).Length);
        Assert.Contains(seen, p => p.Index == 1 && p.State == BatchItemState.Running);
        Assert.Contains(seen, p => p.Index == 1 && p.State == BatchItemState.Done);
        Assert.Equal("2 done.", summary.Text);
    }

    [Fact]
    public async Task ExistingFilesAreNeverOverwrittenUnlessAsked()
    {
        var a = Put("in/a.pdf", TestPdf.Make(1));
        Directory.CreateDirectory(Out);
        File.WriteAllBytes(Path.Combine(Out, "a.pdf"), [1]);
        var summary = await Run([a], Plan(new RotateStep(180)));
        Assert.Equal(1, summary.Done);
        Assert.Equal([1], File.ReadAllBytes(Path.Combine(Out, "a.pdf")));
        Assert.True(File.Exists(Path.Combine(Out, "a (2).pdf")));

        summary = await Run([a], Plan(new RotateStep(180)) with { NeverOverwrite = false });
        Assert.NotEqual([1], File.ReadAllBytes(Path.Combine(Out, "a.pdf")));
        Assert.False(File.Exists(Path.Combine(Out, "a (3).pdf")));

        // Writing into the input folder never replaces an input, even with overwriting allowed.
        var inPlace = await Run([a], (Plan(new RotateStep(90)) with { NeverOverwrite = false, OutputFolder = Path.GetDirectoryName(a)! }));
        Assert.Equal(1, inPlace.Done);
        Assert.Equal(TestPdf.Make(1).Length, new FileInfo(a).Length);
        Assert.True(File.Exists(Path.Combine(_root, "in", "a (2).pdf")));
    }

    [Fact]
    public async Task TwoInputsWithTheSameNameGetTwoOutputs()
    {
        var x = Put("in/x/report.pdf", TestPdf.Make(1, "x"));
        var y = Put("in/y/report.pdf", TestPdf.Make(1, "y"));
        var summary = await Run([x, y], Plan(new RotateStep(90)) with { KeepSubfolders = false, NeverOverwrite = false });
        Assert.Equal(2, summary.Done);
        Assert.Equal(2, Directory.GetFiles(Out).Length);
    }

    [Fact]
    public async Task SubfoldersAreKeptBelowTheOutputFolder()
    {
        Put("in/top.pdf", TestPdf.Make(1));
        Put("in/sub/inner.pdf", TestPdf.Make(1));
        var files = BatchFiles.Expand([Path.Combine(_root, "in")], recursive: true);
        var summary = await BatchRunner.RunAsync(files, Plan(new RotateStep(90)), new BatchHost(), null, default);
        Assert.Equal(2, summary.Done);
        Assert.True(File.Exists(Path.Combine(Out, "top.pdf")));
        Assert.True(File.Exists(Path.Combine(Out, "sub", "inner.pdf")));
    }

    [Fact]
    public async Task AFailureIsListedAndTheBatchGoesOn()
    {
        var bad = Put("in/broken.pdf", "%PDF-1.7\nthis is not a pdf at all"u8.ToArray());
        var notPdf = Put("in/fake.pdf", "hello"u8.ToArray());
        var good = Put("in/good.pdf", TestPdf.Make(1));
        var summary = await Run([bad, notPdf, good], Plan(new RotateStep(90)));
        Assert.Equal(1, summary.Done);
        Assert.Equal(2, summary.Failed);
        Assert.Equal(BatchItemState.Failed, summary.Items[0].State);
        Assert.False(string.IsNullOrWhiteSpace(summary.Items[0].Message));
        Assert.Contains("isn't a PDF", summary.Items[1].Message);
        Assert.True(File.Exists(Path.Combine(Out, "good.pdf")));
        Assert.False(File.Exists(Path.Combine(Out, "broken.pdf"))); // nothing half-written
        Assert.Equal("1 done, 2 failed.", summary.Text);
    }

    [Fact]
    public async Task ImagesBecomePdfsFirst()
    {
        var png = Put("in/photo.png", TestImages.Png(40, 20, (_, _) => (0, 0, 255, 255)));
        var summary = await Run([png], Plan(new ExportStep(BatchExportFormat.Text)) with { ImagePageSize = PageSizeOption.A4 });
        Assert.Equal(1, summary.Done);
        var pdf = File.ReadAllBytes(Path.Combine(Out, "photo.pdf")); // made even with only an export chosen
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        Assert.Equal(842, engine.GetPage(0).Width, 0); // A4, turned for a wide picture
        // A picture has no text: no text file, and the result says why.
        Assert.False(File.Exists(Path.Combine(Out, "photo.txt")));
        Assert.Contains(summary.Items[0].Notes, n => n.Contains("no text", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task OnlyExportsWriteNoPdf()
    {
        var a = Put("in/a.pdf", TestPdf.Make(2));
        var summary = await Run([a], Plan(new ExportStep(BatchExportFormat.Word), new ExportStep(BatchExportFormat.Png, 72)));
        Assert.Equal(1, summary.Done);
        Assert.False(File.Exists(Path.Combine(Out, "a.pdf")));
        Assert.True(new FileInfo(Path.Combine(Out, "a.docx")).Length > 1000);
        Assert.True(File.Exists(Path.Combine(Out, "a - page 1.png")));
        Assert.True(File.Exists(Path.Combine(Out, "a - page 2.png")));
        using var docx = DocumentFormat.OpenXml.Packaging.WordprocessingDocument.Open(Path.Combine(Out, "a.docx"), false);
        Assert.Contains("Page 2 alpha", docx.MainDocumentPart!.Document.InnerText);
    }

    [Fact]
    public async Task ExportsCommentsFormDataAndSummaries()
    {
        var commented = Put("in/review.pdf", CommentFilesTests.Commented());
        var form = Put("in/form.pdf", FormEditor.SetValues(FormDataTests.Form(), null, new Dictionary<string, string> { ["name"] = "Ana" }));
        var plain = Put("in/plain.pdf", TestPdf.Make(1));
        var plan = Plan(new ExportStep(BatchExportFormat.CommentsXfdf), new ExportStep(BatchExportFormat.CommentsCsv), new ExportStep(BatchExportFormat.CommentSummary),
            new ExportStep(BatchExportFormat.FormDataJson), new ExportStep(BatchExportFormat.FormDataFdf));
        Assert.Null(plan.Validate(true));
        var summary = await Run([commented, form, plain], plan);
        Assert.Equal(3, summary.Done);
        Assert.Equal(13, CommentFiles.Count(File.ReadAllBytes(Path.Combine(Out, "review.xfdf"))));
        Assert.Equal(13, CommentFiles.Count(File.ReadAllBytes(Path.Combine(Out, "review comments.csv"))));
        Assert.Contains("Callout, text", Text(File.ReadAllBytes(Path.Combine(Out, "review comments.pdf")), page: 1));
        Assert.Equal("Ana", FormDataFiles.ReadValues(File.ReadAllBytes(Path.Combine(Out, "form.json")))["name"]);
        Assert.Equal("Ana", FormDataFiles.ReadValues(File.ReadAllBytes(Path.Combine(Out, "form.fdf")))["name"]);
        Assert.False(File.Exists(Path.Combine(Out, "plain.xfdf")));
        Assert.False(File.Exists(Path.Combine(Out, "plain.json")));
        Assert.Contains(summary.Items.Single(i => i.File.Path == plain).Notes, n => n.StartsWith("Comments: none", StringComparison.Ordinal));

        // The new exports go into presets and come back.
        Assert.Equal(plan.Steps, BatchPresets.Read(BatchPresets.Write(BatchPreset.From("Review", plan, false))).Steps);
    }

    [Fact]
    public async Task PasswordsAreAskedPerFileOrSkipped()
    {
        var locked = Put("in/locked.pdf", TestPdf.Encrypted(1, "secret"));
        var open = Put("in/open.pdf", TestPdf.Make(1));
        var asked = new List<BatchPasswordRequest>();
        var answers = new Queue<string?>(["wrong", "secret", "secret-owner"]);
        var host = new BatchHost
        {
            AskPassword = (r, _) =>
            {
                asked.Add(r);
                return Task.FromResult(answers.Dequeue());
            },
        };
        var summary = await Run([locked, open], Plan(new WatermarkStep(new WatermarkOptions { Text = "COPY" })), host);
        Assert.Equal(2, summary.Done);
        // Opened with its open password, which doesn't allow changes: its permissions password is asked for next.
        Assert.Equal([BatchPasswordKind.Open, BatchPasswordKind.Open, BatchPasswordKind.Permissions], asked.Select(a => a.Kind));
        Assert.False(asked[0].Wrong);
        Assert.True(asked[1].Wrong);
        Assert.False(asked[2].Wrong);
        Assert.Equal(locked, asked[0].File.Path);
        // The result keeps its protection: it opens with the same password only.
        var result = File.ReadAllBytes(Path.Combine(Out, "locked.pdf"));
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(result, InputFileTypes.PDF, null).Dispose());
        Assert.Contains("COPY", Text(result, "secret"));

        // Skip: a file that needs a password is listed as skipped, without asking.
        asked.Clear();
        var skipped = await Run([locked, open], Plan(new RotateStep(90)) with { Passwords = PasswordPolicy.Skip }, host);
        Assert.Empty(asked);
        Assert.Equal(1, skipped.Skipped);
        Assert.Equal(BatchItemState.Skipped, skipped.Items[0].State);
        Assert.Contains("password", skipped.Items[0].Message);

        // No answer (Cancel in the prompt) skips that file only.
        var declined = await Run([locked, open], Plan(new RotateStep(90)), new BatchHost { AskPassword = (_, _) => Task.FromResult<string?>(null) });
        Assert.Equal((1, 1), (declined.Skipped, declined.Done));
    }

    [Fact]
    public async Task ARestrictedFileAsksForItsPermissionsPassword()
    {
        var restricted = Put("in/r.pdf", PdfSecurity.Protect(TestPdf.Make(1), null, null, "boss", new PdfPermissions(Modify: false)));
        var asked = new List<BatchPasswordRequest>();
        var host = new BatchHost
        {
            AskPassword = (r, _) =>
            {
                asked.Add(r);
                return Task.FromResult<string?>("boss");
            },
        };
        var summary = await Run([restricted], Plan(new RotateStep(90)), host);
        Assert.Equal(1, summary.Done);
        Assert.Equal(BatchPasswordKind.Permissions, Assert.Single(asked).Kind);
        var info = PdfSecurity.ReadSecurity(File.ReadAllBytes(Path.Combine(Out, "r.pdf")), null);
        Assert.False(info.Permissions.Modify); // still restricted
    }

    [Fact]
    public async Task ProtectAndUnprotect()
    {
        var a = Put("in/a.pdf", TestPdf.Make(1));
        var summary = await Run([a], Plan(new RotateStep(90), new ProtectStep("open", "owner", PdfPermissions.All), new ExportStep(BatchExportFormat.Text)));
        Assert.Equal(1, summary.Done);
        var protectedPdf = File.ReadAllBytes(Path.Combine(Out, "a.pdf"));
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(protectedPdf, InputFileTypes.PDF, null).Dispose());
        Assert.Contains("Page 1", Text(protectedPdf, "open"));
        Assert.Contains("Page 1", File.ReadAllText(Path.Combine(Out, "a.txt")));

        var locked = Put("in/locked.pdf", TestPdf.Encrypted(1, "pw"));
        var host = new BatchHost { AskPassword = (r, _) => Task.FromResult<string?>(r.Kind == BatchPasswordKind.Open ? "pw" : "pw-owner") };
        var unprotected = await Run([locked], Plan(new UnprotectStep()), host);
        Assert.Equal(1, unprotected.Done);
        Assert.Contains("Page 1", Text(File.ReadAllBytes(Path.Combine(Out, "locked.pdf"))));
    }

    [Fact]
    public async Task SignedFilesAreSkippedUnlessChosen()
    {
        var signed = Put("in/signed.pdf", Core2SignatureTests.Signed());
        var summary = await Run([signed], Plan(new RotateStep(90)));
        Assert.Equal(1, summary.Skipped);
        Assert.Contains("signed", summary.Items[0].Message, StringComparison.OrdinalIgnoreCase);

        // Exports only read the file: signed files are exported.
        Assert.Equal(1, (await Run([signed], Plan(new ExportStep(BatchExportFormat.Text)))).Done);

        var edited = await Run([signed], Plan(new FlattenStep(new FlattenOptions())) with { SignedFiles = SignedFilePolicy.Edit });
        Assert.Equal(1, edited.Done);

        // Changes and exports together: the changes are skipped, the exports still made, no changed copy written.
        Directory.Delete(Out, true);
        var mixed = await Run([signed], Plan(new RotateStep(90), new ExportStep(BatchExportFormat.Text)));
        Assert.Equal(1, mixed.Done);
        Assert.Contains("Hello contract", File.ReadAllText(Path.Combine(Out, "signed.txt")));
        Assert.False(File.Exists(Path.Combine(Out, "signed.pdf")));
        Assert.Contains(mixed.Items[0].Notes, n => n.Contains("Signed", StringComparison.Ordinal));
    }

    [Fact]
    public void RenderingActionsWeighTheirPages()
    {
        var plain = Plan(new RotateStep(90));
        Assert.Equal(32L << 20, BatchRunner.Weight(1000, (612, 792), plain)); // small file, no rendering: the minimum
        // A small vector PDF exported at 600 dpi: a Letter page is 5100 x 6600 pixels, 4 bytes each.
        var images = Plan(new ExportStep(BatchExportFormat.Png, 600));
        Assert.Equal((32L << 20) + 4L * 5100 * 6600, BatchRunner.Weight(1000, (612, 792), images));
        // Four of them don't fit a 256 MB budget together.
        Assert.True(4 * BatchRunner.Weight(1000, (612, 792), images) > 256L << 20);
        // OCR renders at 300 dpi; a huge page is capped as the renderers cap it.
        Assert.Equal((32L << 20) + 4L * 2550 * 3300, BatchRunner.Weight(1000, null, Plan(new OcrStep())));
        Assert.Equal((32L << 20) + 4L * 64_000_000, BatchRunner.Weight(1000, (14400, 14400), images));
    }

    [Fact]
    public void AFileThatAppearsMeanwhileIsNeverOverwritten()
    {
        var names = new OutputNames(overwrite: false, []);
        var path = names.Place(Out, "a.pdf", temp =>
        {
            File.WriteAllBytes(temp, [1]);
            File.WriteAllBytes(Path.Combine(Out, "a.pdf"), [9]); // another program, between picking the name and the move
        });
        Assert.Equal(Path.Combine(Out, "a (2).pdf"), path);
        Assert.Equal([9], File.ReadAllBytes(Path.Combine(Out, "a.pdf")));
        Assert.Equal([1], File.ReadAllBytes(path));
        Assert.DoesNotContain(Directory.GetFiles(Out), f => f.EndsWith(".tmp", StringComparison.Ordinal));
        // A failed write leaves nothing behind.
        Assert.Throws<InvalidOperationException>(() => names.Place(Out, "b.pdf", _ => throw new InvalidOperationException()));
        Assert.Equal(2, Directory.GetFiles(Out).Length);
    }

    [Fact]
    public async Task BatesNumbersCanContinueFromFileToFile()
    {
        var files = new[] { Put("in/1.pdf", TestPdf.Make(2)), Put("in/2.pdf", TestPdf.Make(3)), Put("in/3.pdf", TestPdf.Make(1)) };
        var options = new HeaderFooterOptions { FooterRight = "<<bates>>", HeaderLeft = "<<file>>", Bates = new BatesFormat("CASE-", 1, 4) };
        var summary = await Run(files, Plan(new HeaderFooterStep(options, ContinueBates: true)) with { MaxParallel = 3 });
        Assert.Equal(3, summary.Done);
        Assert.Contains("CASE-0001", Text(File.ReadAllBytes(Path.Combine(Out, "1.pdf"))));
        Assert.Contains("1.pdf", Text(File.ReadAllBytes(Path.Combine(Out, "1.pdf"))));
        Assert.Contains("CASE-0003", Text(File.ReadAllBytes(Path.Combine(Out, "2.pdf"))));
        Assert.Contains("CASE-0005", Text(File.ReadAllBytes(Path.Combine(Out, "2.pdf")), page: 2));
        Assert.Contains("CASE-0006", Text(File.ReadAllBytes(Path.Combine(Out, "3.pdf"))));

        // Without it, each file starts again.
        Directory.Delete(Out, true);
        await Run(files, Plan(new HeaderFooterStep(options)));
        Assert.Contains("CASE-0001", Text(File.ReadAllBytes(Path.Combine(Out, "3.pdf"))));
    }

    [Fact]
    public async Task OcrUsesTheHostsRecognizerOnPagesWithoutText()
    {
        var scan = Put("in/scan.png", TestImages.Png(200, 100, (_, _) => (255, 255, 255, 255)));
        var calls = 0;
        var host = new BatchHost
        {
            Recognize = (engine, page, _) =>
            {
                Interlocked.Increment(ref calls);
                return [new OcrWord("Recognized", new RectD(10, 10, 80, 12))];
            },
        };
        var summary = await Run([scan, Put("in/text.pdf", TestPdf.Make(1))], Plan(new OcrStep(), new ExportStep(BatchExportFormat.Text)), host);
        Assert.Equal(2, summary.Done);
        Assert.Equal(1, calls); // the PDF with text isn't recognized
        Assert.Contains("Recognized", File.ReadAllText(Path.Combine(Out, "scan.txt")));
    }

    [Fact]
    public async Task ParallelismIsBounded()
    {
        var files = Enumerable.Range(0, 8).Select(i => Put($"in/f{i}.pdf", TestPdf.Make(1))).ToList();
        var running = 0;
        var most = 0;
        var host = new BatchHost
        {
            Recognize = (_, _, _) =>
            {
                var now = Interlocked.Increment(ref running);
                lock (files) most = Math.Max(most, now);
                Thread.Sleep(60);
                Interlocked.Decrement(ref running);
                return [];
            },
        };
        // Pages with text aren't recognized, so give them a blank page to recognize.
        var blank = files.Select((f, i) => Put($"in/b{i}.png", TestImages.Png(10, 10, (_, _) => (255, 255, 255, 255)))).ToList();
        var summary = await Run(blank, Plan(new OcrStep()) with { MaxParallel = 2 }, host);
        Assert.Equal(8, summary.Done);
        Assert.InRange(most, 1, 2);
    }

    [Fact]
    public async Task CancelStopsTheRest()
    {
        var files = Enumerable.Range(0, 6).Select(i => Put($"in/c{i}.png", TestImages.Png(10, 10, (_, _) => (255, 255, 255, 255)))).ToList();
        using var cts = new CancellationTokenSource();
        var host = new BatchHost
        {
            Recognize = (_, _, token) =>
            {
                cts.Cancel();
                token.ThrowIfCancellationRequested();
                return [];
            },
        };
        var summary = await Run(files, Plan(new OcrStep()) with { MaxParallel = 1 }, host, cancel: cts.Token);
        Assert.Equal(6, summary.Cancelled);
        Assert.Equal(0, summary.Done);
        Assert.False(Directory.Exists(Out) && Directory.EnumerateFiles(Out).Any()); // nothing written for cancelled files
        Assert.Equal("6 cancelled.", summary.Text);
    }

    /// <summary>Reports synchronously (Progress&lt;T&gt; posts to the thread pool, so a test could read before it lands).</summary>
    private sealed class SyncProgress<T>(Action<T> report) : IProgress<T>
    {
        private readonly Lock _gate = new();

        public void Report(T value)
        {
            lock (_gate) report(value);
        }
    }
}
