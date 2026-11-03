using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>
/// Route 2: a queue printer's driver asked over Windows' bidirectional printing (bidi). Replies are handwritten in the shapes of
/// Microsoft's schema docs ("Constructing a Bidi Communication Schema Query", the Consumables and Summary reference pages): names
/// are the vendor's, values typed; anything else, hostile or merely odd, is nothing rather than an error.
/// </summary>
public class QueueBidiTests
{
    private const string Ns = "http://schemas.microsoft.com/windows/2005/03/printing/bidi";

    private static string Get(string queries) => $"<bidi:Get xmlns:bidi=\"{Ns}\">{queries}</bidi:Get>";

    private static string Value(string schema, string type, string value) => $"<Schema name=\"{schema}\"><{type}>{value}</{type}></Schema>";

    private static string Consumable(string name, string type, string? color, int level) =>
        Value($@"\Printer.Consumables.{name}:Type", "BIDI_ENUM", type)
        + (color is null ? "" : Value($@"\Printer.Consumables.{name}:Color", "BIDI_STRING", color))
        + Value($@"\Printer.Consumables.{name}:Level", "BIDI_INT", level.ToString());

    private static string Supplies(string inner) => Get($@"<Query schema=""\Printer.Consumables"">{inner}</Query>");

    private static string Status(string reasons, string state = "Idle") => Get(
        $@"<Query schema=""\Printer.Status.Summary"">{Value(@"\Printer.Status.Summary:State", "BIDI_ENUM", state)}{Value(@"\Printer.Status.Summary:StateReason", "BIDI_STRING", reasons)}</Query>");

    [Fact]
    public void ADriversConsumablesReadAsSupplies()
    {
        var r = BidiQueueReading.From([Supplies(
            Consumable("Blk3E", "Toner", "Black", 42) + Consumable("Cyn3E", "Toner", "Cyan", 100)
            + Consumable("Mgt", "Ink", "Magenta", 0) + Consumable("Yel", "Ink", "Yellow", -1)
            + Value(@"\Printer.Consumables.Blk3E:Model", "BIDI_STRING", "CF217A")
            + Value(@"\Printer.Consumables.Blk3E:Installed", "BIDI_BOOL", "true"))]);

        Assert.NotNull(r);
        Assert.Equal(QueueReadingFrom.Driver, r.From);
        Assert.Null(r.Status);
        Assert.Equal(["Black toner", "Cyan toner", "Magenta ink", "Yellow ink"], r.Supplies.Select(s => s.Name));
        Assert.Equal(["K", "C", "M", "Y"], r.Supplies.Select(s => s.ColorCode));
        Assert.Equal(new int?[] { 42, 100, 0, null }, r.Supplies.Select(s => s.PercentRemaining));
        Assert.Equal(["ok", "ok", "out", "unknown"], r.Supplies.Select(s => s.State));
        Assert.Equal("CF217A", r.Supplies[0].ProductNumber);
        Assert.Equal("toner", r.Supplies[0].Kind);
    }

    [Theory]
    [InlineData(11, "ok")]
    [InlineData(10, "low")]
    [InlineData(1, "low")]
    [InlineData(0, "out")]
    public void TheSchemaHasNoLowMarkSoTenPercentIsOne(int level, string state)
    {
        Assert.Equal(state, BidiQueueReading.From([Supplies(Consumable("K", "Toner", "Black", level))])!.Supplies.Single().State);
    }

    [Fact]
    public void TheDocsNamespaceSpellingAndABareRootReadTheSame()
    {
        var inner = $@"<Query schema=""\Printer.Consumables"">{Consumable("K", "Toner", "Black", 5)}</Query>";
        foreach (var xml in new[]
                 {
                     $"<bidi:Get xmlns:bidi=\"https://schemas.microsoft.com/windows/2005/03/printing/bidi\">{inner}</bidi:Get>",
                     $"<Get>{inner}</Get>",
                 })
            Assert.Equal(5, BidiQueueReading.From([xml])!.Supplies.Single().PercentRemaining);
    }

    [Fact]
    public void WasteBoxesGetNoPercentageAndAnUninstalledSupplyIsLeftOut()
    {
        var r = BidiQueueReading.From([Supplies(
            Consumable("Bin", "WasteToner", null, 30)
            + Consumable("Fuser", "FuserOil", null, 60)
            + Consumable("Dev", "Developer", null, 70)
            + Consumable("Gone", "Toner", "Yellow", 90) + Value(@"\Printer.Consumables.Gone:Installed", "BIDI_BOOL", "false"))]);

        Assert.Equal(["Waste toner", "Fuser oil", "Developer"], r!.Supplies.Select(s => s.Name));
        Assert.True(r.Supplies[0].IsWaste);
        Assert.Null(r.Supplies[0].PercentRemaining);
        Assert.Equal(60, r.Supplies[1].PercentRemaining);
    }

    [Fact]
    public void AVendorsOwnWordsKeepToSafeOnesAndNamesStayApart()
    {
        var r = BidiQueueReading.From([Supplies(
            Consumable("HighYield", "Toner", "Black", 50) + Consumable("Standard", "Toner", "Black", 60)
            + Consumable("Mystery", "Unobtainium", "Teal", 70)
            + Value(@"\Printer.Consumables.OnlyLevel:Level", "BIDI_INT", "80"))]);

        Assert.Equal(["Black toner", "Black toner (Standard)", "Teal supply", "OnlyLevel"], r!.Supplies.Select(s => s.Name));
        Assert.Equal("Black toner (Standard)", r.Supplies[1].Key);
        Assert.Equal("supply", r.Supplies[2].Kind);
        Assert.Null(r.Supplies[2].ColorCode);
    }

    [Fact]
    public void AStatusReasonBecomesAlertsInTheAppsOwnWords()
    {
        var r = BidiQueueReading.From([Status("MarkerSupplyLow DoorOpen None Vendor&lt;Secret&gt;Reason", "Stopped")]);

        Assert.NotNull(r);
        Assert.Null(r.Status); // Windows' status keeps the headline
        Assert.Equal(["marker-supply-low", "door-open"], r.Alerts.Select(a => a.Id));
        Assert.Equal(Severity.Warning, r.Alerts[0].Severity);
        Assert.Equal(Severity.Error, r.Alerts[1].Severity);
        Assert.Empty(r.Supplies);
        Assert.Equal("user-intervention", BidiQueueReading.From([Status("AttentionRequired")])!.Alerts.Single().Id);
        Assert.Null(BidiQueueReading.From([Status("None")]));
        Assert.Null(BidiQueueReading.From([Status("SomethingElseEntirely")]));
    }

    [Fact]
    public void BothRepliesMakeOneReadingAndAFailedOneCostsNothing()
    {
        var r = BidiQueueReading.From([null, Supplies(Consumable("K", "Toner", "Black", 9)), Status("MediaLow"), "<not xml"]);
        Assert.Equal(9, r!.Supplies.Single().PercentRemaining);
        Assert.Equal("media-low", r.Alerts.Single().Id);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not xml at all")]
    [InlineData("<bidi:Get xmlns:bidi=\"" + Ns + "\">")] // cut short
    [InlineData("<Other><Query><Schema name=\"\\Printer.Consumables.K:Level\"><BIDI_INT>5</BIDI_INT></Schema></Query></Other>")] // not a Get
    [InlineData("<Get/>")]
    [InlineData("<Get><Query schema=\"\\Printer.Consumables\"/></Get>")] // the shape of an unsupported query
    [InlineData("<Get><Schema name=\"\\Printer.Consumables.K:Level\"><BIDI_INT>5</BIDI_INT></Schema></Get>")] // wrong depth
    [InlineData("<!DOCTYPE Get [<!ENTITY a \"aaaaaaaa\">]><Get><Query><Schema name=\"\\Printer.Consumables.K:Level\"><BIDI_INT>5</BIDI_INT></Schema></Query></Get>")]
    public void IllFormedRepliesGiveNothing(string xml)
    {
        Assert.Null(BidiQueueReading.From([xml]));
    }

    /// <summary>What Windows really answers for a driver without these schemas (this PC's WSD queues, 2026-11-03): error 13005, ERROR_BIDI_SCHEMA_NOT_SUPPORTED.</summary>
    [Fact]
    public void WindowsRealAnswerForAnUnsupportedSchemaIsNothing()
    {
        Assert.Null(BidiQueueReading.From([
            $"""<bidi:Get xmlns:bidi="{Ns}"><Query schema="\Printer.Consumables"><Error>13005</Error></Query></bidi:Get>""",
            $"""<bidi:Get xmlns:bidi="{Ns}"><Query schema="\Printer.Status.Summary"><Error>13005</Error></Query></bidi:Get>""",
        ]));
    }

    [Fact]
    public void AnEntityBombAndExternalEntitiesAreRefused()
    {
        const string bomb = """
            <?xml version="1.0"?><!DOCTYPE Get [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>
            <Get><Query><Schema name="\Printer.Consumables.K:Color"><BIDI_STRING>&c;</BIDI_STRING></Schema></Query></Get>
            """;
        const string external = """
            <!DOCTYPE Get [<!ENTITY x SYSTEM "file:///c:/windows/win.ini">]>
            <Get><Query><Schema name="\Printer.Consumables.K:Color"><BIDI_STRING>&x;</BIDI_STRING></Schema></Query></Get>
            """;
        Assert.Null(BidiQueueReading.From([bomb]));
        Assert.Null(BidiQueueReading.From([external]));
    }

    [Fact]
    public void AHugeReplyIsNotRead()
    {
        var padding = new string(' ', BidiQueueReading.MaxChars);
        Assert.Null(BidiQueueReading.From([Supplies(Consumable("K", "Toner", "Black", 5)) + padding]));
    }

    [Fact]
    public void TooManySchemasOrSuppliesAreCappedNotFollowed()
    {
        var many = string.Concat(Enumerable.Range(0, 500).Select(i => Value($@"\Printer.Consumables.S{i}:Level", "BIDI_INT", "50")));
        var r = BidiQueueReading.From([Supplies(many)]);
        Assert.Equal(BidiQueueReading.MaxSupplies, r!.Supplies.Count);

        var deep = string.Concat(Enumerable.Repeat("<a>", 5000)) + string.Concat(Enumerable.Repeat("</a>", 5000));
        Assert.Null(BidiQueueReading.From([$"<Get>{deep}</Get>"]));
    }

    [Theory]
    [InlineData("BIDI_STRING", "40")] // wrong type
    [InlineData("BIDI_INT", "101")] // out of range
    [InlineData("BIDI_INT", "-7")]
    [InlineData("BIDI_INT", "99999999999999999999")]
    [InlineData("BIDI_INT", "12.5")]
    [InlineData("BIDI_INT", "")]
    [InlineData("BIDI_BOOL", "true")]
    public void AWrongLevelReadsAsUnknown(string type, string value)
    {
        var r = BidiQueueReading.From([Supplies(Value(@"\Printer.Consumables.K:Type", "BIDI_ENUM", "Toner") + Value(@"\Printer.Consumables.K:Level", type, value))]);
        Assert.Null(r!.Supplies.Single().PercentRemaining);
        Assert.Equal("unknown", r.Supplies.Single().State);
    }

    [Theory]
    [InlineData(@"\Printer.Consumables.K<x>:Level")]
    [InlineData(@"\Printer.Consumables.has space:Level")]
    [InlineData(@"\Printer.Consumables.K.Sub:Level")]
    [InlineData(@"\Printer.Consumables.K:Serial")]
    [InlineData(@"\Printer.DeviceInfo:IEEE1284DeviceId")]
    [InlineData(@"\Printer.Consumables")]
    [InlineData("anything")]
    public void SchemasOutsideWhatWasAskedAreIgnored(string name)
    {
        var xml = Get($"<Query>{Value(name.Replace("<", "&lt;").Replace(">", "&gt;"), "BIDI_INT", "50")}</Query>");
        Assert.Null(BidiQueueReading.From([xml]));
    }

    [Fact]
    public void AHostileModelOrColorIsDropped()
    {
        var r = BidiQueueReading.From([Supplies(
            Value(@"\Printer.Consumables.K:Type", "BIDI_ENUM", "Toner")
            + Value(@"\Printer.Consumables.K:Color", "BIDI_STRING", "&lt;script&gt;alert(1)&lt;/script&gt;")
            + Value(@"\Printer.Consumables.K:Model", "BIDI_STRING", new string('A', 300))
            + Value(@"\Printer.Consumables.K:Level", "BIDI_INT", "50"))]);
        var s = r!.Supplies.Single();
        Assert.Equal("Toner", s.Name);
        Assert.Null(s.ColorCode);
        Assert.Null(s.ProductNumber);
    }

    [Fact]
    public void TheRequestsAskOnlyForSuppliesAndStatusNeverIdentifiersNorChanges()
    {
        Assert.All(BidiQueueReading.Requests, x =>
        {
            Assert.StartsWith("<bidi:Get ", x); // Get only: never a Set
            Assert.DoesNotContain("DeviceInfo", x);
            Assert.DoesNotContain("Configuration", x);
        });
        Assert.Contains(BidiQueueReading.Requests, x => x.Contains(@"schema=""\Printer.Consumables"""));
        Assert.Contains(BidiQueueReading.Requests, x => x.Contains(@"schema=""\Printer.Status.Summary"""));
    }

    // ---------------------------------------------------------------- which route, and how it merges

    private static QueueDeviceReading DriverReading() =>
        BidiQueueReading.From([Supplies(Consumable("K", "Toner", "Black", 40)), Status("MarkerSupplyLow")])!;

    [Fact]
    public async Task TheDriverIsAskedOnlyWhenIppHasNothingAndTheCardSaysWhere()
    {
        var ipp = new QueueDeviceTests.Reader(_ => Task.FromResult<QueueDeviceReading?>(null));
        var driver = new QueueDeviceTests.Reader(_ => Task.FromResult<QueueDeviceReading?>(DriverReading()));
        var source = new DeviceQueueStatusSource(new QueueDeviceTests.FixedWindows(QueueDeviceTests.Ready), [ipp, driver]);

        var read = await source.ReadAsync(CancellationToken.None);

        Assert.Equal((1, 1), (ipp.Calls, driver.Calls));
        Assert.Equal(40, read!.Supplies.Single().PercentRemaining);
        Assert.Equal(QueueReadingFrom.Driver, source.From);
        Assert.Equal("From its driver", QueueDeviceText.Source(source.From!.Value));
        Assert.Equal("Ready", read.Status.Message); // an alert adds to Windows' status, doesn't replace it
        Assert.Equal(Severity.Warning, read.Status.Severity);
    }

    [Fact]
    public async Task IppAnsweringMeansTheDriverIsNotAsked()
    {
        var bytes = QueueDeviceTests.AttributesGroup("printer-state enum 3\nmarker-names name Black\nmarker-levels integer 70");
        var ipp = new QueueDeviceTests.Reader(_ => Task.FromResult(IppQueueReading.From(bytes, usb: true)));
        var driver = new QueueDeviceTests.Reader(_ => Task.FromResult<QueueDeviceReading?>(DriverReading()));
        var source = new DeviceQueueStatusSource(new QueueDeviceTests.FixedWindows(QueueDeviceTests.Ready), [ipp, driver]);

        await source.ReadAsync(CancellationToken.None);

        Assert.Equal((1, 0), (ipp.Calls, driver.Calls));
        Assert.Equal(QueueReadingFrom.PrinterOverUsb, source.From);
    }

    [Fact]
    public async Task AnUnsupportedDriverLeavesNotReportedAndIsAskedMinutesLater()
    {
        var now = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        var driver = new QueueDeviceTests.Reader(_ => Task.FromResult(BidiQueueReading.From([null, null])));
        var source = new DeviceQueueStatusSource(new QueueDeviceTests.FixedWindows(QueueDeviceTests.Ready), [driver]) { Now = () => now };

        var read = await source.ReadAsync(CancellationToken.None);
        Assert.Empty(read!.Supplies);
        Assert.Null(source.From);
        now += TimeSpan.FromMinutes(1);
        await source.ReadAsync(CancellationToken.None);
        Assert.Equal(1, driver.Calls);
    }

    [Fact]
    public async Task ADriverThatHangsIsCutOffAndTheWindowsStatusStands()
    {
        var hangs = new QueueDeviceTests.Reader(async _ => { await Task.Delay(Timeout.Infinite, CancellationToken.None); return null; });
        var source = new DeviceQueueStatusSource(new QueueDeviceTests.FixedWindows(QueueDeviceTests.Ready), [hangs]) { Limit = TimeSpan.FromMilliseconds(100) };
        var read = await source.ReadAsync(CancellationToken.None);
        Assert.Equal("Ready", read!.Status.Message);
        Assert.Empty(read.Supplies);
    }

    [Fact]
    public async Task ADriversProblemWindowsAlreadySaysIsNotSaidTwice()
    {
        var windows = new PrinterStatus("paused", "Paused", Severity.Warning,
            [new PrinterAlert("toner-low", Severity.Warning, "Toner low"), new PrinterAlert("no-toner", Severity.Error, "Out of toner"), new PrinterAlert("output-bin-full", Severity.Error, "Output bin full")]);
        var reading = BidiQueueReading.From([Status("MarkerSupplyLow MarkerSupplyEmpty OutputAreaFull Paused MediaJam")]);
        var read = await new DeviceQueueStatusSource(new QueueDeviceTests.FixedWindows(windows), [new QueueDeviceTests.Reader(_ => Task.FromResult(reading))])
            .ReadAsync(CancellationToken.None);

        Assert.Equal(["toner-low", "no-toner", "output-bin-full", "media-jam"], read!.Status.Alerts.Select(a => a.Id));
    }

    // ---------------------------------------------------------------- the queues asked

    private static SpoolerQueue Queue(string name, string driver, string monitor = "USB Monitor") =>
        new(name, "USB001", driver, 0, SpoolerFlags.AttributeLocal, 0) { PortMonitor = monitor };

    [Fact]
    public void AMakersDriverIsAskedTheIppClassDriverAndVirtualPrintersAreNot()
    {
        Assert.True(BidiQueueReading.WorthAsking(Queue("HP LaserJet", "HP LaserJet Pro M404 PCL 6")));
        Assert.True(BidiQueueReading.WorthAsking(Queue("EPSON", "EPSON ET-2850 Series")));
        Assert.False(BidiQueueReading.WorthAsking(Queue("M234", "Microsoft IPP Class Driver", "WSD Port Monitor")));
        Assert.False(BidiQueueReading.WorthAsking(Queue("Microsoft Print to PDF", "Microsoft Print To PDF", "Local Monitor")));
    }

    // ---------------------------------------------------------------- demo mode

    [Fact]
    public async Task TheDemoUsbLasersDriverReportsTonerAndTheOtherDemoQueuesNothing()
    {
        var usb = DemoFleet.Queues.Single(q => q.Name == "Demo USB laser");
        var reading = await DemoFleet.DeviceReaders(usb).Single().ReadAsync(CancellationToken.None);

        Assert.Equal(QueueReadingFrom.Driver, reading!.From);
        Assert.Equal("Black toner", reading.Supplies.Single().Name);
        Assert.Equal("K", reading.Supplies.Single().ColorCode);
        Assert.Equal("low", reading.Supplies.Single().State); // 8%: never reads OK beside "toner low"
        Assert.Empty(DemoFleet.DeviceReaders(DemoFleet.Queues.Single(q => q.Name.Contains("Front desk"))));
    }
}
