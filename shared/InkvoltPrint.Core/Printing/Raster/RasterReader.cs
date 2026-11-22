using System.Buffers.Binary;

namespace InkvoltPrint.Core.Printing.Raster;

/// <summary>One page read from a raster document, with its resolution (dots per inch across and down).</summary>
public sealed record RasterDocumentPage(RasterPage Page, int DpiX, int DpiY)
{
    public double WidthInches => (double)Page.Width / DpiX;
    public double HeightInches => (double)Page.Height / DpiY;
}

/// <summary>How much one raster document may hold (roadmap 4.10: it comes from a device on the network).</summary>
public sealed record RasterLimits
{
    /// <summary>Pages in one document.</summary>
    public int MaxPages { get; init; } = 500;

    /// <summary>Pixels on one page: 36 million (Letter at 600 dpi is 33.7 million; the shared printer asks for 300).</summary>
    public long MaxPixels { get; init; } = 36_000_000;

    public int MinDpi { get; init; } = 72;
    public int MaxDpi { get; init; } = 1200;
}

/// <summary>
/// Reads the raster documents a phone sends a shared printer (roadmap 4.10): PWG Raster (<c>image/pwg-raster</c>, PWG 5102.4, what
/// <see cref="PwgRasterWriter"/> writes) and Apple Raster (<c>image/urf</c>, what <see cref="UrfWriter"/> writes), 8-bit grey or 24-bit
/// color, chunky, with the run-length lines both use (<see cref="RasterLines"/>). Pages come one at a time. Everything is hostile input:
/// a header outside <see cref="RasterLimits"/> (size, resolution, pages), a format it doesn't take (other bit depths, color spaces or
/// orders), a run past the end of its line or data that ends early is a <see cref="FormatException"/>, never an index out of range,
/// and nothing is allocated before the header's size has been checked.
/// </summary>
public static class RasterReader
{
    /// <summary>The pages of a PWG Raster document ("RaS2", then each page's 1796-byte header and its lines).</summary>
    public static IEnumerable<RasterDocumentPage> ReadPwg(ReadOnlyMemory<byte> data, RasterLimits? limits = null)
    {
        limits ??= new RasterLimits();
        if (data.Length < 4 || !data.Span[..4].SequenceEqual("RaS2"u8)) throw new FormatException("not PWG Raster");
        var at = 4;
        var pages = 0;
        while (at < data.Length)
        {
            if (++pages > limits.MaxPages) throw new FormatException("too many pages");
            if (data.Length - at < PwgRasterWriter.HeaderBytes) throw new FormatException("PWG Raster header cut short");
            var h = data.Span.Slice(at, PwgRasterWriter.HeaderBytes);
            at += PwgRasterWriter.HeaderBytes;
            static uint U(ReadOnlySpan<byte> h, int offset) => BinaryPrimitives.ReadUInt32BigEndian(h[offset..]);
            var (dpiX, dpiY, width, height) = (U(h, 276), U(h, 280), U(h, 372), U(h, 376));
            var (bitsPerColor, bitsPerPixel, bytesPerLine, order, space) = (U(h, 384), U(h, 388), U(h, 392), U(h, 396), U(h, 400));
            var (color, invert) = (bitsPerColor, bitsPerPixel, space) switch
            {
                (8, 8, 18 or 3) => (RasterColor.Gray8, space == 3), // sgray; black (CUPS: 0 is white)
                (8, 24, 19 or 1 or 20) => (RasterColor.Rgb8, false), // srgb, rgb, adobe-rgb (printed as sRGB)
                _ => throw new FormatException("PWG Raster color not taken"),
            };
            Check(width, height, dpiX, dpiY, limits);
            if (order != 0 || bytesPerLine != width * (bitsPerPixel / 8)) throw new FormatException("PWG Raster layout not taken");
            var page = ReadLines(data.Span, ref at, (int)width, (int)height, color, whiteTo: false);
            if (invert) for (var i = 0; i < page.Pixels.Length; i++) page.Pixels[i] = (byte)(255 - page.Pixels[i]);
            yield return new RasterDocumentPage(page, (int)dpiX, (int)dpiY);
        }
    }

    /// <summary>The pages of an Apple Raster document ("UNIRAST", a NUL, a page count, then each page's 32-byte header and its lines).</summary>
    public static IEnumerable<RasterDocumentPage> ReadUrf(ReadOnlyMemory<byte> data, RasterLimits? limits = null)
    {
        limits ??= new RasterLimits();
        if (data.Length < 12 || !data.Span[..8].SequenceEqual("UNIRAST\0"u8)) throw new FormatException("not Apple Raster");
        var said = BinaryPrimitives.ReadUInt32BigEndian(data.Span[8..]);
        if (said > limits.MaxPages) throw new FormatException("too many pages");
        var at = 12;
        var pages = 0;
        while (at < data.Length && (said == 0 || pages < said))
        {
            if (++pages > limits.MaxPages) throw new FormatException("too many pages");
            if (data.Length - at < UrfWriter.HeaderBytes) throw new FormatException("Apple Raster header cut short");
            var h = data.Span.Slice(at, UrfWriter.HeaderBytes);
            at += UrfWriter.HeaderBytes;
            var (bpp, space) = (h[0], h[1]);
            var width = BinaryPrimitives.ReadUInt32BigEndian(h[12..]);
            var height = BinaryPrimitives.ReadUInt32BigEndian(h[16..]);
            var dpi = BinaryPrimitives.ReadUInt32BigEndian(h[20..]);
            var color = (bpp, space) switch
            {
                (8, 0 or 4) => RasterColor.Gray8, // sGray, device grey
                (24, 1 or 3 or 5) => RasterColor.Rgb8, // sRGB, Adobe RGB, device RGB
                _ => throw new FormatException("Apple Raster color not taken"),
            };
            Check(width, height, dpi, dpi, limits);
            var page = ReadLines(data.Span, ref at, (int)width, (int)height, color, whiteTo: true);
            yield return new RasterDocumentPage(page, (int)dpi, (int)dpi);
        }
        if (pages == 0) throw new FormatException("Apple Raster with no page");
    }

    private static void Check(uint width, uint height, uint dpiX, uint dpiY, RasterLimits limits)
    {
        if (width == 0 || height == 0 || width > 100_000 || height > 100_000 || (long)width * height > limits.MaxPixels)
            throw new FormatException("raster page size out of range");
        if (dpiX < limits.MinDpi || dpiX > limits.MaxDpi || dpiY < limits.MinDpi || dpiY > limits.MaxDpi)
            throw new FormatException("raster resolution out of range");
    }

    /// <summary>
    /// A page's lines: each a repeat count (the line is used 1-256 times), then runs: 0-127 the next pixel 1-128 times, 129-255 that
    /// many (257 minus it) pixels as they are, and 128 (Apple Raster, <paramref name="whiteTo"/>) white to the end of the line.
    /// </summary>
    private static RasterPage ReadLines(ReadOnlySpan<byte> data, ref int at, int width, int height, RasterColor color, bool whiteTo)
    {
        var bpp = RasterPage.Channels(color);
        var line = width * bpp;
        var pixels = new byte[(long)line * height];
        var y = 0;
        while (y < height)
        {
            if (at >= data.Length) throw new FormatException("raster data cut short");
            var repeat = data[at++] + 1;
            var row = pixels.AsSpan(y * line, line);
            var x = 0;
            while (x < width)
            {
                if (at >= data.Length) throw new FormatException("raster data cut short");
                var run = data[at++];
                if (run == 128)
                {
                    if (!whiteTo) throw new FormatException("PWG Raster run 128");
                    row[(x * bpp)..].Fill(255);
                    x = width;
                }
                else if (run < 128)
                {
                    var count = run + 1;
                    if (x + count > width) throw new FormatException("raster run past the end of its line");
                    if (data.Length - at < bpp) throw new FormatException("raster data cut short");
                    var pixel = data.Slice(at, bpp);
                    at += bpp;
                    for (var i = 0; i < count; i++) pixel.CopyTo(row[((x + i) * bpp)..]);
                    x += count;
                }
                else
                {
                    var count = 257 - run;
                    if (x + count > width) throw new FormatException("raster run past the end of its line");
                    if (data.Length - at < count * bpp) throw new FormatException("raster data cut short");
                    data.Slice(at, count * bpp).CopyTo(row[(x * bpp)..]);
                    at += count * bpp;
                    x += count;
                }
            }
            for (var r = 1; r < repeat && y + r < height; r++) row.CopyTo(pixels.AsSpan((y + r) * line, line));
            y += repeat;
        }
        return new RasterPage(width, height, color, pixels);
    }
}
