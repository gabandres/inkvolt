using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Tests;

/// <summary>
/// Stands in for the recognizer, without a language of its own: told where each page's words are on the upright page, it
/// tells which page it was handed from its shape (each corpus page has a height of its own), and returns the words it can
/// see there (ink in the box, not blacked out), so what comes back after redacting really is what is left to see. A word
/// can be dropped, as Windows' recognizer sometimes drops a whole line, and come back or not when its place is read alone.
/// </summary>
internal sealed class PlantedReader : ITextRecognizer
{
    /// <summary>A word, its box as shares of the page's size.</summary>
    private sealed record Word(string Text, double X, double Y, double W, double H);

    private sealed record Sheet(double Shape, List<Word> Words);

    private readonly List<Sheet> _sheets = [];

    public string Language => "en-US";

    public string LanguageName => "English";

    /// <summary>These words aren't read when a whole page is.</summary>
    public HashSet<string> Dropped { get; } = [];

    /// <summary>A dropped word is read when its place is read on its own.</summary>
    public bool ReadsPlacesAlone { get; set; }

    /// <summary>How many places were read on their own.</summary>
    public int PlacesRead { get; private set; }

    public void Plant(double pageWidth, double pageHeight, PageText text)
    {
        var words = new List<(string, RectD)>();
        var value = text.Text;
        for (var i = 0; i < value.Length;)
        {
            if (char.IsWhiteSpace(value[i]))
            {
                i++;
                continue;
            }
            var end = i;
            while (end < value.Length && !char.IsWhiteSpace(value[end])) end++;
            words.Add((value[i..end], text.GetRects(i, end)[0]));
            i = end;
        }
        PlantWords(pageWidth, pageHeight, words);
    }

    /// <param name="words">Boxes in points on the page.</param>
    public void PlantWords(double pageWidth, double pageHeight, IEnumerable<(string Text, RectD Box)> words) =>
        _sheets.Add(new Sheet(pageWidth / pageHeight, [.. words.Select(w => new Word(w.Text, w.Box.X / pageWidth, w.Box.Y / pageHeight, w.Box.Width / pageWidth, w.Box.Height / pageHeight))]));

    public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, width, height);
        if (height < 500)
        {
            PlacesRead++;
            if (!ReadsPlacesAlone || Dropped.Count == 0) return [];
            var inked = Enumerable.Range(0, gray.Length).Where(i => gray[i] < 128).ToList();
            if (inked.Count == 0) return [];
            var text = Dropped.First();
            Dropped.Remove(text);
            var (x0, y0) = (inked.Min(i => i % width), inked.Min(i => i / width));
            var (x1, y1) = (inked.Max(i => i % width), inked.Max(i => i / width));
            return [new RecognizedWord(text, x0, y0, x1 - x0 + 1, y1 - y0 + 1, 0)];
        }
        var shape = width / (double)height;
        var sheet = _sheets.MinBy(s => Math.Abs(s.Shape - shape));
        if (sheet is null || Math.Abs(sheet.Shape - shape) > 0.002) return []; // on its side still: nothing reads
        var found = new List<RecognizedWord>();
        foreach (var w in sheet.Words)
        {
            if (Dropped.Contains(w.Text)) continue;
            var (x, y, bw, bh) = (w.X * width, w.Y * height, w.W * width, w.H * height);
            if (Sees(gray, width, height, x, y, bw, bh)) found.Add(new RecognizedWord(w.Text, x, y, bw, bh, 0));
        }
        return found;
    }

    /// <summary>Ink in the word's box, and not a black bar.</summary>
    private static bool Sees(byte[] gray, int width, int height, double wx, double wy, double ww, double wh)
    {
        var (x0, y0) = (Math.Clamp((int)wx, 0, width), Math.Clamp((int)wy, 0, height));
        var (x1, y1) = (Math.Clamp((int)(wx + ww), 0, width), Math.Clamp((int)(wy + wh), 0, height));
        if (x1 <= x0 || y1 <= y0) return false;
        var dark = 0;
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
                if (gray[y * width + x] < 128) dark++;
        var share = dark / (double)((x1 - x0) * (y1 - y0));
        return share is > 0.03 and < 0.8;
    }
}
