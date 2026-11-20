using ZXing;
using ZXing.Common;
using ZXing.OneD;
using ZXing.QrCode;
using ZXing.QrCode.Internal;

namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// Separator sheets marked with a code that says PATCHT: a QR code (the one on Inkvolt Print's own sheet, and Paperless-ngx's
/// separator pages, whose default text it is), or a Code 128 or Code 39 barcode. Read and written through ZXing.Net
/// (Apache-2.0). The page is read as it is, so it may be fed either way round and turned; a code saying anything else (an
/// invoice's QR code, a parcel label) separates nothing.
/// <para>
/// A scan is hostile input: a copy larger than <see cref="MaxSide"/> is read reduced, and a page crowded with marks shaped
/// like a QR code's corner squares (more than <see cref="MaxFinderMarks"/>) isn't searched for one, since the search's time
/// grows with the cube of their number; such a page is no separator sheet anyway.
/// </para>
/// </summary>
public static class SeparatorCodes
{
    /// <summary>What a separator's code says (Patch T's name, as Paperless-ngx writes it).</summary>
    public const string Text = "PATCHT";

    /// <summary>The longest side read; a larger copy is reduced first (the app's analysis copy is 1,100 pixels).</summary>
    public const int MaxSide = 1700;

    /// <summary>Most marks shaped like a QR code's corner square (dark, light, dark three times as wide, light, dark) a page may have.</summary>
    public const int MaxFinderMarks = 3000;

    /// <summary>The kind of code on the page that says <see cref="Text"/>: <see cref="SeparatorKind.QrCode"/>, <see cref="SeparatorKind.Barcode"/>, or null.</summary>
    public static SeparatorKind? Find(GrayImage img)
    {
        if (img.Width < 21 || img.Height < 21 || img.Pixels.Length != img.Width * img.Height) return null;
        try
        {
            var (pixels, w, h) = Reduced(img);
            var source = new RGBLuminanceSource(pixels, w, h, RGBLuminanceSource.BitmapFormat.Gray8);
            var binarizer = new HybridBinarizer(source);
            if (FinderMarks(binarizer.BlackMatrix) <= MaxFinderMarks
                && Says(new QRCodeReader().decode(new BinaryBitmap(binarizer), Hints(BarcodeFormat.QR_CODE))))
                return SeparatorKind.QrCode;
            var lines = Hints(BarcodeFormat.CODE_128, BarcodeFormat.CODE_39);
            if (Says(new MultiFormatOneDReader(lines).decode(new BinaryBitmap(new HybridBinarizer(source)), lines)))
                return SeparatorKind.Barcode;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            // A page ZXing can't make sense of has no code on it.
        }
        return null;
    }

    /// <summary>
    /// The QR code of <see cref="Text"/> as its modules, true for dark, <c>[row, column]</c>, without its quiet zone (four
    /// modules of white around it). The highest error correction (H, 30%), so smudges and a punched hole still read.
    /// </summary>
    public static bool[,] QrModules()
    {
        var matrix = new QRCodeWriter().encode(Text, BarcodeFormat.QR_CODE, 0, 0, new Dictionary<EncodeHintType, object>
        {
            [EncodeHintType.ERROR_CORRECTION] = ErrorCorrectionLevel.H,
            [EncodeHintType.MARGIN] = 0,
        });
        var modules = new bool[matrix.Height, matrix.Width];
        for (var y = 0; y < matrix.Height; y++)
            for (var x = 0; x < matrix.Width; x++)
                modules[y, x] = matrix[x, y];
        return modules;
    }

    private static bool Says(Result? result) =>
        result?.Text is { Length: <= 64 } text && string.Equals(text.Trim(), Text, StringComparison.OrdinalIgnoreCase);

    private static Dictionary<DecodeHintType, object> Hints(params BarcodeFormat[] formats) => new()
    {
        [DecodeHintType.POSSIBLE_FORMATS] = formats.ToList(),
        [DecodeHintType.TRY_HARDER] = true,
    };

    /// <summary>The image, reduced by a whole factor (the average of each square) until its longer side is at most <see cref="MaxSide"/>.</summary>
    private static (byte[] Pixels, int Width, int Height) Reduced(GrayImage img)
    {
        var k = (Math.Max(img.Width, img.Height) + MaxSide - 1) / MaxSide;
        if (k <= 1) return (img.Pixels, img.Width, img.Height);
        var (w, h) = (img.Width / k, img.Height / k);
        var pixels = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var sum = 0;
                for (var dy = 0; dy < k; dy++)
                    for (var dx = 0; dx < k; dx++)
                        sum += img.Pixels[(y * k + dy) * img.Width + x * k + dx];
                pixels[y * w + x] = (byte)(sum / (k * k));
            }
        return (pixels, w, h);
    }

    /// <summary>
    /// How many times a row of the black-and-white page crosses a mark in a QR corner square's proportions (1:1:3:1:1, each
    /// within half a module, as ZXing's own finder judges them); counting stops just past <see cref="MaxFinderMarks"/>.
    /// </summary>
    internal static int FinderMarks(BitMatrix matrix)
    {
        var count = 0;
        Span<int> runs = stackalloc int[5];
        for (var y = 0; y < matrix.Height; y++)
        {
            // The last five runs, dark first: shifted along as each run ends.
            runs.Clear();
            var filled = 0;
            var x = 0;
            while (x < matrix.Width && !matrix[x, y]) x++;
            while (x < matrix.Width)
            {
                var dark = matrix[x, y];
                var start = x;
                while (x < matrix.Width && matrix[x, y] == dark) x++;
                runs[..4].CopyTo(runs[1..]);
                runs[0] = x - start;
                filled++;
                // runs[0] is the newest; a mark is dark-light-dark-light-dark, so it ends on a dark run.
                if (dark && filled >= 5 && LooksLikeFinder(runs) && ++count > MaxFinderMarks) return count;
            }
        }
        return count;
    }

    private static bool LooksLikeFinder(ReadOnlySpan<int> r)
    {
        var total = r[0] + r[1] + r[2] + r[3] + r[4];
        if (total < 7) return false;
        var module = total / 7.0;
        var variance = module / 2;
        return Math.Abs(module - r[0]) < variance && Math.Abs(module - r[1]) < variance && Math.Abs(3 * module - r[2]) < 3 * variance
            && Math.Abs(module - r[3]) < variance && Math.Abs(module - r[4]) < variance;
    }
}
