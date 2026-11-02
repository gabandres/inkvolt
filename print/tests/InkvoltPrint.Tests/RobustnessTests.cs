using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Xml.Linq;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Tests;

/// <summary>What a printer can't make the app do over HTTP: ask another computer, or keep a reply without end. All reads go through <see cref="DeviceHttp"/>.</summary>
public class DeviceHttpLimitsTests
{
    private const string Host = "192.0.2.10", Other = "192.0.2.200";

    /// <summary>A reply of so many bytes, read a chunk at a time; counts what was read of it, and can break off instead of ending.</summary>
    private sealed class Reply(long size, bool breaksOff = false) : Stream
    {
        public long At;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => At; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (breaksOff && At >= size) throw new IOException("The connection went.");
            var n = (int)Math.Min(count, size - At);
            Array.Clear(buffer, offset, n);
            At += n;
            return n;
        }
    }

    private sealed class Serving(Stream reply, Action<Uri>? asked = null) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            asked?.Invoke(request.RequestUri!);
            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StreamContent(reply) });
        }
    }

    private sealed class NothingThere(Action<Uri> asked) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            lock (asked) asked(request.RequestUri!);
            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.NotFound));
        }
    }

    private static string Fixture(string file) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", file));

    [Theory]
    [InlineData("http://192.0.2.200/secret.xml")]
    [InlineData("https://192.0.2.200/secret.xml")]
    [InlineData("http://192.0.2.10.evil.example/secret.xml")]
    [InlineData("http://user@192.0.2.200/secret.xml")]
    public async Task A_request_to_another_computer_isnt_sent(string url)
    {
        var asked = new List<Uri>();
        using var http = new DeviceHttp(Host, new Serving(new MemoryStream([1]), asked.Add));
        await Assert.ThrowsAsync<HttpRequestException>(() => http.GetBytesOrNullAsync(new Uri(url)));
        using var post = new HttpRequestMessage(HttpMethod.Post, url);
        await Assert.ThrowsAsync<HttpRequestException>(() => http.SendOnceAsync(post));
        Assert.Empty(asked);
    }

    [Theory]
    [InlineData(Host, "http://192.0.2.10/a")]
    [InlineData(Host, "http://192.0.2.10:631/ipp/print")]
    [InlineData(Host, "https://192.0.2.10/a")]
    [InlineData(Host, "https://192.0.2.10:8443/eSCL/")]
    [InlineData("HP-Printer.local", "http://hp-printer.LOCAL:8080/a")]
    [InlineData("HP-Printer.local", "https://HP-PRINTER.local/a")]
    [InlineData("2001:db8::5", "http://[2001:db8::5]:631/ipp/print")]
    [InlineData("[2001:db8::5]", "https://[2001:db8::5]/a")]
    public async Task The_printers_own_host_on_any_port_or_scheme_is_asked(string host, string url)
    {
        var asked = new List<Uri>();
        using var http = new DeviceHttp(host, new Serving(new MemoryStream([1, 2, 3]), asked.Add));
        Assert.Equal([1, 2, 3], await http.GetBytesOrNullAsync(new Uri(url)));
        Assert.Equal(new Uri(url), Assert.Single(asked));
    }

    [Theory]
    [InlineData("ftp://192.0.2.10/a")]
    [InlineData("file:///C:/Windows/win.ini")]
    public async Task Only_web_addresses_are_asked_on_the_printer_too(string url)
    {
        using var http = new DeviceHttp(Host, new Serving(new MemoryStream([1])));
        await Assert.ThrowsAsync<HttpRequestException>(() => http.GetBytesOrNullAsync(new Uri(url)));
    }

    [Theory]
    [InlineData("http://192.0.2.200/DevMgmt/ProductStatusDyn.xml")]
    [InlineData("//192.0.2.200/DevMgmt/ProductStatusDyn.xml")]
    [InlineData("http://NPI1A2B3C.local/DevMgmt/ProductStatusDyn.xml")] // its own .local name: the same document, on the address in use
    public async Task A_link_in_a_printers_documents_stays_on_it_and_still_reads(string link)
    {
        var other = false;
        var tree = Fixture("DevMgmt_DiscoveryTree.xml").Replace("/DevMgmt/ProductStatusDyn.xml", link);
        Assert.Contains(link, tree);
        var printer = new FixtureHandler(name => name == "DevMgmt_DiscoveryTree.xml" ? System.Text.Encoding.UTF8.GetBytes(tree)
            : File.Exists(Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name)) ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name)) : null);
        var network = new HostRouter(new Dictionary<string, HttpMessageHandler>
        {
            [Host] = printer,
            [Other] = new Serving(new MemoryStream([1]), _ => other = true),
        });
        using var http = new DeviceHttp(Host, network);
        var ledm = new InkvoltPrint.Core.Ledm.LedmClient(http);

        Assert.NotNull(await ledm.GetStatusAsync());
        Assert.False(other);
    }

    [Fact]
    public void A_settings_link_with_the_password_stays_on_the_printer_keeping_its_scheme_and_port()
    {
        using var http = new DeviceHttp(Host, new Serving(new MemoryStream([1])));
        Assert.Equal(new Uri("https://192.0.2.10/DevMgmt/Settings.xml"), http.Https("https://192.0.2.200/DevMgmt/Settings.xml"));
        Assert.Equal(new Uri("https://192.0.2.10:8443/x"), http.Https("https://user:pw@192.0.2.200:8443/x"));
        Assert.Equal(new Uri("http://192.0.2.10:8080/x?a=1"), http.Http("http://192.0.2.200:8080/x?a=1"));
        Assert.Equal(new Uri("https://192.0.2.10:8443/x"), http.Https("https://192.0.2.10:8443/x"));
        Assert.Equal(new Uri("http://192.0.2.10/DevMgmt/x.xml"), http.Http("/DevMgmt/x.xml"));
    }

    [Fact]
    public async Task An_escl_address_kept_from_before_is_asked_on_the_printers_address_at_its_own_port()
    {
        var asked = new List<Uri>();
        var network = new HostRouter(new Dictionary<string, HttpMessageHandler>
        {
            [Host] = new NothingThere(asked.Add),
            [Other] = new NothingThere(asked.Add),
        });
        using var http = new DeviceHttp(Host, network);
        var scanner = new EsclClient(http, new Uri($"http://{Other}:8080/eSCL/"));
        Assert.Equal(new Uri($"http://{Host}:8080/eSCL/"), scanner.Root);
        await InkvoltPrint.Core.Probe.PrinterConnection.ProbeAsync(http, new Uri($"http://{Other}:8080/eSCL/"));
        Assert.DoesNotContain(asked, u => u.Host == Other);
        Assert.Contains(asked, u => u.Port == 8080 && u.AbsolutePath == "/eSCL/ScannerCapabilities");
    }

    [Fact]
    public async Task A_reply_that_never_ends_is_given_up_on_at_the_limit()
    {
        var reply = new Reply(300L << 20);
        using var http = new DeviceHttp(Host, new Serving(reply));
        await Assert.ThrowsAsync<HttpRequestException>(() => http.GetBytesOrNullAsync(http.Http("/x")));
        Assert.InRange(reply.At, 1, DeviceHttp.MaxReplyBytes + (1 << 20));
    }

    [Fact]
    public async Task A_reply_at_the_limit_is_whole_and_a_scanned_page_may_be_longer()
    {
        using var http = new DeviceHttp(Host, new Serving(new Reply(DeviceHttp.MaxReplyBytes)));
        Assert.Equal(DeviceHttp.MaxReplyBytes, (await http.GetBytesOrNullAsync(http.Http("/x")))!.Length);

        var page = DeviceHttp.MaxReplyBytes + 1000;
        using var scanner = new DeviceHttp(Host, new Serving(new Reply(page)));
        using var request = new HttpRequestMessage(HttpMethod.Get, scanner.Http("/eSCL/ScanJobs/1/NextDocument"));
        DeviceHttp.AllowLongReply(request);
        using var reply = await scanner.SendAsync(request);
        Assert.Equal(page, (await reply.Content.ReadAsByteArrayAsync()).Length);
    }

    [Fact]
    public async Task A_scanner_can_send_a_page_longer_than_a_document()
    {
        var page = DeviceHttp.MaxReplyBytes + 1000;
        using var http = new DeviceHttp(Host, new LongPageScanner(page));
        var pages = new List<byte[]>();
        await foreach (var jpeg in new EsclClient(http, http.Http("/eSCL/")).ScanAsync(new ScanRequest(ScanSource.Platen))) pages.Add(jpeg);
        Assert.Equal(page, Assert.Single(pages).Length);
    }

    /// <summary>The M234dw's scanner, with one page longer than any document.</summary>
    private sealed class LongPageScanner(long size) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            if (request.Method == HttpMethod.Post)
            {
                var created = new HttpResponseMessage(System.Net.HttpStatusCode.Created);
                created.Headers.Location = new Uri("/eSCL/ScanJobs/1", UriKind.Relative);
                return Task.FromResult(created);
            }
            if (path.EndsWith("/NextDocument", StringComparison.Ordinal))
                return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StreamContent(new Reply(size)) });
            return Task.FromResult(path.EndsWith("/ScannerCapabilities", StringComparison.Ordinal) ? new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent(Fixture("eSCL_ScannerCapabilities.xml")) }
                : path.EndsWith("/ScannerStatus", StringComparison.Ordinal) ? new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent(Fixture("eSCL_ScannerStatus.xml")) }
                : new HttpResponseMessage(System.Net.HttpStatusCode.NotFound));
        }
    }

    [Fact]
    public async Task A_reply_that_breaks_off_reads_as_no_answer()
    {
        using var http = new DeviceHttp(Host, new Serving(new Reply(1000, breaksOff: true)));
        await Assert.ThrowsAsync<HttpRequestException>(() => http.GetBytesOrNullAsync(http.Http("/x")));
    }

    [Fact]
    public async Task A_printer_answering_without_end_reads_as_offline_not_a_crash()
    {
        using var connection = await InkvoltPrint.Core.Probe.PrinterConnection.OpenAsync(Host, transport: new FreshEndless());
        Assert.False(connection.Probe.Reachable);
    }

    private sealed class FreshEndless : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StreamContent(new Reply(100L << 20)) });
    }
}

/// <summary>Malformed device replies must fail cleanly (FormatException), never with index errors.</summary>
public class RobustnessTests
{
    [Fact]
    public void Ipp_truncated_reply_is_a_FormatException()
    {
        // Header + printer group + an attribute whose declared value length runs past the end.
        byte[] reply = [1, 1, 0, 0, 0, 0, 0, 1, 0x04, 0x44, 0, 4, (byte)'n', (byte)'a', (byte)'m', (byte)'e', 0, 50, (byte)'x'];
        Assert.Throws<FormatException>(() => IppCodec.Decode(reply));
    }

    [Fact]
    public void Ipp_reason_without_suffix_is_an_error()
    {
        var r = new IppResponse(0, new Dictionary<string, List<object>>
        {
            ["printer-state"] = [3],
            ["printer-state-reasons"] = ["media-jam"],
        });

        var status = IppClient.ToStatus(r);

        Assert.Equal(Severity.Error, Assert.Single(status.Alerts).Severity);
    }

    [Fact]
    public void Truncated_jpeg_header_is_not_found_instead_of_crashing()
    {
        var jpeg = TestJpeg.Build(100, 50, null);
        var sof = Array.FindIndex(jpeg, 2, b => b == 0xC0) - 1;
        var cut = jpeg[..(sof + 7)]; // SOF marker present, size fields cut off

        Assert.Equal(-1, JpegFix.FindSofHeightOffset(cut));
        Assert.Throws<FormatException>(() => PdfWriter.JpegInfo(cut));
    }

    [Fact]
    public void Zero_height_page_is_rejected_rather_than_writing_a_broken_pdf()
    {
        var jpeg = TestJpeg.Build(100, 0, dnlHeight: null);
        Assert.Equal(jpeg, JpegFix.PatchZeroHeight(jpeg));
        Assert.Throws<FormatException>(() => PdfWriter.JpegInfo(jpeg));
    }

    [Fact]
    public void Scanner_status_lists_jobs()
    {
        var doc = XDocument.Parse("""
            <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:State>Processing</pwg:State>
              <scan:Jobs>
                <scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/abc</pwg:JobUri><pwg:JobState>Processing</pwg:JobState><scan:Age>3</scan:Age></scan:JobInfo>
                <scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/old</pwg:JobUri><pwg:JobState>Completed</pwg:JobState><scan:Age>300</scan:Age></scan:JobInfo>
              </scan:Jobs>
            </scan:ScannerStatus>
            """);

        var s = ScannerStatus.Parse(doc);

        Assert.Equal([new ScanJobInfo("/eSCL/ScanJobs/abc", "Processing", 3), new ScanJobInfo("/eSCL/ScanJobs/old", "Completed", 300)], s.Jobs);
    }

    [Fact]
    public void Certificate_is_pinned_on_first_use_and_a_different_one_is_refused()
    {
        var pin = new MemoryPin();
        using var http = new DeviceHttp("printer.test", pin: pin);
        using var first = SelfSigned("CN=printer");
        using var impostor = SelfSigned("CN=printer");

        Assert.True(http.ValidateCertificate(first, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.NotNull(pin.Value);
        Assert.True(http.ValidateCertificate(first, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.False(http.CertificateChanged);

        Assert.False(http.ValidateCertificate(impostor, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.True(http.CertificateChanged);
    }

    [Fact]
    public void Pinned_printer_refuses_a_different_certificate_even_if_it_is_CA_valid()
    {
        var pin = new MemoryPin();
        using var http = new DeviceHttp("printer.test", pin: pin);
        using var first = SelfSigned("CN=printer");
        using var other = SelfSigned("CN=printer");
        Assert.True(http.ValidateCertificate(first, SslPolicyErrors.RemoteCertificateChainErrors));

        Assert.False(http.ValidateCertificate(other, SslPolicyErrors.None));
    }

    [Fact]
    public void Racing_first_handshakes_are_both_checked_against_the_pin_that_won()
    {
        var pin = new MemoryPin();
        using var http = new DeviceHttp("printer.test", pin: pin);
        using var winner = SelfSigned("CN=printer");
        using var loser = SelfSigned("CN=printer");
        pin.SetIfAbsent(443, Convert.ToHexString(SHA256.HashData(winner.GetRawCertData()))); // the other handshake stored first

        Assert.False(http.ValidateCertificate(loser, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.True(http.ValidateCertificate(winner, SslPolicyErrors.RemoteCertificateChainErrors));
    }

    [Theory]
    [InlineData("12345678-1234-4abc-8def-123456789abc")]
    [InlineData("urn:uuid:12345678-1234-4ABC-8DEF-123456789ABC")]
    [InlineData("{12345678-1234-4abc-8def-123456789abc}")]
    public void Printer_ids_are_normalised_guids(string raw) =>
        Assert.Equal("12345678-1234-4abc-8def-123456789abc", PrinterId.Normalize(raw, "10.0.0.5"));

    [Theory]
    [InlineData(@"..\..\evil")]
    [InlineData(@"C:\Windows\x")]
    [InlineData(null)]
    public void Untrusted_ids_become_a_stable_guid_from_the_host(string? raw)
    {
        var id = PrinterId.Normalize(raw, "10.0.0.5");
        Assert.True(Guid.TryParse(id, out _));
        Assert.Equal(id, PrinterId.Normalize(raw, "10.0.0.5"));
        Assert.DoesNotContain('\\', PrinterId.FileName(id));
        Assert.DoesNotContain('.', PrinterId.FileName(@"..\..\evil"));
    }

    private const string Known = "12345678-1234-4abc-8def-123456789abc", Other = "87654321-4321-4cba-8fed-cba987654321";

    [Fact]
    public void Same_device_when_any_interface_reports_its_uuid() =>
        Assert.Equal(DeviceIdentity.Same, PrinterId.Identify(Known, "192.0.2.10", [null, null, Other, "urn:uuid:12345678-1234-4ABC-8DEF-123456789ABC"]));

    [Fact]
    public void Different_device_when_it_reports_only_other_uuids() =>
        Assert.Equal(DeviceIdentity.Different, PrinterId.Identify(Known, "192.0.2.10", [Other, null, "", Other]));

    [Fact]
    public void Unknown_when_the_device_reports_no_usable_uuid() =>
        Assert.Equal(DeviceIdentity.Unknown, PrinterId.Identify(Known, "192.0.2.10", [null, " ", "not-a-uuid"]));

    [Fact]
    public void Unknown_for_a_printer_remembered_by_its_address()
    {
        var byAddress = PrinterId.Normalize(null, "192.0.2.10");

        Assert.Equal(DeviceIdentity.Unknown, PrinterId.Identify(byAddress, "192.0.2.10", [Other]));
    }

    [Fact]
    public void A_uuid_the_user_accepted_counts_as_the_printer()
    {
        Assert.Equal(DeviceIdentity.Same, PrinterId.Identify(Known, [Other], "192.0.2.10", ["urn:uuid:" + Other.ToUpperInvariant()]));
        Assert.Equal(DeviceIdentity.Different, PrinterId.Identify(Known, [], "192.0.2.10", [Other]));
    }

    [Theory]
    // The announced address answers with the printer's UUID: move; as another device: never.
    [InlineData(DeviceIdentity.Same, true, "HP LaserJet MFP M234dw", "HP LaserJet MFP M234dw", true)]
    [InlineData(DeviceIdentity.Different, false, null, "HP LaserJet MFP M234dw", false)]
    // Can't tell there (no answer, or no UUID): a typed address still answering as this kind of printer is kept...
    [InlineData(DeviceIdentity.Unknown, true, "HP LaserJet MFP M234dw", "HP LaserJet MFP M234dw", false)]
    [InlineData(DeviceIdentity.Unknown, true, "HP LaserJet MFP M234dw", null, false)]
    // ...otherwise the printer moves, as discovery always did.
    [InlineData(DeviceIdentity.Unknown, false, null, "HP LaserJet MFP M234dw", true)]
    [InlineData(DeviceIdentity.Unknown, true, "Example Inkjet 300", "HP LaserJet MFP M234dw", true)]
    public void Moving_to_an_announced_address(DeviceIdentity atNew, bool currentAnswers, string? currentModel, string? announced, bool move) =>
        Assert.Equal(move, PrinterId.ShouldMove(atNew, currentAnswers, currentModel, announced));

    [Theory]
    [InlineData("HP LaserJet MFP M234dw", "hp laserjet mfp m234dw", true)]
    [InlineData("HP LaserJet MFP M234dw", "LaserJet MFP M234dw", true)]
    [InlineData("Example Inkjet 300", "HP LaserJet MFP M234dw", false)]
    [InlineData(null, "HP LaserJet MFP M234dw", false)]
    [InlineData("Anything", "", true)]
    public void Same_kind_of_device(string? model, string? announced, bool expected) => Assert.Equal(expected, PrinterId.SameKind(model, announced));

    private static X509Certificate2 SelfSigned(string subject)
    {
        using var key = ECDsa.Create();
        var req = new CertificateRequest(subject, key, HashAlgorithmName.SHA256);
        return req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(1));
    }

    private sealed class MemoryPin : ICertificatePin
    {
        public readonly Dictionary<int, string> Pins = [];
        public string? Value => Pins.GetValueOrDefault(443);
        public string? Get(int port) => Pins.GetValueOrDefault(port);
        public string SetIfAbsent(int port, string sha256Hex) => Pins.TryAdd(port, sha256Hex) ? sha256Hex : Pins[port];
    }
}
