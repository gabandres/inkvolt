using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>Synthetic PDFs for Word / Excel export: headings, paragraphs, a bullet list, a ruled table, an image, two columns.</summary>
internal static class ExportTestPdf
{
    public const string Para1 =
        "Inkvolt keeps every page on this computer. The viewer opens large files quickly and the organizer moves pages " +
        "around without changing their content. This paragraph runs over several lines so it has to be joined back.";

    public const string Para2 = "A second paragraph starts after a gap and ends on the same page.";

    public static readonly string[] Bullets = ["First point in the list", "Second point in the list", "Third point"];

    public static readonly string[][] Table =
    [
        ["Item", "Qty", "Price"],
        ["Apples", "4", "1.20"],
        ["Pears", "12", "3.05"],
        ["Plums", "7", "0.99"],
    ];

    /// <summary>
    /// Page 1: title, heading, two paragraphs, a bullet list, a ruled table and an image. Page 2: two columns.
    /// <paramref name="logo"/>: the same small logo at the top right of both pages, and an icon in the table's "Pears" row.
    /// </summary>
    public static byte[] Make(bool ruledTable = true, bool logo = false)
    {
        var logoPng = TestImages.Png(24, 12, (x, _) => (200, (byte)(x * 10), 40, 255));
        var iconPng = TestImages.Png(8, 8, (_, _) => (20, 160, 20, 255));
        void Logo(XGraphics gfx)
        {
            if (!logo) return;
            using var img = XImage.FromStream(new MemoryStream(logoPng));
            gfx.DrawImage(img, 492, 24, 48, 24);
        }
        TestPdf.UseFonts();
        using var doc = new PdfDocument();
        var title = new XFont("Arial", 24, XFontStyleEx.Bold);
        var heading = new XFont("Arial", 16, XFontStyleEx.Bold);
        var body = new XFont("Arial", 11);
        var italic = new XFont("Arial", 11, XFontStyleEx.Italic);

        var page = doc.AddPage();
        page.Width = XUnit.FromPoint(612);
        page.Height = XUnit.FromPoint(792);
        using (var gfx = XGraphics.FromPdfPage(page))
        {
            var y = 80.0;
            Logo(gfx);
            gfx.DrawString("Quarterly Report", title, XBrushes.Black, new XPoint(72, y));
            y += 40;
            gfx.DrawString("Summary", heading, XBrushes.Black, new XPoint(72, y));
            y += 24;
            y = Wrap(gfx, Para1, body, 72, y, 468);
            y += 10;
            gfx.DrawString("A second paragraph starts after a gap and ends on the ", body, XBrushes.Black, new XPoint(72, y));
            var w = gfx.MeasureString("A second paragraph starts after a gap and ends on the ", body).Width;
            gfx.DrawString("same page.", italic, XBrushes.Black, new XPoint(72 + w, y));
            y += 24;
            foreach (var b in Bullets)
            {
                gfx.DrawString("•", body, XBrushes.Black, new XPoint(84, y));
                gfx.DrawString(b, body, XBrushes.Black, new XPoint(100, y));
                y += 15;
            }
            y += 20;
            gfx.DrawString("Prices", heading, XBrushes.Black, new XPoint(72, y));
            y += 14;
            double[] cols = [72, 252, 342, 432];
            const double rowH = 20;
            var top = y;
            for (var r = 0; r < Table.Length; r++)
                for (var c = 0; c < 3; c++)
                    gfx.DrawString(Table[r][c], r == 0 ? new XFont("Arial", 11, XFontStyleEx.Bold) : body, XBrushes.Black,
                        new XPoint(cols[c] + 6, top + r * rowH + 14));
            if (ruledTable)
            {
                var pen = new XPen(XColors.Black, 0.75);
                for (var r = 0; r <= Table.Length; r++) gfx.DrawLine(pen, cols[0], top + r * rowH, cols[3], top + r * rowH);
                foreach (var x in cols) gfx.DrawLine(pen, x, top, x, top + Table.Length * rowH);
            }
            if (logo)
            {
                using var icon = XImage.FromStream(new MemoryStream(iconPng));
                gfx.DrawImage(icon, cols[0] + 60, top + 2 * rowH + 5, 10, 10);
            }
            y = top + Table.Length * rowH + 30;
            var png = TestImages.Png(40, 30, (x, yy) => ((byte)(x * 6), (byte)(yy * 8), 200, 255));
            using var img = XImage.FromStream(new MemoryStream(png));
            gfx.DrawImage(img, 72, y, 160, 120);
            gfx.DrawString("Figure 1. A picture.", body, XBrushes.Black, new XPoint(72, y + 136));
        }

        var page2 = doc.AddPage();
        page2.Width = XUnit.FromPoint(612);
        page2.Height = XUnit.FromPoint(792);
        using (var gfx = XGraphics.FromPdfPage(page2))
        {
            Logo(gfx);
            gfx.DrawString("Two Columns", heading, XBrushes.Black, new XPoint(72, 80));
            Wrap(gfx, "The left column talks about apples and how they grow in orchards on the hills around the town every autumn.", body, 72, 110, 216);
            Wrap(gfx, "The right column talks about pears, which ripen later and keep for weeks in a cool dark cellar room.", body, 324, 110, 216);
        }

        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    /// <summary>Draws <paramref name="text"/> word-wrapped to <paramref name="width"/>; returns the baseline after the last line.</summary>
    private static double Wrap(XGraphics gfx, string text, XFont font, double x, double y, double width)
    {
        var line = "";
        foreach (var word in text.Split(' '))
        {
            var next = line.Length == 0 ? word : line + " " + word;
            if (gfx.MeasureString(next, font).Width > width && line.Length > 0)
            {
                gfx.DrawString(line, font, XBrushes.Black, new XPoint(x, y));
                y += 14;
                line = word;
            }
            else line = next;
        }
        if (line.Length > 0) gfx.DrawString(line, font, XBrushes.Black, new XPoint(x, y));
        return y + 14;
    }
}
