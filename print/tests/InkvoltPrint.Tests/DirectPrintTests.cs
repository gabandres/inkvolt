using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Printing.Direct;
using InkvoltPrint.Core.Printing.Raster;

namespace InkvoltPrint.Tests;

/// <summary>
/// Roadmap 2.1, driverless printing: the three raster encoders byte for byte against their specs (PWG 5102.4's header table
/// and compression, Apple raster's header as CUPS reads it, PCLm's PDF structure), read back by decoders written here from
/// the specs; the IPP requests and the collection decoding; what a printer's attributes allow and the plan made from them,
/// hostile values included; and a job through a fake printer. The same encoders were checked against CUPS's ippeveprinter
/// (it kept byte-identical files) and libcups' reader (print/README.md, roadmap 2.1).
/// </summary>
public class RasterEncoderTests
{
    private static RasterJob Letter(RasterFormat format, RasterColor color = RasterColor.Gray8, int pages = 1, int dpi = 300) =>
        new(format, dpi, color, "na_letter_8.5x11in", 21590, 27940, pages);

    // ---- the compression PWG raster and Apple raster share (PWG 5102.4 §4.3.1.2) ----

    [Fact]
    public void A_line_packs_into_repeat_and_literal_runs()
    {
        byte[] line = [5, 5, 5, 1, 2, 3, 9, 9, 7];
        var into = new byte[64];
        var n = RasterLines.Pack(line, 1, into);
        // 0x02: next pixel 3 times; 0xFE (257-3): 3 pixels as they are; 0x01: next pixel twice; 0x00: one pixel (the last).
        Assert.Equal(new byte[] { 0x02, 5, 0xFE, 1, 2, 3, 0x01, 9, 0x00, 7 }, into[..n]);
    }

    [Fact]
    public void Runs_stop_at_128_pixels_and_128_is_never_written()
    {
        var into = new byte[1024];
        var same = Enumerable.Repeat((byte)7, 300).ToArray();
        Assert.Equal(new byte[] { 127, 7, 127, 7, 43, 7 }, into[..RasterLines.Pack(same, 1, into)]); // 128 + 128 + 44
        var different = Enumerable.Range(0, 200).Select(i => (byte)i).ToArray();
        var packed = into[..RasterLines.Pack(different, 1, into)];
        Assert.Equal(129, packed[0]); // 257 - 128
        Assert.Equal(257 - 72, packed[129]);
        Assert.Equal(1 + 128 + 1 + 72, packed.Length);
    }

    [Fact]
    public void Rgb_pixels_run_as_three_bytes()
    {
        byte[] line = [1, 2, 3, 1, 2, 3, 4, 5, 6];
        var into = new byte[32];
        Assert.Equal(new byte[] { 0x01, 1, 2, 3, 0x00, 4, 5, 6 }, into[..RasterLines.Pack(line, 3, into)]);
    }

    [Fact]
    public void Identical_lines_share_a_repeat_count_up_to_256()
    {
        var page = RasterPage.Blank(4, 300, RasterColor.Gray8);
        using var ms = new MemoryStream();
        RasterLines.Write(ms, page, (1, 1));
        // 256 white lines, then 44: each line is one run of 4 white pixels.
        Assert.Equal(new byte[] { 0xFF, 0x03, 0xFF, 43, 0x03, 0xFF }, ms.ToArray());
    }

    // ---- PWG raster (PWG 5102.4-2012) ----

    [Fact]
    public void Pwg_raster_starts_with_its_sync_word_and_a_1796_byte_header_per_page()
    {
        var job = Letter(RasterFormat.PwgRaster, RasterColor.Rgb8, pages: 2) with { Duplex = true, Back = BackSide.Rotated, Quality = 5, MediaType = "stationery" };
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, job);
        w.Write(RasterPage.Blank(2550, 3300, RasterColor.Rgb8));
        w.Write(RasterPage.Blank(2550, 3300, RasterColor.Rgb8));
        w.Finish();
        var b = ms.ToArray();
        Assert.Equal("RaS2"u8.ToArray(), b[..4]);
        var h = b[4..1800];
        uint U(int at) => BinaryPrimitives.ReadUInt32BigEndian(h.AsSpan(at));
        int I(int at) => BinaryPrimitives.ReadInt32BigEndian(h.AsSpan(at));
        string S(int at) => Encoding.ASCII.GetString(h, at, 64).TrimEnd('\0');
        Assert.Equal("PwgRaster", S(0));          // MediaClass
        Assert.Equal("stationery", S(128));       // MediaType
        Assert.Equal(1u, U(272));                 // Duplex
        Assert.Equal((300u, 300u), (U(276), U(280))); // HWResolution
        Assert.Equal((612u, 792u), (U(352), U(356))); // PageSize in points
        Assert.Equal(0u, U(368));                 // Tumble
        Assert.Equal((2550u, 3300u), (U(372), U(376))); // Width, Height
        Assert.Equal((8u, 24u, 7650u), (U(384), U(388), U(392))); // BitsPerColor, BitsPerPixel, BytesPerLine
        Assert.Equal(0u, U(396));                 // ColorOrder chunky
        Assert.Equal(19u, U(400));                // ColorSpace sRGB
        Assert.Equal(3u, U(420));                 // NumColors
        Assert.Equal(2u, U(452));                 // TotalPageCount
        Assert.Equal((1, 1), (I(456), I(460)));   // the front is not turned
        Assert.Equal((0u, 0u, 2550u, 3300u), (U(464), U(468), U(472), U(476))); // ImageBox
        Assert.Equal(0x00FFFFFFu, U(480));        // AlternatePrimary
        Assert.Equal(5u, U(484));                 // PrintQuality
        Assert.Equal("na_letter_8.5x11in", S(1732)); // PageSizeName
        // Everything else is reserved: zero.
        var set = new HashSet<int>();
        foreach (var (at, len) in new[] { (0, 64), (128, 64), (272, 12), (352, 8), (368, 32), (400, 4), (420, 4), (452, 36), (1732, 64) })
            for (var i = 0; i < len; i++) set.Add(at + i);
        for (var i = 0; i < 1796; i++)
            if (!set.Contains(i)) Assert.True(h[i] == 0, $"reserved byte {i} is {h[i]}");
        // The back is rotated (rotated + long edge: both directions mirrored, as cupsRasterInitPWGHeader sets it).
        var back = PwgRasterWriter.Header(job, job.Transform(1));
        Assert.Equal(-1, BinaryPrimitives.ReadInt32BigEndian(back.AsSpan(456)));
        Assert.Equal(-1, BinaryPrimitives.ReadInt32BigEndian(back.AsSpan(460)));
    }

    [Fact]
    public void Pwg_raster_reads_back_pixel_for_pixel_with_the_back_side_turned()
    {
        var front = Noise(37, 23, RasterColor.Rgb8, seed: 1);
        var back = Noise(37, 23, RasterColor.Rgb8, seed: 2);
        var job = new RasterJob(RasterFormat.PwgRaster, 100, RasterColor.Rgb8, "custom", 940, 584, 2) { Duplex = true, Tumble = true, Back = BackSide.Flipped };
        Assert.Equal((37, 23), (job.WidthPixels, job.HeightPixels));
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, job);
        w.Write(front);
        w.Write(back);
        w.Finish();
        var pages = SpecDecoder.Pwg(ms.ToArray());
        Assert.Equal(2, pages.Count);
        Assert.Equal(front.Pixels, pages[0].Pixels);
        Assert.Equal((-1, 1), pages[1].Transform); // flipped + short edge: across mirrored
        Assert.Equal(Mirror(back, across: true, down: false).Pixels, pages[1].Pixels);
    }

    [Theory]
    [InlineData(BackSide.Normal, false, 1, 1)]
    [InlineData(BackSide.Normal, true, 1, 1)]
    [InlineData(BackSide.Flipped, false, 1, -1)]
    [InlineData(BackSide.Flipped, true, -1, 1)]
    [InlineData(BackSide.Rotated, false, -1, -1)]
    [InlineData(BackSide.Rotated, true, 1, 1)]
    [InlineData(BackSide.ManualTumble, false, 1, 1)]
    [InlineData(BackSide.ManualTumble, true, -1, -1)]
    public void Backs_are_turned_as_the_printer_asks(BackSide back, bool tumble, int crossFeed, int feed)
    {
        var job = Letter(RasterFormat.PwgRaster, pages: 2) with { Duplex = true, Tumble = tumble, Back = back };
        Assert.Equal((1, 1), job.Transform(0));
        Assert.Equal((crossFeed, feed), job.Transform(1));
        Assert.Equal((1, 1), (job with { Duplex = false }).Transform(1));
    }

    // ---- Apple raster ----

    [Fact]
    public void Urf_has_its_file_header_page_count_and_32_byte_page_headers()
    {
        var job = Letter(RasterFormat.Urf, RasterColor.Gray8, pages: 3) with { Duplex = true, Quality = 3 };
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, job);
        for (var i = 0; i < 3; i++) w.Write(RasterPage.Blank(2550, 3300, RasterColor.Gray8));
        w.Finish();
        var b = ms.ToArray();
        Assert.Equal("UNIRAST\0"u8.ToArray(), b[..8]);
        Assert.Equal(3u, BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(8)));
        var h = b.AsSpan(12, 32).ToArray();
        Assert.Equal(new byte[] { 8, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0 }, h[..12]); // 8 bits, sGray, long edge, draft
        Assert.Equal(2550u, BinaryPrimitives.ReadUInt32BigEndian(h.AsSpan(12)));
        Assert.Equal(3300u, BinaryPrimitives.ReadUInt32BigEndian(h.AsSpan(16)));
        Assert.Equal(300u, BinaryPrimitives.ReadUInt32BigEndian(h.AsSpan(20)));
        Assert.All(h[24..], x => Assert.Equal(0, x));
        Assert.Equal(new byte[] { 24, 1, 1, 4 }, UrfWriter.Header(Letter(RasterFormat.Urf, RasterColor.Rgb8))[..4]); // sRGB, one-sided, normal
        Assert.Equal(2, UrfWriter.Header(job with { Tumble = true })[2]);
    }

    [Fact]
    public void Urf_reads_back_pixel_for_pixel()
    {
        var page = Noise(61, 20, RasterColor.Gray8, seed: 3);
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, new RasterJob(RasterFormat.Urf, 100, RasterColor.Gray8, "custom", 1549, 508, 1));
        w.Write(page);
        w.Finish();
        Assert.Equal(page.Pixels, SpecDecoder.Urf(ms.ToArray()).Single());
    }

    // ---- PCLm ----

    [Fact]
    public void Pclm_is_a_pdf_of_strips_with_a_valid_cross_reference_table()
    {
        var page = Noise(40, 37, RasterColor.Rgb8, seed: 4);
        var job = new RasterJob(RasterFormat.Pclm, 100, RasterColor.Rgb8, "custom", 1016, 940, 2) { StripHeight = 16 };
        Assert.Equal((40, 37), (job.WidthPixels, job.HeightPixels));
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, job);
        w.Write(page);
        w.Write(page);
        w.Finish();
        var pdf = ms.ToArray();
        var text = Encoding.Latin1.GetString(pdf);
        Assert.StartsWith("%PDF-1.7\n%PCLm 1.0\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n", text);
        Assert.EndsWith("%%EOF\n", text);
        var decoded = SpecDecoder.Pclm(pdf);
        Assert.Equal(2, decoded.Count);
        foreach (var (pixels, strips, content, box) in decoded)
        {
            Assert.Equal(page.Pixels, pixels);
            Assert.Equal([16, 16, 5], strips); // the last strip is shorter
            Assert.Equal("0.72 0 0 0.72 0 0 cm\nq 40 0 0 16 0 21 cm /Image0 Do Q\nq 40 0 0 16 0 5 cm /Image1 Do Q\nq 40 0 0 5 0 0 cm /Image2 Do Q\n", content);
            Assert.Equal("[0 0 28.8 26.6457]", box);
        }
        Assert.Contains("/Type/Pages/Kids[3 0 R 8 0 R]/Count 2", text);
    }

    [Fact]
    public void Pclm_strips_can_be_run_length_and_grey()
    {
        var page = Noise(33, 20, RasterColor.Gray8, seed: 5);
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, new RasterJob(RasterFormat.Pclm, 100, RasterColor.Gray8, "custom", 838, 508, 1) { StripHeight = 8, RunLength = true });
        w.Write(page);
        w.Finish();
        var text = Encoding.Latin1.GetString(ms.ToArray());
        Assert.Contains("/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/RunLengthDecode", text);
        Assert.Equal(page.Pixels, SpecDecoder.Pclm(ms.ToArray()).Single().Pixels);
    }

    [Fact]
    public void Run_length_follows_pdf_RunLengthDecode()
    {
        using var ms = new MemoryStream();
        RunLengthStream.Encode([1, 2, 3, 3, 3, 3, 4], ms);
        // 0x01: two bytes as they are; 0xFD (257-4): one byte four times; 0x00: one byte.
        Assert.Equal(new byte[] { 0x01, 1, 2, 0xFD, 3, 0x00, 4 }, ms.ToArray());
    }

    // ---- the writer's own checks ----

    [Fact]
    public void A_writer_refuses_pages_that_dont_match_and_jobs_out_of_range()
    {
        using var ms = new MemoryStream();
        var w = RasterWriter.For(ms, Letter(RasterFormat.PwgRaster));
        Assert.Throws<ArgumentException>(() => w.Write(RasterPage.Blank(100, 100, RasterColor.Gray8)));
        Assert.Throws<ArgumentException>(() => w.Write(RasterPage.Blank(2550, 3300, RasterColor.Rgb8)));
        Assert.Throws<InvalidOperationException>(() => w.Finish());
        Assert.Throws<ArgumentException>(() => RasterWriter.For(ms, Letter(RasterFormat.Urf) with { Dpi = 0 }));
        Assert.Throws<ArgumentException>(() => RasterWriter.For(ms, Letter(RasterFormat.Urf) with { WidthHmm = 5_000_000 }));
        Assert.Throws<ArgumentException>(() => RasterWriter.For(ms, Letter(RasterFormat.Pclm) with { StripHeight = 0 }));
        Assert.Throws<ArgumentOutOfRangeException>(() => new RasterPage(30_000, 30_000, RasterColor.Gray8, []));
    }

    [Fact]
    public void Pages_are_made_from_bgra_enlarged_and_fitted()
    {
        byte[] bgra = [0, 0, 255, 255, 255, 255, 255, 255]; // red, white
        var rgb = RasterPage.FromBgra(2, 1, 8, bgra, RasterColor.Rgb8);
        Assert.Equal(new byte[] { 255, 0, 0, 255, 255, 255 }, rgb.Pixels);
        var grey = RasterPage.FromBgra(2, 1, 8, bgra, RasterColor.Gray8);
        Assert.Equal(new byte[] { 77, 255 }, grey.Pixels); // BT.601: 0.299 of red
        var big = grey.Enlarged(2);
        Assert.Equal(new byte[] { 77, 77, 255, 255, 77, 77, 255, 255 }, big.Pixels);
        // Cut on the right, padded with white at the bottom.
        Assert.Equal(new byte[] { 77, 77, 255, 77, 77, 255, 255, 255, 255 }, big.Fitted(3, 3).Pixels);
    }

    internal static RasterPage Noise(int w, int h, RasterColor color, int seed)
    {
        var rnd = new Random(seed);
        var pixels = new byte[w * h * RasterPage.Channels(color)];
        for (var i = 0; i < pixels.Length; i++) pixels[i] = rnd.Next(4) == 0 ? (byte)255 : (byte)rnd.Next(4); // runs and literals
        // A few identical lines in a row, for the line repeat.
        var line = w * RasterPage.Channels(color);
        if (h > 4) for (var y = 1; y < 4; y++) Array.Copy(pixels, 0, pixels, y * line, line);
        return new RasterPage(w, h, color, pixels);
    }

    private static RasterPage Mirror(RasterPage p, bool across, bool down)
    {
        var bpp = p.BytesPerPixel;
        var o = new byte[p.Pixels.Length];
        for (var y = 0; y < p.Height; y++)
            for (var x = 0; x < p.Width; x++)
            {
                var (sx, sy) = (across ? p.Width - 1 - x : x, down ? p.Height - 1 - y : y);
                Array.Copy(p.Pixels, (sy * p.Width + sx) * bpp, o, (y * p.Width + x) * bpp, bpp);
            }
        return new RasterPage(p.Width, p.Height, p.Color, o);
    }
}

/// <summary>Decoders written from the specs, not from the encoders: PWG 5102.4 §4.3, Apple raster as CUPS reads it, PCLm's PDF.</summary>
internal static class SpecDecoder
{
    public static List<(byte[] Pixels, (int CrossFeed, int Feed) Transform)> Pwg(byte[] b)
    {
        Assert.Equal("RaS2", Encoding.ASCII.GetString(b, 0, 4));
        var pages = new List<(byte[], (int, int))>();
        var i = 4;
        while (i < b.Length)
        {
            var h = b.AsSpan(i, 1796);
            int w = (int)BinaryPrimitives.ReadUInt32BigEndian(h[372..]), height = (int)BinaryPrimitives.ReadUInt32BigEndian(h[376..]);
            var bpp = (int)BinaryPrimitives.ReadUInt32BigEndian(h[388..]) / 8;
            var t = (BinaryPrimitives.ReadInt32BigEndian(h[456..]), BinaryPrimitives.ReadInt32BigEndian(h[460..]));
            i += 1796;
            pages.Add((Lines(b, ref i, w, height, bpp), t));
        }
        return pages;
    }

    public static List<byte[]> Urf(byte[] b)
    {
        Assert.Equal("UNIRAST\0", Encoding.ASCII.GetString(b, 0, 8));
        var count = (int)BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(8));
        var pages = new List<byte[]>();
        var i = 12;
        for (var p = 0; p < count; p++)
        {
            var bpp = b[i] / 8;
            int w = (int)BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(i + 12)), h = (int)BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(i + 16));
            i += 32;
            pages.Add(Lines(b, ref i, w, h, bpp));
        }
        Assert.Equal(b.Length, i);
        return pages;
    }

    /// <summary>Line repeat byte, then runs: 0-127 the next pixel n+1 times, 129-255 257-n pixels as they are (128 isn't expected).</summary>
    private static byte[] Lines(byte[] b, ref int i, int w, int h, int bpp)
    {
        var o = new byte[w * h * bpp];
        var y = 0;
        while (y < h)
        {
            var repeat = b[i++] + 1;
            var line = new byte[w * bpp];
            var x = 0;
            while (x < w)
            {
                var c = b[i++];
                Assert.NotEqual(128, c);
                if (c < 128)
                {
                    for (var k = 0; k <= c; k++) Array.Copy(b, i, line, (x + k) * bpp, bpp);
                    i += bpp;
                    x += c + 1;
                }
                else
                {
                    var n = 257 - c;
                    Array.Copy(b, i, line, x * bpp, n * bpp);
                    i += n * bpp;
                    x += n;
                }
            }
            Assert.Equal(w, x);
            for (var r = 0; r < repeat; r++) line.CopyTo(o, (y + r) * line.Length);
            y += repeat;
        }
        Assert.Equal(h, y);
        return o;
    }

    public static List<(byte[] Pixels, List<int> Strips, string Content, string MediaBox)> Pclm(byte[] pdf)
    {
        var text = Encoding.Latin1.GetString(pdf);
        var xref = int.Parse(Regex.Match(text, @"startxref\n(\d+)\n%%EOF\n$").Groups[1].Value);
        Assert.StartsWith("xref\n0 ", text[xref..]);
        var count = int.Parse(Regex.Match(text[xref..], @"^xref\n0 (\d+)\n").Groups[1].Value);
        var rows = text[xref..].Split('\n').Skip(2).Take(count).ToList();
        Assert.Equal("0000000000 65535 f ", rows[0]);
        var offsets = rows.Select(r => int.Parse(r[..10])).ToList();
        for (var n = 1; n < count; n++) Assert.StartsWith($"{n} 0 obj\n", text[offsets[n]..]);
        Assert.Contains($"trailer\n<</Size {count}/Root 1 0 R>>", text);
        string Obj(int n) => text[offsets[n]..text.IndexOf("endobj\n", offsets[n], StringComparison.Ordinal)];
        byte[] StreamOf(int n, out string dict)
        {
            var o = Obj(n);
            var start = o.IndexOf(">>\nstream\n", StringComparison.Ordinal);
            dict = o[..start];
            var len = int.Parse(Regex.Match(dict, @"/Length (\d+)").Groups[1].Value);
            var at = offsets[n] + start + ">>\nstream\n".Length;
            Assert.Equal("\nendstream\n", text.Substring(at + len, 11));
            return pdf[at..(at + len)];
        }
        var result = new List<(byte[], List<int>, string, string)>();
        var kids = Regex.Matches(Regex.Match(Obj(2), @"/Kids\[([^\]]*)\]").Groups[1].Value, @"(\d+) 0 R").Select(m => int.Parse(m.Groups[1].Value));
        foreach (var kid in kids)
        {
            var page = Obj(kid);
            var box = Regex.Match(page, @"/MediaBox(\[[^\]]*\])").Groups[1].Value;
            var content = Encoding.ASCII.GetString(StreamOf(int.Parse(Regex.Match(page, @"/Contents (\d+) 0 R").Groups[1].Value), out _));
            var pixels = new List<byte>();
            var strips = new List<int>();
            foreach (Match m in Regex.Matches(content, @"q (\d+) 0 0 (\d+) 0 (\d+) cm /Image(\d+) Do Q"))
            {
                var image = int.Parse(Regex.Match(page, $@"/Image{m.Groups[4].Value} (\d+) 0 R").Groups[1].Value);
                var data = StreamOf(image, out var dict);
                Assert.Contains("/Type/XObject/Subtype/Image", dict);
                strips.Add(int.Parse(m.Groups[2].Value));
                if (dict.Contains("/FlateDecode"))
                {
                    using var z = new ZLibStream(new MemoryStream(data), CompressionMode.Decompress);
                    using var raw = new MemoryStream();
                    z.CopyTo(raw);
                    pixels.AddRange(raw.ToArray());
                }
                else
                {
                    var i = 0;
                    while (data[i] != 128)
                        if (data[i] < 128) { pixels.AddRange(data.AsSpan(i + 1, data[i] + 1).ToArray()); i += data[i] + 2; }
                        else { pixels.AddRange(Enumerable.Repeat(data[i + 1], 257 - data[i])); i += 2; }
                    Assert.Equal(data.Length - 1, i);
                }
            }
            result.Add(([.. pixels], strips, content, box));
        }
        return result;
    }
}

public class DirectPrintTests
{
    // ---- IPP: requests, collections, hostile replies ----

    private static DirectPrintPlan Plan(DirectPaper? paper = null) =>
        new(RasterFormat.PwgRaster, 300, RasterColor.Rgb8, paper ?? new DirectPaper("na_letter_8.5x11in", 21590, 27940, 635, 635, 635, 635))
        { TwoSided = true, Copies = 2, ColorMode = "color", Quality = 5, MediaType = "photographic-glossy" };

    [Fact]
    public void Print_job_has_its_operation_and_job_attributes_in_order()
    {
        var body = DirectJob.PrintJobRequest("ipp://192.0.2.11:631/ipp/print", "ana", "report.pdf", Plan(), requestId: 7);
        Assert.Equal(new byte[] { 2, 0, 0, 2, 0, 0, 0, 7, 1 }, body[..9]); // IPP/2.0, Print-Job, request 7, operation group
        var (status, groups) = IppCodec.DecodeGroups(body);
        Assert.Equal(2, status); // the operation id sits where a reply's status does
        var op = groups[0].Attributes;
        Assert.Equal(["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "job-name", "document-format"], op.Keys);
        Assert.Equal("image/pwg-raster", op["document-format"][0]);
        Assert.Equal(IppCodec.JobTag, groups[1].Tag);
        var job = new IppResponse(0, groups[1].Attributes);
        Assert.Equal(2, job.Int("copies"));
        Assert.Equal("two-sided-long-edge", job.Str("sides"));
        Assert.Equal("color", job.Str("print-color-mode"));
        Assert.Equal(5, job.Int("print-quality"));
        var col = job.Collections("media-col").Single();
        Assert.Equal(21590, col.Collection("media-size")!.Int("x-dimension"));
        Assert.Equal(27940, col.Collection("media-size")!.Int("y-dimension"));
        Assert.Equal(635, col.Int("media-top-margin"));
        Assert.Equal("photographic-glossy", col.Str("media-type"));
        Assert.Equal(IppCodec.EndTag, body[^1]);
    }

    [Fact]
    public void A_collection_is_written_as_rfc_8010_has_it()
    {
        var body = new IppRequest(IppCodec.PrintJob, 1, "ipp://x/").JobGroup()
            .Collection("media-col", c => c.Collection("media-size", s => s.Integer("x-dimension", 1))).ToArray();
        var at = body.AsSpan().IndexOf(new byte[] { 0x34, 0, 9 }); // media-col, the job group's only attribute
        Assert.Equal(IppCodec.JobTag, body[at - 1]);
        byte[] expected =
        [
            0x34, 0, 9, .. "media-col"u8, 0, 0,               // begCollection "media-col"
            0x4A, 0, 0, 0, 10, .. "media-size"u8,             // memberAttrName "media-size"
            0x34, 0, 0, 0, 0,                                 // its value: a collection
            0x4A, 0, 0, 0, 11, .. "x-dimension"u8,
            0x21, 0, 0, 0, 4, 0, 0, 0, 1,                     // integer 1
            0x37, 0, 0, 0, 0,                                 // end of media-size
            0x37, 0, 0, 0, 0,                                 // end of media-col
            0x03,
        ];
        Assert.Equal(expected, body[at..]);
    }

    [Fact]
    public void Long_names_are_cut_to_255_bytes()
    {
        var body = DirectJob.PrintJobRequest("ipp://x/", new string('é', 300), new string('a', 400), Plan());
        var op = new IppResponse(0, IppCodec.DecodeGroups(body).Groups[0].Attributes);
        Assert.Equal(255, op.Str("job-name")!.Length);
        Assert.True(Encoding.UTF8.GetByteCount(op.Str("requesting-user-name")!) <= 255);
    }

    [Fact]
    public void Hostile_collections_are_refused_or_bounded()
    {
        // Nested past the limit.
        var deep = new List<byte> { 2, 0, 0, 0, 0, 0, 0, 1, 4 };
        void Attr(byte tag, string name, byte[] v)
        {
            deep.AddRange([tag, (byte)(name.Length >> 8), (byte)name.Length, .. Encoding.ASCII.GetBytes(name), (byte)(v.Length >> 8), (byte)v.Length, .. v]);
        }
        Attr(0x34, "media-col-database", []);
        for (var i = 0; i < IppCodec.MaxCollectionDepth; i++)
        {
            Attr(0x4A, "", "m"u8.ToArray());
            Attr(0x34, "", []);
        }
        deep.Add(3);
        Assert.Throws<FormatException>(() => IppCodec.Decode([.. deep]));
        // Never closed.
        Assert.Throws<FormatException>(() => IppCodec.Decode([2, 0, 0, 0, 0, 0, 0, 1, 4, 0x34, 0, 1, (byte)'a', 0, 0, 3]));
        // Closed twice.
        Assert.Throws<FormatException>(() => IppCodec.Decode([2, 0, 0, 0, 0, 0, 0, 1, 4, 0x37, 0, 0, 0, 0, 3]));
        // Truncated anywhere: a FormatException, never an index out of range.
        var good = DirectJob.PrintJobRequest("ipp://x/", "u", "j", Plan());
        for (var cut = 9; cut < good.Length - 1; cut++)
        {
            var part = good[..cut];
            try { IppCodec.DecodeGroups(part); }
            catch (FormatException) { }
        }
    }

    [Fact]
    public void Resolution_range_and_date_values_decode()
    {
        var r = IppCodec.Decode(Printer(b => b
            .Raw(0x32, "pwg-raster-document-resolution-supported", [0, 0, 1, 44, 0, 0, 1, 44, 3])
            .Raw(0x32, "", [0, 0, 0, 118, 0, 0, 0, 118, 4])
            .Raw(0x33, "copies-supported", [0, 0, 0, 1, 0, 0, 0, 99])
            .Raw(0x31, "printer-current-time", [0x07, 0xEA, 11, 18, 9, 30, 0, 0, (byte)'-', 4, 0])));
        Assert.Equal([300, 300], r.Resolutions("pwg-raster-document-resolution-supported").Select(x => x.Dpi!.Value));
        Assert.Equal(new IppRange(1, 99), r.Range("copies-supported"));
        Assert.Equal(new DateTimeOffset(2026, 11, 18, 9, 30, 0, TimeSpan.FromHours(-4)), r.Attributes["printer-current-time"][0]);
        Assert.Equal(new IppResolution(300, 300, 3), IppText.ParseResolution("300dpi"));
        Assert.Equal(new IppResolution(600, 300, 3), IppText.ParseResolution("600x300dpi"));
        Assert.Null(IppText.ParseResolution("300"));
        Assert.Equal(new IppRange(1, 99), IppText.ParseRange("1-99"));
        Assert.Null(IppText.ParseRange("9-1"));
    }

    // ---- what a printer takes ----

    private static C MediaCol(int w, int h, int margin, string? name = null, string? source = null) =>
        Col(c =>
        {
            c.Coll("media-size", s => s.Int("x-dimension", w).Int("y-dimension", h));
            foreach (var side in new[] { "bottom", "left", "right", "top" }) c.Int($"media-{side}-margin", margin);
            if (name is not null) c.Kw("media-size-name", name);
            if (source is not null) c.Kw("media-source", source);
        });

    [Fact]
    public void Caps_come_from_media_col_database_and_the_raster_attributes()
    {
        var r = IppCodec.Decode(Printer(b => b
            .Mime("document-format-supported", "application/octet-stream", "image/pwg-raster", "image/urf", "application/PCLm")
            .Kw("pwg-raster-document-type-supported", "black_1", "sgray_8", "srgb_8")
            .Res("pwg-raster-document-resolution-supported", 300, 600)
            .Kw("pwg-raster-document-sheet-back", "flipped")
            .Kw("urf-supported", "V1.4", "W8", "SRGB24", "RS300-600", "DM3")
            .Res("pclm-source-resolution-supported", 600)
            .Int("pclm-strip-height-preferred", 32)
            .Kw("pclm-compression-method-preferred", "jpeg", "rle", "flate")
            .Collections("media-col-database", MediaCol(21590, 27940, 423, "na_letter_8.5x11in"), MediaCol(21590, 27940, 0, "na_letter_8.5x11in"),
                MediaCol(21000, 29700, 423), MediaCol(9_999_999, 100, 0), MediaCol(10160, 15240, 0, "na_index-4x6_4x6in", "photo"))
            .Collections("media-col-default", MediaCol(21590, 27940, 423, "na_letter_8.5x11in"))
            .Kw("sides-supported", "one-sided", "two-sided-long-edge")
            .Kw("print-color-mode-supported", "monochrome", "color")
            .Kw("print-color-mode-default", "color")
            .Range("copies-supported", 1, 99)
            .Enums("print-quality-supported", 3, 4, 5, 9)
            .Kw("media-type-supported", "stationery", "photographic-glossy", "BAD KEYWORD")));
        var caps = IppPrintCaps.From(r);
        Assert.Equal([RasterFormat.PwgRaster, RasterFormat.Urf, RasterFormat.Pclm], caps.Formats);
        Assert.Equal([RasterColor.Gray8, RasterColor.Rgb8], caps.PwgColors);
        Assert.Equal([300, 600], caps.PwgDpis);
        Assert.Equal(BackSide.Flipped, caps.PwgBack);
        Assert.Equal([300, 600], caps.UrfDpis);
        Assert.Equal(BackSide.Rotated, caps.UrfBack);
        Assert.Equal(32, caps.PclmStripHeight);
        Assert.True(caps.PclmRunLength); // run-length before flate
        Assert.Equal(4, caps.Papers.Count); // the 100 km wide one left out
        Assert.Equal("iso_a4_210x297mm", caps.Papers[2].Name); // named from its size when the printer gives no name
        Assert.Equal("photo", caps.Papers[3].Source);
        Assert.True(caps.Papers[1].Borderless);
        Assert.Equal(caps.Papers[0], caps.DefaultPaper);
        Assert.True(caps.TwoSided);
        Assert.True(caps.Color && caps.ColorByDefault);
        Assert.Equal(99, caps.MaxCopies);
        Assert.Equal([3, 4, 5], caps.Qualities);
        Assert.Equal(["stationery", "photographic-glossy"], caps.MediaTypes);
    }

    [Fact]
    public void Without_media_col_database_the_papers_come_from_media_supported()
    {
        var caps = IppPrintCaps.From(IppCodec.Decode(Printer(b => b
            .Mime("document-format-supported", "image/urf")
            .Kw("urf-supported", "W8", "RS300")
            .Kw("media-supported", "na_letter_8.5x11in", "iso_a4_210x297mm", "custom_min_10x10mm", "na_index-4x6_4x6in", "nonsense")
            .Kw("media-default", "iso_a4_210x297mm")
            .Ints("media-left-margin-supported", 0, 300).Ints("media-right-margin-supported", 0, 300)
            .Ints("media-top-margin-supported", 0, 300).Ints("media-bottom-margin-supported", 0, 300, -5))));
        Assert.Equal(6, caps.Papers.Count); // three sizes, each with margins and borderless
        Assert.Equal(new DirectPaper("iso_a4_210x297mm", 21000, 29700, 300, 300, 300, 300), caps.DefaultPaper);
        Assert.Equal((10160, 15240), IppPrintCaps.Size("na_index-4x6_4x6in"));
        Assert.Null(IppPrintCaps.Size("custom_max_1000x1000in"));
        Assert.Null(IppPrintCaps.Size(new string('a', 500) + "_1x1in"));
        Assert.False(caps.TwoSided);
        Assert.False(caps.Color);
        Assert.Equal(1, caps.MaxCopies);
    }

    [Fact]
    public void A_format_counts_only_with_what_it_needs_and_hostile_lists_are_cut()
    {
        var caps = IppPrintCaps.From(IppCodec.Decode(Printer(b => b
            .Mime("document-format-supported", "image/pwg-raster", "image/urf", "application/PCLm")
            .Kw("pwg-raster-document-type-supported", "black_1") // nothing 8-bit
            .Kw("urf-supported", "RS0-99999", "W8")              // no usable resolution
            .Res("pclm-source-resolution-supported", 0)
            .Int("pclm-strip-height-preferred", 0)
            .Collections("media-col-database", Enumerable.Range(0, 1000).Select(i => MediaCol(10000 + i * 10, 15000, -9)).ToArray())
            .Range("copies-supported", 1, int.MaxValue))));
        Assert.Empty(caps.Formats);
        Assert.False(caps.CanPrint);
        Assert.Equal(IppPrintCaps.MaxPapers, caps.Papers.Count);
        Assert.All(caps.Papers, p => Assert.Equal(0, p.Left)); // a negative margin reads as none
        Assert.Equal(16, caps.PclmStripHeight);
        Assert.Equal(999, caps.MaxCopies);
    }

    // ---- the plan ----

    private static IppPrintCaps Caps(Func<IppPrintCaps, IppPrintCaps>? change = null)
    {
        var letter = new DirectPaper("na_letter_8.5x11in", 21590, 27940, 423, 423, 423, 423);
        var caps = new IppPrintCaps
        {
            Formats = [RasterFormat.PwgRaster, RasterFormat.Urf, RasterFormat.Pclm],
            PwgColors = [RasterColor.Gray8, RasterColor.Rgb8],
            PwgDpis = [300, 600],
            PwgBack = BackSide.Rotated,
            UrfColors = [RasterColor.Gray8],
            UrfDpis = [600],
            PclmDpis = [600],
            Papers = [letter, letter with { Left = 0, Top = 0, Right = 0, Bottom = 0 }, new DirectPaper("iso_a4_210x297mm", 21000, 29700, 423, 423, 423, 423),
                new DirectPaper("na_index-4x6_4x6in", 10160, 15240, 0, 0, 0, 0)],
            DefaultPaper = letter,
            TwoSided = true,
            Color = true,
            MaxCopies = 99,
            CollatedCopies = true,
            Qualities = [4, 5],
            MediaTypes = ["stationery", "photographic-glossy"],
        };
        return change?.Invoke(caps) ?? caps;
    }

    [Fact]
    public void Pwg_raster_at_300_dpi_first_with_what_was_asked()
    {
        var plan = DirectPrintPlan.Choose(Caps(), new DirectPrintRequest(3, TwoSided: true) { Color = true, Quality = 5, MediaType = "photographic-glossy" }, out var problem)!;
        Assert.Null(problem);
        Assert.Equal(RasterFormat.PwgRaster, plan.Format);
        Assert.Equal((300, 300, 1), (plan.Dpi, plan.RenderDpi, plan.Enlarge));
        Assert.Equal(RasterColor.Rgb8, plan.Color);
        Assert.Equal("color", plan.ColorMode);
        Assert.Equal((3, 1), (plan.Copies, plan.Repeat));
        Assert.True(plan.TwoSided);
        Assert.Equal(BackSide.Rotated, plan.Back);
        Assert.Equal(5, plan.Quality);
        Assert.Equal("na_letter_8.5x11in", plan.Paper.Name);
        Assert.False(plan.Paper.Borderless);
        Assert.Equal("image/pwg-raster", plan.DocumentFormat);
    }

    [Fact]
    public void Apple_raster_at_600_is_drawn_at_300_and_enlarged_in_grey()
    {
        var plan = DirectPrintPlan.Choose(Caps(c => c with { Formats = [RasterFormat.Urf, RasterFormat.Pclm] }), new DirectPrintRequest { Color = true }, out _)!;
        Assert.Equal(RasterFormat.Urf, plan.Format);
        Assert.Equal((600, 300, 2), (plan.Dpi, plan.RenderDpi, plan.Enlarge));
        Assert.Equal(RasterColor.Gray8, plan.Color); // its urf-supported has W8 only
        Assert.Equal("monochrome", plan.ColorMode);
        Assert.Equal(360, DirectPrintPlan.ChooseDpi([360, 720]));
        Assert.Equal(360, DirectPrintPlan.ChooseDpi([360]));
        Assert.Equal(150, DirectPrintPlan.ChooseDpi([100, 150]));
        Assert.Null(DirectPrintPlan.ChooseDpi([]));
        var odd = new DirectPrintPlan(RasterFormat.Urf, 360, RasterColor.Gray8, Caps().Papers[0]);
        Assert.Equal((360, 1), (odd.RenderDpi, odd.Enlarge));
    }

    [Fact]
    public void Only_the_format_asked_for()
    {
        var plan = DirectPrintPlan.Choose(Caps(), new DirectPrintRequest { Format = RasterFormat.Pclm }, out _)!;
        Assert.Equal(RasterFormat.Pclm, plan.Format);
        Assert.Equal("application/PCLm", plan.DocumentFormat);
    }

    [Fact]
    public void Copies_the_printer_doesnt_make_are_sent_again_with_a_blank_back_between()
    {
        var plan = DirectPrintPlan.Choose(Caps(c => c with { MaxCopies = 1 }), new DirectPrintRequest(2, TwoSided: true), out _)!;
        Assert.Equal((1, 2), (plan.Copies, plan.Repeat));
        Assert.Equal(4, plan.PagesPerCopy(3));
        Assert.Equal(8, plan.Job(plan.PagesPerCopy(3)).Pages);
        var once = DirectPrintPlan.Choose(Caps(), new DirectPrintRequest(2, TwoSided: true), out _)!;
        Assert.Equal(3, once.PagesPerCopy(3)); // the printer makes the copies: no blank
    }

    [Fact]
    public void Paper_by_name_size_default_or_borderless()
    {
        var caps = Caps();
        Assert.Equal("iso_a4_210x297mm", DirectPrintPlan.Choose(caps, new DirectPrintRequest { PaperName = "iso_a4_210x297mm" }, out _)!.Paper.Name);
        Assert.Equal("iso_a4_210x297mm", DirectPrintPlan.Choose(caps, new DirectPrintRequest { PaperInches = (11.69, 8.27) }, out _)!.Paper.Name);
        Assert.True(DirectPrintPlan.Choose(caps, new DirectPrintRequest { PaperName = "na_letter_8.5x11in", Borderless = true }, out _)!.Paper.Borderless);
        Assert.Equal("na_letter_8.5x11in", DirectPrintPlan.Choose(caps with { DefaultPaper = null }, new DirectPrintRequest(), out _)!.Paper.Name);
        Assert.Null(DirectPrintPlan.Choose(caps, new DirectPrintRequest { PaperName = "iso_a3_297x420mm" }, out var problem));
        Assert.Equal(Core.CoreStrings.Direct_NoPaper, problem);
        Assert.Null(DirectPrintPlan.Choose(caps, new DirectPrintRequest { PaperName = "iso_a4_210x297mm", Borderless = true }, out _));
    }

    [Fact]
    public void What_the_printer_cant_do_is_said_and_nothing_is_planned()
    {
        Assert.Null(DirectPrintPlan.Choose(Caps(c => c with { TwoSided = false }), new DirectPrintRequest(TwoSided: true), out var p1));
        Assert.Equal(Core.CoreStrings.Direct_NotTwoSided, p1);
        Assert.Null(DirectPrintPlan.Choose(Caps(c => c with { Formats = [] }), new DirectPrintRequest(), out var p2));
        Assert.Equal(Core.CoreStrings.Direct_NoFormat, p2);
        Assert.Null(DirectPrintPlan.Choose(Caps(), new DirectPrintRequest(0), out var p3));
        Assert.Equal(Core.CoreStrings.Direct_Copies, p3);
        // A quality or paper type the printer doesn't list is said, not dropped.
        Assert.Null(DirectPrintPlan.Choose(Caps(), new DirectPrintRequest { Quality = 3 }, out var p4));
        Assert.Equal(Core.CoreStrings.Direct_NoQuality, p4);
        Assert.Null(DirectPrintPlan.Choose(Caps(), new DirectPrintRequest { MediaType = "labels" }, out var p5));
        Assert.Equal(Core.CoreStrings.Direct_NoMediaType, p5);
        var plan = DirectPrintPlan.Choose(Caps(), new DirectPrintRequest { Quality = 4, MediaType = "stationery", Color = false }, out _)!;
        Assert.Equal((4, "stationery"), (plan.Quality, plan.MediaType));
        Assert.Equal(RasterColor.Gray8, plan.Color);
        Assert.False(plan.Grey);
    }

    [Fact]
    public void Grey_on_a_format_that_takes_only_color_is_made_grey_here()
    {
        var rgbOnly = Caps(c => c with { PwgColors = [RasterColor.Rgb8] });
        var grey = DirectPrintPlan.Choose(rgbOnly, new DirectPrintRequest { Color = false }, out _)!;
        Assert.Equal(RasterColor.Rgb8, grey.Color);
        Assert.True(grey.Grey);
        Assert.Equal("monochrome", grey.ColorMode);
        var color = DirectPrintPlan.Choose(rgbOnly, new DirectPrintRequest { Color = true }, out _)!;
        Assert.False(color.Grey);
        Assert.Equal("color", color.ColorMode);
        // The pixels: RGB with the three equal.
        var page = RasterPage.FromBgra(1, 1, 4, [0, 0, 255, 255], RasterColor.Rgb8, grey: true);
        Assert.Equal(new byte[] { 77, 77, 77 }, page.Pixels);
    }

    [Fact]
    public void The_printer_makes_copies_only_when_it_collates_them()
    {
        var collates = DirectPrintPlan.Choose(Caps(), new DirectPrintRequest(3), out _)!;
        Assert.Equal((3, 1), (collates.Copies, collates.Repeat));
        var body = new IppResponse(0, IppCodec.DecodeGroups(DirectJob.PrintJobRequest("ipp://x/", "u", "j", collates)).Groups[1].Attributes);
        Assert.Equal("separate-documents-collated-copies", body.Str("multiple-document-handling"));
        var doesnt = DirectPrintPlan.Choose(Caps(c => c with { CollatedCopies = false }), new DirectPrintRequest(3), out _)!;
        Assert.Equal((1, 3), (doesnt.Copies, doesnt.Repeat)); // the pages go three times, collated by the order they're sent in
        var one = new IppResponse(0, IppCodec.DecodeGroups(DirectJob.PrintJobRequest("ipp://x/", "u", "j", doesnt)).Groups[1].Attributes);
        Assert.Null(one.Int("copies"));
        Assert.Null(one.Str("multiple-document-handling"));
        Assert.True(IppPrintCaps.From(IppCodec.Decode(Printer(b => b.Kw("multiple-document-handling-supported",
            "separate-documents-uncollated-copies", "separate-documents-collated-copies")))).CollatedCopies);
        Assert.False(IppPrintCaps.From(IppCodec.Decode(Printer(b => b.Kw("multiple-document-handling-supported",
            "separate-documents-uncollated-copies")))).CollatedCopies);
    }

    [Fact]
    public async Task The_printers_attributes_are_read_once_a_while()
    {
        var reads = 0;
        var now = new DateTime(2026, 11, 19, 12, 0, 0);
        var fail = false;
        var cache = new IppCapsCache(_ =>
        {
            reads++;
            return fail ? Task.FromException<IppPrintCaps>(new TimeoutException()) : Task.FromResult(new IppPrintCaps { MaxCopies = reads });
        }, TimeSpan.FromMinutes(2), () => now);
        Assert.Equal(1, (await cache.GetAsync()).MaxCopies);
        Assert.Equal(1, (await cache.GetAsync()).MaxCopies); // the two-sided check, the paper check and the print share one read
        now = now.AddMinutes(3);
        Assert.Equal(2, (await cache.GetAsync()).MaxCopies);
        cache.Forget();
        fail = true;
        await Assert.ThrowsAsync<TimeoutException>(() => cache.GetAsync());
        fail = false;
        Assert.Equal(4, (await cache.GetAsync()).MaxCopies); // a failed read isn't kept
        Assert.Equal(4, reads);
    }

    [Fact]
    public async Task A_cancel_says_whether_the_printer_took_it()
    {
        async Task<Exception> Stop(Func<byte[], byte[]> answer)
        {
            using var http = new DeviceHttp("192.0.2.11", new Answering(answer));
            return await Record.ExceptionAsync(() => DirectJob.StopAsync(new IppClient(http), "ana", 5, new CancellationToken(true)));
        }
        Assert.IsType<OperationCanceledException>(await Stop(_ => IppCodec.EncodeResponse(0, 1, [])));
        foreach (ushort ended in new ushort[] { 0x0404, 0x0406, 0x0407 }) // not possible (it ended), not found, gone
            Assert.IsType<OperationCanceledException>(await Stop(_ => IppCodec.EncodeResponse(ended, 1, [])));
        foreach (ushort refused in new ushort[] { 0x040C, 0x0401, 0x0500 })
        {
            var ex = Assert.IsType<DirectPrintException>(await Stop(_ => IppCodec.EncodeResponse(refused, 1, [])));
            Assert.True(ex.MayHavePrinted);
            Assert.Equal(Core.CoreStrings.Direct_CancelNotTaken, ex.Message);
        }
        Assert.IsType<DirectPrintException>(await Stop(_ => [1, 2])); // no answer to speak of
    }

    [Fact]
    public void A_printers_clock_out_of_range_is_left_out_not_thrown()
    {
        // Offset 14:59 (RFC 2579 allows 13 hours), and year 9999, which an offset can push past what a date holds.
        foreach (var value in new byte[][]
        {
            [0x07, 0xEA, 11, 18, 9, 30, 0, 0, (byte)'+', 14, 59],
            [0x27, 0x0F, 12, 31, 23, 59, 59, 0, (byte)'-', 13, 59],
            [0x27, 0x0F, 12, 31, 23, 59, 59, 0, (byte)'+', 0, 0],
        })
        {
            var answer = Response(0, b => b.Group(IppCodec.JobTag).Int("job-id", 3).Enums("job-state", 5).Raw(0x31, "date-time-at-creation", value));
            var job = PrinterJobs.Parse(answer, new DateTime(2026, 11, 19, 12, 0, 0)).Single();
            Assert.Equal(new DateTime(2026, 11, 19, 12, 0, 0), job.Submitted); // the time it was read instead
            Assert.Null(IppCodec.ReadDateTime(value));
        }
        Assert.NotNull(IppCodec.ReadDateTime([0x07, 0xEA, 11, 18, 9, 30, 0, 0, (byte)'+', 13, 0]));
    }

    [Theory]
    [InlineData(true, true, false, PrintRoute.Queue)]
    [InlineData(true, true, true, PrintRoute.Direct)]
    [InlineData(false, true, false, PrintRoute.Direct)]
    [InlineData(true, false, true, PrintRoute.Queue)]
    [InlineData(false, false, true, PrintRoute.None)]
    public void The_windows_queue_stays_the_default(bool queue, bool raster, bool chose, PrintRoute route) =>
        Assert.Equal(route, PrintRoutes.Choose(queue, raster, chose));

    // ---- jobs ----

    [Fact]
    public void Job_states_in_plain_words()
    {
        Assert.Equal(Core.CoreStrings.Direct_Printed, DirectJob.Describe(new DirectJobState(9, ["job-completed-successfully"], null, 3), 3));
        Assert.Equal(string.Format(Core.CoreStrings.Direct_PrintingPage, 2, 3), DirectJob.Describe(new DirectJobState(5, [], null, 1), 3));
        Assert.Equal(string.Format(Core.CoreStrings.Direct_Waiting, Core.CoreStrings.Direct_ReasonHeld),
            DirectJob.Describe(new DirectJobState(4, ["job-held-for-authorization"], null, null), 3));
        Assert.Equal(string.Format(Core.CoreStrings.Direct_AbortedBecause, Core.CoreStrings.Direct_ReasonFormat),
            DirectJob.Describe(new DirectJobState(8, ["document-format-error"], null, null), 3));
        Assert.Equal(Core.CoreStrings.Direct_RefusedFormat, DirectJob.Refused(0x040A));
        Assert.Equal(Core.CoreStrings.Direct_RefusedSignIn, DirectJob.Refused(0x0401));
        // RFC 8011 §13.1: busy is service-unavailable, temporary-error, not-accepting-jobs and busy; job-canceled is a cancel at
        // the printer; uri-scheme-not-supported is no format problem.
        foreach (ushort busy in new ushort[] { 0x0502, 0x0505, 0x0506, 0x0507 }) Assert.Equal(Core.CoreStrings.Direct_RefusedBusy, DirectJob.Refused(busy));
        Assert.Equal(Core.CoreStrings.Direct_CanceledAtPrinter, DirectJob.Refused(0x0508));
        Assert.Equal(Core.CoreStrings.Direct_Refused, DirectJob.Refused(0x040C));
        Assert.Equal(Core.CoreStrings.Direct_RefusedTooLarge, DirectJob.Refused(0x0408));
        Assert.Equal(Core.CoreStrings.Direct_RefusedFormat, DirectJob.Refused(0x041B));
        Assert.Equal(Core.CoreStrings.Direct_Refused, DirectJob.Refused(0x0400)); // no codes in words the user reads
        var hostile = IppCodec.Decode(Job(b => b.Int("job-state", 99)), IppCodec.JobTag);
        Assert.Null(DirectJob.StateOf(hostile));
        var long_ = DirectJob.StateOf(IppCodec.Decode(Job(b => b.Enums("job-state", 5).Text("job-state-message", new string('x', 5000) + "\nmore")
            .Int("job-impressions-completed", -4)), IppCodec.JobTag))!;
        Assert.True(long_.Message!.Length <= 201);
        Assert.Null(long_.PagesDone);
    }

    [Fact]
    public void Get_jobs_lists_the_printers_jobs_for_the_queue_card()
    {
        var answer = Response(0, b => b
            .Group(IppCodec.JobTag).Int("job-id", 12).Text("job-name", "report.pdf").Enums("job-state", 5).Kw("job-state-reasons", "job-printing")
                .Text("job-originating-user-name", "ana").Int("job-impressions", 4).Int("job-impressions-completed", 1)
                .Raw(0x31, "date-time-at-creation", [0x07, 0xEA, 11, 18, 9, 30, 0, 0, (byte)'+', 0, 0])
            .Group(IppCodec.JobTag).Int("job-id", 13).Text("job-name", "photos").Enums("job-state", 6).Kw("job-state-reasons", "resources-are-not-ready")
            .Group(IppCodec.JobTag).Int("job-id", -1).Enums("job-state", 3));
        var jobs = PrinterJobs.Parse(answer, new DateTime(2026, 11, 18, 10, 0, 0));
        Assert.Equal(2, jobs.Count);
        var printing = jobs.Single(j => j.Id == 12);
        Assert.Equal(("report.pdf", 4, 1, "ana"), (printing.Name, printing.Pages, printing.PagesPrinted, printing.Owner));
        Assert.Equal(JobStatus.Printing, printing.Status);
        Assert.Equal(new DateTimeOffset(2026, 11, 18, 9, 30, 0, TimeSpan.Zero).LocalDateTime, printing.Submitted);
        Assert.True(jobs.Single(j => j.Id == 13).Status.HasFlag(JobStatus.PaperOut));
        Assert.Throws<DirectPrintException>(() => PrinterJobs.Parse(Response(0x0401, _ => { }), DateTime.Now));
        var request = PrinterJobs.GetJobsRequest("ipp://x/", "ana");
        Assert.Equal(new byte[] { 2, 0, 0, 0x0A }, request[..4]);
    }

    [Fact]
    public async Task A_job_goes_to_the_printer_and_is_followed_to_its_end()
    {
        var fixtures = Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo");
        var handler = new FixtureHandler(name => File.Exists(Path.Combine(fixtures, name)) ? File.ReadAllBytes(Path.Combine(fixtures, name)) : null);
        using var http = new DeviceHttp("192.0.2.11", handler);
        var ipp = new IppClient(http);
        var caps = IppPrintCaps.From(await ipp.GetPrinterAttributesAsync(IppPrintCaps.Requested));
        Assert.Equal([RasterFormat.PwgRaster, RasterFormat.Urf], caps.Formats);
        Assert.True(caps.TwoSided && caps.Color);
        Assert.Contains(caps.Papers, p => p.Name == "na_index-4x6_4x6in" && p.Borderless);
        Assert.Equal("na_letter_8.5x11in", caps.DefaultPaper!.Name);
        Assert.Equal(300, caps.DefaultPaper.Left);

        var plan = DirectPrintPlan.Choose(caps, new DirectPrintRequest(2) { Color = false }, out _)!;
        using var document = new MemoryStream();
        var writer = RasterWriter.For(document, plan.Job(1));
        writer.Write(RasterPage.Blank(writer.Job.WidthPixels, writer.Job.HeightPixels, plan.Color));
        writer.Finish();
        document.Position = 0;
        var (id, state) = await DirectJob.SendAsync(ipp, "ana", "test", plan, document);
        Assert.Equal(1, id);
        Assert.Equal(DirectJobState.Pending, state!.State);
        var sent = handler.PrintJobs.Single();
        var end = Array.IndexOf(sent, IppCodec.EndTag, 8); // the request's attributes end where the document begins
        while (sent[end + 1] != (byte)'R') end = Array.IndexOf(sent, IppCodec.EndTag, end + 1);
        Assert.Equal(document.ToArray(), sent[(end + 1)..]);
        var seen = new List<DirectJobState>();
        var last = await DirectJob.WatchAsync(ipp, "ana", id, new SyncProgress<DirectJobState>(seen.Add), TimeSpan.FromMilliseconds(10), TimeSpan.FromSeconds(5), CancellationToken.None);
        Assert.Equal(DirectJobState.Completed, last!.State);
        Assert.Single(seen);
        Assert.True(await DirectJob.CancelAsync(ipp, "ana", id));
    }

    [Fact]
    public async Task A_printer_that_refuses_the_job_has_sent_nothing()
    {
        var handler = new Answering(_ => IppCodec.EncodeResponse(0x040A, 1, []));
        using var http = new DeviceHttp("192.0.2.11", handler);
        var ex = await Assert.ThrowsAsync<DirectPrintException>(() =>
            DirectJob.SendAsync(new IppClient(http), "ana", "test", Plan(), new MemoryStream([1, 2, 3])));
        Assert.False(ex.MayHavePrinted);
        Assert.Equal(Core.CoreStrings.Direct_RefusedFormat, ex.Message);
        var garbage = new Answering(_ => [1, 2, 3]);
        using var http2 = new DeviceHttp("192.0.2.11", garbage);
        var ex2 = await Assert.ThrowsAsync<DirectPrintException>(() =>
            DirectJob.SendAsync(new IppClient(http2), "ana", "test", Plan(), new MemoryStream([1, 2, 3])));
        Assert.True(ex2.MayHavePrinted);
    }

    [Fact]
    public void The_apps_state_file_puts_back_every_list_a_hand_edit_left_null()
    {
        // state.json is read into AppState (the app, which this project can't reference); a "DirectPrinters": null there threw
        // at start-up. Every list and dictionary AppState declares must be put back in Load.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        var source = File.ReadAllText(Path.Combine(dir!.FullName, "print", "src", "InkvoltPrint.App", "AppState.cs"));
        var load = source.IndexOf("public static AppState Load", StringComparison.Ordinal);
        Assert.True(load > 0);
        var names = Regex.Matches(source[..load], @"public (?:List|Dictionary)<.*> (\w+) \{ get; set; \}").Select(m => m.Groups[1].Value).ToList();
        Assert.Contains("DirectPrinters", names);
        var body = source[load..source.IndexOf("return state;", load, StringComparison.Ordinal)];
        foreach (var name in names) Assert.Matches($@"state\.{name} (=|\?\?=)", body);
    }

    [Fact]
    public void Photo_names_map_both_ways()
    {
        Assert.Equal("PhotographicGlossy", IppPhotoNames.MediaTypeName("photographic-glossy"));
        Assert.Equal("photographic-glossy", IppPhotoNames.MediaTypeKeyword("PhotographicGlossy"));
        Assert.Null(IppPhotoNames.MediaTypeName("com.example-roll"));
        Assert.Equal((3, 5), (IppPhotoNames.Quality("Draft")!.Value, IppPhotoNames.Quality(IppPhotoNames.QualityName(5))!.Value));
        Assert.Equal((true, false), (IppPhotoNames.Color("Color")!.Value, IppPhotoNames.Color("Grayscale")!.Value));
    }

    private sealed class SyncProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }

    private sealed class Answering(Func<byte[], byte[]> answer) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = await request.Content!.ReadAsByteArrayAsync(ct);
            return new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new ByteArrayContent(answer(body)), RequestMessage = request };
        }
    }

    // ---- building replies ----

    private static byte[] Printer(Action<B> attrs) => Response(0, b => attrs(b.Group(4)));

    private static byte[] Job(Action<B> attrs) => Response(0, b => attrs(b.Group(IppCodec.JobTag)));

    private static byte[] Response(ushort status, Action<B> attrs)
    {
        var b = new B();
        b.Bytes.AddRange([2, 0, (byte)(status >> 8), (byte)status, 0, 0, 0, 1, 1]);
        attrs(b);
        b.Bytes.Add(3);
        return [.. b.Bytes];
    }

    private static C Col(Action<C> members)
    {
        var c = new C();
        members(c);
        return c;
    }

    /// <summary>A collection to write: its members as (name, tag, value) or nested collections.</summary>
    private sealed class C
    {
        public readonly List<(string Name, byte Tag, byte[] Value, C? Nested)> Members = [];
        public C Int(string name, int v) { Members.Add((name, 0x21, BE(v), null)); return this; }
        public C Kw(string name, string v) { Members.Add((name, 0x44, Encoding.ASCII.GetBytes(v), null)); return this; }
        public C Coll(string name, Action<C> members)
        {
            Members.Add((name, 0x34, [], Col(members)));
            return this;
        }
    }

    private sealed class B
    {
        public readonly List<byte> Bytes = [];

        public B Group(byte tag) { Bytes.Add(tag); return this; }
        public B Raw(byte tag, string name, byte[] v)
        {
            var n = Encoding.UTF8.GetBytes(name);
            Bytes.AddRange([tag, (byte)(n.Length >> 8), (byte)n.Length, .. n, (byte)(v.Length >> 8), (byte)v.Length, .. v]);
            return this;
        }
        private B Many(byte tag, string name, IEnumerable<byte[]> values)
        {
            var first = true;
            foreach (var v in values) { Raw(tag, first ? name : "", v); first = false; }
            return this;
        }
        public B Kw(string name, params string[] v) => Many(0x44, name, v.Select(Encoding.UTF8.GetBytes));
        public B Mime(string name, params string[] v) => Many(0x49, name, v.Select(Encoding.UTF8.GetBytes));
        public B Text(string name, string v) => Raw(0x41, name, Encoding.UTF8.GetBytes(v));
        public B Int(string name, int v) => Raw(0x21, name, BE(v));
        public B Ints(string name, params int[] v) => Many(0x21, name, v.Select(BE));
        public B Enums(string name, params int[] v) => Many(0x23, name, v.Select(BE));
        public B Range(string name, int lo, int hi) => Raw(0x33, name, [.. BE(lo), .. BE(hi)]);
        public B Res(string name, params int[] dpi) => Many(0x32, name, dpi.Select(d => (byte[])[.. BE(d), .. BE(d), 3]));
        public B Collections(string name, params C[] values)
        {
            var first = true;
            foreach (var v in values)
            {
                Raw(0x34, first ? name : "", []);
                first = false;
                Members(v);
                Raw(0x37, "", []);
            }
            return this;
        }
        private void Members(C c)
        {
            foreach (var (name, tag, value, nested) in c.Members)
            {
                Raw(0x4A, "", Encoding.UTF8.GetBytes(name));
                Raw(tag, "", value);
                if (nested is not null)
                {
                    Members(nested);
                    Raw(0x37, "", []);
                }
            }
        }
    }

    private static byte[] BE(int v)
    {
        var b = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(b, v);
        return b;
    }
}
