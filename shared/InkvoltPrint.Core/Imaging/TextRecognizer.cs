namespace InkvoltPrint.Core.Imaging;

/// <summary>A recognized word: its text and its box in the recognized image's pixels, and which line it was read on.</summary>
public sealed record RecognizedWord(string Text, double X, double Y, double Width, double Height, int Line);

/// <summary>
/// A text recognition engine, on this device: Windows' own today (Windows.Media.Ocr), Apple's Vision on the Mac; a second
/// engine (Tesseract, roadmap 2.2's later stage) would be another implementation. It reads a page image and returns its
/// words in reading order. No engine Inkvolt uses gives a per-word confidence (Windows' doesn't have one), so
/// nothing here pretends to: doubtful words are found by <c>SuspectWords</c> instead.
/// </summary>
public interface ITextRecognizer
{
    /// <summary>The language it reads, as a BCP-47 tag ("en-US", "es-MX").</summary>
    string Language { get; }

    /// <summary>The language as the user knows it ("English (United States)").</summary>
    string LanguageName { get; }

    /// <summary>
    /// The words in <paramref name="pixels"/>: rows of <paramref name="width"/> × <paramref name="channels"/> bytes (1 = grey,
    /// 3 = BGR), no padding. May be called from any thread, one call at a time.
    /// </summary>
    IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default);
}

/// <summary>A spelling dictionary for one language (Windows' spell checker; the Mac's NSSpellChecker).</summary>
public interface ISpelling
{
    string Language { get; }

    /// <summary>Whether the dictionary knows the word (as written; a word it would only auto-correct isn't known).</summary>
    bool IsKnown(string word);

    /// <summary>Its suggestions for a word, best first; none when it has none.</summary>
    IReadOnlyList<string> Suggest(string word);
}
