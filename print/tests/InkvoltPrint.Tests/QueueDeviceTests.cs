using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>
/// Queue printers that say more than the spooler: route 1, the printer's own IPP attributes through Windows' IPP class driver
/// (IPP over USB included), read with the network printers' IPP mapping; the decorator that asks, times out, and stays quiet
/// when a queue has nothing to say.
/// </summary>
public class QueueDeviceTests
{
    private static string FixtureText => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo", "ipp_print.ipp.txt"));

    /// <summary>The printer-attributes group as Windows hands it over: the fixture's response without its header, operation group and end tag.</summary>
    internal static byte[] AttributesGroup(string ippText, bool withTag = true)
    {
        var full = IppCodec.EncodeResponse(0, 1, IppText.Parse(ippText));
        var i = 9; // header, operation-attributes tag
        for (var n = 0; n < 2; n++) // attributes-charset, attributes-natural-language
        {
            var nameLen = (full[i + 1] << 8) | full[i + 2];
            var valLen = (full[i + 3 + nameLen] << 8) | full[i + 4 + nameLen];
            i += 5 + nameLen + valLen;
        }
        Assert.Equal(0x04, full[i]);
        return full[(withTag ? i : i + 1)..^1];
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void AnIppUsbPrintersAttributesReadAsANetworkPrintersDo(bool withTag)
    {
        var r = IppQueueReading.From(AttributesGroup(FixtureText, withTag), usb: true);

        Assert.NotNull(r);
        Assert.Equal(QueueReadingFrom.PrinterOverUsb, r.From);
        Assert.Equal("ready", r.Status!.Code);
        Assert.Contains(r.Status.Alerts, a => a.Id == "marker-supply-low" && a.Severity == Severity.Warning);
        Assert.Equal(["Black ink", "Cyan ink", "Magenta ink", "Yellow ink", "Maintenance box"], r.Supplies.Select(s => s.Name));
        Assert.Equal([72, 55, 63, 12], r.Supplies.Take(4).Select(s => s.PercentRemaining!.Value));
        Assert.Equal("low", r.Supplies[3].State);
        Assert.Equal("K", r.Supplies[0].ColorCode);
        Assert.Null(r.Supplies[4].PercentRemaining); // a waste box: no percentage
    }

    [Fact]
    public void ANetworkIppQueueSaysItCameThroughWindows()
    {
        var r = IppQueueReading.From(AttributesGroup(FixtureText), usb: false);
        Assert.Equal(QueueReadingFrom.PrinterThroughWindows, r!.From);
        Assert.Equal("From the printer, through Windows", QueueDeviceText.Source(r.From));
        Assert.Equal("From the printer over USB", QueueDeviceText.Source(QueueReadingFrom.PrinterOverUsb));
    }

    [Fact]
    public void IllFormedOrHostileAttributeBytesGiveNothing()
    {
        var good = AttributesGroup(FixtureText);
        Assert.Null(IppQueueReading.From([], usb: true));
        Assert.Null(IppQueueReading.From(good[..^7], usb: true)); // cut short
        Assert.Null(IppQueueReading.From(new byte[IppQueueReading.MaxBytes + 1], usb: true)); // too big to be one
        Assert.Null(IppQueueReading.From(Enumerable.Repeat((byte)0xFF, 300).ToArray(), usb: true));
        Assert.Null(IppQueueReading.From(AttributesGroup("printer-name name Somebody's printer"), usb: true)); // neither state nor supplies
        // Wrong types: a level as text, a state as a keyword. Read as unknown, never thrown.
        var odd = IppQueueReading.From(AttributesGroup("printer-state keyword idle\nmarker-names name Black\nmarker-levels keyword full"), usb: true);
        Assert.NotNull(odd);
        Assert.Null(odd.Status); // no state it can read: Windows' stands (APrinterWithNoStateLeavesWindowsHeadline)
        Assert.Equal("unknown", odd.Supplies.Single().State);
        Assert.Null(odd.Supplies.Single().PercentRemaining);
    }

    [Fact]
    public void AHostilePrintersFloodOfSuppliesAndProblemsIsCut()
    {
        var text = "printer-state enum 3\n" + string.Join("\n", Enumerable.Range(0, 1500).Select(i => $"marker-names name Supply {i}"))
            + "\n" + string.Join("\n", Enumerable.Range(0, 1500).Select(i => $"printer-state-reasons keyword made-up-{i}-error"))
            + "\n" + string.Join("\n", Enumerable.Range(0, 1500).Select(i => $"printer-alert octetString code=made-up-alert-{i};severity=critical"));

        var r = IppQueueReading.From(AttributesGroup(text), usb: true);

        Assert.Equal(IppClient.MaxSupplies, r!.Supplies.Count);
        Assert.Equal("Supply 0", r.Supplies[0].Name);
        Assert.True(r.Status!.Alerts.Count <= 2 * IppClient.MaxAlerts, $"{r.Status.Alerts.Count} alerts");
        Assert.Equal(Severity.Error, r.Status.Severity);
    }

    [Fact]
    public void ItAsksForNoIdentifiers()
    {
        Assert.DoesNotContain(IppQueueReading.Attributes, a => a.Contains("uuid") || a.Contains("serial") || a.Contains("uri")
            || a.Contains("name", StringComparison.Ordinal) && a != "marker-names" || a.Contains("location") || a.Contains("info"));
    }

    // ---------------------------------------------------------------- the decorator

    internal sealed class FixedWindows(PrinterStatus status, bool offline = false) : IQueueStatusSource
    {
        public string Origin => "Windows and the printer's driver";
        public bool HasSupplyLevels => false;
        public Task<QueueStatusRead?> ReadAsync(CancellationToken ct) => Task.FromResult<QueueStatusRead?>(new QueueStatusRead(status, offline, []));
    }

    internal sealed class Reader(Func<CancellationToken, Task<QueueDeviceReading?>> read) : IQueueDeviceReader
    {
        public int Calls { get; private set; }

        public Task<QueueDeviceReading?> ReadAsync(CancellationToken ct)
        {
            Calls++;
            return read(ct);
        }
    }

    internal static readonly PrinterStatus Ready = new("ready", "Ready", Severity.Info, [], null);

    [Fact]
    public async Task AQueueWithAnIppUsbPrinterShowsItsSuppliesAndStatus()
    {
        var reading = IppQueueReading.From(AttributesGroup(FixtureText), usb: true);
        var source = new DeviceQueueStatusSource(new FixedWindows(Ready with { Detail = "2 jobs waiting." }), [new Reader(_ => Task.FromResult(reading))]);

        var read = await source.ReadAsync(CancellationToken.None);

        Assert.Equal(5, read!.Supplies.Count);
        Assert.Equal(Severity.Warning, read.Status.Severity);
        Assert.Contains("2 jobs waiting.", read.Status.Detail);
        Assert.True(source.HasSupplyLevels);
        Assert.Equal(QueueReadingFrom.PrinterOverUsb, source.From);
        Assert.Equal("the printer over USB (IPP, through Windows)", source.Origin);
    }

    [Theory]
    [InlineData("marker-names name Black\nmarker-levels integer 40")] // no printer-state
    [InlineData("printer-state keyword idle\nmarker-names name Black\nmarker-levels integer 40")] // not an enum
    [InlineData("printer-state enum 9\nmarker-names name Black\nmarker-levels integer 40")] // not a state IPP has
    public async Task APrinterWithNoStateLeavesWindowsHeadline(string attributes)
    {
        var reading = IppQueueReading.From(AttributesGroup(attributes), usb: true);
        var jam = new PrinterStatus("media-jam", "Paper jam", Severity.Error, [], "Clear the jam.");
        var source = new DeviceQueueStatusSource(new FixedWindows(jam), [new Reader(_ => Task.FromResult(reading))]);

        var read = await source.ReadAsync(CancellationToken.None);

        Assert.Equal("Paper jam", read!.Status.Message); // not "Unknown", with nothing wrong
        Assert.Equal(Severity.Error, read.Status.Severity);
        Assert.Equal(40, read.Supplies.Single().PercentRemaining);
    }

    [Fact]
    public async Task AProblemFromAPrinterWithNoStateIsStillAdded()
    {
        var reading = IppQueueReading.From(AttributesGroup("printer-state-reasons keyword media-jam-error\nmarker-names name Black"), usb: true);
        var source = new DeviceQueueStatusSource(new FixedWindows(Ready), [new Reader(_ => Task.FromResult(reading))]);

        var read = await source.ReadAsync(CancellationToken.None);

        Assert.Equal("Ready", read!.Status.Message);
        Assert.Equal(Severity.Error, read.Status.Severity);
        Assert.Contains(read.Status.Alerts, a => a.Id == "media-jam");
    }

    [Fact]
    public async Task WindowsHoldingTheJobsStaysTheHeadline()
    {
        var reading = IppQueueReading.From(AttributesGroup(FixtureText), usb: true);
        var paused = new PrinterStatus("paused", "Paused", Severity.Warning, [], "Printing is paused in Windows.");
        var source = new DeviceQueueStatusSource(new FixedWindows(paused), [new Reader(_ => Task.FromResult(reading))]);

        var read = await source.ReadAsync(CancellationToken.None);

        Assert.Equal("Paused", read!.Status.Message);
        Assert.Contains(read.Status.Alerts, a => a.Id == "marker-supply-low");
        Assert.Equal(5, read.Supplies.Count);
    }

    [Fact]
    public async Task NotReportedWhenNoRouteAnswersAndAskedAgainOnlyMinutesLater()
    {
        var now = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        var ipp = new Reader(_ => Task.FromResult<QueueDeviceReading?>(null));
        var driver = new Reader(_ => Task.FromResult<QueueDeviceReading?>(new QueueDeviceReading(QueueReadingFrom.Driver, null, [], [])));
        var source = new DeviceQueueStatusSource(new FixedWindows(Ready), [ipp, driver]) { Now = () => now };

        var read = await source.ReadAsync(CancellationToken.None);
        Assert.Empty(read!.Supplies);
        Assert.Equal("Ready", read.Status.Message);
        Assert.Null(source.From);
        Assert.False(source.HasSupplyLevels);
        Assert.Equal("Windows and the printer's driver", source.Origin);

        now += TimeSpan.FromMinutes(4);
        await source.ReadAsync(CancellationToken.None);
        Assert.Equal((1, 1), (ipp.Calls, driver.Calls));
        now += TimeSpan.FromMinutes(1);
        await source.ReadAsync(CancellationToken.None);
        Assert.Equal((2, 2), (ipp.Calls, driver.Calls));
    }

    [Fact]
    public async Task AnAnsweringPrinterIsReadEvery30SecondsAndTheFirstRouteWins()
    {
        var now = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        var reading = IppQueueReading.From(AttributesGroup(FixtureText), usb: true);
        var ipp = new Reader(_ => Task.FromResult(reading));
        var driver = new Reader(_ => throw new InvalidOperationException("never asked"));
        var source = new DeviceQueueStatusSource(new FixedWindows(Ready), [ipp, driver]) { Now = () => now };

        await source.ReadAsync(CancellationToken.None);
        now += TimeSpan.FromSeconds(10);
        Assert.Equal(5, (await source.ReadAsync(CancellationToken.None))!.Supplies.Count); // the last reading stands
        Assert.Equal(1, ipp.Calls);
        now += TimeSpan.FromSeconds(25);
        await source.ReadAsync(CancellationToken.None);
        Assert.Equal((2, 0), (ipp.Calls, driver.Calls));
    }

    [Fact]
    public async Task AReaderThatHangsOrThrowsIsCutOffAndTheNextAsked()
    {
        var hangs = new Reader(async ct => { await Task.Delay(Timeout.Infinite, CancellationToken.None); return null; }); // ignores its token
        var throws = new Reader(_ => throw new System.Runtime.InteropServices.COMException("bidi"));
        var answers = new Reader(_ => Task.FromResult<QueueDeviceReading?>(new QueueDeviceReading(QueueReadingFrom.Driver, null, [],
            [new Consumable("Black toner", "toner", "K", 40, "ok", null, null, null, null, null)])));
        var source = new DeviceQueueStatusSource(new FixedWindows(Ready), [hangs, throws, answers]) { Limit = TimeSpan.FromMilliseconds(100) };

        var started = DateTime.UtcNow;
        var read = await source.ReadAsync(CancellationToken.None);

        Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(5));
        Assert.Equal("Black toner", read!.Supplies.Single().Name);
        Assert.Equal("the printer's driver", source.Origin);
    }

    [Fact]
    public async Task ARemovedQueueIsStillReportedRemoved()
    {
        var gone = new GoneQueue();
        var reader = new Reader(_ => throw new InvalidOperationException("not asked for a removed queue"));
        Assert.Null(await new DeviceQueueStatusSource(gone, [reader]).ReadAsync(CancellationToken.None));
        Assert.Equal(0, reader.Calls);
    }

    private sealed class GoneQueue : IQueueStatusSource
    {
        public string Origin => "Windows";
        public bool HasSupplyLevels => false;
        public Task<QueueStatusRead?> ReadAsync(CancellationToken ct) => Task.FromResult<QueueStatusRead?>(null);
    }

    [Fact]
    public async Task AnOfflineQueueKeepsItsHeadlineWithTheLastSupplies()
    {
        var reading = IppQueueReading.From(AttributesGroup(FixtureText), usb: true);
        var offline = new PrinterStatus("offline", "Offline", Severity.Error, [], "Windows can't reach it.");
        var read = await new DeviceQueueStatusSource(new FixedWindows(offline, offline: true), [new Reader(_ => Task.FromResult(reading))])
            .ReadAsync(CancellationToken.None);
        Assert.True(read!.Offline);
        Assert.Equal("Offline", read.Status.Message);
        Assert.Equal(Severity.Error, read.Status.Severity);
        Assert.Equal(5, read.Supplies.Count);
    }
}
