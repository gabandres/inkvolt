using InkvoltPrint.Core;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Tests;

/// <summary>
/// WIA 2.0's own interface (README's WIA backlog): the glass and feeder items as the driver defines them become the scanner the
/// Scan tab sees, a job picks its item, each page's progress is passed on, and a cancel stops the page under way in the driver
/// (the fake WIA scanner as a WIA 2.0 driver). The COM side (WindowsWia2) needs a real WIA 2.0 scanner.
/// </summary>
public class Wia2Tests
{
    private static readonly WiaDeviceInfo Usb = new(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0009", "Example DocScan 2", "Example", null, @"\\.\Usbscan9");

    /// <summary>A glass item (8.5 × 11.7 in, 75-1200 dpi) and a feeder item of its own (8.5 × 14 in, 150-600 dpi, both sides, paper sensor).</summary>
    private static readonly Wia2Item Glass = new(Wia2Source.Flatbed, null, 8500, 11700, WiaValues.Of(300, 75, 150, 300, 600, 1200),
        [WiaIds.DataThreshold, WiaIds.DataGrayscale, WiaIds.DataColor], [WiaIds.FormatBmp, WiaIds.FormatJpeg]);

    private static readonly Wia2Item Feeder = new(Wia2Source.Feeder, WiaIds.CapFeed | WiaIds.CapDuplex | WiaIds.CapDetectFeedAvailable | 0x10000,
        8500, 14000, WiaValues.Of(300, 150, 300, 600), [WiaIds.DataGrayscale, WiaIds.DataColor], [WiaIds.FormatPdf]);

    private static readonly Wia2Item Film = new(Wia2Source.Other, null, 1400, 9000, WiaValues.Of(4800, 4800), [WiaIds.DataColor], [WiaIds.FormatBmp]);

    [Fact]
    public void Ids_match_wiadef_h_and_wia_lh_h()
    {
        Assert.Equal(new Guid("FB607B1F-43F3-488B-855B-FB703EC342A6"), Wia2Ids.Flatbed); // WIA_CATEGORY_FLATBED
        Assert.Equal(new Guid("FE131934-F84C-42AD-8DA4-6129CDDD7288"), Wia2Ids.Feeder);
        Assert.Equal((4106, 4108, 4125, 6165, 6166), (Wia2Ids.Format, Wia2Ids.Tymed, Wia2Ids.ItemCategory, Wia2Ids.MaxHorizontalSize, Wia2Ids.MaxVerticalSize));
        Assert.Equal(0x020, Wia2Ids.SelectFrontOnly); // FRONT_ONLY
        Assert.Equal((1, 2, 3, 5, 6), (Wia2Ids.MsgStatus, Wia2Ids.MsgEndOfStream, Wia2Ids.MsgEndOfTransfer, Wia2Ids.MsgDeviceStatus, Wia2Ids.MsgNewPage));
        Assert.Equal(Wia2Source.Feeder, Wia2Item.SourceOf(Wia2Ids.FeederFront));
        Assert.Equal(Wia2Source.Other, Wia2Item.SourceOf(Wia2Ids.Film));
    }

    [Fact]
    public void The_glass_and_feeder_items_become_the_scanner_with_the_feeders_own_values()
    {
        var info = Wia2Items.Info([Film, Glass, Feeder])!;
        Assert.True(info.CancelsPage);
        Assert.Equal(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDuplex | WiaIds.CapDetectFeedAvailable, info.Handling); // nothing else from the feeder's bits
        Assert.Equal((8500, 11700, 8500, 14000), (info.BedWidth!.Value, info.BedHeight!.Value, info.FeederWidth!.Value, info.FeederHeight!.Value));

        var caps = WiaCapabilities.From(info, "x");
        Assert.Equal([ScanSource.Platen, ScanSource.Adf, ScanSource.AdfDuplex], caps.Sources);
        Assert.Equal([75, 150, 300, 600, 1200], caps.Platen!.Resolutions);
        Assert.Equal([150, 300, 600], caps.Adf!.Resolutions); // the feeder item's own, not the glass's
        Assert.Equal(4200, caps.Adf.MaxHeight); // 14 in
        Assert.Contains("BlackAndWhite1", caps.Platen.ColorModes);

        // Its feeder sends only PDF, its glass pictures: each job asks its own source's way.
        Assert.True(WiaCapabilities.Plan(new ScanRequest(ScanSource.Adf), caps, info).Pdf);
        Assert.False(WiaCapabilities.Plan(new ScanRequest(ScanSource.Platen), caps, info).Pdf);
    }

    [Fact]
    public void A_feeder_only_or_a_glass_only_device_and_one_with_neither()
    {
        var feederOnly = Wia2Items.Info([Feeder with { Formats = [WiaIds.FormatJpeg] }])!;
        Assert.Equal([ScanSource.Adf, ScanSource.AdfDuplex], WiaCapabilities.From(feederOnly, "x").Sources);
        Assert.Null(feederOnly.FeederResolutions); // its one item's values are the device's

        var glassOnly = Wia2Items.Info([Glass])!;
        Assert.Null(glassOnly.Handling);
        Assert.Equal([ScanSource.Platen], WiaCapabilities.From(glassOnly, "x").Sources);

        Assert.Null(Wia2Items.Info([Film])); // nothing to scan pages with: WIA 1.0's view of it is used
        Assert.Null(Wia2Items.Info([]));
    }

    [Fact]
    public void A_job_picks_its_item_its_sides_and_its_format()
    {
        var items = new[] { Film, Glass, Feeder };
        var info = Wia2Items.Info(items)!;
        var caps = WiaCapabilities.From(info, "x");
        var glass = WiaCapabilities.Plan(new ScanRequest(ScanSource.Platen, ScanColor.Color, 300), caps, info);
        var simplex = WiaCapabilities.Plan(new ScanRequest(ScanSource.Adf), caps, info);
        var duplex = WiaCapabilities.Plan(new ScanRequest(ScanSource.AdfDuplex), caps, info);
        Assert.Equal((1, 2, 2), (Wia2Items.For(glass, items), Wia2Items.For(simplex, items), Wia2Items.For(duplex, items)));
        Assert.Equal(Wia2Ids.SelectFrontOnly, Wia2Items.FeederSelect(simplex));
        Assert.Equal(WiaIds.SelectDuplex | WiaIds.SelectFrontFirst, Wia2Items.FeederSelect(duplex));
        Assert.True(WiaFeeder.FeederTaken(simplex, Wia2Items.SelectReadBack(simplex, items)));
        Assert.False(WiaFeeder.FeederTaken(simplex, Wia2Items.SelectReadBack(simplex, [Glass]))); // no feeder item: said, nothing scanned

        Assert.Equal(WiaIds.FormatJpeg, Wia2Items.FormatFor(glass, Glass.Formats));
        Assert.Equal(WiaIds.FormatBmp, Wia2Items.FormatFor(glass with { Depth = 1 }, Glass.Formats)); // black and white: BMP
        Assert.Equal(WiaIds.FormatPdf, Wia2Items.FormatFor(simplex, Feeder.Formats));
        Assert.Equal(WiaIds.FormatBmp, Wia2Items.FormatFor(glass, [WiaIds.FormatBmp]));
    }

    [Fact]
    public void The_format_is_one_the_item_lists_and_none_means_WIA_1()
    {
        var info = Wia2Items.Info([Glass])!;
        var color = WiaCapabilities.Plan(new ScanRequest(ScanSource.Platen), WiaCapabilities.From(info, "x"), info);
        Assert.Equal(WiaIds.FormatPng, Wia2Items.FormatFor(color, [WiaIds.FormatPng, WiaIds.FormatTiff])); // no JPEG, no BMP
        Assert.Equal(WiaIds.FormatTiff, Wia2Items.FormatFor(color, ["{b96b3cb1-0728-11d3-9d7b-0000f81ef32e}"])); // TIFF, any case
        Assert.Equal(WiaIds.FormatJpeg, Wia2Items.FormatFor(color with { Depth = 1 }, [WiaIds.FormatJpeg])); // JPEG after all
        Assert.Null(Wia2Items.FormatFor(color, ["{700B4A0F-2011-411C-B430-D1E0B2E10B28}"])); // XPS only: WIA 1.0's path
        Assert.Equal(WiaIds.FormatBmp, Wia2Items.FormatFor(color, [])); // nothing said: BMP, as every driver takes
    }

    [Fact]
    public void A_passing_device_status_is_forgotten_and_one_that_ends_the_transfer_kept()
    {
        int? error = null;
        error = Wia2Items.TransferError(error, Wia2Ids.MsgDeviceStatus, WiaErrors.WarmingUp);
        Assert.Null(error); // warming up passes
        error = Wia2Items.TransferError(error, Wia2Ids.MsgDeviceStatus, WiaErrors.PaperJam);
        Assert.Equal(WiaErrors.PaperJam, error);
        Assert.Equal(WiaErrors.PaperJam, Wia2Items.TransferError(error, Wia2Ids.MsgDeviceStatus, 0)); // a later good status doesn't clear a jam…
        Assert.Null(Wia2Items.TransferError(error, Wia2Ids.MsgStatus, 0)); // …the page going on does
        Assert.Null(Wia2Items.TransferError(error, Wia2Ids.MsgNewPage, 0));
        Assert.Equal(WiaErrors.CoverOpen, Wia2Items.TransferError(null, Wia2Ids.MsgEndOfTransfer, WiaErrors.CoverOpen));
    }

    [Fact]
    public void A_jam_after_some_pages_is_raised_after_them_and_an_empty_feeder_isnt()
    {
        Assert.Equal(WiaErrors.PaperJam, Wia2Items.FailureAfter(WiaErrors.PaperJam, null));
        Assert.Equal(WiaErrors.PaperJam, Wia2Items.FailureAfter(0, WiaErrors.PaperJam)); // reported through the callback
        Assert.Null(Wia2Items.FailureAfter(WiaErrors.PaperEmpty, null)); // the job's end
        Assert.Null(Wia2Items.FailureAfter(Wia2Ids.EndOfMedia, null));
        Assert.Null(Wia2Items.FailureAfter(0, null));
    }

    private static FakeWiaScanner Wia2Fake(int feederPages = 3) =>
        new(Usb, Wia2Items.Info([Glass, Feeder with { Formats = [WiaIds.FormatJpeg] }])!, (_, n) => [0xFF, 0xD8, (byte)n]) { FeederPages = feederPages };

    [Fact]
    public async Task Each_pages_progress_is_passed_on()
    {
        var fake = Wia2Fake();
        var scanner = await WiaScanner.OpenAsync(new FakeWiaSystem([fake]), fake.Device, CancellationToken.None);
        var seen = new List<(int Page, int Percent)>();
        scanner.Progress = (page, percent) => seen.Add((page, percent));
        var pages = new List<byte[]>();
        await foreach (var p in scanner.ScanAsync(new ScanRequest(ScanSource.Adf))) pages.Add(p);
        Assert.Equal(3, pages.Count);
        Assert.Equal([0, 25, 50, 75, 100], seen.Where(s => s.Page == 2).Select(s => s.Percent));
        Assert.Equal([1, 2, 3], seen.Select(s => s.Page).Distinct());
    }

    [Fact]
    public async Task Cancelling_stops_the_page_under_way_in_the_driver()
    {
        var fake = Wia2Fake();
        fake.SlowPage = TimeSpan.FromMinutes(2);
        var scanner = await WiaScanner.OpenAsync(new FakeWiaSystem([fake]), fake.Device, CancellationToken.None);
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        var clock = System.Diagnostics.Stopwatch.StartNew();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await foreach (var _ in scanner.ScanAsync(new ScanRequest(ScanSource.Platen), cts.Token)) { }
        });
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(30), $"{clock.Elapsed.TotalSeconds:0.0} s");
        Assert.Equal(1, fake.StoppedPages); // stopped in the driver, not left running
        Assert.False(scanner.IsBusy); // the scanner takes the next job at once
    }

    [Fact]
    public async Task A_WIA_1_driver_reports_no_progress_and_its_page_runs_to_its_end()
    {
        var fake = new FakeWiaScanner(Usb, Wia2Items.Info([Glass])! with { CancelsPage = false }, (_, n) => [0xFF, 0xD8, (byte)n]) { SlowPage = TimeSpan.FromMilliseconds(400) };
        var scanner = await WiaScanner.OpenAsync(new FakeWiaSystem([fake]), fake.Device, CancellationToken.None);
        var seen = 0;
        scanner.Progress = (_, _) => seen++;
        var pages = new List<byte[]>();
        await foreach (var p in scanner.ScanAsync(new ScanRequest(ScanSource.Platen))) pages.Add(p);
        Assert.Single(pages);
        Assert.Equal(0, seen);
        Assert.Equal(0, fake.StoppedPages);
    }
}
