using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Xml.Linq;
using PrintDesk.Core.Escl;
using PrintDesk.Core.Ipp;
using PrintDesk.Core.Model;
using PrintDesk.Core.Net;
using PrintDesk.Core.Pdf;

namespace PrintDesk.Tests;

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

    private static X509Certificate2 SelfSigned(string subject)
    {
        using var key = ECDsa.Create();
        var req = new CertificateRequest(subject, key, HashAlgorithmName.SHA256);
        return req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(1));
    }

    private sealed class MemoryPin : ICertificatePin
    {
        public string? Value;
        public string? Get() => Value;
        public void Set(string sha256Hex) => Value = sha256Hex;
    }
}
