using MuPDFCore;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Batch presets (JSON in and out), the watched folder, the command line and the Save as PDF/A action (roadmap 1.2).</summary>
[Collection("Pro")] // the command line asks the Pro check, which ProTests switches on and off
public sealed class BatchAutomationTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-auto-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private string Put(string relative, byte[] bytes)
    {
        var path = Path.Combine(_root, relative);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private static string Text(byte[] pdf, int page = 0)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return engine.GetText(page).Text;
    }

    private static int Pages(string path)
    {
        using var engine = PdfEngine.Open(File.ReadAllBytes(path), InputFileTypes.PDF, null);
        return engine.PageCount;
    }

    /// <summary>Every action with settings off their defaults.</summary>
    private static BatchPreset Everything() => new()
    {
        Name = "Everything «über»",
        OutputFolder = @"D:\Results\Scans",
        NameTemplate = "<<name>> <<n:3>> <<date:yyyy-MM>>",
        NeverOverwrite = false,
        KeepSubfolders = false,
        SignedFiles = SignedFilePolicy.Edit,
        Passwords = PasswordPolicy.Skip,
        ImagePageSize = PageSizeOption.A4,
        Steps =
        [
            new OcrStep(),
            new OptimizeStep(new OptimizeOptions { MaxImageDpi = null, JpegQuality = 60, RemoveMetadata = true, CompressStreams = false }),
            new SanitizeStep(new HashSet<SanitizeItem> { SanitizeItem.Signatures, SanitizeItem.Metadata, SanitizeItem.ActiveContent }),
            new RedactPatternsStep(new RedactionPatternOptions
            {
                Patterns = new HashSet<RedactionPattern> { RedactionPattern.ZipCode, RedactionPattern.Email },
                Phrases = ["Acme Corp", "Jane \"JD\" Doe"],
                WholeWord = false,
                MatchCase = true,
                Expression = @"CASE-\d{4}",
                Pages = [0, 2],
            }),
            new CheckRedactionStep(),
            new CheckAccessibilityStep(),
            new WatermarkStep(new WatermarkOptions { Text = "DRAFT", FontSize = 60, Color = new AnnotColor(1, 0, 0), Opacity = 0.25, Rotation = -30, Layout = WatermarkLayout.Tiled, Behind = true }),
            new WatermarkStep(new WatermarkOptions { Image = new StampImage(2, 1, [255, 0, 0, 0, 0, 255], [255, 128]), ImageScale = 0.2, Color = new AnnotColor(0, 0, 1) }), // colors keep 8 bits a channel
            new HeaderFooterStep(new HeaderFooterOptions
            {
                HeaderLeft = "<<file>>", FooterCenter = "Page <<page>> of <<pages>>", FooterRight = "<<bates>>", FontSize = 9, MarginBottom = 20,
                Bates = new BatesFormat("CASE-", 100, 7, "-X"),
            }, ContinueBates: true),
            new RotateStep(-90),
            new FlattenStep(new FlattenOptions { Links = true, PrintableOnly = true }),
            new UnprotectStep(),
            new ExportStep(BatchExportFormat.Jpeg, 300),
            new ExportStep(BatchExportFormat.Word),
            new SaveAsPdfAStep(),
            new ProtectStep("open-secret", "owner-secret", new PdfPermissions(PrintPermission.LowResolution, Copy: false), EncryptionMethod.Aes128),
        ],
    };

    // ───────────── presets ─────────────

    [Fact]
    public void APresetRoundTripsThroughExportAndImportUnchanged()
    {
        var json = BatchPresets.Write(Everything());
        var path = Path.Combine(_root, "presets", BatchPresets.FileName("Everything «über»"));
        BatchPresets.Save(BatchPresets.Read(json), path);
        Assert.Equal(json, File.ReadAllText(path)); // export → import → export: the same text
        var again = BatchPresets.Load(path);
        Assert.Equal(json, BatchPresets.Write(again));

        // The same settings come back (passwords aside, and the picture as pixels).
        var original = Everything();
        static object Output(BatchPreset p) => (p.Name, p.OutputFolder, p.NameTemplate, p.NeverOverwrite, p.KeepSubfolders, p.SignedFiles, p.Passwords, p.ImagePageSize);
        Assert.Equal(Output(original), Output(again));
        Assert.Equal(original.Steps.Count, again.Steps.Count);
        for (var i = 0; i < original.Steps.Count; i++)
        {
            switch ((original.Steps[i], again.Steps[i]))
            {
                case (WatermarkStep { Options.Image: { } a } w1, WatermarkStep { Options.Image: { } b } w2):
                    Assert.Equal((a.Width, a.Height), (b.Width, b.Height));
                    Assert.Equal(a.Rgb, b.Rgb);
                    Assert.Equal(a.Alpha, b.Alpha);
                    Assert.Equal(w1.Options with { Image = null }, w2.Options with { Image = null });
                    break;
                case (RedactPatternsStep r1, RedactPatternsStep r2):
                    Assert.Equal(r1.Options.Patterns.Order(), r2.Options.Patterns.Order());
                    Assert.Equal(r1.Options.Phrases, r2.Options.Phrases);
                    Assert.Equal(r1.Options.Pages, r2.Options.Pages);
                    Assert.Equal((r1.Options.Expression, r1.Options.WholeWord, r1.Options.MatchCase), (r2.Options.Expression, r2.Options.WholeWord, r2.Options.MatchCase));
                    break;
                case (SanitizeStep s1, SanitizeStep s2):
                    Assert.Equal(s1.Items.Order(), s2.Items.Order());
                    break;
                case (ProtectStep p1, ProtectStep p2):
                    Assert.Equal(("", ""), (p2.UserPassword, p2.OwnerPassword)); // wanted, not kept
                    Assert.True(p2.NeedsPasswords);
                    Assert.Equal((p1.Permissions, p1.Method), (p2.Permissions, p2.Method));
                    break;
                case (HeaderFooterStep h1, HeaderFooterStep h2):
                    Assert.Equal(h1.Options with { Date = default }, h2.Options with { Date = default });
                    Assert.Equal(h1.ContinueBates, h2.ContinueBates);
                    break;
                default:
                    Assert.Equal(original.Steps[i], again.Steps[i]);
                    break;
            }
        }
    }

    [Fact]
    public void APresetIsPlainReadableJsonWithoutPasswords()
    {
        var json = BatchPresets.Write(Everything());
        Assert.DoesNotContain("open-secret", json);
        Assert.DoesNotContain("owner-secret", json);
        Assert.StartsWith("{\n  \"format\": \"Inkvolt PDF batch preset\",\n  \"version\": 1,\n  \"name\": \"Everything «über»\",", json);
        Assert.Contains("\"names\": \"<<name>> <<n:3>> <<date:yyyy-MM>>\"", json); // not \u003C escapes
        Assert.Contains("\"action\": \"redactPatterns\"", json);
        Assert.Contains("\"patterns\": [\n        \"email\",\n        \"zipCode\"\n      ]", json); // the offered order, one per line
        Assert.Contains("\"openPassword\": true,\n      \"permissionsPassword\": true", json);
        Assert.Contains("\"color\": \"#FF0000\"", json);
        Assert.Contains("\"pages\": [\n        1,\n        3\n      ]", json); // page numbers from 1
        Assert.EndsWith("}\n", json);
        Assert.DoesNotContain("\r", json);
    }

    [Fact]
    public void AHandWrittenPresetTakesDefaultsForWhatItLeavesOut()
    {
        var preset = BatchPresets.Read("""
            // comments and trailing commas are fine
            { "version": 1, "actions": [ { "action": "watermark", "text": "COPY" }, { "action": "saveAsPdfA" }, ], }
            """, "From file");
        Assert.Equal("From file", preset.Name);
        Assert.Null(preset.OutputFolder);
        Assert.Equal(BatchNames.DefaultTemplate, preset.NameTemplate);
        Assert.Equal(new WatermarkOptions { Text = "COPY" }, Assert.IsType<WatermarkStep>(preset.Steps[0]).Options);
        Assert.IsType<SaveAsPdfAStep>(preset.Steps[1]);
    }

    [Theory]
    [InlineData("{ \"version\": 1, ", "isn't valid JSON (line 1")]
    [InlineData("[1, 2]", "should be a JSON object")]
    [InlineData("{ \"actions\": [] }", "has no \"version\"")]
    [InlineData("{ \"format\": \"something else\", \"version\": 1 }", "isn't an Inkvolt PDF batch preset")]
    [InlineData("{ \"version\": \"one\" }", "isn't one Inkvolt PDF knows")]
    [InlineData("{ \"version\": 2, \"actions\": [ { \"action\": \"teleport\" } ] }", "saved by a newer Inkvolt PDF (preset version 2")]
    [InlineData("{ \"version\": 1 }", "has no \"actions\"")]
    [InlineData("{ \"version\": 1, \"actions\": [] }", "list is empty")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"stamp\" } ] }", "Action 1: \"stamp\" isn't an action")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"ocr\" }, { \"action\": \"rotate\", \"degres\": 90 } ] }", "Action 2 (rotate): \"degres\" isn't a setting")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"rotate\", \"degrees\": 45 } ] }", "should be 90, -90 or 180")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"watermark\", \"text\": \"X\", \"opacity\": \"half\" } ] }", "\"opacity\" should be a number")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"watermark\", \"text\": \"X\", \"opacity\": 3 } ] }", "\"opacity\" should be between 0 and 1")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"export\", \"format\": \"pptx\" } ] }", "\"format\" should be one of \"word\", \"excel\"")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"protect\", \"openPassword\": \"hunter2\" } ] }", "passwords aren't kept in presets")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"protect\", \"openPassword\": true, \"password\": \"x\" } ] }", "passwords are never kept in presets")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"protect\" } ] }", "set \"openPassword\", \"permissionsPassword\" or both")]
    [InlineData("{ \"version\": 1, \"output\": { \"folder\": \"results\" }, \"actions\": [ { \"action\": \"ocr\" } ] }", "should be a full path")]
    [InlineData("{ \"version\": 1, \"actions\": [ { \"action\": \"redactPatterns\", \"patterns\": [\"ssn\"] } ] }", "(\"ssn\" isn't one)")]
    public void AMalformedOrNewerPresetIsRefusedSayingWhy(string json, string expected)
    {
        var ex = Assert.Throws<BatchPresetException>(() => BatchPresets.Read(json));
        Assert.Contains(expected, ex.Message);
    }

    [Fact]
    public void LoadingAMissingOrDamagedFileSaysWhichFile()
    {
        Assert.Contains("no preset file", Assert.Throws<BatchPresetException>(() => BatchPresets.Load(Path.Combine(_root, "none.json"))).Message);
        var damaged = Put("damaged.json", [0xFF, 0xFE, 0x00]);
        Assert.Contains("isn't valid JSON", Assert.Throws<BatchPresetException>(() => BatchPresets.Load(damaged)).Message);
    }

    [Fact]
    public void ProtectPasswordsAreGivenWhenItRuns()
    {
        var steps = BatchPresets.Read("""{ "version": 1, "actions": [ { "action": "protect", "openPassword": true } ] }""").Steps;
        var plan = new BatchPlan { Steps = steps, OutputFolder = _root };
        Assert.Contains("needs its passwords", plan.Validate(true));
        var given = BatchPresets.WithPasswords(steps, "s3cret", "ignored: not wanted");
        Assert.Equal(new ProtectStep("s3cret", null, PdfPermissions.All), given[0]);
        Assert.Null((plan with { Steps = given }).Validate(true));
        Assert.Equal("Protect with a password", given[0].ToString()); // never the password
    }

    // ───────────── Save as PDF/A in a batch ─────────────

    [Fact]
    public async Task SaveAsPdfAIsABatchAction()
    {
        var a = Put("in/a.pdf", TestPdf.Make(2, "archive"));
        var plan = new BatchPlan { Steps = [new RotateStep(90), new SaveAsPdfAStep()], OutputFolder = Path.Combine(_root, "out") };
        var summary = await BatchRunner.RunAsync([new BatchFile(a)], plan, new BatchHost(), null, CancellationToken.None);
        var item = Assert.Single(summary.Items);
        Assert.Equal(BatchItemState.Done, item.State);
        var result = File.ReadAllBytes(item.Outputs[0]);
        Assert.Empty(PdfA.Validate(result));
        Assert.Contains("archive", Text(result));
        Assert.Contains(item.Notes, n => n.StartsWith("PDF/A-2b"));

        Assert.Contains("can't be password protected", (plan with { Steps = [new SaveAsPdfAStep(), new ProtectStep("a", null, PdfPermissions.All)] }).Validate(true));
        Assert.Contains("after the other changes", (plan with { Steps = [new SaveAsPdfAStep(), new RotateStep(90)] }).Validate(true));
        Assert.Null((plan with { Steps = [new SaveAsPdfAStep(), new ExportStep(BatchExportFormat.Text)] }).Validate(true)); // exports may follow
    }

    // ───────────── watched folder ─────────────

    private static readonly WatchOptions Quick = new() { PollInterval = TimeSpan.FromMilliseconds(50), QuietPeriod = TimeSpan.FromMilliseconds(800) };

    private string Inbox => Path.Combine(_root, "inbox");
    private string Results => Path.Combine(_root, "results");

    private BatchPlan RotatePlan => new() { Steps = [new RotateStep(90)], OutputFolder = Results };

    private static string[] Names(string folder, string pattern = "*") =>
        Directory.Exists(folder) ? [.. Directory.GetFiles(folder, pattern).Select(Path.GetFileName).Order(StringComparer.OrdinalIgnoreCase)!] : [];

    private string[] LogLines() => File.Exists(Path.Combine(Inbox, WatchedFolder.LogName)) ? File.ReadAllLines(Path.Combine(Inbox, WatchedFolder.LogName)) : [];

    private static async Task Until(Func<bool> condition, int seconds = 90)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > end) throw new TimeoutException("the watched folder didn't get there in time");
            await Task.Delay(50);
        }
    }

    /// <summary>A copy that keeps the file open and adds a chunk at a time (as Explorer copying over a slow network does).</summary>
    private static async Task CopySlowlyHeld(byte[] bytes, string path, int chunks)
    {
        await using var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        fs.SetLength(bytes.Length); // network copies set the full size first
        var size = (bytes.Length + chunks - 1) / chunks;
        for (var at = 0; at < bytes.Length; at += size)
        {
            await fs.WriteAsync(bytes.AsMemory(at, Math.Min(size, bytes.Length - at)));
            await fs.FlushAsync();
            await Task.Delay(120);
        }
    }

    /// <summary>
    /// A copy that closes the file between chunks (a tool appending to it): it keeps growing, with pauses well inside the
    /// quiet period. On a thread of its own: on a busy CI runner, pool continuations were delayed past the quiet period,
    /// so the file looked finished halfway.
    /// </summary>
    private static Task CopySlowlyInBursts(byte[] bytes, string path, int chunks) => Task.Factory.StartNew(() =>
    {
        var size = (bytes.Length + chunks - 1) / chunks;
        for (var at = 0; at < bytes.Length; at += size)
        {
            using (var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read))
                fs.Write(bytes, at, Math.Min(size, bytes.Length - at));
            Thread.Sleep(80);
        }
    }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);

    [Fact]
    public async Task AWatchedFolderTakesEachFileOnceEvenWhenCopiedSlowly()
    {
        Directory.CreateDirectory(Inbox);
        const int each = 8;
        using var cts = new CancellationTokenSource();
        var entries = new List<WatchEntry>();
        var progress = new Progress<WatchProgress>(p =>
        {
            if (p.Finished is { } e) lock (entries) entries.Add(e);
        });
        // A longer quiet period than the other tests: the bursts' pauses must stay well inside it on a busy PC.
        var watch = WatchedFolder.RunAsync(Inbox, RotatePlan, new BatchHost(), Quick with { QuietPeriod = TimeSpan.FromSeconds(1.5) }, progress, cts.Token);

        var copies = new List<Task>();
        for (var i = 0; i < each; i++)
        {
            copies.Add(CopySlowlyHeld(TestPdf.Make(3, $"held{i}"), Path.Combine(Inbox, $"held{i}.pdf"), 10));
            copies.Add(CopySlowlyInBursts(TestPdf.Make(3, $"burst{i}"), Path.Combine(Inbox, $"burst{i}.pdf"), 10));
            File.WriteAllBytes(Path.Combine(Inbox, $"quick{i}.pdf"), TestPdf.Make(3, $"quick{i}"));
        }
        File.WriteAllBytes(Path.Combine(Inbox, "notes.txt"), [1, 2, 3]); // not a PDF or an image: left alone
        await Task.WhenAll(copies);
        await Until(() => Names(Path.Combine(Inbox, WatchedFolder.DoneFolder)).Length + Names(Path.Combine(Inbox, WatchedFolder.FailedFolder)).Length >= each * 3);
        await Task.Delay(Quick.QuietPeriod * 2); // nothing more may come out
        await cts.CancelAsync();
        var summary = await watch;

        Assert.Equal(new WatchSummary(each * 3, 0), summary);
        Assert.Empty(Names(Path.Combine(Inbox, WatchedFolder.FailedFolder)));
        Assert.Empty(Names(Path.Combine(Inbox, WatchedFolder.WorkingFolder)));
        var done = Names(Path.Combine(Inbox, WatchedFolder.DoneFolder));
        Assert.Equal(each * 3, done.Length);
        Assert.DoesNotContain(done, n => n.Contains(" (2)")); // none twice
        var results = Names(Results);
        Assert.Equal(done, results); // one result per file, same names
        foreach (var name in results)
        {
            Assert.Equal(3, Pages(Path.Combine(Results, name))); // whole: taken once the copy was complete
            Assert.Contains(Path.GetFileNameWithoutExtension(name), Text(File.ReadAllBytes(Path.Combine(Results, name)), 2));
        }
        Assert.Equal(["notes.txt"], Names(Inbox).Where(n => n != WatchedFolder.LogName));
        var log = LogLines();
        Assert.Equal(each * 3, log.Length);
        Assert.All(log, l => Assert.Equal("done", l.Split('\t')[1]));
        Assert.Equal(done, log.Select(l => l.Split('\t')[2]).Order(StringComparer.OrdinalIgnoreCase));
        lock (entries) Assert.Equal(each * 3, entries.Count);
    }

    [Fact]
    public async Task ALockedFileWaitsUntilItIsLetGo()
    {
        var path = Put("inbox/held.pdf", TestPdf.Make(1, "held"));
        using var cts = new CancellationTokenSource();
        var watch = WatchedFolder.RunAsync(Inbox, RotatePlan, new BatchHost(), Quick, null, cts.Token);
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) // another app holds it
        {
            await Task.Delay(Quick.QuietPeriod * 3);
            Assert.True(File.Exists(path));
            Assert.Empty(Names(Path.Combine(Inbox, WatchedFolder.DoneFolder)));
        }
        await Until(() => Names(Path.Combine(Inbox, WatchedFolder.DoneFolder)).Length == 1);
        await cts.CancelAsync();
        Assert.Equal(new WatchSummary(1, 0), await watch);
        Assert.Equal(["held.pdf"], Names(Results));
    }

    [Fact]
    public async Task OriginalsGoToDoneOrFailedWithALogLineEach()
    {
        Put("inbox/good.pdf", TestPdf.Make(1, "good"));
        Put("inbox/bad.pdf", "this is not a PDF"u8.ToArray());
        Put("inbox/done/good.pdf", [1]); // a name taken already
        Put("inbox/sub/deeper.pdf", TestPdf.Make(1)); // subfolders aren't watched
        var summary = await WatchedFolder.RunAsync(Inbox, RotatePlan, new BatchHost(), Quick with { Once = true }, null, CancellationToken.None);

        Assert.Equal(new WatchSummary(1, 1), summary);
        Assert.Equal(["good (2).pdf", "good.pdf"], Names(Path.Combine(Inbox, WatchedFolder.DoneFolder)));
        Assert.Equal(["bad.pdf"], Names(Path.Combine(Inbox, WatchedFolder.FailedFolder)));
        Assert.Equal(["good.pdf"], Names(Results));
        Assert.True(File.Exists(Path.Combine(Inbox, "sub", "deeper.pdf")));
        var log = LogLines().Select(l => l.Split('\t')).OrderBy(c => c[2]).ToList();
        Assert.Equal(2, log.Count);
        Assert.Equal(("failed", "bad.pdf", "This file isn't a PDF."), (log[0][1], log[0][2], log[0][3]));
        Assert.Equal(("done", "good.pdf", Path.Combine(Results, "good.pdf")), (log[1][1], log[1][2], log[1][4]));
    }

    [Fact]
    public async Task ARestartSendsInterruptedFilesToFailedAndOneFolderHasOneWatcher()
    {
        Put("inbox/working/crashed.pdf", TestPdf.Make(1)); // the app closed while working on it
        Put("inbox/new.pdf", TestPdf.Make(1));
        using var cts = new CancellationTokenSource();
        var first = WatchedFolder.RunAsync(Inbox, RotatePlan, new BatchHost(), Quick, null, cts.Token);
        await Until(() => Names(Path.Combine(Inbox, WatchedFolder.DoneFolder)).Length == 1);

        await Assert.ThrowsAsync<FolderWatchedException>(() => WatchedFolder.RunAsync(Inbox, RotatePlan, new BatchHost(), Quick, null, CancellationToken.None));
        await cts.CancelAsync();
        Assert.Equal(new WatchSummary(1, 1), await first);
        Assert.Equal(["crashed.pdf"], Names(Path.Combine(Inbox, WatchedFolder.FailedFolder))); // never run again
        Assert.Equal(["new.pdf"], Names(Results));
        Assert.Contains(LogLines(), l => l.Contains("crashed.pdf") && l.Contains("Interrupted"));

        // Restarted: nothing is done twice, and the folder can be watched again.
        Assert.Equal(new WatchSummary(0, 0), await WatchedFolder.RunAsync(Inbox, RotatePlan, new BatchHost(), Quick with { Once = true }, null, CancellationToken.None));
        Assert.Equal(["new.pdf"], Names(Results));
    }

    [Fact]
    public void TheResultsCantGoIntoTheWatchedFolderItself()
    {
        Directory.CreateDirectory(Inbox);
        Assert.Contains("can't go into the watched folder", WatchedFolder.Validate(Inbox, Inbox + Path.DirectorySeparatorChar));
        Assert.Null(WatchedFolder.Validate(Inbox, WatchedFolder.DefaultOutput(Inbox)));
        Assert.Contains("There is no folder", WatchedFolder.Validate(Path.Combine(_root, "missing"), Results));
    }

    // ───────────── command line ─────────────

    private async Task<(int Code, string Output, string Error)> Cli(Dictionary<string, string>? environment, params string[] args)
    {
        var output = new StringWriter();
        var error = new StringWriter();
        var code = await BatchCommandLine.RunAsync(args, output, error, new BatchHost(), CancellationToken.None, name => environment?.GetValueOrDefault(name));
        return (code, output.ToString(), error.ToString());
    }

    private string Preset(string json) => Put($"presets/{Guid.NewGuid():N}.json", System.Text.Encoding.UTF8.GetBytes(json));

    [Fact]
    public void TheCommandLineIsParsed()
    {
        Assert.True(BatchCommandLine.IsCommand(["--BATCH", "p.json", "a.pdf"]));
        Assert.True(BatchCommandLine.IsCommand(["/?"]));
        Assert.False(BatchCommandLine.IsCommand([@"C:\docs\--batch.pdf"]));
        Assert.False(BatchCommandLine.IsCommand([]));
        Assert.Equal(new CommandLineRequest(CommandKind.Help), BatchCommandLine.Parse(["-h"]));
        var batch = BatchCommandLine.Parse(["--batch", "p.json", "a.pdf", "--out", @"D:\out", "folder", "--recursive", "--quiet"]);
        Assert.Equal((CommandKind.Batch, "p.json", @"D:\out", true, true), (batch.Kind, batch.Preset, batch.Output, batch.Recursive, batch.Quiet));
        Assert.Equal(["a.pdf", "folder"], batch.Inputs);
        var watch = BatchCommandLine.Parse(["--watch", @"D:\in", "--preset", "p.json", "--once"]);
        Assert.Equal((CommandKind.Watch, "p.json", @"D:\in", true, (string?)null), (watch.Kind, watch.Preset, watch.Folder, watch.Once, watch.Output));

        Assert.Contains("needs the files or folders", Assert.Throws<CommandLineException>(() => BatchCommandLine.Parse(["--batch", "p.json"])).Message);
        Assert.Contains("--out needs a value", Assert.Throws<CommandLineException>(() => BatchCommandLine.Parse(["--batch", "p.json", "a.pdf", "--out"])).Message);
        Assert.Contains("\"--fast\" isn't an option", Assert.Throws<CommandLineException>(() => BatchCommandLine.Parse(["--batch", "p.json", "a.pdf", "--fast"])).Message);
        Assert.Contains("needs a preset", Assert.Throws<CommandLineException>(() => BatchCommandLine.Parse(["--watch", @"D:\in"])).Message);
        Assert.Contains("one folder", Assert.Throws<CommandLineException>(() => BatchCommandLine.Parse(["--watch", "a", "b", "--preset", "p"])).Message);
        Assert.Contains("goes with --watch", Assert.Throws<CommandLineException>(() => BatchCommandLine.Parse(["--batch", "p", "a", "--once"])).Message);
    }

    [Fact]
    public async Task HelpAndWrongCommandLinesGiveTheirExitCodes()
    {
        var help = await Cli(null, "--help");
        Assert.Equal(BatchCommandLine.Done, help.Code);
        Assert.Contains("inkvoltpdf --batch <preset.json>", help.Output);
        Assert.Contains("Exit codes", help.Output);

        var wrong = await Cli(null, "--batch");
        Assert.Equal(BatchCommandLine.Wrong, wrong.Code);
        Assert.Contains("--help", wrong.Error);

        var missing = await Cli(null, "--batch", Path.Combine(_root, "none.json"), _root, "--out", Results);
        Assert.Equal((BatchCommandLine.Wrong, true), (missing.Code, missing.Error.Contains("no preset file")));

        var future = await Cli(null, "--batch", Preset("""{ "version": 9, "actions": [] }"""), _root, "--out", Results);
        Assert.Equal((BatchCommandLine.Wrong, true), (future.Code, future.Error.Contains("newer Inkvolt PDF")));

        var noOut = await Cli(null, "--batch", Preset("""{ "version": 1, "actions": [ { "action": "rotate" } ] }"""), _root);
        Assert.Equal((BatchCommandLine.Wrong, true), (noOut.Code, noOut.Error.Contains("--out <folder>")));

        var noFiles = await Cli(null, "--batch", Preset("""{ "version": 1, "actions": [ { "action": "rotate" } ] }"""), Path.Combine(_root, "nothing-here.pdf"), "--out", Results);
        Assert.Equal((BatchCommandLine.Wrong, true), (noFiles.Code, noFiles.Error.Contains("There is no file or folder")));
        Assert.False(Directory.Exists(Results)); // nothing done
    }

    [Fact]
    public async Task TheBatchCommandRunsAPresetAndFailsOnAnyFailure()
    {
        Put("in/a.pdf", TestPdf.Make(1, "first"));
        Put("in/b.pdf", TestPdf.Make(1, "second"));
        var preset = Preset(BatchPresets.Write(new BatchPreset { Name = "Turn", OutputFolder = Results, Steps = [new RotateStep(90)] }));

        var ok = await Cli(null, "--batch", preset, Path.Combine(_root, "in"));
        Assert.Equal(BatchCommandLine.Done, ok.Code);
        Assert.Equal(["a.pdf", "b.pdf"], Names(Results));
        Assert.Contains("[2/2] done", ok.Output);
        Assert.Contains("2 done.", ok.Output);
        Assert.Equal("", ok.Error);

        Put("in/c.pdf", "not a pdf"u8.ToArray());
        var other = Path.Combine(_root, "other");
        var failing = await Cli(null, "--batch", preset, Path.Combine(_root, "in"), "--out", other, "--quiet");
        Assert.Equal(BatchCommandLine.SomeFailed, failing.Code);
        Assert.Equal(["a.pdf", "b.pdf"], Names(other)); // --out wins over the preset's folder
        Assert.Contains("failed   c.pdf: This file isn't a PDF.", failing.Error);
        Assert.DoesNotContain("done ", failing.Output); // --quiet: only failures and the summary
        Assert.Contains("2 done, 1 failed.", failing.Output);
    }

    [Fact]
    public async Task TheBatchCommandTakesProtectPasswordsFromTheEnvironment()
    {
        Put("in/a.pdf", TestPdf.Make(1));
        var preset = Preset("""{ "version": 1, "output": { "folder": null }, "actions": [ { "action": "saveAsPdfA" }, { "action": "export", "format": "text" } ] }""");
        var archived = await Cli(null, "--batch", preset, Path.Combine(_root, "in", "a.pdf"), "--out", Results);
        Assert.Equal(BatchCommandLine.Done, archived.Code);
        Assert.Empty(PdfA.Validate(File.ReadAllBytes(Path.Combine(Results, "a.pdf"))));
        Assert.True(File.Exists(Path.Combine(Results, "a.txt")));

        var protect = Preset("""{ "version": 1, "actions": [ { "action": "protect", "openPassword": true } ] }""");
        var without = await Cli(null, "--batch", protect, Path.Combine(_root, "in"), "--out", Path.Combine(_root, "locked"));
        Assert.Equal(BatchCommandLine.Wrong, without.Code);
        Assert.Contains(BatchCommandLine.OpenPasswordVariable, without.Error);

        var with = await Cli(new() { [BatchCommandLine.OpenPasswordVariable] = "s3cret" }, "--batch", protect, Path.Combine(_root, "in"), "--out", Path.Combine(_root, "locked"));
        Assert.Equal(BatchCommandLine.Done, with.Code);
        var locked = File.ReadAllBytes(Path.Combine(_root, "locked", "a.pdf"));
        Assert.True(PdfSecurity.NeedsOpenPassword(locked));
        Assert.DoesNotContain("s3cret", with.Output + with.Error);
    }

    [Fact]
    public async Task TheWatchCommandHandlesTheFolderOnce()
    {
        Put("inbox/a.pdf", TestPdf.Make(1));
        Put("inbox/b.pdf", "broken"u8.ToArray());
        var preset = Preset("""{ "version": 1, "actions": [ { "action": "rotate", "degrees": 180 } ] }""");
        var run = await Cli(null, "--watch", Inbox, "--preset", preset, "--once");
        Assert.Equal(BatchCommandLine.SomeFailed, run.Code);
        Assert.Equal(["a.pdf"], Names(WatchedFolder.DefaultOutput(Inbox))); // the preset has no folder: <folder>\results
        Assert.Contains("a.pdf", run.Output);
        Assert.Contains("b.pdf", run.Error);
        Assert.Contains("1 file done, 1 failed.", run.Output);

        var itself = await Cli(null, "--watch", Inbox, "--preset", preset, "--out", Inbox, "--once");
        Assert.Equal(BatchCommandLine.Wrong, itself.Code);
    }
}
