using System.Text;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Tests;

/// <summary>
/// Batch scanning: patch code and blank separator sheets found on synthetic scans (a letter page at 100 dpi, 850 × 1100,
/// as the app analyses it), one feeder run split into files at them, and the printable separator sheet.
/// </summary>
public class BatchScanTests
{
    private const int W = 850, H = 1100;
    private const double Ppi = 100;

    private static byte[] Paper(byte level = 242, int seed = 1)
    {
        var random = new Random(seed);
        var pixels = new byte[W * H];
        for (var i = 0; i < pixels.Length; i++) pixels[i] = (byte)(level + random.Next(-6, 7));
        return pixels;
    }

    /// <summary>
    /// A patch drawn from <see cref="SeparatorSheet.Bars"/> at <paramref name="ppi"/>: bars <paramref name="length"/> inches long
    /// starting at (<paramref name="x"/>, <paramref name="y"/>) inches, running down the page (vertical) or across it, turned
    /// <paramref name="degrees"/> clockwise about the page centre. <paramref name="gain"/> widens every bar (and narrows every
    /// space) by that many inches, as toner spread or a photocopy does.
    /// </summary>
    private static GrayImage PatchPage(PatchCode code, double x = 3.5, double y = 3, double length = 3, bool vertical = true,
        double degrees = 0, double gain = 0, double ppi = Ppi, byte ink = 25)
    {
        var (w, h) = ((int)(8.5 * ppi), (int)(11 * ppi));
        var random = new Random(3);
        var pixels = new byte[w * h];
        for (var i = 0; i < pixels.Length; i++) pixels[i] = (byte)(242 + random.Next(-6, 7));
        var bars = SeparatorSheet.Bars(code);
        var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
        for (var py = 0; py < h; py++)
            for (var px = 0; px < w; px++)
            {
                // Where this pixel was on the straight page, in inches.
                var (dx, dy) = (px - w / 2.0, py - h / 2.0);
                var qx = (cos * dx + sin * dy + w / 2.0) / ppi;
                var qy = (-sin * dx + cos * dy + h / 2.0) / ppi;
                var (across, along) = vertical ? (qx - x, qy - y) : (qy - y, qx - x);
                if (along < 0 || along > length) continue;
                foreach (var (offset, width) in bars)
                    if (across >= offset - gain / 2 && across < offset + width + gain / 2) pixels[py * w + px] = ink;
            }
        return new GrayImage(w, h, pixels);
    }

    private static void Fill(byte[] pixels, int x, int y, int w, int h, byte level)
    {
        for (var yy = y; yy < y + h; yy++)
            for (var xx = x; xx < x + w; xx++)
                pixels[yy * W + xx] = level;
    }

    // ---- The patch codes themselves ----

    [Fact]
    public void Patch_bars_follow_the_kodak_spec()
    {
        // Two wide bars (0.20 in), two narrow bars (0.08 in), three narrow spaces (0.08 in): 0.80 in across.
        Assert.Equal([(0.0, 0.08), (0.16, 0.20), (0.44, 0.08), (0.60, 0.20)], Round(SeparatorSheet.Bars(PatchCode.PatchT)));
        Assert.Equal([(0.0, 0.20), (0.28, 0.08), (0.44, 0.08), (0.60, 0.20)], Round(SeparatorSheet.Bars(PatchCode.Patch2)));
        Assert.Equal([(0.0, 0.20), (0.28, 0.08), (0.44, 0.20), (0.72, 0.08)], Round(SeparatorSheet.Bars(PatchCode.Patch3)));
        foreach (var code in Enum.GetValues<PatchCode>())
        {
            var bars = SeparatorSheet.Bars(code);
            Assert.Equal(0.80, bars[^1].Offset + bars[^1].Width, 6);
            Assert.Equal(2, bars.Count(b => b.Width > 0.1));
        }

        static (double, double)[] Round(IReadOnlyList<(double Offset, double Width)> bars) =>
            [.. bars.Select(b => (Math.Round(b.Offset, 6), Math.Round(b.Width, 6)))];
    }

    [Theory]
    [InlineData(PatchCode.Patch1)]
    [InlineData(PatchCode.Patch2)]
    [InlineData(PatchCode.Patch3)]
    [InlineData(PatchCode.Patch4)]
    [InlineData(PatchCode.Patch6)]
    [InlineData(PatchCode.PatchT)]
    public void Reads_each_patch(PatchCode code) => Assert.Equal(code, PatchCodes.Find(PatchPage(code), Ppi));

    [Fact]
    public void Reads_patches_across_the_page_too() =>
        Assert.Equal(PatchCode.Patch2, PatchCodes.Find(PatchPage(PatchCode.Patch2, x: 2, y: 5, vertical: false), Ppi));

    [Theory]
    [InlineData(4)]
    [InlineData(-6)]
    public void Reads_a_sheet_fed_crooked(double degrees) =>
        Assert.Equal(PatchCode.PatchT, PatchCodes.Find(PatchPage(PatchCode.PatchT, degrees: degrees), Ppi));

    [Fact]
    public void Reads_a_photocopied_or_low_resolution_patch()
    {
        Assert.Equal(PatchCode.PatchT, PatchCodes.Find(PatchPage(PatchCode.PatchT, gain: 0.02), Ppi)); // bars spread
        Assert.Equal(PatchCode.PatchT, PatchCodes.Find(PatchPage(PatchCode.PatchT, gain: -0.015), Ppi)); // bars thin
        Assert.Equal(PatchCode.PatchT, PatchCodes.Find(PatchPage(PatchCode.PatchT, ppi: 72), 72)); // legal from the feeder
        Assert.Equal(PatchCode.PatchT, PatchCodes.Find(PatchPage(PatchCode.PatchT, ink: 110), Ppi)); // grey toner
    }

    [Fact]
    public void Upside_down_patch_t_reads_as_patch_3_and_still_separates()
    {
        var turned = PatchPage(PatchCode.PatchT, degrees: 180);

        Assert.Equal(PatchCode.Patch3, PatchCodes.Find(turned, Ppi)); // NWNW read backwards is WNWN
        Assert.Equal(SeparatorKind.PatchCode, Separators.Detect(turned, Ppi, SplitAt.PatchCode).Kind);
    }

    [Fact]
    public void Too_short_too_small_or_too_large_is_no_patch()
    {
        Assert.Null(PatchCodes.Find(PatchPage(PatchCode.PatchT, length: 0.5), Ppi)); // a fragment, not a 2 in patch
        Assert.Null(PatchCodes.Find(PatchPage(PatchCode.PatchT, ppi: 40), 100)); // at 40% size: 0.32 in across
        Assert.Null(PatchCodes.Find(PatchPage(PatchCode.PatchT, ppi: 200), 100)); // at twice the size: 1.6 in across
    }

    [Fact]
    public void Text_tables_and_bars_of_one_width_are_no_patch()
    {
        // Lines of words.
        var text = Paper();
        for (var row = 0; row < 30; row++)
            for (var x = 110; x < 740; x += 70) Fill(text, x, 150 + row * 24, 58, 8, 40);
        Assert.Null(PatchCodes.Find(new GrayImage(W, H, text), Ppi));

        // A table: thin rules every 0.5 in, with text in the cells.
        var table = Paper();
        for (var x = 100; x <= 700; x += 50) Fill(table, x, 200, 2, 600, 30);
        for (var y = 200; y <= 800; y += 30) Fill(table, 100, y, 600, 2, 30);
        Assert.Null(PatchCodes.Find(new GrayImage(W, H, table), Ppi));

        // Four bars of one width, spaced like a patch: two must be wide.
        var even = Paper();
        for (var i = 0; i < 4; i++) Fill(even, 300 + i * 20, 300, 12, 300, 25);
        Assert.Null(PatchCodes.Find(new GrayImage(W, H, even), Ppi));

        // A barcode: thin bars far below the patch's size.
        var barcode = Paper();
        for (var i = 0; i < 60; i++) Fill(barcode, 300 + i * 4, 300, i % 3 == 0 ? 2 : 1, 80, 25);
        Assert.Null(PatchCodes.Find(new GrayImage(W, H, barcode), Ppi));

        Assert.Null(PatchCodes.Find(new GrayImage(W, H, Paper(level: 70)), Ppi)); // a dark page
    }

    // ---- What counts as a separator ----

    [Fact]
    public void Separator_pages_by_mode()
    {
        var patchT = PatchPage(PatchCode.PatchT);
        var blank = new GrayImage(W, H, Paper());
        var text = new GrayImage(W, H, Paper());
        Fill(text.Pixels, 200, 300, 400, 10, 40);

        Assert.Equal(new SeparatorFound(SeparatorKind.PatchCode, PatchCode.PatchT), Separators.Detect(patchT, Ppi, SplitAt.PatchCode));
        Assert.Equal(SeparatorKind.None, Separators.Detect(blank, Ppi, SplitAt.PatchCode).Kind);
        Assert.Equal(SeparatorKind.BlankPage, Separators.Detect(blank, Ppi, SplitAt.BlankPage).Kind);
        Assert.Equal(SeparatorKind.None, Separators.Detect(patchT, Ppi, SplitAt.BlankPage).Kind);
        Assert.Equal(SeparatorKind.PatchCode, Separators.Detect(patchT, Ppi, SplitAt.PatchCodeOrBlankPage).Kind);
        Assert.Equal(SeparatorKind.BlankPage, Separators.Detect(blank, Ppi, SplitAt.PatchCodeOrBlankPage).Kind);
        Assert.Equal(SeparatorKind.None, Separators.Detect(text, Ppi, SplitAt.PatchCodeOrBlankPage).Kind);
        Assert.Equal(SeparatorKind.None, Separators.Detect(patchT, Ppi, SplitAt.None).Kind);
    }

    [Theory]
    [InlineData(PatchCode.Patch1)]
    [InlineData(PatchCode.Patch4)]
    [InlineData(PatchCode.Patch6)]
    public void Image_control_patches_are_not_separators(PatchCode code) =>
        Assert.Equal(SeparatorKind.None, Separators.Detect(PatchPage(code), Ppi, SplitAt.PatchCode).Kind);

    // ---- Splitting a run into files ----

    private static BatchPage P => new(false, false, false);
    private static BatchPage S => new(true, false, false);
    private static BatchPage Start => new(false, true, false);
    private static BatchPage Skip => new(false, false, true);

    [Fact]
    public void Splits_at_each_separator_and_drops_it()
    {
        int[][] parts = [.. BatchSplit.Parts([P, P, S, P, S, P, P, P], keepSeparators: false).Select(p => p.ToArray())];

        Assert.Equal([[0, 1], [3], [5, 6, 7]], parts);
    }

    [Fact]
    public void Kept_separators_start_the_next_file()
    {
        int[][] parts = [.. BatchSplit.Parts([P, S, P, P, S, P], keepSeparators: true).Select(p => p.ToArray())];

        Assert.Equal([[0], [1, 2, 3], [4, 5]], parts);
    }

    [Fact]
    public void Leading_trailing_and_repeated_separators_make_no_empty_files()
    {
        Assert.Equal([[2, 3], [6]], BatchSplit.Parts([S, S, P, P, S, S, P, S], keepSeparators: false).Select(p => p.ToArray()));
        // Kept: in front of the next page; the last ones (no page after them) end the last file.
        Assert.Equal([[0, 1, 2, 3], [4, 5, 6, 7]], BatchSplit.Parts([S, S, P, P, S, S, P, S], keepSeparators: true).Select(p => p.ToArray()));
        Assert.Empty(BatchSplit.Parts([S, S], keepSeparators: true));
        Assert.Empty(BatchSplit.Parts([], keepSeparators: false));
    }

    [Fact]
    public void Split_points_set_by_hand_and_skipped_pages()
    {
        // A page marked "starts a new file", and a blank page skipped (not a separator) in between.
        Assert.Equal([[0, 1], [3, 4], [6]], BatchSplit.Parts([P, P, Skip, Start, P, S, P], keepSeparators: false).Select(p => p.ToArray()));
        Assert.Equal([[0, 1, 2]], BatchSplit.Parts([Start, P, P], keepSeparators: false).Select(p => p.ToArray())); // first page: nothing to split from
        Assert.Equal([[0], [1, 2]], BatchSplit.Parts([P, S, Start], keepSeparators: true).Select(p => p.ToArray())); // after a separator: one split
        Assert.Equal([[0, 1, 3]], BatchSplit.Parts([P, P, Skip, P], keepSeparators: false).Select(p => p.ToArray()));
    }

    [Fact]
    public void Split_points_are_reported_per_page()
    {
        var starts = BatchSplit.FileStarts([P, P, S, P, Start, P, S], keepSeparators: false);

        Assert.Equal([1, 0, 0, 2, 3, 0, 0], starts); // the file each page begins (0: none)
        Assert.Equal([1, 0, 2, 0, 0], BatchSplit.FileStarts([P, P, S, P, P], keepSeparators: true));
    }

    [Fact]
    public void Presets_keep_their_split_and_repair_unknown_ones()
    {
        var stored = new Core.Presets.ScanPresetSettings
        {
            Items =
            [
                new() { Id = "batch", Name = "Batch", SplitAt = SplitAt.PatchCode, KeepSeparators = true },
                new() { Id = "newer", Name = "Newer", SplitAt = (SplitAt)42 },
            ],
        };

        var presets = Core.Presets.ScanPresets.Normalize(stored);

        Assert.Equal(SplitAt.PatchCode, presets[0].SplitAt);
        Assert.True(presets[0].KeepSeparators);
        Assert.Equal(SplitAt.None, presets[1].SplitAt);
        Assert.Contains("a new file at each patch code sheet", Core.Presets.ScanPresetText.Summary(presets[0]));
        Assert.DoesNotContain("new file", Core.Presets.ScanPresetText.Summary(presets[1]));
    }

    [Fact]
    public void Two_sided_runs_give_a_patch_sheets_other_side_to_the_sheet()
    {
        // Front, back pairs (an even run): the patch sheet's back goes with it even when show-through makes it look printed.
        Assert.Equal([3], BatchSplit.DuplexSeparatorBacks([false, false, true, false, false, false], [false, true, false, false, false, true]));
        // Laid face down: the patch on the back, its front goes with it.
        Assert.Equal([2], BatchSplit.DuplexSeparatorBacks([false, false, false, true], [false, false, false, false]));
        // An odd run (a side dropped): the pairing isn't known, so only a back that looks blank.
        Assert.Empty(BatchSplit.DuplexSeparatorBacks([false, false, true, false, false], [false, false, false, false, false]));
        Assert.Equal([3], BatchSplit.DuplexSeparatorBacks([false, false, true, false, false], [false, false, false, true, false]));
        Assert.Empty(BatchSplit.DuplexSeparatorBacks([true, true], [false, false])); // both sides patch sheets already
    }

    [Fact]
    public void A_retry_after_a_partial_save_skips_the_files_already_written()
    {
        var (a, b, c) = (new object(), new object(), new object());
        var saved = new Core.Presets.SavedParts<object>();
        saved.Add([a, b], ["Doc 1.pdf"]);

        Assert.Equal(["Doc 1.pdf"], saved.Find([a, b]));
        Assert.Null(saved.Find([c]));
        Assert.Null(saved.Find([b, a])); // reordered: a different file now
        Assert.Null(saved.Find([a]));
        saved.Clear();
        Assert.Null(saved.Find([a, b]));
    }

    [Fact]
    public void Each_file_gets_its_own_number_even_when_the_preset_is_gone()
    {
        var reserved = new Core.Presets.PartNumbers(5);
        Assert.Equal([7, 8], new[] { reserved.Take(7), reserved.Take(8) });

        var deleted = new Core.Presets.PartNumbers(5);
        Assert.Equal([5, 6, 7], new[] { deleted.Take(null), deleted.Take(null), deleted.Take(null) });

        var midway = new Core.Presets.PartNumbers(5); // deleted after the first file took 9
        Assert.Equal([9, 10], new[] { midway.Take(9), midway.Take(null) });
    }

    // ---- The printable separator sheet ----

    [Fact]
    public void Separator_sheet_is_a_one_page_vector_pdf_with_the_patch()
    {
        using var ms = new MemoryStream();
        SeparatorSheet.Write(ms, PatchCode.PatchT, 8.5, 11);
        var pdf = Encoding.Latin1.GetString(ms.ToArray());

        Assert.StartsWith("%PDF-1.4", pdf);
        Assert.Contains("/MediaBox [0 0 612 792]", pdf);
        Assert.Contains("/Count 1", pdf);
        Assert.Contains("(Patch T)", pdf);
        Assert.EndsWith("%%EOF\n", pdf);
        // The bars at their exact widths: 0.08 in = 5.76 pt, 0.20 in = 14.4 pt.
        Assert.Contains(" 5.76 ", pdf);
        Assert.Contains(" 14.4 ", pdf);
        Assert.DoesNotContain("/Image", pdf);
    }

    [Fact]
    public void Separator_sheet_layout_reads_back_as_its_patch()
    {
        // Every bar the sheet draws (in inches on the page), rendered at 100 dpi, is read as the sheet's patch.
        foreach (var code in new[] { PatchCode.PatchT, PatchCode.Patch2 })
        {
            var pixels = Paper();
            foreach (var r in SeparatorSheet.Layout(code, 8.5, 11))
                Fill(pixels, (int)Math.Round(r.X * Ppi), (int)Math.Round(r.Y * Ppi), (int)Math.Round(r.Width * Ppi), (int)Math.Round(r.Height * Ppi), 25);
            Assert.Equal(code, PatchCodes.Find(new GrayImage(W, H, pixels), Ppi));
        }
    }
}
