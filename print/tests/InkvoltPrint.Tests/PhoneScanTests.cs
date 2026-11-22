using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Capture;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Sharing;
using InkvoltPrint.Sharing;

namespace InkvoltPrint.Tests;

/// <summary>
/// Phone as a scanner (roadmap 4.6) and the photo-to-page step it shares with a camera (4.12): the photo's header read as hostile input,
/// the page found, warped and sized, and the phone page's pairing, limits and replies, in Core and over HTTPS on loopback.
/// </summary>
public class PhoneScanTests
{
    // ---------------------------------------------------------------- photos as hostile input

    /// <summary>A JPEG's first bytes: SOI, an EXIF block with <paramref name="orientation"/> (none when null), then a frame header.</summary>
    internal static byte[] JpegHeader(int width, int height, int? orientation = null, bool bigEndian = false)
    {
        var b = new List<byte> { 0xFF, 0xD8 };
        if (orientation is { } o)
        {
            var tiff = new List<byte>();
            void U16(int v) { if (bigEndian) { tiff.Add((byte)(v >> 8)); tiff.Add((byte)v); } else { tiff.Add((byte)v); tiff.Add((byte)(v >> 8)); } }
            void U32(int v) { if (bigEndian) { U16(v >> 16); U16(v & 0xFFFF); } else { U16(v & 0xFFFF); U16(v >> 16); } }
            tiff.AddRange(bigEndian ? "MM"u8.ToArray() : "II"u8.ToArray());
            U16(42);
            U32(8);
            U16(2); // two entries: something else, then the orientation
            U16(0x010F); U16(2); U32(4); U32(0);
            U16(0x0112); U16(3); U32(1); U16(o); U16(0);
            U32(0);
            var app1 = "Exif\0\0"u8.ToArray().Concat(tiff).ToArray();
            b.AddRange([0xFF, 0xE1, (byte)((app1.Length + 2) >> 8), (byte)(app1.Length + 2)]);
            b.AddRange(app1);
        }
        b.AddRange([0xFF, 0xC0, 0x00, 0x11, 0x08, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width, 0x03,
            0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
        b.AddRange([0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00, 0xFF, 0xD9]);
        return [.. b];
    }

    private static byte[] PngHeader(uint width, uint height)
    {
        var b = new List<byte> { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13 };
        b.AddRange("IHDR"u8.ToArray());
        b.AddRange([(byte)(width >> 24), (byte)(width >> 16), (byte)(width >> 8), (byte)width, (byte)(height >> 24), (byte)(height >> 16), (byte)(height >> 8), (byte)height]);
        b.AddRange([8, 2, 0, 0, 0, 0, 0, 0, 0]);
        return [.. b];
    }

    [Fact]
    public void A_photo_is_known_by_its_first_bytes_with_its_size_and_orientation()
    {
        Assert.Equal(new PhotoHeader(PhotoKind.Jpeg, 4032, 3024), PhotoInput.Inspect(JpegHeader(4032, 3024)));
        Assert.Equal(new PhotoHeader(PhotoKind.Jpeg, 4032, 3024, 6), PhotoInput.Inspect(JpegHeader(4032, 3024, 6)));
        Assert.Equal(new PhotoHeader(PhotoKind.Jpeg, 4032, 3024, 8), PhotoInput.Inspect(JpegHeader(4032, 3024, 8, bigEndian: true)));
        Assert.Equal((3024, 4032), PhotoInput.Inspect(JpegHeader(4032, 3024, 6))!.Upright);
        Assert.Equal(new PhotoHeader(PhotoKind.Png, 1200, 1600), PhotoInput.Inspect(PngHeader(1200, 1600)));
        // An orientation out of range is none.
        Assert.Equal(1, PhotoInput.Inspect(JpegHeader(1000, 1000, 9))!.Orientation);
    }

    [Fact]
    public void Anything_else_and_photos_too_large_or_small_are_refused_unread()
    {
        Assert.Null(PhotoInput.Inspect("<html><body>not a photo at all</body></html>"u8));
        Assert.Null(PhotoInput.Inspect("GIF89a................................"u8));
        Assert.Null(PhotoInput.Inspect(JpegHeader(4032, 3024)[..10])); // cut off before its frame header
        Assert.Null(PhotoInput.Inspect(JpegHeader(20_000, 1000))); // a side past the limit
        Assert.Null(PhotoInput.Inspect(JpegHeader(10_000, 10_000))); // 100 megapixels
        Assert.Null(PhotoInput.Inspect(JpegHeader(100, 3000))); // too narrow to hold a page
        Assert.Null(PhotoInput.Inspect(JpegHeader(0, 3000))); // height given later (DNL): not taken
        Assert.Null(PhotoInput.Inspect(PngHeader(uint.MaxValue, 5)));
        // The scan's data before any frame header, or a segment longer than the file.
        Assert.Null(PhotoInput.Inspect(new byte[] { 0xFF, 0xD8, 0xFF, 0xDA, 0, 4, 0, 0 }.Concat(new byte[30]).ToArray()));
        Assert.Null(PhotoInput.Inspect(new byte[] { 0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF }.Concat(new byte[30]).ToArray()));
        // An EXIF block that points past its end reads as no orientation.
        Assert.Equal(1, PhotoInput.ExifOrientation([(byte)'I', (byte)'I', 42, 0, 0xF0, 0xFF, 0xFF, 0x7F]));
        Assert.Null(PhotoInput.Inspect(new byte[PhotoInput.MaxBytes + 1]));
    }

    // ---------------------------------------------------------------- photo to page

    [Theory]
    [InlineData(1100, 850, "Letter", 11)]
    [InlineData(1414, 1000, "A4", 11.69)]
    [InlineData(1400, 850, "Legal", 14)]
    [InlineData(4032, 3024, "Letter", 11)] // a 4:3 photo of the whole frame
    [InlineData(3000, 3000, "Photo", 11)]
    [InlineData(3000, 1500, "Narrow", 17)]
    [InlineData(3000, 800, "Receipt", 11.81)]
    public void A_page_is_taken_for_the_paper_its_proportions_say(double longSide, double shortSide, string name, double inches)
    {
        var paper = PhotoPage.Paper(longSide, shortSide);
        Assert.Equal(name, paper.Name);
        Assert.Equal(inches, paper.LongInches, 1);
        Assert.Equal(paper, PhotoPage.Paper(shortSide, longSide));
        Assert.Equal("Letter", PhotoPage.Paper(double.NaN, 5).Name);
    }

    [Theory]
    [InlineData(1, 0, 0)]
    [InlineData(2, 2, 0)]
    [InlineData(3, 2, 1)]
    [InlineData(4, 0, 1)]
    [InlineData(5, 0, 0)]
    [InlineData(6, 0, 1)]
    [InlineData(7, 2, 1)]
    [InlineData(8, 2, 0)]
    public void A_photo_is_turned_the_way_the_camera_held_it(int orientation, int cornerX, int cornerY)
    {
        // 3 × 2, each pixel its own value: the shown top left is the stored pixel the EXIF orientation says.
        var p = new Picture([0, 1, 2, 3, 4, 5], 3, 2, 1);
        var turned = PhotoPage.Orient(p, orientation);
        Assert.Equal(orientation >= 5 ? (2, 3) : (3, 2), (turned.Width, turned.Height));
        Assert.Equal(cornerY * 3 + cornerX, turned.Pixels[0]);
        Assert.Equal(p.Pixels.Order(), turned.Pixels.Order());
    }

    /// <summary>A white page with a few dark lines on a dark desk, photographed at an angle: its corners clockwise from the top left.</summary>
    internal static Picture PageOnDesk(int w, int h, (double X, double Y)[] corners, int channels = 3)
    {
        var px = new byte[w * h * channels];
        bool Inside(double x, double y)
        {
            for (var i = 0; i < 4; i++)
            {
                var (a, b) = (corners[i], corners[(i + 1) % 4]);
                if ((b.X - a.X) * (y - a.Y) - (b.Y - a.Y) * (x - a.X) < 0) return false;
            }
            return true;
        }
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                byte v = 60;
                if (Inside(x + 0.5, y + 0.5))
                {
                    v = 235;
                    // Lines of "text" across the page's middle.
                    var (cx, cy) = ((corners[0].X + corners[2].X) / 2, (corners[0].Y + corners[2].Y) / 2);
                    if (Math.Abs(x - cx) < w * 0.12 && ((int)(y - cy + 1000) % 24) < 3 && Math.Abs(y - cy) < h * 0.2) v = 30;
                }
                for (var c = 0; c < channels; c++) px[(y * w + x) * channels + c] = v;
            }
        return new Picture(px, w, h, channels);
    }

    [Fact]
    public void A_page_photographed_at_an_angle_is_warped_flat_and_sized_as_its_paper()
    {
        // A page seen from one side: wider at the bottom.
        var photo = PageOnDesk(900, 1200, [(250, 150), (650, 150), (760, 1050), (140, 1050)]);
        var page = PhotoPage.Make(photo, 1, 150, gray: false);
        Assert.True(page.Straightened);
        Assert.Equal(3, page.Image.Channels);
        Assert.Equal(150, page.Dpi);
        // Its long side is the paper's at 150 dpi; the page fills the result (its middle and its corners just inside are paper, not desk).
        Assert.Equal((int)Math.Round(page.Paper.LongInches * 150), Math.Max(page.Image.Width, page.Image.Height));
        byte At(double fx, double fy) => page.Image.Pixels[((int)(fy * page.Image.Height) * page.Image.Width + (int)(fx * page.Image.Width)) * 3];
        foreach (var (fx, fy) in new[] { (0.04, 0.04), (0.96, 0.04), (0.96, 0.96), (0.04, 0.96), (0.5, 0.05) }) Assert.True(At(fx, fy) > 200, $"desk at {fx},{fy}");
    }

    [Fact]
    public void A_photo_without_a_page_on_a_desk_is_kept_whole_in_grey_when_asked()
    {
        var photo = PageOnDesk(800, 600, [(0, 0), (800, 0), (800, 600), (0, 600)]); // all paper: nothing to warp
        var page = PhotoPage.Make(photo, 6, 200, gray: true);
        Assert.False(page.Straightened);
        Assert.True(page.Image.IsGray);
        // Turned upright first (EXIF 6: a quarter clockwise): taller than wide, 11 inches at 200 dpi.
        Assert.Equal(2200, page.Image.Height);
        Assert.Equal(1650, page.Image.Width);
        Assert.Throws<ArgumentException>(() => PhotoPage.Make(new Picture(new byte[10], 4, 4, 3), 1, 150, false));
    }

    // ---------------------------------------------------------------- a capture source as a scanner

    /// <summary>"Decodes" any photo to a grey page on a desk of the header's size (or <see cref="Size"/>); "encodes" as a few bytes saying its size.</summary>
    private sealed class FakeCodec : IPhotoCodec
    {
        public (int W, int H)? Size { get; init; }

        public List<(int W, int H, int Channels, int Dpi)> Encoded { get; } = [];

        public Picture Decode(byte[] data, PhotoHeader header)
        {
            var (w, h) = Size ?? (header.Width, header.Height);
            return new Picture(Enumerable.Repeat((byte)200, w * h * 3).ToArray(), w, h, 3);
        }

        public byte[] EncodeJpeg(Picture page, int dpi)
        {
            Encoded.Add((page.Width, page.Height, page.Channels, dpi));
            return Encoding.ASCII.GetBytes($"{page.Width}x{page.Height}");
        }
    }

    [Fact]
    public async Task Photos_come_out_as_pages_at_the_scans_resolution_and_others_are_left_out()
    {
        var channel = Channel.CreateUnbounded<CapturedPhoto>();
        var codec = new FakeCodec();
        var notes = new List<string>();
        var scanner = new CaptureScanner(channel.Reader, codec, notes.Add);
        channel.Writer.TryWrite(new CapturedPhoto(JpegHeader(800, 600)));
        channel.Writer.TryWrite(new CapturedPhoto("<html>"u8.ToArray()));
        channel.Writer.TryWrite(new CapturedPhoto(Frame: new Picture(new byte[600 * 800], 600, 800, 1)));
        channel.Writer.TryWrite(new CapturedPhoto(Frame: new Picture(new byte[10 * 10], 10, 10, 1))); // too small to be a page
        channel.Writer.Complete();
        var pages = new List<string>();
        await foreach (var jpeg in scanner.ScanAsync(new ScanRequest(ScanSource.Platen, ScanColor.Grayscale, 150))) pages.Add(Encoding.ASCII.GetString(jpeg));
        Assert.Equal(["1650x1238", "1238x1650"], pages); // a 4:3 photo is taken for Letter: 11 inches the long way at 150 dpi, either way round
        Assert.All(codec.Encoded, e => Assert.Equal((1, 150), (e.Channels, e.Dpi)));
        Assert.Equal(2, scanner.LeftOut);
        Assert.Equal([CoreStrings.Capture_NotAPhoto, CoreStrings.Capture_NotAPhoto], notes);

        // A file whose pixels aren't the size its header says is left out.
        var lying = Channel.CreateUnbounded<CapturedPhoto>();
        lying.Writer.TryWrite(new CapturedPhoto(JpegHeader(800, 600)));
        lying.Writer.Complete();
        var none = new List<byte[]>();
        await foreach (var jpeg in new CaptureScanner(lying.Reader, new FakeCodec { Size = (4000, 3000) }).ScanAsync(new ScanRequest())) none.Add(jpeg);
        Assert.Empty(none);
        Assert.Equal(PhotoPage.Resolutions, CaptureScanner.Capabilities("Phone").Platen!.Resolutions);
    }

    // ---------------------------------------------------------------- the phone session

    private static readonly IPAddress Phone = IPAddress.Parse("192.0.2.20"), Other = IPAddress.Parse("192.0.2.21");

    private static Task<byte[]?> Body(byte[] bytes, int max) => Task.FromResult(bytes.Length > max ? null : bytes);

    private static Task<PhoneReply> Ask(PhoneSession s, string method, string path, IPAddress? peer = null, string? cookie = null, bool fromPage = true, byte[]? body = null,
        Action? read = null) =>
        s.HandleAsync(new PhoneRequest(method, path, peer ?? Phone, cookie, fromPage), (max, _) => { read?.Invoke(); return Body(body ?? [], max); }, CancellationToken.None);

    private static string CookieOf(PhoneReply reply) => reply.SetCookie!.Split(';')[0].Split('=', 2)[1];

    [Fact]
    public async Task Only_the_token_reaches_the_page_and_nothing_else_is_there()
    {
        var s = new PhoneSession("<OFFICE-PC>");
        Assert.Equal(43, s.Token.Length);
        Assert.NotEqual(s.Token, new PhoneSession("x").Token);
        var page = await Ask(s, "GET", s.PagePath, fromPage: false);
        Assert.Equal(200, page.Status);
        var html = Encoding.UTF8.GetString(page.Body!);
        Assert.Contains("&lt;OFFICE-PC&gt;", html);
        Assert.DoesNotContain("<OFFICE-PC>", html);
        Assert.Contains("capture=\"environment\"", html);
        var nonce = page.ContentSecurityPolicy!.Split("'nonce-")[1].Split('\'')[0];
        Assert.Contains($"<script nonce=\"{nonce}\">", html);
        Assert.Contains("default-src 'none'", page.ContentSecurityPolicy);
        Assert.NotEqual(nonce, (await Ask(s, "GET", s.PagePath)).ContentSecurityPolicy!.Split("'nonce-")[1].Split('\'')[0]);

        foreach (var path in new[] { "/", "/p/", "/p", "/p/" + s.Token[..^1], "/p/" + s.Token + "x", "/p/" + s.Token.ToUpperInvariant(), s.PagePath + "/other",
                     s.PagePath + "/../", "/favicon.ico", "/p/" + new string('a', 500) })
            Assert.Equal(404, (await Ask(s, "GET", path)).Status);
        Assert.Equal(405, (await Ask(s, "POST", s.PagePath)).Status);
        Assert.Equal(405, (await Ask(s, "GET", s.PagePath + "/photo")).Status);
        Assert.Equal(PhoneState.Waiting, s.State);
    }

    [Fact]
    public async Task The_first_phone_to_pair_is_the_only_one_that_can_send()
    {
        var s = new PhoneSession("PC");
        // Not the page's script (a form from elsewhere): refused, and nothing paired.
        Assert.Equal(403, (await Ask(s, "POST", s.PagePath + "/pair", fromPage: false)).Status);
        var paired = await Ask(s, "POST", s.PagePath + "/pair");
        Assert.Equal(200, paired.Status);
        Assert.Contains("HttpOnly", paired.SetCookie);
        Assert.Contains("Secure", paired.SetCookie);
        Assert.Contains("SameSite=Strict", paired.SetCookie);
        Assert.Contains($"Path={s.PagePath}", paired.SetCookie);
        var cookie = CookieOf(paired);
        Assert.Equal(PhoneState.Paired, s.State);

        // Another device that scanned the same code: told it's used, can't send; nor can the phone's cookie from another address.
        Assert.Equal(403, (await Ask(s, "POST", s.PagePath + "/pair", Other)).Status);
        var read = 0;
        Assert.Equal(403, (await Ask(s, "POST", s.PagePath + "/photo", Other, cookie, body: JpegHeader(800, 600), read: () => read++)).Status);
        Assert.Equal(403, (await Ask(s, "POST", s.PagePath + "/photo", Phone, cookie[..^1] + (cookie[^1] == 'A' ? 'B' : 'A'), body: JpegHeader(800, 600), read: () => read++)).Status);
        Assert.Equal(403, (await Ask(s, "POST", s.PagePath + "/photo", Phone, null, body: JpegHeader(800, 600), read: () => read++)).Status);
        Assert.Equal(403, (await Ask(s, "POST", s.PagePath + "/photo", Phone, cookie, fromPage: false, body: JpegHeader(800, 600), read: () => read++)).Status);
        Assert.Equal(403, (await Ask(s, "POST", s.PagePath + "/done", Other, cookie)).Status);
        Assert.Equal(0, read); // none of their bodies was read
        Assert.Equal(0, s.Received);

        // The phone pairs again on a reload, and sends.
        Assert.Equal(200, (await Ask(s, "POST", s.PagePath + "/pair", Phone, cookie)).Status);
        var sent = await Ask(s, "POST", s.PagePath + "/photo", Phone, cookie, body: JpegHeader(800, 600));
        Assert.Equal(200, sent.Status);
        Assert.Contains("\"pages\":1", Encoding.UTF8.GetString(sent.Body!));
        Assert.True(s.Photos.TryRead(out var photo));
        Assert.Equal(JpegHeader(800, 600), photo.Data);
    }

    [Fact]
    public async Task Photos_are_bounded_in_size_kind_and_count_and_Done_ends_the_scan()
    {
        var s = new PhoneSession("PC", new PhoneLimits { MaxPhotos = 2, MaxPhotoBytes = 1000, Waiting = 4 });
        var cookie = CookieOf(await Ask(s, "POST", s.PagePath + "/pair"));
        Task<PhoneReply> Send(byte[] body) => Ask(s, "POST", s.PagePath + "/photo", Phone, cookie, body: body);
        Assert.Equal(413, (await Send(JpegHeader(800, 600).Concat(new byte[1000]).ToArray())).Status);
        Assert.Equal(415, (await Send("<html>not a photo</html>.........."u8.ToArray())).Status);
        Assert.Equal(415, (await Send(JpegHeader(20_000, 600))).Status);
        Assert.Equal(200, (await Send(JpegHeader(800, 600))).Status);
        Assert.Equal(200, (await Send(PngHeader(600, 800))).Status);
        Assert.Equal(429, (await Send(JpegHeader(800, 600))).Status);
        Assert.Equal(2, s.Received);

        var changed = 0;
        s.Changed += () => changed++;
        var done = await Ask(s, "POST", s.PagePath + "/done", Phone, cookie);
        Assert.Equal(200, done.Status);
        Assert.Equal(PhoneState.Finished, s.State);
        Assert.Equal(1, changed);
        // The photos sent before Done are still read, then the scan ends.
        var left = new List<CapturedPhoto>();
        await foreach (var p in s.Photos.ReadAllAsync()) left.Add(p);
        Assert.Equal(2, left.Count);
        Assert.Equal(410, (await Ask(s, "POST", s.PagePath + "/pair", Phone, cookie)).Status);
    }

    [Fact]
    public async Task Ending_the_scan_on_the_PC_refuses_what_the_phone_sends_next()
    {
        var s = new PhoneSession("PC");
        var cookie = CookieOf(await Ask(s, "POST", s.PagePath + "/pair"));
        s.Finish();
        s.Finish();
        Assert.Equal(410, (await Ask(s, "POST", s.PagePath + "/photo", Phone, cookie, body: JpegHeader(800, 600))).Status);
        Assert.True(s.Photos.Completion.IsCompleted);
        // A code no phone paired with, once ended, pairs nobody.
        var unpaired = new PhoneSession("PC");
        unpaired.Finish();
        Assert.Equal(410, (await Ask(unpaired, "POST", unpaired.PagePath + "/pair")).Status);
    }

    [Fact]
    public void The_PC_says_where_the_phone_stands()
    {
        Assert.Equal(CoreStrings.Phone_StatusWaiting, PhoneScan.StatusText(PhoneState.Waiting, 0));
        Assert.Equal(CoreStrings.Phone_StatusConnected, PhoneScan.StatusText(PhoneState.Paired, 0));
        Assert.Equal(CoreStrings.Phone_StatusReceived_One, PhoneScan.StatusText(PhoneState.Paired, 1));
        Assert.Equal(string.Format(CoreStrings.Phone_StatusReceived_Many, 3), PhoneScan.StatusText(PhoneState.Paired, 3));
        Assert.Equal(string.Format(CoreStrings.Phone_StatusFinished_Many, 0), PhoneScan.StatusText(PhoneState.Finished, 0));
    }

    [Fact]
    public void The_address_is_the_private_networks_IPv4_one()
    {
        var served = new List<LocalNetwork>
        {
            new(12, IPAddress.Parse("fe80::1"), 64, NetworkKind.Private),
            new(12, IPAddress.Parse("192.168.1.30"), 24, NetworkKind.Private),
            new(7, IPAddress.Parse("10.0.0.4"), 24, NetworkKind.Private),
        };
        Assert.Equal(IPAddress.Parse("10.0.0.4"), PhoneScan.AddressFor(served));
        Assert.Null(PhoneScan.AddressFor([]));
        var s = new PhoneSession("PC");
        Assert.Equal($"https://10.0.0.4:9781/p/{s.Token}", PhoneScan.UrlFor(IPAddress.Parse("10.0.0.4"), PhoneScan.DefaultPort, s));
    }

    // ---------------------------------------------------------------- over HTTPS on loopback

    private sealed class FakeNetworks(IReadOnlyList<LocalNetwork> networks) : IShareNetworks
    {
        public IReadOnlyList<LocalNetwork> Read() => networks;

        public event Action? Changed
        {
            add { }
            remove { }
        }
    }

    [Fact]
    public async Task No_private_network_opens_nothing()
    {
        var env = new PhoneEnvironment(new KestrelPhoneHost(), new FakeNetworks([new(3, IPAddress.Parse("192.168.1.30"), 24, NetworkKind.Public)]),
            PhoneEnvironment.ThisPcOnly(new KestrelPhoneHost()).Certificates);
        var opening = await PhoneScan.OpenAsync(env, "PC");
        Assert.Null(opening.Link);
        Assert.Equal(CoreStrings.Phone_NoPrivateNetwork, opening.Problem);
    }

    [Fact]
    public async Task A_phone_pairs_sends_and_finishes_over_HTTPS_and_the_port_closes_after()
    {
        var opening = await PhoneScan.OpenAsync(PhoneEnvironment.ThisPcOnly(new KestrelPhoneHost()), "OFFICE-PC");
        var link = opening.Link!;
        var uri = new Uri(link.Url);
        Assert.Equal("https", uri.Scheme);
        Assert.Equal("127.0.0.1", uri.Host);
        Assert.True(link.Qr().GetLength(0) >= 21);
        var cookies = new CookieContainer();
        using (var http = new HttpClient(new SocketsHttpHandler
               {
                   CookieContainer = cookies,
                   SslOptions = { RemoteCertificateValidationCallback = (_, _, _, _) => true },
               }))
        {
            using var page = await http.GetAsync(uri);
            Assert.Equal(HttpStatusCode.OK, page.StatusCode);
            Assert.Equal("text/html", page.Content.Headers.ContentType!.MediaType);
            Assert.Contains("default-src 'none'", page.Headers.GetValues("Content-Security-Policy").Single());
            Assert.Equal("nosniff", page.Headers.GetValues("X-Content-Type-Options").Single());
            Assert.Equal("no-referrer", page.Headers.GetValues("Referrer-Policy").Single());
            Assert.Equal(HttpStatusCode.NotFound, (await http.GetAsync(new Uri(uri, "/"))).StatusCode);

            HttpRequestMessage Post(string action, byte[]? body = null)
            {
                var m = new HttpRequestMessage(HttpMethod.Post, link.Url + action) { Content = new ByteArrayContent(body ?? []) };
                m.Headers.Add(PhoneSession.PageHeader, "1");
                m.Content.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg");
                return m;
            }
            Assert.Equal(HttpStatusCode.OK, (await http.SendAsync(Post("/pair"))).StatusCode);
            Assert.Equal(PhoneState.Paired, link.Session.State);
            Assert.Equal(HttpStatusCode.OK, (await http.SendAsync(Post("/photo", JpegHeader(1600, 1200)))).StatusCode);
            Assert.Equal(HttpStatusCode.UnsupportedMediaType, (await http.SendAsync(Post("/photo", new byte[5000]))).StatusCode);
            Assert.Equal(1, link.Session.Received);

            // Without the session cookie (another browser on this PC): refused.
            using (var stranger = new HttpClient(new SocketsHttpHandler { UseCookies = false, SslOptions = { RemoteCertificateValidationCallback = (_, _, _, _) => true } }))
                Assert.Equal(HttpStatusCode.Forbidden, (await stranger.SendAsync(Post("/photo", JpegHeader(1600, 1200)))).StatusCode);

            Assert.Equal(HttpStatusCode.OK, (await http.SendAsync(Post("/done"))).StatusCode);
            Assert.True(link.Session.Photos.TryRead(out var photo));
            Assert.Equal(JpegHeader(1600, 1200), photo.Data);
        }
        await link.DisposeAsync();
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        await Assert.ThrowsAsync<SocketException>(async () => await socket.ConnectAsync(IPAddress.Loopback, uri.Port));
    }
}
