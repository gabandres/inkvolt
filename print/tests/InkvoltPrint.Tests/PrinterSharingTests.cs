using System.Buffers.Binary;
using System.Net;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing.Direct;
using InkvoltPrint.Core.Printing.Raster;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Sharing;
using InkvoltPrint.Sharing;

namespace InkvoltPrint.Tests;

/// <summary>
/// Sharing a Windows queue with phones (roadmap 4.10): the IPP server (<see cref="SharedPrinter"/>) on hostile requests, the raster
/// documents phones send read back (<see cref="RasterReader"/>, against the core's own writers), the share's life
/// (<see cref="PrinterShare"/>), and our own straight-to-the-printer client printing to it over the real Kestrel server on loopback,
/// as an Android phone's print service would (attributes, then Print-Job with a PWG Raster, chunked).
/// </summary>
public class PrinterSharingTests
{
    private static readonly IPAddress Phone = IPAddress.Parse("192.0.2.40"), OtherPhone = IPAddress.Parse("192.0.2.41");
    private static readonly SharedQueue Laser = new("Office laser", Color: false, TwoSided: true, SharedPrinterMedia.A4);
    private static readonly Guid Id = new("6f1d1f6e-0000-4000-8000-000000000010");

    private sealed class Sink : ISharedPrintSink
    {
        public List<SharedPrintJob> Jobs { get; } = [];
        public TaskCompletionSource? Hold { get; set; }
        public Exception? Fail { get; set; }

        public async Task PrintAsync(SharedPrintJob job, CancellationToken ct)
        {
            if (Hold is { } hold) await hold.Task.WaitAsync(ct);
            if (Fail is { } fail) throw fail;
            lock (Jobs) Jobs.Add(job);
        }
    }

    private static SharedPrinter Printer(Sink sink, PrinterShareLimits? limits = null) => new(Laser, Id, "Office laser on DESK", "DESK", sink, limits);

    private static string Uri => "ipp://192.0.2.10:9782" + SharedPrinter.PathOf(Id);

    private static Task<ShareReply> Send(SharedPrinter p, byte[] body, IPAddress? peer = null) =>
        p.HandleAsync(new ShareRequest("POST", p.Path, body, peer ?? Phone, "192.0.2.10:9782"), CancellationToken.None);

    private static (ushort Status, IReadOnlyList<(byte Tag, Dictionary<string, List<object>> Attributes)> Groups) Read(ShareReply reply)
    {
        Assert.Equal(200, reply.Status);
        Assert.Equal("application/ipp", reply.ContentType);
        return IppCodec.DecodeGroups(reply.Body);
    }

    private static byte[] PwgDocument(int pages = 1, RasterColor color = RasterColor.Gray8)
    {
        var job = new RasterJob(RasterFormat.PwgRaster, 100, color, SharedPrinterMedia.A4, 21000, 29700, pages);
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, job);
        for (var i = 0; i < pages; i++) w.Write(Page(job.WidthPixels, job.HeightPixels, color, i));
        w.Finish();
        return ms.ToArray();
    }

    /// <summary>A page with something on it: a dark bar whose place depends on the page, and a stripe of every grey.</summary>
    private static RasterPage Page(int w, int h, RasterColor color, int seed)
    {
        var page = RasterPage.Blank(w, h, color);
        var bpp = page.BytesPerPixel;
        for (var y = 10 + seed * 5; y < 30 + seed * 5; y++)
            for (var x = 5; x < w - 5; x++)
                for (var c = 0; c < bpp; c++) page.Pixels[(y * w + x) * bpp + c] = (byte)(x * (c + 1) % 256);
        return page;
    }

    private static byte[] PrintJob(byte[] document, string format = "image/pwg-raster", Action<IppRequest>? job = null)
    {
        var r = new IppRequest(IppCodec.PrintJob, 7, Uri).Name("requesting-user-name", "phone").Name("job-name", "Boarding pass").MimeMediaType("document-format", format);
        r.JobGroup();
        job?.Invoke(r);
        return [.. r.ToArray(), .. document];
    }

    private static async Task WaitFor(Func<bool> condition)
    {
        var until = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(5));
        while (!condition())
        {
            if (DateTime.UtcNow > until) Assert.Fail("Timed out waiting.");
            await Task.Delay(20);
        }
    }

    // ---------------------------------------------------------------- the IPP server

    [Fact]
    public async Task Its_attributes_say_what_a_phone_needs_to_print()
    {
        using var p = Printer(new Sink());
        var (status, groups) = Read(await Send(p, IppCodec.EncodeGetPrinterAttributes(Uri, ["all"])));
        Assert.Equal(SharedPrinter.Ok, status);
        var a = groups.Single(g => g.Tag == 0x04).Attributes;
        Assert.Equal(["application/pdf", "image/jpeg", "image/pwg-raster", "image/urf", "application/octet-stream"], a["document-format-supported"].Cast<string>());
        Assert.Equal($"urn:uuid:{Id:D}", a["printer-uuid"][0]);
        Assert.Equal("ipp://192.0.2.10:9782" + p.Path, a["printer-uri-supported"][0]);
        Assert.Contains("DM1", a["urf-supported"].Cast<string>());
        Assert.DoesNotContain("SRGB24", a["urf-supported"].Cast<string>()); // a black-and-white queue
        Assert.Equal(["sgray_8"], a["pwg-raster-document-type-supported"].Cast<string>());
        Assert.Equal(false, a["color-supported"][0]);
        Assert.Equal(["one-sided", "two-sided-long-edge"], a["sides-supported"].Cast<string>());
        Assert.Equal(SharedPrinterMedia.A4, a["media-default"][0]);
        Assert.Equal(new IppRange(1, 10), a["copies-supported"][0]);
        var col = Assert.IsType<IppCollection>(a["media-col-database"][0]);
        Assert.Equal(21000, col.Collection("media-size")!.Int("x-dimension"));
        // What straight-to-the-printer printing (2.1) reads from a printer, it reads from this one.
        var caps = IppPrintCaps.From(IppCodec.Decode((await Send(p, IppCodec.EncodeGetPrinterAttributes(Uri, IppPrintCaps.Requested))).Body));
        Assert.Contains(RasterFormat.PwgRaster, caps.Formats);
        Assert.NotNull(DirectPrintPlan.Choose(caps, new DirectPrintRequest(), out _));
    }

    [Fact]
    public async Task Asked_for_some_attributes_it_answers_with_those()
    {
        using var p = Printer(new Sink());
        var (_, groups) = Read(await Send(p, IppCodec.EncodeGetPrinterAttributes(Uri, ["printer-state", "printer-name"])));
        Assert.Equal(["printer-state", "printer-name"], groups.Single(g => g.Tag == 0x04).Attributes.Keys.Order().Reverse());
    }

    [Theory]
    [InlineData(new byte[] { 1, 1, 0, 0x0B, 0, 0, 0, 1 })] // too short
    [InlineData(new byte[] { 1, 1, 0, 0x0B, 0, 0, 0, 1, 0x01, 0x47, 0xFF, 0xFF, 0, 0 })] // a name longer than the request
    [InlineData(new byte[] { 1, 1, 0, 0x0B, 0, 0, 0, 1, 0x01, 0x47, 0, 1, (byte)'a', 0, 1, (byte)'b' })] // no end-of-attributes
    public async Task A_malformed_request_is_a_bad_request_never_a_crash(byte[] body)
    {
        using var p = Printer(new Sink());
        var reply = await Send(p, body);
        if (reply.Body is null) Assert.Equal(400, reply.Status);
        else Assert.Equal(SharedPrinter.BadRequest, Read(reply).Status);
    }

    [Fact]
    public async Task Other_versions_and_operations_are_refused_in_ipp_words()
    {
        using var p = Printer(new Sink());
        var v3 = IppCodec.EncodeGetPrinterAttributes(Uri, ["all"]);
        v3[0] = 3;
        Assert.Equal(SharedPrinter.VersionNotSupported, Read(await Send(p, v3)).Status);
        var purge = new IppRequest(0x0012, 1, Uri).ToArray(); // Purge-Jobs
        Assert.Equal(SharedPrinter.OperationNotSupported, Read(await Send(p, purge)).Status);
        var noCharset = new byte[] { 2, 0, 0, 0x0B, 0, 0, 0, 1, 0x01, 0x03 };
        Assert.Equal(SharedPrinter.BadRequest, Read(await Send(p, noCharset)).Status);
        Assert.Equal(405, (await p.HandleAsync(new ShareRequest("PUT", p.Path, [], Phone), CancellationToken.None)).Status);
    }

    [Fact]
    public async Task A_pwg_raster_job_prints_once_with_its_options()
    {
        var sink = new Sink();
        using var p = Printer(sink);
        var document = PwgDocument(2);
        var (status, groups) = Read(await Send(p, PrintJob(document, job: r => r.Integer("copies", 2).Keyword("sides", "two-sided-long-edge").Keyword("print-color-mode", "monochrome"))));
        Assert.Equal(SharedPrinter.Ok, status);
        var job = groups.Single(g => g.Tag == 0x02).Attributes;
        Assert.Equal(1, job["job-id"][0]);
        Assert.Equal(Uri + "/1", job["job-uri"][0]);
        await WaitFor(() => sink.Jobs.Count == 1 && p.ActiveJobs == 0);
        var printed = sink.Jobs[0];
        Assert.Equal(("Office laser", "image/pwg-raster", 2, true, true, "Boarding pass"),
            (printed.Queue, printed.Format, printed.Copies, printed.TwoSided, printed.Monochrome, printed.JobName));
        Assert.Equal(document, printed.Document);
        var state = Read(await Send(p, DirectJob.GetJobAttributesRequest(Uri, "phone", 1)));
        Assert.Equal(9, state.Groups.Single(g => g.Tag == 0x02).Attributes["job-state"][0]); // completed
    }

    [Fact]
    public async Task A_document_is_taken_only_as_what_its_bytes_show()
    {
        var sink = new Sink();
        using var p = Printer(sink);
        Assert.Equal(SharedPrinter.DocumentFormatError, Read(await Send(p, PrintJob("%PDF-1.7\n"u8.ToArray(), "image/jpeg"))).Status);
        Assert.Equal(SharedPrinter.FormatNotSupported, Read(await Send(p, PrintJob("MZ\x90\0"u8.ToArray(), "application/octet-stream"))).Status);
        Assert.Equal(SharedPrinter.FormatNotSupported, Read(await Send(p, PrintJob("PK\x03\x04"u8.ToArray(), "application/vnd.ms-excel"))).Status);
        Assert.Equal(SharedPrinter.BadRequest, Read(await Send(p, PrintJob([]))).Status);
        Assert.Equal(SharedPrinter.Ok, Read(await Send(p, PrintJob(PwgDocument(), "application/octet-stream"))).Status);
        await WaitFor(() => sink.Jobs.Count == 1);
        Assert.Equal("image/pwg-raster", sink.Jobs[0].Format);
        Assert.Equal("image/urf", SharedPrinter.Sniff("UNIRAST\0"u8));
        Assert.Equal("image/jpeg", SharedPrinter.Sniff([0xFF, 0xD8, 0xFF, 0xE0]));
    }

    [Fact]
    public async Task What_it_doesnt_take_is_listed_back_and_refused_only_with_fidelity()
    {
        var sink = new Sink();
        using var p = Printer(sink);
        byte[] Validate(bool fidelity)
        {
            var r = new IppRequest(0x0004, 3, Uri).MimeMediaType("document-format", "application/pdf");
            if (fidelity) r.Value(IppCodec.Boolean, "ipp-attribute-fidelity", [1]);
            return r.JobGroup().Integer("copies", 50).Keyword("finishings-col-ish", "staple").Keyword("print-color-mode", "color").ToArray();
        }
        var (status, groups) = Read(await Send(p, Validate(false)));
        Assert.Equal(SharedPrinter.OkIgnored, status);
        var unsupported = groups.Single(g => g.Tag == 0x05).Attributes;
        Assert.Equal(["copies", "finishings-col-ish", "print-color-mode"], unsupported.Keys.Order());
        Assert.Equal(SharedPrinter.AttributesNotSupported, Read(await Send(p, Validate(true))).Status);
        Assert.Empty(sink.Jobs); // Validate-Job prints nothing
    }

    [Fact]
    public async Task A_busy_printer_says_so_and_a_device_sees_and_cancels_only_its_own_jobs()
    {
        var sink = new Sink { Hold = new TaskCompletionSource() };
        using var p = Printer(sink);
        var document = PwgDocument();
        Assert.Equal(SharedPrinter.Ok, Read(await Send(p, PrintJob(document))).Status); // job 1 prints (held)
        await WaitFor(() => Read(Send(p, DirectJob.GetJobAttributesRequest(Uri, "phone", 1)).Result).Groups.Single(g => g.Tag == 2).Attributes["job-state"][0] is 5);
        Assert.Equal(SharedPrinter.Ok, Read(await Send(p, PrintJob(document), OtherPhone)).Status); // 2 waits
        Assert.Equal(SharedPrinter.Ok, Read(await Send(p, PrintJob(document))).Status); // 3 waits
        Assert.Equal(SharedPrinter.Busy, Read(await Send(p, PrintJob(document))).Status); // a fourth: try later

        Assert.Equal(SharedPrinter.NotFound, Read(await Send(p, DirectJob.GetJobAttributesRequest(Uri, "phone", 2))).Status); // the other phone's
        var jobs = Read(await Send(p, PrinterJobs.GetJobsRequest(Uri, "phone")));
        Assert.Equal([3, 1], jobs.Groups.Where(g => g.Tag == 2).Select(g => (int)g.Attributes["job-id"][0]));
        Assert.Equal(SharedPrinter.NotFound, Read(await Send(p, DirectJob.CancelJobRequest(Uri, "phone", 2))).Status);
        Assert.Equal(SharedPrinter.NotPossible, Read(await Send(p, DirectJob.CancelJobRequest(Uri, "phone", 1))).Status); // already printing
        Assert.Equal(SharedPrinter.Ok, Read(await Send(p, DirectJob.CancelJobRequest(Uri, "phone", 3))).Status);

        sink.Hold.SetResult();
        await WaitFor(() => p.ActiveJobs == 0);
        Assert.Equal(2, sink.Jobs.Count); // 1 and 2; 3 was cancelled before it printed
    }

    [Fact]
    public async Task A_job_that_cant_be_read_is_aborted_and_the_printer_goes_on()
    {
        var sink = new Sink { Fail = new FormatException("raster data cut short") };
        using var p = Printer(sink);
        Read(await Send(p, PrintJob(PwgDocument())));
        await WaitFor(() => p.ActiveJobs == 0);
        var job = Read(await Send(p, DirectJob.GetJobAttributesRequest(Uri, "phone", 1))).Groups.Single(g => g.Tag == 2).Attributes;
        Assert.Equal(8, job["job-state"][0]);
        Assert.Equal("document-format-error", job["job-state-reasons"][0]);
        sink.Fail = null;
        Read(await Send(p, PrintJob(PwgDocument())));
        await WaitFor(() => sink.Jobs.Count == 1);
    }

    [Fact]
    public async Task A_busy_printer_or_a_document_too_large_is_refused_from_the_head_alone()
    {
        var sink = new Sink { Hold = new TaskCompletionSource() };
        using var p = Printer(sink);
        var head = PrintJob([]); // the attributes only: the document isn't read yet
        Assert.Null(p.Precheck(new ShareRequest("POST", p.Path, head, Phone), 1000));
        Assert.Equal(SharedPrinter.TooLarge, Read(p.Precheck(new ShareRequest("POST", p.Path, head, Phone), 200L * 1024 * 1024)!).Status);
        Read(await Send(p, PrintJob(PwgDocument()))); // printing (held)
        await WaitFor(() => Read(Send(p, DirectJob.GetJobAttributesRequest(Uri, "phone", 1)).Result).Groups.Single(g => g.Tag == 2).Attributes["job-state"][0] is 5);
        foreach (var _ in Enumerable.Range(0, 2)) Read(await Send(p, PrintJob(PwgDocument()))); // two waiting
        Assert.Equal(3, p.ActiveJobs);
        Assert.Equal(SharedPrinter.Busy, Read(p.Precheck(new ShareRequest("POST", p.Path, head, OtherPhone), 1000)!).Status);
        Assert.Null(p.Precheck(new ShareRequest("POST", p.Path, IppCodec.EncodeGetPrinterAttributes(Uri, ["all"]), Phone), 100)); // only Print-Job
        sink.Hold.SetResult();
        await WaitFor(() => p.ActiveJobs == 0);
    }

    [Fact]
    public async Task Auto_monochrome_prints_grey_on_a_color_queue()
    {
        var sink = new Sink();
        using var p = new SharedPrinter(Laser with { Color = true }, Id, "Color laser", "DESK", sink);
        Read(await Send(p, PrintJob(PwgDocument(), job: r => r.Keyword("print-color-mode", "auto-monochrome"))));
        Read(await Send(p, PrintJob(PwgDocument(), job: r => r.Keyword("print-color-mode", "auto"))));
        await WaitFor(() => sink.Jobs.Count == 2);
        Assert.Equal([true, false], sink.Jobs.OrderBy(j => j.Monochrome ? 0 : 1).Select(j => j.Monochrome));
    }

    [Fact]
    public async Task A_document_past_the_limit_is_refused()
    {
        using var p = Printer(new Sink(), new PrinterShareLimits { MaxDocumentBytes = 1000 });
        Assert.Equal(SharedPrinter.TooLarge, Read(await Send(p, PrintJob(PwgDocument()))).Status);
    }

    [Fact]
    public async Task Names_from_the_phone_are_one_line_and_bounded()
    {
        var sink = new Sink();
        using var p = Printer(sink);
        var r = new IppRequest(IppCodec.PrintJob, 1, Uri).Name("job-name", "C:\\secret\\a\u202Eb\r\nfake.pdf").JobGroup().ToArray();
        Read(await Send(p, [.. r, .. PwgDocument()]));
        await WaitFor(() => sink.Jobs.Count == 1);
        Assert.Equal("ab fake.pdf", sink.Jobs[0].JobName);
    }

    // ---------------------------------------------------------------- raster documents

    [Theory]
    [InlineData(RasterFormat.PwgRaster, RasterColor.Gray8)]
    [InlineData(RasterFormat.PwgRaster, RasterColor.Rgb8)]
    [InlineData(RasterFormat.Urf, RasterColor.Gray8)]
    [InlineData(RasterFormat.Urf, RasterColor.Rgb8)]
    public void Raster_documents_read_back_pixel_for_pixel(RasterFormat format, RasterColor color)
    {
        var job = new RasterJob(format, 100, color, SharedPrinterMedia.Letter, 21590, 27940, 3);
        var pages = Enumerable.Range(0, 3).Select(i => Page(job.WidthPixels, job.HeightPixels, color, i)).ToList();
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, job);
        foreach (var page in pages) w.Write(page);
        w.Finish();
        var read = (format == RasterFormat.Urf ? RasterReader.ReadUrf(ms.ToArray()) : RasterReader.ReadPwg(ms.ToArray())).ToList();
        Assert.Equal(3, read.Count);
        for (var i = 0; i < 3; i++)
        {
            Assert.Equal(pages[i].Pixels, read[i].Page.Pixels);
            Assert.Equal(100, read[i].DpiX);
            Assert.Equal(8.5, read[i].WidthInches, 1);
        }
    }

    [Fact]
    public void Hostile_raster_is_a_format_error()
    {
        var good = PwgDocument();
        Assert.Throws<FormatException>(() => RasterReader.ReadPwg(good.AsMemory(0, good.Length - 3)).ToList()); // cut short
        Assert.Throws<FormatException>(() => RasterReader.ReadPwg("RaS2"u8.ToArray().Concat(new byte[100]).ToArray()).ToList()); // header cut short
        var huge = (byte[])good.Clone();
        BinaryPrimitives.WriteUInt32BigEndian(huge.AsSpan(4 + 372), 90_000); // width
        BinaryPrimitives.WriteUInt32BigEndian(huge.AsSpan(4 + 376), 90_000); // height
        Assert.Throws<FormatException>(() => RasterReader.ReadPwg(huge).ToList());
        var deep = (byte[])good.Clone();
        BinaryPrimitives.WriteUInt32BigEndian(deep.AsSpan(4 + 384), 16); // 16 bits a color
        Assert.Throws<FormatException>(() => RasterReader.ReadPwg(deep).ToList());
        var slow = (byte[])good.Clone();
        BinaryPrimitives.WriteUInt32BigEndian(slow.AsSpan(4 + 276), 1); // 1 dpi
        Assert.Throws<FormatException>(() => RasterReader.ReadPwg(slow).ToList());
        // A run past the end of its line: one line of 4 pixels, then a run of 128 of the next pixel.
        var urf = new List<byte>("UNIRAST\0"u8.ToArray()) { 0, 0, 0, 1 };
        var h = new byte[32];
        h[0] = 8;
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(12), 4);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(16), 1);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(20), 300);
        urf.AddRange(h);
        urf.AddRange([0, 127, 0]);
        Assert.Throws<FormatException>(() => RasterReader.ReadUrf(urf.ToArray()).ToList());
        Assert.Throws<FormatException>(() => RasterReader.ReadUrf("UNIRAST\0\0\0\0\0"u8.ToArray()).ToList()); // no page
        var many = "UNIRAST\0"u8.ToArray().Concat(new byte[] { 0, 0, 0x10, 0 }).ToArray();
        Assert.Throws<FormatException>(() => RasterReader.ReadUrf(many).ToList()); // says 4096 pages
    }

    [Fact]
    public void Apple_raster_fills_a_line_with_white_on_128()
    {
        var urf = new List<byte>("UNIRAST\0"u8.ToArray()) { 0, 0, 0, 1 };
        var h = new byte[32];
        h[0] = 8;
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(12), 4);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(16), 2);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(20), 300);
        urf.AddRange(h);
        urf.AddRange([1, 0, 7, 128]); // the line twice: one pixel of 7, then white to the end
        var page = Assert.Single(RasterReader.ReadUrf(urf.ToArray())).Page;
        Assert.Equal(new byte[] { 7, 255, 255, 255, 7, 255, 255, 255 }, page.Pixels);
    }

    // ---------------------------------------------------------------- the share

    private sealed class Networks : IShareNetworks
    {
        public List<LocalNetwork> List { get; } = [new(4, IPAddress.Parse("192.0.2.10"), 24, NetworkKind.Private)];
        public IReadOnlyList<LocalNetwork> Read() => List;
        public event Action? Changed;
        public void Raise() => Changed?.Invoke();
    }

    private sealed class Adverts : IShareAdvertiser
    {
        public List<ShareAdvert> Live { get; } = [];

        public Task<IAsyncDisposable> AdvertiseAsync(ShareAdvert advert, IReadOnlyList<LocalNetwork> on, CancellationToken ct)
        {
            lock (Live) Live.Add(advert);
            return Task.FromResult<IAsyncDisposable>(new Gone(() => { lock (Live) Live.Remove(advert); }));
        }

        private sealed class Gone(Action gone) : IAsyncDisposable
        {
            public ValueTask DisposeAsync()
            {
                gone();
                return ValueTask.CompletedTask;
            }
        }
    }

    private sealed class Host : IPrinterShareHost
    {
        public List<PrinterListen> Started { get; } = [];
        public int Open { get; private set; }

        public Task<IShareListener> StartAsync(PrinterListen listen, CancellationToken ct)
        {
            Started.Add(listen);
            Open++;
            return Task.FromResult<IShareListener>(new Listener(listen.Port, () => Open--));
        }

        private sealed class Listener(int port, Action closed) : IShareListener
        {
            public int Port => port;

            public ValueTask DisposeAsync()
            {
                closed();
                return ValueTask.CompletedTask;
            }
        }
    }

    private static SpoolerQueue Queue(string name, string port = "USB001", string driver = "Brother HL-L2350DW series") => new(name, port, driver, 0, 0, 0);

    [Theory]
    [InlineData("USB001", "Brother HL-L2350DW series", true)]
    [InlineData("WSD-1234", "Microsoft IPP Class Driver", true)]
    [InlineData("PORTPROMPT:", "Microsoft Print To PDF", false)]
    [InlineData("FILE:", "HP Universal Printing PCL 6", false)]
    [InlineData("XPSPort:", "Microsoft XPS Document Writer v4", false)]
    [InlineData("Microsoft.Office.OneNoteVirtualPrinter_onenote-psa:print", "Microsoft Virtual Print Class Driver", false)]
    public void Queues_that_save_a_file_or_hand_to_an_app_arent_shared(string port, string driver, bool shared) =>
        Assert.Equal(shared, PrinterShare.CanShare(Queue("q", port, driver)));

    [Fact]
    public async Task Turned_on_it_listens_on_private_networks_and_announces_each_printer()
    {
        var (host, networks, adverts, saved) = (new Host(), new Networks(), new Adverts(), new List<IReadOnlyList<PrinterShareChoice>>());
        var env = new PrinterShareEnvironment(host, networks, adverts, (name, _) => Task.FromResult<SharedQueue?>(Laser with { Name = name }), new Sink());
        await using var share = new PrinterShare(env, "DESK", null, saved.Add);
        Assert.False(share.Card(Queue("Office laser")).IsOn);
        Assert.False(share.Card(Queue("PDF", "PORTPROMPT:", "Microsoft Print To PDF")).IsShown);
        Assert.True(await share.TurnOnAsync(Queue("Office laser")));
        Assert.Equal(PrinterShareState.On, share.State);
        Assert.Equal(PrinterShare.DefaultPort, host.Started.Single().Port);
        Assert.True(host.Started[0].AllowPeer(IPAddress.Parse("192.0.2.77"), IPAddress.Parse("192.0.2.10")));
        Assert.False(host.Started[0].AllowPeer(IPAddress.Parse("198.51.100.7"), IPAddress.Parse("192.0.2.10"))); // not on the subnet
        var advert = Assert.Single(adverts.Live);
        Assert.Equal(ShareAdvert.PrinterService, advert.Kind);
        Assert.Equal("Office laser on DESK", advert.Instance);
        var txt = advert.Txt.ToDictionary(kv => kv.Key, kv => kv.Value);
        Assert.Equal(share.Served[0].Path.TrimStart('/'), txt["rp"]);
        Assert.Equal("F", txt["Color"]);
        Assert.Equal("T", txt["Duplex"]);
        Assert.Contains("image/urf", txt["pdl"]);
        Assert.StartsWith("V1.4,CP1,W8,RS300,DM1", txt["URF"]);
        Assert.Equal(share.Served[0].Uuid.ToString("D"), txt["UUID"]);
        Assert.Single(saved[^1]);
        Assert.Contains("9782", share.Text("Office laser"));

        // A second printer: the same server, both announced; the path picks the printer.
        Assert.True(await share.TurnOnAsync(Queue("Inkjet")));
        Assert.Single(host.Started);
        Assert.Equal(2, adverts.Live.Count);
        var inkjet = share.Served.Single(p => p.Queue.Name == "Inkjet");
        Assert.Equal(404, (await share.HandleAsync(new ShareRequest("POST", "/ipp/print/other", [], Phone), CancellationToken.None)).Status);
        Assert.Equal(200, (await share.HandleAsync(new ShareRequest("GET", inkjet.Path, [], Phone), CancellationToken.None)).Status);

        // The private network goes: nothing listens or is announced; it comes back: both again.
        networks.List[0] = networks.List[0] with { Kind = NetworkKind.Public };
        await share.RecheckAsync();
        Assert.Equal((PrinterShareState.NoPrivateNetwork, 0, 0), (share.State, host.Open, adverts.Live.Count));
        Assert.Equal(CoreStrings.PrinterShare_NoPrivateNetwork, share.Text("Inkjet"));
        networks.List[0] = networks.List[0] with { Kind = NetworkKind.Private };
        await share.RecheckAsync();
        Assert.Equal((PrinterShareState.On, 1, 2), (share.State, host.Open, adverts.Live.Count));

        // A shared queue removed from Windows stops being served; the last one off stops the server.
        await share.OfferAsync(["Office laser"]);
        Assert.Equal(["Office laser"], share.Served.Select(p => p.Queue.Name));
        Assert.Single(adverts.Live);
        await share.TurnOffAsync("Office laser");
        Assert.Equal((PrinterShareState.WaitingForPrinter, 0, 0), (share.State, host.Open, adverts.Live.Count));
        await share.TurnOffAsync("Inkjet");
        Assert.Equal(PrinterShareState.Off, share.State);
        Assert.Empty(saved[^1]);
    }

    [Fact]
    public async Task Kept_choices_start_once_their_queue_is_listed_and_closing_stops_everything()
    {
        var (host, adverts) = (new Host(), new Adverts());
        var env = new PrinterShareEnvironment(host, new Networks(), adverts, (name, _) => Task.FromResult<SharedQueue?>(Laser with { Name = name }), new Sink());
        var share = new PrinterShare(env, "DESK", [new PrinterShareChoice("Office laser", Id)], _ => { });
        Assert.Equal(PrinterShareState.Off, share.State);
        await share.OfferAsync(["Office laser", "Other"]);
        Assert.Equal(PrinterShareState.On, share.State);
        Assert.Equal(SharedPrinter.PathOf(Id), share.Served.Single().Path); // the UUID kept: phones find it again
        await share.DisposeAsync();
        Assert.Equal((0, 0), (host.Open, adverts.Live.Count));
    }

    [Fact]
    public async Task A_queue_that_cant_be_read_says_so_and_is_read_again_with_the_next_list()
    {
        var (host, adverts) = (new Host(), new Adverts());
        var readable = false;
        var env = new PrinterShareEnvironment(host, new Networks(), adverts,
            (name, _) => Task.FromResult(readable ? Laser with { Name = name } : (SharedQueue?)null), new Sink());
        await using var share = new PrinterShare(env, "DESK", null, _ => { });
        Assert.True(await share.TurnOnAsync(Queue("Office laser")));
        Assert.Equal(CoreStrings.PrinterShare_Unreadable, share.Text("Office laser"));
        Assert.Empty(share.Served);
        await share.OfferAsync(["Office laser"]); // the same list: still unreadable, read again
        Assert.Empty(share.Served);
        readable = true;
        await share.OfferAsync(["Office laser"]);
        Assert.Equal(PrinterShareState.On, share.State);
        Assert.Single(share.Served);
        Assert.Contains(PrinterShare.DefaultPort.ToString(), share.Text("Office laser"));
    }

    [Fact]
    public async Task This_pc_only_never_announces_even_when_printers_change()
    {
        var env = new PrinterShareEnvironment(new Host(), new Networks(), new ThrowingAdverts(),
            (name, _) => Task.FromResult<SharedQueue?>(Laser with { Name = name }), new Sink(), Port: 0, LoopbackOnly: true);
        await using var share = new PrinterShare(env, "DESK", null, _ => { });
        await share.TurnOnAsync(Queue("Office laser"));
        await share.TurnOnAsync(Queue("Inkjet")); // the running server's branch
        Assert.Equal(2, share.Served.Count);
        Assert.DoesNotContain(CoreStrings.PrinterShare_NotAnnounced, share.Text("Inkjet"));
    }

    private sealed class ThrowingAdverts : IShareAdvertiser
    {
        public Task<IAsyncDisposable> AdvertiseAsync(ShareAdvert advert, IReadOnlyList<LocalNetwork> on, CancellationToken ct) =>
            throw new InvalidOperationException("nothing is announced for this PC only");
    }

    // ---------------------------------------------------------------- AirPrint's subtype, answered by our own responder

    private static MdnsInstance Instance(string address = "192.0.2.10") =>
        new("_universal", new ShareAdvert("Office laser on DESK", "DESK.local", 9782, [new("rp", "ipp/print/x"), new("URF", "V1.4,W8")], ShareAdvert.PrinterService),
            IPAddress.Parse(address));

    private static byte[] Query(string name, ushort type = 12, bool unicast = false, ushort flags = 0)
    {
        var q = new List<byte> { 0, 0, (byte)(flags >> 8), (byte)flags, 0, 1, 0, 0, 0, 0, 0, 0 };
        q.AddRange(MdnsSubtype.Name(name));
        q.AddRange([(byte)(type >> 8), (byte)type, unicast ? (byte)0x80 : (byte)0, 1]);
        return [.. q];
    }

    [Fact]
    public void A_query_for_the_subtype_gets_the_instance_with_its_srv_txt_and_address()
    {
        var questions = MdnsSubtype.Questions(Query("_universal._sub._ipp._tcp.local"));
        Assert.NotNull(questions);
        var answer = MdnsSubtype.Answer(questions, [Instance()]);
        Assert.NotNull(answer);
        Assert.Equal(0x8400, BinaryPrimitives.ReadUInt16BigEndian(answer.AsSpan(2))); // a response, authoritative
        Assert.Equal(1, BinaryPrimitives.ReadUInt16BigEndian(answer.AsSpan(6)));
        Assert.Equal(3, BinaryPrimitives.ReadUInt16BigEndian(answer.AsSpan(10)));
        var at = 12;
        Assert.Equal("_universal._sub._ipp._tcp.local", MdnsSubtype.ReadName(answer, ref at));
        at += 10; // type, class, TTL, length
        Assert.Equal("office laser on desk._ipp._tcp.local", MdnsSubtype.ReadName(answer, ref at));
        // Anything else isn't ours to answer: Windows answers the plain service, the instance and the host.
        Assert.Null(MdnsSubtype.Answer(MdnsSubtype.Questions(Query("_ipp._tcp.local")), [Instance()]));
        Assert.Null(MdnsSubtype.Answer(MdnsSubtype.Questions(Query("_universal._sub._ipp._tcp.local", type: 16)), [Instance()]));
        Assert.True(MdnsSubtype.Questions(Query("_universal._sub._ipp._tcp.local", unicast: true))![0].Unicast);
    }

    [Fact]
    public void Hostile_mdns_packets_are_dropped()
    {
        Assert.Null(MdnsSubtype.Questions(Query("_universal._sub._ipp._tcp.local", flags: 0x8400))); // a response
        Assert.Null(MdnsSubtype.Questions(Query("_universal._sub._ipp._tcp.local", flags: 0x2800))); // another opcode
        Assert.Null(MdnsSubtype.Questions(Query("_universal._sub._ipp._tcp.local")[..20])); // cut short
        Assert.Null(MdnsSubtype.Questions(new byte[MdnsSubtype.MaxPacket + 1]));
        var many = Query("a.local");
        many[5] = 200; // says 200 questions
        Assert.Null(MdnsSubtype.Questions(many));
        byte[] loop = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 12, 0, 1]; // a name pointing at itself
        Assert.Null(MdnsSubtype.Questions(loop));
        byte[] forward = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 16, 0, 12, 1, (byte)'a', 0, 0, 1];
        Assert.Null(MdnsSubtype.Questions(forward)); // pointers only go back
        var longName = string.Join('.', Enumerable.Repeat(new string('a', 63), 5));
        Assert.Null(MdnsSubtype.Questions(Query(longName))); // past 255 bytes
    }

    [Fact]
    public void Only_a_device_on_the_served_subnet_and_interface_is_answered()
    {
        var net = new LocalNetwork(4, IPAddress.Parse("192.0.2.10"), 24, NetworkKind.Private);
        (MdnsInstance, LocalNetwork)[] registered = [(Instance(), net)];
        Assert.Single(MdnsSubtype.For(registered, IPAddress.Parse("192.0.2.50"), 4));
        Assert.Empty(MdnsSubtype.For(registered, IPAddress.Parse("192.0.2.50"), 7)); // came in on another interface
        Assert.Empty(MdnsSubtype.For(registered, IPAddress.Parse("198.51.100.5"), 4)); // not on the subnet
        var advert = PrinterDnssd.For(new SharedPrinter(Laser, Id, "Office laser on DESK", "DESK", new Sink()), "DESK", PrinterShare.DefaultPort);
        Assert.Equal(["_universal"], advert.Subtypes);
        var goodbye = MdnsSubtype.Answer(null, [Instance()], goodbye: true)!;
        var at = 12;
        MdnsSubtype.ReadName(goodbye, ref at);
        Assert.Equal(0u, BinaryPrimitives.ReadUInt32BigEndian(goodbye.AsSpan(at + 4))); // TTL 0
    }

    [Fact]
    public void The_instance_name_is_one_dns_sd_label()
    {
        var name = PrinterShare.InstanceName("HP.LaserJet\r\n" + new string('é', 80), "DESK");
        Assert.DoesNotContain('.', name);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(name) <= 63);
    }

    // ---------------------------------------------------------------- end to end, over the real server

    [Fact]
    public async Task Our_own_ipp_client_prints_to_a_shared_printer_over_kestrel()
    {
        var sink = new Sink();
        var env = new PrinterShareEnvironment(new KestrelPrinterHost(), new Networks(), new Adverts(),
            (name, _) => Task.FromResult<SharedQueue?>(new SharedQueue(name, Color: true, TwoSided: false)), sink, Port: 0, LoopbackOnly: true);
        await using var share = new PrinterShare(env, "DESK", null, _ => { });
        Assert.True(await share.TurnOnAsync(Queue("Office laser")));
        Assert.Equal(PrinterShareState.On, share.State);
        var printer = share.Served.Single();
        using var http = new DeviceHttp("127.0.0.1");
        var ipp = new IppClient(http, new System.Uri($"http://127.0.0.1:{share.Port}{printer.Path}"));

        // As straight-to-the-printer printing does with a printer: read what it takes, plan, send a raster, follow the job.
        var caps = IppPrintCaps.From(await ipp.GetPrinterAttributesAsync(IppPrintCaps.Requested));
        var plan = DirectPrintPlan.Choose(caps, new DirectPrintRequest(Copies: 2), out var problem);
        Assert.True(plan is not null, problem);
        var raster = new RasterJob(plan!.Format, 100, plan.Color, plan.Paper.Name, plan.Paper.WidthHmm, plan.Paper.HeightHmm, 2);
        using var document = new MemoryStream();
        var w = RasterWriter.For(document, raster);
        w.Write(Page(raster.WidthPixels, raster.HeightPixels, raster.Color, 0));
        w.Write(Page(raster.WidthPixels, raster.HeightPixels, raster.Color, 1));
        w.Finish();
        document.Position = 0;
        var (id, state) = await DirectJob.SendAsync(ipp, "phone", "Two pages", plan, document);
        Assert.Equal(1, id);
        Assert.NotNull(state);
        await WaitFor(() => sink.Jobs.Count == 1);
        var done = await DirectJob.WatchAsync(ipp, "phone", id, null, TimeSpan.FromMilliseconds(50), TimeSpan.FromSeconds(5), CancellationToken.None);
        Assert.Equal(9, done?.State);
        var pages = (plan.Format == RasterFormat.Urf ? RasterReader.ReadUrf(sink.Jobs[0].Document) : RasterReader.ReadPwg(sink.Jobs[0].Document)).ToList();
        Assert.Equal(2, pages.Count);
        Assert.Equal(2, sink.Jobs[0].Copies);

        // Not IPP: refused before anything's read.
        using var plain = new HttpClient();
        var wrongType = await plain.PostAsync($"http://127.0.0.1:{share.Port}{printer.Path}", new StringContent("hello"));
        Assert.Equal(HttpStatusCode.UnsupportedMediaType, wrongType.StatusCode);
    }
}
