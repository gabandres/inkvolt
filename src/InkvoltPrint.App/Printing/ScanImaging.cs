using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.App.Printing;

/// <summary>
/// Scanned pages as pixels: the small greyscale copy the blank page and skew checks read, and a page with its
/// <see cref="PageEdits"/> applied (straightened, cropped, turned). WIC only, no visuals, so any thread will do.
/// </summary>
public static class ScanImaging
{
    /// <summary>Longest side of the analysis copy: about 100 dpi for a letter page.</summary>
    private const int AnalysisSize = 1100;

    /// <summary>JPEG quality for edited pages (unedited pages keep the scanner's own JPEG).</summary>
    private const int Quality = 92;

    public static GrayImage Analysis(byte[] jpeg)
    {
        var (w, h, _) = PdfWriter.JpegInfo(jpeg);
        var scale = Math.Min(1, AnalysisSize / (double)Math.Max(w, h));
        var gray = new FormatConvertedBitmap(Decode(jpeg, (int)Math.Round(w * scale)), PixelFormats.Gray8, null, 0);
        var pixels = new byte[gray.PixelWidth * gray.PixelHeight];
        gray.CopyPixels(pixels, gray.PixelWidth, 0);
        return new GrayImage(gray.PixelWidth, gray.PixelHeight, pixels);
    }

    /// <summary>The page with its edits, decoded <paramref name="decodeWidth"/> pixels wide (0: full size). Frozen.</summary>
    public static BitmapSource Render(byte[] jpeg, PageEdits edits, int decodeWidth = 0)
    {
        BitmapSource bmp = Decode(jpeg, decodeWidth);
        if (bmp.Format != PixelFormats.Gray8 && bmp.Format != PixelFormats.Bgr24)
            bmp = new FormatConvertedBitmap(bmp, PixelFormats.Bgr24, null, 0);
        if (edits.Deskew != 0)
        {
            var channels = bmp.Format == PixelFormats.Gray8 ? 1 : 3;
            var stride = (bmp.PixelWidth * channels + 3) & ~3;
            var pixels = new byte[stride * bmp.PixelHeight];
            bmp.CopyPixels(pixels, stride, 0);
            pixels = PageRotate.Rotate(pixels, bmp.PixelWidth, bmp.PixelHeight, stride, channels, -edits.Deskew);
            bmp = BitmapSource.Create(bmp.PixelWidth, bmp.PixelHeight, bmp.DpiX, bmp.DpiY, bmp.Format, null, pixels, stride);
        }
        if (edits.Crop is { IsFull: false } crop)
        {
            var x = (int)Math.Round(crop.X * bmp.PixelWidth);
            var y = (int)Math.Round(crop.Y * bmp.PixelHeight);
            var w = Math.Clamp((int)Math.Round(crop.Width * bmp.PixelWidth), 1, bmp.PixelWidth - x);
            var h = Math.Clamp((int)Math.Round(crop.Height * bmp.PixelHeight), 1, bmp.PixelHeight - y);
            bmp = new CroppedBitmap(bmp, new Int32Rect(x, y, w, h));
        }
        if (edits.QuarterTurns % 4 != 0) bmp = new TransformedBitmap(bmp, new RotateTransform(90 * edits.QuarterTurns));
        bmp.Freeze();
        return bmp;
    }

    public static byte[] Jpeg(BitmapSource bmp)
    {
        var encoder = new JpegBitmapEncoder { QualityLevel = Quality };
        encoder.Frames.Add(BitmapFrame.Create(bmp));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        return ms.ToArray();
    }

    private static BitmapImage Decode(byte[] jpeg, int decodeWidth)
    {
        var img = new BitmapImage();
        img.BeginInit();
        img.CacheOption = BitmapCacheOption.OnLoad;
        if (decodeWidth > 0) img.DecodePixelWidth = decodeWidth;
        img.StreamSource = new MemoryStream(jpeg);
        img.EndInit();
        img.Freeze();
        return img;
    }
}
