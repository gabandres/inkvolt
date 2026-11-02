using System.IO.Compression;
using System.Text;
using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Recording;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>Help › Report a problem's recording (roadmap 1.2): as <c>inkvoltprint record</c>, through the demo's and the tests' fixtures. No printer.</summary>
public sealed class ReportRecordingTests : IDisposable
{
    private const string Host = "10.20.30.40";
    private static readonly Diagnostics.Identity Me = new("jdoe", "JDOE-LAPTOP");
    private static readonly DateTime Now = new(2026, 11, 1, 17, 30, 5);
    private readonly string _parent = Path.Combine(Path.GetTempPath(), "inkvolt-report-rec-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_parent)) Directory.Delete(_parent, recursive: true);
    }

    private static string FixtureDir(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", name);

    private static HttpMessageHandler At(string host, HttpMessageHandler printer) =>
        new HostRouter(new Dictionary<string, HttpMessageHandler> { [host] = printer });

    private static FixtureHandler Planted()
    {
        var m234dw = FixtureDir("m234dw");
        return new FixtureHandler(name =>
            name == "ipp_print.ipp.txt" ? Encoding.UTF8.GetBytes(RecordingTests.PlantedIpp)
            : File.Exists(Path.Combine(m234dw, name)) ? Encoding.UTF8.GetBytes(RecordingTests.Plant(name, File.ReadAllText(Path.Combine(m234dw, name)))) : null);
    }

    private static RecordOptions Options(HttpMessageHandler printer) =>
        new() { Transport = At(Host, printer), Snmp = new SnmpAgent(SnmpAgent.ParseWalk(RecordingTests.PlantedWalk())), Who = Me };

    [Fact]
    public async Task The_report_path_scrubs_as_the_command_does_in_the_folder_the_zip_and_the_line_copied()
    {
        var done = await ReportRecording.RunAsync(Host, _parent, Options(Planted()), Now);

        Assert.Equal(Path.Combine(_parent, "printer-recording-20261101-173005"), done.Folder);
        Assert.Equal(done.Folder + ".zip", done.Zip);
        Assert.True(done.Result.Files.Count > 5);
        foreach (var file in Directory.GetFiles(done.Folder)) AssertClean(Path.GetFileName(file), File.ReadAllText(file));

        using var zip = ZipFile.OpenRead(done.Zip);
        Assert.Equal(done.Result.Files.Order(), zip.Entries.Select(e => e.FullName).Order());
        foreach (var entry in zip.Entries)
        {
            using var reader = new StreamReader(entry.Open());
            AssertClean(entry.FullName, reader.ReadToEnd());
        }

        var line = ReportRecording.ReportLine(done, Me);
        AssertClean("the line", line);
        Assert.Contains("HP LaserJet MFP M234dw", line);
        Assert.Contains("printer-recording-20261101-173005.zip", line);
        Assert.DoesNotContain(_parent, line);
    }

    private static void AssertClean(string where, string text)
    {
        foreach (var planted in RecordingTests.Planted)
            Assert.False(text.Contains(planted, StringComparison.OrdinalIgnoreCase), $"{planted} left in {where}");
    }

    [Fact]
    public async Task The_demo_printer_records_and_reads_back_with_no_printer_on_this_pc()
    {
        const string host = FixtureHandler.DemoHost;
        var done = await ReportRecording.RunAsync(host, _parent, new RecordOptions
        {
            Transport = At(host, new FixtureHandler(name => File.Exists(Path.Combine(FixtureDir("m234dw"), name)) ? File.ReadAllBytes(Path.Combine(FixtureDir("m234dw"), name)) : null)),
            Who = Me,
        }, Now);
        Assert.Equal("HP LaserJet MFP M234dw", done.Result.Model);
        Assert.Contains("DevMgmt_ProductStatusDyn.xml", done.Result.Files);
        Assert.Contains(PrinterRecorder.NotesFile, done.Result.Files);
        Assert.DoesNotContain(done.Result.Files, f => f.EndsWith(".jpg", StringComparison.Ordinal)); // never scans, whatever asked
    }

    [Fact]
    public async Task It_never_scans_even_if_the_options_say_so()
    {
        var done = await ReportRecording.RunAsync(Host, _parent, Options(Planted()) with { Scan = true }, Now);
        Assert.DoesNotContain(done.Result.Files, f => f.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task Two_recordings_in_one_second_get_their_own_folders()
    {
        var first = await ReportRecording.RunAsync(Host, _parent, Options(Planted()), Now);
        var second = await ReportRecording.RunAsync(Host, _parent, Options(Planted()), Now);
        Assert.NotEqual(first.Folder, second.Folder);
        Assert.True(File.Exists(first.Zip));
        Assert.True(File.Exists(second.Zip));
    }

    [Fact]
    public async Task What_a_printer_calls_itself_doesnt_name_the_folder()
    {
        var hostile = new FixtureHandler(name =>
        {
            var path = Path.Combine(FixtureDir("m234dw"), name);
            if (!File.Exists(path)) return null;
            return Encoding.UTF8.GetBytes(File.ReadAllText(path).Replace("HP LaserJet MFP M234dw", @"..\..\Startup\evil"));
        });
        var done = await ReportRecording.RunAsync(Host, _parent, Options(hostile), Now);
        Assert.Equal(_parent, Path.GetDirectoryName(done.Folder));
        Assert.Equal([done.Folder], Directory.GetDirectories(_parent));
    }

    [Fact]
    public async Task Nothing_answering_leaves_nothing_and_the_message_doesnt_quote_the_address()
    {
        var empty = new FixtureHandler(_ => null);
        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            ReportRecording.RunAsync(Host, _parent, new RecordOptions { Transport = At(Host, empty), Who = Me }, Now));
        Assert.Empty(Directory.GetFileSystemEntries(_parent));
        var text = ReportRecording.FailureText(ex, Me);
        Assert.StartsWith("Nothing recorded: ", text);
        Assert.DoesNotContain(Host, text);
    }

    [Fact]
    public async Task Cancelling_leaves_nothing()
    {
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ReportRecording.RunAsync(Host, _parent, Options(Planted()), Now, cts.Token));
        Assert.Empty(Directory.GetFileSystemEntries(_parent));
    }

    // ---------------------------------------------------------------- names a printer's discovery tree can make the recorder ask for

    [Theory]
    [InlineData("/DevMgmt/ProductStatusDyn.xml", "DevMgmt_ProductStatusDyn.xml")]
    [InlineData("/cdm/system/v1/identity", "cdm_system_v1_identity.json")]
    [InlineData("/eSCL/ScannerCapabilities", "eSCL_ScannerCapabilities.xml")]
    [InlineData("/C:/Windows/evil", "C__Windows_evil.xml")] // would be drive-relative: Path.Combine would leave the folder
    [InlineData("/a:b.xml", "a_b.xml")] // a stream of file "a"
    [InlineData("/x%5C..%5Cevil.xml", "x_5C.._5Cevil.xml")]
    [InlineData("/CON", "CON.xml")]
    public void A_replys_file_name_stays_a_plain_name_in_the_folder(string path, string name)
    {
        Assert.Equal(name, PrinterRecorder.KeptName(path));
        Assert.Equal(Path.Combine("folder", name), Path.Combine("folder", PrinterRecorder.KeptName(path)!));
    }

    [Theory]
    [InlineData("/run.bat")]
    [InlineData("/page.hta")]
    [InlineData("/page.html")]
    [InlineData("/a.lnk")]
    [InlineData("/a.exe")]
    [InlineData("/a.ps1")]
    [InlineData("/recording.tsv")] // the notes are ours
    [InlineData("/snmp.txt")] // so is the walk
    [InlineData("/SNMP.TXT")] // the same file on this disk
    [InlineData("/.xml")]
    public void A_printer_cant_put_a_file_that_runs_or_ours_in_a_recording(string path) => Assert.Null(PrinterRecorder.KeptName(path));

    [Theory]
    [InlineData("http://192.0.2.200/secret.xml")]
    [InlineData("//192.0.2.200/secret.xml")]
    public async Task A_printer_cant_point_the_recorder_at_another_computer(string href)
    {
        var m234dw = FixtureDir("m234dw");
        var tree = File.ReadAllText(Path.Combine(m234dw, "DevMgmt_DiscoveryTree.xml")).Replace("/DevMgmt/ProductStatusDyn.xml", href);
        Assert.Contains(href, tree);
        var printer = new FixtureHandler(name => name == "DevMgmt_DiscoveryTree.xml" ? Encoding.UTF8.GetBytes(tree)
            : File.Exists(Path.Combine(m234dw, name)) ? File.ReadAllBytes(Path.Combine(m234dw, name)) : null);
        var other = false;
        var router = new HostRouter(new Dictionary<string, HttpMessageHandler>
        {
            [Host] = printer,
            ["192.0.2.200"] = new FixtureHandler(name =>
            {
                other = true;
                return Encoding.UTF8.GetBytes("<x>router admin page</x>");
            }),
        });
        var done = await ReportRecording.RunAsync(Host, _parent, new RecordOptions { Transport = router, Who = Me }, Now);

        Assert.False(other, "the recording asked another computer");
        Assert.DoesNotContain(done.Result.Files, f => f.Contains("secret", StringComparison.OrdinalIgnoreCase));
    }

    [Theory]
    [InlineData("/run.bat", "run.bat")]
    [InlineData("/C:/Users/Public/evil.xml", "C:_Users_Public_evil.xml")]
    public async Task A_printer_pointing_the_recorder_at_a_strange_path_stays_in_the_folder_and_keeps_nothing_that_runs(string href, string served)
    {
        // Its discovery tree says the status document is somewhere else: the app asks there, as it must to read the printer.
        var m234dw = FixtureDir("m234dw");
        var tree = File.ReadAllText(Path.Combine(m234dw, "DevMgmt_DiscoveryTree.xml")).Replace("/DevMgmt/ProductStatusDyn.xml", href);
        Assert.Contains(href, tree);
        var asked = false;
        var printer = new FixtureHandler(name =>
        {
            if (name == "DevMgmt_DiscoveryTree.xml") return Encoding.UTF8.GetBytes(tree);
            if (name == served)
            {
                asked = true;
                return File.ReadAllBytes(Path.Combine(m234dw, "DevMgmt_ProductStatusDyn.xml"));
            }
            return File.Exists(Path.Combine(m234dw, name)) ? File.ReadAllBytes(Path.Combine(m234dw, name)) : null;
        });
        var done = await ReportRecording.RunAsync(Host, _parent, new RecordOptions { Transport = At(Host, printer), Who = Me }, Now);

        Assert.True(asked);
        Assert.Equal([done.Folder], Directory.GetDirectories(_parent));
        Assert.All(Directory.GetFiles(done.Folder), f => Assert.Contains(Path.GetExtension(f), new[] { ".xml", ".json", ".txt", ".tsv" }));
        Assert.False(File.Exists(Path.Combine(done.Folder, "run.bat")));
    }
}
