using System.Buffers.Binary;
using System.Text;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Tests;

public class IppTests
{
    [Fact]
    public void Encodes_get_printer_attributes()
    {
        var req = IppCodec.EncodeGetPrinterAttributes("ipp://h:631/ipp/print", ["printer-state", "marker-levels"]);

        Assert.Equal([1, 1, 0, 0x0B, 0, 0, 0, 1, 0x01], req[..9]);
        Assert.Equal(0x03, req[^1]);
        var text = Encoding.ASCII.GetString(req);
        Assert.Contains("requested-attributes", text);
        Assert.Equal(1, CountOf(text, "requested-attributes")); // additional values use empty names
        Assert.Contains("marker-levels", text);
    }

    [Fact]
    public void Decodes_multi_valued_printer_attributes_to_status_and_supplies()
    {
        var resp = new Builder()
            .Group(0x01).Str(0x47, "attributes-charset", "utf-8")
            .Group(0x04)
            .Int(0x23, "printer-state", 3)
            .Str(0x44, "printer-state-reasons", "toner-low-warning").Str(0x44, "", "media-empty-error")
            .Str(0x41, "marker-names", "Black Cartridge")
            .Int(0x21, "marker-levels", 8)
            .Int(0x21, "marker-low-levels", 10)
            .Str(0x44, "marker-types", "toner")
            .End();

        var r = IppCodec.Decode(resp);
        var status = IppClient.ToStatus(r);
        var supply = Assert.Single(IppClient.ToConsumables(r));

        Assert.True(r.Ok);
        Assert.Equal("ready", status.Code);
        Assert.Equal(Severity.Error, status.Severity);
        Assert.Equal(["toner-low", "media-empty"], status.Alerts.Select(a => a.Id));
        Assert.Equal(("Black Cartridge", 8, "low"), (supply.Name, supply.PercentRemaining, supply.State));
        Assert.False(r.Attributes.ContainsKey("attributes-charset")); // operation group ignored
    }

    [Fact]
    public void Firmware_version_from_ipp_prefers_the_main_firmware_entry()
    {
        var resp = new Builder()
            .Group(0x04)
            .Str(0x42, "printer-firmware-name", "boot").Str(0x42, "", "system-firmware")
            .Str(0x41, "printer-firmware-string-version", "1.0.2").Str(0x41, "", "2.6.1")
            .End();

        var fw = FirmwareInfo.From(null, IppCodec.Decode(resp))!;

        Assert.Equal("2.6.1", fw.Display);
        Assert.Contains("printer-firmware-string-version", IppClient.StatusAttributes);
    }

    private static int CountOf(string s, string sub) => (s.Length - s.Replace(sub, "").Length) / sub.Length;

    private sealed class Builder
    {
        private readonly List<byte> _b = [1, 1, 0, 0, 0, 0, 0, 1];
        public Builder Group(byte tag) { _b.Add(tag); return this; }
        public Builder Str(byte tag, string name, string value) => Attr(tag, name, Encoding.UTF8.GetBytes(value));
        public Builder Int(byte tag, string name, int value)
        {
            var v = new byte[4];
            BinaryPrimitives.WriteInt32BigEndian(v, value);
            return Attr(tag, name, v);
        }
        public byte[] End() { _b.Add(3); return [.. _b]; }
        private Builder Attr(byte tag, string name, byte[] value)
        {
            _b.Add(tag);
            _b.AddRange([(byte)(name.Length >> 8), (byte)name.Length]);
            _b.AddRange(Encoding.UTF8.GetBytes(name));
            _b.AddRange([(byte)(value.Length >> 8), (byte)value.Length]);
            _b.AddRange(value);
            return this;
        }
    }
}

public class PdfTests
{
    [Fact]
    public void Writes_pages_with_valid_xref_and_hidden_text()
    {
        var jpeg = TestJpeg.Build(width: 2550, height: 3300, dnlHeight: null);
        using var ms = new MemoryStream();

        PdfWriter.Write(ms, [new PdfPage(jpeg, 300, [new OcrWord("Hello (world)", 300, 300, 600, 60)]), new PdfPage(jpeg, 300)], "Test");

        var pdf = Encoding.Latin1.GetString(ms.ToArray());
        Assert.StartsWith("%PDF-1.4", pdf);
        Assert.EndsWith("%%EOF\n", pdf);
        Assert.Contains("/Count 2", pdf);
        Assert.Contains("/MediaBox [0 0 612 792]", pdf);
        Assert.Contains("3 Tr", pdf);
        Assert.Matches(@"<[0-9A-F]+> Tj", pdf); // the words themselves: OcrLayerTests

        // Every xref offset must point at "<id> 0 obj".
        var startxref = int.Parse(pdf[(pdf.LastIndexOf("startxref\n", StringComparison.Ordinal) + 10)..].Split('\n')[0]);
        var lines = pdf[startxref..].Split('\n');
        var count = int.Parse(lines[1].Split(' ')[1]);
        for (var id = 1; id < count; id++)
        {
            var entry = lines[2 + id];
            if (!entry.EndsWith("n ")) continue;
            var off = int.Parse(entry[..10]);
            Assert.StartsWith($"{id} 0 obj", pdf[off..]);
        }
    }

    [Fact]
    public void JpegInfo_reads_size_and_components()
    {
        Assert.Equal((640, 480, 1), PdfWriter.JpegInfo(TestJpeg.Build(640, 480, null, components: 1)));
    }
}
