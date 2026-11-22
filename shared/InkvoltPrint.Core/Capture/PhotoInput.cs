using System.Buffers.Binary;

namespace InkvoltPrint.Core.Capture;

/// <summary>The kinds of photo a capture source may hand in.</summary>
public enum PhotoKind { Jpeg, Png }

/// <summary>
/// What a photo's header says, read before anything is decoded: its kind, its size in pixels and (JPEG) the EXIF orientation
/// a camera wrote (1 to 8; 1 when there is none).
/// </summary>
public sealed record PhotoHeader(PhotoKind Kind, int Width, int Height, int Orientation = 1)
{
    /// <summary>Its size once turned the way the EXIF orientation says (5 to 8 swap width and height).</summary>
    public (int Width, int Height) Upright => Orientation is >= 5 and <= 8 ? (Height, Width) : (Width, Height);
}

/// <summary>
/// A photo from a capture source (a phone over the network, a camera) checked as hostile input before it is decoded
/// (roadmap 4.6, 4.12): only JPEG or PNG by their first bytes (whatever a request's content type says), at most
/// <see cref="MaxBytes"/>, at least <see cref="MinSide"/> and at most <see cref="MaxSide"/> pixels a side and
/// <see cref="MaxPixels"/> in all, so a small file that would decode to gigabytes is refused unread. Every read is bounded
/// by the bytes there are.
/// </summary>
public static class PhotoInput
{
    /// <summary>The largest photo taken (bytes): a 50-megapixel phone photo at its finest JPEG is about 25 MB.</summary>
    public const int MaxBytes = 32 * 1024 * 1024;

    /// <summary>The longest side taken (pixels).</summary>
    public const int MaxSide = 12_000;

    /// <summary>The most pixels taken (a 50-megapixel camera's full size).</summary>
    public const long MaxPixels = 52_000_000;

    /// <summary>The shortest side taken: anything smaller holds no readable page.</summary>
    public const int MinSide = 200;

    /// <summary>The header of a JPEG or PNG within the limits, or null (not a photo, or too large or small).</summary>
    public static PhotoHeader? Inspect(ReadOnlySpan<byte> data)
    {
        if (data.Length is < 24 or > MaxBytes) return null;
        var header = data[0] == 0xFF && data[1] == 0xD8 ? Jpeg(data) : Png(data);
        if (header is null) return null;
        var (w, h) = (header.Width, header.Height);
        return w < MinSide || h < MinSide || w > MaxSide || h > MaxSide || (long)w * h > MaxPixels ? null : header;
    }

    private static ReadOnlySpan<byte> PngSignature => [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    private static PhotoHeader? Png(ReadOnlySpan<byte> data)
    {
        // The signature, then IHDR first: its length (13), its type, width and height (big-endian).
        if (!data[..8].SequenceEqual(PngSignature) || BinaryPrimitives.ReadUInt32BigEndian(data[8..]) != 13
            || !data.Slice(12, 4).SequenceEqual("IHDR"u8)) return null;
        var w = BinaryPrimitives.ReadUInt32BigEndian(data[16..]);
        var h = BinaryPrimitives.ReadUInt32BigEndian(data[20..]);
        return w > MaxSide || h > MaxSide ? null : new PhotoHeader(PhotoKind.Png, (int)w, (int)h);
    }

    /// <summary>The markers up to the first frame header (SOF): its size, and the orientation from an EXIF block before it.</summary>
    private static PhotoHeader? Jpeg(ReadOnlySpan<byte> data)
    {
        var orientation = 1;
        var at = 2;
        while (at + 4 <= data.Length)
        {
            if (data[at] != 0xFF) return null;
            var marker = data[at + 1];
            if (marker == 0xFF) { at++; continue; } // fill byte
            if (marker is 0x01 or (>= 0xD0 and <= 0xD7)) { at += 2; continue; } // no length
            if (marker is 0xD8 or 0xD9 or 0xDA) return null; // a second start, the end or the scan before any frame header
            var length = BinaryPrimitives.ReadUInt16BigEndian(data[(at + 2)..]);
            if (length < 2 || at + 2 + length > data.Length) return null;
            var segment = data.Slice(at + 4, length - 2);
            if (marker is (>= 0xC0 and <= 0xC3) or (>= 0xC5 and <= 0xC7) or (>= 0xC9 and <= 0xCB) or (>= 0xCD and <= 0xCF))
            {
                if (segment.Length < 6) return null;
                var h = BinaryPrimitives.ReadUInt16BigEndian(segment[1..]);
                var w = BinaryPrimitives.ReadUInt16BigEndian(segment[3..]);
                return new PhotoHeader(PhotoKind.Jpeg, w, h, orientation);
            }
            if (marker == 0xE1 && segment.Length > 14 && segment[..6].SequenceEqual("Exif\0\0"u8)) orientation = ExifOrientation(segment[6..]);
            at += 2 + length;
        }
        return null;
    }

    /// <summary>Tag 0x0112 of a TIFF block's first directory (1 to 8), or 1 when it isn't there or doesn't read.</summary>
    internal static int ExifOrientation(ReadOnlySpan<byte> tiff)
    {
        if (tiff.Length < 8) return 1;
        bool little;
        if (tiff[0] == 'I' && tiff[1] == 'I') little = true;
        else if (tiff[0] == 'M' && tiff[1] == 'M') little = false;
        else return 1;
        ushort U16(ReadOnlySpan<byte> s) => little ? BinaryPrimitives.ReadUInt16LittleEndian(s) : BinaryPrimitives.ReadUInt16BigEndian(s);
        uint U32(ReadOnlySpan<byte> s) => little ? BinaryPrimitives.ReadUInt32LittleEndian(s) : BinaryPrimitives.ReadUInt32BigEndian(s);
        if (U16(tiff[2..]) != 42) return 1;
        var ifd = U32(tiff[4..]);
        if (ifd < 8 || ifd > tiff.Length - 2) return 1;
        var count = U16(tiff[(int)ifd..]);
        for (var i = 0; i < count; i++)
        {
            var entry = (long)ifd + 2 + i * 12L;
            if (entry + 12 > tiff.Length) return 1;
            var e = tiff.Slice((int)entry, 12);
            if (U16(e) != 0x0112) continue;
            // SHORT (3), one value, held in the entry itself.
            if (U16(e[2..]) != 3 || U32(e[4..]) != 1) return 1;
            var value = U16(e[8..]);
            return value is >= 1 and <= 8 ? value : 1;
        }
        return 1;
    }
}
