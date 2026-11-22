using System.IO.Compression;
using System.Text;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Tests;

/// <summary>
/// Small black-and-white PDFs (roadmap 4.4): <see cref="CcittG4"/> read back by a decoder written here from T.6 alone, the
/// code tables checked as codes, <see cref="Bilevel"/>'s black and white, and <see cref="PdfWriter"/>'s 1-bit pages.
/// Inkvolt PDF's tests render the same output through MuPDF (<c>CcittG4RenderTests</c>).
/// </summary>
public class BlackAndWhitePdfTests
{
    [Fact]
    public void The_code_tables_are_the_standards_sizes_and_prefix_free()
    {
        Assert.Equal(64, CcittG4.WhiteTerminating.Length);
        Assert.Equal(64, CcittG4.BlackTerminating.Length);
        Assert.Equal(27, CcittG4.WhiteMakeUp.Length);
        Assert.Equal(27, CcittG4.BlackMakeUp.Length);
        Assert.Equal(13, CcittG4.Extended.Length);
        // Each colour's codes, with the shared make-ups and EOL, can be told apart reading left to right.
        foreach (var codes in new[]
                 {
                     CcittG4.WhiteTerminating.Concat(CcittG4.WhiteMakeUp).Concat(CcittG4.Extended).Append((Code: 1, Length: 12)).ToList(),
                     CcittG4.BlackTerminating.Concat(CcittG4.BlackMakeUp).Concat(CcittG4.Extended).Append((Code: 1, Length: 12)).ToList(),
                 })
        {
            var words = codes.Select(c => Convert.ToString(c.Code, 2).PadLeft(c.Length, '0')).ToList();
            Assert.Equal(words.Count, words.Distinct().Count());
            foreach (var a in words)
                Assert.DoesNotContain(words, b => b != a && b.StartsWith(a, StringComparison.Ordinal));
        }
    }

    [Theory]
    [InlineData(1, 1)]
    [InlineData(7, 3)]
    [InlineData(8, 8)]
    [InlineData(13, 40)]
    [InlineData(200, 60)]
    [InlineData(1728, 20)]
    [InlineData(5000, 6)] // runs past 2560: the extended make-ups, twice
    public void Random_images_come_back_bit_for_bit(int width, int height)
    {
        var rng = new Random(width * 31 + height);
        foreach (var density in new[] { 0.0, 0.02, 0.5, 0.97, 1.0 })
        {
            var image = Random(width, height, density, rng);
            Assert.Equal(image.Bits, G4Decoder.Decode(CcittG4.Encode(image), width, height).Bits);
        }
    }

    [Fact]
    public void Runs_of_every_length_come_back()
    {
        // Rows of one black run of each length from 0 to 2700 at a moving start: every terminating and make-up code.
        const int width = 2800;
        var lengths = Enumerable.Range(0, 2701).ToList();
        var bits = new byte[(width + 7) / 8 * lengths.Count];
        for (var y = 0; y < lengths.Count; y++)
            for (var x = y % 50; x < y % 50 + lengths[y] && x < width; x++)
                bits[y * ((width + 7) / 8) + (x >> 3)] |= (byte)(0x80 >> (x & 7));
        var image = new BitImage(width, lengths.Count, bits);
        Assert.Equal(image.Bits, G4Decoder.Decode(CcittG4.Encode(image), width, lengths.Count).Bits);
    }

    [Fact]
    public void Vertical_edges_and_stripes_use_every_mode()
    {
        // Edges that move by -3..+3 a row (vertical mode), by more (horizontal), and runs that end above (pass mode).
        const int width = 300, height = 120;
        var stride = (width + 7) / 8;
        var bits = new byte[stride * height];
        for (var y = 0; y < height; y++)
        {
            var start = 50 + (y * 7 % 13) - 6;
            for (var x = start; x < start + 30 + y % 5; x++) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
            if (y % 2 == 0)
                for (var x = 150; x < 160; x++) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
            for (var x = 200 + y % 40; x < 205 + y % 40; x++) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
        }
        var image = new BitImage(width, height, bits);
        Assert.Equal(image.Bits, G4Decoder.Decode(CcittG4.Encode(image), width, height).Bits);
    }

    [Fact]
    public void A_page_of_lines_is_far_smaller_than_its_bytes()
    {
        var image = TextLike(2550, 3300);
        var g4 = CcittG4.Encode(image);
        Assert.True(g4.Length * 10 < image.Bits.Length, $"{g4.Length} bytes of G4 for {image.Bits.Length} bytes of pixels");
        Assert.Equal(image.Bits, G4Decoder.Decode(g4, image.Width, image.Height).Bits);
    }

    [Fact]
    public void Hostile_sizes_are_refused_before_anything_is_allocated()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new BitImage(0, 10, []));
        Assert.Throws<ArgumentOutOfRangeException>(() => new BitImage(100_000, 100_000, []));
        Assert.Throws<ArgumentException>(() => new BitImage(16, 2, new byte[3]));
        Assert.Throws<ArgumentOutOfRangeException>(() => BitImage.FromGray(new byte[10], 4, 4, 128));
        Assert.Throws<ArgumentOutOfRangeException>(() => Bilevel.FromScan(new byte[10], 4, 4, 300));
    }

    [Fact]
    public void A_grey_page_on_shaded_paper_is_black_text_on_white()
    {
        // Paper from 240 on the left to 170 on the right (a lid's shadow), text bars of 40 on it: the shadow is paper, not ink.
        const int w = 600, h = 400;
        var gray = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                gray[y * w + x] = (byte)(240 - 70 * x / w);
        for (var line = 0; line < 8; line++)
            for (var y = 40 + line * 40; y < 52 + line * 40; y++)
                for (var x = 50; x < 550; x++)
                    if (x % 9 != 0) gray[y * w + x] = 40;
        var bits = Bilevel.FromScan(gray, w, h, 150);
        Assert.False(bits[580, 20]);  // the darkest paper
        Assert.False(bits[20, 20]);
        Assert.True(bits[300, 46]);   // a bar
        Assert.True(bits[540, 326]);  // a bar on the shadow
        var black = 0;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                if (bits[x, y]) black++;
        Assert.InRange(black, 8 * 12 * 420, 8 * 12 * 500);
    }

    [Theory]
    [InlineData(new byte[] { 255, 255, 255, 30 }, 96)]  // almost all paper: never below the floor
    [InlineData(new byte[] { 20, 20, 230, 230 }, 96)]
    [InlineData(new byte[] { 100, 100, 220, 220 }, 101)]
    public void The_level_parts_ink_from_paper_within_bounds(byte[] levels, int expected)
    {
        var gray = levels.SelectMany(l => Enumerable.Repeat(l, 100)).ToArray();
        Assert.Equal(expected, Bilevel.Threshold(gray));
    }

    [Fact]
    public void A_black_and_white_page_is_written_at_one_bit_as_G4()
    {
        // Scattered runs (as a scan's specks and strokes are): G4 is the smaller.
        var image = Random(850, 1100, 0.05, new Random(3));
        using var ms = new MemoryStream();
        PdfWriter.Write(ms, [PdfPage.BlackAndWhite(image, 100, [new OcrWord("Hello", 100, 100, 200, 20)])], "Small");
        var text = Encoding.Latin1.GetString(ms.ToArray());
        Assert.Contains("/BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns 850 /Rows 1100 >>", text);
        Assert.Contains("/MediaBox [0 0 612 792]", text);
        Assert.Contains("/ColorSpace /DeviceGray", text);
        Assert.Contains("3 Tr", text); // the text layer, as on a JPEG page
        Assert.DoesNotContain("DCTDecode", text);
        // The stream holds exactly the encoder's bytes.
        var g4 = CcittG4.Encode(image);
        var at = text.IndexOf("stream\n", text.IndexOf("CCITTFaxDecode", StringComparison.Ordinal), StringComparison.Ordinal) + 7;
        Assert.Equal(g4, ms.ToArray().AsSpan(at, g4.Length).ToArray());
    }

    [Fact]
    public void Fine_even_patterns_go_as_Flate_when_that_is_smaller()
    {
        // A checkerboard of single pixels: every run 1 long, G4's worst case; Flate packs the repeat in a few bytes.
        const int w = 512, h = 256;
        var bits = new byte[w / 8 * h];
        for (var y = 0; y < h; y++)
            for (var i = 0; i < w / 8; i++)
                bits[y * (w / 8) + i] = y % 2 == 0 ? (byte)0xAA : (byte)0x55;
        var image = new BitImage(w, h, bits);
        var (filter, data) = PdfWriter.OneBit(image);
        Assert.Equal("/Filter /FlateDecode", filter);
        Assert.True(data.Length < CcittG4.Encode(image).Length);
        // Flate holds the rows with black as 0 (DeviceGray), the bits past each row's end 0.
        using var z = new ZLibStream(new MemoryStream(data), CompressionMode.Decompress);
        using var rows = new MemoryStream();
        z.CopyTo(rows);
        Assert.Equal(bits.Select(b => (byte)~b).ToArray(), rows.ToArray());

        var odd = new BitImage(5, 1, [0b1010_0000]);
        Assert.Equal([0b0101_1000], odd.Inverted());
    }

    [Fact]
    public void Jpeg_pages_are_written_as_before()
    {
        var jpeg = TestJpeg.Build(width: 2550, height: 3300, dnlHeight: null);
        using var ms = new MemoryStream();
        PdfWriter.Write(ms, [new PdfPage(jpeg, 300), PdfPage.BlackAndWhite(BitImage.White(30, 30), 300)], "Mixed");
        var text = Encoding.Latin1.GetString(ms.ToArray());
        Assert.Contains("/BitsPerComponent 8 /Filter /DCTDecode", text);
        Assert.Contains("/BitsPerComponent 1 /Filter /CCITTFaxDecode", text);
    }

    private static BitImage Random(int width, int height, double density, Random rng)
    {
        var stride = (width + 7) / 8;
        var bits = new byte[stride * height];
        for (var y = 0; y < height; y++)
        {
            // Runs, not single pixels: a run's colour flips with the density's chance, so long and short runs both come up.
            var black = rng.NextDouble() < density;
            for (var x = 0; x < width; x++)
            {
                if (rng.NextDouble() < 0.08) black = rng.NextDouble() < density;
                if (black) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
            }
        }
        return new BitImage(width, height, bits);
    }

    /// <summary>A page of "text": lines of short black strokes on white, letters' worth of edges.</summary>
    internal static BitImage TextLike(int width, int height)
    {
        var stride = (width + 7) / 8;
        var bits = new byte[stride * height];
        var rng = new Random(7);
        for (var top = height / 12; top + 30 < height * 11 / 12; top += 50)
        {
            var x = width / 10;
            while (x < width * 9 / 10)
            {
                var letter = 10 + rng.Next(14);
                var tall = rng.Next(3) == 0;
                for (var y = tall ? top : top + 10; y < top + 30; y++)
                    for (var dx = 0; dx < letter; dx++)
                        if (dx < 4 || dx >= letter - 4 || y - top is 10 or 11 or 28 or 29)
                            bits[y * stride + ((x + dx) >> 3)] |= (byte)(0x80 >> ((x + dx) & 7));
                x += letter + 4 + (rng.Next(6) == 0 ? 16 : 0);
            }
        }
        return new BitImage(width, height, bits);
    }

    /// <summary>A T.6 (Group 4) decoder written from the standard, independent of the encoder's code: only for these tests.</summary>
    private static class G4Decoder
    {
        private static readonly Dictionary<(int Code, int Length), int> White = Table(CcittG4.WhiteTerminating, CcittG4.WhiteMakeUp);
        private static readonly Dictionary<(int Code, int Length), int> Black = Table(CcittG4.BlackTerminating, CcittG4.BlackMakeUp);

        private static Dictionary<(int, int), int> Table((int Code, int Length)[] terminating, (int Code, int Length)[] makeUp)
        {
            var table = new Dictionary<(int, int), int>();
            for (var i = 0; i < 64; i++) table[terminating[i]] = i;
            for (var i = 0; i < 27; i++) table[makeUp[i]] = (i + 1) * 64;
            for (var i = 0; i < 13; i++) table[CcittG4.Extended[i]] = (i + 28) * 64;
            return table;
        }

        public static BitImage Decode(byte[] data, int width, int height)
        {
            var pos = 0;
            int Bit() => pos < data.Length * 8 ? (data[pos >> 3] >> (7 - (pos++ & 7))) & 1 : throw new InvalidDataException("ran out of data");
            var stride = (width + 7) / 8;
            var bits = new byte[stride * height];
            var above = new bool[width];
            for (var y = 0; y < height; y++)
            {
                var line = new bool[width];
                var a0 = -1;
                var black = false;
                while (a0 < width)
                {
                    var start = Math.Max(a0, 0);
                    // b1: the first changing element on the row above, right of a0, of the colour opposite a0's (the element
                    // before it is a0's colour; before the row, white); b2: the next changing element after it.
                    var b1 = a0 + 1;
                    while (b1 < width && !(above[b1] != black && (b1 == 0 ? false : above[b1 - 1]) == black)) b1++;
                    var b2 = b1 + 1;
                    if (b1 >= width) b2 = width;
                    else while (b2 < width && above[b2] == above[b1]) b2++;
                    var mode = Mode(Bit);
                    switch (mode)
                    {
                        case "P":
                            Fill(line, start, b2, black);
                            a0 = b2;
                            break;
                        case "H":
                            var r1 = Run(Bit, black);
                            var r2 = Run(Bit, !black);
                            Fill(line, start, start + r1, black);
                            Fill(line, start + r1, start + r1 + r2, !black);
                            a0 = start + r1 + r2;
                            break;
                        default:
                            var a1 = b1 + int.Parse(mode);
                            Fill(line, start, a1, black);
                            a0 = a1;
                            black = !black;
                            break;
                    }
                }
                for (var x = 0; x < width; x++)
                    if (line[x]) bits[y * stride + (x >> 3)] |= (byte)(0x80 >> (x & 7));
                above = line;
            }
            // The end: two EOLs.
            for (var i = 0; i < 2; i++)
            {
                var eol = 0;
                for (var k = 0; k < 12; k++) eol = (eol << 1) | Bit();
                Assert.Equal(1, eol);
            }
            return new BitImage(width, height, bits);
        }

        private static void Fill(bool[] line, int from, int to, bool black)
        {
            for (var x = from; x < to && x < line.Length; x++) line[x] = black;
        }

        private static string Mode(Func<int> bit)
        {
            var code = "";
            while (code.Length < 12)
            {
                code += bit();
                switch (code)
                {
                    case "1": return "0";
                    case "011": return "1";
                    case "000011": return "2";
                    case "0000011": return "3";
                    case "010": return "-1";
                    case "000010": return "-2";
                    case "0000010": return "-3";
                    case "001": return "H";
                    case "0001": return "P";
                }
            }
            throw new InvalidDataException("no mode code");
        }

        private static int Run(Func<int> bit, bool black)
        {
            var table = black ? Black : White;
            var total = 0;
            while (true)
            {
                int code = 0, length = 0, run;
                do
                {
                    code = (code << 1) | bit();
                    if (++length > 13) throw new InvalidDataException("no run code");
                } while (!table.TryGetValue((code, length), out run));
                total += run;
                if (run < 64) return total;
            }
        }
    }
}
