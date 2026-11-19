using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// Pages in two languages (roadmap 2.2), read by two recognizers that can't read both at once (Windows' recognizer reads
/// one language): each reads the whole page, and for each line the reading that looks more like real words is kept.
/// Lines are matched by place (a line of one reading and a line of the other that share their height and overlap across
/// are the same line, with whatever lines those overlap); a line only one of them read is kept as read. A reading's words
/// count by their letters, each as much as it is plausible: known to its language's spell checker, else the engine's
/// confidence when it gives one, else half. Ties go to the first language. Tesseract reads two languages in one run
/// ("hin+eng") and doesn't need this.
/// </summary>
public sealed class MixedRecognizer(ITextRecognizer first, ISpelling? firstSpelling, ITextRecognizer second, ISpelling? secondSpelling)
    : ITextRecognizer, IRereadsMissed
{
    public string Language => first.Language;

    public string LanguageName => $"{first.LanguageName} + {second.LanguageName}";

    public ITextRecognizer First => first;

    public ITextRecognizer Second => second;

    /// <summary>
    /// The first one's re-reader (Windows' recognizer itself); none when the first is Tesseract, which skips no lines (the
    /// second language's recognizer would read a gap in the wrong language).
    /// </summary>
    public ITextRecognizer? Rereader => ScanText.RereaderOf(first);

    public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        var a = first.Recognize(pixels, width, height, channels, cancel);
        cancel.ThrowIfCancellationRequested();
        var b = second.Recognize(pixels, width, height, channels, cancel);
        return Choose(a, firstSpelling, b, secondSpelling);
    }

    /// <summary>For each line, the reading of <paramref name="a"/> or <paramref name="b"/> that is more plausible; in <paramref name="a"/>'s reading order.</summary>
    public static List<RecognizedWord> Choose(IReadOnlyList<RecognizedWord> a, ISpelling? spellA, IReadOnlyList<RecognizedWord> b, ISpelling? spellB)
    {
        var linesA = Lines(a);
        var linesB = Lines(b);
        // Union-find over A's lines (0..) and B's lines (linesA.Count..).
        var parent = Enumerable.Range(0, linesA.Count + linesB.Count).ToArray();
        int Find(int i)
        {
            while (parent[i] != i) i = parent[i] = parent[parent[i]];
            return i;
        }
        for (var i = 0; i < linesA.Count; i++)
        for (var j = 0; j < linesB.Count; j++)
            if (Same(linesA[i].Box, linesB[j].Box)) parent[Find(i)] = Find(linesA.Count + j);

        var scoreA = new Dictionary<int, double>();
        var scoreB = new Dictionary<int, double>();
        for (var i = 0; i < linesA.Count; i++) Add(scoreA, Find(i), linesA[i].Words.Sum(w => Plausibility(w, spellA)));
        for (var j = 0; j < linesB.Count; j++) Add(scoreB, Find(linesA.Count + j), linesB[j].Words.Sum(w => Plausibility(w, spellB)));
        bool TakesB(int group) => scoreB.GetValueOrDefault(group) > scoreA.GetValueOrDefault(group) || !scoreA.ContainsKey(group);

        // Groups in A's order; a group only B read goes after the group B read just before it.
        var order = new List<int>();
        var seen = new HashSet<int>();
        foreach (var g in Enumerable.Range(0, linesA.Count).Select(Find))
            if (seen.Add(g)) order.Add(g);
        var previous = -1;
        foreach (var g in Enumerable.Range(0, linesB.Count).Select(j => Find(linesA.Count + j)))
        {
            if (seen.Add(g)) order.Insert(previous < 0 ? 0 : order.IndexOf(previous) + 1, g);
            previous = g;
        }

        var result = new List<RecognizedWord>();
        var line = 0;
        foreach (var g in order)
        {
            var (lines, offset) = TakesB(g) ? (linesB, linesA.Count) : (linesA, 0);
            for (var k = 0; k < lines.Count; k++)
            {
                if (Find(offset + k) != g) continue;
                result.AddRange(lines[k].Words.Select(w => w with { Line = line }));
                line++;
            }
        }
        return result;

        static void Add(Dictionary<int, double> scores, int group, double score) => scores[group] = scores.GetValueOrDefault(group) + score;
    }

    /// <summary>
    /// How much a word counts for its reading: its letters, each as plausible as the word is (0-1). A word its spell
    /// checker knows: 1; one it doesn't (a name): a quarter, up to a half with the engine's confidence; without a spell
    /// checker: the engine's confidence, else a half. Letters mixed with digits or punctuation ("rn,1l", "negr0") read as
    /// garbage: a tenth at most, so they never outweigh a name.
    /// </summary>
    internal static double Plausibility(RecognizedWord word, ISpelling? spelling)
    {
        var core = SuspectWords.Core(word.Text);
        var letters = core.Count(char.IsLetter);
        if (letters == 0) return 0;
        var sure = word.Confidence is { } conf ? Math.Clamp(conf, 0, 100) / 100 : (double?)null;
        var wordLike = core.All(c => char.IsLetter(c) || char.GetUnicodeCategory(c) is System.Globalization.UnicodeCategory.NonSpacingMark
            or System.Globalization.UnicodeCategory.SpacingCombiningMark || c is '\'' or '’' or '-');
        double p;
        if (!wordLike) p = 0.1 * (sure ?? 1);
        else if (spelling is not null)
            p = core.Split('-', StringSplitOptions.RemoveEmptyEntries).All(spelling.IsKnown) ? 1 : 0.25 + 0.25 * (sure ?? 0);
        else p = sure ?? 0.5;
        return letters * p;
    }

    private static List<(List<RecognizedWord> Words, (double X0, double Y0, double X1, double Y1) Box)> Lines(IReadOnlyList<RecognizedWord> words)
    {
        var result = new List<(List<RecognizedWord>, (double, double, double, double))>();
        var index = new Dictionary<int, int>();
        foreach (var w in words)
        {
            if (!index.TryGetValue(w.Line, out var i))
            {
                index[w.Line] = i = result.Count;
                result.Add(([], (w.X, w.Y, w.X + w.Width, w.Y + w.Height)));
            }
            var (list, (x0, y0, x1, y1)) = result[i];
            list.Add(w);
            result[i] = (list, (Math.Min(x0, w.X), Math.Min(y0, w.Y), Math.Max(x1, w.X + w.Width), Math.Max(y1, w.Y + w.Height)));
        }
        return result;
    }

    /// <summary>The same line: they overlap across, and over at least half the shorter one's height.</summary>
    private static bool Same((double X0, double Y0, double X1, double Y1) a, (double X0, double Y0, double X1, double Y1) b)
    {
        var across = Math.Min(a.X1, b.X1) - Math.Max(a.X0, b.X0);
        var down = Math.Min(a.Y1, b.Y1) - Math.Max(a.Y0, b.Y0);
        return across > 0 && down >= 0.5 * Math.Min(a.Y1 - a.Y0, b.Y1 - b.Y0);
    }
}

/// <summary>
/// Two languages' spell checkers as one (suspect words on a page read in two languages): a word either knows is known;
/// suggestions from the first, then the second.
/// </summary>
public sealed class EitherSpelling(ISpelling first, ISpelling second) : ISpelling
{
    public string Language => first.Language;

    public bool IsKnown(string word) => first.IsKnown(word) || second.IsKnown(word);

    public IReadOnlyList<string> Suggest(string word) => [.. first.Suggest(word).Concat(second.Suggest(word)).Distinct().Take(8)];

    /// <summary>Both when there are two, else whichever there is.</summary>
    public static ISpelling? Of(ISpelling? first, ISpelling? second) =>
        first is null ? second : second is null ? first : new EitherSpelling(first, second);
}
