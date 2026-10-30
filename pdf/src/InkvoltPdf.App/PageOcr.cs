using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Windows.Ocr;

namespace InkvoltPdf.App;

/// <summary>
/// Text recognition with Windows' built-in OCR (Windows.Media.Ocr, on the device, nothing leaves the PC), through
/// <see cref="ScanText"/>: pages are rendered at 300 dpi, straightened, turned upright, despeckled and whitened, then
/// recognized. The default language is the first of the user's Windows display languages that has an OCR pack, else
/// English, else any installed OCR language; Recognize Text lets the user pick another installed one.
/// </summary>
internal static class PageOcr
{
    private static readonly Lock Gate = new();
    private static readonly Dictionary<string, WindowsRecognizer?> ByLanguage = [];
    private static readonly Dictionary<string, WindowsSpelling?> Spellings = [];
    private static WindowsRecognizer? _engine;
    private static bool _tried;

    /// <summary>The default recognizer, or null when no OCR language is installed on this PC.</summary>
    public static WindowsRecognizer? Engine
    {
        get
        {
            lock (Gate)
            {
                if (_tried) return _engine;
                _tried = true;
                try
                {
                    _engine = WindowsRecognizer.Create();
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    Log.Write($"OCR isn't available: {ex.Message}");
                    _engine = null;
                }
                return _engine;
            }
        }
    }

    /// <summary>The installed OCR languages (tag, name).</summary>
    public static IReadOnlyList<(string Tag, string Name)> Languages => WindowsRecognizer.Languages();

    /// <summary>The recognizer for an installed language (the default one for null or a language no longer installed).</summary>
    public static WindowsRecognizer? For(string? language)
    {
        if (string.IsNullOrEmpty(language)) return Engine;
        lock (Gate)
        {
            if (!ByLanguage.TryGetValue(language, out var r))
            {
                try
                {
                    r = WindowsRecognizer.Create(language);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    Log.Write($"OCR for {language} isn't available: {ex.Message}");
                    r = null;
                }
                ByLanguage[language] = r;
            }
            return r ?? Engine;
        }
    }

    /// <summary>Windows' spell checker for a language (or another region of it), or null when Windows has none.</summary>
    public static WindowsSpelling? Spelling(string? language)
    {
        if (string.IsNullOrEmpty(language)) return null;
        lock (Gate)
        {
            if (!Spellings.TryGetValue(language, out var s))
            {
                try
                {
                    s = WindowsSpelling.Create(language);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    Log.Write($"No spell checker for {language}: {ex.Message}");
                    s = null;
                }
                Spellings[language] = s;
            }
            return s;
        }
    }

    public const string Unavailable =
        "Windows has no text recognition (OCR) language installed. Add one in Settings > Time & language > Language & region (a language's options list \"Optical character recognition\").";

    /// <summary>
    /// The words on a page (page space: points, top-left of the displayed page), the page cleaned first. For the callers
    /// that only need words (Batch, export, re-recognizing after redaction): no suspect words, nothing written back.
    /// </summary>
    public static List<OcrWord> Recognize(ITextRecognizer engine, PdfEngine pdf, int page, CancellationToken cancel) =>
        [.. ScanText.Recognize(pdf, page, engine, new RecognizeOptions(CheckWords: false), null, cancel).Words];
}
