using System.Diagnostics;
using System.Text;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;
using ZXing;
using ZXing.QrCode;

namespace InkvoltPrint.Tests;

/// <summary>
/// Separator sheets marked with a code saying PATCHT (<see cref="SeparatorCodes"/>): a QR code or a barcode, on synthetic scans
/// of a letter page at 100 dpi (850 × 1100, as the app analyses it), and the QR code on the printable sheet. Hostile pages: one
/// crowded with QR corner squares, one far too large, one whose pixels don't match its size.
/// </summary>
public class SeparatorCodeTests
{
    private const int W = 850, H = 1100;
    private const double Ppi = 100;

    private static byte[] Paper(int w = W, int h = H)
    {
        var random = new Random(5);
        var pixels = new byte[w * h];
        for (var i = 0; i < pixels.Length; i++) pixels[i] = (byte)(242 + random.Next(-6, 7));
        return pixels;
    }

    /// <summary>
    /// <paramref name="modules"/> (true for dark, [row, column]) drawn <paramref name="size"/> inches across with their top-left
    /// corner at (<paramref name="x"/>, <paramref name="y"/>) inches, turned <paramref name="degrees"/> clockwise about the page centre.
    /// </summary>
    private static GrayImage Page(bool[,] modules, double x, double y, double size, double degrees = 0, double height = 0)
    {
        var pixels = Paper();
        Draw(pixels, modules, x, y, size, degrees, height);
        return new GrayImage(W, H, pixels);
    }

    private static void Draw(byte[] pixels, bool[,] modules, double x, double y, double size, double degrees = 0, double height = 0)
    {
        var (rows, columns) = (modules.GetLength(0), modules.GetLength(1));
        var module = size / columns;
        var rowHeight = height > 0 ? height / rows : module;
        var (sin, cos) = Math.SinCos(degrees * Math.PI / 180);
        for (var py = 0; py < H; py++)
            for (var px = 0; px < W; px++)
            {
                var (dx, dy) = (px - W / 2.0, py - H / 2.0);
                var qx = (cos * dx + sin * dy + W / 2.0) / Ppi - x;
                var qy = (-sin * dx + cos * dy + H / 2.0) / Ppi - y;
                if (qx < 0 || qy < 0) continue;
                var (c, r) = ((int)(qx / module), (int)(qy / rowHeight));
                if (r < rows && c < columns && modules[r, c]) pixels[py * W + px] = 25;
            }
    }

    private static bool[,] Qr(string text)
    {
        var matrix = new QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, new Dictionary<EncodeHintType, object> { [EncodeHintType.MARGIN] = 0 });
        var modules = new bool[matrix.Height, matrix.Width];
        for (var r = 0; r < matrix.Height; r++)
            for (var c = 0; c < matrix.Width; c++)
                modules[r, c] = matrix[c, r];
        return modules;
    }

    /// <summary>A barcode's bars as one row of modules (drawn tall with <see cref="Draw"/>'s height).</summary>
    private static bool[,] Bars(BarcodeFormat format, string text)
    {
        var matrix = new MultiFormatWriter().encode(text, format, 0, 1, new Dictionary<EncodeHintType, object> { [EncodeHintType.MARGIN] = 0 });
        var modules = new bool[1, matrix.Width];
        for (var c = 0; c < matrix.Width; c++) modules[0, c] = matrix[c, 0];
        return modules;
    }

    // ---- Reading ----

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(-30)]
    public void A_QR_code_saying_PATCHT_is_a_separator_sheet_however_it_was_fed(double degrees)
    {
        var page = Page(SeparatorCodes.QrModules(), 3.5, 4, 1.25, degrees);

        Assert.Equal(SeparatorKind.QrCode, SeparatorCodes.Find(page));
        Assert.Equal(new SeparatorFound(SeparatorKind.QrCode), Separators.Detect(page, Ppi, SplitAt.PatchCode));
        Assert.Equal(SeparatorKind.QrCode, Separators.Detect(page, Ppi, SplitAt.PatchCodeOrBlankPage).Kind);
        Assert.Equal(SeparatorKind.None, Separators.Detect(page, Ppi, SplitAt.BlankPage).Kind); // not blank either
        Assert.Equal(SeparatorKind.None, Separators.Detect(page, Ppi, SplitAt.None).Kind);
    }

    [Theory]
    [InlineData("patcht")]       // any case, as Paperless-ngx compares
    [InlineData(" PATCHT ")]
    public void The_text_is_read_loosely(string text) =>
        Assert.Equal(SeparatorKind.QrCode, SeparatorCodes.Find(Page(Qr(text), 3, 3, 1.5)));

    [Theory]
    [InlineData("https://example.com/invoice/123")] // an invoice's QR code
    [InlineData("PATCH T")]
    [InlineData("PATCHT PATCHT")]
    public void A_QR_code_saying_anything_else_separates_nothing(string text)
    {
        var page = Page(Qr(text), 3, 3, 1.5);

        Assert.Null(SeparatorCodes.Find(page));
        Assert.Equal(SeparatorKind.None, Separators.Detect(page, Ppi, SplitAt.PatchCode).Kind);
    }

    [Theory]
    [InlineData(BarcodeFormat.CODE_128, 0)]
    [InlineData(BarcodeFormat.CODE_39, 0)]
    [InlineData(BarcodeFormat.CODE_128, 90)]
    public void A_barcode_saying_PATCHT_is_a_separator_sheet(BarcodeFormat format, double degrees)
    {
        var page = Page(Bars(format, "PATCHT"), 2.5, 4, 3, degrees, height: 1);

        Assert.Equal(SeparatorKind.Barcode, SeparatorCodes.Find(page));
        Assert.Equal("barcode sheet", Separators.Detect(page, Ppi, SplitAt.PatchCode).Description);
        Assert.Null(SeparatorCodes.Find(Page(Bars(format, "INVOICE7"), 2.5, 4, 3, degrees, height: 1)));
    }

    [Fact]
    public void Blank_text_and_dark_pages_have_no_code()
    {
        var text = Paper();
        for (var y = 200; y < 900; y += 30)
            for (var x = 100; x < 750; x++)
                if (x % 9 < 5) for (var dy = 0; dy < 12; dy++) text[(y + dy) * W + x] = 30;

        Assert.Null(SeparatorCodes.Find(new GrayImage(W, H, Paper())));
        Assert.Null(SeparatorCodes.Find(new GrayImage(W, H, text)));
        Assert.Null(SeparatorCodes.Find(new GrayImage(W, H, new byte[W * H])));
    }

    [Fact]
    public void A_QR_codes_other_side_belongs_to_the_sheet_in_a_two_sided_run()
    {
        Assert.True(new SeparatorFound(SeparatorKind.QrCode).IsSheet);
        Assert.True(new SeparatorFound(SeparatorKind.Barcode).IsSheet);
        Assert.True(new SeparatorFound(SeparatorKind.PatchCode, PatchCode.PatchT).IsSheet);
        Assert.False(new SeparatorFound(SeparatorKind.BlankPage).IsSheet);
        Assert.False(new SeparatorFound(SeparatorKind.ByHand).IsSheet);
        Assert.False(new SeparatorFound(SeparatorKind.SheetBack).IsSheet);
    }

    // ---- Hostile pages ----

    [Fact]
    public void A_page_crowded_with_corner_squares_is_not_searched()
    {
        // Rows of 1:1:3:1:1 marks, 7 pixels a mark, over the whole page: tens of thousands of finder candidates.
        var pixels = Paper();
        for (var y = 0; y < H; y++)
            for (var x = 0; x < W; x++)
            {
                var (cx, cy) = (x % 9, y % 9);
                var ring = Math.Max(Math.Abs(cx - 3), Math.Abs(cy - 3));
                if (cx < 7 && cy < 7 && ring != 2) pixels[y * W + x] = 20;
            }
        var page = new GrayImage(W, H, pixels);
        var binarizer = new ZXing.Common.HybridBinarizer(new RGBLuminanceSource(pixels, W, H, RGBLuminanceSource.BitmapFormat.Gray8));

        Assert.True(SeparatorCodes.FinderMarks(binarizer.BlackMatrix) > SeparatorCodes.MaxFinderMarks);
        var clock = Stopwatch.StartNew();
        Assert.Null(SeparatorCodes.Find(page));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10), $"took {clock.Elapsed}");
    }

    [Fact]
    public void A_real_QR_code_has_few_corner_squares()
    {
        var page = Page(SeparatorCodes.QrModules(), 3.5, 4, 1.25);
        var binarizer = new ZXing.Common.HybridBinarizer(new RGBLuminanceSource(page.Pixels, W, H, RGBLuminanceSource.BitmapFormat.Gray8));

        Assert.InRange(SeparatorCodes.FinderMarks(binarizer.BlackMatrix), 30, 300);
    }

    [Fact]
    public void A_very_large_page_is_read_reduced()
    {
        // 300 dpi letter, 2550 × 3300: read at a third of that.
        const int w = 2550, h = 3300;
        var pixels = Paper(w, h);
        var modules = SeparatorCodes.QrModules();
        var module = 1.25 * 300 / modules.GetLength(1);
        for (var y = 0; y < (int)(1.25 * 300); y++)
            for (var x = 0; x < (int)(1.25 * 300); x++)
                if (modules[(int)(y / module), (int)(x / module)]) pixels[(1200 + y) * w + 1000 + x] = 25;

        Assert.Equal(SeparatorKind.QrCode, SeparatorCodes.Find(new GrayImage(w, h, pixels)));
    }

    [Fact]
    public void Pixels_that_dont_match_the_size_or_a_tiny_page_are_no_code()
    {
        Assert.Null(SeparatorCodes.Find(new GrayImage(W, H, new byte[10])));
        Assert.Null(SeparatorCodes.Find(new GrayImage(10, 10, new byte[100])));
        Assert.Null(SeparatorCodes.Find(new GrayImage(0, 0, [])));
    }

    // ---- The printed sheet ----

    [Theory]
    [InlineData(8.5, 11)]
    [InlineData(210 / 25.4, 297 / 25.4)]
    public void The_sheets_QR_code_reads_back_beside_its_patch(double width, double height)
    {
        var (w, h) = ((int)(width * Ppi), (int)(height * Ppi));
        var pixels = Paper(w, h);
        void Fill(SheetRect r)
        {
            for (var y = (int)Math.Round(r.Y * Ppi); y < (int)Math.Round((r.Y + r.Height) * Ppi); y++)
                for (var x = (int)Math.Round(r.X * Ppi); x < (int)Math.Round((r.X + r.Width) * Ppi); x++)
                    pixels[y * w + x] = 25;
        }
        foreach (var r in SeparatorSheet.Layout(PatchCode.PatchT, width, height)) Fill(r);
        var qr = SeparatorSheet.QrLayout(width, height);
        foreach (var r in qr) Fill(r);
        var page = new GrayImage(w, h, pixels);

        // Both read: the patch where the sheet's bars are, the QR code with them on the page.
        Assert.Equal(PatchCode.PatchT, PatchCodes.Find(page, Ppi));
        Assert.Equal(SeparatorKind.QrCode, SeparatorCodes.Find(page));
        // Clear of the bars' clear zone (0.8 in), inside the page with its quiet zone (4 modules).
        var bars = SeparatorSheet.Layout(PatchCode.PatchT, width, height);
        Assert.True(bars.Min(b => b.X) - qr.Max(r => r.X + r.Width) >= 0.8);
        Assert.True(qr.Min(r => r.X) >= 0.5 && qr.Min(r => r.Y) > 2.5);

        // Bars cut away, the QR code alone still makes the sheet a separator.
        var qrOnly = Paper(w, h);
        pixels = qrOnly;
        foreach (var r in qr) Fill(r);
        Assert.Equal(SeparatorKind.QrCode, Separators.Detect(new GrayImage(w, h, qrOnly), Ppi, SplitAt.PatchCode).Kind);
    }

    [Fact]
    public void The_sheet_pdf_draws_the_QR_code()
    {
        using var ms = new MemoryStream();
        SeparatorSheet.Write(ms, PatchCode.PatchT, 8.5, 11);
        var pdf = Encoding.Latin1.GetString(ms.ToArray());
        var rects = pdf.Split('\n').Count(l => l.EndsWith(" re f", StringComparison.Ordinal));

        Assert.Equal(4 + SeparatorSheet.QrLayout(8.5, 11).Count, rects);
        Assert.Contains("Patch or QR codes", pdf);
    }

    [Fact]
    public void The_QR_code_is_version_1_at_the_highest_correction()
    {
        var modules = SeparatorCodes.QrModules();

        Assert.Equal(21, modules.GetLength(0));
        Assert.Equal(21, modules.GetLength(1));
    }
}
