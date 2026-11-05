using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>
/// A page recognizer: a recognizer with the choices of how it reads (<see cref="RecognizeOptions"/>: cleaned or as scanned,
/// suspect words, the cleaned pages kept) and the spell checker for its language, reading a document's pages without text
/// into words for a text layer (<see cref="RecognizedPages"/>). Pages that already have text are left alone. Recognize Text,
/// Batch's Recognize Text, the scan dialog and Apply Redactions (<see cref="Redaction.ApplyWithText"/>) read pages through
/// it; the recognizer is the seam (Windows' <c>WindowsRecognizer</c>, a test's stand-in).
/// </summary>
/// <param name="options">Null: <see cref="RecognizeOptions"/>' defaults.</param>
/// <param name="spelling">For suspect words (<see cref="RecognizeOptions.CheckWords"/>); null: no dictionary.</param>
public sealed class PageRecognizer(ITextRecognizer recognizer, RecognizeOptions? options = null, ISpelling? spelling = null)
{
    /// <summary>The recognizer itself, for what reads single places of a page (Redact Patterns' search).</summary>
    public ITextRecognizer Recognizer => recognizer;

    public RecognizeOptions Options { get; } = options ?? new RecognizeOptions();

    /// <summary>The language it reads in (a BCP-47 tag), kept with the text layer for its review.</summary>
    public string Language => recognizer.Language;

    /// <summary>
    /// The words on one page, read as <see cref="Options"/> say, whether it has text or not; nothing is kept or written
    /// (export's <see cref="ExportOptions.Recognize"/>).
    /// </summary>
    public IReadOnlyList<OcrWord> Page(PdfEngine engine, int page, CancellationToken cancel) =>
        ScanText.Recognize(engine, page, recognizer, Options with { KeepCleanedImage = false }, spelling, cancel).Words;

    /// <summary>Reads the pages of <paramref name="data"/> (on the calling thread; the document is opened for it).</summary>
    /// <inheritdoc cref="Recognize(PdfEngine, IReadOnlyList{int}?, IReadOnlyDictionary{int, IReadOnlyList{RectD}}?, IProgress{ValueTuple{int, int}}?, CancellationToken)"/>
    public RecognizedPages Recognize(byte[] data, string? password, IReadOnlyList<int>? pages = null,
        IReadOnlyDictionary<int, IReadOnlyList<RectD>>? exclude = null, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
        return Recognize(engine, pages, exclude, progress, cancel);
    }

    /// <param name="pages">The pages to read, in order (any outside the document left out); null: every page.</param>
    /// <param name="exclude">Black boxes per page (redacted areas): a word mostly inside one isn't kept, nor a letter or two
    /// touching one (that is the recognizer reading the box's edge, not a word).</param>
    /// <param name="progress">(pages done, pages), before each page.</param>
    public RecognizedPages Recognize(PdfEngine engine, IReadOnlyList<int>? pages = null,
        IReadOnlyDictionary<int, IReadOnlyList<RectD>>? exclude = null, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        pages ??= [.. Enumerable.Range(0, engine.PageCount)];
        var words = new Dictionary<int, IReadOnlyList<OcrWord>>();
        var cleaned = new Dictionary<int, CleanedPageImage>();
        var hadText = 0;
        for (var i = 0; i < pages.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            progress?.Report((i, pages.Count));
            var page = pages[i];
            if (page < 0 || page >= engine.PageCount) continue;
            if (TextLayer.HasText(engine, page))
            {
                hadText++;
                continue;
            }
            var read = ScanText.Recognize(engine, page, recognizer, Options, spelling, cancel);
            var kept = read.Words.ToList();
            if (exclude is not null && exclude.TryGetValue(page, out var blacked))
                kept.RemoveAll(w => blacked.Any(b => Overlap(w.Rect, b) > (w.Text.Trim().Length <= 2 ? 0 : 0.3 * w.Rect.Width * w.Rect.Height)));
            if (kept.Count > 0) words[page] = kept;
            if (read.Cleaned is { } image) cleaned[page] = image;
        }
        return new RecognizedPages(words, hadText, cleaned, Language);

        static double Overlap(RectD a, RectD b) =>
            Math.Max(0, Math.Min(a.Right, b.Right) - Math.Max(a.X, b.X)) * Math.Max(0, Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Y, b.Y));
    }
}

/// <summary>What a <see cref="PageRecognizer"/> read.</summary>
/// <param name="Words">Per page that had any, in reading order.</param>
/// <param name="HadText">Pages left alone because they already had text.</param>
/// <param name="Cleaned">The cleaned pages to put in place of the scans (only with <see cref="RecognizeOptions.KeepCleanedImage"/>).</param>
/// <param name="Language">What the words were read in.</param>
public sealed record RecognizedPages(IReadOnlyDictionary<int, IReadOnlyList<OcrWord>> Words, int HadText,
    IReadOnlyDictionary<int, CleanedPageImage> Cleaned, string? Language)
{
    public int WordCount => Words.Values.Sum(w => w.Count);

    public int SuspectCount => Words.Values.Sum(w => w.Count(x => x.IsSuspect));

    /// <summary>
    /// The document with these pages' text layers (the words invisible over the pages, in <see cref="Language"/>), the scans
    /// replaced by the cleaned pages first when there are any; the data as it is when nothing was read.
    /// </summary>
    public byte[] Write(byte[] data, string? password)
    {
        if (Cleaned.Count > 0) data = ScanPage.WriteBack(data, password, Cleaned);
        return WordCount == 0 ? data : TextLayer.AddInvisibleText(data, password, Words, Language);
    }
}

/// <summary>Progress reported on the calling thread, as it happens (<see cref="Progress{T}"/> posts it, in any order, to the thread pool off the UI thread).</summary>
public sealed class DirectProgress<T>(Action<T> report) : IProgress<T>
{
    public void Report(T value) => report(value);
}
