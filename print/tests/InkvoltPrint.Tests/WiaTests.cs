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
        Assert.Equal(["RGB24", "Grayscale8", "BlackAndWhite1"], caps.Platen.ColorModes); // 0: the threshold type
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
        Assert.Equal(WiaIds.SelectFeeder | WiaIds.SelectDuplex | WiaIds.SelectFrontFirst, feeder.Handling); // both sides, front first
        Assert.Equal(0, feeder.Pages); // all pages: a sheet is two, and 1 would give the front only
        Assert.Null(glass.Pages);
        Assert.Equal(1, WiaCapabilities.Plan(new ScanRequest(ScanSource.Adf), caps, info).Pages);
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
        Assert.Equal(["mfcl2710dw"], WiaMatch.Models("Brother MFC-L2710DW series"));
        Assert.Equal(["laser2100"], WiaMatch.Models("Example Laser 2100 PCL6"));
    }

    // ------------------------------------------------------------------ review fixes: feeder safeguards, errors, hung drivers

    [Fact]
    public async Task A_driver_that_refuses_the_feeder_scans_nothing()
    {
        var fake = Fake(Mfp());
        fake.RefusesFeeder = true;
        var scanner = await Open(fake);
        var ex = await Assert.ThrowsAsync<ScanException>(() => All(scanner.ScanAsync(new ScanRequest(ScanSource.Adf))));
        Assert.Equal(WiaFeeder.NotTakenMessage, ex.Message);
        Assert.Empty(fake.Transfers); // the glass isn't scanned 500 times, nor once
    }

    [Fact]
    public async Task A_driver_that_scans_the_glass_once_the_feeder_is_empty_stops_when_it_says_none_is_ready()
    {
        var fake = Fake(Mfp(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDetectFeedAvailable));
        fake.FeederPages = 3;
        fake.GlassWhenEmpty = true;
        fake.DetectsFeed = true;
        var pages = await All((await Open(fake)).ScanAsync(new ScanRequest(ScanSource.Adf)));
        Assert.Equal([0, 1, 2], pages.Select(p => (int)p[2]));
        Assert.Equal(3, fake.Transfers.Count);
    }

    [Fact]
    public async Task A_page_the_same_as_the_one_before_ends_the_job()
    {
        var fake = Fake(Mfp()); // can't tell whether paper is in the feeder
        fake.FeederPages = 3;
        fake.GlassWhenEmpty = true;
        var pages = await All((await Open(fake)).ScanAsync(new ScanRequest(ScanSource.Adf)));
        Assert.Equal([0, 1, 2, 255], pages.Select(p => (int)p[2])); // one glass page gets through, its repeat ends the job
        Assert.Equal(5, fake.Transfers.Count);
    }

    [Fact]
    public async Task An_empty_feeder_read_before_the_first_page_says_to_load_pages_without_scanning()
    {
        var fake = Fake(Mfp(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDetectFeedAvailable));
        fake.FeederPages = 0;
        fake.GlassWhenEmpty = true;
        fake.DetectsFeed = true;
        var scanner = await Open(fake);
        var ex = await Assert.ThrowsAsync<ScanException>(() => All(scanner.ScanAsync(new ScanRequest(ScanSource.Adf))));
        Assert.Equal("Load the pages into the document feeder first.", ex.Message);
        Assert.Empty(fake.Transfers);
    }

    [Fact]
    public async Task Both_sides_take_the_last_sheets_back_though_the_feeder_is_empty_by_then()
    {
        var fake = Fake(Mfp(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDuplex | WiaIds.CapDetectFeedAvailable));
        fake.FeederPages = 2; // sheets
        fake.DetectsFeed = true;
        var pages = await All((await Open(fake)).ScanAsync(new ScanRequest(ScanSource.AdfDuplex)));
        Assert.Equal(4, pages.Count);
        Assert.Equal(WiaIds.SelectFeeder | WiaIds.SelectDuplex | WiaIds.SelectFrontFirst, fake.Applied.Single().Handling);
        Assert.Equal(0, fake.Applied.Single().Pages);
    }

    [Fact]
    public void The_feeder_is_checked_before_each_sheet()
    {
        var simplex = new WiaScanSettings(WiaIds.SelectFeeder, true, WiaIds.DataColor, 24, 300, 1, 1, 1);
        var duplex = simplex with { Handling = WiaIds.SelectFeeder | WiaIds.SelectDuplex | WiaIds.SelectFrontFirst, Pages = 0 };
        var glass = simplex with { Handling = WiaIds.SelectFlatbed, Feeder = false, Pages = null };
        Assert.Equal([true, true, true, true], Enumerable.Range(0, 4).Select(p => WiaFeeder.ChecksBefore(simplex, p)));
        Assert.Equal([true, false, true, false], Enumerable.Range(0, 4).Select(p => WiaFeeder.ChecksBefore(duplex, p)));
        Assert.False(WiaFeeder.ChecksBefore(glass, 0));

        Assert.True(WiaFeeder.Empty(WiaIds.CapFeed | WiaIds.CapDetectFeedAvailable, 0));
        Assert.False(WiaFeeder.Empty(WiaIds.CapFeed | WiaIds.CapDetectFeedAvailable, WiaIds.FeedReady));
        Assert.False(WiaFeeder.Empty(WiaIds.CapFeed, 0));                              // can't tell: go on
        Assert.False(WiaFeeder.Empty(WiaIds.CapFeed | WiaIds.CapDetectFeedAvailable, null));

        Assert.True(WiaFeeder.FeederTaken(simplex, WiaIds.SelectFeeder));
        Assert.True(WiaFeeder.FeederTaken(duplex, WiaIds.SelectFeeder | WiaIds.SelectDuplex)); // front first dropped: still the feeder
        Assert.False(WiaFeeder.FeederTaken(simplex, WiaIds.SelectFlatbed));
        Assert.True(WiaFeeder.FeederTaken(simplex, null));                             // no property to read back
        Assert.True(WiaFeeder.FeederTaken(glass, WiaIds.SelectFlatbed));

        Assert.True(WiaFeeder.Repeats([1, 2, 3], [1, 2, 3]));
        Assert.False(WiaFeeder.Repeats([1, 2, 3], [1, 2, 4]));
        Assert.False(WiaFeeder.Repeats(null, [1]));
    }

    [Fact]
    public async Task A_page_that_never_comes_ends_the_scan_with_a_message()
    {
        var fake = Fake(Mfp());
        var scanner = await Open(fake);
        fake.Hangs = true;
        scanner.PageTimeout = TimeSpan.FromMilliseconds(50);
        var ex = await Assert.ThrowsAsync<ScanException>(() => All(scanner.ScanAsync(new ScanRequest(ScanSource.Platen))));
        Assert.Equal(WiaErrors.Message(WiaErrors.NotAnswering, false), ex.Message);
    }

    [Theory]
    [InlineData(unchecked((int)0x800706BA), true)]  // RPC server unavailable: the WIA service restarted
    [InlineData(unchecked((int)0x80010108), true)]  // RPC_E_DISCONNECTED
    [InlineData(unchecked((int)0x80004005), true)]  // E_FAIL
    [InlineData(unchecked((int)0x80210001), true)]  // WIA general error
    [InlineData(unchecked((int)0x80210005), true)]  // offline
    [InlineData(unchecked((int)0x8021000F), true)]  // invalid driver response
    [InlineData(unchecked((int)0x80210002), false)] // paper jam
    [InlineData(unchecked((int)0x80210003), false)] // feeder empty
    [InlineData(unchecked((int)0x80210006), false)] // busy
    [InlineData(unchecked((int)0x80210007), false)] // warming up
    [InlineData(unchecked((int)0x80210016), false)] // cover open
    public void A_connection_is_dropped_after_any_failure_but_the_paper_or_the_scanners_state(int hresult, bool reconnect) =>
        Assert.Equal(reconnect, WiaErrors.NeedsReconnect(hresult));

    [Fact]
    public void Failures_of_every_kind_become_wia_exceptions_with_their_hresult()
    {
        Assert.Equal(WiaErrors.AccessDenied, WiaErrors.From(new UnauthorizedAccessException()).Code);
        Assert.Equal(WiaErrors.OutOfMemory, WiaErrors.From(new OutOfMemoryException()).Code);
        Assert.Equal(unchecked((int)0x80004001), WiaErrors.From(new NotImplementedException()).Code); // E_NOTIMPL
        Assert.Equal(WiaErrors.Busy, WiaErrors.From(new System.Runtime.InteropServices.COMException("busy", WiaErrors.Busy)).Code);
        Assert.Equal(WiaErrors.RpcDisconnected, WiaErrors.From(new System.Runtime.InteropServices.COMException("gone", WiaErrors.RpcDisconnected)).Code);
        Assert.Equal(WiaErrors.GeneralError, WiaErrors.From(new Exception("late binding")).Code); // COR_E_EXCEPTION, facility 0x13
        var wia = new WiaException(WiaErrors.PaperJam, "jam");
        Assert.Same(wia, WiaErrors.From(wia));
    }

    [Fact]
    public void Newer_errors_read_in_plain_words()
    {
        Assert.Contains("cover is open", WiaErrors.Message(WiaErrors.CoverOpen, false));
        Assert.Contains("lamp", WiaErrors.Message(WiaErrors.LampOff, false));
        Assert.Contains("scanning service", WiaErrors.Message(WiaErrors.RpcServerUnavailable, false));
        Assert.Contains("didn't allow", WiaErrors.Message(WiaErrors.AccessDenied, false));
        Assert.Contains("hasn't finished", WiaErrors.Message(WiaErrors.NotAnswering, true));
    }

    [Fact]
    public async Task Work_runs_on_a_single_threaded_apartment_when_asked()
    {
        var thread = new WorkThread("test", singleThreadedApartment: true);
        Assert.Equal(ApartmentState.STA, await thread.RunAsync(() => Thread.CurrentThread.GetApartmentState(), CancellationToken.None));
    }

    [Fact]
    public async Task Queued_work_its_caller_cancelled_never_runs()
    {
        var thread = new WorkThread("test", false);
        using var gate = new ManualResetEventSlim();
        var busy = thread.RunAsync(() => gate.Wait(TimeSpan.FromSeconds(10)), CancellationToken.None);
        using var cts = new CancellationTokenSource();
        var ran = false;
        var queued = thread.RunAsync(() => ran = true, cts.Token);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => queued); // the caller stops waiting at once
        gate.Set();
        await busy;
        Assert.Equal(7, await thread.RunAsync(() => 7, CancellationToken.None)); // the cancelled one has been dequeued by now
        Assert.False(ran); // a page queued behind a slow call isn't pulled after Cancel
    }

    [Fact]
    public async Task A_call_its_caller_gave_up_on_stops_new_work_until_it_returns()
    {
        var thread = new WorkThread("test", false);
        using var gate = new ManualResetEventSlim();
        using var cts = new CancellationTokenSource();
        var started = new TaskCompletionSource();
        var hung = thread.RunAsync(() => { started.SetResult(); return gate.Wait(TimeSpan.FromSeconds(10)); }, cts.Token);
        await started.Task;
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => hung);
        Assert.True(thread.IsStuck);
        var ran = false;
        await Assert.ThrowsAsync<WorkThreadStuckException>(() => thread.RunAsync(() => ran = true, CancellationToken.None)); // not queued
        gate.Set();
        var until = DateTime.UtcNow.AddSeconds(5);
        while (thread.IsStuck && DateTime.UtcNow < until) await Task.Delay(10);
        Assert.False(thread.IsStuck);
        Assert.Equal(1, await thread.RunAsync(() => 1, CancellationToken.None));
        Assert.False(ran);
    }

    [Fact]
    public void Hyphenated_model_numbers_are_kept_whole()
    {
        Assert.Equal(["et2850"], WiaMatch.Models("EPSON ET-2850 Series"));
        Assert.Equal(["inkjet3700"], WiaMatch.Models("Example Inkjet 3700"));
        Assert.Null(WiaMatch.Match(new WiaDeviceInfo("d", "EPSON ET-2850 Series"), [Target("wf", ["EPSON WF-2850 Series"])]));
        Assert.Equal("et", WiaMatch.Match(new WiaDeviceInfo("d", "EPSON ET-2850"), [Target("wf", ["EPSON WF-2850 Series"]), Target("et", ["EPSON ET-2850 Series"])]));
    }

    [Fact]
    public void A_second_scanner_for_a_printer_that_takes_one_is_listed_on_its_own()
    {
        var usb = new WiaDeviceInfo("u", "Example MFP 4400", Port: @"\\.\Usbscan0");
        var wsd = new WiaDeviceInfo("w", "Example MFP 4400", Port: "http://192.0.2.16:80/wsd/scan");
        var targets = new[] { Target("q", ["Example MFP 4400"], "192.0.2.16") };
        var queue = WiaMatch.Assign([usb, wsd], targets, _ => true);
        Assert.Equal([("u", "q"), ("w", (string?)null)], queue.Select(a => (a.Device.Id, a.Owner)));

        var escl = WiaMatch.Assign([usb, wsd], targets, _ => false); // the printer scans over eSCL: both left alone
        Assert.All(escl, a => Assert.Equal("q", a.Owner));
    }
}
