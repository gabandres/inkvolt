using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.Core.Capture;

namespace InkvoltPrint.App.Printing;

/// <summary>
/// A capture source's photos decoded and its pages encoded with Windows' codecs (WIC through WPF), for <see cref="CaptureScanner"/>.
/// Only after <see cref="PhotoInput.Inspect"/> took the header; the frame is checked against it again (a file that says one size and
/// holds another is refused there). Off the UI thread, frozen.
/// </summary>
public sealed class PhotoCodec : IPhotoCodec
{
    public static readonly PhotoCodec Instance = new();

    public Picture Decode(byte[] data, PhotoHeader header)
    {
        using var stream = new MemoryStream(data, writable: false);
        BitmapDecoder decoder = header.Kind == PhotoKind.Png
            ? new PngBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad)
            : new JpegBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad);
        if (decoder.Frames.Count == 0) throw new InvalidDataException("No picture in the file.");
        BitmapSource frame = decoder.Frames[0];
        if (frame.PixelWidth != header.Width || frame.PixelHeight != header.Height) throw new InvalidDataException("The picture isn't the size its header says.");
        var gray = frame.Format == PixelFormats.Gray8;
        BitmapSource pixels = gray || frame.Format == PixelFormats.Bgr24 ? frame : new FormatConvertedBitmap(frame, PixelFormats.Bgr24, null, 0);
        var channels = gray ? 1 : 3;
        var stride = pixels.PixelWidth * channels;
        var bytes = new byte[(long)stride * pixels.PixelHeight];
        pixels.CopyPixels(bytes, stride, 0);
        return new Picture(bytes, pixels.PixelWidth, pixels.PixelHeight, channels);
    }

    public byte[] EncodeJpeg(Picture page, int dpi)
    {
        var bmp = BitmapSource.Create(page.Width, page.Height, dpi, dpi, page.IsGray ? PixelFormats.Gray8 : PixelFormats.Bgr24, null, page.Pixels,
            page.Width * page.Channels);
        bmp.Freeze();
        return ScanImaging.Jpeg(bmp);
    }
}
