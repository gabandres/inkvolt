namespace InkvoltPrint.Core.Printing.Raster;

/// <summary>The three raster formats IPP Everywhere printers take without a driver.</summary>
public enum RasterFormat
{
    /// <summary>PWG 5102.4 PWG Raster (<c>image/pwg-raster</c>), the one IPP Everywhere requires.</summary>
    PwgRaster,

    /// <summary>Apple Raster (<c>image/urf</c>), AirPrint's.</summary>
    Urf,

    /// <summary>PCLm (<c>application/PCLm</c>): Mopria's raster in a constrained PDF (Mopria Alliance, PCLm Technical Reference).</summary>
    Pclm,
}

/// <summary>8 bits a pixel, grey (sGray, 0 black, 255 white) or three per pixel (sRGB).</summary>
public enum RasterColor
{
    Gray8,
    Rgb8,
}

/// <summary>
/// How the printer wants the back of a two-sided sheet (<c>pwg-raster-document-sheet-back</c>, <c>urf-supported</c>'s DM1-DM4,
/// <c>pclm-raster-back-side</c>): as it is, flipped, rotated, or as a manual-tumble unit takes it.
/// </summary>
public enum BackSide
{
    Normal,
    Flipped,
    Rotated,
    ManualTumble,
}

/// <summary>One page's pixels, top row first, left to right, with no padding: one byte a pixel (grey) or three (R, G, B).</summary>
public sealed class RasterPage
{
    /// <summary>Most pixels on one page: 400 million (13 × 19 in at 1200 dpi is 356 million), so three bytes a pixel fit one array.</summary>
    public const long MaxPixels = 400_000_000;

    public RasterPage(int width, int height, RasterColor color, byte[] pixels)
    {
        if (width <= 0 || height <= 0 || (long)width * height > MaxPixels) throw new ArgumentOutOfRangeException(nameof(width), "page size out of range");
        if (pixels.LongLength != (long)width * height * Channels(color)) throw new ArgumentException("pixel count doesn't match the size", nameof(pixels));
        (Width, Height, Color, Pixels) = (width, height, color, pixels);
    }

    public int Width { get; }
    public int Height { get; }
    public RasterColor Color { get; }
    public byte[] Pixels { get; }
    public int BytesPerPixel => Channels(Color);
    public int BytesPerLine => Width * BytesPerPixel;

    public static int Channels(RasterColor color) => color == RasterColor.Gray8 ? 1 : 3;

    /// <summary>A white page.</summary>
    public static RasterPage Blank(int width, int height, RasterColor color)
    {
        var pixels = new byte[(long)width * height * Channels(color)];
        Array.Fill(pixels, (byte)255);
        return new RasterPage(width, height, color, pixels);
    }

    /// <summary>
    /// From 32-bit BGRA rows (WPF's Pbgra32 on a white page, so alpha is already applied), as grey (ITU-R BT.601 weights)
    /// or RGB. <paramref name="stride"/> is the bytes from one row to the next.
    /// </summary>
    public static RasterPage FromBgra(int width, int height, int stride, ReadOnlySpan<byte> bgra, RasterColor color)
    {
        if (width <= 0 || height <= 0 || stride < width * 4 || bgra.Length < (long)stride * (height - 1) + width * 4)
            throw new ArgumentException("pixel buffer too small for the size", nameof(bgra));
        var channels = Channels(color);
        var pixels = new byte[(long)width * height * channels];
        for (var y = 0; y < height; y++)
        {
            var row = bgra.Slice(y * stride, width * 4);
            var o = (long)y * width * channels;
            for (var x = 0; x < width; x++)
            {
                byte b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2];
                if (channels == 1) pixels[o++] = (byte)((77 * r + 150 * g + 29 * b + 128) >> 8);
                else
                {
                    pixels[o++] = r;
                    pixels[o++] = g;
                    pixels[o++] = b;
                }
            }
        }
        return new RasterPage(width, height, color, pixels);
    }

    /// <summary>This page cut or padded with white on the right and bottom to <paramref name="width"/> × <paramref name="height"/> (rounding between resolutions).</summary>
    public RasterPage Fitted(int width, int height)
    {
        if (width == Width && height == Height) return this;
        var fitted = Blank(width, height, Color);
        var copy = Math.Min(width, Width) * BytesPerPixel;
        for (var y = 0; y < Math.Min(height, Height); y++)
            Pixels.AsSpan(y * BytesPerLine, copy).CopyTo(fitted.Pixels.AsSpan(y * fitted.BytesPerLine));
        return fitted;
    }

    /// <summary>Each pixel made a <paramref name="factor"/> × <paramref name="factor"/> block: a page drawn at 300 dpi for a 600 dpi printer.</summary>
    public RasterPage Enlarged(int factor)
    {
        if (factor == 1) return this;
        if (factor is < 1 or > 8) throw new ArgumentOutOfRangeException(nameof(factor));
        var (w, h, bpp) = (Width * factor, Height * factor, BytesPerPixel);
        if ((long)w * h > MaxPixels) throw new ArgumentOutOfRangeException(nameof(factor), "page size out of range");
        var pixels = new byte[(long)w * h * bpp];
        var line = new byte[w * bpp];
        for (var y = 0; y < Height; y++)
        {
            var src = Pixels.AsSpan(y * BytesPerLine, BytesPerLine);
            for (var x = 0; x < Width; x++)
                for (var k = 0; k < factor; k++)
                    src.Slice(x * bpp, bpp).CopyTo(line.AsSpan((x * factor + k) * bpp));
            for (var k = 0; k < factor; k++) line.CopyTo(pixels.AsSpan((y * factor + k) * w * bpp));
        }
        return new RasterPage(w, h, Color, pixels);
    }
}

/// <summary>
/// What every page of one raster job shares: format, resolution, color, the paper (its PWG self-describing name and its
/// size in hundredths of a millimetre, as <c>media-col</c> gives it), two-sided printing and how the back is turned.
/// </summary>
public sealed record RasterJob(RasterFormat Format, int Dpi, RasterColor Color, string MediaName, int WidthHmm, int HeightHmm, int Pages)
{
    public bool Duplex { get; init; }

    /// <summary>Two-sided along the short edge (calendar style).</summary>
    public bool Tumble { get; init; }

    public BackSide Back { get; init; }

    /// <summary>IPP <c>print-quality</c>: 3 draft, 4 normal, 5 high; 0 the printer's default.</summary>
    public int Quality { get; init; }

    /// <summary>The paper type keyword (<c>media-type</c>, e.g. <c>photographic-glossy</c>), written in a PWG raster header.</summary>
    public string? MediaType { get; init; }

    /// <summary>PCLm's strip height in pixels (<c>pclm-strip-height-preferred</c>).</summary>
    public int StripHeight { get; init; } = 16;

    /// <summary>PCLm's strips with PDF's RunLengthDecode instead of FlateDecode (<c>pclm-compression-method-preferred</c>).</summary>
    public bool RunLength { get; init; }

    /// <summary>Pixels across the paper at <see cref="Dpi"/>.</summary>
    public int WidthPixels => Pixels(WidthHmm, Dpi);

    public int HeightPixels => Pixels(HeightHmm, Dpi);

    /// <summary>The paper in points (1/72 in), as PWG raster's PageSize and PCLm's MediaBox give it.</summary>
    public double WidthPoints => WidthHmm * 72 / 2540.0;

    public double HeightPoints => HeightHmm * 72 / 2540.0;

    public static int Pixels(int hundredthsOfMm, int dpi) => (int)Math.Round(hundredthsOfMm * (double)dpi / 2540);

    /// <summary>
    /// The turn a page gets (cross-feed, feed: -1 mirrors that direction): fronts never; backs as the printer asks, as CUPS's
    /// <c>cupsRasterInitPWGHeader</c> and PWG 5102.4 set CrossFeedTransform and FeedTransform for each <see cref="BackSide"/>.
    /// </summary>
    public (int CrossFeed, int Feed) Transform(int pageIndex)
    {
        if (!Duplex || pageIndex % 2 == 0) return (1, 1);
        return Back switch
        {
            BackSide.Flipped => Tumble ? (-1, 1) : (1, -1),
            BackSide.ManualTumble => Tumble ? (-1, -1) : (1, 1),
            BackSide.Rotated => Tumble ? (1, 1) : (-1, -1),
            _ => (1, 1),
        };
    }

    /// <summary>Why this job can't be written, or null: sizes and counts checked before anything is allocated.</summary>
    public string? Problem()
    {
        if (Dpi is < 72 or > 2400) return "resolution out of range";
        if (WidthHmm is < 500 or > 200_000 || HeightHmm is < 500 or > 500_000) return "paper size out of range";
        if ((long)WidthPixels * HeightPixels > RasterPage.MaxPixels) return "page too large";
        if (Pages is < 1 or > 100_000) return "page count out of range";
        if (StripHeight is < 1 or > 4096) return "strip height out of range";
        return null;
    }
}

/// <summary>Writes one raster job to a stream page by page (a page's pixels are let go once it is written).</summary>
public abstract class RasterWriter
{
    protected RasterWriter(Stream output, RasterJob job)
    {
        if (job.Problem() is { } problem) throw new ArgumentException(problem, nameof(job));
        (Output, Job) = (output, job);
    }

    protected Stream Output { get; }
    public RasterJob Job { get; }
    public int Written { get; private set; }

    public static RasterWriter For(Stream output, RasterJob job) => job.Format switch
    {
        RasterFormat.PwgRaster => new PwgRasterWriter(output, job),
        RasterFormat.Urf => new UrfWriter(output, job),
        _ => new PclmWriter(output, job),
    };

    /// <summary>The next page, the paper's size in pixels at the job's resolution and color.</summary>
    public void Write(RasterPage page)
    {
        if (Written >= Job.Pages) throw new InvalidOperationException("more pages than the job said");
        if (page.Width != Job.WidthPixels || page.Height != Job.HeightPixels || page.Color != Job.Color)
            throw new ArgumentException("page doesn't match the job's paper and color", nameof(page));
        WritePage(page, Written);
        Written++;
    }

    /// <summary>Ends the document (PCLm's page tree, cross-reference table and trailer). Every page must have been written.</summary>
    public void Finish()
    {
        if (Written != Job.Pages) throw new InvalidOperationException("fewer pages than the job said");
        WriteEnd();
        Output.Flush();
    }

    protected abstract void WritePage(RasterPage page, int index);

    protected virtual void WriteEnd() { }
}
