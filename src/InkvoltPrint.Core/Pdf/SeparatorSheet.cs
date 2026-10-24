using System.Globalization;
using System.Text;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Core.Pdf;

/// <summary>A filled rectangle on a sheet, in inches from the top-left corner.</summary>
public readonly record struct SheetRect(double X, double Y, double Width, double Height);

/// <summary>
/// A printable separator sheet: one page with a patch code at its exact size (vector bars, <see cref="PatchCodes"/> geometry)
/// in the middle, running down the page, with a clear zone around it, and a few lines of text above and below saying what it
/// is and how to use it. Printed at actual size it is read by Inkvolt Print's batch scanning (and by scanners that read patch
/// codes themselves).
/// </summary>
public static class SeparatorSheet
{
    /// <summary>How long the bars are: twice the spec's 2 in minimum, so a sheet fed off-centre still shows enough.</summary>
    public const double BarLength = 4;

    /// <summary>The four bars across the patch: offset from its edge and width, in inches, in reading order.</summary>
    public static IReadOnlyList<(double Offset, double Width)> Bars(PatchCode code)
    {
        var bars = new List<(double, double)>(4);
        var x = 0.0;
        foreach (var c in PatchCodes.Pattern(code))
        {
            var width = c == 'W' ? PatchCodes.Wide : PatchCodes.Narrow;
            bars.Add((x, width));
            x += width + PatchCodes.Narrow;
        }
        return bars;
    }

    /// <summary>The bars on a <paramref name="widthIn"/> × <paramref name="heightIn"/> inch sheet: centred, a little above the middle.</summary>
    public static IReadOnlyList<SheetRect> Layout(PatchCode code, double widthIn, double heightIn)
    {
        var left = (widthIn - PatchCodes.Size) / 2;
        var top = (heightIn - BarLength) / 2 - 0.25;
        return [.. Bars(code).Select(b => new SheetRect(left + b.Offset, top, b.Width, BarLength))];
    }

    /// <summary>Writes the sheet as a one-page PDF (<paramref name="widthIn"/> × <paramref name="heightIn"/> inches: Letter or A4).</summary>
    public static void Write(Stream output, PatchCode code, double widthIn, double heightIn)
    {
        var (w, h) = (widthIn * 72, heightIn * 72);
        var content = new StringBuilder();
        var bars = Layout(code, widthIn, heightIn);
        content.Append("0 g\n");
        foreach (var r in bars)
            content.Append(CultureInfo.InvariantCulture, $"{F(r.X * 72)} {F(h - (r.Y + r.Height) * 72)} {F(r.Width * 72)} {F(r.Height * 72)} re f\n");

        var name = PatchCodes.Name(code);
        var top = bars[0].Y * 72;               // points from the top: text stays an inch clear of the bars
        var bottom = (bars[0].Y + BarLength) * 72;
        Text(content, w, h - 72, 26, "Separator sheet");
        Text(content, w, h - 104, 18, name);
        Text(content, w, h - Math.Min(top - 72, 150), 11, "Inkvolt Print starts a new file at this sheet.");
        Text(content, w, 72 * 2.1, 11, "Put a copy in front of each document in the feeder, face up like the pages.");
        Text(content, w, 72 * 2.1 - 16, 11, "On the Scan tab, choose \"Split into files at: Patch codes\".");
        Text(content, w, 72 * 2.1 - 40, 9, "Print at actual size (100%, not \"fit to page\"), in black. Keep the area around the bars clean.");
        Text(content, w, 72 * 2.1 - 54, 9, "Reuse the sheet rather than copying it: copiers widen bars. Scanned sheets are left out unless you keep them.");
        if (h - bottom < 72 * 2.1 + 72) throw new ArgumentException("Sheet too short for the patch and its text", nameof(heightIn));

        PdfWriter.WriteDrawing(output, w, h, content.ToString(), $"Separator sheet ({name})");
    }

    /// <summary>A centred line of Helvetica, its baseline <paramref name="y"/> points from the bottom.</summary>
    private static void Text(StringBuilder content, double pageWidth, double y, double size, string text)
    {
        var width = 0.5 * size * text.Length; // Helvetica averages about half an em per character
        content.Append(CultureInfo.InvariantCulture,
            $"BT /F1 {F(size)} Tf {F(Math.Max(36, (pageWidth - width) / 2))} {F(y)} Td ({PdfWriter.Escape(text)}) Tj ET\n");
    }

    private static string F(double d) => PdfWriter.F(d);
}
