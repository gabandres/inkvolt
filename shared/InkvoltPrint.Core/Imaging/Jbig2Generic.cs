using System.Buffers.Binary;

namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// Lossless JBIG2 (ITU-T T.88) of a black-and-white image: one immediate generic region over the whole page, coded pixel by
/// pixel with the MQ arithmetic coder in template 0's 16-pixel contexts (the four adaptive pixels where T.88 puts them by
/// default) and typical prediction (a row the same as the one above costs one decision). Every pixel is coded as it is:
/// no symbol matching or substitution, so nothing like the scanners whose JBIG2 swapped a 6 for an 8. As PDF's
/// /JBIG2Decode reads it embedded (a page information segment, then the region; no globals, no file header): a set bit is
/// black. A page of text usually comes out smaller than <see cref="CcittG4"/>'s, since each pixel is predicted from its
/// neighbours rather than coded as runs.
/// </summary>
public static class Jbig2Generic
{
    /// <summary>Template 0's adaptive pixels at T.88's nominal places: (3, −1), (−3, −1), (2, −2), (−2, −2).</summary>
    private static readonly sbyte[] Adaptive = [3, -1, -3, -1, 2, -2, -2, -2];

    /// <summary>The context typical prediction's "same row" decision is coded in, for template 0 (T.88 §6.2.5.7).</summary>
    private const int SltpContext = 0x9B25;

    /// <summary>The image as PDF's /JBIG2Decode stream data (embedded organisation, no globals).</summary>
    public static byte[] Encode(BitImage image, CancellationToken cancel = default)
    {
        var region = Region(image, cancel);
        using var ms = new MemoryStream(region.Length + 64);
        // Page information (type 48): size, resolution unknown, flags 0 (white default, lossless region), not striped.
        var page = new byte[19];
        BinaryPrimitives.WriteInt32BigEndian(page, image.Width);
        BinaryPrimitives.WriteInt32BigEndian(page.AsSpan(4), image.Height);
        Segment(ms, 0, 48, page);
        // Immediate generic region (type 38): region information, generic region flags, the adaptive pixels, the coded data.
        var head = new byte[17 + 1 + 8];
        BinaryPrimitives.WriteInt32BigEndian(head, image.Width);
        BinaryPrimitives.WriteInt32BigEndian(head.AsSpan(4), image.Height);
        // x and y 0, combination operator OR (the page is white beneath)
        head[17] = 0b0000_1000; // MMR 0, GBTEMPLATE 0, TPGDON 1
        for (var i = 0; i < 8; i++) head[18 + i] = (byte)Adaptive[i];
        Segment(ms, 1, 38, [.. head, .. region]);
        return ms.ToArray();
    }

    /// <summary>A segment header (T.88 §7.2) with no referred-to segments, on page 1, then its data.</summary>
    private static void Segment(Stream s, int number, int type, byte[] data)
    {
        Span<byte> h = stackalloc byte[11];
        BinaryPrimitives.WriteInt32BigEndian(h, number);
        h[4] = (byte)type;            // page association in one byte, not deferred
        h[5] = 0;                     // no referred-to segments, no retention bits
        h[6] = 1;                     // page 1
        BinaryPrimitives.WriteInt32BigEndian(h[7..], data.Length);
        s.Write(h);
        s.Write(data);
    }

    /// <summary>The generic region's arithmetic-coded pixels (T.88 §6.2.5.7 run backwards, as its encoder).</summary>
    private static byte[] Region(BitImage image, CancellationToken cancel)
    {
        int width = image.Width, height = image.Height;
        const int pad = 4; // each row with 4 white pixels either side, so a context never reads past the row
        var rowLength = width + 2 * pad;
        // Three rows of 0/1 bytes: two above and the row coded.
        var rows = new[] { new byte[rowLength], new byte[rowLength], new byte[rowLength] };
        var coder = new MqEncoder(Math.Max(64, image.Bits.Length / 16));
        var ltp = false;
        for (var y = 0; y < height; y++)
        {
            if ((y & 63) == 0) cancel.ThrowIfCancellationRequested();
            var (up2, up1, line) = (rows[0], rows[1], rows[2]);
            Array.Clear(line);
            var stride = image.Stride;
            var start = y * stride;
            for (var x = 0; x < width; x++) line[pad + x] = (byte)((image.Bits[start + (x >> 3)] >> (7 - (x & 7))) & 1);

            var same = line.AsSpan().SequenceEqual(up1);
            coder.Encode(same != ltp ? 1 : 0, SltpContext);
            ltp = same;
            if (!same)
            {
                // The context as T.88's Figure 3 numbers it: bits 0-3 this row's x−1 to x−4; bits 4-10 the row above's x+3 (A1)
                // to x−3 (A2); bits 11-15 the row two above's x+2 (A3) to x−2 (A4). Each part is a window slid one pixel
                // right per pixel, the newest pixel coming in at its low bit.
                int left = 0, above = 0, above2 = 0;
                for (var i = pad - 3; i < pad; i++) above = (above << 1) | up1[i + 3];
                for (var i = pad - 2; i < pad; i++) above2 = (above2 << 1) | up2[i + 2];
                for (var i = pad; i < pad + width; i++)
                {
                    above = ((above << 1) | up1[i + 3]) & 0x7F;
                    above2 = ((above2 << 1) | up2[i + 2]) & 0x1F;
                    coder.Encode(line[i], left | above << 4 | above2 << 11);
                    left = ((left << 1) | line[i]) & 0xF;
                }
            }
            rows[0] = up1;
            rows[1] = line;
            rows[2] = up2;
        }
        return coder.Finish();
    }

    /// <summary>
    /// The MQ arithmetic encoder (T.88 Annex E, as JPEG 2000's): 65536 contexts, each a probability state and its more
    /// probable symbol; bytes after a 0xFF carry 7 bits, so the data never holds a marker; ended with 0xFF 0xAC.
    /// </summary>
    private sealed class MqEncoder(int capacity)
    {
        private static readonly ushort[] Qe =
        [
            0x5601, 0x3401, 0x1801, 0x0AC1, 0x0521, 0x0221, 0x5601, 0x5401, 0x4801, 0x3801, 0x3001, 0x2401, 0x1C01, 0x1601,
            0x5601, 0x5401, 0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201, 0x1C01, 0x1801, 0x1601, 0x1401,
            0x1201, 0x1101, 0x0AC1, 0x09C1, 0x08A1, 0x0521, 0x0441, 0x02A1, 0x0221, 0x0141, 0x0111, 0x0085, 0x0049, 0x0025,
            0x0015, 0x0009, 0x0005, 0x0001, 0x5601,
        ];

        private static readonly byte[] Nmps =
        [
            1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
            32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46,
        ];

        private static readonly byte[] Nlps =
        [
            1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27,
            28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
        ];

        private static readonly bool[] Switch = [true, false, false, false, false, false, true, false, false, false, false, false, false, false, true];

        /// <summary>Per context: the state's index (low 7 bits) and the more probable symbol (bit 7).</summary>
        private readonly byte[] _states = new byte[65536];

        private readonly List<byte> _out = new(capacity);
        private uint _a = 0x8000, _c;
        private int _ct = 12;
        private int _b = -1; // the byte not yet written (−1: none yet; T.88's byte before the first)

        public void Encode(int bit, int context)
        {
            var state = _states[context];
            var index = state & 0x7F;
            var mps = state >> 7;
            uint qe = Qe[index];
            _a -= qe;
            if (bit == mps)
            {
                if ((_a & 0x8000) != 0)
                {
                    _c += qe;
                    return;
                }
                if (_a < qe) _a = qe;
                else _c += qe;
                _states[context] = (byte)(Nmps[index] | (mps << 7));
            }
            else
            {
                if (_a < qe) _c += qe;
                else _a = qe;
                if (index < Switch.Length && Switch[index]) mps = 1 - mps;
                _states[context] = (byte)(Nlps[index] | (mps << 7));
            }
            do
            {
                _a <<= 1;
                _c <<= 1;
                if (--_ct == 0) ByteOut();
            } while ((_a & 0x8000) == 0);
        }

        private void ByteOut()
        {
            if (_b == 0xFF)
            {
                Next((int)(_c >> 20) & 0xFF);
                _c &= 0xFFFFF;
                _ct = 7;
                return;
            }
            if (_c >= 0x8000000)
            {
                _b++; // the carry (never into the byte before the first: the interval starts below 2^27 there)
                if (_b == 0xFF)
                {
                    _c &= 0x7FFFFFF;
                    Next((int)(_c >> 20) & 0xFF);
                    _c &= 0xFFFFF;
                    _ct = 7;
                    return;
                }
            }
            Next((int)(_c >> 19) & 0xFF); // a carry already added to the byte before is cut off here
            _c &= 0x7FFFF;
            _ct = 8;
        }

        private void Next(int b)
        {
            if (_b >= 0) _out.Add((byte)_b);
            _b = b;
        }

        public byte[] Finish()
        {
            // SETBITS: the most 1s in C within the interval, so the decoder's trailing reads can be anything.
            var temp = _c + _a;
            _c |= 0xFFFF;
            if (_c >= temp) _c -= 0x8000;
            _c <<= _ct;
            ByteOut();
            _c <<= _ct;
            ByteOut();
            if (_b != 0xFF) Next(0xFF);
            Next(0xAC);
            Next(-1);
            return [.. _out];
        }
    }
}
