namespace InkvoltPdf.OcrCorpus;

/// <summary>
/// Word error rate: the fewest words to substitute, delete or insert to turn the recognized text into the true text
/// (a Levenshtein distance over words), divided by the number of true words. Words are compared exactly, accents,
/// case and punctuation included, as a search would see them. 0 is perfect; above 1 is possible (many extra words).
/// </summary>
public static class WordErrorRate
{
    public static double Of(IReadOnlyList<string> truth, IReadOnlyList<string> recognized) =>
        truth.Count == 0 ? (recognized.Count == 0 ? 0 : 1) : (double)Edits(truth, recognized) / truth.Count;

    public static int Edits(IReadOnlyList<string> truth, IReadOnlyList<string> recognized)
    {
        var previous = new int[recognized.Count + 1];
        var current = new int[recognized.Count + 1];
        for (var j = 0; j <= recognized.Count; j++) previous[j] = j;
        for (var i = 1; i <= truth.Count; i++)
        {
            current[0] = i;
            for (var j = 1; j <= recognized.Count; j++)
            {
                var substitute = previous[j - 1] + (string.Equals(truth[i - 1], recognized[j - 1], StringComparison.Ordinal) ? 0 : 1);
                current[j] = Math.Min(substitute, Math.Min(previous[j] + 1, current[j - 1] + 1));
            }
            (previous, current) = (current, previous);
        }
        return previous[recognized.Count];
    }

    /// <summary>
    /// The most true words in a row that the recognized text leaves out (deletions next to each other in a fewest-edits
    /// alignment): a line the recognizer skipped shows as a run as long as the line.
    /// </summary>
    public static int LongestMissedRun(IReadOnlyList<string> truth, IReadOnlyList<string> recognized)
    {
        var (n, m) = (truth.Count, recognized.Count);
        var d = new int[n + 1, m + 1];
        for (var i = 0; i <= n; i++) d[i, 0] = i;
        for (var j = 0; j <= m; j++) d[0, j] = j;
        for (var i = 1; i <= n; i++)
            for (var j = 1; j <= m; j++)
                d[i, j] = Math.Min(d[i - 1, j - 1] + (string.Equals(truth[i - 1], recognized[j - 1], StringComparison.Ordinal) ? 0 : 1),
                    Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1));
        int longest = 0, run = 0;
        for (int i = n, j = m; i > 0 || j > 0;)
        {
            if (i > 0 && j > 0 && d[i, j] == d[i - 1, j - 1] + (string.Equals(truth[i - 1], recognized[j - 1], StringComparison.Ordinal) ? 0 : 1))
            {
                (i, j, run) = (i - 1, j - 1, 0);
                continue;
            }
            if (i > 0 && d[i, j] == d[i - 1, j] + 1)
            {
                i--;
                longest = Math.Max(longest, ++run);
                continue;
            }
            (j, run) = (j - 1, 0);
        }
        return longest;
    }

    /// <summary>The words of a recognized text, split on white space.</summary>
    public static IReadOnlyList<string> Words(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
}
