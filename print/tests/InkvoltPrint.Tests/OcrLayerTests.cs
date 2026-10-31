using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Tests;

/// <summary>
/// The scan PDF's text layer (roadmap 2.3): a CID font with a /ToUnicode map. Read here byte by byte, with no PDF library;
/// what MuPDF and pdf.js make of the same files is in pdf/tests (OcrLayerSearchTests).
/// </summary>
public class OcrLayerTests
{
    private static readonly byte[] Jpeg = TestJpeg.Build(width: 2550, height: 3300, dnlHeight: null);

    private static OcrWord At(string text, double x = 300, double y = 300, double w = 600, double h = 60) => new(text, x, y, w, h);

    private static string Pdf(params OcrWord[] words) => Pdf([new PdfPage(Jpeg, 300, words)]);

    private static string Pdf(IReadOnlyList<PdfPage> pages, string? title = "Scan")
    {
        using var ms = new MemoryStream();
        PdfWriter.Write(ms, pages, title);
        return Encoding.Latin1.GetString(ms.ToArray());
    }

    /// <summary>Every code's text in the ToUnicode map, checking its syntax and each block's limit of 100 entries.</summary>
    private static Dictionary<int, string> ToUnicode(string pdf)
    {
        var at = pdf.IndexOf("begincmap", StringComparison.Ordinal);
        Assert.True(at >= 0, "no ToUnicode CMap in the file");
        var cmap = pdf[at..pdf.IndexOf("endcmap", at, StringComparison.Ordinal)];
        Assert.Contains("<0000> <FFFF>", cmap);
        foreach (Match block in Regex.Matches(cmap, @"(\d+) beginbfchar(.*?)endbfchar", RegexOptions.Singleline))
        {
            var n = int.Parse(block.Groups[1].Value, CultureInfo.InvariantCulture);
            Assert.InRange(n, 1, 100);
            Assert.Equal(n, Regex.Matches(block.Groups[2].Value, @"<[0-9A-F]{4}> <[0-9A-F]+>").Count);
        }
        var map = new Dictionary<int, string>();
        foreach (Match entry in Regex.Matches(cmap, @"<([0-9A-F]{4})> <([0-9A-F]+)>\r?\n"))
        {
            if (entry.Groups[1].Value == "0000" && entry.Groups[2].Value == "FFFF") continue;
            var utf16 = Convert.FromHexString(entry.Groups[2].Value);
            Assert.Equal(0, utf16.Length % 2);
            map.Add(Convert.ToInt32(entry.Groups[1].Value, 16), Encoding.BigEndianUnicode.GetString(utf16));
        }
        return map;
    }

    /// <summary>What each word's hex string in the content says through the map, in writing order, spaces included.</summary>
    private static List<string> Shown(string pdf)
    {
        var map = ToUnicode(pdf);
        var shown = new List<string>();
        foreach (Match tj in Regex.Matches(pdf, @"<([0-9A-F]+)> Tj"))
        {
            var codes = Convert.FromHexString(tj.Groups[1].Value);
            Assert.Equal(0, codes.Length % 2);
            var s = new StringBuilder();
            for (var i = 0; i < codes.Length; i += 2) s.Append(map[BinaryPrimitives.ReadUInt16BigEndian(codes.AsSpan(i))]);
            shown.Add(s.ToString());
        }
        return shown;
    }

    private static string ContentOf(string pdf) => pdf[pdf.IndexOf("BT 3 Tr", StringComparison.Ordinal)..pdf.IndexOf("ET\n", StringComparison.Ordinal)];

    [Fact]
    public void Non_Latin_words_keep_their_letters()
    {
        string[] words = ["Καλημέρα", "Привет", "東京都庁", "中华人民共和国", "안녕하세요", "नमस्ते", "Hello"];
        var pdf = Pdf([.. words.Select((w, i) => At(w, y: 100 + i * 100))]);
        Assert.Equal(words, Shown(pdf));
        Assert.DoesNotContain("?", string.Concat(Shown(pdf)));
    }

    [Fact]
    public void The_font_is_a_composite_font_with_a_unicode_map()
    {
        var pdf = Pdf(At("Привет"));
        Assert.Contains("/Subtype /Type0", pdf);
        Assert.Contains("/Encoding /Identity-H", pdf);
        Assert.Contains("/Subtype /CIDFontType2", pdf);
        Assert.Contains("/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>", pdf);
        Assert.Matches(@"/ToUnicode \d+ 0 R", pdf);
        Assert.Matches(@"/FontFile2 \d+ 0 R", pdf);
        Assert.Matches(@"/CIDToGIDMap \d+ 0 R", pdf);
        Assert.DoesNotContain("WinAnsiEncoding", pdf);
    }

    [Fact]
    public void Characters_outside_the_first_plane_are_one_code_with_a_surrogate_pair()
    {
        var pdf = Pdf(At("𠮷野家"));
        var map = ToUnicode(pdf);
        Assert.Contains("𠮷", map.Values);
        Assert.Matches(@"<[0-9A-F]{4}> <D842DFB7>", pdf); // U+20BB7, as two UTF-16 units in big-endian
        Assert.Equal(["𠮷野家"], Shown(pdf));
        Assert.Equal(3, Regex.Match(pdf, @"<([0-9A-F]+)> Tj").Groups[1].Length / 4);
    }

    [Fact]
    public void A_letter_and_its_marks_are_one_code()
    {
        var pdf = Pdf(At("नमस्ते"));
        var codes = Regex.Match(pdf, @"<([0-9A-F]+)> Tj").Groups[1].Length / 4;
        Assert.True(codes < "नमस्ते".Length, $"{codes} codes");
        Assert.Contains("स्", ToUnicode(pdf).Values.Select(v => v.Length > 1 ? v[..2] : v));
    }

    [Fact]
    public void A_right_to_left_word_is_turned_round_character_by_character_marks_too()
    {
        // pdf.js and MuPDF turn it back the same way; reversing by cluster would leave each mark on the wrong side of its letter when read back.
        var word = "שָׁלום".Normalize(NormalizationForm.FormC);
        var pdf = Pdf(At(word));
        var written = new string(word.Reverse().ToArray());
        Assert.Equal([written], Shown(pdf));
        Assert.All(ToUnicode(pdf).Values, v => Assert.Equal(1, v.Length));
    }

    [Fact]
    public void Decomposed_letters_are_written_composed_so_a_typed_search_finds_them()
    {
        var decomposed = "Чайка"; // и + breve
        Assert.Equal(["Чайка"], Shown(Pdf(At(decomposed))));
    }

    [Theory]
    [InlineData("مرحبا", "ابحرم")]
    [InlineData("שלום", "םולש")]
    [InlineData("عام2026", "2026ماع")] // digits keep their order: pdf.js and MuPDF read them forward
    [InlineData("2026عام", "ماع2026")]
    [InlineData("٢٠٢٦", "٢٠٢٦")]
    [InlineData("مبلغ 1,234.50 ريال", "لاير 1,234.50 غلبم")]
    [InlineData("(كلمة)", ")ةملك(")]
    public void Right_to_left_words_are_written_in_visual_order(string word, string written)
    {
        Assert.Equal([written], Shown(Pdf(At(word))));
    }

    [Fact]
    public void Latin_words_are_left_alone()
    {
        Assert.Equal(["Hello (world)", "a\\b", "100%"], Shown(Pdf(At("Hello (world)", y: 100), At("a\\b", y: 300), At("100%", y: 500))));
    }

    [Theory]
    [InlineData("\uD83D")] // a lone high surrogate
    [InlineData("\uDC00")]
    [InlineData("\u0000")]
    [InlineData("‏")] // only a direction mark
    [InlineData("﻿")]
    [InlineData("￿")]
    [InlineData("\u001F\u0007")]
    [InlineData("   ")]
    [InlineData("")]
    public void A_word_with_nothing_left_to_show_is_left_out(string text)
    {
        var pdf = Pdf(At(text), At("kept", y: 500));
        Assert.Equal(["kept"], Shown(pdf));
    }

    [Theory]
    [InlineData("a\uD83Db", "ab")]
    [InlineData("‏שלום‎", "םולש")] // direction marks would split a search
    [InlineData("﻿word﻿", "word")]
    [InlineData("tab\there", "tabhere")]
    [InlineData("  padded  ", "padded")]
    [InlineData("(((", "(((")]
    [InlineData(">><<", ">><<")]
    [InlineData("%PDF-1.7 endobj", "%PDF-1.7 endobj")]
    public void Unusual_words_stay_valid(string text, string shown)
    {
        var pdf = Pdf(At(text));
        Assert.Equal([shown], Shown(pdf));
        Assert.Matches(@"^[\x20-\x7E\n]+$", ContentOf(pdf));
        XrefPointsAtObjects(pdf);
    }

    [Theory]
    [InlineData(double.NaN, 10, 10, 10)]
    [InlineData(10, double.PositiveInfinity, 10, 10)]
    [InlineData(10, 10, double.NaN, 10)]
    [InlineData(10, 10, 10, double.NaN)]
    [InlineData(10, 10, 10, 0)]
    [InlineData(10, 10, 10, -5)]
    public void A_box_no_page_can_have_is_left_out(double x, double y, double w, double h)
    {
        var pdf = Pdf(At("gone", x, y, w, h), At("kept", y: 500));
        Assert.Equal(["kept"], Shown(pdf));
        Assert.DoesNotContain("NaN", pdf);
        Assert.DoesNotContain("Infinity", pdf);
        Assert.DoesNotContain("∞", pdf);
    }

    [Theory]
    [InlineData(0.0)] // no width at all
    [InlineData(1e-9)]
    [InlineData(1e7)]
    public void Text_scaling_stays_in_a_range_viewers_accept(double width)
    {
        var content = ContentOf(Pdf(At("word", w: width)));
        var tz = double.Parse(Regex.Match(content, @"([\d.]+) Tz").Groups[1].Value, CultureInfo.InvariantCulture);
        Assert.InRange(tz, 1, 1000);
    }

    [Fact]
    public void A_tiny_box_still_gets_a_real_font_size()
    {
        var content = ContentOf(Pdf(At("word", h: 1e-6)));
        var size = double.Parse(Regex.Match(content, @"/F1 ([\d.]+) Tf").Groups[1].Value, CultureInfo.InvariantCulture);
        Assert.True(size > 0, $"size {size}");
    }

    [Fact]
    public void Nothing_is_added_when_there_are_no_words()
    {
        var pdf = Pdf([new PdfPage(Jpeg, 300), new PdfPage(Jpeg, 300, [])]);
        Assert.DoesNotContain("/Font", pdf);
        Assert.DoesNotContain("FontFile2", pdf);
        XrefPointsAtObjects(pdf);
    }

    [Fact]
    public void One_font_serves_every_page_and_a_letter_keeps_its_code()
    {
        var pdf = Pdf([new PdfPage(Jpeg, 300, [At("Привет")]), new PdfPage(Jpeg, 300, [At("привет Привет", y: 100)]), new PdfPage(Jpeg, 300)]);
        Assert.Single(Regex.Matches(pdf, "/FontFile2"));
        var map = ToUnicode(pdf);
        Assert.Equal(map.Values.Count, map.Values.Distinct().Count());
        Assert.Equal(["Привет", "привет Привет"], Shown(pdf));
        XrefPointsAtObjects(pdf);
    }

    [Fact]
    public void A_large_alphabet_is_written_in_blocks_of_at_most_100()
    {
        var text = new StringBuilder();
        for (var c = 0x4E00; c < 0x4E00 + 750; c++) text.Append((char)c);
        var pdf = Pdf(At(text.ToString()));
        Assert.Equal(750, ToUnicode(pdf).Count);
        Assert.Equal([text.ToString()], Shown(pdf));
    }

    [Fact]
    public void A_cluster_no_map_should_hold_is_split_up()
    {
        // Zalgo: a base with many marks. A single entry that long is legal but unwise; each mark then gets its own code.
        var zalgo = "a" + new string('́', 200);
        var pdf = Pdf(At(zalgo));
        Assert.All(ToUnicode(pdf).Values, v => Assert.True(v.Length <= 32, $"{v.Length} units"));
        Assert.Equal([zalgo.Normalize(NormalizationForm.FormC)], Shown(pdf));
    }

    [Fact]
    public void Past_what_a_font_can_hold_the_file_is_still_valid()
    {
        // More different letters than two bytes can number, as a hostile list of words might give: the rest are left out, the file stays readable.
        var words = new List<OcrWord>();
        for (var c = 0x10000; c < 0x10000 + 70_000; c += 100)
        {
            var s = new StringBuilder();
            for (var k = 0; k < 100; k++)
                if (char.ConvertFromUtf32(c + k) is var one && char.GetUnicodeCategory(one, 0) != UnicodeCategory.OtherNotAssigned) s.Append(one);
            if (s.Length > 0) words.Add(At(s.ToString()));
        }
        var pdf = Pdf([new PdfPage(Jpeg, 300, words)]);
        Assert.True(ToUnicode(pdf).Count <= 65_535);
        Assert.All(Regex.Matches(pdf, @"<([0-9A-F]+)> Tj"), m => Assert.Equal(0, m.Groups[1].Length % 4));
        XrefPointsAtObjects(pdf);
    }

    [Fact]
    public void Each_stream_length_is_right()
    {
        var pdf = Pdf(At("Привет"), At("東京", y: 200));
        var checkedStreams = 0;
        foreach (Match m in Regex.Matches(pdf, @"/Length (\d+)[^\n]*>>\nstream\n"))
        {
            var length = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
            var start = m.Index + m.Length;
            Assert.Equal("\nendstream", pdf.Substring(start + length, "\nendstream".Length));
            checkedStreams++;
        }
        Assert.True(checkedStreams >= 5, $"{checkedStreams} streams"); // image, content, font program, CID map, unicode map
    }

    [Fact]
    public void The_font_program_is_a_well_formed_TrueType_font_whose_glyph_paints_nothing()
    {
        var pdf = Pdf(At("Привет"));
        var id = Regex.Match(pdf, @"/FontFile2 (\d+) 0 R").Groups[1].Value;
        var m = Regex.Match(pdf, $@"\n{id} 0 obj\n<< /Length (\d+) /Length1 (\d+) >>\nstream\n");
        Assert.True(m.Success);
        Assert.Equal(m.Groups[1].Value, m.Groups[2].Value);
        var ttf = Encoding.Latin1.GetBytes(pdf.Substring(m.Index + m.Length, int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)));

        Assert.Equal(0x00010000u, BinaryPrimitives.ReadUInt32BigEndian(ttf));
        var count = BinaryPrimitives.ReadUInt16BigEndian(ttf.AsSpan(4));
        var tables = new Dictionary<string, (int Offset, int Length)>();
        var previous = "";
        for (var i = 0; i < count; i++)
        {
            var entry = ttf.AsSpan(12 + 16 * i, 16);
            var tag = Encoding.ASCII.GetString(entry[..4]);
            Assert.True(string.CompareOrdinal(previous, tag) < 0, "tables must be sorted by tag");
            previous = tag;
            var (offset, length) = ((int)BinaryPrimitives.ReadUInt32BigEndian(entry[8..]), (int)BinaryPrimitives.ReadUInt32BigEndian(entry[12..]));
            Assert.Equal(0, offset % 4);
            Assert.InRange(offset + length, 0, ttf.Length);
            tables[tag] = (offset, length);
            if (tag != "head") Assert.Equal(BinaryPrimitives.ReadUInt32BigEndian(entry[4..]), Sum(ttf.AsSpan(offset, length)));
        }
        foreach (var required in new[] { "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post" }) Assert.Contains(required, tables.Keys);

        // The whole file sums to the magic number head's checkSumAdjustment makes it.
        Assert.Equal(0xB1B0AFBAu, Sum(ttf));
        var head = tables["head"].Offset;
        Assert.Equal(0x5F0F3CF5u, BinaryPrimitives.ReadUInt32BigEndian(ttf.AsSpan(head + 12)));
        Assert.Equal(1000, BinaryPrimitives.ReadUInt16BigEndian(ttf.AsSpan(head + 18)));

        // Glyph 1, which every code draws, encloses no area but has a real box (MuPDF drops text with empty bounds), and the width the PDF says.
        var loca = tables["loca"].Offset;
        var glyph = ttf.AsSpan(tables["glyf"].Offset + BinaryPrimitives.ReadUInt16BigEndian(ttf.AsSpan(loca + 2)) * 2);
        Assert.Equal(1, BinaryPrimitives.ReadInt16BigEndian(glyph));
        Assert.True(Field(glyph, 6) > Field(glyph, 2) && Field(glyph, 8) > Field(glyph, 4), "a box with an area");
        var points = Field(glyph, 10) + 1;
        var (x, y) = (0, 0);
        var corners = new List<(int X, int Y)>();
        for (var i = 0; i < points; i++)
        {
            x += Field(glyph, 14 + points + i * 2);
            y += Field(glyph, 14 + points + points * 2 + i * 2);
            corners.Add((x, y));
        }
        var area = 0;
        for (var i = 0; i < points; i++)
        {
            var (from, to) = (corners[i], corners[(i + 1) % points]);
            area += from.X * to.Y - to.X * from.Y;
        }
        Assert.Equal(0, area);
        var hmtx = tables["hmtx"].Offset;
        Assert.Equal(500, BinaryPrimitives.ReadUInt16BigEndian(ttf.AsSpan(hmtx + 4)));
        Assert.Contains("/DW 500", pdf);

        static short Field(ReadOnlySpan<byte> g, int at) => BinaryPrimitives.ReadInt16BigEndian(g[at..]);

        static uint Sum(ReadOnlySpan<byte> data)
        {
            uint sum = 0;
            for (var i = 0; i < data.Length; i += 4)
            {
                uint word = 0;
                for (var k = 0; k < 4; k++) word = (word << 8) | (i + k < data.Length ? data[i + k] : (byte)0);
                sum += word;
            }
            return sum;
        }
    }

    [Fact]
    public void Every_code_is_mapped_to_the_glyph_by_the_CID_map()
    {
        var pdf = Pdf(At("Привет"));
        var id = Regex.Match(pdf, @"/CIDToGIDMap (\d+) 0 R").Groups[1].Value;
        var m = Regex.Match(pdf, $@"\n{id} 0 obj\n<< /Length (\d+) >>\nstream\n");
        Assert.True(m.Success);
        var map = Encoding.Latin1.GetBytes(pdf.Substring(m.Index + m.Length, int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)));
        var highest = Regex.Matches(ContentOf(pdf), @"<([0-9A-F]+)> Tj").SelectMany(x => Convert.FromHexString(x.Groups[1].Value).Chunk(2))
            .Max(c => BinaryPrimitives.ReadUInt16BigEndian(c));
        Assert.Equal((highest + 1) * 2, map.Length);
        Assert.Equal(0, BinaryPrimitives.ReadUInt16BigEndian(map)); // code 0 is .notdef
        for (var i = 2; i < map.Length; i += 2) Assert.Equal(1, BinaryPrimitives.ReadUInt16BigEndian(map.AsSpan(i)));
    }

    [Fact]
    public void A_non_Latin_file_name_is_kept_in_the_title()
    {
        var pdf = Pdf([new PdfPage(Jpeg, 300)], "Счёт (март) 𠮷");
        var hex = Regex.Match(pdf, @"/Title <([0-9A-F]+)>").Groups[1].Value;
        Assert.StartsWith("FEFF", hex);
        Assert.Equal("Счёт (март) 𠮷", Encoding.BigEndianUnicode.GetString(Convert.FromHexString(hex[4..])));
    }

    [Fact]
    public void A_title_with_a_broken_character_stays_valid()
    {
        var pdf = Pdf([new PdfPage(Jpeg, 300)], "bad\uD83Dname\u0000)");
        var hex = Regex.Match(pdf, @"/Title <([0-9A-F]+)>").Groups[1].Value;
        Assert.Equal("badname)", Encoding.BigEndianUnicode.GetString(Convert.FromHexString(hex[4..])));
    }

    [Fact]
    public void Words_on_one_line_get_a_space_between_them_and_a_new_line_none()
    {
        var pdf = Pdf(At("one", x: 100, w: 200), At("two", x: 320, w: 200), At("three", x: 100, y: 500, w: 300));
        Assert.Equal(["one", " ", "two", "three"], Shown(pdf));
    }

    [Fact]
    public void Words_on_a_right_to_left_line_get_a_space_in_the_gap_to_their_left()
    {
        // The words of a right-to-left line come in reading order: the first is the one furthest right.
        var pdf = Pdf(At("שלום", x: 600, w: 200), At("עולם", x: 340, w: 200));
        Assert.Equal(["םולש", "םלוע "], Shown(pdf));
    }

    [Fact]
    public void Chinese_and_Japanese_words_on_one_line_run_together_with_no_gap()
    {
        var pdf = Pdf(At("東京", x: 100, w: 120), At("都庁", x: 230, w: 120), At("です", x: 360, w: 120));
        Assert.Equal(["東京", "都庁", "です"], Shown(pdf));
        // The first word is stretched up to the second, so no reader sees a gap to turn into a space.
        var tz = Regex.Matches(ContentOf(pdf), @"([\d.]+) Tz").Select(m => double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)).ToList();
        Assert.True(tz[0] > tz[2], $"{tz[0]} then {tz[2]}");
    }

    [Fact]
    public void Words_whose_boxes_touch_still_get_a_space()
    {
        Assert.Equal(["one", " ", "two"], Shown(Pdf(At("one", x: 100, w: 200), At("two", x: 300, w: 200))));
        Assert.Equal(["one", " ", "two"], Shown(Pdf(At("one", x: 100, w: 200), At("two", x: 295, w: 200))));
    }

    [Fact]
    public void A_CJK_word_and_a_Latin_word_still_get_a_space()
    {
        var pdf = Pdf(At("東京", x: 100, w: 120), At("Tokyo", x: 240, w: 200));
        Assert.Equal(["東京", " ", "Tokyo"], Shown(pdf));
    }

    private static void XrefPointsAtObjects(string pdf)
    {
        var startxref = int.Parse(pdf[(pdf.LastIndexOf("startxref\n", StringComparison.Ordinal) + 10)..].Split('\n')[0], CultureInfo.InvariantCulture);
        var lines = pdf[startxref..].Split('\n');
        Assert.Equal("xref", lines[0]);
        var count = int.Parse(lines[1].Split(' ')[1], CultureInfo.InvariantCulture);
        for (var id = 1; id < count; id++)
        {
            var entry = lines[2 + id];
            Assert.EndsWith(" n ", entry); // no holes in the numbering
            Assert.StartsWith($"{id} 0 obj", pdf[int.Parse(entry[..10], CultureInfo.InvariantCulture)..]);
        }
    }
}
