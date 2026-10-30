using System.Runtime.InteropServices.WindowsRuntime;
using InkvoltPrint.Core.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace InkvoltPrint.Windows.Ocr;

/// <summary>
/// Windows' built-in text recognition (Windows.Media.Ocr: on the device, nothing leaves the PC) for one installed OCR
/// language. Images larger than the engine's limit are read in overlapping tiles; a word cut by one tile is whole in its
/// neighbour, and each word is kept by the tile that owns its centre. Its words carry no confidence: Windows' OcrWord has
/// only its text and box.
/// </summary>
public sealed class WindowsRecognizer : ITextRecognizer
{
    private const int Overlap = 160; // px shared by neighbouring tiles

    private readonly OcrEngine _engine;

    private WindowsRecognizer(OcrEngine engine) => _engine = engine;

    public string Language => _engine.RecognizerLanguage.LanguageTag;
    public string LanguageName => _engine.RecognizerLanguage.DisplayName;

    /// <summary>The OCR languages installed on this PC (tag and name), in Windows' order.</summary>
    public static IReadOnlyList<(string Tag, string Name)> Languages()
    {
        try
        {
            return OcrEngine.AvailableRecognizerLanguages.Select(l => (l.LanguageTag, l.DisplayName)).ToList();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return [];
        }
    }

    /// <summary>
    /// The recognizer for <paramref name="language"/>; with none, the first of the user's Windows display languages that
    /// has an OCR pack, else English, else any installed OCR language. Null when no OCR language is installed.
    /// </summary>
    public static WindowsRecognizer? Create(string? language = null)
    {
        OcrEngine? engine = null;
        if (language is { Length: > 0 })
        {
            var lang = new global::Windows.Globalization.Language(language);
            if (OcrEngine.IsLanguageSupported(lang)) engine = OcrEngine.TryCreateFromLanguage(lang);
            return engine is null ? null : new WindowsRecognizer(engine);
        }
        engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine is null)
        {
            var english = new global::Windows.Globalization.Language("en-US");
            if (OcrEngine.IsLanguageSupported(english)) engine = OcrEngine.TryCreateFromLanguage(english);
        }
        if (engine is null && OcrEngine.AvailableRecognizerLanguages.FirstOrDefault() is { } any)
            engine = OcrEngine.TryCreateFromLanguage(any);
        return engine is null ? null : new WindowsRecognizer(engine);
    }

    public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        var max = (int)Math.Max(Overlap * 2 + 64, OcrEngine.MaxImageDimension);
        var words = new List<RecognizedWord>();
        var line = 0;
        foreach (var (x0, x1, coreX0, coreX1) in Tiles(width, max))
        foreach (var (y0, y1, coreY0, coreY1) in Tiles(height, max))
        {
            cancel.ThrowIfCancellationRequested();
            using var bitmap = TileBitmap(pixels, width, channels, x0, y0, x1 - x0, y1 - y0);
            var result = _engine.RecognizeAsync(bitmap).AsTask(cancel).GetAwaiter().GetResult();
            foreach (var l in result.Lines)
            {
                foreach (var word in l.Words)
                {
                    var r = word.BoundingRect;
                    double cx = x0 + r.X + r.Width / 2, cy = y0 + r.Y + r.Height / 2;
                    if (cx < coreX0 || cx >= coreX1 || cy < coreY0 || cy >= coreY1) continue; // the neighbouring tile has it
                    words.Add(new RecognizedWord(word.Text, x0 + r.X, y0 + r.Y, r.Width, r.Height, line));
                }
                line++;
            }
        }
        return words;
    }

    /// <summary>Overlapping spans of at most <paramref name="max"/> px covering 0..<paramref name="size"/>, each with the part it owns.</summary>
    private static IEnumerable<(int Start, int End, int CoreStart, int CoreEnd)> Tiles(int size, int max)
    {
        if (size <= max)
        {
            yield return (0, size, 0, size);
            yield break;
        }
        var step = max - Overlap;
        for (var start = 0; ; start += step)
        {
            var end = Math.Min(size, start + max);
            var last = end == size;
            yield return (start, end, start == 0 ? 0 : start + Overlap / 2, last ? size : end - Overlap / 2);
            if (last) yield break;
        }
    }

    private static SoftwareBitmap TileBitmap(byte[] pixels, int width, int channels, int x, int y, int w, int h)
    {
        var bgra = new byte[w * h * 4];
        for (var row = 0; row < h; row++)
        {
            var src = ((y + row) * width + x) * channels;
            var dst = row * w * 4;
            for (var col = 0; col < w; col++, src += channels, dst += 4)
            {
                if (channels == 1) bgra[dst] = bgra[dst + 1] = bgra[dst + 2] = pixels[src];
                else
                {
                    bgra[dst] = pixels[src];
                    bgra[dst + 1] = pixels[src + 1];
                    bgra[dst + 2] = pixels[src + 2];
                }
                bgra[dst + 3] = 255;
            }
        }
        return SoftwareBitmap.CreateCopyFromBuffer(bgra.AsBuffer(), BitmapPixelFormat.Bgra8, w, h, BitmapAlphaMode.Premultiplied);
    }
}
