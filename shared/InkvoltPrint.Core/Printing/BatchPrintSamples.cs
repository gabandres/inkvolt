using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace InkvoltPrint.Core.Printing;

/// <summary>
/// Small real files written from their formats' specs, so demo mode and the tests can run a batch through the real engines with
/// no files shipped: PDFs with a given number of pages (one with a password, RC4 40-bit as the PDF 1.3 standard handler writes
/// it), a baseline JPEG, a PNG, a multi-page TIFF. Each page or picture is plain grey, tinted by <c>shade</c>.
/// </summary>
internal static class BatchPrintSamples
{
    private static readonly byte[] Pad = Convert.FromHexString("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A");

    /// <summary>A PDF of <paramref name="pages"/> Letter pages, each saying its number and file; with <paramref name="password"/>, it opens only with that.</summary>
    public static byte[] Pdf(int pages, string label, string? password = null)
    {
        var fileId = MD5.HashData(Encoding.UTF8.GetBytes(label + pages));
        byte[]? key = null;
        string? encrypt = null;
        var kids = string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{4 + i * 2} 0 R"));
        var objects = new List<byte[]>
        {
            Encoding.ASCII.GetBytes("<< /Type /Catalog /Pages 2 0 R >>"),
            Encoding.ASCII.GetBytes($"<< /Type /Pages /Kids [{kids}] /Count {pages} >>"),
            Encoding.ASCII.GetBytes("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        };
        var encryptNumber = 4 + pages * 2;
        if (password is not null)
        {
            const int permissions = -44; // all printing allowed; the bits above 6 set, as the standard handler has them
            var owner = Rc4(MD5.HashData(Padded(password)).AsSpan(0, 5), Padded(password));
            using var md5 = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
            md5.AppendData(Padded(password));
            md5.AppendData(owner);
            Span<byte> p = stackalloc byte[4];
            BinaryPrimitives.WriteInt32LittleEndian(p, permissions);
            md5.AppendData(p);
            md5.AppendData(fileId);
            key = md5.GetHashAndReset()[..5];
            var user = Rc4(key, Pad);
            encrypt = $"<< /Filter /Standard /V 1 /R 2 /O <{Convert.ToHexString(owner)}> /U <{Convert.ToHexString(user)}> /P {permissions} >>";
        }
        for (var i = 0; i < pages; i++)
        {
            var number = 4 + i * 2;
            objects.Add(Encoding.ASCII.GetBytes($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {number + 1} 0 R >>"));
            var text = new string(label.Where(c => c is >= ' ' and <= '~' and not ('(' or ')' or '\\')).ToArray());
            var content = Encoding.ASCII.GetBytes($"BT /F1 36 Tf 72 680 Td ({text} page {i + 1}) Tj ET");
            if (key is not null) content = Rc4(ObjectKey(key, number + 1), content);
            objects.Add([.. Encoding.ASCII.GetBytes($"<< /Length {content.Length} >>\nstream\n"), .. content, .. Encoding.ASCII.GetBytes("\nendstream")]);
        }
        if (encrypt is not null) objects.Add(Encoding.ASCII.GetBytes(encrypt));

        using var pdf = new MemoryStream();
        void Write(string s) => pdf.Write(Encoding.ASCII.GetBytes(s));
        Write("%PDF-1.3\n");
        var offsets = new long[objects.Count];
        for (var i = 0; i < objects.Count; i++)
        {
            offsets[i] = pdf.Position;
            Write($"{i + 1} 0 obj\n");
            pdf.Write(objects[i]);
            Write("\nendobj\n");
        }
        var xref = pdf.Position;
        Write($"xref\n0 {objects.Count + 1}\n0000000000 65535 f \n");
        foreach (var o in offsets) Write($"{o:D10} 00000 n \n");
        var id = Convert.ToHexString(fileId);
        Write($"trailer\n<< /Size {objects.Count + 1} /Root 1 0 R /ID [<{id}> <{id}>]{(encrypt is null ? "" : $" /Encrypt {encryptNumber} 0 R")} >>\nstartxref\n{xref}\n%%EOF\n");
        return pdf.ToArray();
    }

    private static byte[] Padded(string password)
    {
        var bytes = Encoding.Latin1.GetBytes(password);
        return [.. bytes.Take(32), .. Pad.Take(32 - Math.Min(32, bytes.Length))];
    }

    private static byte[] ObjectKey(byte[] key, int number)
    {
        byte[] extra = [(byte)number, (byte)(number >> 8), (byte)(number >> 16), 0, 0];
        return MD5.HashData([.. key, .. extra])[..Math.Min(key.Length + 5, 16)];
    }

    private static byte[] Rc4(ReadOnlySpan<byte> key, ReadOnlySpan<byte> data)
    {
        var s = Enumerable.Range(0, 256).Select(i => (byte)i).ToArray();
        for (int i = 0, j = 0; i < 256; i++)
        {
            j = (j + s[i] + key[i % key.Length]) & 255;
            (s[i], s[j]) = (s[j], s[i]);
        }
        var result = new byte[data.Length];
        for (int n = 0, i = 0, j = 0; n < data.Length; n++)
        {
            i = (i + 1) & 255;
            j = (j + s[i]) & 255;
            (s[i], s[j]) = (s[j], s[i]);
            result[n] = (byte)(data[n] ^ s[(s[i] + s[j]) & 255]);
        }
        return result;
    }

    /// <summary>A baseline mid-grey JPEG: no block differs from the last, so the entropy data is two bits a block.</summary>
    public static byte[] Jpeg(int width, int height)
    {
        using var j = new MemoryStream();
        j.Write([0xFF, 0xD8]);
        j.Write([0xFF, 0xE0, 0, 16, (byte)'J', (byte)'F', (byte)'I', (byte)'F', 0, 1, 1, 1, 0, 150, 0, 150, 0, 0]); // JFIF, 150 dpi
        j.Write([0xFF, 0xDB, 0, 67, 0]);
        j.Write(Enumerable.Repeat((byte)8, 64).ToArray()); // quantization 8: a DC step is one grey level
        j.Write([0xFF, 0xC0, 0, 11, 8, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width, 1, 1, 0x11, 0]);
        // One Huffman code each, "0": DC difference category 0, AC end of block.
        foreach (var table in new byte[] { 0x00, 0x10 })
        {
            j.Write([0xFF, 0xC4, 0, 20, table, 1]);
            j.Write(new byte[15]);
            j.WriteByte(0);
        }
        j.Write([0xFF, 0xDA, 0, 8, 1, 1, 0x00, 0, 63, 0]);
        var blocks = (long)((width + 7) / 8) * ((height + 7) / 8);
        for (long b = 0; b < blocks / 4; b++) j.WriteByte(0); // four blocks to the byte, each "0" and "0"
        var last = (int)(blocks % 4) * 2;
        if (last > 0) j.WriteByte((byte)(0xFF >> last)); // padded with ones
        j.Write([0xFF, 0xD9]);
        return j.ToArray();
    }

    /// <summary>A grey 8-bit PNG.</summary>
    public static byte[] Png(int width, int height, byte shade = 128)
    {
        using var data = new MemoryStream();
        using (var z = new ZLibStream(data, CompressionLevel.Fastest, leaveOpen: true))
        {
            var row = new byte[width + 1];
            Array.Fill(row, shade);
            row[0] = 0;
            for (var y = 0; y < height; y++) z.Write(row);
        }
        Span<byte> ihdr = stackalloc byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr, width);
        BinaryPrimitives.WriteInt32BigEndian(ihdr[4..], height);
        ihdr[8] = 8; // bits
        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        Chunk(png, "IHDR", ihdr);
        Chunk(png, "IDAT", data.ToArray());
        Chunk(png, "IEND", []);
        return png.ToArray();
    }

    private static void Chunk(Stream png, string type, ReadOnlySpan<byte> data)
    {
        Span<byte> number = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(number, data.Length);
        png.Write(number);
        var body = new byte[4 + data.Length];
        Encoding.ASCII.GetBytes(type, body);
        data.CopyTo(body.AsSpan(4));
        png.Write(body);
        BinaryPrimitives.WriteUInt32BigEndian(number, Crc32(body));
        png.Write(number);
    }

    internal static uint Crc32(ReadOnlySpan<byte> bytes)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in bytes)
        {
            crc ^= b;
            for (var i = 0; i < 8; i++) crc = (crc >> 1) ^ (0xEDB88320u & (uint)-(int)(crc & 1));
        }
        return ~crc;
    }

    /// <summary>A grey, uncompressed little-endian TIFF of <paramref name="pages"/> pages.</summary>
    public static byte[] Tiff(int pages, int width, int height, byte shade = 128)
    {
        const int Tags = 8, IfdSize = 2 + Tags * 12 + 4;
        var pixels = width * height;
        var bytes = new byte[8 + pages * (IfdSize + pixels)];
        "II*\0"u8.CopyTo(bytes);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(4), 8);
        var at = 8;
        for (var p = 0; p < pages; p++)
        {
            var data = at + IfdSize;
            var next = p + 1 < pages ? data + pixels : 0;
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(at), Tags);
            (ushort Tag, ushort Type, int Value)[] tags =
            [
                (256, 4, width), (257, 4, height), (258, 3, 8), (259, 3, 1), (262, 3, 1), (273, 4, data), (278, 4, height), (279, 4, pixels),
            ];
            for (var t = 0; t < Tags; t++)
            {
                var e = bytes.AsSpan(at + 2 + t * 12);
                BinaryPrimitives.WriteUInt16LittleEndian(e, tags[t].Tag);
                BinaryPrimitives.WriteUInt16LittleEndian(e[2..], tags[t].Type);
                BinaryPrimitives.WriteInt32LittleEndian(e[4..], 1);
                BinaryPrimitives.WriteInt32LittleEndian(e[8..], tags[t].Value);
            }
            BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(at + 2 + Tags * 12), next);
            bytes.AsSpan(data, pixels).Fill(shade);
            at = data + pixels;
        }
        return bytes;
    }
}
