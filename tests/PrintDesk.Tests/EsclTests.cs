using System.Buffers.Binary;
using PrintDesk.Core.Escl;

namespace PrintDesk.Tests;

public class EsclTests
{
    private static ScannerCapabilities Caps() => ScannerCapabilities.Parse(Fixture.Xml("eSCL_ScannerCapabilities.xml"));

    [Fact]
    public void Capabilities_platen_only()
    {
        var c = Caps();

        Assert.Equal("2.63", c.Version);
        Assert.Equal("12345678-1234-4abc-8def-123456789abc", c.Uuid);
        Assert.Equal([ScanSource.Platen], c.Sources);
        Assert.Equal([200, 300, 600], c.Platen!.Resolutions);
        Assert.Equal(["RGB24", "Grayscale8"], c.Platen.ColorModes);
        Assert.Equal((2550, 3508), (c.Platen.MaxWidth, c.Platen.MaxHeight));
    }

    [Fact]
    public void Status()
    {
        var s = ScannerStatus.Parse(Fixture.Xml("eSCL_ScannerStatus.xml"));
        Assert.True(s.IsIdle);
        Assert.Null(s.AdfState);
    }

    [Fact]
    public void ScanSettings_snaps_resolution_and_clamps_region()
    {
        var doc = EsclXml.BuildScanSettings(new ScanRequest(Resolution: 250, Color: ScanColor.Grayscale, Width: 9999), Caps());
        var s = doc.Root!;

        Assert.Equal(EsclXml.Scan + "ScanSettings", s.Name);
        Assert.Equal("200", s.Element(EsclXml.Scan + "XResolution")!.Value);
        Assert.Equal("Grayscale8", s.Element(EsclXml.Scan + "ColorMode")!.Value);
        Assert.Equal("Platen", s.Element(EsclXml.Pwg + "InputSource")!.Value);
        var region = s.Element(EsclXml.Pwg + "ScanRegions")!.Element(EsclXml.Pwg + "ScanRegion")!;
        Assert.Equal("2550", region.Element(EsclXml.Pwg + "Width")!.Value);
        Assert.Equal("3508", region.Element(EsclXml.Pwg + "Height")!.Value);
    }

    [Fact]
    public void ScanSettings_rejects_missing_source() =>
        Assert.Throws<InvalidOperationException>(() => EsclXml.BuildScanSettings(new ScanRequest(Source: ScanSource.Adf), Caps()));

    [Fact]
    public void JpegFix_copies_DNL_height_into_SOF()
    {
        var jpeg = TestJpeg.Build(width: 100, height: 0, dnlHeight: 1234);

        var fixedJpeg = JpegFix.PatchZeroHeight(jpeg);

        var off = JpegFix.FindSofHeightOffset(fixedJpeg);
        Assert.Equal(1234, BinaryPrimitives.ReadUInt16BigEndian(fixedJpeg.AsSpan(off)));
        Assert.Equal(0, BinaryPrimitives.ReadUInt16BigEndian(jpeg.AsSpan(off))); // input untouched
    }

    [Fact]
    public void JpegFix_leaves_normal_jpeg_alone()
    {
        var jpeg = TestJpeg.Build(width: 100, height: 50, dnlHeight: null);
        Assert.Same(jpeg, JpegFix.PatchZeroHeight(jpeg));
    }
}

/// <summary>Builds a structurally valid JPEG skeleton (markers only, fake scan data).</summary>
internal static class TestJpeg
{
    public static byte[] Build(int width, int height, int? dnlHeight, byte components = 3)
    {
        var b = new List<byte> { 0xFF, 0xD8 };
        b.AddRange([0xFF, 0xE0, 0x00, 0x10, (byte)'J', (byte)'F', (byte)'I', (byte)'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
        var sofLen = 8 + 3 * components;
        b.AddRange([0xFF, 0xC0, 0, (byte)sofLen, 8, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width, components]);
        for (byte c = 1; c <= components; c++) b.AddRange([c, 0x11, 0]);
        b.AddRange([0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 0x3F, 0]);
        b.AddRange([0x12, 0x34, 0xFF, 0x00, 0x56]); // entropy data with a stuffed FF
        if (dnlHeight is { } d) b.AddRange([0xFF, 0xDC, 0, 4, (byte)(d >> 8), (byte)d]);
        b.AddRange([0xFF, 0xD9]);
        return [.. b];
    }
}
