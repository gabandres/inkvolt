using System.Globalization;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>Why a recognized word is a suspect word (several may apply).</summary>
[Flags]
public enum SuspectReasons
{
    None = 0,
    /// <summary>The spell checker for the recognized language doesn't know it.</summary>
    NotInDictionary = 1,
    /// <summary>Letters and digits mixed inside it ("c0de", "1O5"), the way OCR confuses O and 0, l and 1, S and 5.</summary>
    LettersAndDigits = 2,
    /// <summary>A character text rarely has (|, ¦, a control or private-use character), or punctuation inside the word.</summary>
    OddCharacters = 4,
    /// <summary>Read differently from the page as scanned than from the cleaned page.</summary>
    ReadDifferently = 8,
}

/// <summary>
/// Suspect words: recognized words worth a second look. Windows' recognizer gives no confidence per word (its OcrWord has
/// only its text and box), so this is a heuristic, never a score: a word is suspect when the spell checker for the
/// page's language doesn't know it, when letters and digits are mixed inside it, when it has odd characters, or when the
/// page as scanned and the cleaned page gave different words at its place. Short words, numbers, words in capitals (an
/// acronym) and the usual mixes (A4, 2nd, 10mm, MP3) are left alone.
/// </summary>
public static class SuspectWords
{
    private const string Edges = ".,;:!?¿¡\"'“”‘’«»()[]{}…*";

    public static SuspectReasons Check(string text, ISpelling? spelling)
    {
        var core = Core(text);
        if (core.Length == 0) return text.Any(Odd) ? SuspectReasons.OddCharacters : SuspectReasons.None;
        var reasons = SuspectReasons.None;
        if (text.Any(Odd) || PunctuationInside(core)) reasons |= SuspectReasons.OddCharacters;
        if (MixedInside(core)) reasons |= SuspectReasons.LettersAndDigits;
        if (spelling is not null && NeedsDictionary(core) && core.Split('-', StringSplitOptions.RemoveEmptyEntries).Any(part => !spelling.IsKnown(part)))
            reasons |= SuspectReasons.NotInDictionary;
        return reasons;
    }

    /// <summary>The word without the punctuation around it ("(river)," → "river").</summary>
    public static string Core(string text) => text.Trim().Trim(Edges.ToCharArray());

    /// <summary>
    /// For each word of <paramref name="cleaned"/>, whether the page as scanned (<paramref name="original"/>, in the same
    /// page space) read the same word differently: its word nearest the same place (centres within half a line) is
    /// spelled a little differently (at most a third of its letters) and is itself a real word (in
    /// <paramref name="spelling"/>'s dictionary, when there is one). Then either reading may be the right one. A place
    /// where the scan gave no word, a garbled one or another word altogether doesn't count.
    /// </summary>
    public static bool[] ReadDifferently(IReadOnlyList<OcrWord> cleaned, IReadOnlyList<OcrWord> original, ISpelling? spelling = null)
    {
        var result = new bool[cleaned.Count];
        for (var i = 0; i < cleaned.Count; i++)
            result[i] = Alternative(cleaned[i], original) is { } other
                && (spelling is null || !NeedsDictionary(other) || spelling.IsKnown(other));
        return result;
    }

    /// <summary>
    /// The page as scanned's reading of a word, when it is the same word read a little differently (see
    /// <see cref="ReadDifferently"/>), without the punctuation around it; else null.
    /// </summary>
    public static string? Alternative(OcrWord cleaned, IReadOnlyList<OcrWord> original)
    {
        var (cx, cy) = (cleaned.Rect.CenterX, cleaned.Rect.CenterY);
        var reach = cleaned.Rect.Height / 2;
        var nearest = original.Where(o => Math.Abs(o.Rect.CenterY - cy) < reach && o.Rect.Contains(cx, cy))
            .MinBy(o => Math.Abs(o.Rect.CenterX - cx) + Math.Abs(o.Rect.CenterY - cy));
        if (nearest is null) return null;
        var (mine, theirs) = (Core(cleaned.Text), Core(nearest.Text));
        if (theirs.Length == 0 || mine == theirs) return null;
        return Distance(mine, theirs) <= Math.Max(1, Math.Max(mine.Length, theirs.Length) / 3) ? theirs : null;
    }

    /// <summary>Letters to change, add or remove to turn one word into the other (Levenshtein).</summary>
    private static int Distance(string a, string b)
    {
        var previous = new int[b.Length + 1];
        var current = new int[b.Length + 1];
        for (var j = 0; j <= b.Length; j++) previous[j] = j;
        for (var i = 1; i <= a.Length; i++)
        {
            current[0] = i;
            for (var j = 1; j <= b.Length; j++)
                current[j] = Math.Min(previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), Math.Min(previous[j] + 1, current[j - 1] + 1));
            (previous, current) = (current, previous);
        }
        return previous[b.Length];
    }

    /// <summary>A word to look up: two letters or more, all letters (apostrophes and hyphens inside), not an acronym.</summary>
    private static bool NeedsDictionary(string core) =>
        core.Count(char.IsLetter) >= 2
        && core.All(c => char.IsLetter(c) || c is '\'' or '’' or '-')
        && !(core.All(c => !char.IsLower(c)) && core.Length <= 6);

    /// <summary>A digit between letters or a letter between digits; "A4", "MP3", "2nd", "10mm", "COVID-19" are fine.</summary>
    private static bool MixedInside(string core)
    {
        for (var i = 1; i + 1 < core.Length; i++)
        {
            var (before, here, after) = (core[i - 1], core[i], core[i + 1]);
            if (char.IsDigit(here) && char.IsLetter(before) && char.IsLetter(after)) return true;
            if (char.IsLetter(here) && char.IsDigit(before) && char.IsDigit(after)) return true;
        }
        // A lone O, l or I among digits at the end or start ("100O", "l23") reads as a digit misread.
        return core.Length >= 3 && (core.Count(char.IsDigit) >= core.Length - 1) && core.Any(c => c is 'O' or 'o' or 'l' or 'I');
    }

    /// <summary>Punctuation a word doesn't have inside it ("wo;rd", "riv(er"); a comma between digits (1,234) is fine.</summary>
    private static bool PunctuationInside(string core)
    {
        for (var i = 0; i < core.Length; i++)
        {
            var c = core[i];
            if (c is ';' or '!' or '?' or '"' or '(' or ')' or '[' or ']' or '{' or '}' or '¿' or '¡') return true;
            if (c == ',' && !(i > 0 && i + 1 < core.Length && char.IsDigit(core[i - 1]) && char.IsDigit(core[i + 1]))) return true;
        }
        return false;
    }

    private static bool Odd(char c) =>
        c is '|' or '¦' or '�' || char.IsControl(c) || CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.PrivateUse or UnicodeCategory.Surrogate or UnicodeCategory.OtherNotAssigned;
}
