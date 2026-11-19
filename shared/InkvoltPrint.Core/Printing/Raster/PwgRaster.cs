using System.Buffers.Binary;
using System.Text;

namespace InkvoltPrint.Core.Printing.Raster;

/// <summary>
/// The page data compression PWG Raster (PWG 5102.4 §4.3.1.2) and Apple Raster share: each line starts with a line
/// repeat count (0-255: the line is used 1-256 times), then runs of pixels: 0-127 means the next pixel 1-128 times,
/// 129-255 means 257 minus it (2-128) pixels as they are. 128 is never written (Apple Raster reads it as "white to the
/// end of the line", PWG Raster doesn't define it). A page's transform (back sides) mirrors the lines and their order here.
/// </summary>
internal static class RasterLines
{
    public static void Write(Stream output, RasterPage page, (int CrossFeed, int Feed) transform)
    {
        var bpp = page.BytesPerPixel;
        var line = page.BytesPerLine;
        var current = new byte[line];
        var next = new byte[line];
        var packed = new byte[line + (page.Width + 127) / 128 + page.Width + 1]; // worst case: every pixel its own run byte
        Line(page, 0, transform, current);
        var y = 0;
        while (y < page.Height)
        {
            var repeat = 1;
            var haveNext = false;
            while (y + repeat < page.Height)
            {
                Line(page, y + repeat, transform, next);
                if (repeat == 256 || !next.AsSpan().SequenceEqual(current))
                {
                    haveNext = true;
                    break;
                }
                repeat++;
            }
            output.WriteByte((byte)(repeat - 1));
            output.Write(packed, 0, Pack(current, bpp, packed));
            y += repeat;
            if (haveNext) (current, next) = (next, current);
        }
    }

    /// <summary>Output line <paramref name="y"/>: the page's line, from the bottom when the feed is mirrored, reversed when the cross-feed is.</summary>
    internal static void Line(RasterPage page, int y, (int CrossFeed, int Feed) transform, byte[] into)
    {
        var source = transform.Feed < 0 ? page.Height - 1 - y : y;
        var row = page.Pixels.AsSpan((int)((long)source * page.BytesPerLine), page.BytesPerLine);
        if (transform.CrossFeed > 0)
        {
            row.CopyTo(into);
            return;
        }
        var bpp = page.BytesPerPixel;
        for (int x = 0, w = page.Width; x < w; x++) row.Slice((w - 1 - x) * bpp, bpp).CopyTo(into.AsSpan(x * bpp));
    }

    /// <summary>One line's runs into <paramref name="into"/>; returns the bytes written.</summary>
    internal static int Pack(ReadOnlySpan<byte> line, int bpp, byte[] into)
    {
        var n = line.Length / bpp;
        var o = 0;
        var i = 0;
        static bool Same(ReadOnlySpan<byte> line, int bpp, int a, int b) => line.Slice(a * bpp, bpp).SequenceEqual(line.Slice(b * bpp, bpp));
        while (i < n)
        {
            if (i + 1 < n && Same(line, bpp, i, i + 1))
            {
                var run = 2;
                while (i + run < n && run < 128 && Same(line, bpp, i, i + run)) run++;
                into[o++] = (byte)(run - 1);
                line.Slice(i * bpp, bpp).CopyTo(into.AsSpan(o));
                o += bpp;
                i += run;
                continue;
            }
            var count = 1; // pixels that differ from the one after them
            while (i + count < n && count < 128 && !(i + count + 1 < n && Same(line, bpp, i + count, i + count + 1))) count++;
            into[o++] = count == 1 ? (byte)0 : (byte)(257 - count);
            line.Slice(i * bpp, count * bpp).CopyTo(into.AsSpan(o));
            o += count * bpp;
            i += count;
        }
        return o;
    }
}

/// <summary>
/// PWG Raster (PWG 5102.4-2012, <c>image/pwg-raster</c>): the sync word <c>RaS2</c>, then per page a 1796-byte header
/// (big-endian, the field offsets of §4.3.1.1 Table 1) and the compressed lines. Grey is <c>sgray_8</c> (ColorSpace 18),
/// color <c>srgb_8</c> (ColorSpace 19), chunky; reserved fields are zero.
/// </summary>
public sealed class PwgRasterWriter : RasterWriter
{
    public const int HeaderBytes = 1796;
    public const int SgrayColorSpace = 18, SrgbColorSpace = 19;

    public PwgRasterWriter(Stream output, RasterJob job) : base(output, job) => output.Write("RaS2"u8);

    protected override void WritePage(RasterPage page, int index)
    {
        var transform = Job.Transform(index);
        Output.Write(Header(Job, transform));
        RasterLines.Write(Output, page, transform);
    }

    /// <summary>A page's header. Exposed for the byte tests.</summary>
    internal static byte[] Header(RasterJob job, (int CrossFeed, int Feed) transform)
    {
        var h = new byte[HeaderBytes];
        Text(h, 0, "PwgRaster");                    // MediaClass: always "PwgRaster"
        Text(h, 128, job.MediaType ?? "");           // MediaType
        U32(h, 272, job.Duplex ? 1u : 0);            // Duplex
        U32(h, 276, (uint)job.Dpi);                  // HWResolution: cross feed
        U32(h, 280, (uint)job.Dpi);                  //               feed
        U32(h, 352, (uint)Math.Round(job.WidthPoints));  // PageSize, points
        U32(h, 356, (uint)Math.Round(job.HeightPoints));
        U32(h, 368, job.Tumble ? 1u : 0);            // Tumble
        U32(h, 372, (uint)job.WidthPixels);          // Width
        U32(h, 376, (uint)job.HeightPixels);         // Height
        var bpp = job.Color == RasterColor.Gray8 ? 8u : 24u;
        U32(h, 384, 8);                              // BitsPerColor
        U32(h, 388, bpp);                            // BitsPerPixel
        U32(h, 392, (uint)job.WidthPixels * bpp / 8); // BytesPerLine
        U32(h, 396, 0);                              // ColorOrder: chunky
        U32(h, 400, job.Color == RasterColor.Gray8 ? (uint)SgrayColorSpace : SrgbColorSpace); // ColorSpace
        U32(h, 420, job.Color == RasterColor.Gray8 ? 1u : 3u); // NumColors
        U32(h, 452, (uint)job.Pages);                // TotalPageCount
        BinaryPrimitives.WriteInt32BigEndian(h.AsSpan(456), transform.CrossFeed); // CrossFeedTransform
        BinaryPrimitives.WriteInt32BigEndian(h.AsSpan(460), transform.Feed);      // FeedTransform
        U32(h, 472, (uint)job.WidthPixels);          // ImageBoxRight (Left and Top stay 0)
        U32(h, 476, (uint)job.HeightPixels);         // ImageBoxBottom
        U32(h, 480, 0x00FFFFFF);                     // AlternatePrimary: white in sRGB
        U32(h, 484, (uint)job.Quality);              // PrintQuality: 0 default, 3 draft, 4 normal, 5 high
        Text(h, 1732, job.MediaName);                // PageSizeName: the PWG self-describing name
        return h;
    }

    private static void U32(byte[] h, int at, uint v) => BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(at), v);

    /// <summary>A 64-byte string field: US-ASCII, NUL-terminated and padded (at most 63 characters; others become '?').</summary>
    private static void Text(byte[] h, int at, string s)
    {
        var ascii = Encoding.ASCII.GetBytes(s.Length > 63 ? s[..63] : s);
        ascii.CopyTo(h, at);
    }
}

/// <summary>
/// Apple Raster (<c>image/urf</c>): <c>UNIRAST</c> and a NUL, the page count (big-endian), then per page a 32-byte header
/// (bits per pixel; color space 0 sGray, 1 sRGB; duplex 1 one-sided, 2 short edge, 3 long edge; quality; width, height and
/// resolution as big-endian 32-bit numbers at 12, 16 and 20) and the lines compressed as PWG Raster's. The layout CUPS
/// reads and writes (<c>cups/raster-stream.c</c>, <c>CUPS_RASTER_SYNCapple</c>).
/// </summary>
public sealed class UrfWriter : RasterWriter
{
    public const int HeaderBytes = 32;

    public UrfWriter(Stream output, RasterJob job) : base(output, job)
    {
        output.Write("UNIRAST\0"u8);
        Span<byte> count = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(count, (uint)job.Pages);
        output.Write(count);
    }

    protected override void WritePage(RasterPage page, int index)
    {
        Output.Write(Header(Job));
        RasterLines.Write(Output, page, Job.Transform(index));
    }

    internal static byte[] Header(RasterJob job)
    {
        var h = new byte[HeaderBytes];
        h[0] = job.Color == RasterColor.Gray8 ? (byte)8 : (byte)24;
        h[1] = job.Color == RasterColor.Gray8 ? (byte)0 : (byte)1;
        h[2] = !job.Duplex ? (byte)1 : job.Tumble ? (byte)2 : (byte)3;
        h[3] = (byte)(job.Quality is 3 or 4 or 5 ? job.Quality : 4);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(12), (uint)job.WidthPixels);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(16), (uint)job.HeightPixels);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(20), (uint)job.Dpi);
        return h;
    }
}
