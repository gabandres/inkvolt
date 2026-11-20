using System.Security.Cryptography;
using System.Text;
using InkvoltPdf.Bench;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.OcrCorpus;

/// <summary>How a <see cref="PhotoFile"/>'s page was photographed.</summary>
public enum PhotoDamage
{
    /// <summary>At an angle, on a darker desk: the page a trapezoid.</summary>
    Trapezoid,

    /// <summary>Open in a book: lines bent towards the spine on the left, sagging and fanning out.</summary>
    Bent,
}

/// <param name="Page">The typeset page it starts from (its font, size and words; <see cref="ScanCorpus"/>'s first page of it).</param>
public sealed record PhotoFile(string Name, CorpusFile Page, PhotoDamage Damage)
{
    public string Describe() => Damage switch
    {
        PhotoDamage.Trapezoid => $"{Page.Font.TrimStart('/')} {Page.FontSize} pt, photographed at an angle on a grey desk",
        _ => $"{Page.Font.TrimStart('/')} {Page.FontSize} pt, a book's page: lines bent towards the spine",
    };
}

/// <summary>
/// Photographed pages for roadmap 2.2's trapezoid correction and straightened lines: a corpus page as typeset (no
/// damage but light noise), then put on a desk at an angle with a known map, or bent as an open book bends it with a
/// known shift. Deterministic, as <see cref="ScanCorpus"/>; nothing is committed.
/// </summary>
public static class PhotoCorpus
{
    public const int Dpi = ScanCorpus.Dpi;

    public static readonly IReadOnlyList<PhotoFile> Files =
    [
        new("en-trapezoid", ScanCorpus.Files[0], PhotoDamage.Trapezoid),
        new("es-trapezoid", ScanCorpus.Files[3], PhotoDamage.Trapezoid),
        new("en-book", ScanCorpus.Files[2], PhotoDamage.Bent),
        new("es-book", ScanCorpus.Files[4], PhotoDamage.Bent),
    ];

    /// <summary>The page's corners in the photo (clockwise from the top left) for a page of <paramref name="w"/> × <paramref name="h"/>: the camera tipped back, the top further away.</summary>
    public static (double X, double Y)[] Corners(int w, int h) =>
        [(0.16 * w, 0.09 * h), (0.86 * w, 0.075 * h), (0.95 * w, 0.93 * h), (0.06 * w, 0.95 * h)];

    /// <summary>
    /// How far down an open book moves a line (pixels) at (<paramref name="x"/>, <paramref name="y"/>) of a page of
    /// <paramref name="w"/> × <paramref name="h"/>: nothing at the outer edge (right), sagging towards the spine (left), and
    /// lines further apart there.
    /// </summary>
    public static double Sag(double x, double y, int w, int h)
    {
        var s = Math.Clamp(1 - x / w, 0, 1);
        return 0.25 * Dpi * s * s * s + 0.04 * s * s * (y - h / 2.0);
    }

    /// <summary>The photographed page (grey) and its words.</summary>
    public static (byte[] Pixels, int Width, int Height, List<string> Words) Photo(PhotoFile file)
    {
        var (clean, w, h, words) = ScanCorpus.CleanPage(file.Page, 0);
        var rng = new Rng(Seed(file.Name));
        var px = file.Damage == PhotoDamage.Trapezoid ? OnDesk(clean, w, h, Corners(w, h), ref rng) : Bend(clean, w, h, ref rng);
        return (px, w, h, words);
    }

    /// <summary>The photo as a one-page PDF (a grey JPEG at 300 dpi).</summary>
    public static byte[] Pdf(PhotoFile file)
    {
        var (px, w, h, _) = Photo(file);
        return ScanCorpus.ScanPdf(file.Page with { Name = file.Name }, [(JpegEncoder.EncodeGray(px, w, h, 80, Dpi), w, h)]);
    }

    /// <summary><paramref name="page"/> laid on a grey desk with its corners at <paramref name="corners"/> (the photo the page's size), lit a little unevenly, noisy.</summary>
    public static byte[] OnDesk(byte[] page, int w, int h, (double X, double Y)[] corners, ref Rng rng)
    {
        (double, double)[] square = [(0, 0), (w, 0), (w, h), (0, h)];
        var toPage = Homography.Between(corners, square)!;
        var result = new byte[w * h];
        var noise = new double[w * h];
        for (var i = 0; i < noise.Length; i++) noise[i] = (rng.NextDouble() - 0.5) * 16;
        Parallel.For(0, h, y =>
        {
            for (var x = 0; x < w; x++)
            {
                var (sx, sy) = toPage.Apply(x + 0.5, y + 0.5);
                double v;
                if (sx < 0 || sy < 0 || sx >= w || sy >= h) v = 70 + 25.0 * x / w; // the desk
                else
                {
                    var ink = Bilinear(page, w, h, sx - 0.5, sy - 0.5);
                    var paper = 228 - 20.0 * y / h; // further from the lamp at the bottom
                    v = 30 + (paper - 30) * ink / 255;
                }
                result[y * w + x] = (byte)Math.Clamp(Math.Round(v + noise[y * w + x]), 0, 255);
            }
        });
        return result;
    }

    /// <summary><paramref name="page"/> as an open book shows it: each column moved down by <see cref="Sag"/>, noisy.</summary>
    public static byte[] Bend(byte[] page, int w, int h, ref Rng rng)
    {
        var result = new byte[w * h];
        var noise = new double[w * h];
        for (var i = 0; i < noise.Length; i++) noise[i] = (rng.NextDouble() - 0.5) * 16;
        Parallel.For(0, h, y =>
        {
            for (var x = 0; x < w; x++)
            {
                // The content shown at y came from the y' that the sag moved here: y = y' + Sag(x, y'), solved by a few steps.
                var from = (double)y;
                for (var k = 0; k < 4; k++) from = y - Sag(x + 0.5, from, w, h);
                var ink = Bilinear(page, w, h, x, from - 0.5);
                var v = 30 + (232 - 30) * ink / 255;
                result[y * w + x] = (byte)Math.Clamp(Math.Round(v + noise[y * w + x]), 0, 255);
            }
        });
        return result;
    }

    private static double Bilinear(byte[] px, int w, int h, double x, double y)
    {
        var (x0, y0) = ((int)Math.Floor(x), (int)Math.Floor(y));
        var (fx, fy) = (x - x0, y - y0);
        double At(int a, int b) => a < 0 || b < 0 || a >= w || b >= h ? 255 : px[b * w + a];
        return (At(x0, y0) * (1 - fx) + At(x0 + 1, y0) * fx) * (1 - fy) + (At(x0, y0 + 1) * (1 - fx) + At(x0 + 1, y0 + 1) * fx) * fy;
    }

    private static ulong Seed(string name) => BitConverter.ToUInt64(SHA256.HashData(Encoding.ASCII.GetBytes("inkvolt-photo-" + name)), 0);
}
