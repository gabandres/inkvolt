using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Xml.Linq;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Sharing;
using InkvoltPrint.Core.Wia;
using InkvoltPrint.Sharing;

namespace InkvoltPrint.Tests;

/// <summary>
/// Sharing a scanner on the network (print/ROADMAP.md 3.1): the eSCL documents served and read (ScanSettings as hostile input), the
/// jobs (one scan at a time, a queue limit, each job only its device's, expiry), who may connect, the certificate and the DNS-SD
/// record, the switch (off by default, private networks only, free, closing at once), and scans through the real HTTPS server on
/// loopback with our own eSCL client, page for page the same as the direct scan.
/// </summary>
public class ScannerSharingTests
{
    private static readonly WiaDeviceInfo Usb = new("{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\\0007", "Example Scan 300", "Example", "Example Scan 300", "\\\\.\\Usbscan0");

    /// <summary>Glass and a feeder (both sides), 8.5 × 11.69 in glass, 8.5 × 14 in sheets, 75–1200 dpi, black and white, grey and color.</summary>
    private static readonly WiaScannerInfo Mfp = new(WiaIds.CapFeed | WiaIds.CapFlat | WiaIds.CapDuplex, 8500, 11690, 8500, 14000,
        WiaValues.Range(150, 75, 1200, 25), [WiaIds.DataThreshold, WiaIds.DataGrayscale, WiaIds.DataColor], [WiaIds.FormatBmp]);

    /// <summary>
    /// Each page: a JPEG header (start of image, a 16 × 16 color frame) and what was asked of the driver with its number in the job,
    /// bytes a test compares.
    /// </summary>
    private static FakeWiaScanner Fake(WiaScannerInfo? info = null) =>
        new(Usb, info ?? Mfp, (s, page) => [0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0,
            .. Encoding.UTF8.GetBytes($"{s}|{page}"), 0xFF, 0xD9]);

    private static async Task<WiaScanner> Open(FakeWiaScanner fake, FakeWiaSystem? system = null) =>
        await WiaScanner.OpenAsync(system ?? new FakeWiaSystem([fake]), fake.Device, CancellationToken.None);

    private static async Task<List<byte[]>> All(IAsyncEnumerable<byte[]> pages)
    {
        var list = new List<byte[]>();
        await foreach (var p in pages) list.Add(p);
        return list;
    }

    private static readonly ShareIdentity Identity = new("Example Scan 300", "Example", Guid.Parse("0f6b3d2a-7c1e-4c55-9a51-2b8e44d1c0aa"));
    private static readonly IPAddress Peer = IPAddress.Parse("192.0.2.20"), OtherPeer = IPAddress.Parse("192.0.2.21");

    private static byte[] Settings(string inner) => Encoding.UTF8.GetBytes(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><scan:ScanSettings xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" " +
        "xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\"><pwg:Version>2.63</pwg:Version>" + inner + "</scan:ScanSettings>");

    private static Task<ShareReply> Ask(SharedScanner s, string method, string path, byte[]? body = null, IPAddress? peer = null) =>
        s.HandleAsync(new ShareRequest(method, path, body ?? [], peer ?? Peer, "192.0.2.10:9780"), CancellationToken.None);

    // ---------------------------------------------------------------- the documents

    [Fact]
    public async Task Capabilities_read_back_as_the_scanners_own()
    {
        var scanner = await Open(Fake());
        var doc = ShareXml.Capabilities(scanner.Capabilities, Identity);
        var read = ScannerCapabilities.Parse(DeviceXml.Load(doc));
        var own = scanner.Capabilities;
        Assert.Equal(own.Sources, read.Sources);
        Assert.Equal("Example Scan 300", read.MakeAndModel);
        Assert.Equal("Example", read.Manufacturer);
        Assert.Equal(Identity.Uuid.ToString("D"), read.Uuid);
        foreach (var (mine, theirs) in new[] { (own.Platen!, read.Platen!), (own.Adf!, read.Adf!) })
        {
            Assert.Equal((mine.MinWidth, mine.MaxWidth, mine.MinHeight, mine.MaxHeight), (theirs.MinWidth, theirs.MaxWidth, theirs.MinHeight, theirs.MaxHeight));
            Assert.Equal(mine.ColorModes, theirs.ColorModes);
            Assert.Equal(mine.Resolutions, theirs.Resolutions);
            Assert.True(theirs.OffersJpeg);
            Assert.Contains("application/pdf", theirs.DocumentFormats);
            Assert.True(theirs.HasDocumentFormatExt);
        }
        Assert.True(read.AdfDuplex);
    }

    [Fact]
    public async Task Settings_our_client_writes_read_back_as_the_same_scan()
    {
        var caps = (await Open(Fake())).Capabilities;
        foreach (var request in new[]
        {
            new ScanRequest(ScanSource.Platen, ScanColor.Color, 300),
            new ScanRequest(ScanSource.Adf, ScanColor.Grayscale, 200),
            new ScanRequest(ScanSource.AdfDuplex, ScanColor.BlackAndWhite, 600, "Photo", 1200, 1500),
        })
        {
            var xml = EsclXml.BuildScanSettings(request, caps);
            var body = Encoding.UTF8.GetBytes(xml.Declaration + xml.Root!.ToString());
            var read = ShareXml.ReadSettings(body, caps);
            var input = caps.For(request.Source)!;
            Assert.Equal(request.Source, read.Request.Source);
            Assert.Equal(request.Color, read.Request.Color);
            Assert.Equal(request.Resolution, read.Request.Resolution);
            Assert.Equal(request.Width ?? input.MaxWidth, read.Request.Width);
            Assert.Equal(request.Height ?? input.MaxHeight, read.Request.Height);
            Assert.Equal("image/jpeg", read.Format);
            // Planned for the driver, the same as the direct scan.
            Assert.Equal(WiaCapabilities.Plan(request, caps, Mfp), WiaCapabilities.Plan(read.Request, caps, Mfp));
        }
    }

    [Fact]
    public async Task A_region_with_an_offset_reaches_the_driver()
    {
        var caps = (await Open(Fake())).Capabilities;
        var read = ShareXml.ReadSettings(Settings(
            "<pwg:ScanRegions><pwg:ScanRegion><pwg:Height>900</pwg:Height><pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>" +
            "<pwg:Width>600</pwg:Width><pwg:XOffset>300</pwg:XOffset><pwg:YOffset>150</pwg:YOffset></pwg:ScanRegion></pwg:ScanRegions>" +
            "<pwg:InputSource>Platen</pwg:InputSource><scan:ColorMode>RGB24</scan:ColorMode><scan:XResolution>200</scan:XResolution>" +
            "<scan:YResolution>200</scan:YResolution><pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>"), caps);
        Assert.Equal("application/pdf", read.Format);
        var plan = WiaCapabilities.Plan(read.Request, caps, Mfp);
        Assert.Equal((200, 100, 400, 600), (plan.X, plan.Y, plan.Width, plan.Height)); // pixels at 200 dpi
        // An offset past the source is kept inside it, and the width shrinks to what's left.
        var far = WiaCapabilities.Plan(new ScanRequest(Width: 2550, XOffset: 2500, Resolution: 300), caps, Mfp);
        Assert.Equal((2500, 50), (far.X, far.Width));
        // TWAIN's frame starts at the offset too.
        var twain = Core.Twain.TwainSettings.From(plan);
        Assert.Equal((1.0, 0.5, 3.0, 3.5), (twain.Left, twain.Top, twain.Right, twain.Bottom));
    }

    [Theory]
    [InlineData("<!DOCTYPE x [<!ENTITY a \"aaaa\">]>", 400)] // a DTD: refused before anything is expanded
    [InlineData("<scan:Intent>&a;</scan:Intent>", 400)] // an entity it never declared
    [InlineData("<pwg:InputSource>Camera</pwg:InputSource>", 409)]
    [InlineData("<scan:ColorMode>CMYK32</scan:ColorMode>", 409)]
    [InlineData("<pwg:DocumentFormat>image/tiff</pwg:DocumentFormat>", 409)]
    [InlineData("<scan:XResolution>-5</scan:XResolution>", 400)]
    [InlineData("<scan:XResolution>99999999999</scan:XResolution>", 400)]
    [InlineData("<scan:XResolution>3e2</scan:XResolution>", 400)]
    [InlineData("<pwg:ScanRegions><pwg:ScanRegion><pwg:ContentRegionUnits>escl:Millimeters</pwg:ContentRegionUnits></pwg:ScanRegion></pwg:ScanRegions>", 400)]
    [InlineData("<pwg:ScanRegions><pwg:ScanRegion><pwg:Width>0</pwg:Width></pwg:ScanRegion></pwg:ScanRegions>", 400)]
    public async Task Hostile_or_unoffered_settings_are_refused(string inner, int status)
    {
        var caps = (await Open(Fake())).Capabilities;
        var body = inner.StartsWith("<!DOCTYPE", StringComparison.Ordinal)
            ? Encoding.UTF8.GetBytes("<?xml version=\"1.0\"?>" + inner + "<scan:ScanSettings xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\">&a;</scan:ScanSettings>")
            : Settings(inner);
        var ex = Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(body, caps));
        Assert.Equal(status, ex.Status);
    }

    [Fact]
    public async Task Settings_too_long_too_deep_or_too_many_are_refused_unread()
    {
        var caps = (await Open(Fake())).Capabilities;
        Assert.Equal(400, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(new byte[ShareXml.MaxSettingsBytes + 1], caps)).Status);
        Assert.Equal(400, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings([], caps)).Status);
        var deep = string.Concat(Enumerable.Repeat("<x>", 20)) + string.Concat(Enumerable.Repeat("</x>", 20));
        Assert.Equal(400, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(Settings(deep), caps)).Status);
        var many = string.Concat(Enumerable.Repeat("<x/>", ShareXml.MaxElements + 1));
        Assert.Equal(400, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(Settings(many), caps)).Status);
        var longText = $"<scan:Intent>{new string('a', ShareXml.MaxText + 1)}</scan:Intent>";
        Assert.Equal(400, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(Settings(longText), caps)).Status);
        Assert.Equal(400, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings("<ScanSettings/>"u8, caps)).Status); // no eSCL namespace
        Assert.Equal(400, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings("<not xml"u8, caps)).Status);
        // Duplex on a scanner without it.
        var simplex = WiaCapabilities.From(Mfp with { Handling = WiaIds.CapFeed | WiaIds.CapFlat }, "Example");
        Assert.Equal(409, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(
            Settings("<pwg:InputSource>Feeder</pwg:InputSource><scan:Duplex>true</scan:Duplex>"), simplex)).Status);
    }

    [Fact]
    public async Task A_feeder_only_scanner_scans_its_feeder_when_no_source_is_named()
    {
        var caps = (await Open(Fake(Mfp with { Handling = WiaIds.CapFeed }))).Capabilities;
        Assert.Equal(ScanSource.Adf, ShareXml.ReadSettings(Settings(""), caps).Request.Source);
    }

    // ---------------------------------------------------------------- the jobs

    [Fact]
    public async Task A_job_gives_its_pages_then_404_and_only_to_its_device()
    {
        var fake = Fake();
        using var share = new SharedScanner(await Open(fake), (await Open(fake)).Capabilities, Identity);
        var created = await Ask(share, "POST", "/eSCL/ScanJobs", Settings("<pwg:InputSource>Feeder</pwg:InputSource>"));
        Assert.Equal(201, created.Status);
        Assert.StartsWith("https://192.0.2.10:9780/eSCL/ScanJobs/", created.Location);
        var job = new Uri(created.Location!).AbsolutePath;
        Assert.Equal(404, (await Ask(share, "GET", job + "/NextDocument", peer: OtherPeer)).Status); // not that device's job
        Assert.Equal(404, (await Ask(share, "DELETE", job, peer: OtherPeer)).Status);
        var pages = new List<byte[]>();
        for (var reply = await Ask(share, "GET", job + "/NextDocument"); reply.Status == 200; reply = await Ask(share, "GET", job + "/NextDocument"))
        {
            Assert.Equal("image/jpeg", reply.ContentType);
            pages.Add(reply.Body!);
        }
        Assert.Equal(3, pages.Count);
        Assert.Equal(404, (await Ask(share, "GET", job + "/NextDocument")).Status);
        var status = DeviceXml.Load((await Ask(share, "GET", "/eSCL/ScannerStatus")).Body!);
        Assert.Contains("Completed", status.Root!.ToString());
        Assert.DoesNotContain("ScanJobs", DeviceXml.Load((await Ask(share, "GET", "/eSCL/ScannerStatus", peer: OtherPeer)).Body!).Root!.ToString());
    }

    [Theory]
    [InlineData("GET", "/eSCL/ScanJobs")]
    [InlineData("POST", "/eSCL/ScannerCapabilities")]
    [InlineData("PUT", "/eSCL/ScannerStatus")]
    public async Task Wrong_methods_are_405(string method, string path)
    {
        var fake = Fake();
        using var share = new SharedScanner(await Open(fake), (await Open(fake)).Capabilities, Identity);
        Assert.Equal(405, (await Ask(share, method, path)).Status);
    }

    [Theory]
    [InlineData("/")]
    [InlineData("/eSCL/../../Windows/win.ini")]
    [InlineData("/eSCL/ScanJobs/..%2F..%2Fwin.ini/NextDocument")]
    [InlineData("/eSCL/ScanJobs/not-a-job/NextDocument")]
    [InlineData("/eSCL/ScanJobs/00000000000000000000000000000000/NextDocument")]
    [InlineData("/escl/ScannerCapabilities")]
    [InlineData("/eSCL/ScannerIcon")]
    public async Task Anything_else_is_404(string path)
    {
        var fake = Fake();
        using var share = new SharedScanner(await Open(fake), (await Open(fake)).Capabilities, Identity);
        Assert.Equal(404, (await Ask(share, "GET", path)).Status);
    }

    /// <summary>A scanner connected, then hanging in its driver: a job on it holds the scanner until it's cancelled.</summary>
    private static async Task<(WiaScanner Scanner, FakeWiaScanner Fake)> Hung()
    {
        var fake = Fake();
        var scanner = await Open(fake);
        fake.Hangs = true;
        return (scanner, fake);
    }

    [Fact]
    public async Task One_scan_at_a_time_and_a_full_queue_is_told_to_wait()
    {
        var (scanner, _) = await Hung(); // the first job holds the scanner
        using var share = new SharedScanner(scanner, scanner.Capabilities, Identity, new ShareLimits { MaxQueued = 2, MaxJobsPerPeer = 10 });
        var body = Settings("");
        Assert.Equal(201, (await Ask(share, "POST", "/eSCL/ScanJobs", body)).Status);
        Assert.Equal(201, (await Ask(share, "POST", "/eSCL/ScanJobs", body)).Status);
        Assert.Equal(201, (await Ask(share, "POST", "/eSCL/ScanJobs", body)).Status);
        var full = await Ask(share, "POST", "/eSCL/ScanJobs", body);
        Assert.Equal(503, full.Status);
        Assert.NotNull(full.RetryAfterSeconds);
        Assert.Equal(3, share.ActiveJobs);
        await WaitFor(() => scanner.IsBusy);
        var status = DeviceXml.Load((await Ask(share, "GET", "/eSCL/ScannerStatus")).Body!).Root!;
        Assert.Equal("Processing", status.Elements().First(e => e.Name.LocalName == "State").Value);
        Assert.Single(status.Descendants(), e => e.Name.LocalName == "JobState" && e.Value == "Processing"); // one scans, two wait
        Assert.Equal(2, status.Descendants().Count(e => e.Name.LocalName == "JobState" && e.Value == "Pending"));
    }

    [Fact]
    public async Task One_device_can_hold_only_a_few_jobs()
    {
        var (scanner, _) = await Hung();
        using var share = new SharedScanner(scanner, scanner.Capabilities, Identity, new ShareLimits { MaxJobsPerPeer = 2, MaxQueued = 5 });
        Assert.Equal(201, (await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Status);
        Assert.Equal(201, (await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Status);
        Assert.Equal(503, (await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Status);
        Assert.Equal(201, (await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""), OtherPeer)).Status);
    }

    [Fact]
    public async Task A_job_nobody_reads_expires_and_lets_the_scanner_go()
    {
        var (scanner, fake) = await Hung();
        var time = new ManualTime();
        using var share = new SharedScanner(scanner, scanner.Capabilities, Identity,
            new ShareLimits { IdleLimit = TimeSpan.FromSeconds(60), KeepFinished = TimeSpan.FromMinutes(5) }, time);
        var job = new Uri((await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Location!).AbsolutePath;
        Assert.Equal(1, share.ActiveJobs);
        time.Advance(TimeSpan.FromSeconds(59));
        await Ask(share, "GET", "/eSCL/ScannerCapabilities");
        Assert.Equal(1, share.ActiveJobs); // not yet
        time.Advance(TimeSpan.FromSeconds(2));
        await Ask(share, "GET", "/eSCL/ScannerCapabilities"); // any request sweeps (and a timer, every few seconds)
        await WaitFor(() => share.ActiveJobs == 0 && !scanner.IsBusy);
        Assert.Equal(404, (await Ask(share, "GET", job + "/NextDocument")).Status);
        time.Advance(TimeSpan.FromMinutes(6));
        await Ask(share, "GET", "/eSCL/ScannerCapabilities");
        Assert.Equal(0, share.KeptJobs); // forgotten
        fake.Hangs = false; // the scanner is free for the next job
        var next = new Uri((await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Location!).AbsolutePath;
        Assert.Equal(200, (await Ask(share, "GET", next + "/NextDocument")).Status);
    }

    [Fact]
    public async Task Delete_cancels_the_scan()
    {
        var (scanner, fake) = await Hung();
        using var share = new SharedScanner(scanner, scanner.Capabilities, Identity);
        var job = new Uri((await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Location!).AbsolutePath;
        Assert.Equal(200, (await Ask(share, "DELETE", job)).Status);
        await WaitFor(() => share.ActiveJobs == 0 && !scanner.IsBusy);
        fake.Hangs = false;
        Assert.Equal(404, (await Ask(share, "GET", job + "/NextDocument")).Status);
        Assert.Contains("Canceled", DeviceXml.Load((await Ask(share, "GET", "/eSCL/ScannerStatus")).Body!).Root!.ToString());
    }

    [Fact]
    public async Task A_scan_that_fails_says_so_and_the_server_goes_on()
    {
        var fake = Fake();
        fake.FailAtPage = 0;
        var scanner = await Open(fake);
        using var share = new SharedScanner(scanner, scanner.Capabilities, Identity);
        var job = new Uri((await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Location!).AbsolutePath;
        Assert.Equal(409, (await Ask(share, "GET", job + "/NextDocument")).Status);
        Assert.Contains("Aborted", DeviceXml.Load((await Ask(share, "GET", "/eSCL/ScannerStatus")).Body!).Root!.ToString());
        fake.FailAtPage = null;
        var next = new Uri((await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Location!).AbsolutePath;
        Assert.Equal(200, (await Ask(share, "GET", next + "/NextDocument")).Status);
    }

    [Fact]
    public async Task A_scan_from_this_PC_holds_the_scanner_and_the_network_waits()
    {
        var fake = Fake();
        var system = new FakeWiaSystem([fake]);
        var here = await Open(fake, system);
        var shared = await Open(fake, system);
        fake.Hangs = true;
        using var cts = new CancellationTokenSource();
        var local = All(here.ScanAsync(new ScanRequest(), cts.Token)); // this PC's scan, hanging in the driver
        await WaitFor(() => shared.IsBusy);
        // The same scanner can't start a second job meanwhile...
        await Assert.ThrowsAsync<ScanException>(() => All(shared.ScanAsync(new ScanRequest())));
        // ...and a device on the network is told to come back.
        using var share = new SharedScanner(shared, shared.Capabilities, Identity, busyElsewhere: () => shared.IsBusy);
        Assert.Equal(503, (await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Status);
        Assert.Contains("Processing", DeviceXml.Load((await Ask(share, "GET", "/eSCL/ScannerStatus")).Body!).Root!.ToString());
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => local);
        Assert.False(shared.IsBusy);
    }

    [Fact]
    public async Task Disposed_it_answers_nothing_and_lets_the_scanner_go()
    {
        var (scanner, _) = await Hung();
        var share = new SharedScanner(scanner, scanner.Capabilities, Identity);
        await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""));
        await WaitFor(() => scanner.IsBusy);
        share.Dispose();
        Assert.Equal(503, (await Ask(share, "GET", "/eSCL/ScannerCapabilities")).Status);
        Assert.Equal(0, share.KeptJobs);
        await WaitFor(() => !scanner.IsBusy);
    }

    // ---------------------------------------------------------------- who may connect

    private static readonly LocalNetwork Home = new(7, IPAddress.Parse("192.168.1.20"), 24, NetworkKind.Private);
    private static readonly LocalNetwork Cafe = new(9, IPAddress.Parse("10.0.0.5"), 16, NetworkKind.Public);
    private static readonly LocalNetwork HomeV6 = new(7, IPAddress.Parse("fe80::1%7"), 64, NetworkKind.Private);
    private static readonly LocalNetwork HomeUla = new(7, IPAddress.Parse("fd00:1:2:3::20"), 64, NetworkKind.Private);

    [Theory]
    [InlineData("192.168.1.33", "192.168.1.20", true)]
    [InlineData("::ffff:192.168.1.33", "::ffff:192.168.1.20", true)] // IPv4 on a dual-mode socket
    [InlineData("127.0.0.1", "127.0.0.1", true)] // this PC
    [InlineData("::1", "::1", true)]
    [InlineData("127.0.0.1", "192.168.1.20", false)] // loopback arrives on loopback, nowhere else
    [InlineData("192.168.2.33", "192.168.1.20", false)] // another subnet
    [InlineData("10.0.3.4", "10.0.0.5", false)] // the public network's subnet
    [InlineData("10.0.3.4", "192.168.1.20", false)]
    [InlineData("8.8.8.8", "192.168.1.20", false)]
    [InlineData("fe80::2%7", "fe80::1%7", true)] // link-local on the private interface
    [InlineData("fe80::2%9", "fe80::1%7", false)] // link-local on another interface
    [InlineData("fe80::2", "fe80::1%7", false)] // no interface said
    [InlineData("fd00:1:2:3::99", "fd00:1:2:3::20", true)]
    [InlineData("192.168.1.33", "192.168.1.21", false)] // an address this PC doesn't serve on
    [InlineData("fd00:1:2:4::99", "fd00:1:2:3::20", false)]
    public void Only_this_PC_and_private_subnets_may_connect(string peer, string local, bool allowed)
    {
        var served = SharePeers.Served([Home, Cafe, HomeV6, HomeUla]);
        Assert.DoesNotContain(Cafe, served);
        Assert.Equal(allowed, SharePeers.Allows(IPAddress.Parse(peer), IPAddress.Parse(local), served));
    }

    [Fact]
    public void A_public_network_with_the_same_subnet_as_the_private_one_is_refused()
    {
        // Home and the café both hand out 192.168.1.x: a device in the café reaches this PC's café address.
        var cafeSameSubnet = new LocalNetwork(9, IPAddress.Parse("192.168.1.77"), 24, NetworkKind.Public);
        var served = SharePeers.Served([Home, cafeSameSubnet]);
        Assert.False(SharePeers.Allows(IPAddress.Parse("192.168.1.33"), IPAddress.Parse("192.168.1.77"), served));
        Assert.True(SharePeers.Allows(IPAddress.Parse("192.168.1.33"), IPAddress.Parse("192.168.1.20"), served));
        // And a peer on the private subnet whose connection came in on another interface (routed) isn't let in either.
        var lab = new LocalNetwork(11, IPAddress.Parse("10.1.0.2"), 16, NetworkKind.Private);
        Assert.False(SharePeers.Allows(IPAddress.Parse("192.168.1.33"), IPAddress.Parse("10.1.0.2"), SharePeers.Served([Home, lab])));
    }

    [Fact]
    public void Public_networks_domains_and_odd_prefixes_are_not_served()
    {
        Assert.Empty(SharePeers.Served([Cafe, Home with { Kind = NetworkKind.Domain }, Home with { PrefixLength = 0 }, Home with { PrefixLength = 32 },
            new LocalNetwork(1, IPAddress.Loopback, 8, NetworkKind.Private)]));
        Assert.False(SharePeers.Allows(IPAddress.Parse("192.168.1.33"), IPAddress.Parse("192.168.1.20"), []));
    }

    // ---------------------------------------------------------------- the certificate and the announcement

    [Fact]
    public void The_certificate_is_self_signed_for_this_PC_with_a_fingerprint_to_compare()
    {
        var now = DateTimeOffset.UtcNow;
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var cert = ShareCertificate.Create(key, "office-pc.local", now);
        Assert.True(ShareCertificate.Usable(cert, now));
        Assert.False(ShareCertificate.Usable(cert, now.AddDays(800))); // renewed before its end
        Assert.True(cert.NotAfter - cert.NotBefore <= TimeSpan.FromDays(826));
        var san = cert.Extensions.Single(e => e.Oid?.Value == "2.5.29.17");
        Assert.Contains("office-pc.local", new X509SubjectAlternativeNameExtension(san.RawData, san.Critical).EnumerateDnsNames());
        var fingerprint = ShareCertificate.Fingerprint(cert);
        Assert.Matches("^([0-9A-F]{2}:){31}[0-9A-F]{2}$", fingerprint);
        Assert.Equal(Convert.ToHexString(SHA256.HashData(cert.RawData)), fingerprint.Replace(":", ""));
    }

    [Fact]
    public async Task The_announcement_is_uscans_with_what_clients_read()
    {
        var caps = (await Open(Fake())).Capabilities;
        var advert = ShareDnssd.For(Identity, caps, "OFFICE-PC", 9780);
        Assert.Equal("_uscans._tcp", ShareAdvert.Service);
        Assert.Equal("Example Scan 300 on OFFICE-PC", advert.Instance);
        Assert.Equal("OFFICE-PC.local", advert.Host);
        var txt = advert.Txt.ToDictionary(kv => kv.Key, kv => kv.Value);
        Assert.Equal("eSCL", txt["rs"]);
        Assert.Equal(Identity.Uuid.ToString("D"), txt["UUID"]);
        Assert.Equal("binary,grayscale,color", txt["cs"]);
        Assert.Equal("platen,adf", txt["is"]);
        Assert.Equal("T", txt["duplex"]);
        Assert.Equal("image/jpeg,application/pdf", txt["pdl"]);
        // What Inkvolt Print's own discovery makes of it: the share's eSCL root over HTTPS.
        var service = new Core.Discovery.DnssdService(ShareAdvert.Service, txt["UUID"], advert.Host, "192.0.2.10", advert.Port, txt);
        Assert.Equal("https://192.0.2.10:9780/eSCL/", Core.Discovery.DnssdJoin.EsclRoot(service, "192.0.2.10")!.AbsoluteUri);
    }

    [Theory]
    [InlineData("A.B\\C", "PC", "A B C on PC")]
    [InlineData("Scanner\u0007", "PC", "Scanner on PC")]
    public void Instance_names_have_no_dots_or_control_characters(string scanner, string pc, string expected) =>
        Assert.Equal(expected, ShareDnssd.InstanceName(scanner, pc));

    [Fact]
    public void Long_names_are_cut_to_63_bytes_between_characters()
    {
        var name = ShareDnssd.InstanceName(new string('é', 40) + "😀😀", "PC");
        Assert.True(Encoding.UTF8.GetByteCount(name) <= 63);
        Assert.DoesNotContain('�', Encoding.UTF8.GetString(Encoding.UTF8.GetBytes(name)));
        Assert.Equal("my-pc-1.local", ShareDnssd.HostName("my pc_1"));
        Assert.Equal("inkvolt-print.local", ShareDnssd.HostName("..."));
    }

    // ---------------------------------------------------------------- the switch

    private sealed class FakeNetworks : IShareNetworks
    {
        private Action? _changed;

        public List<LocalNetwork> Now { get; set; } = [Home];
        public IReadOnlyList<LocalNetwork> Read() => Now;

        public event Action? Changed
        {
            add { _changed += value; Listeners++; }
            remove { _changed -= value; Listeners--; }
        }

        /// <summary>Who hears changes now (Windows' adapter polls only while someone does).</summary>
        public int Listeners { get; private set; }

        public void Raise() => _changed?.Invoke();
    }

    /// <summary>Announces nothing until cancelled (DNS-SD that never confirms).</summary>
    private sealed class HangingAdvertiser : IShareAdvertiser
    {
        public bool Cancelled { get; private set; }

        public async Task<IAsyncDisposable> AdvertiseAsync(ShareAdvert advert, IReadOnlyList<LocalNetwork> on, CancellationToken ct)
        {
            try
            {
                await Task.Delay(Timeout.Infinite, ct);
            }
            catch (OperationCanceledException)
            {
                Cancelled = true;
                throw;
            }
            throw new InvalidOperationException("Never.");
        }
    }

    private sealed class FakeListener(int port) : IShareListener
    {
        public int Port { get; } = port;
        public bool Closed { get; private set; }

        public ValueTask DisposeAsync()
        {
            Closed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class FakeHost : IShareHost
    {
        public List<(ShareListen Listen, FakeListener Listener)> Started { get; } = [];
        public bool PortTaken { get; set; }

        public Task<IShareListener> StartAsync(ShareListen listen, CancellationToken ct)
        {
            if (PortTaken) throw new SocketException((int)SocketError.AddressAlreadyInUse);
            var listener = new FakeListener(listen.Port);
            Started.Add((listen, listener));
            return Task.FromResult<IShareListener>(listener);
        }

        public bool Listening => Started.Count > 0 && !Started[^1].Listener.Closed;
    }

    private sealed class FakeAdvertiser : IShareAdvertiser
    {
        public List<(ShareAdvert Advert, IReadOnlyList<LocalNetwork> On, Closer Closer)> Adverts { get; } = [];

        public Task<IAsyncDisposable> AdvertiseAsync(ShareAdvert advert, IReadOnlyList<LocalNetwork> on, CancellationToken ct)
        {
            var closer = new Closer();
            Adverts.Add((advert, on, closer));
            return Task.FromResult<IAsyncDisposable>(closer);
        }

        public bool Announced => Adverts.Count > 0 && !Adverts[^1].Closer.Closed;

        public sealed class Closer : IAsyncDisposable
        {
            public bool Closed { get; private set; }

            public ValueTask DisposeAsync()
            {
                Closed = true;
                return ValueTask.CompletedTask;
            }
        }
    }

    private sealed class EphemeralCertificates : IShareCertificates
    {
        public X509Certificate2 Get(string hostName, DateTimeOffset now) => ShareCertificate.Ephemeral(hostName, now);
    }

    private static (ScannerShare Share, FakeHost Host, FakeAdvertiser Ads, FakeNetworks Nets, List<ScannerShareChoice> Saved) Switch(
        ScannerShareChoice? choice = null)
    {
        var host = new FakeHost();
        var ads = new FakeAdvertiser();
        var nets = new FakeNetworks();
        var saved = new List<ScannerShareChoice>();
        var share = new ScannerShare(new ShareEnvironment(host, nets, ads, new EphemeralCertificates()), "OFFICE-PC", choice, saved.Add);
        return (share, host, ads, nets, saved);
    }

    [Fact]
    public async Task Off_by_default_nothing_listens()
    {
        var (share, host, ads, _, _) = Switch();
        await share.OfferAsync(Usb.Id, await Open(Fake()));
        Assert.Equal(ShareState.Off, share.State);
        Assert.False(share.IsOn);
        Assert.Empty(host.Started);
        Assert.Empty(ads.Adverts);
        Assert.Equal(CoreStrings.Share_Off, share.Text(Usb.Id));
    }

    [Fact]
    public async Task Turned_on_it_listens_on_its_port_announces_and_shows_the_fingerprint()
    {
        var (share, host, ads, _, saved) = Switch();
        await share.ShareAsync(await Open(Fake()));
        Assert.Equal(ShareState.On, share.State);
        Assert.True(host.Listening);
        Assert.Equal(ScannerShare.DefaultPort, host.Started[0].Listen.Port);
        Assert.Equal(IPAddress.IPv6Any, host.Started[0].Listen.Address);
        Assert.True(ads.Announced);
        Assert.Equal([Home], ads.Adverts[0].On);
        Assert.Equal(ScannerShare.DefaultPort, ads.Adverts[0].Advert.Port);
        Assert.Equal(ShareCertificate.Fingerprint(host.Started[0].Listen.Certificate), share.Fingerprint);
        Assert.Equal(Usb.Id, saved[^1].DeviceId);
        Assert.NotNull(saved[^1].Uuid);
        Assert.Contains("9780", share.Text(Usb.Id));
        // Who may connect follows the private networks.
        Assert.True(host.Started[0].Listen.AllowPeer(IPAddress.Parse("192.168.1.40"), Home.Address));
        Assert.False(host.Started[0].Listen.AllowPeer(IPAddress.Parse("10.0.0.40"), Home.Address));
    }

    [Fact]
    public async Task Turned_off_the_port_closes_and_the_announcement_ends_at_once()
    {
        var (share, host, ads, _, saved) = Switch();
        await share.ShareAsync(await Open(Fake()));
        await share.StopAsync();
        Assert.False(host.Listening);
        Assert.False(ads.Announced);
        Assert.Equal(ShareState.Off, share.State);
        Assert.Null(saved[^1].DeviceId);
        Assert.Equal(saved[0].Uuid, saved[^1].Uuid); // kept for the next time
    }

    [Fact]
    public async Task On_a_public_network_only_nothing_listens_until_a_private_one_comes()
    {
        var (share, host, ads, nets, _) = Switch();
        nets.Now = [Cafe];
        await share.ShareAsync(await Open(Fake()));
        Assert.Equal(ShareState.NoPrivateNetwork, share.State);
        Assert.Empty(host.Started);
        Assert.Equal(CoreStrings.Share_NoPrivateNetwork, share.Text(Usb.Id));
        nets.Now = [Cafe, Home];
        await share.RecheckAsync();
        Assert.True(host.Listening);
        Assert.Equal([Home], ads.Adverts[^1].On);
        // The private network goes (the laptop moved to the café): the port closes.
        nets.Now = [Cafe];
        await share.RecheckAsync();
        Assert.False(host.Listening);
        Assert.False(ads.Announced);
        Assert.Equal(ShareState.NoPrivateNetwork, share.State);
    }

    [Fact]
    public async Task A_second_private_network_is_announced_on_without_reopening_the_port()
    {
        var (share, host, ads, nets, _) = Switch();
        await share.ShareAsync(await Open(Fake()));
        nets.Now = [Home, HomeUla];
        await share.RecheckAsync();
        Assert.Single(host.Started);
        Assert.True(host.Listening);
        Assert.Equal(2, ads.Adverts.Count);
        Assert.True(ads.Adverts[0].Closer.Closed);
        Assert.Equal(2, ads.Adverts[^1].On.Count);
    }

    [Fact]
    public async Task Sharing_is_free_no_key_is_asked()
    {
        // The owner's decision of 2026-11-22: sharing a scanner is free. The share asks nothing of Inkvolt Pro, and Pro has no such feature.
        var (share, host, _, _, _) = Switch();
        Assert.Equal(ShareSwitch.On, await share.TurnOnAsync(await Open(Fake())));
        Assert.Equal(ShareState.On, share.State);
        Assert.True(host.Listening);
        Assert.DoesNotContain("ScannerSharing", Enum.GetNames<ProFeature>());
    }

    [Fact]
    public async Task Kept_on_it_waits_for_the_scanner_and_stops_when_it_goes()
    {
        var (share, host, _, _, _) = Switch(new ScannerShareChoice(Usb.Id, Usb.Name, Guid.NewGuid()));
        Assert.True(share.IsOn);
        await share.RecheckAsync();
        Assert.Equal(ShareState.WaitingForScanner, share.State);
        Assert.Empty(host.Started);
        await share.OfferAsync("another-scanner", await Open(Fake()));
        Assert.Empty(host.Started);
        await share.OfferAsync(Usb.Id, await Open(Fake()));
        Assert.True(host.Listening);
        await share.OfferAsync(Usb.Id, null); // unplugged
        Assert.False(host.Listening);
        Assert.Equal(ShareState.WaitingForScanner, share.State);
    }

    [Fact]
    public async Task One_scanner_at_a_time()
    {
        var (share, host, _, _, _) = Switch();
        await share.ShareAsync(await Open(Fake()));
        var other = new FakeWiaScanner(Usb with { Id = "other", Name = "Photo Scanner" }, Mfp, (_, _) => [1]);
        await share.ShareAsync(await Open(other));
        Assert.Equal(2, host.Started.Count);
        Assert.True(host.Started[0].Listener.Closed);
        Assert.True(host.Listening);
        Assert.True(share.IsShared("other"));
        Assert.Equal(string.Format(CoreStrings.Share_OtherShared, "Photo Scanner"), share.Text(Usb.Id));
    }

    [Fact]
    public async Task A_taken_port_is_said_and_nothing_is_left_open()
    {
        var (share, host, ads, _, _) = Switch();
        host.PortTaken = true;
        await share.ShareAsync(await Open(Fake()));
        Assert.Equal(ShareState.Failed, share.State);
        Assert.Equal(string.Format(CoreStrings.Share_PortInUse, ScannerShare.DefaultPort), share.Text(Usb.Id));
        Assert.Empty(ads.Adverts);
    }

    [Fact]
    public async Task The_app_closing_closes_the_port_and_keeps_the_choice()
    {
        var (share, host, ads, nets, saved) = Switch();
        await share.ShareAsync(await Open(Fake()));
        var count = saved.Count;
        await share.DisposeAsync();
        Assert.False(host.Listening);
        Assert.False(ads.Announced);
        Assert.Equal(count, saved.Count);
        // Nothing starts again after it closed: not a network change, not the scanner coming back.
        nets.Raise();
        await share.OfferAsync(Usb.Id, await Open(Fake()));
        await share.RecheckAsync();
        Assert.Single(host.Started);
    }

    // ---------------------------------------------------------------- over HTTPS on loopback, with our own eSCL client

    private static async Task<(IShareListener Listener, SharedScanner Server, X509Certificate2 Cert)> Serve(WiaScanner scanner, Func<IPAddress, IPAddress, bool>? allow = null)
    {
        var cert = ShareCertificate.Ephemeral("localhost", DateTimeOffset.UtcNow);
        var server = new SharedScanner(scanner, scanner.Capabilities, Identity, busyElsewhere: () => scanner.IsBusy);
        var listener = await new KestrelShareHost().StartAsync(new ShareListen(IPAddress.Loopback, 0, cert, allow ?? ((peer, local) => SharePeers.Allows(peer, local, [])), server), CancellationToken.None);
        return (listener, server, cert);
    }

    private static EsclClient Client(int port) => new(new DeviceHttp("127.0.0.1"), new Uri($"https://127.0.0.1:{port}/eSCL/"));

    [Fact]
    public async Task Our_client_scans_through_the_shared_endpoint_identical_to_the_direct_scan()
    {
        var fake = Fake();
        var system = new FakeWiaSystem([fake]);
        var direct = await Open(fake, system);
        var (listener, server, cert) = await Serve(await Open(fake, system));
        await using (listener)
        using (server)
        using (cert)
        {
            var client = Client(listener.Port);
            var caps = (await client.GetCapabilitiesAsync())!;
            Assert.Equal(direct.Capabilities.Sources, caps.Sources);
            Assert.Equal(direct.Capabilities.Platen!.Resolutions, caps.Platen!.Resolutions);
            Assert.Equal(direct.Capabilities.Adf!.ColorModes, caps.Adf!.ColorModes);
            foreach (var request in new[]
            {
                new ScanRequest(ScanSource.Platen, ScanColor.Color, 300),
                new ScanRequest(ScanSource.Adf, ScanColor.Grayscale, 200),
                new ScanRequest(ScanSource.AdfDuplex, ScanColor.BlackAndWhite, 600),
                new ScanRequest(ScanSource.Platen, ScanColor.Color, 150, Width: 1275, Height: 1650),
            })
            {
                fake.Transfers.Clear();
                var mine = await All(direct.ScanAsync(request));
                var asDriver = fake.Transfers.ToList();
                fake.Transfers.Clear();
                var theirs = await All(client.ScanAsync(request));
                Assert.Equal(mine.Count, theirs.Count);
                Assert.True(mine.Count >= 1);
                for (var i = 0; i < mine.Count; i++) Assert.Equal(mine[i], theirs[i]);
                Assert.Equal(asDriver, fake.Transfers); // the driver was asked the same, page for page
            }
            Assert.Equal(0, server.ActiveJobs);
        }
    }

    private static HttpClient Raw(Action<X509Certificate2?>? seen = null) => new(new SocketsHttpHandler
    {
        SslOptions = { RemoteCertificateValidationCallback = (_, cert, _, _) => { seen?.Invoke(cert as X509Certificate2); return true; } },
    });

    [Fact]
    public async Task The_server_shows_the_certificate_whose_fingerprint_the_card_shows_and_serves_PDF_pages()
    {
        var fake = Fake();
        var (listener, server, cert) = await Serve(await Open(fake));
        await using (listener)
        using (server)
        using (cert)
        {
            X509Certificate2? shown = null;
            using var http = Raw(c => shown ??= c is null ? null : X509CertificateLoader.LoadCertificate(c.RawData));
            var root = $"https://127.0.0.1:{listener.Port}/eSCL/";
            using var post = new HttpRequestMessage(HttpMethod.Post, root + "ScanJobs")
            {
                Content = new ByteArrayContent(Settings("<pwg:InputSource>Platen</pwg:InputSource><pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>")),
            };
            post.Content.Headers.ContentType = new MediaTypeHeaderValue("text/xml");
            using var created = await http.SendAsync(post);
            Assert.Equal(HttpStatusCode.Created, created.StatusCode);
            Assert.Equal(ShareCertificate.Fingerprint(cert), ShareCertificate.Fingerprint(shown!));
            using var page = await http.GetAsync(created.Headers.Location + "/NextDocument");
            Assert.Equal("application/pdf", page.Content.Headers.ContentType!.MediaType);
            Assert.StartsWith("%PDF-", Encoding.ASCII.GetString(await page.Content.ReadAsByteArrayAsync()));
            Assert.Equal("no-store", page.Headers.CacheControl!.ToString());
            Assert.False(page.Headers.Contains("Server"));
        }
    }

    [Fact]
    public async Task Over_HTTPS_big_bodies_and_unknown_paths_are_refused()
    {
        var (listener, server, cert) = await Serve(await Open(Fake()));
        await using (listener)
        using (server)
        using (cert)
        {
            using var http = Raw();
            var root = $"https://127.0.0.1:{listener.Port}";
            using var big = await http.PostAsync(root + "/eSCL/ScanJobs", new ByteArrayContent(new byte[ShareXml.MaxSettingsBytes * 4]));
            Assert.Equal(HttpStatusCode.RequestEntityTooLarge, big.StatusCode);
            using var dtd = await http.PostAsync(root + "/eSCL/ScanJobs", new ByteArrayContent(
                "<?xml version=\"1.0\"?><!DOCTYPE l [<!ENTITY a \"a\">]><scan:ScanSettings xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\"/>"u8.ToArray()));
            Assert.Equal(HttpStatusCode.BadRequest, dtd.StatusCode);
            using var file = await http.GetAsync(root + "/eSCL/..%2F..%2FWindows%2Fwin.ini");
            Assert.Equal(HttpStatusCode.NotFound, file.StatusCode);
            using var plainHttp = new HttpClient();
            await Assert.ThrowsAnyAsync<HttpRequestException>(() => plainHttp.GetAsync($"http://127.0.0.1:{listener.Port}/eSCL/ScannerCapabilities"));
        }
    }

    [Fact]
    public async Task A_device_that_may_not_connect_gets_nothing_not_even_TLS()
    {
        var (listener, server, cert) = await Serve(await Open(Fake()), allow: (_, _) => false);
        await using (listener)
        using (server)
        using (cert)
        {
            var handshakes = 0;
            using var http = Raw(_ => handshakes++);
            await Assert.ThrowsAnyAsync<HttpRequestException>(() => http.GetAsync($"https://127.0.0.1:{listener.Port}/eSCL/ScannerCapabilities"));
            Assert.Equal(0, handshakes);
        }
    }

    [Fact]
    public async Task Closed_the_port_refuses_connections_at_once()
    {
        var (listener, server, cert) = await Serve(await Open(Fake()));
        var port = listener.Port;
        using (cert)
        {
            using var http = Raw();
            using (await http.GetAsync($"https://127.0.0.1:{port}/eSCL/ScannerStatus")) { }
            server.Dispose();
            var started = System.Diagnostics.Stopwatch.StartNew();
            await listener.DisposeAsync();
            Assert.True(started.Elapsed < Timing.Limit(TimeSpan.FromSeconds(3)));
            using var tcp = new TcpClient();
            var ex = await Assert.ThrowsAsync<SocketException>(() => tcp.ConnectAsync(IPAddress.Loopback, port));
            Assert.Equal(SocketError.ConnectionRefused, ex.SocketErrorCode);
        }
    }

    [Fact]
    public async Task Too_many_connections_from_one_device_are_closed()
    {
        var (listener, server, cert) = await Serve(await Open(Fake()));
        await using (listener)
        using (server)
        using (cert)
        {
            var held = new List<TcpClient>();
            try
            {
                for (var i = 0; i < KestrelShareHost.MaxConnectionsPerPeer; i++)
                {
                    var c = new TcpClient();
                    await c.ConnectAsync(IPAddress.Loopback, listener.Port);
                    held.Add(c);
                }
                await Task.Delay(300);
                using var extra = new TcpClient();
                await extra.ConnectAsync(IPAddress.Loopback, listener.Port);
                var stream = extra.GetStream();
                stream.ReadTimeout = 5000;
                var buffer = new byte[16];
                // Closed by the server without a byte (no TLS answer to our hello either).
                try
                {
                    await stream.WriteAsync(new byte[] { 0x16, 0x03, 0x01, 0x00, 0x05, 1, 0, 0, 1, 0 });
                    Assert.Equal(0, await stream.ReadAsync(buffer).AsTask().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(5))));
                }
                catch (IOException)
                {
                    // Reset rather than closed: refused all the same.
                }
            }
            finally
            {
                foreach (var c in held) c.Dispose();
            }
        }
    }

    [Fact]
    public async Task The_switch_with_the_real_server_on_loopback_scans_and_closes()
    {
        var fake = Fake();
        var system = new FakeWiaSystem([fake]);
        var direct = await Open(fake, system);
        var saved = new List<ScannerShareChoice>();
        var share = new ScannerShare(ShareEnvironment.ThisPcOnly(new KestrelShareHost()), "OFFICE-PC", null, saved.Add);
        await share.ShareAsync(await Open(fake, system));
        Assert.Equal(ShareState.On, share.State);
        var port = share.Port!.Value;
        var request = new ScanRequest(ScanSource.Adf, ScanColor.Color, 300);
        Assert.Equal(await All(direct.ScanAsync(request)), await All(Client(port).ScanAsync(request)));
        await share.StopAsync();
        using var tcp = new TcpClient();
        await Assert.ThrowsAsync<SocketException>(() => tcp.ConnectAsync(IPAddress.Loopback, port));
        await share.DisposeAsync();
    }

    // ---------------------------------------------------------------- review of 4bf7e6c0

    [Fact]
    public async Task A_device_waiting_on_a_slow_page_or_polling_status_keeps_its_job()
    {
        var (scanner, _) = await Hung(); // a page that takes minutes (600 dpi on a slow flatbed)
        var time = new ManualTime();
        using var share = new SharedScanner(scanner, scanner.Capabilities, Identity,
            new ShareLimits { IdleLimit = TimeSpan.FromSeconds(60), LongPoll = TimeSpan.FromMinutes(10) }, time);
        var job = new Uri((await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Location!).AbsolutePath;
        using var gone = new CancellationTokenSource();
        var waiting = share.HandleAsync(new ShareRequest("GET", job + "/NextDocument", [], Peer), gone.Token); // the long poll
        time.Advance(TimeSpan.FromMinutes(3));
        await Ask(share, "GET", "/eSCL/ScannerCapabilities"); // sweeps
        Assert.Equal(1, share.ActiveJobs); // in flight counts as asked about, however long it takes
        Assert.False(waiting.IsCompleted);
        gone.Cancel(); // the device stops waiting...
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiting);
        // ...but polls its status, as sane-airscan does between pages.
        for (var i = 0; i < 4; i++)
        {
            time.Advance(TimeSpan.FromSeconds(50));
            await Ask(share, "GET", "/eSCL/ScannerStatus");
        }
        Assert.Equal(1, share.ActiveJobs);
        time.Advance(TimeSpan.FromSeconds(61)); // then silence: it's let go
        await Ask(share, "GET", "/eSCL/ScannerCapabilities");
        await WaitFor(() => share.ActiveJobs == 0);
        // Another device's status polls don't keep it.
        var other = new Uri((await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""), OtherPeer)).Location!).AbsolutePath;
        Assert.NotNull(other);
        time.Advance(TimeSpan.FromSeconds(40));
        await Ask(share, "GET", "/eSCL/ScannerStatus");
        time.Advance(TimeSpan.FromSeconds(40));
        await Ask(share, "GET", "/eSCL/ScannerStatus");
        await WaitFor(() => share.ActiveJobs == 0);
    }

    [Fact]
    public async Task A_forgotten_jobs_cancellation_is_disposed_once_its_scan_is_over()
    {
        var fake = Fake();
        var scanner = await Open(fake);
        var time = new ManualTime();
        var share = new SharedScanner(scanner, scanner.Capabilities, Identity, new ShareLimits { KeepFinished = TimeSpan.FromMinutes(5) }, time);
        var job = new Uri((await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""))).Location!).AbsolutePath;
        Assert.Equal(200, (await Ask(share, "GET", job + "/NextDocument")).Status);
        Assert.Equal(404, (await Ask(share, "GET", job + "/NextDocument")).Status);
        Assert.Equal(0, share.ReleasedJobs);
        time.Advance(TimeSpan.FromMinutes(6));
        await Ask(share, "GET", "/eSCL/ScannerCapabilities");
        Assert.Equal(1, share.ReleasedJobs);
        // A job still scanning when the server stops is released once its scan has ended.
        fake.Hangs = true;
        await Ask(share, "POST", "/eSCL/ScanJobs", Settings(""));
        await WaitFor(() => scanner.IsBusy);
        share.Dispose();
        await WaitFor(() => share.ReleasedJobs == 2);
    }

    [Fact]
    public async Task Only_advertised_resolutions_are_taken_and_pixels_are_bounded()
    {
        var caps = (await Open(Fake())).Capabilities; // 75, 100, 150, 200, 300, 400, 600, 1200
        Assert.Equal(409, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(Settings("<scan:XResolution>250</scan:XResolution>"), caps)).Status);
        Assert.Equal(409, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(Settings("<scan:XResolution>19200</scan:XResolution>"), caps)).Status);
        Assert.Equal(409, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(
            Settings("<scan:XResolution>300</scan:XResolution><scan:YResolution>600</scan:YResolution>"), caps)).Status);
        Assert.Equal(600, ShareXml.ReadSettings(Settings("<scan:XResolution>600</scan:XResolution><scan:YResolution>600</scan:YResolution>"), caps).Request.Resolution);
        // A driver that lists no resolution: 300 dpi is all that's offered, and all that's taken.
        var none = (await Open(Fake(Mfp with { Resolutions = WiaValues.Only(0) }))).Capabilities;
        Assert.Empty(none.Platen!.Resolutions);
        Assert.Contains("<scan:XResolution>300</scan:XResolution>", Encoding.UTF8.GetString(ShareXml.Capabilities(none, Identity)));
        Assert.Equal(300, ShareXml.ReadSettings(Settings(""), none).Request.Resolution);
        Assert.Equal(409, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(Settings("<scan:XResolution>19200</scan:XResolution>"), none)).Status);
        // A region past the source is kept inside it before planning; a page too many pixels across is refused.
        var big = ShareXml.ReadSettings(Settings("<pwg:ScanRegions><pwg:ScanRegion><pwg:Width>299999</pwg:Width><pwg:Height>299999</pwg:Height>" +
            "<pwg:XOffset>299999</pwg:XOffset></pwg:ScanRegion></pwg:ScanRegions>"), caps).Request;
        Assert.Equal((2549, 1, 3507), (big.XOffset, big.Width, big.Height));
        var huge = new ScannerCapabilities("x", "x", null, new InputCaps(0, 300 * 1000, 0, 300 * 1000, ["RGB24"], ["image/jpeg"], [1200], []), null, false);
        Assert.Equal(409, Assert.Throws<ShareRequestException>(() => ShareXml.ReadSettings(Settings(""), huge)).Status);
    }

    [Fact]
    public async Task A_shared_scanner_that_isnt_connected_keeps_its_card_and_can_be_turned_off()
    {
        var (share, host, _, _, saved) = Switch();
        await share.ShareAsync(await Open(Fake()));
        // The entry knows its scanner but it's off now: the card stays, ticked, waiting.
        await share.OfferAsync(Usb.Id, null);
        var card = share.Card(null, Usb);
        Assert.True(card.IsShown);
        Assert.True(card.IsOn);
        Assert.Equal(CoreStrings.Share_WaitingForScanner, card.Text);
        // A scanner that isn't the shared one and isn't connected shows nothing; one Windows reaches over eSCL never shows.
        Assert.False(share.Card(null, Usb with { Id = "other" }).IsShown);
        Assert.False(share.Card(Usb with { Id = "escl", Port = @"SWD\Escl\x" }, null).IsShown);
        // Forgetting its entry turns sharing off, so re-adding it doesn't share it again.
        await share.ForgetAsync([null, "other", Usb.Id]);
        Assert.False(share.IsOn);
        Assert.Null(saved[^1].DeviceId);
        Assert.False(host.Listening);
        Assert.False(share.Card(null, Usb).IsShown);
    }

    [Fact]
    public async Task The_card_shows_the_fingerprint_only_while_listening_16_bytes_a_line()
    {
        var (share, _, _, nets, _) = Switch();
        var scanner = await Open(Fake());
        var off = share.Card(scanner.Device, null);
        Assert.True(off.IsShown);
        Assert.False(off.IsOn);
        Assert.Null(off.Fingerprint);
        await share.ShareAsync(scanner);
        var on = share.Card(scanner.Device, null);
        Assert.Equal(share.Fingerprint, on.Fingerprint!.Replace("\n", ""));
        Assert.Equal(2, on.Fingerprint.Split('\n').Length);
        nets.Now = [Cafe];
        await share.RecheckAsync();
        Assert.Null(share.Card(scanner.Device, null).Fingerprint);
    }

    [Fact]
    public async Task Turning_on_without_a_connected_scanner_changes_nothing()
    {
        var (share, host, _, _, saved) = Switch();
        var scanner = await Open(Fake());
        Assert.Equal(ShareSwitch.NoScanner, await share.TurnOnAsync(null));
        Assert.False(share.IsOn);
        Assert.Empty(saved);
        Assert.Empty(host.Started);
        Assert.Equal(ShareSwitch.On, await share.TurnOnAsync(scanner));
        Assert.True(host.Listening);
    }

    [Fact]
    public async Task Networks_are_watched_only_while_a_scanner_is_shared()
    {
        var (share, _, _, nets, _) = Switch();
        Assert.Equal(0, nets.Listeners);
        await share.RecheckAsync();
        Assert.Equal(0, nets.Listeners);
        await share.ShareAsync(await Open(Fake()));
        Assert.Equal(1, nets.Listeners);
        await share.StopAsync();
        Assert.Equal(0, nets.Listeners);
        await share.ShareAsync(await Open(Fake()));
        await share.DisposeAsync();
        Assert.Equal(0, nets.Listeners);
    }

    [Fact]
    public async Task Closing_cancels_an_announcement_under_way_at_once()
    {
        var host = new FakeHost();
        var ads = new HangingAdvertiser();
        var share = new ScannerShare(new ShareEnvironment(host, new FakeNetworks(), ads, new EphemeralCertificates()), "OFFICE-PC", null, _ => { });
        var starting = share.ShareAsync(await Open(Fake()));
        await WaitFor(() => host.Started.Count == 1);
        // The announcement never ends by itself: closing at all means it was cancelled, not waited out.
        await share.DisposeAsync().AsTask().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(10)));
        await starting;
        Assert.True(ads.Cancelled);
        Assert.False(host.Listening);
    }

    [Fact]
    public async Task An_entry_whose_scanner_changes_withdraws_the_old_one()
    {
        var (share, host, _, _, _) = Switch();
        var a = await Open(Fake());
        await share.ShareAsync(a);
        var listening = host.Started[^1].Listen.Scanner;
        // The entry's Windows scanner is now B: A is offered as gone (PrinterViewModel.UseWiaScannerAsync), and nothing serves A.
        await share.OfferAsync(Usb.Id, null);
        await share.OfferAsync("b", await Open(new FakeWiaScanner(Usb with { Id = "b" }, Mfp, (_, _) => [1])));
        Assert.False(host.Listening);
        Assert.Equal(503, (await listening.HandleAsync(new ShareRequest("GET", "/eSCL/ScannerCapabilities", [], Peer), CancellationToken.None)).Status);
        Assert.Equal(ShareState.WaitingForScanner, share.State);
    }

    // ---------------------------------------------------------------- the Store package

    [Fact]
    public void The_package_may_serve_private_networks_on_the_shares_and_the_phone_scans_ports_and_nothing_more()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        var manifest = XDocument.Load(Path.Combine(dir!.FullName, "print", "packaging", "AppxManifest.template.xml"));
        var capabilities = manifest.Descendants().Where(e => e.Name.LocalName == "Capability").Select(e => e.Attribute("Name")!.Value).ToList();
        Assert.Contains("privateNetworkClientServer", capabilities);
        Assert.DoesNotContain("internetClientServer", capabilities);
        XNamespace desktop2 = "http://schemas.microsoft.com/appx/manifest/desktop/windows10/2";
        var rules = manifest.Descendants(desktop2 + "Rule").ToList();
        // The share's port, and the phone scan's (roadmap 4.6): each alone, inbound TCP on private networks.
        Assert.Equal([ScannerShare.DefaultPort, Core.Capture.PhoneScan.DefaultPort], rules.Select(r => int.Parse(r.Attribute("LocalPortMin")!.Value)));
        foreach (var rule in rules)
        {
            Assert.Equal("in", rule.Attribute("Direction")!.Value);
            Assert.Equal("TCP", rule.Attribute("IPProtocol")!.Value);
            Assert.Equal("private", rule.Attribute("Profile")!.Value);
            Assert.Equal(rule.Attribute("LocalPortMin")!.Value, rule.Attribute("LocalPortMax")!.Value);
            Assert.Equal("InkvoltPrint.exe", rule.Parent!.Attribute("Executable")!.Value);
        }
    }

    // ---------------------------------------------------------------- helpers

    private static async Task WaitFor(Func<bool> condition)
    {
        var until = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(5));
        while (!condition())
        {
            if (DateTime.UtcNow > until) Assert.Fail("Timed out waiting.");
            await Task.Delay(20);
        }
    }

    /// <summary>A clock the test moves by hand (timers are the system's: the sweep also runs on each request).</summary>
    private sealed class ManualTime : TimeProvider
    {
        private DateTimeOffset _now = new(2026, 11, 19, 12, 0, 0, TimeSpan.Zero);

        public override DateTimeOffset GetUtcNow() => _now;

        public void Advance(TimeSpan by) => _now += by;
    }
}
