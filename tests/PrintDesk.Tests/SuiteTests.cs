using PrintDesk.Core.Escl;
using PrintDesk.Core.Model;
using PrintDesk.Core.Suite;

namespace PrintDesk.Tests;

/// <summary>What the other Desk apps (PdfDesk) use: remembered printers, queue matching, health summary, scan options.</summary>
public class SuiteTests
{
    private const string Uuid = "12345678-1234-4abc-8def-123456789abc";

    private static DeskPrinters Known(params DeskPrinter[] printers) => new(printers, new Dictionary<string, string>());

    private static readonly DeskPrinter Hp = new(Uuid, "HP LaserJet MFP M234dw", "HP LaserJet MFP M234dw", "192.0.2.10",
        new Uri("http://192.0.2.10:8080/eSCL/"));

    [Fact]
    public void ReadsPrinterDeskState()
    {
        var state = DeskPrinters.Parse("""
            { "Printers": [
                { "Uuid": "12345678-1234-4abc-8def-123456789abc", "Name": "HP", "Model": null, "Host": "192.0.2.10", "EsclRoot": "http://192.0.2.10:8080/eSCL/" },
                { "Uuid": null, "Host": "10.0.0.2" },
                { "Uuid": "x", "Host": "", "Name": "no host" },
                { "Uuid": "b", "Host": "printer.local", "EsclRoot": "file:///c:/evil" } ],
              "QueueNames": { "b": "Office printer", "c": 5 } }
            """);
        Assert.Equal(2, state.Printers.Count);
        Assert.Equal(new Uri("http://192.0.2.10:8080/eSCL/"), state.Printers[0].EsclRoot);
        Assert.Null(state.Printers[1].EsclRoot); // only http(s) roots
        Assert.Equal("printer.local", state.Printers[1].Name); // nameless → host
        Assert.Equal("Office printer", state.QueueNames["B"]);
        Assert.Single(state.QueueNames);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[1,2]")]
    [InlineData("{\"Printers\": 5}")]
    public void BadStateReadsEmpty(string json) => Assert.Empty(DeskPrinters.Parse(json).Printers);

    [Fact]
    public void AppCandidatesStartWithThePackagedAlias()
    {
        var local = Path.Combine("C:", "Users", "u", "AppData", "Local");
        var (alias, folders) = DeskPaths.AppCandidates("PdfDesk.exe", local);
        Assert.Equal(Path.Combine(local, "Microsoft", "WindowsApps", "pdfdesk.exe"), alias);
        Assert.Equal([Path.Combine(local, "Programs", "Desk", "PdfDesk", "PdfDesk.exe"), Path.Combine(local, "Programs", "PdfDesk", "PdfDesk.exe")], folders);
    }

    [Fact]
    public void StateFilesIncludeThePackagedCopyAndTheNewestWins()
    {
        var local = Path.Combine(Path.GetTempPath(), "pd-" + Guid.NewGuid().ToString("N"));
        try
        {
            Assert.Empty(DeskPaths.StateFiles(local));
            Assert.Null(DeskPaths.CurrentStateFile(local));

            var plain = Path.Combine(local, "PrintDesk", "state.json");
            var packaged = Path.Combine(local, "Packages", "12345Example.PrintDesk_abcdefghjkmnp", "LocalCache", "Local", "PrintDesk", "state.json");
            var unrelated = Path.Combine(local, "Packages", "Other.App_abcdefghjkmnp", "LocalCache", "Local", "PrintDesk", "state.json");
            foreach (var f in new[] { plain, packaged, unrelated })
            {
                Directory.CreateDirectory(Path.GetDirectoryName(f)!);
                File.WriteAllText(f, "{}");
            }
            File.SetLastWriteTimeUtc(plain, DateTime.UtcNow.AddHours(-1));
            File.SetLastWriteTimeUtc(packaged, DateTime.UtcNow);

            Assert.Equal([plain, packaged], DeskPaths.StateFiles(local));
            Assert.Equal(packaged, DeskPaths.CurrentStateFile(local));

            File.SetLastWriteTimeUtc(plain, DateTime.UtcNow.AddHours(1));
            Assert.Equal(plain, DeskPaths.CurrentStateFile(local));
        }
        finally
        {
            Directory.Delete(local, recursive: true);
        }
    }

    [Fact]
    public void MissingStateFileReadsEmpty() =>
        Assert.Empty(DeskPrinters.Load(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "state.json")).Printers);

    [Fact]
    public void MatchesQueueByContainerId()
    {
        var other = Hp with { Uuid = Guid.NewGuid().ToString(), Host = "10.0.0.9", EsclRoot = null };
        var q = new QueueInfo("Some queue", "WSD-00000000-0000-4000-8000-000000000001", "{12345678-1234-4ABC-8DEF-123456789ABC}");
        Assert.Same(Hp, QueueMatch.Match(q, Known(other, Hp)));
    }

    [Fact]
    public void StoredAssociationWinsOverEverythingElse()
    {
        var other = new DeskPrinter(Guid.NewGuid().ToString(), "Other", null, "10.0.0.9", null);
        var known = new DeskPrinters([Hp, other], new Dictionary<string, string> { [other.Uuid] = "HP LaserJet MFP M234dw (ABCDEF)" });
        Assert.Same(other, QueueMatch.Match(new QueueInfo("HP LaserJet MFP M234dw (ABCDEF)", "192.0.2.10", Uuid), known));
    }

    [Theory]
    [InlineData("IP_192.0.2.10")]
    [InlineData("192.0.2.10")]
    [InlineData("192.0.2.10_1")]
    [InlineData("http://192.0.2.10:631/ipp/print")]
    [InlineData("ipps://192.0.2.10/ipp/print")]
    public void MatchesQueueByAddressInPort(string port) =>
        Assert.Same(Hp, QueueMatch.Match(new QueueInfo("Office", port), Known(Hp)));

    [Theory]
    [InlineData("IP_198.51.100.13")]
    [InlineData("IP_192.0.2.100")]
    [InlineData("WSD-00000000-0000-4000-8000-000000000001")]
    [InlineData("PORTPROMPT:")]
    public void OtherPortsDontMatch(string port) => Assert.Null(QueueMatch.Match(new QueueInfo("Office", port), Known(Hp)));

    [Fact]
    public void MatchesByHostNameFromTheEsclRoot()
    {
        var p = Hp with { Host = "192.168.1.7", EsclRoot = new Uri("https://npiabcdef.local/eSCL/") };
        Assert.Same(p, QueueMatch.Match(new QueueInfo("Office", "http://NPIABCDEF.local:631/ipp/print"), Known(p)));
    }

    [Fact]
    public void QueueNameMatchesOnlyWhenUnambiguous()
    {
        var q = new QueueInfo("HP LaserJet MFP M234dw (ABCDEF)", "WSD-1");
        Assert.Same(Hp, QueueMatch.Match(q, Known(Hp)));
        var twin = Hp with { Uuid = Guid.NewGuid().ToString(), Host = "10.0.0.3" };
        Assert.Null(QueueMatch.Match(q, Known(Hp, twin)));
        // "HP LaserJet MFP M234" must not match "HP LaserJet MFP M234dw (…)"
        Assert.Null(QueueMatch.Match(q, Known(Hp with { Name = "HP LaserJet MFP M234", Model = null })));
        Assert.Null(QueueMatch.Match(new QueueInfo("Microsoft Print to PDF", "PORTPROMPT:"), Known(Hp)));
    }

    [Fact]
    public void NoPrintersNoMatch() => Assert.Null(QueueMatch.Match(new QueueInfo("x", "IP_1.2.3.4", Uuid), DeskPrinters.Empty));

    private static Consumable Toner(int? pct, string state = "ok") =>
        new("Black toner", "toner", "K", pct, state, null, null, 10, null, null);

    [Fact]
    public void SleepingPrinterIsFineToPrintTo()
    {
        var h = PrinterHealth.From(new PrinterStatus("inPowerSave", "Ready", Severity.Info, []), [Toner(45)]);
        Assert.Equal(Readiness.Sleeping, h.State);
        Assert.False(h.ShouldWarn);
        Assert.Equal(45, h.TonerPercent);
        Assert.Equal("Sleeping · toner 45%", h.Summary);
    }

    [Fact]
    public void PaperProblemIsAnErrorWorthAWarning()
    {
        var status = new PrinterStatus("trayEmptyOrOpen", "Tray empty or open", Severity.Error,
            [new PrinterAlert("trayEmptyOrOpen", Severity.Error, "Tray empty or open"), new PrinterAlert("cartridgeLow", Severity.Warning, "Toner low")]);
        var h = PrinterHealth.From(status, [Toner(8, "low")]);
        Assert.Equal(Readiness.Error, h.State);
        Assert.True(h.ShouldWarn);
        Assert.Equal(["Tray empty or open"], h.PaperProblems);
        Assert.Equal(["Toner low"], h.Problems);
        Assert.Contains("Black toner: 8% (low)", h.Supplies);
    }

    [Fact]
    public void IppReasonsCountAsPaperProblems()
    {
        var status = new PrinterStatus("stopped", "Stopped", Severity.Error, [new PrinterAlert("media-jam", Severity.Error, "Media jam")]);
        var h = PrinterHealth.From(status, []);
        Assert.True(h.ShouldWarn);
        Assert.Equal(["Media jam"], h.PaperProblems);
        Assert.Null(h.TonerPercent);
    }

    [Fact]
    public void ScannerFeederJamIsNotAPaperProblem() => Assert.False(PrinterHealth.IsPaper("scannerAdfJam"));

    [Theory]
    [InlineData("offline", Severity.Error, Readiness.Offline, true)]
    [InlineData("unavailable", Severity.Info, Readiness.Unknown, false)]
    [InlineData("ready", Severity.Info, Readiness.Ready, false)]
    [InlineData("ready", Severity.Warning, Readiness.Attention, false)]
    [InlineData("processing", Severity.Info, Readiness.Busy, false)]
    [InlineData("stopped", Severity.Info, Readiness.Error, true)]
    public void ReadinessFromStatus(string code, Severity sev, Readiness expected, bool warn)
    {
        var h = PrinterHealth.From(new PrinterStatus(code, code, sev, []), []);
        Assert.Equal(expected, h.State);
        Assert.Equal(warn, h.ShouldWarn);
    }

    private static readonly InputCaps Platen = new(0, 2550, 0, 3508, ["RGB24", "Grayscale8"], ["image/jpeg"], [75, 100, 200, 300, 600], ["Document"]);
    private static readonly InputCaps Feeder = new(0, 2550, 0, 4200, ["Grayscale8"], ["image/jpeg"], [100, 200], ["Document"]);

    [Fact]
    public void ScanOptionsFollowTheSource()
    {
        var caps = new ScannerCapabilities("2.6", "HP", Uuid, Platen, Feeder, AdfDuplex: true);
        Assert.Equal([ScanSource.Platen, ScanSource.Adf, ScanSource.AdfDuplex], ScanChoices.Sources(caps));
        Assert.Equal("Document feeder (both sides)", ScanChoices.SourceLabel(ScanSource.AdfDuplex));

        // Glass: 150 isn't offered, so its nearest (100 or 200) stands in; duplicates collapse.
        Assert.Equal([100, 200, 300], ScanChoices.Resolutions(caps, ScanSource.Platen));
        Assert.Equal([100, 200], ScanChoices.Resolutions(caps, ScanSource.Adf));
        Assert.Equal([ScanColor.Color, ScanColor.Grayscale], ScanChoices.Colors(caps, ScanSource.Platen));
        Assert.Equal([ScanColor.Grayscale], ScanChoices.Colors(caps, ScanSource.AdfDuplex));

        // Legal (4200 high) fits only the feeder.
        Assert.DoesNotContain(ScanChoices.PageSizesFor(caps, ScanSource.Platen), p => p.Key == "legal");
        Assert.Contains(ScanChoices.PageSizesFor(caps, ScanSource.AdfDuplex), p => p.Key == "legal");
    }

    [Fact]
    public void ScannerWithoutListsTakesTheWantedValues()
    {
        var bare = new InputCaps(0, 2550, 0, 3300, [], [], [], []);
        var caps = new ScannerCapabilities("2.0", null, null, bare, null, false);
        Assert.Equal([150, 200, 300], ScanChoices.Resolutions(caps, ScanSource.Platen));
        Assert.Equal([ScanColor.Color, ScanColor.Grayscale], ScanChoices.Colors(caps, ScanSource.Platen));
        Assert.Equal(["letter", "full"], ScanChoices.PageSizesFor(caps, ScanSource.Platen).Select(p => p.Key));
        Assert.Equal(["full"], ScanChoices.PageSizesFor(caps, ScanSource.Adf).Select(p => p.Key));
    }

    [Fact]
    public void PageSizeDefaultsAndRequest()
    {
        var offered = ScanChoices.PageSizes;
        Assert.Equal("a4", ScanChoices.DefaultPageSize(offered, null, metric: true).Key);
        Assert.Equal("letter", ScanChoices.DefaultPageSize(offered, "bogus", metric: false).Key);
        Assert.Equal("legal", ScanChoices.DefaultPageSize(offered, "legal", metric: true).Key);

        var legal = offered.Single(p => p.Key == "legal");
        var req = ScanChoices.ToRequest(ScanSource.AdfDuplex, ScanColor.Grayscale, 200, legal);
        Assert.Equal(new ScanRequest(ScanSource.AdfDuplex, ScanColor.Grayscale, 200, "Document", 2550, 4200), req);

        // The request becomes eSCL settings the device accepts: duplex feeder, grayscale, its nearest resolution.
        var caps = new ScannerCapabilities("2.6", "HP", Uuid, Platen, Feeder, AdfDuplex: true);
        var xml = EsclXml.BuildScanSettings(req, caps).ToString();
        Assert.Contains("Feeder", xml);
        Assert.Contains("<scan:Duplex>true</scan:Duplex>", xml);
        Assert.Contains("Grayscale8", xml);
        Assert.Contains("<scan:XResolution>200</scan:XResolution>", xml);
        Assert.Contains("<pwg:Height>4200</pwg:Height>", xml);

        var whole = ScanChoices.ToRequest(ScanSource.Platen, ScanColor.Color, 300, offered[^1]);
        Assert.Null(whole.Width);
        Assert.Null(whole.Height);
    }
}
