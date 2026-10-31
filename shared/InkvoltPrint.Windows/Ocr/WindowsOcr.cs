using System.Runtime.InteropServices.WindowsRuntime;
using OcrWord = InkvoltPrint.Core.Pdf.OcrWord;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace InkvoltPrint.Windows.Ocr;

/// <summary>Inbox Windows OCR (no cloud, no downloads): uses the OCR languages installed with Windows.</summary>
public static class WindowsOcr
{
    private const int OcrDpi = 300;

    public static bool IsAvailable => OcrEngine.TryCreateFromUserProfileLanguages() is not null;

    private static OcrEngine? Engine(string? language)
    {
        if (language is { Length: > 0 })
        {
            try
            {
                var wanted = new global::Windows.Globalization.Language(language);
                if (OcrEngine.IsLanguageSupported(wanted) && OcrEngine.TryCreateFromLanguage(wanted) is { } engine) return engine;
            }
            catch (ArgumentException)
            {
                // not a language tag: a hand-edited setting
            }
        }
        return OcrEngine.TryCreateFromUserProfileLanguages();
    }

    /// <summary>Recognises words in a JPEG page. Coordinates are returned in the JPEG's own pixel space.</summary>
    /// <param name="language">The language to read (a BCP-47 tag of an installed OCR language); null, or one no longer installed: Windows' first display language that has OCR.</param>
    public static async Task<IReadOnlyList<OcrWord>> RecognizeAsync(byte[] jpeg, int dpi, CancellationToken ct = default, string? language = null)
    {
        var engine = Engine(language) ?? throw new InvalidOperationException("No OCR language installed");
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(jpeg.AsBuffer()).AsTask(ct);
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(ct);

        // OCR is as accurate at 300 dpi as at 600, and 4x faster; scale boxes back afterwards.
        var factor = dpi > OcrDpi ? (double)OcrDpi / dpi : 1.0;
        var maxDim = OcrEngine.MaxImageDimension;
        factor = Math.Min(factor, Math.Min((double)maxDim / decoder.PixelWidth, (double)maxDim / decoder.PixelHeight));
        var transform = new BitmapTransform
        {
            ScaledWidth = (uint)Math.Max(1, decoder.PixelWidth * factor),
            ScaledHeight = (uint)Math.Max(1, decoder.PixelHeight * factor),
            InterpolationMode = BitmapInterpolationMode.Fant,
        };
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform,
            ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage).AsTask(ct);
        var result = await engine.RecognizeAsync(bitmap).AsTask(ct);

        var inv = 1 / factor;
        return result.Lines
            .SelectMany(l => l.Words)
            .Select(w => new OcrWord(w.Text, w.BoundingRect.X * inv, w.BoundingRect.Y * inv, w.BoundingRect.Width * inv, w.BoundingRect.Height * inv))
            .ToList();
    }
}
