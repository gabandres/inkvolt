namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// CCITT Group 4 (ITU-T T.6) encoding of a black-and-white image: each row coded against the one above it (the first
/// against an imaginary white row) in pass, vertical and horizontal modes, the runs of horizontal mode in T.4's modified
/// Huffman codes, ended by an end-of-facsimile-block (two EOLs), not byte-aligned. As PDF's /CCITTFaxDecode reads it with
/// <c>/K -1 /Columns</c> width <c>/Rows</c> height and the rest left at their defaults (black is 0 in the decoded image),
/// and as a TIFF's Compression 4. A page of text is usually a tenth or less of its JPEG.
/// </summary>
public static class CcittG4
{
    public static byte[] Encode(BitImage image, CancellationToken cancel = default)
    {
        var width = image.Width;
        var bits = new BitWriter(Math.Max(64, image.Bits.Length / 8));
        var reference = new bool[width];   // the imaginary first reference row: all white
        var coding = new bool[width];
        for (var y = 0; y < image.Height; y++)
        {
            if ((y & 63) == 0) cancel.ThrowIfCancellationRequested();
            var row = y * image.Stride;
            for (var x = 0; x < width; x++) coding[x] = (image.Bits[row + (x >> 3)] & (0x80 >> (x & 7))) != 0;
            EncodeRow(bits, coding, reference, width);
            (reference, coding) = (coding, reference);
        }
        bits.Put(1, 12); // EOFB: two EOLs
        bits.Put(1, 12);
        return bits.ToArray();
    }

    /// <summary>One row against the row above (T.6 §2.2; the steps libtiff's Fax3Encode2DRow takes).</summary>
    private static void EncodeRow(BitWriter bits, bool[] line, bool[] above, int width)
    {
        // a0 starts on an imaginary white element just before the row; colour is a0's.
        var a0 = -1;
        var black = false;
        var a1 = line[0] ? 0 : Next(line, 0, false, width);
        var b1 = above[0] ? 0 : Next(above, 0, false, width);
        while (true)
        {
            var b2 = b1 < width ? Next(above, b1, above[b1], width) : width;
            if (b2 < a1)
            {
                bits.Put(0b0001, 4); // pass
                a0 = b2;
            }
            else if (a1 - b1 is var d && d >= -3 && d <= 3)
            {
                Vertical(bits, d);
                a0 = a1;
                black = !black;
            }
            else
            {
                var a2 = a1 < width ? Next(line, a1, line[a1], width) : width;
                bits.Put(0b001, 3); // horizontal
                Run(bits, a1 - Math.Max(a0, 0), black);
                Run(bits, a2 - a1, !black);
                a0 = a2;
            }
            if (a0 >= width) return;
            // The next changing elements after a0: on this row, of the other colour; on the row above, the first one past a0 whose
            // colour is the other colour (skip what is already that colour at a0, then the run of a0's colour).
            a1 = Next(line, a0, black, width);
            b1 = Next(above, Next(above, a0, !black, width), black, width);
        }
    }

    /// <summary>The first position at or after <paramref name="from"/> whose colour isn't <paramref name="black"/>; <paramref name="width"/> when none.</summary>
    private static int Next(bool[] row, int from, bool black, int width)
    {
        var x = from;
        while (x < width && row[x] == black) x++;
        return x;
    }

    /// <summary>a1 is <paramref name="d"/> elements right of b1 (left when negative).</summary>
    private static void Vertical(BitWriter bits, int d)
    {
        switch (d)
        {
            case 0: bits.Put(0b1, 1); break;
            case 1: bits.Put(0b011, 3); break;
            case 2: bits.Put(0b000011, 6); break;
            case 3: bits.Put(0b0000011, 7); break;
            case -1: bits.Put(0b010, 3); break;
            case -2: bits.Put(0b000010, 6); break;
            default: bits.Put(0b0000010, 7); break;
        }
    }

    /// <summary>A run in T.4's codes: 2560 make-ups while it's longer, then a make-up for its 64s, then its terminating code.</summary>
    private static void Run(BitWriter bits, int length, bool black)
    {
        var (terminating, makeUp) = black ? (BlackTerminating, BlackMakeUp) : (WhiteTerminating, WhiteMakeUp);
        while (length >= 2624)
        {
            Put(bits, Extended[^1]);
            length -= 2560;
        }
        if (length >= 64)
        {
            var n = length / 64; // 1..40
            Put(bits, n <= 27 ? makeUp[n - 1] : Extended[n - 28]);
            length -= n * 64;
        }
        Put(bits, terminating[length]);
    }

    private static void Put(BitWriter bits, (int Code, int Length) code) => bits.Put(code.Code, code.Length);

    private static (int Code, int Length)[] Codes(string codes) =>
        [.. codes.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(c => (Convert.ToInt32(c, 2), c.Length))];

    // T.4 Table 2: terminating codes for runs of 0 to 63, then make-up codes for 64 to 1728 (Table 3), then the make-up
    // codes both colours share for 1792 to 2560.
    internal static readonly (int Code, int Length)[] WhiteTerminating = Codes(
        "00110101 000111 0111 1000 1011 1100 1110 1111 10011 10100 00111 01000 001000 000011 110100 110101 " +
        "101010 101011 0100111 0001100 0001000 0010111 0000011 0000100 0101000 0101011 0010011 0100100 0011000 00000010 00000011 00011010 " +
        "00011011 00010010 00010011 00010100 00010101 00010110 00010111 00101000 00101001 00101010 00101011 00101100 00101101 00000100 00000101 00001010 " +
        "00001011 01010010 01010011 01010100 01010101 00100100 00100101 01011000 01011001 01011010 01011011 01001010 01001011 00110010 00110011 00110100");

    internal static readonly (int Code, int Length)[] WhiteMakeUp = Codes(
        "11011 10010 010111 0110111 00110110 00110111 01100100 01100101 01101000 01100111 011001100 011001101 011010010 011010011 " +
        "011010100 011010101 011010110 011010111 011011000 011011001 011011010 011011011 010011000 010011001 010011010 011000 010011011");

    internal static readonly (int Code, int Length)[] BlackTerminating = Codes(
        "0000110111 010 11 10 011 0011 0010 00011 000101 000100 0000100 0000101 0000111 00000100 00000111 000011000 " +
        "0000010111 0000011000 0000001000 00001100111 00001101000 00001101100 00000110111 00000101000 00000010111 00000011000 000011001010 000011001011 000011001100 000011001101 000001101000 000001101001 " +
        "000001101010 000001101011 000011010010 000011010011 000011010100 000011010101 000011010110 000011010111 000001101100 000001101101 000011011010 000011011011 000001010100 000001010101 000001010110 000001010111 " +
        "000001100100 000001100101 000001010010 000001010011 000000100100 000000110111 000000111000 000000100111 000000101000 000001011000 000001011001 000000101011 000000101100 000001011010 000001100110 000001100111");

    internal static readonly (int Code, int Length)[] BlackMakeUp = Codes(
        "0000001111 000011001000 000011001001 000001011011 000000110011 000000110100 000000110101 0000001101100 0000001101101 " +
        "0000001001010 0000001001011 0000001001100 0000001001101 0000001110010 0000001110011 0000001110100 0000001110101 0000001110110 " +
        "0000001110111 0000001010010 0000001010011 0000001010100 0000001010101 0000001011010 0000001011011 0000001100100 0000001100101");

    internal static readonly (int Code, int Length)[] Extended = Codes(
        "00000001000 00000001100 00000001101 000000010010 000000010011 000000010100 000000010101 000000010110 000000010111 " +
        "000000011100 000000011101 000000011110 000000011111");

    /// <summary>Bits written most significant first, packed into bytes; the last byte padded with 0s.</summary>
    private sealed class BitWriter(int capacity)
    {
        private readonly List<byte> _bytes = new(capacity);
        private int _acc, _count;

        public void Put(int code, int length)
        {
            for (var i = length - 1; i >= 0; i--)
            {
                _acc = (_acc << 1) | ((code >> i) & 1);
                if (++_count == 8)
                {
                    _bytes.Add((byte)_acc);
                    (_acc, _count) = (0, 0);
                }
            }
        }

        public byte[] ToArray()
        {
            if (_count > 0) _bytes.Add((byte)(_acc << (8 - _count)));
            (_acc, _count) = (0, 0);
            return [.. _bytes];
        }
    }
}
