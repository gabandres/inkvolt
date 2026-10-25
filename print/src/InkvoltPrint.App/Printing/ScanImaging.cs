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

    /// <summary>
    /// The photos on a scan of the glass, each cut out straight (<see cref="PhotoCrop"/>) and turned its quarter turns, at the
    /// scan's full resolution, as JPEGs. The scan is decoded once; only the pixels around each photo are copied out of it.
    /// </summary>
    public static List<byte[]> Photos(byte[] jpeg, IReadOnlyList<PhotoBox> boxes)
    {
        BitmapSource bmp = Decode(jpeg, 0);
        if (bmp.Format != PixelFormats.Gray8 && bmp.Format != PixelFormats.Bgr24)
            bmp = new FormatConvertedBitmap(bmp, PixelFormats.Bgr24, null, 0);
        bmp.Freeze();
        return [.. boxes.Select(box => Jpeg(Photo(bmp, box)))];
    }

    private static BitmapSource Photo(BitmapSource bmp, PhotoBox box)
    {
        var channels = bmp.Format == PixelFormats.Gray8 ? 1 : 3;
        var (x, y, w, h) = PhotoCrop.Bounds(box, bmp.PixelWidth, bmp.PixelHeight);
        var stride = (w * channels + 3) & ~3;
        var region = new byte[stride * h];
        bmp.CopyPixels(new Int32Rect(x, y, w, h), region, stride, 0);
        var photo = PhotoCrop.Straighten(region, w, h, stride, channels, box, bmp.PixelWidth, x, y);
        BitmapSource result = BitmapSource.Create(photo.Width, photo.Height, bmp.DpiX, bmp.DpiY, bmp.Format, null, photo.Pixels, photo.Stride);
        if (box.QuarterTurns % 4 != 0) result = new TransformedBitmap(result, new RotateTransform(90 * box.QuarterTurns));
        result.Freeze();
        return result;
    }

    /// <summary>
    /// The page's thumbnail with each photo's outline and number drawn over it (for the review's thumbnails). Needs the UI
    /// thread (drawing). Frozen.
    /// </summary>
    public static BitmapSource WithPhotos(BitmapSource page, IReadOnlyList<PhotoBox> photos)
    {
        if (photos.Count == 0) return page;
        var (w, h) = (page.PixelWidth, page.PixelHeight);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawImage(page, new Rect(0, 0, w, h));
            var accent = new SolidColorBrush(Color.FromRgb(0x00, 0x67, 0xC0));
            var pen = new Pen(accent, Math.Max(2, w / 160.0));
            var typeface = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
            for (var i = 0; i < photos.Count; i++)
            {
                var corners = photos[i].Corners().Select(c => new Point(c.X * w, c.Y * w)).ToList();
                var outline = new StreamGeometry();
                using (var g = outline.Open())
                {
                    g.BeginFigure(corners[0], false, true);
                    g.PolyLineTo(corners.Skip(1).ToList(), true, false);
                }
                dc.DrawGeometry(null, pen, outline);
                var label = new FormattedText($"{i + 1}", System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, typeface,
                    Math.Max(12, w / 18.0), Brushes.White, 1);
                var centre = new Point(photos[i].CenterX * w, photos[i].CenterY * w);
                var r = Math.Max(label.Width, label.Height) * 0.75;
                dc.DrawEllipse(accent, null, centre, r, r);
                dc.DrawText(label, new Point(centre.X - label.Width / 2, centre.Y - label.Height / 2));
            }
        }
        var bmp = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
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
