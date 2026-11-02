using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace InkvoltPrint.App.Printing;

/// <summary>
/// One picture to print: a file, or one page of a multi-page TIFF. <see cref="PixelWidth"/> × <see cref="PixelHeight"/> as
/// stored; <see cref="Orientation"/> is its EXIF orientation (1 when it has none).
/// </summary>
public sealed record PhotoSource(string Path, int Frame, string Name, int PixelWidth, int PixelHeight, int Orientation, bool IsJpeg);

/// <summary>
/// Reading pictures for photo printing through Windows Imaging Component (what WPF decodes with): JPEG, PNG, BMP, GIF (its
/// first frame), TIFF (every page), and HEIC / WebP when this PC has their codecs (Microsoft Store extensions).
/// </summary>
public static class PhotoFiles
{
    private static readonly string[] Always = [".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".bmp", ".dib", ".gif", ".tif", ".tiff"];
    private static readonly string[] Heif = [".heic", ".heif", ".hif"];
    private static readonly string[] Webp = [".webp"];

    private static readonly Lazy<(bool Heif, bool Webp)> Codecs = new(() => (HasDecoder(HeifContainer), HasDecoder(WebpContainer)));

    /// <summary>This PC can open HEIC / HEIF photos (the HEIF extension; most HEIC photos also need the HEVC extension to decode).</summary>
    public static bool CanReadHeif => Codecs.Value.Heif;

    public static bool CanReadWebp => Codecs.Value.Webp;

    /// <summary>The extensions that can be opened on this PC.</summary>
    public static IReadOnlyList<string> Extensions =>
        [.. Always, .. CanReadHeif ? Heif : [], .. CanReadWebp ? Webp : []];

    public static bool IsPicture(string path) =>
        Extensions.Contains(System.IO.Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>A known picture type that this PC has no codec for (HEIC or WebP without the Store extension).</summary>
    public static string? MissingCodec(string path)
    {
        var ext = System.IO.Path.GetExtension(path);
        if (Heif.Contains(ext, StringComparer.OrdinalIgnoreCase) && !CanReadHeif)
            return "HEIC photos need the HEIF Image Extensions from the Microsoft Store, which this PC doesn't have.";
        if (Webp.Contains(ext, StringComparer.OrdinalIgnoreCase) && !CanReadWebp)
            return "WebP pictures need the Webp Image Extensions from the Microsoft Store, which this PC doesn't have.";
        return null;
    }

    /// <summary>The Open dialog's filter.</summary>
    public static string DialogFilter =>
        $"Pictures ({string.Join(", ", Extensions.Select(e => "*" + e))})|{string.Join(";", Extensions.Select(e => "*" + e))}|All files (*.*)|*.*";

    /// <summary>What the Photos tab says about formats on this PC.</summary>
    public static string FormatsText
    {
        get
        {
            var extra = new List<string>();
            if (CanReadHeif) extra.Add("HEIC");
            if (CanReadWebp) extra.Add("WebP");
            var missing = new List<string>();
            if (!CanReadHeif) missing.Add("HEIC");
            if (!CanReadWebp) missing.Add("WebP");
            return $"JPEG, PNG, BMP, GIF, TIFF{string.Concat(extra.Select(e => ", " + e))}." +
                   (missing.Count > 0 ? $" {string.Join(" and ", missing)} need Windows' image extension{(missing.Count > 1 ? "s" : "")} from the Microsoft Store." : "");
        }
    }

    /// <summary>
    /// The pictures in a file: one, or one per TIFF page. Throws <see cref="NotSupportedException"/> (no codec),
    /// <see cref="IOException"/> or <see cref="FileFormatException"/> for files it can't read, and
    /// <see cref="InvalidDataException"/> for one of more than <paramref name="maxPages"/> pages (checked before the pages are read).
    /// </summary>
    public static IReadOnlyList<PhotoSource> Read(string path, int maxPages = int.MaxValue)
    {
        using var stream = File.OpenRead(path);
        var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation | BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.None);
        var name = System.IO.Path.GetFileName(path);
        var isJpeg = decoder is JpegBitmapDecoder;
        // GIF frames are an animation: its first frame is the picture. TIFF pages are pictures of their own.
        var frames = decoder is TiffBitmapDecoder ? decoder.Frames.Count : 1;
        if (frames > maxPages) throw new InvalidDataException($"The picture has {frames:N0} pages: a batch takes at most {maxPages:N0} per file.");
        var list = new List<PhotoSource>(frames);
        for (var i = 0; i < frames; i++)
        {
            var frame = decoder.Frames[i];
            list.Add(new PhotoSource(path, i, frames > 1 ? $"{name}, page {i + 1}" : name, frame.PixelWidth, frame.PixelHeight, Orientation(frame), isJpeg));
        }
        return list;
    }

    /// <summary>The EXIF orientation (1-8) when the picture has one; WIC's photo policy finds it in JPEG, TIFF and HEIF alike.</summary>
    private static int Orientation(BitmapFrame frame)
    {
        try
        {
            if (frame.Metadata is not BitmapMetadata meta) return 1;
            var value = meta.GetQuery("System.Photo.Orientation") ?? (meta.Format == "jpg" ? meta.GetQuery("/app1/ifd/{ushort=274}") : null);
            return value is ushort o and >= 1 and <= 8 ? o : 1;
        }
        catch (Exception ex) when (ex is NotSupportedException or InvalidOperationException or ArgumentException or COMException)
        {
            return 1; // no metadata (BMP, some PNGs)
        }
    }

    /// <summary>
    /// The picture decoded no wider than <paramref name="maxWidth"/> stored pixels (0: full size), frozen so any thread can
    /// draw it. Stored orientation: the caller turns it (EXIF and the user's turns).
    /// </summary>
    public static BitmapSource Decode(PhotoSource photo, int maxWidth)
    {
        var width = maxWidth > 0 && maxWidth < photo.PixelWidth ? maxWidth : 0;
        if (photo.Frame == 0)
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad; // color profiles (Display P3, Adobe RGB) are applied: the pixels are sRGB
            if (width > 0) image.DecodePixelWidth = width;
            using var stream = File.OpenRead(photo.Path);
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        using (var stream = File.OpenRead(photo.Path))
        {
            // Not cached: a long TIFF's other pages aren't decoded for this one.
            var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.None).Frames[photo.Frame];
            BitmapSource result = frame;
            if (width > 0) result = new TransformedBitmap(frame, new ScaleTransform(width / (double)photo.PixelWidth, width / (double)photo.PixelWidth));
            var copy = new WriteableBitmap(result);
            copy.Freeze();
            return copy;
        }
    }

    /// <summary>
    /// The picture for a print job: decoded at the size it needs, flattened on white (transparent PNG / GIF areas print as
    /// paper) and stored as JPEG, which the XPS writer keeps as JPEG (<see cref="PrintImages"/>), so the job
    /// stays a few MB a page. Runs on the spooling thread.
    /// </summary>
    public static BitmapSource ForPrint(PhotoSource photo, int width, PrintImages images) => images.Jpeg(ForPrintJpeg(photo, width));

    /// <summary>
    /// The picture's JPEG for a print job, as <see cref="ForPrint"/>. <paramref name="upright"/> also applies its EXIF orientation
    /// (batch print has no turns of its own; Photos draws each sheet with them).
    /// </summary>
    public static byte[] ForPrintJpeg(PhotoSource photo, int width, bool upright = false)
    {
        BitmapSource bitmap = Decode(photo, width);
        if (photo.IsJpeg) bitmap = new FormatConvertedBitmap(bitmap, PixelFormats.Bgr24, null, 0); // CMYK and grey JPEGs too
        else
        {
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                var area = new Rect(0, 0, bitmap.PixelWidth, bitmap.PixelHeight);
                dc.DrawRectangle(Brushes.White, null, area);
                dc.DrawImage(bitmap, area);
            }
            var flat = new RenderTargetBitmap(bitmap.PixelWidth, bitmap.PixelHeight, 96, 96, PixelFormats.Pbgra32);
            flat.Render(visual);
            bitmap = flat;
        }
        if (upright && Core.Photos.ExifOrientation.Transform(photo.Orientation) is var (turns, mirror) && (turns != 0 || mirror))
        {
            var turn = new TransformGroup();
            if (mirror) turn.Children.Add(new ScaleTransform(-1, 1));
            if (turns != 0) turn.Children.Add(new RotateTransform(turns * 90));
            bitmap = new TransformedBitmap(bitmap, turn);
        }
        var encoder = new JpegBitmapEncoder { QualityLevel = 92 };
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var bytes = new MemoryStream();
        encoder.Save(bytes);
        return bytes.ToArray();
    }

    // ---- Is there a WIC decoder for this container format? (IWICImagingFactory::CreateDecoder; Store codecs included) ----

    private static readonly Guid HeifContainer = new("E1E62521-6787-405B-A339-500715B5763F");
    private static readonly Guid WebpContainer = new("E094B0E2-67F2-45B3-B0EA-115337CA7CF3");
    private static readonly Guid WicFactory = new("CACAF262-9370-4615-A13B-9F5539DA4C0A");

    private static bool HasDecoder(Guid container)
    {
        object? factory = null;
        try
        {
            factory = Activator.CreateInstance(Type.GetTypeFromCLSID(WicFactory, throwOnError: true)!);
            if (factory is not IWICImagingFactory wic || wic.CreateDecoder(container, IntPtr.Zero, out var decoder) < 0) return false;
            Marshal.Release(decoder);
            return true;
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException or TypeLoadException)
        {
            Log.Write($"WIC codec check: {ex.Message}");
            return false;
        }
        finally
        {
            if (factory is not null && Marshal.IsComObject(factory)) Marshal.ReleaseComObject(factory);
        }
    }

    /// <summary>The start of IWICImagingFactory's vtable, up to CreateDecoder (the others are never called).</summary>
    [ComImport, Guid("ec5ec8a9-c395-4314-9c77-54d7a935ff70"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IWICImagingFactory
    {
        void CreateDecoderFromFilename();
        void CreateDecoderFromStream();
        void CreateDecoderFromFileHandle();
        void CreateComponentInfo();

        [PreserveSig]
        int CreateDecoder(in Guid guidContainerFormat, IntPtr pguidVendor, out IntPtr ppIDecoder);
    }
}
