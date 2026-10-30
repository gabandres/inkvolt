namespace InkvoltPdf.Bench;

/// <summary>
/// A baseline JPEG encoder for 8-bit grayscale (ITU T.81 Annex K's quantization and Huffman tables), so the scan corpus
/// needs no image library and comes out the same on every machine.
/// </summary>
public static class JpegEncoder
{
    private static readonly byte[] ZigZag =
    [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ];

    private static readonly int[] Luminance =
    [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ];

    private static readonly byte[] DcBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
    private static readonly byte[] DcVals = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
    private static readonly byte[] AcBits = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
    private static readonly byte[] AcVals =
    [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
        0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
        0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
    ];

    /// <summary>C[u*8+x] = c(u)/2 · cos((2x+1)uπ/16): the 8-point DCT as a matrix.</summary>
    private static readonly float[] Cos = BuildCos();

    private static float[] BuildCos()
    {
        var c = new float[64];
        for (var u = 0; u < 8; u++)
            for (var x = 0; x < 8; x++)
                c[u * 8 + x] = (float)((u == 0 ? Math.Sqrt(0.5) : 1) / 2 * Math.Cos((2 * x + 1) * u * Math.PI / 16));
        return c;
    }

    private static (ushort[] Codes, byte[] Lengths) BuildCodes(byte[] bits, byte[] vals)
    {
        var codes = new ushort[256];
        var lengths = new byte[256];
        var code = 0;
        var k = 0;
        for (var len = 1; len <= 16; len++)
        {
            for (var i = 0; i < bits[len - 1]; i++)
            {
                var sym = vals[k++];
                codes[sym] = (ushort)code;
                lengths[sym] = (byte)len;
                code++;
            }
            code <<= 1;
        }
        return (codes, lengths);
    }

    private static readonly (ushort[] Codes, byte[] Lengths) Dc = BuildCodes(DcBits, DcVals);
    private static readonly (ushort[] Codes, byte[] Lengths) Ac = BuildCodes(AcBits, AcVals);

    /// <param name="pixels">Row-major gray values, <paramref name="width"/> × <paramref name="height"/>.</param>
    /// <param name="quality">1–100 as libjpeg scales it.</param>
    /// <param name="dpi">Written to the JFIF header.</param>
    public static byte[] EncodeGray(byte[] pixels, int width, int height, int quality, int dpi)
    {
        var scale = quality < 50 ? 5000 / quality : 200 - 2 * quality;
        var q = new int[64];
        for (var i = 0; i < 64; i++) q[i] = Math.Clamp((Luminance[i] * scale + 50) / 100, 1, 255);

        var ms = new MemoryStream(width * height / 6);
        void Marker(byte m) { ms.WriteByte(0xFF); ms.WriteByte(m); }
        void U16(int v) { ms.WriteByte((byte)(v >> 8)); ms.WriteByte((byte)v); }

        Marker(0xD8);
        Marker(0xE0); U16(16); ms.Write("JFIF\0"u8); ms.WriteByte(1); ms.WriteByte(1); ms.WriteByte(1); U16(dpi); U16(dpi); ms.WriteByte(0); ms.WriteByte(0);
        Marker(0xDB); U16(67); ms.WriteByte(0);
        for (var i = 0; i < 64; i++) ms.WriteByte((byte)q[ZigZag[i]]);
        Marker(0xC0); U16(11); ms.WriteByte(8); U16(height); U16(width); ms.WriteByte(1); ms.WriteByte(1); ms.WriteByte(0x11); ms.WriteByte(0);
        Marker(0xC4); U16(2 + 17 + DcVals.Length + 17 + AcVals.Length);
        ms.WriteByte(0x00); ms.Write(DcBits); ms.Write(DcVals);
        ms.WriteByte(0x10); ms.Write(AcBits); ms.Write(AcVals);
        Marker(0xDA); U16(8); ms.WriteByte(1); ms.WriteByte(1); ms.WriteByte(0x00); ms.WriteByte(0); ms.WriteByte(63); ms.WriteByte(0);

        var bits = new BitWriter(ms);
        var s = new float[64];
        var t = new float[64];
        var coef = new int[64];
        var prevDc = 0;
        for (var by = 0; by < height; by += 8)
        {
            for (var bx = 0; bx < width; bx += 8)
            {
                for (var y = 0; y < 8; y++)
                {
                    var row = Math.Min(by + y, height - 1) * width;
                    for (var x = 0; x < 8; x++) s[y * 8 + x] = pixels[row + Math.Min(bx + x, width - 1)] - 128f;
                }
                // Rows: t[y][u] = Σx s[y][x]·C[u][x]; then columns: F[v][u] = Σy t[y][u]·C[v][y].
                for (var y = 0; y < 8; y++)
                    for (var u = 0; u < 8; u++)
                    {
                        float sum = 0;
                        for (var x = 0; x < 8; x++) sum += s[y * 8 + x] * Cos[u * 8 + x];
                        t[y * 8 + u] = sum;
                    }
                for (var v = 0; v < 8; v++)
                    for (var u = 0; u < 8; u++)
                    {
                        float sum = 0;
                        for (var y = 0; y < 8; y++) sum += t[y * 8 + u] * Cos[v * 8 + y];
                        var n = v * 8 + u;
                        coef[n] = (int)MathF.Round(sum / q[n]);
                    }

                var diff = coef[0] - prevDc;
                prevDc = coef[0];
                var cat = Category(diff);
                bits.Put(Dc.Codes[cat], Dc.Lengths[cat]);
                if (cat > 0) bits.Put(Bits(diff, cat), cat);
                var run = 0;
                for (var k = 1; k < 64; k++)
                {
                    var val = coef[ZigZag[k]];
                    if (val == 0) { run++; continue; }
                    while (run > 15) { bits.Put(Ac.Codes[0xF0], Ac.Lengths[0xF0]); run -= 16; }
                    cat = Category(val);
                    var sym = (run << 4) | cat;
                    bits.Put(Ac.Codes[sym], Ac.Lengths[sym]);
                    bits.Put(Bits(val, cat), cat);
                    run = 0;
                }
                if (run > 0) bits.Put(Ac.Codes[0], Ac.Lengths[0]);
            }
        }
        bits.Flush();
        Marker(0xD9);
        return ms.ToArray();
    }

    private static int Category(int v) => v == 0 ? 0 : 32 - int.LeadingZeroCount(Math.Abs(v));

    private static int Bits(int v, int cat) => (v < 0 ? v + (1 << cat) - 1 : v) & ((1 << cat) - 1);

    private sealed class BitWriter(Stream s)
    {
        private ulong _acc;
        private int _n;

        public void Put(int code, int len)
        {
            _acc = (_acc << len) | (uint)code;
            _n += len;
            while (_n >= 8)
            {
                var b = (byte)(_acc >> (_n - 8));
                s.WriteByte(b);
                if (b == 0xFF) s.WriteByte(0);
                _n -= 8;
            }
            _acc &= (1UL << _n) - 1;
        }

        public void Flush()
        {
            if (_n == 0) return;
            Put((1 << (8 - _n)) - 1, 8 - _n); // pad with ones to the byte
        }
    }
}
