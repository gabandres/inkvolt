using System.Diagnostics;
using System.Text;
using Inkvolt.Testing;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Batch's long-term action (roadmap 3.4, <see cref="AddLongTermStep"/>): Add Verification Information on each signed
/// file through one client per run, against the local authority of <see cref="LtvTestPki"/>, nothing needing the internet.
/// </summary>
public sealed class BatchLongTermTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-batch-ltv-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private string Put(string name, byte[] bytes)
    {
        var path = Path.Combine(_root, "in", name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private string Out => Path.Combine(_root, "out");

    private BatchPlan Plan(params BatchStep[] steps) => new() { Steps = steps, OutputFolder = Out };

    private static byte[] Signed(LtvTestPki pki, int pages = 2) =>
        Signing.Sign(TestPdf.Make(pages), null, new SignRequest { Certificate = pki.Signer, Reason = "Approved" });

    private static Task<BatchSummary> Run(IEnumerable<string> paths, BatchPlan plan, BatchHost host, CancellationToken cancel = default) =>
        BatchRunner.RunAsync([.. paths.Select(p => new BatchFile(p))], plan, host, null, cancel);

    private static SignatureInfo First(byte[] pdf, LtvTestPki pki) => Signatures.Verify(pdf, null, pki.Anchors).First(s => s.SubFilter != "ETSI.RFC3161");

    [Fact]
    public async Task A_mixed_batch_says_per_file_what_happened_and_asks_each_server_once()
    {
        using var pki = new LtvTestPki();
        var one = Signed(pki, 1);
        var two = Signed(pki, 3);
        byte[] already;
        using (var c = pki.Client()) already = (await Ltv.AddVerificationAsync(Signed(pki, 2), null, c)).Pdf;
        var hitsBefore = pki.Hits.Count;
        var paths = new[] { Put("one.pdf", one), Put("two.pdf", two), Put("plain.pdf", TestPdf.Make(1)), Put("already.pdf", already) };
        var originals = paths.Select(File.ReadAllBytes).ToList();

        var summary = await Run(paths, Plan(new AddLongTermStep()), new BatchHost { LongTermClient = () => pki.Client() });

        Assert.True(Plan(new AddLongTermStep()).IsSequential);
        foreach (var (item, signed) in summary.Items.Take(2).Zip([one, two]))
        {
            Assert.Equal(BatchItemState.Done, item.State);
            var result = File.ReadAllBytes(Assert.Single(item.Outputs));
            Assert.True(result.AsSpan(0, signed.Length).SequenceEqual(signed), "an update after the signed bytes");
            var s = First(result, pki);
            Assert.Equal(SignatureStatus.Valid, s.Status);
            Assert.True(s.LongTerm!.DataComplete);
            Assert.Contains(item.Notes, n => n.StartsWith("Asked 127.0.0.1", StringComparison.Ordinal));
        }
        Assert.Equal(BatchItemState.Skipped, summary.Items[2].State);
        Assert.StartsWith("No signature", summary.Items[2].Message);
        Assert.Equal(BatchItemState.Done, summary.Items[3].State);
        Assert.Empty(summary.Items[3].Outputs);
        Assert.Contains(summary.Items[3].Notes, n => n.StartsWith("Already long-term", StringComparison.Ordinal));
        // The originals as they were; the second file's chain was already known to the run: its servers weren't asked again.
        Assert.Equal(originals, paths.Select(File.ReadAllBytes).ToList());
        var asked = pki.Hits.Skip(hitsBefore).ToList();
        Assert.Equal(2, asked.Count(h => h == "/ocsp")); // the signer's and the intermediate's, once each: not again for the second file
    }

    [Fact]
    public async Task A_document_timestamp_per_file_reaches_b_lta()
    {
        using var pki = new LtvTestPki();
        var path = Put("a.pdf", Signed(pki));
        var summary = await Run([path], Plan(new AddLongTermStep(pki.TimestampUrl)), new BatchHost { LongTermClient = () => pki.Client() });
        var item = Assert.Single(summary.Items);
        Assert.Equal(BatchItemState.Done, item.State);
        Assert.Equal(PadesLevel.BLTA, First(File.ReadAllBytes(item.Outputs[0]), pki).LongTerm!.Level);
    }

    [Fact]
    public async Task Offline_and_unreachable_are_told_apart_and_a_silent_server_isn_t_asked_again()
    {
        var pki = new LtvTestPki();
        var paths = new[] { Put("a.pdf", Signed(pki, 1)), Put("b.pdf", Signed(pki, 2)) };
        var client = () => pki.Client(Timing.Limit(TimeSpan.FromSeconds(10)));
        pki.Dispose(); // the "internet" is gone

        var offline = await Run(paths, Plan(new AddLongTermStep()), new BatchHost { LongTermClient = client, IsOnline = () => false });
        Assert.All(offline.Items, i =>
        {
            Assert.Equal(BatchItemState.Failed, i.State);
            Assert.StartsWith("Offline", i.Message);
            Assert.Empty(i.Outputs);
        });

        var clock = Stopwatch.StartNew();
        var unreachable = await Run(paths, Plan(new AddLongTermStep()), new BatchHost { LongTermClient = client, IsOnline = () => true });
        Assert.All(unreachable.Items, i => Assert.StartsWith("Couldn't reach the service", i.Message));
        Assert.Contains("can't be reached", unreachable.Items[0].Message);
        Assert.Contains("wasn't asked again", unreachable.Items[1].Message);
        Assert.True(clock.Elapsed < Timing.Limit(TimeSpan.FromSeconds(10)), clock.Elapsed.ToString());
        Assert.False(Directory.Exists(Out) && Directory.EnumerateFiles(Out).Any());
    }

    [Fact]
    public async Task Without_a_client_nothing_goes_online()
    {
        using var pki = new LtvTestPki();
        var summary = await Run([Put("a.pdf", Signed(pki))], Plan(new AddLongTermStep()), new BatchHost());
        Assert.Equal(BatchItemState.Failed, summary.Items[0].State);
        Assert.Contains("may not go online", summary.Items[0].Message);
        Assert.Empty(pki.Hits);
    }

    [Fact]
    public void It_goes_with_checks_and_exports_only()
    {
        Assert.Null(Plan(new AddLongTermStep(), new ReportContentsStep(), new ExportStep(BatchExportFormat.Text)).Validate(false));
        Assert.Contains("break their signatures", Plan(new RotateStep(90), new AddLongTermStep()).Validate(false));
        Assert.Contains("twice", Plan(new AddLongTermStep(), new AddLongTermStep()).Validate(false));
    }

    [Fact]
    public async Task Cancelling_stops_a_file_waiting_on_a_server_and_saves_nothing()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/ocsp"] = async body =>
        {
            await Task.Delay(TimeSpan.FromSeconds(20));
            return LtvTestPki.Http(200, pki.OcspReply(body));
        };
        var paths = new[] { Put("a.pdf", Signed(pki, 1)), Put("b.pdf", Signed(pki, 2)) };
        using var cancel = Timing.CancelAfter(TimeSpan.FromMilliseconds(500));
        var clock = Stopwatch.StartNew();
        var summary = await Run(paths, Plan(new AddLongTermStep()), new BatchHost { LongTermClient = () => pki.Client(TimeSpan.FromSeconds(15)) }, cancel.Token);
        Assert.True(clock.Elapsed < Timing.Limit(TimeSpan.FromSeconds(5)), clock.Elapsed.ToString());
        Assert.All(summary.Items, i =>
        {
            Assert.Equal(BatchItemState.Cancelled, i.State);
            Assert.Empty(i.Outputs);
        });
    }

    [Theory]
    [InlineData("oversized")]
    [InlineData("garbage")]
    public async Task A_hostile_reply_fails_the_file_and_stores_nothing(string kind)
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/ocsp"] = _ => Task.FromResult(LtvTestPki.Http(200, kind == "oversized"
            ? new byte[LtvClient.MaxOcspReply + 1]
            : Encoding.ASCII.GetBytes("<html>Sign in to the hotel Wi-Fi</html>")));
        foreach (var ca in new[] { pki.Intermediate, pki.Root }) pki.Overrides[$"/crl/{ca.Thumbprint}.crl"] = _ => Task.FromResult(LtvTestPki.Http(404, []));
        var summary = await Run([Put("a.pdf", Signed(pki))], Plan(new AddLongTermStep()), new BatchHost { LongTermClient = () => pki.Client() });
        var item = Assert.Single(summary.Items);
        Assert.Equal(BatchItemState.Failed, item.State);
        Assert.StartsWith("Couldn't reach the service", item.Message);
        Assert.Contains("Nothing was changed", item.Message);
        Assert.Empty(item.Outputs);
    }

    [Fact]
    public void Presets_keep_the_action_and_its_timestamp_server()
    {
        foreach (var step in new[] { new AddLongTermStep(), new AddLongTermStep(LtvPlan.SuggestedTimestampServer) })
        {
            var json = BatchPresets.Write(new BatchPreset { Name = "LTV", Steps = [step] });
            Assert.Equal(step, Assert.Single(BatchPresets.Read(json).Steps));
        }
        var ex = Assert.Throws<BatchPresetException>(() => BatchPresets.Read("""
            { "format": "Inkvolt PDF batch preset", "version": 1, "actions": [ { "action": "addLongTermData", "timestampServer": "http://127.0.0.1/tsa" } ] }
            """));
        Assert.Contains("timestampServer", ex.Message);
    }

    [Fact]
    public async Task The_command_line_runs_it_only_with_online()
    {
        using var pki = new LtvTestPki();
        var input = Put("a.pdf", Signed(pki));
        var preset = Path.Combine(_root, "ltv.json");
        BatchPresets.Save(new BatchPreset { Name = "LTV", Steps = [new AddLongTermStep()] }, preset);

        async Task<(int Code, string Output, string Error)> Cli(params string[] args)
        {
            var (output, error) = (new StringWriter(), new StringWriter());
            var code = await BatchCommandLine.RunAsync(args, output, error, new BatchHost { LongTermClient = () => pki.Client() }, CancellationToken.None, _ => null);
            return (code, output.ToString(), error.ToString());
        }

        var refused = await Cli("--batch", preset, input, "--out", Out);
        Assert.Equal(BatchCommandLine.Wrong, refused.Code);
        Assert.Contains("--online", refused.Error);
        Assert.Empty(pki.Hits);

        var ran = await Cli("--batch", preset, input, "--out", Out, "--online");
        Assert.Equal(BatchCommandLine.Done, ran.Code);
        Assert.Contains("Asked 127.0.0.1", ran.Output);
        Assert.True(First(File.ReadAllBytes(Assert.Single(Directory.GetFiles(Out))), pki).LongTerm!.DataComplete);
    }
}
