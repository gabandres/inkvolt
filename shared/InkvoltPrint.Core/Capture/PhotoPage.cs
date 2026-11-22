using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Core.Capture;

/// <summary>Pixels row by row with no padding: <see cref="Channels"/> 3 (blue, green, red) or 1 (grey).</summary>
public sealed record Picture(byte[] Pixels, int Width, int Height, int Channels)
{
    public bool IsGray => Channels == 1;
}

/// <summary>Decodes a photo whose header was checked (<see cref="PhotoInput.Inspect"/>) and writes a page as JPEG: the app's (Windows' codecs), a fake in tests.</summary>
public interface IPhotoCodec
{
    /// <summary>The photo's pixels as stored (not turned by its EXIF orientation), BGR or grey; throws when it doesn't decode.</summary>
    Picture Decode(byte[] data, PhotoHeader header);

    /// <summary>The page as a JPEG at <paramref name="dpi"/>.</summary>
    byte[] EncodeJpeg(Picture page, int dpi);
}

/// <summary>A paper size a photographed page is taken to be, by its proportions.</summary>
public sealed record PaperGuess(string Name, double LongInches);

/// <summary>A photo made into a scanned page: its pixels at <see cref="Dpi"/>, whether a page was found and straightened, and the paper it was taken for.</summary>
public sealed record CapturedPage(Picture Image, int Dpi, bool Straightened, PaperGuess Paper);

/// <summary>
/// A photo of a page made into a scan (roadmap 4.6, 4.12): turned the way the camera held it (EXIF orientation), the page
/// found on a darker desk and warped back to a rectangle (<see cref="Trapezoid"/>, only when sure; otherwise the whole photo),
/// sized as the paper its proportions say (<see cref="Paper"/>) at the resolution asked for, in grey when asked. A photo has no
/// resolution of its own, so its size on paper comes from the paper it's taken for; what's left of the cleanup (straightening a
/// few degrees, crop to the paper, whitening, OCR) is the scan review's, as for a scanner's page.
/// </summary>
public static class PhotoPage
{
    /// <summary>Resolutions a capture source offers (a phone's photo of a Letter page is about 350 dpi; finer would only be made up).</summary>
    public static readonly IReadOnlyList<int> Resolutions = [150, 200, 300];

    private static readonly (string Name, double Long, double Short)[] Papers = [("Letter", 11, 8.5), ("A4", 297 / 25.4, 210 / 25.4), ("Legal", 14, 8.5)];

    /// <summary>
    /// The paper a page of <paramref name="longSide"/> × <paramref name="shortSide"/> (any unit) is taken for: Letter, A4 or Legal when its
    /// proportions are within 4% of one; longer and narrower, a page 8.5 inches wide, or a till receipt 80 mm wide past 2.2 times as long
    /// as wide; squarer, a page 11 inches the long way (a photo of the whole frame).
    /// </summary>
    public static PaperGuess Paper(double longSide, double shortSide)
    {
        if (!(longSide > 0 && shortSide > 0 && double.IsFinite(longSide) && double.IsFinite(shortSide))) return new("Letter", 11);
        if (shortSide > longSide) (longSide, shortSide) = (shortSide, longSide);
        var ratio = Math.Min(longSide / shortSide, 8);
        var best = Papers.MinBy(p => Math.Abs(Math.Log(ratio / (p.Long / p.Short))));
        if (Math.Abs(Math.Log(ratio / (best.Long / best.Short))) <= Math.Log(1.04)) return new(best.Name, best.Long);
        if (ratio > 2.2) return new("Receipt", 80 / 25.4 * ratio);
        if (ratio > Papers.Max(p => p.Long / p.Short)) return new("Narrow", 8.5 * ratio);
        return new("Photo", 11);
    }

    /// <summary>
    /// The page in <paramref name="photo"/> (as stored, <paramref name="orientation"/> its EXIF orientation) at <paramref name="dpi"/>
    /// (75 to 600), in grey when <paramref name="gray"/>. <paramref name="straighten"/>: look for the page on a desk and warp it flat.
    /// </summary>
    public static CapturedPage Make(Picture photo, int orientation, int dpi, bool gray, bool straighten = true, CancellationToken cancel = default)
    {
        if (photo.Channels is not (1 or 3) || photo.Width < 1 || photo.Height < 1 || (long)photo.Width * photo.Height * photo.Channels != photo.Pixels.Length)
            throw new ArgumentException("Not a picture of the size it says.", nameof(photo));
        dpi = Math.Clamp(dpi, 75, 600);
        var image = Orient(photo, orientation);
        if (gray && !image.IsGray) image = new Picture(ScanCleanup.ToGray(image.Pixels, image.Width, image.Height), image.Width, image.Height, 1);
        cancel.ThrowIfCancellationRequested();

        var perspective = straighten
            ? Trapezoid.Find(new GrayImage(image.Width, image.Height, image.IsGray ? image.Pixels : ScanCleanup.ToGray(image.Pixels, image.Width, image.Height)), cancel)
            : null;
        cancel.ThrowIfCancellationRequested();

        // The page's size in the photo: the found page's sides (the mean of each opposite pair), or the whole photo.
        double across = image.Width, down = image.Height;
        if (perspective is { Corners: var c })
        {
            static double Length((double X, double Y) a, (double X, double Y) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
            across = (Length(c[0], c[1]) + Length(c[3], c[2])) / 2;
            down = (Length(c[0], c[3]) + Length(c[1], c[2])) / 2;
        }
        var paper = Paper(Math.Max(across, down), Math.Min(across, down));
        var scale = paper.LongInches * dpi / Math.Max(across, down); // photo pixels to page pixels
        var outW = Math.Clamp((int)Math.Round(across * scale), 1, PhotoInput.MaxSide * 2);
        var outH = Math.Clamp((int)Math.Round(down * scale), 1, PhotoInput.MaxSide * 2);

        // Much smaller than the photo: averaged down first, so the page doesn't sparkle with the detail sampling would skip.
        var factor = Math.Max(1, (int)Math.Floor(1 / scale));
        var source = factor > 1 ? Reduce(image, factor) : image;
        var ch = source.Channels;
        var result = new byte[(long)outW * outH * ch];
        Parallel.For(0, outH, new ParallelOptions { CancellationToken = cancel }, y =>
        {
            for (var x = 0; x < outW; x++)
            {
                double sx, sy;
                if (perspective is { } p)
                {
                    var px = p.Left + (x + 0.5) / outW * (p.Right - p.Left);
                    var py = p.Top + (y + 0.5) / outH * (p.Bottom - p.Top);
                    (sx, sy) = p.Source(px, py);
                }
                else (sx, sy) = ((x + 0.5) / outW * image.Width, (y + 0.5) / outH * image.Height);
                PageWarp.Sample(source.Pixels, source.Width, source.Height, ch, sx / factor - 0.5, sy / factor - 0.5, result, (y * outW + x) * ch);
            }
        });
        return new CapturedPage(new Picture(result, outW, outH, ch), dpi, perspective is not null, paper);
    }

    /// <summary>The picture turned (and mirrored) the way an EXIF orientation of 1 to 8 says it is shown; any other value leaves it as it is.</summary>
    public static Picture Orient(Picture p, int orientation)
    {
        if (orientation is < 2 or > 8) return p;
        var (w, h, ch) = (p.Width, p.Height, p.Channels);
        var swap = orientation >= 5;
        var (ow, oh) = swap ? (h, w) : (w, h);
        var result = new byte[p.Pixels.Length];
        Parallel.For(0, oh, y =>
        {
            for (var x = 0; x < ow; x++)
            {
                var (sx, sy) = orientation switch
                {
                    2 => (w - 1 - x, y),
                    3 => (w - 1 - x, h - 1 - y),
                    4 => (x, h - 1 - y),
                    5 => (y, x),
                    6 => (y, h - 1 - x),
                    7 => (w - 1 - y, h - 1 - x),
                    _ => (w - 1 - y, x), // 8
                };
                Buffer.BlockCopy(p.Pixels, (sy * w + sx) * ch, result, (y * ow + x) * ch, ch);
            }
        });
        return new Picture(result, ow, oh, ch);
    }

    /// <summary>Each <paramref name="factor"/> × <paramref name="factor"/> block averaged into one pixel.</summary>
    private static Picture Reduce(Picture p, int factor)
    {
        var (w, h, ch) = (Math.Max(1, p.Width / factor), Math.Max(1, p.Height / factor), p.Channels);
        var result = new byte[w * h * ch];
        Parallel.For(0, h, y =>
        {
            Span<int> sum = stackalloc int[3];
            for (var x = 0; x < w; x++)
            {
                sum.Clear();
                var n = 0;
                for (var dy = 0; dy < factor && y * factor + dy < p.Height; dy++)
                    for (var dx = 0; dx < factor && x * factor + dx < p.Width; dx++, n++)
                    {
                        var i = ((y * factor + dy) * p.Width + x * factor + dx) * ch;
                        for (var c = 0; c < ch; c++) sum[c] += p.Pixels[i + c];
                    }
                for (var c = 0; c < ch; c++) result[(y * w + x) * ch + c] = (byte)(sum[c] / Math.Max(1, n));
            }
        });
        return new Picture(result, w, h, ch);
    }
}
