using MuPDFCore;
using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

public class ImageImportTests
{
    private static List<PdfDictionary> Images(PdfSharp.Pdf.PdfDocument doc, int page) =>
        [.. PdfObj.Dict(PdfObj.Dict(doc.Pages[page].Elements["/Resources"])!.Elements["/XObject"])!.Elements.Values.Select(PdfObj.Dict).OfType<PdfDictionary>()];

    [Fact]
    public void JpegIsEmbeddedAsIs()
    {
        var jpeg = TestImages.Jpeg(120, 80);
        var pdf = ImageImport.ImagesToPdf([(jpeg, "photo.jpg")]);
        using var doc = Core2Pdf.Open(pdf);
        Assert.Equal(1, doc.PageCount);
        var image = Assert.Single(Images(doc, 0));
        Assert.Equal("DCTDecode", PdfObj.Name(image.Elements["/Filter"]));
        Assert.Equal(jpeg, image.Stream!.Value);
        Assert.Equal(120, PdfObj.Int(image.Elements["/Width"]));
        Assert.Equal(80, PdfObj.Int(image.Elements["/Height"]));
        Assert.Equal("DeviceRGB", PdfObj.Name(image.Elements["/ColorSpace"]));

        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var g = engine.GetPage(0);
        Assert.True(g.Width > g.Height);
        // Red quarter top-left, white elsewhere.
        var red = TestImages.PixelAt(pdf, 0, g.Width * 0.2, g.Height * 0.2);
        Assert.True(red.R > 200 && red.G < 60, $"{red}");
        var white = TestImages.PixelAt(pdf, 0, g.Width * 0.8, g.Height * 0.8);
        Assert.True(white.G > 200, $"{white}");
    }

    [Fact]
    public void ExifOrientationTurnsThePage()
    {
        // Stored landscape, orientation 6 (rotate 90 clockwise to view): shown portrait, the red corner top-right.
        var jpeg = TestImages.WithExifOrientation(TestImages.Jpeg(200, 100), 6);
        Assert.Equal(6, ImageImport.ReadJpeg(jpeg)!.Orientation);
        var pdf = ImageImport.ImagesToPdf([(jpeg, "turned.jpg")]);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var g = engine.GetPage(0);
        Assert.True(g.Height > g.Width);
        var topRight = TestImages.PixelAt(pdf, 0, g.Width * 0.8, g.Height * 0.2);
        Assert.True(topRight.R > 200 && topRight.G < 60, $"{topRight}");
        var topLeft = TestImages.PixelAt(pdf, 0, g.Width * 0.2, g.Height * 0.2);
        Assert.True(topLeft.G > 200, $"{topLeft}");
    }

    /// <summary>
    /// The paragraph editor's Insert Picture reads a picture's size from its header (the pre-release review, from the Mac
    /// port): the header reader had no JPEG case, so every JPEG was "not an image". A JPEG's SOF segment gives it, its EXIF
    /// turn counted; a truncated file, a zero-length or overlong segment, endless fill bytes or a size past MaxPixels give none.
    /// </summary>
    [Fact]
    public void AJpegsPixelSizeComesFromItsFrameHeader()
    {
        var jpeg = TestImages.Jpeg(120, 80);
        Assert.Equal((120, 80), ImageImport.PixelSize(jpeg, "photo.jpg"));
        Assert.Equal((100, 200), ImageImport.PixelSize(TestImages.WithExifOrientation(TestImages.Jpeg(200, 100), 6), "turned.jpg"));
        Assert.Equal((300, 200), ImageImport.PixelSize(Frame(0xC2, 200, 300), "x.jpg")); // progressive (SOF2)
        Assert.Equal((300, 200), ImageImport.PixelSize(Frame(0xC1, 200, 300), "x.jpg")); // extended (SOF1)

        // Truncated inside the frame header, or before it: no size.
        var sof = Enumerable.Range(2, jpeg.Length - 3).First(i => jpeg[i] == 0xFF && jpeg[i + 1] is 0xC0 or 0xC1 or 0xC2);
        foreach (var cut in new[] { 3, sof, sof + 5, sof + 8 }) Assert.Equal((0, 0), ImageImport.PixelSize(jpeg[..cut], "cut.jpg"));

        Assert.Equal((0, 0), ImageImport.PixelSize([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x00, .. Frame(0xC0, 10, 10)[2..]], "zero.jpg"));
        Assert.Equal((0, 0), ImageImport.PixelSize([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01, .. Frame(0xC0, 10, 10)[2..]], "one.jpg"));
        Assert.Equal((0, 0), ImageImport.PixelSize([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 0, 0], "overlong.jpg"));
        Assert.Equal((0, 0), ImageImport.PixelSize([0xFF, 0xD8, .. Enumerable.Repeat((byte)0xFF, 1_000_000)], "fill.jpg"));
        Assert.Equal((0, 0), ImageImport.PixelSize(Frame(0xC0, 0, 300), "flat.jpg"));
        Assert.Equal((0, 0), ImageImport.PixelSize(Frame(0xC0, 65535, 65535), "huge.jpg")); // 4.3 billion pixels
        Assert.Equal((0, 0), ImageImport.PixelSize(Frame(0xC0, 200, 300, bits: 12), "deep.jpg")); // DCTDecode wants 8 bits

        // SOI, then a frame header (SOFn: 8-bit, height, width, 3 components) and the end.
        static byte[] Frame(byte sof, int height, int width, byte bits = 8) =>
        [
            0xFF, 0xD8, 0xFF, sof, 0x00, 17, bits, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width, 3,
            1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xFF, 0xD9,
        ];
    }

    [Fact]
    public void PngWithAlphaGetsAnSMask()
    {
        // Left half opaque red, right half fully transparent; one half-transparent dark red pixel row at the top.
        var png = TestImages.Png(40, 20, (x, y) => y == 0 ? ((byte)100, (byte)0, (byte)0, (byte)128) : x < 20 ? ((byte)255, (byte)0, (byte)0, (byte)255) : ((byte)0, (byte)0, (byte)0, (byte)0), dpi: 72);
        var pdf = ImageImport.ImagesToPdf([(png, "logo.png")]);
        using var doc = Core2Pdf.Open(pdf);
        var image = Assert.Single(Images(doc, 0));
        Assert.Equal("FlateDecode", PdfObj.Name(image.Elements["/Filter"]));
        Assert.Equal(40, PdfObj.Int(image.Elements["/Width"]));
        var mask = PdfObj.Dict(image.Elements["/SMask"]);
        Assert.NotNull(mask);
        Assert.Equal("DeviceGray", PdfObj.Name(mask!.Elements["/ColorSpace"]));
        var alpha = PdfObj.StreamBytes(mask);
        Assert.Equal(255, alpha[40 + 5]);
        Assert.Equal(0, alpha[40 + 30]);
        Assert.InRange(alpha[3], 120, 136);
        // Colors are stored straight (not premultiplied): the half-transparent pixel keeps its red of 100.
        var rgb = PdfObj.StreamBytes(image);
        Assert.InRange(rgb[3 * 3], 94, 106);

        // At 72 dpi the page is the image's pixel size; transparent parts show the white page.
        Assert.Equal(40, doc.Pages[0].Width.Point, 1);
        Assert.Equal(20, doc.Pages[0].Height.Point, 1);
        var clear = TestImages.PixelAt(pdf, 0, 30, 10);
        Assert.True(clear.R > 240 && clear.G > 240, $"{clear}");
        var solid = TestImages.PixelAt(pdf, 0, 5, 10);
        Assert.True(solid.R > 200 && solid.G < 60, $"{solid}");
    }

    [Fact]
    public void PageSizesAndPageCount()
    {
        var png = TestImages.Png(300, 100, (_, _) => (0, 0, 255, 255));
        var jpeg = TestImages.Jpeg(50, 100);
        var pdf = ImageImport.ImagesToPdf([(png, "wide.png"), (jpeg, "tall.jpg"), (png, "again.png")], PageSizeOption.Letter);
        using var doc = Core2Pdf.Open(pdf);
        Assert.Equal(3, doc.PageCount);
        // Wide image → landscape Letter; tall → portrait.
        Assert.Equal(792, doc.Pages[0].Width.Point, 1);
        Assert.Equal(612, doc.Pages[0].Height.Point, 1);
        Assert.Equal(612, doc.Pages[1].Width.Point, 1);
        Assert.Equal(792, doc.Pages[1].Height.Point, 1);
        // An opaque single-color image needs no mask; 96 dpi without pHYs: 300 px = 225 pt, centered.
        Assert.Null(Images(doc, 0)[0].Elements["/SMask"]);
        var center = TestImages.PixelAt(pdf, 0, 396, 306);
        Assert.True(center.B > 200 && center.R < 60, $"{center}");
        var outside = TestImages.PixelAt(pdf, 0, 396 - 120, 306);
        Assert.True(outside.R > 240, $"{outside}");

        using var a4 = Core2Pdf.Open(ImageImport.ImagesToPdf([(jpeg, "tall.jpg")], PageSizeOption.A4));
        Assert.Equal(595.28, a4.Pages[0].Width.Point, 1);

        Assert.Throws<InvalidOperationException>(() => ImageImport.ImagesToPdf([("not an image"u8.ToArray(), "notes.txt")]));
        Assert.Throws<ArgumentException>(() => ImageImport.ImagesToPdf([]));
    }
}
