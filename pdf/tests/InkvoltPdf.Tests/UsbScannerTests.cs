using System.Buffers.Binary;
using System.Text.Json;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Twain;
using InkvoltPrint.Core.Wia;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 2.3, USB scanners: the Scan dialog's driver scanners (WIA, and TWAIN through the same device interface) with made-up
/// devices (a feeder of 10 pages, a duplex feeder, a flatbed): the plan sent to the driver, the pages assembled into one PDF with
/// a text layer, blank pages left out, presets, and the words for what goes wrong. Nothing here touches a real scanner.
/// </summary>
public class UsbScannerTests
{
    private static readonly WiaDeviceInfo Usb = new(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0001", "Example DocScan 10", "Example", null, @"\\.\Usbscan0");

    /// <summary>Glass and a duplex feeder, 8.5 × 11.69 in glass, legal sheets, 75–600 dpi in steps of 25, color, grey and threshold.</summary>
    private static WiaScannerInfo FeederScanner(int? handling = WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDuplex) => new(
        handling, 8500, 11690, 8500, 14000, WiaValues.Range(200, 75, 600, 25),
        [WiaIds.DataThreshold, WiaIds.DataGrayscale, WiaIds.DataColor], [WiaIds.FormatBmp]);

    /// <summary>A flatbed without document handling, 150/300/600 dpi, color and grey only.</summary>
    private static WiaScannerInfo Flatbed() => new(null, 8500, 11690, null, null, WiaValues.Of(300, 150, 300, 600),
        [WiaIds.DataGrayscale, WiaIds.DataColor], [WiaIds.FormatJpeg]);

    /// <summary>A real JPEG with the page number in a comment segment, so each page differs and the test can tell which it is.</summary>
    private static byte[] Page(int number)
    {
        var jpeg = ScanPdfTests.Jpeg;
        var page = new byte[jpeg.Length + 6];
        jpeg.AsSpan(0, 2).CopyTo(page);                                    // SOI
        page[2] = 0xFF; page[3] = 0xFE; page[4] = 0; page[5] = 4;          // COM, length 4
        BinaryPrimitives.WriteUInt16BigEndian(page.AsSpan(6), (ushort)number);
        jpeg.AsSpan(2).CopyTo(page.AsSpan(8));
        return page;
    }

    private static int NumberOf(byte[] page) => BinaryPrimitives.ReadUInt16BigEndian(page.AsSpan(6));

    /// <summary>The analysis copy of page n: blank paper when <paramref name="blank"/> says so, else paper with a line of "text".</summary>
    private static Func<byte[], GrayImage> Analysis(Func<int, bool> blank) => jpeg =>
    {
        const int w = 200, h = 260;
        var pixels = Enumerable.Repeat((byte)245, w * h).ToArray();
        if (!blank(NumberOf(jpeg)))
            for (var y = 120; y < 130; y++)
                for (var x = 40; x < 160; x++)
                    pixels[y * w + x] = 20;
        return new GrayImage(w, h, pixels);
    };

    private static FakeWiaScanner Fake(WiaScannerInfo info, int feederPages = 10) =>
        new(Usb, info, (_, n) => Page(n)) { FeederPages = feederPages };

    private static Task<WiaScanner> Open(FakeWiaScanner fake) => WiaScanner.OpenAsync(new FakeWiaSystem([fake]), fake.Device, CancellationToken.None);

    private static async Task<List<ScanRunPage>> Run(IScanner scanner, ScanRequest request, Func<byte[], GrayImage>? analysis = null)
    {
        var list = new List<ScanRunPage>();
        await foreach (var p in ScanRun.PagesAsync(scanner, request, analysis)) list.Add(p);
        return list;
    }

    private static byte[] Pdf(IEnumerable<ScanRunPage> pages, int dpi) =>
        ScanRun.ToPdf([.. pages.Where(p => p.Fate == ScanPageFate.Kept).Select(p => (p.Jpeg, dpi))], "Scan");

    /// <summary>The PDF with an OCR text layer naming each page's number, as the dialog adds Windows' recognized words.</summary>
    private static byte[] WithText(byte[] pdf, IReadOnlyList<int> numbers) =>
        TextLayer.AddInvisibleText(pdf, null, numbers.Select((n, i) => (n, i))
            .ToDictionary(x => x.i, x => (IReadOnlyList<OcrWord>)[new OcrWord($"Sheet{x.n}", new RectD(2, 2, 20, 8))]));

    // ---- The plan -------------------------------------------------------------------------------------------------------------

    [Fact]
    public void A_feeder_scanner_offers_glass_feeder_both_sides_and_black_and_white()
    {
        var caps = WiaCapabilities.From(FeederScanner(), "Example DocScan 10");
        Assert.Equal([ScanSource.Platen, ScanSource.Adf, ScanSource.AdfDuplex], ScanChoices.Sources(caps));
        Assert.Equal([ScanColor.Color, ScanColor.Grayscale, ScanColor.BlackAndWhite], ScanChoices.Colors(caps, ScanSource.Adf));
        Assert.Equal([150, 200, 300], ScanChoices.Resolutions(caps, ScanSource.Adf));
        Assert.Contains(ScanChoices.PageSizesFor(caps, ScanSource.Adf), s => s.Key == "legal");
        Assert.DoesNotContain(ScanChoices.PageSizesFor(caps, ScanSource.Platen), s => s.Key == "legal"); // the glass is 11.69 in long
        Assert.Equal("Black and white", ScanChoices.ColorLabel(ScanColor.BlackAndWhite));
    }

    [Fact]
    public void The_plan_sets_feeder_duplex_color_dpi_and_the_page_in_pixels()
    {
        var info = FeederScanner();
        var caps = WiaCapabilities.From(info, "x");
        var letter = ScanChoices.PageSizes.First(p => p.Key == "letter");

        var duplex = WiaCapabilities.Plan(ScanChoices.ToRequest(ScanSource.AdfDuplex, ScanColor.Grayscale, 300, letter), caps, info);
        Assert.Equal(WiaIds.SelectFeeder | WiaIds.SelectDuplex | WiaIds.SelectFrontFirst, duplex.Handling);
        Assert.True(duplex.Duplex);
        Assert.Equal(0, duplex.Pages); // both sides: all pages per job
        Assert.Equal((WiaIds.DataGrayscale, 8, 300), (duplex.DataType, duplex.Depth, duplex.Resolution));
        Assert.Equal((2550, 3300), (duplex.Width, duplex.Height)); // 8.5 × 11 in at 300 dpi

        var bw = WiaCapabilities.Plan(ScanChoices.ToRequest(ScanSource.Adf, ScanColor.BlackAndWhite, 200, letter), caps, info);
        Assert.Equal((WiaIds.SelectFeeder, 1), (bw.Handling!.Value, bw.Pages!.Value));
        Assert.Equal((WiaIds.DataThreshold, 1), (bw.DataType, bw.Depth));
        Assert.Equal((1700, 2200), (bw.Width, bw.Height));

        var flat = WiaCapabilities.Plan(ScanChoices.ToRequest(ScanSource.Platen, ScanColor.BlackAndWhite, 300, null), WiaCapabilities.From(Flatbed(), "f"), Flatbed());
        Assert.Null(flat.Handling); // a glass-only driver's document handling is left alone
        Assert.False(flat.Feeder);
        Assert.Equal((WiaIds.DataGrayscale, 8), (flat.DataType, flat.Depth)); // no threshold type: grey
    }

    [Fact]
    public void A_TWAIN_source_goes_through_the_same_plan()
    {
        var caps = new TwainCaps(Feeder: true, FeederOnly: false, Duplex: true, FeederLoaded: true, [Tw.PtBw, Tw.PtGray, Tw.PtRgb],
            WiaValues.Of(300, 100, 200, 300, 600), 8.5, 14);
        var info = caps.ToInfo();
        Assert.Equal(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDuplex | WiaIds.CapDetectFeedAvailable, info.Handling);
        Assert.Equal([WiaIds.DataThreshold, WiaIds.DataGrayscale, WiaIds.DataColor], info.DataTypes);
        Assert.Equal((8500, 14000), (info.BedWidth!.Value, info.BedHeight!.Value));

        var plan = WiaCapabilities.Plan(new ScanRequest(ScanSource.AdfDuplex, ScanColor.Color, 300), WiaCapabilities.From(info, "t"), info);
        var tw = TwainSettings.From(plan);
        Assert.Equal((true, true, Tw.PtRgb, (ushort)24, 300, (short)-1), (tw.Feeder, tw.Duplex, tw.PixelType, tw.BitDepth, tw.Resolution, tw.Count));
        Assert.Equal((8.5, 14.0), (tw.Right, tw.Bottom));

        var sheetFed = new TwainCaps(true, true, false, false, [Tw.PtGray], WiaValues.Only(200), null, null).ToInfo();
        Assert.Equal([ScanSource.Adf], WiaCapabilities.From(sheetFed, "s").Sources);
        Assert.Null(new TwainCaps(false, false, false, false, [], WiaValues.Only(300), 8.5, 11.7).ToInfo().Handling); // a flatbed
    }

    [Fact]
    public void TWAIN_fixed_point_numbers_and_DIBs_read_right()
    {
        foreach (var v in new[] { 0.0, 1.5, 8.5, 11.69, 300, 1200, -0.25 })
            Assert.Equal(v, Tw.FromFix32(Tw.ToFix32(v)), 3);
        Assert.Equal(0x8000_0008u, Tw.ToFix32(8.5)); // Whole 8 in the low half, Frac 0x8000 in the high half

        // A 3 × 2 px 24-bit DIB: rows padded to 12 bytes.
        var dib = new byte[40 + 24];
        BinaryPrimitives.WriteInt32LittleEndian(dib, 40);
        BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(4), 3);
        BinaryPrimitives.WriteInt32LittleEndian(dib.AsSpan(8), 2);
        BinaryPrimitives.WriteUInt16LittleEndian(dib.AsSpan(12), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(dib.AsSpan(14), 24);
        Assert.Equal(64, Dib.Length(dib));
        var bmp = Dib.ToBmp(dib);
        Assert.Equal("BM", System.Text.Encoding.ASCII.GetString(bmp, 0, 2));
        Assert.Equal(78, BinaryPrimitives.ReadInt32LittleEndian(bmp.AsSpan(2)));
        Assert.Equal(54, BinaryPrimitives.ReadInt32LittleEndian(bmp.AsSpan(10))); // pixels right after the header

        // 1-bit (black and white): two palette entries before the pixels.
        BinaryPrimitives.WriteUInt16LittleEndian(dib.AsSpan(14), 1);
        Assert.Equal(40 + 8 + 8, Dib.Length(dib));
        Assert.Equal(14 + 40 + 8, BinaryPrimitives.ReadInt32LittleEndian(Dib.ToBmp(dib).AsSpan(10)));
        Assert.Throws<FormatException>(() => Dib.ToBmp(new byte[12]));
    }

    // ---- Page assembly ----------------------------------------------------------------------------------------------------------

    [Fact]
    public async Task A_feeder_stack_of_10_becomes_one_searchable_PDF()
    {
        var fake = Fake(FeederScanner());
        var scanner = await Open(fake);
        var pages = await Run(scanner, ScanChoices.ToRequest(ScanSource.Adf, ScanColor.Grayscale, 300, null));
        Assert.Equal(10, pages.Count);
        Assert.All(pages, p => Assert.Equal(ScanPageFate.Kept, p.Fate));
        Assert.Equal(Enumerable.Range(0, 10), pages.Select(p => NumberOf(p.Jpeg)));
        Assert.Equal(10, fake.Transfers.Count); // one page per transfer, until the feeder said it was empty

        var pdf = WithText(Pdf(pages, 300), [.. pages.Select(p => NumberOf(p.Jpeg))]);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        Assert.Equal(10, engine.PageCount);
        Assert.Contains("Sheet0", engine.GetText(0).Text);
        Assert.Contains("Sheet9", engine.GetText(9).Text);
        Assert.Equal(40 * 72.0 / 300, engine.GetPage(0).Width, 1); // each page at its scanned size
    }

    [Fact]
    public async Task A_flatbed_scans_one_page_a_time_into_the_same_PDF()
    {
        var fake = Fake(Flatbed());
        var scanner = await Open(fake);
        Assert.Equal([ScanSource.Platen], scanner.Capabilities.Sources);
        var all = new List<ScanRunPage>();
        for (var i = 0; i < 10; i++)
            all.AddRange(await Run(scanner, ScanChoices.ToRequest(ScanSource.Platen, ScanColor.Color, 300, null)));
        Assert.Equal(10, all.Count);
        Assert.All(fake.Applied, s => Assert.Null(s.Handling));
        using var engine = PdfEngine.Open(Pdf(all, 300), InputFileTypes.PDF, null);
        Assert.Equal(10, engine.PageCount);
    }

    [Fact]
    public async Task Both_sides_of_10_sheets_with_blank_backs_drop_to_10_pages()
    {
        var fake = Fake(FeederScanner());
        var scanner = await Open(fake);
        var request = ScanChoices.ToRequest(ScanSource.AdfDuplex, ScanColor.Grayscale, 200, null);

        var kept = await Run(scanner, request, Analysis(n => n % 2 == 1)); // every back (odd side) is empty
        Assert.Equal(20, kept.Count);
        Assert.Equal(10, kept.Count(p => p.Fate == ScanPageFate.Blank));
        Assert.Equal(Enumerable.Range(0, 10).Select(i => i * 2), kept.Where(p => p.Fate == ScanPageFate.Kept).Select(p => NumberOf(p.Jpeg)));
        using var engine = PdfEngine.Open(Pdf(kept, 200), InputFileTypes.PDF, null);
        Assert.Equal(10, engine.PageCount);

        var all = await Run(scanner, request); // not asked: every side stays
        Assert.Equal(20, all.Count(p => p.Fate == ScanPageFate.Kept));
    }

    [Fact]
    public async Task Blank_dropping_keeps_a_page_with_a_little_ink_and_reports_unreadable_ones()
    {
        var scanner = new ListScanner([Page(0), Page(1), [0xFF, 0xD8, 0xFF, 0xD9], Page(3)]);
        var pages = await Run(scanner, new ScanRequest(), Analysis(n => n == 1));
        Assert.Equal([ScanPageFate.Kept, ScanPageFate.Blank, ScanPageFate.Unreadable, ScanPageFate.Kept], pages.Select(p => p.Fate));

        // A page the check can't judge is kept: no page is lost to it.
        var unsure = await Run(scanner, new ScanRequest(), _ => throw new InvalidOperationException("can't decode"));
        Assert.Equal(3, unsure.Count(p => p.Fate == ScanPageFate.Kept));
    }

    [Fact]
    public void The_done_line_counts_pages_and_blanks()
    {
        Assert.Equal("Done: 10 pages from the feeder (10 blank pages left out).", ScanRun.DoneText(10, 10, 0, false, "Open as new document"));
        Assert.Equal("Done: 1 page from the feeder.", ScanRun.DoneText(1, 0, 0, false, "x"));
        Assert.StartsWith("Done (1 blank page left out). For another page, put it on the glass", ScanRun.DoneText(1, 1, 0, true, "Insert pages"));
        Assert.Contains("Clear \"Leave out blank pages\"", ScanRun.DoneText(0, 3, 0, false, "x"));
        Assert.Equal("The scanner returned no pages (1 page that couldn't be read left out).", ScanRun.DoneText(0, 0, 1, false, "x"));
    }

    // ---- Presets ----------------------------------------------------------------------------------------------------------------

    [Fact]
    public void A_preset_saves_the_choices_and_is_matched_to_each_scanner()
    {
        var preset = ScanPresets.FromChoices([], "Contracts", ScanSource.AdfDuplex, ScanColor.BlackAndWhite, 300, "legal", ocr: true, skipBlank: true);
        Assert.Equal((PresetSource.Feeder, true, false, true), (preset.Source, preset.TwoSided, preset.Color, preset.BlackAndWhite));
        Assert.Equal((300, "legal", PresetFileType.SearchablePdf, true), (preset.Resolution, preset.PageSize, preset.FileType, preset.SkipBlank));

        // Saved with the app's settings and read back.
        var stored = JsonSerializer.Deserialize<List<ScanPreset>>(JsonSerializer.Serialize(new List<ScanPreset> { preset }))!;
        var list = ScanPresets.Normalize(new ScanPresetSettings { Items = stored });
        Assert.Equal(preset with { Unknown = list[0].Unknown }, list[0]);

        var duplexScanner = WiaCapabilities.From(FeederScanner(), "d");
        var plan = PresetPlan.For(list[0], duplexScanner, null, ocrAvailable: true, metric: false);
        Assert.Equal(new ScanRequest(ScanSource.AdfDuplex, ScanColor.BlackAndWhite, 300, Width: 2550, Height: 4200), plan.Request);
        Assert.True(plan.Ocr);
        Assert.Empty(plan.Notes);

        var flatbed = PresetPlan.For(list[0], WiaCapabilities.From(Flatbed(), "f"), null, ocrAvailable: false, metric: true);
        Assert.Equal(ScanSource.Platen, flatbed.Request.Source);
        Assert.Equal(ScanColor.Grayscale, flatbed.Request.Color); // no black and white: grey
        Assert.False(flatbed.Ocr);
        Assert.Contains("This scanner has no document feeder: scanning from the glass.", flatbed.Notes);
        Assert.Contains(flatbed.Notes, n => n.StartsWith("Legal (8.5 × 14 in) doesn't fit this source"));
        Assert.Contains(flatbed.Notes, n => n.StartsWith("Text recognition isn't available"));

        var second = ScanPresets.FromChoices(list, "Contracts", ScanSource.Platen, ScanColor.Color, 150, null, false, false);
        Assert.Equal("Contracts (2)", second.Name);
        Assert.Equal((PresetSource.Glass, true, PresetFileType.Pdf), (second.Source, second.Color, second.FileType));
        Assert.Equal("Another preset is already called \"Contracts\".", ScanPresets.NameProblem(list, "", "contracts"));
    }

    // ---- What goes wrong, in words ----------------------------------------------------------------------------------------------

    [Fact]
    public async Task A_jam_mid_stack_says_so_and_keeps_the_pages_before_it()
    {
        var fake = Fake(FeederScanner());
        fake.FailAtPage = 3;
        var scanner = await Open(fake);
        var got = new List<ScanRunPage>();
        var ex = await Assert.ThrowsAsync<ScanException>(async () =>
        {
            await foreach (var p in ScanRun.PagesAsync(scanner, new ScanRequest(ScanSource.Adf), null)) got.Add(p);
        });
        Assert.Equal("The document feeder is jammed. Clear the paper and try again.", ex.Message);
        Assert.Equal(3, got.Count);
    }

    [Fact]
    public async Task An_empty_feeder_an_unplugged_scanner_and_TWAIN_failures_read_plainly()
    {
        var empty = Fake(FeederScanner(), feederPages: 0);
        var ex = await Assert.ThrowsAsync<ScanException>(async () => await Run(await Open(empty), new ScanRequest(ScanSource.Adf)));
        Assert.Equal("Load the pages into the document feeder first.", ex.Message);

        var off = Fake(FeederScanner());
        off.ConnectError = WiaErrors.Offline;
        var wia = await Assert.ThrowsAsync<WiaException>(() => Open(off));
        Assert.Equal("The scanner isn't answering. Check that it's on and connected (its cable or the network), then try again.",
            WiaErrors.Message(wia.Code, false));

        Assert.Equal(WiaErrors.PaperJam, TwainErrors.ToWia(Tw.CcPaperJam));
        Assert.Equal(WiaErrors.PaperEmpty, TwainErrors.ToWia(Tw.CcNoMedia));
        Assert.Equal(WiaErrors.CoverOpen, TwainErrors.ToWia(Tw.CcInterlock));
        Assert.Equal(WiaErrors.Offline, TwainErrors.ToWia(Tw.CcCheckDeviceOnline));
        Assert.Equal("The scanner reports a paper jam. Clear it and try again.", WiaErrors.Message(TwainErrors.ToWia(Tw.CcPaperJam), false));

        // Shared by both apps: no message names one of them.
        foreach (var code in new[] { WiaErrors.NotAnswering, WiaErrors.RpcCallFailed, WiaErrors.AccessDenied })
            Assert.DoesNotContain("Inkvolt Print", WiaErrors.Message(code, true));
    }

    [Fact]
    public void Without_a_TWAIN_manager_the_dialog_says_so()
    {
        var note = ScannerList.TwainNote(managerInstalled: false, error: null)!;
        Assert.StartsWith("Scanners with only a TWAIN driver aren't listed: this PC has no 64-bit TWAIN manager (TWAINDSM.dll).", note);
        Assert.Null(ScannerList.TwainNote(true, null));
        Assert.Equal("TWAIN scanners couldn't be listed: x", ScannerList.TwainNote(true, "x"));
        Assert.Contains("(USB)", ScannerList.NoneFound(true));
    }

    // ---- The list ---------------------------------------------------------------------------------------------------------------

    [Fact]
    public void Driver_scanners_are_listed_beside_network_ones_without_doubles()
    {
        Assert.Equal("Example DocScan 10  (USB · Windows driver)", ScannerList.Label(ScannerKind.Wia, Usb.Name, connection: Usb.ConnectionText));
        Assert.Equal("Fujitsu fi-7160  (TWAIN driver)", ScannerList.Label(ScannerKind.Twain, "Fujitsu fi-7160"));
        Assert.Equal("Office MFP  (192.0.2.5) · found on the network", ScannerList.Label(ScannerKind.Network, "Office MFP", "192.0.2.5", remembered: false));
        Assert.Equal("wia:" + Usb.Id, ScannerList.Key(ScannerKind.Wia, Usb.Id));

        // Windows' own eSCL driver for a printer the dialog already reaches over the network: its UUID is in the port.
        var network = new List<ScanTarget> { new("564e4238-4a31-4a35-3552-fc3fdbbd5f99", ["HP Color LaserJet MFP M277dw"], ["192.0.2.7"]) };
        var escl = new WiaDeviceInfo("{x}\\0002", "HP Color LaserJet MFP M277c6 (BD5F99)", "HP", null, @"SWD\Escl\564e4238-4a31-4a35-3552-fc3fdbbd5f99");
        Assert.True(ScannerList.IsListedOnTheNetwork(escl, network));
        Assert.False(ScannerList.IsListedOnTheNetwork(escl, []));
        Assert.False(ScannerList.IsListedOnTheNetwork(Usb, network)); // a USB scanner is never a network double
        var other = escl with { Port = @"SWD\Escl\11111111-2222-3333-4444-555555555555", Name = "Canon MF743C" };
        Assert.False(ScannerList.IsListedOnTheNetwork(other, network));
    }

    [Fact]
    public void ESCL_asks_for_black_and_white_only_where_offered()
    {
        static string Mode(params string[] modes)
        {
            var caps = new ScannerCapabilities("2.6", "m", null, new InputCaps(0, 2550, 0, 3508, modes, ["image/jpeg"], [300], []), null, false);
            var xml = EsclXml.BuildScanSettings(new ScanRequest(Color: ScanColor.BlackAndWhite), caps);
            return xml.Root!.Element(EsclXml.Scan + "ColorMode")!.Value;
        }
        Assert.Equal("BlackAndWhite1", Mode("RGB24", "Grayscale8", "BlackAndWhite1"));
        Assert.Equal("Grayscale8", Mode("RGB24", "Grayscale8"));
    }

    /// <summary>A scanner that hands over the pages it was given (for the page checks alone).</summary>
    private sealed class ListScanner(IReadOnlyList<byte[]> pages) : IScanner
    {
        public Task<ScannerStatus> GetStatusAsync(CancellationToken ct = default) => Task.FromResult(new ScannerStatus("Idle", null, []));

        public async IAsyncEnumerable<byte[]> ScanAsync(ScanRequest request, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
        {
            foreach (var p in pages)
            {
                await Task.Yield();
                yield return p;
            }
        }
    }
}
