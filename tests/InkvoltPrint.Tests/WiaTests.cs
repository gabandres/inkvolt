using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Tests;

/// <summary>Scanning through Windows Image Acquisition (WIA): capabilities, scan settings, feeder jobs, errors and matching to printers.</summary>
public class WiaTests
{
    private static readonly WiaDeviceInfo Usb = new("{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\\0001", "Example Scan 300", "Example", "Example Scan 300", "\\\\.\\Usbscan0");

    /// <summary>A flatbed with a feeder (both sides), 8.5 × 11.69 in glass, 8.5 × 14 in sheets, 75–1200 dpi in steps of 25.</summary>
    private static WiaScannerInfo Mfp(int? handling = WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDuplex) => new(
        handling, 8500, 11690, 8500, 14000, WiaValues.Range(150, 75, 1200, 25), [0, WiaIds.DataGrayscale, WiaIds.DataColor], [WiaIds.FormatBmp]);

    private static FakeWiaScanner Fake(WiaScannerInfo info) => new(Usb, info, (s, page) => [0xFF, 0xD8, (byte)page, (byte)(s.Resolution / 100)]);

    private static async Task<WiaScanner> Open(FakeWiaScanner fake) => await WiaScanner.OpenAsync(new FakeWiaSystem([fake]), fake.Device, CancellationToken.None);

    private static async Task<List<byte[]>> All(IAsyncEnumerable<byte[]> pages)
    {
        var list = new List<byte[]>();
        await foreach (var p in pages) list.Add(p);
        return list;
    }

    [Fact]
    public void Ids_match_wiadef_h()
    {
        // WIA_DPS_FIRST = WIA_DIP_FIRST (2) + 3 × WIA_RESERVED_FOR_NEW_PROPS (1024); WIA_IPA_FIRST and WIA_IPS_FIRST follow the same way.
        Assert.Equal(3074, WiaIds.HorizontalBedSize);
        Assert.Equal(3077, WiaIds.VerticalSheetFeedSize);
        Assert.Equal(3086, WiaIds.DocumentHandlingCapabilities);
        Assert.Equal(3088, WiaIds.DocumentHandlingSelect);
        Assert.Equal(3096, WiaIds.Pages);
        Assert.Equal(4103, WiaIds.DataType);
        Assert.Equal(6147, WiaIds.XResolution);
        Assert.Equal(6152, WiaIds.YExtent);
        Assert.Equal(unchecked((int)0x80210003), WiaErrors.PaperEmpty); // MAKE_HRESULT(SEVERITY_ERROR, FACILITY_WIA (33), 3)
        Assert.True(WiaErrors.IsWia(WiaErrors.Offline));
        Assert.False(WiaErrors.IsWia(unchecked((int)0x80004005)));
    }

    [Fact]
    public void Capabilities_come_from_the_drivers_properties()
    {
        var caps = WiaCapabilities.From(Mfp(), "Example Scan 300");
        Assert.Equal([ScanSource.Platen, ScanSource.Adf, ScanSource.AdfDuplex], caps.Sources);
        Assert.Equal(2550, caps.Platen!.MaxWidth);   // 8500 thousandths = 2550 three-hundredths
        Assert.Equal(3507, caps.Platen.MaxHeight);
        Assert.Equal(4200, caps.Adf!.MaxHeight);     // 14 in
        Assert.Equal(["RGB24", "Grayscale8"], caps.Platen.ColorModes);
        Assert.Equal([75, 100, 150, 200, 300, 400, 600, 1200], caps.Platen.Resolutions); // the usual ones its 25-dpi steps allow
        Assert.True(caps.Platen.OffersJpeg);
        Assert.Equal("Example Scan 300", caps.MakeAndModel);
    }

    [Fact]
    public void A_driver_without_document_handling_is_a_flatbed()
    {
        var caps = WiaCapabilities.From(Mfp(handling: null) with { BedWidth = null, BedHeight = null, Resolutions = WiaValues.Of(300, 300, 150, 600, 150) }, "x");
        Assert.Equal([ScanSource.Platen], caps.Sources);
        Assert.Equal(2550, caps.Platen!.MaxWidth); // no size given: eSCL's defaults
        Assert.Equal([150, 300, 600], caps.Platen.Resolutions);
    }

    [Fact]
    public void A_sheet_fed_scanner_has_only_the_feeder_and_takes_long_pages()
    {
        var caps = WiaCapabilities.From(Mfp(WiaIds.CapFeed) with { FeederHeight = 0, DataTypes = [WiaIds.DataGrayscale] }, "x");
        Assert.Equal([ScanSource.Adf], caps.Sources);
        Assert.Equal(4200, caps.Adf!.MaxHeight); // "any length": Legal
        Assert.Equal(["Grayscale8"], caps.Adf.ColorModes);
    }

    [Fact]
    public void Settings_pick_the_source_color_nearest_resolution_and_area_in_pixels()
    {
        var info = Mfp();
        var caps = WiaCapabilities.From(info, "x");
        var glass = WiaCapabilities.Plan(new ScanRequest(ScanSource.Platen, ScanColor.Grayscale, 250, Width: 2550, Height: 3300), caps, info);
        Assert.Equal(new WiaScanSettings(WiaIds.SelectFlatbed, false, WiaIds.DataGrayscale, 8, 200, 1700, 2200), glass);

        var feeder = WiaCapabilities.Plan(new ScanRequest(ScanSource.AdfDuplex, ScanColor.Color, 300), caps, info);
        Assert.Equal(WiaIds.SelectFeeder | WiaIds.SelectDuplex, feeder.Handling);
        Assert.True(feeder.Feeder);
        Assert.Equal((WiaIds.DataColor, 24, 300), (feeder.DataType, feeder.Depth, feeder.Resolution));
        Assert.Equal((2550, 4200), (feeder.Width, feeder.Height)); // the whole feeder area at 300 dpi
    }

    [Fact]
    public void Settings_fall_back_to_what_the_scanner_has()
    {
        var info = Mfp(handling: null) with { DataTypes = [WiaIds.DataGrayscale] };
        var caps = WiaCapabilities.From(info, "x");
        var s = WiaCapabilities.Plan(new ScanRequest(ScanSource.Adf, ScanColor.Color, 300, Width: 9999), caps, info);
        Assert.Null(s.Handling);       // a glass-only driver: document handling is left alone
        Assert.False(s.Feeder);        // no feeder: the glass
        Assert.Equal(WiaIds.DataGrayscale, s.DataType); // no color: grey
        Assert.Equal(2550, s.Width);   // clamped to the glass
    }

    [Fact]
    public async Task A_glass_scan_gives_one_page()
    {
        var fake = Fake(Mfp());
        var pages = await All((await Open(fake)).ScanAsync(new ScanRequest(ScanSource.Platen)));
        Assert.Single(pages);
        Assert.Single(fake.Transfers);
    }

    [Fact]
    public async Task A_feeder_scan_takes_pages_until_the_feeder_is_empty()
    {
        var fake = Fake(Mfp());
        fake.FeederPages = 4;
        var pages = await All((await Open(fake)).ScanAsync(new ScanRequest(ScanSource.Adf)));
        Assert.Equal([0, 1, 2, 3], pages.Select(p => (int)p[2]));
    }

    [Fact]
    public async Task An_empty_feeder_at_the_start_says_to_load_pages()
    {
        var fake = Fake(Mfp());
        fake.FeederPages = 0;
        var scanner = await Open(fake);
        var ex = await Assert.ThrowsAsync<ScanException>(() => All(scanner.ScanAsync(new ScanRequest(ScanSource.Adf))));
        Assert.Equal("Load the pages into the document feeder first.", ex.Message);
    }

    [Fact]
    public async Task A_jam_part_way_keeps_the_pages_before_it_and_says_so()
    {
        var fake = Fake(Mfp());
        fake.FeederPages = 5;
        fake.FailAtPage = 2;
        var scanner = await Open(fake);
        var got = new List<byte[]>();
        var ex = await Assert.ThrowsAsync<ScanException>(async () =>
        {
            await foreach (var p in scanner.ScanAsync(new ScanRequest(ScanSource.Adf))) got.Add(p);
        });
        Assert.Equal(2, got.Count);
        Assert.Contains("jammed", ex.Message);
    }

    [Fact]
    public async Task A_scanner_that_is_off_says_so()
    {
        var fake = Fake(Mfp());
        fake.ConnectError = WiaErrors.Offline;
        var ex = await Assert.ThrowsAsync<WiaException>(() => Open(fake));
        Assert.True(WiaErrors.IsUnreachable(ex.Code));
        Assert.Contains("isn't answering", WiaErrors.Message(ex.Code, false));
    }

    [Fact]
    public async Task Cancelling_stops_before_the_next_page()
    {
        var fake = Fake(Mfp());
        fake.FeederPages = 10;
        using var cts = new CancellationTokenSource();
        var got = 0;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await foreach (var _ in (await Open(fake)).ScanAsync(new ScanRequest(ScanSource.Adf), cts.Token))
                if (++got == 2) cts.Cancel();
        });
        Assert.Equal(2, fake.Transfers.Count);
    }

    [Fact]
    public async Task A_driver_that_never_says_empty_stops_at_the_limit()
    {
        var fake = Fake(Mfp());
        fake.FeederPages = int.MaxValue;
        var pages = await All((await Open(fake)).ScanAsync(new ScanRequest(ScanSource.Adf)));
        Assert.Equal(WiaScanner.MaxFeederPages, pages.Count);
    }

    [Theory]
    [InlineData(WiaIds.FeedReady, "ScannerAdfLoaded")]
    [InlineData(WiaIds.FeedReady | WiaIds.PaperJam, "ScannerAdfJam")]
    [InlineData(WiaIds.PathCoverUp, "ScannerAdfHatchOpen")]
    [InlineData(0, "ScannerAdfEmpty")]
    public async Task Feeder_state_reads_as_escl_words(int status, string adf)
    {
        var fake = Fake(Mfp(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDetectFeedAvailable));
        fake.HandlingStatus = status;
        var s = await (await Open(fake)).GetStatusAsync();
        Assert.Equal(adf, s.AdfState);
        Assert.Equal(adf == "ScannerAdfLoaded", s.Problem(feeder: true) is null);
    }

    [Fact]
    public void Feeder_state_is_unknown_when_the_driver_cant_tell()
    {
        Assert.Null(WiaCapabilities.Status(WiaIds.CapFeed | WiaIds.CapFlat, 0).AdfState); // no "can detect paper" bit
        Assert.Null(WiaCapabilities.Status(WiaIds.CapFeed, null).AdfState);
        Assert.Null(WiaCapabilities.Status(WiaIds.CapFlat, WiaIds.FeedReady).AdfState); // no feeder
    }

    [Fact]
    public void Errors_read_in_plain_words()
    {
        Assert.Equal("Load the pages into the document feeder first.", WiaErrors.Message(WiaErrors.PaperEmpty, true));
        Assert.Contains("warming up", WiaErrors.Message(WiaErrors.WarmingUp, false));
        Assert.Contains("busy", WiaErrors.Message(WiaErrors.Busy, false));
        Assert.Contains("locked", WiaErrors.Message(WiaErrors.DeviceLocked, false));
        Assert.Contains("0x80210063", WiaErrors.Message(unchecked((int)0x80210063), false));
    }

    // ------------------------------------------------------------------ matching WIA scanners to printers on the list

    private static ScanTarget Target(string id, string[] names, params string[] hosts) => new(id, names, hosts);

    [Fact]
    public void A_usb_mfp_matches_its_queue_by_model_number()
    {
        var targets = new[]
        {
            Target("q1", ["Office laser", "Example Laser 2100 PCL6"]),
            Target("q2", ["Front desk", "Example Inkjet 3700 Series"]),
        };
        Assert.Equal("q1", WiaMatch.Match(new WiaDeviceInfo("d", "Example Laser 2100"), targets));
        Assert.Equal("q2", WiaMatch.Match(new WiaDeviceInfo("d", "EXAMPLE Inkjet-3700 (USB)"), targets));
    }

    [Fact]
    public void Hyphenated_model_numbers_and_maker_variants_match()
    {
        var targets = new[] { Target("b", ["Brother MFC-L2710DW series"]), Target("h", ["Hewlett-Packard LaserJet M100"]) };
        Assert.Equal("b", WiaMatch.Match(new WiaDeviceInfo("d", "Brother MFCL2710DW LAN"), targets));
        Assert.Equal("h", WiaMatch.Match(new WiaDeviceInfo("d", "HP LaserJet M100 (1A2B3C)"), targets));
    }

    [Fact]
    public void A_network_queue_named_by_windows_matches_by_the_model_in_parentheses()
    {
        var targets = new[] { Target("q", ["NPI1A2B3C (Example Color Laser MFP M400)", "Microsoft IPP Class Driver"]), Target("u", ["Example Laser 2100"]) };
        Assert.Equal("q", WiaMatch.Match(new WiaDeviceInfo("d", "Example Color Laser MFP M400 (1A2B3C)", "Microsoft", Port: @"SWD\Escl\x"), targets));
    }

    [Fact]
    public void Another_maker_with_the_same_number_does_not_match()
    {
        Assert.Null(WiaMatch.Match(new WiaDeviceInfo("d", "Example 2800"), [Target("x", ["Sample 2800 Series"])]));
        Assert.Null(WiaMatch.Match(new WiaDeviceInfo("d", "Example Scan 300"), [Target("x", ["Example Laser 2100"])]));
    }

    [Fact]
    public void The_address_in_the_port_wins()
    {
        var targets = new[] { Target("a", ["Example MFP 4400"], "192.0.2.15"), Target("b", ["Example MFP 4400"], "192.0.2.16") };
        Assert.Equal("b", WiaMatch.Match(new WiaDeviceInfo("d", "Example MFP 4400", Port: "http://192.0.2.16:80/wsd/scan"), targets));
        Assert.Null(WiaMatch.Match(new WiaDeviceInfo("d", "Example MFP 4400", Port: "\\\\.\\Usbscan0"), targets)); // two alike: neither
        Assert.Null(WiaMatch.Match(new WiaDeviceInfo("d", "Example MFP 4400", Port: "http://192.0.2.150/"), targets)); // not .15
    }

    [Fact]
    public void An_exact_name_settles_two_alike()
    {
        var targets = new[] { Target("a", ["Example MFP 4400 (Office)"]), Target("b", ["Example MFP 4400 Plus"]) };
        Assert.Null(WiaMatch.Match(new WiaDeviceInfo("d", "Example MFP 4400 copy room"), targets)); // same model number twice
        Assert.Equal("a", WiaMatch.Match(new WiaDeviceInfo("d", "Example MFP 4400"), targets));
    }

    [Fact]
    public void Escl_devices_are_recognised_by_their_port()
    {
        Assert.True(new WiaDeviceInfo("d", "x", Port: @"SWD\Escl\00000000-0000-4000-8000-000000000000").IsEscl);
        Assert.False(Usb.IsEscl);
    }

    [Theory]
    [InlineData(@"\\.\Usbscan0", "USB")]
    [InlineData(@"SWD\Escl\00000000-0000-4000-8000-000000000000", "Network")]
    [InlineData("http://192.0.2.16:80/wsd/scan", "Network")]
    [InlineData("192.0.2.16", "Network")]
    [InlineData("COM1", null)]
    [InlineData("", null)]
    public void The_port_tells_how_the_pc_reaches_it(string port, string? text) =>
        Assert.Equal(text, new WiaDeviceInfo("d", "x", Port: port).ConnectionText);

    [Fact]
    public void Normalizing_leaves_out_driver_words_and_suffixes()
    {
        Assert.Equal("hp laserjet m234dw", WiaMatch.Normalize("HP LaserJet MFP M234dw (1A2B3C)"));
        Assert.Equal(["mfcl2710dw", "l2710dw"], WiaMatch.Models("Brother MFC-L2710DW series"));
        Assert.Equal(["2100"], WiaMatch.Models("Example Laser 2100 PCL6"));
    }
}
