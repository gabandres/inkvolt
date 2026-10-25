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
