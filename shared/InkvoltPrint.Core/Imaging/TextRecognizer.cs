namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// A recognized word: its text and its box in the recognized image's pixels, which line it was read on, and how sure the
/// engine was (0-100) when it says: Tesseract does, Windows' recognizer doesn't (null).
/// </summary>
public sealed record RecognizedWord(string Text, double X, double Y, double Width, double Height, int Line, double? Confidence = null);

/// <summary>
/// A text recognition engine, on this device: Windows' own (Windows.Media.Ocr), Apple's Vision on the Mac, and Inkvolt
/// PDF's optional Tesseract (roadmap 2.2). It reads a page image and returns its words in reading order. Windows'
/// recognizer gives no per-word confidence, so doubtful words are found by <c>SuspectWords</c>; Tesseract's confidence,
/// when there is one, is one more reason.
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
