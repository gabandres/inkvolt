using System.Buffers.Binary;
using System.IO.Compression;

namespace InkvoltPdf.Core;

/// <summary>Minimal PNG writer for rendered pixels: 8-bit RGB or RGBA (straight alpha), no filtering.</summary>
internal static class PngEncoder
{
    private static readonly uint[] Crc = MakeCrc();

    /// <param name="pixels">Rows of <paramref name="width"/> pixels, 3 (RGB) or 4 (RGBA) bytes each, tightly packed.</param>
    public static byte[] Encode(int width, int height, byte[] pixels, bool alpha)
    {
        var channels = alpha ? 4 : 3;
        if (pixels.Length < (long)width * height * channels) throw new ArgumentException("Too few pixels for the size.", nameof(pixels));
        using var png = new MemoryStream();
        png.Write([0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        var ihdr = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr, width);
        BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(4), height);
        ihdr[8] = 8;                    // bits per channel
        ihdr[9] = (byte)(alpha ? 6 : 2); // RGBA or RGB
        Chunk(png, "IHDR", ihdr);
        using (var data = new MemoryStream())
        {
            using (var z = new ZLibStream(data, CompressionLevel.Fastest, leaveOpen: true))
            {
                var stride = width * channels;
                for (var y = 0; y < height; y++)
                {
                    z.WriteByte(0); // no filter
                    z.Write(pixels, y * stride, stride);
                }
            }
            Chunk(png, "IDAT", data.ToArray());
        }
        Chunk(png, "IEND", []);
        return png.ToArray();
    }

    private static void Chunk(Stream s, string type, byte[] data)
    {
        Span<byte> head = stackalloc byte[8];
        BinaryPrimitives.WriteInt32BigEndian(head, data.Length);
        for (var i = 0; i < 4; i++) head[4 + i] = (byte)type[i];
        s.Write(head);
        s.Write(data);
        var crc = 0xFFFFFFFFu;
        foreach (var b in head[4..]) crc = Crc[(crc ^ b) & 0xFF] ^ (crc >> 8);
        foreach (var b in data) crc = Crc[(crc ^ b) & 0xFF] ^ (crc >> 8);
        Span<byte> tail = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(tail, crc ^ 0xFFFFFFFFu);
        s.Write(tail);
    }

    private static uint[] MakeCrc()
    {
        var table = new uint[256];
        for (var n = 0u; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }
}

/// <summary>
/// Minimal PNG reader for the pictures batch presets carry (<see cref="PngEncoder"/>'s output, and any 8-bit RGB or RGBA
/// PNG without interlacing, every row filter): to a <see cref="StampImage"/>.
/// </summary>
internal static class PngDecoder
{
    /// <exception cref="InvalidDataException">Not a PNG of that kind, or damaged.</exception>
    public static StampImage Decode(byte[] png)
    {
        ReadOnlySpan<byte> signature = [0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A];
        if (png.Length < 33 || !png.AsSpan(0, 8).SequenceEqual(signature)) throw new InvalidDataException("not a PNG file");
        int width = 0, height = 0, channels = 0;
        using var idat = new MemoryStream();
        for (var at = 8; at + 12 <= png.Length;)
        {
            var length = BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(at));
            if (length < 0 || at + 12L + length > png.Length) throw new InvalidDataException("a chunk runs past the end");
            var type = System.Text.Encoding.ASCII.GetString(png, at + 4, 4);
            var data = png.AsSpan(at + 8, length);
            if (type == "IHDR")
            {
                width = BinaryPrimitives.ReadInt32BigEndian(data);
                height = BinaryPrimitives.ReadInt32BigEndian(data[4..]);
                if (data[8] != 8 || data[12] != 0) throw new InvalidDataException("only 8-bit pictures without interlacing");
                channels = data[9] switch { 2 => 3, 6 => 4, _ => throw new InvalidDataException("only RGB or RGBA pictures") };
            }
            else if (type == "IDAT") idat.Write(data);
            else if (type == "IEND") break;
            at += 12 + length;
        }
        if (width is <= 0 or > 8192 || height is <= 0 or > 8192 || channels == 0) throw new InvalidDataException("no usable picture size");

        var stride = width * channels;
        var raw = new byte[(long)(stride + 1) * height];
        idat.Position = 0;
        using (var z = new ZLibStream(idat, CompressionMode.Decompress))
        {
            try
            {
                z.ReadExactly(raw);
            }
            catch (EndOfStreamException)
            {
                throw new InvalidDataException("the picture data is cut short");
            }
        }
        var pixels = new byte[stride * height];
        for (var y = 0; y < height; y++)
        {
            var filter = raw[y * (stride + 1)];
            var src = raw.AsSpan(y * (stride + 1) + 1, stride);
            var row = pixels.AsSpan(y * stride, stride);
            var up = y > 0 ? pixels.AsSpan((y - 1) * stride, stride) : default;
            for (var x = 0; x < stride; x++)
            {
                int a = x >= channels ? row[x - channels] : 0, b = y > 0 ? up[x] : 0, c = x >= channels && y > 0 ? up[x - channels] : 0;
                row[x] = (byte)(src[x] + filter switch
                {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => (a + b) / 2,
                    4 => Paeth(a, b, c),
                    _ => throw new InvalidDataException("an unknown row filter"),
                });
            }
        }
        var n = width * height;
        var rgb = new byte[n * 3];
        byte[]? alpha = channels == 4 ? new byte[n] : null;
        for (var i = 0; i < n; i++)
        {
            rgb[i * 3] = pixels[i * channels];
            rgb[i * 3 + 1] = pixels[i * channels + 1];
            rgb[i * 3 + 2] = pixels[i * channels + 2];
            if (alpha is not null) alpha[i] = pixels[i * 4 + 3];
        }
        return new StampImage(width, height, rgb, alpha);
    }

    private static int Paeth(int a, int b, int c)
    {
        var p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }
}
