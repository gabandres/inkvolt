namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// A black-and-white (1-bit) image: <see cref="Height"/> rows of <see cref="Stride"/> bytes, the leftmost pixel in each
/// byte's highest bit, a set bit black (ink). What <see cref="CcittG4"/> encodes and a black-and-white PDF page holds.
/// </summary>
public sealed record BitImage
{
    /// <summary>The most pixels an image may have (a 600 dpi A3 page is about 70 million): bounds what is allocated.</summary>
    public const long MaxPixels = 200_000_000;

    public BitImage(int width, int height, byte[] bits)
    {
        if (width < 1 || height < 1 || (long)width * height > MaxPixels) throw new ArgumentOutOfRangeException(nameof(width), "Image size out of range");
        ArgumentNullException.ThrowIfNull(bits);
        if (bits.Length < (long)((width + 7) / 8) * height) throw new ArgumentException("Fewer bytes than the image's rows hold", nameof(bits));
        (Width, Height, Bits) = (width, height, bits);
    }

    public int Width { get; }
    public int Height { get; }
    public byte[] Bits { get; }

    /// <summary>Bytes per row: a row starts on a byte, its unused last bits are 0.</summary>
    public int Stride => (Width + 7) / 8;

    /// <summary>Whether the pixel at (<paramref name="x"/>, <paramref name="y"/>) is black.</summary>
    public bool this[int x, int y] => (Bits[y * Stride + (x >> 3)] & (0x80 >> (x & 7))) != 0;

    /// <summary>All white.</summary>
    public static BitImage White(int width, int height) => new(width, height, new byte[(long)((width + 7) / 8) * height]);

    /// <summary>Grey pixels (rows of <paramref name="width"/> bytes, 0 black) darker than <paramref name="threshold"/> as black.</summary>
    public static BitImage FromGray(byte[] gray, int width, int height, int threshold)
    {
        if (width < 1 || height < 1 || (long)width * height > MaxPixels || gray.Length < (long)width * height)
            throw new ArgumentOutOfRangeException(nameof(width), "Image size out of range");
        var stride = (width + 7) / 8;
        var bits = new byte[(long)stride * height];
        Parallel.For(0, height, y =>
        {
            var row = y * width;
            var line = y * stride;
            for (var x = 0; x < width; x++)
                if (gray[row + x] < threshold) bits[line + (x >> 3)] |= (byte)(0x80 >> (x & 7));
        });
        return new BitImage(width, height, bits);
    }

    /// <summary>The rows with a set bit white instead (PDF's DeviceGray at 1 bit: 0 black, 1 white).</summary>
    internal byte[] Inverted()
    {
        var stride = Stride;
        var tail = (byte)(0xFF << (8 * stride - Width)); // the bits past the row's end stay 0
        var result = new byte[(long)stride * Height];
        for (var y = 0; y < Height; y++)
            for (var i = 0; i < stride; i++)
            {
                var v = (byte)~Bits[y * stride + i];
                result[y * stride + i] = i == stride - 1 ? (byte)(v & tail) : v;
            }
        return result;
    }
}

/// <summary>
/// A scanned page made black and white for a small file: the paper evened out to white (<see cref="PaperLevel"/>, so a
/// lid's shadow or grey paper doesn't turn black), the JPEG's noise smoothed (<see cref="Smooth"/>), then each pixel black
/// or white at the level that best parts the page's ink from its paper (Otsu's), kept between <see cref="MinThreshold"/>
/// and <see cref="MaxThreshold"/> so a page of almost all paper or almost all ink isn't cut at an odd level.
/// </summary>
public static class Bilevel
{
    public const int MinThreshold = 96, MaxThreshold = 200;

    /// <param name="gray">Rows of <paramref name="width"/> bytes, 0 black, at <paramref name="dpi"/>; not changed.</param>
    public static BitImage FromScan(byte[] gray, int width, int height, int dpi, CancellationToken cancel = default)
    {
        if (width < 1 || height < 1 || (long)width * height > BitImage.MaxPixels || gray.Length < (long)width * height)
            throw new ArgumentOutOfRangeException(nameof(width), "Image size out of range");
        var smooth = Smooth.Median3(gray, width, height, cancel);
        cancel.ThrowIfCancellationRequested();
        PaperLevel.Whiten(smooth, PaperLevel.Estimate(smooth, width, height, Math.Clamp(dpi, 50, 2400)));
        cancel.ThrowIfCancellationRequested();
        return BitImage.FromGray(smooth, width, height, Threshold(smooth));
    }

    /// <summary>Otsu's level for the pixels (the one that best splits them into two groups), within the bounds above.</summary>
    public static int Threshold(byte[] gray)
    {
        var histogram = new long[256];
        foreach (var v in gray) histogram[v]++;
        long total = gray.Length, sumAll = 0;
        for (var v = 0; v < 256; v++) sumAll += v * histogram[v];
        long below = 0, sumBelow = 0;
        double best = -1;
        var level = 128;
        for (var t = 0; t < 255; t++)
        {
            below += histogram[t];
            sumBelow += t * histogram[t];
            var above = total - below;
            if (below == 0 || above == 0) continue;
            var meanBelow = sumBelow / (double)below;
            var meanAbove = (sumAll - sumBelow) / (double)above;
            var between = below * (double)above * (meanBelow - meanAbove) * (meanBelow - meanAbove);
            if (between > best) (best, level) = (between, t + 1); // pixels below t + 1 are the dark group
        }
        return Math.Clamp(level, MinThreshold, MaxThreshold);
    }
}
