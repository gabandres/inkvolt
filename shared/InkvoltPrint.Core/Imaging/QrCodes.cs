using ZXing;
using ZXing.QrCode;
using ZXing.QrCode.Internal;

namespace InkvoltPrint.Core.Imaging;

/// <summary>QR codes written (ZXing.Net): the separator sheet's (<see cref="SeparatorCodes"/>) and a phone scan's address (<see cref="Capture.PhoneLink"/>).</summary>
public static class QrCodes
{
    /// <summary>
    /// The QR code of <paramref name="text"/> as its modules, true for dark, <c>[row, column]</c>, without its quiet zone (four modules
    /// of white around it). <paramref name="high"/>: the highest error correction (H, 30%), for paper that may be smudged or punched;
    /// otherwise M (15%), for a screen, with fewer and larger modules.
    /// </summary>
    public static bool[,] Modules(string text, bool high)
    {
        var matrix = new QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, new Dictionary<EncodeHintType, object>
        {
            [EncodeHintType.ERROR_CORRECTION] = high ? ErrorCorrectionLevel.H : ErrorCorrectionLevel.M,
            [EncodeHintType.MARGIN] = 0,
        });
        var modules = new bool[matrix.Height, matrix.Width];
        for (var y = 0; y < matrix.Height; y++)
            for (var x = 0; x < matrix.Width; x++)
                modules[y, x] = matrix[x, y];
        return modules;
    }
}
