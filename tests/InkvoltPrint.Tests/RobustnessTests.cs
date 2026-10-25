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
