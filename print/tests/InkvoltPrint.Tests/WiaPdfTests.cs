using InkvoltPrint.Core;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Tests;

/// <summary>
/// WIA drivers that offer only PDF (print/ROADMAP.md 1.3, the eSCL PDF-only path's twin): the fake WIA scanner set to PDF only
/// scans the same pages, byte for byte, as its JPEG run, whether its driver sends a PDF per page or the whole run in one, so the
/// review, OCR, presets and photos get the pages a picture driver gives; a driver that also offers a picture format is asked for it.
/// </summary>
public class WiaPdfTests
{
    private static readonly WiaDeviceInfo Usb = new(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0007", "Example DocPdf 20", "Example", null, @"\\.\Usbscan7");

    /// <summary>Six different pages, as a feeder batch (sizes differ, so the bytes do).</summary>
    private static readonly IReadOnlyList<byte[]> Six = [.. Enumerable.Range(0, 6).Select(i => TestJpeg.Build(2550 - i * 10, 3300, null))];

    private static WiaScannerInfo Info(params string[] formats) => new(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDuplex | WiaIds.CapDetectFeedAvailable,
        8500, 11690, 8500, 14000, WiaValues.Of(300, 150, 300, 600), [WiaIds.DataGrayscale, WiaIds.DataColor], formats);

    private static FakeWiaScanner Fake(params string[] formats) =>
        new(Usb, Info(formats), (s, page) => Six[page % Six.Count]) { FeederPages = 6, DetectsFeed = true };

    private static async Task<List<byte[]>> ScanAsync(FakeWiaScanner fake, ScanSource source)
    {
        var scanner = await WiaScanner.OpenAsync(new FakeWiaSystem([fake]), fake.Device, CancellationToken.None);
        var pages = new List<byte[]>();
        await foreach (var page in scanner.ScanAsync(new ScanRequest(source, Resolution: 300))) pages.Add(page);
        return pages;
    }

    [Fact]
    public async Task A_PDF_only_WIA_feeder_scans_the_same_pages_as_its_JPEG_run()
    {
        var jpegRun = await ScanAsync(Fake(WiaIds.FormatJpeg, WiaIds.FormatBmp), ScanSource.Adf);
        var pdfOnly = Fake(WiaIds.FormatPdf);
        var pdfRun = await ScanAsync(pdfOnly, ScanSource.Adf);

        Assert.Equal(6, jpegRun.Count);
        Assert.Equal(jpegRun, pdfRun); // byte for byte: the same split, straightening, crop and OCR
        Assert.All(pdfOnly.Transfers, t => Assert.True(t.Pdf)); // asked as PDF, one page a transfer
        Assert.Equal(6, pdfOnly.Transfers.Count);
        Assert.All(pdfRun, p => Assert.Equal(1, ScannerPdf.OriginOf(p)!.PageCount)); // each page remembers its PDF
        Assert.All(jpegRun, p => Assert.Null(ScannerPdf.OriginOf(p)));
    }

    [Fact]
    public async Task A_driver_that_sends_the_whole_run_in_one_PDF_gives_every_page()
    {
        var fake = Fake(WiaIds.FormatPdf);
        fake.PdfWholeRun = true;
        fake.DetectsFeed = false; // a driver that can't tell: the next transfer says the feeder is empty
        var pages = await ScanAsync(fake, ScanSource.Adf);

        Assert.Equal(Six, pages);
        Assert.Single(fake.Transfers);
        var origins = pages.Select(ScannerPdf.OriginOf).ToList();
        Assert.All(origins, o => Assert.Equal(6, o!.PageCount));
        Assert.Equal([0, 1, 2, 3, 4, 5], origins.Select(o => o!.Page));
        Assert.Same(origins[0]!.Pdf, ScannerPdf.KeepAsSent([.. origins.Select(o => new PageToSave(o, false))])); // a PDF save untouched is the driver's own
    }

    [Fact]
    public async Task A_PDF_only_glass_scans_one_page()
    {
        var fake = Fake(WiaIds.FormatPdf);
        var glass = await ScanAsync(fake, ScanSource.Platen);
        Assert.Equal([Six[0]], glass);
        Assert.True(fake.Applied.Single().Pdf);
    }

    [Fact]
    public void Only_a_driver_with_PDF_and_no_picture_format_is_PDF_only()
    {
        Assert.True(Info(WiaIds.FormatPdf).PdfOnly);
        Assert.True(Info("9980bd5b-3463-43c7-bdca-3caa146f229f").PdfOnly); // any case, no braces
        Assert.True(Info(WiaIds.FormatPdf, "{700B4A0F-2011-411C-B430-D1E0B2E10B28}").PdfOnly); // XPS beside it is no picture either
        Assert.False(Info(WiaIds.FormatPdf, WiaIds.FormatBmp).PdfOnly);
        Assert.False(Info(WiaIds.FormatPdf, WiaIds.FormatMemoryBmp).PdfOnly);
        Assert.False(Info(WiaIds.FormatTiff, WiaIds.FormatPdf).PdfOnly);
        Assert.False(Info().PdfOnly); // nothing said: a picture is asked, as before
        Assert.False(Info("not a guid").PdfOnly);

        var caps = WiaCapabilities.From(Info(WiaIds.FormatPdf), "x");
        Assert.True(WiaCapabilities.Plan(new ScanRequest(ScanSource.Adf), caps, Info(WiaIds.FormatPdf)).Pdf);
        Assert.False(WiaCapabilities.Plan(new ScanRequest(ScanSource.Adf), caps, Info(WiaIds.FormatPdf, WiaIds.FormatJpeg)).Pdf);
        Assert.True(caps.Adf!.OffersJpeg); // the Scan tab still gets JPEG pages
    }

    [Fact]
    public async Task A_PDF_the_driver_sends_that_cant_be_read_ends_the_scan_in_words()
    {
        var broken = new BrokenPdf(Info(WiaIds.FormatPdf));
        var scanner = await WiaScanner.OpenAsync(broken, Usb, CancellationToken.None);
        var ex = await Assert.ThrowsAsync<ScanException>(async () =>
        {
            await foreach (var _ in scanner.ScanAsync(new ScanRequest(ScanSource.Platen))) { }
        });
        Assert.Equal(CoreStrings.Escl_PdfPictures, ex.Message); // not one picture a page, and no renderer in tests
    }

    /// <summary>A driver whose PDF has no page this PC can take out (hostile or broken input).</summary>
    private sealed class BrokenPdf(WiaScannerInfo info) : IWiaSystem, IWiaDevice, IWiaDeviceHost
    {
        public WiaScannerInfo Info => info;
        public Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct) => Task.FromResult<IReadOnlyList<WiaDeviceInfo>>([Usb]);
        public IWiaDeviceHost Device(string deviceId) => this;
        public int? ReadHandlingStatus() => null;
        public int? Apply(WiaScanSettings settings) => settings.Handling;
        public byte[]? TransferPage(WiaScanSettings settings) => "%PDF-1.7\n1 0 obj << /Type /Catalog /Pages 1 0 R >> endobj\ntrailer << /Root 1 0 R >>"u8.ToArray();
        public Task<T> UseAsync<T>(Func<IWiaDevice, T> work, CancellationToken ct) => Task.FromResult(work(this));
    }
}
