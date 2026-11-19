namespace InkvoltPdf.Core;

/// <summary>Which engine reads a page.</summary>
public enum OcrEngine
{
    /// <summary>Windows' recognizer (one language, or two chosen line by line: <see cref="MixedRecognizer"/>).</summary>
    Windows,
    /// <summary>Tesseract, every language in one run.</summary>
    Tesseract,
    /// <summary>Windows' recognizer for one language and Tesseract for the other, chosen line by line.</summary>
    WindowsAndTesseract,
}

/// <summary>
/// A language Recognize Text offers: its tag and name, whether Windows has an OCR language installed for it, and
/// Tesseract's model for it (null when Tesseract hasn't one).
/// </summary>
public sealed record OcrLanguageChoice(string Tag, string Name, bool Windows, TesseractLanguage? Tesseract);

/// <summary>
/// How a choice of languages is read and what must be downloaded first: <see cref="NeedsEngine"/> (Tesseract isn't on this
/// PC) and <see cref="ToDownload"/> (its languages that aren't).
/// </summary>
public sealed record OcrPlan(OcrLanguageChoice First, OcrLanguageChoice? Second, OcrEngine Engine, IReadOnlyList<TesseractLanguage> Tesseract,
    bool NeedsEngine, IReadOnlyList<TesseractLanguage> ToDownload)
{
    public bool NeedsDownload => NeedsEngine || ToDownload.Count > 0;

    /// <summary>What the download takes: the installer (the engine is taken out of it) and the languages' data.</summary>
    public long DownloadBytes => (NeedsEngine ? TesseractCatalog.InstallerSize : 0) + ToDownload.Sum(l => l.Size);
}

/// <summary>
/// The OCR languages Recognize Text offers and how a choice is read (roadmap 2.2): Windows' installed OCR languages
/// first, then Tesseract's languages that none of them reads (an optional download). One language: Windows' recognizer
/// when Windows has it, else Tesseract. Two languages on the same pages: both Windows' → Windows' recognizer for each,
/// the better line kept (<see cref="MixedRecognizer"/>, no download); else Tesseract reads both at once ("hin+eng"),
/// which reads words of either language inside a line.
/// </summary>
public static class OcrLanguages
{
    /// <param name="windows">Windows' installed OCR languages (tag, name), in Windows' order.</param>
    /// <param name="nameOf">A Tesseract language's name as the person reads it.</param>
    public static List<OcrLanguageChoice> Offer(IReadOnlyList<(string Tag, string Name)> windows, Func<TesseractLanguage, string> nameOf)
    {
        var result = windows.Select(w => new OcrLanguageChoice(w.Tag, w.Name, true, TesseractCatalog.ForTag(w.Tag))).ToList();
        var covered = result.Where(r => r.Tesseract is not null).Select(r => r.Tesseract!.Code).ToHashSet();
        result.AddRange(TesseractCatalog.Languages.Where(l => !covered.Contains(l.Code))
            .Select(l => new OcrLanguageChoice(l.Tag, nameOf(l), false, l))
            .OrderBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase));
        return result;
    }

    /// <summary>
    /// The choice with <paramref name="tag"/> (as saved), else the one that reads the same language (a Windows language
    /// removed since: Tesseract's, to download; "en-US" saved, "en-GB" installed); null when nothing reads it.
    /// </summary>
    public static OcrLanguageChoice? Find(IReadOnlyList<OcrLanguageChoice> offer, string? tag)
    {
        if (string.IsNullOrEmpty(tag)) return null;
        return offer.FirstOrDefault(c => string.Equals(c.Tag, tag, StringComparison.OrdinalIgnoreCase))
            ?? (TesseractCatalog.ForTag(tag) is { } same ? offer.FirstOrDefault(c => c.Tesseract?.Code == same.Code) : null);
    }

    /// <param name="second">The other language on the same pages; null (or the same one): one language.</param>
    /// <param name="hasEngine">Tesseract is on this PC.</param>
    /// <param name="hasLanguage">A Tesseract language's data is on this PC.</param>
    public static OcrPlan Plan(OcrLanguageChoice first, OcrLanguageChoice? second, bool hasEngine, Func<TesseractLanguage, bool> hasLanguage)
    {
        if (second is not null && string.Equals(second.Tag, first.Tag, StringComparison.OrdinalIgnoreCase)) second = null;
        OcrEngine engine;
        List<TesseractLanguage> tesseract;
        if (second is null && (first.Windows || first.Tesseract is null)) (engine, tesseract) = (OcrEngine.Windows, new List<TesseractLanguage>());
        else if (second is null) (engine, tesseract) = (OcrEngine.Tesseract, new List<TesseractLanguage> { first.Tesseract! });
        else if (first.Windows && second.Windows) (engine, tesseract) = (OcrEngine.Windows, new List<TesseractLanguage>());
        else if (first.Tesseract is not null && second.Tesseract is not null)
            (engine, tesseract) = (OcrEngine.Tesseract, new List<TesseractLanguage> { first.Tesseract, second.Tesseract });
        else
            // One that only Windows reads (no Tesseract model) with one that only Tesseract reads.
            (engine, tesseract) = (OcrEngine.WindowsAndTesseract, new List<TesseractLanguage> { (first.Windows ? second : first).Tesseract! });
        return new OcrPlan(first, second, engine, tesseract, tesseract.Count > 0 && !hasEngine, [.. tesseract.Where(l => !hasLanguage(l))]);
    }
}
