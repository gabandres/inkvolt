using InkvoltPrint.Core;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Twain;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Tests;

/// <summary>
/// TWAIN sources in Inkvolt Print's printer list and Scan tab (roadmap 2.5): listed beside WIA through one <see cref="DriverScanners"/>,
/// matched to printers, scanned through the same <see cref="WiaScanner"/> path; a fake source (<see cref="FakeTwain"/>, the
/// FakeWiaSystem's twin) for capabilities, a feeder run, an empty feeder, cancel and a hang. Black and white as the tab's color choice.
/// </summary>
public class TwainTests
{
    private static readonly WiaDeviceInfo UsbMfp = new(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0000", "EPSON Perfection V600 Photo", "EPSON", "EPSON Perfection V600 Photo", @"\\.\Usbscan0");

    /// <summary>A flatbed with a feeder (both sides), black and white, grey and color, 100–600 dpi, 8.5 × 14 in.</summary>
    private static readonly TwainCaps DocScanner = new(Feeder: true, FeederOnly: false, Duplex: true, FeederLoaded: false,
        [Tw.PtBw, Tw.PtGray, Tw.PtRgb], WiaValues.Of(300, 100, 200, 300, 600), 8.5, 14);

    /// <summary>A film scanner: glass only, grey and color, a range of resolutions.</summary>
    private static readonly TwainCaps FilmScanner = new(false, false, false, false, [Tw.PtGray, Tw.PtRgb], WiaValues.Range(1200, 300, 7200, 1), 8.5, 11.7);

    private static byte[] Draw(WiaScanSettings s, int page) => [0xFF, 0xD8, (byte)page, (byte)s.DataType];

    private static FakeWiaScanner Wia(WiaDeviceInfo device) => new(device,
        new WiaScannerInfo(null, 8500, 11700, null, null, WiaValues.Of(300, 300), [WiaIds.DataColor], [WiaIds.FormatBmp]), Draw);

    private static async Task<List<byte[]>> All(IAsyncEnumerable<byte[]> pages)
    {
        var list = new List<byte[]>();
        await foreach (var p in pages) list.Add(p);
        return list;
    }

    private static async Task<WiaScanner> Open(FakeWiaScanner source)
    {
        var system = new DriverScanners(new FakeWiaSystem([]), new FakeWiaSystem([source]));
        var device = (await system.ListScannersAsync(CancellationToken.None)).Single();
        return await WiaScanner.OpenAsync(system, device, CancellationToken.None);
    }

    [Fact]
    public async Task TWAIN_sources_are_listed_beside_WIA_scanners_and_scan_through_the_same_path()
    {
        var wia = Wia(UsbMfp);
        var film = FakeTwain.Source("Example FilmScan 7200", FilmScanner, Draw, "Example");
        var system = new DriverScanners(new FakeWiaSystem([wia]), new FakeWiaSystem([film]));

        var listed = await system.ListScannersAsync(CancellationToken.None);
        Assert.Equal(["EPSON Perfection V600 Photo", "Example FilmScan 7200"], listed.Select(d => d.Name));
        Assert.Equal([false, true], listed.Select(d => d.IsTwain));
        Assert.Equal("twain:Example FilmScan 7200", listed[1].Id); // never the same as a WIA id, so each goes to its own driver
        Assert.Equal("Example", listed[1].Manufacturer);
        Assert.Null(listed[1].ConnectionText);

        var scanner = await WiaScanner.OpenAsync(system, listed[1], CancellationToken.None);
        Assert.Single(await All(scanner.ScanAsync(new ScanRequest(ScanSource.Platen))));
        Assert.Single(film.Transfers);
        Assert.Empty(wia.Transfers);

        var usb = await WiaScanner.OpenAsync(system, listed[0], CancellationToken.None);
        Assert.Single(await All(usb.ScanAsync(new ScanRequest(ScanSource.Platen))));
        Assert.Single(wia.Transfers);
    }

    [Fact]
    public async Task A_TWAIN_source_that_is_a_listed_WIA_scanner_is_left_out()
    {
        var twain = new FakeWiaSystem([
            FakeTwain.Source("EPSON Perfection V600", FilmScanner, Draw, "EPSON"), // the same scanner's TWAIN driver: WIA has it
            FakeTwain.Source("Example FilmScan 7200", FilmScanner, Draw),
        ]);
        var listed = await new DriverScanners(new FakeWiaSystem([Wia(UsbMfp)]), twain).ListScannersAsync(CancellationToken.None);
        Assert.Equal(["EPSON Perfection V600 Photo", "Example FilmScan 7200"], listed.Select(d => d.Name));
    }

    [Fact]
    public async Task TWAIN_failing_to_list_keeps_the_WIA_scanners_and_the_sources_listed_before()
    {
        var twain = new ListingTwain([new WiaDeviceInfo("Example FilmScan 7200", "Example FilmScan 7200", Port: WiaDeviceInfo.TwainPort)]);
        var notes = new List<string>();
        var system = new DriverScanners(new FakeWiaSystem([Wia(UsbMfp)]), twain, notes.Add);
        Assert.Equal(2, (await system.ListScannersAsync(CancellationToken.None)).Count);

        twain.Fails = new DllNotFoundException("TWAINDSM.dll");
        Assert.Equal(2, (await system.ListScannersAsync(CancellationToken.None)).Count); // a scanner on its own doesn't vanish from the list
        Assert.Single(notes);

        await Assert.ThrowsAsync<WiaException>(() => new DriverScanners(new FailingWia(), twain).ListScannersAsync(CancellationToken.None));
    }

    [Fact]
    public async Task A_hung_TWAIN_manager_doesnt_hold_up_the_WIA_list()
    {
        var system = new DriverScanners(new FakeWiaSystem([Wia(UsbMfp)]), new ListingTwain([]) { Hangs = true }) { TwainListLimit = TimeSpan.FromMilliseconds(50) };
        var listed = await system.ListScannersAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(["EPSON Perfection V600 Photo"], listed.Select(d => d.Name));
    }

    [Fact]
    public async Task A_TWAIN_source_offers_its_feeder_duplex_colors_and_resolutions()
    {
        var scanner = await Open(FakeTwain.Source("Example DocScan 10", DocScanner, Draw));
        var caps = scanner.Capabilities;
        Assert.Equal([ScanSource.Platen, ScanSource.Adf, ScanSource.AdfDuplex], ScanChoices.Sources(caps));
        Assert.Equal([ScanColor.Color, ScanColor.Grayscale, ScanColor.BlackAndWhite], ScanChoices.Colors(caps, ScanSource.Adf));
        Assert.Equal([100, 200, 300, 600], caps.Adf!.Resolutions);

        var film = (await Open(FakeTwain.Source("Example FilmScan 7200", FilmScanner, Draw))).Capabilities;
        Assert.Equal([ScanSource.Platen], ScanChoices.Sources(film));
        Assert.Equal([ScanColor.Color, ScanColor.Grayscale], ScanChoices.Colors(film, ScanSource.Platen)); // no black and white offered
    }

    [Fact]
    public async Task A_TWAIN_feeder_run_takes_every_page_until_the_source_has_none()
    {
        var source = FakeTwain.Source("Example DocScan 10", DocScanner, Draw);
        source.FeederPages = 4;
        var pages = await All((await Open(source)).ScanAsync(new ScanRequest(ScanSource.Adf)));
        Assert.Equal(4, pages.Count);
        Assert.True(source.Applied.Single().Feeder);

        source.FeederPages = 3;
        Assert.Equal(6, (await All((await Open(source)).ScanAsync(new ScanRequest(ScanSource.AdfDuplex)))).Count); // both sides
    }

    [Fact]
    public async Task An_empty_TWAIN_feeder_says_to_load_pages()
    {
        var source = FakeTwain.Source("Example DocScan 10", DocScanner, Draw);
        source.FeederPages = 0;
        var ex = await Assert.ThrowsAsync<ScanException>(async () => await All((await Open(source)).ScanAsync(new ScanRequest(ScanSource.Adf))));
        Assert.Equal(CoreStrings.Wia_LoadFeeder, ex.Message);
    }

    [Fact]
    public async Task Cancelling_a_TWAIN_scan_stops_before_the_next_page()
    {
        var source = FakeTwain.Source("Example DocScan 10", DocScanner, Draw);
        source.FeederPages = 10;
        var scanner = await Open(source);
        using var cts = new CancellationTokenSource();
        var got = 0;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await foreach (var _ in scanner.ScanAsync(new ScanRequest(ScanSource.Adf), cts.Token))
                if (++got == 2) cts.Cancel();
        });
        Assert.Equal(2, source.Transfers.Count);
    }

    [Fact]
    public async Task A_hung_TWAIN_source_ends_the_scan_with_a_message()
    {
        var source = FakeTwain.Source("Example DocScan 10", DocScanner, Draw);
        var scanner = await Open(source);
        source.Hangs = true;
        scanner.PageTimeout = TimeSpan.FromMilliseconds(50);
        var ex = await Assert.ThrowsAsync<ScanException>(() => All(scanner.ScanAsync(new ScanRequest(ScanSource.Platen))));
        Assert.Equal(WiaErrors.Message(WiaErrors.NotAnswering, false), ex.Message);
    }

    [Fact]
    public void A_TWAIN_source_goes_to_its_printer_by_the_same_rules_as_WIA()
    {
        var source = new WiaDeviceInfo("twain:Example MFP-4400 TWAIN", "Example MFP-4400 TWAIN", "Example", Port: WiaDeviceInfo.TwainPort);
        var other = new WiaDeviceInfo("twain:Example FilmScan 7200", "Example FilmScan 7200", "Example", Port: WiaDeviceInfo.TwainPort);
        var targets = new[] { new ScanTarget("q", ["Example MFP4400 series"], ["192.0.2.16"]) };
        var assigned = WiaMatch.Assign([source, other], targets, _ => true);
        Assert.Equal([("twain:Example MFP-4400 TWAIN", "q"), ("twain:Example FilmScan 7200", (string?)null)], assigned.Select(a => (a.Device.Id, a.Owner)));
    }

    [Fact]
    public async Task Black_and_white_scans_as_a_one_bit_TWAIN_job()
    {
        var source = FakeTwain.Source("Example DocScan 10", DocScanner, Draw);
        var scanner = await Open(source);
        await All(scanner.ScanAsync(new ScanRequest(ScanSource.Platen, ScanColor.BlackAndWhite, 300)));
        var applied = source.Applied.Single();
        Assert.Equal((WiaIds.DataThreshold, 1), (applied.DataType, applied.Depth));
        var tw = TwainSettings.From(applied);
        Assert.Equal((Tw.PtBw, (ushort)1), (tw.PixelType, tw.BitDepth));
    }

    [Theory]
    [InlineData(true, false, ScanColor.Color)]
    [InlineData(false, false, ScanColor.Grayscale)]
    [InlineData(false, true, ScanColor.BlackAndWhite)]
    public void The_Scan_tabs_color_choice_is_kept_where_the_source_offers_it(bool color, bool blackAndWhite, ScanColor expected)
    {
        Assert.Equal(expected, ScanChoices.Pick([ScanColor.Color, ScanColor.Grayscale, ScanColor.BlackAndWhite], color, blackAndWhite));
        // A source without black and white scans in grey; one with color only, in color.
        Assert.Equal(color ? ScanColor.Color : ScanColor.Grayscale, ScanChoices.Pick([ScanColor.Color, ScanColor.Grayscale], color, blackAndWhite));
        Assert.Equal(ScanColor.Color, ScanChoices.Pick([ScanColor.Color], color, blackAndWhite));
    }

    [Fact]
    public void The_Scan_tab_remembers_black_and_white_as_presets_do()
    {
        Assert.Equal((true, false), ScanChoices.Remember(ScanColor.Color));
        Assert.Equal((false, false), ScanChoices.Remember(ScanColor.Grayscale));
        Assert.Equal((false, true), ScanChoices.Remember(ScanColor.BlackAndWhite));
    }

    /// <summary>A TWAIN manager whose listing can be made to fail or hang.</summary>
    private sealed class ListingTwain(IReadOnlyList<WiaDeviceInfo> sources) : IWiaSystem
    {
        public Exception? Fails { get; set; }
        public bool Hangs { get; set; }

        public async Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct)
        {
            if (Hangs) await Task.Delay(Timeout.Infinite, CancellationToken.None); // a manager stuck in a driver ignores cancelling
            if (Fails is { } ex) throw ex;
            return sources;
        }

        public IWiaDeviceHost Device(string deviceId) => throw new WiaException(WiaErrors.NoDeviceAvailable, "No such source.");
    }

    private sealed class FailingWia : IWiaSystem
    {
        public Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct) =>
            Task.FromException<IReadOnlyList<WiaDeviceInfo>>(new WiaException(WiaErrors.RpcServerUnavailable, "WIA stopped."));

        public IWiaDeviceHost Device(string deviceId) => throw new NotSupportedException();
    }
}
